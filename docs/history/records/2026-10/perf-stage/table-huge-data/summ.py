#!/usr/bin/env python3
"""summ.py times.txt...: medians per project, level, and arm, and each arm's
per-round wall ratio to `main` and to `jit` in the same round and level, as "N% faster" or "N% slower" (median, with the 25th
and 75th percentiles), and the free 2 MiB blocks at the start (min-max)."""
import sys, statistics as st
from collections import defaultdict

rows = defaultdict(list)          # (proj, v, mode) -> [dict]
by_round = defaultdict(dict)      # (proj, mode, round) -> v -> dict
for path in sys.argv[1:]:
    for line in open(path):
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

def med(xs): return st.median(xs) if xs else float('nan')
def q(xs, p):
    xs = sorted(xs); i = (len(xs) - 1) * p; lo = int(i); hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (i - lo)
def pct(r):
    return f"{(1 - r) * 100:.1f}% faster" if r <= 1 else f"{(r - 1) * 100:.1f}% slower"
def vs(proj, mode, v, base):
    rs = [vv[v]['duration_time'] / vv[base]['duration_time']
          for (p, m, rd), vv in by_round.items() if p == proj and m == mode and v in vv and base in vv]
    if v == base or not rs: return ''
    return f"{pct(med(rs))} [{(q(rs, .25) - 1) * 100:+.1f}%, {(q(rs, .75) - 1) * 100:+.1f}%]"

modes = ['natural', 'quiet', 'leave35', 'light']
arms = ['main', 'jit']
for proj in ['ts-pattern', 'zod3', 'tiny-invariant', 'superstruct', 'mitt', 'neverthrow']:
    print(f"\n## {proj}\n")
    print("| level | arm | runs | free at start | wall ms | user cycles | kernel cycles | faults | thp_fault_alloc | compact_stall | peak RSS MB | wall vs main [25th, 75th] | wall vs jit [25th, 75th] |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|")
    for mode in modes:
        for v in arms:
            rs = rows.get((proj, v, mode))
            if not rs: continue
            g = lambda k: med([r[k] for r in rs if k in r])
            u = [r['units'] for r in rs]
            print(f"| {mode} | {v} | {len(rs)} | {g('units'):.0f} ({min(u):.0f}-{max(u):.0f}) | {g('duration_time') / 1e6:.0f} | "
                  f"{g('cycles/u') / 1e9:.2f}G | {g('cycles/k') / 1e9:.2f}G | {g('page-faults'):.0f} | {g('thp_fault_alloc'):.0f} | "
                  f"{g('compact_stall'):.0f} | {g('rss_kb') / 1024:.1f} | {vs(proj, mode, v, 'main')} | {vs(proj, mode, v, 'jit')} |")
    bad = [r for (p, v, m), rs in rows.items() if p == proj for r in rs if r.get('same') != 1.0]
    ex = sorted({r.get('exit') for (p, v, m), rs in rows.items() if p == proj for r in rs})
    print(f"\nRuns whose output differs from the reference: {len(bad)}; exit statuses: {ex}")
