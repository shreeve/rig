#!/usr/bin/env python3
"""Every mask operation as Rig programs, against a scalar reference in
Python: `&`, `|`, `^`, `==`, `!=` of two masks and of a mask and a Bool,
their compound forms, `not`, the comparisons that make masks, `select`
of vectors, masks, and scalars, `array`, `with`, lane indexing, `lag`,
`splat`, `bits`, `first`, `any`, and `all`, and a mask printed; for every
lane count, on random lanes and on all-false, all-true, and one-lane
masks. The forms where a mask lives across blocks are each checked too: a
mask built up by a loop that runs a number of times known only when the
program runs, an argument and a result of a function called through a
function value (never inlined), a struct's field, an optional, an array
element, and a module constant.

  test/lanes/mask_rig_grid.py <rig> [--release] [--jobs N] [--seed S]

Each program prints `ok` once per check that passes and `bad <what>`
otherwise; a cell passes when it prints only `ok`s, as many as it has
checks. Prints each failing cell and exits 1 if any fails.
"""
import argparse, concurrent.futures as cf, os, random, subprocess, sys, tempfile

LANES = [2, 4, 8, 16, 32, 64]

def lit(xs):
    return "[" + ", ".join(("true" if x else "false") if isinstance(x, bool) else str(x) for x in xs) + "]"

def bits(m):
    return sum(1 << i for i, x in enumerate(m) if x)

class Prog:
    def __init__(self):
        self.lines, self.checks = [], 0
    def check(self, cond, what):
        self.lines.append(f'  print("ok" if {cond} else "bad {what}")')
        self.checks += 1

def cell(n, kind, seed):
    r = random.Random(f"{seed}-{n}-{kind}")
    def lanes():
        if kind == "none": return [False] * n
        if kind == "all": return [True] * n
        if kind == "one":
            k = r.randrange(n)
            return [i == k for i in range(n)]
        return [r.random() < 0.5 for _ in range(n)]
    a, b = lanes(), [r.random() < 0.5 for _ in range(n)]
    xs = [r.randrange(256) for _ in range(n)]
    ys = [r.choice([xs[i], r.randrange(256)]) for i in range(n)]
    keys = [r.randrange(256) for _ in range(13)]
    p = Prog()
    head = [f"type M = Simd[Bool, {n}]", f"type V = Simd[U8, {n}]",
            f"A: [{n}]Bool = {lit(a)}", f"B: [{n}]Bool = {lit(b)}",
            f"XS: [{n}]U8 = {lit(xs)}", f"YS: [{n}]U8 = {lit(ys)}",
            f"KEYS: [13]U8 = {lit(keys)}", f"CM: M = Simd[Bool, {n}]({lit(a)})", "CT: M = M.splat(true)", "",
            "obj Holder", "  m: M", "  k: Int", "",
            f"fun same(m: M, want: [{n}]Bool) -> Bool", "  m.array() == want", "",
            "fun flip(m: M) -> M", "  m.not()", "",
            # A mask built up lane by lane through a loop, as a value
            # carried from one pass to the next.
            "fun found(v: V, keys: ?[13]U8, count: Int) -> M",
            "  m = M.splat(false)",
            "  for i in 0..count",
            "    m |= v == keys[i]",
            "  m", "",
            "sub main()", "  a = M(A)", "  b = M(B)", "  x = V(XS)", "  y = V(YS)"]
    def want(name, xs_):
        p.lines.append(f"  {name}: [{n}]Bool = {lit(xs_)}")
    want("e_and", [p_ and q for p_, q in zip(a, b)]); p.check("same(a & b, e_and)", "&")
    want("e_or", [p_ or q for p_, q in zip(a, b)]); p.check("same(a | b, e_or)", "|")
    want("e_xor", [p_ != q for p_, q in zip(a, b)]); p.check("same(a ^ b, e_xor)", "^")
    p.check("same(a != b, e_xor)", "!=")
    want("e_eq", [p_ == q for p_, q in zip(a, b)]); p.check("same(a == b, e_eq)", "==")
    want("e_not", [not p_ for p_ in a]); p.check("same(a.not(), e_not)", "not")
    p.check("same(a | true, M.splat(true).array()) and same(a & false, M.splat(false).array())", "with a Bool")
    p.check("same(a == false, e_not) and same(a ^ true, e_not)", "== and ^ with a Bool")
    p.lines += ["  c = a", "  c &= b"]; p.check("same(c, e_and)", "&=")
    p.lines += ["  c = a", "  c |= b"]; p.check("same(c, e_or)", "|=")
    p.lines += ["  c = a", "  c ^= b"]; p.check("same(c, e_xor)", "^=")
    want("e_lt", [p_ < q for p_, q in zip(xs, ys)]); p.check("same(x < y, e_lt)", "<")
    want("e_veq", [p_ == q for p_, q in zip(xs, ys)]); p.check("same(x == y, e_veq)", "== of vectors")
    want("e_ge", [p_ >= 128 for p_ in xs]); p.check("same(x >= 128, e_ge)", ">= a scalar")
    p.lines.append(f"  e_sel: [{n}]U8 = {lit([xs[i] if a[i] else ys[i] for i in range(n)])}")
    p.check("(a.select(x, y) == V(e_sel)).all()", "select of vectors")
    want("e_selm", [b[i] if a[i] else not b[i] for i in range(n)]); p.check("same(a.select(b, b.not()), e_selm)", "select of masks")
    p.lines.append(f"  e_sel12: [{n}]Int = {lit([1 if x_ else 2 for x_ in a])}")
    p.check("a.select(1, 2).array() == e_sel12", "select of scalars")
    want("e_selb", [True if x_ else b[i] for i, x_ in enumerate(a)]); p.check("same(a.select(true, b), e_selb)", "select of a Bool and a mask")
    p.check(f"a.bits() == {bits(a)}", "bits")
    first = next((i for i, x_ in enumerate(a) if x_), None)
    p.check(f"a.first() == {'none' if first is None else first}", "first")
    p.check(f"a.any() == {'true' if any(a) else 'false'}", "any")
    p.check(f"a.all() == {'true' if all(a) else 'false'}", "all")
    p.check(f"(x == y).bits() == {bits([p_ == q for p_, q in zip(xs, ys)])}", "bits of a comparison")
    p.lines += ["  lanes_ok = true", f"  for i in 0..{n}", "    lanes_ok = lanes_ok and a[i] == A[i]"]
    p.check("lanes_ok", "lane index")
    k = r.randrange(n)
    want("e_with", [(not a[k]) if i == k else a[i] for i in range(n)]); p.check(f"same(a.with({k}, not A[{k}]), e_with)", "with")
    if n > 1:
        want("e_lag", [a[i - 1] if i >= 1 else b[n - 1] for i in range(n)]); p.check("same(a.lag[1](b), e_lag)", "lag")
    p.check(f"String(a) == \"{lit(a)}\"", "printed")
    for count in (0, 1, 5, 13):
        hit = [any(xs[i] == keys[j] for j in range(count)) for i in range(n)]
        p.check(f"found(x, ?KEYS, {count}).bits() == {bits(hit)}", f"found over {count}")
    p.lines += ["  f: fun(M) -> M = flip"]; p.check("same(f(a), e_not) and same(f(f(a)), A)", "through a function value")
    p.lines += ["  h = Holder(m: a, k: 1)", "  h.m |= b"]; p.check("same(h.m, e_or) and h.k == 1", "a field")
    p.lines += ["  o: M? = a if XS[0] < 255 else none"]; p.check("same(o ?? b, A)" if xs[0] < 255 else "same(o ?? b, B)", "an optional")
    p.lines += ["  pair: [2]M = [a, b]"]; p.check("same(pair[0] ^ pair[1], e_xor)", "an array element")
    p.check("same(CM, A) and same(CM & b, e_and) and CT.all()", "a module constant")
    return "\n".join(head + p.lines) + "\n", p.checks

def run_cell(rig, release, work, name, src, checks):
    path = os.path.join(work, name + ".rig")
    with open(path, "w") as f:
        f.write(src)
    cmd = [rig, "run"] + (["--release"] if release else []) + [path]
    env = dict(os.environ, RIG_OUT_DIR=os.path.join(work, name))
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    out = [l for l in r.stdout.split("\n") if l]
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
    cells = [(f"mask_{n}_{kind}",) + cell(n, kind, a.seed) for n in LANES for kind in ("random", "none", "all", "one")]
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
