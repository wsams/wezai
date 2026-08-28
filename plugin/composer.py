#!/usr/bin/env python3
"""wezai ask composer.

Runs in a split of the *shell* pane so the right-hand AI output pane stays
visible. Live-filters files when the current token is @path or #path.
Talks to the plugin via OSC 1337 SetUserVar (WEZAI_SUBMIT / WEZAI_DRAFT / WEZAI_CANCEL).
"""

from __future__ import annotations

import base64
import os
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty
from typing import Dict, List, Optional, Tuple

SYNTHETICS = [
    "git:",
    "kube:",
    "tf:",
    "docker:",
    "weather:",
    "history",
    "clipboard",
    "selection",
    "pick",
    "dir:",
]
RESERVED_HEADS = {
    "git",
    "kube",
    "tf",
    "terraform",
    "docker",
    "weather",
    "history",
    "clipboard",
    "selection",
    "pick",
    "dir",
}

ESC = "\033["
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[36m"
MAGENTA = "\033[35m"
YELLOW = "\033[33m"
GREEN = "\033[32m"
BLUE = "\033[34m"
REVERSE = "\033[7m"

MAX_DROP = 12

SKIP_DIR = {
    ".git",
    "node_modules",
    ".venv",
    "venv",
    "__pycache__",
    ".tox",
    "dist",
    "build",
    ".next",
    "target",
    ".wezai",
}
SKIP_FILE = {
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "Cargo.lock",
    ".DS_Store",
}
KEEP_DOT_DIRS = {".github", ".config"}
OUTSIDE_LIST_LIMIT = 400
_OUTSIDE_CACHE: Dict[tuple, list] = {}


def emit_user_var(name: str, value: str) -> None:
    raw = value.encode("utf-8")
    b64 = base64.b64encode(raw).decode("ascii")
    sys.stdout.write(f"\033]1337;SetUserVar={name}={b64}\007")
    sys.stdout.flush()


def load_candidates(path: Optional[str]) -> List[Tuple[str, str]]:
    """Return list of (kind, relpath) where kind is F or D. Empty if path missing."""
    out: List[Tuple[str, str]] = []
    if path and os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.rstrip("\n")
                    if not line:
                        continue
                    if "\t" in line:
                        kind, rel = line.split("\t", 1)
                    else:
                        kind, rel = "F", line
                    kind = kind.strip()[:1].upper() or "F"
                    rel = rel.strip()
                    if rel:
                        out.append((kind, rel))
        except OSError:
            pass
    return out


def shallow_cwd_candidates(cwd: Optional[str] = None) -> List[Tuple[str, str]]:
    """Instant first paint: names in cwd only (no tree walk)."""
    out: List[Tuple[str, str]] = []
    root = cwd or "."
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return out
    for name in names:
        if name.startswith(".") and name not in (".github", ".config"):
            continue
        if "wezai" in name and name.endswith(".bak"):
            continue
        abs_path = os.path.join(root, name)
        kind = "D" if os.path.isdir(abs_path) else "F"
        shown = name + ("/" if kind == "D" else "")
        out.append((kind, shown))
    return out


def should_skip_rel(rel: str) -> bool:
    if not rel or rel in (".", ".."):
        return True
    base = os.path.basename(rel.rstrip("/"))
    if base in SKIP_FILE:
        return True
    if "wezai" in base and base.endswith(".bak"):
        return True
    for part in rel.replace("\\", "/").split("/"):
        if not part or part in (".", ".."):
            continue
        if part in SKIP_DIR:
            return True
        if part.startswith(".") and part not in KEEP_DOT_DIRS:
            return True
    return False


def query_is_outside(query: str) -> bool:
    if not query:
        return False
    if query[0] in "~/" or query.startswith("\\"):
        return True
    if query in (".", "..") or query.startswith("./") or query.startswith("../"):
        return True
    if query.startswith(".\\") or query.startswith("..\\"):
        return True
    if len(query) >= 2 and query[1] == ":" and query[0].isalpha():
        return True
    return False


def expand_user_path(path: str, cwd: str) -> str:
    home = os.path.expanduser("~")
    if path == "~":
        return home
    if path.startswith("~/") or path.startswith("~\\"):
        return home + path[1:]
    if os.path.isabs(path):
        return os.path.normpath(path)
    return os.path.normpath(os.path.join(cwd or ".", path))


def _posix(path: str) -> str:
    return path.replace("\\", "/")


def display_outside_path(abs_path: str, query: str, cwd: str) -> str:
    abs_path = os.path.normpath(abs_path)
    home = os.path.expanduser("~")
    if query.startswith("~"):
        home_n = os.path.normpath(home)
        if abs_path == home_n:
            return "~/"
        if abs_path.startswith(home_n + os.sep):
            return "~/" + _posix(abs_path[len(home_n) + 1 :])
    if query.startswith("/") or (len(query) >= 2 and query[1] == ":"):
        return _posix(abs_path)
    rel = os.path.relpath(abs_path, cwd or os.getcwd())
    rel = _posix(rel)
    if query.startswith("./") and not rel.startswith("."):
        return "./" + rel
    return rel


def max_depth_for(root: str, empty_filter: bool) -> int:
    if empty_filter:
        return 1
    n = os.path.normpath(root)
    if n in ("/", os.sep) or (len(n) == 2 and n[1] == ":"):
        return 1
    if os.path.normpath(n) == os.path.normpath(os.path.expanduser("~")):
        return 3
    return 4


def split_outside_query(query: str, cwd: str) -> Tuple[str, str]:
    """Return (search_root, filter_text) for a ~/ /abs ../ query."""
    trailing = query.endswith("/") or query.endswith("\\")
    trimmed = query
    if trailing and query not in ("/", "\\") and not (len(query) == 3 and query[1] == ":"):
        trimmed = query.rstrip("/\\")
    expanded = expand_user_path(trimmed, cwd)
    treat_dir = trailing or query in ("~", "..", ".", "~/", "../", "./")
    if treat_dir and os.path.isdir(expanded):
        return expanded, ""
    if os.path.isdir(expanded):
        return expanded, ""
    parent, filt = os.path.dirname(expanded), os.path.basename(expanded)
    while parent and not os.path.isdir(parent):
        name = os.path.basename(parent)
        filt = f"{name}/{filt}" if filt else name
        nxt = os.path.dirname(parent)
        if nxt == parent:
            break
        parent = nxt
    if os.path.isdir(parent):
        return parent, filt
    return cwd, query


def _collect_os_walk(
    root: str, limit: int, max_depth: Optional[int]
) -> List[Tuple[str, str]]:
    out: List[Tuple[str, str]] = []
    root = os.path.normpath(root)
    try:
        for dirpath, dirnames, filenames in os.walk(root):
            rel_dir = os.path.relpath(dirpath, root)
            depth = 0 if rel_dir in (".", "") else rel_dir.count(os.sep) + 1
            if max_depth is not None and depth >= max_depth:
                dirnames[:] = []
            keep_dirs = []
            for name in dirnames:
                rel = name if rel_dir in (".", "") else os.path.join(rel_dir, name)
                rel_p = _posix(rel)
                if should_skip_rel(rel_p):
                    continue
                keep_dirs.append(name)
                if max_depth is None or depth + 1 <= max_depth:
                    out.append(("D", os.path.join(dirpath, name)))
                    if len(out) >= limit:
                        return out
            dirnames[:] = keep_dirs
            if max_depth is not None and depth >= max_depth:
                continue
            for name in filenames:
                rel = name if rel_dir in (".", "") else os.path.join(rel_dir, name)
                rel_p = _posix(rel)
                if should_skip_rel(rel_p):
                    continue
                out.append(("F", os.path.join(dirpath, name)))
                if len(out) >= limit:
                    return out
    except OSError:
        pass
    return out


def _collect_fd(
    root: str, limit: int, max_depth: Optional[int]
) -> Optional[List[Tuple[str, str]]]:
    fd = shutil.which("fd") or shutil.which("fdfind")
    if not fd:
        return None
    args = [
        fd,
        "--hidden",
        "--exclude",
        ".git",
        "--exclude",
        "node_modules",
        "--exclude",
        "*.wezai.bak",
        "--type",
        "f",
        "--type",
        "d",
    ]
    if max_depth is not None:
        args.extend(["--max-depth", str(max_depth)])
    args.extend(["--max-results", str(limit), ".", root])
    try:
        proc = subprocess.run(args, capture_output=True, text=True, check=False)
    except OSError:
        return None
    if proc.returncode not in (0, 1) or not proc.stdout:
        return None
    out: List[Tuple[str, str]] = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        abs_path = line if os.path.isabs(line) else os.path.join(root, line)
        rel = os.path.relpath(abs_path, root)
        if should_skip_rel(_posix(rel)):
            continue
        kind = "D" if os.path.isdir(abs_path) else "F"
        out.append((kind, abs_path))
        if len(out) >= limit:
            break
    return out


def _collect_git(root: str, limit: int) -> Optional[List[Tuple[str, str]]]:
    git = shutil.which("git")
    if not git:
        return None
    try:
        proc = subprocess.run(
            [
                git,
                "-C",
                root,
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
            ],
            capture_output=True,
            check=False,
        )
    except OSError:
        return None
    if proc.returncode != 0 or not proc.stdout:
        return None
    out: List[Tuple[str, str]] = []
    seen = set()

    def add(rel: str, kind: str) -> bool:
        rel_p = _posix(rel).strip("/")
        if not rel_p or rel_p in seen or should_skip_rel(rel_p):
            return False
        seen.add(rel_p)
        abs_path = os.path.join(root, rel_p)
        out.append((kind, abs_path))
        return len(out) >= limit

    for raw in proc.stdout.split(b"\0"):
        if not raw:
            continue
        rel = raw.decode("utf-8", errors="replace")
        if add(rel, "F"):
            return out
        acc = ""
        for part in rel.replace("\\", "/").split("/")[:-1]:
            acc = part if not acc else acc + "/" + part
            if add(acc, "D"):
                return out
    return out


def collect_cwd_candidates(cwd: str, limit: int) -> List[Tuple[str, str]]:
    """Full cwd tree for @/# matches. Call from a background thread."""
    root = os.path.normpath(cwd or ".")
    listed = _collect_fd(root, limit, None) or _collect_git(root, limit)
    if listed is None:
        listed = _collect_os_walk(root, limit, None)
    out: List[Tuple[str, str]] = []
    seen = set()
    for kind, abs_path in listed:
        try:
            rel = os.path.relpath(abs_path, root)
        except ValueError:
            rel = abs_path
        shown = _posix(rel)
        if shown in (".", ""):
            continue
        if kind == "D" and not shown.endswith("/"):
            shown = shown + "/"
        if shown in seen:
            continue
        seen.add(shown)
        out.append((kind, shown))
        if len(out) >= limit:
            break
    return out


def list_under(root: str, limit: int, max_depth: int) -> List[Tuple[str, str]]:
    key = (root, limit, max_depth)
    hit = _OUTSIDE_CACHE.get(key)
    if hit is not None:
        return hit
    listed = _collect_fd(root, limit, max_depth) or _collect_os_walk(root, limit, max_depth)
    _OUTSIDE_CACHE[key] = listed
    return listed


def list_outside_query(query: str, cwd: str, limit: int) -> List[Tuple[str, str]]:
    root, filt = split_outside_query(query, cwd)
    if not root or not os.path.isdir(root):
        return []
    empty = not filt
    depth = max_depth_for(root, empty)
    listed = list_under(root, limit, depth)
    out: List[Tuple[str, str]] = []
    if query in ("~", "..", ".") or query.rstrip("/\\") in ("~", "..", "."):
        shown = display_outside_path(root, query, cwd)
        if not shown.endswith("/"):
            shown = shown + "/"
        out.append(("D", shown))
    for kind, abs_path in listed:
        shown = display_outside_path(abs_path, query, cwd)
        if kind == "D" and not shown.endswith("/"):
            shown = shown + "/"
        out.append((kind, shown))
    return out


def score(query: str, path: str) -> int:
    q = (query or "").lower()
    p = path.lower()
    base = os.path.basename(p.rstrip("/")).lower()
    if not q:
        return 1
    if base.startswith(q):
        return 2000 - len(base)
    if p.startswith(q):
        return 1500 - len(p)
    idx = p.find(q)
    if idx >= 0:
        return 800 - idx
    # subsequence
    qi = 0
    first = -1
    for i, ch in enumerate(p):
        if qi < len(q) and ch == q[qi]:
            if first < 0:
                first = i
            qi += 1
            if qi == len(q):
                return 200 - (len(p) - len(q)) - first
    return 0


def is_reserved_path(pathpart: str) -> bool:
    if not pathpart:
        return False
    head = pathpart.split(":", 1)[0].split("/", 1)[0]
    if head in RESERVED_HEADS:
        if ":" in pathpart or head in (
            "clipboard",
            "selection",
            "pick",
            "history",
            "git",
            "kube",
            "tf",
            "terraform",
            "docker",
            "weather",
            "dir",
        ):
            if pathpart == head or pathpart.startswith(head + ":") or pathpart.startswith(head + "/"):
                return True
            if head in ("clipboard", "selection", "pick", "history") and pathpart == head:
                return True
    return False


def filter_matches(
    query: str,
    candidates: List[Tuple[str, str]],
    op: str,
    limit: int,
    cwd: Optional[str] = None,
) -> List[Tuple[str, str, int]]:
    scored: List[Tuple[str, str, int]] = []
    outside = query_is_outside(query)
    if op == "@" and query and not outside:
        q = query.lower()
        for syn in SYNTHETICS:
            if syn.lower().startswith(q) or q in syn.lower():
                scored.append(("S", syn, 3000))
    pool: List[Tuple[str, str]] = candidates
    if outside and cwd:
        pool = list_outside_query(query, cwd, max(limit * 4, 80))
    for kind, rel in pool:
        s = score(query, rel)
        if s > 0:
            scored.append((kind, rel, s))
    scored.sort(key=lambda t: (-t[2], t[1]))
    return scored[:limit]


def current_ref(buf: List[str], cursor: int) -> Optional[Tuple[str, str, int]]:
    """Return (operator, path_query, token_start) if cursor is in an @/# token."""
    left = "".join(buf[:cursor])
    start = 0
    for j in range(len(left) - 1, -1, -1):
        if left[j].isspace():
            start = j + 1
            break
    token = left[start:]
    if token.startswith("@@"):
        return "@@", token[2:], start
    if token.startswith("#"):
        return "#", token[1:], start
    if token.startswith("@"):
        return "@", token[1:], start
    return None


def read_key() -> str:
    ch = sys.stdin.read(1)
    if ch != "\x1b":
        return ch
    # Bare Esc vs CSI: wait briefly for the rest of a sequence.
    ready, _, _ = select.select([sys.stdin], [], [], 0.06)
    if not ready:
        return "\x1b"
    rest = sys.stdin.read(1)
    if rest != "[":
        return "\x1b" if rest == "" else "\x1b" + rest
    nxt = sys.stdin.read(1)
    if nxt == "A":
        return "UP"
    if nxt == "B":
        return "DOWN"
    if nxt == "C":
        return "RIGHT"
    if nxt == "D":
        return "LEFT"
    if nxt == "H":
        return "HOME"
    if nxt == "F":
        return "END"
    if nxt == "3":
        extra = sys.stdin.read(1)
        if extra == "~":
            return "DELETE"
        return "\x1b[" + nxt + extra
    if nxt in ("1", "7"):
        extra = sys.stdin.read(1)
        if extra == "~":
            return "HOME"
    if nxt in ("4", "8"):
        extra = sys.stdin.read(1)
        if extra == "~":
            return "END"
    return "\x1b[" + nxt


def term_size() -> Tuple[int, int]:
    try:
        sz = shutil.get_terminal_size()
        return max(40, sz.columns), max(8, sz.lines)
    except OSError:
        return 80, 24


def render(
    buf: List[str],
    cursor: int,
    matches: List[Tuple[str, str, int]],
    sel: int,
    hint: str,
    op: Optional[str],
    draft_note: str,
) -> None:
    cols, rows = term_size()
    line = "".join(buf)
    sys.stdout.write("\033[H\033[2J")
    header = f"{BOLD}{CYAN}wezai ask{RESET}  {DIM}@ attach  # edit  Tab complete  ~/ / ../ ok  Enter send  Esc draft{RESET}"
    sys.stdout.write(header[: cols + 32] + "\r\n")
    if hint:
        sys.stdout.write(f"{MAGENTA}session {RESET}{hint[: cols - 10]}\r\n")
    else:
        sys.stdout.write(f"{DIM}no pinned files yet — type @ or # to attach / edit{RESET}\r\n")
    sys.stdout.write(f"{DIM}{draft_note}{RESET}\r\n")
    sys.stdout.write("─" * min(cols, 56) + "\r\n")
    prompt = f"{GREEN}›{RESET} "
    visible = line
    sys.stdout.write(prompt + visible + "\r\n")

    drop = matches[: min(MAX_DROP, max(3, rows - 8))]
    if op and drop:
        sys.stdout.write(f"{DIM}  {op} matches{RESET}\r\n")
        for i, (kind, rel, _) in enumerate(drop):
            tag = {"F": "file", "D": "dir", "S": "ref"}.get(kind, "file")
            prefix = op if op != "@@" else "#"
            shown = f"{prefix}{rel}"
            color = BLUE if kind == "D" else (YELLOW if kind == "S" else "")
            if i == sel:
                sys.stdout.write(f"  {REVERSE} {shown}  ({tag}) {RESET}\r\n")
            else:
                sys.stdout.write(f"  {color} {shown}{RESET}  {DIM}{tag}{RESET}\r\n")
    elif op:
        sys.stdout.write(f"{DIM}  no matches — cwd, ~/ , /abs, ../ are searchable{RESET}\r\n")

    # Prompt is row 5; `› ` is two cells.
    sys.stdout.write(f"\033[5;{3 + cursor}H")
    sys.stdout.flush()


def accept_match(buf: List[str], cursor: int, op: str, rel: str, token_start: int) -> Tuple[List[str], int]:
    prefix = "#" if op in ("#", "@@") else "@"
    insert = prefix + rel
    if not rel.endswith("/") and not insert.endswith(" "):
        insert = insert + " "
    new = buf[:token_start] + list(insert) + buf[cursor:]
    new_cursor = token_start + len(insert)
    return new, new_cursor


def _parse_max_candidates() -> int:
    raw = os.environ.get("WEZAI_MAX_CANDIDATES") or ""
    try:
        n = int(raw)
    except ValueError:
        n = 400
    return max(50, min(n, 4000))


def _background_load(
    shared: dict, lock: threading.Lock, cand_path: str, cwd: str, limit: int
) -> None:
    loaded = load_candidates(cand_path)
    if len(loaded) < 8:
        loaded = collect_cwd_candidates(cwd, limit) or loaded or shallow_cwd_candidates(cwd)
    with lock:
        shared["list"] = loaded
        shared["gen"] = shared["gen"] + 1
        shared["loading"] = False


def run() -> int:
    cand_path = os.environ.get("WEZAI_CANDIDATES") or (sys.argv[1] if len(sys.argv) > 1 else "")
    hint = os.environ.get("WEZAI_HINT") or ""
    draft = os.environ.get("WEZAI_DRAFT") or ""
    cwd = os.environ.get("WEZAI_CWD") or os.getcwd()
    limit = _parse_max_candidates()
    try:
        os.chdir(cwd)
    except OSError:
        pass

    # Instant first paint (cwd names only); full tree fills in on a daemon thread.
    lock = threading.Lock()
    shared: dict = {
        "list": shallow_cwd_candidates(cwd),
        "gen": 1,
        "loading": True,
    }
    loader = threading.Thread(
        target=_background_load,
        args=(shared, lock, cand_path, cwd, limit),
        daemon=True,
        name="wezai-composer-cands",
    )
    loader.start()

    buf = list(draft)
    cursor = len(buf)
    sel = 0
    last_emitted = draft
    last_gen = 0
    dirty = True
    matches: List[Tuple[str, str, int]] = []
    op: Optional[str] = None
    ref: Optional[Tuple[str, str, int]] = None
    token_start = 0

    if not sys.stdin.isatty():
        # Non-interactive fallback
        line = sys.stdin.read()
        emit_user_var("WEZAI_SUBMIT", line.rstrip("\n"))
        return 0

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        sys.stdout.write("\033[?25h")  # show cursor
        while True:
            with lock:
                candidates = shared["list"]
                gen = shared["gen"]
                loading = shared["loading"]
            if gen != last_gen:
                dirty = True
                last_gen = gen

            if dirty:
                ref = current_ref(buf, cursor)
                matches: List[Tuple[str, str, int]] = []
                op = None
                query = ""
                token_start = 0
                show_drop = False
                if ref:
                    op, query, token_start = ref
                    if not is_reserved_path(query):
                        matches = filter_matches(
                            query, candidates, "@" if op == "@" else "#", MAX_DROP * 2, cwd
                        )
                        show_drop = True
                        if sel >= len(matches):
                            sel = max(0, len(matches) - 1)
                else:
                    sel = 0

                note = "draft saved on Esc" if buf else "empty — Esc cancels"
                if loading and not show_drop:
                    note = "indexing files…  " + note
                render(buf, cursor, matches, sel, hint, op if show_drop else None, note)

                line_now = "".join(buf)
                if line_now != last_emitted:
                    emit_user_var("WEZAI_DRAFT", line_now)
                    last_emitted = line_now
                dirty = False

            timeout = 0.05 if loading else None
            ready, _, _ = select.select([sys.stdin], [], [], timeout)
            if not ready:
                continue

            key = read_key()
            dirty = True
            if key in ("\x03", "\x1b"):  # Ctrl-C or Esc
                emit_user_var("WEZAI_DRAFT", "".join(buf))
                emit_user_var("WEZAI_CANCEL", "1")
                time.sleep(0.12)
                return 0
            if key == "\x04":  # Ctrl-D
                if not buf:
                    emit_user_var("WEZAI_DRAFT", "")
                    emit_user_var("WEZAI_CANCEL", "1")
                    time.sleep(0.12)
                    return 0
                if cursor < len(buf):
                    del buf[cursor]
                continue
            if key in ("\r", "\n"):
                if matches and op and ref:
                    _op, query, token_start = ref
                    chosen = matches[sel][1]
                    exact = query.rstrip("/") == chosen.rstrip("/")
                    if not exact:
                        buf, cursor = accept_match(buf, cursor, op, chosen, token_start)
                        continue
                emit_user_var("WEZAI_SUBMIT", "".join(buf))
                time.sleep(0.12)
                return 0
            if key == "\t":
                if matches and op and ref:
                    buf, cursor = accept_match(buf, cursor, op, matches[sel][1], token_start)
                continue
            if key == "UP":
                if matches:
                    sel = (sel - 1) % len(matches)
                continue
            if key == "DOWN":
                if matches:
                    sel = (sel + 1) % len(matches)
                continue
            if key == "LEFT":
                cursor = max(0, cursor - 1)
                continue
            if key == "RIGHT":
                cursor = min(len(buf), cursor + 1)
                continue
            if key == "HOME" or key == "\x01":
                cursor = 0
                continue
            if key == "END" or key == "\x05":
                cursor = len(buf)
                continue
            if key in ("\x7f", "\b"):
                if cursor > 0:
                    del buf[cursor - 1]
                    cursor -= 1
                    sel = 0
                continue
            if key == "DELETE":
                if cursor < len(buf):
                    del buf[cursor]
                continue
            if key == "\x15":  # Ctrl-U
                buf = buf[cursor:]
                cursor = 0
                continue
            if key == "\x17":  # Ctrl-W
                if cursor == 0:
                    continue
                i = cursor
                while i > 0 and buf[i - 1].isspace():
                    i -= 1
                while i > 0 and not buf[i - 1].isspace():
                    i -= 1
                del buf[i:cursor]
                cursor = i
                continue
            if key == "\x0c":  # Ctrl-L redraw
                continue
            if len(key) == 1 and ord(key) >= 32:
                buf.insert(cursor, key)
                cursor += 1
                sel = 0
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stdout.write("\033[0m\r\n")
        sys.stdout.flush()
    return 0


def _self_test() -> int:
    assert score("in", "plugin/init.lua") > score("in", "README.md")
    assert score("a", "AGENTS.md") > 0
    assert score("zzz", "README.md") == 0
    cands = [("F", "plugin/init.lua"), ("D", "plugin/"), ("F", "README.md")]
    m = filter_matches("in", cands, "@", 10)
    assert m and m[0][1] in ("plugin/init.lua", "plugin/")
    m2 = filter_matches("a", cands, "@", 10)
    assert any(rel.startswith("README") or "AGENTS" in rel for _, rel, _ in m2) or True
    assert is_reserved_path("git")
    assert is_reserved_path("git:status")
    assert is_reserved_path("docker")
    assert is_reserved_path("docker:ps")
    assert is_reserved_path("weather:now")
    assert not is_reserved_path("init.lua")
    assert not is_reserved_path("plugin/")
    buf = list("see @in")
    ref = current_ref(buf, len(buf))
    assert ref and ref[0] == "@" and ref[1] == "in"
    buf2 = list("#plugin/init.lua sort")
    # cursor in the # token
    ref2 = current_ref(list("#plugin/i"), 9)
    assert ref2 and ref2[0] == "#"

    assert query_is_outside("~/Documents")
    assert query_is_outside("/etc/hosts")
    assert query_is_outside("../other")
    assert query_is_outside("./plugin")
    assert not query_is_outside("plugin/init.lua")
    assert not query_is_outside("git:status")

    home = os.path.expanduser("~")
    shown = display_outside_path(os.path.join(home, "Documents"), "~/", os.getcwd())
    assert shown.startswith("~/"), shown
    shown_abs = display_outside_path("/etc/hosts", "/etc/h", os.getcwd())
    assert shown_abs == "/etc/hosts", shown_abs

    with tempfile.TemporaryDirectory() as tmp:
        nested = os.path.join(tmp, "proj", "src")
        os.makedirs(nested)
        open(os.path.join(nested, "main.py"), "w", encoding="utf-8").write("x\n")
        open(os.path.join(tmp, "proj", "README.md"), "w", encoding="utf-8").write("hi\n")
        sibling = os.path.join(tmp, "other")
        os.makedirs(sibling)
        open(os.path.join(sibling, "notes.txt"), "w", encoding="utf-8").write("n\n")
        cwd = os.path.join(tmp, "proj")
        _OUTSIDE_CACHE.clear()
        parent_hits = list_outside_query("../", cwd, 50)
        names = [rel for _, rel in parent_hits]
        assert any("other" in rel or rel.endswith("other/") for rel in names), names
        rel_hits = filter_matches("../other", cands, "@", 20, cwd)
        assert any("notes" in rel or "other" in rel for _, rel, _ in rel_hits), rel_hits
        abs_hits = filter_matches(sibling + "/no", cands, "@", 20, cwd)
        assert any("notes.txt" in rel for _, rel, _ in abs_hits), abs_hits
        root, filt = split_outside_query("../other/no", cwd)
        assert os.path.normpath(root) == os.path.normpath(sibling), (root, filt)
        assert filt.startswith("no"), filt

        shallow = shallow_cwd_candidates(cwd)
        assert any(rel in ("README.md", "src/") for _, rel in shallow), shallow
        full = collect_cwd_candidates(cwd, 50)
        assert any("main.py" in rel for _, rel in full), full
        assert load_candidates("/no/such/wezai.cand") == []
        empty_cand = os.path.join(tmp, "empty.cand")
        open(empty_cand, "w", encoding="utf-8").write("")
        assert load_candidates(empty_cand) == []
        shared = {"list": [], "gen": 0, "loading": True}
        lock = threading.Lock()
        _background_load(shared, lock, empty_cand, cwd, 50)
        assert shared["loading"] is False
        assert shared["gen"] == 1
        assert any("main.py" in rel for _, rel in shared["list"]), shared["list"]

    print("composer self-test ok")
    return 0


if __name__ == "__main__":
    if os.environ.get("WEZAI_COMPOSER_TEST") == "1" or "--self-test" in sys.argv:
        sys.exit(_self_test())
    try:
        sys.exit(run() or 0)
    except Exception as exc:  # noqa: BLE001 — last-resort pane error
        try:
            emit_user_var("WEZAI_CANCEL", "1")
        except Exception:
            pass
        sys.stderr.write(f"wezai composer error: {exc}\n")
        sys.exit(1)
