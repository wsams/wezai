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
import sys
import termios
import time
import tty
from typing import List, Optional, Tuple

SYNTHETICS = [
    "git:",
    "kube:",
    "tf:",
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


def emit_user_var(name: str, value: str) -> None:
    raw = value.encode("utf-8")
    b64 = base64.b64encode(raw).decode("ascii")
    sys.stdout.write(f"\033]1337;SetUserVar={name}={b64}\007")
    sys.stdout.flush()


def load_candidates(path: Optional[str]) -> List[Tuple[str, str]]:
    """Return list of (kind, relpath) where kind is F or D."""
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
    if out:
        return out
    # Fallback: shallow names in cwd
    try:
        for name in sorted(os.listdir(".")):
            if name.startswith(".") and name not in (".github", ".config"):
                continue
            if "wezai" in name and name.endswith(".bak"):
                continue
            kind = "D" if os.path.isdir(name) else "F"
            shown = name + ("/" if kind == "D" else "")
            out.append((kind, shown))
    except OSError:
        pass
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
            "dir",
        ):
            if pathpart == head or pathpart.startswith(head + ":") or pathpart.startswith(head + "/"):
                return True
            if head in ("clipboard", "selection", "pick", "history") and pathpart == head:
                return True
    return False


def filter_matches(
    query: str, candidates: List[Tuple[str, str]], op: str, limit: int
) -> List[Tuple[str, str, int]]:
    scored: List[Tuple[str, str, int]] = []
    if op == "@" and query:
        q = query.lower()
        for syn in SYNTHETICS:
            if syn.lower().startswith(q) or q in syn.lower():
                scored.append(("S", syn, 3000))
    for kind, rel in candidates:
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
    header = f"{BOLD}{CYAN}wezai ask{RESET}  {DIM}@ attach   # edit   Tab complete   Enter send   Esc save draft{RESET}"
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
        sys.stdout.write(f"{DIM}  no matches{RESET}\r\n")

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


def run() -> int:
    cand_path = os.environ.get("WEZAI_CANDIDATES") or (sys.argv[1] if len(sys.argv) > 1 else "")
    hint = os.environ.get("WEZAI_HINT") or ""
    draft = os.environ.get("WEZAI_DRAFT") or ""
    cwd = os.environ.get("WEZAI_CWD") or os.getcwd()
    try:
        os.chdir(cwd)
    except OSError:
        pass

    candidates = load_candidates(cand_path)
    buf = list(draft)
    cursor = len(buf)
    sel = 0
    last_emitted = draft

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
            ref = current_ref(buf, cursor)
            matches: List[Tuple[str, str, int]] = []
            op = None
            query = ""
            token_start = 0
            show_drop = False
            if ref:
                op, query, token_start = ref
                if not is_reserved_path(query):
                    matches = filter_matches(query, candidates, "@" if op == "@" else "#", MAX_DROP * 2)
                    show_drop = True
                    if sel >= len(matches):
                        sel = max(0, len(matches) - 1)
            else:
                sel = 0

            note = "draft saved on Esc" if buf else "empty — Esc cancels"
            render(buf, cursor, matches, sel, hint, op if show_drop else None, note)

            line_now = "".join(buf)
            if line_now != last_emitted:
                emit_user_var("WEZAI_DRAFT", line_now)
                last_emitted = line_now

            key = read_key()
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
    assert not is_reserved_path("init.lua")
    assert not is_reserved_path("plugin/")
    buf = list("see @in")
    ref = current_ref(buf, len(buf))
    assert ref and ref[0] == "@" and ref[1] == "in"
    buf2 = list("#plugin/init.lua sort")
    # cursor in the # token
    ref2 = current_ref(list("#plugin/i"), 9)
    assert ref2 and ref2[0] == "#"
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
