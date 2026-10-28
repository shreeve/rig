#!/usr/bin/env python3
"""analyze.py TIMES.txt: per project and variant, the median and fastest
wall time and the medians of user and system time, user and kernel cycles,
user instructions, page faults and peak RSS; then the ratios."""
import sys, statistics as st, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    if ' v=' not in line: continue
    f = line.split(); proj = f[0]; d = dict(x.split('=', 1) for x in f[1:])
    rows[(proj, d['v'])].append(d)
order = ['773-pgo', '2c0-pgo', '364-pgo', 'tsrs', 'tsrs-src']
def m(proj, v, k, f=st.median):
    return f(float(x[k]) for x in rows[(proj, v)])
for proj in ['ts-pattern', 'zod3']:
    print(f'\n{proj}')
    print('| variant | n | wall median ms | wall fastest ms | user ms | system ms | user cycles | kernel cycles | instructions | page faults | peak RSS MB | output |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|')
    for v in order:
        r = rows.get((proj, v))
        if not r: continue
        same = all(x['same'] == '1' for x in r)
        exits = ','.join(sorted(set(x['exit'] for x in r)))
        g = lambda k: m(proj, v, k)
        print(f"| {v} | {len(r)} | {g('duration_time')/1e6:,.1f} | {m(proj, v, 'duration_time', min)/1e6:,.1f} | {g('user_time')/1e6:,.1f} | {g('system_time')/1e6:,.1f} | {g('cycles/u')/1e9:.3f}G | {g('cycles/k')/1e6:,.0f}M | {g('instructions/u')/1e9:.3f}G | {g('page-faults'):,.0f} | {g('rss_kb')/1024:.1f} | {'same' if same else 'DIFF'} exit {exits} |")
    print()
    for a, b in [('773-pgo', 'tsrs'), ('2c0-pgo', 'tsrs'), ('364-pgo', 'tsrs'), ('773-pgo', '2c0-pgo'), ('2c0-pgo', '364-pgo'), ('773-pgo', '364-pgo')]:
        q = lambda k, f=st.median: m(proj, a, k, f) / m(proj, b, k, f)
        print(f"{a} / {b}: wall median {q('duration_time'):.3f}, fastest {q('duration_time', min):.3f}, user {q('user_time'):.3f}, system {q('system_time'):.3f}, user cycles {q('cycles/u'):.4f}, kernel cycles {q('cycles/k'):.3f}, instructions {q('instructions/u'):.4f}, faults {q('page-faults'):.3f}, RSS {q('rss_kb'):.3f}")
    loads = [float(x['load']) for k, r in rows.items() if k[0] == proj for x in r]
    print(f'load: {min(loads)} to {max(loads)}')
