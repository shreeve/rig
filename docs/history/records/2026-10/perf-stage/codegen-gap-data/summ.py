#!/usr/bin/env python3
"""summ.py TIMES [BASE]: medians a variant and project of time-rot.sh's
output, and each variant against BASE (main) and tsrs."""
import sys, statistics as st, collections
times = sys.argv[1]; base_v = sys.argv[2] if len(sys.argv) > 2 else 'main'
d = collections.defaultdict(lambda: collections.defaultdict(list)); vs = []
for l in open(times):
    if l.startswith('#') or not l.strip(): continue
    w = l.split(); proj = w[0]
    f = dict(x.split('=', 1) for x in w[1:] if '=' in x)
    if f['v'] not in vs: vs.append(f['v'])
    for k in ('duration_time', 'cycles/u', 'cycles/k', 'instructions/u', 'rss_kb', 'page-faults', 'huge2m', 'dtlb_load_misses.walk_completed'):
        d[(proj, f['v'])][k].append(float(f[k]))
    d[(proj, f['v'])]['same'].append(int(f['same']))
for proj in ('ts-pattern', 'zod3'):
    if (proj, base_v) not in d: continue
    print(f'## {proj} (medians of {len(d[(proj, base_v)]["duration_time"])} runs)')
    med = lambda v, k: st.median(d[(proj, v)][k])
    for v in vs:
        if (proj, v) not in d: continue
        print(f'{v:8s} wall {med(v,"duration_time")/1e6:7.1f} ms  user {med(v,"cycles/u")/1e9:6.3f}G  kernel {med(v,"cycles/k")/1e6:5.0f}M  instr {med(v,"instructions/u")/1e9:6.3f}G  '
              f'rss {med(v,"rss_kb")/1024:6.1f} MB  faults {med(v,"page-faults"):6.0f}  dtlb walks {med(v,"dtlb_load_misses.walk_completed")/1e6:5.2f}M  same {sum(d[(proj,v)]["same"])}/{len(d[(proj,v)]["same"])}')
    for v in vs:
        if v == base_v or (proj, v) not in d: continue
        r = lambda k: 100 * (1 - med(v, k) / med(base_v, k))
        print(f'  {v} against {base_v}: wall {r("duration_time"):5.1f}% less, user cycles {r("cycles/u"):5.1f}% fewer, kernel {r("cycles/k"):5.1f}%, instructions {r("instructions/u"):5.1f}% fewer, rss {r("rss_kb"):5.1f}% less')
    if (proj, 'tsrs') in d:
        for v in vs:
            if v == 'tsrs': continue
            print(f'  {v} / tsrs: wall {med(v,"duration_time")/med("tsrs","duration_time"):.3f}x, user cycles {med(v,"cycles/u")/med("tsrs","cycles/u"):.3f}x, instructions {med(v,"instructions/u")/med("tsrs","instructions/u"):.3f}x, rss {med(v,"rss_kb")/med("tsrs","rss_kb"):.3f}x')
    print(f'  free 2 MiB blocks before runs: {min(d[(proj, base_v)]["huge2m"]):.0f}-{max(d[(proj, base_v)]["huge2m"]):.0f}')
