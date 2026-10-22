#!/usr/bin/env python3
# summ.py TIMES.tsv: fastest of N per variant and project, against base.
import sys, collections
rows = collections.defaultdict(list)
for l in open(sys.argv[1]):
    f = l.rstrip('\n').split('\t')
    r, p, v, ins, cyc, br, dur, h = f[:8]
    if len(f) > 8 and float(f[8]) >= 2.0: continue
    rows[(p, v)].append((int(ins), int(cyc), int(br), int(dur)))
projects = ['tiny-invariant', 'zod3', 'ts-pattern']
variants = []
for (p, v) in rows:
    if v not in variants: variants.append(v)
singles = [v for v in ['index', 'cast', 'overflow', 'bounds', 'tags', 'other'] if v in variants]
best = {k: tuple(min(x[i] for x in vs) for i in range(4)) for k, vs in rows.items()}
print('fastest of N (N = %s); instructions Mi, cycles Mc, branches Mi, time ms; change against base' % ','.join(str(len(v)) for v in list(rows.values())[:1]))
for p in projects:
    b = best[(p, 'base')]
    print(f'\n{p}')
    print(f'  {"variant":10} {"instr":>9} {"d instr":>8} {"cycles":>9} {"d cyc":>7} {"branches":>9} {"d br":>7} {"time":>7} {"d time":>7}')
    sums = [0, 0, 0, 0]
    for v in variants:
        x = best[(p, v)]
        d = [100.0 * (x[i] - b[i]) / b[i] for i in range(4)]
        if v in singles:
            for i in range(4): sums[i] += d[i]
        print(f'  {v:10} {x[0]/1e6:9.0f} {d[0]:7.2f}% {x[1]/1e6:9.0f} {d[1]:6.2f}% {x[2]/1e6:9.0f} {d[2]:6.2f}% {x[3]/1e6:7.1f} {d[3]:6.2f}%')
    print(f'  {"sum of singles":14} instr {sums[0]:.2f}%  cycles {sums[1]:.2f}%  branches {sums[2]:.2f}%  time {sums[3]:.2f}%')
