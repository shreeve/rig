#!/usr/bin/env python3
"""Compound assignment (`+=`, `-=`, `*=`) on integer vector lanes through
every kind of place, in Rig: a local, a `!V` parameter, a field, an
element, a field through a `!Box` parameter, and an element through a
`![2]V` parameter, for several lane types.

  test/lanes/place_grid.py <rig> [--release] [--jobs N]

A `clean` program (all places, no overflowing lane) must print the
expected lane for each place. An `ovf` program (one place) must panic
`integer overflow` after printing `start`. Prints each failing program and
exits 1 if any fails.
"""
import argparse, concurrent.futures as cf, os, subprocess, sys, tempfile

TYPES = {"U8": (8, False), "I8": (8, True), "I32": (32, True), "U64": (64, False), "I64": (64, True)}
OPS = {"+": "add", "-": "sub", "*": "mul"}
PLACES = ["local", "param", "field", "element", "field_param", "element_param"]
LANES = 32

def rng(bits, signed):
    return (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)

def header(ty, op):
    return f"""type V = Simd[{ty}, {LANES}]

obj Box
  v: V

sub on_param(p: !V, y: V)
  p {op}= y

sub on_field(b: !Box, y: V)
  b.v {op}= y

sub on_element(a: ![2]V, y: V)
  a[1] {op}= y

"""

def place_code(place, op, tail):
    """The statements that apply `x op= y` through `place` and `tail(expr)`
    the lane read back."""
    return {
        "local": f"  l = x\n  l {op}= y\n  {tail('l')}\n",
        "param": f"  p = x\n  on_param(!p, y)\n  {tail('p')}\n",
        "field": f"  bx = Box(v: x)\n  bx.v {op}= y\n  {tail('bx.v')}\n",
        "element": f"  arr = [x, x]\n  arr[1] {op}= y\n  {tail('arr[1]')}\n",
        "field_param": f"  fb = Box(v: x)\n  on_field(!fb, y)\n  {tail('fb.v')}\n",
        "element_param": f"  ea = [x, x]\n  on_element(!ea, y)\n  {tail('ea[1]')}\n",
    }[place]

def operands(op, ty, ovf):
    lo, hi = rng(*TYPES[ty])
    if ovf:
        return {"+": (hi, 2), "-": (lo, 1), "*": (hi, 2)}[op]
    return {"+": (3, 4), "-": (9, 4), "*": (3, 5)}[op]

def expected(op, a, b):
    return {"+": a + b, "-": a - b, "*": a * b}[op]

def program(op, ty, place):
    ovf = place is not None
    a, b = operands(op, ty, ovf)
    src = header(ty, op) + "sub main()\n"
    # Built at run time, so nothing folds.
    src += f"  seed: [{LANES}]{ty} = [{LANES} of 0]\n  for i in 0..{LANES}\n    seed[i] = {ty}({a})\n"
    src += f"  x = Simd[{ty}, {LANES}](seed)\n  y = Simd[{ty}, {LANES}].splat({ty}({b}))\n"
    if ovf:
        src += '  print("start")\n' + place_code(place, op, lambda e: f"print({e}[0])")
    else:
        for pl in PLACES:
            src += place_code(pl, op, lambda e: f"print({e}[0])")
    return src

def run_cell(rig, release, work, cell):
    op, ty, place = cell
    name = f"{OPS[op]}_{ty}_{place or 'clean'}"
    path = os.path.join(work, name + ".rig")
    with open(path, "w") as f:
        f.write(program(op, ty, place))
    cmd = [rig, "run"] + (["--release"] if release else []) + [path]
    env = dict(os.environ, RIG_OUT_DIR=os.path.join(work, name))
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if place:
        ok = r.returncode != 0 and "integer overflow" in r.stderr and r.stdout.strip() == "start"
        why = "missed overflow" if r.returncode == 0 else "wrong failure"
    else:
        want = str(expected(op, *operands(op, ty, False)))
        ok = r.returncode == 0 and r.stdout.split() == [want] * len(PLACES)
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
        for ty in TYPES:
            cells.append((op, ty, None))
            cells += [(op, ty, pl) for pl in PLACES]
    bad = 0
    with tempfile.TemporaryDirectory() as work, cf.ThreadPoolExecutor(a.jobs) as ex:
        for res in ex.map(lambda c: run_cell(a.rig, a.release, work, c), cells):
            if res:
                bad += 1
                print(f"{res[0]}: {res[1]}\n  {res[2]}")
    print(f"{len(cells)} programs, {bad} bad")
    sys.exit(1 if bad else 0)

main()
