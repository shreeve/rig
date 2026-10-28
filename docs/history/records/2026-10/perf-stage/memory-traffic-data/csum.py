#!/usr/bin/env python3
# csum.py DIR: counts.sh's CSVs, the median of each event per project and
# program, and Trig over tsrs.
import sys, glob, os, collections, statistics
d = sys.argv[1]
vals = collections.defaultdict(list)
for f in glob.glob(os.path.join(d, '*.csv')):
    p, v, g, r, _ = os.path.basename(f).split('.')
    for line in open(f):
        x = line.strip().split(',')
        if len(x) < 3 or line.startswith('#'): continue
        try: n = float(x[0])
        except ValueError: continue
        ev = x[2]
        if g == 'G2' and ev.startswith('cpu_core/cycles/u'): continue
        vals[(p, ev, v)].append(n)
progs = sorted({k[2] for k in vals})
for p in ['ts-pattern', 'zod3']:
    evs = sorted({k[1] for k in vals if k[0] == p}, key=lambda e: list(dict.fromkeys(k[1] for k in vals)).index(e))
    print('\n## %s (medians of %s runs)\n' % (p, '/'.join(str(len(vals[(p, evs[0], v)])) for v in progs)))
    print('| event | ' + ' | '.join(progs) + ' | ' + ' | '.join('%s / tsrs' % v for v in progs if not v.startswith('tsrs')) + ' |')
    print('|---|' + '---:|' * (len(progs) + sum(1 for v in progs if not v.startswith('tsrs'))))
    for e in evs:
        m = {v: statistics.median(vals[(p, e, v)]) if vals[(p, e, v)] else None for v in progs}
        cells = ['%.4g' % m[v] if m[v] is not None else '' for v in progs]
        rat = ['%.2f' % (m[v] / m['tsrs']) if m.get('tsrs') and m[v] else '' for v in progs if not v.startswith('tsrs')]
        print('| %s | %s | %s |' % (e.replace('cpu_core/', '').rstrip('/'), ' | '.join(cells), ' | '.join(rat)))
