# `rig emit` prints the root module's Zig and writes the whole package
# (every module plus the runtime) to $RIG_OUT_DIR, which Zig can build
# on its own.
source "$ROOT/test/cli/_lib.sh"

cat >shapes.rig <<'EOF'
pub fun area(w: Int, h: Int) -> Int
  w * h
EOF
cat >main.rig <<'EOF'
use shapes

sub main()
  print(shapes.area(2, 3))
EOF

"$RIG" emit main.rig >main.zig 2>err.txt || fail "rig emit: $(cat err.txt)"
expect_has "$(cat main.zig)" 'const shapes = @import("shapes.zig");' "emitted root module"
expect_has "$(cat main.zig)" "pub fn main() void" "emitted root module"
expect_has "$(cat err.txt)" "$RIG_OUT_DIR" "note naming the package directory"
cmp -s main.zig "$RIG_OUT_DIR/main.zig" || fail "stdout differs from the written root module"
[[ -f "$RIG_OUT_DIR/shapes.zig" ]] || fail "imported module not written"
[[ -f "$RIG_OUT_DIR/rig/runtime.zig" ]] || fail "runtime not written"

here=$PWD
(cd "$RIG_OUT_DIR" && ${ZIG:-zig} build-exe main.zig -femit-bin="$here/prog") || fail "the package does not build on its own"
expect_eq "$(./prog)" "6" "package built with zig build-exe"

cat >bad.rig <<'EOF'
sub main()
  print(missing)
EOF
"$RIG" emit bad.rig >bad.zig 2>err.txt; expect_rc $? 1 "emit of a rejected program"
[[ ! -s bad.zig ]] || fail "a rejected program was emitted"
expect_has "$(cat err.txt)" "bad.rig:2:" "diagnostic position"
exit 0
