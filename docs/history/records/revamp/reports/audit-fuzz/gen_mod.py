#!/usr/bin/env python3
"""Multi-module programs: main.rig + lib.rig + util.rig, with modelled output."""
import json, os, random, sys


def lit(v):
    return f"({v})" if v < 0 else str(v)


def gen(seed):
    r = random.Random(seed)
    base = r.randint(1, 20)
    secret = r.randint(1, 9)
    kmul = r.randint(1, 5)
    cval = r.randint(0, 50)
    util = f"""pub BASE = {base}
pub LIMIT: U8 = {r.randint(100, 250)}

pub fun one -> Int
  1

pub enum Color
  red = {cval}
  green
  blue

pub struct V2
  pub x: Int
  pub y: Int

  pub fun dot(?self, o: ?V2) -> Int
    self.x * o.x + self.y * o.y + bias()

fun bias -> Int
  0

pub type Byte = U8
"""
    lib = f"""use util

SECRET = {secret}
pub K = util.BASE * {kmul}
pub NAMES = ["n0", "n1", "n2"]

pub fun scale(n: Int, by: Int = SECRET, off: Int = util.BASE) -> Int
  n * by + off

pub fun pk[T](a: T, b: T, first: Bool = true) -> T
  a if first else b

pub struct Vault
  secret: Int
  pub label: String = "v"

  pub fun open(n: Int) -> Vault
    Vault(secret: n + SECRET)

  pub fun peek(?self, plus: Int = K) -> Int
    self.secret + plus

  pub sub bump(!self, by: Int = 1)
    self.secret += by

pub struct Box2[T]
  pub items: Vec[T]

  pub sub add(!self, x: T)
    !self.items.push(<x)

  pub fun count(?self) -> Int
    self.items.len

pub enum Shape
  dot
  circle(r: Int)
  rect(w: Int, h: Int)

  pub fun area(?self) -> Int
    match self
      .dot => 0
      .circle(r) => 3 * r * r
      .rect(w, h) => w * h

pub error LibErr
  bad
  worse

pub fun check(n: Int) -> Int!
  return LibErr.bad if n < 0
  return .worse if n > 100
  n + util.one()

pub struct Res
  pub id: Int

  drop(!self)
    print("rel", self.id)

pub sub each(xs: ?Vec[Int], f: ?sub(Int))
  for x in xs
    f(x)

pub fun counter(start: Int) -> *fun(Int) -> Int
  c: *Cell[Int] = *Cell(start)
  *|+c, step|
    c.set(c.get() + step)
    c.get()

pub fun color_num(c: util.Color) -> Int
  Int(c)
"""
    body, out = [], []
    K = base * kmul
    # scale with defaults and keywords
    calls = []
    for _ in range(r.randint(1, 3)):
        n = r.randint(-9, 9)
        c = r.randint(0, 3)
        if c == 0:
            calls.append((f"lib.scale({lit(n)})", n * secret + base))
        elif c == 1:
            b = r.randint(-5, 5)
            calls.append((f"lib.scale({lit(n)}, {lit(b)})", n * b + base))
        elif c == 2:
            o = r.randint(-5, 5)
            calls.append((f"lib.scale(off: {lit(o)}, n: {lit(n)})", n * secret + o))
        else:
            calls.append((f"lib.scale({lit(n)}, off: 0, by: lib.K)", n * K))
    body.append(f"  print({', '.join(c for c, _ in calls)})")
    out.append(" ".join(str(v) for _, v in calls))
    body.append(f"  print(lib.K, util.BASE, lib.NAMES[{(i := r.randint(0, 2))}], util.LIMIT > 50, lib.K * 2)")
    out.append(f"{K} {base} n{i} true {K * 2}")
    # generics across modules
    a, b = r.randint(0, 99), r.randint(0, 99)
    first = r.random() < 0.5
    body.append(f"  small: U8 = {a}")
    body.append(f"  print(lib.pk(small, {b}, {'true' if first else 'false'}), lib.pk(\"a\", \"b\"), lib.pk(1.5, 2.5, first: false))")
    out.append(f"{a if first else b} a 2.5")
    # vault: private field via pub methods
    n = r.randint(0, 50)
    body.append(f"  v = lib.Vault.open({n})")
    bumps = r.randint(0, 3)
    tot = n + secret
    for _ in range(bumps):
        by = r.randint(1, 5)
        if r.random() < 0.5:
            body.append(f"  !v.bump({by})")
            tot += by
        else:
            body.append("  !v.bump()")
            tot += 1
    body.append(f"  print(v.peek(), v.peek(0), v.peek(plus: 2), v.label)")
    out.append(f"{tot + K} {tot} {tot + 2} v")
    # local type with a lib name; generic box over a local type
    body.append("  p = Point(x: 3)\n  bx = lib.Box2[Point](items: Vec())\n  !bx.add(p)\n  !bx.add(Point(x: 4))\n  print(bx.count(), bx.items[1].x, p.x)")
    out.append("2 4 3")
    # enums across modules
    w, h = r.randint(0, 9), r.randint(0, 9)
    body.append(f"  s: lib.Shape = .rect(w: {w}, h: {h})\n  c = lib.Shape.circle({w})\n  print(s.area(), c.area(), s, lib.Shape.dot == .dot)")
    out.append(f"{w * h} {3 * w * w} .rect(w: {w}, h: {h}) true")
    body.append(f"""  match c
    .circle(rr) => print("circle", rr)
    _ => print("other")""")
    out.append(f"circle {w}")
    col = r.choice(["red", "green", "blue"])
    cv = {"red": cval, "green": cval + 1, "blue": cval + 2}[col]
    body.append(f"  col: util.Color = .{col}\n  print(lib.color_num(col), col, col == util.Color.{col})")
    out.append(f"{cv} .{col} true")
    # errors across modules
    for _ in range(r.randint(1, 3)):
        x = r.choice([-5, 0, 7, 100, 101, 500])
        body.append(f"""  q{_} = lib.check({x}) catch |e|
    print("err", e, e == lib.LibErr.bad)
    -1
  print(q{_})""")
        if x < 0:
            out += ["err .bad true", "-1"]
        elif x > 100:
            out += ["err .worse false", "-1"]
        else:
            out.append(str(x + 1))
    # drop glue across modules
    body.append("""  rs: Vec[*lib.Res] = Vec()
  keep = *lib.Res(id: 1)
  !rs.push(+keep)
  !rs.push(*lib.Res(id: 2))
  !rs.clear()
  print("kept", keep.id)""")
    out += ["rel 2", "kept 1"]
    # closures across modules
    xs = [r.randint(-5, 5) for _ in range(r.randint(0, 4))]
    body.append("  xs: Vec[Int] = Vec()")
    for x in xs:
        body.append(f"  !xs.push({lit(x)})")
    st = r.randint(0, 9)
    body.append(f"""  tot = 0
  lib.each(?xs, |!tot, x| tot += x)
  nx = lib.counter({st})
  print(tot, nx(1), nx(2))""")
    out.append(f"{sum(xs)} {st + 1} {st + 3}")
    # util struct
    body.append("  a2 = util.V2(x: 1, y: 2)\n  print(a2.dot(?(util.V2(x: 3, y: 4))))")
    out.append("11")
    out.append("rel 1")  # keep released at the end of main
    main = "use lib\nuse util\n\nstruct Point\n  x: Int\n\nfun scale -> Int\n  0\n\nsub main\n" + "\n".join(body) + "\n  print(scale())\n"
    out.insert(len(out) - 1, "0")
    return {"main.rig": main, "lib.rig": lib, "util.rig": util}, "\n".join(out) + "\n"


if __name__ == "__main__":
    root, n, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    os.makedirs(root, exist_ok=True)
    for i in range(base, base + n):
        files, out = gen(i)
        d = os.path.join(root, f"m{i:05d}")
        os.makedirs(d, exist_ok=True)
        for f, t in files.items():
            open(os.path.join(d, f), "w").write(t)
        json.dump({"kind": "out", "out": out, "area": "modules"}, open(os.path.join(d, "expect.json"), "w"))
