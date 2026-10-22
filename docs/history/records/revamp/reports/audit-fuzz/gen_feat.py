#!/usr/bin/env python3
"""Feature-dense Rig programs built from snippets with modelled output."""
import json, os, random, sys, struct as pystruct

INTT = {"I8": (8, True), "I16": (16, True), "I32": (32, True), "Int": (64, True),
        "I128": (128, True), "U8": (8, False), "U16": (16, False), "U32": (32, False),
        "U64": (64, False), "U128": (128, False)}


def rng(t):
    b, s = INTT[t]
    return (-(1 << (b - 1)), (1 << (b - 1)) - 1) if s else (0, (1 << b) - 1)


def lit(v):
    return f"({v})" if v < 0 else str(v)


def b2s(b):
    return "true" if b else "false"


def tdiv(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def trem(a, b):
    return a - b * tdiv(a, b)


class S:
    def __init__(self):
        self.decls = []
        self.body = []
        self.out = []


# ---------------------------------------------------------------- match on ints
def sn_match_int(r, k):
    s = S()
    t = r.choice(["Int", "U8", "I16", "I32", "U32", "I8"])
    lo_t, hi_t = rng(t)
    lo_t = max(lo_t, -50)
    hi_t = min(hi_t, 300)
    arms = []  # (pattern_text, predicate, result_text, resultfn)
    used_lits = set()
    covered = set()
    for _ in range(r.randint(1, 5)):
        kind = r.random()
        res_v = r.randint(-100, 100)
        if kind < 0.3:
            vals = sorted(set(r.randint(lo_t, min(hi_t, 40)) for _ in range(r.randint(1, 3))))
            vals = [v for v in vals if v not in used_lits and v not in covered]
            if not vals:
                continue
            used_lits.update(vals)
            covered.update(vals)
            arms.append((", ".join(str(v) for v in vals), (lambda vs: lambda n: n in vs)(set(vals)), lit(res_v), (lambda c: lambda n: c)(res_v)))
        elif kind < 0.55:
            a = r.randint(lo_t, min(hi_t, 60))
            b = r.randint(a + 1, min(hi_t + 1, a + 30))
            rngset = set(range(a, b))
            if rngset & covered:
                continue
            covered |= rngset
            arms.append((f"{a}..{b}", (lambda a, b: lambda n: a <= n < b)(a, b), lit(res_v), (lambda c: lambda n: c)(res_v)))
        elif kind < 0.85:
            m = r.randint(2, 5)
            rem = r.randint(0, m - 1)
            name = f"q{k}"
            if t.startswith("U"):
                arms.append((f"{name} if {name} % {m} == {rem}", (lambda m, rem: lambda n: n % m == rem)(m, rem),
                             f"Int({name}) + {lit(res_v)}", (lambda c: lambda n: n + c)(res_v)))
            else:
                arms.append((f"{name} if {name} % {m} == {rem}", (lambda m, rem: lambda n: trem(n, m) == rem)(m, rem),
                             f"Int({name}) + {lit(res_v)}", (lambda c: lambda n: n + c)(res_v)))
        else:
            thr = r.randint(lo_t, hi_t)
            arms.append((f"_ if n > {lit(thr)}", (lambda thr: lambda n: n > thr)(thr), lit(res_v), (lambda c: lambda n: c)(res_v)))
    dflt = r.randint(-100, 100)
    fn = f"cls_{k}"
    lines = [f"fun {fn}(n: {t}) -> Int", "  match n"]
    for p, _, rt, _ in arms:
        lines.append(f"    {p} => {rt}")
    lines.append(f"    _ => {lit(dflt)}")
    s.decls.append("\n".join(lines))
    probes = [r.randint(lo_t, hi_t) for _ in range(r.randint(2, 6))]
    res = []
    for n in probes:
        v = dflt
        for _, pred, _, f in arms:
            if pred(n):
                v = f(n)
                break
        res.append(v)
    s.body.append(f"  print({', '.join(f'{fn}({lit(n)})' for n in probes)})")
    s.out.append(" ".join(str(v) for v in res))
    return s


# ---------------------------------------------------------------- enums
def sn_enum(r, k):
    s = S()
    E = f"Sh{k}"
    s.decls.append(f"""enum {E}
  circle(r: Int)
  rect(w: Int, h: Int)
  dot
  tri(a: Int, b: Int, c: Int)

  fun area(?self) -> Int
    match self
      .circle(r) => 3 * r * r
      .rect(w, h) => w * h
      .dot => 0
      .tri(a, b, c) => a + b + c

  fun kind(?self) -> String
    match self
      .circle, .dot => "round"
      .rect(w, h) if w == h => "square"
      .rect => "rect"
      _ => "other"
""")
    vals = []
    for i in range(r.randint(2, 5)):
        c = r.randint(0, 3)
        if c == 0:
            x = r.randint(0, 9)
            vals.append((f"{E}.circle(r: {x})" if r.random() < 0.5 else f"{E}.circle({x})", ("circle", x)))
        elif c == 1:
            w, h = r.randint(0, 9), r.randint(0, 9)
            if r.random() < 0.3:
                h = w
            vals.append((f"{E}.rect(w: {w}, h: {h})", ("rect", w, h)))
        elif c == 2:
            vals.append((f"{E}.dot", ("dot",)))
        else:
            a, b, cc = r.randint(0, 9), r.randint(0, 9), r.randint(0, 9)
            vals.append((f"{E}.tri(a: {a}, b: {b}, c: {cc})", ("tri", a, b, cc)))

    def area(v):
        return {"circle": lambda: 3 * v[1] * v[1], "rect": lambda: v[1] * v[2], "dot": lambda: 0, "tri": lambda: v[1] + v[2] + v[3]}[v[0]]()

    def kind(v):
        if v[0] in ("circle", "dot"):
            return "round"
        if v[0] == "rect":
            return "square" if v[1] == v[2] else "rect"
        return "other"

    def show(v):
        if v[0] == "circle":
            return f".circle(r: {v[1]})"
        if v[0] == "rect":
            return f".rect(w: {v[1]}, h: {v[2]})"
        if v[0] == "dot":
            return ".dot"
        return f".tri(a: {v[1]}, b: {v[2]}, c: {v[3]})"

    for i, (txt, v) in enumerate(vals):
        n = f"e{k}_{i}"
        s.body.append(f"  {n} = {txt}")
        s.body.append(f"  print({n}.area(), {n}.kind(), {n})")
        s.out.append(f"{area(v)} {kind(v)} {show(v)}")
    # write through match !e
    i = r.randrange(len(vals))
    n = f"e{k}_{i}"
    add = r.randint(1, 5)
    s.body.append(f"""  match !{n}
    .circle(r) => r += {add}
    .rect(w, h)
      w *= {add}
      h = w
    .tri(a, _, c) => a = c
    .dot => print("dot")""")
    v = vals[i][1]
    if v[0] == "circle":
        v = ("circle", v[1] + add)
    elif v[0] == "rect":
        v = ("rect", v[1] * add, v[1] * add)
    elif v[0] == "tri":
        v = ("tri", v[3], v[2], v[3])
    else:
        s.out.append("dot")
    s.body.append(f"  print({n})")
    s.out.append(show(v))
    vals[i] = (E + show(v), v)
    # equality
    j = r.randrange(len(vals))
    s.body.append(f"  print(e{k}_{j} == {vals[j][0]}, e{k}_{j} == .dot, e{k}_{j} != .circle(r: 1))")
    vj = vals[j][1]
    s.out.append(f"true {b2s(vj[0] == 'dot')} {b2s(vj != ('circle', 1))}")
    # plain enum with values
    P = f"St{k}"
    base = r.randint(0, 50)
    s.decls.append(f"enum {P}\n  lo = {base}\n  mid\n  hi = {base + 10}\n")
    s.body.append(f"  p{k}: {P} = .mid\n  print(Int(p{k}), Int({P}.hi), p{k} == .mid, U8({P}.lo))")
    s.out.append(f"{base + 1} {base + 10} true {base}")
    return s


# ---------------------------------------------------------------- structs
def sn_struct(r, k):
    s = S()
    T = f"Acct{k}"
    dflt = r.randint(0, 20)
    s.decls.append(f"""struct {T}
  owner: String
  balance: Int = {dflt}
  frozen: Bool = false

  fun open(name: String) -> Self
    {T}(owner: name)

  fun can_pay(?self, amount: Int) -> Bool
    not self.frozen and self.balance >= amount

  sub pay(!self, amount: Int)
    self.balance -= amount

  sub freeze(!self)
    self.frozen = true

  fun close(<self) -> Int
    self.balance
""")
    name = r.choice(["ada", "bob", "cy"])
    bal = dflt
    frozen = False
    use_open = r.random() < 0.5
    if use_open:
        s.body.append(f'  a{k} = {T}.open("{name}")')
    else:
        bal = r.randint(0, 100)
        s.body.append(f'  a{k} = {T}(owner: "{name}", balance: {bal})')
    for _ in range(r.randint(1, 5)):
        c = r.random()
        if c < 0.6:
            amt = r.randint(0, 50)
            s.body.append(f"  !a{k}.pay({amt}) if a{k}.can_pay({amt})")
            if not frozen and bal >= amt:
                bal -= amt
        elif c < 0.75:
            s.body.append(f"  !a{k}.freeze()")
            frozen = True
        else:
            amt = r.randint(0, 30)
            s.body.append(f"  a{k}.balance += {amt}")
            bal += amt
    s.body.append(f"  print(a{k}, a{k}.can_pay(1))")
    s.out.append(f'{T}(owner: "{name}", balance: {bal}, frozen: {b2s(frozen)}) {b2s(not frozen and bal >= 1)}')
    s.body.append(f"  print(<a{k}.close())")
    s.out.append(str(bal))
    # struct equality and nested struct
    x, y = r.randint(-9, 9), r.randint(-9, 9)
    P = f"Pt{k}"
    s.decls.append(f"struct {P}\n  x: Int\n  y: Int = 0\n\n  fun plus(?self, o: ?{P}) -> {P}\n    {P}(x: self.x + o.x, y: self.y + o.y)\n")
    s.body.append(f"  p{k} = {P}(x: {lit(x)}, y: {lit(y)})\n  q{k} = {P}(x: {lit(y)})\n  print(p{k}.plus(?q{k}), p{k} == q{k}, [p{k}] == [p{k}], {P}(x: 1) == {P}(x: 1, y: 0))")
    s.out.append(f"{P}(x: {x + y}, y: {y}) {b2s(x == y and y == 0)} true true")
    return s


# ---------------------------------------------------------------- optionals
def sn_opt(r, k):
    s = S()
    th = r.randint(-5, 5)
    s.decls.append(f"""fun half{k}(n: Int) -> Int?
  return none if n % 2 != 0
  n / 2

fun pos{k}(n: Int) -> Int?
  n if n > {lit(th)} else none

fun chain{k}(n: Int) -> Int?
  pos{k}(half{k}(half{k}(n)?)?)? + 1

fun first{k}(n: Int) -> Int
  x = half{k}(n) ?? return -1
  y = pos{k}(x) ?? return -2
  x + y
""")

    def half(n):
        return None if trem(n, 2) != 0 else tdiv(n, 2)

    def pos(n):
        return n if n > th else None

    def chain(n):
        a = half(n)
        if a is None:
            return None
        b = half(a)
        if b is None:
            return None
        c = pos(b)
        if c is None:
            return None
        return c + 1

    def first(n):
        x = half(n)
        if x is None:
            return -1
        y = pos(x)
        if y is None:
            return -2
        return x + y

    def sh(v):
        return "none" if v is None else str(v)

    ns = [r.randint(-20, 40) for _ in range(r.randint(2, 5))]
    for n in ns:
        d = r.randint(-9, 9)
        s.body.append(f"  print(chain{k}({lit(n)}), first{k}({lit(n)}), half{k}({lit(n)}) ?? pos{k}({lit(n)}) ?? {lit(d)}, half{k}({lit(n)}) == none)")
        h = half(n)
        alt = h if h is not None else (pos(n) if pos(n) is not None else d)
        s.out.append(f"{sh(chain(n))} {first(n)} {alt} {b2s(h is None)}")
        s.body.append(f"""  if half{k}({lit(n)}) as a{k} and a{k} > 0 and pos{k}(a{k}) as b{k}
    print("both", a{k}, b{k})
  else
    print("no")""")
        a = half(n)
        if a is not None and a > 0 and pos(a) is not None:
            s.out.append(f"both {a} {pos(a)}")
        else:
            s.out.append("no")
    # optional struct field and <p.f take
    s.decls.append(f"struct Hold{k}\n  v: Int?\n")
    iv = r.randint(0, 9)
    s.body.append(f"""  h{k} = Hold{k}(v: {iv})
  t{k} = <h{k}.v
  print(t{k}, h{k}.v, t{k} ?? 0)""")
    s.out.append(f"{iv} none {iv}")
    return s


# ---------------------------------------------------------------- errors
def sn_err(r, k):
    s = S()
    lim = r.randint(3, 8)
    s.decls.append(f"""error E{k}
  neg
  big

fun check{k}(n: Int) -> Int!
  return E{k}.neg if n < 0
  return .big if n > {lim}
  n * 2

fun twice{k}(n: Int) -> Int!
  check{k}(n)! + check{k}(n + 1)!

sub log{k}(n: Int)!
  defer print("d{k}", n)
  errdefer print("ed{k}", n)
  _ = check{k}(n)!
  print("ok{k}", n)

fun safe{k}(n: Int) -> Int
  twice{k}(n) catch |e|
    return -100 if e == E{k}.neg
    -200
""")

    def check(n):
        if n < 0:
            return ("err", "neg")
        if n > lim:
            return ("err", "big")
        return ("ok", n * 2)

    def twice(n):
        a = check(n)
        if a[0] == "err":
            return a
        b = check(n + 1)
        if b[0] == "err":
            return b
        return ("ok", a[1] + b[1])

    def safe(n):
        t = twice(n)
        if t[0] == "err":
            return -100 if t[1] == "neg" else -200
        return t[1]

    for _ in range(r.randint(2, 4)):
        n = r.randint(-3, lim + 2)
        d = r.randint(-9, 9)
        s.body.append(f"  print(safe{k}({lit(n)}), twice{k}({lit(n)}) catch {lit(d)})")
        t = twice(n)
        s.out.append(f"{safe(n)} {t[1] if t[0] == 'ok' else d}")
        s.body.append(f"  log{k}({lit(n)}) catch |e| print(\"caught\", e)")
        c = check(n)
        if c[0] == "ok":
            s.out.append(f"ok{k} {n}")
            s.out.append(f"d{k} {n}")
        else:
            s.out.append(f"ed{k} {n}")
            s.out.append(f"d{k} {n}")
            s.out.append(f"caught .{c[1]}")
        s.body.append(f"""  m{k}_{_} = check{k}({lit(n)}) catch |err|
    print("failed:", err)
    0
  print(m{k}_{_})""")
        if c[0] == "ok":
            s.out.append(str(c[1]))
        else:
            s.out.append(f"failed: .{c[1]}")
            s.out.append("0")
    return s


# ---------------------------------------------------------------- closures
def sn_closure(r, k):
    s = S()
    start = r.randint(0, 50)
    s.decls.append(f"""fun counter{k}(start: Int) -> *fun(Int) -> Int
  count: *Cell[Int] = *Cell(start)
  *|+count, step|
    count.set(count.get() + step)
    count.get()

sub each{k}(xs: ?Vec[Int], f: ?sub(Int))
  for x in xs
    f(x)

fun apply{k}(f: ?fun(Int) -> Int, x: Int) -> Int
  f(x)
""")
    steps = [r.randint(-5, 10) for _ in range(r.randint(1, 4))]
    s.body.append(f"  nx{k} = counter{k}({start})")
    c = start
    outs = []
    for st in steps:
        c += st
        outs.append(str(c))
    s.body.append(f"  print({', '.join(f'nx{k}({lit(st)})' for st in steps)})")
    s.out.append(" ".join(outs))
    xs = [r.randint(-9, 9) for _ in range(r.randint(0, 5))]
    s.body.append(f"  v{k}: Vec[Int] = Vec()")
    for x in xs:
        s.body.append(f"  !v{k}.push({lit(x)})")
    m = r.randint(1, 5)
    s.body.append(f"""  tot{k} = 0
  each{k}(?v{k}, |!tot{k}, n| tot{k} += n * {m})
  kk{k} = {m}
  addk{k} = |+kk{k}, a: Int| a + kk{k}
  print(tot{k}, apply{k}(?addk{k}, 1), apply{k}(|x| x * x, {m}), addk{k}(10))""")
    s.out.append(f"{sum(xs) * m} {1 + m} {m * m} {10 + m}")
    # owned closures in a vec, clone, weak
    s.body.append(f"""  hs{k}: Vec[*fun(Int) -> Int] = Vec()
  !hs{k}.push(<nx{k})
  !hs{k}.push(*|x| x * 10)
  for h in ?hs{k}
    print(h(3))""")
    s.out.append(str(c + 3))
    s.out.append("30")
    # closure calling captured closure, move capture of vec
    s.body.append(f"""  base{k} = |x: Int| x + {m}
  outer{k} = |?base{k}, y: Int| base{k}(y) * 2
  print(outer{k}(4))
  w{k}: Vec[Int] = Vec()
  !w{k}.push({m})
  own{k} = *|<w{k}| w{k}.len
  print(own{k}())""")
    s.out.append(str((4 + m) * 2))
    s.out.append("1")
    return s


# ---------------------------------------------------------------- generics
def sn_generic(r, k):
    s = S()
    s.decls.append(f"""fun mx{k}[T](a: T, b: T) -> T
  a if a > b else b

struct Pair{k}[T, U]
  first: T
  second: U

  fun left(?self) -> T
    self.first

  fun swap(?self) -> Pair{k}[U, T]
    Pair{k}(first: self.second, second: self.first)

enum Opt{k}[T]
  some(value: T)
  nothing

  fun or(?self, d: T) -> T
    match self
      .some(v) => v
      .nothing => d

struct Ring{k}[T, n: Int]
  items: [n]T
  head: Int = 0

  sub put(!self, x: T)
    self.items[self.head % n] = x
    self.head += 1

fun sum{k}[n: Int](xs: [n]Int) -> Int
  t = 0
  for x in xs
    t += x
  t

sub rep{k}[T, n: Int](x: T)
  for i in 0..n
    print(i, x)
""")
    a, b = r.randint(-50, 50), r.randint(-50, 50)
    t = r.choice(["U8", "I16", "Int", "U128", "I32"])
    lo, hi = rng(t)
    a2, b2 = r.randint(max(lo, 0), min(hi, 200)), r.randint(max(lo, 0), min(hi, 200))
    s.body.append(f"  sm{k}: {t} = {a2}\n  print(mx{k}({lit(a)}, {lit(b)}), mx{k}(sm{k}, {b2}), mx{k}(1.5, 2.5), mx{k}(\"ab\", \"b\"))")
    s.out.append(f"{max(a, b)} {max(a2, b2)} 2.5 b")
    x = r.randint(0, 99)
    s.body.append(f"""  pr{k} = Pair{k}(first: {x}, second: "s{x}")
  print(pr{k}.left(), pr{k}.swap(), pr{k}.swap().swap().second)""")
    s.out.append(f'{x} Pair{k}(first: "s{x}", second: {x}) s{x}')
    y = r.randint(0, 9)
    s.body.append(f"""  o{k}: Opt{k}[Int] = .some({y})
  n{k} = Opt{k}[String].nothing
  print(o{k}.or(5), n{k}.or("dflt"), o{k})""")
    s.out.append(f"{y} dflt .some(value: {y})")
    n = r.randint(1, 5)
    puts = [r.randint(0, 9) for _ in range(r.randint(0, 8))]
    items = [0] * n
    s.body.append(f"  rg{k} = Ring{k}(items: [{n} of 0])")
    for i, p in enumerate(puts):
        s.body.append(f"  !rg{k}.put({p})")
        items[i % n] = p
    s.body.append(f"  print(rg{k}.items, rg{k}.head)")
    s.out.append(f"[{', '.join(map(str, items))}] {len(puts)}")
    arr = [r.randint(-9, 9) for _ in range(r.randint(1, 5))]
    s.body.append(f"  print(sum{k}([{', '.join(map(lit, arr))}]))")
    s.out.append(str(sum(arr)))
    c = r.randint(1, 3)
    s.body.append(f'  rep{k}[String, {c}]("hi")')
    for i in range(c):
        s.out.append(f"{i} hi")
    return s


# ---------------------------------------------------------------- vec
def sn_vec(r, k):
    s = S()
    et = r.choice(["Int", "U8", "I32", "String", "U64"])
    model = []
    s.body.append(f"  v{k}: Vec[{et}] = Vec()")

    def val():
        if et == "String":
            return '"' + r.choice(["a", "bb", "ccc", "", "zz"]) + '"'
        lo, hi = rng(et)
        return str(r.randint(max(lo, 0), min(hi, 250)))

    def show(v):
        return v if et == "String" else v

    for _ in range(r.randint(1, 10)):
        c = r.random()
        if c < 0.55:
            x = val()
            s.body.append(f"  !v{k}.push({x})")
            model.append(x)
        elif c < 0.7:
            s.body.append(f"  print(!v{k}.pop())")
            if model:
                p = model.pop()
                s.out.append(p.strip('"') if et == "String" else p)
            else:
                s.out.append("none")
        elif c < 0.8 and model:
            i = r.randrange(len(model))
            x = val()
            s.body.append(f"  v{k}[{i}] = {x}")
            model[i] = x
        elif c < 0.9:
            i = r.randint(0, len(model) + 1)
            s.body.append(f"  print(v{k}.get({i}))")
            if i < len(model):
                s.out.append(model[i].strip('"') if et == "String" else model[i])
            else:
                s.out.append("none")
        else:
            s.body.append(f"  print(v{k}.len)")
            s.out.append(str(len(model)))
    s.body.append(f"  print(v{k})")
    if et == "String":
        s.out.append("[" + ", ".join(model) + "]")
    else:
        s.out.append("[" + ", ".join(model) + "]")
    if et != "String":
        s.body.append(f"""  tt{k}: {et} = 0
  for x in ?v{k}
    tt{k} +%= x
  for x, i in !v{k}
    x = x +% {et}(i)
  print(tt{k}, v{k})""")
        b, sg = INTT[et]
        tot = sum(int(x) for x in model) % (1 << b)
        newm = [str((int(x) + i) % (1 << b)) for i, x in enumerate(model)]
        s.out.append(f"{tot} [{', '.join(newm)}]")
    s.body.append(f"""  n{k} = 0
  for _ in <v{k}
    n{k} += 1
  print(n{k})""")
    s.out.append(str(len(model)))
    # Cell of Vec
    s.body.append(f"""  log{k}: *Cell[Vec[Int]] = *Cell(Vec())
  oth{k} = +log{k}
  log{k}.push(1)
  oth{k}.push(2)
  log{k}[0] = 10
  print(log{k}.len, log{k}[0], oth{k}.get(1), log{k}.get(9))
  if log{k}.pop() as last
    print("popped", last)""")
    s.out.append("2 10 2 none")
    s.out.append("popped 2")
    return s


# ---------------------------------------------------------------- drops
def sn_drop(r, k):
    s = S()
    s.decls.append(f"""struct Res{k}
  id: Int

  drop(!self)
    print("rel{k}", self.id)

sub eat{k}(x: Res{k})
  print("eat{k}", x.id)

struct Two{k}
  a: *Res{k}
  b: *Res{k}

  drop(!self)
    print("two{k}")
""")
    # sequence inside a helper sub
    n = r.randint(2, 5)
    lines = [f"sub scope{k}"]
    live = []
    out = []
    for i in range(n):
        lines.append(f"  x{i} = Res{k}(id: {i})")
        live.append(i)
    for i in list(live):
        c = r.random()
        if c < 0.25:
            lines.append(f"  eat{k}(<x{i})")
            out += [f"eat{k} {i}", f"rel{k} {i}"]
            live.remove(i)
        elif c < 0.45:
            lines.append(f"  -x{i}")
            out.append(f"rel{k} {i}")
            live.remove(i)
        elif c < 0.55:
            lines.append(f"  y{i} = <x{i}")
            live.remove(i)
            live.append(i)  # now declared later
    lines.append(f'  print("end{k}")')
    out.append(f"end{k}")
    # drop in reverse declaration order: y bindings declared later
    for i in reversed(live):
        out.append(f"rel{k} {i}")
    s.decls.append("\n".join(lines) + "\n")
    s.body.append(f"  scope{k}()")
    s.out += out
    # shared handles
    s.body.append(f"""  sh{k} = *Res{k}(id: 100)
  sh2{k} = +sh{k}
  -sh{k}
  print("alive", sh2{k}.id)
  wk{k} = ~sh2{k}
  print(wk{k}.upgrade() == none)
  -sh2{k}
  print(wk{k}.upgrade() == none)""")
    s.out += ["alive 100", "false", f"rel{k} 100", "true"]
    s.body.append(f"""  tw{k} = Two{k}(a: *Res{k}(id: 1), b: *Res{k}(id: 2))
  -tw{k}""")
    s.out += [f"two{k}", f"rel{k} 2", f"rel{k} 1"]
    return s


# ---------------------------------------------------------------- strings/slices/bytes
def sn_str(r, k):
    s = S()
    words = ["hello", "rig", "abc", "zebra", "a", "", "hello, world"]
    w = r.choice(words[:5] + words[6:])
    a = r.randint(0, len(w))
    b = r.randint(a, len(w))
    s.body.append(f'  s{k} = "{w}"')
    s.body.append(f"  print(s{k}[{a}..{b}], s{k}.len, s{k}.get({len(w)}), s{k}[{a}..], s{k}[..{b}])")
    s.out.append(f"{w[a:b]} {len(w)} none {w[a:]} {w[:b]}")
    if w:
        i = r.randrange(len(w))
        s.body.append(f"  print(s{k}[{i}], s{k}.get({i}))")
        s.out.append(f"{ord(w[i])} {ord(w[i])}")
    w2 = r.choice(words)
    s.body.append(f'  print(s{k} < "{w2}", s{k} == "{w2}", s{k} >= "{w2}")')
    bw, bw2 = w.encode(), w2.encode()
    s.out.append(f"{b2s(bw < bw2)} {b2s(bw == bw2)} {b2s(bw >= bw2)}")
    s.body.append(f"""  cnt{k} = 0
  for ch in s{k}
    cnt{k} += 1 if ch == 108 else 0
  print(cnt{k})""")
    s.out.append(str(w.count("l")))
    arr = [r.randint(-50, 50) for _ in range(r.randint(1, 8))]
    n = len(arr)
    a = r.randint(0, n)
    b = r.randint(a, n)
    s.decls.append(f"""fun total{k}(xs: []Int) -> Int
  t = 0
  for x in xs
    t += x
  t

sub bump{k}(xs: ![]Int, d: Int)
  for x in !xs
    x += d
""")
    s.body.append(f"""  ar{k} = [{', '.join(map(lit, arr))}]
  sl{k} = ?ar{k}[{a}..{b}]
  print(sl{k}, sl{k}.len, total{k}(sl{k}), total{k}(?ar{k}[..]))""")
    s.out.append(f"[{', '.join(map(str, arr[a:b]))}] {b - a} {sum(arr[a:b])} {sum(arr)}")
    d = r.randint(-5, 5)
    s.body.append(f"  bump{k}(!ar{k}[{a}..{b}], {lit(d)})\n  print(ar{k})")
    arr2 = arr[:a] + [x + d for x in arr[a:b]] + arr[b:]
    s.out.append(f"[{', '.join(map(str, arr2))}]")
    if n >= 2:
        i, j = r.randrange(n), r.randrange(n)
        s.body.append(f"  !ar{k}.swap({i}, {j})\n  print(ar{k})")
        arr2[i], arr2[j] = arr2[j], arr2[i]
        s.out.append(f"[{', '.join(map(str, arr2))}]")
    fv = r.randint(-3, 3)
    s.body.append(f"  !ar{k}[{a}..{b}].fill({lit(fv)})\n  print(ar{k})")
    arr2 = arr2[:a] + [fv] * (b - a) + arr2[b:]
    s.out.append(f"[{', '.join(map(str, arr2))}]")
    # bytes
    t = r.choice(["U16", "U32", "U64", "I16", "I32", "Int", "U8", "I8", "U128", "I128"])
    end = r.choice([".little", ".big"])
    bb, sg = INTT[t]
    lo, hi = rng(t)
    v = r.randint(lo, hi)
    size = bb // 8
    off = r.randint(0, 16 - size)
    s.body.append(f"""  pg{k}: [16]U8 = [16 of 0]
  !pg{k}.write[{t}, {end}]({off}, {lit(v) if lo <= v <= hi else v})
  print(pg{k}.read[{t}, {end}]({off}), pg{k}[{off}])""")
    bs = v.to_bytes(size, "little" if end == ".little" else "big", signed=sg)
    s.out.append(f"{v} {bs[0]}")
    return s


# ---------------------------------------------------------------- loops
def sn_loop(r, k):
    s = S()
    n1, n2 = r.randint(1, 5), r.randint(1, 5)
    cj = r.randint(0, 4)
    bi = r.randint(0, 5)
    s.body.append(f"""  :outer{k} for i in 0..{n1}
    for j in 0..{n2}
      continue :outer{k} if j > i + {cj}
      break :outer{k} if i == {bi}
      print("L{k}", i, j)""")
    done = False
    for i in range(n1):
        for j in range(n2):
            if j > i + cj:
                break
            if i == bi:
                done = True
                break
            s.out.append(f"L{k} {i} {j}")
        if done:
            break
    lim = r.randint(0, 8)
    brk = r.randint(0, 10)
    s.body.append(f"""  i{k} = 0
  while i{k} < {lim} : i{k} += 1
    continue if i{k} == 1
    break if i{k} == {brk}
    print("W{k}", i{k})
  else
    print("E{k}")""")
    i = 0
    broke = False
    while i < lim:
        if i == 1:
            i += 1
            continue
        if i == brk:
            broke = True
            break
        s.out.append(f"W{k} {i}")
        i += 1
    if not broke:
        s.out.append(f"E{k}")
    xs = [r.randint(0, 9) for _ in range(4)]
    tgt = r.randint(0, 9)
    s.decls.append(f"""fun idx{k}(xs: ?[4]Int, target: Int) -> Int
  for x, i in xs
    break i if x == target
  else
    -1
""")
    s.body.append(f"  xs{k} = [{', '.join(map(str, xs))}]\n  print(idx{k}(?xs{k}, {tgt}))")
    s.out.append(str(xs.index(tgt) if tgt in xs else -1))
    n = r.randint(1, 60)
    s.body.append(f"""  n{k} = {n}
  st{k} = 0
  last{k} = while true
    break st{k} if n{k} == 1
    n{k} = n{k} / 2 if n{k} % 2 == 0 else 3 * n{k} + 1
    st{k} += 1
  print(last{k})""")
    steps = 0
    while n != 1:
        n = n // 2 if n % 2 == 0 else 3 * n + 1
        steps += 1
    s.out.append(str(steps))
    return s


# ---------------------------------------------------------------- box list
def sn_box(r, k):
    s = S()
    s.decls.append(f"""struct Node{k}
  value: Int
  next: Box[Node{k}]?

struct Stack{k}
  top: Box[Node{k}]?

  sub push(!self, v: Int)
    self.top = Box(Node{k}(value: v, next: <self.top))

  fun pop(!self) -> Int?
    if <self.top as n
      self.top = <n.next
      return n.value
    none

  sub reverse(!self)
    cur = <self.top
    prev: Box[Node{k}]? = none
    while <cur as n
      cur = <n.next
      n.next = <prev
      prev = <n
    self.top = <prev

enum Ex{k}
  num(n: Int)
  add(l: Box[Ex{k}], r: Box[Ex{k}])
  mul(l: Box[Ex{k}], r: Box[Ex{k}])

fun ev{k}(e: ?Box[Ex{k}]) -> Int
  match e
    .num(n) => n
    .add(l, r) => ev{k}(?l) + ev{k}(?r)
    .mul(l, r) => ev{k}(?l) * ev{k}(?r)
""")
    vals = [r.randint(-9, 9) for _ in range(r.randint(0, 6))]
    s.body.append(f"  st{k} = Stack{k}(top: none)")
    for v in vals:
        s.body.append(f"  !st{k}.push({lit(v)})")
    stack = list(vals)
    if r.random() < 0.5:
        s.body.append(f"  !st{k}.reverse()")
        stack.reverse()
    pops = r.randint(0, len(vals) + 1)
    res = []
    for _ in range(pops):
        res.append(str(stack.pop()) if stack else "none")
    if pops:
        s.body.append(f"  print({', '.join(f'!st{k}.pop()' for _ in range(pops))})")
        s.out.append(" ".join(res))

    def gen(d):
        if d == 0 or r.random() < 0.3:
            v = r.randint(-9, 9)
            return f"Box(Ex{k}.num({lit(v)}))", v
        a, va = gen(d - 1)
        b, vb = gen(d - 1)
        if r.random() < 0.5:
            return f"Box(Ex{k}.add(l: {a}, r: {b}))", va + vb
        return f"Box(Ex{k}.mul(l: {a}, r: {b}))", va * vb

    e, v = gen(3)
    s.body.append(f"  ex{k} = {e}\n  print(ev{k}(?ex{k}))")
    s.out.append(str(v))
    return s


# ---------------------------------------------------------------- signal / cell
def sn_signal(r, k):
    s = S()
    sets = [r.randint(0, 9) for _ in range(r.randint(1, 4))]
    s.body.append(f"""  sig{k}: *Signal[Int] = *Signal(0)
  seen{k}: *Cell[Int] = *Cell(0)
  sig{k}.subscribe(*|~sig{k}, +seen{k}|
    if sig{k}.upgrade() as c
      seen{k}.set(seen{k}.get() + c.get())
      print("sig{k}", c.get()))""")
    for v in sets:
        s.body.append(f"  sig{k}.set({v})")
        s.out.append(f"sig{k} {v}")
    s.body.append(f"  print(seen{k}.get(), seen{k}.replace(7), seen{k}.get())")
    s.out.append(f"{sum(sets)} {sum(sets)} 7")
    return s


# ---------------------------------------------------------------- defaults/kwargs
def sn_kw(r, k):
    s = S()
    d1, d2 = r.randint(-5, 5), r.randint(1, 5)
    s.decls.append(f"""K{k} = {d2}

fun sc{k}(n: Int, by: Int = K{k}, off: Int = {lit(d1)}, _: Bool = false) -> Int
  n * by + off
""")
    calls = []
    for _ in range(r.randint(1, 4)):
        n = r.randint(-9, 9)
        c = r.randint(0, 4)
        if c == 0:
            calls.append((f"sc{k}({lit(n)})", n * d2 + d1))
        elif c == 1:
            b = r.randint(-3, 3)
            calls.append((f"sc{k}({lit(n)}, {lit(b)})", n * b + d1))
        elif c == 2:
            o = r.randint(-3, 3)
            calls.append((f"sc{k}(off: {lit(o)}, n: {lit(n)})", n * d2 + o))
        elif c == 3:
            b, o = r.randint(-3, 3), r.randint(-3, 3)
            calls.append((f"sc{k}({lit(n)}, off: {lit(o)}, by: {lit(b)})", n * b + o))
        else:
            calls.append((f"sc{k}({lit(n)}, {d2}, {d1}, true)", n * d2 + d1))
    s.body.append(f"  print({', '.join(c for c, _ in calls)})")
    s.out.append(" ".join(str(v) for _, v in calls))
    return s


SNIPPETS = {"match_int": sn_match_int, "enum": sn_enum, "struct": sn_struct, "opt": sn_opt,
            "err": sn_err, "closure": sn_closure, "generic": sn_generic, "vec": sn_vec,
            "drop": sn_drop, "str": sn_str, "loop": sn_loop, "box": sn_box, "signal": sn_signal,
            "kw": sn_kw}


def gen_prog(seed, only=None):
    r = random.Random(seed)
    names = [only] if only else r.sample(list(SNIPPETS), r.randint(2, 5))
    decls, body, out = [], [], []
    for i, nm in enumerate(names):
        s = SNIPPETS[nm](r, f"{i}")
        decls += s.decls
        body += s.body
        out += s.out
    src = "\n".join(decls) + "\nsub main\n" + "\n".join(body) + "\n"
    return src, "\n".join(out) + "\n", "+".join(names)


if __name__ == "__main__":
    root, n, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    only = sys.argv[4] if len(sys.argv) > 4 else None
    os.makedirs(root, exist_ok=True)
    for i in range(base, base + n):
        src, out, area = gen_prog(i, only)
        d = os.path.join(root, f"f{i:05d}")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "main.rig"), "w").write(src)
        json.dump({"kind": "out", "out": out, "area": area}, open(os.path.join(d, "expect.json"), "w"))
