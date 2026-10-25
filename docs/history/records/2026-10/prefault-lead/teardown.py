#!/usr/bin/env python3
"""teardown.py TRIG RUNS: on ts-pattern at one checker (core 6), strace
-ttt of execve, write, munmap and exit_group; the time from the last write
to exit_group, and to the process's end, against the whole run. A second
set of runs traces only execve, write and exit_group, to time it without
munmap's tracing cost."""
import re, subprocess, sys
exe, runs = sys.argv[1], int(sys.argv[2])
cwd = "/zfs/trig-pup/full/trig/misc/projects/ts-pattern"
def one(calls):
    st = "/tmp/teardown.st"
    subprocess.run(["strace", "-f", "-ttt", "--seccomp-bpf", "-e", "trace=" + calls, "-o", st, "taskset", "-c", "6", exe, "-p", "tsconfig.trig.json", "--noEmit", "--checkers", "1"], cwd=cwd, stdout=subprocess.DEVNULL)
    lines = open(st).read().splitlines()
    ts = lambda l: float(l.split()[1])
    start = ts([l for l in lines if "execve(" in l and "trig" in l][-1])
    lastw = max(ts(l) for l in lines if re.search(r"\bwritev?\(1,", l))
    eg = ts([l for l in lines if "exit_group(" in l][0])
    end = ts(lines[-1])
    mun = [l for l in lines if "munmap(" in l and ts(l) > lastw]
    size = sum(int(re.search(r"munmap\(0x[0-9a-f]+, (\d+)", l).group(1)) for l in mun)
    return end - start, eg - lastw, end - eg, len(mun), size
for calls in ["execve,write,writev,munmap,exit_group", "execve,write,writev,exit_group"]:
    rs = [one(calls) for _ in range(runs)]
    best = min(rs, key=lambda r: r[1] + r[2])
    print("%s: wall %.3f s; last write to exit_group %.1f ms; exit_group to end %.1f ms; teardown %.1f ms = %.1f%% of wall; munmaps after last write %d (%.0f MB)" % (
        calls, best[0], best[1] * 1e3, best[2] * 1e3, (best[1] + best[2]) * 1e3, (best[1] + best[2]) / best[0] * 100, best[3], best[4] / 1e6))
    print("  all runs teardown ms:", " ".join("%.1f" % ((r[1] + r[2]) * 1e3) for r in rs))
