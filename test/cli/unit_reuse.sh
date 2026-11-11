# A split build (`--units=N`) compiles again only the units whose input
# changed: after an edit inside one function's body, one unit; after a
# change to a type, a signature, or a constant, every unit. A unit is
# never linked from an object compiled from other source: the program
# built after each edit prints what a build from scratch and a build of
# one unit print. The Zig commands are counted through a wrapper.
# timeout: 600
source "$ROOT/test/cli/_lib.sh"

REAL_ZIG=${ZIG:-zig}
cat >zig-counted <<EOF
#!/bin/sh
echo "\$1" >>"$PWD/zig.log"
exec "$REAL_ZIG" "\$@"
EOF
chmod +x zig-counted

# build DIR ARGS...: rig build with its package in ./DIR, kept between
# calls, and no build store, which keeps each package apart by content.
build() {
    local dir=$1; shift
    : >zig.log
    env -u RIG_BUILD_STORE RIG_OUT_DIR="$PWD/$dir" ZIG="$PWD/zig-counted" "$RIG" build "$@"
}
# compiled: how many units the last build compiled.
compiled() { grep -c '^build-obj$' zig.log; }
# same WHAT: the program the last build wrote as ./prog prints what a
# build from scratch and a build of one unit print.
same() {
    local out; out=$(./prog 2>&1)
    rm -rf scratch whole
    build scratch --units=3 -o prog-scratch main.rig || fail "$1: build from scratch"
    expect_eq "$(compiled)" 3 "$1: units a build from scratch compiles"
    build whole --units=1 -o prog-whole main.rig || fail "$1: build of one unit"
    expect_eq "$out" "$(./prog-scratch 2>&1)" "$1: reused against from scratch"
    expect_eq "$out" "$(./prog-whole 2>&1)" "$1: reused against one unit"
}

cat >shape.rig <<'EOF'
pub obj Box
  pub w: Int
  pub h: Int

pub LIMIT = 1000

pub called fun area(b: ?Box) -> Int
  b.w * b.h

pub called fun describe(b: ?Box) -> String
  String("box ", b.w, "x", b.h)

pub called sub grow(b: !Box, by: Int)
  b.w += by
  b.h += by
EOF

cat >price.rig <<'EOF'
use shape

pub error Price
  negative
  too_many

pub called fun total(unit: Int, qty: Int) -> Int!
  return Price.negative if unit < 0 or qty < 0
  return Price.too_many if qty > shape.LIMIT
  cents = unit * qty
  return cents - cents / 10 if qty >= 10
  cents

pub called fun of_box(b: ?shape.Box, unit: Int) -> Int!
  total(unit, shape.area(b))!

pub called fun label(n: Int) -> String
  String("n=", n)
EOF

cat >main.rig <<'EOF'
use price
use shape

called fun sq(x: Int) -> Int
  x * x

called fun twice(x: Int) -> Int
  sq(x) + sq(x)

sub main()
  b = shape.Box(w: 3, h: 4)
  print(shape.describe(?b), shape.area(?b))
  shape.grow(!b, 1)
  print(price.of_box(?b, 7)!)
  print(price.label(twice(5)))
  bad = price.total(1, 5000) catch |e| -1
  print(bad)
EOF

build out --units=3 -o prog main.rig || fail "the first build"
expect_eq "$(compiled)" 3 "units the first build compiles"
expect_eq "$(./prog 2>&1)" "box 3x4 12
126
n=50
-1" "the first build"
for k in 0 1 2; do
    ls out/__rig_u${k}_*.zig >/dev/null 2>&1 || fail "unit $k owns no function: the program is too small to test"
done

build out --units=3 -o prog main.rig || fail "the same build again"
expect_eq "$(grep -cv '^env$' zig.log)" 0 "Zig compiles and links of the same build again"

# A body: one unit.
cp out/shape.zig shape-declarations.zig
sed -i.bak 's|return cents - cents / 10 if qty >= 10|return cents - cents / 5 if qty >= 10|' price.rig
build out --units=3 -o prog main.rig || fail "the build after a body changed"
expect_eq "$(compiled)" 1 "units compiled after a body changed"
expect_eq "$(./prog 2>&1)" "box 3x4 12
112
n=50
-1" "after a body changed"
cmp -s out/shape.zig shape-declarations.zig || fail "a body's change reached another module's declarations"
same "after a body changed"

# A body that grows, with hidden names and locals of its own: one unit,
# and no function moves to another.
cat >grow.txt <<'EOF'
  extra = List([1, 2, 3])
  for x in ?extra
    b.w += x - x
  b.h += extra.sum() - 6
EOF
sed -i.bak '/^  b.w += by$/r grow.txt' shape.rig
build out --units=3 -o prog main.rig || fail "the build after a body grew"
expect_eq "$(compiled)" 1 "units compiled after a body grew"
same "after a body grew"

# A type every unit uses: every unit, and the new field is read.
echo "  pub d: Int = 2" >field.txt
sed -i.bak '/^  pub h: Int$/r field.txt' shape.rig
sed -i.bak 's|^  b.w \* b.h$|  b.w * b.h * b.d|' shape.rig
build out --units=3 -o prog main.rig || fail "the build after a type changed"
expect_eq "$(compiled)" 3 "units compiled after a type changed"
expect_eq "$(./prog 2>&1)" "box 3x4 24
224
n=50
-1" "after a type changed"
same "after a type changed"

# A constant: every unit.
sed -i.bak 's|^pub LIMIT = 1000$|pub LIMIT = 10000|' shape.rig
build out --units=3 -o prog main.rig || fail "the build after a constant changed"
expect_eq "$(compiled)" 3 "units compiled after a constant changed"
expect_has "$(./prog 2>&1)" "
4000" "after a constant changed"
same "after a constant changed"

# A signature: every unit.
sed -i.bak 's|^pub called fun label(n: Int) -> String$|pub called fun label(n: Int, of: Int = 3) -> String|; s|^  String("n=", n)$|  String("n=", n, "/", of)|' price.rig
build out --units=3 -o prog main.rig || fail "the build after a signature changed"
expect_eq "$(compiled)" 3 "units compiled after a signature changed"
expect_has "$(./prog 2>&1)" "n=50/3" "after a signature changed"
same "after a signature changed"

# An object that is gone, or one Zig did not finish, is compiled again.
rm -f prog; rm -rf out/.zig-cache/rig-build
rm out/.zig-cache/rig-units/debug/u1-*.ok
build out --units=3 -o prog main.rig || fail "the build after a marker went"
expect_eq "$(compiled)" 1 "units compiled after a marker went"
rm -f prog; rm -rf out/.zig-cache/rig-build
rm out/.zig-cache/rig-units/debug/u2-*.o
build out --units=3 -o prog main.rig || fail "the build after an object went"
expect_eq "$(compiled)" 1 "units compiled after an object went"
expect_has "$(./prog 2>&1)" "n=50/3" "after an object went"
expect_eq "$(ls out/.zig-cache/rig-units/debug/*.ok | wc -l | tr -d ' ')" 3 "markers kept, one a unit"
exit 0
