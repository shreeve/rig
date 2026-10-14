#!/usr/bin/env python3
"""Compound assignment (`+=`, `-=`, `*=`) on integer vector lanes through
every kind of place, in Rig: a local, a `!V` parameter, a field, an
element, a field through a `!Box` parameter, and an element through a
`![2]V` parameter, for several lane types.

  test/lanes/place_grid.py <rig> [--release] [--jobs N]

Each lane type is one program, built once; its first argument names what
to run. `clean` applies each operator through every place with no
overflowing lane, and must print the expected lane for each. `<op>_<place>`
applies `op` through `place` to an overflowing lane, and must print
`start`, then panic `integer overflow`. Prints each failing cell and exits
1 if any fails.
"""
import argparse, concurrent.futures as cf, os, subprocess, sys, tempfile

TYPES = {"U8": (8, False), "I8": (8, True), "I32": (32, True), "U64": (64, False), "I64": (64, True)}
OPS = {"+": "add", "-": "sub", "*": "mul"}
PLACES = ["local", "param", "field", "element", "field_param", "element_param"]
LANES = 32

def rng(bits, signed):
    return (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)

def header(ty):
    src = f"type V = Simd[{ty}, {LANES}]\n\nobj Box\n  v: V\n\n"
    for op, name in OPS.items():
        src += f"sub on_param_{name}(p: !V, y: V)\n  p {op}= y\n\n"
        src += f"sub on_field_{name}(b: !Box, y: V)\n  b.v {op}= y\n\n"
        src += f"sub on_element_{name}(a: ![2]V, y: V)\n  a[1] {op}= y\n\n"
    return src

def place_code(place, op, tail):
    """The statements that apply `x op= y` through `place` and `tail(expr)`
    the lane read back."""
    name = OPS[op]
    return {
        "local": f"  l = x\n  l {op}= y\n  {tail('l')}\n",
        "param": f"  p = x\n  on_param_{name}(!p, y)\n  {tail('p')}\n",
        "field": f"  bx = Box(v: x)\n  bx.v {op}= y\n  {tail('bx.v')}\n",
        "element": f"  arr = [x, x]\n  arr[1] {op}= y\n  {tail('arr[1]')}\n",
        "field_param": f"  fb = Box(v: x)\n  on_field_{name}(!fb, y)\n  {tail('fb.v')}\n",
        "element_param": f"  ea = [x, x]\n  on_element_{name}(!ea, y)\n  {tail('ea[1]')}\n",
    }[place]

def operands(op, ty, ovf):
    lo, hi = rng(*TYPES[ty])
    if ovf:
        return {"+": (hi, 2), "-": (lo, 1), "*": (hi, 2)}[op]
    return {"+": (3, 4), "-": (9, 4), "*": (3, 5)}[op]

def expected(op, a, b):
    return {"+": a + b, "-": a - b, "*": a * b}[op]

def cell(op, ty, place):
    """A sub's body: `x op= y` through `place` on an overflowing lane, or
    through every place on a clean one (`place` None)."""
    ovf = place is not None
    a, b = operands(op, ty, ovf)
    # Built at run time, so nothing folds.
    src = f"  seed: [{LANES}]{ty} = [{LANES} of 0]\n  for i in 0..{LANES}\n    seed[i] = {ty}({a})\n"
    src += f"  x = Simd[{ty}, {LANES}](seed)\n  y = Simd[{ty}, {LANES}].splat({ty}({b}))\n"
    if ovf:
        return src + '  print("start")\n' + place_code(place, op, lambda e: f"print({e}[0])")
    for pl in PLACES:
        src += place_code(pl, op, lambda e: f"print({e}[0])")
    return src

def type_program(ty):
    subs, ovfs = [], []
    for op, name in OPS.items():
        subs.append(f"sub clean_{name}()\n{cell(op, ty, None)}")
        for pl in PLACES:
            subs.append(f"sub {name}_{pl}()\n{cell(op, ty, pl)}")
            ovfs.append((op, f"{name}_{pl}"))
    main = ["sub main()", "  args = os.args()", "  which = args[1]", '  if which == "clean"']
    main += [f"    clean_{name}()" for name in OPS.values()]
    for _, c in ovfs:
        main += [f'  else if which == "{c}"', f"    {c}()"]
    return "use std.os\n\n" + header(ty) + "\n".join(subs) + "\n" + "\n".join(main) + "\n", ovfs

def check_type(rig, release, work, ty, jobs):
    src, ovfs = type_program(ty)
    path = os.path.join(work, f"places_{ty}.rig")
    with open(path, "w") as f:
        f.write(src)
    exe = os.path.join(work, f"places_{ty}")
    env = dict(os.environ, RIG_OUT_DIR=os.path.join(work, f"out_{ty}"))
    b = subprocess.run([rig, "build"] + (["--release"] if release else []) + ["-o", exe, path],
                       capture_output=True, text=True, env=env)
    if b.returncode:
        return [f"{ty}: build failed\n  {b.stderr[:1500]}"]
    bad = []
    r = subprocess.run([exe, "clean"], capture_output=True, text=True)
    want = [str(expected(op, *operands(op, ty, False))) for op in OPS for _ in PLACES]
    if r.returncode != 0 or r.stdout.split() != want:
        why = "false overflow" if "integer overflow" in r.stderr else "wrong value"
        bad.append(f"{ty} clean: {why}\n  {(r.stderr or r.stdout)[:300]}")
    def run(c):
        return subprocess.run([exe, c], capture_output=True, text=True)
    with cf.ThreadPoolExecutor(jobs) as ex:
        for (_, c), r in zip(ovfs, ex.map(lambda o: run(o[1]), ovfs)):
            if r.returncode != 0 and "integer overflow" in r.stderr and r.stdout.strip() == "start":
                continue
            why = "missed overflow" if r.returncode == 0 else "wrong failure"
            bad.append(f"{ty} {c}: {why}\n  {(r.stderr or r.stdout)[:300]}")
    return bad

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rig")
    ap.add_argument("--release", action="store_true")
    ap.add_argument("--jobs", type=int, default=2)
    a = ap.parse_args()
    with tempfile.TemporaryDirectory() as work, cf.ThreadPoolExecutor(a.jobs) as ex:
        bad = [line for res in ex.map(lambda ty: check_type(a.rig, a.release, work, ty, a.jobs), TYPES) for line in res]
    for line in bad:
        print(line)
    cells = len(TYPES) * len(OPS) * (1 + len(PLACES))
    print(f"{len(TYPES)} programs, {cells} cells, {len(bad)} bad")
    sys.exit(1 if bad else 0)

main()
