#!/usr/bin/env python3
"""Generate and run the form x context x type matrix of small programs.

Each program puts one expression form (a place, a ternary, `o?`, ...) in
one context (a `print` argument, a binding, an element assignment, ...)
for one type (Int, String, Text, Vec, `*T`, Box, a struct with a
`drop`, a struct holding a Cell, a struct declared `unique`), plus the
stores into a view parameter (`store.`, below) and the views of a
read `match` payload, used in the arm or escaping (`payload.`). The rule
is the corpus's: `rig check` rejects the program with a file:line:col
diagnostic, or it runs, and runs clean under the sanitizer (no leak, no
use of freed memory, no Zig compile error, no crash). A `payload.`
program that runs must also print what the payload holds.

    test/matrix.py                 # generate, check, and run everything
    test/matrix.py -j 8 -k vec     # 8 at a time; only ids containing "vec"
    test/matrix.py --keep DIR      # write the programs to DIR and keep them
                                   # (one run at a time in DIR)
    test/matrix.py --oracle        # only run the reference ownership checker
                                   # (bin/rig-oracle, test/oracle/) over them
    test/matrix.py --shard 2/4     # only the cells whose id hashes to shard 2 of 4

Nothing it writes is committed: programs go to a temporary directory,
and each run's output is removed after it passes. Programs build in
test/run's store (RIG_BUILD_STORE, test/README.md), so a program built
before, by any worktree, is not built again.
"""

import argparse
import concurrent.futures
import fcntl
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RIG = os.path.join(ROOT, "bin", "rig")
ORACLE = os.path.join(ROOT, "bin", "rig-oracle")


def build_store():
    """Where programs build: RIG_BUILD_STORE, else test/run's default, the
    store in the repository's git directory that its worktrees share;
    empty builds each program in its own output directory."""
    if "RIG_BUILD_STORE" in os.environ:
        return os.environ["RIG_BUILD_STORE"]
    if not os.path.exists(os.path.join(ROOT, ".git")):
        return ""
    r = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                       cwd=ROOT, capture_output=True, text=True)
    return os.path.join(r.stdout.strip(), "rig-build-store") if r.returncode == 0 else ""


STORE = build_store()

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

N_DECL = "struct N\n  v: Int\n\n  fun peek(?self, k: Int) -> Int\n    self.v + k\n\n  fun me(?self) -> ?N\n    self\n"
TYPES = {
    "int": dict(ty="Int", decls="", mk="n", ctor="Int(5)"),
    "string": dict(ty="String", decls="", mk='"s" if n > 0 else "t"', ctor='"lit"'),
    "text": dict(ty="Text", decls="", mk='Text("t", n)', ctor='Text("lit")'),
    "vec": dict(ty="Vec[Int]", decls="",
                mk="xs: Vec[Int] = Vec()\n  !xs.push(n)\n  xs", ctor="Vec[Int]()"),
    "shared": dict(ty="*N", decls=N_DECL, mk="*N(v: n)", ctor="*N(v: 5)"),
    "box": dict(ty="Box[N]", decls=N_DECL, mk="Box(N(v: n))", ctor="Box(N(v: 5))"),
    "drop": dict(ty="D", decls='struct D\n  v: Int\n\n  drop(!self)\n    print("drop", self.v)\n\n  fun take(<self) -> Int\n    self.v\n\n  sub bump(!self)\n    self.v += 1\n\n  fun peek(?self, k: Int) -> Int\n    self.v + k\n\n  fun me(?self) -> ?D\n    self\n',
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
    "lend_arg": dict(inline="print(look(?E))"),
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
    # A header whose subject makes a temporary (`?Text(...)`): it takes
    # the value a call makes there, so it binds that value.
    "match_subject_temp": dict(inline='match pass_t(E, ?Text("t"))\n    y => print(look(?y))', temp=True),
    "as_temp": dict(inline='if some_t(E, ?Text("t")) as y\n    print(look(?y))', temp=True),
    # A method that consumes its receiver (`<self`, `Box.unbox`).
    "recv_consume": dict(inline="print((E).M)", recv={"drop": "take()", "box": "unbox().v"}),
    # A method that writes its receiver: a value made there, or one
    # lent with `!` (a place without one is rejected).
    "recv_write": dict(inline="(E).M", recv={"vec": "push(1)", "text": 'add("x")', "drop": "bump()"}),
    # `!` lends any value to write (Core sentence 4): the receiver of a
    # write method, an argument where a `!T` goes, and a write view held
    # past the statement, which a temporary's must not be.
    "recv_write_lent": dict(inline="!(E).M", recv={"vec": "push(1)", "text": 'add("x")', "drop": "bump()"}),
    "write_arg": dict(inline="print(poke(!(E)))", write=True),
    "write_held": dict(inline="x = !(E)", after="print(look(?x))"),
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
    # A view a method returns of its receiver, kept while the receiver's
    # place is lent to write: the view keeps every place the receiver may
    # be lent, and one of a value made there ends with its statement.
    "recv_view_then_write": dict(inline="r = (E).M\n  _ = poke(!W)\n  print(r.v)", write=True,
                                 recv={t: "me()" for t in ("shared", "box", "drop")}),
    "eq_then_write": dict(inline="print((E) == pokev(!W))", write=True, types=("int", "string", "text")),
    "index_then_write": dict(inline="print((E)[poke(!W)])", write=True, types=("vec",)),
    # A `?self` method returning a view of its receiver (`me`): the view
    # held past the statement, used after a later operand writes what the
    # form reads, or held while a later statement writes it.
    "recv_view": dict(inline="x = (E).M", after="print(x.v)", recv={"drop": "me()", "shared": "me()"}),
    "recv_view_arg_then_write": dict(inline="print((E).M.v, poke(!W))", write=True,
                                     recv={"drop": "me()", "shared": "me()"}),
    "recv_view_held_then_write": dict(inline="x = (E).M", after="print(poke(!W), x.v)", write=True,
                                      recv={"drop": "me()", "shared": "me()"}),
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
# Stores into a view parameter: `f` stores a view of its write
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


# -----------------------------------------------------------------------------
# A view of a read `match` payload: used in its arm, or escaping the match
# (returned from the function that matches, or stored in a binding it
# returns). Each cell runs other code on the stack before it reads the
# view, and must print what the payload holds, since the sanitizer cannot
# see a stale stack slot. Cells are `payload.<type>.<subject>.<use>`.
# -----------------------------------------------------------------------------

# Each payload type: its spelling, `mk()` and `mk2()` bodies making two
# different values, the statement that shows a view `v` of one, and what
# it prints for `mk()`.
PAYLOAD_TYPES = {
    "int": dict(ty="Int", mk="4", mk2="40", show="print(v)", out="4"),
    "plain": dict(ty="P", mk="P(x: 4, y: 5)", mk2="P(x: 40, y: 50)", show="print(v.x, v.y)", out="4 5"),
    "owner": dict(ty="Res", mk='Res(n: 1, t: Text("hello"))', mk2='Res(n: 10, t: Text("k"))',
                  show="print(v.n, v.t)", out="1 hello"),
    "text": dict(ty="Text", mk='Text("tx")', mk2='Text("other")', show="print(v)", out="tx"),
    "vec": dict(ty="Vec[Int]", mk="xs: Vec[Int] = Vec()\n  !xs.push(8)\n  xs",
                mk2="xs: Vec[Int] = Vec()\n  !xs.push(80)\n  !xs.push(81)\n  xs",
                show="print(v[0], v.len)", out="8 1"),
    "box": dict(ty="Box[N]", mk="Box(N(v: 6))", mk2="Box(N(v: 60))", show="print(v.v)", out="6"),
    "shared": dict(ty="*N", mk="*N(v: 7)", mk2="*N(v: 70)", show="print(v.v)", out="7"),
}
# How the match reaches the enum: a `?E` parameter matched bare or lent
# again, a `?Box[E]` parameter, a field of a `?H` parameter, or, in a
# generic function, a `?G[T]` parameter, the view a call returns of one,
# a lend of that view, a branching value, or a field of a view a call
# returns. `main` makes `e` from `mk()` and passes `?e`.
PAYLOAD_SUBJECTS = {
    "param": dict(param="e: ?E", subj="e"),
    "lend": dict(param="e: ?E", subj="?e"),
    "box": dict(param="e: ?Box[E]", subj="e", make="e = Box(E.a(r: mk()))"),
    "field": dict(param="e: ?H", subj="e.e", make="e = H(e: E.a(r: mk()))"),
    "generic": dict(param="e: ?G[T]", subj="e", make="e: G[TY] = .a(r: mk())", generic=True),
    "generic_call": dict(param="e: ?G[T]", subj="getg(e)", make="e: G[TY] = .a(r: mk())", generic=True),
    "generic_lend_call": dict(param="e: ?G[T]", subj="?getg(e)", make="e: G[TY] = .a(r: mk())", generic=True),
    "generic_branch": dict(param="e: ?G[T]", subj="(e if yes() else e)", make="e: G[TY] = .a(r: mk())", generic=True),
    "generic_field_call": dict(param="e: ?GH[T]", subj="getgh(e).e", make="e: GH[TY] = GH(e: .a(r: mk()))", generic=True),
}
# Where the view goes: the arms use it (`arm`, through `see`, which runs
# `clobber` first), return it (`ret`), or store it (`store`) in a binding
# that held a view of `k` and that the function returns. A `copy` escape
# returns the payload, or the whole value, by value.
PAYLOAD_ESCAPES = {
    "arm": dict(arm=[".a(r) => see(?r)", ".b(r) => see(?r)"]),
    "arm_guard": dict(arm=[".a(r) if ok(?r) => see(?r)", "_ => pass"]),
    "arm_local": dict(arm=[".a(r)", "  w = ?r", "  see(w)", ".b(_) => pass"]),
    "arm_whole": dict(arm=[".b(_) => pass", "x => seee(?x)"]),
    "return": dict(ret=[".a(r) => ?r", ".b(r) => ?r"]),
    "guard": dict(ret=[".a(r) if ok(?r) => ?r", ".a(r) => ?r", ".b(r) => ?r"]),
    "whole": dict(ret=["x => ?x"], whole=True),
    "store": dict(store=[".a(r) => saved = ?r", ".b(_) => pass"]),
    "guard_store": dict(store=[".a(r) if ok(?r) => saved = ?r", "_ => pass"]),
    "whole_store": dict(store=[".b(_) => pass", "x => saved = ?x"], whole=True),
    "copy": dict(ret=[".a(r) => r", ".b(r) => r"], copy=True),
    "copy_guard": dict(ret=[".a(r) if ok(?r) => r", ".a(r) => r", ".b(r) => r"], copy=True),
    "copy_whole": dict(ret=["x => x"], whole=True, copy=True),
}


def payload_program(tname, sname, ename):
    """The program for one payload cell, and the output it must print."""
    t = PAYLOAD_TYPES[tname]
    s = PAYLOAD_SUBJECTS[sname]
    x = PAYLOAD_ESCAPES[ename]
    ty = t["ty"]
    out = ["struct N\n  v: Int\n", "struct P\n  x: Int\n  y: Int\n", "struct Res\n  n: Int\n  t: Text\n",
           f"enum E\n  a(r: {ty})\n  b(r: {ty})\n", "struct H\n  e: E\n", "enum G[T]\n  a(r: T)\n  b(r: T)\n",
           "struct GH[T]\n  e: G[T]\n", "fun getg[T](e: ?G[T]) -> ?G[T] from e\n  e\n",
           "fun getgh[T](h: ?GH[T]) -> ?GH[T] from h\n  h\n", "fun yes() -> Bool\n  true\n",
           f"fun mk() -> {ty}\n  {t['mk']}\n", f"fun mk2() -> {ty}\n  {t['mk2']}\n",
           f"fun ok(v: ?{ty}) -> Bool\n  true\n",
           "fun clobber(n: Int) -> Int\n  a = [n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7]\n"
           "  b = [n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7]\n  a[1] + b[2]\n"]
    show = [t["show"]]
    if x.get("whole"):
        # A view of the whole value is shown through its payload.
        show = ["match v", "  .a(p) => show(?p)", "  .b(p) => show(?p)"]
        out.append(f"sub show(v: ?{ty})\n  {t['show']}\n")
    main = [s.get("make", "e = E.a(r: mk())").replace("TY", ty)]
    if "arm" in x:
        if s.get("generic"):
            return None, None
        out.append(f"sub see(v: ?{ty})\n  print(clobber(1000))\n  {t['show']}\n")
        out.append(f"sub seee(v: ?E)\n  match v\n    .a(p) => see(?p)\n    .b(p) => see(?p)\n")
        out.append(f"sub inner({s['param']})\n  match {s['subj']}\n" + indent(x["arm"], 4) + "\n")
        main.append("inner(?e)")
        out.append("sub main\n" + indent(main, 2) + "\n")
        return "\n".join(out), f"2003\n{t['out']}\n"
    res = "E" if x.get("whole") else ty
    fun = "inner"
    if s.get("generic"):
        # The payload type is the function's `T`; `gok` is `ok` for it.
        res = "G[T]" if x.get("whole") else "T"
        fun = "inner[T]"
        out.append("fun gok[T](v: ?T) -> Bool\n  true\n")
    arms = [a.replace("ok(", "gok(") if s.get("generic") else a for a in x.get("ret", x.get("store", []))]
    if "ret" in x:
        view = "" if x.get("copy") else "?"
        out.append(f"fun {fun}({s['param']}) -> {view}{res}\n  match {s['subj']}\n" + indent(arms, 4) + "\n")
        main.append("v = inner(?e)")
    else:
        body = ["saved = k", f"match {s['subj']}"] + ["  " + a for a in arms] + ["saved"]
        out.append(f"fun {fun}({s['param']}, k: ?{res}) -> ?{res}\n" + indent(body, 2) + "\n")
        whole_k = f"k: G[{ty}] = .b(r: mk2())" if s.get("generic") else "k = E.b(r: mk2())"
        main += [whole_k if x.get("whole") else "k = mk2()", "v = inner(?e, ?k)"]
    main.append("print(clobber(1000))")
    main += show
    out.append("sub main\n" + indent(main, 2) + "\n")
    return "\n".join(out), f"2003\n{t['out']}\n"


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
    if ctx.get("temp"):
        out.append(f"fun pass_t(x: {ty}, t: ?Text) -> {ty}\n  x\n")
        out.append(f"fun some_t(x: {ty}, t: ?Text) -> {ty}?\n  x\n")
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
        if cname in ("lend_arg", "for_source") and " " in e:
            e = f"({e})"
        # `@POKE` and `@POKY` stand for the type's change through the loop
        # or match binding, or `pass`; they are replaced before `E` is.
        poke = t.get("poke", "pass")
        text = text.replace("@POKY", "@Y").replace("@POKE", "@P")
        body.append(text.replace("E", e).replace("@Y", poke.replace("e.", "y.")).replace("@P", poke))
    if "after" in ctx:
        after = ctx["after"]
        if ctx.get("write"):
            after = after.replace("!W", "!" + WRITE_TARGETS.get(fname, "a"))
        body.append(after)
    if not returns:
        body.append("0")
    out.append(f"fun run(c: Bool, o: {ty}?) -> {ret_ty}\n{indent(body, 2)}\n")
    main = ["for c in [true, false]", "  r = run(c, mk(9))", "  print(r == none)"]
    out.append("sub main\n" + indent(main, 2) + "\n")
    return "\n".join(out)


def run_one(path, keep, started_dir, expect=None):
    """Classify one program: rejected, ok, or a failure with its reason.
    With `expect`, a program that runs must print exactly that."""
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
    # rig creates `started` once the program has started: the evidence
    # that it ran (test/run's run_program). Each attempt has a fresh path
    # in this run's private directory, which no other run shares.
    started = os.path.join(started_dir, os.path.basename(path)[:-4] + "." + uuid.uuid4().hex)
    env = dict(os.environ, RIG_SANITIZE="1", RIG_OUT_DIR=outdir, RIG_BUILD_STORE=STORE, RIG_RUN_STARTED=started)
    try:
        r = subprocess.run([RIG, "run", path], capture_output=True, text=True, errors="replace", timeout=120, env=env, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "fail", "timed out"
    err = r.stderr
    m = BAD.search(err)
    ran = os.path.isfile(started) and "rig: the program did not run" not in err
    if os.path.lexists(started):
        os.remove(started)
    if not keep:
        shutil.rmtree(outdir, ignore_errors=True)
    if not ran:
        return "fail", "the program did not run: " + first_line(err)
    if m:
        line = next((l for l in err.splitlines() if BAD.search(l)), m.group(0))
        return "fail", line.strip()
    # rig says when a signal ended the program (its status alone cannot).
    # A Rig panic aborts (signal 6) after its `panic:` report; any other
    # signal came from outside, or is a crash nothing reported.
    sig = re.search(r"rig: the program was killed by signal (\d+)", err)
    if sig and not (sig.group(1) == "6" and "panic: " in err):
        return "fail", "killed by signal %s: %s" % (sig.group(1), first_line(err))
    if expect is not None and r.stdout != expect:
        return "fail", "printed " + repr(r.stdout) + ", expected " + repr(expect)
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
    ap.add_argument("--shard", help="I/N: only the cells whose id hashes to I - 1 modulo N (1 <= I <= N)")
    args = ap.parse_args()
    shard = re.fullmatch(r"([1-9][0-9]*)/([1-9][0-9]*)", args.shard or "1/1")
    if not shard or int(shard[1]) > int(shard[2]):
        ap.error("--shard needs I/N, with 1 <= I <= N")
    if args.oracle and args.shard:
        # The oracle's coverage floor is for every program.
        ap.error("--oracle runs over every program: it takes no --shard")
    shard_i, shard_n = int(shard[1]), int(shard[2])

    def wanted(ident):
        if args.k and not any(k in ident for k in args.k):
            return False
        return zlib.crc32(ident.encode()) % shard_n == shard_i - 1
    if not os.access(RIG, os.X_OK):
        sys.exit(f"{RIG} is not built; run `zig build`")
    work = args.keep or tempfile.mkdtemp(prefix="rig-matrix.")
    os.makedirs(work, exist_ok=True)
    if args.keep:
        # One run at a time in a kept directory: runs sharing one would
        # overwrite each other's programs.
        lock = open(os.path.join(work, ".matrix.lock"), "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"waiting for the matrix run in {work}", file=sys.stderr)
            fcntl.flock(lock, fcntl.LOCK_EX)
    cells = []
    skipped = 0
    for t in TYPES:
        for c in CONTEXTS:
            for f in FORMS:
                ident = f"{t}.{c}.{f}"
                if not wanted(ident):
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
                if not wanted(ident):
                    continue
                path = os.path.join(work, ident.replace(".", "__") + ".rig")
                with open(path, "w") as fh:
                    fh.write(store_program(o, f, then))
                cells.append((ident, path))
    expects = {}
    for t in PAYLOAD_TYPES:
        for sname in PAYLOAD_SUBJECTS:
            for e in PAYLOAD_ESCAPES:
                ident = f"payload.{t}.{sname}.{e}"
                if not wanted(ident):
                    continue
                src, expects[ident] = payload_program(t, sname, e)
                if src is None:
                    skipped += 1
                    continue
                path = os.path.join(work, ident.replace(".", "__") + ".rig")
                with open(path, "w") as fh:
                    fh.write(src)
                cells.append((ident, path))
    if args.oracle:
        sys.exit(run_oracle(work, cells, args))
    results = {}
    started_dir = tempfile.mkdtemp(prefix="rig-matrix-started.")
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.j) as pool:
            futs = {pool.submit(run_one, p, bool(args.keep), started_dir, expects.get(i)): i for i, p in cells}
            for fut in concurrent.futures.as_completed(futs):
                results[futs[fut]] = fut.result()
    finally:
        shutil.rmtree(started_dir, ignore_errors=True)
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
