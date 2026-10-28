#!/usr/bin/env python3
"""measure.py ROUNDS NAME=TRIG ...: each trig on ts-pattern and zod3, at one
checker (core 6, its sibling 7 idle), or with FOUR=1 at four (cores 0,5,6,7),
interleaved, the order reversed every other round; per case the fastest wall
of ROUNDS and the median, with its user time; the least and the median sys
time; the fewest user instructions, user and kernel cycles (P-core
counters), and page faults; the median dTLB load misses; peak RSS (median
and largest).
Outputs must agree. NOPERF=1 times without perf (faults: minor, %R)."""
import os, re, resource, statistics, subprocess, sys, time
last = resource.getrusage(resource.RUSAGE_CHILDREN)
NOPERF = os.environ.get("NOPERF") == "1"
PD = "/zfs/trig-pup/full/trig/misc/projects"
PROJ = ["ts-pattern", "zod3"]
rounds = int(sys.argv[1])
specs = [s.split("=", 1) for s in sys.argv[2:]]
MODES = [("1", ["taskset", "-c", "6"], ["--checkers", "1"])]
if os.environ.get("FOUR") == "1": MODES = [("4", ["taskset", "-c", "0,5,6,7"], ["--checkers", "4"])]
res = {}
def one(exe, proj, pin, extra):
    cmd = ([] if NOPERF else ["perf", "stat", "-x,", "-e", "instructions:u,cycles:u,cycles:k,page-faults,dTLB-load-misses", "--"]) + ["/usr/bin/time", "-f", "TIME %M %R"] + pin + [exe, "-p", "tsconfig.trig.json", "--noEmit"] + extra
    t = time.perf_counter()
    p = subprocess.Popen(cmd, cwd=os.path.join(PD, proj), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, e = p.communicate()
    ru = resource.getrusage(resource.RUSAGE_CHILDREN)
    w = time.perf_counter() - t
    global last
    u, s, rss = ru.ru_utime - last.ru_utime, ru.ru_stime - last.ru_stime, int(re.search(r"TIME (\d+)", e).group(1))
    last = ru
    def ev(name):
        m = re.search(r"^(\d+),,cpu_core/%s," % re.escape(name), e, re.M)
        return int(m.group(1)) if m else 0
    ins, cyc, kcyc, tlb = ev("instructions/u"), ev("cycles/u"), ev("cycles/k"), ev("dTLB-load-misses/")
    f = int(re.search(r"TIME \d+ (\d+)", e).group(1)) if NOPERF else int(re.search(r"^(\d+),,page-faults", e, re.M).group(1))
    return dict(w=w, u=u, s=s, ins=ins, cyc=cyc, kcyc=kcyc, tlb=tlb, f=f, rss=rss), out
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
print("| project | checkers | build | wall s | wall s median | user s | sys s | sys s median | instructions (user) | user cycles | kernel cycles | page faults | dTLB misses median | RSS MB median | RSS MB max |")
print("|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for proj in PROJ:
    for mode, _, _ in MODES:
        for name, _ in specs:
            xs = res[(proj, mode, name)]
            b = min(xs, key=lambda x: x["w"])
            print("| %s | %s | %s | %.3f | %.3f | %.3f | %.3f | %.3f | %d | %d | %d | %d | %d | %.1f | %.1f |" % (proj, mode, name, b["w"], statistics.median(x["w"] for x in xs), b["u"],
                  min(x["s"] for x in xs), statistics.median(x["s"] for x in xs), min(x["ins"] for x in xs), min(x["cyc"] for x in xs), min(x["kcyc"] for x in xs),
                  min(x["f"] for x in xs), statistics.median(x["tlb"] for x in xs),
                  statistics.median(x["rss"] for x in xs) / 1024, max(x["rss"] for x in xs) / 1024))
