# A split build (`--units=N`) compiles the program as N units, each a
# `zig build-obj`, and links them: it prints what one unit prints, with
# calls, errors, text, tasks, and the runtime's state crossing between
# units, and `rig test` runs the same tests. A small program's debug
# build stays one unit.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

# build_in DIR ARGS...: rig with its package in a directory of its own that
# lasts between runs, its units from an earlier run removed.
build_in() {
    local dir="$RIG_OUT_DIR/programs/units-$1"; shift
    rm -f "$dir"/__rig_unit_*
    RIG_OUT_DIR="$dir" "$RIG" "$@"
}

cat >price.rig <<'EOF'
pub error Price
  negative
  too_many

pub called fun total(unit: Int, qty: Int) -> Int!
  return Price.negative if unit < 0 or qty < 0
  return Price.too_many if qty > 1000
  cents = unit * qty
  return cents - cents / 10 if qty >= 10
  cents

pub called fun label(s: ?String) -> String
  String("n=", s)

pub called fun checked(unit: Int, qty: Int) -> Int!
  total(unit, qty)!
EOF

cat >main.rig <<'EOF'
use price

called fun sq(x: Int) -> Int
  x * x

called fun sum(xs: ?List[Int]) -> Int
  xs.sum()

sub main()
  print(price.total(250, 10)!)
  print(price.label("7"))
  bad = price.checked(250, -1) catch |e| -1
  print(bad)
  xs = List([3, 4])
  t = sq(5)&
  u = sum(?xs)&
  print(>t, >u)
  print(price.checked(250, 5000)!)

test "an error crosses units"
  _ = price.checked(250, -1) catch |e| return e == price.Price.negative
  false

test "text crosses units"
  price.label("a") == "n=a"

test "fails across units"
  price.checked(1, 2000)!
  true
EOF

build_in one run main.rig >one.txt 2>&1; rc1=$?
[[ -e $RIG_OUT_DIR/programs/units-one/__rig_unit_0.zig ]] && fail "a small program's debug build was split"
build_in three run --units=3 main.rig >three.txt 2>&1; rc3=$?
[[ -e $RIG_OUT_DIR/programs/units-three/__rig_unit_2.zig ]] || fail "--units=3 wrote no third unit"
grep -q "rig.split.away" "$RIG_OUT_DIR"/programs/units-three/*.zig || fail "--units=3 cut no function"
expect_eq "$(cat three.txt)" "$(cat one.txt)" "rig run, three units against one"
expect_rc $rc3 $rc1 "rig run, three units against one"
expect_has "$(cat three.txt)" "2250" "rig run --units=3"
expect_has "$(cat three.txt)" "Price.too_many" "an error from another unit ends main"

build_in t1 test main.rig >t1.txt 2>&1; rc1=$?
build_in t2 test --units=2 main.rig >t2.txt 2>&1; rc2=$?
expect_eq "$(cat t2.txt)" "$(cat t1.txt)" "rig test, two units against one"
expect_rc $rc2 $rc1 "rig test, two units against one"
expect_has "$(cat t2.txt)" "2 passed, 1 failed" "rig test --units=2"

build_in b build --units=2 -o prog main.rig || fail "rig build --units=2"
out=$(./prog 2>&1)
expect_eq "$out" "$(cat one.txt)" "rig build --units=2"

rig check --units=2 main.rig 2>err.txt && fail "rig check --units=2 succeeded"
expect_has "$(cat err.txt)" "\`--units\` applies to build, run, and test" "rig check --units"
rig run --units=0 main.rig 2>err.txt && fail "--units=0 succeeded"
expect_has "$(cat err.txt)" "at least 1" "--units=0"
exit 0
