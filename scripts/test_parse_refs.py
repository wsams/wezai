#!/usr/bin/env python3
"""Regression checks for @ / # token parsing (mirrors plugin/context.lua)."""

from __future__ import annotations

import re
import sys

TRAIL_PUNCT = re.compile(r"[?!.,;:\]\})'\"…]+$")

RESERVED = (
    "clipboard",
    "selection",
    "pick",
    "history",
)


def is_reserved(raw: str) -> bool:
    if raw in RESERVED:
        return True
    for p in ("history:", "git:", "kube:", "tf:", "terraform:", "dir:"):
        if raw.startswith(p) or raw == p[:-1]:
            return True
    return False


def sanitize(path: str, quoted: bool) -> str:
    if not path or quoted or is_reserved(path):
        return path
    cleaned = TRAIL_PUNCT.sub("", path)
    return cleaned or path


def parse_at_refs(line: str) -> dict:
    paths: list[str] = []
    edit_paths: list[str] = []
    synthetics: list[str] = []
    if not line:
        return {"paths": paths, "edit_paths": edit_paths, "synthetics": synthetics, "rest": line or ""}

    def at_token_start(idx: int) -> bool:
        return idx == 0 or line[idx - 1].isspace()

    def read_path(start: int):
        if start < len(line) and line[start] in ("'", '"'):
            q = line[start]
            close = line.find(q, start + 1)
            if close >= 0:
                return line[start + 1 : close], close + 1, True
            return line[start + 1 :], len(line), True
        j = start
        while j < len(line) and not line[j].isspace():
            j += 1
        return sanitize(line[start:j], False), j, False

    def classify(raw: str):
        if raw in ("clipboard", "selection", "pick"):
            return "synthetic", raw
        if raw == "history" or raw.startswith("history:"):
            return "synthetic", raw
        if raw.startswith("git:"):
            return "synthetic", raw
        if raw.startswith("kube:"):
            return "synthetic", raw
        if raw.startswith("tf:") or raw.startswith("terraform:"):
            if raw.startswith("terraform:"):
                return "synthetic", "tf:" + raw[len("terraform:") :]
            return "synthetic", raw
        if raw.startswith("dir:"):
            return "synthetic", raw
        return "path", raw

    rest_parts: list[str] = []
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if ch == "#" and at_token_start(i):
            nxt = line[i + 1] if i + 1 < n else ""
            if nxt == "" or nxt.isspace():
                rest_parts.append("#")
                i += 1
            elif nxt.strip():
                path, i, _ = read_path(i + 1)
                path = re.sub(r"^[#@]+", "", path)
                if path:
                    edit_paths.append(path)
            else:
                rest_parts.append("#")
                i += 1
        elif ch == "@" and at_token_start(i):
            nxt = line[i + 1] if i + 1 < n else ""
            if nxt == "@":
                path, i, _ = read_path(i + 2)
                path = re.sub(r"^[@#]+", "", path)
                if path:
                    edit_paths.append(path)
            else:
                path, i, _ = read_path(i + 1)
                if path:
                    kind, value = classify(path)
                    if kind == "synthetic":
                        synthetics.append(value)
                    else:
                        paths.append(value)
        else:
            start = i
            while i < n:
                c = line[i]
                if (c == "@" or c == "#") and at_token_start(i):
                    break
                i += 1
            rest_parts.append(line[start:i])

    rest = re.sub(r"\s+", " ", "".join(rest_parts)).strip()
    return {"paths": paths, "edit_paths": edit_paths, "synthetics": synthetics, "rest": rest}


def main() -> int:
    cases = [
        ("@README.md is this safe?", ["README.md"], [], [], "is this safe?"),
        ("@package.json?", ["package.json"], [], [], ""),
        ("#notes.txt sort the lines", [], ["notes.txt"], [], "sort the lines"),
        ("@@notes.txt sort the lines", [], ["notes.txt"], [], "sort the lines"),
        ("@plugin/ how is loading wired?", ["plugin/"], [], [], "how is loading wired?"),
        ("@a.lua #b.lua add tests", ["a.lua"], ["b.lua"], [], "add tests"),
        ("# heading with space", [], [], [], "# heading with space"),
        ("@git:status what should I commit?", [], [], ["git:status"], "what should I commit?"),
        ('@"path with spaces" explain', ["path with spaces"], [], [], "explain"),
        ("plain question", [], [], [], "plain question"),
    ]
    failed = 0
    for line, paths, edits, syns, rest in cases:
        got = parse_at_refs(line)
        ok = (
            got["paths"] == paths
            and got["edit_paths"] == edits
            and got["synthetics"] == syns
            and got["rest"] == rest
        )
        if not ok:
            failed += 1
            print("FAIL", repr(line))
            print("  got ", got)
            print("  want", {"paths": paths, "edit_paths": edits, "synthetics": syns, "rest": rest})
    if failed:
        print(f"{failed} parse cases failed")
        return 1
    print("parse_at_refs cases ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
