#!/usr/bin/env python3
"""The checked lane arithmetic grid in Rig: `+`, `-`, `*`, and `-v` (and
their compound forms) on every integer lane type and lane count, on
vectors made at run time.

  test/lanes/rig_grid.py <rig> [--release] [--jobs N]

A `clean` program has no overflowing lane and must print `true` twice
(the operator, then its compound form, against the expected lanes). An
`ovf` program (or `sparse`, one vector used twice with a single overflowing lane) has an overflowing lane and must stop with a panic
`integer overflow` after printing `start`. Prints each cell that fails
and exits 1 if any does.
"""
import argparse, concurrent.futures as cf, math, os, subprocess, sys, tempfile

TYPES = {"U8": (8, False), "I8": (8, True), "U16": (16, False), "I16": (16, True),
         "U32": (32, False), "I32": (32, True), "U64": (64, False), "I64": (64, True)}
LANES = [2, 4, 8, 16, 32, 64]
OVF_LANES = [32, 64]
OPS = ["add", "sub", "mul", "neg"]
SYM = {"add": "+", "sub": "-", "mul": "*", "neg": "-"}

def rng(bits, signed):
    return (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)

def modulus(op, bits, signed):
    """Lane values below it never overflow `op`, and the arithmetic that
    makes them fits an `Int`."""
    lo, hi = rng(bits, signed)
    if op == "mul":
        return math.isqrt(hi)
    return hi // 4 if bits == 64 and not signed else hi // 2

def lane_values(op, bits, signed, n, ovf):
    m = modulus(op, bits, signed)
    xs = [(i * 7 + 3) % m for i in range(n)]
    ys = [(i * 5 + 1) % m for i in range(n)]
    if op == "sub" and not signed:
        xs = [x + m for x in xs]
    if op == "neg":
        xs = [x - m // 2 for x in xs] if signed else xs
        ys = [0] * n
    return xs, ys

def result(op, x, y):
    return {"add": x + y, "sub": x - y, "mul": x * y, "neg": -x}[op]

def sparse_program(op, ty, n):
    """One vector used twice (`x op x`), almost all lanes zero and lane 5
    overflowing: the shape on which Zig's own vector `*` missed an
    overflow of `Simd[I8, 32]` on aarch64 with --release."""
    bits, signed = TYPES[ty]
    lo, hi = rng(bits, signed)
    big = lo if op == "neg" else hi
    src = f"sub main()\n  a: [{n}]{ty} = [{n} of 0]\n"
    src += f"  for i in 0..{n}\n    if i == 5\n      a[i] = {ty}({big})\n"
    src += "    else if i == 7 or i == 13\n      a[i] = 1\n    else if i == 9\n      a[i] = 7\n"
    src += f'  x = Simd[{ty}, {n}](a)\n  print("start")\n'
    src += "  r = -x\n" if op == "neg" else f"  r = x {SYM[op]} x\n"
    return src + "  print(r[0])\n"

def program(op, ty, n, ovf):
    if ovf == "sparse":
        return sparse_program(op, ty, n)
    bits, signed = TYPES[ty]
    xs, ys = lane_values(op, bits, signed, n, ovf)
    lo, hi = rng(bits, signed)
    if ovf:
        xs[-1], ys[-1] = {"add": (hi, 1), "sub": (lo if signed else 0, 1),
                          "mul": (hi, 2), "neg": (lo, 0)}[op]
    want = [result(op, x, y) for x, y in zip(xs, ys)]
    assert ovf or all(lo <= w <= hi for w in want), (op, ty, n)
    # The lanes are made from run-time values: each is a formula of the
    # index, so nothing folds.
    def fill(name, vals, base):
        return (f"  {name}: [{n}]{ty} = [{n} of 0]\n  for i in 0..{n}\n"
                f"    {name}[i] = {ty}(({base[0]} * i + {base[1]}) % {base[2]} + {base[3]})\n")
    m = modulus(op, bits, signed)
    shift = (m if (op == "sub" and not signed) else 0)
    a_shift = shift - (m // 2 if op == "neg" and signed else 0)
    src = f"sub main()\n"
    src += fill("xa", xs, (7, 3, m, a_shift))
    if op != "neg":
        src += fill("ya", ys, (5, 1, m, 0))
    if ovf:
        src += f"  xa[{n - 1}] = {ty}({xs[-1]})\n"
        if op != "neg":
            src += f"  ya[{n - 1}] = {ty}({ys[-1]})\n"
    src += f"  x = Simd[{ty}, {n}](xa)\n"
    if op != "neg":
        src += f"  y = Simd[{ty}, {n}](ya)\n"
    if ovf:
        src += '  print("start")\n'
    sym = SYM[op]
    expr = f"-x" if op == "neg" else f"x {sym} y"
    src += f"  r = {expr}\n"
    if ovf:
        src += "  print(r[0])\n"
        return src
    lits = ", ".join(str(w) for w in want)
    src += f"  e = Simd[{ty}, {n}]([{lits}])\n  print((r == e).all())\n"
    if op == "neg":
        src += "  t = Simd[%s, %d].splat(0)\n  t -= x\n" % (ty, n)
    else:
        src += f"  t = x\n  t {sym}= y\n"
    src += "  print((t == e).all())\n"
    return src

def run_cell(rig, release, work, cell):
    op, ty, n, ovf = cell
    name = f"{op}_{ty}_{n}_{ovf if isinstance(ovf, str) else 'ovf' if ovf else 'clean'}"
    path = os.path.join(work, name + ".rig")
    with open(path, "w") as f:
        f.write(program(op, ty, n, ovf))
    cmd = [rig, "run"] + (["--release"] if release else []) + [path]
    env = dict(os.environ, RIG_OUT_DIR=os.path.join(work, name))
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if ovf:
        ok = r.returncode != 0 and "integer overflow" in r.stderr and r.stdout.strip() == "start"
        why = "missed overflow" if r.returncode == 0 else "wrong failure"
    else:
        ok = r.returncode == 0 and r.stdout.split() == ["true", "true"]
        why = "false overflow" if "integer overflow" in r.stderr else "wrong value"
    return None if ok else (name, why, (r.stderr or r.stdout)[:300])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rig")
    ap.add_argument("--release", action="store_true")
    ap.add_argument("--jobs", type=int, default=2)
    a = ap.parse_args()
    cells = []
    for op in OPS:
        for ty, (bits, signed) in TYPES.items():
            if op == "neg" and not signed:
                continue
            cells += [(op, ty, n, False) for n in LANES]
            cells += [(op, ty, n, True) for n in OVF_LANES]
            if op != "sub":
                cells += [(op, ty, n, "sparse") for n in OVF_LANES]
    bad = 0
    with tempfile.TemporaryDirectory() as work, cf.ThreadPoolExecutor(a.jobs) as ex:
        for res in ex.map(lambda c: run_cell(a.rig, a.release, work, c), cells):
            if res:
                bad += 1
                print(f"{res[0]}: {res[1]}\n  {res[2]}")
    print(f"{len(cells)} programs, {bad} bad")
    sys.exit(1 if bad else 0)

main()
