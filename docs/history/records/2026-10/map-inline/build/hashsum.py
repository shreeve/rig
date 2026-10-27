#!/usr/bin/env python3
"""hashsum.py FILE BASE NEW: the fastest of each row per binary, and NEW against BASE."""
import sys, collections
best = collections.defaultdict(dict); checks = collections.defaultdict(set); order = []
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) != 6: continue
    b, r, keys, op, ns, chk = p
    row = (keys, op)
    if row not in order: order.append(row)
    ns = float(ns)
    best[row][b] = min(best[row].get(b, 1e18), ns)
    checks[row].add(chk)
for pair in sys.argv[2:]:
    base, new = pair.split(':')
    print(f"\n{new} against {base}")
    for row in order:
        a = best[row].get(base); c = best[row].get(new)
        if a is None or c is None: continue
        d = (a - c) / a * 100
        word = f"{d:.1f}% faster" if d >= 0 else f"{-d:.1f}% slower"
        print(f"  {row[0]:>8} {row[1]:<12} {a:8.2f} {c:8.2f}  {word}  {'ok' if len(checks[row]) == 1 else 'CHECK DIFFERS'}")
