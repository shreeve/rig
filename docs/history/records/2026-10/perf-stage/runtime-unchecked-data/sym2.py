#!/usr/bin/env python3
"""sym2.py BIN IPS OUT: samples by innermost frame file:line and outermost function."""
import sys, subprocess, collections, re, os
binp, ipsp, outp = sys.argv[1:4]
ips = [(int(n), ip) for n, ip in (l.split() for l in open(ipsp))]
p = subprocess.run(["addr2line", "-i", "-f", "-C", "-a", "-e", binp], input="\n".join(ip for _, ip in ips) + "\n", capture_output=True, text=True)
frames = {}; cur = None; L = p.stdout.split("\n"); i = 0
while i < len(L):
    if L[i].startswith("0x"): cur = int(L[i], 16); frames[cur] = []; i += 1; continue
    if cur is not None and i + 1 < len(L): frames[cur].append((L[i], L[i + 1])); i += 2; continue
    i += 1
c = collections.Counter()
for n, ip in ips:
    fr = frames.get(int(ip, 16), [])
    if not fr: c["?"] += n; continue
    outer = re.sub(r"__(func|anon)_\d+", "", fr[-1][0].split("(")[0])
    loc = fr[0][1].split(" ")[0]; loc = "/".join(loc.split("/")[-2:])
    c[f"{loc}|{outer}"] += n
with open(outp, "w") as f:
    f.write(f"# total {sum(c.values())}\n")
    for k, n in c.most_common(): f.write(f"{n} {k}\n")
