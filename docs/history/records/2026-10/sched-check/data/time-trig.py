#!/usr/bin/env python3
"""Interleaved Trig timing for the sched-check study, fastest of N.
usage: time-trig.py ROUNDS OUT.md NAME=TRIG ...   (the first NAME is the reference)
Each run: trig -p tsconfig.trig.json --noEmit in misc/projects/<p>, under
/usr/bin/time -l (instructions retired, cycles elapsed). Outputs must agree."""
import os, re, subprocess, sys, time
PROJECTS = os.environ.get("TRIG_PROJECTS", "ts-pattern,zod3").split(",")
PDIR = os.path.expanduser("~/Data/Code/trig/misc/projects")
def timed(exe, d):
    t = time.perf_counter()
    p = subprocess.run(["/usr/bin/time", "-l", exe, "-p", "tsconfig.trig.json", "--noEmit"] + os.environ.get("TRIG_ARGS", "").split(), cwd=d, capture_output=True, text=True)
    w = time.perf_counter() - t
    g = lambda pat: int(re.search(pat, p.stderr).group(1))
    return w, g(r"(\d+)\s+instructions retired"), g(r"(\d+)\s+cycles elapsed"), g(r"(\d+)\s+maximum resident"), p
rounds, out, specs = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
names = [s.split("=", 1)[0] for s in specs]; exe = dict(s.split("=", 1) for s in specs)
ref = {}
for proj in PROJECTS:
    d = os.path.join(PDIR, proj)
    for n in names:
        p = timed(exe[n], d)[4]
        o = (p.returncode, p.stdout, p.stderr[:p.stderr.find("real")] if False else "\n".join(l for l in p.stderr.splitlines() if not re.match(r"\s+[\d.]+ ", l)))
        if proj not in ref: ref[proj] = o
        elif o != ref[proj]: sys.exit("%s prints differently under %s" % (proj, n))
best = {}; raw = open(out + ".raw", "w")
# A round counts only when the 1-minute load is under LOAD_MAX before and
# after it (other sessions share the Mac); it waits for that, up to an hour.
LOAD_MAX = float(os.environ.get("LOAD_MAX", "1e9"))
kept = 0; r = 0; t_end = time.time() + 3600
while kept < rounds and time.time() < t_end:
    while os.getloadavg()[0] >= LOAD_MAX and time.time() < t_end: time.sleep(5)
    lines = []
    for proj in PROJECTS:
        d = os.path.join(PDIR, proj)
        order = names if r % 2 == 0 else names[::-1]
        for n in order:
            w, i, c, m, _ = timed(exe[n], d)
            lines.append((proj, n, w, i, c, m))
    r += 1
    if os.getloadavg()[0] >= LOAD_MAX: continue
    kept += 1
    for (proj, n, w, i, c, m) in lines:
        raw.write("%d\t%s\t%s\t%.4f\t%d\t%d\t%d\n" % (kept, proj, n, w, i, c, m)); raw.flush()
        k = (proj, n)
        if k not in best or w < best[k][0]: best[k] = (w, i, c, m)
    print("round %d of %d kept (%d run)" % (kept, rounds, r), file=sys.stderr, flush=True)
def pct(a, b, up="faster", down="slower"):
    s = a / b
    return "%.1f%% %s" % (((s - 1) if s >= 1 else (1 / s - 1)) * 100, up if s >= 1 else down)
with open(out, "w") as f:
    f.write("| project | variant | wall (fastest of %d) | against %s | instructions | cycles (of fastest) | peak RSS |\n|---|---|---:|---|---:|---:|---:|\n" % (rounds, names[0]))
    for proj in PROJECTS:
        a = best[(proj, names[0])]
        for n in names:
            b = best[(proj, n)]
            f.write("| %s | %s | %.1f ms | %s | %.3fG (%s) | %.3fG | %.0f MB |\n" % (proj, n, b[0] * 1e3, "" if n == names[0] else pct(a[0], b[0]),
                    b[1] / 1e9, "" if n == names[0] else pct(a[1], b[1], "fewer", "more"), b[2] / 1e9, b[3] / 2**20))
print(open(out).read())
