#!/usr/bin/env python3
"""Generate and run the form x context x type matrix of small programs.

Each program puts one expression form (a place, a ternary, `o?`, ...) in
one context (a `print` argument, a binding, an element assignment, ...)
for one type (Int, String, Text, Vec, `*T`, Box, a struct with a
`drop`). The rule is the corpus's: `rig check` rejects the program with
a file:line:col diagnostic, or it runs clean under the sanitizer (no leak,
no use of freed memory, no Zig compile error, no crash).

    test/matrix.py                 # generate, check, and run everything
    test/matrix.py -j 8 -k vec     # 8 at a time; only ids containing "vec"
    test/matrix.py --keep DIR      # write the programs to DIR and keep them

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

N_DECL = "struct N\n  v: Int\n"
TYPES = {
    "int": dict(ty="Int", decls="", mk="n", ctor="Int(5)"),
    "string": dict(ty="String", decls="", mk='"s" if n > 0 else "t"', ctor='"lit"'),
    "text": dict(ty="Text", decls="", mk='Text("t", n)', ctor='Text("lit")'),
    "vec": dict(ty="Vec[Int]", decls="",
                mk="xs: Vec[Int] = Vec()\n  !xs.push(n)\n  xs", ctor="Vec[Int]()"),
    "shared": dict(ty="*N", decls=N_DECL, mk="*N(v: n)", ctor="*N(v: 5)"),
    "box": dict(ty="Box[N]", decls=N_DECL, mk="Box(N(v: n))", ctor="Box(N(v: 5))"),
    "drop": dict(ty="D", decls='struct D\n  v: Int\n\n  drop(!self)\n    print("drop", self.v)\n\n  fun take(<self) -> Int\n    self.v\n',
                 mk="D(v: n)", ctor="D(v: 5)"),
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
    # A method that consumes its receiver (`<self`, `Box.unbox`).
    "recv_consume": dict(inline="print((E).M)", recv={"drop": "take()", "box": "unbox().v"}),
    # `none` and a bare `.variant` test a value and drop it if no name holds it.
    "eq_none": dict(inline="print(E == none)", optional=True),
    "eq_variant": dict(inline="print(E != .dot)", types=("enum",)),
}

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
    out.append(f"struct H\n  f: {ty}\n")
    returns = ctx.get("returns", False)
    needs = ctx.get("needs")
    if needs == "vs":
        # Calls that grow the Vec an element assignment stores into.
        out.append(f"fun through(v: !Vec[{ty}], x: {ty}) -> {ty}\n  for i in 0..100\n    !v.push(mk(i))\n  x\n")
        out.append(f"fun grow(v: !Vec[{ty}]) -> Int\n  for i in 0..100\n    !v.push(mk(i))\n  0\n")
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
        e = form
        if cname in ("borrow_arg", "for_source") and " " in e:
            e = f"({e})"
        body.append(text.replace("E", e))
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
