#!/usr/bin/env python3
# smaps-peak.py OUT -- CMD...: runs CMD, polls /proc/PID/smaps every few ms and keeps the snapshot with the largest
# total Rss; writes Rss by mapping path (file-backed pages: the binary's text and data, shared libraries) to OUT.
import sys, subprocess, time, collections

out = sys.argv[1]
cmd = sys.argv[3:]
p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
best, best_rss = None, -1
while p.poll() is None:
    try:
        txt = open(f'/proc/{p.pid}/smaps').read()
    except Exception:
        break
    rss, cur, rows = 0, None, collections.defaultdict(lambda: [0, 0])
    for l in txt.split('\n'):
        f = l.split()
        if not f:
            continue
        if '-' in f[0] and len(f) >= 5 and all(c in '0123456789abcdef-' for c in f[0]):
            path = f[5] if len(f) >= 6 else '[anon]'
            cur = (path, f[1])
        elif f[0] == 'Rss:' and cur:
            v = int(f[1])
            rss += v
            rows[cur][0] += v
        elif f[0] == 'AnonHugePages:' and cur:
            rows[cur][1] += int(f[1])
    if rss > best_rss:
        best_rss, best = rss, rows
    time.sleep(0.002)
p.wait()
with open(out, 'w') as o:
    o.write(f'# peak sampled total Rss {best_rss} kB; exit {p.returncode}\n')
    for (path, perms), (r, h) in sorted(best.items(), key=lambda kv: -kv[1][0]):
        if r:
            o.write(f'{r}\t{h}\t{perms}\t{path}\n')
