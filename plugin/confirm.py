#!/usr/bin/env python3
"""wezai Apply/Cancel prompt.

Splits the *shell* pane so the right-hand AI output pane stays visible
(diffs print there). Talks to the plugin via OSC 1337 SetUserVar (WEZAI_CONFIRM).
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
from typing import Tuple

ESC = "\033["
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
REVERSE = "\033[7m"


def emit_user_var(name: str, value: str) -> None:
    raw = value.encode("utf-8")
    b64 = base64.b64encode(raw).decode("ascii")
    sys.stdout.write(f"\033]1337;SetUserVar={name}={b64}\007")
    sys.stdout.flush()


def read_key() -> str:
    ch = sys.stdin.read(1)
    if ch != "\x1b":
        return ch
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
    return "\x1b[" + nxt


def term_size() -> Tuple[int, int]:
    try:
        sz = shutil.get_terminal_size()
        return max(40, sz.columns), max(6, sz.lines)
    except OSError:
        return 80, 16


def render(title: str, hint: str, apply_label: str, cancel_label: str, sel: int) -> None:
    cols, _rows = term_size()
    sys.stdout.write("\033[H\033[2J")
    header = f"{BOLD}{CYAN}wezai confirm{RESET}  {DIM}a=Apply  c=Cancel  Esc=cancel  (diff is in the right pane){RESET}"
    sys.stdout.write(header[: cols + 40] + "\r\n")
    sys.stdout.write(f"{BOLD}{title[: cols]}{RESET}\r\n")
    if hint:
        sys.stdout.write(f"{DIM}{hint[: cols]}{RESET}\r\n")
    sys.stdout.write("─" * min(cols, 56) + "\r\n")
    rows = ((apply_label, "apply"), (cancel_label, "cancel"))
    for i, (label, _id) in enumerate(rows):
        if i == sel:
            sys.stdout.write(f"  {REVERSE} {label} {RESET}\r\n")
        else:
            color = GREEN if i == 0 else YELLOW
            sys.stdout.write(f"  {color} {label}{RESET}\r\n")
    sys.stdout.flush()


def run() -> int:
    title = os.environ.get("WEZAI_CONFIRM_TITLE") or "Apply changes?"
    hint = os.environ.get("WEZAI_CONFIRM_HINT") or "Review the wezai pane on the right, then Apply or Cancel."
    apply_label = os.environ.get("WEZAI_CONFIRM_APPLY") or "Apply — write file"
    cancel_label = os.environ.get("WEZAI_CONFIRM_CANCEL") or "Cancel — discard changes"
    decided = False
    sel = 0

    if not sys.stdin.isatty():
        emit_user_var("WEZAI_CONFIRM", "cancel")
        return 0

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        sys.stdout.write("\033[?25l")
        while True:
            render(title, hint, apply_label, cancel_label, sel)
            key = read_key()
            if key in ("\x03", "\x1b", "q", "Q"):
                emit_user_var("WEZAI_CONFIRM", "cancel")
                decided = True
                time.sleep(0.12)
                return 0
            if key in ("a", "A", "y", "Y"):
                emit_user_var("WEZAI_CONFIRM", "apply")
                decided = True
                time.sleep(0.12)
                return 0
            if key in ("c", "C", "n", "N"):
                emit_user_var("WEZAI_CONFIRM", "cancel")
                decided = True
                time.sleep(0.12)
                return 0
            if key in ("\r", "\n"):
                emit_user_var("WEZAI_CONFIRM", "apply" if sel == 0 else "cancel")
                decided = True
                time.sleep(0.12)
                return 0
            if key in ("UP", "LEFT"):
                sel = 0
                continue
            if key in ("DOWN", "RIGHT"):
                sel = 1
                continue
            if key == "\t":
                sel = 1 - sel
                continue
    finally:
        if not decided:
            try:
                emit_user_var("WEZAI_CONFIRM", "cancel")
                time.sleep(0.08)
            except Exception:
                pass
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stdout.write("\033[0m\033[?25h\r\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run() or 0)
    except Exception as exc:  # noqa: BLE001
        try:
            emit_user_var("WEZAI_CONFIRM", "cancel")
        except Exception:
            pass
        sys.stderr.write(f"wezai confirm error: {exc}\n")
        sys.exit(1)
