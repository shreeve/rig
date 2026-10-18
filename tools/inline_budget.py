#!/usr/bin/env python3
"""Write the inline budget's programs: test/rig/emit-inline-budget.rig.test,
and, for test/cli/inline_budget.sh, the programs of its grid.

Zig charges every inline call, Rig's inlined functions and the runtime's
`inline fn` helpers (`rig.addProven`, ...) alike, to the compile-time
evaluation budget of the function the code lands in, and fails a build
that passes it. Every emitted function that is not inline raises it
first (`rig.eval_quota`), so no count of inline calls stops a build.

    python3 tools/inline_budget.py               # rewrite the test file
    python3 tools/inline_budget.py --check       # exit 1 if it is stale
    python3 tools/inline_budget.py grid N SHAPE  # print one grid program
    python3 tools/inline_budget.py want N SHAPE  # what it prints

A grid program holds N calls of each of its shapes (SHAPE `all` is every
shape in one program):
  plain    N calls of an inlined helper
  value    N calls of an inlined instance of a compile-time-value function
  nested   N calls of an inlined helper that calls another twice
  proven   one function with N proven adds (`rig.addProven`)
  helpers  N calls of an inlined helper holding six proven adds
  ctproven the same through an instance (`bump[1]`)
  forced   N calls of a helper marked `inline`, over the size the
           compiler inlines by itself, holding twelve proven adds
"""
import os
import sys

SHAPES = ["plain", "value", "nested", "proven", "helpers", "ctproven", "forced"]
ADD = "  if i + 1 <= s.len\n    i += 1\n"
SIX = ADD * 6
CALLS = {
    "plain": "  n = inc(n)\n",
    "value": "  n = step[1](n)\n",
    "nested": "  n = twice(n)\n",
    "helpers": "  n = n + bump(s, 0)\n",
    "ctproven": "  n = n + cbump[1](s, 0)\n",
    "forced": "  n = n + fbump(s, 0)\n",
}


def grid(n, shapes):
    out = ("fun inc(x: Int) -> Int\n  x + 1\n\n"
           "fun step[k: Int](x: Int) -> Int\n  inc(x) + k - 1\n\n"
           "fun twice(x: Int) -> Int\n  inc(inc(x))\n\n"
           "fun bump(s: ?String, at: Int) -> Int\n  i = at\n" + SIX + "  i - at\n\n"
           "fun cbump[k: Int](s: ?String, at: Int) -> Int\n  i = at\n" + SIX + "  i - at + k - 1\n\n"
           "inline fun fbump(s: ?String, at: Int) -> Int\n  i = at\n" + SIX + SIX + "  i - at\n\n"
           "fun many(s: ?String) -> Int\n  i = 0\n")
    if "proven" in shapes:
        out += ADD * n
    out += "  i\n\nsub main()\n  s = \"abcdefghijklmnopqrstuvwxyz\"\n  n = 0\n"
    for shape in shapes:
        if shape in CALLS:
            out += CALLS[shape] * n
    return out + "  print(n + many(s))\n"


def want(n, shapes):
    each = {"nested": 2 * n, "proven": min(n, 26), "helpers": 6 * n, "ctproven": 6 * n, "forced": 12 * n}
    return sum(each.get(s, n) for s in shapes)


# The probes of the review that found the class.
PLAIN_FN = "fun big(s: ?String) -> Int\n  i = 0\n" + ADD * 1100 + "  i\n\nsub main()\n  print(big(\"abcdefghijklmnopqrstuvwxyz\"))\n"
HELPERS = ("fun bump(s: ?String, at: Int) -> Int\n  i = at\n" + SIX + "  i\n\nsub main()\n  s = \"abcdefghijklmnopqrstuvwxyz\"\n  n = 0\n"
           + "  n = bump(s, 0) + n - bump(s, 0)\n" * 120 + "  print(n)\n")
CT_INSTANCE = ("fun bump[k: Int](s: ?String, at: Int) -> Int\n  i = at\n" + SIX + "  i + k - 1\n\nsub main()\n  s = \"abcdefghijklmnopqrstuvwxyz\"\n  n = 0\n"
               + "  n = bump[1](s, 0) + n - bump[1](s, 0)\n" * 120 + "  print(n)\n")
OVER = "fun inc(x: Int) -> Int\n  x + 1\n\nsub main()\n  n = 0\n" + "  n = inc(n)\n" * 300 + "  print(n)\n"
UNDER = ("fun bump(s: ?String, at: Int) -> Int\n  i = at\n" + SIX + "  i - at\n\nsub main()\n  s = \"abcdefghijklmnopqrstuvwxyz\"\n  n = 0\n"
         + "  n = n + bump(s, 0)\n" * 250 + "  print(n)\n")


def indent(text):
    return "".join(("  " + l if l else "") + "\n" for l in text.rstrip("\n").split("\n"))


def case(head, comment, text):
    return head + "\n" + "".join(f"  # {c}\n" for c in comment) + "\n" + indent(text) + "\n"


def text():
    quota = r"@setEvalBranchQuota\(rig\.eval_quota\);"
    out = [
        "# The inline budget, written by tools/inline_budget.py (edit it, not this\n"
        "# file): Zig charges every inline call to the evaluation budget of the\n"
        "# function the code lands in, and every emitted function that is not\n"
        "# inline raises it first (`rig.eval_quota`), so no count of inline calls\n"
        "# stops a build (test/cli/inline_budget.sh builds the grid of counts).\n\n",
        case("test \"inline budget proven adds in a plain fn\", \"26\", release: true",
             ["1,100 proven adds in one function, a probe of the review that found the class."], PLAIN_FN),
        case("test \"inline budget runtime inline helpers\", \"0\", release: true",
             ["240 calls of an inlined helper holding six proven adds."], HELPERS),
        case("test \"inline budget ct instance proven adds\", \"0\", release: true",
             ["The same through an instance, `bump[1]`."], CT_INSTANCE),
        case("code \"inline budget 300 calls stay inlined\", \"pub inline fn inc(\"",
             ["No count of calls stops inlining: 300 calls of a helper leave it inlined."], OVER),
        case("code \"inline budget 250 calls of six adds stay inlined\", \"pub inline fn bump(\", \"rig.addProven(\"",
             ["Nor do 250 calls of one holding six proven adds (1,750 inline calls in",
              "main), and the adds stay proven."], UNDER),
        case("test \"inline budget 250 calls of six adds\", \"1500\", release: true",
             ["What those 1,750 inline calls in main compute."], UNDER),
        case("code \"inline budget marked helper over the size limit\", \"pub inline fn fbump(\", /(?:rig\\.addProven\\([\\s\\S]*?){12}/",
             ["The marked helper is inlined, over the size limit, its adds proven."], grid(100, ["forced"])),
        case("code \"inline budget raised first in each fn not inline\", "
             "/(?:rig\\.addProven\\([\\s\\S]*?){1000}/, "
             f"/^fn __rig_run_main\\([^\\n]*\\n[^\\n]*{quota}/m, "
             f"/^pub fn many\\([^\\n]*\\n[^\\n]*{quota}/m, "
             "/^(?![\\s\\S]*pub inline fn [^\\n]*(?:\\n[^\\n]*)?@setEvalBranchQuota)/",
             ["Each function that is not inline raises its budget first; an inline",
              "one runs on its caller's. `main`'s body is `__rig_run_main`, which",
              "`main` runs on the program's stack. All 1,000 adds of `many` are proven."],
             grid(1000, ["proven"])),
    ]
    return "".join(out).rstrip("\n") + "\n"


def main():
    if len(sys.argv) == 4 and sys.argv[1] in ("grid", "want"):
        n, shape = int(sys.argv[2]), sys.argv[3]
        shapes = SHAPES if shape == "all" else [shape]
        sys.stdout.write(grid(n, shapes) if sys.argv[1] == "grid" else f"{want(n, shapes)}\n")
        return
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test", "rig", "emit-inline-budget.rig.test")
    new = text()
    if sys.argv[1:] == ["--check"]:
        have = open(path).read() if os.path.exists(path) else ""
        if have != new:
            print(f"{path} is stale: run python3 tools/inline_budget.py")
            sys.exit(1)
        return
    with open(path, "w") as f:
        f.write(new)


if __name__ == "__main__":
    main()
