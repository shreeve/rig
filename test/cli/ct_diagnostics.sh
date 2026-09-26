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

struct Box[T]
  v: T

fun f(r: ?Ring[Int, nope]) -> Int
  1

fun g(b: ?Box[Nope]) -> Int
  1

sub main()
  r = Ring[Int, 2](items: [0; 2])
  s: Ring[Int, Int] = r
  b = Box[Int](v: 1)
  a: [nope]Int = [0; 2]
  print(f(?r), g(?b), s.items, a)
EOF2
expect_eq "$(errors_of poison.rig)" "poison.rig:7:21: error: use of unbound name \`nope\`
poison.rig:10:15: error: use of unbound type \`Nope\`
poison.rig:15:16: error: compile-time argument 2 of \`Ring\` is a value of type \`Int\`, not a type
poison.rig:17:7: error: use of unbound name \`nope\`" "a poisoned instance"

# An argument out of range for an array length is reported once, where
# the instance is spelled.
cat >range.rig <<'EOF2'
struct Ring[T, n: Int]
  items: [n]T

sub main()
  r = Ring[Int, -1](items: [0; 2])
  s = Ring[Int, 5000000000](items: [0; 2])
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
  [0; n]

sub main()
  a: [nope]Int = zeros()
  print(f([1]), a)
EOF2
expect_eq "$(errors_of infer.rig)" "infer.rig:1:15: error: \`T\` is a type; an array length is an integer, a constant, or a compile-time parameter
infer.rig:8:7: error: use of unbound name \`nope\`" "no inference cascade"
