#!/usr/bin/env python3
"""The Map benchmark guard: builds bench/hash/guard.rig twice, as written
for `Map` and with `Map[`/`Set[` read as `HashMap[`/`HashSet[`, and
compares each row's instructions retired per operation with
bench/hash/guard.txt. Any row more than 2% above its baseline is a
regression, and the guard exits 1. Instruction counts do not move with
the machine's load, so the guard runs on a busy machine; they come from
`/usr/bin/time -l`, so it runs on macOS only. After a change that is
meant to move them, `--update` writes the new baseline, which is
committed.

usage: bench/hash/guard.py [--update]   (RIG names the rig to build with;
                                          bin/rig by default)
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RIG = os.environ.get("RIG", os.path.join(ROOT, "bin", "rig"))
BASE = os.path.join(HERE, "guard.txt")
ROWS = ["int-hit", "int-miss", "int-churn", "int-iterate", "text-hit", "text-miss",
        "text-churn", "pair-hit", "small-hit", "dense-count"]
TABLES = {"map": lambda s: s,
          "hashmap": lambda s: s.replace("Map[", "HashMap[").replace("Set[", "HashSet[")}
N = 100000           # the operations of one repetition (guard.rig's N)
LO = 1               # the repetitions of the shorter of the two runs
# A run's count moves by 1 to 2 million instructions however long it
# runs (the kernel's work for the process, which only ever adds), so a
# row's two runs are made to differ by about 1,000 million: the run of
# HI repetitions is sized from a probe of the row, and each count is the
# least of 5 runs.
SPAN = 1000e6
PROBE = 11
LIMIT = 1.02


def instructions(exe, row, reps):
    p = subprocess.run(["/usr/bin/time", "-l", exe, row, str(reps)], capture_output=True, text=True)
    m = re.search(r"(\d+)\s+instructions retired", p.stderr)
    if p.returncode != 0 or not m:
        sys.exit("guard: %s %s %d failed: %s" % (exe, row, reps, p.stderr[-400:]))
    return int(m.group(1))


def least(exe, row, reps):
    return min(instructions(exe, row, reps) for _ in range(5))


def per_op(exe, row):
    # The difference of a run of HI repetitions and one of LO, over the
    # operations between them, so building the keys and the Map counts
    # nothing.
    lo = least(exe, row, LO)
    probe = (instructions(exe, row, PROBE) - lo) / (PROBE - LO)
    hi = LO + max(PROBE - LO, round(SPAN / probe))
    return (least(exe, row, hi) - lo) / ((hi - LO) * N)


def build(out, table):
    src = os.path.join(out, table + ".rig")
    with open(os.path.join(HERE, "guard.rig")) as r, open(src, "w") as w:
        w.write(TABLES[table](r.read()))
    exe = os.path.join(out, table)
    env = dict(os.environ, RIG_OUT_DIR=os.path.join(out, table + "-out"))
    subprocess.run([RIG, "build", "--release", "-o", exe, src], check=True, env=env)
    return exe


def main():
    update = "--update" in sys.argv[1:]
    if sys.platform != "darwin":
        sys.exit("guard: counts instructions with /usr/bin/time -l, on macOS only")
    with tempfile.TemporaryDirectory() as out:
        now = {}
        for table in TABLES:
            exe = build(out, table)
            for row in ROWS:
                now[table, row] = per_op(exe, row)
    if update:
        with open(BASE, "w") as w:
            w.write("# instructions retired per operation, rig build --release; bench/hash/guard.py --update writes it\n")
            for table in TABLES:
                for row in ROWS:
                    w.write("%s %s %.2f\n" % (table, row, now[table, row]))
        print("guard: wrote %s" % os.path.relpath(BASE, ROOT))
        return
    base = {}
    for line in open(BASE):
        if line.strip() and not line.startswith("#"):
            table, row, v = line.split()
            base[table, row] = float(v)
    bad = 0
    for table in TABLES:
        for row in ROWS:
            ratio = now[table, row] / base[table, row]
            word = "more" if ratio >= 1 else "fewer"
            flag = "  REGRESSION" if ratio > LIMIT else ""
            bad += bool(flag)
            print("%-8s %-12s %8.2f (baseline %8.2f, %.1f%% %s instructions)%s"
                  % (table, row, now[table, row], base[table, row], abs(ratio - 1) * 100, word, flag))
    sys.exit(1 if bad else 0)


main()
