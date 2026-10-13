# Which functions `rig emit` writes `inline`: small ones that are only
# called, and no other (docs/INTERNALS.md, "Inlining"). Each is checked by
# the shape of its Zig; test/behavior/emit/inline_*.rig run the programs.
source "$ROOT/test/cli/_lib.sh"

# expect_lacks <text> <substring> <what>
expect_lacks() { ! grep -qF -- "$2" <<<"$1" || fail "$3: has [$2] in: $1"; }

emit() {
    local out
    out=$(rig emit "$1" 2>/dev/null) || fail "rig emit $1"
    printf '%s' "$out"
}

cat >small.rig <<'RIG'
fun next(n: Int) -> Int
  n + 1

sub main()
  print(next(41))
RIG
out=$(emit small.rig)
expect_has "$out" 'pub inline fn next(__rig_in_' "a small function that is called"
# A parameter is a run-time value inside, so a literal argument cannot
# fold the arithmetic into a compile error.
expect_has "$out" 'const n = rig.rt(__rig_in_' "a parameter bound through rig.rt"
expect_has "$out" 'pub fn main(' "main"
expect_lacks "$out" 'inline fn main' "main"

cat >kept.rig <<'RIG'
fun fact(n: Int) -> Int
  1 if n <= 1 else n * fact(n - 1)

fun even(n: Int) -> Bool
  true if n == 0 else odd(n - 1)

fun odd(n: Int) -> Bool
  false if n == 0 else even(n - 1)

fun plus_one(n: Int) -> Int
  n + 1

fun apply(f: ?fun(Int) -> Int, x: Int) -> Int
  f(x)

fun twice(n: Int) -> Int
  n * 2

sub main()
  print(fact(5))
  print(even(4))
  print(apply(plus_one, 1))
  print(twice(3))
RIG
out=$(emit kept.rig)
expect_has "$out" 'pub fn fact(' "direct recursion"
expect_has "$out" 'pub fn even(' "mutual recursion"
expect_has "$out" 'pub fn odd(' "mutual recursion"
expect_has "$out" 'pub fn plus_one(' "a function passed as a value"
expect_has "$out" 'pub inline fn apply(' "the function that takes it"
expect_has "$out" 'pub inline fn twice(' "a function beside them"

# A method is inlined as a function is.
cat >method.rig <<'RIG'
obj Counter
  n: Int

  fun get(?self) -> Int
    self.n

sub main()
  c = Counter(n: 2)
  print(c.get())
RIG
out=$(emit method.rig)
expect_has "$out" 'pub inline fn get(' "a method"

# A cycle of method calls, through a receiver, a type, or two types'
# methods, is found. A method call resolves by name, so a method that
# calls another of its name is taken to call itself.
cat >methods.rig <<'RIG'
obj Ping
  n: Int

  fun depth(?self, k: Int) -> Int
    0 if k == 0 else 1 + self.depth(k - 1)

  fun count(k: Int) -> Int
    0 if k == 0 else 1 + Ping.count(k - 1)

  fun hop(?self, p: ?Pong, k: Int) -> Int
    0 if k == 0 else p.hop(?self, k - 1)

  fun size(?self) -> Int
    self.n

obj Pong
  n: Int

  fun hop(?self, p: ?Ping, k: Int) -> Int
    0 if k == 0 else p.hop(?self, k - 1)

  fun size(?self, p: ?Ping) -> Int
    p.size() + self.n

sub main()
  a = Ping(n: 1)
  b = Pong(n: 2)
  print(a.depth(3), Ping.count(2), a.hop(?b, 4), b.size(?a))
RIG
out=$(emit methods.rig)
expect_has "$out" 'pub fn depth(' "recursion through the receiver"
expect_has "$out" 'pub fn count(' "recursion through the type"
expect_lacks "$out" 'inline fn hop(' "recursion through two types' methods"
expect_has "$out" 'pub inline fn size(__rig_in_self: *const Ping)' "a method of a name another calls"
expect_has "$out" 'pub fn size(self: *const Pong' "a method calling another of its name"
out=$(rig run methods.rig 2>&1) || fail "rig run methods.rig: $out"
expect_eq "$out" "3 2 0 3" "methods.rig"

# A body of more than inlining.max_size nodes (60), called from two
# places, is called.
{
    echo 'fun long(n: Int) -> Int'
    echo '  total = n'
    for i in $(seq 1 30); do echo "  total += $i * n"; done
    echo '  total'
    echo
    echo 'sub main()'
    echo '  print(long(2) + long(3))'
} >long.rig
out=$(emit long.rig)
expect_has "$out" 'pub fn long(' "a long body"

# A function holds at most 16 MiB of values on its stack, and Zig puts the
# frame of an inlined call in its caller's: a function that keeps much,
# and calls that add much to a frame, are not inlined.
cat >frames.rig <<'RIG'
fun keeps() -> Int
  a = [10000 of 1]
  a[3]

fun small() -> Int
  a = [2048 of 1]
  a[3]

sub main()
  print(keeps())
  print(small() + small() + small())
RIG
out=$(emit frames.rig)
expect_has "$out" 'pub fn keeps(' "a function with a large frame"
expect_has "$out" 'pub inline fn small(' "calls that add 48 KiB to a frame"
{
    echo 'fun small() -> Int'
    echo '  a = [2048 of 1]'
    echo '  a[3]'
    echo
    echo 'sub main()'
    echo -n '  print(small()'
    for i in 1 2 3 4 5; do echo -n ' + small()'; done
    echo ')'
} >frames5.rig
out=$(emit frames5.rig)
expect_has "$out" 'pub fn small(' "calls that would add 96 KiB to a frame"

# A chain of functions that each call the next twice would have Zig analyze
# the innermost 2^n times: a function that expands to more than
# inlining.max_expanded (320) nodes is called.
{
    echo 'fun f0(n: Int) -> Int'
    echo '  n + 1'
    for i in $(seq 1 12); do
        echo
        echo "fun f$i(n: Int) -> Int"
        echo "  f$((i - 1))(n) + f$((i - 1))(n + 1)"
    done
    echo
    echo 'sub main()'
    echo '  print(f12(1))'
} >chain.rig
out=$(emit chain.rig)
expect_has "$out" 'pub inline fn f0(' "the innermost of a chain"
expect_has "$out" 'pub fn f' "a function that would expand too far is called"

# A small entry that calls a large function inlines, and the large one is
# not inlined back into it: the size rule measures each body as written,
# so the large function stays one out-of-line copy for every call site.
{
    echo 'fun run(n: Int) -> Int'
    echo '  total = n'
    for i in $(seq 1 30); do echo "  total += $i * n"; done
    echo '  total'
    echo
    echo 'fun entry(n: Int) -> Int'
    echo '  n if n < 2 else run(n)'
    echo
    echo 'sub main()'
    echo '  print(entry(1) + entry(5) + entry(9))'
} >entry.rig
out=$(emit entry.rig)
expect_has "$out" 'pub inline fn entry(' "the small entry"
expect_has "$out" 'pub fn run(' "the large function it calls"
expect_lacks "$out" 'inline fn run(' "the large function it calls"

# The `next` a `for` over an iterator calls is a call: a `next` that loops
# over another of its own kind is on a cycle and called.
cat >iter.rig <<'RIG'
obj Count
  lo: Int
  hi: Int

  fun next(!self) -> Int?
    return none if self.lo >= self.hi
    self.lo += 1
    if self.hi > 100
      inner = Count(lo: 0, hi: 1)
      for x in !inner
        print("inner", x)
    self.lo - 1

sub main()
  c = Count(lo: 0, hi: 3)
  for n in !c
    print(n)
RIG
out=$(emit iter.rig)
expect_has "$out" 'pub fn next(' "an iterator that loops over itself"
expect_lacks "$out" 'inline fn next' "an iterator that loops over itself"

# A call that may reach an inlined function is read through rig.rt, so the
# result is a run-time value.
out=$(emit small.rig)
expect_has "$out" 'rig.print(.{ rig.rt(next(41)) })' "a call of an inlined function"

# A function that keeps nearly all of `sema.max_frame_bytes` calls what
# would take it over, though the callee is small enough to inline.
cat >framefull.rig <<'RIG'
fun bump(i: Int) -> Int
  t = [4000 of i]
  t[i % 4000] + 1

fun near(i: Int) -> Int
  a = [850000 of 1]
  b = [850000 of 2]
  bump(i) + a[i] + b[i]

sub main()
  print(near(3))
RIG
out=$(emit framefull.rig)
expect_has "$out" 'pub fn bump(' "a callee that would overfill the caller's frame"
expect_has "$out" 'pub fn near(' "the caller"

# An instance of a function with compile-time values (Bool, Int, enum) is
# sized and inlined as any function, and so are the helpers it calls; one
# with a compile-time type parameter is called.
cat >ctvalue.rig <<'RIG'
enum Mode
  strict
  loose

fun step(s: ?String, i: Int) -> Int
  i + 1 if i < s.len else i

fun pick(s: ?String, i: Int) -> Int
  step(s, i) + 1

fun walk[dense: Bool](s: ?String) -> Int
  i = 0
  while i < s.len
    i = pick(s, i)
    i = step(s, i) if dense else i
  i

fun times[n: Int](x: Int) -> Int
  x * n

fun mode[m: Mode](x: Int) -> Int
  x + 1 if m == .strict else x - 1

fun same[T](x: T) -> T
  x

fun down[b: Bool](x: Int) -> Int
  x if x <= 0 else down[not b](x - 1)

sub main()
  print(walk[true]("abc"), walk[false]("abc"))
  print(times[3](2), mode[.strict](1), mode[.loose](1), same(5), down[true](4))
RIG
out=$(emit ctvalue.rig)
expect_has "$out" 'pub inline fn walk(comptime dense: bool' "a function with a compile-time Bool"
expect_has "$out" 'pub inline fn times(comptime n: i64' "a function with a compile-time Int"
expect_has "$out" 'pub inline fn mode(comptime m: ' "a function with a compile-time enum"
expect_has "$out" 'pub inline fn step(' "the callee of an instance"
expect_has "$out" 'pub inline fn pick(' "the callee of an instance"
expect_has "$out" 'pub fn same(comptime T: type' "a function with a compile-time type"
expect_has "$out" 'pub fn down(' "recursion through an instance"

# A function whose one call is the only copy of it is inlined whatever its
# size or expansion: `plain`, `once`, `big`, `scalar` and `number` have more
# than inlining.max_size nodes or expand to more than inlining.max_expanded.
# A call in a function with compile-time values is one call in each
# instance: `once`, called once in `inst`, is inlined into each instance,
# and so is `number`, called once in `scalar`, which each instance of
# `document` calls once. The same bodies called from two places are called,
# and so is a recursive one called once. (A large function called from a
# small one that is inlined at two calls is called: entry.rig above.)
pad() {
    echo '  total = n'
    for i in $(seq 1 35); do echo "  total += $i * n"; done
}
{
    echo 'fun leaf(n: Int) -> Int'
    echo '  total = n'
    for i in $(seq 1 18); do echo "  total += $i * n"; done
    echo '  total'
    for name in once twice plain; do
        echo
        echo "fun $name(n: Int) -> Int"
        echo '  leaf(n) + leaf(n + 1) + leaf(n + 2) + leaf(n + 3) + leaf(n + 4) + leaf(n + 5) + leaf(n + 6) + leaf(n + 7)'
    done
    for name in big shared number scalar rec; do
        echo
        echo "fun $name(n: Int) -> Int"
        pad
        case $name in
            scalar) echo '  total += number(n)' ;;
            rec) echo '  total += rec(n - 1) if n > 0 else 0' ;;
        esac
        echo '  total'
    done
    echo
    echo 'fun inst[b: Bool](n: Int) -> Int'
    pad
    echo '  total + (once(n) if b else twice(n) + twice(n + 1))'
    echo
    echo 'fun document[dense: Bool](n: Int) -> Int'
    pad
    echo '  total + scalar(n + 1 if dense else n)'
    echo
    echo 'sub main()'
    echo '  print(inst[true](1) + inst[false](2) + plain(3))'
    echo '  print(big(1) + shared(2) + shared(3) + rec(4))'
    echo '  print(document[true](1) + document[false](2))'
} >once.rig
out=$(emit once.rig)
expect_has "$out" 'pub inline fn leaf(' "the leaf"
expect_has "$out" 'pub inline fn once(' "an expansion over the limit, called once in an instance function"
expect_has "$out" 'pub inline fn plain(' "an expansion over the limit, called once in an ordinary function"
expect_has "$out" 'pub fn twice(' "the same expansion, called from two places"
expect_has "$out" 'pub fn inst(comptime b: bool' "a body over the limit, called from two places"
expect_has "$out" 'pub inline fn big(' "a body over the limit, called once"
expect_has "$out" 'pub fn shared(' "the same body, called from two places"
expect_has "$out" 'pub fn document(comptime dense: bool' "the instance function"
expect_has "$out" 'pub inline fn scalar(' "a body over the limit, called once in an instance function"
expect_has "$out" 'pub inline fn number(' "its callee, called once in each instance"
expect_has "$out" 'pub fn rec(' "a body over the limit that recurses, called once"
got=$(rig run once.rig 2>&1) || fail "rig run once.rig: $got"
expect_eq "$got" $'33541\n10096\n6941' "once.rig"

# The one call must be in the function's own module, and so must the
# chain of one calls it is inlined through: how often another module
# calls a module's functions does not decide the code the module gets.
# `parse` is small and inlined; `document`, its one call, is large and is
# called, though `main` calls `parse` once. `helper`, large and called once
# from another module, is called too; `inner`, large and called once in
# `document`, which is not inlined, is inlined.
{
    echo 'pub fun parse(n: Int) -> Int'
    echo '  document(n) + 1'
    echo
    for name in document helper inner; do
        echo "pub fun $name(n: Int) -> Int"
        pad
        [[ $name == document ]] && echo '  total += inner(n)'
        echo '  total'
        echo
    done
} >lib.rig
{
    echo 'use lib'
    echo
    echo 'sub main()'
    echo '  print(lib.parse(1) + lib.helper(2))'
} >app.rig
rig emit app.rig >/dev/null 2>&1 || fail "rig emit app.rig"
lib=$(cat "$RIG_OUT_DIR/programs/app/lib.zig") || fail "no lib.zig"
expect_has "$lib" 'pub inline fn parse(' "a small function of another module"
expect_has "$lib" 'pub fn document(' "a large function whose one call is inlined into another module"
expect_has "$lib" 'pub fn helper(' "a large function called once from another module"
expect_has "$lib" 'pub inline fn inner(' "a large function called once in its module"
out=$(rig run app.rig 2>&1) || fail "rig run app.rig: $out"
expect_eq "$out" 2525 "app.rig"

# Inlining keeps what the proofs omitted: a Simd read proven in bounds
# stays proven in a function that is inlined, whether it is small or is
# called from one place only.
{
    echo 'fun scan(s: ?String, at: Int) -> Int'
    echo '  i = at'
    echo '  while i + 16 <= s.len : i += 16'
    echo '    v = s.read[Simd[U8, 16]](i)'
    echo '    if (v == 0x22).first() as k'
    echo '      return i + k'
    echo '  s.len'
    echo
    echo 'sub main()'
    echo '  print(scan("abc\"abcdefghijklmnopq", 0))'
} >proven.rig
out=$(emit proven.rig)
expect_has "$out" 'pub inline fn scan(' "a function with a proven read"
expect_has "$out" 'rig.simdReadProven(' "the read stays proven when inlined"
