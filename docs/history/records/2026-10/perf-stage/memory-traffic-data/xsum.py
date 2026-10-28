#!/usr/bin/env python3
# xsum.py DIR: xtime.sh's runs, per project and arm: fastest and median wall,
# medians of the rest, peak RSS (median), and each against arm 0.
import sys, glob, os, collections, statistics
d = sys.argv[1]
v = collections.defaultdict(lambda: collections.defaultdict(list))
for f in glob.glob(os.path.join(d, '*.csv')):
    p, a, r, _ = os.path.basename(f).split('.')
    for line in open(f):
        x = line.strip().split(',')
        if len(x) < 3 or line.startswith('#'): continue
        try: v[(p, a)][x[2]].append(float(x[0]))
        except ValueError: pass
    rs = f[:-4] + '.rss'
    if os.path.exists(rs): v[(p, a)]['rss'].append(float(open(rs).read().split()[-1]))
for p in ['ts-pattern', 'zod3']:
    arms = sorted({a for q, a in v if q == p}, key=int)
    if not arms: continue
    print('\n## %s (%d rounds)\n' % (p, len(v[(p, arms[0])]['duration_time'])))
    print('| arm | wall fastest ms | wall median ms | user cycles | kernel cycles | instructions | dTLB walk cycles | STLB load misses | blocked loads | faults | peak RSS MB |')
    print('|---|' + '---:|' * 10)
    base = None
    for a in arms:
        m = v[(p, a)]
        row = [min(m['duration_time']) / 1e6, statistics.median(m['duration_time']) / 1e6]
        for k in ['cpu_core/cycles/u', 'cpu_core/cycles/k', 'cpu_core/instructions/u', 'cpu_core/dtlb_load_misses.walk_active/u', 'cpu_core/mem_inst_retired.stlb_miss_loads/u', 'cpu_core/ld_blocks.store_forward/u', 'page-faults']:
            row.append(statistics.median(m[k]) if m[k] else float('nan'))
        row.append(statistics.median(m['rss']) / 1024 if m['rss'] else float('nan'))
        if base is None: base = row
        cells = ['%.1f' % row[0], '%.1f' % row[1]] + ['%.4gM' % (x / 1e6) for x in row[2:8]] + ['%d' % row[8], '%.1f' % row[9]]
        if a != arms[0]:
            cells = [c + ' (%+.1f%%)' % (100 * (x / b - 1)) for c, x, b in zip(cells, row, base)]
        print('| %s | %s |' % (a, ' | '.join(cells)))
