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
expect_has "$out" 'rig.print(.{ "hello, rig", "\n" })' "hello"

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
expect_has "$out" 'const y: i64 = rig.rt(two());' "unchanged binding"
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
expect_has "$out" 'try rig.rt(bar())' "propagate"
expect_has "$out" 'pub inline fn foo() anyerror!i64' "fallible return type"
expect_has "$out" 'rig.onOwnStack(__rig_run_main, .{__rig_init}) catch |__rig_failed| rig.failMain(__rig_failed);' "fallible main"
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
obj Res
  n: Int
  t: String

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

sub main()
  e = E.a(r: Res(n: 1, t: String("x")), k: 2)
  print(whole(?e), guarded(?e))
EOF2
out=$("$RIG" emit payload.rig 2>/dev/null) || fail "rig emit payload.rig"
expect_has "$out" 'const r = &__rig_payload_1.r;' "payload viewed where it is"
expect_has "$out" 'else => |*x| rig.rt(count(x)),' "catch-all of a lent subject"
expect_has "$out" 'const x = &e.*;' "guarded catch-all of a lent subject"

# Emit takes no address of a Zig temporary value. A `?self` method on a
# value that branches runs on the leaf it takes, through its address,
# never on a copy (`@as(S, if ...)`), so a view it returns views the
# leaf. A Cell-holding field of a temporary is lent, and a method is
# called on a kept temporary, where the statement's slot holds it, never
# through a copy in the call's block.
cat >leaves.rig <<'EOF2'
obj S
  t: String

  fun inner(?self) -> ?String
    ?self.t

  fun pick(?self, x: Int, y: Int) -> ?String
    ?self.t

fun mks() -> S
  S(t: String("m"))

fun f(n: Int) -> Int
  n

sub main()
  a = S(t: String("aa"))
  b = S(t: String("bb"))
  c = a.t.len == 2
  r = (a if c else b).inner()
  print(r)
  print(mks().pick(y: f(1), x: f(2)))
EOF2
out=$("$RIG" emit leaves.rig 2>/dev/null) || fail "rig emit leaves.rig"
expect_has "$out" 'const r: []const u8 = rig.rt((if (c) &a else &b).inner());' "branching receiver"
expect_has "$out" '__rig_recv_' "kept receiver evaluated first"
grep -q '@as(S, (if' <<<"$out" && fail "a branching receiver copied: $out"
grep -qE 'var __rig_(arg|recv)_' <<<"$out" && fail "a temporary copied into the call's block: $out"
grep -qE '__rig_recv_[0-9]+ = &\(rig\.keep\(' <<<"$out" || fail "kept receiver not reached in its slot: $out"

# A `match` on a generic read view a name holds switches on the value
# where the view reaches it, never on a copy (`rig.viewed`).
cat >generic.rig <<'EOF2'
enum Opt[T]
  some(v: T)
  nothing

  fun all(?self) -> Int
    match self
      x => size(?x)

fun size[T](v: ?T) -> Int
  1

sub main()
  a = Opt.some(v: 3)
  print(a.all())
EOF2
out=$("$RIG" emit generic.rig 2>/dev/null) || fail "rig emit generic.rig"
expect_has "$out" 'switch (rig.viewedPtr(__rig_Self, &self).*)' "generic subject switched in place"

# So does one on a generic read view a field or an element holds (`w.r`,
# `arr[1]`), guarded or not: emit never takes the address of a field of
# a `rig.viewed(...)` copy, and never switches on one, whose payloads
# would be captured by pointer into a Zig temporary.
cat >viewfield.rig <<'EOF2'
enum Opt[T]
  some(v: T)
  nothing

obj V[T]
  r: ?Opt[T]

fun look[T](x: ?T) -> Int
  1

fun f[T](w: ?V[T]) -> Int
  match w.r
    .some(v) => look(?v)
    .nothing => 0

fun g[T](w: ?V[T]) -> Int
  match w.r
    .some(v) if look(?v) == 1 => look(?v) + 1
    _ => 0

fun h[T](a: ?Opt[T], b: ?Opt[T]) -> Int
  arr = [a, b]
  n = match arr[1]
    .some(v) if look(?v) == 1 => look(?v)
    _ => 0
  m = match arr[0]
    .some(v) => look(?v)
    .nothing => 0
  n + m

sub main()
  o = Opt.some(v: String("t"))
  w = V(r: ?o)
  print(f(?w), g(?w), h(?o, ?o))
EOF2
out=$("$RIG" emit viewfield.rig 2>/dev/null) || fail "rig emit viewfield.rig"
expect_has "$out" 'switch (rig.viewedPtr(Opt(T), &w.r).*)' "generic view in a field switched in place"
expect_has "$out" '&rig.viewedPtr(Opt(T), &w.r).*.some.v' "guarded payload of a generic view in a field"
grep -qF '&rig.viewed(' <<<"$out" && fail "the address of a field of a rig.viewed copy: $out"
grep -qE 'switch \(rig\.viewed\(' <<<"$out" && fail "a switch on a rig.viewed copy: $out"

# Under the sanitizer, each storage location emit adds is filled with
# `0xAA` when its scope ends (`rig.poison`), after its drop; without it,
# nothing is written.
cat >poison.rig <<'EOF2'
fun mk(n: Int) -> List[Int]!
  v: List[Int] = List()
  !v.push(n)
  v

fun pair(a: List[Int], b: List[Int]) -> Int
  a[0] + b[0]

fun run() -> Int!
  pair(mk(1)!, mk(2)!)

sub main()
  print(run() catch 0, String("abc").len)
EOF2
out=$(RIG_SANITIZE=1 "$RIG" emit poison.rig 2>/dev/null) || fail "rig emit poison.rig"
expect_has "$out" 'defer rig.poison(&__rig_arg_' "hoisted argument poisoned"
expect_has "$out" 'defer rig.poison(&__rig_tmp_' "statement temporary poisoned"
grep -qE 'rig\.drop\(&__rig_tmp_[0-9]+\); \} rig\.poison\(&__rig_tmp_' <<<"$out" || fail "statement temporary not poisoned when the statement ends: $out"
out=$(RIG_SANITIZE=0 "$RIG" emit poison.rig 2>/dev/null) || fail "rig emit poison.rig"
grep -q 'rig.poison' <<<"$out" && fail "poisoned without the sanitizer: $out"
out=$(RIG_SANITIZE=1 "$RIG" run poison.rig 2>&1) || fail "rig run poison.rig: $out"
expect_eq "$out" "3 3" "poisoned program runs"

# The read view of a String is its bytes wherever it is bound: `?t`, a loop
# over String elements, a payload, an `as` binding, a capture, and a
# generic `?T` at `T = String`. No Zig names a pointer to a String as a
# view, and `+s` of a `?String` makes a String.
cat >textview.rig <<'EOF2'
enum Slot
  full(item: String)
  empty

fun same[T](a: ?T, b: ?T) -> Bool
  a == b

fun size(s: ?String) -> Int
  s.len

sub main()
  t = String("abc")
  v = ?t
  names: List[String] = List()
  !names.push(String("x"))
  for x in ?names
    print(size(?x))
  o: String? = String("o")
  if ?o as p
    print(size(?p))
  slot = Slot.full(item: String("s"))
  match ?slot
    .full(item) => print(size(?item))
    .empty => pass
  show = |?t| print(t)
  show()
  u = +v
  print(same(?t, ?t), u, v)
EOF2
out=$("$RIG" emit textview.rig 2>/dev/null) || fail "rig emit textview.rig"
expect_has "$out" 'const v: []const u8 = t.bytes();' "?t is the Text's bytes"
expect_has "$out" 'const x = __rig_elem_' "a loop binds each element's bytes"
expect_has "$out" 'const p = __rig_opt_' "an as binding is the bytes"
expect_has "$out" 'const item = __rig_payload_' "a payload binding is the bytes"
expect_has "$out" '.cap_t = t.bytes()' "a capture is the bytes"
expect_has "$out" 'same(rig.String, t.bytes(), t.bytes())' "a generic ?T at a Text is the bytes"
expect_has "$out" 'var u = rig.String.of(.{ v });' "+s of a String makes a Text"
grep -q '\*const rig.String' <<<"$out" && fail "a pointer view of a Text: $out"
true

cat >loop_index.rig <<'EOF2'
sub main()
  xs = [1, 2, 3]
  for x, i in ?xs[..]
    print(x, i)
EOF2
out=$("$RIG" emit loop_index.rig 2>/dev/null) || fail "rig emit loop_index.rig"
expect_has "$out" '@as(i64, @bitCast(@as(u64, __rig_i_' "a loop index reads the counter's bits"
grep -qF '@intCast(__rig_i_' <<<"$out" && fail "a loop index is range-checked each iteration: $out"

# The mask helpers are inlined into their callers: called, a wide mask
# is taken apart lane by lane. (Their asm, checked by hand with
# `zig build-obj -target aarch64-macos`, has no `umov` and no call.)
for f in maskBits maskBitsNot maskFirst maskAny maskAll nibbleMask foldBytes maskBytes opaqueBytes \
         maskBitsCast maskBitsNeon maskBitsOpaque maskBitsPieces maskBitsSwar mask maskOf \
         maskLanes maskArray maskAnd maskOr maskXor maskEq maskNe maskNot maskSelect; do
  grep -qE "^(pub )?inline fn $f\(" "$ROOT/src/runtime.zig" || fail "runtime: $f is not an inline fn"
done
true

# A mask of more than 16 lanes is held as bytes (`rig.Mask`), which LLVM
# keeps in vector registers where a `@Vector(32, bool)` crossing blocks
# is taken apart lane by lane; its operators are the runtime's.
cat >wide_mask.rig <<'EOF2'
fun found(v: Simd[U8, 32], keys: ?[4]U8) -> Simd[Bool, 32]
  m = Simd[Bool, 32].splat(false)
  for k in keys
    m |= v == k
  m
EOF2
out=$("$RIG" emit wide_mask.rig 2>/dev/null) || fail "rig emit wide_mask.rig"
expect_has "$out" 'rig.Mask(32)' "a mask type is rig.Mask"
expect_has "$out" 'rig.maskOr(' "a mask's |= is the runtime's"
expect_has "$out" 'rig.mask(v == ' "a comparison gives its lanes as a mask"
grep -qF '@Vector(32, bool)' <<<"$out" && fail "a wide mask is a bool vector: $out"
grep -qE '^pub fn Mask\(comptime n: comptime_int\) type \{$' "$ROOT/src/runtime.zig" || fail "runtime: no rig.Mask"
grep -qF 'return if (n > 16) WideMask(n) else @Vector(n, bool);' "$ROOT/src/runtime.zig" || fail "runtime: a mask of more than 16 lanes is not bytes"

# A test the compiler proved is omitted (docs/INTERNALS.md, "Proven
# checks"): the proven half of an index or a byte read, and an add known
# to fit. The half not proven is still made, and an access with nothing
# proven is the checked one.
cat >proven.rig <<'EOF2'
fun skip_space(s: ?String, at: Int) -> Int
  i = at
  while i < s.len
    c = s[i]
    if c == 32 and i + 8 <= s.len and s.read[U64, .little](i) == 0x2020202020202020
      i += 8
    else if c == 32
      i += 1
    else
      break
  i

fun count(s: ?String) -> Int
  n = 0
  i = 0
  while i + 8 <= s.len
    if s.read[U64, .little](i) != 0
      n += 1
    i += 8
  n

fun first(s: ?String, i: Int) -> U8
  s[i]

sub main()
  print(skip_space("   x", 0), count("abcdefgh"), first("a", 0))
EOF2
out=$("$RIG" emit proven.rig 2>/dev/null) || fail "rig emit proven.rig"
expect_has "$out" 'rig.atProven(s, i, .upper)' "an index whose sign is unknown keeps its sign test"
expect_has "$out" 'rig.readIntProven(u64, s, i, .little, .both)' "a read with both tests proven"
expect_has "$out" 'rig.addProven(i, 8) <= rig.len(s.len)' "a guard's add proven by an earlier guard"
expect_has "$out" 'i = rig.addProven(i, 8);' "a proven +="
expect_has "$out" 'if (!((i + 8) <= rig.len(s.len))) break;' "a loop guard's own add stays checked"
expect_has "$out" 'return rig.at(s, i);' "an index with nothing proven"
