#!/usr/bin/env python3
"""Tests for plugin/history_edit.py. Run: python3 scripts/test_history_edit.py"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "plugin" / "history_edit.py"

failed = 0
passed = 0


def expect(cond: bool, msg: str) -> None:
    global failed, passed
    if cond:
        passed += 1
        return
    failed += 1
    sys.stderr.write("FAIL: %s\n" % msg)


def eq(a, b, msg: str) -> None:
    expect(a == b, "%s got %r expected %r" % (msg, a, b))


def run_edit(kind: str, hist: Path, cmd: str) -> tuple[int, str, str]:
    cmdfile = hist.parent / "cmd.txt"
    cmdfile.write_bytes(cmd.encode("utf-8"))
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), kind, str(hist), str(cmdfile)],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode, proc.stdout, proc.stderr


def test_bash() -> None:
    text = "\n".join(
        [
            "#1000",
            "echo old",
            "#2000",
            "ls",
            "#3000",
            "echo old",
            "#4000",
            "git status",
            "",
        ]
    )
    with tempfile.TemporaryDirectory() as td:
        hist = Path(td) / "bash_history"
        hist.write_text(text)
        rc, out, err = run_edit("bash", hist, "echo old")
        eq(rc, 0, "bash exit")
        eq(out.strip(), "2", "bash removed count")
        body = hist.read_text()
        expect("echo old" not in body, "bash removed cmd")
        expect("git status" in body, "bash kept git")
        expect("#4000" in body, "bash kept ts")
        expect("#1000" not in body, "bash dropped deleted ts")


def test_zsh() -> None:
    text = "\n".join(
        [
            ": 1000:0;echo old",
            ": 2000:0;ls",
            ": 3000:0;echo old",
            ": 4000:0;git status",
            "",
        ]
    )
    with tempfile.TemporaryDirectory() as td:
        hist = Path(td) / "zsh_history"
        hist.write_text(text)
        rc, out, _ = run_edit("zsh", hist, "echo old")
        eq(rc, 0, "zsh exit")
        eq(out.strip(), "2", "zsh removed count")
        body = hist.read_text()
        expect("echo old" not in body, "zsh removed")
        expect("git status" in body, "zsh kept")


def test_fish() -> None:
    text = """- cmd: echo old
  when: 1000
- cmd: git status
  when: 2000
  paths:
    - /tmp
- cmd: echo old
  when: 3000
- cmd: docker compose up
  when: 4000
"""
    with tempfile.TemporaryDirectory() as td:
        hist = Path(td) / "fish_history"
        hist.write_text(text)
        rc, out, _ = run_edit("fish", hist, "echo old")
        eq(rc, 0, "fish exit")
        eq(out.strip(), "2", "fish removed count")
        body = hist.read_text()
        expect("echo old" not in body, "fish removed")
        expect("docker compose up" in body, "fish kept docker")
        expect("git status" in body, "fish kept git")


def test_missing() -> None:
    with tempfile.TemporaryDirectory() as td:
        hist = Path(td) / "bash_history"
        hist.write_text("ls\ngit status\n")
        rc, out, _ = run_edit("bash", hist, "nope")
        eq(rc, 0, "missing still exit 0")
        eq(out.strip(), "0", "missing count 0")
        eq(hist.read_text(), "ls\ngit status\n", "file unchanged")


if __name__ == "__main__":
    test_bash()
    test_zsh()
    test_fish()
    test_missing()
    print("test_history_edit: %d passed, %d failed" % (passed, failed))
    sys.exit(1 if failed else 0)
