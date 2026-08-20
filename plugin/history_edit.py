#!/usr/bin/env python3
"""Rewrite bash/zsh/fish history files, removing an exact command (all copies).

Invoked from the user's live shell so bash/zsh can `history -a` / `fc -W`
before the rewrite and reload after — one synchronous chain, no race with
in-memory history.

Usage:
  history_edit.py bash|zsh|fish HISTFILE CMDFILE

CMDFILE contains the exact command bytes to delete (no extra terminator).
Prints the number of removed copies to stdout. Exit 0 even when 0 removed
(so the shell chain can still reload); exit 2 on I/O errors.
"""

from __future__ import annotations

import sys
from pathlib import Path


def split_lines(text: str) -> list[str]:
    if not text:
        return []
    # Keep the same semantics as Lua split_lines: drop a single trailing
    # empty from a terminating newline, keep interior blank lines.
    parts = text.split("\n")
    if parts and parts[-1] == "":
        parts.pop()
    return parts


def join_lines(lines: list[str], had_nl: bool) -> str:
    body = "\n".join(lines)
    if had_nl and (body == "" or not body.endswith("\n")):
        body += "\n"
    return body


def unescape_fish_cmd(cmd: str) -> str:
    cmd = cmd.replace("\\n", "\n").replace("\\\\", "\\")
    return cmd.strip()


def strip_bash_exact(text: str, cmd: str) -> tuple[str, int]:
    had_nl = text.endswith("\n")
    out: list[str] = []
    removed = 0
    pending_ts: str | None = None
    for line in split_lines(text):
        if len(line) > 1 and line[0] == "#" and line[1:].isdigit():
            if pending_ts is not None:
                out.append(pending_ts)
            pending_ts = line
            continue
        if line.strip() == cmd:
            removed += 1
            pending_ts = None
            continue
        if pending_ts is not None:
            out.append(pending_ts)
            pending_ts = None
        out.append(line)
    if pending_ts is not None:
        out.append(pending_ts)
    return join_lines(out, had_nl), removed


def zsh_cmd_from_line(line: str) -> str:
    # : 1712345678:0;the command
    if line.startswith(": "):
        semi = line.find(";")
        if semi != -1:
            # require ts:dur before the semicolon
            head = line[2:semi]
            if ":" in head and head.split(":", 1)[0].isdigit():
                return line[semi + 1 :]
    return line


def strip_zsh_exact(text: str, cmd: str) -> tuple[str, int]:
    had_nl = text.endswith("\n")
    out: list[str] = []
    removed = 0
    for line in split_lines(text):
        if zsh_cmd_from_line(line).strip() == cmd:
            removed += 1
        else:
            out.append(line)
    return join_lines(out, had_nl), removed


def strip_fish_exact(text: str, cmd: str) -> tuple[str, int]:
    had_nl = text.endswith("\n")
    lines = split_lines(text)
    out: list[str] = []
    removed = 0
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if not line.startswith("- cmd:"):
            out.append(line)
            i += 1
            continue
        raw = line[6:].lstrip()
        block = [line]
        assembled = raw
        j = i
        while assembled.endswith("\\") and j + 1 < n:
            j += 1
            assembled = assembled[:-1] + lines[j]
            block.append(lines[j])
        j += 1
        while j < n and not lines[j].startswith("- cmd:"):
            if lines[j] and not lines[j][0].isspace() and not lines[j].startswith("-"):
                break
            block.append(lines[j])
            j += 1
        if unescape_fish_cmd(assembled) == cmd:
            removed += 1
        else:
            out.extend(block)
        i = j
    return join_lines(out, had_nl), removed


def strip_exact(kind: str, text: str, cmd: str) -> tuple[str, int]:
    if kind == "zsh":
        return strip_zsh_exact(text, cmd)
    if kind == "fish":
        return strip_fish_exact(text, cmd)
    return strip_bash_exact(text, cmd)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        sys.stderr.write("usage: history_edit.py bash|zsh|fish HISTFILE CMDFILE\n")
        return 2
    kind, histfile, cmdfile = argv[1], argv[2], argv[3]
    if kind not in ("bash", "zsh", "fish"):
        sys.stderr.write("unknown kind: %s\n" % kind)
        return 2
    try:
        cmd = Path(cmdfile).read_bytes().decode("utf-8", "surrogateescape")
        raw = Path(histfile).read_bytes()
    except OSError as exc:
        sys.stderr.write(str(exc) + "\n")
        return 2
    text = raw.decode("utf-8", "surrogateescape")
    new_text, removed = strip_exact(kind, text, cmd)
    if new_text != text:
        tmp = Path(histfile + ".wezai.tmp")
        try:
            tmp.write_bytes(new_text.encode("utf-8", "surrogateescape"))
            tmp.replace(Path(histfile))
        except OSError as exc:
            try:
                tmp.unlink()
            except OSError:
                pass
            sys.stderr.write(str(exc) + "\n")
            return 2
    sys.stdout.write(str(removed) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
