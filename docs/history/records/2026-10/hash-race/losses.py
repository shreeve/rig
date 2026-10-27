"""Read a bench/hash/bench-hash report and print, for each table named,
every row it does not win, the int rows left out: its time, the
winner's, and by how much it loses. usage: losses.py REPORT V [V ...]"""
import sys
lines = open(sys.argv[1]).read().splitlines()
hdr = lines[0].split()
names = hdr[2:hdr.index('fastest')]
rows = []
for l in lines[1:]:
    f = l.split()
    if len(f) < 2 + len(names) or f[0].startswith('int') or f[0] in ('keys', 'first', 'memory:', 'runs'):
        continue
    try:
        vals = {n: float(x) for n, x in zip(names, f[2:2 + len(names)]) if x != '-'}
    except ValueError:
        continue
    if len(vals) == len(names):
        rows.append((f[0] + ' ' + f[1], vals))
for v in sys.argv[2:]:
    lost = []
    for row, vals in rows:
        w = min(vals, key=vals.get)
        if w != v:
            lost.append((vals[v] / vals[w], row, w, vals[w], vals[v]))
    print(f"\n{v}: wins {len(rows) - len(lost)} of {len(rows)}; loses {len(lost)}:")
    for r, row, w, bw, bv in sorted(lost, reverse=True):
        print(f"  {row:24} {bv:8.2f} vs {w} {bw:.2f}  ({(r - 1) * 100:.1f}% slower)")
