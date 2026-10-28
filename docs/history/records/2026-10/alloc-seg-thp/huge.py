#!/usr/bin/env python3
"""huge.py RUNS NAME=TRIG ...: each trig on ts-pattern and zod3 at one checker
(core 6), untimed, its /proc/PID/smaps_rollup read every 5 ms from core 4;
the largest AnonHugePages and Rss seen, the most of RUNS runs."""
import os, re, subprocess, sys, time
PD = "/zfs/trig-pup/full/trig/misc/projects"
os.sched_setaffinity(0, {4})
runs = int(sys.argv[1]); specs = [s.split("=", 1) for s in sys.argv[2:]]
print("| project | build | AnonHugePages MB, most seen | Rss MB, most seen |")
print("|---|---|---:|---:|")
for proj in ["ts-pattern", "zod3"]:
    for name, exe in specs:
        best = [0, 0]
        for _ in range(runs):
            p = subprocess.Popen(["taskset", "-c", "6", exe, "-p", "tsconfig.trig.json", "--noEmit", "--checkers", "1"], cwd=os.path.join(PD, proj), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            while p.poll() is None:
                try: t = open("/proc/%d/smaps_rollup" % p.pid).read()
                except OSError: break
                m = re.search(r"AnonHugePages:\s+(\d+)", t); r = re.search(r"^Rss:\s+(\d+)", t, re.M)
                if m and r: best = [max(best[0], int(m.group(1))), max(best[1], int(r.group(1)))]
                time.sleep(0.005)
        print("| %s | %s | %.1f | %.1f |" % (proj, name, best[0] / 1024, best[1] / 1024))
