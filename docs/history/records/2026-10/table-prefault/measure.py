#!/usr/bin/env python3
"""measure.py ROUNDS NAME ...: each trig build (T/b/NAME/bin) on copies of
ts-pattern and zod3, at one checker (core 8, sibling 9 idle) and at four
(cores 0-2,5,8-21), interleaved. Each run under perf stat (cycles:k,
cycles:u, instructions:u, page-faults) and /usr/bin/time (peak RSS).
Per case: fastest wall, least kernel cycles, least user cycles, median
user instructions, median faults, median RSS."""
import os, re, subprocess, sys, statistics, json, time
T = "/zfs/worktrees/rig/table-prefault"
PROJ = ["ts-pattern", "zod3"]
rounds = int(sys.argv[1]); names = sys.argv[2:]
MODES = [("1", ["taskset", "-c", "8"], ["--checkers", "1"]),
         ("4", ["taskset", "-c", os.environ.get("CPUS4", "0-2,5,8-21")], ["--checkers", "4"])]
data = {}
outs = {}
def one(exe, proj, pin, extra):
    ev = "cycles:k,cycles:u,instructions:u,page-faults"
    cmd = ["perf", "stat", "--no-scale", "-x", ",", "-e", ev, "--", "/usr/bin/time", "-f", "TIME %M %e"] + pin + [exe, "-p", "tsconfig.trig.json", "--noEmit"] + extra
    t0 = time.perf_counter()
    p = subprocess.run(cmd, cwd=os.path.join(T, "projects", proj), capture_output=True, text=True)
    t1 = time.perf_counter() - t0
    e = p.stderr
    m = re.search(r"TIME (\d+) ([\d.]+)", e)
    rss, wall = int(m.group(1)), t1
    c = {}
    for line in e.splitlines():
        f = line.split(",")
        if len(f) < 4: continue
        try: v = int(f[0])
        except ValueError: continue
        k = f[2]
        mm = re.match(r"cpu_(?:core|atom)/(\w+)/(\w)", k)
        if mm: k = mm.group(1) + ":" + mm.group(2)
        c[k] = c.get(k, 0) + v
    return wall, rss, c, p.stdout
for r in range(rounds):
    for proj in PROJ:
        for mode, pin, extra in MODES:
            for name in names:
                w, rss, c, out = one(os.path.join(T, "b", name, "bin"), proj, pin, extra)
                k = (proj, mode)
                if k in outs and outs[k] != out: sys.exit("outputs differ: %s %s %s" % (proj, mode, name))
                outs[k] = out
                data.setdefault("%s|%s|%s" % (proj, mode, name), []).append([w, rss, c])
    print("round %d" % (r + 1), file=sys.stderr, flush=True)
json.dump(data, open(os.path.join(T, "measure-%d.json" % os.getpid()), "w"))
def key(c, *ks):
    for k in ks:
        for kk in c:
            if kk.startswith(k): return c[kk]
    return 0
print("| project | checkers | build | wall s | kernel cycles | user cycles | user instr | faults | RSS MB |")
print("|---|---|---|---:|---:|---:|---:|---:|---:|")
for proj in PROJ:
    for mode, _, _ in MODES:
        for name in names:
            xs = data["%s|%s|%s" % (proj, mode, name)]
            w = min(x[0] for x in xs)
            kc = min(key(x[2], "cycles:k") for x in xs)
            uc = min(key(x[2], "cycles:u") for x in xs)
            ui = statistics.median(key(x[2], "instructions:u") for x in xs)
            pf = statistics.median(key(x[2], "page-faults") for x in xs)
            rss = statistics.median(x[1] for x in xs)
            print("| %s | %s | %s | %.3f | %.3fG | %.3fG | %.3fG | %d | %.0f |" % (proj, mode, name, w, kc / 1e9, uc / 1e9, ui / 1e9, pf, rss / 1024))
