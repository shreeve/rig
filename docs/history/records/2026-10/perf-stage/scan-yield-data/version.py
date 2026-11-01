#!/usr/bin/env python3
"""version.py PKG DST: the sound form of the scan rule, by hand. Each loop
classify.py covers in std's modules (outermost first) is written twice,
the copy chosen as the loop starts:

    if (B < __rig_turns_N) { __rig_turns_N -= B; <loop, no checks> }
    else { <loop as main emits it> }

where B bounds the loop's turns from its length: a walk's slice length,
a range's end less its start, or a `while`'s `rig.lenOf(x)` less the
index it compares. The count starts at 1,024 for a loop it is fresh in,
so a short loop takes the copy; inside another loop the remainder of the
shared count decides, and the copy charges its turns ahead. B ignores
the turns of a compile-time loop nested in the scan (find_any's tail):
it measures what the test and the copy cost, not the exact threshold.
"""
import os, re, sys, shutil, runpy
from collections import defaultdict

pkg, dst = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
sys.argv = ['classify.py', pkg, os.devnull]
g = runpy.run_path(os.path.join(here, 'classify.py'))
files, sites, covered, match_close = g['files'], g['sites'], g['covered'], g['match_close']

def left_operand(c, at):
    """The operand that ends just before position `at` of string c."""
    k = at - 1
    while k >= 0 and c[k] == ' ': k -= 1
    if c[k] == ')':
        d = 0
        for j in range(k, -1, -1):
            if c[j] == ')': d += 1
            elif c[j] == '(':
                d -= 1
                if d == 0: return c[j:k + 1]
        return None
    j = k
    while j >= 0 and (c[j].isalnum() or c[j] in '_.'): j -= 1
    return c[j + 1:k + 1] or None

def bound(st, s):
    if st['kind'] == 'range':
        m = re.search(r'while \((__rig_i_\d+) < (__rig_end_\d+)\)', st['header'])
        return f'({m.group(2)} - {m.group(1)})' if m else None
    if st['kind'] == 'for':
        h = st['header']
        p = h.find('for (') + 4
        q = match_close(h, p, '(', ')')
        args = h[p + 1:q]
        d = 0; first = args
        for i, ch in enumerate(args):
            if ch in '([': d += 1
            elif ch in ')]': d -= 1
            elif ch == ',' and d == 0: first = args[:i]; break
        first = first.strip()
        if '..' in first and not first.startswith('rig.slice'):
            a, b = first.split('..', 1)
            return f'(({b.strip()}) - ({a.strip()}))' if b.strip() else None
        return f'({first}).len'
    if st['kind'] == 'while':
        c = st['cond']
        m = re.search(r'<=?\s*rig\.lenOf\(([^()]*)\)', c)
        if not m: return None
        lt = c.rfind('<', 0, m.end() - len(m.group(0)) + 2)
        idx = left_operand(c, m.start())
        return f'(rig.lenOf({m.group(1)}) - {idx})' if idx else None
    return None

chosen = defaultdict(list)
skipped = []
for st in sorted(sites, key=lambda x: (x['file'], x['pos'])):
    f = st['file']
    if not f.startswith('__rig_std_') or not covered(st): continue
    src, s = files[f]
    a, b = st['body']
    hs = s.rfind('\n', 0, a) + 1 if st['kind'] == 'for' else s.rfind('\n', 0, st['pos']) + 1
    head = s[hs:a]
    lm = re.match(r'(\s*)((?:\w+:\s*)?)(while|for)\b', head)
    if not lm:
        skipped.append((f, st['header'], 'header')); continue
    start = hs + len(lm.group(1)); end = b + 1
    if re.match(r'\s*else\b', s[end:end + 20]):
        skipped.append((f, st['header'], 'else')); continue
    if any(x[0] <= start < x[1] for x in chosen[f]):
        continue   # inside a loop already written twice
    B = bound(st, s)
    if not B:
        skipped.append((f, st['header'], 'bound')); continue
    chosen[f].append((start, end, st['counter'], B))

if os.path.exists(dst): shutil.rmtree(dst)
shutil.copytree(pkg, dst, ignore=shutil.ignore_patterns('.zig-cache'))
n = 0
for f, lst in chosen.items():
    src = files[f][0]
    for start, end, ctr, B in sorted(lst, key=lambda x: -x[0]):
        loop = src[start:end]
        fast = loop.replace(f'rig.turn(&{ctr})', f'rig.noTurn(&{ctr})')
        new = (f'if ({B} < {ctr}) {{ {ctr} -= @intCast(@max({B}, 0)); {fast} }} else {{ {loop} }}')
        src = src[:start] + new + src[end:]
        n += 1
    open(os.path.join(dst, f), 'w').write(src)
rt = os.path.join(dst, 'rig', 'runtime.zig')
r = open(rt).read()
anchor = 'pub inline fn turn(n: *u32) void {'
r = r.replace(anchor, '/// STUDY (scan-yield): a covered loop\'s turn checks nothing.\npub inline fn noTurn(n: *u32) void {\n    _ = n;\n}\n\n' + anchor)
open(rt, 'w').write(r)
print(f'{n} loops written twice into {dst}')
for x in skipped: print('skipped', x)
