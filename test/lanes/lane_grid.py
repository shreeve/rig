#!/usr/bin/env python3
"""The checked lane arithmetic grid: every op, lane type, and lane count,
on clean vectors (no lane overflows) and on vectors with an overflowing
lane, in each build mode, for each way of making the operation.

  test/lanes/lane_grid.py [--impl plain,intrinsic,rig] [--modes Debug,ReleaseSafe,ReleaseFast]
                          [--jobs N] [--ops add,sub,mul,neg] [--seeds N]

Prints each cell that reports an overflow where there is none ("false")
or misses one ("missed"), or gives a wrong value, and exits 1 if any cell
does. ReleaseFast has no checks, so its `ovf` cells are not run: it checks
only that clean cells give the right values. `rig` is the default.
"""
import argparse, concurrent.futures as cf, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
TYPES = ["u8", "i8", "u16", "i16", "u32", "i32", "u64", "i64"]
LANES = [2, 4, 8, 16, 32, 64]

def build(mode, out, zig, impls):
    # The ways asked for, and no others: each is a copy of every cell.
    listing = os.path.join(os.path.dirname(out), "impls.zig")
    with open(listing, "w") as f:
        f.write("pub const list = .{ " + ", ".join(f".{i}" for i in impls) + " };\n")
    cmd = [zig, "build-exe", "-O", mode, f"-femit-bin={out}", "--dep", "rig", "--dep", "impls",
           f"-Mroot={HERE}/lane_grid.zig", f"-Mrig={ROOT}/src/runtime.zig", f"-Mimpls={listing}",
           "--cache-dir", os.path.join(os.path.dirname(out), "cache"),
           "--global-cache-dir", os.path.join(os.path.dirname(out), "gcache")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"build failed ({mode}):\n{r.stderr[:2000]}")

def run(exe, args):
    r = subprocess.run([exe] + [str(a) for a in args], capture_output=True, text=True)
    return r.returncode, r.stderr

def check(exe, mode, impl, op, ty, n, seeds):
    bad = []
    signed = ty.startswith("i")
    if op == "neg" and not signed:
        return bad
    for seed in range(seeds):
        rc, _ = run(exe, [impl, op, ty, n, "clean", seed])
        if rc == 3:
            bad.append("wrong value")
        elif rc != 0:
            bad.append("false")
        if mode == "ReleaseFast":
            continue
        for at in sorted({0, n // 2, n - 1}):
            rc, err = run(exe, [impl, op, ty, n, "ovf", seed, at])
            # A panic aborts; a returned overflow case exits 4 (missed).
            if rc == 4:
                bad.append(f"missed@{at}")
            elif rc == 3:
                bad.append("wrong value")
            elif rc == 0:
                pass  # this seed has no overflow to force
            elif "integer overflow" not in err:
                bad.append(f"unexpected exit {rc}@{at}")
    return sorted(set(bad))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--impl", default="rig")
    ap.add_argument("--modes", default="Debug,ReleaseSafe,ReleaseFast")
    ap.add_argument("--ops", default="add,sub,mul,neg")
    ap.add_argument("--types", default=",".join(TYPES))
    ap.add_argument("--lanes", default=",".join(map(str, LANES)))
    ap.add_argument("--seeds", type=int, default=4)
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("CPUQ_CORES", "2").split("-")[0] or 2))
    ap.add_argument("--zig", default="zig")
    a = ap.parse_args()
    failures = 0
    cells = 0
    with tempfile.TemporaryDirectory() as tmp:
        for mode in a.modes.split(","):
            out = os.path.join(tmp, f"grid-{mode}")
            build(mode, out, a.zig, a.impl.split(","))
            jobs = [(impl, op, ty, int(n)) for impl in a.impl.split(",") for op in a.ops.split(",")
                    for ty in a.types.split(",") for n in a.lanes.split(",")]
            with cf.ThreadPoolExecutor(a.jobs) as ex:
                futs = {ex.submit(check, out, mode, *j, a.seeds): j for j in jobs}
                for f in cf.as_completed(futs):
                    impl, op, ty, n = futs[f]
                    bad = f.result()
                    if not (op == "neg" and ty.startswith("u")):
                        cells += 1
                    if bad:
                        failures += 1
                        print(f"{mode:12} {impl:9} {op:4} {ty:4} x{n:<3} {', '.join(bad)}")
    print(f"{cells} cells, {failures} bad")
    sys.exit(1 if failures else 0)

main()
