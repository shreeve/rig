#!/usr/bin/env python3
# analyze.py times.txt: per project, checker count and variant, the median
# and fastest wall, and the medians of the counters; then Trig's ratio to
# each tsrs mode, and each tool's speedup from one checker.
import sys, statistics as st, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    if line.startswith('#') or '=' not in line: continue
    parts = line.split()
    proj = parts[0]
    kv = dict(p.split('=', 1) for p in parts[1:] if '=' in p)
    if kv.get('same') != '1' or kv.get('exit') not in ('0', '2'): print('BAD', line.strip()); continue
    rows[(proj, int(kv['n']), kv['v'])].append(kv)
def med(xs): return st.median(xs)
keys = [('wall', 'duration_time', 1e6), ('user', 'user_time', 1e6), ('sys', 'system_time', 1e6),
        ('task', 'task-clock', 1), ('ucyc', 'cyclesu', 1e9), ('kcyc', 'cyclesk', 1e9),
        ('ins', 'instructionsu', 1e9), ('faults', 'page-faults', 1), ('cs', 'context-switches', 1),
        ('rss', 'rss_kb', 1024)]
summ = {}
for proj in ('ts-pattern', 'zod3'):
    print(f'\n{proj}')
    print(f"{'n':>2} {'variant':6} {'runs':>4} {'wall med':>9} {'fastest':>8} {'user':>7} {'sys':>6} {'task ms':>8} {'u cyc G':>8} {'k cyc G':>8} {'ins G':>7} {'faults':>7} {'csw':>6} {'RSS MB':>7}")
    for n in (1, 2, 4, 8):
        for v in ('t773', 't2c0', 'tsgo', 'tsdef'):
            rs = rows.get((proj, n, v))
            if not rs: continue
            d = {name: med([float(r[k]) for r in rs]) / div for name, k, div in keys}
            d['fast'] = min(float(r['duration_time']) for r in rs) / 1e6
            summ[(proj, n, v)] = d
            print(f"{n:>2} {v:6} {len(rs):>4} {d['wall']:9.1f} {d['fast']:8.1f} {d['user']:7.1f} {d['sys']:6.1f} {d['task']:8.1f} {d['ucyc']:8.3f} {d['kcyc']:8.3f} {d['ins']:7.3f} {d['faults']:7.0f} {d['cs']:6.0f} {d['rss']:7.1f}")
    print(f"\n{'n':>2} {'Trig/tsgo med':>13} {'fast':>6} {'Trig/tsdef med':>14} {'fast':>6} {'Trig speedup':>12} {'tsgo speedup':>12} {'tsdef speedup':>13} {'Trig task/1':>11} {'tsgo task/1':>11} {'Trig ins/1':>10} {'tsgo ins/1':>10}")
    for n in (1, 2, 4, 8):
        t, g, f = (summ.get((proj, n, v)) for v in ('t773', 'tsgo', 'tsdef'))
        if not (t and g and f): continue
        t1, g1, f1 = (summ[(proj, 1, v)] for v in ('t773', 'tsgo', 'tsdef'))
        print(f"{n:>2} {t['wall']/g['wall']:13.3f} {t['fast']/g['fast']:6.3f} {t['wall']/f['wall']:14.3f} {t['fast']/f['fast']:6.3f} {t1['wall']/t['wall']:12.2f} {g1['wall']/g['wall']:12.2f} {f1['wall']/f['wall']:13.2f} {t['task']/t1['task']:11.3f} {g['task']/g1['task']:11.3f} {t['ins']/t1['ins']:10.3f} {g['ins']/g1['ins']:10.3f}")
