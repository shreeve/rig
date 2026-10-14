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
