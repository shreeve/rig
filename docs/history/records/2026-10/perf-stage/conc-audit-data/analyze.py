#!/usr/bin/env python3
"""analyze.py TIMES: medians, fastest runs and the audit's derived shares."""
import sys, re, statistics as st
from collections import defaultdict
rows = defaultdict(list)
for line in open(sys.argv[1]):
    if line.startswith('#') or ' v=' not in line: continue
    f = dict(kv.split('=', 1) for kv in line.split()[1:] if '=' in kv)
    proj = line.split()[0]
    if f.get('same') != '1':
        print('# skipped', line.strip()); continue
    def n(k):
        v = f.get(k, '')
        try: return float(v)
        except ValueError: return float('nan')
    r = dict(wall=n('duration_time') / 1e6, cyc=n('cycles/u') + n('cycles/k'), cycu=n('cycles/u'),
             ins=n('instructions/u'), rss=n('rss_kb') / 1024, flt=n('page-faults'),
             walks=n('dtlb_load_misses.walk_completed/u') + n('dtlb_store_misses.walk_completed/u'),
             wact=n('dtlb_load_misses.walk_active/u') + n('dtlb_store_misses.walk_active/u'),
             parse=n('parse_ms'), bind=n('bind_ms'), check=n('check_ms'), total=n('total_ms'))
    r['serial'] = r['wall'] - r['check']
    r['pb'] = r['parse'] + r['bind']
    rows[proj, f['v']].append(r)
med = lambda xs: st.median(xs)
def m(proj, v, k): return med([r[k] for r in rows[proj, v]])
def lo(proj, v, k): return min(r[k] for r in rows[proj, v])
projs = sorted({p for p, _ in rows}, key=lambda p: ['empty', 'zod3', 'ts-pattern'].index(p) if p in ('empty','zod3','ts-pattern') else 9)
arms = sorted({v for _, v in rows})
print('| project | arm | runs | wall median | wall fastest | cycles u+k | instr u | peak RSS MB | faults | dTLB walks | walk-active cycles | parse | bind | check | total (Trig/tsrs clock) |')
print('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
for p in projs:
    for v in arms:
        if not rows[p, v]: continue
        print(f"| {p} | {v} | {len(rows[p,v])} | {m(p,v,'wall'):.2f} | {lo(p,v,'wall'):.2f} | {m(p,v,'cyc')/1e6:.1f}M | {m(p,v,'ins')/1e6:.1f}M | {m(p,v,'rss'):.1f} | {m(p,v,'flt'):.0f} | {m(p,v,'walks')/1e6:.3f}M | {m(p,v,'wact')/1e6:.1f}M | "
              f"{st.mean(r['parse'] for r in rows[p,v]):.1f} | {st.mean(r['bind'] for r in rows[p,v]):.1f} | {st.mean(r['check'] for r in rows[p,v]):.1f} | {st.mean(r['total'] for r in rows[p,v]):.1f} |")
def pct(a, b): return f"{(a/b-1)*100:+.1f}%"
print('\n## Serial head (share of wall; parse+bind and everything outside Check time)')
for p in projs:
    for v in arms:
        if not rows[p, v]: continue
        w = m(p, v, 'wall')
        pb = st.mean(r['pb'] for r in rows[p, v]); se = med([r['serial'] / r['wall'] for r in rows[p, v]])
        print(f"{p:11s} {v:6s} wall {w:8.2f} ms  parse+bind {pb:6.1f} ms = {pb/w*100:5.1f}%  all serial (wall - check) {se*100:5.1f}%  Amdahl ceiling {1/se:.2f}x")
print('\n## 4 over 1')
for p in projs:
    for a in ('base', 'pgo', 'tsrs'):
        if not rows[p, a+'1'] or not rows[p, a+'4']: continue
        g = lambda k: m(p, a+'4', k) / m(p, a+'1', k)
        print(f"{p:11s} {a:5s} RSS {g('rss'):.3f}  walks {g('walks'):.3f}  walk-active cycles {g('wact'):.3f}  faults {g('flt'):.3f}  cycles {g('cyc'):.3f}  wall {g('wall'):.3f}"
              f"  walk-active share of user cycles at 1 {m(p,a+'1','wact')/m(p,a+'1','cycu')*100:.1f}% at 4 {m(p,a+'4','wact')/m(p,a+'4','cycu')*100:.1f}%")
print('\n## No yield checks against base (negative = less)')
for p in projs:
    for c in '14':
        b, y = 'base'+c, 'noy'+c
        if not rows[p, b] or not rows[p, y]: continue
        print(f"{p:11s} {c} checker(s): wall median {pct(m(p,y,'wall'), m(p,b,'wall'))}  fastest {pct(lo(p,y,'wall'), lo(p,b,'wall'))}  cycles u+k {pct(m(p,y,'cyc'), m(p,b,'cyc'))}  instr {pct(m(p,y,'ins'), m(p,b,'ins'))}")
