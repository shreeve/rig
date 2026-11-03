#!/usr/bin/env python3
# join.py SCAN DATA...: STLB-miss samples in the Tables region, by the window's residency at the scan.
import re, subprocess, sys, collections
H = 2 << 20
win = {}; vmas = []
for l in open(sys.argv[1]):
    w = l.split()
    if w[0] == "W": win[int(w[1], 16) // H * H] = win.get(int(w[1], 16) // H * H, 0) + int(w[2])
    elif w[0] == "V": vmas.append((int(w[1], 16), int(w[2], 16), int(w[3]), int(w[4])))
region = None; byclass = collections.Counter(); tot = 0
first = set()
for d in sys.argv[2:]:
    out = subprocess.run(["perf", "script", "-i", d, "--show-mmap-events", "-F", "pid,addr,data_page_size"], capture_output=True, text=True).stdout
    for l in out.splitlines():
        m = re.search(r"MMAP2? \d+/\d+: \[(0x[0-9a-f]+)\((0x4000200000)\)", l)
        if m: region = (int(m[1], 16), int(m[1], 16) + 0x4000200000); continue
        if "MMAP" in l: continue
        w = l.split()
        if len(w) < 3: continue
        try: addr = int(w[1], 16)
        except ValueError: continue
        tot += 1
        if not region or not (region[0] <= addr < region[1]): byclass["not tables"] += 1; continue
        wa = addr // H * H; c = win.get(wa, 0)
        isfirst = win.get(wa - H, 0) == 0
        kind = "full" if c == 512 else ("empty-at-scan" if c == 0 else "partial")
        byclass[(kind, "first" if isfirst else "later", w[2])] += 1
print(f"samples {tot}")
for k, v in sorted(byclass.items(), key=lambda x: -x[1]): print(f"  {str(k):40} {v:6} {100*v/tot:5.1f}%")
# window census in the tables region
if region:
    ws = {a: c for a, c in win.items() if region[0] <= a < region[1]}
    full = sum(1 for c in ws.values() if c == 512); part = [c for c in ws.values() if c < 512]
    firsts = [a for a in ws if ws.get(a - H, 0) == 0]
    fp = [ws[a] for a in firsts if ws[a] < 512]
    print(f"tables region windows: {len(ws)} touched, {full} full ({full*2} MiB), {len(part)} partial holding {sum(part)*4/1024:.1f} MiB (would cost {(len(part)*512-sum(part))*4/1024:.1f} MiB more as huge); first windows {len(firsts)} ({len(fp)} partial)")
