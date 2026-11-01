#!/usr/bin/env python3
"""time-mac.py ROUNDS OUT NAME=TRIG...: interleaved Trig runs on the Mac,
one checker (--singleThreaded), the order reversing each round, on the
empty project, mitt, ts-pattern and zod3. Each run under /usr/bin/time -l
(instructions retired, cycles elapsed, peak RSS); wall from the parent.
Every run's stdout, stderr (less time's lines) and exit status must equal
the first variant's first run, byte for byte, or the script stops.
A round counts only when the 1-minute load is under LOAD_MAX before and
after it (default 1e9). Raw lines go to OUT.raw; OUT gets fastest and
median per project and variant."""
import os, re, subprocess, sys, time, statistics as st
S = os.path.dirname(os.path.abspath(__file__))
P = os.path.expanduser("~/Data/Code/trig/misc/projects")
PROJ = [("empty", os.path.join(S, "empty"))] + [(p, os.path.join(P, p)) for p in ("mitt", "ts-pattern", "zod3")]
PROJ = [x for x in PROJ if x[0] in os.environ.get("PROJECTS", "empty,mitt,ts-pattern,zod3").split(",")]
def run(exe, d):
    t = time.perf_counter()
    p = subprocess.run(["/usr/bin/time", "-l", exe, "-p", "tsconfig.trig.json", "--noEmit", "--singleThreaded"], cwd=d, capture_output=True)
    w = time.perf_counter() - t
    err = p.stderr.decode(errors="replace")
    g = lambda pat: int(re.search(pat, err).group(1))
    body = "\n".join(l for l in err.splitlines() if not re.match(r"\s*\d+\s+[a-z]", l) and not re.match(r"\s*[\d.]+ real", l))
    return w, g(r"(\d+)\s+instructions retired"), g(r"(\d+)\s+cycles elapsed"), g(r"(\d+)\s+maximum resident"), (p.returncode, p.stdout, body)
rounds, out, specs = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
names = [s.split("=", 1)[0] for s in specs]; exe = dict(s.split("=", 1) for s in specs)
LOAD_MAX = float(os.environ.get("LOAD_MAX", "1e9"))
ref = {}; data = {}; raw = open(out + ".raw", "a")
kept = r = 0; t_end = time.time() + float(os.environ.get("MAX_S", "7200"))
while kept < rounds and time.time() < t_end:
    while os.path.exists(os.path.expanduser("~/Data/Code/mumps-compare/.mac-quiet")): time.sleep(30)
    while os.getloadavg()[0] >= LOAD_MAX and time.time() < t_end: time.sleep(5)
    lines = []
    for proj, d in PROJ:
        for n in (names if r % 2 == 0 else names[::-1]):
            w, i, c, m, o = run(exe[n], d)
            if proj not in ref: ref[proj] = o
            elif o != ref[proj]: sys.exit("%s: %s prints differently (round %d)" % (proj, n, r))
            lines.append((proj, n, w, i, c, m))
    r += 1
    if os.getloadavg()[0] >= LOAD_MAX: continue
    kept += 1
    for (proj, n, w, i, c, m) in lines:
        raw.write("%d\t%s\t%s\t%.5f\t%d\t%d\t%d\n" % (kept, proj, n, w, i, c, m)); raw.flush()
        data.setdefault((proj, n), []).append((w, i, c, m))
    print("round %d of %d kept (%d run)" % (kept, rounds, r), file=sys.stderr, flush=True)
def pct(a, b, up, down):
    if a == b: return "level"
    s = a / b
    return "%.2f%% %s" % (((s - 1) if s >= 1 else (1 / s - 1)) * 100, up if s >= 1 else down)
with open(out, "w") as f:
    f.write("%d rounds kept of %d run; every run's output identical to %s's\n\n" % (kept, r, names[0]))
    f.write("| project | variant | wall fastest | wall median | vs %s (median) | instructions (min) | vs %s | cycles fastest | cycles median | vs %s (median) | peak RSS median |\n|---|---|---:|---:|---|---:|---|---:|---:|---|---:|\n" % ((names[0],) * 3))
    for proj, _ in PROJ:
        a = data[(proj, names[0])]
        for n in names:
            b = data[(proj, n)]
            col = lambda xs, k: [x[k] for x in xs]
            wm, im, cm = st.median(col(b, 0)), min(col(b, 1)), st.median(col(b, 2))
            aw, ai, ac = st.median(col(a, 0)), min(col(a, 1)), st.median(col(a, 2))
            f.write("| %s | %s | %.2f ms | %.2f ms | %s | %.4fG | %s | %.4fG | %.4fG | %s | %.1f MB |\n" % (
                proj, n, min(col(b, 0)) * 1e3, wm * 1e3, "" if n == names[0] else pct(aw, wm, "faster", "slower"),
                im / 1e9, "" if n == names[0] else pct(ai, im, "fewer", "more"),
                min(col(b, 2)) / 1e9, cm / 1e9, "" if n == names[0] else pct(ac, cm, "fewer", "more"), st.median(col(b, 3)) / 2**20))
print(open(out).read())
