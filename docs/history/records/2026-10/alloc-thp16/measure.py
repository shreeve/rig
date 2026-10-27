#!/usr/bin/env python3
"""measure.py ROUNDS NAME=TRIG ...: each trig on ts-pattern and zod3, at one
checker (core 8, its sibling 9 idle) and at four (cores 6 to 9), interleaved,
the order reversed every other round; per case the fastest wall of ROUNDS
with its user and sys time, the fewest user instructions and page faults,
and peak RSS (median and largest). Outputs must agree."""
import os, re, resource, statistics, subprocess, sys, time
last = resource.getrusage(resource.RUSAGE_CHILDREN)
NOPERF = os.environ.get("NOPERF") == "1"  # wall without perf; faults are minor faults (%R)
PD = "/zfs/trig-pup/full/trig/misc/projects"
PROJ = ["ts-pattern", "zod3"]
rounds = int(sys.argv[1])
specs = [s.split("=", 1) for s in sys.argv[2:]]
MODES = [("1", ["taskset", "-c", "8"], ["--checkers", "1"]), ("4", ["taskset", "-c", "6,7,8,9"], ["--checkers", "4"])]
res = {}
def one(exe, proj, pin, extra):
    cmd = ([] if NOPERF else ["perf", "stat", "-x,", "-e", "instructions:u,page-faults", "--"]) + ["/usr/bin/time", "-f", "TIME %M %R"] + pin + [exe, "-p", "tsconfig.trig.json", "--noEmit"] + extra
    t = time.perf_counter()
    p = subprocess.Popen(cmd, cwd=os.path.join(PD, proj), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, e = p.communicate()
    ru = resource.getrusage(resource.RUSAGE_CHILDREN)
    w = time.perf_counter() - t
    global last
    u, s, rss = ru.ru_utime - last.ru_utime, ru.ru_stime - last.ru_stime, int(re.search(r"TIME (\d+)", e).group(1))
    last = ru
    ins = sum(int(x) for x in re.findall(r"^(\d+),,\S*instructions", e, re.M))
    f = int(re.search(r"TIME \d+ (\d+)", e).group(1)) if NOPERF else int(re.search(r"^(\d+),,page-faults", e, re.M).group(1))
    return dict(w=w, u=u, s=s, ins=ins, f=f, rss=rss), out
outs = {}
for r in range(rounds):
    for proj in PROJ:
        for mode, pin, extra in MODES:
            for name, exe in (specs if r % 2 == 0 else specs[::-1]):
                x, out = one(exe, proj, pin, extra)
                k = (proj, mode)
                if k in outs and outs[k] != out: sys.exit("outputs differ: %s %s %s" % (proj, mode, name))
                outs[k] = out
                res.setdefault((proj, mode, name), []).append(x)
    print("round %d" % (r + 1), file=sys.stderr, flush=True)
print("| project | checkers | build | wall s | user s | sys s | instructions (user) | page faults | RSS MB median | RSS MB max |")
print("|---|---|---|---:|---:|---:|---:|---:|---:|---:|")
for proj in PROJ:
    for mode, _, _ in MODES:
        for name, _ in specs:
            xs = res[(proj, mode, name)]
            b = min(xs, key=lambda x: x["w"])
            print("| %s | %s | %s | %.3f | %.3f | %.3f | %d | %d | %.1f | %.1f |" % (proj, mode, name, b["w"], b["u"], min(x["s"] for x in xs),
                  min(x["ins"] for x in xs), min(x["f"] for x in xs), statistics.median(x["rss"] for x in xs) / 1024, max(x["rss"] for x in xs) / 1024))
