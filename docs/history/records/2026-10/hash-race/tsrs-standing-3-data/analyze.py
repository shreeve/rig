#!/usr/bin/env python3
"""analyze.py TIMES.txt...: per project and variant, the median and fastest
wall time and the medians of user and system time, user and kernel cycles,
user instructions, page faults, dTLB and iTLB walks and peak RSS; then the
ratios. Several files are read as one set of rounds. Rig main's runs are
also split by whether its huge-page gate let them have huge pages, as their
page faults show (ts-pattern under 28,000, zod3 under 9,000, against about
40,400 and 10,060 without): 1b2-pgo/huge and 1b2-pgo/small."""
import sys, statistics as st, collections
rows = collections.defaultdict(list)
for path in sys.argv[1:]:
    for line in open(path):
        if ' v=' not in line: continue
        f = line.split(); proj = f[0]; d = dict(x.split('=', 1) for x in f[1:])
        rows[(proj, d['v'])].append(d)
        if d['v'] == '1b2-pgo':
            cut = 28000 if proj == 'ts-pattern' else 9000
            rows[(proj, '1b2-pgo/' + ('huge' if float(d['page-faults']) < cut else 'small'))].append(d)
order = ['1b2-pgo', '1b2-pgo/huge', '1b2-pgo/small', '773-pgo', '773-403-pgo', 'tsrs', 'tsrs-src']
def m(proj, v, k, f=st.median):
    return f(float(x[k]) for x in rows[(proj, v)])
for proj in ['ts-pattern', 'zod3']:
    print(f'\n{proj}')
    print('| variant | n | wall median ms | wall fastest ms | user ms | system ms | user cycles | kernel cycles | instructions | page faults | dTLB load walks | dTLB store walks | STLB hits | iTLB walks | peak RSS MB | output |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|')
    for v in order:
        r = rows.get((proj, v))
        if not r: continue
        same = all(x['same'] == '1' for x in r)
        exits = ','.join(sorted(set(x['exit'] for x in r)))
        g = lambda k: m(proj, v, k)
        print(f"| {v} | {len(r)} | {g('duration_time')/1e6:,.1f} | {m(proj, v, 'duration_time', min)/1e6:,.1f} | {g('user_time')/1e6:,.1f} | {g('system_time')/1e6:,.1f} | {g('cycles/u')/1e9:.3f}G | {g('cycles/k')/1e6:,.0f}M | {g('instructions/u')/1e9:.3f}G | {g('page-faults'):,.0f} | {g('dtlb_load_misses.walk_completed')/1e3:,.0f}k | {g('dtlb_store_misses.walk_completed')/1e3:,.0f}k | {g('dtlb_load_misses.stlb_hit')/1e6:,.1f}M | {g('itlb_misses.walk_completed')/1e3:,.0f}k | {g('rss_kb')/1024:.1f} | {'same' if same else 'DIFF'} exit {exits} |")
    print()
    for a, b in [('1b2-pgo', 'tsrs'), ('1b2-pgo/huge', 'tsrs'), ('1b2-pgo/small', 'tsrs'), ('1b2-pgo/huge', '773-pgo'), ('1b2-pgo/small', '773-pgo'), ('1b2-pgo/small', '1b2-pgo/huge'), ('773-pgo', 'tsrs'), ('773-403-pgo', 'tsrs'), ('1b2-pgo', '773-pgo'), ('773-pgo', '773-403-pgo'), ('1b2-pgo', '773-403-pgo')]:
        if (proj, a) not in rows or (proj, b) not in rows: continue
        q = lambda k, f=st.median: m(proj, a, k, f) / m(proj, b, k, f)
        print(f"{a} / {b}: wall median {q('duration_time'):.3f}, fastest {q('duration_time', min):.3f}, user {q('user_time'):.3f}, system {q('system_time'):.3f}, user cycles {q('cycles/u'):.4f}, kernel cycles {q('cycles/k'):.3f}, instructions {q('instructions/u'):.4f}, faults {q('page-faults'):.3f}, dTLB load walks {q('dtlb_load_misses.walk_completed'):.3f}, dTLB store walks {q('dtlb_store_misses.walk_completed'):.3f}, iTLB walks {q('itlb_misses.walk_completed'):.3f}, RSS {q('rss_kb'):.3f}")
    loads = [float(x['load']) for k, r in rows.items() if k[0] == proj for x in r]
    print(f'load: {min(loads)} to {max(loads)}')
    hs = [int(x['huge2m']) for k, r in rows.items() if k[0] == proj and '/' not in k[1] for x in r]
    print(f'free 2 MiB blocks before a run: {min(hs)} to {max(hs)}, median {st.median(hs)}')
