#!/usr/bin/env python3
"""Write test/rig/emit-markers.rig.test, the cases of the function markers,
and, for test/cli/markers.sh, its programs.

The function markers (SPEC.md, "Function markers"): `inline fun` is
emitted `inline fn` at any size, `called fun` is emitted `noinline fn`,
and a function whose body starts with `rarely` starts with Zig's cold
hint; the last two are never inlined by the compiler's own rule.

    python3 tools/markers.py            # rewrite the test file
    python3 tools/markers.py --check    # exit 1 if it is stale
    python3 tools/markers.py NAME       # print program NAME: kinds, large,
                                        # tested, or chain-N
"""
import os
import re
import sys

SHAPES = """inline fun big(a: Int) -> Int
  x = a
""" + "  x = x * 3 + 1\n" * 20 + """  x

fun small(a: Int) -> Int
  rarely
  a + 1

called fun tiny(a: Int) -> Int
  a - 1

obj Wrap[T]
  value: T

  inline fun get(?@) -> T
    @value

  fun peek(?@) -> T
    rarely
    @value

  called fun same(?@) -> T
    @value

inline fun larger[T](a: T, b: T) -> T
  a if a > b else b

sub main()
  w = Wrap[Int](value: 2)
  print(big(1), small(2), tiny(3), w.get(), w.peek(), w.same(), larger(3, 4))
"""
PLAIN = re.sub(r"^ *rarely\n", "", re.sub(r"^( *)(inline|called) ", r"\1", SHAPES, flags=re.M), flags=re.M)

# std.json's shape: `doc[dense]` has two instances, each calling `number`,
# which is over the size limit, and rarely `utf8_text`.
HELPERS = """DOT: U8 = 0x2E
ZERO: U8 = 0x30
NINE: U8 = 0x39
LOWER_E: U8 = 0x65

fun is_digit(b: U8) -> Bool
  b >= ZERO and b <= NINE
"""
PARSER = """# A number at `i`: its integer part times 100, plus the bytes it spans.
fun number(s: ?String, i: Int) -> Int
  n = 0
  j = i
  while j < s.len and is_digit(s[j])
    n = n * 10 + Int(s[j] - ZERO)
    j += 1
  if j < s.len and s[j] == DOT
    j += 1
    while j < s.len and is_digit(s[j])
      j += 1
  if j < s.len and s[j] == LOWER_E
    j += 1
    e = 0
    while j < s.len and is_digit(s[j])
      e = e * 10 + Int(s[j] - ZERO)
      j += 1
    while e > 0
      n *= 10
      e -= 1
  n * 100 + (j - i)

# A byte past ASCII, which a document rarely holds.
fun utf8_text(s: ?String, i: Int) -> Int
  Int(s[i])

# The parser: `dense` documents keep only the numbers' values.
fun doc[dense: Bool](s: ?String) -> Int
  total = 0
  words = 0
  spaces = 0
  i = 0
  while i < s.len
    b = s[i]
    if b >= 128
      total += utf8_text(s, i)
      i += 1
    else if is_digit(b)
      v = number(s, i)
      total += v / 100 if dense else v
      i += v % 100
    else if b == 0x20 or b == 0x0A or b == 0x09 or b == 0x0D
      spaces += 1
      i += 1
    else if b == 0x2C or b == 0x3A
      words += 2
      i += 1
    else
      words += 1
      i += 1
  if dense
    return total
  j = 0
  lines = 0
  while j < s.len
    if s[j] == 0x0A
      lines += 1
    j += 1
  total + words * 1000000 + spaces * 10000000 + lines * 100000000
"""
DOC = ("# The shape std.json wants: one parser, two compile-time instances that\n"
       "# each call one helper over the size the compiler inlines by itself.\n\n"
       + HELPERS + "\n" + PARSER + "\nsub main()\n  s = \"12 3 4.5 2e2 é\"\n  print(doc[true](s), doc[false](s))\n")


def marked(text):
    return re.sub(r"^(fun utf8_text[^\n]*\n)", r"\1  rarely\n", re.sub(r"^fun number", "inline fun number", text, flags=re.M), flags=re.M)


def called(text):
    return re.sub(r"^fun doc", "called fun doc", marked(text), flags=re.M)


MARKED = marked(DOC)
CALLED = called(DOC)


def renamed(text, k, add):
    """The parser with its functions named for its kind `k`, and its
    `utf8_text` adding `add` to the byte, so that no two of them are the
    same function, which LLVM would merge into one."""
    text = text.replace("  Int(s[i])\n", f"  Int(s[i]) + {add}\n")
    return re.sub(r"\b(number|utf8_text|doc)\b(?=[\[(])", r"\1_" + k, text)


# The three parsers in one program, for the symbols of one --release
# build: `_d` unmarked, `_m` marked, `_c` marked and `called`. Each
# `utf8_text` adds its own count to the two bytes of the `é`.
KINDS = (HELPERS + "\n" + renamed(PARSER, "d", 0) + "\n" + renamed(marked(PARSER), "m", 1) + "\n" + renamed(called(PARSER), "c", 2)
         + "\nsub main()\n  s = \"12 3 4.5 2e2 é\"\n"
         + "".join(f"  print(doc_{k}[true](s), doc_{k}[false](s))\n" for k in "dmc"))

# A marked `inline` function whose frame alone would make it `noinline`
# (4 times its reach passes 1 MiB).
LARGE = """inline fun huge(i: Int) -> Int
  t = [40000 of i]
  t[i % 40000]

fun near(i: Int) -> Int
  huge(i) + 1

sub main()
  print(near(3))
"""

TESTED = """inline fun twice(n: Int) -> Int
  n * 2

fun fallback(n: Int) -> Int
  rarely
  0 - n

called fun kept(n: Int) -> Int
  n + 100

sub main()
  print(twice(1))

test "markers"
  print(twice(3), fallback(4), kept(5))
"""


def chain(n):
    """`main` calls g0, and each marked g_i calls g_(i+1), n deep."""
    out = "".join(f"inline fun g{i}(x: Int) -> Int\n  g{i + 1}(x) + 1\n\n" for i in range(n))
    return out + f"fun g{n}(x: Int) -> Int\n  x\n\nsub main()\n  print(g0(0))\n"


def indent(text):
    return "".join(("  " + l if l else "") + "\n" for l in text.rstrip("\n").split("\n"))


def case(head, comment, text):
    return head + "\n" + "".join(f"  # {c}\n" for c in comment) + "\n" + indent(text) + "\n"


def lacks(s):
    return "/^(?![\\s\\S]*" + re.escape(s).replace("/", "\\/") + ")/"


def text():
    quota = r"@setEvalBranchQuota\(rig\.eval_quota\);"
    cold = r"@branchHint\(\.cold\);"
    out = [
        "# The function markers, written by tools/markers.py (edit it, not this\n"
        "# file): `inline fun` is emitted `inline fn` at any size, `called fun`\n"
        "# `noinline fn`, and a body that starts with `rarely` starts with Zig's\n"
        "# cold hint; the last\n"
        "# two are never inlined by the compiler's own rule, and no marker changes\n"
        "# what a program does (test/cli/markers.sh reads the symbols of an\n"
        "# optimized build, and the limits `rig check` holds).\n\n",
        case("code \"markers each shape\", "
             "\"pub inline fn big(__rig_in_a: i64) i64 {\", \"pub inline fn get(\", \"pub inline fn larger(comptime T: type, \", "
             "\"pub fn small(a: i64) i64 {\", \"pub noinline fn tiny(a: i64) i64 {\", \"pub noinline fn same(\", "
             f"/fn tiny\\([^\\n]*\\n    {quota}\\n/, "
             f"/fn small\\([^\\n]*\\n    {cold}\\n    {quota}\\n/, "
             f"/fn peek\\([^\\n]*\\n *{cold}\\n/",
             ["`inline` over the size limit, of a generic type's method, and with a type",
              "parameter is `inline fn`; `rarely` is not inlined, and starts with the",
              "cold hint; `called` is `noinline`, with no cold hint."], SHAPES),
        case("code \"markers none, the compiler's rule decides\", "
             "\"pub fn big(a: i64) i64 {\", \"pub inline fn small(\", \"pub fn larger(comptime T: type, \", "
             + lacks("@branchHint") + ", " + lacks("noinline"),
             ["Without the markers, the compiler's rule decides: `big` is over its size",
              "and is called; `small`, `get`, and `peek` are inlined; `larger`, generic",
              "over a type, is not; no function is cold or `noinline`."], PLAIN),
        case("test \"markers change no meaning\", \"5230176601 3 2 2 2 2 4\", release: true",
             ["A marker changes no meaning: the program prints the same without them."], SHAPES),
        case("test \"markers none change no meaning\", \"5230176601 3 2 2 2 2 4\", release: true",
             ["The same program without its markers."], PLAIN),
        case("code \"markers json shape unmarked\", "
             "\"pub fn number(s: []const u8, i: i64) i64 {\", \"pub inline fn utf8_text(\", \"pub fn doc(comptime dense: bool, \"",
             ["std.json's shape: `doc[dense]` is one Zig function of two instances,",
              "each calling `number`, over the size limit, and rarely `utf8_text`."], DOC),
        case("code \"markers json shape marked\", "
             "\"pub inline fn number(__rig_in_s: []const u8, __rig_in_i: i64) i64 {\", \"pub fn utf8_text(s: []const u8, i: i64) i64 {\", "
             f"/fn utf8_text\\([^\\n]*\\n    {cold}\\n/",
             ["Marked, `number` is inlined into each instance, and `utf8_text` is",
              "called, and cold."], MARKED),
        case("code \"markers json shape called\", "
             "\"pub noinline fn doc(comptime dense: bool, s: []const u8) i64 {\", \"pub inline fn number(\"",
             ["A `called` parser is `noinline`, each instance, and `number` is still",
              "inlined."], CALLED),
    ]
    for name, prog in (("unmarked", DOC), ("marked", MARKED), ("called", CALLED)):
        out.append(case(f"test \"markers json shape {name} runs\", \"583 40022273\", release: true",
                        [f"The {name} parser computes what the others do."], prog))
    out += [
        case("code \"markers inline over the frame limit\", \"pub inline fn huge(\", "
             + lacks("noinline fn huge(") + ", \"pub noinline fn near(\"",
             ["A marked `inline` function whose frame alone would make it `noinline`",
              "(4 times its reach passes 1 MiB) is still written `inline fn`: its",
              "values land in its caller, whose account holds them, and the caller is",
              "the frame written `noinline`."], LARGE),
        case("test \"markers inline over the frame limit runs\", \"4\", release: true",
             ["The large marked function's caller computes."], LARGE),
        case("test \"markers inline nest 256 deep\", \"256\"",
             ["Calls of marked `inline` functions nest at most 256 deep",
              "(`typecheck.max_inline_depth`): Zig analyzes each inlined body inside",
              "the one around it, and runs out of its own stack some thousands deep.",
              "`main` calls g0, and each marked g_i calls g_(i+1), 256 deep."], chain(256)),
    ]
    return "".join(out).rstrip("\n") + "\n"


def main():
    args = sys.argv[1:]
    progs = {"kinds": KINDS, "large": LARGE, "tested": TESTED}
    if len(args) == 1 and (args[0] in progs or args[0].startswith("chain-")):
        sys.stdout.write(progs[args[0]] if args[0] in progs else chain(int(args[0][6:])))
        return
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test", "rig", "emit-markers.rig.test")
    new = text()
    if args == ["--check"]:
        have = open(path).read() if os.path.exists(path) else ""
        if have != new:
            print(f"{path} is stale: run python3 tools/markers.py")
            sys.exit(1)
        return
    with open(path, "w") as f:
        f.write(new)


if __name__ == "__main__":
    main()
