#!/usr/bin/env python3
"""SIMD round 2 as Rig programs, against a scalar reference in Python:
`+|`, `-|`, `+|=`, `-|=`, `>>`, `<<%`, `<<` (on lanes that keep their
bits), and their compound forms, on every integer lane type and lane
count, by every amount (constant and run-time); `lag[k]` for every `k`;
and `lookup` on tables of 16, 32, and 64 bytes with indexes of every lane
count, biased to the edges.

  test/lanes/simd2_rig_grid.py <rig> [--release] [--jobs N] [--seed S]

Each program prints `ok` once per check that passes and `bad <what>`
otherwise; a cell passes when it prints only `ok`s, as many as it has
checks. Prints each failing cell and exits 1 if any fails.
"""
import argparse, concurrent.futures as cf, os, random, subprocess, sys, tempfile

TYPES = {"U8": (8, False), "I8": (8, True), "U16": (16, False), "I16": (16, True),
         "U32": (32, False), "I32": (32, True), "U64": (64, False), "I64": (64, True)}
LANES = [2, 4, 8, 16, 32, 64]

def rng(bits, signed):
    return (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)

def wrap(v, bits, signed):
    v &= (1 << bits) - 1
    return v - (1 << bits) if signed and v >> (bits - 1) else v

def values(r, bits, signed, n):
    lo, hi = rng(bits, signed)
    edges = [lo, lo + 1, hi, hi - 1, 0, 1, 0x70, 0x7F, -1 if signed else 2]
    out = []
    for _ in range(n):
        k = r.randrange(3)
        v = r.choice(edges) if k == 0 else r.randint(lo, hi) >> r.randrange(bits) if k == 1 else r.randint(lo, hi)
        out.append(max(lo, min(hi, v)))
    return out

def lit(xs):
    return "[" + ", ".join(str(x) for x in xs) + "]"

class Prog:
    def __init__(self):
        self.lines, self.checks = [], 0
    def check(self, cond, what):
        self.lines.append(f'  print("ok" if {cond} else "bad {what}")')
        self.checks += 1

def vector_cell(ty, n, seed):
    bits, signed = TYPES[ty]
    lo, hi = rng(bits, signed)
    r = random.Random(f"{seed}-{ty}-{n}")
    xs, ys = values(r, bits, signed, n), values(r, bits, signed, n)
    V = f"Simd[{ty}, {n}]"
    p = Prog()
    head = [f"type V = {V}", f"XS: [{n}]{ty} = {lit(xs)}", f"YS: [{n}]{ty} = {lit(ys)}", "",
            f"fun same(a: V, b: [{n}]{ty}) -> Bool", "  (a == V(b)).all()", "",
            "sub main()", "  x = V(XS)", "  y = V(YS)"]
    sat_add = [max(lo, min(hi, a + b)) for a, b in zip(xs, ys)]
    sat_sub = [max(lo, min(hi, a - b)) for a, b in zip(xs, ys)]
    p.lines.append(f"  e_add: [{n}]{ty} = {lit(sat_add)}")
    p.lines.append(f"  e_sub: [{n}]{ty} = {lit(sat_sub)}")
    p.check("same(x +| y, e_add)", "+|")
    p.check("same(x -| y, e_sub)", "-|")
    p.lines += ["  t = x", "  t +|= y"]
    p.check("same(t, e_add)", "+|=")
    p.lines += ["  t = x", "  t -|= y"]
    p.check("same(t, e_sub)", "-|=")
    s = ys[0]
    p.lines.append(f"  s: {ty} = {s}")
    p.lines.append(f"  e_adds: [{n}]{ty} = {lit([max(lo, min(hi, a + s)) for a in xs])}")
    p.lines.append(f"  e_subs: [{n}]{ty} = {lit([max(lo, min(hi, s - a)) for a in xs])}")
    p.check("same(x +| s, e_adds)", "+| scalar")
    p.check("same(s -| x, e_subs)", "-| scalar")
    # Shifts by every amount known when the program runs, against the
    # scalar operator lane by lane; and by constants, against Python.
    p.lines += [f"  for c in 0..{bits}", "    r = x >> c", "    w = x <<% c",
                f"    keep = V(XS) >> c >> 1 if c > 0 else x",
                "    k = keep << c", "    u = x", "    u >>= c",
                f"    for i in 0..{n}",
                f'      print("bad >> by", c) if r[i] != XS[i] >> c or u[i] != r[i]',
                f'      print("bad <<% by", c) if w[i] != XS[i] <<% c',
                f'      print("bad << by", c) if k[i] != keep[i] <<% c']
    for c in sorted({1, bits // 2, bits - 1}):
        p.lines.append(f"  e_shr{c}: [{n}]{ty} = {lit([a >> c for a in xs])}")
        p.lines.append(f"  e_shl{c}: [{n}]{ty} = {lit([wrap(a << c, bits, signed) for a in xs])}")
        p.check(f"same(x >> {c}, e_shr{c})", f">> {c}")
        p.check(f"same(x <<% {c}, e_shl{c})", f"<<% {c}")
        p.lines += ["  t = x", f"  t <<%= {c}"]
        p.check(f"same(t, e_shl{c})", f"<<%= {c}")
    # lag[k], every k.
    for k in range(1, n):
        want = [xs[i - k] if i >= k else ys[n - k + i] for i in range(n)]
        p.lines.append(f"  e_lag{k}: [{n}]{ty} = {lit(want)}")
        p.check(f"same(x.lag[{k}](y), e_lag{k})", f"lag {k}")
    return "\n".join(head + p.lines) + "\n", p.checks

def lookup_cell(m, n, seed):
    r = random.Random(f"{seed}-lookup-{m}-{n}")
    t = [r.randrange(256) for _ in range(m)]
    edges = [0, 15, 16, 31, 32, 47, 48, 63, 64, 0x6F, 0x70, 0x7F, 0x80, 0x8F, 0x90, 0xEF, 0xF0, 0xFF]
    p = Prog()
    head = [f"T = Simd[U8, {m}]({lit(t)})", "", "sub main()"]
    for j in range(6):
        idx = [r.choice(edges) if r.random() < 0.4 else r.randrange(m) if r.random() < 0.5 else r.randrange(256) for _ in range(n)]
        want = [t[i] if i < m else 0 for i in idx]
        p.lines.append(f"  i{j} = Simd[U8, {n}]({lit(idx)})")
        p.lines.append(f"  e{j} = Simd[U8, {n}]({lit(want)})")
        p.check(f"(T.lookup(i{j}) == e{j}).all()", f"lookup {j}")
    return "\n".join(head + p.lines) + "\n", p.checks

def run_cell(rig, release, work, name, src, checks):
    path = os.path.join(work, name + ".rig")
    with open(path, "w") as f:
        f.write(src)
    cmd = [rig, "run"] + (["--release"] if release else []) + [path]
    env = dict(os.environ, RIG_OUT_DIR=os.path.join(work, name))
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    out = r.stdout.split("\n")
    out = [l for l in out if l]
    if r.returncode == 0 and out == ["ok"] * checks:
        return None
    bad = [l for l in out if l != "ok"][:5]
    return f"{name}: exit {r.returncode}, {len(out)} lines of {checks}; {bad} {r.stderr[:600]}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rig")
    ap.add_argument("--release", action="store_true")
    ap.add_argument("--jobs", type=int, default=int((os.environ.get("CPUQ_CORES") or "2").split("-")[0]))
    ap.add_argument("--seed", default="1")
    ap.add_argument("--keep", help="write the programs here and keep them")
    a = ap.parse_args()
    cells = []
    for ty in TYPES:
        for n in LANES:
            cells.append((f"v_{ty}_{n}",) + vector_cell(ty, n, a.seed))
    for m in (16, 32, 64):
        for n in LANES:
            cells.append((f"lookup_{m}_{n}",) + lookup_cell(m, n, a.seed))
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        work = a.keep or tmp
        os.makedirs(work, exist_ok=True)
        with cf.ThreadPoolExecutor(a.jobs) as ex:
            for res in ex.map(lambda c: run_cell(a.rig, a.release, work, *c), cells):
                if res:
                    bad += 1
                    print(res)
    print(f"{len(cells)} programs ({'release' if a.release else 'debug'}), {bad} bad")
    sys.exit(1 if bad else 0)

main()
