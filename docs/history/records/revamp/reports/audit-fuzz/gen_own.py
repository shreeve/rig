#!/usr/bin/env python3
"""Random ownership walks. Oracle (checked by own_oracle.py): every resource
id is released exactly once, and never used after its release."""
import json, os, random, sys

PRELUDE = """struct R
  id: Int

  drop(!self)
    print("rel", self.id)

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

error E
  bad

sub look(r: ?R)
  print("use", r.id)

sub eat(r: R)
  print("use", r.id)

fun pass(r: R) -> R
  print("use", r.id)
  r

fun mk(id: Int) -> R
  print("new", id)
  R(id: id)

fun keep(a: ?R, b: R, first: Bool) -> R
  look(?a)
  if first
    return mk(a.id * 100)
  <b

fun rt_bool(b: Bool) -> Bool
  b

fun rt_int(n: Int) -> Int
  n

fun may(k: Int) -> Int!
  return E.bad if k == 0
  k
"""


class G:
    def __init__(self, r):
        self.r = r
        self.nid = 0
        self.nv = 0
        self.subs = []
        self.fallible = False

    def rid(self):
        self.nid += 1
        return self.nid

    def var(self):
        self.nv += 1
        return f"v{self.nv}"

    # env: dict name -> kind  (R, H (*R), B (Box[R]), O (R?), P, Q, V (Vec[*R]), E (HR), F (owned closure))
    def new(self, env, ind, lines):
        r = self.r
        k = r.choice("RRHBOPQVEF")
        n = self.var()
        if k == "R":
            lines.append(f"{ind}{n} = mk({self.rid()})")
        elif k == "H":
            lines.append(f"{ind}{n} = *mk({self.rid()})")
        elif k == "B":
            lines.append(f"{ind}{n} = Box(mk({self.rid()}))")
        elif k == "O":
            if r.random() < 0.7:
                lines.append(f"{ind}{n}: R? = mk({self.rid()})")
            else:
                lines.append(f"{ind}{n}: R? = none")
        elif k == "P":
            lines.append(f"{ind}{n} = P(a: mk({self.rid()}), b: mk({self.rid()}))")
        elif k == "Q":
            if r.random() < 0.5:
                lines.append(f"{ind}{n} = Q(h: *mk({self.rid()}), o: mk({self.rid()}))")
            else:
                lines.append(f"{ind}{n} = Q(h: *mk({self.rid()}), o: none)")
        elif k == "V":
            lines.append(f"{ind}{n}: Vec[*R] = Vec()")
            for _ in range(r.randint(0, 3)):
                lines.append(f"{ind}!{n}.push(*mk({self.rid()}))")
        elif k == "E":
            c = r.randint(0, 2)
            if c == 0:
                lines.append(f"{ind}{n} = HR.one(r: mk({self.rid()}))")
            elif c == 1:
                lines.append(f"{ind}{n} = HR.two(a: mk({self.rid()}), b: *mk({self.rid()}))")
            else:
                lines.append(f"{ind}{n}: HR = .empty")
        else:
            src = [x for x, kk in env.items() if kk in "RH"]
            if src and r.random() < 0.7:
                s = r.choice(src)
                kk = env.pop(s)
                if kk == "R":
                    lines.append(f"{ind}{n} = *|<{s}| look(?{s})")
                else:
                    lines.append(f"{ind}{n} = *|<{s}| print(\"use\", {s}.id)")
            else:
                lines.append(f"{ind}{n} = *|| print(\"noop\")")
        env[n] = k

    def stmt(self, env, ind, lines, depth, in_loop, can_fail):
        r = self.r
        names = list(env)
        c = r.random()
        if not names or c < 0.18:
            self.new(env, ind, lines)
            return
        n = r.choice(names)
        k = env[n]
        c = r.random()
        if c < 0.25:
            # use
            if k == "R":
                lines.append(f"{ind}look(?{n})")
            elif k in "HB":
                lines.append(f"{ind}print(\"use\", {n}.id)")
            elif k == "O":
                lines.append(f"{ind}if ?{n} as t{self.nv}\n{ind}  look(?t{self.nv})")
            elif k == "P":
                lines.append(f"{ind}look(?{n}.{r.choice('ab')})")
            elif k == "Q":
                lines.append(f"{ind}print(\"use\", {n}.h.id)")
            elif k == "V":
                lines.append(f"{ind}for e{self.nv} in ?{n}\n{ind}  print(\"use\", e{self.nv}.id)")
            elif k == "E":
                lines.append(f"{ind}match ?{n}\n{ind}  .one(x) => look(?x)\n{ind}  .two(x, y)\n{ind}    look(?x)\n{ind}    print(\"use\", y.id)\n{ind}  .empty => print(\"empty\")")
            elif k == "F":
                lines.append(f"{ind}{n}()")
            return
        if in_loop:
            # outer names may only be read, cloned, or mutated in place inside a loop
            if k == "V" and c < 0.6:
                lines.append(f"{ind}!{n}.push(*mk({self.rid()}))")
            elif k == "H" and c < 0.6:
                m = self.var()
                lines.append(f"{ind}{m} = +{n}")
                lines.append(f"{ind}print(\"use\", {m}.id)")
            elif k == "P" and c < 0.6:
                lines.append(f"{ind}{n}.{r.choice('ab')} = mk({self.rid()})")
            elif k == "O" and c < 0.6:
                lines.append(f"{ind}{n} = mk({self.rid()})")
            return
        if c < 0.4:
            # consume
            env.pop(n)
            if k == "R":
                lines.append(f"{ind}eat(<{n})" if r.random() < 0.6 else f"{ind}{self.var()} = pass(<{n})")
                if lines[-1].startswith(f"{ind}v"):
                    env[lines[-1].strip().split(" ")[0]] = "R"
            elif k == "B":
                lines.append(f"{ind}eat(<{n}.unbox())")
            elif k == "O":
                lines.append(f"{ind}if <{n} as t{self.nv}\n{ind}  eat(<t{self.nv})")
            elif k == "P":
                lines.append(f"{ind}match <{n}\n{ind}  x => eat(<x.a)" if False else f"{ind}-{n}")
            elif k == "E":
                lines.append(f"{ind}match <{n}\n{ind}  .one(x) => eat(<x)\n{ind}  .two(x, y)\n{ind}    print(\"use\", y.id)\n{ind}  .empty => print(\"empty\")")
            else:
                lines.append(f"{ind}-{n}")
            return
        if c < 0.5:
            # move to a new name
            env.pop(n)
            m = self.var()
            lines.append(f"{ind}{m} = <{n}")
            env[m] = k
            return
        if c < 0.58:
            env.pop(n)
            lines.append(f"{ind}-{n}")
            return
        if c < 0.66 and n != "pr":
            # overwrite a live owner: the old value is released
            if k == "R":
                lines.append(f"{ind}{n} = mk({self.rid()})")
            elif k == "O":
                lines.append(f"{ind}{n} = {'none' if r.random() < 0.3 else f'mk({self.rid()})'}")
            elif k == "P":
                f = r.choice("ab")
                if r.random() < 0.5:
                    lines.append(f"{ind}{n}.{f} = mk({self.rid()})")
                else:
                    m = self.var()
                    lines.append(f"{ind}{m} = replace(!{n}.{f}, mk({self.rid()}))")
                    env[m] = "R"
            elif k == "H":
                m = self.var()
                lines.append(f"{ind}{m} = +{n}")
                env[m] = "H"
            elif k == "V":
                if r.random() < 0.5:
                    lines.append(f"{ind}_ = !{n}.pop()")
                else:
                    lines.append(f"{ind}!{n}.clear()")
            elif k == "Q":
                lines.append(f"{ind}{n}.o = mk({self.rid()})" if r.random() < 0.5 else f"{ind}{n}.h = *mk({self.rid()})")
            elif k == "E":
                lines.append(f"{ind}{n} = HR.one(r: mk({self.rid()}))")
            elif k == "B":
                m = self.var()
                lines.append(f"{ind}{m} = Box(mk({self.rid()}))")
                env[m] = "B"
            return
        if c < 0.68:
            ex = r.random()
            if ex < 0.25 and k == "R":
                lines.append(f"{ind}defer look(?{n})")
            elif ex < 0.4 and k == "R":
                lines.append(f"{ind}errdefer look(?{n})")
            elif ex < 0.6 and k == "E":
                lines.append(f"{ind}match !{n}\n{ind}  .one(x) => x = mk({self.rid()})\n{ind}  .two(x, _) => x = mk({self.rid()})\n{ind}  .empty => print(\"empty\")")
            elif ex < 0.8 and k == "Q":
                m = self.var()
                lines.append(f"{ind}{m} = <{n}.o")
                env[m] = "O"
            elif k == "O":
                lines.append(f"{ind}while <{n} as w{self.nv}\n{ind}  eat(<w{self.nv})")
            elif k == "R":
                m = self.var()
                lines.append(f"{ind}{m} = keep(?{n}, mk({self.rid()}), rt_bool({'true' if r.random() < 0.5 else 'false'}))")
                env[m] = "R"
            return
        if c < 0.7:
            # push a handle into a Vec
            vs = [x for x, kk in env.items() if kk == "V"]
            hs = [x for x, kk in env.items() if kk == "H"]
            if vs and hs:
                h = r.choice(hs)
                env.pop(h)
                lines.append(f"{ind}!{r.choice(vs)}.push(<{h})")
            return
        if c < 0.74:
            # swap two of a kind
            same = [x for x, kk in env.items() if kk == k and x != n]
            if same and k in "ROP":
                lines.append(f"{ind}swap(!{n}, !{r.choice(same)})")
            return
        if depth <= 0:
            return
        if c < 0.84:
            # if / else
            cond = r.random() < 0.5
            lines.append(f"{ind}if rt_bool({'true' if cond else 'false'})")
            e1 = dict(env)
            self.block(e1, ind + "  ", lines, depth - 1, in_loop, can_fail)
            gone = set(env) - set(e1)
            if r.random() < 0.6:
                lines.append(f"{ind}else")
                e2 = dict(env)
                self.block(e2, ind + "  ", lines, depth - 1, in_loop, can_fail)
                gone |= set(env) - set(e2)
            for g in gone:
                env.pop(g, None)
            return
        if c < 0.9:
            lv = f"i{self.nv}"
            brk = r.random() < 0.3
            lines.append(f"{ind}for {lv if brk else '_'} in 0..rt_int({r.randint(0, 3)})")
            e1 = dict(env)
            self.block(e1, ind + "  ", lines, depth - 1, True, can_fail)
            if brk:
                lines.append(f"{ind}  break if {lv} == 1")
            return
        if c < 0.95 and can_fail:
            lines.append(f"{ind}_ = may(rt_int({r.randint(0, 2)}))!")
            return
        if not in_loop:
            lines.append(f"{ind}return if rt_bool({'true' if r.random() < 0.3 else 'false'})")

    def block(self, env, ind, lines, depth, in_loop, can_fail):
        start = len(lines)
        for _ in range(self.r.randint(2, 8)):
            self.stmt(env, ind, lines, depth, in_loop, can_fail)
        if len(lines) == start:
            lines.append(f"{ind}print(\"noop\")")

    def helper(self, idx):
        can_fail = self.r.random() < 0.4
        lines = []
        env = {}
        # parameters: sometimes take ownership of an R
        params = []
        if self.r.random() < 0.3:
            params.append("pr: R")
            env["pr"] = "R"
        self.block(env, "  ", lines, 3, False, can_fail)
        head = f"sub h{idx}({', '.join(params)}){'!' if can_fail else ''}"
        self.subs.append(head + "\n" + "\n".join(lines) + "\n")
        return can_fail, bool(params)


def gen(seed):
    r = random.Random(seed)
    g = G(r)
    calls = []
    for i in range(r.randint(1, 4)):
        can_fail, takes = g.helper(i)
        arg = f"mk({g.rid()})" if takes else ""
        if can_fail:
            calls.append(f"  h{i}({arg}) catch |e| print(\"caught\", e)")
        else:
            calls.append(f"  h{i}({arg})")
    src = PRELUDE + "\n" + "\n".join(g.subs) + "\nsub main\n" + "\n".join(calls) + "\n"
    return src, g.nid


if __name__ == "__main__":
    root, n, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    os.makedirs(root, exist_ok=True)
    for i in range(base, base + n):
        src, nid = gen(i)
        d = os.path.join(root, f"o{i:05d}")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "main.rig"), "w").write(src)
        json.dump({"kind": "own", "nid": nid, "area": "own"}, open(os.path.join(d, "expect.json"), "w"))
