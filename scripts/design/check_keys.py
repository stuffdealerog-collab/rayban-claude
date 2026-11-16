#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Сверяет надписи L("…") в коде с keys.json: каждая должна быть в каталоге, лишних в каталоге быть не должно.

    python3 scripts/design/check_keys.py
"""
import json
import os
import re
import sys

HERE = os.path.dirname(__file__)
ROOT = os.path.join(HERE, "..", "..", "RayBanClaude")
LITERAL = re.compile(r'\bL\("((?:[^"\\]|\\.)*)"')
ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}


def unescape(text):
    text = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), text)
    return re.sub(r"\\(.)", lambda m: ESCAPES.get(m.group(1), m.group(0)), text)


used = {}
for directory, _, files in os.walk(ROOT):
    for name in files:
        if not name.endswith(".swift"):
            continue
        source = open(os.path.join(directory, name), encoding="utf-8").read()
        for match in LITERAL.finditer(source):
            used.setdefault(unescape(match.group(1)), name)

keys = set(json.load(open(os.path.join(HERE, "keys.json"), encoding="utf-8")))
missing = sorted(key for key in used if key not in keys)
unused = sorted(keys - set(used))
for key in missing:
    print(f"нет в keys.json ({used[key]}): {key!r}")
for key in unused:
    print(f"не используется в коде: {key!r}")
print(f"надписей в коде: {len(used)}, в каталоге: {len(keys)}")
sys.exit(1 if missing else 0)
