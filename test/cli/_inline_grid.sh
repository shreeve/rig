# The programs of the inline grid (test/cli/inline_grid.sh and its
# --release shards, inline_grid_release_*.sh): what an inlined function
# hands back is a run-time value to its caller. Sourced after _lib.sh.
#
# inline_grid_write: write every program into the current directory.
# inline_grid_release_reached <shape>...: build each reached program of
# those shapes with --release, and check that it panics.

inline_grid_write() {
python3 - <<'PY'
import os
# use: (callee result type, the value, an expression on z)
USES = {
    "div": ("Int", "0", "10 / z"),
    "overflow": ("Int", "9223372036854775807", "1 + z"),
    "overflow8": ("U8", "U8(255)", "z + U8(1)"),
    "narrow": ("Int", "300", "U8(z)"),
    "shift": ("Int", "70", "1 << z"),
    "index": ("Int", "7", "xs[z]"),
}
SHAPES = ["const", "ignored", "transitive", "ctbool", "ctint", "ctenum", "ctthrough"]

def defs(shape, use):
    ty, v, _ = USES[use]
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

def extra(name, defs_text, use_text, cond):
    return "use std.os\n\n" + defs_text + f"\nsub main()\n  if {cond}\n" + use_text + "  print(\"ok\")\n"

for shape in SHAPES:
    open(f"unreached_{shape}.rig", "w").write(program(shape, list(USES), "os.args().len > 50"))
    # The compile-time shapes run the three uses that panic differently.
    for u in USES:
        if shape.startswith("ct") and u not in ("div", "overflow8", "index"):
            continue
        open(f"reached_{shape}_{u}.rig", "w").write(program(shape, [u], "os.args().len > 0"))
# Instances that compute from run-time arguments, call helpers, and recurse
# through an instance, against the values worked out by hand.
open("ctvalues.rig", "w").write("""use std.os

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
""")
open("unreached_optional.rig", "w").write(extra("o", "fun nothing() -> Int?\n  none\n", "    z = nothing() ?? 0\n    print(10 / z)\n", "os.args().len > 50"))
open("unreached_failing.rig", "w").write(extra("f", "error Oops\n  bad\n\nfun fails() -> Int!\n  return Oops.bad\n", "    z = fails() catch 0\n    print(10 / z)\n", "os.args().len > 50"))
open("unreached_var.rig", "w").write(extra("v", "fun zero() -> Int\n  0\n", "    z = zero()\n    var_ = z\n    print(10 / var_)\n", "os.args().len > 50"))
PY
}

inline_grid_release_reached() {
    local shape f out
    for shape in "$@"; do
        for f in reached_"$shape"_*.rig; do
            rig build --release -o "prog_${f%.rig}" "$f" >build.log 2>&1 || fail "release $f: $(cat build.log)"
            out=$(RIG_NO_CRASH_REPORT=1 ./"prog_${f%.rig}" 2>&1) && fail "release $f should panic: $out"
            expect_has "$out" "panic" "release $f"
        done
    done
}
