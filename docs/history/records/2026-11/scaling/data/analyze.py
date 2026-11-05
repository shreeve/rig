import sys, re, statistics as st
from collections import defaultdict
rows = defaultdict(list)
for line in open(sys.argv[1]):
    if not line.startswith('R '): continue
    f = line.split()
    proj, arm, c, same = f[2], f[3], int(f[4]), f[5]
    d = {}
    m = re.search(r'rss (\d+)', line); d['rss'] = int(m.group(1)) / 1024 if m else None
    m = re.search(r'wall=(\d+)us', line); d['wallx'] = int(m.group(1)) / 1000 if m else None
    for k, v in re.findall(r'(\S+)=([\d.]+)\(', line):
        k = k.replace('cpu_atom/', '').replace('/', '')
        d[k] = float(v)
    if 'duration_time' in d: d['wall'] = d['duration_time'] / 1e6
    d['same'] = same
    rows[(proj, arm, c)].append(d)
def g(rs, k, fn=min):
    v = [r[k] for r in rs if r.get(k) is not None]
    return fn(v) if v else float('nan')
med = st.median
print('| project | arm | C | wall fastest | wall median | task-clock | user Gcyc | kernel Gcyc | Ginstr | user CPI | pgwalk % user | LLC-miss stall % | L2-hit+LLC-hit stall % | dTLB walks M | faults K | RSS MiB | csw | runs |')
print('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
for key in sorted(rows, key=lambda k: (k[0], k[1], k[2])):
    rs = rows[key]
    wk = 'wall' if 'wall' in rs[0] else 'wallx'
    cu = g(rs, 'cyclesu', med); ck = g(rs, 'cyclesk', med); ins = g(rs, 'instructionsu', med)
    pw = g(rs, 'ld_head.pgwalk_at_retu', med); lm = g(rs, 'mem_bound_stalls_load.llc_missu', med)
    lh = g(rs, 'mem_bound_stalls_load.llc_hitu', med) + g(rs, 'mem_bound_stalls_load.l2_hitu', med)
    print(f"| {key[0]} | {key[1]} | {key[2]} | {g(rs, wk):.1f} | {g(rs, wk, med):.1f} | {g(rs,'task-clock',med):.0f} | {cu/1e9:.3f} | {ck/1e9:.3f} | {ins/1e9:.3f} | {cu/ins:.3f} | {100*pw/cu:.2f} | {100*lm/cu:.1f} | {100*lh/cu:.1f} | {g(rs,'dtlb_load_misses.walk_completedu',med)/1e6:.2f} | {g(rs,'page-faults',med)/1e3:.1f} | {g(rs,'rss',med):.0f} | {g(rs,'context-switches',med):.0f} | {len(rs)}{'' if all(r['same']=='same' for r in rs) else ' DIFF'} |")
