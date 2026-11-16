#!/usr/bin/env python3
"""analyze.py RUNDIR: each run-N.out/run-N.err pair (stdout rows, stderr trace); per-call breakdown, medians over runs (us)."""
import sys, os, glob, statistics as st
d = sys.argv[1]
agg = {}
def put(k, v): agg.setdefault(k, []).append(v)
for out in sorted(glob.glob(d + "/run-*.out")):
    rows = {}
    for line in open(out):
        p = line.split()
        if len(p) == 3: rows[p[0]] = int(p[1])
    ev = []
    for line in open(out[:-4] + ".err"):
        if line.startswith("T "):
            _, t, i, k, a = line.split(); ev.append((int(t), int(i), int(k), int(a)))
    ev.sort()
    T0 = next(t for t, i, k, a in ev if k == 1)
    marks = [t for t, i, k, a in ev if k == 14]
    flts = [a for t, i, k, a in ev if k == 18]
    # windows: call1 [m1-e1, m1], call2 [m2-e2, m2], call3 [m4-e3, m4]
    win = {1: (marks[0] - rows["psum1"], marks[0]), 2: (marks[1] - rows["psum2"], marks[1]), 3: (marks[3] - rows["psum3"], marks[3])}
    put("T0 - psum1 start", (T0 - win[1][0]) / 1e3)
    put("faults call1", flts[1] - flts[0]); put("faults call2", flts[2] - flts[1]); put("faults call3", flts[4] - flts[3])
    for c, (a0, a1) in win.items():
        put("call%d ms" % c, (a1 - a0) / 1e6)
        inw = [e for e in ev if a0 <= e[0] <= a1]
        put("call%d stack mmaps" % c, sum(1 for e in inw if e[2] == 12))
        put("call%d stack mmap us" % c, sum(e[3] for e in inw if e[2] == 12) / 1e3)
        put("call%d alloc mmaps" % c, sum(1 for e in inw if e[2] == 13))
        put("call%d alloc mmap us" % c, sum(e[3] for e in inw if e[2] == 13) / 1e3)
        put("call%d fibers" % c, sum(1 for e in inw if e[2] == 7))
        put("call%d steals" % c, sum(1 for e in inw if e[2] == 8))
        put("call%d kicks" % c, sum(1 for e in inw if e[2] == 11))
        # first fiber per worker, relative to call start
        firsts = {}
        for t, i, k, a in inw:
            if k == 7 and i not in firsts: firsts[i] = t
        fs = sorted(v - a0 for i, v in firsts.items() if i != 0)
        if fs:
            put("call%d first fiber, 1st other worker us" % c, fs[0] / 1e3)
            put("call%d first fiber, median other worker us" % c, fs[len(fs) // 2] / 1e3)
            put("call%d first fiber, last worker us" % c, fs[-1] / 1e3)
        put("call%d workers that ran" % c, len(firsts))
        # sleep time inside the window, summed over workers, and idle before first fiber
        asleep = 0
        for w in set(i for _, i, _, _ in ev):
            s = None
            for t, i, k, a in ev:
                if i != w: continue
                if k == 9: s = t
                elif k == 10 and s is not None:
                    asleep += max(0, min(t, a1) - max(s, a0)); s = None
            if s is not None: asleep += max(0, a1 - max(s, a0))
        put("call%d worker-us asleep" % c, asleep / 1e3)
    # thread start-up in call 1
    if not any(e[2] == 3 for e in ev): continue
    put("startWorkers: pollers opened us", (next(t for t, i, k, a in ev if k == 2) - T0) / 1e3)
    put("startWorkers: threads spawned us", (max(t for t, i, k, a in ev if k == 3) - T0) / 1e3)
    put("startWorkers: returned (monitor started) us", (next(t for t, i, k, a in ev if k == 4) - T0) / 1e3)
    ent = sorted(t - T0 for t, i, k, a in ev if k == 5)
    alt = sorted(t - T0 for t, i, k, a in ev if k == 6)
    if ent:
        put("worker threads entered: first us", ent[0] / 1e3); put("worker threads entered: last us", ent[-1] / 1e3)
        put("altstack attached: last us", alt[-1] / 1e3)
for k, v in agg.items():
    print("%-48s median %10.2f  min %10.2f  max %10.2f  (n=%d)" % (k, st.median(v), min(v), max(v), len(v)))
