# ehab.py AB.TXT: per project and checker count, the fastest and median of each time.
import sys, re, collections, statistics as st
d = collections.defaultdict(list)
for l in open(sys.argv[1]):
    m = re.search(r'proj=(\S+) c=(\d+) arm=(\w+) exitwatch at-exit ([\d.]+) reaped ([\d.]+) rss-at-exit (\d+)', l)
    if m: d[(m[1], int(m[2]), m[3])].append((float(m[4]), float(m[5]), int(m[6])))
print('| project | C | plain: reaped, fastest / median | watched: reaped | watched: at exit | exit (reaped less at exit), median | RSS at exit, MiB |')
print('|---|---:|---|---|---|---|---|')
for proj in ('ts-pattern', 'zod3'):
    for c in (1, 4, 8):
        p = [x[1] for x in d[(proj, c, 'plain')]]; w = d[(proj, c, 'watch')]
        if not p or not w: continue
        we = [x[0] for x in w]; wr = [x[1] for x in w]; ex = [x[1] - x[0] for x in w]; rss = [x[2] / 1024 for x in w]
        print(f'| {proj} | {c} | {min(p):.1f} / {st.median(p):.1f} | {min(wr):.1f} / {st.median(wr):.1f} | {min(we):.1f} / {st.median(we):.1f} | {st.median(ex):.1f} | {st.median(rss):.0f} |  (n={len(p)},{len(w)})')
