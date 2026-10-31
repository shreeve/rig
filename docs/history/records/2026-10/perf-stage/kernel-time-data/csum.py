#!/usr/bin/env python3
"""csum.py FILE: medians of counts.sh lines by project and RIG_KT."""
import sys, collections, statistics as st
d = collections.defaultdict(list)
for l in open(sys.argv[1]):
    w = l.split()
    if len(w) < 4 or '=' not in w[1]: continue
    kv = dict(x.split('=', 1) for x in w[1:] if '=' in x)
    kv = {k.replace('cpu_atom/', '').replace('cpu_core/', '').rstrip('/').replace('cycles/k', 'cycles:k').replace('cycles/u', 'cycles:u'): v for k, v in kv.items()}
    if 'cycles:k' not in kv: continue
    d[(w[0], kv['kt'])].append(kv)
for (p, kt), rs in sorted(d.items()):
    g = lambda k: st.median(float(r[k]) for r in rs)
    print(f"{p:11} {kt:5} n={len(rs)} wall={g('duration_time')/1e6:7.1f}ms user={g('cycles:u')/1e6:7.0f}M kern={g('cycles:k')/1e6:6.0f}M sum={(g('cycles:u')+g('cycles:k'))/1e6:7.0f}M faults={g('page-faults'):6.0f} minflt={g('minflt'):6.0f} rss={g('rss_kb')/1024:6.1f}MB")
