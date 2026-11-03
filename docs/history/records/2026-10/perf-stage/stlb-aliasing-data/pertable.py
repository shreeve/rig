#!/usr/bin/env python3
# pertable.py SCAN DATA...: group the Tables region's touched windows into Tables (runs of touched windows),
# and count STLB-miss samples per Table.
import re, subprocess, sys, collections
H = 2 << 20
win = {}
for l in open(sys.argv[1]):
    w = l.split()
    if w[0] == "W": a = int(w[1], 16) // H * H; win[a] = win.get(a, 0) + int(w[2])
region = None; samples = []; tot = 0
for d in sys.argv[2:]:
    out = subprocess.run(["perf", "script", "-i", d, "--show-mmap-events", "-F", "pid,addr"], capture_output=True, text=True).stdout
    for l in out.splitlines():
        m = re.search(r"MMAP2? \d+/\d+: \[(0x[0-9a-f]+)\((0x4000200000)\)", l)
        if m: region = (int(m[1], 16), int(m[1], 16) + 0x4000200000); continue
        if "MMAP" in l: continue
        w = l.split()
        try: addr = int(w[1], 16)
        except (ValueError, IndexError): continue
        tot += 1
        if region and region[0] <= addr < region[1]: samples.append(addr)
ws = sorted(a for a in win if region[0] <= a < region[1])
tables = []  # [start, end, resident pages]
for a in ws:
    if tables and tables[-1][1] == a: tables[-1][1] = a + H; tables[-1][2] += win[a]
    else: tables.append([a, a + H, win[a]])
cnt = collections.Counter()
for s in samples:
    for i, t in enumerate(tables):
        if t[0] <= s < t[1] + (64 << 20): cnt[i] += 1; break
print(f"samples {tot}, in Tables {len(samples)} ({100*len(samples)/tot:.1f}%), tables {len(tables)}")
acc = 0
print(" idx  offset-GiB  resident-MiB  windows  miss%  cum%  miss-per-MiB")
for i, c in cnt.most_common(25):
    t = tables[i]; acc += c
    mib = t[2] * 4 / 1024
    print(f"{i:4} {(t[0]-region[0])/(1<<30):10.2f} {mib:12.2f} {(t[1]-t[0])//H:8} {100*c/tot:6.1f} {100*acc/tot:5.1f} {c/max(mib,0.01):8.1f}")
small = [i for i, t in enumerate(tables) if t[2] < 512]
print(f"tables under 2 MiB: {len(small)}, resident {sum(tables[i][2] for i in small)*4/1024:.1f} MiB, miss share {100*sum(cnt[i] for i in small)/tot:.1f}%")
