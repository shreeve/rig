#!/usr/bin/env python3
"""modes.py TIMES: Trig's runs split by the huge-page gate (open: faults under
1.3 times the arm's fewest), medians per mode, and the no-yield comparison
within the shut mode."""
import sys, statistics as st
d = {}
for l in open(sys.argv[1]):
    if ' v=' not in l: continue
    p = l.split()[0]; f = dict(x.split('=', 1) for x in l.split()[1:] if '=' in x)
    d.setdefault((p, f['v']), []).append(dict(w=float(f['duration_time'])/1e6, c=float(f['cycles/u'])+float(f['cycles/k']),
        i=float(f['instructions/u']), flt=float(f['page-faults']), rss=float(f['rss_kb'])/1024, chk=float(f['check_ms']),
        wact=float(f['dtlb_load_misses.walk_active/u'])+float(f['dtlb_store_misses.walk_active/u']), cu=float(f['cycles/u'])))
def split(rs):
    lo = min(r['flt'] for r in rs)
    return [r for r in rs if r['flt'] < 1.3*lo], [r for r in rs if r['flt'] >= 1.3*lo]
M = lambda rs, k: st.median(r[k] for r in rs) if rs else float('nan')
for (p, v), rs in sorted(d.items()):
    o, s = split(rs)
    print(f"{p:10s} {v:6s} open {len(o):2d}: wall {M(o,'w'):7.2f} rss {M(o,'rss'):6.1f} flt {M(o,'flt'):6.0f} | shut {len(s):2d}: wall {M(s,'w'):7.2f} rss {M(s,'rss'):6.1f} flt {M(s,'flt'):6.0f} walk-act/ucyc {M(s,'wact')/M(s,'cu')*100 if s else 0:.1f}%")
print('\nno yield checks against base, all runs and shut mode only (negative = less)')
for p in ['empty', 'zod3', 'ts-pattern']:
    for c in '14':
        b, y = d[p, 'base'+c], d[p, 'noy'+c]
        for name, bb, yy in (('all', b, y), ('shut', split(b)[1] or b, split(y)[1] or y)):
            pc = lambda k: (M(yy, k)/M(bb, k)-1)*100
            fw = (min(r['w'] for r in yy)/min(r['w'] for r in bb)-1)*100
            print(f"{p:10s} {c} {name:4s} n={len(bb)},{len(yy)} wall median {pc('w'):+.1f}% fastest {fw:+.1f}% cycles {pc('c'):+.1f}% instr {pc('i'):+.1f}%")
