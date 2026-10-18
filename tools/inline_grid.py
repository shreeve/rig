#!/usr/bin/env python3
"""Write test/rig/emit-inline-grid.rig.test, the inline grid.

What an inlined function hands back is a run-time value to its caller: a
result that no argument decides (a constant, a parameter it ignores,
another inlined call, an empty optional, an error) must not let Zig fold
the arithmetic, indexing, narrowing, or shift on it into a compile error
in code the program never runs, and the same use, run, must panic. The
grid is callee shape x use: each shape gets one case with every use in a
branch that does not run, and each cell one case that runs the use. Every
case is `release: true`, so it is built in debug and in Zig's safe mode.

    python3 tools/inline_grid.py            # rewrite the test file
    python3 tools/inline_grid.py --check    # exit 1 if it is stale
"""
import os
import sys

# use: (callee result type, the value, an expression on z, the panic)
USES = {
    "div": ("Int", "0", "10 / z", "panic: division by zero"),
    "overflow": ("Int", "9223372036854775807", "1 + z", "panic: integer overflow"),
    "overflow8": ("U8", "U8(255)", "z + U8(1)", "panic: integer overflow"),
    "narrow": ("Int", "300", "U8(z)", "panic: integer does not fit in destination type"),
    "shift": ("Int", "70", "1 << z", "panic: integer does not fit in destination type"),
    "index": ("Int", "7", "xs[z]", "panic: index out of bounds"),
}
SHAPES = ["const", "ignored", "transitive", "ctbool", "ctint", "ctenum", "ctthrough"]
WHAT = {
    "const": "a constant",
    "ignored": "a constant, its parameter ignored",
    "transitive": "another inlined call's constant",
    "ctbool": "a compile-time Bool instance's constant",
    "ctint": "a compile-time Int instance's constant",
    "ctenum": "a compile-time enum instance's constant",
    "ctthrough": "an inlined call's constant, through an instance",
}


def defs(shape, use):
    ty, v = USES[use][0], USES[use][1]
    base = f"fun c_{use}() -> {ty}\n  {v}\n"
    if shape == "const":
        return base, f"c_{use}()"
    if shape == "ignored":
        return f"fun c_{use}(n: Int) -> {ty}\n  {v}\n", f"c_{use}(1)"
    if shape == "transitive":
        return base + f"\nfun t_{use}(n: Int) -> {ty}\n  c_{use}()\n", f"t_{use}(1)"
    # Compile-time parameters: the instance is a function as any other, so
    # its result is a run-time value to the caller.
    if shape == "ctbool":
        return f"fun c_{use}[b: Bool](n: Int) -> {ty}\n  {v} if b else {v}\n", f"c_{use}[true](1)"
    if shape == "ctint":
        return f"fun c_{use}[k: Int](n: Int) -> {ty}\n  {v}\n", f"c_{use}[3](1)"
    if shape == "ctenum":
        return f"enum M_{use}\n  a\n  b\n\nfun c_{use}[m: M_{use}](n: Int) -> {ty}\n  {v}\n", f"c_{use}[.b](1)"
    return base + f"\nfun t_{use}[b: Bool](n: Int) -> {ty}\n  c_{use}()\n", f"t_{use}[false](1)"


def program(shape, uses, cond):
    ds, body = [], []
    for u in uses:
        d, call = defs(shape, u)
        ds.append(d)
        body.append(f"    z_{u} = {call}\n    print({USES[u][2].replace('z', 'z_' + u)})\n")
    return ("use std.os\n\n" + "\n".join(ds) + f"\nsub main()\n  xs = [1, 2, 3]\n  print(xs.len)\n  if {cond}\n" + "".join(body) + "  print(\"ok\")\n")


def extra(defs_text, use_text, cond):
    return "use std.os\n\n" + defs_text + f"\nsub main()\n  if {cond}\n" + use_text + "  print(\"ok\")\n"


CTVALUES = """use std.os

enum Mode
  strict
  loose

fun step(i: Int) -> Int
  i + 1

fun scale[k: Int](x: Int) -> Int
  step(x) * k

fun pick[m: Mode](x: Int) -> Int
  x + 1 if m == .strict else x - 1

fun flip[b: Bool](x: Int) -> Int
  x if x <= 0 else flip[not b](x - 1) + (1 if b else 2)

fun sum[dense: Bool](n: Int) -> Int
  total = 0
  i = 0
  while i < n
    total += scale[2](i) if dense else step(i)
    i += 1
  total

sub main()
  n = os.args().len + 3
  print(scale[3](n), pick[.strict](n), pick[.loose](n), flip[true](n))
  print(sum[true](n), sum[false](n))
"""


def indent(text):
    return "".join(("  " + l if l else "") + "\n" for l in text.rstrip("\n").split("\n"))


def case(head, comment, text):
    return head + "\n" + "".join(f"  # {c}\n" for c in comment) + "\n" + indent(text) + "\n"


def cases():
    out = []
    # Each case's program reads its arguments, so no condition is known
    # before it runs: `os.args().len > 50` never holds, `> 0` always does.
    never, always = "os.args().len > 50", "os.args().len > 0"
    for shape in SHAPES:
        out.append(case(f"test \"inline grid {shape} unreached\", release: true, '''\n  3\n  ok\n'''",
                        [f"Every use of {WHAT[shape]}, in a branch that never runs, builds."],
                        program(shape, list(USES), never)))
    out.append(case("test \"inline grid optional unreached\", \"ok\", release: true",
                    ["An empty optional's fallback, divided by in a branch that never runs, builds."],
                    extra("fun nothing() -> Int?\n  none\n", "    z = nothing() ?? 0\n    print(10 / z)\n", never)))
    out.append(case("test \"inline grid failing unreached\", \"ok\", release: true",
                    ["An error's fallback, divided by in a branch that never runs, builds."],
                    extra("error Oops\n  bad\n\nfun fails() -> Int!\n  return Oops.bad\n", "    z = fails() catch 0\n    print(10 / z)\n", never)))
    out.append(case("test \"inline grid var unreached\", \"ok\", release: true",
                    ["A constant held in a second name, divided by in a branch that never runs, builds."],
                    extra("fun zero() -> Int\n  0\n", "    z = zero()\n    var_ = z\n    print(10 / var_)\n", never)))
    out.append(case("test \"inline grid ct values\", release: true, '''\n  15 5 3 6\n  20 10\n'''",
                    ["Instances that compute from run-time arguments, call helpers, and recurse",
                     "through an instance, against the values worked out by hand."],
                    CTVALUES))
    for shape in SHAPES:
        for u in USES:
            # The compile-time shapes run the three uses that panic differently.
            if shape.startswith("ct") and u not in ("div", "overflow8", "index"):
                continue
            out.append(case(f"bomb \"inline grid {shape} {u} reached\", \"{USES[u][3]}\", prints: \"3\", release: true",
                            [f"The {u} use of {WHAT[shape]}, run, panics."],
                            program(shape, [u], always)))
    return out


def text():
    head = ("# The inline grid, written by tools/inline_grid.py (edit it, not this\n"
            "# file): what an inlined function hands back is a run-time value to its\n"
            "# caller, so Zig folds no use of it into a compile error in code that\n"
            "# never runs, and the same use, run, panics.\n\n")
    return head + "".join(cases()).rstrip("\n") + "\n"


def main():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test", "rig", "emit-inline-grid.rig.test")
    want = text()
    if sys.argv[1:] == ["--check"]:
        have = open(path).read() if os.path.exists(path) else ""
        if have != want:
            print(f"{path} is stale: run python3 tools/inline_grid.py")
            sys.exit(1)
        return
    with open(path, "w") as f:
        f.write(want)


if __name__ == "__main__":
    main()
