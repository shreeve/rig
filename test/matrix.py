#!/usr/bin/env python3
"""Generate and run the form x context x type matrix of small programs.

Each program puts one expression form (a place, a ternary, `o?`, a
result taken out of several, `d1, d2 = f()`, ...) in one context (a
`print` argument, a binding, an element assignment, one of several
results a call is given or a function returns, ...)
for one type (Int, ?String, String, List, `*T`, `^T`, a struct with a
`drop`, a struct declared `unique`, a vector, and a few cells of a struct holding
a Cell, every one of which must be rejected), plus the
stores into a view parameter (`store.`, below), a call that keeps each
kind of parameter by each store, with `keeps` and without (`keeps.`,
below), a loan reaching a generic body's `T` result each way, its `from`
naming that parameter or not (`gen.`, below), a value `replace`
takes out of each kind of place, then the place written, the value put
back, or what it views dropped while it lives (`taken.`, below), the views of a
read `match` payload, used in the arm or escaping (`payload.`), a
`match` payload field that is itself a view (`viewpay.`), a lend of a
binding that is a write view, then a write through it while the view
is live or after (`lendw.`), a header (`match`, `if … as`, `while … as`,
`for`) whose subject reaches a place holding a write view through a
branch, every one of which must be rejected (`hdr.`), a
`while` step reading what its condition binds (`step.`), an assignment
to a place a view reaches whose value holds a statement of its own
(`target.`), an assignment whose target starts from a value that changes
what its value reads (`order.`), a place built over an index that
writes the place's root, read, lent, or assigned (`rootidx.`), a call
of an owned closure held each
way, given its holder or a value, and returning a view or a value
(`clos.`), a loop over each kind of source that views a List, whose
body defers a write to that List (rejected: the deferred write runs in
the loop, before the next step reads the source again), defers one to
another List, or is followed by a write (`dloop.`), and the
shapes of nested loops and the jumps between them (`loop.`), a `for`
over an iterator, from each kind of source, in each statement, value, and
jump context, run in debug and with `--release` (`iter.`), a Cell
changed through the `*` handle to the value holding it (`cellmut.`),
built in debug and with `--release`, and a value holding a Cell made or
held anywhere but behind `*` (`cellmut.value.`, `celltemp.value.`),
every one of which must be rejected, and a branch of such places copied
by value (`cellbranch.`), likewise, the loans on a struct's fields, a
nested struct's, a read-view field's, `self`'s, and a box's, each beside
a second use of a sibling, the same field, or the whole value, in a
line, a loop, or a closure, past each exit, rejected exactly where the
paths overlap, and run to the output the rule gives (`field.`), and a guard, a write between it and
a use, and the use, whose test the compiler omits only where the guard
still holds (`proof.`, below), and a write and a use in the slots of each
statement form, proven exactly where the unit rule says, and run alike in
debug and with `--release` (`unit.`, below), and a generic `==`, `!=`, or
ordering over every pairing of a view, an optional, an owner, and a List
element, at each instance type, which is rejected with a diagnostic or
runs, in debug and with `--release`, and prints what the values compare
as, and over the same pairings that values `==` calls equal have equal
`.hash()`es (`cmp.`), and a variant literal whose enum comes from
where it goes, in each place a view of that enum goes, lent as the
value `T.V(...)` is, or rejected (`vlit.`). The rule is
the corpus's: `rig check` rejects the program with a file:line:col
diagnostic, or it runs, and runs clean under the sanitizer (no leak, no
use of freed memory, no Zig compile error, no crash). A `payload.`
program that runs must also print what the payload holds, a `lendw.`
program what the view showed and what the write left, and a `loop.`
program the trace of its steps, defers, and drops, as an `iter.` program
the trace of its bodies and drops. A `cellmut.` program
whose type is not `value` must be accepted, and print its trace in debug
and again built with `--release`.

    test/matrix.py                 # generate, check, and run everything
    test/matrix.py -j 8 -k list     # 8 at a time; only ids containing "list"
    test/matrix.py --keep DIR      # write the programs to DIR and keep them
                                   # (one run at a time in DIR)
    test/matrix.py --oracle        # only run the reference ownership checker
                                   # (bin/rig-oracle, test/oracle/) over them
    test/matrix.py --shard 2/4     # only the cells whose id hashes to shard 2 of 4
    test/matrix.py --rig OLD/rig   # test another compiler
    test/matrix.py --timeout 20 --mem 2048   # each program's limits
    test/matrix.py --delta         # check every program, but do not run one
                                   # whose runs passed before (below)
    test/matrix.py --deep          # also each write of the proof. grid with
                                   # its use nested, and every write, use, and
                                   # guard of the unit. grid (the deep gate)

Each program is stopped past its time, past 1 MB of output, or when its
processes hold more than its memory, and every loop a cell writes
counts its passes and stops past a cap, so a loop that never ends fails
the cell.

Nothing it writes is committed: programs go to a temporary directory,
and each run's output is removed after it passes. Programs build in
test/run's store (RIG_BUILD_STORE, test/README.md), so a program built
before, by any worktree, is not built again.

A program whose runs pass is recorded in test/run's results cache
(RIG_RESULTS_CACHE, test/README.md) under a key that hashes everything
the verdict depends on: the code below that runs and judges it, the
compiler's driver (src/main.zig), Zig, the RIG_ settings, the program,
what it must print, whether it is also built with `--release`, and
every file of its sanitized package, with whether Zig links it with
libc. A run is recorded only if none of them changed while it ran, and
the sanitizer guarded every allocation. With `--delta`, a program whose
key is recorded is checked but not run, and counts as ran clean,
carried over. The cache is not used with `--rig`, whose driver it
cannot know; otherwise bin/rig is built first, so that it is the
compiler src/main.zig describes.
"""

import argparse
import concurrent.futures
import fcntl
import hashlib
import inspect
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



def rd(ty):
    """The read view of a type: a read view is its own."""
    return ty if ty.startswith("?") else f"?{ty}"


def fal(ty):
    """The fallible result of a type: a read view takes parentheses first."""
    return f"({ty})!" if ty.startswith("?") else f"{ty}!"


def opt(ty):
    """The optional of a type: a read view or an optional takes
    parentheses first."""
    return f"({ty})?" if ty.startswith("?") or ty.endswith("?") else f"{ty}?"


def optn(ty, n):
    """The optional of a type, n levels deep."""
    for _ in range(n):
        ty = opt(ty)
    return ty


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


def results_cache():
    """test/run's results cache: RIG_RESULTS_CACHE, else rig-results-cache
    in the repository's git directory; None when empty or outside git."""
    if "RIG_RESULTS_CACHE" in os.environ:
        return os.environ["RIG_RESULTS_CACHE"] or None
    if not os.path.exists(os.path.join(ROOT, ".git")):
        return None
    r = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                       cwd=ROOT, capture_output=True, text=True)
    return os.path.join(r.stdout.strip(), "rig-results-cache") if r.returncode == 0 else None


def sha256(*parts):
    h = hashlib.sha256()
    for p in parts:
        p = p if isinstance(p, bytes) else str(p).encode()
        h.update(b"%d:" % len(p) + p)
    return h.hexdigest()


def package_listing(rig, path, tmp):
    """Each file of the package `RIG_SANITIZE=1 rig emit` writes for the
    program at `path` (the package `rig run` builds, but for the line
    naming its start hook, which src/main.zig writes), as `hash path`
    lines, and whether Zig links it with libc; None when emit fails."""
    d = tempfile.mkdtemp(dir=tmp)
    try:
        env = dict(os.environ, RIG_OUT_DIR=d, RIG_SANITIZE="1")
        try:
            p = subprocess.run([rig, "emit", path], env=env, capture_output=True, timeout=60, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return None
        if p.returncode != 0:
            return None
        listing = []
        for dirpath, dirs, files in os.walk(d):
            dirs.sort()
            for name in sorted(files):
                f = os.path.join(dirpath, name)
                listing.append("%s %s" % (hashlib.sha256(open(f, "rb").read()).hexdigest(), os.path.relpath(f, d)))
        if not listing:
            return None
        return "\n".join(listing) + "\nlibc %s" % (b"(-lc)\n" in p.stderr)
    finally:
        shutil.rmtree(d, ignore_errors=True)


# The RIG_ variables that name where things go; every other one is a
# setting of the run (test/run's RIG_LOCATIONS).
RIG_LOCATIONS = re.compile(r"RIG_(RESULTS_CACHE|BUILD_STORE|BUILD_STORE_DAYS|TEST_OUT|OUT_DIR|RUN_STARTED|PROGRAM_STARTED)$")


def fixed_inputs():
    """What a run fixes when it starts and a recorded run must have used:
    src/main.zig, and bin/rig (by its device, inode, size, and time,
    since a `zig build` replaces it)."""
    st = os.stat(RIG)
    return sha256(open(os.path.join(ROOT, "src", "main.zig"), "rb").read(), st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)


class Results:
    """The results cache: one empty file per recorded key, in a directory
    named by the key's first two digits; a hit touches it, so test/run's
    prune keeps what runs still use."""

    def __init__(self, path, delta, tmp):
        self.path, self.delta, self.tmp = path, delta, tmp
        zig = os.environ.get("ZIG", "zig")
        zenv = subprocess.run([zig, "env"], capture_output=True, text=True)
        if zenv.returncode != 0:
            raise OSError("`zig env` failed")
        # The code that runs a program and judges it, the limits it runs
        # under, and every RIG_ setting (a runtime knob, such as
        # RIG_SANITIZE_BLOCKS, or one a program reads).
        verdict = [inspect.getsource(f) for f in VERDICT_CODE] + [r.pattern for r in (BAD, POS, CRASH)]
        settings = sorted("%s=%s" % kv for kv in os.environ.items() if kv[0].startswith("RIG_") and not RIG_LOCATIONS.match(kv[0]))
        self.fixed = fixed_inputs()
        self.base = sha256("rig results 2 matrix", *verdict, RUN_SECONDS, RUN_OUTPUT, RUN_MB, CAP_MODE,
                           open(os.path.join(ROOT, "src", "main.zig"), "rb").read(), zig, zenv.stdout, *settings)

    def key(self, path, expect, release):
        listing = package_listing(RIG, path, self.tmp)
        if listing is None:
            return None
        return sha256(self.base, open(path, "rb").read(), repr(expect), release, listing)

    def file(self, key):
        return os.path.join(self.path, key[:2], key)

    def carried(self, key):
        """A --delta run, and the key is recorded."""
        if not self.delta or not os.path.isfile(self.file(key)):
            return False
        try:
            os.utime(self.file(key))
        except OSError:
            pass
        return True

    def record(self, key, path, expect, release):
        """Record `key`, if nothing it hashes changed while the program ran:
        the program, its package, src/main.zig, and bin/rig."""
        try:
            if fixed_inputs() != self.fixed or self.key(path, expect, release) != key:
                return
        except OSError:
            return
        try:
            os.makedirs(os.path.dirname(self.file(key)), exist_ok=True)
            open(self.file(key), "w").close()
        except OSError:
            pass


RESULTS = None

# What a sound program never does when it runs (test/run's CORPUS_BAD_RE).
BAD = re.compile(
    r"rig: a proven check failed|rig: memory leak detected|rig: use of freed memory|rig: access past the end|rig: double free"
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

N_DECL = "obj N\n  v: Int\n\n  fun peek(?self, k: Int) -> Int\n    self.v + k\n\n  fun me(?self) -> ?N\n    self\n"
TYPES = {
    "int": dict(ty="Int", decls="", mk="n", ctor="Int(5)"),
    "string": dict(ty="?String", decls="", mk='"s" if n > 0 else "t"', ctor='"lit"'),
    "static": dict(ty="Static", decls="", mk='"s" if n > 0 else "t"', ctor='"lit"'),
    "text": dict(ty="String", decls="", mk='String("t", n)', ctor='String("lit")'),
    "list": dict(ty="List[Int]", decls="",
                mk="xs: List[Int] = List()\n  !xs.push(n)\n  xs", ctor="List[Int]()"),
    "shared": dict(ty="*N", decls=N_DECL, mk="*N(v: n)", ctor="*N(v: 5)"),
    "box": dict(ty="^N", decls=N_DECL, mk="^N(v: n)", ctor="^N(v: 5)"),
    "drop": dict(ty="D", decls='obj D\n  v: Int\n\n  drop(!self)\n    print("drop", self.v)\n\n  fun take(<self) -> Int\n    self.v\n\n  sub bump(!self)\n    self.v += 1\n\n  fun peek(?self, k: Int) -> Int\n    self.v + k\n\n  fun me(?self) -> ?D\n    self\n',
                 mk="D(v: n)", ctor="D(v: 5)"),
    # A struct that holds a Cell, which lives only behind `*`: a value
    # of it is rejected wherever it stands, so it keeps only the cells
    # in `rejected` (a context and a form), each of which must be
    # rejected.
    "cell": dict(ty="Counter", decls="obj Counter\n  hits: Cell[Int]\n",
                 mk="Counter(hits: Cell(n))", ctor="Counter(hits: Cell(5))",
                 rejected=(("binding", "ctor"), ("print", "call"), ("lend_arg", "place"),
                           ("destructure", "call"), ("binding", "destructure"))),
    # A struct declared `unique`.
    "unique": dict(ty="U", decls="obj U unique\n  v: Int\n", mk="U(v: n)", ctor="U(v: 5)"),
    # Values that copy (`sema.copies`): a plain struct and an array,
    # which a view's value is copied out as a number's is.
    "plain": dict(ty="P", decls="obj P\n  v: Int\n", mk="P(v: n)", ctor="P(v: 5)"),
    "array": dict(ty="A2", decls="type A2 = [2]Int\n", mk="[n, n + 1]", ctor="[5, 6]"),
    # A vector: plain data, one value like an Int (Core §1), whose `==`
    # gives a mask.
    "simd": dict(ty="Simd[U8, 4]", decls="", mk="Simd[U8, 4].splat(U8(n))", ctor="Simd[U8, 4]([1, 2, 3, 4])"),
    # A payload enum: `== .variant` tests the variant.
    "enum": dict(ty="S", decls="enum S\n  dot\n  line(v: List[Int])\n",
                 mk="xs: List[Int] = List()\n  !xs.push(n)\n  .line(v: <xs)", ctor="S.dot",
                 only=("eq_variant", "eq_none", "binding", "tail_if", "tail_match", "destructure")),
    # `error`, an error of any set: owning in every program, though no
    # set here holds anything to drop (Core §2, "A failure moves its
    # error"). `error!` is rejected, so it has no `fail`, and no form or
    # tail catches one.
    "error": dict(ty="error", decls="error X\n  one\n  two\n", mk="X.one if n > 0 else X.two", ctor="X.one",
                  fallible=False),
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
    # A result taken out of several (`d1, d2 = f()`): an owned one, a
    # branch of the two, one that reads `a` (`-> (?T, ?T)`), and a write
    # view of `a` beside a result that holds none (`-> (!T, Bool)`).
    "destructure": "d1",
    "destructure_branch": "d1 if c else d2",
    "destructure_view": "d1",
    "destructure_write": "d1",
}
# The binding each view or destructure form reads, declared before the
# context.
VIEW_FORMS = {
    "read_view": "r = ?a", "write_view": "w = !a",
    "destructure": "d1, _ = pass2(mk(5), mk(6))",
    "destructure_branch": "d1, d2 = pass2(mk(5), mk(6))",
    "destructure_view": "d1, _ = views2(?a)",
    "destructure_write": "d1, _ = wv(!a)",
}

# The functions that give several results, for a type `T`: each passes
# its owned arguments through, or views its one argument, as the forms
# and contexts that call it take them.
RESULT_FUNS = {
    "pass2": "fun pass2(x: {t}, y: {t}) -> ({t}, {t})\n  return x, y\n",
    "pass2f": "fun pass2f(x: {t}, y: {t}, c: Bool) -> ({t}, {t})!\n  return E.bad if c\n  return x, y\n",
    "some2": "fun some2(x: {t}, y: {t}, c: Bool) -> ({t}, {t})?\n  return none if c\n  return x, y\n",
    "views2": "fun views2(x: {r}) -> ({r}, {r})\n  return x, x\n",
    "wv": "fun wv(x: !{t}) -> (!{t}, Bool)\n  return x, true\n",
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
    "list_push": dict(inline="!vs.push(E)", needs="vs", after="print(vs.len)"),
    "return": dict(block="return E", returns=True),
    "elem_assign": dict(block="vs[0] = E", needs="vs", after="print(vs.len)"),
    "elem_assign_call": dict(inline="vs[0] = through(!vs, E)", needs="vs", after="print(vs.len)"),
    "elem_index_call": dict(block="vs[grow(!vs)] = E", needs="vs", after="print(vs.len)"),
    "match_subject": dict(inline="match E\n    y => print(look(?y))"),
    "for_source": dict(inline="for e in ?E\n    print(e)"),
    # A loop over an array made in its header, which it takes.
    "for_literal": dict(inline="for e in [E, mk(6)]\n    print(look(?e))"),
    # A loop over a branch whose arms are arrays: each element is a copy.
    "for_branch": dict(inline="for e in ([E, mk(6)] if c else [mk(7), mk(8)])\n    print(look(?e))"),
    # A match on a part of a made value.
    "match_part": dict(inline="match H(f: E).f\n    y\n      print(look(?y))"),
    # A header whose subject makes a temporary (`?String(...)`): it takes
    # the value a call makes there, so it binds that value.
    "match_subject_temp": dict(inline='match pass_t(E, ?String("t"))\n    y => print(look(?y))', temp=True),
    "as_temp": dict(inline='if some_t(E, ?String("t")) as y\n    print(look(?y))', temp=True),
    # A method that consumes its receiver (`<self`, `^T.unbox`).
    "recv_consume": dict(inline="print((E).M)", recv={"drop": "take()", "box": "unbox().v"}),
    # A method that writes its receiver: a value made there, or one
    # lent with `!` (a place without one is rejected).
    "recv_write": dict(inline="(E).M", recv={"list": "push(1)", "text": 'add("x")', "drop": "bump()"}),
    # `!` lends any value to write (Core sentence 4): the receiver of a
    # write method, an argument where a `!T` goes, and a write view held
    # past the statement, which a temporary's must not be.
    "recv_write_lent": dict(inline="!(E).M", recv={"list": "push(1)", "text": 'add("x")', "drop": "bump()"}),
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
                                 recv={t: "get(poke(!W))" if t == "list" else "peek(poke(!W))"
                                       for t in ("list", "shared", "box", "drop")}),
    # A view a method returns of its receiver, kept while the receiver's
    # place is lent to write: the view keeps every place the receiver may
    # be lent, and one of a value made there ends with its statement.
    "recv_view_then_write": dict(inline="r = (E).M\n  _ = poke(!W)\n  print(r.v)", write=True,
                                 recv={t: "me()" for t in ("shared", "box", "drop")}),
    "eq_then_write": dict(inline="print((E) == pokev(!W))", write=True, types=("int", "string", "static", "text")),
    "index_then_write": dict(inline="print((E)[poke(!W)])", write=True, types=("list",)),
    # A `?self` method returning a view of its receiver (`me`): the view
    # held past the statement, used after a later operand writes what the
    # form reads, or held while a later statement writes it.
    "recv_view": dict(inline="x = (E).M", after="print(x.v)", recv={"drop": "me()", "shared": "me()"}),
    "recv_view_arg_then_write": dict(inline="print((E).M.v, poke(!W))", write=True,
                                     recv={"drop": "me()", "shared": "me()"}),
    "recv_view_held_then_write": dict(inline="x = (E).M", after="print(poke(!W), x.v)", write=True,
                                      recv={"drop": "me()", "shared": "me()"}),
    # A slice of the value, written with no lend, as an argument where a
    # `[]T` or a ?String goes: it is lent the way its name is, as
    # `?(E)[..1]`, also while a later argument writes what it slices.
    "slice_arg": dict(inline="print(sliced(E[..1]))", slice=True, types=("list", "array", "text", "string", "static")),
    "slice_arg_then_write": dict(inline="print(both(E[..1], poke(!W)))", slice=True, write=True,
                                 types=("list", "array", "text", "string", "static")),
    # The value as one of several results (RESULT_FUNS): passed through
    # and bound by name, each name declared, `_` (which drops it at the
    # statement's end), or assigned over a value it drops; bound by
    # `if … as`, past a failure (which drops what the call was given), or
    # past `none`; and given by `return E, other` to a caller that binds
    # both.
    "destructure": dict(inline="x, y = pass2(E, mk(6))", after="print(look(?x), look(?y))"),
    "destructure_discard": dict(inline="_, y = pass2(E, mk(6))", after="print(look(?y))"),
    "destructure_assign": dict(inline="x = mk(7)\n  print(look(?x))\n  x, y = pass2(E, mk(6))",
                               after="print(look(?x), look(?y))"),
    "destructure_as": dict(inline="if some2(E, mk(6), not c) as x, y\n    print(look(?x), look(?y))"),
    "destructure_catch": dict(inline="x, y = pass2f(E, mk(6), not c) catch return 0",
                              after="print(look(?x), look(?y))"),
    "destructure_none": dict(inline="x, y = some2(E, mk(6), not c) ?? return 0",
                             after="print(look(?x), look(?y))"),
    "destructure_return": dict(inline="return E, mk(6)", returns=True, results=True),
}

# How `poke` changes a value of each type: it grows the buffer, or
# replaces the value, freeing what the old one owned.
POKES = {
    "int": "x += 1", "string": 'x = "u"', "static": 'x = "u"',
    "text": 'for _ in 0..100\n    !x.add("abcdefgh")', "list": "for i in 0..100\n    !x.push(i)",
    "shared": "x = *N(v: 9)", "box": "x = ^N(v: 9)", "drop": "x = D(v: 9)",
    "unique": "x = U(v: 9)", "enum": "x = S.dot",
    "plain": "x = P(v: 9)", "array": "x[0] += 1", "simd": "x = x +% 1",
    "error": "x = X.two",
}
WRITE_TARGETS = {"field": "h.f", "nullish": "b", "catch": "b", "destructure": "d1", "destructure_branch": "d1"}

# A block-local binding at the tail of a value block leaves it before the
# block's defers run. Each shape of value block goes to each sink, with a
# `defer` that uses the binding (writes a List or String, reads the rest) or
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
TAIL_WRITES = {"list": "!t.push(1)", "text": '!t.add("x")'}
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
    "list": dict(ty="List[Int]", view="[]Int", lend="?b[..]", init="x = [9, 9]",
                make="v: List[Int] = List()\n  !v.push(1)", grow=["for i in 0..100", "  !b.push(i)"]),
    "text": dict(ty="String", view="?String", lend="?b[0..1]", init='x = String("zz")',
                 make='v = String("abc")', grow=["for _ in 0..100", '  !b.add("abcdefgh")']),
}
# What `a` is: its type, how `main` makes it from the view `I`, and the
# statements that read the stored view back.
STORE_HOLDERS = {
    "h": dict(ty="H", make="h = H(r: I)", read=["print(a.r[0])"]),
    "o": dict(ty="O", make="h = O(h: H(r: I))", read=["print(a.h.r[0])"]),
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
    "element": ("s", ["a[0].r = S"]),
    "loop_element": ("s", ["for k in !a", "  k.r = S"]),
    "loop_assign": ("s", ["for k in !a", "  k = H(r: S)"]),
    "match_payload": ("e", ["match !a", "  .one(h) => h.r = S", "  .zero => print(0)"]),
    "as_binding": ("opt", ["if !a as h", "  h.r = S"]),
}


# -----------------------------------------------------------------------------
# A generic body tracks no loan in a value of a type parameter's type, but
# in an instance one may hold a view: `g` makes its `T` result from its
# parameter `p` each way (a callable's result, an element of a `[]T`, an
# optional's value through `??` or `as`, a closure's result, the result
# of a function a field holds, a `match` payload of a viewed `Opt[T]`),
# and its `from` names `p` (and `d`, where
# the body may return it) or only `d`.
# Unnamed, the body is rejected; named, the result keeps `p`'s argument
# lent, so `main` may read it, and may not drop what it views first.
# Cells are `gen.<form>.<said>.<then>`.
# -----------------------------------------------------------------------------

# Each form: `g`'s parameters before `d`, what `from` names when it names
# `p`, the body, `main`'s setup and arguments before `d`'s, and the type
# argument `T` stands for (`?String`, or `K`, which holds one).
GEN_FORMS = {
    "call": dict(params="f: ?fun(?String) -> T, p: ?String", said="f, p", body=["f(p)"], setup=[],
                 args="|s: ?String| s, ?t"),
    "element": dict(params="p: []T", said="p", body=["p[0]"], setup=["a = [?t]"], args="?a[..]"),
    "nullish": dict(params="p: T?", said="p, d", body=["p ?? d"], setup=["o: (?String)? = ?t"], args="o"),
    "as": dict(params="p: T?", said="p, d", body=["if <p as v", "  return v", "d"], setup=["o: (?String)? = ?t"],
               args="o"),
    "closure": dict(params="f: ?fun(?String) -> T, p: ?String", said="f, p", body=["h = |?f, ?p| f(p)", "h()"],
                    setup=[], args="|s: ?String| s, ?t"),
    "field": dict(field=True, params="p: ?String", said="p", body=["self.f(p)"], setup=[], args="?t"),
    "match": dict(params="p: ?Opt[T]", said="p, d", body=["match p", "  .some(v) => v", "  .nothing => d"],
                  setup=["o = Opt[?String].some(?t)"], args="?o"),
}


def gen_program(fname, said, then):
    """The program for one `gen.` cell, and what it prints."""
    f = GEN_FORMS[fname]
    origin = f["said"] if said else "d"
    out = ["obj K\n  s: ?String\n", "enum Opt[T]\n  some(value: T)\n  nothing\n"]
    if f.get("field"):
        out.append("obj H[T]\n  f: *fun(?String) -> T\n\n"
                   f"  fun g(?self, {f['params']}, d: ?String) -> T from {origin}\n{indent(f['body'], 4)}\n")
        call = "r = h.g(?t, ?u)"
        setup = ["h = H[K](f: *|s| K(s: s))"]
        show = "print(r.s)"
    else:
        out.append(f"fun g[T]({f['params']}, d: T) -> T from {origin}\n{indent(f['body'], 2)}\n")
        call = f"r = g({f['args']}, ?u)"
        setup = f["setup"]
        show = "print(r)"
    main = ['t = String("abc")', 'u = String("u")'] + setup + [call]
    main += (["<t"] if then == "drop" else []) + [show]
    out.append("sub main()\n" + indent(main, 2) + "\n")
    expect = "abc\n" if said and then == "read" else "(rejected)\n"
    return "\n".join(out), expect


# -----------------------------------------------------------------------------
# A value `replace` takes out of a place: `t = replace(!P, v)` is
# `t = <P; P = v` (docs/INTERNALS.md), so `t` views what the place's value
# viewed (`src`) and no part of the place. The place, of each kind, is
# then written while `t` lives (accepted), `t` put back into it (accepted),
# or `src` dropped while `t` lives (rejected). Its type holds a view and
# owns a String, which the view could view by type. Cells are
# `taken.<place>.<then>`.
# -----------------------------------------------------------------------------

# How `main` makes the place `P` from `src`; `run` puts it in a function
# given the holder as a write view; `take` replaces the `replace`, and
# `thens` a then's lines and output (None: not written).
TAKEN_PLACES = {
    "local": dict(setup=["s = S(text: ?src, value: String())"], place="s"),
    "field": dict(setup=["h = H(s: S(text: ?src, value: String()))"], place="h.s"),
    "nested": dict(setup=["g = G(h: H(s: S(text: ?src, value: String())))"], place="g.h.s"),
    "write_local": dict(setup=["h = H(s: S(text: ?src, value: String()))", "w = !h.s"], place="w"),
    "element": dict(setup=["v: List[S] = List()", "!v.push(S(text: ?src, value: String()))"], place="v[0]"),
    "boxed": dict(setup=["b = ^H(s: S(text: ?src, value: String()))"], place="b.s"),
    "param": dict(setup=["h = H(s: S(text: ?src, value: String()))"], place="p.s", run=True),
    # A closure that captures `h` to write takes the value: it views
    # `src`, never `h`, so the closure writes `h` again while it lives.
    # Its result carries the closure's captures (Core sentence 7), so `h`
    # itself is not written or put back into while it lives.
    "closure": dict(setup=['h = H(s: S(text: ?src, value: String("v")))',
                           'f = |!h| replace(!h.s, S(text: "", value: String("n")))'],
                    place="h.s", take=["t = f()"],
                    thens={"write": (["u = f()", "print(t.text, t.value, u.value)"], "abc v n\n"), "put_back": None}),
}
TAKEN_THENS = {
    "write": (['P.value = String("w")', "print(t.text, P.value)"], "abc w\n"),
    "put_back": (["_ = replace(!P, <t)", "print(P.text)"], "abc\n"),
    "drop": (["<src", "print(t.text)"], "(rejected)\n"),
}


# -----------------------------------------------------------------------------
# A `while` step that reads what its condition binds: a view of `v` (a
# List's `[]Int`, a String's `?String`), a struct holding one read through a
# field or a method, while the body grows `v` (or only reads it) on its
# way to the step: falling off its end, `continue`, `continue @outer`
# from a nested `for`, `while`, or `while … as` (also where the loop is
# written as nested `if`s, for a joined condition or a `catch break`
# in it), an inner loop, a `defer`, or a `break` (where the step does
# not run). The step runs after the body, so it must not read what the
# body grew, and a `read` cell must print the count of the steps it ran.
# Cells are `step.<owner>.<holder>.<shape>.<then>`.
# -----------------------------------------------------------------------------

STEP_OWNERS = {
    "list": dict(ty="List[Int]", view="[]Int", lend="?v[..]", make="v: List[Int] = List()\n  !v.push(1)",
                grow="!v.push(i)", read="X[0]"),
    "text": dict(ty="String", view="?String", lend="?v[0..1]", make='v = String("abc")',
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
    "labeled": ["@outer while C: S", "  n += 1", "  for _ in 0..1", "    G", "    continue @outer"],
    "labeled_joined": ["@outer while J: S", "  n += 1", "  for _ in 0..1", "    G", "    continue @outer"],
    "labeled_catchbreak": ["@outer while B: S", "  n += 1", "  for _ in 0..1", "    G", "    continue @outer"],
    "labeled_while": ["@outer while C: S", "  n += 1", "  j = 0", "  while j < 2: j += 1", "    G", "    continue @outer"],
    "labeled_while_joined": ["@outer while J: S", "  n += 1", "  j = 0", "  while j < 2: j += 1", "    G", "    continue @outer"],
    "labeled_while_catchbreak": ["@outer while B: S", "  n += 1", "  j = 0", "  while j < 2: j += 1", "    G", "    continue @outer"],
    "labeled_whileas_joined": ["@outer while J: S", "  n += 1", "  while mk(?v, 0) as _", "    G", "    continue @outer"],
    "labeled_whileas_catchbreak": ["@outer while B: S", "  n += 1", "  while mk(?v, 0) as _", "    G", "    continue @outer"],
    "inner": ["while C: S", "  n += 1", "  j = 0", "  while j < 1: j += 1", "    G"],
    "defer": ["while C: S", "  n += 1", "  defer G"],
    "joined": ["while J: S", "  n += 1", "  G"],
    "failure": ["while F: S", "  n += 1", "  G"],
    "break": ["while C: S", "  n += 1", "  if n > 1", "    G", "    break"],
}


# -----------------------------------------------------------------------------
# An assignment to a place a view reaches (`w[0] = X`, `w[0] += X`,
# `w.n = X`, `u[w[0]] = X`, and `w = X` and `w += X` through a write
# view) whose value holds a statement of its own (a `match` arm, a block
# arm, the last arm, an `if` block, an `else` block, a `catch` block, an
# `if` block in a last arm), or none (a ternary, the plain value). An
# assignment is `{ __v = value; place op= __v }` (docs/INTERNALS.md), so
# every scope in the value ends before the store goes through the view:
# there the value may not grow, read, move, or drop what the view views,
# nor point the view at a local of its own scope; it may lend another
# value, or point the view at another one, and the store then lands
# there. `in_block` puts the assignment last in a block whose local the
# view was pointed at, which is valid. Each valid cell must be accepted
# and print what was stored, in debug and with `--release`.
# Cells are `target.<target>.<nest>.<act>`.
# -----------------------------------------------------------------------------

TARGET_PLACES = {
    "elem": dict(make=["v: List[Int] = List()", "!v.push(7)", "w = !v[0..1]"], store="w[0] = X", show="v[0]",
                 repoint="w = !R[0..1]", elem="Int", seen="R[0]", base=7, add=False),
    "compound": dict(make=["v: List[Int] = List()", "!v.push(7)", "w = !v[0..1]"], store="w[0] += X", show="v[0]",
                     repoint="w = !R[0..1]", elem="Int", seen="R[0]", base=7, add=True),
    "field": dict(make=["v: List[S] = List()", "!v.push(S(n: 7))", "w = !v[0]"], store="w.n = X", show="v[0].n",
                  repoint="w = !R[0]", elem="S", seen="R[0].n", base=7, add=False),
    "index": dict(make=["v: List[Int] = List()", "!v.push(0)", "u: List[Int] = List()", "!u.push(5)", "!u.push(6)", "w = ?v[0..1]"],
                  store="u[w[0]] = X", show="u[0]", repoint="w = ?R[0..1]", elem="Int", seen="u[1]", base=5, add=False),
    "name": dict(make=["v: List[Int] = List()", "!v.push(7)", "w = !v[0]"], store="w = X", show="v[0]",
                 repoint="w = !R[0]", elem="Int", seen="R[0]", base=7, add=False),
    "name_compound": dict(make=["v: List[Int] = List()", "!v.push(7)", "w = !v[0]"], store="w += X", show="v[0]",
                          repoint="w = !R[0]", elem="Int", seen="R[0]", base=7, add=True),
}
TARGET_NESTS = {
    "arm": ["match k", "  0 => A", "  _ => 3"],
    "block_arm": ["match k", "  0", "    A", "  _ => 3"],
    "last_arm": ["match k", "  1 => 3", "  _", "    A"],
    "if_block": ["if k == 0", "  A", "else", "  3"],
    "else_block": ["if k != 0", "  3", "else", "  A"],
    "catch_block": ["fail(-1) catch |_|", "  A"],
    "nested_last": ["match k", "  1 => 3", "  _", "    if k != 0", "      4", "    else", "      A"],
    "ternary": ["A if k == 0 else 3"],
    "plain": ["A"],
    "in_block": None,
}
# Each act is the lines of the value, its last line the value itself;
# `R` is the List a re-pointing act points the view at. Valid acts give
# the stored value (`stores`) and whether the view ends at x (`at_x`).
TARGET_ACTS = {
    "grow": dict(lines=["grow(!v)"]),
    "read": dict(lines=["v.len"]),
    "move": dict(lines=["sink(<v)"]),
    "drop": dict(lines=["<v", "3"]),
    "other": dict(lines=["grow(!x)"], stores=201),
    "local": dict(lines=["y: List[Int] = List()", "!y.push(1)", "grow(!y)"], stores=201),
    "repoint_local": dict(lines=["MAKE_y", "REPOINT_y", "3"]),
    "repoint_outer": dict(lines=["REPOINT_x", "3"], stores=3, at_x=True),
    "repoint_grow": dict(lines=["REPOINT_x", "grow(!v)"], stores=201, at_x=True),
}


def target_program(tname, nname, aname):
    """The program for one target cell, or None where the act's lines
    cannot stand in the nest (a statement in a one-line value), or
    `in_block` with any act but the plain value."""
    t = TARGET_PLACES[tname]
    a = TARGET_ACTS[aname]
    pushed = "S(n: 1)" if t["elem"] == "S" else ("0" if tname == "index" else "1")

    def act_line(line):
        if line.startswith("MAKE_"):
            r = line[5:]
            return [f"{r}: List[{t['elem']}] = List()", f"!{r}.push({pushed})"]
        if line.startswith("REPOINT_"):
            return [t["repoint"].replace("R", line[8:])]
        if tname == "field" and line in ("grow(!v)", "grow(!x)"):
            return [line.replace("grow", "grows")]
        return [line]

    lines = [l for line in a["lines"] for l in act_line(line)]
    store = t["store"].split("X")[0]
    x_make = [f"x: List[{t['elem']}] = List()", f"!x.push({'S(n: 1)' if t['elem'] == 'S' else '1'})"]
    if nname == "in_block":
        if aname != "repoint_local":
            return None
        inner = [f"y: List[{t['elem']}] = List()", f"!y.push({pushed})", t["repoint"].replace("R", "y"), store + "3"]
        body = list(t["make"]) + ["k = 0", "if k == 0"] + ["  " + l for l in inner] + [f"print({t['show']})"]
    else:
        nest = TARGET_NESTS[nname]
        if len(lines) > 1 and nname in ("arm", "ternary", "plain"):
            return None
        out_nest = []
        for l in nest:
            if "A" in l.split() or l.strip().startswith("A"):
                pad = l[:len(l) - len(l.lstrip())]
                if len(lines) == 1:
                    out_nest.append(l.replace("A", lines[0], 1))
                else:
                    out_nest += [pad + x for x in lines]
            else:
                out_nest.append(l)
        uses_k = any("k" in l.split() for l in out_nest)
        show = t["show"] + (", " + t["seen"].replace("R", "x") if a.get("at_x") else "")
        body = list(t["make"]) + x_make + (["k = 0"] if uses_k else []) + [store + out_nest[0]] + out_nest[1:] + [f"print({show})"]
    out = ["error E\n  bad\n", "obj S\n  n: Int\n",
           "fun grow(v: !List[Int]) -> Int\n  for _ in 0..200\n    !v.push(1)\n  v.len\n",
           "fun grows(v: !List[S]) -> Int\n  for _ in 0..200\n    !v.push(S(n: 1))\n  v.len\n",
           "fun sink(v: List[S]) -> Int\n  v.len\n" if t["elem"] == "S" else "fun sink(v: List[Int]) -> Int\n  v.len\n",
           "fun fail(n: Int) -> Int!\n  return E.bad if n < 0\n  n\n",
           "sub main()\n" + indent(body, 2) + "\n"]
    return "\n".join(out)


def target_output(tname, nname, aname):
    """What a valid cell prints, or None for a cell that may be rejected:
    the value stored where the view points after the value (added to
    what is there, for `op=`), and beside it what the view first viewed."""
    t = TARGET_PLACES[tname]
    a = TARGET_ACTS[aname]
    if nname == "in_block":
        # The store lands in y; u[y[0]] is u[0] for `index`.
        return ("3\n" if tname == "index" else f"{t['base']}\n") if aname == "repoint_local" else None
    if "stores" not in a:
        return None
    if aname == "local" and nname in ("arm", "ternary", "plain"):
        return None
    if a.get("at_x"):
        # x holds 1 (index: u[1] holds 6, replaced).
        stored = a["stores"] + (1 if t["add"] else 0)
        return f"{t['base']} {stored}\n"
    stored = a["stores"] + (t["base"] if t["add"] else 0)
    return f"{stored}\n"


def step_program(oname, hname, shape, then):
    """The program for one step cell."""
    o = STEP_OWNERS[oname]
    h = STEP_HOLDERS[hname]
    v = o["view"]
    hty = h["ty"].replace("V", v)
    out = ["use std.text\n" if oname == "text" else "", "error E\n  bad\n",
           f"obj H\n  r: {v}\n\n  fun get(?self) -> {v}\n    self.r\n",
           f"sub grow(v: !{o['ty']})\n  for {'i' if 'i' in o['grow'] else '_'} in 0..100\n    {o['grow']}\n",
           f"fun mk(v: {rd(o['ty'])}, n: Int) -> {hty}?\n  if n < 3\n    return {h['make'].replace('L', o['lend'])}\n  none\n",
           f"fun mkf(v: {rd(o['ty'])}, n: Int) -> {hty}?!\n  return E.bad if n == 7\n  mk(v, n)\n"]
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
# Loop shapes: an outer loop labeled `@outer` holding an inner construct
# that jumps once, in the outer loop's second pass, with a `defer` or an
# owned local at the outer body's end. Every program prints a trace of
# its passes, steps, defers, and drops, which must be the one
# `loop_trace` computes from the meaning of the jumps (SPEC, "while" and
# "Labels, break, and continue"): a step runs after the body's defers and
# drops on every path but `break`, and a jump in a loop's `else` targets
# the loop around it. Cells are `loop.<outer>.<inner>.<jump>.<end>`.
# -----------------------------------------------------------------------------

LOOP_OUTERS = {
    "while": "@outer while i < 3: i = st(i)",
    "while_as": "@outer while lim(i, 3) as h: i = st(h)",
    "joined": "@outer while lim(i, 3) as h and h >= 0: i = st(h)",
    "catch_break": "@outer while (limf(i, 3) catch break) as h: i = st(h)",
    "for": "@outer for q in 0..3",
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
    "continue_outer": "continue @outer",
    "break_outer": "break @outer",
    "else_continue": None,
}


# -----------------------------------------------------------------------------
# A `for` over an iterator (`next(!self) -> Int?`, yielding 0, 1, 2),
# which is `while (!it).next() as k` (SPEC, "for"), from each kind of
# source and in each context: a statement that runs out, breaks, skips,
# returns, fails, or has an `else`; a loop used as a value or as a
# function's last line; one a `continue @outer` leaves from an outer
# loop; a labeled one. An iterator a name or field holds is advanced in
# place and dropped at the end of its scope; one made there, or taken
# with `<`, is held for the loop and dropped where it ends, by any jump.
# Every cell must be accepted, built in debug and with `--release`, and
# print the trace `iter_output` computes, except `moved` in a loop that
# runs twice (the second pass uses what the first took). Cells are
# `iter.<source>.<context>`.
# -----------------------------------------------------------------------------

ITER_SOURCES = {
    "place": dict(setup=["it = mk(1)"], head="for k in !it", rest="(!it).next() ?? -1", held=False),
    "field": dict(setup=["h = Hold(it: mk(1))"], head="for k in !h.it", rest="(!h.it).next() ?? -1", held=False),
    "made": dict(setup=[], head="for k in mk(1)", rest=None, held=True),
    "moved": dict(setup=["it = mk(1)"], head="for k in <it", rest=None, held=True),
}
ITER_CONTEXTS = ("end", "break", "continue", "return", "fail", "else", "value_end", "value_break",
                 "tail_end", "tail_break", "nested", "labeled")


# -----------------------------------------------------------------------------
# A loop whose source views `b.xs`, from each kind of source (a `while`
# whose condition reads a slice, `while … as` over an iterator, and a
# `for` over a made, lent, named, or taken iterator, a List, or a
# slice), with a body that defers a write to `b.xs` (which runs inside
# the loop, before the source is read again: rejected), defers a write
# to another List, or is followed by a write to `b.xs` after the loop.
# Cells are `dloop.<source>.<write>`.
# -----------------------------------------------------------------------------

DLOOP_SOURCES = {
    "while_cond": (["s = ?b.xs[0..2]", "i = 0"], "while s[i] > 0 : i += 1", ["x = s[i]"]),
    "while_as": (["c = smk(?b.xs)"], "while (!c).next() as x", []),
    "made": ([], "for x in smk(?b.xs)", []),
    "lent": ([], "for x in ?b.each()", []),
    "place": (["c = smk(?b.xs)"], "for x in !c", []),
    "moved": (["c = smk(?b.xs)"], "for x in <c", []),
    "list": ([], "for x in ?b.xs", []),
    "slice": ([], "for x in ?b.xs[0..2]", []),
}
DLOOP_WRITES = {
    "defer": (["defer grow(!b.xs)"], [], None),
    "defer_other": (["defer grow(!w)"], [], "1\n2\n2 200\n"),
    "after": ([], ["grow(!b.xs)"], "1\n2\n102 0\n"),
}


def dloop_program(source, write):
    """The program for one `dloop.` cell, and what it prints (None where
    it must be rejected)."""
    setup, head, first = DLOOP_SOURCES[source]
    body, after, out = DLOOP_WRITES[write]
    lines = ["obj SCur", "  xs: []Int", "  i: Int", "",
             "  fun next(!self) -> Int?", "    return none if self.i >= self.xs.len", "    self.i += 1",
             "    self.xs[self.i - 1]", "",
             "obj SB", "  xs: List[Int]", "",
             "  fun each(?self) -> SCur from self", "    SCur(xs: ?self.xs[0..self.xs.len], i: 0)", "",
             "fun smk(v: ?List[Int]) -> SCur from v", "  SCur(xs: ?v[0..v.len], i: 0)", "",
             "sub grow(v: !List[Int])", "  for _ in 0..100", "    !v.push(1)", "",
             "sub main()", "  b = SB(xs: List())", "  !b.xs.push(1)", "  !b.xs.push(2)", "  w: List[Int] = List()"]
    lines += ["  " + l for l in setup] + ["  " + head]
    lines += ["    " + l for l in first + body + ["print(x)", "break if x == 2"]]
    lines += ["  " + l for l in after] + ["  print(b.xs.len, w.len)"]
    return "\n".join(lines) + "\n", out


def dloop_cells():
    """The `dloop.` cells: (id, program, expected output or None to be rejected)."""
    return [(f"dloop.{src}.{w}",) + dloop_program(src, w) for src in DLOOP_SOURCES for w in DLOOP_WRITES]


# A variant literal whose enum comes from where it goes (`.V`, `.V(...)`)
# in each place a view of its enum goes. Where the view is held by
# address (any but a plain enum's read view), the literal is the value
# `T.V(...)` is: lent to a view argument as a temporary its statement
# drops, and rejected where the view is kept, lent to write, or is a view
# of an optional. A plain enum's read view holds a copy, so takes the
# literal anywhere a read view goes.
# Cells are `vlit.<literal>.<place>`.
VLIT_LITERALS = {
    # name: (type, literal, what `show` prints of it, plain)
    "bare": ("S", ".dot", "dot", False),
    "scalar": ("S", ".pt(x: 4)", "pt 4", False),
    "owner": ("S", ".line(v: three())", "line 3", False),
    "nested": ("W", ".wrap(s: .line(v: three()))", "wrap line 3", False),
    "generic": ("G[List[Int]]", ".some(value: three())", "some 3", False),
    "plain": ("C", ".red", "red", True),
}
VLIT_PLACES = {
    # name: (declarations, statements in main, accepted for a view held
    # by address, accepted for a plain enum's, what it prints past `show`)
    "arg": ("", ["show(@L)"], True, True, ""),
    "opt_arg": ("sub maybe(v: (?T)?)\n  if v as x\n    show(x)\n  else\n    print(\"none\")\n",
                ["maybe(@L)", "maybe(none)"], True, True, "none\n"),
    "generic_arg": ("sub same[U](a: ?U, b: ?U)\n  print(\"same\")\n", ["x: @T = @L", "same(?x, @L)"], True, True, "same\n"),
    "method_arg": ("obj H\n  n: Int\n\nsub H.look(?self, v: ?T)\n  show(v)\n",
                   ["h = H(n: 0)", "h.look(@L)"], True, True, ""),
    "kwarg": ("sub show2(v: ?T, k: Int)\n  show(v)\n  print(k)\n", ["show2(k: one(), v: @L)"], True, True, "1\n"),
    "nested_call": ("fun count(v: ?T) -> Int\n  show(v)\n  1\n", ["print(count(@L) + count(@L))"], True, True, "2\n"),
    "fail_arg": ("error E\n  oops\n\nfun bad() -> Int!\n  return E.oops\n\nsub both(v: ?T, k: Int)\n  show(v)\n\n"
                 "fun tryit() -> Int!\n  both(@L, bad()!)\n  return 1\n", ["print(tryit() catch -1)"], True, True, "-1\n"),
    "loop": ("", ["for _ in 0..2\n    show(@L)"], True, True, None),
    "write_arg": ("sub poke(v: !T)\n  print(\"poke\")\n", ["poke(@L)"], False, False, ""),
    "view_of_opt": ("sub vo(v: ?T?)\n  print(\"vo\")\n", ["vo(@L)"], False, False, ""),
    "binding": ("", ["x: ?@T = @L", "show(x)"], False, True, ""),
    "field": ("obj R\n  v: ?T\n", ["r = R(v: @L)", "show(r.v)"], False, True, ""),
    "elem": ("", ["xs: [1]?@T = [@L]", "show(xs[0])"], False, True, ""),
    "return": ("fun made() -> ?T\n  return @L\n", ["show(made())"], False, True, ""),
    "kept": ("fun keep(v: ?T) -> ?T\n  return v\n", ["x = keep(@L)", "show(x)"], False, True, ""),
    "default": ("sub dflt(v: ?T = @L)\n  show(v)\n", ["dflt()"], False, True, ""),
    # A fallback that is a value copies out what `o` views, which only a
    # value that copies may; a plain enum's fallback must be lent too.
    "coalesce": ("", ["o: (?@T)? = none", "show(o ?? @L)"], False, False, ""),
}
VLIT_DECLS = """enum S
  dot
  pt(x: Int)
  line(v: List[Int])

enum W
  wrap(s: S)
  none_of

enum G[T]
  some(value: T)
  nothing

enum C
  red
  green

fun three() -> List[Int]
  xs = List[Int]()
  for i in 0..3
    !xs.push(i)
  return <xs

fun one() -> Int
  1

sub show_s(v: ?S)
  match v
    .dot => print("dot")
    .pt(x) => print("pt", x)
    .line(items) => print("line", items.len)

"""
VLIT_SHOW = {
    "S": "sub show(v: ?S)\n  show_s(v)\n",
    "W": "sub show_wrap(s: ?S)\n  print(\"wrap\")\n  show_s(s)\n\nsub show(v: ?W)\n  match v\n    .wrap(s) => show_wrap(s)\n    .none_of => print(\"none_of\")\n",
    "G[List[Int]]": "sub show(v: ?G[List[Int]])\n  match v\n    .some(value) => print(\"some\", value.len)\n    .nothing => print(\"nothing\")\n",
    "C": "sub show(v: ?C)\n  print(\"red\" if v == .red else \"green\")\n",
}


def vlit_program(lname, pname):
    """The program for one `vlit.` cell, and what it prints (None where
    it must be rejected); no program where the place takes no such
    literal (a default is a bare variant)."""
    ty, lit, shown, plain = VLIT_LITERALS[lname]
    decls, stmts, held, by_copy, more = VLIT_PLACES[pname]
    if pname == "default" and "(" in lit:
        return None, None
    src = VLIT_DECLS + VLIT_SHOW[ty] + "\n"
    if decls:
        src += decls.replace("?T", "?" + ty).replace("!T", "!" + ty).replace("@L", lit) + "\n"
    src += "sub main()\n" + "".join("  " + s.replace("@L", lit).replace("@T", ty) + "\n" for s in stmts)
    if not (by_copy if plain else held):
        return src, None
    # `wrap`'s line prints on two lines.
    line = shown.replace("wrap ", "wrap\n") + "\n"
    if pname == "generic_arg" or pname == "fail_arg":
        return src, more
    if pname == "loop":
        return src, line * 2
    if pname == "nested_call":
        return src, line * 2 + more
    return src, line + more


def vlit_cells():
    """The `vlit.` cells: (id, program, expected output or None to be rejected)."""
    out = []
    for lname in VLIT_LITERALS:
        for pname in VLIT_PLACES:
            src, expect = vlit_program(lname, pname)
            if src is not None:
                out.append((f"vlit.{lname}.{pname}", src, expect))
    return out


# A generic `==`, `!=`, or ordering over two operands, each a view, an
# optional, an owner, or a List element, with `K` any instance type.
EQ_TYPES = {
    "int": dict(ty="Int", decl="", mk=["n"], copy=True, eq=True, ord=True),
    "float": dict(ty="Float", decl="", mk=["return 1.5 if n == 1", "2.5"], copy=True, eq=True, ord=True),
    "string": dict(ty="String", decl="", mk=['return String("a") if n == 1', 'String("b")'], copy=False, eq=True, ord=True),
    "view": dict(ty="?String", decl="", mk=['return "a" if n == 1', '"b"'], copy=True, eq=True, ord=True),
    "obj": dict(ty="P", decl="obj P\n  n: Int\n  s: String\n\n", mk=['P(n: n, s: String("x"))'], copy=False, eq=True, ord=False),
    "enum": dict(ty="E", decl="enum E\n  a(x: Int)\n  z\n\n", mk=["E.a(x: n)"], copy=True, eq=True, ord=False),
    # A plain enum orders by its variants' values, not their order.
    "plain": dict(ty="Q", decl="enum Q\n  hi = 9\n  lo = 4\n\n", mk=["return Q.lo if n == 1", "Q.hi"], copy=True, eq=True, ord=True),
    "list": dict(ty="List[Int]", decl="", mk=["l: List[Int] = List()", "!l.push(n)", "l"], copy=False, eq=False, ord=False),
    "box": dict(ty="^P", decl="obj P\n  n: Int\n  s: String\n\n", mk=['^P(n: n, s: String("x"))'], copy=False, eq=False, ord=False),
    "shared": dict(ty="*P", decl="obj P\n  n: Int\n  s: String\n\n", mk=['*P(n: n, s: String("x"))'], copy=False, eq=False, ord=False),
}
# form -> (parameter type with K, whether it may be none, the operand in the body)
EQ_FORMS = {
    "view": ("?K", False, "{v}"),
    "wview": ("!K", False, "{v}"),
    "own": ("K", False, "{v}"),
    "opt": ("K?", True, "{v}"),
    "vopt": ("?K?", True, "{v}"),
    "optv": ("(?K)?", True, "{v}"),
    "nopt": ("(K?)?", True, "{v}"),
    "nnopt": ("((K?)?)?", True, "{v}"),
    "elem": ("?List[K]", False, "{v}[0]"),
    "elemopt": ("?List[K?]", True, "{v}[0]"),
}
EQ_RIGHT = ("view", "wview", "own", "opt", "vopt", "optv", "nopt", "nnopt")
# the optional levels of a form's parameter type
EQ_DEPTH = {"opt": 1, "vopt": 1, "optv": 1, "elemopt": 1, "nopt": 2, "nnopt": 3}
EQ_ORDER_FORMS = ("view", "own", "opt", "vopt", "optv")


def eq_operand(form, spec, n, i):
    """The setup lines and the argument for one operand holding value `n`
    (0 is none) in the form."""
    ty, copy = spec["ty"], spec["copy"]
    a, x = f"a{i}", f"x{i}"
    take = x if copy else f"<{x}"
    if form in ("nopt", "nnopt"):
        # n is (s, core): s `some` layers around a core that is none (s < depth) or the value
        d, (s, core) = EQ_DEPTH[form], n
        if s == d:
            return [f"{x}: {optn(ty, d)} = mk({core})"], take
        lines, prev = [f"v{i}_0: {optn(ty, d - s)} = none"], f"v{i}_0"
        for j in range(1, s + 1):
            lines.append(f"v{i}_{j}: {optn(ty, d - s + j)} = " + (prev if copy else f"<{prev}"))
            prev = f"v{i}_{j}"
        return lines, prev if copy else f"<{prev}"
    if form in ("view", "wview", "own"):
        arg = {"view": f"?{a}", "wview": f"!{a}", "own": a if copy else f"<{a}"}[form]
        return [f"{a} = mk({n})"], arg
    if form in ("opt", "vopt"):
        arg = take if form == "opt" else f"?{x}"
        return [f"{x}: {opt(ty)} = " + ("none" if n == 0 else f"mk({n})")], arg
    if form == "optv":
        if n == 0:
            return [f"{x}: {opt(rd(ty))} = none"], x
        return [f"{a} = mk({n})", f"{x}: {opt(rd(ty))} = ?{a}"], x
    if form == "elem":
        return [f"{x}: List[{ty}] = List()", f"!{x}.push(mk({n}))"], f"?{x}"
    return [f"{x}: List[{opt(ty)}] = List()", f"!{x}.push(" + ("none" if n == 0 else f"mk({n})") + ")"], f"?{x}"


def eq_expect(op, left, right):
    if left is None or right is None:
        return left is None and right is None if op == "eq" else not (left is None and right is None)
    return {"eq": left == right, "ne": left != right, "lt": left < right, "ge": left >= right}[op]


def eq_program(tname, lform, rform, group):
    """The program, and what it prints (None where it must be rejected)."""
    spec = EQ_TYPES[tname]
    ops = {"eq": ("eq", "ne"), "ord": ("lt", "ge"), "hash": ("hs",)}[group]
    symbol = {"eq": "==", "ne": "!=", "lt": "<", "ge": ">="}
    lty, lmay, lbody = EQ_FORMS[lform]
    rty, rmay, rbody = EQ_FORMS[rform]
    lines = [spec["decl"].rstrip("\n")] if spec["decl"] else []
    if lines:
        lines.append("")
    lines += [f"fun mk(n: Int) -> {spec['ty']}"] + ["  " + l for l in spec["mk"]] + [""]
    for op in ops:
        l, r = lbody.format(v='a'), rbody.format(v='b')
        # Values `==` calls equal hash equal.
        test = f"not ({l} == {r}) or {l}.hash() == {r}.hash()" if op == "hs" else f"{l} {symbol[op]} {r}"
        lines += [f"fun {op}[K](a: {lty}, b: {rty}) -> Bool", f"  {test}", ""]
    run, out = [], []
    def cases(form, may):
        d = EQ_DEPTH.get(form, 0)
        if not may or group == "ord":
            return [(0, 1), (0, 2)]
        return [(s, None) for s in range(d)] + [(d, 1), (d, 2)]

    def arg(form, v):
        """The value in the form's operand: an int (0 is none), or (s, core) for the nested forms."""
        s, core = v
        if form in ("nopt", "nnopt"):
            return v
        return core if core is not None else 0

    def same(lv, rv):
        """Whether two values are equal: the shallower side is lifted by `some` to the deeper one's depth."""
        ld, rd_ = EQ_DEPTH.get(lform, 0), EQ_DEPTH.get(rform, 0)
        top = max(ld, rd_)
        return lv[0] + top - ld == rv[0] + top - rd_ and lv[1] == rv[1]

    run, out = [], []
    i = 0
    for lv in cases(lform, lmay):
        for rv in cases(rform, rmay):
            shown = []
            for op in ops:
                ls, la = eq_operand(lform, spec, arg(lform, lv), i)
                rs, ra = eq_operand(rform, spec, arg(rform, rv), i + 1)
                i += 2
                run += ls + rs
                shown.append(f"{op}[{spec['ty']}]({la}, {ra})")
            run.append("print(" + ", ".join(shown) + ")")
            if group == "hash":
                out.append("true")
            elif group == "eq":
                e = same(lv, rv)
                out.append(" ".join("true" if (e if op == "eq" else not e) else "false" for op in ops))
            else:
                vals = [None if v[1] is None else v[1] for v in (lv, rv)]
                out.append(" ".join("true" if eq_expect(op, *vals) else "false" for op in ops))
    lines += ["sub main()"] + ["  " + l for l in run]
    ok = {"eq": spec["eq"], "ord": spec["ord"], "hash": spec["eq"] and tname != "float"}[group]
    return "\n".join(lines) + "\n", ("\n".join(out) + "\n") if ok else None


def eq_cells():
    """The `cmp.` cells: (id, program, expected output or None to be rejected)."""
    cells = []
    for tname, spec in EQ_TYPES.items():
        for group in ("eq", "ord", "hash"):
            ordered = group == "ord"
            for lform in (EQ_ORDER_FORMS + ("elem", "elemopt") if ordered else EQ_FORMS):
                for rform in EQ_RIGHT:
                    if ordered and not spec["ord"] and lform != rform:
                        continue
                    if ordered and rform not in EQ_ORDER_FORMS:
                        continue
                    src, out = eq_program(tname, lform, rform, group)
                    cells.append((f"cmp.{tname}.{group}.{lform}.{rform}", src, out))
    return cells


def iter_program(source, ctx):
    """The program for one iterator cell."""
    src = ITER_SOURCES[source]
    head = src["head"]
    run = list(src["setup"])
    rest = [f'print("rest", {src["rest"]})'] if src["rest"] and ctx in ("end", "break", "continue", "else") else []
    loop = {
        "end": [head, '  print("body", k)'],
        "break": [head, '  print("body", k)', "  break if k == 1"],
        "continue": [head, '  print("body", k)', "  continue if k == 1", '  print("tail", k)'],
        "return": [head, '  print("body", k)', "  return if k == 1"],
        "fail": [head, '  print("body", k)', "  chk(k)!"],
        "else": [head, '  print("body", k)', "else", '  print("else")'],
        "labeled": ["@l " + head, '  print("body", k)', "  break @l if k == 1"],
        "nested": ["@outer for _ in 0..2", "  " + head, '    print("body", k)', "    continue @outer if k == 1",
                   '  print("inner done")'],
    }
    if ctx in ("value_end", "value_break"):
        stop = "7" if ctx == "value_end" else "1"
        run += ["r = " + head, '  print("body", k)', f"  break k * 10 if k == {stop}", "else", "  -1",
                'print("value", r)']
    elif ctx in ("tail_end", "tail_break"):
        run = ['print("tail", tailv())']
    else:
        run += loop[ctx] + ['print("after")'] + rest
    lines = ["obj It", "  id: Int", "  at: Int", "",
             "  fun next(!self) -> Int?", "    return none if self.at >= 3", "    self.at += 1", "    self.at - 1", "",
             "  drop(!self)", '    print("drop", self.id)', "",
             "obj Hold", "  it: It", "",
             "error E", "  bad", "",
             "fun mk(id: Int) -> It", "  It(id: id, at: 0)", "",
             "sub chk(k: Int)!", "  return E.bad if k == 1", ""]
    if ctx in ("tail_end", "tail_break"):
        stop = "7" if ctx == "tail_end" else "1"
        lines += ["fun tailv() -> Int"] + ["  " + l for l in src["setup"]] + \
                 ["  " + head, '    print("body", k)', f"    break k * 10 if k == {stop}", "  else", "    -1", ""]
    lines += ["sub run()!"] + ["  " + l for l in run] + ["",
              "sub main()", '  run() catch |_| print("failed")', '  print("end")']
    return "\n".join(lines) + "\n"


def iter_output(source, ctx):
    """What an iterator cell prints, or None where it must be rejected."""
    held = ITER_SOURCES[source]["held"]
    has_rest = ITER_SOURCES[source]["rest"] is not None
    drop = ["drop 1"]
    persistent_drop = [] if held else drop
    held_drop = drop if held else []
    if source == "moved" and ctx == "nested":
        return None
    b = lambda *ks: [f"body {k}" for k in ks]
    if ctx == "end":
        out = b(0, 1, 2) + held_drop + ["after"] + (["rest -1"] if has_rest else []) + persistent_drop
    elif ctx == "break":
        out = b(0, 1) + held_drop + ["after"] + (["rest 2"] if has_rest else []) + persistent_drop
    elif ctx == "continue":
        out = ["body 0", "tail 0", "body 1", "body 2", "tail 2"] + held_drop + ["after"] + (["rest -1"] if has_rest else []) + persistent_drop
    elif ctx == "return":
        out = b(0, 1) + drop
    elif ctx == "fail":
        out = b(0, 1) + drop + ["failed"]
    elif ctx == "else":
        out = b(0, 1, 2) + ["else"] + held_drop + ["after"] + (["rest -1"] if has_rest else []) + persistent_drop
    elif ctx == "labeled":
        out = b(0, 1) + held_drop + ["after"] + persistent_drop
    elif ctx == "nested":
        if held:
            out = b(0, 1) + drop + b(0, 1) + drop + ["after"]
        else:
            out = b(0, 1, 2) + ["inner done", "after"] + drop
    elif ctx == "value_end":
        out = b(0, 1, 2) + held_drop + ["value -1"] + persistent_drop
    elif ctx == "value_break":
        out = b(0, 1) + held_drop + ["value 10"] + persistent_drop
    elif ctx == "tail_end":
        out = b(0, 1, 2) + drop + ["tail -1"]
    else:
        out = b(0, 1) + drop + ["tail 10"]
    return "\n".join(out + ["end"]) + "\n"


# -----------------------------------------------------------------------------
# Constants Zig must not fold: a part of a constant (an element of a
# constant array, a field of a value built of literals, a payload, a
# byte of text) is a run-time value. Each cell reads one part, with
# one operator that fails on it, in one way; the program either is
# rejected by `rig check` with a diagnostic (where Rig folds a constant
# scalar itself) or panics when it runs, before it prints. A Zig compile
# error, or a value printed, fails the cell. Cells are
# `fold.<constant>.<access>.<op>`, accepted and run in debug and with
# `--release` unless the constant is a scalar.
# -----------------------------------------------------------------------------

FOLD_MAX = "9223372036854775807"
FOLD_VALUES = [FOLD_MAX, "(-9223372036854775807 - 1)", "0", "(-1)"]
FOLD_BYTES = ["255", "0", "0", "255"]
FOLD_FIELDS = "abcd"
# op: (the role of the value it fails on, the expression over X, the
# types it applies to)
FOLD_OPS = {
    "add": (0, "X + 1", "iu"), "sub": (1, "X - 1", "iu"), "mul": (0, "X * 2", "iu"),
    "neg": (1, "-X", "i"), "shl": (0, "X << 1", "iu"), "conv": (0, "U8(X)", "i"),
    "div0": (2, "1 / X", "iu"), "mod0": (2, "1 % X", "iu"), "divm1": (1, "X / (-1)", "i"),
}
FOLD_FEW = ("add", "conv", "div0")
FOLD_DECLS = ("obj P\n  a: Int\n  b: Int\n  c: Int\n  d: Int\n\n"
              "obj D\n  a: Int = 9223372036854775807\n  b: Int = -9223372036854775808\n  c: Int = 0\n  d: Int = -1\n\n"
              "enum E\n  v(a: Int, b: Int, c: Int, d: Int)\n\n")
FOLD_ARRAY = "[" + ", ".join(FOLD_VALUES) + "]"
# constant -> (the declaration, how a part is read ({r} the index of the
# role, {f} its field name), the element type: `i` Int, `u` U8, the
# accesses that apply)
FOLD_CONSTS = {
    "array": dict(top=f"K = {FOLD_ARRAY}", read="K[{r}]", ty="i",
                  access=("direct", "bound", "runtime", "arg", "generic", "subject", "arm", "for", "slice")),
    "nested": dict(top=f"K = [{FOLD_ARRAY}, {FOLD_ARRAY}]", read="K[1][{r}]", ty="i",
                   access=("direct", "bound", "runtime", "arg", "generic", "subject", "arm", "row")),
    "text": dict(top='K = "\\xff\\x00\\x00\\xff"', read="K[{r}]", ty="u",
                 access=("direct", "bound", "runtime", "arg", "generic", "subject", "arm", "for", "guard")),
    "literal": dict(top="", read=f"{FOLD_ARRAY}[{{r}}]", ty="i", access=("direct", "bound", "runtime", "arg", "generic", "subject", "arm")),
    "ctor": dict(top="", read="P(a: " + FOLD_VALUES[0] + ", b: " + FOLD_VALUES[1] + ", c: 0, d: (-1)).{f}", ty="i",
                 access=("direct", "bound", "arg", "generic", "subject", "arm")),
    "default": dict(top="", read="D().{f}", ty="i", access=("direct", "bound", "arg", "generic", "subject", "arm")),
    "local": dict(top="", pre=f"K = {FOLD_ARRAY}", read="K[{r}]", ty="i",
                  access=("direct", "bound", "runtime", "arg", "generic", "subject", "arm", "for")),
    "variant": dict(top="", ty="i", access=("direct", "bound")),
    "optional": dict(top=None, ty="i", access=("as", "coalesce", "arm", "propagate")),
    "optarray": dict(top="O: [4]Int? = [" + ", ".join(FOLD_VALUES) + "]", ty="i", access=("as", "coalesce", "propagate")),
    "fallible": dict(top=None, ty="i", access=("propagate", "coalesce")),
    "scalar": dict(top=None, ty="i", access=("direct", "bound", "arm"), rejected=True),
}


def fold_cells():
    """(id, constant, access, op) of every cell."""
    cells = []
    for c, spec in FOLD_CONSTS.items():
        for a in spec["access"]:
            for op, (_, _, kinds) in FOLD_OPS.items():
                if spec["ty"] not in kinds or (spec["ty"] == "u" and op in ("conv", "neg", "divm1")):
                    continue
                if a not in ("direct", "bound") and op not in FOLD_FEW + ("sub",):
                    continue
                if a == "generic" and op == "conv":
                    continue
                cells.append((f"fold.{c}.{a}.{op}", c, a, op))
    return cells


def fold_pattern(role):
    """A `.v` pattern that binds only the field of `role`."""
    return ".v(" + ", ".join("abcd"[i] if i == role else "_" for i in range(4)) + ")"


def fold_program(c, a, op):
    """The program for one constant cell, and whether it must be accepted."""
    spec = FOLD_CONSTS[c]
    role, tmpl, _ = FOLD_OPS[op]
    ty = "U8" if spec["ty"] == "u" else "Int"
    if c == "text":
        role = {"add": 0, "sub": 1, "mul": 0, "shl": 0, "div0": 1, "mod0": 1}[op]
    value = (FOLD_BYTES if spec["ty"] == "u" else FOLD_VALUES)[role]
    top, pre = [FOLD_DECLS], []
    main = []
    use = lambda x: tmpl.replace("X", x)
    if spec["top"]:
        top.append(spec["top"] + "\n")
    if c == "optional":
        top.append(f"O: Int? = {value}\n")
    if c == "fallible":
        top.append(f"fun mk() -> Int!\n  {value}\n")
    if c == "scalar":
        top.append(f"K = {value}\n")
    if spec.get("pre"):
        main.append(spec["pre"])
    read = spec.get("read", "").format(r=role, f=FOLD_FIELDS[role]) if "read" in spec else None
    if c == "scalar":
        read = "K"
    if c == "optional":
        read = "(O ?? 0)"
    if c == "optarray":
        read = f"(O[{role}] ?? 0)"
    if c == "fallible":
        read = "(mk() catch 0)"
    helpers = []
    if a == "direct":
        if c == "variant":
            main += ["match E.v(a: " + FOLD_VALUES[0] + ", b: " + FOLD_VALUES[1] + ", c: 0, d: (-1))",
                     f"  {fold_pattern(role)} => print({use('abcd'[role])})"]
        else:
            main.append(f"print({use(read)})")
    elif a == "bound":
        if c == "variant":
            main += ["e = E.v(a: " + FOLD_VALUES[0] + ", b: " + FOLD_VALUES[1] + ", c: 0, d: (-1))",
                     "match e", f"  {fold_pattern(role)} => print({use('abcd'[role])})"]
        else:
            main += [f"m = {read}", f"print({use('m')})"]
    elif a == "runtime":
        main += ["i = 0", f"i += {role}", f"print({use(spec['read'].format(r='i', f=''))})"]
    elif a == "arg":
        helpers.append(f"sub f(x: {ty})\n  print({use('x')})\n")
        main.append(f"f({read})")
    elif a == "generic":
        helpers.append(f"sub g[T](x: T)\n  print({use('x')})\n")
        main.append(f"g({read})")
    elif a == "subject":
        main += [f"match {read}", f"  {7 if c != 'text' else 7} => print(0)", f"  n => print({use('n')})"]
    elif a == "arm":
        main += ["match true", f"  true => print({use(read)})", "  _ => print(0)"]
    elif a == "for":
        src = "K"
        main += [f"for x in {src}", f"  if x == {value}", f"    print({use('x')})"]
    elif a == "slice":
        main += ["s = ?K[0..4]", f"print({use(f's[{role}]')})"]
    elif a == "row":
        main += ["row = K[1]", f"print({use(f'row[{role}]')})"]
    elif a == "guard":
        main += ["if K.len > 0", f"  print({use(read)})"]
    elif a == "as":
        main += [f"if {'O' if c == 'optional' else f'O[{role}]'} as x", f"  print({use('x')})"]
    elif a == "coalesce":
        main.append(f"print({use(read)})")
    elif a == "propagate":
        # `?` or `!` of a constant binds a run-time value.
        src_ = {"optional": "O", "optarray": f"O[{role}]", "fallible": "mk()"}[c]
        mark = "!" if c == "fallible" else "?"
        helpers.append(f"fun p() -> Int{mark}\n" + f"  v = {src_}{mark}\n  print({use('v')})\n  v\n")
        main.append("print(p() " + ("catch 0)" if c == "fallible" else "?? 0)"))
    src = "\n".join(top) + "\n" + "\n".join(helpers) + "\nsub main()\n" + "\n".join("  " + l for l in main) + "\n"
    return src, not FOLD_CONSTS[c].get("rejected", False)


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
    head = ["obj D", "  n: Int", "", "  drop(!self)", '    print("drop", self.n)', "",
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
    "owner": dict(ty="Res", mk='Res(n: 1, t: String("hello"))', mk2='Res(n: 10, t: String("k"))',
                  show="print(v.n, v.t)", out="1 hello"),
    "text": dict(ty="String", mk='String("tx")', mk2='String("other")', show="print(v)", out="tx"),
    "list": dict(ty="List[Int]", mk="xs: List[Int] = List()\n  !xs.push(8)\n  xs",
                mk2="xs: List[Int] = List()\n  !xs.push(80)\n  !xs.push(81)\n  xs",
                show="print(v[0], v.len)", out="8 1"),
    "box": dict(ty="^N", mk="^N(v: 6)", mk2="^N(v: 60)", show="print(v.v)", out="6"),
    "shared": dict(ty="*N", mk="*N(v: 7)", mk2="*N(v: 70)", show="print(v.v)", out="7"),
}
# How the match reaches the enum: a `?E` parameter matched bare or lent
# again, a `?^E` parameter, a field of a `?H` parameter, or, in a
# generic function, a `?G[T]` parameter, the view a call returns of one,
# a lend of that view, a branching value, or a field of a view a call
# returns. `main` makes `e` from `mk()` and passes `?e`.
PAYLOAD_SUBJECTS = {
    "param": dict(param="e: ?E", subj="e"),
    "lend": dict(param="e: ?E", subj="?e"),
    "box": dict(param="e: ?^E", subj="e", make="e = ^E.a(r: mk())"),
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
    out = ["obj N\n  v: Int\n", "obj P\n  x: Int\n  y: Int\n", "obj Res\n  n: Int\n  t: String\n",
           f"enum E\n  a(r: {ty})\n  b(r: {ty})\n", "obj H\n  e: E\n", "enum G[T]\n  a(r: T)\n  b(r: T)\n",
           "obj GH[T]\n  e: G[T]\n", "fun getg[T](e: ?G[T]) -> ?G[T] from e\n  e\n",
           "fun getgh[T](h: ?GH[T]) -> ?GH[T] from h\n  h\n", "fun yes() -> Bool\n  true\n",
           f"fun mk() -> {ty}\n  {t['mk']}\n", f"fun mk2() -> {ty}\n  {t['mk2']}\n",
           f"fun ok(v: {rd(ty)}) -> Bool\n  true\n",
           "fun clobber(n: Int) -> Int\n  a = [n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7]\n"
           "  b = [n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7]\n  a[1] + b[2]\n"]
    show = [t["show"]]
    if x.get("whole"):
        # A view of the whole value is shown through its payload.
        show = ["match v", "  .a(p) => show(?p)", "  .b(p) => show(?p)"]
        out.append(f"sub show(v: {rd(ty)})\n  {t['show']}\n")
    main = [s.get("make", "e = E.a(r: mk())").replace("TY", ty)]
    if "arm" in x:
        if s.get("generic"):
            return None, None
        out.append(f"sub see(v: {rd(ty)})\n  print(clobber(1000))\n  {t['show']}\n")
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
        out.append(f"fun {fun}({s['param']}, k: {rd(res)}) -> {rd(res)}\n" + indent(body, 2) + "\n")
        whole_k = f"k: G[{ty}] = .b(r: mk2())" if s.get("generic") else "k = E.b(r: mk2())"
        main += [whole_k if x.get("whole") else "k = mk2()", "v = inner(?e, ?k)"]
    main.append("print(clobber(1000))")
    main += show
    out.append("sub main()\n" + indent(main, 2) + "\n")
    return "\n".join(out), f"2003\n{t['out']}\n"


# -----------------------------------------------------------------------------
# A `match` payload field that is itself a view: an enum instantiated at a
# view type (`G[?String]`, `G[[]Int]`), whose binding is the view
# the field holds, used in the arm or escaping. Like a `payload.` cell, a
# program that runs runs other code on the stack before it reads the view,
# and must print what it views. Cells are `viewpay.<type>.<subject>.<use>`.
# -----------------------------------------------------------------------------

# Each field type: its spelling, the same with the type parameter `T`
# (`gen`, at `arg`), the sigil that passes a view of that kind (`lend`),
# `k` and `d` making two values, the statement that shows a view `v` of
# one, and what it prints for `k`, then for `d`.
VIEWPAY_TYPES = {
    "text": dict(ty="?String", gen="?T", arg="String", lend="?", k='String("tx")', d='String("dd")',
                 show="print(v)", out="tx", outd="dd"),
    "int": dict(ty="?Int", gen="?T", arg="Int", lend="?", k="4", d="40", show="print(v)", out="4", outd="40"),
    "plain": dict(ty="?P", gen="?T", arg="P", lend="?", k="P(x: 4, y: 5)", d="P(x: 40, y: 50)",
                  show="print(v.x, v.y)", out="4 5", outd="40 50"),
    "list": dict(ty="?List[Int]", gen="?T", arg="List[Int]", lend="?", k="list(8)", d="list(80)",
                show="print(v[0], v.len)", out="8 1", outd="80 1"),
    "slice": dict(ty="[]Int", gen="[]T", arg="Int", lend="?", k="[8, 9]", d="[80]", slice=True,
                  show="print(v[0], v.len)", out="8 2", outd="80 1"),
}
# How the match reaches the enum: a call that wraps the view, the same in
# a generic function, a `?G[V]` or `!G[V]` parameter, or a local the
# function makes. `main` lends `k` and `d`.
VIEWPAY_SUBJECTS = {
    "call": dict(subj="wrap(x)"),
    "generic": dict(subj="gwrap(x)", generic=True),
    "param": dict(param="o: ?G[@V]", subj="o", make="o = wrap(LK)", arg="?o"),
    "write_param": dict(param="o: !G[@V]", subj="o", make="o = wrap(LK)", arg="!o"),
    "local": dict(subj="o", local=["o = wrap(x)"]),
}
# Where the view goes: returned (`ret`), returned past a guard that reads
# it (`guard`), used in the arm, which then returns `d` (`arm`), stored in
# a binding the function returns (`store`), or returned through a
# catch-all that matches the whole value again (`whole`).
VIEWPAY_USES = {
    "ret": dict(arms=[".a(r) => r", ".b(r) => r"]),
    "guard": dict(arms=[".a(r) if ok(r) => r", "_ => d"]),
    "arm": dict(arms=[".a(r)", "  see(r)", "  d", ".b(_) => d"], arm=True),
    "store": dict(arms=[".a(r) => saved = r", ".b(_) => pass"], store=True),
    "whole": dict(arms=[".b(r) => r", "w => match w", "  .a(r) => r", "  .b(r) => r"]),
}


def viewpay_program(tname, sname, uname):
    """The program for one view payload cell, and the output it must print."""
    t = VIEWPAY_TYPES[tname]
    s = VIEWPAY_SUBJECTS[sname]
    u = VIEWPAY_USES[uname]
    if u.get("arm") and s.get("generic") and t["show"] != "print(v)":
        # A generic arm shows the view with `print`, which spells only a
        # view of a value that prints as itself.
        return None, None
    lend = t["lend"]
    ty = t["ty"]
    gen = s.get("generic")
    vt = t["gen"] if gen else ty
    out = ["enum G[T]\n  a(r: T)\n  b(r: T)\n", "obj P\n  x: Int\n  y: Int\n",
           "fun list(n: Int) -> List[Int]\n  xs: List[Int] = List()\n  !xs.push(n)\n  xs\n",
           f"fun wrap(x: {ty}) -> G[{ty}] from x\n  .a(r: x)\n",
           f"fun gwrap[T](x: {t['gen']}) -> G[{t['gen']}] from x\n  .a(r: x)\n",
           f"fun ok(v: {ty}) -> Bool\n  true\n", f"fun gok[T](v: {t['gen']}) -> Bool\n  true\n",
           "fun clobber(n: Int) -> Int\n  a = [n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7]\n"
           "  b = [n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7]\n  a[1] + b[2]\n"]
    see = "gsee" if gen else "see"
    out.append(f"sub see(v: {ty})\n  print(clobber(1000))\n  {t['show']}\n")
    out.append(f"sub gsee[T](v: {t['gen']})\n  print(clobber(1000))\n  print(v)\n")
    arms = [a.replace("ok(", "gok(" if gen else "ok(").replace("see(", see + "(") for a in u["arms"]]
    subj, local = s["subj"], s.get("local", [])
    first = s.get("param", f"x: {vt}").replace("@V", ty)
    head = f"fun inner{'[T]' if gen else ''}({first}, d: {vt}) -> {vt} from {first.split(':')[0]}, d"
    if u.get("store"):
        body = [f"saved: {vt} = d"] + local + [f"match {subj}"] + ["  " + a for a in arms] + ["saved"]
    else:
        body = local + [f"match {subj}"] + ["  " + a for a in arms]
    out.append(head + "\n" + indent(body, 2) + "\n")
    lk = f"{lend}k[..]" if t.get("slice") else f"{lend}k"
    ld = f"{lend}d[..]" if t.get("slice") else f"{lend}d"
    main = [f"k = {t['k']}", f"d = {t['d']}"]
    if "make" in s:
        main.append(s["make"].replace("LK", lk))
    main.append(f"v = inner({s.get('arg', lk)}, {ld})")
    main.append("print(clobber(1000))")
    main.append(t["show"])
    out.append("sub main()\n" + indent(main, 2) + "\n")
    shown = "\n".join(["2003", t["out"]] if u.get("arm") else [])
    want = f"{shown}\n" if shown else ""
    return "\n".join(out), want + f"2003\n{t['outd'] if u.get('arm') else t['out']}\n"


# -----------------------------------------------------------------------------
# A lend of a binding that is a write view (a `match !e` payload, `if !o as
# b`, `for b in !v`, a `!T` parameter, a `|!b|` capture, a held `b = !x`),
# followed by a write through the binding while
# the lend's view is live, or after its last use. A lend of a write view
# is a loan on it (docs/INTERNALS.md, "Lending a binding"), so a write
# while the view is live is rejected; a program that runs must print what
# the view showed before the write, then what the write left. Cells are
# `lendw.<binding>.<type>.<lend>.<when>`.
# -----------------------------------------------------------------------------

# Each type: its spelling, `mk()`'s body, each lend of the binding `@B`
# with the statement that shows its view `s` and what that prints, the
# write through `@B`, and the statement that shows `@B` after it, with
# what it prints.
_LW_GROW = "for i in 0..64\n  !@B.push(i)"
LENDW_TYPES = {
    "text": dict(ty="String", mk='String("hello")',
                 lends=dict(whole=("?@B", "print(s)", "hello"), slice=("?@B[1..]", "print(s)", "ello"),
                            call=("text.trim(?@B)", "print(s)", "hello")),
                 write='for _ in 0..64\n  !@B.add("' + "z" * 64 + '")', show="print(@B.len)", out="4101"),
    "list": dict(ty="List[Int]", mk="xs: List[Int] = List()\n  !xs.push(1)\n  !xs.push(2)\n  !xs.push(3)\n  xs",
                lends=dict(whole=("?@B", "print(s)", "[1, 2, 3]"), slice=("?@B[1..]", "print(s)", "[2, 3]"),
                           call=("tail(?@B)", "print(s)", "[2, 3]")),
                write=_LW_GROW, show="print(@B.len)", out="67"),
    "box": dict(ty="^String", mk='^String("hello")',
                lends=dict(whole=("?@B", "print(s)", "hello"), slice=("?@B[1..]", "print(s)", "ello"),
                           call=("text.trim(?@B)", "print(s)", "hello")),
                write='@B = ^String("other")', show="print(@B)", out="other"),
    "struct": dict(ty="P", mk="P(xs: tail3())",
                   lends=dict(whole=("?@B", "print(s.xs)", "[1, 2, 3]"), slice=("?@B.xs[1..]", "print(s)", "[2, 3]"),
                              call=("@B.rest()", "print(s)", "[2, 3]")),
                   write=_LW_GROW.replace("@B.", "@B.xs."), show="print(@B.xs.len)", out="67"),
}
# Each binding: the declarations it needs, the lines before the body,
# the lines opening it, the body's indent under them, the lines after
# it, the binding's name when it is not `b`, for a parameter of `f`, the
# parameter and the value `main` makes and lends `f`, and whether every
# program must be rejected (`rejected`).
LENDW_BINDINGS = {
    "match": dict(decls="enum E\n  a(x: TY)\n  z\n", setup=["e = E.a(mk())"],
                  head=["match !e", "  .a(b)"], depth=4, after=["  .z => pass"]),
    "match_param": dict(decls="enum E\n  a(x: TY)\n  z\n", param="e: !E", arg="E.a(mk())",
                        head=["match !e", "  .a(b)"], depth=4, after=["  .z => pass"]),
    "if_as": dict(setup=["o: TY? = mk()"], head=["if !o as b"], depth=2),
    "for": dict(setup=["v: List[TY] = List()", "!v.push(mk())"], head=["for b in !v"], depth=2),
    "param": dict(param="b: !TY", arg="mk()", head=[], depth=0),
    "closure": dict(setup=["b = mk()"], head=["g = |!b|"], depth=2, after=["g()"]),
    "held": dict(setup=["x = mk()", "b = !x"], head=[], depth=0),
}
# More binding kinds: write bindings of every subject and header, and
# read bindings of a write view a local optional holds, every write
# through which is rejected.
_LW_E = "enum E\n  a(x: TY)\n  z\n"
_LW_HH = "\nobj HH\n  e: E\n"
_LW_GET = _LW_HH + "\nfun get(h: !HH) -> !E\n  !h.e\n"
_LW_TWO = ["e1 = E.a(mk())", "e2 = E.a(mk())", "c = true"]
LENDW_BINDINGS.update({
    "match_named": dict(decls=_LW_E, setup=["e = E.a(mk())"], head=["match !e", "  .a(x: b)"], depth=4, after=["  .z => pass"]),
    "match_box": dict(decls=_LW_E, setup=["e = ^E.a(mk())"], head=["match !e", "  .a(b)"], depth=4, after=["  .z => pass"]),
    "match_field": dict(decls=_LW_E + _LW_HH, setup=["h = HH(e: E.a(mk()))"], head=["match !h.e", "  .a(b)"], depth=4, after=["  .z => pass"]),
    "match_index": dict(decls=_LW_E, setup=["es: List[E] = List()", "!es.push(E.a(mk()))"], head=["match !es[0]", "  .a(b)"], depth=4, after=["  .z => pass"]),
    "match_generic": dict(decls="enum G[T]\n  a(x: T)\n  z\n", setup=["e: G[TY] = G.a(mk())"], head=["match !e", "  .a(b)"], depth=4, after=["  .z => pass"]),
    "match_guard": dict(decls=_LW_E, setup=["e = E.a(mk())", "c = true"], head=["match !e", "  .a(b) if c"], depth=4, after=["  _ => pass"]),
    "match_nested": dict(decls=_LW_E + "\nenum O\n  a(i: E)\n  z\n", setup=["o = O.a(E.a(mk()))"], head=["match !o", "  .a(io)", "    match !io", "      .a(b)"], depth=8, after=["      .z => pass", "  .z => pass"]),
    "match_call": dict(decls=_LW_E + _LW_GET, setup=["h = HH(e: E.a(mk()))"], head=["match !get(!h)", "  .a(b)"], depth=4, after=["  .z => pass"]),
    # A branch of write lends is lent on.
    "match_branch_lent_on": dict(decls=_LW_E, setup=["e1 = E.a(mk())", "e2 = E.z", "c = true"], head=["match (!e1 if c else !e2)", "  .a(b)"], depth=4, after=["  .z => pass"]),
    "while_as": dict(setup=["o: TY? = mk()", "n = 0"], head=["while !o as b"], depth=2, after=["  n += 1", "  break if n > 0"]),
    "if_as_write_param": dict(param="o: !(TY?)", arg="mk()", argty="TY?", head=["if !o as b"], depth=2),
    "if_as_field": dict(decls="obj HO\n  o: TY?\n", setup=["h = HO(o: mk())"], head=["if !h.o as b"], depth=2),
    "if_as_payload": dict(decls="enum E\n  a(o: TY?)\n  z\n", setup=["e = E.a(mk())"], head=["match !e", "  .a(o)", "    if !o as b"], depth=6, after=["  .z => pass"]),
    "for_index": dict(setup=["v: List[TY] = List()", "!v.push(mk())"], head=["for b, j in !v"], depth=2, after=["  _ = j"]),
    "for_array": dict(setup=["v = [mk()]"], head=["for b in !v"], depth=2),
    "closure_of_payload": dict(decls=_LW_E, setup=["e = E.a(mk())"], head=["match !e", "  .a(b0)", "    g = |!b0|"], depth=6, after=["    g()", "  .z => pass"], name="b0"),
    "held_of_payload": dict(decls=_LW_E, setup=["e = E.a(mk())"], head=["match !e", "  .a(b0)", "    b = !b0"], depth=4, after=["  .z => pass"]),
    "defer_arm": dict(decls=_LW_E, setup=["e = E.a(mk())"], head=["match !e", "  .a(b)", "    defer print(\"d\")"], depth=4, after=["  .z => pass"], prints="d\n"),
    # A read `if … as` or `while … as` binds the write view a local
    # optional holds as a read view.
    "read_as_local": dict(setup=["y = mk()", "o: (!TY)? = !y"], head=["if o as b"], depth=2, rejected=True),
    "read_while_as_local": dict(setup=["y = mk()", "o: (!TY)? = !y", "n = 0"], head=["while o as b"], depth=2, after=["  n += 1", "  break if n > 0"], rejected=True),
    # A branch whose leaf is a name holding a write view, matched in
    # place: a lend of the branch, which would copy the write view out of
    # the name (`lendsBranch`).
    "read_branch_bare_write_views": dict(decls=_LW_E, setup=_LW_TWO + ["wa = !e1", "wb = !e2"],
                                         head=["match (wa if c else wb)", "  .a(b)"], depth=4, after=["  .z => pass"], rejected=True),
    "read_coalesce_local_write_view": dict(decls=_LW_E, setup=_LW_TWO + ["o: (!E)? = !e1"],
                                           head=["match o ?? !e2", "  .a(b)"], depth=4, after=["  .z => pass"], rejected=True),
    # The same, written through the place the branch would copy the
    # write view out of (`via`): a second writer.
    "copied_branch_bare_write_views": dict(decls=_LW_E, setup=_LW_TWO + ["wa = !e1", "wb = !e2"],
                                           head=["match (wa if c else wb)", "  .a(b)"], depth=4, after=["  .z => pass"],
                                           via=["match !wa", "  .a(x2)", "@WRITE", "  .z => pass"], rejected=True),
    "copied_branch_write_view_and_lend": dict(decls=_LW_E, setup=_LW_TWO + ["wa = !e1"],
                                              head=["match (wa if c else !e2)", "  .a(b)"], depth=4, after=["  .z => pass"],
                                              via=["match !wa", "  .a(x2)", "@WRITE", "  .z => pass"], rejected=True),
    "copied_coalesce_local_write_view": dict(decls=_LW_E, setup=_LW_TWO + ["o: (!E)? = !e1"],
                                             head=["match o ?? !e2", "  .a(b)"], depth=4, after=["  .z => pass"],
                                             via=["if !o as w2", "  match !w2", "    .a(x2)", "@WRITE", "    .z => pass"], rejected=True),
})


def lendw_program(bname, tname, lname, when):
    """The program for one lend-then-write cell, and what it must print."""
    t = LENDW_TYPES[tname]
    b = LENDW_BINDINGS[bname]
    lend, show_s, out_s = t["lends"][lname]
    name = b.get("name", "b")
    fill = lambda x: x.replace("@B", name)
    write = fill(t["write"]).split("\n")
    if "via" in b:
        # The write goes through the place `via` matches to write, as `x2`.
        inner = t["write"].replace("@B", "x2").split("\n")
        at = next(l for l in b["via"] if l.strip() == "@WRITE")
        pad = " " * (b["via"][b["via"].index(at) - 1].index(".") + 2)
        write = []
        for l in b["via"]:
            write += [pad + w for w in inner] if l.strip() == "@WRITE" else [l]
    body = [f"s = {fill(lend)}"]
    if when == "live":
        body += write + [show_s, fill(t["show"])]
    else:
        body += [show_s] + write + [fill(t["show"])]
    out = ["use std.text\n", "obj P\n  xs: List[Int]\n\n  fun rest(?self) -> []Int\n    ?self.xs[1..]\n",
           "fun tail3() -> List[Int]\n  xs: List[Int] = List()\n  !xs.push(1)\n  !xs.push(2)\n  !xs.push(3)\n  xs\n",
           "fun tail(v: ?List[Int]) -> []Int\n  ?v[1..]\n",
           f"fun mk() -> {t['ty']}\n  {t['mk']}\n"]
    if "decls" in b:
        out.append(b["decls"].replace("TY", t["ty"]))
    lines = [l.replace("TY", t["ty"]) for l in b.get("setup", [])] + b["head"]
    lines += [" " * b["depth"] + l for l in body] + b.get("after", [])
    if "param" in b:
        out.append(f"sub f({b['param'].replace('TY', t['ty'])})\n" + indent(lines, 2) + "\n")
        # `argty` types the value `main` makes and lends `f`.
        y = f"y: {b['argty']} = {b['arg']}" if "argty" in b else f"y = {b['arg']}"
        out.append("sub main()\n" + indent([y.replace("TY", t["ty"]), "f(!y)"], 2) + "\n")
    else:
        out.append("sub main()\n" + indent(lines, 2) + "\n")
    if b.get("rejected"):
        # No run prints this: a program that runs fails the cell.
        return "\n".join(out), "(rejected)\n"
    return "\n".join(out), f"{out_s}\n{t['out']}\n" + b.get("prints", "")


# -----------------------------------------------------------------------------
# A header (`match`, `if … as`, `while … as`, `for`) whose subject reaches
# a place holding a write view through a branch: a path through it, `?.`,
# `??`, and `catch` (a whole branch is `lendw.`'s), over each kind of
# write-view leaf (a `!W` parameter, a local `a = !x`). The arm takes a
# view of the value the header binds, then writes through the place the
# branch read, and reads the view. The header reads the branch in place,
# a lend of it, which would copy the write view out of the place with no
# loan on it (`lendsBranch`), so every program must be rejected, and one
# that runs fails the cell. Each subject is written bare, lent to read
# (`?S`), and lent to write (`!S`). Cells are
# `hdr.<header>.<sigil>.<shape>.<leaf>`.
# -----------------------------------------------------------------------------

_HDR_PRE = """obj Res
  v: List[Int]

enum E
  a(r: Res)
  b

error Bad
  nope

obj W
  e: E
  o: List[Int]?
  v: List[Int]

fun list(n: Int) -> List[Int]
  xs: List[Int] = List()
  !xs.push(n)
  !xs.push(n + 1)
  xs

fun mkw(n: Int) -> W
  W(e: E.a(r: Res(v: list(n))), o: list(n), v: list(n))

fun tg(w: !W, ok: Bool) -> (!W)!
  return Bad.nope if not ok
  w
"""

# Each header: how it opens over `SUBJ`, whose part named by the field it
# reads, the view its body takes, and the lines that close it. `WRITE`
# marks the write through the place the branch read.
HDR_HEADERS = {
    "match": dict(field="e", lines=["match SUBJ", "  .a(r)", "    s = ?r.v[..]", "    WRITE", "    print(s[0])", "  .b => pass"]),
    "as": dict(field="o", lines=["if SUBJ as x", "  s = ?x[..]", "  WRITE", "  print(s[0])"]),
    "while_as": dict(field="o", lines=["while SUBJ as x", "  s = ?x[..]", "  WRITE", "  print(s[0])", "  break"]),
    "for": dict(field="v", lines=["for x in SUBJ", "  WRITE", "  print(x)"]),
}
# The value written for each field: a new one, which drops the old.
HDR_NEW = {"e": "E.a(r: Res(v: list(9)))", "o": "list(9)", "v": "list(9)"}
# Each leaf kind: the parameters of `f`, how `main` calls it, the lines
# before the header, and the two leaves.
HDR_LEAVES = {
    "wparam": dict(params="a: !W, b: !W, c: Bool", call=["w1 = mkw(1)", "w2 = mkw(2)", "f(!w1, !w2, true)"], pre=[], a="a", b="b"),
    "wlocal": dict(params="c: Bool", call=["f(true)"], pre=["w1 = mkw(1)", "w2 = mkw(2)", "a = !w1", "b = !w2"], a="a", b="b"),
}
# Each subject shape: the subject, given the leaves `A` and `B` and the
# field `F`, and the place the write goes through. `fun` marks a shape
# whose header propagates `none` (`?`), which `f` must return.
HDR_SHAPES = {
    "part": dict(subj="(A if c else B).F", via="A.F"),
    "optchain": dict(subj="o?.F", via="A.F", pre=["o: (!W)? = !A"], fun=True),
    "coalesce": dict(subj="(o ?? !B).F", via="A.F", pre=["o: (!W)? = !A"]),
    "catch": dict(subj="(tg(!B, false) catch |_| A).F", via="A.F"),
}


# Each sigil the subject is written with: bare, lent to read (`?S`), or
# to write (`!S`), which a lend of a branch rejects (`lendsBranch`).
HDR_SIGILS = {"bare": "", "read": "?", "write": "!"}


def hdr_program(hname, sname, lname, gname="bare"):
    """The program for one header-path cell."""
    h = HDR_HEADERS[hname]
    sh = HDR_SHAPES[sname]
    lf = HDR_LEAVES[lname]
    field = h["field"]
    a, b = lf["a"], lf["b"]
    subj = HDR_SIGILS[gname] + sh["subj"].replace("A", a).replace("B", b).replace("F", field)
    via = sh["via"].replace("A", a).replace("F", field)
    write = f"{via} = {HDR_NEW[field]}"
    body = [l.replace("SUBJ", subj).replace("WRITE", write) for l in h["lines"]]
    pre = lf["pre"] + [l.replace("A", a) for l in sh.get("pre", [])]
    lines = pre + body
    if sh.get("fun"):
        head = f"fun f({lf['params']}) -> Int?"
        lines = lines + ["1"]
        main = [l.replace("f(", "print(f(", 1) + " ?? 0)" if l.startswith("f(") else l for l in lf["call"]]
    else:
        head = f"sub f({lf['params']})"
        main = lf["call"]
    return _HDR_PRE + "\n" + head + "\n" + indent(lines, 2) + "\n\nsub main()\n" + indent(main, 2) + "\n"


# -----------------------------------------------------------------------------
# A Cell lives only behind `*`: a value holding one is reached through a
# `*` handle. A Cell changed, or read, through the handle to the value
# holding it, through a `!T` parameter given the handle, and through a
# `!self` method called on it, built in debug and with `--release`: a
# change by a marked call must reach the value in both. Each program applies each
# operation (in a function of its own, to a value of its own) through
# one access in a statement, a loop that continues early, a loop that
# breaks, a `defer`, and a loop that returns, and prints the state after
# each, which must be what `cellmut_output` computes. Cells are
# `cellmut.<type>.<access>`: one program each, since a release build is
# slow.
# -----------------------------------------------------------------------------

# Each type: its spelling, declarations (`METHODS` marks where a struct's
# methods go), how `mk()` makes one behind a handle, the paths to its
# `Cell[Int]` and its `Cell[List[Int]]` from a value `E` (None: it has
# none), and whether it prints when dropped.
CELLMUT_TYPES = {
    # a `drop`
    "drop": dict(ty="D", decls='obj D\n  c: Cell[Int]\n  v: Cell[List[Int]]\n\n  drop(!self)\n    print("drop", self.c.get(), self.v.len)\nMETHODS',
                 mk="*D(c: Cell(1), v: Cell(list2()))", c="E.c", v="E.v", drop=True),
    # the Cells in a part
    "part": dict(ty="W", decls="obj In\n  c: Cell[Int]\n  v: Cell[List[Int]]\n\nobj W\n  t: In\nMETHODS",
                 mk="*W(t: In(c: Cell(1), v: Cell(list2())))", c="E.t.c", v="E.t.v"),
    # a generic type at Int
    "generic": dict(ty="G[Int]", decls="obj G[T]\n  c: Cell[T]\n  v: Cell[List[T]]\nMETHODS",
                    mk="*G(c: Cell(1), v: Cell(list2()))", c="E.c", v="E.v"),
    # a bare Cell[Int], and a bare Cell[List[Int]]
    "cell": dict(ty="Cell[Int]", decls="", mk="*Cell(1)", c="E", v=None),
    "cellvec": dict(ty="Cell[List[Int]]", decls="", mk="*Cell(list2())", c=None, v="E"),
}

# Each operation, applied once through `E` with argument `KARG`, adding
# what it reads to `s`; `C` is the path to the `Cell[Int]`, `V` to the
# `Cell[List[Int]]`.
CELLMUT_OPS = {
    "set": ("c", ["!C.set(C.get() + KARG)"]),
    "replace": ("c", ["s += (!C).replace(KARG)"]),
    "get": ("c", ["s += C.get()"]),
    "push": ("v", ["!V.push(KARG)"]),
    "pop": ("v", ["s += (!V).pop() ?? -1"]),
    "clear": ("v", ["!V.clear()", "!V.push(KARG)"]),
    "index": ("v", ["(!V)[0] = V[0] + KARG"]),
    "method": ("m", ["!E.bump(KARG)"]),
}

# Each access to the handle `x`: the declaration it adds (`T` the type,
# `OP` the operation through the access path `e`), and how one
# application is written in `run` (`OP` inline, or a call passing
# `KARG`). A wrapper returns the `s` its operation adds to.
_CM_WRAP = "  s = 0\nOP\n  s\n"
CELLMUT_ACCESS = {
    "handle": dict(do="OP", e="x"),
    "param": dict(decls="fun via(y: !T, k: Int) -> Int\n" + _CM_WRAP, do="s += via(!x, KARG)", e="y"),
    "method": dict(method="fun via(!self, k: Int) -> Int\n" + _CM_WRAP, do="s += (!x).via(KARG)", e="self"),
}


def cellmut_applies(tname, aname, oname):
    t, needs = CELLMUT_TYPES[tname], CELLMUT_OPS[oname][0]
    if needs == "c" and t["c"] is None or needs == "v" and t["v"] is None:
        return False
    return t["decls"] != "" or (needs != "m" and aname != "method")


def _cm_op(t, oname, e, karg):
    """The operation's lines through path `e`, with argument `karg`."""
    out = []
    for l in CELLMUT_OPS[oname][1]:
        if t["c"]:
            l = re.sub(r"\bC\b", t["c"].replace("E", e), l)
        if t["v"]:
            l = re.sub(r"\bV\b", t["v"].replace("E", e), l)
        out.append(re.sub(r"\bE\b", e, l).replace("KARG", karg))
    return out


def _cm_wrap(text, ty, op):
    """A wrapper's declaration: `T` the type, `OP` its operation's lines."""
    lines = []
    for l in text.replace("!T", "!" + ty).rstrip("\n").split("\n"):
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
    if t["decls"]:
        c = t["c"].replace("E", "self")
        bump = [f"!{c}.set({c}.get() + k)"] + (["!" + t["v"].replace("E", "self") + ".push(k)"] if t["v"] else [])
        # A generic type's methods take and add its `T`.
        kty = "T" if tname == "generic" else "Int"
        methods = ["", f"  sub bump(!self, k: {kty})"] + ["    " + l for l in bump]
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
    out += ["fun list2() -> List[Int]", "  v: List[Int] = List()", "  !v.push(1)", "  !v.push(2)", "  v", ""]
    out += [f"fun mk() -> *{ty}", f"  {t['mk']}", ""]
    out += ["fun maybe(n: Int) -> Int?", "  return none if n % 2 == 1", "  n", ""]
    if "decls" in a:
        for oname in ops:
            out += _cm_wrap(a["decls"].replace("via(", f"via_{oname}("), ty, _cm_op(t, oname, a["e"], "k")) + [""]
    # The state, read through the handle.
    shown = []
    if t["c"]:
        shown.append(t["c"].replace("E", "x") + ".get()")
    if t["v"]:
        vp = t["v"].replace("E", "x")
        shown += [vp + ".len", f"({vp}.get(0) ?? -1)"]
    show = "print(s, " + ", ".join(shown) + ")"
    for oname in ops:
        def apply(k, ind):
            if a["do"] == "OP":
                return [ind + o for o in _cm_op(t, oname, a["e"], k)]
            return [ind + a["do"].replace("via(", f"via_{oname}(").replace("KARG", k)]
        body = ["s = 0", "x = mk()"]
        # a statement
        body += apply("1", "") + [show]
        # a loop whose argument may continue
        body += ["for i in 0..4"] + apply("i", "  ") + ["  s += maybe(i) ?? continue", show]
        # a loop that breaks
        body += ["j = 0", "while j < 9", "  j += 1"] + apply("j", "  ") + ["  break if j == 3", show]
        # a `defer` in a loop's body
        body += ["for _ in 0..2", "  defer"] + apply("10", "    ") + ["  s += 100", show]
        # a loop that returns, with the state shown by a `defer`
        body += ["defer", "  " + show, "for i in 0..9"] + apply("i", "  ") + ["  return if i == 2"]
        out += [f"sub run_{oname}()"] + ["  " + l for l in body] + [""]
    out += ["sub main()"] + [f'  print("{o}")\n  run_{o}()' for o in ops] + ['  print("end")']
    return "\n".join(out) + "\n"


def cellmut_output(tname, aname):
    """What a cellmut cell prints."""
    return "".join(f"{o}\n" + _cm_trace(tname, o) for o in cellmut_ops(tname, aname)) + "end\n"


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
# A value holding a Cell made, held, or changed anywhere but behind `*`:
# a Cell local, a struct holding one as a local, a by-value parameter, or
# a List element (`cellmut.value.`), and a Cell temporary changed or read
# where it stands: a bare Cell, a struct made in the statement, and one a
# call returns (`celltemp.value.`). Every program must be rejected.
# -----------------------------------------------------------------------------

_CV_N = "obj N\n  c: Cell[Int]\n\n"
CELL_VALUES = {
    "cellmut.value.cell": "sub main()\n  c = Cell(1)\n  !c.set(2)\n  print(c.get())\n",
    "cellmut.value.local": _CV_N + "sub main()\n  x = N(c: Cell(1))\n  !x.c.set(2)\n  print(x.c.get())\n",
    "cellmut.value.param": _CV_N + "sub bump(y: N)\n  !y.c.set(y.c.get() + 1)\n\nsub main()\n  x = *N(c: Cell(1))\n  print(x.c.get())\n",
    "cellmut.value.element": _CV_N + "sub main()\n  vs: List[N] = List()\n  print(vs.len)\n",
    "celltemp.value.cell": "sub main()\n  !Cell(5).set(77)\n  print(1)\n",
    "celltemp.value.struct": _CV_N + "sub main()\n  print(N(c: Cell(5)).c.get())\n",
    "celltemp.value.call": _CV_N + "fun mk(n: Int) -> N\n  N(c: Cell(n))\n\nsub main()\n  print(mk(5).c.get())\n",
}


# A branch of places that hold a Cell, copied by value: every form that
# gives one of its leaves (`if`, a block `if`, a `match`), in every
# context that reads or stores the value, with the leaf a struct holding
# a Cell or the bare Cell. A change through another handle would land
# under the copy, so each program must be rejected (`cellbranch.`).
_CB_PRE = """enum K
  p
  q

obj S
  c: Cell[List[Int]]

obj O
  s: S

fun grow(s: ?S) -> Int
  s.c.push(1)
  5

fun see(x: ?S) -> Int
  x.c.len

fun take(x: S) -> Int
  1

sub main()
  a = *O(s: S(c: Cell(List())))
  b = *O(s: S(c: Cell(List())))
  a2 = +a
  k = a.s.c.len == 0
  e = K.p
"""
_CB_FORMS = {
    "ifelse": ["L if k else R"],
    "blockif": ["if k", "  L", "else", "  R"],
    "match": ["match e", "  .p => L", "  .q => R"],
}
# Each context: its lines given the value `V`, and whether it takes a
# struct only.
_CB_CTX = {
    "print": (["print(V, grow(?a2.s))"], False),
    "bind": (["x = V", "print(see(?x), grow(?a2.s))"], True),
    "text": (["t = String(V, grow(?a2.s))", "print(t)"], False),
    "take": (["print(take(V))"], True),
}


def _cb_program(form, ctx, leaf):
    l, r = ("a.s", "b.s") if leaf == "struct" else ("a.s.c", "b.s.c")
    branch = [x.replace("L", l).replace("R", r) for x in _CB_FORMS[form]]
    lines, _ = _CB_CTX[ctx]
    if len(branch) == 1:
        body = [x.replace("V", branch[0]) for x in lines]
    else:
        # A branch of several lines is bound first, then used.
        body = ["y = " + branch[0]] + branch[1:] + [x.replace("V", "y") for x in lines]
    return _CB_PRE + "\n".join("  " + x for x in body) + "\n"


for _f in _CB_FORMS:
    for _c, (_, _only) in _CB_CTX.items():
        for _l in ("struct",) if _only else ("struct", "cell"):
            CELL_VALUES[f"cellbranch.{_f}.{_c}.{_l}"] = _cb_program(_f, _c, _l)


# -----------------------------------------------------------------------------
# Slices of a value however it is held: a slice of an array, a List, a String,
# or a ?String, held owned, through a read or write view, a `*T`, a box, a
# field, or a nested field (and a write view of a `*T` or a box),
# passed as an argument whose result keeps the view, or bound bare, and
# then the owner changed or replaced while the slice is still used
# (`live`) or after its last use (`done`). Whatever is accepted must run
# sanitizer-clean: a slice that lends what it slices keeps the change out.
# -----------------------------------------------------------------------------

SLICEVIEW_ELEMS = {
    "array": dict(ty="[4]Int", view="[]Int", mk="[n, n + 1, n + 2, n + 3]", grow=["P[0] = 9"]),
    "list": dict(ty="List[Int]", view="[]Int", mk="v: List[Int] = List()\n  for i in 0..4\n    !v.push(n + i)\n  v",
                grow=["for i in 0..100", "  !P.push(i)"]),
    "text": dict(ty="String", view="?String", mk='String("hello", n)', grow=["for _ in 0..100", '  !P.add("abcdefgh")']),
    "string": dict(ty="?String", view="?String", mk='"hello" if n > 0 else "world"', grow=['P = "other"']),
    "static": dict(ty="Static", view="?String", mk='"hello" if n > 0 else "world"', grow=['P = "other"']),
}

# How the slice's object is held (`X` is what is sliced), and what
# changes the owner: growing it (`P`, the place written) or replacing
# what holds it.
SLICEVIEW_HOLDERS = {
    "owned": dict(setup=["o = mk(1)"], x="o", place="o"),
    "read": dict(setup=["o = mk(1)", "x = ?o"], x="x", place="o"),
    "write": dict(setup=["o = mk(1)", "x = !o"], x="x", place="x"),
    "shared": dict(setup=["x = *mk(1)"], x="x", replace="x = *mk(2)"),
    "wshared": dict(setup=["h = *mk(1)", "x = !h"], x="x", replace="x = *mk(2)"),
    "box": dict(setup=["x = ^mk(1)"], x="x", replace="x = ^mk(2)"),
    "wbox": dict(setup=["b = ^mk(1)", "x = !b"], x="x", replace="x = ^mk(2)"),
    "field": dict(setup=["h = H(f: mk(1))"], x="h.f", place="h.f"),
    "nested": dict(setup=["g = G(h: H(f: mk(1)))"], x="g.h.f", place="g.h.f"),
}


def sliceview_program(hname, ename, use, then):
    e = SLICEVIEW_ELEMS[ename]
    h = SLICEVIEW_HOLDERS[hname]
    ty, view = e["ty"], e["view"]
    out = [f"fun mk(n: Int) -> {ty}\n  {e['mk']}\n",
           f"fun keep(x: {view}) -> {view}\n  x\n",
           f"obj H\n  f: {ty}\n",
           f"obj G\n  h: H\n"]
    body = list(h["setup"])
    sliced = f"{h['x']}[1..]"
    body.append(f"s = keep({sliced})" if use == "arg" else f"s = {sliced}")
    if then == "done":
        body.append("print(s)")
    if "replace" in h:
        body.append(h["replace"])
    else:
        body += [l.replace("P", h["place"]) for l in e["grow"]]
    after = h.get("place", h["x"])
    body.append("print(s)" if then == "live" else f"print({after}[1..].len)" if ename == "string" else f"print((?{after}[1..]).len)")
    out.append("sub main()\n" + indent(body, 2) + "\n")
    return "\n".join(out)


def store_program(oname, fname, then):
    """The program for one store cell."""
    o = STORE_OWNERS[oname]
    kind, lines = STORE_FORMS[fname]
    h = STORE_HOLDERS[kind]
    v = o["view"]
    out = [f"obj H\n  r: {v}\n\n  sub set(!self, s: {v}) keeps s\n    self.r = s\n",
           "obj O\n  h: H\n", "enum E\n  one(h: H)\n  zero\n",
           f"sub put(h: !H, s: {v}) keeps s\n  h.r = s\n"]
    body = [l.replace("S", o["lend"]) for l in lines]
    body += o["grow"] if then == "grow" else ["print(b.len)"]
    body += ["print(t[0])"] if fname == "read_back" else h["read"]
    out.append(f"sub f(a: !{h['ty']}, b: !{o['ty']}) keeps b\n{indent(body, 2)}\n")
    main = [o["init"], o["make"], h["make"].replace("I", "?x[..]"), "f(!h, !v)"]
    out.append("sub main()\n" + indent(main, 2) + "\n")
    return "\n".join(out)


# -----------------------------------------------------------------------------
# A call that keeps a parameter (Core sentence 7): each kind of parameter,
# stored by the callee into its receiver, into a write argument, through a
# call that keeps it, on some paths only, or not at all, with `keeps`
# naming it and without, then the holder read, or the lent owner changed
# first. A lent parameter is kept only when `keeps` names it, and a body
# that stores one unnamed is rejected; a parameter taken by value is kept
# by its type, and `keeps` may not name it; a call through a function
# value keeps by type. Cells are `keeps.<kind>.<store>.<said>.<then>`,
# each with its outcome: what it prints, or rejected.
# -----------------------------------------------------------------------------

# Each kind: the parameter's type `P`, the holder's field type, what the
# callee stores (`E`), how `main` makes the holder's first value
# (`setup`, `init`), the owner (`owner`) and the argument lent from it
# (`lend`), how the holder is read back with what it prints stored and
# first, how the owner is changed, and how the callee hands the
# parameter on (`on`, `p` unless written). `lent`: a lent parameter, which
# `keeps` names; `generic`: the holder is `H[T]`; `recv`: the receiver
# is the parameter, kept in a `!List[?Item]` argument; `fnval`: the
# callee is called through a function value.
KEEPS_KINDS = {
    "read": dict(P="?Item", held="?Item", E="p", setup=["z = Item(n: 0)"], init="?z", owner=["it = Item(n: 7)"],
                 lend="?it", read="print(h.r.n)", stored="7", first="0", change="it.n = 8"),
    "write": dict(P="!List[Int]", held="[]Int", E="?p[..]", setup=["z: List[Int] = List()", "!z.push(0)"], init="?z[..]",
                  owner=["v: List[Int] = List()", "!v.push(7)"], lend="!v", read="print(h.r[0])", stored="7", first="0",
                  change="!v.push(8)", on="!p"),
    "slice": dict(P="[]Int", held="[]Int", E="p", setup=["z = [0]"], init="?z[..]", owner=["a = [7, 1]"], lend="?a[..]",
                  read="print(h.r[0])", stored="7", first="0", change="a[0] = 8"),
    "text": dict(P="?String", held="?String", E="p", setup=[], init='"first"', owner=['t = String("seven")'], lend="?t",
                 read="print(h.r)", stored="seven", first="first", change='!t.add("x")'),
    "optional": dict(P="(?String)?", held="(?String)?", E="p", setup=[], init="none", owner=['t = String("seven")'],
                     lend="?t", read="print(h.r)", stored="seven", first="none", change='!t.add("x")'),
    "generic": dict(P="?T", held="(?T)?", E="p", setup=[], init="none", owner=['t = String("seven")'], lend="?t",
                    read="print(h.r)", stored="seven", first="none", change='!t.add("x")', generic=True),
    "receiver": dict(P="?self", lend="it", owner=["it = Item(n: 7)"], read="print(out.len)", stored="1", first="0",
                     change="it.n = 8", recv=True),
    "value": dict(P="Token", held="Token", E="p", setup=[], init='Token(text: "first")', owner=['t = String("seven")'],
                  lend="Token(text: ?t)", read="print(h.r.text)", stored="seven", first="first", change='!t.add("x")',
                  by_value=True),
    "fnval": dict(P="?String", held="?String", E="p", setup=[], init='"first"', owner=['t = String("seven")'], lend="?t",
                  read="print(h.r)", stored="seven", first="first", change='!t.add("x")', fnval=True),
}
# Each store: how the callee's body stores `E` (`self.r`, or `h.r` in a
# function given the holder `h`), and whether it stores at all.
KEEPS_STORES = {
    "self": dict(stores=True),
    "arg": dict(stores=True),
    "call": dict(stores=True),
    "some": dict(stores=True),
    "none": dict(stores=False),
}


def keeps_program(kname, sname, said, then):
    """The program for one `keeps.` cell and what it prints ("(rejected)"
    when it must be rejected); None where the store cannot stand."""
    k = KEEPS_KINDS[kname]
    s = KEEPS_STORES[sname]
    recv, fnval, generic, by_value = k.get("recv"), k.get("fnval"), k.get("generic"), k.get("by_value")
    # A receiver is stored only into a write argument; a function value
    # is a function, which has no receiver.
    if recv and sname == "self" or fnval and sname in ("self", "some"):
        return None, None
    clause = (" keeps self" if recv else " keeps p") if said else ""
    some = sname == "some"
    out = ["obj Item\n  n: Int\n", "obj Token\n  text: ?String\n"]
    if recv:
        body = {"arg": ["!out.push(self)"], "call": ["self.put_in(!out)"],
                "some": ["if c", "  !out.push(self)"], "none": ["pass"]}[sname]
        params = "?self, out: !List[?Item]" + (", c: Bool" if some else "")
        out[0] = ("obj Item\n  n: Int\n\n"
                  f"  sub m({params}){clause}\n{indent(body, 4)}\n\n"
                  "  sub put_in(?self, out: !List[?Item]) keeps self\n    !out.push(self)\n")
        main = k["owner"] + ["out: List[?Item] = List()", f"(?it).m(!out{', true' if some else ''})"]
        main += ([k["change"]] if then == "change" else []) + [k["read"]]
        out.append("sub main()\n" + indent(main, 2) + "\n")
        expect = keeps_expect(k, sname, said, then)
        return "\n".join(out), expect
    hty = "H[T]" if generic else "H"
    tp = "[T]" if generic else ""
    setter_keeps = "" if by_value else " keeps p"
    target = "h.r" if sname == "arg" or fnval else "self.r"
    body = {"self": [f"{target} = {k['E']}"], "arg": [f"{target} = {k['E']}"],
            "call": ["set_r(!h, p)" if fnval else f"!self.set({k.get('on', 'p')})"],
            "some": ["if c", f"  {target} = {k['E']}"], "none": ["pass"]}[sname]
    params = f"p: {k['P']}" + (", c: Bool" if some else "")
    methods = f"  sub set(!self, p: {k['P']}){setter_keeps}\n    self.r = {k['E']}\n"
    if sname in ("self", "call", "some", "none") and not fnval:
        methods += f"\n  sub m(!self, {params}){clause}\n{indent(body, 4)}\n"
    out.append(f"obj H{tp}\n  r: {k['held']}\n\n{methods}")
    if fnval:
        out.append(f"sub m(h: !H, {params}){clause}\n{indent(body, 2)}\n")
        out.append(f"sub set_r(h: !H, p: {k['P']}) keeps p\n  h.r = {k['E']}\n")
    elif sname == "arg":
        out.append(f"sub m{tp}(h: !{hty}, {params}){clause}\n{indent(body, 2)}\n")
    make = f"h = H[String](r: {k['init']})" if generic else f"h = H(r: {k['init']})"
    arg = k["lend"]
    if fnval:
        call = ["f: ?sub(!H, ?String) = ?m", f"f(!h, {arg})"]
    elif sname == "arg":
        call = [f"m(!h, {arg})"]
    else:
        call = [f"!h.m({arg}{', true' if some else ''})"]
    main = k["setup"] + [make] + k["owner"] + call
    main += ([k["change"]] if then == "change" else []) + [k["read"]]
    out.append("sub main()\n" + indent(main, 2) + "\n")
    return "\n".join(out), keeps_expect(k, sname, said, then)


def keeps_expect(k, sname, said, then):
    """What a `keeps.` cell prints, or "(rejected)"."""
    rejected = "(rejected)\n"
    stores = KEEPS_STORES[sname]["stores"]
    if k.get("by_value"):
        # `keeps` names no parameter taken by value, which is kept by its
        # type: the owner stays lent while the holder lives.
        if said or then == "change":
            return rejected
        return (k["stored"] if stores else k["first"]) + "\n"
    # An unnamed lent parameter stored is the body check's error.
    if stores and not said:
        return rejected
    # Kept: by the clause, or by type through a function value.
    kept = said or k.get("fnval")
    if then == "change" and kept:
        return rejected
    return (k["stored"] if stores else k["first"]) + "\n"


def taken_then(pname, then):
    """A `taken.` cell's lines after the take, and its output."""
    return TAKEN_PLACES[pname].get("thens", {}).get(then, TAKEN_THENS[then])


def taken_program(pname, then):
    """The program for one `taken.` cell; None where the place lives in
    no frame that owns `src`."""
    pl = TAKEN_PLACES[pname]
    lines, _ = taken_then(pname, then) or (None, None)
    if lines is None or pl.get("run") and then == "drop":
        return None
    out = ["obj S\n  text: ?String\n  value: String\n", "obj H\n  s: S\n", "obj G\n  h: H\n"]
    place = pl["place"]
    take = pl.get("take", [f"t = replace(!{place}, S(text: \"\", value: String()))"])
    body = take + [l.replace("P", place) for l in lines]
    main = ['src = String("abc")'] + pl["setup"]
    if pl.get("run"):
        out.append("sub run(p: !H)\n" + indent(body, 2) + "\n")
        main.append("run(!h)")
    else:
        main += body
    out.append("sub main()\n" + indent(main, 2) + "\n")
    return "\n".join(out)


# A value that holds a read view of an owner (`holder.`), whatever
# holds it, keeps the owner lent while the holder is used: the owner is
# written, moved, or dropped while the holder is still used (rejected),
# or after its last use (runs, and prints what each saw).
HOLDER_OWNERS = {
    "list": dict(view="?List[Int]", mk=["o: List[Int] = List()", "!o.push(7)"], read=".len", write="!o.push(8)", after="o.len"),
    "big": dict(view="?Big", mk=["o = Big(v: List())", "!o.v.push(7)"], read=".v.len", write="!o.v.push(8)", after="o.v.len"),
    "boxed": dict(view="?List[Int]", mk=["o = ^List[Int]()", "!o.push(7)"], read=".len", write="!o.push(8)", after="o.len"),
    "shared": dict(view="?List[Int]", mk=["o: *List[Int] = *List()"], read=".len", write=None, after="o.len", n=0),
}

HOLDER_FORMS = {
    "box": dict(setup=["h = ^@V"], read="h{R}"),
    "generic_fn": dict(setup=["h = same(@V)"], read="h{R}"),
    "generic_box": dict(setup=["h = boxed(@V)"], read="h{R}"),
    "optional": dict(setup=["h: (?T)? = @V"], read=None, opt=True),
    "struct": dict(setup=["h = Hold(v: @V)"], read="h.v{R}"),
    "method": dict(setup=["h = Hold(v: @V)"], read="h.get(){R}"),
    "pair": dict(setup=["h = Pair(a: @V, b: @V)"], read="h.b{R}"),
    "list": dict(setup=["h: List[?T] = List()", "!h.push(@V)"], read="h[0]{R}"),
    "array": dict(setup=["h = [@V, @V]"], read="h[1]{R}"),
}


def holder_program(oname, fname, change, then):
    o = HOLDER_OWNERS[oname]
    f = HOLDER_FORMS[fname]
    if change == "write" and o["write"] is None:
        return None, None
    out = ["obj Big\n  v: List[Int]\n",
           "fun same[T](x: T) -> T\n  x\n",
           "fun boxed[T](x: T) -> ^T\n  ^x\n",
           "obj Hold[T]\n  v: T\n\n  fun get(?self) -> T\n    self.v\n",
           "obj Pair[A, B]\n  a: A\n  b: B\n"]
    view = o["view"]
    body = list(o["mk"])
    body += [l.replace("@V", "?o").replace("?T", view) for l in f["setup"]]
    if f.get("opt"):
        reads = ["if h as w", "  print(w%s)" % o["read"]]
    else:
        reads = ["print(%s)" % f["read"].replace("{R}", o["read"])]
    effect = {"write": [o["write"]] if o["write"] else [], "move": ["w = <o"], "drop": ["<o"]}[change]
    if then == "live":
        body += effect + reads
        return "\n".join(out) + "\nsub main()\n" + indent(body, 2) + "\n", "(rejected)\n"
    body += reads + effect
    n = o.get("n", 1)
    expect = f"{n}\n"
    if change == "write":
        body.append("print(%s)" % o["after"])
        expect += f"{n + 1}\n"
    elif change == "move":
        body.append("print(w%s)" % o["read"])
        expect += f"{n}\n"
    return "\n".join(out) + "\nsub main()\n" + indent(body, 2) + "\n", expect



# A generic body that puts its `T` inside another value, at any depth,
# and stores that where no loan is tracked (`nest.`): an instance at a
# view of an owner, or a ?String, is rejected, so nothing reads the owner
# after it ends.
NEST_WRAPPERS = {
    "list": dict(ty="List[T]", build=["w: List[T] = List()", "!w.push(x)"]),
    "hold": dict(ty="Hold[T]", build=["w = Hold(v: x)"]),
    "shared": dict(ty="*Hold[T]", build=["w = *Hold(v: x)"]),
    "weak": dict(ty="~Hold[T]", build=["h = *Hold(v: x)", "w = ~h"]),
    "optional": dict(ty="T?", build=["w: T? = x"]),
    "box": dict(ty="^T", build=["w = ^x"]),
    "vecbox": dict(ty="List[^T]", build=["w: List[^T] = List()", "!w.push(^x)"]),
    "bare": dict(ty="T", build=["w = x"]),
}
NEST_HOMES = ("cell", "closure")
NEST_OWNERS = {
    "box": dict(make="b = ^String(\"hello\")", arg="?b"),
    "text": dict(make="b = String(\"hello\")", arg="?b[..]"),
    "list": dict(make="b: List[Int] = List()", arg="?b"),
    "string": dict(make="b: ?String = \"lit\"", arg="b"),
    "static": dict(make="b = \"lit\"", arg="b"),
}


def nest_program(wname, home, oname):
    w = NEST_WRAPPERS[wname]
    o = NEST_OWNERS[oname]
    if home == "cell":
        ret, last = f"*Cell[{w['ty']}]", "*Cell(<w)"
    else:
        ret, last = "*sub()", "*|<w| print(1)"
    body = list(w["build"]) + [last]
    return "\n".join([
        "obj Hold[T]\n  v: T\n",
        f"fun mk[T](x: T) -> {ret}\n{indent(body, 2)}\n",
        "sub main()\n" + indent([o["make"], f"f = mk({o['arg']})", "print(1)"], 2) + "\n"])


# A call of an owned closure (`clos.`): the closure is held as a local, a
# field, a List element, an `as` binding, a view passed to a function, a
# generic type's field, or a temporary; it is given its holder to write
# or read, a String to own, or a ?String; and it returns a number, a
# String, or a ?String viewing its argument. The result is printed
# (`use`), or the argument's root is written first (`conflict`). A call
# that lends to write what holds the closure is rejected (the closure
# could free itself), as is a result viewing an owned parameter, a
# write while the result views it, and a temporary callee.
CLOS_ARGS = {
    # arg: (parameter type, argument, the body per result, what each prints)
    "wholder": ("!Hold", "!h", {"plain": ["k.n += 1", "k.n"], "owned": ["String(k.name)"], "view": ["?k.name"]},
                {"plain": "2", "owned": "nm", "view": "nm"}),
    "rholder": ("?Hold", "?h", {"plain": ["k.n"], "owned": ["String(k.name)"], "view": ["?k.name"]},
                {"plain": "1", "owned": "nm", "view": "nm"}),
    "owned": ("String", 'String("own")', {"plain": ["k.len"], "owned": ["k"], "view": ["?k"]},
              {"plain": "3", "owned": "own", "view": None}),
    "text": ("?String", "?t", {"plain": ["k.len"], "owned": ["String(k)"], "view": ["k"]},
             {"plain": "3", "owned": "txt", "view": "txt"}),
}
CLOS_RESULTS = {"plain": "Int", "owned": "String", "view": "?String"}
CLOS_CALLEES = ("local", "field", "element", "asbind", "view", "generic", "temp")
# The callees held in `h`, the holder the call may lend.
CLOS_IN_HOLDER = ("field", "element", "asbind", "view")
CLOS_THENS = ("use", "conflict")


def clos_program(callee, aname, rname, then):
    """The program for one owned-closure call cell, and what it prints."""
    ptype, arg, bodies, prints = CLOS_ARGS[aname]
    ty = f"*fun({ptype}) -> {CLOS_RESULTS[rname]}"
    field = {"field": f"  f: {ty}\n", "element": f"  fs: List[{ty}]\n",
             "asbind": f"  o: ({ty})?\n", "view": f"  f: {ty}\n"}.get(callee, "")
    out = ["obj Hold\n  n: Int\n  name: String\n" + field,
           "obj Box[T]\n  f: T\n"]
    if callee == "view":
        passed = {"wholder": "!k", "rholder": "k", "owned": "<k", "text": "k"}[aname]
        out.append(f"fun call(f: ?{ty}, k: {ptype}) -> {CLOS_RESULTS[rname]}\n  f({passed})\n")
    body = ['t = String("txt")', f"cl: {ty} = *|k|"] + ["  " + l for l in bodies[rname]]
    made = 'h = Hold(n: 1, name: String("nm"){})'
    if callee in ("field", "view"):
        body.append(made.format(", f: <cl"))
    elif callee == "element":
        body += [made.format(", fs: List()"), "!h.fs.push(<cl)"]
    elif callee == "asbind":
        body.append(made.format(", o: <cl"))
    else:
        body.append(made.format(""))
    if callee == "generic":
        body.append("b = Box(f: <cl)")
    call = {"local": f"cl({arg})", "field": f"h.f({arg})", "element": f"h.fs[0]({arg})",
            "asbind": f"g({arg})", "view": f"call(?h.f, {arg})", "generic": f"b.f({arg})",
            "temp": f"(+cl)({arg})"}[callee]
    tail = [f"r = {call}"]
    if then == "conflict":
        tail.append('!t.add("!")' if aname == "text" else "h.n += 10")
    tail.append("print(r)")
    if callee == "asbind":
        body += ["if h.o as g"] + ["  " + l for l in tail]
    else:
        body += tail
    out.append("sub main()\n" + indent(body, 2) + "\n")
    rejected = (callee == "temp" or prints[rname] is None
                or (aname == "wholder" and callee in CLOS_IN_HOLDER)
                or (then == "conflict" and rname == "view"))
    return "\n".join(out), "(rejected)\n" if rejected else prints[rname] + "\n"


# -----------------------------------------------------------------------------
# Named arguments in every order. Arguments are evaluated in the order they
# are written and passed in the order the parameters are declared
# (docs/INTERNALS.md, "Evaluation order of arguments"): one argument writes
# what another views, written first or second, in a function, a method, and
# a generic function. A view that is a loan (a ?String, a `?String`, a slice) is
# rejected when written before the write; a copy of a number is not, and
# shows the value before the write. Written after the write, every view
# shows what the write left. Cells are `named.<call>.<kind>.<order>`.
# -----------------------------------------------------------------------------

NAMED_KINDS = {
    # kind: (setup, view argument, parameter type, what the sub prints of it, view after the write,
    #        view before the write, writer argument, writer result, loan)
    "string": ("t = String(\"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ\")", "?t", "?String", "v.len > 8000", "true", "false", "grow(!t)", "1", True),
    "qtext": ("t = String(\"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ\")", "?t", "?String", "v.len > 8000", "true", "false", "grow(!t)", "1", True),
    "slice": ("t: List[Int] = List()\n!t.push(1)", "?t", "[]Int", "v.len", "301", "1", "fill(!t)", "1", True),
    "int": ("t = 1", "?t", "Int", "v", "11", "1", "bump(!t)", "11", False),
}
NAMED_CALLS = ("fun", "method", "generic")
NAMED_ORDERS = ("decl", "swap")


def named_program(call, kind, order):
    """The program for one named-arguments cell, and what it prints (None: rejected)."""
    setup, view, ptype, observe, after, before, writer, wres, loan = NAMED_KINDS[kind]
    if call == "generic" and kind != "int":
        return None, None
    lines = [
        "fun grow(t: !String) -> Int", "  for _ in 0..200", '    !t.add("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")', "  1", "",
        "fun fill(v: !List[Int]) -> Int", "  for i in 0..300", "    !v.push(i)", "  1", "",
        "fun bump(n: !Int) -> Int", "  n += 10", "  n", "",
    ]
    if call == "fun":
        lines += [f"sub show(v: {ptype}, w: Int)", f"  print({observe}, w)", ""]
        callee = "show"
    elif call == "method":
        lines += ["obj M", "  k: Int", "", f"  sub show(?self, v: {ptype}, w: Int)", f"    print({observe}, w)", ""]
        callee = "m.show"
    else:
        lines += ["sub show[T](v: T, w: Int)", "  print(v, w)", ""]
        callee = "show"
    lines += ["sub main()", "  " + setup.replace("\n", "\n  ")]
    if call == "method":
        lines.append("  m = M(k: 0)")
    args = [f"v: {view}", f"w: {writer}"]
    if order == "swap":
        args.reverse()
    lines.append(f"  {callee}({', '.join(args)})")
    src = "\n".join(lines) + "\n"
    if order == "decl":
        if loan:
            return src, None
        return src, f"{before} {wres}\n"
    return src, f"{after} {wres}\n"


# -----------------------------------------------------------------------------
# An assignment whose target's path starts from a value that changes what
# the assignment's value reads: a call that writes `i`, a method of a lent
# receiver, a propagation of an optional or a failure, a branch whose
# condition writes `i`, or a call that takes the List `x` the value reads.
# An assignment evaluates its value, then its target from the base of its
# path outward, then stores (docs/INTERNALS.md, "Assignments"), so the
# value reads `i` or `x` as they were. Each path is a field, an element,
# or an element whose index is a call; each value reads plainly, through
# an index, or with a call of its own. Each cell must be accepted and
# print what that order stores, in debug and with `--release`.
# Cells are `order.<root>.<path>.<op>.<value>`; `order.leave.<step>.<fail>`
# makes an owned value, then a step of its target leaves (`?`, `!`) or
# not, and must print the same either way, with nothing leaked.
# -----------------------------------------------------------------------------

# Each root: the target's base, the read `R` of what it changes, and the
# function the assignment stands in (`sub`, or one returning `Int?` or
# `Int!` for a propagation).
ORDER_ROOTS = {
    "call": dict(base="pick(!p, !i)", read="i", fn="sub"),
    "method": dict(base="(!p).at(!i)", read="i", fn="sub"),
    "slice": dict(base="pick_s(!p.v[..], !i)", read="i", fn="sub"),
    "opt": dict(base="pick_opt(!p, !i)?", read="i", fn="opt"),
    "err": dict(base="pick_err(!p, !i)!", read="i", fn="err"),
    "branch": dict(base="(!p if bump(!i) else !q)", read="i", fn="sub"),
    "take": dict(base="take(<x, !p)", read="x[0]", fn="sub"),
}
# Each path from the base, and which element of `p` it reaches (None: the field `n`).
ORDER_PATHS = {"field": (".n", None), "elem": (".v[0]", 0), "elem_call": (".v[id(1)]", 1)}
ORDER_OPS = {"set": ("=", lambda old, v: v), "add": ("+=", lambda old, v: old + v), "shl": ("<<=", lambda old, v: old << v)}
# Each value, with `R` the read, and what it gives when `R` reads 1.
ORDER_VALUES = {"plain": ("R", 1), "index": ("s[R]", 20), "call": ("R + id(0)", 1)}
ORDER_LEAVES = {
    "root_opt": dict(stmt="pick_h(!h, fail)?.l = <w", fn="opt", show="h.l.len"),
    "root_err": dict(stmt="pick_he(!h, fail)!.l = <w", fn="err", show="h.l.len"),
    "index_opt": dict(stmt="a[slot(fail)?] = <w", fn="opt", show="a[0].len"),
    "index_err": dict(stmt="a[slot_e(fail)!] = <w", fn="err", show="a[0].len"),
}
ORDER_DECLS = """error E
  bad

obj P
  n: Int
  v: [2]Int

  fun at(self: !P, k: !Int) -> !P
    k += 1
    self

obj H
  l: List[Int]

fun pick(p: !P, k: !Int) -> !P
  k += 1
  p

fun pick_s(t: ![]Int, k: !Int) -> ![]Int from t
  k += 1
  t

fun pick_opt(p: !P, k: !Int) -> (!P)?
  k += 1
  !p

fun pick_err(p: !P, k: !Int) -> (!P)!
  k += 1
  !p

fun bump(k: !Int) -> Bool
  k += 1
  true

fun take(xs: List[Int], p: !P) -> !P
  p

fun id(n: Int) -> Int
  n

fun pick_h(h: !H, fail: Bool) -> (!H)?
  if fail
    return none
  !h

fun pick_he(h: !H, fail: Bool) -> (!H)!
  return E.bad if fail
  !h

fun slot(fail: Bool) -> Int?
  if fail
    return none
  0

fun slot_e(fail: Bool) -> Int!
  return E.bad if fail
  0
"""


def order_fn(fn, body, call):
    """`run` holding `body`, and `main`'s lines calling it with `call`."""
    head = {"sub": "sub run(" + call + ")", "opt": "fun run(" + call + ") -> Int?", "err": "fun run(" + call + ") -> Int!"}[fn]
    tail = [] if fn == "sub" else ["0"]
    return head + "\n" + indent(body + tail, 2) + "\n"


def order_program(root, path, op, value):
    """The program for one order cell and what it prints, or (None, None)
    where the path cannot follow the root."""
    r = ORDER_ROOTS[root]
    step, elem = ORDER_PATHS[path]
    if root == "slice":
        if elem is None:
            return None, None
        step = step[2:]
    v_src, v = ORDER_VALUES[value]
    body = ["p = P(n: 5, v: [5, 5])"]
    body += ["q = P(n: 5, v: [5, 5])"] if root == "branch" else []
    body += ["x: List[Int] = List()", "!x.push(1)"] if root == "take" else ["i = 1"]
    body += ["s: [3]Int = [10, 20, 30]"] if value == "index" else []
    sigil, combine = ORDER_OPS[op]
    body += [f"{r['base']}{step} {sigil} {v_src.replace('R', r['read'])}", "print(p)"]
    stored = combine(5, v)
    n, vs = (stored, [5, 5]) if elem is None else (5, [stored if k == elem else 5 for k in range(2)])
    main = "run()" if r["fn"] == "sub" else ("_ = run()" if r["fn"] == "opt" else "_ = run() catch 0")
    src = ORDER_DECLS + "\n" + order_fn(r["fn"], body, "") + "\nsub main()\n  " + main + "\n"
    return src, f"P(n: {n}, v: [{vs[0]}, {vs[1]}])\n"


def order_leave_program(step, fail):
    """The program for one leave cell and what it prints."""
    lv = ORDER_LEAVES[step]
    body = ["h = H(l: List())"] if step.startswith("root") else ["a: [2]List[Int] = [List(), List()]"]
    body += ["w: List[Int] = List()", "!w.push(1)", "!w.push(2)", lv["stmt"], f"print({lv['show']})"]
    main = "_ = run(" + fail + ")" + (" catch 0" if lv["fn"] == "err" else "")
    src = ORDER_DECLS + "\n" + order_fn(lv["fn"], body, "fail: Bool") + "\nsub main()\n  " + main + '\n  print("done")\n'
    return src, ("done\n" if fail == "true" else "2\ndone\n")


# -----------------------------------------------------------------------------
# A place built over a sub-expression that writes its root (`rootidx.`).
# Cells are `rootidx.<shape>.<site>.<writer>`: a place reaching an Int
# element 5 at index `K`, `K` a call that writes the place's root (`root`,
# which grows or replaces the storage the place is in and leaves the
# element 5 in the new storage), another root of the same type (`other`),
# or reads the root (`read`), and the place used at a site. A lend, a
# slice, or a receiver finds the place up to each index before the index
# runs, so a `root` writer there is rejected; so does a read, which is
# rejected only where the List the index applies to lies outside the
# root's own storage (`stays` is false): elsewhere it is found where it
# was and the element read after the index runs. An assignment finds its
# target after its indexes run, so there a `root` writer is accepted and
# the store lands in the storage it left.
# -----------------------------------------------------------------------------

# Each shape: its declarations' root type, the root's setup, the place
# with `K` its last index, the List the place indexes (`B`), whether that
# List lies in the root's own storage, the writer's body, which replaces
# that List's storage (or re-points the handle), and the sites it can
# stand at, when not every one.
ROOTIDX_SHAPES = {
    "list": dict(ty="List[Int]", init=["R: List[Int] = List()", "!R.push(5)"], place="R[K]", base="R", stays=True,
                 grow=["for _ in 0..100", "  !r.push(0)"]),
    "nested": dict(ty="List[List[Int]]", init=["R: List[List[Int]] = List()", "!R.push(List())", "!R[0].push(5)"],
                   place="R[0][K]", base="R[0]", stays=False, grow=["for _ in 0..100", "  !r.push(List())"]),
    "array": dict(ty="[2]List[Int]", init=["R: [2]List[Int] = [List(), List()]", "!R[0].push(5)"],
                  place="R[0][K]", base="R[0]", stays=True, grow=["n: List[Int] = List()", "!n.push(5)", "r[0] = <n"]),
    "elemfield": dict(ty="P", init=["R = P(qs: List(), bx: ^Q(vals: List()))", "!R.qs.push(Q(vals: List()))", "!R.qs[0].vals.push(5)"],
                      place="R.qs[0].vals[K]", base="R.qs[0].vals", stays=False, grow=["for _ in 0..100", "  !r.qs.push(Q(vals: List()))"]),
    "box": dict(ty="P", init=["R = P(qs: List(), bx: ^Q(vals: List()))", "!R.bx.vals.push(5)"],
                place="R.bx.vals[K]", base="R.bx.vals", stays=False, grow=["n: List[Int] = List()", "!n.push(5)", "r.bx = ^Q(vals: <n)"]),
    "listbox": dict(ty="List[^Q]", init=["R: List[^Q] = List()", "!R.push(^Q(vals: List()))", "!R[0].vals.push(5)"],
                    place="R[0].vals[K]", base="R[0].vals", stays=False,
                    grow=["n: List[Int] = List()", "!n.push(5)", "r[0] = ^Q(vals: <n)", "for _ in 0..100", "  !r.push(^Q(vals: List()))"]),
    "handle": dict(ty="*List[Int]", init=["R = *mk()"], place="R[K]", base="R", stays=False,
                   grow=["r = *mk()"], sites=("bind", "print", "cond", "arg", "view", "recv")),
}
# Each site: the lines using the place (`X`) or its List (`B`), what it
# prints, and when it finds the place: before its index runs (`before`),
# as a read does (`read`), or after (`after`).
ROOTIDX_SITES = {
    "bind": (["x = X", "print(x)"], "5", "read"),
    "print": (["print(X)"], "5", "read"),
    "cond": (["if X == 5", '  print("yes")'], "yes", "read"),
    "arg": (["show(X)"], "5", "read"),
    "view": (["print(peek(?X))"], "5", "before"),
    "lend": (["set9(!X)", "print(X0)"], "9", "before"),
    "slice": (["print(?B[0..K + 1])"], "[5]", "before"),
    "recv": (["print(B.get(K))"], "5", "before"),
    "wrecv": (["!B.insert(K, 7)", "print(B)"], "[7, 5]", "before"),
    "assign": (["X = 9", "print(X0)"], "9", "after"),
    "compound": (["X += 7", "print(X0)"], "12", "after"),
    "value": (["X0 += K", "print(X0)"], "5", "after"),
}
ROOTIDX_WRITERS = {"root": "wr(!R)", "other": "wr(!o)", "read": "rd(?R)"}


def rootidx_program(shape, site, writer):
    """The program for one rootidx cell and what it prints."""
    sh = ROOTIDX_SHAPES[shape]
    if site not in sh.get("sites", ROOTIDX_SITES):
        return None, None
    lines, prints, found = ROOTIDX_SITES[site]
    k = ROOTIDX_WRITERS[writer]
    decls = ["obj Q", "  vals: List[Int]", "", "obj P", "  qs: List[Q]", "  bx: ^Q", ""]
    decls += [f"fun wr(r: !{sh['ty']}) -> Int"] + ["  " + g for g in sh["grow"]] + ["  0", ""]
    decls += [f"fun rd(r: ?{sh['ty']}) -> Int", "  0", ""]
    decls += ["fun mk() -> List[Int]", "  n: List[Int] = List()", "  !n.push(5)", "  n", ""]
    decls += ["fun peek(n: ?Int) -> Int", "  n", "", "sub show(n: Int)", "  print(n)", "", "sub set9(n: !Int)", "  n = 9", ""]
    body = [l.replace("R", "o") for l in sh["init"]] if writer == "other" else []
    body += sh["init"]
    place = sh["place"].replace("K", k)
    for line in lines:
        line = line.replace("X0", sh["place"].replace("K", "0")).replace("X", place)
        body.append(line.replace("B", sh["base"]).replace("K", k))
    body = [l.replace("R", "t") for l in body]
    src = "\n".join(decls) + "\nsub main()\n" + indent(body, 2) + "\n"
    rejected = writer == "root" and (found == "before" or found == "read" and not sh["stays"])
    return src, "(rejected)\n" if rejected else prints + "\n"


# Disjoint field loans (Core sentence 5, §5 "A field is a place of its
# own"): a first loan on `X.a` (`r = ?X.a` or `w = !X.a`), used again
# after a second use of a place of the same value, in a context, past an
# exit. The places (`FIELD_ROOTS`): a struct's fields, a nested struct's,
# a field reached through a read-view field (whose loan is the view's,
# not the holder's), `self`'s in a `!self` method, and a box's. The
# second use is a read lend, a write lend, a take (`<X.o`), or an
# assignment, of a sibling (`sib`: `X.b`, `X.o`), the same field
# (`same`), or the whole value (`parent`). The contexts: straight line,
# a loop whose back edge carries the first loan, and a closure, whose
# capture uses the whole name. The exits: fall-through, `return`,
# `break`, `continue`, `!`, and a failing `if … as` guard. A cell the
# rule accepts must run and print what the simulation says; any other
# must be rejected.
FIELD_ROOTS = {
    # X: the value the first loan is a field of; Y: the value the second
    # use is of (`h` holds the read view the first loan goes through);
    # cap: the name a closure captures.
    "field": dict(make=['x = P(a: String("a"), b: String("b"), o: String("o"), n: 1)'], X="x", Y="x", cap="x", again='x = P(a: String("a"), b: String("B"), o: String("o"), n: 1)'),
    "nested": dict(make=['x = Outer(i: P(a: String("a"), b: String("b"), o: String("o"), n: 1), m: 0)'], X="x.i", Y="x.i", cap="x", again='x.i = P(a: String("a"), b: String("B"), o: String("o"), n: 1)'),
    "readview": dict(make=['src = P(a: String("a"), b: String("s"), o: none, n: 0)', 'x = H(r: ?src, b: String("b"), o: String("o"), n: 1)'], X="x.r", Y="x", cap="x", again='x = H(r: ?src, b: String("B"), o: String("o"), n: 1)', viewed=True),
    "self": dict(make=[], X="self", Y="self", cap="self", again='self = P(a: String("a"), b: String("B"), o: String("o"), n: 1)'),
    "box": dict(make=['x = ^P(a: String("a"), b: String("b"), o: String("o"), n: 1)'], X="x", Y="x", cap="x", again='x = ^P(a: String("a"), b: String("B"), o: String("o"), n: 1)'),
}
FIELD_FIRSTS = ("read", "write")
FIELD_RELS = ("sib", "same", "parent")
FIELD_SECONDS = ("read", "write", "take", "assign")
FIELD_CONTEXTS = ("straight", "loop", "closure")
FIELD_EXITS = ("fall", "return", "break", "continue", "propagate", "guard")
FIELD_DECLS = """error E
  bad

obj P
  a: String
  b: String
  o: String?
  n: Int

obj Outer
  i: P
  m: Int

obj H
  r: ?P
  b: String
  o: String?
  n: Int

sub touch(p: !P)
  !p.b.add("2")

sub touch_h(h: !H)
  !h.b.add("2")

fun check(k: Int) -> Int!
  return E.bad if k == 1
  k

fun some(k: Int) -> Int?
  if k == 1
    return none
  k
"""


def field_second(root, rel, second):
    """The statement of a second use, and what it does to the simulated
    state (`a`, `b`, `o`, and the lines it prints); None where the form
    cannot stand."""
    r = FIELD_ROOTS[root]
    Y = r["Y"]
    if rel == "sib":
        return {
            "read": ([f"y = ?{Y}.b", "print(y)"], lambda s: s["out"].append(s["b"])),
            "write": ([f"!{Y}.b.add(\"2\")"], lambda s: s.update(b=s["b"] + "2")),
            "take": ([f"t = <{Y}.o", "print(t)"], lambda s: (s["out"].append(s["o"] or "none"), s.update(o=None))),
            "assign": ([f'{Y}.b = String("B")'], lambda s: s.update(b="B")),
        }[second]
    if rel == "same":
        # The first loan's own field; a field that is not optional is
        # never taken, and nothing is written through a read view.
        X = r["X"]
        if r.get("viewed") and second != "read":
            return None
        return {
            "read": ([f"y = ?{X}.a", "print(y)"], lambda s: s["out"].append(s["a"])),
            "write": ([f"!{X}.a.add(\"2\")"], lambda s: s.update(a=s["a"] + "2")),
            "take": None,
            "assign": ([f'{X}.a = String("A")'], lambda s: s.update(a="A")),
        }[second]
    # The whole value the second use is of.
    touch = "touch_h" if r.get("viewed") else "touch"
    return {
        "read": ([f"y = ?{Y}", "print(y.b)"], lambda s: s["out"].append(s["b"])),
        "write": ([f"{touch}(!{Y})"], lambda s: s.update(b=s["b"] + "2")),
        "take": None,
        "assign": ([r["again"]], lambda s: s.update(b="B")),
    }[second]


def field_accepts(root, first, rel, second, ctx):
    """Whether the rule accepts the cell: the second use touches a place
    that overlaps the first loan's only where it is the same field or the
    whole value, or a closure captures the whole name; through a read-view
    field the first loan is the view's, and touches nothing of `x`."""
    if FIELD_ROOTS[root].get("viewed"):
        return True
    if ctx == "closure" or rel != "sib":
        return first == "read" and second == "read"
    return True


def field_program(root, first, rel, second, ctx, ex):
    """The program for one field-loan cell, and what it prints (or
    `(rejected)`); (None, None) where the form cannot stand."""
    r = FIELD_ROOTS[root]
    if r.get("viewed") and first == "write":
        return None, None  # a write lend through a read view is a type error
    if ex in ("break", "continue") and ctx != "loop":
        return None, None
    if ctx == "closure" and ex != "fall":
        return None, None
    if rel != "sib" and (ctx == "closure" or ex != "fall"):
        return None, None
    sec = field_second(root, rel, second)
    if sec is None:
        return None, None
    stmts, effect = sec
    X = r["X"]
    take_first = [f"r = ?{X}.a"] if first == "read" else [f"w = !{X}.a"]
    use_first = ["print(r)"] if first == "read" else ['!w.add("+")']
    after_first = [] if first == "read" else [f"print({X}.a)"]
    final = [f"print({r['Y']}.b)"]
    exit_lines = {
        "fall": [], "guard": [],
        "return": ["if k == 1", "  return 1"],
        "break": ["if k == 1", "  break"],
        "continue": ["if k == 1", "  continue"],
        "propagate": ["_ = check(k)!"],
    }[ex]
    second_lines = (["if some(k) as _"] + ["  " + l for l in stmts]) if ex == "guard" else stmts
    if ctx == "closure":
        cap = ("?" if second == "read" else "!") + r["cap"]
        middle = [f"f = |{cap}|"] + ["  " + l for l in stmts] + ["f()"]
    elif ctx == "loop":
        middle = ["for _ in 0..2"] + ["  " + l for l in second_lines + exit_lines + use_first]
    else:
        middle = second_lines + exit_lines + use_first
    body = list(r["make"]) + take_first + middle + (use_first if ctx == "closure" else []) + after_first + final + ["0"]
    if root == "self":
        decls = FIELD_DECLS.replace("obj P\n  a: String\n  b: String\n  o: String?\n  n: Int\n", "obj P\n  a: String\n  b: String\n  o: String?\n  n: Int\n\n  fun run(!self, k: Int) -> Int!\n" + indent(body, 4) + "\n")
        call = ['x = P(a: String("a"), b: String("b"), o: String("o"), n: 1)', "n = (!x).run(k) catch 9"]
    else:
        decls = FIELD_DECLS + "\nfun run(k: Int) -> Int!\n" + indent(body, 2) + "\n"
        call = ["n = run(k) catch 9"]
    src = decls + "\nsub main()\n  for k in 0..2\n" + indent(call + ["print(n)"], 4) + "\n"
    if not field_accepts(root, first, rel, second, ctx):
        return src, "(rejected)\n"
    # Simulate both calls.
    out = []
    for k in (0, 1):
        s = {"a": "a", "b": "b", "o": "o", "out": out}
        result = 0

        def step(s=s):
            """The second use, its exit, and the first view's use: what
            the exit does (None, `return`, `fail`, `break`, `continue`)."""
            if not (ex == "guard" and k == 1):
                effect(s)
            if k == 1 and ex in ("return", "break", "continue"):
                return ex
            if k == 1 and ex == "propagate":
                return "fail"
            if first == "read":
                s["out"].append(s["a"])
            else:
                s["a"] += "+"
            return None
        how = None
        if ctx == "loop":
            for _ in range(2):
                how = step()
                if how == "continue":
                    how = None
                    continue
                if how == "break":
                    how = None
                    break
                if how is not None:
                    break
        elif ctx == "closure":
            effect(s)
            if first == "read":
                s["out"].append(s["a"])
            else:
                s["a"] += "+"
        else:
            how = step()
        if how == "return":
            result = 1
        elif how == "fail":
            result = 9
        else:
            if first == "write":
                s["out"].append(s["a"])
            s["out"].append(s["b"])
        out.append(str(result))
    return src, "".join(line + "\n" for line in out)


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
    fallible = t.get("fallible", True)
    if not fallible and (fname == "catch" or ctx.get("tail") == "catch"):
        return None
    if "tail" in ctx:
        if fname != "call" or tname in ("int", "string", "static", "plain", "array", "simd"):
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
    if fallible:
        out.append(f"fun fail(c: Bool) -> {fal(ty)}\n  return E.bad if c\n  mk(7)\n")
    out.append(f"fun look(x: {rd(ty)}) -> Int\n  1\n")
    if fname in VIEW_FORMS and ("decl" in ctx or "tail" in ctx):
        return None
    if "decl" in ctx:
        if isinstance(form, list):
            return None
        out.append(ctx["decl"].replace("@T?", opt(ty)).replace("@T", ty).replace("E", form))
    out.append(f"obj H\n  f: {ty}\n")
    returns = ctx.get("returns", False)
    needs = ctx.get("needs")
    if needs == "vs":
        # Calls that grow the List an element assignment stores into.
        out.append(f"fun through(v: !List[{ty}], x: {ty}) -> {ty}\n  for i in 0..100\n    !v.push(mk(i))\n  x\n")
        out.append(f"fun grow(v: !List[{ty}]) -> Int\n  for i in 0..100\n    !v.push(mk(i))\n  0\n")
    if ctx.get("temp"):
        out.append(f"fun pass_t(x: {ty}, t: ?String) -> {ty}\n  x\n")
        out.append(f"fun some_t(x: {ty}, t: ?String) -> {opt(ty)}\n  x\n")
    if ctx.get("slice"):
        view = "?String" if tname in ("text", "string", "static") else "[]Int"
        out.append(f"fun sliced(x: {view}) -> Int\n  x.len\n")
        out.append(f"fun both(x: {view}, k: Int) -> Int\n  x.len + k\n")
    if ctx.get("write"):
        out.append(f"fun poke(x: !{ty}) -> Int\n  {POKES[tname]}\n  0\n")
        out.append(f"fun pokev(x: !{ty}) -> {ty}\n  n = poke(!x)\n  mk(n + 9)\n")
    ret_ty = opt(ty) if returns else "Int?"
    if ctx.get("optional"):
        body = [f"a: {opt(ty)} = mk(1)", f"b: {opt(ty)} = mk(2)", "print(a == none, b == none)"]
    else:
        body = [f"a: {ty} = mk(1)", f"b: {ty} = mk(2)", "print(look(?a), look(?b))"]
    if needs == "h" or fname == "field":
        body += [f"h = H(f: mk(3))", "print(look(?h.f))"]
    if needs == "vs":
        body += [f"vs: List[{ty}] = List()", "!vs.push(mk(4))"]
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
        # A slice's object is a path, or in parentheses.
        if ctx.get("slice") and not re.fullmatch(r"[\w.]+", e):
            e = f"({e})"
        body.append(text.replace("E", e))
    if "after" in ctx:
        after = ctx["after"]
        if ctx.get("write"):
            after = after.replace("!W", "!" + WRITE_TARGETS.get(fname, "a"))
        body.append(after)
    if not returns:
        body.append("0")
    if ctx.get("results"):
        ret_ty = f"({ty}, {ty})"
        main = ["for c in [true, false]", "  p, q = run(c, mk(9))", "  print(look(?p), look(?q))"]
    else:
        main = ["for c in [true, false]", "  r = run(c, mk(9))", "  print(r == none)"]
    called = set(re.findall(r"\b(\w+)\(", "\n".join(body)))
    for name, text in RESULT_FUNS.items():
        if name in called:
            out.append(text.format(t=ty, r=rd(ty)))
    out.append(f"fun run(c: Bool, o: {opt(ty)}) -> {ret_ty}\n{indent(body, 2)}\n")
    out.append("sub main()\n" + indent(main, 2) + "\n")
    return "\n".join(out)


# -----------------------------------------------------------------------------
# Proven checks (`proof.`): a guard, a write between it and a use, and the
# use (docs/INTERNALS.md, "Proven checks"). Each cell's `--facts=proofs`
# entry at its use must be what PROOF_USES says the guard's facts, less
# what the write ends, prove: a positive copy of the pass's rules, kept
# apart from them so the two cannot drift together. Each cell starts `i`
# where the use is in range exactly when the write does not move it, so a
# write that ends a fact the use needs makes the cell panic with the
# test's own message, in debug and with `--release`; a debug run that
# reaches a proven test that fails panics with "rig: a proven check
# failed", which fails the cell.
# -----------------------------------------------------------------------------

PROOF_LEN, PROOF_SHORT = 12, 2

# name: (how it holds, its text, the facts on its true edge, the width it
# leaves room for). `fits` is `s.len <= max_len`, which a length read
# shows.
PROOF_GUARDS = {
    "while_lt": ("while", "i < s.len", dict(nonneg=False, below=1, fits=True), 1),
    "if_lt": ("if", "i < s.len", dict(nonneg=False, below=1, fits=True), 1),
    "while_le8": ("while", "i + 8 <= s.len", dict(nonneg=False, below=8, fits=True), 8),
    "if_le8": ("if", "i + 8 <= s.len", dict(nonneg=False, below=8, fits=True), 8),
    "if_nonneg": ("if", "0 <= i and i < s.len", dict(nonneg=True, below=1, fits=True), 1),
    "check": ("stmt", "c = s[i]", dict(nonneg=True, below=1, fits=False), 1),
    "if_gt": ("if", "s.len > i", dict(nonneg=False, below=1, fits=True), 1),
    # `+%` and `or` make no fact (the wrapping guard still reads s.len).
    "while_wrap": ("while", "i +% 8 <= s.len", dict(nonneg=False, below=None, fits=True), 8),
    "if_or": ("if", "i < s.len or flag", dict(nonneg=False, below=None, fits=False), 1),
}

# name: (lines before the use, with `U` where the use goes if it is inside
# them; what the write does to the facts; how it moves `i`: "+1", "len",
# "repoint", or "loop", where the use runs at `i` and then `i + 1`).
_moved = dict(below=None)
PROOF_MUTATIONS = {
    "none": ([], {}, None),
    "add": (["i += 1"], _moved, "+1"),
    "add_assign": (["i = i + 1"], _moved, "+1"),
    "len": (["i = s.len"], dict(below=None, nonneg=True, fits=True), "len"),
    "bump": (["bump(!i)"], dict(below=None, nonneg=False), "+1"),
    "closure": (["f = |!i| i += 1", "f()"], dict(below=None, nonneg=False), "+1"),
    "defer": (["if flag", "  defer i += 1"], _moved, "+1"),
    "value": (["out[0] = next(!i)"], dict(below=None, nonneg=False), "+1"),
    "repoint": (["REPOINT"], dict(below=None, fits=False), "repoint"),
    "branch": (["if flag", "  i += 1"], _moved, "+1"),
    "arm": (["match k", "  1 => i += 1", "  _ => pass"], _moved, "+1"),
    "loop": (["m = 0", "while m < 2", "  U", "  i += 1", "  m += 1"], _moved, "loop"),
    "raw": (["raw", "  i += 1"], dict(below=None, nonneg=False, fits=False), "+1"),
    "shadow": (["new i = i + 1"], dict(below=None, nonneg=False), "+1"),
    "step": (["m = 0", "while m < 2 : i += 1", "  m += 1", "  U", "  continue"], _moved, "loop"),
}

# name: (the use as a statement, the node it is (`L:C KIND`'s kind), the
# text the node starts with, the width it reads or writes (None: an add,
# which cannot overflow here), whether it writes `s`, the expression it is
# right of `and` (None: it is a statement), and the panic its own test
# makes.
PROOF_USES = {
    "index": ("print(s[i])", "index", "s[i]", 1, False, "s[i] != 255", "index out of bounds"),
    "index_set": ("s[i] = 7", "index", "s[i]", 1, True, None, "index out of bounds"),
    "read": ("print(s.read[U64, .little](i))", "read", "s.read", 8, False, "s.read[U64, .little](i) != 0", "byte read out of range"),
    "write": ("!s.write[U32, .little](i, 0x01020304)", "write", "s.write", 4, True, None, "byte write out of range"),
    "simd": ("print(s.read[Simd[U8, 8]](i)[0])", "read", "s.read", 8, False, "s.read[Simd[U8, 8]](i)[0] != 0", "byte read out of range"),
    "simd_write": ("!s.write[Simd[U8, 4]](i, Simd[U8, 4].splat(9))", "write", "s.write", 4, True, None, "byte write out of range"),
    "add": ("print(i + 1)", "+", "i + 1", None, False, "i + 1 > 0", None),
    "add_set": ("i += 1", "+=", "i += 1", None, False, None, None),
    "add8": ("print(i + 8)", "+", "i + 8", None, False, "i + 8 > 0", None),
    # `w = four(k)` before the guard: `four` bounds `w.size` by 4.
    "add_field": ("print(i + w.size)", "+", "i + w.size", None, False, "i + w.size > 0", None),
    "add_field_set": ("i += w.size", "+=", "i += w.size", None, False, None, None),
}
PROOF_PLACES = ("straight", "nested", "and")


def proof_tests(facts, uname):
    """The tests the use's node has proven under `facts` (docs/INTERNALS.md,
    "Proven checks"): an index or a byte access, `0 <= i` and room for its
    width; an add of `c`, room for `c`, or any room below a length that
    fits; an add of a field its function bounds by 4, as an add of 4."""
    _, kind, _, width, _, _, _ = PROOF_USES[uname]
    below = facts["below"]
    if width is not None:
        tests = []
        if facts["nonneg"]:
            tests.append("lower")
        if below is not None and below >= width:
            tests.append("upper")
        return tests
    c = {"add8": 8, "add_field": 4, "add_field_set": 4}.get(uname, 1)
    return ["no_overflow"] if below is not None and (below >= c or facts["fits"]) else []


def proof_program(gname, mname, uname, place, deep=False):
    """A `proof.` cell: the program, what it prints, the panic it must make
    (None: it runs clean), and the `--facts=proofs` entry at its use
    (None: there is none). None where the form cannot stand, and, but with
    `deep`, for a write with its use anywhere but straight after it."""
    ghow, gtext, gfacts, groom = PROOF_GUARDS[gname]
    mlines, meffect, mmove = PROOF_MUTATIONS[mname]
    ustmt, ukind, ustart, uwidth, uwrites, uexpr, upanic = PROOF_USES[uname]
    if place != "straight" and mname != "none" and not (deep and place == "nested"):
        return None
    if place == "and" and (uexpr is None or ghow == "stmt"):
        return None
    L = PROOF_LEN
    # The largest start the guard and the unmoved use both allow.
    at = L - max(groom, uwidth or 1)
    text = "?String" if not uwrites else "![]U8"
    sig = [f"t: {text}"]
    if mname == "repoint":
        sig.append(f"u: {text}")
    if mname == "value":
        sig.append("out: ![]Int")
    sig += ["at: Int", "flag: Bool", "k: Int"]
    body = ["s = t" if not uwrites else "s = <t", "i = at"]
    if uname.startswith("add_field"):
        body.append("w = four(k)")
    # `i += 1` is followed by a read of `i`, which it would otherwise leave
    # unread.
    # The use's line is marked with a NUL until its place is known.
    stmts = ["\0" + ustmt] + (["print(i)"] if uname in ("add_set", "add_field_set") else [])
    use = [uexpr] if place == "and" else stmts
    if place == "nested":
        use = ["if flag"] + ["  " + x for x in stmts]
    inner = []
    if mlines and any(l.strip() == "U" for l in mlines):
        for l in mlines:
            if l.strip() == "U":
                pad = l[: len(l) - len(l.lstrip())]
                inner += [pad + u for u in use]
            else:
                inner.append(l)
    else:
        repoint = "s = u" if not uwrites else "s = <u"
        inner = [repoint if l == "REPOINT" else l for l in mlines] + use
    out = []
    if ghow == "stmt":
        body += [gtext, "print(c)"] + inner
        out.append(str(ord("a") + at) if not uwrites else "0")
    elif place == "and":
        head = f"\0{ghow} {gtext} and {uexpr}"
        body += [head, '  print("ok")'] + (["  break"] if ghow == "while" else [])
    else:
        body += [f"{ghow} {gtext}"] + ["  " + l for l in inner] + (["  break"] if ghow == "while" else [])
    # Where the use's node starts.
    needle = uexpr if place == "and" else ustmt
    line_no = col = None
    for n, l in enumerate(body):
        if "\0" in l:
            l = body[n] = l.replace("\0", "")
            line_no, col = n, l.index(needle) + needle.index(ustart) + 1
    # What runs: the values of `i` where the use runs, and the view's length.
    # What runs: `i` where the use runs, once, or twice in a loop that
    # adds one after it, and the length of the view.
    i = {"+1": at + 1, "len": L}.get(mmove, at)
    length = PROOF_SHORT if mmove == "repoint" else L
    data = "abcdefghijkl"
    prints = [out[0]] if ghow == "stmt" else []
    panic = None
    buf = [0] * L
    for _ in range(2 if mmove == "loop" else 1):
        if uwidth is not None and (i < 0 or i + uwidth > length):
            panic = upanic
            break
        if place == "and":
            prints.append("ok")
        elif uname == "index":
            prints.append(str(ord(data[i])))
        elif uname == "read":
            prints.append(str(int.from_bytes(data[i:i + 8].encode(), "little")))
        elif uname == "index_set":
            buf[i] = 7
        elif uname == "write":
            buf[i:i + 4] = [4, 3, 2, 1]
        elif uname == "simd":
            prints.append(str(ord(data[i])))
        elif uname == "simd_write":
            buf[i:i + 4] = [9, 9, 9, 9]
        elif uname == "add":
            prints.append(str(i + 1))
        elif uname == "add8":
            prints.append(str(i + 8))
        elif uname == "add_set":
            i += 1
            prints.append(str(i))
        elif uname == "add_field":
            prints.append(str(i + 4))
        elif uname == "add_field_set":
            i += 4
            prints.append(str(i))
        i += 1
    if uwrites and panic is None:
        prints.append("[" + ", ".join(map(str, buf)) + "]")
    expect = "".join(x + "\n" for x in prints)
    facts = dict(gfacts)
    facts.update(meffect)
    tests = proof_tests(facts, uname)
    src = ["sub bump(n: !Int)", "  n += 1", "", "fun next(n: !Int) -> Int", "  n += 1", "  7", ""]
    if uname.startswith("add_field"):
        src += ["obj W", "  size: Int", "", "fun four(k: Int) -> W", "  return W(size: 4) if k > 0", "  W(size: 0)", ""]
    src.append(f"sub probe({', '.join(sig)})")
    first = len(src) + 1
    src += ["  " + l for l in body]
    src.append("")
    src.append("sub main()")
    args = []
    if not uwrites:
        args.append(f'"{data}"')
        if mname == "repoint":
            args.append(f'"{data[:PROOF_SHORT]}"')
    else:
        src.append(f"  a: [{L}]U8 = [{L} of 0]")
        args.append("!a[..]")
        if mname == "repoint":
            src.append(f"  b: [{PROOF_SHORT}]U8 = [{PROOF_SHORT} of 0]")
            args.append("!b[..]")
    if mname == "value":
        src.append("  o = [0]")
        args.append("!o[..]")
    args += [str(at), "true", "1"]
    src.append(f"  probe({', '.join(args)})")
    if uwrites:
        src.append("  print(a)")
    at_use = f"{first + line_no}:{col + 2}"
    entry = f"{at_use} {ukind} {' '.join(tests)}" if tests else None
    return "\n".join(src) + "\n", expect, panic, (at_use, ukind), entry


def proof_dump_at(dump, at, kind):
    """The `--facts=proofs` entries of `kind` at `at` (`L:C`)."""
    return [l for l in dump.splitlines() if l.startswith("%s %s " % (at, kind))]


def run_proof(path, keep, started_dir, cell):
    """Classify one `proof.` cell: the checker accepts it, `--facts=proofs`
    lists exactly the tests the cell's table proves at its use, and it
    runs as it must in debug and with `--release`: clean, printing what it
    must, or panicking with its use's own message."""
    expect, panic, (line, kind), entry = cell
    try:
        chk = subprocess.run([RIG, "check", "--facts=proofs", path], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "fail", "rig check timed out"
    if chk.returncode != 0:
        return "fail", "rejected, but must be accepted: " + first_error(chk.stdout + chk.stderr)
    got = proof_dump_at(chk.stdout, line, kind)
    if got != ([entry] if entry else []):
        return "fail", f"proves {got}, expected {entry or 'nothing'} at {line}"
    key = RESULTS and RESULTS.key(path, (expect, panic), True)
    if key and RESULTS.carried(key):
        return "ok", "carried over"
    unguarded = []
    for flags in ([], ["--release"]):
        why = run_proof_built(path, keep, started_dir, expect, panic, flags, unguarded)
        if why:
            return "fail", ("--release: " if flags else "") + why
    if key and not unguarded:
        RESULTS.record(key, path, (expect, panic), True)
    return "ok", ""


def run_proof_built(path, keep, started_dir, expect, panic, flags, unguarded):
    """One build of a `proof.` cell: None when it exits 0 printing `expect`,
    or, with `panic`, exits non-zero with that panic after printing
    `expect`; else why not. Nothing a sound program never does may show
    (BAD), a proven test's assertion included."""
    outdir = path[:-4] + (".release" if flags else "") + ".out"
    started = os.path.join(started_dir, os.path.basename(path)[:-4] + "." + uuid.uuid4().hex)
    env = dict(os.environ, RIG_SANITIZE="1", RIG_OUT_DIR=outdir, RIG_BUILD_STORE=STORE, RIG_RUN_STARTED=started)
    try:
        r = run_capped([RIG, "run"] + flags + [path], env)
    except subprocess.TimeoutExpired:
        return "timed out"
    except MemoryError as e:
        return str(e)
    err = r.stderr
    if "rig: sanitizer: mapping limit reached" in err:
        unguarded.append(flags)
    ran = os.path.isfile(started) and "rig: the program did not run" not in err
    if os.path.lexists(started):
        os.remove(started)
    if not keep:
        shutil.rmtree(outdir, ignore_errors=True)
    if not ran:
        return "the program did not run: " + first_line(err)
    m = BAD.search(err)
    if m:
        return next((l for l in err.splitlines() if BAD.search(l)), m.group(0)).strip()
    if panic is None and r.returncode != 0:
        return "exit %d: %s" % (r.returncode, first_line(err))
    if panic is not None and (r.returncode == 0 or "panic: " + panic not in err):
        return "expected panic %r; exit %d: %s" % (panic, r.returncode, first_line(err))
    if r.stdout != expect:
        return "printed " + repr(r.stdout) + ", expected " + repr(expect)
    return None


# -----------------------------------------------------------------------------
# Units (`unit.`): a write of `i` and a use of it, each in a slot of a
# statement form, under a guard (docs/INTERNALS.md, "Proven checks"). The
# form's own text decides which slots are one unit and which run after
# which; `UNIT_FORMS` says, for each slot the use is in, which slots a
# write in ends the guard's facts: its own unit's slots and those on a
# path from the guard to it. That is a third statement of the unit rule,
# kept apart from the pass and from emit, and it names no order inside a
# unit, so it holds whichever order a run takes. `i` starts where the
# use is in range exactly when the write runs before it. Each cell must
# be accepted (or rejected with a diagnostic, which proves nothing); its
# `--facts=proofs` entry at the use must be what the rule gives; and it
# must run the same in debug, where a proven test that fails panics with
# "rig: a proven check failed", and with `--release`: the same output, the
# same exit, the same panic.
# -----------------------------------------------------------------------------

UNIT_LEN = 12

# name: (lines, with `{X}` for an expression slot X (an Int), `{X?}` for a
# Bool slot, and a line `{X:}` for a statement slot; for each slot the
# use may be in, the slots whose write ends what the guard showed).
_ALL4 = ("P1", "P2", "B", "S")
UNIT_FORMS = {
    "call": (["print({A}, {B})"], {"A": "AB", "B": "AB"}),
    "bind": (["x = {A} + {B}", "print(x)"], {"A": "AB", "B": "AB"}),
    "name": (["n = {A}", "print(n)"], {"A": "A"}),
    "compound": (["n += {A}", "print(n)"], {"A": "A"}),
    "elem": (["w[{A}] = {B}"], {"A": "AB", "B": "AB"}),
    "elem_compound": (["w[{A}] += {B}"], {"A": "AB", "B": "AB"}),
    "root_call": (["pick(!w, {A})[{B}] = {C}"], {"A": "ABC", "B": "ABC", "C": "ABC"}),
    "root_method": (["(!p).at({A}).v[{B}] = {C}"], {"A": "ABC", "B": "ABC", "C": "ABC"}),
    "root_opt": (["get(!p, {A})?.v[{B}] = {C}"], {"A": "ABC", "B": "ABC", "C": "ABC"}),
    "root_branch": (["(!w if {A?} else !w2[..])[{B}] = {C}"], {"A": "ABC", "B": "ABC", "C": "ABC"}),
    "return": (["if flag", "  return {A} + {B}"], {"A": "AB", "B": "AB"}),
    "while": (["while {P1} + m < 1 and {P2?} : m += 1 + {S}", "  {B:}"], {s: _ALL4 for s in _ALL4}),
    "while_cont_cond": (["while (opt({P1}, m) ?? continue) + m < 1 and {P2?} : m += 1 + {S}", "  {B:}"], {s: _ALL4 for s in _ALL4}),
    "while_cont_body": (["while {P1} + m < 1 and {P2?} : m += 1 + {S}", "  {B:}", "  continue"], {s: _ALL4 for s in _ALL4}),
    "while_cont_step": (["while {P1} + m < 1 and {P2?} : m += 1 + (opt({S}, 1) ?? continue)", "  {B:}"], {s: _ALL4 for s in _ALL4}),
    "if": (["if {P1?} and {P2?}", "  {T:}", "else", "  {E:}"],
           {"P1": ("P1",), "P2": ("P1", "P2"), "T": ("P1", "P2", "T"), "E": ("P1", "P2", "E")}),
    "match": (["match {A}", "  0 if {G1?}", "    {B1:}", "  _ if {G2?}", "    {B2:}", "  _ => pass"],
              {"A": ("A", "G1", "G2"), "G1": ("A", "G1", "G2"), "G2": ("A", "G1", "G2"),
               "B1": ("A", "G1", "G2", "B1"), "B2": ("A", "G1", "G2", "B2")}),
    "value_if": (["x = {A} if flag else {B}", "print(x)"], {"A": "AB", "B": "AB"}),
    "value_and": (["ok = {A?} and {B?}", "print(ok)"], {"A": "AB", "B": "AB"}),
    "value_match": (["x = match k", "  1", "    {X1:}", "    {V}", "  _", "    {X2:}", "    0", "print(x)"],
                    {"X1": ("X1", "X2", "V"), "X2": ("X1", "X2", "V"), "V": ("X1", "X2", "V")}),
    # A `defer` body is walked from no facts: a use in it is never proven.
    "defer": (["if flag", "  defer", "    {D:}", "  {I:}", "{O:}"],
              {"D": None, "I": ("I",), "O": ("D", "I", "O")}),
}

# name: (as an Int expression, as a statement, whether it keeps `0 <= i`).
UNIT_WRITES = {
    "bump": ("bump(!i)", "print(bump(!i))", False),
    "closure": ("run(|!i| i += 1)", "print(run(|!i| i += 1))", False),
    "nested": (None, "i += 1", True),
    "none": (None, None, True),
}

# name: (as an Int expression, as a statement, the dump's kind, the text
# the node starts with, its width (None: an add)).
UNIT_USES = {
    "index": ("Int(s[i])", "print(s[i])", "index", "s[i]", 1),
    "read": ("Int(s.read[U32, .little](i))", "print(s.read[U32, .little](i))", "read", "s.read", 4),
    "add": ("(i + 1)", "print(i + 1)", "+", "i + 1", None),
    "write": (None, "!s.write[U32, .little](i, 0x01020304)", "write", "s.write", 4),
    "simd": ("Int(s.read[Simd[U8, 4]](i)[0])", "print(s.read[Simd[U8, 4]](i)[0])", "read", "s.read", 4),
    "simd_write": (None, "!s.write[Simd[U8, 4]](i, Simd[U8, 4].splat(9))", "write", "s.write", 4),
}

# name: (lines before the form, the form's indent, lines after it, the
# facts the guard shows).
UNIT_GUARDS = {
    "if": (["if i < s.len"], "  ", [], dict(nonneg=False, below=1)),
    "while": (["while i < s.len"], "  ", ["  break"], dict(nonneg=False, below=1)),
    "check": (["c = s[i]", "print(c)"], "", [], dict(nonneg=True, below=1)),
}

UNIT_PRELUDE = """obj P
  v: [2]Int

  fun at(self: !P, n: Int) -> !P
    self

fun z(n: Int) -> Int
  0

fun bump(n: !Int) -> Int
  n += 1
  0

fun run(f: ?sub()) -> Int
  f()
  0

fun opt(n: Int, m: Int) -> Int?
  n if m > 0 else none

fun pick(t: ![]Int, n: Int) -> ![]Int from t
  t

fun get(p: !P, n: Int) -> (!P)?
  !p
"""


def unit_slots(lines):
    """The slots of a form, in the order they appear: (name, how), with how
    `expr`, `bool`, or `stmt`."""
    out = []
    for l in lines:
        for m in re.finditer(r"\{(\w+)([?:]?)\}", l):
            out.append((m.group(1), {"": "expr", "?": "bool", ":": "stmt"}[m.group(2)]))
    return out


def unit_program(fname, wname, wslot, uname, uslot, gname):
    """A `unit.` cell: the program, the use's `L:C`, its dump kind, and the
    entry the rule gives (None: nothing proven); None where the write or
    the use cannot stand in its slot."""
    lines, kills = UNIT_FORMS[fname]
    slots = dict(unit_slots(lines))
    wexpr, wstmt, keeps_nonneg = UNIT_WRITES[wname]
    uexpr, ustmt, ukind, ustart, uwidth = UNIT_USES[uname]
    if uslot not in slots or uslot not in kills:
        return None
    if wname == "none":
        if wslot is not None:
            return None
    elif wslot not in slots or (slots[wslot] != "stmt" and wexpr is None):
        return None
    if slots[uslot] != "stmt" and uexpr is None:
        return None
    filled = {}
    for name, how in slots.items():
        parts = []
        if name == wslot and wname != "none":
            parts.append(wstmt if how == "stmt" else f"z({wexpr})")
        if name == uslot:
            parts.append("\0" + (ustmt if how == "stmt" else f"z({uexpr})"))
        if how == "stmt":
            filled[name] = parts or ["pass"]
        elif how == "bool":
            filled[name] = [" + ".join(parts) + " == 0" if parts else "true"]
        else:
            filled[name] = [" + ".join(parts) if parts else "0"]
    body = []
    for l in lines:
        m = re.fullmatch(r"(\s*)\{(\w+):\}", l)
        if m:
            body += [m.group(1) + x for x in filled[m.group(2)]]
            continue
        body.append(re.sub(r"\{(\w+)[?]?\}", lambda mm: filled[mm.group(1)][0], l))
    before, indent, after, gfacts = UNIT_GUARDS[gname]
    width = uwidth or 1
    at = UNIT_LEN - width
    probe = ["i = at", "n = 0", "m = 0", "p = P(v: [0, 0])", "w2: [2]Int = [0, 0]"]
    probe += before + [indent + l for l in body] + after + ["print(i, n, m, p, w2)", "0"]
    line_no = col = None
    for k, l in enumerate(probe):
        if "\0" in l:
            l = probe[k] = l.replace("\0", "")
            needle = ustmt if slots[uslot] == "stmt" else f"z({uexpr})"
            col = l.index(needle) + needle.index(ustart) + 1
            line_no = k
    src = UNIT_PRELUDE.splitlines()
    src.append("")
    src.append("fun probe(s: ![]U8, w: ![]Int, at: Int, k: Int, flag: Bool) -> Int?")
    first = len(src) + 1
    src += ["  " + l for l in probe]
    src.append("")
    src.append("sub main()")
    src.append(f"  a: [{UNIT_LEN}]U8 = [{', '.join(str(97 + j) for j in range(UNIT_LEN))}]")
    src.append("  t: [2]Int = [0, 0]")
    src.append(f"  print(probe(!a[..], !t[..], {at}, 1, true) ?? 9)")
    src.append("  print(a, t)")
    at_use = f"{first + line_no}:{col + 2}"
    # The rule: the guard's facts reach the use unless a write ends them.
    facts = dict(gfacts)
    ends = kills[uslot]
    if ends is None:
        facts = dict(nonneg=False, below=None)
    elif wname != "none" and wslot in ends:
        facts["below"] = None
        if not keeps_nonneg:
            facts["nonneg"] = False
    tests = []
    if uwidth is not None:
        if facts["nonneg"]:
            tests.append("lower")
        if facts["below"] is not None and facts["below"] >= uwidth:
            tests.append("upper")
    elif facts["below"] is not None and facts["below"] >= 1:
        tests.append("no_overflow")
    entry = f"{at_use} {ukind} {' '.join(tests)}" if tests else None
    return "\n".join(src) + "\n", (at_use, ukind), entry


def unit_cells(deep):
    """Every `unit.` cell's id and arguments: with `deep`, every form,
    write, write slot, use, use slot, and guard; else each form's slot
    pairs with `bump(!i)` and `s[i]` under `if`, and each use slot with no
    write under each guard."""
    for f, (lines, kills) in UNIT_FORMS.items():
        names = [n for n, _ in unit_slots(lines)]
        for g in UNIT_GUARDS:
            for w in UNIT_WRITES:
                for u in UNIT_USES:
                    if not deep and not ((w == "bump" and u == "index" and g == "if") or (w == "none" and u == "index")):
                        continue
                    for ws in (names if w != "none" else [None]):
                        for us in names:
                            yield f"unit.{g}.{f}.{w}.{ws or '-'}.{u}.{us}", (f, w, ws, u, us, g)


def run_unit(path, keep, started_dir, cell):
    """Classify one `unit.` cell: the checker rejects it with a diagnostic,
    or `--facts=proofs` lists exactly what the rule gives at its use, and
    it runs alike in debug and with `--release`, with nothing a sound
    program never does (a proven test's assertion included)."""
    (line, kind), entry = cell
    try:
        chk = subprocess.run([RIG, "check", "--facts=proofs", path], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "fail", "rig check timed out"
    if chk.returncode != 0:
        if POS.search(chk.stdout + chk.stderr) and not CRASH.search(chk.stdout + chk.stderr):
            return "ok", "rejected"
        return "fail", "rejected without a diagnostic: " + first_error(chk.stdout + chk.stderr)
    got = proof_dump_at(chk.stdout, line, kind)
    if got != ([entry] if entry else []):
        return "fail", f"proves {got}, the rule gives {entry or 'nothing'} at {line}"
    key = RESULTS and RESULTS.key(path, ("unit", entry), True)
    if key and RESULTS.carried(key):
        return "ok", "carried over"
    runs, unguarded = [], []
    for flags in ([], ["--release"]):
        outdir = path[:-4] + (".release" if flags else "") + ".out"
        started = os.path.join(started_dir, os.path.basename(path)[:-4] + "." + uuid.uuid4().hex)
        env = dict(os.environ, RIG_SANITIZE="1", RIG_OUT_DIR=outdir, RIG_BUILD_STORE=STORE, RIG_RUN_STARTED=started)
        try:
            r = run_capped([RIG, "run"] + flags + [path], env)
        except subprocess.TimeoutExpired:
            return "fail", ("--release: " if flags else "") + "timed out"
        except MemoryError as e:
            return "fail", str(e)
        if "rig: sanitizer: mapping limit reached" in r.stderr:
            unguarded.append(flags)
        ran = os.path.isfile(started) and "rig: the program did not run" not in r.stderr
        if os.path.lexists(started):
            os.remove(started)
        if not keep:
            shutil.rmtree(outdir, ignore_errors=True)
        if not ran:
            return "fail", ("--release: " if flags else "") + "the program did not run: " + first_line(r.stderr)
        m = BAD.search(r.stderr)
        if m:
            return "fail", ("--release: " if flags else "") + next((l for l in r.stderr.splitlines() if BAD.search(l)), m.group(0)).strip()
        panic = re.search(r"panic: (.*)", r.stderr)
        runs.append((r.returncode, r.stdout, panic.group(1).strip() if panic else None))
    if runs[0] != runs[1]:
        return "fail", f"debug {runs[0]!r} but --release {runs[1]!r}"
    if key and not unguarded:
        RESULTS.record(key, path, ("unit", entry), True)
    return "ok", ""


# A program that runs away is stopped: after RUN_SECONDS (`--timeout`),
# when it has printed more than RUN_OUTPUT bytes, or when its processes
# (the compiler, Zig, the program) hold more than RUN_MB megabytes
# (`--mem`). Memory is watched, not limited: the sanitizer reserves
# address space far beyond what it uses, so an address-space limit
# (`ulimit -v`, `prlimit --as`) stops every sanitized program.
RUN_SECONDS = 120
RUN_OUTPUT = 1 << 20
RUN_MB = 2048
# Memory is read every RUN_MEM_EVERY seconds, so a program that ends
# sooner is never read: where there is no /proc, each reading is a `ps`
# of the whole machine.
RUN_MEM_EVERY = 1.0


PAGE_KB = os.sysconf("SC_PAGE_SIZE") // 1024
# Linux lists a process's children in /proc, so the reading walks only
# the program's own tree; elsewhere (macOS) `ps` lists every process.
PROC_CHILDREN = os.path.exists(f"/proc/self/task/{os.getpid()}/children")


def tree_rss(pgid):
    """The resident memory of process group `pgid` (its leader and the
    leader's descendants), in kilobytes."""
    if PROC_CHILDREN:
        total, stack = 0, [pgid]
        while stack:
            p = stack.pop()
            try:
                with open(f"/proc/{p}/statm") as f:
                    total += int(f.read().split()[1]) * PAGE_KB
                for t in os.listdir(f"/proc/{p}/task"):
                    with open(f"/proc/{p}/task/{t}/children") as f:
                        stack.extend(int(c) for c in f.read().split())
            except (OSError, ValueError):
                pass
        return total
    r = subprocess.run(["ps", "-A", "-o", "pgid=,rss="], capture_output=True, text=True)
    total = 0
    for l in r.stdout.splitlines():
        f = l.split()
        if len(f) == 2 and f[0] == str(pgid):
            total += int(f[1])
    return total


def find_cap():
    """`cpuq cap`, where it stops programs, else None (the watchdog).
    It is used wherever cpuq is installed; RIG_CAP=0 refuses it.
    Probed once."""
    want, path = os.environ.get("RIG_CAP", ""), shutil.which("cpuq")
    if want == "0" or not path:
        return None
    try:
        ok = subprocess.run([path, "cap", "--time", "10s", "--", "true"], capture_output=True,
                            stdin=subprocess.DEVNULL, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        ok = False
    if not ok:
        print("note: `cpuq cap` failed its probe; the watchdog stops programs", file=sys.stderr)
    return path if ok else None


CPUQ = find_cap()
# How programs are stopped, in the results cache's key.
CAP_MODE = "watchdog" if not CPUQ else "cap %s %s" % (
    subprocess.run([CPUQ, "--version"], capture_output=True, text=True).stdout.strip(),
    "cgroup" if os.environ.get("CPUQ_CGROUP") else "tree")


def run_capped(cmd, env, cap=True):
    """Run `cmd` with its output in files, stopping it as RUN_* say: by
    `cpuq cap` where cpuq is installed (inside a cpuq job on Linux the
    kernel enforces the memory limit, and nothing polls), else by the
    watchdog below (CI, and machines without cpuq)."""
    if CPUQ and cap:
        return run_capped_cpuq(cmd, env)
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        p = subprocess.Popen(cmd, stdout=out, stderr=err, stdin=subprocess.DEVNULL, env=env, start_new_session=True)
        start = time.monotonic()
        next_mem = start + RUN_MEM_EVERY
        why = None
        while True:
            try:
                p.wait(timeout=0.2)
                break
            except subprocess.TimeoutExpired:
                pass
            now = time.monotonic()
            if now - start > RUN_SECONDS:
                why = "timeout"
            elif os.fstat(out.fileno()).st_size + os.fstat(err.fileno()).st_size > RUN_OUTPUT:
                why = f"printed more than {RUN_OUTPUT} bytes"
            elif now >= next_mem:
                next_mem = now + RUN_MEM_EVERY
                if tree_rss(p.pid) > RUN_MB << 10:
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



def run_capped_cpuq(cmd, env):
    """`run_capped` through `cpuq cap`, which stops the program and
    everything it started. Its output must go to files: cap refuses
    pipes."""
    capped = [CPUQ, "cap", "--mem", f"{RUN_MB}M", "--time", f"{RUN_SECONDS}s", "--output", str(RUN_OUTPUT), "--"] + cmd
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        p = subprocess.Popen(capped, stdout=out, stderr=err, stdin=subprocess.DEVNULL, env=env, start_new_session=True)
        try:
            p.wait(timeout=RUN_SECONDS + 60)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            raise MemoryError("stopped: cpuq cap did not return (a harness failure)")
        out.seek(0)
        err.seek(0)
        stdout = out.read().decode(errors="replace")
        stderr = err.read().decode(errors="replace")
    # cap's own line, when it has one, is the last.
    last = stderr.rstrip("\n").rpartition("\n")[2]
    if last.startswith("cpuq cap: stopped "):
        if p.returncode == 124:
            raise subprocess.TimeoutExpired(cmd, RUN_SECONDS)
        if p.returncode == 122:
            raise MemoryError(f"stopped: used more than {RUN_MB} MB")
        if p.returncode == 121:
            raise MemoryError(f"stopped: printed more than {RUN_OUTPUT} bytes")
    elif p.returncode == 125 and last.startswith("cpuq cap: "):
        print(f"note: {last}; the watchdog runs it", file=sys.stderr)
        return run_capped(cmd, env, cap=False)
    return subprocess.CompletedProcess(cmd, p.returncode, stdout, stderr)

def run_one(path, keep, started_dir, expect=None, release=False):
    """Classify one program: rejected, ok, or a failure with its reason.
    With `expect`, a program that runs must print exactly that; with
    `release`, also when built with `--release`, and it must be
    accepted; with `release == "also"`, a program that is accepted is
    also built with `--release`, but it may be rejected."""
    d = os.path.dirname(path)
    try:
        chk = subprocess.run([RIG, "check", path], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "fail", "rig check timed out"
    out = chk.stdout + chk.stderr
    if chk.returncode < 0 or chk.returncode > 128 or CRASH.search(out):
        return "fail", "compiler crashed: " + first_line(out)
    if chk.returncode != 0:
        # A program also built with `--release` is one the checker must
        # accept.
        if release is True:
            return "fail", "rejected, but must be accepted: " + first_error(out)
        if POS.search(out):
            return "rejected", first_error(out)
        return "fail", "rejected without file:line:col: " + first_line(out)
    key = RESULTS and RESULTS.key(path, expect, release)
    if key and RESULTS.carried(key):
        return "ok", "carried over"
    unguarded = []
    why = run_built(path, keep, started_dir, expect, [], unguarded)
    if why is None and release:
        why = run_built(path, keep, started_dir, expect, ["--release"], unguarded)
        why = why and "--release: " + why
    if why:
        return "fail", why
    if key and not unguarded:
        RESULTS.record(key, path, expect, release)
    return "ok", ""


def run_built(path, keep, started_dir, expect, flags, unguarded):
    """Run one accepted program built with `flags`: None when it runs as
    it must, else why not. A run past the sanitizer's mapping limit,
    which guards no more allocations, is noted in `unguarded`."""
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
    if "rig: sanitizer: mapping limit reached" in err:
        unguarded.append(flags)
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
           "--rejects", os.path.join(ROOT, "test", "oracle", "rejections"),
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


# Every function a program's verdict reads (Results hashes their code).
VERDICT_CODE = (tree_rss, run_capped, run_capped_cpuq, find_cap, run_one, run_built, first_line, first_error, run_proof, run_proof_built, proof_dump_at, run_unit)



# cpuq names a file in CPUQ_PROGRESS where a run reports how far it has
# got. Only this run writes it: the programs it runs never see it.
PROGRESS = os.environ.pop("CPUQ_PROGRESS", None)


class Progress:
    """Replaces PROGRESS with one line, `DONE TOTAL FAILING`: the programs
    with a verdict, all this run will have, and those that failed so far;
    at most once a second, and once more at the end."""

    def __init__(self, total):
        self.total, self.done, self.failing, self.last = total, 0, 0, 0.0
        self.write(True)

    def add(self, failed):
        self.done += 1
        self.failing += failed
        self.write(False)

    def write(self, now):
        if not PROGRESS or (not now and time.monotonic() - self.last < 1.0):
            return
        self.last = time.monotonic()
        try:
            with open(PROGRESS + ".tmp", "w") as f:
                f.write(f"{self.done} {self.total} {self.failing}\n")
            os.replace(PROGRESS + ".tmp", PROGRESS)
        except OSError:
            pass


def main():
    global RIG, RUN_SECONDS, RUN_MB, RESULTS
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
    ap.add_argument("--delta", action="store_true", help="do not run a program whose runs passed before (the results cache)")
    ap.add_argument("--deep", action="store_true", help="every write of the proof. grid with its use nested too, and the whole unit. grid (the deep gate)")
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
    expects = {}
    for t in TYPES:
        kept = TYPES[t].get("rejected")
        for c in CONTEXTS:
            for f in FORMS:
                ident = f"{t}.{c}.{f}"
                if kept is not None and (c, f) not in kept or not wanted(ident):
                    continue
                src = program(t, f, c)
                if src is None:
                    skipped += 1
                    continue
                path = os.path.join(work, ident.replace(".", "__") + ".rig")
                with open(path, "w") as fh:
                    fh.write(src)
                cells.append((ident, path))
                if kept is not None:
                    # No run prints this: a program that runs fails the cell.
                    expects[ident] = "(rejected)\n"
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
    release = set()
    also = set()
    for kname in KEEPS_KINDS:
        for sname in KEEPS_STORES:
            for said in ("said", "unsaid"):
                for then in ("read", "change"):
                    ident = f"keeps.{kname}.{sname}.{said}.{then}"
                    if not wanted(ident):
                        continue
                    src, expect = keeps_program(kname, sname, said == "said", then)
                    if src is None:
                        skipped += 1
                        continue
                    path = os.path.join(work, ident.replace(".", "__") + ".rig")
                    with open(path, "w") as fh:
                        fh.write(src)
                    cells.append((ident, path))
                    expects[ident] = expect
                    # A cell that prints must be accepted.
                    if expect != "(rejected)\n":
                        release.add(ident)
    for fname in GEN_FORMS:
        for said in ("said", "unsaid"):
            for then in ("read", "drop"):
                ident = f"gen.{fname}.{said}.{then}"
                if not wanted(ident):
                    continue
                src, expects[ident] = gen_program(fname, said == "said", then)
                path = os.path.join(work, ident.replace(".", "__") + ".rig")
                with open(path, "w") as fh:
                    fh.write(src)
                cells.append((ident, path))
                # A cell that prints must be accepted.
                if expects[ident] != "(rejected)\n":
                    release.add(ident)
    for pname in TAKEN_PLACES:
        for then in TAKEN_THENS:
            ident = f"taken.{pname}.{then}"
            if not wanted(ident):
                continue
            src = taken_program(pname, then)
            if src is None:
                skipped += 1
                continue
            path = os.path.join(work, ident.replace(".", "__") + ".rig")
            with open(path, "w") as fh:
                fh.write(src)
            cells.append((ident, path))
            expects[ident] = taken_then(pname, then)[1]
            # A cell that runs must be accepted.
            if then != "drop":
                release.add(ident)
    for root in FIELD_ROOTS:
        for first in FIELD_FIRSTS:
            for rel in FIELD_RELS:
                for second in FIELD_SECONDS:
                    for ctx in FIELD_CONTEXTS:
                        for ex in FIELD_EXITS:
                            ident = f"field.{root}.{first}.{rel}.{second}.{ctx}.{ex}"
                            if not wanted(ident):
                                continue
                            src, out = field_program(root, first, rel, second, ctx, ex)
                            if src is None:
                                skipped += 1
                                continue
                            path = os.path.join(work, ident.replace(".", "__") + ".rig")
                            with open(path, "w") as fh:
                                fh.write(src)
                            cells.append((ident, path))
                            expects[ident] = out
                            if out != "(rejected)\n" and ctx == "straight" and ex == "fall":
                                release.add(ident)
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
    for tp in TARGET_PLACES:
        for nest in TARGET_NESTS:
            for act in TARGET_ACTS:
                ident = f"target.{tp}.{nest}.{act}"
                if not wanted(ident):
                    continue
                src = target_program(tp, nest, act)
                if src is None:
                    skipped += 1
                    continue
                path = os.path.join(work, ident.replace(".", "__") + ".rig")
                with open(path, "w") as fh:
                    fh.write(src)
                cells.append((ident, path))
                if target_output(tp, nest, act) is not None:
                    expects[ident] = target_output(tp, nest, act)
                    release.add(ident)
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
    for source in ITER_SOURCES:
        for ctx in ITER_CONTEXTS:
            ident = f"iter.{source}.{ctx}"
            if not wanted(ident):
                continue
            path = os.path.join(work, ident.replace(".", "__") + ".rig")
            with open(path, "w") as fh:
                fh.write(iter_program(source, ctx))
            cells.append((ident, path))
            out = iter_output(source, ctx)
            expects[ident] = out if out is not None else "(rejected)\n"
            if out is not None:
                release.add(ident)
    for ident, src, out in dloop_cells():
        if not wanted(ident):
            continue
        path = os.path.join(work, ident.replace(".", "__") + ".rig")
        with open(path, "w") as fh:
            fh.write(src)
        cells.append((ident, path))
        expects[ident] = out if out is not None else "(rejected)\n"
        if out is not None:
            release.add(ident)
    for ident, src, out in vlit_cells():
        if not wanted(ident):
            continue
        path = os.path.join(work, ident.replace(".", "__") + ".rig")
        with open(path, "w") as fh:
            fh.write(src)
        cells.append((ident, path))
        expects[ident] = out if out is not None else "(rejected)\n"
        if out is not None:
            release.add(ident)
    for ident, src, out in eq_cells():
        if not wanted(ident):
            continue
        path = os.path.join(work, ident.replace(".", "__") + ".rig")
        with open(path, "w") as fh:
            fh.write(src)
        cells.append((ident, path))
        expects[ident] = out if out is not None else "(rejected)\n"
        also.add(ident)
    for ident, c, a, op in fold_cells():
        if not wanted(ident):
            continue
        src, accepted = fold_program(c, a, op)
        path = os.path.join(work, ident.replace(".", "__") + ".rig")
        with open(path, "w") as fh:
            fh.write(src)
        cells.append((ident, path))
        # The part is read when the program runs: it panics before it prints.
        expects[ident] = ""
        if accepted:
            release.add(ident)
    for call in NAMED_CALLS:
        for kind in NAMED_KINDS:
            for order in NAMED_ORDERS:
                ident = f"named.{call}.{kind}.{order}"
                if not wanted(ident):
                    continue
                src, out = named_program(call, kind, order)
                if src is None:
                    skipped += 1
                    continue
                path = os.path.join(work, ident.replace(".", "__") + ".rig")
                with open(path, "w") as fh:
                    fh.write(src)
                cells.append((ident, path))
                expects[ident] = out if out is not None else "(rejected)\n"
                if out is not None:
                    release.add(ident)
    order_cells = [(f"order.{root}.{path}.{op}.{value}", order_program(root, path, op, value))
                   for root in ORDER_ROOTS for path in ORDER_PATHS for op in ORDER_OPS for value in ORDER_VALUES]
    order_cells += [(f"order.leave.{step}.{fail}", order_leave_program(step, fail)) for step in ORDER_LEAVES for fail in ("true", "false")]
    for ident, (src, out) in order_cells:
        if not wanted(ident):
            continue
        if src is None:
            skipped += 1
            continue
        path = os.path.join(work, ident.replace(".", "__") + ".rig")
        with open(path, "w") as fh:
            fh.write(src)
        cells.append((ident, path))
        expects[ident] = out
        release.add(ident)
    for shape in ROOTIDX_SHAPES:
        for site in ROOTIDX_SITES:
            for writer in ROOTIDX_WRITERS:
                ident = f"rootidx.{shape}.{site}.{writer}"
                if not wanted(ident):
                    continue
                src, out = rootidx_program(shape, site, writer)
                if src is None:
                    skipped += 1
                    continue
                expects[ident] = out
                path = os.path.join(work, ident.replace(".", "__") + ".rig")
                with open(path, "w") as fh:
                    fh.write(src)
                cells.append((ident, path))
                if expects[ident] != "(rejected)\n":
                    release.add(ident)
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
    for t in VIEWPAY_TYPES:
        for sname in VIEWPAY_SUBJECTS:
            for u in VIEWPAY_USES:
                ident = f"viewpay.{t}.{sname}.{u}"
                if not wanted(ident):
                    continue
                src, expects[ident] = viewpay_program(t, sname, u)
                if src is None:
                    skipped += 1
                    continue
                path = os.path.join(work, ident.replace(".", "__") + ".rig")
                with open(path, "w") as fh:
                    fh.write(src)
                cells.append((ident, path))
    for hname in SLICEVIEW_HOLDERS:
        for ename in SLICEVIEW_ELEMS:
            for use in ("arg", "bind"):
                for then in ("live", "done"):
                    ident = f"sliceview.{hname}.{ename}.{use}.{then}"
                    if not wanted(ident):
                        continue
                    path = os.path.join(work, ident.replace(".", "__") + ".rig")
                    with open(path, "w") as fh:
                        fh.write(sliceview_program(hname, ename, use, then))
                    cells.append((ident, path))
    for oname in HOLDER_OWNERS:
        for fname in HOLDER_FORMS:
            for change in ("write", "move", "drop"):
                for then in ("live", "done"):
                    ident = f"holder.{oname}.{fname}.{change}.{then}"
                    if not wanted(ident):
                        continue
                    src, expect = holder_program(oname, fname, change, then)
                    if src is None:
                        skipped += 1
                        continue
                    path = os.path.join(work, ident.replace(".", "__") + ".rig")
                    with open(path, "w") as fh:
                        fh.write(src)
                    cells.append((ident, path))
                    expects[ident] = expect
                    if then == "done":
                        release.add(ident)
    for callee in CLOS_CALLEES:
        for aname in CLOS_ARGS:
            for rname in CLOS_RESULTS:
                for then in CLOS_THENS:
                    ident = f"clos.{callee}.{aname}.{rname}.{then}"
                    if not wanted(ident):
                        continue
                    src, expects[ident] = clos_program(callee, aname, rname, then)
                    path = os.path.join(work, ident.replace(".", "__") + ".rig")
                    with open(path, "w") as fh:
                        fh.write(src)
                    cells.append((ident, path))
    for wname in NEST_WRAPPERS:
        for home in NEST_HOMES:
            for oname in NEST_OWNERS:
                ident = f"nest.{wname}.{home}.{oname}"
                if not wanted(ident):
                    continue
                path = os.path.join(work, ident.replace(".", "__") + ".rig")
                with open(path, "w") as fh:
                    fh.write(nest_program(wname, home, oname))
                cells.append((ident, path))
                # A `Static` carries no loan, so it goes there at any depth.
                expects[ident] = "1\n" if oname == "static" else "(rejected)\n"
    for bname in LENDW_BINDINGS:
        for t in LENDW_TYPES:
            for lname in LENDW_TYPES[t]["lends"]:
                for when in ("live", "after"):
                    ident = f"lendw.{bname}.{t}.{lname}.{when}"
                    if not wanted(ident):
                        continue
                    src, expects[ident] = lendw_program(bname, t, lname, when)
                    path = os.path.join(work, ident.replace(".", "__") + ".rig")
                    with open(path, "w") as fh:
                        fh.write(src)
                    cells.append((ident, path))
    for hname in HDR_HEADERS:
        for gname in HDR_SIGILS:
            for sname in HDR_SHAPES:
                for lname in HDR_LEAVES:
                    ident = f"hdr.{hname}.{gname}.{sname}.{lname}"
                    if not wanted(ident):
                        continue
                    src = hdr_program(hname, sname, lname, gname)
                    path = os.path.join(work, ident.replace(".", "__") + ".rig")
                    with open(path, "w") as fh:
                        fh.write(src)
                    cells.append((ident, path))
                    # No run prints this: a program that runs fails the cell.
                    expects[ident] = "(rejected)\n"
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
    for ident, src in CELL_VALUES.items():
        if not wanted(ident):
            continue
        path = os.path.join(work, ident.replace(".", "__") + ".rig")
        with open(path, "w") as fh:
            fh.write(src)
        cells.append((ident, path))
        # No run prints this: a program that runs fails the cell.
        expects[ident] = "(rejected)\n"
    proofs = {}
    for g in PROOF_GUARDS:
        for m in PROOF_MUTATIONS:
            for u in PROOF_USES:
                for place in PROOF_PLACES:
                    ident = f"proof.{g}.{m}.{u}.{place}"
                    if not wanted(ident):
                        continue
                    cell = proof_program(g, m, u, place, args.deep)
                    if cell is None:
                        continue
                    path = os.path.join(work, ident.replace(".", "__") + ".rig")
                    with open(path, "w") as fh:
                        fh.write(cell[0])
                    cells.append((ident, path))
                    proofs[ident] = cell[1:]
    units = {}
    for ident, (f, w, ws, u, us, g) in unit_cells(args.deep):
        if not wanted(ident):
            continue
        cell = unit_program(f, w, ws, u, us, g)
        if cell is None:
            continue
        path = os.path.join(work, ident.replace(".", "__").replace("-", "_") + ".rig")
        with open(path, "w") as fh:
            fh.write(cell[0])
        cells.append((ident, path))
        units[ident] = cell[1:]
    if args.oracle:
        sys.exit(run_oracle(work, cells, args))
    results = {}
    started_dir = tempfile.mkdtemp(prefix="rig-matrix-started.")
    cache = results_cache()
    if args.delta and (args.rig or not cache):
        print("note: no results cache (%s); --delta runs everything" % ("--rig" if args.rig else "RIG_RESULTS_CACHE is empty"))
    if cache and not args.rig:
        # The cache's keys name src/main.zig: bin/rig must be built from it.
        b = subprocess.run([os.environ.get("ZIG", "zig"), "build"], cwd=ROOT, stdin=subprocess.DEVNULL)
        if b.returncode != 0:
            sys.exit("zig build failed")
        RESULTS = Results(cache, args.delta, started_dir)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.j) as pool:
            futs = {(pool.submit(run_proof, p, bool(args.keep), started_dir, proofs[i]) if i in proofs else
                     pool.submit(run_unit, p, bool(args.keep), started_dir, units[i]) if i in units else
                     pool.submit(run_one, p, bool(args.keep), started_dir, expects.get(i), "also" if i in also else i in release)): i for i, p in cells}
            progress = Progress(len(futs))
            for fut in concurrent.futures.as_completed(futs):
                results[futs[fut]] = fut.result()
                progress.add(results[futs[fut]][0] == "fail")
            progress.write(True)
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
    carried = sum(1 for st, why in results.values() if st == "ok" and why == "carried over")
    print(f"\n{len(cells)} programs ({skipped} cells where the form cannot stand): "
          f"{counts.get('ok', 0)} ran clean{f' ({carried} carried over)' if args.delta else ''}, "
          f"{counts.get('rejected', 0)} rejected, {counts.get('fail', 0)} failed")
    if not args.keep:
        shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if counts.get("fail") else 0)


if __name__ == "__main__":
    main()
