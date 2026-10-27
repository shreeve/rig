#!/usr/bin/env python3
# sum.py FILE BASE:NEW ...: trigbench lines summarized per build: fastest
# wall, fewest cycles and instructions, median peak RSS, all outputs
# identical; then each NEW against its BASE.
import sys, re, statistics, collections
rows = collections.defaultdict(list); same = collections.defaultdict(set)
for line in open(sys.argv[1]):
    d = dict(kv.split('=', 1) for kv in line.split()[1:])
    b = d['build']; rows[b].append((float(d['secs']), int(d['cycles']), int(d['instructions']), int(d['rss_kb']))); same[b].add(d['same'])
best = {}
for b, r in rows.items():
    best[b] = (min(x[0] for x in r), min(x[1] for x in r), min(x[2] for x in r), statistics.median(x[3] for x in r))
    print(f"{b:10s} wall {best[b][0]*1000:8.1f} ms  cycles {best[b][1]/1e9:6.3f}G  instr {best[b][2]/1e9:6.3f}G  rss {best[b][3]/1024:6.1f} MB  same {''.join(sorted(same[b]))}  n={len(r)}")
def pct(a, b):
    d = (b - a) / a * 100
    return f"{abs(d):.1f}% {'slower' if d > 0 else 'faster'}"
def pctn(a, b, more, fewer):
    d = (b - a) / a * 100
    return f"{abs(d):.2f}% {more if d > 0 else fewer}"
for pair in sys.argv[2:]:
    a, b = pair.split(':'); A, B = best[a], best[b]
    print(f"  {b} vs {a}: wall {pct(A[0], B[0])}, cycles {pctn(A[1], B[1], 'more', 'fewer')}, instructions {pctn(A[2], B[2], 'more', 'fewer')}, RSS {pctn(A[3], B[3], 'higher', 'lower')}")
