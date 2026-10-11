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
