# timeout: 900
# What an inlined function hands back is a run-time value to its caller:
# a result that no argument decides (a constant, a parameter it ignores,
# another inlined call, an empty optional, an error) must not let Zig fold
# the arithmetic, indexing, narrowing, or shift on it into a compile error
# in code the program never runs, and the same use, run, must panic. A grid
# of callee shape x use x mode (debug, --release): each shape gets one
# program with every use in a branch that does not run, and each cell one
# program that runs the use.
source "$ROOT/test/cli/_lib.sh"

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
SHAPES = ["const", "ignored", "transitive"]

def defs(shape, use):
    ty, v, _ = USES[use]
    base = f"fun c_{use}() -> {ty}\n  {v}\n"
    if shape == "const":
        return base, f"c_{use}()"
    if shape == "ignored":
        return f"fun c_{use}(n: Int) -> {ty}\n  {v}\n", f"c_{use}(1)"
    return base + f"\nfun t_{use}(n: Int) -> {ty}\n  c_{use}()\n", f"t_{use}(1)"

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
    for u in USES:
        open(f"reached_{shape}_{u}.rig", "w").write(program(shape, [u], "os.args().len > 0"))
open("unreached_optional.rig", "w").write(extra("o", "fun nothing() -> Int?\n  none\n", "    z = nothing() ?? 0\n    print(10 / z)\n", "os.args().len > 50"))
open("unreached_failing.rig", "w").write(extra("f", "error Oops\n  bad\n\nfun fails() -> Int!\n  return Oops.bad\n", "    z = fails() catch 0\n    print(10 / z)\n", "os.args().len > 50"))
open("unreached_var.rig", "w").write(extra("v", "fun zero() -> Int\n  0\n", "    z = zero()\n    var_ = z\n    print(10 / var_)\n", "os.args().len > 50"))
PY

for mode in debug release; do
    for f in unreached_*.rig; do
        if [[ $mode == debug ]]; then
            out=$(rig run "$f" 2>&1) || fail "$mode $f: $out"
        else
            rig build --release -o "prog_${f%.rig}" "$f" >build.log 2>&1 || fail "release $f: $(cat build.log)"
            out=$(./"prog_${f%.rig}" 2>&1) || fail "release $f ran: $out"
        fi
        case $f in
            unreached_optional.rig|unreached_failing.rig|unreached_var.rig) expect_eq "$out" "ok" "$mode $f" ;;
            *) expect_eq "$out" $'3\nok' "$mode $f" ;;
        esac
    done
    for f in reached_*.rig; do
        if [[ $mode == debug ]]; then
            out=$(rig run "$f" 2>&1) && fail "$mode $f should panic: $out"
        else
            rig build --release -o "prog_${f%.rig}" "$f" >build.log 2>&1 || fail "release $f: $(cat build.log)"
            out=$(./"prog_${f%.rig}" 2>&1) && fail "release $f should panic: $out"
        fi
        expect_has "$out" "panic" "$mode $f"
    done
done
