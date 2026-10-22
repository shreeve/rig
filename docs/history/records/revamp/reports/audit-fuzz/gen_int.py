#!/usr/bin/env python3
"""Integer arithmetic programs with exactly computed expected output."""
import json, os, random, sys

TYPES = {
    "I8": (8, True), "I16": (16, True), "I32": (32, True), "Int": (64, True), "I64": (64, True),
    "I128": (128, True), "U8": (8, False), "U16": (16, False), "U32": (32, False),
    "U64": (64, False), "U128": (128, False),
}


def rng(t):
    b, s = TYPES[t]
    return (-(1 << (b - 1)), (1 << (b - 1)) - 1) if s else (0, (1 << b) - 1)


def fits(t, v):
    lo, hi = rng(t)
    return lo <= v <= hi


def wrap(t, v):
    b, s = TYPES[t]
    v &= (1 << b) - 1
    if s and v >= 1 << (b - 1):
        v -= 1 << b
    return v


def tdiv(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def trem(a, b):
    return a - b * tdiv(a, b)


class Bad(Exception):
    pass


class Gen:
    def __init__(self, r):
        self.r = r
        self.n = 0
        self.decls = []   # module level
        self.locals = []  # main body lines declaring leaves
        self.used_ids = set()

    def fresh(self, p):
        self.n += 1
        return f"{p}{self.n}"

    def rand_val(self, t):
        lo, hi = rng(t)
        r = self.r
        k = r.random()
        if k < 0.35:
            v = r.randint(max(lo, -20), min(hi, 20))
        elif k < 0.6:
            v = r.randint(max(lo, -1000), min(hi, 1000))
        elif k < 0.8:
            v = r.randint(lo // 2 if lo else 0, hi // 2)
        elif k < 0.9:
            v = r.choice([lo, hi, lo + 1, hi - 1, 0, 1])
        else:
            v = r.randint(lo, hi)
        return v

    def lit(self, t, v):
        if v < 0:
            return f"({v})"
        k = self.r.random()
        if k < 0.1:
            return hex(v)
        if k < 0.13 and v < 256:
            return bin(v)
        if k < 0.18 and v >= 1000:
            s = str(v)
            # underscores every 3 digits
            parts = []
            while len(s) > 3:
                parts.insert(0, s[-3:])
                s = s[:-3]
            parts.insert(0, s)
            return "_".join(parts)
        return str(v)

    def leaf(self, t, v=None):
        r = self.r
        fixed = v is not None
        if v is None:
            v = self.rand_val(t)
        k = r.random()
        if fixed and 0.84 <= k < 0.92:
            k = 0.2
        lo, hi = rng(t)
        if k < 0.3:
            return self.lit(t, v), v
        if k < 0.6:
            name = self.fresh("v")
            self.locals.append(f"  {name}: {t} = id_{t.lower()}({self.lit(t, v)})")
            return name, v
        if k < 0.72:
            name = self.fresh("c")
            self.locals.append(f"  {name}: {t} = {self.lit(t, v)}")
            return name, v
        if k < 0.84:
            name = self.fresh("M")
            self.decls.append(f"{name}: {t} = {self.lit(t, v)}")
            return name, v
        if k < 0.92:
            if r.random() < 0.5:
                return f"{t}.min", lo
            return f"{t}.max", hi
        # array element or Vec element
        name = self.fresh("a")
        self.locals.append(f"  {name}: [2]{t} = [{self.lit(t, v)}, {self.lit(t, v)}]")
        return f"{name}[1]", v

    def expr(self, t, depth):
        r = self.r
        if depth <= 0 or r.random() < 0.25:
            return self.leaf(t)
        for _ in range(8):
            snap = (len(self.locals), len(self.decls))
            try:
                return self.op(t, depth)
            except Bad:
                del self.locals[snap[0]:]
                del self.decls[snap[1]:]
        return self.leaf(t)

    def op(self, t, depth):
        r = self.r
        b, s = TYPES[t]
        lo, hi = rng(t)
        ops = ["+", "-", "*", "/", "%", "+%", "-%", "*%", "&", "|", "^", "<<", ">>", "neg", "conv", "cond"]
        o = r.choice(ops)
        if o == "neg":
            if not s:
                raise Bad
            e, v = self.expr(t, depth - 1)
            if -v > hi:
                raise Bad
            return f"-({e})", -v
        if o == "conv":
            src = r.choice(list(TYPES))
            e, v = self.expr(src, depth - 1)
            if not fits(t, v):
                raise Bad
            return f"{t}({e})", v
        if o == "cond":
            e1, v1 = self.expr(t, depth - 1)
            e2, v2 = self.expr(t, depth - 1)
            e3, v3 = self.expr(t, depth - 1)
            cmp = r.choice(["<", "<=", ">", ">=", "==", "!="])
            c = {"<": v1 < v2, "<=": v1 <= v2, ">": v1 > v2, ">=": v1 >= v2, "==": v1 == v2, "!=": v1 != v2}[cmp]
            e4, v4 = self.expr(t, depth - 1)
            return f"(({e3}) if ({e1}) {cmp} ({e2}) else ({e4}))", (v3 if c else v4)
        if o in ("<<", ">>"):
            e, v = self.expr(t, depth - 1)
            amt = r.randint(0, b - 1)
            st = r.choice(["Int", "U8", t, "U32", "I16"])
            if not fits(st, amt):
                st = "Int"
            ae, _ = self.leaf(st, amt)
            if o == "<<":
                res = v << amt
                if not fits(t, res):
                    raise Bad
            else:
                res = v >> amt
            return f"(({e}) {o} {ae})", res
        e1, v1 = self.expr(t, depth - 1)
        e2, v2 = self.expr(t, depth - 1)
        if o == "+":
            res = v1 + v2
        elif o == "-":
            res = v1 - v2
        elif o == "*":
            res = v1 * v2
        elif o == "/":
            if v2 == 0:
                raise Bad
            res = tdiv(v1, v2)
        elif o == "%":
            if v2 == 0:
                raise Bad
            res = trem(v1, v2)
        elif o == "+%":
            res = wrap(t, v1 + v2)
        elif o == "-%":
            res = wrap(t, v1 - v2)
        elif o == "*%":
            res = wrap(t, v1 * v2)
        elif o == "&":
            res = v1 & v2
        elif o == "|":
            res = v1 | v2
        elif o == "^":
            res = v1 ^ v2
        if not fits(t, res):
            raise Bad
        return f"({e1} {o} {e2})", res


def gen_prog(seed):
    r = random.Random(seed)
    g = Gen(r)
    body = []
    out = []
    for i in range(r.randint(3, 8)):
        t = r.choice(list(TYPES))
        kind = r.random()
        if kind < 0.6:
            e, v = g.expr(t, r.randint(1, 4))
            name = g.fresh("r")
            g.locals.append(f"  {name}: {t} = {e}")
            g.locals.append(f"  print({name})")
            out.append(str(v))
        elif kind < 0.75:
            e1, v1 = g.expr(t, 2)
            e2, v2 = g.expr(t, 2)
            n1, n2 = g.fresh("x"), g.fresh("y")
            g.locals.append(f"  {n1}: {t} = {e1}")
            g.locals.append(f"  {n2}: {t} = {e2}")
            g.locals.append(f"  print({n1} < {n2}, {n1} == {n2}, {n1} >= {n2}, {n1} != {n2} and {n1} <= {n2})")
            out.append(f"{str(v1 < v2).lower()} {str(v1 == v2).lower()} {str(v1 >= v2).lower()} {str(v1 != v2 and v1 <= v2).lower()}")
        else:
            # compound assignment chain
            name = g.fresh("acc")
            v0 = g.rand_val(t)
            g.locals.append(f"  {name}: {t} = id_{t.lower()}({g.lit(t, v0)})")
            acc = v0
            b, s = TYPES[t]
            for _ in range(r.randint(1, 5)):
                op = r.choice(["+=", "-=", "*=", "/=", "%=", "+%=", "-%=", "*%=", "&=", "|=", "^=", "<<=", ">>="])
                if op in ("<<=", ">>="):
                    amt = r.randint(0, b - 1)
                    st = r.choice(["Int", "U8", t])
                    if not fits(st, amt):
                        st = "Int"
                    snap = len(g.locals), len(g.decls)
                    ae, _ = g.leaf(st, amt)
                    res = acc << amt if op == "<<=" else acc >> amt
                    if not fits(t, res):
                        del g.locals[snap[0]:]
                        del g.decls[snap[1]:]
                        continue
                    g.locals.append(f"  {name} {op} {ae}")
                    acc = res
                    continue
                snap = len(g.locals), len(g.decls)
                e, v = g.expr(t, 1)
                o = op[:-1]
                def rollback():
                    del g.locals[snap[0]:]
                    del g.decls[snap[1]:]
                if o in ("/", "%") and v == 0:
                    rollback()
                    continue
                res = {"+": lambda: acc + v, "-": lambda: acc - v, "*": lambda: acc * v,
                       "/": lambda: tdiv(acc, v), "%": lambda: trem(acc, v),
                       "+%": lambda: wrap(t, acc + v), "-%": lambda: wrap(t, acc - v), "*%": lambda: wrap(t, acc * v),
                       "&": lambda: acc & v, "|": lambda: acc | v, "^": lambda: acc ^ v}[o]()
                if not fits(t, res):
                    rollback()
                    continue
                g.locals.append(f"  {name} {op} {e}")
                acc = res
            g.locals.append(f"  print({name})")
            out.append(str(acc))
    lines = []
    for t in TYPES:
        if t == "I64":
            continue
        lines.append(f"fun id_{t.lower()}(x: {t}) -> {t}\n  x\n")
    lines.append("fun id_i64(x: I64) -> I64\n  x\n")
    src = "\n".join(g.decls) + "\n\n" + "\n".join(lines) + "\nsub main\n" + "\n".join(g.locals) + "\n"
    return src, "\n".join(out) + "\n"


if __name__ == "__main__":
    root, n, base = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 0
    os.makedirs(root, exist_ok=True)
    for i in range(base, base + n):
        src, out = gen_prog(i)
        d = os.path.join(root, f"int{i:05d}")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "main.rig"), "w").write(src)
        json.dump({"kind": "out", "out": out, "area": "int"}, open(os.path.join(d, "expect.json"), "w"))
