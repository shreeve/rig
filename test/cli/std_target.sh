# std.target: `target.arch` is the architecture of the machine the
# program is compiled for, which is this one (`uname -m`), and a choice
# on it reaches Zig as a compile-time choice, both branches intact.
source "$ROOT/test/cli/_lib.sh"

cat >arch.rig <<'EOF'
use std.target

TIER = 0 if target.arch == .x86_64 else 16

sub main()
  print(target.arch, TIER)
EOF

case "$(uname -m)" in
    arm64 | aarch64) want=".aarch64 16" ;;
    x86_64 | amd64) want=".x86_64 0" ;;
    *) want="" ;;
esac
out=$(rig run arch.rig 2>&1); expect_rc $? 0 "rig run arch.rig: $out"
if [[ -n $want ]]; then
    expect_eq "$out" "$want" "target.arch is this machine's architecture"
fi

# The constant's branch is Zig's: Rig folds neither branch away, and the
# module's `arch` is Zig's own `builtin.cpu.arch`, as Rig's `Arch`.
"$RIG" emit arch.rig >arch.zig 2>err.txt || fail "rig emit: $(cat err.txt)"
expect_has "$(cat arch.zig)" 'pub const TIER: i64 = @as(i64, if (' "a compile-time choice"
expect_has "$(cat arch.zig)" '.arch == .x86_64) 0 else 16);' "both branches survive"
grep -q "pub const arch: rig.Arch = " "$RIG_OUT_DIR"/*.zig || fail "std.target's arch is not Rig's Arch"
expect_has "$(cat "$RIG_OUT_DIR/rig/std/target.zig")" "pub const arch = builtin.cpu.arch;" "Zig's arch"
expect_has "$(cat "$RIG_OUT_DIR/rig/runtime.zig")" "pub const Arch = std.Target.Cpu.Arch;" "Rig's Arch is Zig's"

# A Zig-backed constant may also be a `Bool` or an integer: Rig knows its
# type, and Zig its value, so a place that needs the value rejects it.
# `RIG_STD` stands in for the embedded library.
mkdir lib
cat >lib/facts.rig <<'EOF'
extern zig "facts.zig"
  pub wide: Bool
  pub bits: U16
EOF
printf 'pub const wide = true;\npub const bits = 64;\n' >lib/facts.zig
cat >facts.rig <<'EOF'
use std.facts

LANES = 32 if facts.wide else 16

sub main()
  print(facts.wide, facts.bits + 1, LANES)
EOF
out=$(RIG_STD="$PWD/lib" rig run facts.rig 2>&1); expect_rc $? 0 "Bool and integer Zig-backed constants: $out"
expect_eq "$out" "true 65 32" "Bool and integer Zig-backed constants"
cat >sized.rig <<'EOF'
use std.facts

sub main()
  a: [facts.bits]U8 = [4 of 0]
  print(a)
EOF
out=$(RIG_STD="$PWD/lib" "$RIG" check sized.rig 2>&1); expect_rc $? 1 "an integer Zig-backed constant as an array length"
expect_has "$out" "sized.rig:4:7: error: an array length must be known when Rig checks the program; the value of \`facts.bits\` is chosen for each target" "an integer Zig-backed constant as an array length"
cat >lib/facts.rig <<'EOF'
extern zig "facts.zig"
  pub name: String
EOF
out=$(RIG_STD="$PWD/lib" "$RIG" check facts.rig 2>&1); expect_rc $? 1 "a String Zig-backed constant"
expect_has "$out" "a Zig-backed constant is a \`Bool\`, an integer, or a built-in enum, not \`String\`" "a String Zig-backed constant"
