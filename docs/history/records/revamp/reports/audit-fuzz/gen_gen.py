#!/usr/bin/env python3
"""Generic functions and types instantiated with owning and Copy types.
Oracle: own_oracle (each resource released once, never used after)."""
import json, os, random, sys

PRELUDE = """struct R
  id: Int

  drop(!self)
    print("rel", self.id)

struct P
  a: R
  b: R

enum HR
  one(r: R)
  empty

error E
  bad

fun mk(id: Int) -> R
  print("new", id)
  R(id: id)

fun optr(id: Int) -> R?
  return none if id % 3 == 0
  mk(id)

sub look(r: ?R)
  print("use", r.id)

fun rt_bool(b: Bool) -> Bool
  b

fun rt_int(n: Int) -> Int
  n

fun pick[T](a: T, b: T, first: Bool) -> T
  if first
    return <a
  <b

fun keep_first[T](a: T, b: T) -> T
  a

fun ident[T](x: T) -> T
  x

fun cycle[T](x: T, n: Int) -> T
  cur = <x
  for _ in 0..n
    cur = ident(<cur)
  cur

fun wrap[T](x: T) -> T?
  x

fun unwrap_or[T](o: T?, d: T) -> T
  if <o as v
    return <v
  <d

fun first_some[T](a: T?, b: T?) -> T?
  if <a as x
    return <x
  <b

fun must[T](o: T?) -> T!
  if <o as x
    return <x
  E.bad

fun chain[T](o: T?) -> T?
  x = (<o)?
  x

sub swap_gen[T](a: !T, b: !T)
  swap(!a, !b)

fun first_ref[T, U](p: ?Pair[T, U]) -> ?T
  ?p.first

struct Pair[T, U]
  first: T
  second: U

  fun left(?self) -> ?T
    ?self.first

struct Shelf[T]
  items: Vec[T]

  sub add(!self, x: T)
    !self.items.push(<x)

  fun take(!self) -> T?
    !self.items.pop()

enum Maybe[T]
  just(v: T)
  nada

fun get_or[T](m: Maybe[T], d: T) -> T
  match <m
    .just(v) => v
    .nada => d

fun fill_shelf[T](a: T, b: T) -> Shelf[T]
  s = Shelf[T](items: Vec())
  !s.add(<a)
  !s.add(<b)
  s
"""

TYPES = {
    "R": ("mk({i})", ["look(?{x})"], True),
    "*R": ("*mk({i})", ['print("use", {x}.id)'], True),
    "Box[R]": ("Box(mk({i}))", ['print("use", {x}.id)'], True),
    "R?": ("optr({i})", ["if ?{x} as y{u}", '  print("use", y{u}.id)'], False),
    "Int": ("{i}", ['print("int", {x})'], True),
    "String": ('"s{i}"', ['print("str", {x})'], True),
    "HR": ("HR.one(r: mk({i}))", ["match ?{x}", "  .one(z{u}) => look(?z{u})", '  .empty => print("empty")'], False),
    "P": ("P(a: mk({i}), b: mk({j}))", ["look(?{x}.a)", "look(?{x}.b)"], False),
}
VEC_OK = ["*R", "Box[R]", "Int", "String"]


class G:
    def __init__(self, r):
        self.r = r
        self.n = 0

    def i(self):
        self.n += 1
        return self.n * 10

    def make(self, t):
        mk = TYPES[t][0]
        self.idn = getattr(self, "idn", 0) + 1
        i = self.idn * 10
        return mk.format(i=i, j=i + 1)

    def use(self, t, x, ind="  "):
        self.n += 1
        return [ind + l.format(x=x, u=self.n) for l in TYPES[t][1]]

    def call(self, lines, can_fail):
        r = self.r
        t = r.choice(list(TYPES))
        k0 = r.randint(0, 13)
        if t == "R?" and k0 in (3, 4, 5, 6, 7):
            t = "R"
        self.n += 1
        q = self.n
        res = f"r{self.n}"
        k = k0
        if k == 0:
            lines.append(f"  {res} = pick({self.make(t)}, {self.make(t)}, rt_bool({r.choice(['true', 'false'])}))")
            lines += self.use(t, res)
        elif k == 1:
            lines.append(f"  {res} = keep_first({self.make(t)}, {self.make(t)})")
            lines += self.use(t, res)
        elif k == 2:
            lines.append(f"  {res} = cycle({self.make(t)}, rt_int({r.randint(0, 3)}))")
            lines += self.use(t, res)
        elif k == 3:
            lines.append(f"  {res} = wrap({self.make(t)})")
            self.n += 1
            lines.append(f"  if ?{res} as w{self.n}")
            lines += self.use(t, f"w{self.n}", "    ")
        elif k == 4:
            some = r.random() < 0.5
            lines.append(f"  o{q}: {t}? = {self.make(t) if some else 'none'}")
            lines.append(f"  {res} = unwrap_or(<o{q}, {self.make(t)})")
            lines += self.use(t, res)
        elif k == 5:
            a = self.make(t) if r.random() < 0.5 else "none"
            b = self.make(t) if r.random() < 0.5 else "none"
            lines.append(f"  a{q}: {t}? = {a}")
            lines.append(f"  b{q}: {t}? = {b}")
            lines.append(f"  {res} = first_some(<a{q}, <b{q})")
            self.n += 1
            lines.append(f"  if ?{res} as w{self.n}")
            lines += self.use(t, f"w{self.n}", "    ")
        elif k == 6 and can_fail:
            some = r.random() < 0.6
            lines.append(f"  o{q}: {t}? = {self.make(t) if some else 'none'}")
            lines.append(f"  {res} = must(<o{q})!")
            lines += self.use(t, res)
        elif k == 7:
            some = r.random() < 0.6
            lines.append(f"  o{q}: {t}? = {self.make(t) if some else 'none'}")
            lines.append(f"  {res} = chain(<o{q})")
            self.n += 1
            lines.append(f"  if ?{res} as w{self.n}")
            lines += self.use(t, f"w{self.n}", "    ")
        elif k == 8:
            lines.append(f"  a{q} = {self.make(t)}")
            lines.append(f"  b{q} = {self.make(t)}")
            lines.append(f"  swap_gen(!a{q}, !b{q})")
            lines += self.use(t, f"a{q}")
            lines += self.use(t, f"b{q}")
        elif k == 9:
            u = r.choice(list(TYPES))
            lines.append(f"  {res} = Pair(first: {self.make(t)}, second: {self.make(u)})")
            lines.append(f"  f{q} = first_ref(?{res})")
            lines += self.use(t, f"f{q}")
            lines += self.use(u, f"{res}.second")
        elif k == 10 and t in VEC_OK:
            lines.append(f"  {res} = fill_shelf({self.make(t)}, {self.make(t)})")
            m = self.n
            lines.append(f"  !{res}.add({self.make(t)})")
            for _ in range(r.randint(0, 4)):
                self.n += 1
                lines.append(f"  if !{res}.take() as w{self.n}")
                lines += self.use(t, f"w{self.n}", "    ")
            lines.append(f"  print(\"int\", {res}.items.len)")
        elif k == 11:
            j = r.random() < 0.5
            lines.append(f"  m{q}: Maybe[{t}] = {'.just(' + self.make(t) + ')' if j else '.nada'}")
            lines.append(f"  {res} = get_or(<m{q}, {self.make(t)})")
            lines += self.use(t, res)
        elif k == 12:
            # generic closure use: map a value through a borrowed callable
            lines.append(f"  {res} = {self.make(t)}")
            lines.append(f"  c{q} = |x: ?{t}| 1")
            lines.append(f"  print(\"int\", c{q}(?{res}))")
            lines += self.use(t, res)
        else:
            lines.append(f"  {res} = ident(ident({self.make(t)}))")
            lines += self.use(t, res)


def gen(seed):
    r = random.Random(seed)
    g = G(r)
    subs, calls = [], []
    for h in range(r.randint(2, 4)):
        can_fail = r.random() < 0.4
        lines = []
        for _ in range(r.randint(2, 6)):
            g.call(lines, can_fail)
        if can_fail:
            subs.append(f"sub h{h}()!\n" + "\n".join(lines) + "\n")
            calls.append(f"  h{h}() catch |e| print(\"caught\", e)")
        else:
            subs.append(f"sub h{h}\n" + "\n".join(lines) + "\n")
            calls.append(f"  h{h}()")
    return PRELUDE + "\n" + "\n".join(subs) + "\nsub main\n" + "\n".join(calls) + "\n"


if __name__ == "__main__":
    root, n, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    os.makedirs(root, exist_ok=True)
    for i in range(base, base + n):
        d = os.path.join(root, f"g{i:05d}")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "main.rig"), "w").write(gen(i))
        json.dump({"kind": "own", "area": "generic"}, open(os.path.join(d, "expect.json"), "w"))
