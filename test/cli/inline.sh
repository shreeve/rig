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

# A body of more than inlining.max_size nodes (60) is called.
{
    echo 'fun long(n: Int) -> Int'
    echo '  total = n'
    for i in $(seq 1 30); do echo "  total += $i * n"; done
    echo '  total'
    echo
    echo 'sub main()'
    echo '  print(long(2))'
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

# A function that is called from one place only is exempt from
# inlining.max_expanded (nothing repeats it), as with `once` here, which
# expands to over 320 nodes; `twice` is the same body called twice.
{
    echo 'fun leaf(n: Int) -> Int'
    echo '  total = n'
    for i in $(seq 1 18); do echo "  total += $i * n"; done
    echo '  total'
    for name in once twice; do
        echo
        echo "fun $name(n: Int) -> Int"
        echo '  leaf(n) + leaf(n + 1) + leaf(n + 2) + leaf(n + 3) + leaf(n + 4) + leaf(n + 5) + leaf(n + 6) + leaf(n + 7)'
    done
    echo
    echo 'sub main()'
    echo '  print(once(1) + twice(2) + twice(3))'
} >once.rig
out=$(emit once.rig)
expect_has "$out" 'pub inline fn leaf(' "the leaf"
expect_has "$out" 'pub inline fn once(' "an expansion over the limit, called from one place"
expect_has "$out" 'pub fn twice(' "the same expansion, called from two"
