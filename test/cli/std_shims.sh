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

# One whose type differs fails the build, naming the declaration, so
# the program does not run.
printf 'pub fn half(x: i32) i64 {\n    return @divTrunc(x, 2);\n}\n' >lib/half.zig
out=$(RIG_STD="$PWD/lib" rig run main.rig 2>&1); expect_rc $? 125 "mismatched shim"
expect_has "$out" "rig: the program did not run" "mismatched shim"
expect_has "$out" "rig: the Zig function of \`std.half.half\` has type fn (i32) i64, but its Rig signature lowers to fn (i64) i64" "mismatched shim"

# The checker rejects a generic Zig-backed function, a fallible one in
# a module that declares no error set, and a Zig file that is missing
# or not a plain name.
cat >lib/half.rig <<'EOF2'
extern zig "half.zig"
  pub fun half(x: Int) -> Int
  pub fun same[T](x: T) -> T
  pub fun parse(s: String) -> Int!
  pub sub save(s: String)!
EOF2
out=$(RIG_STD="$PWD/lib" "$RIG" check main.rig 2>&1); expect_rc $? 1 "untrusted signatures"
expect_has "$out" "half.rig:3:11: error: a Zig-backed function cannot take compile-time parameters: write \`same\` in Rig" "generic"
expect_has "$out" "half.rig:4:11: error: \`parse\` can fail, so its module must declare the errors its Zig function returns: add an error set, \`error Name\`" "fallible fun"
expect_has "$out" "half.rig:5:11: error: \`save\` can fail, so its module must declare the errors" "fallible sub"
printf 'extern zig "../half.zig"\n  pub fun half(x: Int) -> Int\n' >lib/half.rig
out=$(RIG_STD="$PWD/lib" "$RIG" check main.rig 2>&1); expect_rc $? 1 "path"
expect_has "$out" "half.rig:1:12: error: \`extern zig\` names a Zig file of the standard library, \`name.zig\`" "path"
printf 'extern zig "gone.zig"\n  pub fun half(x: Int) -> Int\n' >lib/half.rig
out=$(RIG_STD="$PWD/lib" "$RIG" check main.rig 2>&1); expect_rc $? 1 "missing"
expect_has "$out" "half.rig:1:12: error: the standard library has no Zig file \`gone.zig\`" "missing"

# A fallible Zig-backed function fails with the errors of its module's
# error sets, which its Zig function names as the emitter does:
# `error.@"std.half.Odd.odd"`. The failure is an ordinary Rig error: it
# propagates, is caught, compared, and matched, and the function is a
# value of its Rig type.
cat >lib/half.rig <<'EOF2'
pub error Odd
  odd

error Unused
  never

extern zig "half.zig"
  pub fun half(x: Int) -> Int!
  pub sub even(x: Int)!
EOF2
cat >lib/half.zig <<'EOF2'
const Odd = error{@"std.half.Odd.odd"};

pub fn half(x: i64) Odd!i64 {
    if (@rem(x, 2) != 0) return error.@"std.half.Odd.odd";
    return @divTrunc(x, 2);
}

pub fn even(x: i64) Odd!void {
    _ = try half(x);
}
EOF2
cat >main.rig <<'EOF2'
use std.half

fun twice(f: ?fun(Int) -> Int!, x: Int) -> Int!
  f(f(x)!)!

sub main!
  print(half.half(8)!, twice(half.half, 12)!)
  n = half.half(7) catch |e|
    print(e, e == half.Odd.odd)
    -1
  half.even(3) catch |e|
    match e
      half.Odd.odd => print("odd", n)
      _ => print("other")
  half.even(4)!
  print(twice(half.half, 6)!)
EOF2
out=$(RIG_STD="$PWD/lib" rig run main.rig 2>&1); expect_rc $? 1 "fallible shim: $out"
expect_eq "$out" $'4 3\nOdd.odd true\nodd -1\nerror: Odd.odd' "fallible shim"

# Its Zig function must name the errors it returns, each an error of
# the module's error sets; the build fails otherwise, and the program
# does not run (exit status 125).
printf 'use std.half\n\nsub main!\n  print(half.half(8)!)\n' >main.rig
printf 'pub fn half(x: i64) error{Oops}!i64 {\n    return if (x == 0) error.Oops else x;\n}\npub fn even(x: i64) error{}!void {\n    _ = x;\n}\n' >lib/half.zig
out=$(RIG_STD="$PWD/lib" rig run main.rig 2>&1); expect_rc $? 125 "undeclared error"
expect_has "$out" "rig: the Zig function of \`std.half.half\` returns \`error.Oops\`, which is not an error of module \`std.half\`" "undeclared error"
printf 'pub fn half(x: i64) anyerror!i64 {\n    return x;\n}\npub fn even(x: i64) error{}!void {\n    _ = x;\n}\n' >lib/half.zig
out=$(RIG_STD="$PWD/lib" rig run main.rig 2>&1); expect_rc $? 125 "anyerror"
expect_has "$out" "rig: the Zig function of \`std.half.half\` returns \`anyerror\`; it must name the errors it returns" "anyerror"
printf 'pub fn half(x: i64) i64 {\n    return x;\n}\npub fn even(x: i64) error{}!void {\n    _ = x;\n}\n' >lib/half.zig
out=$(RIG_STD="$PWD/lib" rig run main.rig 2>&1); expect_rc $? 125 "cannot fail"
expect_has "$out" "rig: the Zig function of \`std.half.half\` has type fn (i64) i64, but its Rig signature lowers to fn (i64) E!i64, for an error set E of module \`std.half\`" "cannot fail"
exit 0
