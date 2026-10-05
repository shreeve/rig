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
  const user = 1
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

# A read `match` views a payload that is not plain data where it is, and
# a catch-all binding of a lent subject is the address of the value
# switched on.
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
expect_has "$out" 'const r = &__rig_payload_1.r;' "payload viewed where it is"
expect_has "$out" 'else => |*x| count(x),' "catch-all of a lent subject"
expect_has "$out" 'const x = &e.*;' "guarded catch-all of a lent subject"

# Emit takes no address of a Zig temporary value. A `?self` method on a
# value that branches runs on the leaf it takes, through its address,
# never on a copy (`@as(S, if ...)`), so a view it returns views the
# leaf. A Cell-holding field of a temporary is lent, and a method is
# called on a kept temporary, where the statement's slot holds it, never
# through a copy in the call's block.
cat >leaves.rig <<'EOF2'
struct S
  t: Text

  fun inner(?self) -> ?Text
    ?self.t

  fun pick(?self, x: Int, y: Int) -> ?Text
    ?self.t

struct P
  c: Cell[Int]
  n: Int

struct H
  p: P

fun mk -> H
  H(p: P(c: Cell(1), n: 42))

fun mks -> S
  S(t: Text("m"))

fun id(x: ?P) -> ?P
  x

fun f(n: Int) -> Int
  n

sub main
  a = S(t: Text("aa"))
  b = S(t: Text("bb"))
  c = a.t.len == 2
  r = (a if c else b).inner()
  print(r)
  print(id(?mk().p).n)
  print(mks().pick(y: f(1), x: f(2)))
EOF2
out=$("$RIG" emit leaves.rig 2>/dev/null) || fail "rig emit leaves.rig"
expect_has "$out" 'const r = (if (c) &a else &b).inner();' "branching receiver"
expect_has "$out" '= &((rig.keep(&__rig_tmp_' "Cell part lent in its slot"
expect_has "$out" '__rig_recv_' "kept receiver evaluated first"
grep -q '@as(S, (if' <<<"$out" && fail "a branching receiver copied: $out"
grep -qE 'var __rig_(arg|recv)_' <<<"$out" && fail "a temporary copied into the call's block: $out"
grep -qE '__rig_recv_[0-9]+ = &\(rig\.keep\(' <<<"$out" || fail "kept receiver not reached in its slot: $out"

# A `match` on a generic read view a name holds switches on the value
# where the view reaches it, never on a copy (`rig.borrowed`).
cat >generic.rig <<'EOF2'
enum Opt[T]
  some(v: T)
  none

  fun all(?self) -> Int
    match self
      x => size(?x)

fun size[T](v: ?T) -> Int
  1

sub main
  a = Opt.some(v: 3)
  print(a.all())
EOF2
out=$("$RIG" emit generic.rig 2>/dev/null) || fail "rig emit generic.rig"
expect_has "$out" 'switch (rig.borrowedPtr(__rig_Self, &self).*)' "generic subject switched in place"
