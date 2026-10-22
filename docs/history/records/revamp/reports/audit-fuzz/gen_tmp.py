#!/usr/bin/env python3
"""Owned temporaries in nested calls, constructors and receivers, with a
propagating (`!` / `?`) sub-expression somewhere. Oracle: own_oracle."""
import json, os, random, sys

PRELUDE = ["""struct R
  id: Int

  drop(!self)
    print("rel", self.id)

  fun look(?self) -> Int
    print("use", self.id)
    self.id

struct P
  a: R
  b: R

struct Q
  h: *R
  o: R?

enum HR
  one(r: R)
  two(a: R, b: *R)
  empty

struct M
  r: R

  fun with(<self, n: Int) -> Int
    print("use", self.r.id)
    n + self.r.id

  fun peek(?self, n: Int) -> Int
    print("use", self.r.id)
    n

  sub put(!self, r: R)
    self.r = <r

error E
  bad

fun mk(id: Int) -> R
  print("new", id)
  R(id: id)

fun mkm(id: Int) -> M
  M(r: mk(id))

fun mayr(k: Int) -> R!
  return E.bad if k == 0
  mk(k)

fun may(k: Int) -> Int!
  return E.bad if k == 0
  k

fun optr(k: Int) -> R?
  return none if k == 0
  mk(k)

fun opt(k: Int) -> Int?
  return none if k == 0
  k

fun two(a: R, b: R) -> Int
  print("use", a.id)
  print("use", b.id)
  a.id + b.id

fun one(a: R, n: Int) -> Int
  print("use", a.id)
  a.id + n

fun take3(a: R, n: Int, b: R) -> Int
  print("use", a.id)
  print("use", b.id)
  n

fun hand(h: *R, n: Int) -> Int
  print("use", h.id)
  n

fun bx(b: Box[R], n: Int) -> Int
  print("use", b.id)
  n

fun pp(p: P) -> Int
  print("use", p.a.id)
  print("use", p.b.id)
  1

fun qq(q: Q) -> Int
  print("use", q.h.id)
  2

fun hr(e: HR) -> Int
  match <e
    .one(r) => r.look()
    .two(a, b)
      print("use", b.id)
      a.look()
    .empty => 0

fun ints(xs: [2]Int) -> Int
  xs[0] + xs[1]

fun rt_int(n: Int) -> Int
  n
"""]


class G:
    def __init__(self, r, mode):
        self.r = r
        self.mode = mode  # "!" or "?"
        self.nid = 0

    def rid(self):
        self.nid += 1
        return self.nid

    def fail_leaf_int(self):
        k = self.r.choice([0, 1, 1, 2, 5])
        if self.mode == "!":
            return f"may(rt_int({k}))!"
        return f"opt(rt_int({k}))?"

    def fail_leaf_r(self):
        k = self.r.choice([0, 3, 4])
        i = self.rid() + 1000 * k
        if self.mode == "!":
            return f"mayr(rt_int({i if k else 0}))!"
        return f"optr(rt_int({i if k else 0}))?"

    def eR(self, d):
        r = self.r
        c = r.random()
        if d <= 0 or c < 0.4:
            return f"mk({self.rid()})"
        if c < 0.65:
            return self.fail_leaf_r()
        if c < 0.8:
            return f"<{self.eM(d - 1)}.r" if False else f"mk({self.rid()})"
        return f"mk({self.rid()})"

    def eM(self, d):
        return f"M(r: {self.eR(d - 1)})"

    def eI(self, d):
        r = self.r
        c = r.random()
        if d <= 0 or c < 0.2:
            return str(r.randint(0, 9))
        if c < 0.4:
            return self.fail_leaf_int()
        k = r.randint(0, 11)
        if k == 0:
            return f"two({self.eR(d - 1)}, {self.eR(d - 1)})"
        if k == 1:
            return f"one({self.eR(d - 1)}, {self.eI(d - 1)})"
        if k == 2:
            return f"take3({self.eR(d - 1)}, {self.eI(d - 1)}, {self.eR(d - 1)})"
        if k == 3:
            return f"{self.eM(d - 1)}.with({self.eI(d - 1)})"
        if k == 4:
            return f"hand(*{self.eR(d - 1)}, {self.eI(d - 1)})"
        if k == 5:
            return f"bx(Box({self.eR(d - 1)}), {self.eI(d - 1)})"
        if k == 6:
            return f"pp(P(a: {self.eR(d - 1)}, b: {self.eR(d - 1)}))"
        if k == 7:
            return f"qq(Q(h: *{self.eR(d - 1)}, o: {self.eR(d - 1)}))"
        if k == 8:
            return f"hr(HR.two(a: {self.eR(d - 1)}, b: *{self.eR(d - 1)}))"
        if k == 9:
            return f"ints([{self.eI(d - 1)}, {self.eI(d - 1)}])"
        if k == 10:
            return f"({self.eI(d - 1)} + {self.eI(d - 1)})"
        return f"one({self.eR(d - 1)}, {self.eI(d - 1)})"

    def stmt(self, lines, env):
        r = self.r
        c = r.random()
        if c < 0.35:
            lines.append(f"  print(\"val\", {self.eI(3)})")
        elif c < 0.5:
            n = f"x{len(lines)}"
            lines.append(f"  {n} = {self.eR(2)}")
            env.append(n)
        elif c < 0.6:
            n = f"p{len(lines)}"
            lines.append(f"  {n} = P(a: {self.eR(2)}, b: {self.eR(2)})")
        elif c < 0.68:
            n = f"m{len(lines)}"
            lines.append(f"  {n} = {self.eM(2)}")
            lines.append(f"  !{n}.put({self.eR(2)})")
            lines.append(f"  print(\"val\", {n}.peek({self.eI(2)}))")
        elif c < 0.76:
            n = f"v{len(lines)}"
            lines.append(f"  {n}: Vec[*R] = Vec()")
            for _ in range(r.randint(1, 3)):
                lines.append(f"  !{n}.push(*{self.eR(2)})")
        elif c < 0.84:
            n = f"q{len(lines)}"
            lines.append(f"  {n} = Q(h: *{self.eR(2)}, o: {self.eR(2) if r.random() < 0.7 else 'none'})")
        elif c < 0.9:
            n = f"e{len(lines)}"
            lines.append(f"  {n} = HR.one(r: {self.eR(2)})")
        elif c < 0.95 and env:
            n = env.pop(r.randrange(len(env)))
            lines.append(f"  print(\"val\", one(<{n}, {self.eI(2)}))")
        else:
            n = f"b{len(lines)}"
            lines.append(f"  {n} = [{self.eI(2)}, {self.eI(2)}]")
            lines.append(f"  print(\"val\", {n}[0])")


def gen(seed):
    r = random.Random(seed)
    subs, calls = [], []
    nid = 0
    for h in range(r.randint(2, 4)):
        mode = r.choice("!?")
        g = G(r, mode)
        g.nid = nid
        lines, env = [], []
        for _ in range(r.randint(2, 6)):
            g.stmt(lines, env)
        nid = g.nid + 10
        if mode == "!":
            subs.append(f"sub h{h}()!\n" + "\n".join(lines) + "\n")
            calls.append(f"  h{h}() catch |e| print(\"caught\", e)")
        else:
            subs.append(f"fun h{h} -> Int?\n" + "\n".join(lines) + "\n  0\n")
            calls.append(f"  print(\"got\", h{h}())")
    src = PRELUDE[0] + "\n" + "\n".join(subs) + "\nsub main\n" + "\n".join(calls) + "\n"
    return src


if __name__ == "__main__":
    root, n, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    os.makedirs(root, exist_ok=True)
    for i in range(base, base + n):
        src = gen(i)
        d = os.path.join(root, f"t{i:05d}")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "main.rig"), "w").write(src)
        json.dump({"kind": "own", "area": "tmp"}, open(os.path.join(d, "expect.json"), "w"))
