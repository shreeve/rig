#!/usr/bin/env python3
"""Literal typing through generic calls and constructors, in typed contexts."""
import random

TYPES = ["U8", "I8", "I16", "U16", "I32", "U32", "Int", "U64", "I128", "U128", "Float", "F32"]
INTT = {"I8": (8, True), "I16": (16, True), "I32": (32, True), "Int": (64, True),
        "I128": (128, True), "U8": (8, False), "U16": (16, False), "U32": (32, False),
        "U64": (64, False), "U128": (128, False)}


def isf(t):
    return t in ("Float", "F32")


def rng(t):
    if isf(t):
        return (-1000, 1000)
    b, s = INTT[t]
    return (-(1 << (b - 1)), (1 << (b - 1)) - 1) if s else (0, (1 << b) - 1)


def fmt(t, v):
    if isf(t):
        return f"{int(v)}.0" if v == int(v) else repr(float(v))
    return str(v)


def lit(v):
    if isinstance(v, float) and v == int(v):
        v = int(v)
    return f"({v})" if v < 0 else str(v)


PRELUDE = ["fun gid[T](a: T) -> T\n  a\n", "fun gmax[T](a: T, b: T) -> T\n  a if a > b else b\n",
           "fun gmin[T](a: T, b: T) -> T\n  a if a < b else b\n",
           "fun gadd[T](a: T, b: T) -> T\n  a + b\n",
           "fun gdbl[T](a: T) -> T\n  a * 2\n",
           "fun ghalf[T](a: T) -> T\n  a / 2\n",
           "fun gsome[T](a: T) -> T?\n  a\n",
           "fun gnone[T] -> T?\n  none\n",
           "fun gpick[T](a: T, b: T, first: Bool) -> T\n  a if first else b\n",
           "fun gfail[T](a: T, ok: Bool) -> T!\n  return GE.bad if not ok\n  a\n",
           "error GE\n  bad\n",
           "struct Wrap[T]\n  v: T\n\n  fun get(?self) -> T\n    self.v\n\n  fun make(x: T) -> Wrap[T]\n    Wrap(v: x)\n",
           "enum Opt[T]\n  some(v: T)\n  nothing\n\n  fun or(?self, d: T) -> T\n    match self\n      .some(v) => v\n      .nothing => d\n",
           "struct Pair[T, U]\n  a: T\n  b: U\n",
           "fun rt_bool(b: Bool) -> Bool\n  b\n"] + \
          [f"fun take_{t.lower()}(x: {t}) -> {t}\n  x\n" for t in TYPES] + \
          [f"fun id_{t.lower()}(x: {t}) -> {t}\n  x\n" for t in TYPES]


def expr(r, t, depth):
    """returns (text, value) of type t built from literals via generic calls."""
    lo, hi = rng(t)
    if isf(t):
        cand = [0.5, 1.0, 2.5, 3.0, -1.5, 4.0, 7.0]
    else:
        cand = [0, 1, 2, 3, 7, 100, 127, 200, lo, hi, hi - 1, -1, -100, 255, 256]
    cand = [c for c in cand if lo <= c <= hi]
    if depth <= 0 or r.random() < 0.2:
        v = r.choice(cand)
        return lit(v), v
    k = r.randint(0, 12)
    if k == 0:
        e, v = expr(r, t, depth - 1)
        return f"gid({e})", v
    if k == 1:
        e1, v1 = expr(r, t, depth - 1)
        e2, v2 = expr(r, t, depth - 1)
        return f"gmax({e1}, {e2})", max(v1, v2)
    if k == 2:
        e1, v1 = expr(r, t, depth - 1)
        e2, v2 = expr(r, t, depth - 1)
        return f"gmin({e1}, {e2})", min(v1, v2)
    if k == 3:
        e1, v1 = expr(r, t, depth - 1)
        e2, v2 = expr(r, t, depth - 1)
        if lo <= v1 + v2 <= hi:
            return f"gadd({e1}, {e2})", v1 + v2
        return e1, v1
    if k == 4:
        e1, v1 = expr(r, t, depth - 1)
        if lo <= v1 * 2 <= hi:
            return f"gdbl({e1})", v1 * 2
        return e1, v1
    if k == 5:
        e1, v1 = expr(r, t, depth - 1)
        if isf(t):
            return f"ghalf({e1})", v1 / 2
        q = abs(v1) // 2
        return f"ghalf({e1})", q if v1 >= 0 else -q
    if k == 6:
        e1, v1 = expr(r, t, depth - 1)
        d = r.choice(cand)
        return f"(gsome({e1}) ?? {lit(d)})", v1
    if k == 7:
        d = r.choice(cand)
        e1, v1 = expr(r, t, depth - 1)
        return f"(gnone() ?? {e1})", v1
    if k == 8:
        e1, v1 = expr(r, t, depth - 1)
        e2, v2 = expr(r, t, depth - 1)
        f = r.random() < 0.5
        return f"gpick({e1}, {e2}, rt_bool({'true' if f else 'false'}))", (v1 if f else v2)
    if k == 9:
        e1, v1 = expr(r, t, depth - 1)
        return f"Wrap(v: {e1}).v", v1
    if k == 10:
        e1, v1 = expr(r, t, depth - 1)
        d = r.choice(cand)
        ok = r.random() < 0.5
        return f"(gfail({e1}, {'true' if ok else 'false'}) catch {lit(d)})", (v1 if ok else d)
    if k == 11:
        e1, v1 = expr(r, t, depth - 1)
        return f"Wrap.make({e1}).get()", v1
    e1, v1 = expr(r, t, depth - 1)
    return f"gid(gid({e1}))", v1


def make_case(r, n):
    t = r.choice(TYPES)
    e, v = expr(r, t, r.randint(1, 3))
    k = r.randint(0, 9)
    decls = []
    if k == 0:
        lines = [f"  x{n}: {t} = {e}", f"  print(x{n})"]
        out = [fmt(t, v)]
    elif k == 1:
        lines = [f"  print(take_{t.lower()}({e}))"]
        out = [fmt(t, v)]
    elif k == 2:
        lines = [f"  w{n}: Wrap[{t}] = Wrap(v: {e})", f"  print(w{n}.v, w{n})"]
        out = [f"{fmt(t, v)} Wrap(v: {fmt(t, v)})"]
    elif k == 3:
        lines = [f"  o{n}: Opt[{t}] = .some({e})", f"  print(o{n}.or({lit(rng(t)[0] if not isf(t) else 0)}))"]
        out = [fmt(t, v)]
    elif k == 4:
        lines = [f"  b{n}: {t} = id_{t.lower()}({lit(0)})", f"  print(b{n} + {e})"]
        out = [fmt(t, v)]
    elif k == 5:
        lines = [f"  p{n}: Pair[{t}, Int] = Pair(a: {e}, b: 1)", f"  print(p{n}.a)"]
        out = [fmt(t, v)]
    elif k == 6:
        lines = [f"  q{n}: {t}? = {e}", f"  print(q{n})"]
        out = [fmt(t, v)]
    elif k == 7:
        decls.append(f"fun ret{n} -> {t}\n  {e}\n")
        lines = [f"  print(ret{n}())"]
        out = [fmt(t, v)]
    elif k == 8:
        lines = [f"  xs{n}: [2]{t} = [{e}, {e}]", f"  print(xs{n})"]
        out = [f"[{fmt(t, v)}, {fmt(t, v)}]"]
    else:
        lines = [f"  v{n}: Vec[{t}] = Vec()", f"  !v{n}.push({e})", f"  print(v{n}[0])"]
        out = [fmt(t, v)]
    return decls, f"sub t{n}\n" + "\n".join(lines) + "\n", out
