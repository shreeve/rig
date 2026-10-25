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
expect_has "$(cat main.zig)" '_shapes = @import("shapes.zig");' "emitted root module"
expect_has "$(cat main.zig)" "pub fn main(__rig_init: std.process.Init.Minimal) void" "emitted root module"
expect_has "$(cat err.txt)" "$RIG_OUT_DIR" "note naming the package directory"
cmp -s main.zig "$RIG_OUT_DIR/__rig_main.zig" || fail "stdout differs from the written root module"
[[ -f "$RIG_OUT_DIR/shapes.zig" ]] || fail "imported module not written"
[[ -f "$RIG_OUT_DIR/rig/runtime.zig" ]] || fail "runtime not written"

# Output is streamed: appending to a file appends.
"$RIG" emit main.rig >>twice.zig 2>/dev/null
"$RIG" emit main.rig >>twice.zig 2>/dev/null
expect_eq "$(cat twice.zig)" "$(cat main.zig main.zig)" "emit >> file"

here=$PWD
(cd "$RIG_OUT_DIR" && ${ZIG:-zig} build-exe __rig_main.zig -femit-bin="$here/prog") || fail "the package does not build on its own"
expect_eq "$(./prog)" "6" "package built with zig build-exe"

# Only a program that names `time.since_start` or `os.memory` asks the
# runtime for the clock's reading at its start or the allocator's counts;
# any other compiles to the runtime without them.
cat >clock.rig <<'EOF'
use std.os
use std.time

sub main()
  t = time.now()
  print(os.args().len > 0, t.elapsed() >= 0)
EOF
cat >reads.rig <<'EOF'
use std.os
use std.time

sub main()
  read: fun() -> Int = time.since_start
  print(read() >= 0, os.memory().allocs >= 0)
EOF
"$RIG" emit clock.rig >clock.zig 2>/dev/null || fail "rig emit clock.rig"
grep -qE "__rig_since_start|__rig_memory" clock.zig && fail "a program naming neither asks for them: $(grep __rig_ clock.zig)"
"$RIG" emit reads.rig >reads.zig 2>/dev/null || fail "rig emit reads.rig"
expect_has "$(cat reads.zig)" "pub const __rig_since_start = true;" "a program naming time.since_start"
expect_has "$(cat reads.zig)" "pub const __rig_memory = true;" "a program naming os.memory"
expect_eq "$("$RIG" run --release reads.rig 2>&1)" "true true" "since_start and memory in a release build"

cat >bad.rig <<'EOF'
sub main()
  print(missing)
EOF
"$RIG" emit bad.rig >bad.zig 2>err.txt; expect_rc $? 1 "emit of a rejected program"
[[ ! -s bad.zig ]] || fail "a rejected program was emitted"
expect_has "$(cat err.txt)" "bad.rig:2:" "diagnostic position"
exit 0
