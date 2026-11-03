#!/usr/bin/env python3
# setconf.py DATA...: STLB-miss samples by page index within the 2 MiB window, in and out of the Tables region,
# and by STLB set for set counts 128/256 (page index mod sets).
import re, subprocess, sys, collections
B = [(0,1),(1,2),(2,8),(8,32),(32,128),(128,512)]
c_in = collections.Counter(); c_out = collections.Counter(); pages_in = collections.Counter(); tin = tout = 0
mod128 = collections.Counter()
for d in sys.argv[1:]:
    out = subprocess.run(["perf", "script", "-i", d, "--show-mmap-events", "-F", "pid,addr"], capture_output=True, text=True).stdout
    region = None
    for l in out.splitlines():
        m = re.search(r"MMAP2? \d+/\d+: \[(0x[0-9a-f]+)\((0x4000200000)\)", l)
        if m: region = (int(m[1], 16), int(m[1], 16) + 0x4000200000); continue
        if "MMAP" in l: continue
        w = l.split()
        try: addr = int(w[1], 16)
        except (ValueError, IndexError): continue
        if addr >= 0xffff800000000000: continue
        pi = (addr >> 12) & 511
        b = next(i for i, (lo, hi) in enumerate(B) if lo <= pi < hi)
        if region and region[0] <= addr < region[1]: c_in[b] += 1; tin += 1; mod128[(addr >> 12) & 127] += 1
        else: c_out[b] += 1; tout += 1
print(f"{'page index in 2MiB window':28} {'Tables miss%':>12} {'other miss%':>12} {'uniform%':>9}")
for i, (lo, hi) in enumerate(B):
    print(f"{f'{lo}..{hi-1}':28} {100*c_in[i]/max(tin,1):12.1f} {100*c_out[i]/max(tout,1):12.1f} {100*(hi-lo)/512:9.1f}")
top = mod128.most_common(4)
print(f"Tables misses {tin}; by page index mod 128, top sets: " + ", ".join(f"{k}:{100*v/tin:.1f}%" for k, v in top) + f" (uniform {100/128:.2f}%)")
