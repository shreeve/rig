#!/usr/bin/env python3
"""The checked lane arithmetic grid in Rig: `+`, `-`, `*`, and `-v` (and
their compound forms) on every integer lane type and lane count, on
vectors made at run time.

  test/lanes/rig_grid.py <rig> [--release] [--jobs N] [--types U8,I8,...]
                         [--lanes 2,4,...] [--keep DIR]

Each lane type is one program, built once, whose cells are subs; its
first argument names the cell to run, or `clean`, every cell with no
overflowing lane (each prints `ok <cell>` or `bad <cell>`; when that run
fails, each is run again on its own):

  line   `x op y` and `t op= y` once, on vectors made from formulas of the
         lane index
  loop   `acc op= v` in a loop over a String's bytes, each block read as
         a vector (`t.read[V](i)`), for a trip count known only when it
         runs: the shape in which Zig's own vector `+` on `Simd[U8, 64]`
         reported an overflow that was not there, on aarch64 with
         --release

Every other cell has one overflowing lane and must print `start`, then
stop with the panic `integer overflow`:

  ovf        `x op y` with the last lane overflowing
  sparse     `x op x` with lane 5 overflowing and almost every other zero
             (Zig's own vector `*` missed this one on `Simd[I8, 32]`)
  loopovf    the loop, with one more block whose last lane overflows

Prints each cell that fails and exits 1 if any does.
"""
import argparse, concurrent.futures as cf, math, os, subprocess, sys, tempfile

TYPES = {"U8": (8, False), "I8": (8, True), "U16": (16, False), "I16": (16, True),
         "U32": (32, False), "I32": (32, True), "U64": (64, False), "I64": (64, True)}
LANES = [2, 4, 8, 16, 32, 64]
OPS = ["add", "sub", "mul", "neg"]
SYM = {"add": "+", "sub": "-", "mul": "*", "neg": "-"}
# Blocks the loop reads: three or more, where the false overflow showed.
ITERS = 4

def rng(bits, signed):
    return (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)

def as_int(v, bits):
    """`v` as an `Int` literal with the same low `bits` bits."""
    v &= (1 << bits) - 1
    return v - (1 << 64) if v >= 1 << 63 else v

def ops_for(signed):
    return [op for op in OPS if signed or op != "neg"]

# line, ovf, sparse: one statement on vectors made from formulas.

def modulus(op, bits, signed):
    """Lane values below it never overflow `op`, and the arithmetic that
    makes them fits an `Int`."""
    lo, hi = rng(bits, signed)
    if op == "mul":
        return math.isqrt(hi)
    return hi // 4 if bits == 64 and not signed else hi // 2

def line_values(op, bits, signed, n):
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

def line_cell(op, ty, n, ovf):
    bits, signed = TYPES[ty]
    lo, hi = rng(bits, signed)
    xs, ys = line_values(op, bits, signed, n)
    if ovf:
        xs[-1], ys[-1] = {"add": (hi, 1), "sub": (lo if signed else 0, 1),
                          "mul": (hi, 2), "neg": (lo, 0)}[op]
    want = [result(op, x, y) for x, y in zip(xs, ys)]
    assert ovf or all(lo <= w <= hi for w in want), (op, ty, n)
    V = f"Simd[{ty}, {n}]"
    m = modulus(op, bits, signed)
    shift = m if op == "sub" and not signed else 0
    a_shift = shift - (m // 2 if op == "neg" and signed else 0)
    # Each lane is a formula of its index, so nothing folds.
    def fill(name, base):
        return (f"  {name}: [{n}]{ty} = [{n} of 0]\n  for i in 0..{n}\n"
                f"    {name}[i] = {ty}(({base[0]} * i + {base[1]}) % {base[2]} + {base[3]})\n")
    src = fill("xa", (7, 3, m, a_shift))
    if op != "neg":
        src += fill("ya", (5, 1, m, 0))
    if ovf:
        src += f"  xa[{n - 1}] = {ty}({xs[-1]})\n"
        if op != "neg":
            src += f"  ya[{n - 1}] = {ty}({ys[-1]})\n"
    src += f"  x = {V}(xa)\n"
    if op != "neg":
        src += f"  y = {V}(ya)\n"
    expr = "-x" if op == "neg" else f"x {SYM[op]} y"
    if ovf:
        return src + f'  print("start")\n  r = {expr}\n  print(r[0])\n'
    name = f"line_{op}_{n}"
    src += f"  r = {expr}\n  e = {V}([{', '.join(map(str, want))}])\n"
    if op == "neg":
        src += f"  t = {V}.splat(0)\n  t -= x\n"
    else:
        src += f"  t = x\n  t {SYM[op]}= y\n"
    return src + f'  print("ok {name}" if (r == e).all() and (t == e).all() else "bad {name}")\n'

def sparse_cell(op, ty, n):
    bits, signed = TYPES[ty]
    lo, hi = rng(bits, signed)
    big = lo if op == "neg" else hi
    src = f"  a: [{n}]{ty} = [{n} of 0]\n"
    src += f"  for i in 0..{n}\n    if i == 5\n      a[i] = {ty}({big})\n"
    src += "    else if i == 7 or i == 13\n      a[i] = 1\n    else if i == 9\n      a[i] = 7\n"
    src += f'  x = Simd[{ty}, {n}](a)\n  print("start")\n'
    src += "  r = -x\n" if op == "neg" else f"  r = x {SYM[op]} x\n"
    return src + "  print(r[0])\n"

# loop, loopovf: an accumulator over blocks of a String's bytes.

def loop_plan(op, bits, signed):
    """The lane value formula (Rig, of the lane's place `k` in the bytes),
    its Python twin, the accumulator's start, and the statement."""
    lo, hi = rng(bits, signed)
    if op == "mul":
        return "k % 2 + 1", lambda k: k % 2 + 1, 1, "acc *= v"
    m = min(hi // ITERS, 100)
    f = (f"(7 * k + 3) % {m} + 1", lambda k: (7 * k + 3) % m + 1)
    if op == "add":
        return f + (0, "acc += v")
    if op == "sub":
        return f + (ITERS * m, "acc -= v")
    return f + (0, "acc = -acc + v")

def loop_cell(op, ty, n, ovf):
    bits, signed = TYPES[ty]
    lo, hi = rng(bits, signed)
    size = bits // 8
    formula, value, start, step = loop_plan(op, bits, signed)
    acc = [start] * n
    for b in range(ITERS):
        for j in range(n):
            v = value(b * n + j)
            acc[j] = {"add": acc[j] + v, "sub": acc[j] - v, "mul": acc[j] * v, "neg": -acc[j] + v}[op]
            assert lo <= acc[j] <= hi and (op != "neg" or lo <= -acc[j] <= hi), (op, ty, n)
    V = f"Simd[{ty}, {n}]"
    blocks = ITERS + 1 if ovf else ITERS
    src = f"  s = String()\n  for k in 0..{blocks * n}\n    v = {formula}\n"
    if ovf:
        # The extra block is zero but its last lane, which overflows the
        # accumulator, whatever its lanes are.
        big = {"add": hi, "sub": hi if not signed else lo, "mul": hi}[op]
        src += f"    if k >= {ITERS * n}\n      v = {as_int(big, bits)} if k == {blocks * n - 1} else 0\n"
    src += f"    for b in 0..{size}\n      !s.push(U8((v >> (8 * b)) & 255))\n"
    src += f"  t = ?s[..]\n  acc = {V}.splat({start})\n"
    if ovf:
        src += '  print("start")\n'
    src += f"  i = 0\n  while i + {n * size} <= t.len : i += {n * size}\n"
    order = ", .little" if size > 1 else ""
    src += f"    v = t.read[{V}{order}](i)\n    {step}\n"
    if ovf:
        return src + "  print(acc[0])\n"
    name = f"loop_{op}_{n}"
    src += f"  e = {V}([{', '.join(map(str, acc))}])\n"
    return src + f'  print("ok {name}" if (acc == e).all() else "bad {name}")\n'

def type_program(ty, lanes):
    """The program for lane type `ty`: its source, its clean cells, and
    its overflowing ones."""
    bits, signed = TYPES[ty]
    subs, clean, ovfs = [], [], []
    def add(name, body):
        subs.append(f"sub {name}()\n{body}")
    for op in ops_for(signed):
        for n in lanes:
            add(f"line_{op}_{n}", line_cell(op, ty, n, False))
            add(f"loop_{op}_{n}", loop_cell(op, ty, n, False))
            clean += [f"line_{op}_{n}", f"loop_{op}_{n}"]
            add(f"ovf_{op}_{n}", line_cell(op, ty, n, True))
            ovfs.append(f"ovf_{op}_{n}")
            if op != "sub" and n > 13:
                add(f"sparse_{op}_{n}", sparse_cell(op, ty, n))
                ovfs.append(f"sparse_{op}_{n}")
            if op != "neg":
                add(f"loopovf_{op}_{n}", loop_cell(op, ty, n, True))
                ovfs.append(f"loopovf_{op}_{n}")
    main = ["sub main()", "  args = os.args()", "  which = args[1]", '  if which == "clean"']
    main += [f"    {c}()" for c in clean]
    for c in clean + ovfs:
        main += [f'  else if which == "{c}"', f"    {c}()"]
    return "use std.os\n\n" + "\n".join(subs) + "\n" + "\n".join(main) + "\n", clean, ovfs

def run(exe, arg):
    return subprocess.run([exe, arg], capture_output=True, text=True)

def check_type(rig, release, work, ty, lanes, jobs):
    """The failures of lane type `ty`'s program, as lines."""
    src, clean, ovfs = type_program(ty, lanes)
    path = os.path.join(work, f"lanes_{ty}.rig")
    with open(path, "w") as f:
        f.write(src)
    exe = os.path.join(work, f"lanes_{ty}")
    env = dict(os.environ, RIG_OUT_DIR=os.path.join(work, f"out_{ty}"))
    b = subprocess.run([rig, "build"] + (["--release"] if release else []) + ["-o", exe, path],
                       capture_output=True, text=True, env=env)
    if b.returncode:
        return [f"{ty}: build failed\n  {b.stderr[:1500]}"], 0
    bad = []
    r = run(exe, "clean")
    if r.returncode or r.stdout.split("\n")[:-1] != [f"ok {c}" for c in clean]:
        # Each clean cell again on its own: a panic stops the run of all.
        with cf.ThreadPoolExecutor(jobs) as ex:
            for c, r in zip(clean, ex.map(lambda c: run(exe, c), clean)):
                if r.returncode == 0 and r.stdout == f"ok {c}\n":
                    continue
                why = "false overflow" if "integer overflow" in r.stderr else "wrong value"
                bad.append(f"{ty} {c}: {why}\n  {(r.stderr or r.stdout)[:300]}")
    with cf.ThreadPoolExecutor(jobs) as ex:
        for c, r in zip(ovfs, ex.map(lambda c: run(exe, c), ovfs)):
            if r.returncode != 0 and "integer overflow" in r.stderr and r.stdout.strip() == "start":
                continue
            why = "missed overflow" if r.returncode == 0 else "wrong failure"
            bad.append(f"{ty} {c}: {why}\n  {(r.stderr or r.stdout)[:300]}")
    return bad, len(clean) + len(ovfs)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rig")
    ap.add_argument("--release", action="store_true")
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--types", default=",".join(TYPES))
    ap.add_argument("--lanes", default=",".join(map(str, LANES)))
    ap.add_argument("--keep", help="write the programs here and keep them")
    a = ap.parse_args()
    types = a.types.split(",")
    lanes = [int(n) for n in a.lanes.split(",")]
    with tempfile.TemporaryDirectory() as tmp:
        work = a.keep or tmp
        os.makedirs(work, exist_ok=True)
        with cf.ThreadPoolExecutor(a.jobs) as ex:
            results = list(ex.map(lambda ty: check_type(a.rig, a.release, work, ty, lanes, a.jobs), types))
    cells = sum(r[1] for r in results)
    bad = [line for r in results for line in r[0]]
    for line in bad:
        print(line)
    print(f"{len(types)} programs ({'release' if a.release else 'debug'}), {cells} cells, {len(bad)} bad")
    sys.exit(1 if bad else 0)

main()
