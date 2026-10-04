#!/usr/bin/env python3
"""Generate and run the form x context x type matrix of small programs.

Each program puts one expression form (a place, a ternary, `o?`, ...) in
one context (a `print` argument, a binding, an element assignment, ...)
for one type (Int, String, Text, Vec, `*T`, Box, a struct with a
`drop`, a struct holding a Cell, a struct declared `unique`), plus the
stores into a borrowed parameter (`store.`, below). The rule is the
corpus's: `rig check` rejects the program with
a file:line:col diagnostic, or it runs clean under the sanitizer (no leak,
no use of freed memory, no Zig compile error, no crash).

    test/matrix.py                 # generate, check, and run everything
    test/matrix.py -j 8 -k vec     # 8 at a time; only ids containing "vec"
    test/matrix.py --keep DIR      # write the programs to DIR and keep them
    test/matrix.py --oracle        # only run the reference ownership checker
                                   # (bin/rig-oracle, test/oracle/) over them

Nothing it writes is committed: programs go to a temporary directory,
and each run's build is removed after it passes.
"""

import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RIG = os.path.join(ROOT, "bin", "rig")
ORACLE = os.path.join(ROOT, "bin", "rig-oracle")

# What a sound program never does when it runs (test/run's CORPUS_BAD_RE).
BAD = re.compile(
    r"rig: memory leak detected|rig: use of freed memory|rig: access past the end|rig: double free"
    r"|\.zig:\d+:\d+: error|\.rig:\d+:\d+: error|Segmentation fault|Bus error|General protection"
    r"|Illegal instruction|reached unreachable|access of union field|invalid enum value"
    r"|incorrect alignment|attempt to use null value|switch on corrupt value|invalid error code"
)
POS = re.compile(r"\.rig:\d+:\d+")
CRASH = re.compile(r"panic:|Segmentation fault|reached unreachable|Bus error")

# -----------------------------------------------------------------------------
# Types: the type's spelling, declarations it needs, how `mk(n)` makes a
# fresh one, and a constructor expression.
# -----------------------------------------------------------------------------

N_DECL = "struct N\n  v: Int\n\n  fun peek(?self, k: Int) -> Int\n    self.v + k\n"
TYPES = {
    "int": dict(ty="Int", decls="", mk="n", ctor="Int(5)"),
    "string": dict(ty="String", decls="", mk='"s" if n > 0 else "t"', ctor='"lit"'),
    "text": dict(ty="Text", decls="", mk='Text("t", n)', ctor='Text("lit")'),
    "vec": dict(ty="Vec[Int]", decls="",
                mk="xs: Vec[Int] = Vec()\n  !xs.push(n)\n  xs", ctor="Vec[Int]()"),
    "shared": dict(ty="*N", decls=N_DECL, mk="*N(v: n)", ctor="*N(v: 5)"),
    "box": dict(ty="Box[N]", decls=N_DECL, mk="Box(N(v: n))", ctor="Box(N(v: 5))"),
    "drop": dict(ty="D", decls='struct D\n  v: Int\n\n  drop(!self)\n    print("drop", self.v)\n\n  fun take(<self) -> Int\n    self.v\n\n  sub bump(!self)\n    self.v += 1\n\n  fun peek(?self, k: Int) -> Int\n    self.v + k\n',
                 mk="D(v: n)", ctor="D(v: 5)"),
    # A struct that holds a Cell (`poke` changes it through the binding),
    # and one declared `unique`.
    "cell": dict(ty="Counter", decls="struct Counter\n  hits: Cell[Int]\n\n  sub hit(?self)\n    self.hits.set(self.hits.get() + 1)\n",
                 mk="Counter(hits: Cell(n))", ctor="Counter(hits: Cell(5))", poke="e.hit()"),
    "unique": dict(ty="U", decls="struct U unique\n  v: Int\n", mk="U(v: n)", ctor="U(v: 5)"),
    # A payload enum: `== .variant` tests the variant.
    "enum": dict(ty="S", decls="enum S\n  dot\n  line(v: Vec[Int])\n",
                 mk="xs: Vec[Int] = Vec()\n  !xs.push(n)\n  .line(v: <xs)", ctor="S.dot",
                 only=("eq_variant", "eq_none", "binding", "tail_if", "tail_match")),
}

# -----------------------------------------------------------------------------
# Forms: an expression, or a block form (`if ... as`, `match`) that only
# stands where a block's value is taken.
# -----------------------------------------------------------------------------

FORMS = {
    "place": "a",
    "field": "h.f",
    "ternary": "a if c else b",
    "optional": "o?",
    "nullish": "o ?? b",
    "catch": "fail(c) catch b",
    "if_as": ["if o as v", "  v", "else", "  b"],
    "match": ["match c", "  true => a", "  false => b"],
    "call": "mk(5)",
    "ctor": None,  # the type's constructor
    "move": "<a",
    "clone": "+a",
}

# -----------------------------------------------------------------------------
# Contexts: statements that use the form `E`. `inline` contexts need an
# expression; the others take a block form on the lines after them.
# -----------------------------------------------------------------------------

CONTEXTS = {
    "print": dict(inline="print(E)"),
    "borrow_arg": dict(inline="print(look(?E))"),
    "eq": dict(inline="print(E == a)"),
    "binding": dict(block="x = E", after="print(look(?x))"),
    "field_store": dict(block="h.f = E", needs="h", after="print(look(?h.f))"),
    "vec_push": dict(inline="!vs.push(E)", needs="vs", after="print(vs.len)"),
    "return": dict(block="return E", returns=True),
    "elem_assign": dict(block="vs[0] = E", needs="vs", after="print(vs.len)"),
    "elem_assign_call": dict(inline="vs[0] = through(!vs, E)", needs="vs", after="print(vs.len)"),
    "elem_index_call": dict(block="vs[grow(!vs)] = E", needs="vs", after="print(vs.len)"),
    "match_subject": dict(inline="match E\n    y => print(look(?y))"),
    "for_source": dict(inline="for e in ?E\n    print(e)"),
    # A loop over an array made in its header, which it takes.
    "for_literal": dict(inline="for e in [E, mk(6)]\n    @POKE\n    print(look(?e))"),
    # A loop over a branch whose arms are arrays: each element is a copy.
    "for_branch": dict(inline="for e in ([E, mk(6)] if c else [mk(7), mk(8)])\n    @POKE\n    print(look(?e))"),
    # A match on a part of a made value.
    "match_part": dict(inline="match H(f: E).f\n    y\n      @POKY\n      print(look(?y))"),
    # A method that consumes its receiver (`<self`, `Box.unbox`).
    "recv_consume": dict(inline="print((E).M)", recv={"drop": "take()", "box": "unbox().v"}),
    # A method that writes its receiver: a value made there, or one
    # lent with `!` (a place without one is rejected).
    "recv_write": dict(inline="(E).M", recv={"vec": "push(1)", "text": 'add("x")', "drop": "bump()"}),
    # `none` and a bare `.variant` test a value and drop it if no name holds it.
    "eq_none": dict(inline="print(E == none)", optional=True),
    "eq_variant": dict(inline="print(E != .dot)", types=("enum",)),
    # A closure whose result is inferred returns its value: the tail of
    # an expression body, and of a block body. (Its own `a`, `b`, `c`,
    # `o` are parameters, in a function of their own.)
    "closure_tail": dict(decl="fun ctail(k: Bool, p: @T?) -> @T\n  g = |a: @T, b: @T, c: Bool, o: @T?| E\n  g(mk(1), mk(2), k, <p)\n",
                         inline="x = ctail(c, mk(3))\n  print(look(?x))"),
    "closure_block": dict(decl="fun ctail(k: Bool, p: @T?) -> @T\n  g = |a: @T, b: @T, c: Bool, o: @T?|\n    print(0)\n    E\n  g(mk(1), mk(2), k, <p)\n",
                          inline="x = ctail(c, mk(3))\n  print(look(?x))"),
    # `+e` reads `e`, and `_ = e` drops what it takes.
    "clone": dict(inline="x = +(E)\n  print(look(?x))"),
    "discard": dict(inline="_ = E"),
    # A value read in place, then its place lent to write (`poke(!W)`) by
    # a later operand of the same call or operator, before the read is
    # used. `W` is what the form reads: `h.f` for a field, `b` for a
    # fallback, else `a`.
    "arg_then_write": dict(inline="print(E, poke(!W))", write=True),
    "recv_read_then_write": dict(inline="print((E).M)", write=True,
                                 recv={t: "get(poke(!W))" if t == "vec" else "peek(poke(!W))"
                                       for t in ("vec", "shared", "box", "drop")}),
    "eq_then_write": dict(inline="print((E) == pokev(!W))", write=True, types=("int", "string", "text")),
    "index_then_write": dict(inline="print((E)[poke(!W)])", write=True, types=("vec",)),
}

# How `poke` changes a value of each type: it grows the buffer, or
# replaces the value, freeing what the old one owned.
POKES = {
    "int": "x += 1", "string": 'x = "u"',
    "text": 'for _ in 0..100\n    !x.add("abcdefgh")', "vec": "for i in 0..100\n    !x.push(i)",
    "shared": "x = *N(v: 9)", "box": "x = Box(N(v: 9))", "drop": "x = D(v: 9)",
    "cell": "x = Counter(hits: Cell(9))", "unique": "x = U(v: 9)", "enum": "x = S.dot",
}
WRITE_TARGETS = {"field": "h.f", "nullish": "b", "catch": "b"}

# A block-local binding at the tail of a value block leaves it before the
# block's defers run. Each shape of value block goes to each sink, with a
# `defer` that uses the binding (writes a Vec or Text, reads the rest) or
# none. Each cell's form is `mk(5)`.
TAIL_SHAPES = {
    "if": ["if c", "  BODY", "else", "  mk(8)"],
    "match": ["match c", "  true", "    BODY", "  false => mk(8)"],
    "catch": ["fail(c) catch |_|", "  BODY"],
    "while_else": ["while false", "  break mk(8)", "else", "  BODY"],
    "for_else": ["for k in [1, 2]", "  break mk(8) if k > 5", "else", "  BODY"],
    "nested": ["if c", "  t: T = mk(5)", "  DEFER", "  if not c", "    t", "  else", "    mk(9)", "else", "  mk(8)"],
}
TAIL_SINKS = {
    "binding": dict(block="x = E", after="print(look(?x))"),
    "field": dict(block="h.f = E", needs="h", after="print(look(?h.f))"),
    "result": dict(block="return E", returns=True),
}
TAIL_WRITES = {"vec": "!t.push(1)", "text": '!t.add("x")'}
for shape in TAIL_SHAPES:
    for sink, ctx in TAIL_SINKS.items():
        for defer in ("defer", "plain"):
            CONTEXTS[f"tail_{shape}_{sink}_{defer}"] = dict(ctx, tail=shape, defer=defer == "defer")


# -----------------------------------------------------------------------------
# Stores into a borrowed parameter: `f` stores a view of its write
# parameter `b` in what its parameter `a` reaches, by each store form,
# then grows `b` (or only reads it) and reads the view through `a`. The
# caller reads `a` after the return, so `b` stays lent: growing it must
# be rejected. Cells are `store.<owner>.<form>.<then>`.
# -----------------------------------------------------------------------------

STORE_OWNERS = {
    "vec": dict(ty="Vec[Int]", view="[]Int", lend="?b[..]", init="x = [9, 9]",
                make="v: Vec[Int] = Vec()\n  !v.push(1)", grow=["for i in 0..100", "  !b.push(i)"]),
    "text": dict(ty="Text", view="String", lend="?b[0..1]", init='x = Text("zz")',
                 make='v = Text("abc")', grow=["for _ in 0..100", '  !b.add("abcdefgh")']),
}
# What `a` is: its type, how `main` makes it from the view `I`, and the
# statements that read the stored view back.
STORE_HOLDERS = {
    "h": dict(ty="H", make="h = H(r: I)", read=["print(a.r[0])"]),
    "o": dict(ty="O", make="h = O(h: H(r: I))", read=["print(a.h.r[0])"]),
    "c": dict(ty="C", make="h0 = H(r: I)\n  h = C(w: !h0)", read=["print(a.w.r[0])"]),
    "s": dict(ty="[]H", make="h = [H(r: I)]", read=["print(a[0].r[0])"]),
    "e": dict(ty="E", make="h: E = .one(h: H(r: I))",
              read=["match a", "  .one(h) => print(h.r[0])", "  .zero => print(0)"]),
    "opt": dict(ty="H?", make="h: H? = H(r: I)", read=["if ?a as h", "  print(h.r[0])"]),
}
# Each form: its holder, and the statements that store the view `S`.
STORE_FORMS = {
    "field": ("h", ["a.r = S"]),
    "method": ("h", ["!a.set(S)"]),
    "call": ("h", ["put(!a, S)"]),
    "alias": ("h", ["k = !a", "k.r = S"]),
    "assign_whole": ("h", ["a = H(r: S)"]),
    "read_back": ("h", ["a.r = S", "t = a.r"]),
    "defer": ("h", ["if a.r.len > 0", "  defer a.r = S", "  print(1)"]),
    "closure": ("h", ["g = |!a, ?b| a.r = S", "g()"]),
    "replace": ("h", ["print(replace(!a.r, S))"]),
    "swap": ("h", ["q = H(r: S)", "swap(!a, !q)"]),
    "nested": ("o", ["a.h.r = S"]),
    "write_field": ("c", ["a.w.r = S"]),
    "write_through": ("c", ["a.w = H(r: S)"]),
    "element": ("s", ["a[0].r = S"]),
    "loop_element": ("s", ["for k in !a", "  k.r = S"]),
    "loop_assign": ("s", ["for k in !a", "  k = H(r: S)"]),
    "match_payload": ("e", ["match !a", "  .one(h) => h.r = S", "  .zero => print(0)"]),
    "as_binding": ("opt", ["if !a as h", "  h.r = S"]),
}


def store_program(oname, fname, then):
    """The program for one store cell."""
    o = STORE_OWNERS[oname]
    kind, lines = STORE_FORMS[fname]
    h = STORE_HOLDERS[kind]
    v = o["view"]
    out = [f"struct H\n  r: {v}\n\n  sub set(!self, s: {v})\n    self.r = s\n",
           "struct O\n  h: H\n", "struct C\n  w: !H\n", "enum E\n  one(h: H)\n  zero\n",
           f"sub put(h: !H, s: {v})\n  h.r = s\n"]
    body = [l.replace("S", o["lend"]) for l in lines]
    body += o["grow"] if then == "grow" else ["print(b.len)"]
    body += ["print(t[0])"] if fname == "read_back" else h["read"]
    out.append(f"sub f(a: !{h['ty']}, b: !{o['ty']})\n{indent(body, 2)}\n")
    main = [o["init"], o["make"], h["make"].replace("I", "?x[..]"), "f(!h, !v)"]
    out.append("sub main\n" + indent(main, 2) + "\n")
    return "\n".join(out)


def indent(lines, n):
    return "\n".join(" " * n + l for l in lines)


def program(tname, fname, cname):
    """The program for one cell, or None when the form cannot stand there."""
    t = TYPES[tname]
    ctx = CONTEXTS[cname]
    form = FORMS[fname] if fname != "ctor" else t["ctor"]
    if isinstance(form, list) and "block" not in ctx:
        return None
    if "only" in t and not any(cname.startswith(c) for c in t["only"]):
        return None
    if "recv" in ctx and tname not in ctx["recv"] or tname not in ctx.get("types", (tname,)):
        return None
    if "tail" in ctx:
        if fname != "call" or tname in ("int", "string"):
            return None
        write = TAIL_WRITES.get(tname, "print(look(?t))")
        lines = []
        for l in TAIL_SHAPES[ctx["tail"]]:
            pad = l[:len(l) - len(l.lstrip())]
            part = ["t: T = mk(5)", "DEFER", "t"] if l.strip() == "BODY" else [l.strip()]
            for p in part:
                if p == "DEFER":
                    p = "defer " + write if ctx["defer"] else ""
                if p:
                    lines.append(pad + p.replace("t: T", "t: " + t["ty"]))
        form = lines
    ty = t["ty"]
    out = []
    out.append(t["decls"])
    out.append("error E\n  bad\n")
    out.append(f"fun mk(n: Int) -> {ty}\n  {t["mk"]}\n")
    out.append(f"fun fail(c: Bool) -> {ty}!\n  return E.bad if c\n  mk(7)\n")
    out.append(f"fun look(x: ?{ty}) -> Int\n  1\n")
    if "decl" in ctx:
        if isinstance(form, list):
            return None
        out.append(ctx["decl"].replace("@T", ty).replace("E", form))
    out.append(f"struct H\n  f: {ty}\n")
    returns = ctx.get("returns", False)
    needs = ctx.get("needs")
    if needs == "vs":
        # Calls that grow the Vec an element assignment stores into.
        out.append(f"fun through(v: !Vec[{ty}], x: {ty}) -> {ty}\n  for i in 0..100\n    !v.push(mk(i))\n  x\n")
        out.append(f"fun grow(v: !Vec[{ty}]) -> Int\n  for i in 0..100\n    !v.push(mk(i))\n  0\n")
    if ctx.get("write"):
        out.append(f"fun poke(x: !{ty}) -> Int\n  {POKES[tname]}\n  0\n")
        out.append(f"fun pokev(x: !{ty}) -> {ty}\n  n = poke(!x)\n  mk(n + 9)\n")
    ret_ty = f"{ty}?" if returns else "Int?"
    if ctx.get("optional"):
        body = [f"a: {ty}? = mk(1)", f"b: {ty}? = mk(2)", "print(a == none, b == none)"]
    else:
        body = [f"a: {ty} = mk(1)", f"b: {ty} = mk(2)", "print(look(?a), look(?b))"]
    if needs == "h" or fname == "field":
        body += [f"h = H(f: mk(3))", "print(look(?h.f))"]
    if needs == "vs":
        body += [f"vs: Vec[{ty}] = Vec()", "!vs.push(mk(4))"]
    if isinstance(form, list):
        head = ctx["block"].replace("E", form[0])
        body.append(head)
        body += form[1:]
    else:
        text = ctx.get("inline") or ctx["block"]
        if "recv" in ctx:
            text = text.replace("M", ctx["recv"][tname])
        if ctx.get("write"):
            text = text.replace("!W", "!" + WRITE_TARGETS.get(fname, "a"))
        e = form
        if cname in ("borrow_arg", "for_source") and " " in e:
            e = f"({e})"
        # `@POKE` and `@POKY` stand for the type's change through the loop
        # or match binding, or `pass`; they are replaced before `E` is.
        poke = t.get("poke", "pass")
        text = text.replace("@POKY", "@Y").replace("@POKE", "@P")
        body.append(text.replace("E", e).replace("@Y", poke.replace("e.", "y.")).replace("@P", poke))
    if "after" in ctx:
        body.append(ctx["after"])
    if not returns:
        body.append("0")
    out.append(f"fun run(c: Bool, o: {ty}?) -> {ret_ty}\n{indent(body, 2)}\n")
    main = ["for c in [true, false]", "  r = run(c, mk(9))", "  print(r == none)"]
    out.append("sub main\n" + indent(main, 2) + "\n")
    return "\n".join(out)


def run_one(path, keep):
    """Classify one program: rejected, ok, or a failure with its reason."""
    d = os.path.dirname(path)
    try:
        chk = subprocess.run([RIG, "check", path], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "fail", "rig check timed out"
    out = chk.stdout + chk.stderr
    if chk.returncode < 0 or chk.returncode > 128 or CRASH.search(out):
        return "fail", "compiler crashed: " + first_line(out)
    if chk.returncode != 0:
        if POS.search(out):
            return "rejected", first_error(out)
        return "fail", "rejected without file:line:col: " + first_line(out)
    outdir = path[:-4] + ".out"
    env = dict(os.environ, RIG_SANITIZE="1", RIG_OUT_DIR=outdir)
    try:
        r = subprocess.run([RIG, "run", path], capture_output=True, text=True, timeout=120, env=env, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "fail", "timed out"
    err = r.stderr
    m = BAD.search(err)
    if not keep:
        shutil.rmtree(outdir, ignore_errors=True)
    if m:
        line = next((l for l in err.splitlines() if BAD.search(l)), m.group(0))
        return "fail", line.strip()
    return "ok", ""


def run_oracle(work, cells, args):
    """Check every program with the reference ownership checker; its exit status."""
    if not os.access(ORACLE, os.X_OK):
        print(f"{ORACLE} is not built; run `zig build oracle`")
        return 1
    listing = os.path.join(work, "oracle.list")
    with open(listing, "w") as fh:
        for ident, path in cells:
            fh.write(f"{ident}\t{path}\n")
    cmd = [ORACLE, "--set", "matrix", "--allow", os.path.join(ROOT, "test", "oracle", "differences"),
           "--coverage", os.path.join(ROOT, "test", "oracle", "coverage"), "--list", listing]
    if args.v:
        cmd.append("-v")
    r = subprocess.run(cmd, stdin=subprocess.DEVNULL)
    if not args.keep:
        shutil.rmtree(work, ignore_errors=True)
    return r.returncode


def first_line(s):
    return next((l for l in s.splitlines() if l.strip()), "")


def first_error(s):
    for l in s.splitlines():
        if ": error: " in l:
            return re.sub(r"^.*?: error: ", "", l)
    return first_line(s)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-j", type=int, default=4, help="programs at a time (default 4)")
    ap.add_argument("-k", action="append", default=[], help="only ids containing this (repeatable)")
    ap.add_argument("--keep", help="write the programs here and keep them and their builds")
    ap.add_argument("-v", action="store_true", help="list every result")
    ap.add_argument("--oracle", action="store_true", help="run bin/rig-oracle over the programs instead")
    args = ap.parse_args()
    if not os.access(RIG, os.X_OK):
        sys.exit(f"{RIG} is not built; run `zig build`")
    work = args.keep or tempfile.mkdtemp(prefix="rig-matrix.")
    os.makedirs(work, exist_ok=True)
    cells = []
    skipped = 0
    for t in TYPES:
        for c in CONTEXTS:
            for f in FORMS:
                ident = f"{t}.{c}.{f}"
                if args.k and not any(k in ident for k in args.k):
                    continue
                src = program(t, f, c)
                if src is None:
                    skipped += 1
                    continue
                path = os.path.join(work, ident.replace(".", "__") + ".rig")
                with open(path, "w") as fh:
                    fh.write(src)
                cells.append((ident, path))
    for o in STORE_OWNERS:
        for f in STORE_FORMS:
            for then in ("grow", "read"):
                ident = f"store.{o}.{f}.{then}"
                if args.k and not any(k in ident for k in args.k):
                    continue
                path = os.path.join(work, ident.replace(".", "__") + ".rig")
                with open(path, "w") as fh:
                    fh.write(store_program(o, f, then))
                cells.append((ident, path))
    if args.oracle:
        sys.exit(run_oracle(work, cells, args))
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.j) as pool:
        futs = {pool.submit(run_one, p, bool(args.keep)): i for i, p in cells}
        for fut in concurrent.futures.as_completed(futs):
            results[futs[fut]] = fut.result()
    counts = {}
    for ident, (st, why) in sorted(results.items()):
        counts[st] = counts.get(st, 0) + 1
        if st == "fail" or args.v:
            print(f"{st:9} {ident}  {why}")
    reasons = {}
    for st, why in results.values():
        if st == "rejected":
            key = re.sub(r"`[^`]*`", "X", why)
            reasons[key] = reasons.get(key, 0) + 1
    if args.v:
        print("\nrejections by message:")
        for k, n in sorted(reasons.items(), key=lambda kv: -kv[1]):
            print(f"{n:5}  {k}")
    print(f"\n{len(cells)} programs ({skipped} cells where the form cannot stand): "
          f"{counts.get('ok', 0)} ran clean, {counts.get('rejected', 0)} rejected, {counts.get('fail', 0)} failed")
    if not args.keep:
        shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if counts.get("fail") else 0)


if __name__ == "__main__":
    main()
