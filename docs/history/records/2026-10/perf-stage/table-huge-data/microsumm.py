#!/usr/bin/env python3
"""microsumm.py micro.txt: medians of tabjit's lines per level and arm (the
stash arms by the CPUs they ran on), and each arm's per-round wall ratio
to `small` in the same round and level."""
import sys, statistics as st
from collections import defaultdict

rows = defaultdict(list)
by_round = defaultdict(dict)
for line in open(sys.argv[1]):
    if not line.startswith('level='): continue
    d = dict(kv.split('=', 1) for kv in line.split())
    arm = d['arm'] + ('' if not d['arm'].startswith('stash') else ('/2cpu' if ',' in d['cpus'] else '/1cpu'))
    for k in list(d):
        try: d[k] = float(d[k])
        except ValueError: pass
    rows[(d['level'], arm)].append(d)
    by_round[(d['level'], d['round'])][arm] = d

def med(xs): return st.median(xs) if xs else float('nan')
def pct(r): return f"{(1 - r) * 100:.1f}% faster" if r <= 1 else f"{(r - 1) * 100:.1f}% slower"
arms = ['small', 'gate', 'whole', 'jit', 'breaker', 'collapse', 'stash4k/1cpu', 'stash/1cpu', 'stash4k/2cpu', 'stash/2cpu']
print("| level | arm | free at start | wall ms | vs small | user ms | sys ms | pusher sys ms | faults | huge MiB | windows asked | slowest window ms | compact_stall | RSS MiB |")
print("|---|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for level in ['natural', 'light', 'quiet']:
    for a in arms:
        rs = rows.get((level, a))
        if not rs: continue
        g = lambda k: med([r[k] for r in rs])
        fr = [r['free'] for r in rs]
        ratios = [v[a]['wall_ms'] / v['small']['wall_ms'] for (lv, _), v in by_round.items() if lv == level and a in v and 'small' in v]
        vs = pct(med(ratios)) if a != 'small' else ''
        print(f"| {level} | {a} | {g('free'):.0f} ({min(fr):.0f}-{max(fr):.0f}) | {g('wall_ms'):.0f} | {vs} | {g('user_ms'):.0f} | {g('sys_ms'):.0f} | "
              f"{g('main_sys_ms'):.0f} | {g('minflt'):.0f} | {g('huge_mib'):.0f} | {g('asked'):.0f} | {g('worst_ms'):.2f} | {g('compact_stall'):.0f} | {g('rss_mib'):.0f} |")
