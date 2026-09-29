# The standard library's Zig-backed declarations: each is checked at
# Zig compile time against the type its Rig signature lowers to, and
# the checker rejects the ones it could not trust. `RIG_STD` stands in
# for the embedded library.
source "$ROOT/test/cli/_lib.sh"

mkdir lib
printf 'use std.half\n\nsub main()\n  print(half.half(8))\n' >main.rig

# A shim whose function has the Rig signature's type builds and runs.
printf 'extern zig "half.zig"\n  pub fun half(x: Int) -> Int\n' >lib/half.rig
printf 'pub fn half(x: i64) i64 {\n    return @divTrunc(x, 2);\n}\n' >lib/half.zig
out=$(RIG_STD="$PWD/lib" rig run main.rig 2>&1); expect_rc $? 0 "matching shim: $out"
expect_eq "$out" "4" "matching shim"

# One whose type differs fails the build, naming the declaration.
printf 'pub fn half(x: i32) i64 {\n    return @divTrunc(x, 2);\n}\n' >lib/half.zig
out=$(RIG_STD="$PWD/lib" rig run main.rig 2>&1); expect_rc $? 1 "mismatched shim"
expect_has "$out" "rig: the Zig function of \`std.half.half\` has type fn (i32) i64, but its Rig signature lowers to fn (i64) i64" "mismatched shim"

# The checker rejects a generic or fallible Zig-backed function, and a
# Zig file that is missing or not a plain name.
cat >lib/half.rig <<'EOF2'
extern zig "half.zig"
  pub fun half(x: Int) -> Int
  pub fun same[T](x: T) -> T
  pub fun parse(s: String) -> Int!
  pub sub save(s: String)!
EOF2
out=$(RIG_STD="$PWD/lib" "$RIG" check main.rig 2>&1); expect_rc $? 1 "untrusted signatures"
expect_has "$out" "half.rig:3:11: error: a Zig-backed function cannot take compile-time parameters: write \`same\` in Rig" "generic"
expect_has "$out" "half.rig:4:11: error: a Zig-backed function cannot fail" "fallible fun"
expect_has "$out" "half.rig:5:11: error: a Zig-backed function cannot fail" "fallible sub"
printf 'extern zig "../half.zig"\n  pub fun half(x: Int) -> Int\n' >lib/half.rig
out=$(RIG_STD="$PWD/lib" "$RIG" check main.rig 2>&1); expect_rc $? 1 "path"
expect_has "$out" "half.rig:1:12: error: \`extern zig\` names a Zig file of the standard library, \`name.zig\`" "path"
printf 'extern zig "gone.zig"\n  pub fun half(x: Int) -> Int\n' >lib/half.rig
out=$(RIG_STD="$PWD/lib" "$RIG" check main.rig 2>&1); expect_rc $? 1 "missing"
expect_has "$out" "half.rig:1:12: error: the standard library has no Zig file \`gone.zig\`" "missing"
exit 0
