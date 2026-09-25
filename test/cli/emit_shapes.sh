# The shape of the Zig `rig emit` writes for a few constructs: `const`
# unless a binding changes or its initializer is a constant, `try` for
# `!`, `anyerror!T` for fallible types, and escaped names.
source "$ROOT/test/cli/_lib.sh"

cat >hello.rig <<'EOF'
sub main()
  print "hello, rig"
EOF
out=$("$RIG" emit hello.rig 2>/dev/null) || fail "rig emit hello.rig"
expect_has "$out" 'pub fn main() void' "hello"
expect_has "$out" 'rig.print(.{ "hello, rig" })' "hello"

cat >bindings.rig <<'EOF'
fun two() -> Int
  2

sub main()
  x = 1
  y = two()
  z = 5
  user =! 1
  if y > 1
    x = 3
  print(x + y + z + user)
EOF
out=$("$RIG" emit bindings.rig 2>/dev/null) || fail "rig emit bindings.rig"
expect_has "$out" 'var x: i64 = 1;' "reassigned binding"
expect_has "$out" 'const y: i64 = two();' "unchanged binding"
# A constant initializer is kept out of Zig's compile-time evaluation.
expect_has "$out" 'var z: i64 = 5;' "constant initializer"
expect_has "$out" 'const user: i64 = 1;' "fixed binding"
expect_has "$out" 'x = 3;' "reassignment"

cat >fallible.rig <<'EOF'
fun bar() -> Int!
  2

fun foo() -> Int!
  bar()!

sub main()
  x = foo()!
  print(x)
EOF
out=$("$RIG" emit fallible.rig 2>/dev/null) || fail "rig emit fallible.rig"
expect_has "$out" 'try bar()' "propagate"
expect_has "$out" 'pub fn foo() anyerror!i64' "fallible return type"
expect_has "$out" 'pub fn main() anyerror!void' "fallible main"

cat >names.rig <<'EOF'
sub main()
  var = 3
  rig = 4
  print(var + rig)
EOF
out=$("$RIG" emit names.rig 2>/dev/null) || fail "rig emit names.rig"
expect_has "$out" 'var @"var": i64 = 3;' "Zig keyword"
expect_has "$out" "var @\"rig'\": i64 = 4;" "emitter name"
