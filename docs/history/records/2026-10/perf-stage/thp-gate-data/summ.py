#!/usr/bin/env python3
"""summ.py times.txt [BASE]: medians per project, build, and mode, and each
build's per-round wall and total-cycle ratio to BASE (default d) in the same
round and mode, as "N% faster" or "N% slower" (median, 25th-75th of wall)."""
import sys, statistics as st
from collections import defaultdict

rows = defaultdict(list)          # (proj, v, mode) -> [dict]
by_round = defaultdict(dict)      # (proj, mode, round) -> v -> dict
for line in open(sys.argv[1]):
    if line.startswith('#') or '=' not in line: continue
    w = line.split()
    d = {'proj': w[0]}
    for kv in w[1:]:
        k, _, v = kv.partition('=')
        d[k] = v
    for k in list(d):
        try: d[k] = float(d[k])
        except ValueError: pass
    rows[(d['proj'], d['v'], d['mode'])].append(d)
    by_round[(d['proj'], d['mode'], d['round'])][d['v']] = d
base = sys.argv[2] if len(sys.argv) > 2 else 'd'

def med(xs): return st.median(xs) if xs else float('nan')
def q(xs, p):
    xs = sorted(xs); i = (len(xs) - 1) * p; lo = int(i); hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (i - lo)
def pct(r):
    return f"{(1 - r) * 100:.1f}% faster" if r <= 1 else f"{(r - 1) * 100:.1f}% slower"

modes = ['quiet', 'light', 'frag']
names = {'a': '(a) main 773978d1d', 'b': '(b) #760 revert', 'c': '(c) revert, no segment advice',
         'd': '(d) no MADV_HUGEPAGE', 'e': '(e) main, advice gated, 16 blocks spare',
         'e2': '(e2) main, advice gated, 128 blocks spare', 'g': '(g) thp-gate 5b103b53f'}
for proj in ['ts-pattern', 'zod3']:
    print(f"\n## {proj}\n")
    print("| build | mode | runs | wall ms | user cycles | kernel cycles | faults | thp_fault_alloc | thp_fault_fallback | compact_stall | peak RSS MB | free 2 MiB blocks at start | wall vs (%s) [25th-75th] | total cycles vs (%s) |" % (base, base))
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|")
    for mode in modes:
        for v in ['a', 'b', 'c', 'd', 'e', 'e2', 'g']:
            rs = rows.get((proj, v, mode))
            if not rs: continue
            g = lambda k: med([r[k] for r in rs if k in r])
            ratios, cyc = [], []
            for (p, m, rd), vs in by_round.items():
                if p == proj and m == mode and v in vs and base in vs:
                    ratios.append(vs[v]['duration_time'] / vs[base]['duration_time'])
                    cyc.append((vs[v]['cycles/u'] + vs[v]['cycles/k']) / (vs[base]['cycles/u'] + vs[base]['cycles/k']))
            rel = '' if v == base or not ratios else f"{pct(med(ratios))} [{(q(ratios, .25) - 1) * 100:+.1f}%, {(q(ratios, .75) - 1) * 100:+.1f}%]"
            relc = '' if v == base or not cyc else pct(med(cyc))
            print(f"| {names[v]} | {mode} | {len(rs)} | {g('duration_time') / 1e6:.0f} | {g('cycles/u') / 1e9:.2f}G | {g('cycles/k') / 1e9:.2f}G | "
                  f"{g('page-faults'):.0f} | {g('thp_fault_alloc'):.0f} | {g('thp_fault_fallback'):.0f} | {g('compact_stall'):.0f} | "
                  f"{g('rss_kb') / 1024:.1f} | {g('units'):.0f} | {rel} | {relc} |")
    bad = [r for (p, v, m), rs in rows.items() if p == proj for r in rs if r.get('same') != 1.0]
    print(f"\nOutputs differing from the reference: {len(bad)}")
