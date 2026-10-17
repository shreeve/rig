# What `print` buffers is written out before `warn` or `panic` writes to
# stderr and on every exit, a panic's included; a reader that closes the
# pipe early ends the program quietly with status 0, and any other
# failure to write stdout is reported, with status 1. A panic names its
# file from the package root, and ends a running test with its report.
source "$ROOT/test/cli/_lib.sh"
export RIG_NO_CRASH_REPORT=1

cat >order.rig <<'EOF2'
sub main()
  print("one")
  warn("two")
  print("three")
  panic("four\nfive")
EOF2
want=$'one\ntwo\nthree\norder.rig:5:3: panic: four\nfive'
rig build -o order order.rig >/dev/null 2>&1 || fail "build order.rig"
out=$(quiet ./order 2>&1); expect_rc $? 134 "panic exit status"
expect_eq "$out" "$want" "print, warn, and panic in order"
rig build --release -o order_release order.rig >/dev/null 2>&1 || fail "build --release order.rig"
out=$(quiet ./order_release 2>&1); expect_rc $? 134 "panic exit status in --release"
expect_eq "$out" "$want" "print, warn, and panic in order in --release"
err=$(quiet ./order 2>&1 >/dev/null)
expect_eq "$err" $'two\norder.rig:5:3: panic: four\nfive' "warn and panic write stderr"

# A runtime panic is the same event, with no location.
cat >index.rig <<'EOF2'
use std.os

sub main()
  xs = [1, 2, 3]
  print("before")
  print(xs[os.args().len + 4])
EOF2
rig build --release -o index index.rig >/dev/null 2>&1 || fail "build index.rig"
out=$(quiet ./index 2>&1); expect_rc $? 134 "runtime panic exit status"
expect_has "$out" $'before\npanic: index out of bounds' "runtime panic after the output"

# A reader that stops early: no error, status 0, in every build mode.
cat >many.rig <<'EOF2'
sub main()
  for i in 0..200000
    print("line", i)
EOF2
for mode in "" "--release" "--release=fast"; do
  rig build $mode -o many many.rig >/dev/null 2>&1 || fail "build many.rig $mode"
  first=$( (./many 2>err.txt; echo "rc=$?" >rc.txt) | head -1)
  expect_eq "$first" "line 0" "first line $mode"
  expect_eq "$(cat rc.txt)" "rc=0" "closed pipe exit status $mode"
  expect_eq "$(cat err.txt)" "" "closed pipe writes no error $mode"
done

# Any other failure to write stdout is reported, with status 1.
printf 'sub main()\n  print("x")\n' >closed.rig
rig build -o closed closed.rig >/dev/null 2>&1 || fail "build closed.rig"
out=$(./closed 2>&1 >&-); expect_rc $? 1 "closed stdout exit status"
expect_eq "$out" "error: stdout: not open for writing" "closed stdout"

# A panic in a test ends the run, naming the test, after its output.
cat >tested.rig <<'EOF2'
test "first"
  print("in first")

test "second"
  print("in second")
  panic("stop")

test "third"
  print("in third")

sub main()
  pass
EOF2
out=$(rig test tested.rig 2>&1); expect_rc $? 134 "panic in a test"
expect_has "$out" $'ok    first\nin second\nFAIL  second: panicked\n1 passed, 1 failed\ntested.rig:6:3: panic: stop' "panic in a test"
grep -q "in third" <<<"$out" && fail "a test runs after a panic: $out"

# The location is the file from the package root.
mkdir -p p/m
printf 'use m\n\nsub main()\n  m.stop(2)\n' >p/main.rig
printf 'pub sub stop(n: Int)\n  panic("stopped at", n)\n' >p/m/b.rig
rig build -o pm p/main.rig >/dev/null 2>&1 || fail "build p/main.rig"
out=$(quiet ./pm 2>&1); expect_rc $? 134 "panic in a module"
expect_has "$out" "m/b.rig:2:3: panic: stopped at 2" "path from the package root"
grep -q "p/m/b.rig" <<<"$out" && fail "path includes the package directory: $out"
exit 0
