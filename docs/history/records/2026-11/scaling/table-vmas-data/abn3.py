# abn3.py OUT: per project, checker count and arm: fastest and median wall (stat), median
# task-clock and peak RSS, and the median exit (watch: reaped less at-exit).
import sys, re, collections, statistics as st
W = collections.defaultdict(list); S = collections.defaultdict(list)
for l in open(sys.argv[1]):
    m = re.match(r'r=\d+ arm=(\S+) proj=(\S+) c=(\d+) how=(\w+) (.*)', l)
    if not m: continue
    k = (m[2], int(m[3]), m[1]); rest = m[5]
    if m[4] == 'watch':
        e = re.search(r'at-exit ([\d.]+) reaped ([\d.]+)', rest)
        if e: W[k].append((float(e[1]), float(e[2])))
    else:
        tc = re.search(r'([\d.]+),msec,task-clock', rest); du = re.search(r'(\d+),[^,]*,duration_time', rest); rs = re.search(r'maxrss (\d+)', rest); ins = re.search(r'(\d+),[^,]*,cpu_atom/instructions/', rest)
        if tc and du and rs: S[k].append((int(du[1]) / 1e6, float(tc[1]), int(rs[1]) / 1024, int(ins[1]) / 1e9 if ins else float('nan')))
print('| project | C | arm | wall fastest | wall median | task-clock median | instructions median, G | peak RSS median, MiB | exit median | n |')
print('|---|---:|---|---:|---:|---:|---:|---:|---:|---:|')
for k in sorted(S):
    s = S[k]; w = W.get(k, [])
    ex = st.median([b - a for a, b in w]) if w else float('nan')
    print(f'| {k[0]} | {k[1]} | {k[2]} | {min(x[0] for x in s):.1f} | {st.median([x[0] for x in s]):.1f} | {st.median([x[1] for x in s]):.1f} | {st.median([x[3] for x in s]):.3f} | {st.median([x[2] for x in s]):.0f} | {ex:.1f} | {len(s)},{len(w)} |')
