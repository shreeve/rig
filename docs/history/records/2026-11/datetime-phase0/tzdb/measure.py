#!/usr/bin/env python3
"""Measure what the zone tables cost a program: the size of zone.rig's
executable against none.rig's, and the time of each one's release build,
interleaved, the fastest of ROUNDS.

    measure.py [--rounds N] [WORK]

Run from the root of the checkout, timing under tools/mac-claim. It runs
tools/gen-tzdb.py into WORK/tables, copies std to WORK/std and adds
tzdbx.rig, tzdbx.zig and the tables there (a std made for the
measurement: the checkout's std is untouched), and builds each program
with `bin/rig build --release` and RIG_STD=WORK/std. Each build starts
from an empty package directory (RIG_OUT_DIR), so Zig compiles the
program and its tables every time; Zig's global cache, which both share,
stays warm. WORK is zig-out/tzdb-measure by default.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.getcwd()
PROGRAMS = ["none", "zone"]


def run(argv, env=None):
    r = subprocess.run(argv, env=env, capture_output=True, text=True)
    if r.returncode:
        sys.exit("%s failed:\n%s%s" % (" ".join(argv), r.stdout, r.stderr))
    return r.stdout


def build(work, name):
    """Build program `name` from an empty package directory; the seconds."""
    out = os.path.join(work, "out-" + name)
    shutil.rmtree(out, ignore_errors=True)
    env = dict(os.environ, RIG_STD=os.path.join(work, "std"), RIG_OUT_DIR=out)
    start = time.perf_counter()
    run([os.path.join(ROOT, "bin", "rig"), "build", "--release", "-o", os.path.join(work, name),
         os.path.join(work, name + ".rig")], env)
    return time.perf_counter() - start


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--rounds", type=int, default=7)
    ap.add_argument("work", nargs="?", default=os.path.join(ROOT, "zig-out", "tzdb-measure"))
    args = ap.parse_args()
    work = args.work
    tables = os.path.join(work, "tables")
    run([sys.executable, "-I", os.path.join(ROOT, "tools", "gen-tzdb.py"), tables])
    shutil.rmtree(os.path.join(work, "std"), ignore_errors=True)
    shutil.copytree(os.path.join(ROOT, "std"), os.path.join(work, "std"))
    for f in ["tzdbx.rig", "tzdbx.zig"]:
        shutil.copy(os.path.join(HERE, f), os.path.join(work, "std", f))
    for f in ["tzdb_data.zig", "tzdb_names.zig"]:
        shutil.copy(os.path.join(tables, f), os.path.join(work, "std", f))
    for p in PROGRAMS:
        shutil.copy(os.path.join(HERE, p + ".rig"), os.path.join(work, p + ".rig"))

    times = {p: [] for p in PROGRAMS}
    for _ in range(args.rounds):
        for p in PROGRAMS:
            times[p].append(build(work, p))
    sizes = {p: os.path.getsize(os.path.join(work, p)) for p in PROGRAMS}
    for p in PROGRAMS:
        seg = run(["size", "-m", os.path.join(work, p)])
        const = [l.strip() for l in seg.splitlines() if "__const" in l]
        print("%s: %d bytes; %s" % (p, sizes[p], "; ".join(const)))
    print("difference: %d bytes" % (sizes["zone"] - sizes["none"]))
    print("zone prints %s" % run([os.path.join(work, "zone")]).strip())
    if args.rounds:
        for p in PROGRAMS:
            print("%s build: fastest %.3f s of %d (%s)" % (p, min(times[p]), args.rounds,
                                                          " ".join("%.3f" % t for t in times[p])))
        print("difference: %.3f s" % (min(times["zone"]) - min(times["none"])))


if __name__ == "__main__":
    main()
