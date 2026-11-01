#!/usr/bin/env python3
# bench.py ROUNDS PROJECT ARM...: (the Mac; bin/mac/ARM) trig -p tsconfig.trig.json --noEmit --singleThreaded on
# misc/projects/PROJECT, the arms rotated each round (the first arm moves each round);
# cycles and instructions from /usr/bin/time -l (user and kernel), user time, peak RSS;
# output and exit status checked against the first arm's. Prints min and median.
import os, sys, subprocess, re, hashlib, statistics as st
S = os.path.dirname(os.path.abspath(__file__))
R = int(sys.argv[1]); proj = sys.argv[2]; arms = sys.argv[3:]
cwd = os.path.expanduser(f"~/Data/Code/trig/misc/projects/{proj}")
res = {a: [] for a in arms}; ref = {}
for r in range(R):
    for k in range(len(arms)):
        a = arms[(k + r) % len(arms)]
        p = subprocess.run(["/usr/bin/time", "-l", f"{S}/bin/mac/{a}", "-p", "tsconfig.trig.json", "--noEmit", "--singleThreaded"],
                           cwd=cwd, capture_output=True)
        err = p.stderr.decode()
        h = hashlib.md5(p.stdout + bytes([p.returncode & 255])).hexdigest()
        ref.setdefault('x', h)
        if h != ref['x']: print("OUTPUT DIFFERS", a, r, flush=True)
        g = lambda pat: float(re.search(pat, err).group(1))
        res[a].append((g(r"([\d.]+) user"), g(r"([\d.]+) real"), g(r"(\d+)\s+cycles elapsed"), g(r"(\d+)\s+instructions retired"), g(r"(\d+)\s+maximum resident")))
b = arms[0]
def stat(a, i, f): return f([x[i] for x in res[a]])
for a in arms:
    line = f"{proj:10s} {a:6s}"
    for name, i in (("user", 0), ("wall", 1), ("cycles", 2), ("instr", 3)):
        mn, md = stat(a, i, min), stat(a, i, st.median)
        bmn, bmd = stat(b, i, min), stat(b, i, st.median)
        line += f" | {name} min {mn:.4g} ({(mn/bmn-1)*100:+.2f}%) med {md:.4g} ({(md/bmd-1)*100:+.2f}%)"
    line += f" | rss med {stat(a, 4, st.median)/1e6:.1f}MB"
    print(line, flush=True)
