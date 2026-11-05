#!/usr/bin/env python3
"""rss.py BIN...: per project and binary, the RssAnon and RssFile at the
sample of highest VmRSS, polling /proc/PID/status as fast as Python can
(median of 5 runs), and VmHWM. Runs on E-core 15; a measurement, not timing."""
import os, subprocess, sys, statistics
P = "/zfs/trig-pup/full/trig/misc/projects"
def run(b, proj):
    p = subprocess.Popen(["taskset", "-c", "15", b, "-p", "tsconfig.trig.json", "--noEmit", "--checkers", "1"], cwd=os.path.join(P, proj), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    best = None; hwm = 0
    path = "/proc/%d/status" % p.pid
    while p.poll() is None:
        try:
            d = {}
            for l in open(path):
                k, _, v = l.partition(":")
                if k in ("VmRSS", "RssAnon", "RssFile", "RssShmem", "VmHWM"): d[k] = int(v.split()[0])
            if "VmRSS" in d and (best is None or d["VmRSS"] > best["VmRSS"]): best = d
            hwm = max(hwm, d.get("VmHWM", 0))
        except (FileNotFoundError, ProcessLookupError, ValueError):
            pass
    return best, hwm
for proj in ["mitt", "neverthrow", "tiny-invariant", "superstruct", "zod3", "ts-pattern"]:
    line = proj.ljust(15)
    for b in sys.argv[1:]:
        rs = [run(b, proj) for _ in range(5)]
        rs = [r for r in rs if r[0]]
        an = statistics.median(r[0]["RssAnon"] for r in rs) / 1024
        fi = statistics.median(r[0]["RssFile"] for r in rs) / 1024
        hw = statistics.median(r[1] for r in rs) / 1024
        sh = statistics.median(r[0].get("RssShmem", 0) for r in rs) / 1024
        line += " | %s anon %.1f file %.1f shmem %.1f hwm %.1f" % (os.path.basename(b), an, fi, sh, hw)
    print(line, flush=True)
