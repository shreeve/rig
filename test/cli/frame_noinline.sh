# A function whose code may take `sema.noinline_reach` (1 MiB) of stack
# or more is emitted `noinline`, so no build merges two such frames into
# one: a function itself, and a generic function at an instance made in
# its own module or another one. A small function is inlined only when
# its reach is small too, since Zig writes an inlined body, temporaries
# and all, again at each call.
source "$ROOT/test/cli/_lib.sh"

mkdir -p app
cat >app/lib.rig <<'EOF3'
pub fun pick[T](x: T, y: T, c: Bool) -> T
  x if c else y
EOF3
cat >app/main.rig <<'EOF3'
use lib

fun take(a: [40000]Int) -> Int
  a[1]

fun copies(i: Int) -> Int
  a = [40000 of i]
  take(a) + take(a) + take(a)

fun small(i: Int) -> Int
  a = [100 of i]
  take2(a)

fun take2(a: [100]Int) -> Int
  a[1]

fun twice[T](x: T) -> T
  y = x
  z = y
  z

fun peek(a: ?[40000]Int, k: Int) -> Int
  take(a) + k

fun tiny(a: ?[40000]Int, k: Int) -> Int
  a[k] + 1

sub main()
  big = [40000 of 1]
  print(copies(2), small(3), twice(big)[1], lib.pick(big, big, true)[1])
  print(peek(?big, 1) + peek(?big, 2), tiny(?big, 1) + tiny(?big, 2))
EOF3
rig check app/main.rig >/dev/null 2>&1 || fail "check app"
out=$(rig emit app/main.rig 2>&1) || fail "emit app: $out"
expect_has "$out" 'pub noinline fn copies(' "a function that copies 960 KB"
grep -qF 'pub noinline fn small(' <<<"$out" && fail "a small function is noinline"
expect_has "$out" 'pub noinline fn twice(' "a generic function at a large instance"
expect_has "$out" 'fn peek(' "peek"
grep -qF 'pub inline fn peek(' <<<"$out" && fail "a small function that copies 320 KB is inlined"
expect_has "$out" 'pub inline fn tiny(' "a small function that copies nothing is inlined"
lib=$(cat "$RIG_OUT_DIR"/programs/app_main/*lib*.zig 2>/dev/null)
expect_has "$lib" 'pub noinline fn pick(' "a generic function at a large instance another module makes"
exit 0
