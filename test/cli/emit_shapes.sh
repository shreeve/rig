# The shape of the Zig `rig emit` writes for a few constructs: `const`
# unless a binding changes or its initializer is a constant, `try` for
# `!`, `anyerror!T` for fallible types, escaped names, and how a read
# `match` binds its payloads.
source "$ROOT/test/cli/_lib.sh"

cat >hello.rig <<'EOF'
sub main()
  print("hello, rig")
EOF
out=$("$RIG" emit hello.rig 2>/dev/null) || fail "rig emit hello.rig"
expect_has "$out" 'pub fn main(__rig_init: std.process.Init.Minimal) void' "hello"
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
expect_has "$out" '__rig_run_main(__rig_init) catch |err| rig.failMain(err);' "fallible main"
expect_has "$out" 'fn __rig_run_main(__rig_init: std.process.Init.Minimal) anyerror!void' "fallible main body"

cat >names.rig <<'EOF'
sub main()
  var = 3
  rig = 4
  print(var + rig)
EOF
out=$("$RIG" emit names.rig 2>/dev/null) || fail "rig emit names.rig"
expect_has "$out" 'var @"var": i64 = 3;' "Zig keyword"
expect_has "$out" "var @\"rig'\": i64 = 4;" "emitter name"

# A read `match` copies a payload into its arm; a catch-all binding of a
# lent subject is that view, the address of the value switched on.
cat >payload.rig <<'EOF2'
struct Res
  n: Int
  t: Text

enum E
  a(r: Res, k: Int)
  b(r: Res, k: Int)

fun count(e: ?E) -> Int
  match e
    .a(r, k) => r.n + k
    .b(_, k) => k

fun whole(e: ?E) -> Int
  match e
    x => count(x)

fun guarded(e: ?E) -> Int
  match e
    .a(_, k) if k > 5 => k
    x => count(x)

sub main
  e = E.a(r: Res(n: 1, t: Text("x")), k: 2)
  print(whole(?e), guarded(?e))
EOF2
out=$("$RIG" emit payload.rig 2>/dev/null) || fail "rig emit payload.rig"
expect_has "$out" 'const r = __rig_payload_1.r;' "payload copied into the arm"
expect_has "$out" 'else => |*x| count(x),' "catch-all of a lent subject"
expect_has "$out" 'const x = &e.*;' "guarded catch-all of a lent subject"
