# Each mistake in a compile-time integer (an array length, a fill count,
# or a compile-time argument) gets one diagnostic: nothing that follows
# from it is reported again.
source "$ROOT/test/cli/_lib.sh"

# errors_of <file>: the error lines `rig check` prints, in line order.
errors_of() { "$RIG" check "$1" 2>&1 | grep ': error: ' | sort -t: -k2,2n -k3,3n; }

# An instance with a rejected argument is poison, not `Ring[Int, invalid]`.
cat >poison.rig <<'EOF2'
struct Ring[T, n: Int]
  items: [n]T

struct Wrap[T]
  v: T

fun f(r: ?Ring[Int, nope]) -> Int
  1

fun g(b: ?Wrap[Nope]) -> Int
  1

sub main()
  r = Ring[Int, 2](items: [2 of 0])
  s: Ring[Int, Int] = r
  b = Wrap[Int](v: 1)
  a: [nope]Int = [2 of 0]
  print(f(?r), g(?b), s.items, a)
EOF2
expect_eq "$(errors_of poison.rig)" "poison.rig:7:21: error: use of unbound name \`nope\`
poison.rig:10:16: error: use of unbound type \`Nope\`
poison.rig:15:16: error: compile-time argument 2 of \`Ring\` is a value of type \`Int\`, not a type
poison.rig:17:7: error: use of unbound name \`nope\`" "a poisoned instance"

# An argument out of range for an array length is reported once, where
# the instance is spelled.
cat >range.rig <<'EOF2'
struct Ring[T, n: Int]
  items: [n]T

sub main()
  r = Ring[Int, -1](items: [2 of 0])
  s = Ring[Int, 5000000000](items: [2 of 0])
  print(r.items.len, s.items.len)
EOF2
expect_eq "$(errors_of range.rig)" "range.rig:5:7: error: \`Ring[Int, -1]\` cannot use \`n = -1\`: the generic body uses \`n\` as an array length, which runs from 0 to 4294967295
range.rig:6:7: error: \`Ring[Int, 5000000000]\` cannot use \`n = 5000000000\`: the generic body uses \`n\` as an array length, which runs from 0 to 4294967295" "an out-of-range argument"

# A signature or an annotation with a bad array length leaves nothing
# for a call's inference to report.
cat >infer.rig <<'EOF2'
fun f[T](xs: [T]Int) -> Int
  1

fun zeros[n: Int] -> [n]Int
  [n of 0]

sub main()
  a: [nope]Int = zeros()
  print(f([1]), a)
EOF2
expect_eq "$(errors_of infer.rig)" "infer.rig:1:15: error: \`T\` is a type; an array length is an integer, a constant, a compile-time parameter, or arithmetic on them
infer.rig:8:7: error: use of unbound name \`nope\`" "no inference cascade"

# A fill count that is not an integer is named for what it is, once.
cat >kinds.rig <<'EOF2'
sub main()
  a = [2.5 of 0]
  b = [none of 0]
  print(a, b)
EOF2
expect_eq "$(errors_of kinds.rig)" "kinds.rig:2:8: error: an array length is an integer; \`2.5\` is a \`Float\`
kinds.rig:3:8: error: an array length is an integer; \`none\` is the absent optional" "a fill count's kind"

# A value too large is reported once, where it is spelled or made: a
# type holding one, and a fill where its annotation is rejected, are not
# reported again.
expect_eq "$(errors_of "$ROOT/test/reject/types/array_too_large.rig" | wc -l | tr -d ' ')" "12" "one diagnostic per value too large"

# An array argument is not read as brackets written apart from the name
# when the function takes run-time parameters, and a rejected parameter
# type leaves nothing to say about the call.
cat >touch.rig <<'EOF2'
fun f[n: Bool](xs: [n]Int) -> Int
  1

fun g[n: Int](xs: [n + 1]Int) -> Int
  1

fun h[n: Int](xs: [3]Int) -> Int
  n

sub main()
  print(f([1, 2, 3]), g([1, 2]), h([1, 2, 3]))
EOF2
expect_eq "$(errors_of touch.rig)" "touch.rig:1:21: error: an array length is an integer; \`n\` is a compile-time \`Bool\`
touch.rig:4:20: error: an array length \`n + 1\` does arithmetic on a compile-time parameter, which Rig cannot check for overflow or division by zero; use a parameter or a constant
touch.rig:11:34: error: \`h\` takes 1 compile-time argument in brackets: \`h[...](...)\`" "no bracket hint for an array argument"

# A constructor whose instance is rejected says nothing more about its
# arguments' types.
cat >ctor.rig <<'EOF2'
struct Ring[T, n: Int]
  items: [n]T

fun f() -> Int
  3

sub main()
  r = Ring[Int, f()](items: [])
  print(r)
EOF2
expect_eq "$(errors_of ctor.rig)" "ctor.rig:8:17: error: compile-time argument 2 of \`Ring\` must be known at compile time; pass a literal, an enum value, a module constant, a compile-time parameter, a \`=!\` binding of one, or arithmetic on them" "a rejected instance's arguments"

# Each frame too large is reported once.
expect_eq "$(errors_of "$ROOT/test/reject/types/frame_too_large.rig" | wc -l | tr -d ' ')" "7" "one diagnostic per frame too large"
