#!/usr/bin/env python3
# bench.py ROUNDS CHECKERS PROJECT ARM...: (the Mac; bin/mac/ARM) trig -p tsconfig.trig.json --noEmit,
# one checker (--singleThreaded) when CHECKERS is 1, else --checkers CHECKERS. The arms run in an
# order shuffled each round (seeded by the project). /usr/bin/time -l gives user and system time,
# cycles, instructions and peak RSS. Output and exit status are checked against the first arm's.
# Prints the min and median of each arm against the first arm, and appends raw rows to raw.txt.
import os, sys, subprocess, re, hashlib, random, statistics as st
S = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
R = int(sys.argv[1]); ck = sys.argv[2]; proj = sys.argv[3]; arms = sys.argv[4:]
cwd = f"{S}/empty" if proj == "empty" else os.path.expanduser(f"~/Data/Code/trig/misc/projects/{proj}")
flags = ["--singleThreaded"] if ck == "1" else ["--checkers", ck]
res = {a: [] for a in arms}; ref = {}
rng = random.Random(f"{proj}-{ck}")
raw = open(f"{S}/data/raw.txt", "a")
for r in range(R):
    order = arms[:]; rng.shuffle(order)
    for a in order:
        p = subprocess.run(["/usr/bin/time", "-l", f"{S}/bin/mac/{a}", "-p", "tsconfig.trig.json", "--noEmit", *flags], cwd=cwd, capture_output=True)
        err = p.stderr.decode()
        h = hashlib.md5(p.stdout + bytes([p.returncode & 255])).hexdigest()
        ref.setdefault('x', h)
        if h != ref['x']: print("OUTPUT DIFFERS", a, r, flush=True)
        g = lambda pat: float(re.search(pat, err).group(1))
        row = (g(r"([\d.]+) user"), g(r"([\d.]+) sys"), g(r"([\d.]+) real"), g(r"(\d+)\s+cycles elapsed"), g(r"(\d+)\s+instructions retired"), g(r"(\d+)\s+maximum resident"))
        res[a].append(row)
        raw.write(f"{proj} c{ck} r{r} {a} " + " ".join(f"{x:g}" for x in row) + "\n")
b = arms[0]
def stat(a, i, f): return f([x[i] for x in res[a]])
for a in arms:
    line = f"{proj:12s} c{ck} {a:9s}"
    for name, i in (("user", 0), ("sys", 1), ("wall", 2), ("cycles", 3), ("instr", 4), ("rss", 5)):
        mn, md = stat(a, i, min), stat(a, i, st.median)
        bmn, bmd = stat(b, i, min), stat(b, i, st.median)
        line += f" | {name} min {mn:.4g} ({(mn/bmn-1)*100 if bmn else 0:+.2f}%) med {md:.4g} ({(md/bmd-1)*100 if bmd else 0:+.2f}%)"
    print(line, flush=True)
