#!/usr/bin/env python3
"""Rewrite `[x; n]` fill literals as `[n of x]`.

Usage: fill.py FILE...   (.rig: whole file; .md: ```rig blocks only)
"""
import re, sys

def match_close(s, i):
    """s[i] == '['; return index of the matching ']' or -1 (same line only)."""
    depth = 0
    j = i
    while j < len(s):
        c = s[j]
        if c == '\n':
            return -1
        if c in '"\'':
            k = s.find(c, j + 1)
            if k < 0:
                return -1
            j = k + 1
            continue
        if c in '[(':
            depth += 1
        elif c in '])':
            depth -= 1
            if depth == 0:
                return j if c == ']' else -1
        j += 1
    return -1

def top_semicolon(inner):
    depth = 0
    j = 0
    while j < len(inner):
        c = inner[j]
        if c in '"\'':
            k = inner.find(c, j + 1)
            j = (k + 1) if k >= 0 else len(inner)
            continue
        if c in '[(':
            depth += 1
        elif c in '])':
            depth -= 1
        elif c == ';' and depth == 0:
            return j
        j += 1
    return -1

def transform(s):
    out = []
    i = 0
    n = 0
    while i < len(s):
        if s[i] == '[':
            e = match_close(s, i)
            if e > 0:
                inner, k = transform(s[i + 1:e])
                n += k
                p = top_semicolon(inner)
                if p >= 0:
                    val = inner[:p].strip()
                    size = inner[p + 1:].strip()
                    out.append('[' + size + ' of ' + val + ']')
                    n += 1
                else:
                    out.append('[' + inner + ']')
                i = e + 1
                continue
        out.append(s[i])
        i += 1
    return ''.join(out), n

def md(text):
    total = 0
    parts = re.split(r'(^```rig[^\n]*\n.*?^```)', text, flags=re.M | re.S)
    for idx in range(1, len(parts), 2):
        parts[idx], k = transform(parts[idx])
        total += k
    return ''.join(parts), total

grand = 0
for path in sys.argv[1:]:
    text = open(path).read()
    new, k = md(text) if path.endswith('.md') else transform(text)
    if k:
        open(path, 'w').write(new)
        print(f'{k:4d} {path}')
        grand += k
print(f'{grand:4d} total')
