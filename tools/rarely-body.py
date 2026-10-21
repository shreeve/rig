#!/usr/bin/env python3
"""Move `rarely` from a function's header to the first line of its body.

    rarely fun f(x: Int) -> Int        fun f(x: Int) -> Int
      x + 1                    ==>       rarely
                                         x + 1

Usage: tools/rarely-body.py FILE...   (rewrites each file in place; also works
on Markdown and .rig.test files, whose code is indented Rig)
"""
import re, sys

HEAD = re.compile(r'^(\s*)((?:pub\s+)?)rarely\s+((?:fun|sub)\b.*)$')

def depth(line):
    d = 0; q = None; i = 0
    while i < len(line):
        c = line[i]
        if q:
            if c == '\\' and q == '"': i += 1
            elif c == q: q = None
        elif c in '"\'': q = c
        elif c == '#': break
        elif c in '([': d += 1
        elif c in ')]': d -= 1
        i += 1
    return d

def convert(text):
    lines = text.split('\n')
    out = []; i = 0; n = 0
    while i < len(lines):
        m = HEAD.match(lines[i])
        if not m:
            out.append(lines[i]); i += 1; continue
        indent, pub, rest = m.groups()
        out.append(indent + pub + rest)
        d = depth(rest); i += 1
        while d > 0 and i < len(lines):
            out.append(lines[i]); d += depth(lines[i]); i += 1
        j = i
        while j < len(lines) and not lines[j].strip(): j += 1
        body = re.match(r'\s*', lines[j]).group(0) if j < len(lines) else indent + '  '
        if len(body) <= len(indent): body = indent + '  '
        out.append(body + 'rarely'); n += 1
    return '\n'.join(out), n

for p in sys.argv[1:]:
    s = open(p, newline='').read()
    new, n = convert(s)
    if n:
        open(p, 'w', newline='').write(new)
        print(f'{p}: {n}')
