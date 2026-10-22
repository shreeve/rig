#!/usr/bin/env python3
"""Expression-form x context matrix. Each case is a `sub t<N>` so a failing
program can be split case by case."""
import json, os, random, sys

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
        if v == int(v):
            return f"{int(v)}.0"
        return repr(float(v))
    return str(v)


def lit(t, v, force_float=False):
    if isf(t):
        s = fmt(t, v) if (force_float or v != int(v)) else str(int(v))
    else:
        s = str(v)
    return f"({s})" if v < 0 else s


class Case:
    def __init__(self):
        self.decls = []
        self.pre = []    # lines in the sub before the context
        self.lines = []
        self.out = []


def small(r, t, lo=None, hi=None):
    a, b = rng(t)
    if lo is not None:
        a = max(a, lo)
    if hi is not None:
        b = min(b, hi)
    if isf(t):
        return r.choice([0.5, 1.0, 2.5, -1.5, 3.0, 10.25, 0.0, -2.0])
    k = r.random()
    if k < 0.6:
        return r.randint(max(a, -20), min(b, 20))
    if k < 0.85:
        return r.randint(max(a, -100000), min(b, 100000))
    return r.choice([a, b, a + 1, b - 1])


# ---------------------------------------------------------------- expression forms
# each returns (text, value, pre_lines, decls, kind) where kind: "inline" or "block"
def form(r, t, n, ctx_room=None):
    """ctx_room: (lo, hi) the value must lie in (so the context does not overflow)."""
    lo, hi = rng(t)
    if ctx_room:
        lo, hi = max(lo, ctx_room[0]), min(hi, ctx_room[1])
    if lo > hi:
        lo = hi = 0

    def val():
        if isf(t):
            v = r.choice([0.5, 1.0, 2.5, -1.5, 3.0, 10.25, 0.0, -2.0])
            return v if lo <= v <= hi else 0.0 if lo <= 0 <= hi else float(lo)
        k = r.random()
        if k < 0.5:
            return r.randint(max(lo, -20), min(hi, 20)) if max(lo, -20) <= min(hi, 20) else lo
        if k < 0.8:
            return r.randint(lo, hi)
        return r.choice([lo, hi])

    pre, decls = [], []
    f = r.randint(0, 30)
    if f == 12 and not os.environ.get("CTX_F01"):
        f = 0
    if f == 0:
        v = val()
        return lit(t, v), v, pre, decls, "inline"
    if f == 1:
        a, b = val(), val()
        pre.append(f"  flag{n} = rt_bool({r.choice(['true', 'false'])})")
        c = pre[-1].endswith("(true)")
        return f"({lit(t, a)} if flag{n} else {lit(t, b)})", (a if c else b), pre, decls, "inline"
    if f == 2:
        a, b = val(), val()
        c = r.random() < 0.5
        pre.append(f"  flag{n} = rt_bool({b2s(c)})")
        return f"if flag{n}\n    {lit(t, a)}\n  else\n    {lit(t, b)}", (a if c else b), pre, decls, "block"
    if f == 3:
        a, b, c = val(), val(), val()
        k = r.randint(0, 3)
        pre.append(f"  k{n} = rt_int({k})")
        res = a if k == 1 else b if k in (2, 3) else c
        return f"match k{n}\n    1 => {lit(t, a)}\n    2, 3 => {lit(t, b)}\n    _ => {lit(t, c)}", res, pre, decls, "block"
    if f == 4:
        a, b = val(), val()
        some = r.random() < 0.5
        pre.append(f"  o{n}: {t}? = {'id_' + t.lower() + '(' + lit(t, a) + ')' if some else 'none'}")
        return f"(o{n} ?? {lit(t, b)})", (a if some else b), pre, decls, "inline"
    if f == 5:
        a, b = val(), val()
        ok = r.random() < 0.5
        decls.append(f"fun fal{n}(ok: Bool) -> {t}!\n  return Err{n}.bad if not ok\n  {lit(t, a)}\n\nerror Err{n}\n  bad\n")
        return f"(fal{n}({b2s(ok)}) catch {lit(t, b)})", (a if ok else b), pre, decls, "inline"
    if f == 6:
        a = val()
        return f"gid({lit(t, a)})", a, pre, decls, "inline"
    if f == 7:
        if isf(t):
            v = val()
            return lit(t, v), v, pre, decls, "inline"
        a, b = rng(t)
        if lo <= b <= hi and r.random() < 0.5:
            return f"{t}.max", b, pre, decls, "inline"
        if lo <= a <= hi:
            return f"{t}.min", a, pre, decls, "inline"
        v = val()
        return lit(t, v), v, pre, decls, "inline"
    if f == 8:
        v = val()
        return f"{t}({lit(t, v)})", v, pre, decls, "inline"
    if f == 9:
        a, b = val(), val()
        i = r.randint(0, 1)
        pre.append(f"  ix{n} = rt_int({i})")
        return f"[{lit(t, a)}, {lit(t, b)}][ix{n}]", (a, b)[i], pre, decls, "inline"
    if f == 10:
        a, b = val(), val()
        pre.append(f"  arr{n}: [2]{t} = [{lit(t, a)}, {lit(t, b)}]")
        i = r.randint(0, 1)
        return f"arr{n}[{i}]", (a, b)[i], pre, decls, "inline"
    if f == 11:
        # constant arithmetic
        a = val()
        b = val()
        if isf(t):
            s = a + b
            if lo <= s <= hi:
                return f"({lit(t, a)} + {lit(t, b)})", s, pre, decls, "inline"
        else:
            s = a - b
            if lo <= s <= hi:
                return f"({lit(t, a)} - {lit(t, b)})", s, pre, decls, "inline"
        return lit(t, a), a, pre, decls, "inline"
    if f == 12:
        # ternary + literal
        a, b, d = val(), val(), val()
        c = r.random() < 0.5
        pre.append(f"  flag{n} = rt_bool({b2s(c)})")
        s = (a if c else b)
        if isf(t):
            d = 1.5
        res = s + d if not isf(t) else s + d
        if lo <= res <= hi and (isf(t) or True):
            return f"(({lit(t, a)} if flag{n} else {lit(t, b)}) + {lit(t, d)})", res, pre, decls, "inline"
        return lit(t, a), a, pre, decls, "inline"
    if f == 13:
        a = val()
        pre.append(f"  cl{n} = |x: {t}| x")
        return f"cl{n}({lit(t, a)})", a, pre, decls, "inline"
    if f == 14:
        a = val()
        pre.append(f"  ce{n}: Cell[{t}] = Cell({lit(t, a)})")
        return f"ce{n}.get()", a, pre, decls, "inline"
    if f == 15:
        a = val()
        pre.append(f"  vv{n}: Vec[{t}] = Vec()")
        pre.append(f"  !vv{n}.push({lit(t, a)})")
        return f"vv{n}[0]", a, pre, decls, "inline"
    if f == 16:
        a, b = val(), val()
        pre.append(f"  o{n}: {t}? = none")
        c = r.random() < 0.5
        pre.append(f"  flag{n} = rt_bool({b2s(c)})")
        return f"(o{n} ?? ({lit(t, a)} if flag{n} else {lit(t, b)}))", (a if c else b), pre, decls, "inline"
    if f == 17:
        a = val()
        b = val()
        return f"gmax({lit(t, a)}, {lit(t, b)})", max(a, b), pre, decls, "inline"
    if f == 18:
        # loop value
        a, b = val(), val()
        c = r.random() < 0.5
        pre.append(f"  flag{n} = rt_bool({b2s(c)})")
        return f"for i in 0..3\n    break {lit(t, a)} if flag{n} and i == 1\n  else\n    {lit(t, b)}", (a if c else b), pre, decls, "block"
    if f == 19:
        a = val()
        decls.append(f"struct Bx{n}\n  f: {t}\n")
        pre.append(f"  bx{n} = Bx{n}(f: {lit(t, a)})")
        return f"bx{n}.f", a, pre, decls, "inline"
    if f == 20:
        a = val()
        pre.append(f"  cst{n}: {t} =! {lit(t, a)}")
        return f"cst{n}", a, pre, decls, "inline"
    if f == 22:
        a, b = val(), val()
        c = r.random() < 0.5
        pre.append(f"  flag{n} = rt_bool({b2s(c)})")
        pre.append(f"  tv{n}: {t} = id_{t.lower()}({lit(t, b, True)})")
        return f"({lit(t, a)} if flag{n} else tv{n})", (a if c else b), pre, decls, "inline"
    if f == 23:
        a, b = val(), val()
        pre.append(f"  cr{n}: Cell[{t}] = Cell({lit(t, a)})")
        return f"cr{n}.replace({lit(t, a)})", a, pre, decls, "inline"
    if f == 24:
        a, b = val(), val()
        some = r.random() < 0.5
        pre.append(f"  gv{n}: Vec[{t}] = Vec()")
        if some:
            pre.append(f"  !gv{n}.push({lit(t, a)})")
        return f"(gv{n}.get(0) ?? {lit(t, b)})", (a if some else b), pre, decls, "inline"
    if f == 25:
        a = val()
        return f"(|| {lit(t, a)})()", a, pre, decls, "inline"
    if f == 26:
        a, b = val(), val()
        some = r.random() < 0.5
        pre.append(f"  io{n}: {t}? = {('id_' + t.lower() + '(' + lit(t, a, True) + ')') if some else 'none'}")
        return f"if io{n} as q{n}\n    q{n}\n  else\n    {lit(t, b)}", (a if some else b), pre, decls, "block"
    if f == 27:
        a = val()
        return f"raw\n    {lit(t, a)}", a, pre, decls, "block"
    if f == 28:
        a, b = val(), val()
        c = r.random() < 0.5
        pre.append(f"  flag{n} = rt_bool({b2s(c)})")
        return f"(gid({lit(t, a)}) if flag{n} else {lit(t, b)})", (a if c else b), pre, decls, "inline"
    if f == 29:
        a = val()
        k = r.randint(0, 3)
        pre.append(f"  lc{n} = rt_int({k})")
        return f"while true\n    break {lit(t, a)} if lc{n} >= 0", a, pre, decls, "block"
    if f == 30:
        a, b = val(), val()
        some = r.random() < 0.5
        decls.append(f"fun fo{n}(s: Bool) -> {t}?\n  return none if not s\n  {lit(t, a)}\n")
        decls.append(f"fun fu{n}(s: Bool) -> {t}?\n  x = fo{n}(s)?\n  x\n")
        return f"(fu{n}({b2s(some)}) ?? {lit(t, b)})", (a if some else b), pre, decls, "inline"
    # f == 21: generic returning optional unwrapped with ??
    a, b = val(), val()
    return f"(gsome({lit(t, a)}) ?? {lit(t, b)})", a, pre, decls, "inline"


def b2s(b):
    return "true" if b else "false"


# ---------------------------------------------------------------- contexts
def context(r, t, n):
    c = Case()
    lo, hi = rng(t)
    k = r.randint(0, 23)
    if k == 0:
        e, v, pre, decls, kind = form(r, t, n)
        c.decls += decls
        c.pre += pre
        if kind == "block":
            e = e
        c.lines.append(f"  x{n}: {t} = {e}")
        c.lines.append(f"  print(x{n})")
        c.out.append(fmt(t, v))
    elif k == 1:
        # arithmetic operand with typed var
        base = small(r, t, lo=max(lo, -50) if not isf(t) else None, hi=min(hi, 50) if not isf(t) else None)
        room = (lo - base, hi - base) if not isf(t) else None
        e, v, pre, decls, kind = form(r, t, n, room)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        c.pre.append(f"  b{n}: {t} = id_{t.lower()}({lit(t, base, True)})")
        c.lines.append(f"  print(b{n} + {e}, {e} + b{n})")
        s = base + v
        c.out.append(f"{fmt(t, s)} {fmt(t, s)}")
    elif k == 2:
        e, v, pre, decls, kind = form(r, t, n)
        c.decls += decls
        c.pre += pre
        c.decls.append(f"fun take{n}(a: {t}) -> {t}\n  a\n")
        if kind == "block":
            c.lines.append(f"  y{n} = take{n}(" + e + ")")
            # block form inside parens may not parse; fall back
            c.lines = [f"  z{n}: {t} = " + e, f"  y{n} = take{n}(z{n})"]
        else:
            c.lines.append(f"  y{n} = take{n}({e})")
        c.lines.append(f"  print(y{n})")
        c.out.append(fmt(t, v))
    elif k == 3:
        # return value from a function
        e, v, pre, decls, kind = form(r, t, n)
        c.decls += decls
        body = "\n".join(pre)
        ee = e if kind == "block" else e
        form_ret = r.random() < 0.5 and kind == "inline"
        c.decls.append(f"fun ret{n} -> {t}\n{body}\n  {'return ' if form_ret else ''}{ee}\n")
        c.lines.append(f"  print(ret{n}())")
        c.out.append(fmt(t, v))
    elif k == 4:
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        c.decls.append(f"struct W{n}\n  f: {t}\n  g: Int = 1\n")
        c.lines.append(f"  w{n} = W{n}(f: {e})")
        c.lines.append(f"  print(w{n}.f, w{n})")
        c.out.append(f"{fmt(t, v)} W{n}(f: {fmt(t, v)}, g: 1)")
    elif k == 5:
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        c.lines.append(f"  xs{n}: [2]{t} = [{e}, {lit(t, 0)}]")
        c.lines.append(f"  print(xs{n})")
        c.out.append(f"[{fmt(t, v)}, {fmt(t, 0)}]")
    elif k == 6:
        e, v, pre, decls, kind = form(r, t, n)
        c.decls += decls
        c.pre += pre
        if kind == "block":
            e = e
        c.lines.append(f"  op{n}: {t}? = {e}")
        c.lines.append(f"  print(op{n}, op{n} ?? {lit(t, 0)})")
        c.out.append(f"{fmt(t, v)} {fmt(t, v)}")
    elif k == 7:
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        other = small(r, t)
        c.pre.append(f"  cmp{n}: {t} = id_{t.lower()}({lit(t, other, True)})")
        c.lines.append(f"  print(cmp{n} == {e}, {e} < cmp{n}, {e} >= cmp{n})")
        c.out.append(f"{b2s(other == v)} {b2s(v < other)} {b2s(v >= other)}")
    elif k == 8:
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        c.lines.append(f"  vec{n}: Vec[{t}] = Vec()")
        c.lines.append(f"  !vec{n}.push({e})")
        c.lines.append(f"  print(vec{n})")
        c.out.append(f"[{fmt(t, v)}]")
    elif k == 9:
        base = small(r, t, lo=max(lo, -50) if not isf(t) else None, hi=min(hi, 50) if not isf(t) else None)
        room = (lo - base, hi - base) if not isf(t) else None
        e, v, pre, decls, kind = form(r, t, n, room)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        c.pre.append(f"  acc{n}: {t} = id_{t.lower()}({lit(t, base, True)})")
        c.lines.append(f"  acc{n} += {e}")
        c.lines.append(f"  print(acc{n})")
        c.out.append(fmt(t, base + v))
    elif k == 10 and not isf(t):
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        base = small(r, t)
        b, s = INTT[t]
        w = (base + v) & ((1 << b) - 1)
        if s and w >= 1 << (b - 1):
            w -= 1 << b
        c.pre.append(f"  wb{n}: {t} = id_{t.lower()}({lit(t, base)})")
        c.lines.append(f"  print(wb{n} +% {e})")
        c.out.append(str(w))
    elif k == 11:
        e, v, pre, decls, kind = form(r, t, n)
        c.decls += decls
        c.pre += pre
        if kind == "block":
            c.lines.append(f"  gg{n}: {t} = " + e)
            c.lines.append(f"  gy{n}: {t} = gid(gg{n})")
        else:
            c.lines.append(f"  gy{n}: {t} = gid({e})")
        c.lines.append(f"  print(gy{n})")
        c.out.append(fmt(t, v))
    elif k == 12:
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        c.decls.append(f"enum Op{n}\n  some(v: {t})\n  nothing\n")
        c.lines.append(f"  en{n}: Op{n} = .some({e})")
        c.lines.append(f"  print(en{n})")
        c.out.append(f".some(v: {fmt(t, v)})")
    elif k == 13:
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        c.lines.append(f"  cc{n}: Cell[{t}] = Cell({lit(t, 0)})")
        c.lines.append(f"  cc{n}.set({e})")
        c.lines.append(f"  print(cc{n}.get())")
        c.out.append(fmt(t, v))
    elif k == 14:
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        other = small(r, t)
        cond = r.random() < 0.5
        c.pre.append(f"  tf{n} = rt_bool({b2s(cond)})")
        c.pre.append(f"  tv{n}: {t} = id_{t.lower()}({lit(t, other, True)})")
        c.lines.append(f"  tz{n}: {t} = {e} if tf{n} else tv{n}")
        c.lines.append(f"  print(tz{n}, tv{n} if tf{n} else {e})")
        c.out.append(f"{fmt(t, v if cond else other)} {fmt(t, other if cond else v)}")
    elif k == 15:
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        some = r.random() < 0.5
        other = small(r, t)
        c.pre.append(f"  qo{n}: {t}? = {('id_' + t.lower() + '(' + lit(t, other, True) + ')') if some else 'none'}")
        c.lines.append(f"  print(qo{n} ?? {e})")
        c.out.append(fmt(t, other if some else v))
    elif k == 16:
        e, v, pre, decls, kind = form(r, t, n)
        c.decls += decls
        c.pre += pre
        kk = r.randint(0, 2)
        other = small(r, t)
        c.pre.append(f"  mk{n} = rt_int({kk})")
        if kind == "block":
            ee = e.replace("\n", "\n    ")
            c.lines.append(f"  mz{n}: {t} = match mk{n}\n    1\n      {ee}\n    _ => {lit(t, other)}")
        else:
            c.lines.append(f"  mz{n}: {t} = match mk{n}\n    1 => {e}\n    _ => {lit(t, other)}")
        c.lines.append(f"  print(mz{n})")
        c.out.append(fmt(t, v if kk == 1 else other))
    elif k == 18:
        e, v, pre, decls, kind = form(r, t, n)
        c.decls += decls
        c.pre += pre
        c.decls.append(f"struct GP{n}[T]\n  f: T\n")
        if kind == "block":
            c.lines.append(f"  gz{n}: {t} = " + e)
            e = f"gz{n}"
        c.lines.append(f"  gp{n}: GP{n}[{t}] = GP{n}(f: {e})")
        c.lines.append(f"  print(gp{n}.f)")
        c.out.append(fmt(t, v))
    elif k == 19:
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        ok = r.random() < 0.5
        other = small(r, t)
        c.decls.append(f"fun cf{n}(ok: Bool) -> {t}!\n  return CE{n}.no if not ok\n  {lit(t, other)}\n\nerror CE{n}\n  no\n")
        c.lines.append(f"  print(cf{n}({b2s(ok)}) catch {e})")
        c.out.append(fmt(t, other if ok else v))
    elif k == 20:
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        c.lines.append(f"  av{n}: Vec[{t}] = Vec()")
        c.lines.append(f"  !av{n}.push({lit(t, 0)})")
        c.lines.append(f"  av{n}[0] = {e}")
        c.lines.append(f"  aa{n}: [3]{t} = [3 of {lit(t, 0)}]")
        c.lines.append(f"  aa{n}[rt_int(2)] = {e}")
        c.lines.append(f"  print(av{n}[0], aa{n})")
        c.out.append(f"{fmt(t, v)} [{fmt(t, 0)}, {fmt(t, 0)}, {fmt(t, v)}]")
    elif k == 21:
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        c.decls.append(f"struct FA{n}\n  f: {t}\n")
        c.lines.append(f"  fa{n} = FA{n}(f: {lit(t, 0)})")
        c.lines.append(f"  fa{n}.f = {e}")
        c.lines.append(f"  print(fa{n}.f)")
        c.out.append(fmt(t, v))
    elif k == 22:
        # return from inside an if in a fun
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        body = "\n".join("  " + l for l in pre)
        c.decls.append(f"fun ri{n}(go: Bool) -> {t}\n  if go\n{body}\n    return {e}\n  {lit(t, 0)}\n")
        c.lines.append(f"  print(ri{n}(true), ri{n}(false))")
        c.out.append(f"{fmt(t, v)} {fmt(t, 0)}")
    elif k == 23:
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        c.lines.append(f"  vw{n}: Vec[{t}] = Vec()")
        c.lines.append(f"  pushit{n} = |!vw{n}, x: {t}| !vw{n}.push(x)")
        c.lines.append(f"  pushit{n}({e})")
        c.lines.append(f"  print(vw{n})")
        c.out.append(f"[{fmt(t, v)}]")
    else:
        # closure body returns the form
        e, v, pre, decls, kind = form(r, t, n)
        if kind == "block":
            return context(r, t, n)
        c.decls += decls
        c.pre += pre
        c.lines.append(f"  fc{n}: fun({t}) -> {t} = |a| {e}")
        c.lines.append(f"  print(fc{n}({lit(t, 0)}))")
        # closures cannot capture implicitly: forms with pre-locals would fail; accept rejection
        c.out.append(fmt(t, v))
    return c


PRELUDE = ["fun rt_bool(b: Bool) -> Bool\n  b\n", "fun rt_int(n: Int) -> Int\n  n\n",
           "fun gid[T](a: T) -> T\n  a\n", "fun gmax[T](a: T, b: T) -> T\n  a if a > b else b\n",
           "fun gsome[T](a: T) -> T?\n  a\n"] + [f"fun id_{t.lower()}(x: {t}) -> {t}\n  x\n" for t in TYPES]


def make_case(r, n):
    t = r.choice(TYPES)
    c = context(r, t, n)
    return c.decls, f"sub t{n}\n" + "\n".join(c.pre + c.lines) + "\n", c.out


def gen_prog(seed):
    r = random.Random(seed)
    decls = ["fun rt_bool(b: Bool) -> Bool\n  b\n", "fun rt_int(n: Int) -> Int\n  n\n",
             "fun gid[T](a: T) -> T\n  a\n", "fun gmax[T](a: T, b: T) -> T\n  a if a > b else b\n",
             "fun gsome[T](a: T) -> T?\n  a\n"]
    for t in TYPES:
        decls.append(f"fun id_{t.lower()}(x: {t}) -> {t}\n  x\n")
    subs, calls, out = [], [], []
    for n in range(r.randint(6, 14)):
        t = r.choice(TYPES)
        c = context(r, t, n)
        decls += c.decls
        subs.append(f"sub t{n}\n" + "\n".join(c.pre + c.lines) + "\n")
        calls.append(f"  t{n}()")
        out += c.out
    src = "\n".join(decls) + "\n" + "\n".join(subs) + "\nsub main\n" + "\n".join(calls) + "\n"
    return src, "\n".join(out) + "\n"


if __name__ == "__main__":
    root, n, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    os.makedirs(root, exist_ok=True)
    for i in range(base, base + n):
        src, out = gen_prog(i)
        d = os.path.join(root, f"x{i:05d}")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "main.rig"), "w").write(src)
        json.dump({"kind": "out", "out": out, "area": "ctx"}, open(os.path.join(d, "expect.json"), "w"))
