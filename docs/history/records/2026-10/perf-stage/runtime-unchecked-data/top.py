#!/usr/bin/env python3
"""top.py BIN DIS IPS KEYRE N: the N hottest ips whose innermost runtime frame function matches KEYRE, with disassembly around each."""
import sys, subprocess, re
binp, disp, ipsp, keyre, N = sys.argv[1], sys.argv[2], sys.argv[3], re.compile(sys.argv[4]), int(sys.argv[5])
ips = [(int(n), ip) for n, ip in (l.split() for l in open(ipsp))]
p = subprocess.run(["addr2line", "-i", "-f", "-C", "-a", "-e", binp], input="\n".join(ip for _, ip in ips) + "\n", capture_output=True, text=True)
frames = {}; cur = None; L = p.stdout.split("\n"); i = 0
while i < len(L):
    if L[i].startswith("0x"): cur = int(L[i], 16); frames[cur] = []; i += 1; continue
    if cur is not None and i + 1 < len(L): frames[cur].append((L[i], L[i + 1])); i += 2; continue
    i += 1
RT = re.compile(r"/rig/(runtime|alloc|table|sched|tasks|net)\.zig:(\d+)")
hits = []
for n, ip in ips:
    for fn, loc in frames.get(int(ip, 16), []):
        if RT.search(loc):
            if keyre.search(fn): hits.append((n, int(ip, 16), fn.split("(")[0], RT.search(loc).group(0), frames[int(ip,16)][-1][0].split("(")[0]))
            break
hits.sort(reverse=True)
dis = open(disp).read().split("\n")
idx = {}
for j, l in enumerate(dis):
    m = re.match(r"^\s*([0-9a-f]+):", l)
    if m: idx[int(m.group(1), 16)] = j
for n, a, fn, loc, outer in hits[:N]:
    print(f"== {n} {hex(a)} {fn} {loc} in {outer}")
    j = idx.get(a)
    if j is not None: print("\n".join(dis[max(0, j - 8): j + 8]))
