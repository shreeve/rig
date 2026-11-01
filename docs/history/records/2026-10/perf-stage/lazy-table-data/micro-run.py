#!/usr/bin/env python3
# run.py ROUNDS ARM...: ARM/pushloop under /usr/bin/time -l, arms shuffled each round; min and median
# of user time, cycles and instructions against the first arm.
import sys, subprocess, re, random, statistics as st, os
D = os.path.dirname(os.path.abspath(__file__))
R = int(sys.argv[1]); arms = sys.argv[2:]; res = {a: [] for a in arms}; rng = random.Random(1)
for r in range(R):
    o = arms[:]; rng.shuffle(o)
    for a in o:
        p = subprocess.run(["/usr/bin/time", "-l", f"{D}/{a}/pushloop"], capture_output=True); e = p.stderr.decode()
        g = lambda pat: float(re.search(pat, e).group(1))
        res[a].append((g(r"([\d.]+) user"), g(r"(\d+)\s+cycles elapsed"), g(r"(\d+)\s+instructions retired")))
b = arms[0]
for a in arms:
    line = f"{a:6s}"
    for n, i in (("user", 0), ("cycles", 1), ("instr", 2)):
        mn, md = min(x[i] for x in res[a]), st.median(x[i] for x in res[a])
        bmn, bmd = min(x[i] for x in res[b]), st.median(x[i] for x in res[b])
        line += f" | {n} min {mn:.4g} ({(mn/bmn-1)*100:+.2f}%) med {md:.4g} ({(md/bmd-1)*100:+.2f}%)"
    print(line)
