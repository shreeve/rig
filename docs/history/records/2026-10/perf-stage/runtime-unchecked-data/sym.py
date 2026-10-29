#!/usr/bin/env python3
"""sym.py BIN IPS OUT: each sampled ip's inline frames (addr2line -i),
attributed to the innermost frame in the runtime's own Zig (rig/*.zig but
ordered/unordered), as 'file:function'; else 'user'. Writes OUT as
'samples key' lines, most first, and the line-level 'samples file:line fn'."""
import sys, subprocess, collections, re
binp, ipsp, outp = sys.argv[1:4]
ips = []
for l in open(ipsp):
    n, ip = l.split(); ips.append((int(n), ip))
p = subprocess.run(["addr2line", "-i", "-f", "-C", "-a", "-e", binp], input="\n".join(ip for _, ip in ips) + "\n",
                   capture_output=True, text=True)
frames = {}; cur = None; lines = p.stdout.split("\n"); i = 0
while i < len(lines):
    l = lines[i]
    if l.startswith("0x"):
        cur = int(l, 16); frames[cur] = []; i += 1; continue
    if cur is not None and i + 1 < len(lines):
        frames[cur].append((l, lines[i + 1])); i += 2; continue
    i += 1
RT = re.compile(r"/rig/(runtime|alloc|table|sched|tasks|net)\.zig:(\d+)")
by = collections.Counter(); byline = collections.Counter(); tot = 0
for n, ip in ips:
    tot += n
    fr = frames.get(int(ip, 16), [])
    key = "user " + (re.sub(r"__(func|anon)_\d+", "", fr[-1][0].split("(")[0]) if fr else "?"); lk = None
    for fn, loc in fr:
        m = RT.search(loc)
        if m:
            key = f"{m.group(1)}:" + re.sub(r"__(func|anon)_\d+", "", fn.split('(')[0]); lk = f"{m.group(1)}:{m.group(2)} {fn.split('(')[0]}"; break
    by[key] += n
    if lk: byline[lk] += n
with open(outp, "w") as f:
    f.write(f"# total {tot}\n")
    for k, n in by.most_common(): f.write(f"{n} {k}\n")
with open(outp + ".lines", "w") as f:
    for k, n in byline.most_common(400): f.write(f"{n} {k}\n")
