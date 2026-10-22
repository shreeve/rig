#!/usr/bin/env python3
"""Random control flow over Int locals, checked against a Python interpreter.
Covers if/else chains, while (step, else), for over ranges and arrays, labels,
break/continue (with guards and labels), match (literals, ranges,
alternatives, guards), defer, early return, loop values, optionals."""
import json, os, random, sys

MOD = 1000


def trem(a, b):
    q = abs(a) // abs(b)
    q = q if (a >= 0) == (b >= 0) else -q
    return a - b * q


class Brk(Exception):
    def __init__(self, label, val=None):
        self.label, self.val = label, val


class Cont(Exception):
    def __init__(self, label):
        self.label = label


class Ret(Exception):
    def __init__(self, val):
        self.val = val


class Gen:
    def __init__(self, r):
        self.r = r
        self.nl = 0
        self.nv = 0
        self.mut = set()

    # expressions: ("lit", v) ("var", n) ("bin", op, a, b)
    def expr(self, vars_, d=2):
        r = self.r
        if d <= 0 or r.random() < 0.35:
            if vars_ and r.random() < 0.6:
                return ("var", r.choice(vars_))
            return ("lit", r.randint(-9, 20))
        op = r.choice(["+", "-", "*", "%", "/"])
        a = self.expr(vars_, d - 1)
        if op in ("%", "/"):
            return ("bin", op, a, ("lit", r.randint(1, 9)))
        return ("bin", op, a, self.expr(vars_, d - 1))

    def cond(self, vars_):
        r = self.r
        op = r.choice(["<", ">", "==", "!=", "<=", ">="])
        c = ("cmp", op, self.expr(vars_, 1), self.expr(vars_, 1))
        if r.random() < 0.2:
            c = ("and" if r.random() < 0.5 else "or", c, ("cmp", r.choice(["<", ">"]), self.expr(vars_, 1), self.expr(vars_, 1)))
        if r.random() < 0.1:
            c = ("not", c)
        return c

    def block(self, vars_, loops, depth, in_fun):
        r = self.r
        stmts = []
        for _ in range(r.randint(1, 4)):
            stmts.append(self.stmt(vars_, loops, depth, in_fun))
        return stmts

    def stmt(self, vars_, loops, depth, in_fun):
        r = self.r
        c = r.random()
        if c < 0.2 or depth <= 0:
            k = r.random()
            if k < 0.5:
                mv = [v for v in vars_ if v in self.mut]
                return ("assign", r.choice(mv), r.choice(["=", "+=", "-="]), self.expr(vars_))
            if k < 0.8:
                return ("print", [self.expr(vars_) for _ in range(r.randint(1, 3))])
            if loops and k < 0.9:
                lab = r.choice(loops + [None])
                return ("break" if r.random() < 0.4 else "continue", lab, self.cond(vars_))
            if in_fun and r.random() < 0.3:
                return ("return", self.expr(vars_), self.cond(vars_))
            return ("print", [self.expr(vars_)])
        if c < 0.35:
            elifs = [(self.cond(vars_), self.block(vars_, loops, depth - 1, in_fun)) for _ in range(r.randint(0, 2))]
            els = self.block(vars_, loops, depth - 1, in_fun) if r.random() < 0.5 else None
            return ("if", self.cond(vars_), self.block(vars_, loops, depth - 1, in_fun), elifs, els)
        if c < 0.5:
            self.nl += 1
            lab = f"l{self.nl}" if r.random() < 0.5 else None
            self.nv += 1
            iv = f"i{self.nv}"
            lo, hi = r.randint(-2, 2), r.randint(-1, 5)
            body = [("print", [("var", iv)])] + self.block(vars_ + [iv], loops + ([lab] if lab else []) + ["_"], depth - 1, in_fun)
            els = self.block(vars_, loops, depth - 1, in_fun) if r.random() < 0.3 else None
            return ("for", lab, iv, lo, hi, body, els)
        if c < 0.6:
            self.nl += 1
            lab = f"l{self.nl}" if r.random() < 0.5 else None
            self.nv += 1
            cv = f"w{self.nv}"
            lim = r.randint(0, 5)
            body = self.block(vars_ + [cv], loops + ([lab] if lab else []) + ["_"], depth - 1, in_fun)
            els = self.block(vars_, loops, depth - 1, in_fun) if r.random() < 0.3 else None
            return ("while", lab, cv, lim, body, els)
        if c < 0.72:
            arms = []
            used = set()
            for _ in range(r.randint(1, 4)):
                k = r.random()
                if k < 0.4:
                    vs = sorted(set(r.randint(-5, 15) for _ in range(r.randint(1, 3))) - used)
                    if not vs:
                        continue
                    used |= set(vs)
                    arms.append((("lits", vs), None, self.block(vars_, loops, depth - 1, in_fun)))
                elif k < 0.65:
                    a = r.randint(-5, 10)
                    b = a + r.randint(1, 6)
                    rs = set(range(a, b))
                    if rs & used:
                        continue
                    used |= rs
                    arms.append((("range", a, b), None, self.block(vars_, loops, depth - 1, in_fun)))
                else:
                    self.nv += 1
                    bv = f"m{self.nv}"
                    arms.append((("bind", bv), ("cmp", r.choice(["<", ">", "=="]), ("var", bv), ("lit", r.randint(-5, 15))),
                                 self.block(vars_ + [bv], loops, depth - 1, in_fun)))
            dflt = self.block(vars_, loops, depth - 1, in_fun) if r.random() < 0.7 else None
            return ("match", self.expr(vars_, 1), arms, dflt)
        if c < 0.8:
            return ("defer", [self.expr(vars_, 1)])
        if c < 0.88:
            # loop value
            self.nv += 1
            rv = f"v{self.nv}"
            self.nv += 1
            iv = f"i{self.nv}"
            hi = r.randint(0, 6)
            cnd = ("and", ("cmp", ">=", ("var", iv), ("lit", r.randint(0, 4))), self.cond(vars_ + [iv]))
            return ("loopval", rv, iv, hi, cnd, self.expr(vars_ + [iv], 1), self.expr(vars_, 1))
        if c < 0.94:
            # optional: o = e if cond else none; if o as x
            self.nv += 1
            ov = f"o{self.nv}"
            return ("opt", ov, self.expr(vars_, 1), self.cond(vars_), self.expr(vars_, 1))
        mv = [v for v in vars_ if v in self.mut]
        return ("assign", r.choice(mv), "=", self.expr(vars_))


def render_e(e):
    if e[0] == "lit":
        return f"({e[1]})" if e[1] < 0 else str(e[1])
    if e[0] == "var":
        return e[1]
    if e[0] == "bin":
        return f"({render_e(e[2])} {e[1]} {render_e(e[3])})"
    if e[0] == "cmp":
        return f"{render_e(e[2])} {e[1]} {render_e(e[3])}"
    if e[0] in ("and", "or"):
        return f"({render_e(e[1])}) {e[0]} ({render_e(e[2])})"
    if e[0] == "not":
        return f"not ({render_e(e[1])})"


def render(stmts, ind, out):
    for s in stmts:
        k = s[0]
        if k == "assign":
            out.append(f"{ind}{s[1]} {s[2]} {render_e(s[3])} % {MOD}" if s[2] == "=" else f"{ind}{s[1]} {s[2]} {render_e(s[3])}")
            if s[2] != "=":
                out.append(f"{ind}{s[1]} = {s[1]} % {MOD}")
        elif k == "print":
            out.append(f"{ind}print({', '.join(render_e(e) for e in s[1])})")
        elif k in ("break", "continue"):
            lab = f" :{s[1]}" if s[1] and s[1] != "_" else ""
            g = f" if {render_e(s[2])}" if s[2] else ""
            out.append(f"{ind}{k}{lab}{g}")
        elif k == "return":
            out.append(f"{ind}return {render_e(s[1])} if {render_e(s[2])}")
        elif k == "if":
            out.append(f"{ind}if {render_e(s[1])}")
            render(s[2], ind + "  ", out)
            for c, b in s[3]:
                out.append(f"{ind}else if {render_e(c)}")
                render(b, ind + "  ", out)
            if s[4]:
                out.append(f"{ind}else")
                render(s[4], ind + "  ", out)
        elif k == "for":
            lab = f":{s[1]} " if s[1] else ""
            out.append(f"{ind}{lab}for {s[2]} in {render_e(('lit', s[3]))}..{render_e(('lit', s[4]))}")
            render(s[5], ind + "  ", out)
            if s[6]:
                out.append(f"{ind}else")
                render(s[6], ind + "  ", out)
        elif k == "while":
            lab = f":{s[1]} " if s[1] else ""
            out.append(f"{ind}{s[2]} = 0")
            out.append(f"{ind}{lab}while {s[2]} < {s[3]} : {s[2]} += 1")
            render(s[4], ind + "  ", out)
            if s[5]:
                out.append(f"{ind}else")
                render(s[5], ind + "  ", out)
        elif k == "match":
            out.append(f"{ind}match {render_e(s[1])}")
            for pat, guard, body in s[2]:
                if pat[0] == "lits":
                    p = ", ".join(str(v) for v in pat[1])
                elif pat[0] == "range":
                    p = f"{pat[1]}..{pat[2]}"
                else:
                    p = pat[1]
                if guard:
                    p += f" if {render_e(guard)}"
                out.append(f"{ind}  {p}")
                render(body, ind + "    ", out)
            if s[3]:
                out.append(f"{ind}  _")
                render(s[3], ind + "    ", out)
        elif k == "defer":
            out.append(f"{ind}defer print(\"defer\", {', '.join(render_e(e) for e in s[1])})")
        elif k == "loopval":
            _, rv, iv, hi, c, e, d = s
            out.append(f"{ind}{rv} = for {iv} in 0..{hi}")
            out.append(f"{ind}  break {render_e(e)} if {render_e(c)}")
            out.append(f"{ind}else")
            out.append(f"{ind}  {render_e(d)}")
            out.append(f"{ind}print(\"lv\", {rv})")
        elif k == "opt":
            _, ov, e, c, d = s
            out.append(f"{ind}{ov}: Int? = {render_e(e)} if {render_e(c)} else none")
            out.append(f"{ind}if {ov} as {ov}x")
            out.append(f"{ind}  print(\"some\", {ov}x)")
            out.append(f"{ind}else")
            out.append(f"{ind}  print(\"none\", {ov} ?? {render_e(d)})")


class Interp:
    def __init__(self):
        self.out = []
        self.steps = 0

    def ev(self, e, env):
        k = e[0]
        if k == "lit":
            return e[1]
        if k == "var":
            return env[e[1]]
        if k == "bin":
            a, b = self.ev(e[2], env), self.ev(e[3], env)
            op = e[1]
            if op == "+":
                v = a + b
            elif op == "-":
                v = a - b
            elif op == "*":
                v = a * b
            elif op == "%":
                v = trem(a, b)
            else:
                q = abs(a) // abs(b)
                v = q if (a >= 0) == (b >= 0) else -q
            return v
        if k == "cmp":
            a, b = self.ev(e[2], env), self.ev(e[3], env)
            return {"<": a < b, ">": a > b, "==": a == b, "!=": a != b, "<=": a <= b, ">=": a >= b}[e[1]]
        if k == "and":
            return self.ev(e[1], env) and self.ev(e[2], env)
        if k == "or":
            return self.ev(e[1], env) or self.ev(e[2], env)
        if k == "not":
            return not self.ev(e[1], env)

    def block(self, stmts, env):
        defers = []
        try:
            for s in stmts:
                self.stmt(s, env, defers)
        finally:
            for d in reversed(defers):
                self.out.append("defer " + " ".join(str(self.ev(x, env)) for x in d))

    def loop_body(self, lab, body, env):
        """returns 'break' or None"""
        try:
            self.block(body, env)
        except Brk as b:
            if b.label in (None, "_", lab):
                return "break"
            raise
        except Cont as c:
            if c.label in (None, "_", lab):
                return None
            raise
        return None

    def stmt(self, s, env, defers):
        self.steps += 1
        if self.steps > 200000:
            raise RuntimeError("too long")
        k = s[0]
        if k == "assign":
            v = self.ev(s[3], env)
            if s[2] == "=":
                env[s[1]] = trem(v, MOD)
            elif s[2] == "+=":
                env[s[1]] = trem(env[s[1]] + v, MOD)
            else:
                env[s[1]] = trem(env[s[1]] - v, MOD)
        elif k == "print":
            self.out.append(" ".join(str(self.ev(e, env)) for e in s[1]))
        elif k == "break":
            if s[2] is None or self.ev(s[2], env):
                raise Brk(s[1])
        elif k == "continue":
            if s[2] is None or self.ev(s[2], env):
                raise Cont(s[1])
        elif k == "return":
            if self.ev(s[2], env):
                raise Ret(self.ev(s[1], env))
        elif k == "if":
            if self.ev(s[1], env):
                self.block(s[2], env)
                return
            for c, b in s[3]:
                if self.ev(c, env):
                    self.block(b, env)
                    return
            if s[4]:
                self.block(s[4], env)
        elif k == "for":
            _, lab, iv, lo, hi, body, els = s
            broke = False
            for i in range(lo, hi):
                env[iv] = i
                if self.loop_body(lab, body, env) == "break":
                    broke = True
                    break
            if not broke and els:
                self.block(els, env)
        elif k == "while":
            _, lab, cv, lim, body, els = s
            env[cv] = 0
            broke = False
            while env[cv] < lim:
                if self.loop_body(lab, body, env) == "break":
                    broke = True
                    break
                env[cv] += 1
            if not broke and els:
                self.block(els, env)
        elif k == "match":
            v = self.ev(s[1], env)
            for pat, guard, body in s[2]:
                if pat[0] == "lits":
                    m = v in pat[1]
                elif pat[0] == "range":
                    m = pat[1] <= v < pat[2]
                else:
                    env[pat[1]] = v
                    m = True
                if m and guard is not None:
                    m = self.ev(guard, env)
                if m:
                    self.block(body, env)
                    return
            if s[3]:
                self.block(s[3], env)
        elif k == "defer":
            defers.append(s[1])
        elif k == "loopval":
            _, rv, iv, hi, c, e, d = s
            res = None
            for i in range(0, hi):
                env[iv] = i
                if self.ev(c, env):
                    res = self.ev(e, env)
                    break
            if res is None:
                res = self.ev(d, env)
            env[rv] = res
            self.out.append(f"lv {res}")
        elif k == "opt":
            _, ov, e, c, d = s
            if self.ev(c, env):
                self.out.append(f"some {self.ev(e, env)}")
            else:
                self.out.append(f"none {self.ev(d, env)}")


def gen(seed):
    r = random.Random(seed)
    g = Gen(r)
    funs, calls, out = [], [], []
    for f in range(r.randint(1, 3)):
        vars_ = [f"a{f}", f"b{f}", f"c{f}"]
        g.mut |= set(vars_)
        init = {v: r.randint(-5, 10) for v in vars_}
        body = g.block(vars_, [], 3, True)
        lines = [f"fun f{f}(a{f}: Int) -> Int"]
        lines.append(f"  new a{f} = a{f}")
        for v in vars_[1:]:
            lines.append(f"  {v} = {init[v]}")
        render(body, "  ", lines)
        lines.append(f"  a{f} + b{f} + c{f}")
        funs.append("\n".join(lines) + "\n")
        for _ in range(r.randint(1, 2)):
            arg = r.randint(-5, 10)
            calls.append(f"  print(\"ret\", f{f}({arg if arg >= 0 else f'({arg})'}))")
            it = Interp()
            env = dict(init)
            env[f"a{f}"] = arg
            try:
                it.block(body, env)
                ret = env[f"a{f}"] + env[f"b{f}"] + env[f"c{f}"]
            except Ret as rr:
                ret = rr.val
            except RuntimeError:
                return None
            out += it.out
            out.append(f"ret {ret}")
    return "\n".join(funs) + "\nsub main\n" + "\n".join(calls) + "\n", "\n".join(out) + "\n"


if __name__ == "__main__":
    root, n, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    os.makedirs(root, exist_ok=True)
    k = 0
    i = base
    while k < n:
        res = gen(i)
        i += 1
        if res is None:
            continue
        src, out = res
        d = os.path.join(root, f"cf{i:05d}")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "main.rig"), "w").write(src)
        json.dump({"kind": "out", "out": out, "area": "cf"}, open(os.path.join(d, "expect.json"), "w"))
        k += 1
