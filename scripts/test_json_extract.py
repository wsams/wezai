#!/usr/bin/env python3
"""Regression checks for util.extract_json_object (mirrors plugin/util.lua)."""

from __future__ import annotations

import json
import sys


def extract_json_object(s: str | None) -> str | None:
    if not isinstance(s, str):
        return None
    start = s.find("{")
    if start < 0:
        return None
    depth = 0
    in_str = False
    escape = False
    for i in range(start, len(s)):
        c = s[i]
        if in_str:
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return s[start : i + 1]
    return None


def main() -> int:
    failed = 0

    def expect(cond: bool, msg: str) -> None:
        nonlocal failed
        if not cond:
            failed += 1
            print("FAIL:", msg)

    raw = 'Sure.\n{"message":"hi","command":null}\nThanks'
    blob = extract_json_object(raw)
    expect(blob is not None, "prose wrapper extracted")
    obj = json.loads(blob or "")
    expect(obj.get("message") == "hi", "message from wrapper")
    expect(obj.get("command") is None, "null command")

    gemini_edit = '{"message":"sorted","file":"a\\nb\\n","command":""}'
    gblob = extract_json_object(gemini_edit)
    expect(gblob == gemini_edit, "raw object is identity")
    gobj = json.loads(gblob or "")
    expect("file" in gobj and "sorted" in gobj["message"], "gemini-shape file field")

    nested = 'prefix {"message":"ok","files":[{"path":"/tmp/a","content":"x"}]} suffix'
    nblob = extract_json_object(nested)
    expect(nblob is not None, "nested files array extracted")
    nobj = json.loads(nblob or "")
    expect(nobj["files"][0]["path"] == "/tmp/a", "files[].path")

    braced_string = '{"message":"use {braces} in text","command":null}'
    sblob = extract_json_object("note " + braced_string)
    expect(sblob == braced_string, "braces inside strings ignored")

    expect(extract_json_object("no object here") is None, "missing object")
    expect(extract_json_object("{unterminated") is None, "unterminated")

    if failed:
        print(f"{failed} json extract cases failed")
        return 1
    print("extract_json_object cases ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
