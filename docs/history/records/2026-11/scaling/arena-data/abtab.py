# abtab.py AB.TXT BASE: per project and C, each arm's fastest and median wall, cycles, instructions, faults, RSS, against BASE.
import sys, re, statistics as st
from collections import defaultdict
rows = defaultdict(list)
for line in open(sys.argv[1]):
    if not line.startswith('R '): continue
    f = line.split(); d = {'same': f[5]}
    m = re.search(r'rss (\d+)', line); d['rss'] = int(m.group(1)) / 1024
    for k, v in re.findall(r'(\S+)=([\d.]+)\(', line): d[k.replace('cpu_atom/', '').replace('/', '')] = float(v)
    rows[(f[2], int(f[4]), f[3])].append(d)
base = sys.argv[2]
def g(rs, k, fn): return fn([r[k] for r in rs])
print('| project | C | arm | wall fastest ms | wall median | cycles (u+k) G | kernel G | instr G | pgwalk % | faults K | RSS MiB median | runs |')
print('|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
keys = sorted(rows)
for k in keys:
    rs = rows[k]; b = rows.get((k[0], k[1], base))
    w = g(rs, 'duration_time', min) / 1e6; wm = g(rs, 'duration_time', st.median) / 1e6
    cyc = (g(rs, 'cyclesu', st.median) + g(rs, 'cyclesk', st.median)) / 1e9
    def rel(x, key, fn, scale):
        if k[2] == base or not b: return ''
        y = g(b, key, fn) / scale
        return f' ({100*(x/y-1):+.1f}%)'
    print(f"| {k[0]} | {k[1]} | {k[2]} | {w:.1f}{rel(w,'duration_time',min,1e6)} | {wm:.1f}{rel(wm,'duration_time',st.median,1e6)} | {cyc:.3f} | {g(rs,'cyclesk',st.median)/1e9:.3f} | {g(rs,'instructionsu',st.median)/1e9:.3f} | {100*g(rs,'ld_head.pgwalk_at_retu',st.median)/g(rs,'cyclesu',st.median):.2f} | {g(rs,'page-faults',st.median)/1e3:.1f} | {g(rs,'rss',st.median):.0f}{rel(g(rs,'rss',st.median),'rss',st.median,1)} | {len(rs)}{'' if all(r['same']=='same' for r in rs) else ' DIFF'} |")
