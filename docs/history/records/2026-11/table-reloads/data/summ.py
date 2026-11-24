#!/usr/bin/env python3
# summ.py ROWS [A B]: medians per project, arm and event; ratios A/B, and each event's excess as % of B's cycles
# scaled by instructions ((A_ev - B_ev*insA/insB)/B_cycles) for stall-type events.
import sys, collections, statistics
rows = sys.argv[1]; A = sys.argv[2] if len(sys.argv) > 2 else 'T'; B = sys.argv[3] if len(sys.argv) > 3 else 'Y'
d = collections.defaultdict(lambda: collections.defaultdict(list)); md5 = collections.defaultdict(set)
for l in open(rows):
    f = l.split()
    if len(f) < 6: continue
    arm, p, s, r, m = f[:5]; md5[p].add(m)
    for kv in f[5:]:
        k, v = kv.split('='); 
        try: d[(p, arm)][k].append(float(v))
        except ValueError: pass
for p in sorted({k[0] for k in d}):
    a, b = d[(p, A)], d[(p, B)]
    if not a or not b: continue
    med = lambda x, k: statistics.median(x[k]) if x.get(k) else float('nan')
    ia, ib, cb, ca = med(a, 'instructions'), med(b, 'instructions'), med(b, 'cycles'), med(a, 'cycles')
    print(f'## {p}  stdout md5s {sorted(md5[p])}  instr {A}/{B} {ia/ib:.3f}  cycles {A}/{B} {ca/cb:.3f}  (n={len(a["cycles"])},{len(b["cycles"])})')
    for k in sorted(set(a) | set(b)):
        if k in ('cycles', 'instructions'): continue
        va, vb = med(a, k), med(b, k)
        slots = 'topdown' in k
        denom = cb * (6 if slots else 1)  # Crestmont: 6 slots a cycle
        print(f'  {k:42s} {A} {va:14.4g}  {B} {vb:14.4g}  {A}/{B} {va/vb if vb else float("nan"):6.3f}  excess {100*(va - vb*ia/ib)/denom:+6.2f}% of {B} cycles  share {A} {100*va/(ca*(6 if slots else 1)):5.1f}% {B} {100*vb/(cb*(6 if slots else 1)):5.1f}%')
