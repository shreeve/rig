#!/usr/bin/env python3
# summary.py [ARMS]: the counters measure.sh wrote, by project and checkers,
# each arm against the first. Means over every perf stat run.
import sys, os, glob, statistics, re, filecmp
W = "/zfs/worktrees/rig/item15"
arms = sys.argv[1:] or ["base", "fix3", "fix2"]
keys = ["task-clock", "page-faults", "cycles/u", "cycles/k", "instructions/u", "instructions/k"]


def read(a, p, c):
    vals = {k: [] for k in keys}
    for f in glob.glob(f"{W}/raw/{a}.{p}.{c}.*"):
        for line in open(f):
            parts = line.split(",")
            if len(parts) < 3:
                continue
            for k in keys:
                if parts[2].endswith(k):
                    vals[k].append(float(parts[0]))
    r = {k: statistics.mean(v) if v else float("nan") for k, v in vals.items()}
    r["ins"] = r["instructions/u"] + r["instructions/k"]
    r["cyc"] = r["cycles/u"] + r["cycles/k"]
    return r


def strace(a, p, c):
    f = f"{W}/strace/{a}.{p}.{c}"
    if not os.path.exists(f):
        return ""
    t = open(f).read()
    return "bud %d nohuge %d huge %d mmap %d munmap %d madvise %d" % (
        t.count("buddyinfo"), t.count("MADV_NOHUGEPAGE"), t.count("MADV_HUGEPAGE"),
        len(re.findall(r"\bmmap\(", t)), t.count("munmap("), t.count("madvise("))


def rss(a, p, c):
    f = f"{W}/rss/{a}.{p}.{c}"
    if not os.path.exists(f):
        return float("nan")
    v = [int(x) for x in open(f).read().split() if x.isdigit()]
    return statistics.median(v) / 1024 if v else float("nan")


projs = os.environ.get("PROJS", "empty mitt neverthrow").split()
for p in projs:
    for c in [1, 4]:
        if not glob.glob(f"{W}/raw/{arms[0]}.{p}.{c}.*"):
            continue
        print(f"## {p}, {c} checker" + ("s" if c > 1 else ""))
        b = read(arms[0], p, c)
        for a in arms:
            r = read(a, p, c)
            if a == arms[0]:
                same = ""
            else:
                same = " out same" if filecmp.cmp(f"{W}/out/{a}.{p}.{c}", f"{W}/out/{arms[0]}.{p}.{c}", shallow=False) else " OUT DIFFERS"

            def d(k):
                return "" if a == arms[0] else " (%+.2f%%)" % ((r[k] / b[k] - 1) * 100)
            print(f"  {a:8} task {r['task-clock']:.2f} ms{d('task-clock')}  ins {r['ins']/1e6:.2f}M{d('ins')} (k {r['instructions/k']/1e6:.2f}M{d('instructions/k')})"
                  f"  cyc {r['cyc']/1e6:.1f}M{d('cyc')} (k {r['cycles/k']/1e6:.1f}M{d('cycles/k')})  flt {r['page-faults']:.0f}  rss {rss(a, p, c):.1f} MB{same}")
            print(f"           {strace(a, p, c)}")
