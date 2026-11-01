#!/usr/bin/env python3
# summ.py FILE [BASE]: medians per project and arm from ab.sh lines, and
# each arm against BASE (main, or main4 for the four-checker arms): the
# median of the per-round ratios, with the 25th and 75th percentiles.
import sys, statistics as st, collections
rows = collections.defaultdict(lambda: collections.defaultdict(dict))
order = []
for line in open(sys.argv[1]):
    if line.startswith('#') or 'round=' not in line: continue
    w = line.split(); proj = w[0]
    d = dict(x.split('=', 1) for x in w[1:] if '=' in x)
    r, v = int(d['round']), d['v']
    if v not in order: order.append(v)
    rows[proj][v][r] = d
def num(d, k):
    try: return float(d[k])
    except: return None
K = [('duration_time', 'wall', 1e-6), ('cyclesu', 'cyc u', 1e-6), ('cyclesk', 'cyc k', 1e-6),
     ('instructionsu', 'ins u', 1e-6), ('instructionsk', 'ins k', 1e-6), ('page-faults', 'faults', 1),
     ('rss_kb', 'rss MB', 1/1000), ('thp', 'thp', 1)]
def q(xs, p):
    xs = sorted(xs); i = (len(xs) - 1) * p; lo = int(i); hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (i - lo)
def pct(x):
    return f'{(x - 1) * 100:+.2f}%'
for proj, arms in rows.items():
    print(f'== {proj}')
    print('arm'.ljust(7) + ''.join(n.rjust(11) for _, n, _ in K) + '   free2m  gate%  cstall same')
    for v in order:
        if v not in arms: continue
        rs = arms[v]
        cells = []
        for k, n, s in K:
            xs = [num(d, k) for d in rs.values() if num(d, k) is not None]
            cells.append(f'{st.median(xs) * s:11.2f}' if xs else ' ' * 11)
        f2 = [num(d, 'free2m') for d in rs.values()]
        g = sum(1 for d in rs.values() if d.get('gate') == '1') / len(rs) * 100
        cs = sum(int(d.get('cstall', 0)) for d in rs.values())
        same = all(d.get("same") == "1" for d in rs.values()) and len({d.get("exit") for d in rs.values()}) == 1
        print(v.ljust(7) + ''.join(cells) + f'   {min(f2):.0f}-{max(f2):.0f} {g:5.0f}% {cs:6d} {"yes" if same else "NO"}')
    print('vs base, median of per-round ratios [25th, 75th]:')
    for v in order:
        if v not in arms: continue
        base = 'main4' if v.endswith('4') else 'main'
        if v == base or base not in arms: continue
        out = []
        for k, n, _ in K[:7]:
            rr = [num(arms[v][r], k) / num(arms[base][r], k) for r in arms[v] if r in arms[base] and num(arms[base][r], k)]
            if rr: out.append(f'{n} {pct(st.median(rr))} [{pct(q(rr, .25))}, {pct(q(rr, .75))}]')
        print(f'  {v:6} ' + '; '.join(out))
