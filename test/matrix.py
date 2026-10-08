#!/usr/bin/env python3
"""Generate and run the form x context x type matrix of small programs.

Each program puts one expression form (a place, a ternary, `o?`, ...) in
one context (a `print` argument, a binding, an element assignment, ...)
for one type (Int, String, Text, Vec, `*T`, Box, a struct with a
`drop`, a struct holding a Cell, a struct declared `unique`), plus the
stores into a view parameter (`store.`, below), the views of a
read `match` payload, used in the arm or escaping (`payload.`), a
`while` step reading what its condition binds (`step.`), and the
shapes of nested loops and the jumps between them (`loop.`), and a Cell
changed through each kind of path to the value holding it (`cellmut.`),
and the Cell of a temporary changed where it stands, alone or as a leaf
of a value that branches (`celltemp.`), each built in debug and with
`--release`. The rule is
the corpus's: `rig check` rejects the program with a file:line:col
diagnostic, or it runs, and runs clean under the sanitizer (no leak, no
use of freed memory, no Zig compile error, no crash). A `payload.`
program that runs must also print what the payload holds, and a `loop.`
program the trace of its steps, defers, and drops. A `cellmut.` or
`celltemp.` program must be accepted, and print its trace in debug and
again built with `--release`.

    test/matrix.py                 # generate, check, and run everything
    test/matrix.py -j 8 -k vec     # 8 at a time; only ids containing "vec"
    test/matrix.py --keep DIR      # write the programs to DIR and keep them
                                   # (one run at a time in DIR)
    test/matrix.py --oracle        # only run the reference ownership checker
                                   # (bin/rig-oracle, test/oracle/) over them
    test/matrix.py --shard 2/4     # only the cells whose id hashes to shard 2 of 4
    test/matrix.py --rig OLD/rig   # test another compiler
    test/matrix.py --timeout 20 --mem 2048   # each program's limits

Each program is stopped past its time, past 1 MB of output, or when its
processes hold more than its memory, and every loop a cell writes
counts its passes and stops past a cap, so a loop that never ends fails
the cell.

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
import signal
import subprocess
import sys
import tempfile
import time
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
    # Values that copy (`sema.copies`): a plain struct and an array,
    # which a view's value is copied out as a number's is.
    "plain": dict(ty="P", decls="struct P\n  v: Int\n", mk="P(v: n)", ctor="P(v: 5)"),
    "array": dict(ty="A2", decls="type A2 = [2]Int\n", mk="[n, n + 1]", ctor="[5, 6]"),
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
    # A bare name holding a read view (`r = ?a`) or a write view
    # (`w = !a`) of `a`: a read view copies, and where a value is taken,
    # a view of a value that copies is copied out (Core sentence 1, §4).
    "read_view": "r",
    "write_view": "w",
}
# The binding each view form reads, declared before the context.
VIEW_FORMS = {"read_view": "r = ?a", "write_view": "w = !a"}

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
    "plain": "x = P(v: 9)", "array": "x[0] += 1",
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
# A `while` step that reads what its condition binds: a view of `v` (a
# Vec's `[]Int`, a Text's `String`), a struct holding one read through a
# field or a method, while the body grows `v` (or only reads it) on its
# way to the step: falling off its end, `continue`, `continue :outer`
# from a nested `for`, `while`, or `while … as` (also where the loop is
# written as nested `if`s, for a joined condition or a `catch break`
# in it), an inner loop, a `defer`, or a `break` (where the step does
# not run). The step runs after the body, so it must not read what the
# body grew, and a `read` cell must print the count of the steps it ran.
# Cells are `step.<owner>.<holder>.<shape>.<then>`.
# -----------------------------------------------------------------------------

STEP_OWNERS = {
    "vec": dict(ty="Vec[Int]", view="[]Int", lend="?v[..]", make="v: Vec[Int] = Vec()\n  !v.push(1)",
                grow="!v.push(i)", read="X[0]"),
    "text": dict(ty="Text", view="String", lend="?v[0..1]", make='v = Text("abc")',
                 grow='!v.add("abcdefgh")', read='(1 if text.ends_with(X, "a") else 0)'),
}
# What the condition binds: its type, how `mk` makes it from the view
# `L`, and how the step reads the view `X` from it.
STEP_HOLDERS = {
    "view": dict(ty="(V)", make="L", x="h"),
    "field": dict(ty="H", make="H(r: L)", x="h.r"),
    "method": dict(ty="H", make="H(r: L)", x="h.get()"),
}
# The loop: `C` its condition (`J` joined, `F` failing, `B` with a
# `catch break`), `S` its step, `G` what grows `v`.
STEP_SHAPES = {
    "plain": ["while C: S", "  n += 1", "  G"],
    "continue": ["while C: S", "  n += 1", "  if n > 0", "    G", "    continue", "  k += 1"],
    "labeled": [":outer while C: S", "  n += 1", "  for _ in 0..1", "    G", "    continue :outer"],
    "labeled_joined": [":outer while J: S", "  n += 1", "  for _ in 0..1", "    G", "    continue :outer"],
    "labeled_catchbreak": [":outer while B: S", "  n += 1", "  for _ in 0..1", "    G", "    continue :outer"],
    "labeled_while": [":outer while C: S", "  n += 1", "  j = 0", "  while j < 2: j += 1", "    G", "    continue :outer"],
    "labeled_while_joined": [":outer while J: S", "  n += 1", "  j = 0", "  while j < 2: j += 1", "    G", "    continue :outer"],
    "labeled_while_catchbreak": [":outer while B: S", "  n += 1", "  j = 0", "  while j < 2: j += 1", "    G", "    continue :outer"],
    "labeled_whileas_joined": [":outer while J: S", "  n += 1", "  while mk(?v, 0) as _", "    G", "    continue :outer"],
    "labeled_whileas_catchbreak": [":outer while B: S", "  n += 1", "  while mk(?v, 0) as _", "    G", "    continue :outer"],
    "inner": ["while C: S", "  n += 1", "  j = 0", "  while j < 1: j += 1", "    G"],
    "defer": ["while C: S", "  n += 1", "  defer G"],
    "joined": ["while J: S", "  n += 1", "  G"],
    "failure": ["while F: S", "  n += 1", "  G"],
    "break": ["while C: S", "  n += 1", "  if n > 1", "    G", "    break"],
}


def step_program(oname, hname, shape, then):
    """The program for one step cell."""
    o = STEP_OWNERS[oname]
    h = STEP_HOLDERS[hname]
    v = o["view"]
    hty = h["ty"].replace("V", v)
    out = ["use std.text\n" if oname == "text" else "", "error E\n  bad\n",
           f"struct H\n  r: {v}\n\n  fun get(?self) -> {v}\n    self.r\n",
           f"sub grow(v: !{o['ty']})\n  for {'i' if 'i' in o['grow'] else '_'} in 0..100\n    {o['grow']}\n",
           f"fun mk(v: ?{o['ty']}, n: Int) -> {hty}?\n  if n < 3\n    return {h['make'].replace('L', o['lend'])}\n  none\n",
           f"fun mkf(v: ?{o['ty']}, n: Int) -> {hty}?!\n  return E.bad if n == 7\n  mk(v, n)\n"]
    step = "k += " + o["read"].replace("X", h["x"])
    grow = "grow(!v)" if then == "grow" else "k += 1"
    loop = [l.replace("C", "mk(?v, n) as h").replace("J", "mk(?v, n) as h and n >= 0")
             .replace("F", "(mkf(?v, n) catch none) as h").replace("B", "(mkf(?v, n) catch break) as h")
             .replace("S", step).replace("G", grow)
            for l in STEP_SHAPES[shape]]
    main = [o["make"], "k = 0", "n = 0"] + loop + ["print(k, n)"]
    out.append("sub main()\n" + indent(main, 2) + "\n")
    return "\n".join(out)


def step_output(shape):
    """What a `read` step cell prints: three passes, each adding 1 in the
    body and 1 in the step, but `break`, which leaves in the second."""
    return "2 2\n" if shape == "break" else "6 3\n"


# -----------------------------------------------------------------------------
# Loop shapes: an outer loop labeled `:outer` holding an inner construct
# that jumps once, in the outer loop's second pass, with a `defer` or an
# owned local at the outer body's end. Every program prints a trace of
# its passes, steps, defers, and drops, which must be the one
# `loop_trace` computes from the meaning of the jumps (SPEC, "while" and
# "Labels, break, and continue"): a step runs after the body's defers and
# drops on every path but `break`, and a jump in a loop's `else` targets
# the loop around it. Cells are `loop.<outer>.<inner>.<jump>.<end>`.
# -----------------------------------------------------------------------------

LOOP_OUTERS = {
    "while": ":outer while i < 3: i = st(i)",
    "while_as": ":outer while lim(i, 3) as h: i = st(h)",
    "joined": ":outer while lim(i, 3) as h and h >= 0: i = st(h)",
    "catch_break": ":outer while (limf(i, 3) catch break) as h: i = st(h)",
    "for": ":outer for q in 0..3",
}
# Each inner construct, with `JUMP` the statement that jumps; a loop's
# `else` (or the construct's last branch) holds `ELSE`.
LOOP_INNERS = {
    "while": ["j = 0", "while j < 2: j += 1", "  print(\"in\", i, j)", "  JUMP", "  print(\"after\", i, j)", "ELSE"],
    "for": ["for j in 0..2", "  print(\"in\", i, j)", "  JUMP", "  print(\"after\", i, j)", "ELSE"],
    "while_as": ["j = 0", "while lim(j, 2) as g: j = g + 1", "  print(\"in\", i, g)", "  JUMP", "  print(\"after\", i, g)", "ELSE"],
    "match": ["match i", "  1 => JUMP", "  _ => print(\"m\", i)"],
    "if": ["if i == 1", "  JUMP", "else", "  print(\"m\", i)"],
}
LOOP_JUMPS = {
    "continue": "continue",
    "continue_outer": "continue :outer",
    "break_outer": "break :outer",
    "else_continue": None,
}


def loop_program(outer, inner, jump, end):
    """The program for one loop cell."""
    # Every pass of every loop counts, so a loop that runs away (a step a
    # `continue` skipped) stops and prints `cap`, which no trace has.
    cap = ["guard += 1", "if guard > 50", '  print("cap")', "  return"]
    lines = list(cap)
    if outer == "for":
        lines.append("i = q")
    lines.append('defer print("defer", i)' if end == "defer" else "x = D(n: i)")
    lines.append('print("body", i)')
    word = LOOP_JUMPS[jump]
    var = "g" if inner == "while_as" else "j"
    if word is None and inner == "match":
        lines += ["match i", '  0 => print("m", i)', '  2 => print("m", i)', "  _ => continue"]
    elif word is None and inner == "if":
        lines += ["if i != 1", '  print("m", i)', "else", "  continue"]
    else:
        guard = f" if i == 1 and {var} == 1" if inner in ("while", "for", "while_as") else ""
        for l in LOOP_INNERS[inner]:
            if l.startswith("while") or l.startswith("for"):
                lines.append(l)
                lines += ["  " + c for c in cap]
            elif l == "ELSE":
                if word is None:
                    lines += ["else", '  print("else", i)', "  continue if i == 1"]
            elif "JUMP" in l:
                if word is not None:
                    lines.append(l.replace("JUMP", word + guard))
            else:
                lines.append(l)
    lines.append('print("tail", i)')
    head = ["struct D", "  n: Int", "", "  drop(!self)", '    print("drop", self.n)', "",
            "error E", "  bad", "",
            "fun st(i: Int) -> Int", '  print("step", i)', "  i + 1", "",
            "fun lim(i: Int, n: Int) -> Int?", "  i if i < n else none", "",
            "fun limf(i: Int, n: Int) -> Int?!", "  return E.bad if i > 50", "  lim(i, n)", ""]
    main = ["sub main()", "  i = 0", "  guard = 0", "  " + LOOP_OUTERS[outer]] + ["    " + l for l in lines] + ['  print("end", i)']
    return "\n".join(head + main) + "\n"


def loop_trace(outer, inner, jump, end):
    """What a loop cell prints."""
    out = []
    is_loop = inner in ("while", "for", "while_as")
    i = 0
    while i < 3:
        out.append(f"body {i}")
        action = "next"
        if is_loop:
            for j in range(2):
                out.append(f"in {i} {j}")
                if jump != "else_continue" and i == 1 and j == 1:
                    if jump == "continue":
                        continue
                    action = "cont" if jump == "continue_outer" else "break"
                    break
                out.append(f"after {i} {j}")
            if action == "next" and jump == "else_continue":
                out.append(f"else {i}")
                if i == 1:
                    action = "cont"
        elif jump == "else_continue":
            if i == 1:
                action = "cont"
            else:
                out.append(f"m {i}")
        elif i == 1:
            action = "break" if jump == "break_outer" else "cont"
        else:
            out.append(f"m {i}")
        if action == "next":
            out.append(f"tail {i}")
        out.append(f"defer {i}" if end == "defer" else f"drop {i}")
        if action == "break":
            break
        if outer == "for":
            if i == 2:
                break
            i += 1
        else:
            out.append(f"step {i}")
            i += 1
    out.append(f"end {i}")
    return "\n".join(out) + "\n"


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
        out.append("sub main()\n" + indent(main, 2) + "\n")
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
    out.append("sub main()\n" + indent(main, 2) + "\n")
    return "\n".join(out), f"2003\n{t['out']}\n"


# -----------------------------------------------------------------------------
# A Cell changed, or read, through each kind of path to the value holding
# it, in each kind of position, built in debug and with `--release`: a
# change through a read view (`?self`, `?T`, `[]T`, `|?x|`) must reach the
# value in both, so emitted Zig never writes through a `*const` pointer or
# into `const` storage (`sema.interiorMutable`). Each program applies
# each operation (in a function of its own, to a value of its own)
# through one access in a statement, a loop that continues early, a loop
# that breaks, a `defer`, and a loop that returns, and prints the state
# after each, which must be what `cellmut_output` computes. Cells are
# `cellmut.<type>.<access>`: one program each, since a release build is
# slow.
# -----------------------------------------------------------------------------

# Each type: its spelling, declarations (`METHODS` marks where a struct's
# methods go), how `mk()` makes one, the paths to its `Cell[Int]` and its
# `Cell[Vec[Int]]` from a value `E` (None: it has none), and whether it
# prints when dropped.
_CM_C = "struct C\n  c: Cell[Int]\n  v: Cell[Vec[Int]]\n"
CELLMUT_TYPES = {
    # a `drop`
    "drop": dict(ty="D", decls='struct D\n  c: Cell[Int]\n  v: Cell[Vec[Int]]\n\n  drop(!self)\n    print("drop", self.c.get(), self.v.len)\nMETHODS',
                 mk="D(c: Cell(1), v: Cell(vec2()))", c="E.c", v="E.v", drop=True),
    # no `drop`
    "plain": dict(ty="N", decls="struct N\n  c: Cell[Int]\n  v: Cell[Vec[Int]]\nMETHODS",
                  mk="N(c: Cell(1), v: Cell(vec2()))", c="E.c", v="E.v"),
    # constant fields: a value Zig knows at compile time
    "const": dict(ty="K", decls="struct K\n  c: Cell[Int]\n  pad: [4]Int\nMETHODS",
                  mk="K(c: Cell(1), pad: [4 of 0])", c="E.c", v=None),
    # the Cells in a part
    "part": dict(ty="W", decls="struct In\n  c: Cell[Int]\n  v: Cell[Vec[Int]]\n\nstruct W\n  t: In\nMETHODS",
                 mk="W(t: In(c: Cell(1), v: Cell(vec2())))", c="E.t.c", v="E.t.v"),
    # a generic type at Int
    "generic": dict(ty="G[Int]", decls="struct G[T]\n  c: Cell[T]\n  v: Cell[Vec[T]]\nMETHODS",
                    mk="G(c: Cell(1), v: Cell(vec2()))", c="E.c", v="E.v"),
    # generic types holding a Cell holder only behind a handle, and in a
    # Vec: no Cell inline, so their views are `*const` while the Cells
    # they reach change
    "behind_handle": dict(ty="P[C]", decls=_CM_C + "\nstruct P[T]\n  h: *T\n", methods=False,
                          mk="P(h: *C(c: Cell(1), v: Cell(vec2())))", c="E.h.c", v="E.h.v"),
    "in_vec": dict(ty="Q[C]", decls=_CM_C + "\nstruct Q[T]\n  items: Vec[T]\n\nfun cs() -> Vec[C]\n  xs: Vec[C] = Vec()\n  !xs.push(C(c: Cell(1), v: Cell(vec2())))\n  xs\n", methods=False,
                   mk="Q(items: cs())", c="E.items[0].c", v="E.items[0].v"),
    # a bare Cell[Int], and a bare Cell[Vec[Int]]
    "cell": dict(ty="Cell[Int]", decls="", mk="Cell(1)", c="E", v=None),
    "cellvec": dict(ty="Cell[Vec[Int]]", decls="", mk="Cell(vec2())", c=None, v="E"),
}

# Each operation, applied once through `E` with argument `KARG`, adding
# what it reads to `s`; `C` is the path to the `Cell[Int]`, `V` to the
# `Cell[Vec[Int]]`.
CELLMUT_OPS = {
    "set": ("c", ["C.set(C.get() + KARG)"]),
    "replace": ("c", ["s += C.replace(KARG)"]),
    "get": ("c", ["s += C.get()"]),
    "push": ("v", ["V.push(KARG)"]),
    "pop": ("v", ["s += V.pop() ?? -1"]),
    "clear": ("v", ["V.clear()", "V.push(KARG)"]),
    "index": ("v", ["V[0] = V[0] + KARG"]),
    "method": ("m", ["E.bump(KARG)"]),
}

# Each access: the declarations it adds (`T` the type, `OP` the
# operation through the access path `e`), the statements that set it up
# in `run`, how one application is written there (`OP` inline, or a
# call passing `KARG`), and the place that shows the state (`x`
# default; `opt` shows through `if o as z`). A wrapper returns the `s`
# its operation adds to.
_CM_WRAP = "  s = 0\nOP\n  s\n"
CELLMUT_ACCESS = {
    "local": dict(setup=["x = mk()"], do=["OP"], e="x"),
    "field": dict(decls="struct H\n  f: T\n", setup=["h = H(f: mk())"], do=["OP"], e="h.f", x="h.f"),
    "element": dict(setup=["vs: Vec[T] = Vec()", "!vs.push(mk())"], do=["OP"], e="vs[0]", x="vs[0]"),
    "array": dict(setup=["a = [mk()]"], do=["OP"], e="a[0]", x="a[0]"),
    "param": dict(decls="fun via(y: ?T, k: Int) -> Int\n" + _CM_WRAP, setup=["x = mk()"], do=["s += via(?x, KARG)"], e="y"),
    "slice": dict(decls="fun via(y: []T, k: Int) -> Int\n" + _CM_WRAP, setup=["a = [mk()]"], do=["s += via(?a[..], KARG)"], e="y[0]", x="a[0]"),
    "method": dict(method="fun via(?self, k: Int) -> Int\n" + _CM_WRAP, setup=["x = mk()"], do=["s += x.via(KARG)"], e="self"),
    "stored": dict(decls="struct R\n  r: ?T\n", setup=["x = mk()", "r = R(r: ?x)"], do=["OP"], e="r.r"),
    "capture": dict(closure=True, setup=["x = mk()"], do=["s += via(KARG)"], e="x"),
    "optional": dict(setup=["o: T? = mk()"], do=["if o as y", "  OP"], e="y", opt=True),
    "foreach": dict(setup=["vs: Vec[T] = Vec()", "!vs.push(mk())"], do=["for y in ?vs", "  OP"], e="y", x="vs[0]"),
    "shared": dict(setup=["x = *mk()"], do=["OP"], e="x"),
    # across the generic and runtime boundary: a view a generic function
    # returns, an element of a `?Vec` parameter, and a subslice
    "generic_fn": dict(decls="fun id[U](y: ?U) -> ?U\n  y\n", setup=["x = mk()"], do=["OP"], e="id(?x)"),
    "vec_view": dict(decls="fun via(ys: ?Vec[T], k: Int) -> Int\n" + _CM_WRAP, setup=["vs: Vec[T] = Vec()", "!vs.push(mk())"], do=["s += via(?vs, KARG)"], e="ys[0]", x="vs[0]"),
    "subslice": dict(decls="fun via(y: []T, k: Int) -> Int\n" + _CM_WRAP, setup=["a = [mk(), mk()]"], do=["s += via(?a[0..1], KARG)"], e="y[0]", x="a[0]"),
}


def cellmut_applies(tname, aname, oname):
    t, needs = CELLMUT_TYPES[tname], CELLMUT_OPS[oname][0]
    methods = t["decls"] != "" and t.get("methods", True)
    if needs == "c" and t["c"] is None or needs == "v" and t["v"] is None:
        return False
    return methods or (needs != "m" and aname != "method")


def _cm_op(t, oname, e, karg, acc="s"):
    """The operation's lines through path `e`, with argument `karg`,
    adding what it reads to `acc`."""
    out = []
    for l in CELLMUT_OPS[oname][1]:
        if t["c"]:
            l = l.replace("C.", t["c"].replace("E", e) + ".")
        if t["v"]:
            l = l.replace("V.", t["v"].replace("E", e) + ".").replace("V[", t["v"].replace("E", e) + "[")
        out.append(l.replace("E.", e + ".").replace("KARG", karg).replace("s += ", acc + " += "))
    return out


def _cm_wrap(text, ty, op):
    """A wrapper's declaration: `T` the type, `OP` its operation's lines."""
    text = text.replace("?T", "?" + ty).replace("[]T", "[]" + ty).replace("Vec[T]", f"Vec[{ty}]").replace(": T\n", ": " + ty + "\n")
    lines = []
    for l in text.rstrip("\n").split("\n"):
        lines += ["  " + o for o in op] if l == "OP" else [l]
    return lines


def cellmut_ops(tname, aname):
    """The operations a cellmut cell applies, in order."""
    return [o for o in CELLMUT_OPS if cellmut_applies(tname, aname, o)]


def cellmut_program(tname, aname):
    """The program for one cellmut cell: one `run_<op>` per operation,
    each on a value of its own, or None where no operation applies."""
    ops = cellmut_ops(tname, aname)
    if not ops:
        return None
    t, a = CELLMUT_TYPES[tname], CELLMUT_ACCESS[aname]
    ty = t["ty"]
    out = []
    if t["decls"] and not t.get("methods", True):
        out += t["decls"].rstrip("\n").split("\n") + [""]
    elif t["decls"]:
        methods = []
        c = t["c"].replace("E", "self")
        bump = [f"{c}.set({c}.get() + k)"] + ([t["v"].replace("E", "self") + ".push(k)"] if t["v"] else [])
        # A generic type's methods take and add its `T`.
        kty = "T" if tname == "generic" else "Int"
        methods += ["", f"  sub bump(?self, k: {kty})"] + ["    " + l for l in bump]
        if aname == "method":
            for oname in ops:
                wrap = a["method"].replace("via(", f"via_{oname}(")
                if tname == "generic":
                    wrap = wrap.replace("k: Int) -> Int", "k: T) -> T").replace("  s = 0\n", "  s: T = k - k\n")
                op = _cm_op(t, oname, "self", "k")
                if tname == "generic":
                    op = [l.replace("?? -1", "?? k - k - 1") for l in op]
                methods += [""] + ["  " + l for l in _cm_wrap(wrap, ty, op)]
        out += t["decls"].replace("\nMETHODS", "").split("\n") + methods + [""]
    out += ["fun vec2() -> Vec[Int]", "  v: Vec[Int] = Vec()", "  !v.push(1)", "  !v.push(2)", "  v", ""]
    out += [f"fun mk() -> {ty}", f"  {t['mk']}", ""]
    out += ["fun maybe(n: Int) -> Int?", "  return none if n % 2 == 1", "  n", ""]
    decls = a.get("decls", "")
    if "OP" not in decls:
        out += _cm_wrap(decls, ty, []) + [""]
    elif decls:
        for oname in ops:
            out += _cm_wrap(decls.replace("via(", f"via_{oname}("), ty, _cm_op(t, oname, a["e"], "k")) + [""]
    # The state, read through the owner.
    xs = "z" if a.get("opt") else a.get("x", "x")
    shown = []
    if t["c"]:
        shown.append(t["c"].replace("E", xs) + ".get()")
    if t["v"]:
        vp = t["v"].replace("E", xs)
        shown += [vp + ".len", f"({vp}.get(0) ?? -1)"]
    show = ["print(s, " + ", ".join(shown) + ")"]
    if a.get("opt"):
        show = ["if o as z", "  " + show[0]]
    for oname in ops:
        setup = [l.replace("[T]", f"[{ty}]").replace(": T?", f": {ty}?") for l in a["setup"]]
        if a.get("closure"):
            setup += [f"via_{oname} = |?x, k: Int|", "  t = 0"] + ["  " + l for l in _cm_op(t, oname, a["e"], "k", "t")] + ["  t"]

        def apply(k, ind):
            lines = []
            for l in a["do"]:
                if l.strip() == "OP":
                    lines += [ind + l.replace("OP", "") + o for o in _cm_op(t, oname, a["e"], k)]
                else:
                    lines.append(ind + l.replace("via(", f"via_{oname}(").replace("KARG", k))
            return lines
        body = ["s = 0"] + setup
        # a statement
        body += apply("1", "") + show
        # a loop whose argument may continue
        body += ["for i in 0..4"] + apply("i", "  ") + ["  s += maybe(i) ?? continue"] + show
        # a loop that breaks
        body += ["j = 0", "while j < 9", "  j += 1"] + apply("j", "  ") + ["  break if j == 3"] + show
        # a `defer` in a loop's body
        body += ["for _ in 0..2", "  defer"] + apply("10", "    ") + ["  s += 100"] + show
        # a loop that returns, with the state shown by a `defer`
        body += ["defer"] + ["  " + l for l in show] + ["for i in 0..9"] + apply("i", "  ") + ["  return if i == 2"]
        out += [f"sub run_{oname}()"] + ["  " + l for l in body] + [""]
    out += ["sub main()"] + [f'  print("{o}")\n  run_{o}()' for o in ops] + ['  print("end")']
    return "\n".join(out) + "\n"


def cellmut_output(tname, aname):
    """What a cellmut cell prints."""
    # A subslice's array holds a second value, untouched, which drops
    # first: an array drops its elements last to first.
    second = aname == "subslice" and CELLMUT_TYPES[tname].get("drop")
    out = ""
    for o in cellmut_ops(tname, aname):
        lines = _cm_trace(tname, o).splitlines(keepends=True)
        if second:
            lines.insert(len(lines) - 1, "drop 1 2\n")
        out += f"{o}\n" + "".join(lines)
    return out + "end\n"


def _cm_trace(tname, oname):
    """What one operation's `run_<op>` prints."""
    t = CELLMUT_TYPES[tname]
    st = dict(c=1, v=[1, 2], s=0)
    lines = []

    def do(k):
        if oname == "set":
            st["c"] += k
        elif oname == "replace":
            st["s"] += st["c"]
            st["c"] = k
        elif oname == "get":
            st["s"] += st["c"]
        elif oname == "push":
            st["v"].append(k)
        elif oname == "pop":
            st["s"] += st["v"].pop() if st["v"] else -1
        elif oname == "clear":
            st["v"] = [k]
        elif oname == "index":
            st["v"][0] += k
        elif oname == "method":
            st["c"] += k
            if t["v"]:
                st["v"].append(k)

    def show():
        f = [st["s"]]
        if t["c"]:
            f.append(st["c"])
        if t["v"]:
            f += [len(st["v"]), st["v"][0] if st["v"] else -1]
        lines.append(" ".join(str(x) for x in f))
    do(1)
    show()
    for i in range(4):
        do(i)
        if i % 2 == 0:
            st["s"] += i
    show()
    for j in range(1, 4):
        do(j)
    show()
    for _ in range(2):
        st["s"] += 100
        do(10)
    show()
    for i in range(3):
        do(i)
    show()
    if t.get("drop"):
        lines.append(f"drop {st['c']} {len(st['v'])}")
    return "\n".join(lines) + "\n"


# -----------------------------------------------------------------------------
# A temporary that holds a Cell, changed or read where it stands: made
# in the statement, a part of one, or a leaf a value that branches may
# take beside a name's (`a if k else mk(5)`, `o ?? mk(5)`, `mkf(6)!`, a
# nested branch, a part of a branch), through a Cell member, a `?self`
# method, a view a method returns, and, where no leaf is a name's, a read
# or write lend. Each lives in its statement's slot, so a change lands in
# the leaf the value takes, and a `drop` sees it when the statement
# ends; a name's leaf changes where it is. Each operation runs in a
# statement, an argument, a loop, and an `if` and a `while` condition,
# with each leaf taken, and the program must print what
# `celltemp_output` computes, in debug and built with `--release`.
# Cells are `celltemp.<type>.<shape>`, one program each.
# -----------------------------------------------------------------------------

_CT_INT = """
  sub hit(?self)
    self.c.set(self.c.get() + 1)

  fun bumped(?self) -> Int
    self.c.set(self.c.get() + 1)
    self.c.get()

  fun me(?self) -> ?T
    self.c.set(self.c.get() + 1)
    self

  fun bumpw(!self) -> Int
    self.c.set(self.c.get() + 1000)
    self.c.get()
"""
_CT_VEC = """
  sub hit(?self)
    self.c.push(1)

  fun me(?self) -> ?T
    self.c.push(1)
    self

  fun bumpw(!self) -> Int
    self.c.push(1000)
    self.c.len
"""


def _ct_int(name, fields="", drop=False):
    d = f"struct {name}\n  c: Cell[Int]\n{fields}"
    if drop:
        d += '\n  drop(!self)\n    print("drop", self.c.get())\n'
    return d + _CT_INT.replace("?T", "?" + name)


# Each type: its spelling, declarations, a constructor of value `m`, the
# path from a value to its Cell and to its methods' receiver (None: a
# bare Cell, which has no methods), whether its Cell holds an Int or a
# Vec, and whether it prints when dropped.
CELLTEMP_TYPES = {
    "drop": dict(ty="D", decls=_ct_int("D", drop=True), ctor="D(c: Cell(M))", cell=".c", recv="", kind="int", drop=True),
    # constant fields: a value Zig knows at compile time
    "plain": dict(ty="N", decls=_ct_int("N", "  pad: [4]Int\n"), ctor="N(c: Cell(M), pad: [4 of 0])", cell=".c", recv="", kind="int"),
    "part": dict(ty="W", decls=_ct_int("In") + "\nstruct W\n  t: In\n", ctor="W(t: In(c: Cell(M)))", cell=".t.c", recv=".t", kind="int"),
    "vec": dict(ty="V", decls='struct V\n  c: Cell[Vec[Int]]\n\n  drop(!self)\n    print("drop", self.c.len * 1000 + (self.c.get(0) ?? -1))\n' + _CT_VEC.replace("?T", "?V"),
                ctor="V(c: Cell(vec1(M)))", cell=".c", recv="", kind="vec", drop=True),
    "cell": dict(ty="Cell[Int]", decls="", ctor="Cell(M)", cell="", recv=None, kind="int"),
    "cellvec": dict(ty="Cell[Vec[Int]]", decls="", ctor="Cell(vec1(M))", cell="", recv=None, kind="vec"),
    "generic": dict(ty="G[Int]", decls="struct G[T]\n  c: Cell[T]\n", ctor="G[Int](c: Cell(M))", cell=".c", recv=None, kind="int"),
}

# Each shape: the value, with `M(n)` a value made here (a constructor or a
# call), the names it uses, which leaf it takes when `k` is true and
# when false (a name, `made` with its value, or `fail`), how a function
# holding it fails (`fail`: `!`, `opt`: `?`), and whether a leaf is a
# name's, which a lend of the whole would copy.
CELLTEMP_SHAPES = {
    "temp": dict(e="mk(5)", uses=[], take=(("made", 5), ("made", 5))),
    "const": dict(e="M(5)", uses=[], take=(("made", 5), ("made", 5))),
    "part": dict(e="WW(t: mk(5)).t", uses=[], take=(("made", 5), ("made", 5))),
    "made_made": dict(e="(mk(5) if k else M(8))", uses=[], take=(("made", 5), ("made", 8))),
    "name_made": dict(e="(a if k else M(5))", uses=["a"], take=(("a",), ("made", 5)), named=True),
    "made_name": dict(e="(mk(5) if k else a)", uses=["a"], take=(("made", 5), ("a",)), named=True),
    "fallback": dict(e="(o ?? M(5))", uses=["o"], take=(("o",), ("made", 5)), named=True),
    "made_fallback": dict(e="(mko(6 if k else -1) ?? a)", uses=["a"], take=(("made", 6), ("a",)), named=True),
    "catch": dict(e="(mkf(-1 if k else 6) catch a)", uses=["a"], take=(("a",), ("made", 6)), named=True),
    "nested": dict(e="(a if k else (mk(5) if k else M(8)))", uses=["a"], take=(("a",), ("made", 8)), named=True),
    "nested_fallback": dict(e="(a if k else (mko(-1) ?? M(5)))", uses=["a"], take=(("a",), ("made", 5)), named=True),
    "part_of_branch": dict(e="(w if k else WW(t: M(5))).t", uses=["w"], take=(("w",), ("made", 5)), named=True),
    "fails": dict(e="(a if k else mkf(6)!)", uses=["a"], take=(("a",), ("made", 6)), named=True, fkind="fail"),
    "absent": dict(e="(mko(6)? if k else a)", uses=["a"], take=(("made", 6), ("a",)), named=True, fkind="opt"),
    "optional": dict(e="(o if k else mko(5))?", uses=["o"], take=(("o",), ("made", 5)), named=True, fkind="opt"),
}

CELLTEMP_POSITIONS = ["stmt", "arg", "loop", "if", "while"]


def celltemp_ops(t):
    """Each operation: (statement form, value form, effect on the state:
    the new state and what the value form gives)."""
    C = lambda x: x + t["cell"]
    R = lambda x: x + (t["recv"] or "")
    # the Cell's path from the methods' receiver
    inner = t["cell"][len(t["recv"] or ""):]
    ops = {}
    if t["kind"] == "int":
        ops["set"] = (lambda x: f"{C(x)}.set(77)", None, lambda s: (77, None))
        ops["replace"] = (None, lambda x: f"{C(x)}.replace(77)", lambda s: (77, s))
        ops["get"] = (None, lambda x: f"{C(x)}.get()", lambda s: (s, s))
        if t["recv"] is not None:
            ops["hit"] = (lambda x: f"{R(x)}.hit()", None, lambda s: (s + 1, None))
            ops["bumped"] = (None, lambda x: f"{R(x)}.bumped()", lambda s: (s + 1, s + 1))
            ops["me"] = (None, lambda x: f"{R(x)}.me(){inner}.get()", lambda s: (s + 1, s + 1))
            ops["bumpw"] = (None, lambda x: f"!{R(x)}.bumpw()", lambda s: (s + 1000, s + 1000))
        ops["look"] = (None, lambda x: f"look(?{x})", lambda s: (s + 10, s + 10))
        ops["poke"] = (None, lambda x: f"poke(!{x})", lambda s: (s + 100, s + 100))
    else:
        ops["push"] = (lambda x: f"{C(x)}.push(5)", None, lambda s: (s + [5], None))
        ops["pop"] = (None, lambda x: f"{C(x)}.pop() ?? -1", lambda s: (s[:-1], s[-1] if s else -1))
        ops["clear"] = (lambda x: f"{C(x)}.clear()", None, lambda s: ([], None))
        ops["index"] = (lambda x: f"{C(x)}[0] = 9", None, lambda s: ([9] + s[1:], None))
        ops["len"] = (None, lambda x: f"{C(x)}.len", lambda s: (s, len(s)))
        ops["geti"] = (None, lambda x: f"{C(x)}.get(0) ?? -1", lambda s: (s, s[0] if s else -1))
        if t["recv"] is not None:
            ops["hit"] = (lambda x: f"{R(x)}.hit()", None, lambda s: (s + [1], None))
            ops["me"] = (None, lambda x: f"{R(x)}.me(){inner}.len", lambda s: (s + [1], len(s) + 1))
            ops["bumpw"] = (None, lambda x: f"!{R(x)}.bumpw()", lambda s: (s + [1000], len(s) + 1))
        ops["look"] = (None, lambda x: f"look(?{x})", lambda s: (s + [10], len(s) + 1))
        ops["poke"] = (None, lambda x: f"poke(!{x})", lambda s: (s + [100], len(s) + 1))
    return ops


def celltemp_applies(sname, oname, pos, op):
    """A lend of the whole value would copy a name's leaf, so a shape
    with one only reaches its leaves. A statement changes the value; an
    argument or a header uses what an operation gives."""
    if CELLTEMP_SHAPES[sname].get("named") and oname in ("look", "poke", "bumpw"):
        return False
    if pos == "stmt":
        return op[0] is not None
    return op[1] is not None or pos == "loop"


def _ct_state(t, m):
    return m if t["kind"] == "int" else [m]


def _ct_show(t, s):
    return s if t["kind"] == "int" else len(s) * 1000 + (s[0] if s else -1)


def _ct_trace(t, sname, pos, op, k):
    """What one `op_*` function prints for leaf choice `k`."""
    sh = CELLTEMP_SHAPES[sname]
    _, val, eff = op
    st = {"a": _ct_state(t, 1), "w": _ct_state(t, 3), "o": _ct_state(t, 2) if k else None}
    out = []

    def drop(s):
        if t.get("drop"):
            out.append(f"drop {_ct_show(t, s)}")

    def once():
        leaf = sh["take"][0 if k else 1]
        if leaf[0] == "made":
            s, v = eff(_ct_state(t, leaf[1]))
            return v, [s]
        s, v = eff(st[leaf[0]])
        st[leaf[0]] = s
        return v, []
    if pos in ("stmt", "loop"):
        for _ in range(2 if pos == "loop" else 1):
            v, temps = once()
            if val is not None:
                out.append(f"v {v}")
            for s in temps:
                drop(s)
    elif pos == "arg":
        v, temps = once()
        out.append(f"v {v}")
        for s in temps:
            drop(s)
    elif pos == "if":
        v, temps = once()
        for s in temps:
            drop(s)
        if v > 0:
            out.append("body")
    elif pos == "while":
        i = 0
        while i < 2:
            v, temps = once()
            for s in temps:
                drop(s)
            if not v > 0:
                break
            i += 1
        out.append(f"w {i}")
    for n in ("a", "w", "o"):
        if n in sh["uses"] and st[n] is not None:
            out.append(f"{n} {_ct_show(t, st[n])}")
    for n in ("o", "w", "a"):
        if n in sh["uses"] and st[n] is not None:
            drop(st[n])
    return out


def celltemp_cells(tname, sname):
    """The (function name, operation, position) a cell runs, in order."""
    t = CELLTEMP_TYPES[tname]
    if sname == "const" and tname in ("cell", "cellvec"):
        return []
    cells = []
    for oname, op in celltemp_ops(t).items():
        for pos in CELLTEMP_POSITIONS:
            if celltemp_applies(sname, oname, pos, op):
                cells.append((f"op_{oname}_{pos}", oname, pos))
    return cells


def celltemp_program(tname, sname):
    """The program for one celltemp cell, or None where nothing applies."""
    cells = celltemp_cells(tname, sname)
    if not cells:
        return None
    t, sh = CELLTEMP_TYPES[tname], CELLTEMP_SHAPES[sname]
    ty, fk = t["ty"], sh.get("fkind", "plain")
    ctor = lambda m: t["ctor"].replace("M", m)
    x = sh["e"].replace("M(5)", ctor("5")).replace("M(8)", ctor("8"))
    ops = celltemp_ops(t)
    C = lambda v: v + t["cell"]
    out = ["error E\n  bad\n"]
    if t["decls"]:
        out.append(t["decls"])
    out.append("fun vec1(n: Int) -> Vec[Int]\n  v: Vec[Int] = Vec()\n  !v.push(n)\n  v\n")
    out.append(f"fun mk(n: Int) -> {ty}\n  {ctor('n')}\n")
    out.append(f"fun mko(n: Int) -> {ty}?\n  return none if n < 0\n  mk(n)\n")
    out.append(f"fun mkf(n: Int) -> {ty}!\n  return E.bad if n < 0\n  mk(n)\n")
    out.append(f"struct WW\n  t: {ty}\n")
    if t["kind"] == "int":
        out.append(f"fun look(x: ?{ty}) -> Int\n  {C('x')}.set({C('x')}.get() + 10)\n  {C('x')}.get()\n")
        out.append(f"fun poke(x: !{ty}) -> Int\n  {C('x')}.set({C('x')}.get() + 100)\n  {C('x')}.get()\n")
        out.append(f"fun show(x: ?{ty}) -> Int\n  {C('x')}.get()\n")
    else:
        out.append(f"fun look(x: ?{ty}) -> Int\n  {C('x')}.push(10)\n  {C('x')}.len\n")
        out.append(f"fun poke(x: !{ty}) -> Int\n  {C('x')}.push(100)\n  {C('x')}.len\n")
        out.append(f"fun show(x: ?{ty}) -> Int\n  {C('x')}.len * 1000 + ({C('x')}.get(0) ?? -1)\n")
    main = []
    for fname, oname, pos in cells:
        stmt, val, _ = ops[oname]
        body = []
        if "a" in sh["uses"]:
            body.append("a = mk(1)")
        if "w" in sh["uses"]:
            body.append(f"w = WW(t: {ctor('3')})")
        if "o" in sh["uses"]:
            body += [f"o: {ty}? = none", "o = mk(2) if k"]
        s = stmt(x) if stmt else f'print("v", {val(x)})'
        if pos == "stmt":
            body.append(s)
        elif pos == "loop":
            body += ["for _ in 0..2", "  " + s]
        elif pos == "arg":
            body.append(f'print("v", {val(x)})')
        elif pos == "if":
            body += [f"if {val(x)} > 0", '  print("body")']
        elif pos == "while":
            body += ["i = 0", f"while i < 2 and {val(x)} > 0", "  i += 1", 'print("w", i)']
        for n, p in (("a", "?a"), ("w", "?w.t"), ("o", None)):
            if n in sh["uses"]:
                body += [f'print("{n}", show({p}))'] if p else ["if o as y", '  print("o", show(?y))']
        if fk == "fail":
            head, call = f"sub {fname}(k: Bool)!", f'{fname}(K) catch print("failed")'
        elif fk == "opt":
            head, call = f"fun {fname}(k: Bool) -> Int?", f'print("q", {fname}(K) ?? -1)'
            body.append("0")
        else:
            head, call = f"sub {fname}(k: Bool)", f"{fname}(K)"
        out.append(head + "\n" + indent(body, 2) + "\n")
        for k in ("true", "false"):
            main += [f'print("== {oname} {pos} {k}")', call.replace("K", k)]
    out.append("sub main()\n" + indent(main, 2))
    return "\n".join(out) + "\n"


def celltemp_output(tname, sname):
    """What a celltemp cell prints."""
    t, sh = CELLTEMP_TYPES[tname], CELLTEMP_SHAPES[sname]
    ops = celltemp_ops(t)
    fk = sh.get("fkind", "plain")
    out = []
    for fname, oname, pos in celltemp_cells(tname, sname):
        for k in (True, False):
            out.append(f"== {oname} {pos} {'true' if k else 'false'}")
            out += _ct_trace(t, sname, pos, ops[oname], k)
            if fk == "opt":
                out.append("q 0")
    return "\n".join(out) + "\n"


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
    out.append("sub main()\n" + indent(main, 2) + "\n")
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
        if fname != "call" or tname in ("int", "string", "plain", "array"):
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
    if fname in VIEW_FORMS and ("decl" in ctx or "tail" in ctx):
        return None
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
    if fname in VIEW_FORMS:
        body.append(VIEW_FORMS[fname])
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
    out.append("sub main()\n" + indent(main, 2) + "\n")
    return "\n".join(out)


# A program that runs away is stopped: after RUN_SECONDS (`--timeout`),
# when it has printed more than RUN_OUTPUT bytes, or when its processes
# (the compiler, Zig, the program) hold more than RUN_MB megabytes
# (`--mem`). Memory is watched, not limited: the sanitizer reserves
# address space far beyond what it uses, so an address-space limit
# (`ulimit -v`, `prlimit --as`) stops every sanitized program.
RUN_SECONDS = 120
RUN_OUTPUT = 1 << 20
RUN_MB = 2048


def tree_rss(pgid):
    """The resident memory of process group `pgid`, in kilobytes."""
    r = subprocess.run(["ps", "-A", "-o", "pgid=,rss="], capture_output=True, text=True)
    total = 0
    for l in r.stdout.splitlines():
        f = l.split()
        if len(f) == 2 and f[0] == str(pgid):
            total += int(f[1])
    return total


def run_capped(cmd, env):
    """Run `cmd` with its output in files, stopping it as RUN_* say."""
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        p = subprocess.Popen(cmd, stdout=out, stderr=err, stdin=subprocess.DEVNULL, env=env, start_new_session=True)
        start = time.monotonic()
        why = None
        while p.poll() is None:
            time.sleep(0.2)
            if time.monotonic() - start > RUN_SECONDS:
                why = "timeout"
            elif os.fstat(out.fileno()).st_size + os.fstat(err.fileno()).st_size > RUN_OUTPUT:
                why = f"printed more than {RUN_OUTPUT} bytes"
            elif tree_rss(p.pid) > RUN_MB << 10:
                why = f"used more than {RUN_MB} MB"
            if why:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    pass
                p.wait()
                break
        if why == "timeout":
            raise subprocess.TimeoutExpired(cmd, RUN_SECONDS)
        if why:
            raise MemoryError("stopped: " + why)
        out.seek(0)
        err.seek(0)
        return subprocess.CompletedProcess(cmd, p.returncode, out.read().decode(errors="replace"), err.read().decode(errors="replace"))


def run_one(path, keep, started_dir, expect=None, release=False):
    """Classify one program: rejected, ok, or a failure with its reason.
    With `expect`, a program that runs must print exactly that; with
    `release`, also when built with `--release`, and it must be
    accepted."""
    d = os.path.dirname(path)
    try:
        chk = subprocess.run([RIG, "check", path], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "fail", "rig check timed out"
    out = chk.stdout + chk.stderr
    if chk.returncode < 0 or chk.returncode > 128 or CRASH.search(out):
        return "fail", "compiler crashed: " + first_line(out)
    if chk.returncode != 0:
        # A `cellmut.` program is one the checker must accept: every
        # operation it applies has a place.
        if release:
            return "fail", "rejected, but must be accepted: " + first_error(out)
        if POS.search(out):
            return "rejected", first_error(out)
        return "fail", "rejected without file:line:col: " + first_line(out)
    why = run_built(path, keep, started_dir, expect, [])
    if why is None and release:
        why = run_built(path, keep, started_dir, expect, ["--release"])
        why = why and "--release: " + why
    return ("fail", why) if why else ("ok", "")


def run_built(path, keep, started_dir, expect, flags):
    """Run one accepted program built with `flags`: None when it runs as
    it must, else why not."""
    outdir = path[:-4] + (".release" if flags else "") + ".out"
    # rig creates `started` once the program has started: the evidence
    # that it ran (test/run's run_program). Each attempt has a fresh path
    # in this run's private directory, which no other run shares.
    started = os.path.join(started_dir, os.path.basename(path)[:-4] + "." + uuid.uuid4().hex)
    env = dict(os.environ, RIG_SANITIZE="1", RIG_OUT_DIR=outdir, RIG_BUILD_STORE=STORE, RIG_RUN_STARTED=started)
    try:
        r = run_capped([RIG, "run"] + flags + [path], env)
    except subprocess.TimeoutExpired:
        return "timed out"
    except MemoryError as e:
        return str(e)
    err = r.stderr
    m = BAD.search(err)
    ran = os.path.isfile(started) and "rig: the program did not run" not in err
    if os.path.lexists(started):
        os.remove(started)
    if not keep:
        shutil.rmtree(outdir, ignore_errors=True)
    if not ran:
        return "the program did not run: " + first_line(err)
    if m:
        line = next((l for l in err.splitlines() if BAD.search(l)), m.group(0))
        return line.strip()
    # rig says when a signal ended the program (its status alone cannot).
    # A Rig panic aborts (signal 6) after its `panic:` report; any other
    # signal came from outside, or is a crash nothing reported.
    sig = re.search(r"rig: the program was killed by signal (\d+)", err)
    if sig and not (sig.group(1) == "6" and "panic: " in err):
        return "killed by signal %s: %s" % (sig.group(1), first_line(err))
    if expect is not None and r.stdout != expect:
        return "printed " + repr(r.stdout) + ", expected " + repr(expect) + (", stderr " + repr(first_line(err)) if err.strip() else "")
    return None


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
    global RIG, RUN_SECONDS, RUN_MB
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-j", type=int, default=4, help="programs at a time (default 4)")
    ap.add_argument("-k", action="append", default=[], help="only ids containing this (repeatable)")
    ap.add_argument("--keep", help="write the programs here and keep them and their builds")
    ap.add_argument("-v", action="store_true", help="list every result")
    ap.add_argument("--oracle", action="store_true", help="run bin/rig-oracle over the programs instead")
    ap.add_argument("--shard", help="I/N: only the cells whose id hashes to I - 1 modulo N (1 <= I <= N)")
    ap.add_argument("--rig", help="the compiler to test (default bin/rig)")
    ap.add_argument("--timeout", type=int, default=RUN_SECONDS, help=f"seconds each program may take to build and run (default {RUN_SECONDS})")
    ap.add_argument("--mem", type=int, default=RUN_MB, help=f"megabytes each program may use (default {RUN_MB})")
    args = ap.parse_args()
    RIG = os.path.abspath(args.rig) if args.rig else RIG
    RUN_SECONDS, RUN_MB = args.timeout, args.mem
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
    for o in STEP_OWNERS:
        for hname in STEP_HOLDERS:
            for shape in STEP_SHAPES:
                for then in ("grow", "read"):
                    ident = f"step.{o}.{hname}.{shape}.{then}"
                    if not wanted(ident):
                        continue
                    path = os.path.join(work, ident.replace(".", "__") + ".rig")
                    with open(path, "w") as fh:
                        fh.write(step_program(o, hname, shape, then))
                    cells.append((ident, path))
                    if then == "read":
                        expects[ident] = step_output(shape)
    for outer in LOOP_OUTERS:
        for inner in LOOP_INNERS:
            for jump in LOOP_JUMPS:
                for end in ("defer", "owned"):
                    ident = f"loop.{outer}.{inner}.{jump}.{end}"
                    if not wanted(ident):
                        continue
                    path = os.path.join(work, ident.replace(".", "__") + ".rig")
                    with open(path, "w") as fh:
                        fh.write(loop_program(outer, inner, jump, end))
                    cells.append((ident, path))
                    expects[ident] = loop_trace(outer, inner, jump, end)
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
    release = set()
    for t in CELLMUT_TYPES:
        for a in CELLMUT_ACCESS:
            ident = f"cellmut.{t}.{a}"
            if not wanted(ident):
                continue
            src = cellmut_program(t, a)
            if src is None:
                skipped += 1
                continue
            path = os.path.join(work, ident.replace(".", "__") + ".rig")
            with open(path, "w") as fh:
                fh.write(src)
            cells.append((ident, path))
            expects[ident] = cellmut_output(t, a)
            release.add(ident)
    for t in CELLTEMP_TYPES:
        for sname in CELLTEMP_SHAPES:
            ident = f"celltemp.{t}.{sname}"
            if not wanted(ident):
                continue
            src = celltemp_program(t, sname)
            if src is None:
                skipped += 1
                continue
            path = os.path.join(work, ident.replace(".", "__") + ".rig")
            with open(path, "w") as fh:
                fh.write(src)
            cells.append((ident, path))
            expects[ident] = celltemp_output(t, sname)
            release.add(ident)
    if args.oracle:
        sys.exit(run_oracle(work, cells, args))
    results = {}
    started_dir = tempfile.mkdtemp(prefix="rig-matrix-started.")
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.j) as pool:
            futs = {pool.submit(run_one, p, bool(args.keep), started_dir, expects.get(i), i in release): i for i, p in cells}
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
