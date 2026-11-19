#!/usr/bin/env python3
"""m1.py ROUNDS OUT: the memory board for psum on pup. Each round, in rotating order:
- bw (the Zig ceiling: write psum's input, time one pass) at 1 thread on P-core 6 for each
  pages x order x loop, and at 12 threads on 0-11 for pages x loop;
- fork.rig (Rig a303f69fd, main's code) and its Rayon twin at 1 worker (core 6) and 12 (0-11),
  each as it is and with huge pages flipped: Rig with THP disabled for the process
  (prctl PR_SET_THP_DISABLE, so its MADV_HUGEPAGE is void), Rayon with glibc's malloc asking
  for THP (GLIBC_TUNABLES=glibc.malloc.hugetlb=1);
  each under perf stat (page-faults, dTLB-load-misses, cycles, instructions; whole process).
Samples go to OUT as they end."""
import os, subprocess, sys, statistics
rounds, out = int(sys.argv[1]), sys.argv[2]
M = "/zfs/trig-pup/psum-gap/mem"
F = "/zfs/trig-pup/standings-1118/fork"
NOTHP = ["python3", M + "/nothp.py"]
jobs = []
for pages in ("huge", "small", "plain"):
    for order in ("asc", "leafasc", "leafdesc"):
        for loop in ("scalar", "vec"):
            jobs.append(("bw1 %s %s %s" % (pages, order, loop), "6", [M + "/bw", pages, order, "1", loop], {}))
for pages in ("huge", "small"):
    for loop in ("scalar", "vec"):
        jobs.append(("bw12 %s asc %s" % (pages, loop), "0-11", [M + "/bw", pages, "asc", "12", loop], {}))
for cfg, cores, w in (("w1", "6", "1"), ("w12", "0-11", "12")):
    env = {"RIG_WORKERS": w, "RAYON_NUM_THREADS": w}
    jobs.append(("%s rig" % cfg, cores, [F + "/rig"], env))
    jobs.append(("%s rig-aa" % cfg, cores, [F + "/rig-aa"], env))
    jobs.append(("%s rig-nothp" % cfg, cores, NOTHP + [F + "/rig"], env))
    jobs.append(("%s rayon" % cfg, cores, [F + "/rayon"], env))
    jobs.append(("%s rayon-thp" % cfg, cores, [F + "/rayon"], dict(env, GLIBC_TUNABLES="glibc.malloc.hugetlb=1")))
EV = "page-faults,dTLB-load-misses,dTLB-store-misses,cycles:u,instructions:u"
with open(out, "a") as log:
    for k in range(rounds):
        sh = k % len(jobs)
        for name, cores, cmd, env in jobs[sh:] + jobs[:sh]:
            e = dict(os.environ, **env)
            perf = name.startswith("w")
            full = ["taskset", "-c", cores] + (["perf", "stat", "-x", ",", "-e", EV, "--"] if perf else []) + cmd
            p = subprocess.run(full, capture_output=True, text=True, timeout=300, env=e, check=True)
            res = " ".join(l.replace(" ", ":") for l in p.stdout.splitlines())
            cnt = ""
            if perf:
                cnt = " ".join("%s=%s" % (l.split(",")[2], l.split(",")[0]) for l in p.stderr.splitlines() if l.count(",") >= 3)
            log.write("%d|%s|%s|%s\n" % (k + 1, name, res, cnt)); log.flush()
        print("round %d" % (k + 1), flush=True)
