#!/usr/bin/env python3
# latp0.py DATA...: load-latency samples: share (count, latency-weighted) whose address is on page 0 of a 2 MiB window,
# split by level.
import subprocess, sys, collections
n = collections.Counter(); w = collections.Counter(); N = W = 0
for d in sys.argv[1:]:
    out = subprocess.run(["perf", "script", "-i", d, "-F", "addr,data_src,weight"], capture_output=True, text=True).stdout
    for l in out.splitlines():
        if "|OP" not in l: continue
        parts = l.split("|"); addr = int(parts[0].split()[0], 16); wt = int(parts[-1].split()[-1])
        if addr >= 0xffff800000000000: continue
        lvl = next((p for p in parts if p.startswith("LVL")), "LVL ?")
        tlb = next((p for p in parts if p.startswith("TLB")), "")
        p0 = ((addr >> 12) & 511) == 0
        k = ("p0" if p0 else "p>0", lvl)
        n[k] += 1; w[k] += wt; N += 1; W += wt
print(f"samples {N}, weight {W}")
for k in sorted(n, key=lambda k: -w[k])[:12]: print(f"  {k[0]:4} {k[1]:24} {100*n[k]/N:5.1f}% of loads  {100*w[k]/W:5.1f}% of latency")
p0w = sum(v for k, v in w.items() if k[0] == "p0"); p0n = sum(v for k, v in n.items() if k[0] == "p0")
print(f"page 0 of a 2 MiB window: {100*p0n/N:.1f}% of sampled loads, {100*p0w/W:.1f}% of their latency (uniform 0.2%)")
