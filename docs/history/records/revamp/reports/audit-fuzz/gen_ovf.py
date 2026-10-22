#!/usr/bin/env python3
"""Programs whose one operation must fail: at run time (panic, with the
output before it printed) or, when every operand is a constant, at compile
time (rejected)."""
import json, os, random, sys

INTT = {"I8": (8, True), "I16": (16, True), "I32": (32, True), "Int": (64, True),
        "I128": (128, True), "U8": (8, False), "U16": (16, False), "U32": (32, False),
        "U64": (64, False), "U128": (128, False)}


def rng(t):
    b, s = INTT[t]
    return (-(1 << (b - 1)), (1 << (b - 1)) - 1) if s else (0, (1 << b) - 1)


def lit(v):
    return f"({v})" if v < 0 else str(v)


def case(r):
    """returns (decl lines, stmt, runtime?)"""
    t = r.choice(list(INTT))
    b, s = INTT[t]
    lo, hi = rng(t)
    runtime = r.random() < 0.75
    k = r.randint(0, 17)

    def val(v):
        return f"id_{t.lower()}({lit(v)})" if runtime else lit(v)

    if k == 0:
        a = r.randint(max(1, hi - 1000), hi)
        c = r.randint(hi - a + 1, hi - a + 1000) if hi - a + 1 <= hi else hi
        return f"x: {t} = {val(a)} + {lit(min(c, hi))}", runtime
    if k == 1:
        a = r.randint(lo, lo + 100)
        c = r.randint(a - lo + 1, a - lo + 100)
        c = min(c, hi)
        return f"x: {t} = {val(a)} - {lit(c)}", runtime
    if k == 2:
        a = r.randint(2, 1000)
        c = hi // a + 1
        return f"x: {t} = {val(a)} * {lit(c)}", runtime
    if k == 3:
        a = r.randint(lo, hi)
        return f"x: {t} = {val(a)} / {val(0) if runtime else '0'}", runtime
    if k == 4:
        a = r.randint(lo, hi)
        return f"x: {t} = {val(a)} % {val(0) if runtime else '0'}", runtime
    if k == 5 and s:
        return f"x: {t} = {val(lo)} / {lit(-1)}", runtime
    if k == 6:
        # left shift that loses a bit
        amt = r.randint(1, b - 1)
        a = (hi >> (amt - 1)) if s else (1 << (b - amt))
        if a == 0:
            a = 1 << (b - 1) if not s else hi
        return f"x: {t} = {val(a)} << {lit(amt)}", runtime
    if k == 7:
        # shift amount out of range at run time
        amt = r.choice([b, b + 1, 255, -1])
        return f"x: {t} = {val(1)} >> id_int({lit(amt)})" if runtime else f"x: {t} = {lit(1)} >> {lit(amt)}", runtime
    if k == 8 and s:
        return f"x: {t} = -{val(lo)}" if runtime else f"x: {t} = -({lo})", runtime
    if k == 9:
        # narrowing conversion that does not fit
        src = r.choice([u for u in INTT if rng(u)[1] > hi or rng(u)[0] < lo] or ["I128"])
        slo, shi = rng(src)
        v = r.choice([x for x in (hi + 1, lo - 1, shi, slo) if slo <= x <= shi and not (lo <= x <= hi)])
        return f"x: {t} = {t}({'id_' + src.lower() + '(' + lit(v) + ')' if runtime else lit(v)})", runtime
    if k == 10:
        f = r.choice(["1e300", "-1e300", str(float(hi) * 4), str(float(lo) * 4 - 1e6)])
        return f"x: {t} = {t}({'id_float(' + f + ')' if runtime else f})", runtime
    if k == 11:
        return f"x: {t} = {t}(id_float(0.0) / id_float(0.0))", True
    if k == 12:
        # compound assignment overflow
        op = r.choice(["+=", "-=", "*=", "<<="])
        a = hi if op in ("+=", "*=", "<<=") else lo
        rhs = {"+=": "1", "-=": "1", "*=": "2", "<<=": "1"}[op]
        if a == 0 and op == "*=":
            a = hi
        return f"x: {t} = {val(a)}\n  x {op} {rhs}", True
    if k == 13:
        return f"xs = [1, 2, 3]\n  x = xs[id_int(3)]", True
    if k == 14:
        return f"s = \"abc\"\n  x = s[id_int(1)..id_int(0)]", True
    if k == 15:
        return f"v: Vec[{t}] = Vec()\n  !v.push({lit(lo)})\n  x = v[id_int(1)]", True
    if k == 16:
        return f"pg: [4]U8 = [4 of 0]\n  x = pg.read[U32, .little](id_int(1))", True
    return f"x: {t} = {val(hi)}\n  x /= {'id_' + t.lower() + '(0)' if runtime else '0'}", runtime


PRELUDE = "\n".join(f"fun id_{t.lower()}(x: {t}) -> {t}\n  x\n" for t in INTT) + \
    "\nfun id_float(x: Float) -> Float\n  x\n"


if __name__ == "__main__":
    root, n, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    os.makedirs(root, exist_ok=True)
    for i in range(base, base + n):
        r = random.Random(i)
        stmt, runtime = case(r)
        src = PRELUDE + f"\nsub main\n  print(\"before\")\n  {stmt}\n  print(\"after\", x)\n"
        d = os.path.join(root, f"v{i:05d}")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "main.rig"), "w").write(src)
        exp = {"kind": "panic" if runtime else "reject", "out": "before\n", "area": "ovf"}
        json.dump(exp, open(os.path.join(d, "expect.json"), "w"))
