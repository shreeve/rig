# What `print` buffers is written out before `warn` or `panic` writes to
# stderr and on every exit, a panic's included; a reader that closes the
# pipe early ends the program quietly with status 0, and any other
# failure to write stdout is reported, with status 1; a failed write to
# stderr is dropped; a panic ends a running test with its report. One
# program does each, chosen by its argument, in every build mode.
# test/rig/runtime-print-flush.rig.test checks the panic's place and the
# file it names from the package root.
# builds: shared
source "$ROOT/test/cli/_lib.sh"
export RIG_NO_CRASH_REPORT=1

cat >flush.rig <<'EOF2'
use std.os

sub main()
  what = os.args()[1]
  if what == "order"
    print("one")
    warn("two")
    print("three")
    panic("four\nfive")
  else if what == "index"
    # A runtime panic is the same event, with no location.
    xs = [1, 2, 3]
    print("before")
    print(xs[os.args().len + 4])
  else if what == "many"
    for i in 0..200000
      print("line", i)
  else if what == "closed"
    print("x")
  else if what == "noerr"
    warn("lost")
    print("after")
EOF2
want=$'one\ntwo\nthree\nflush.rig:9:5: panic: four\nfive'
for mode in "" "--release" "--release=fast"; do
  how=${mode:-debug}
  rig build $mode -o flush flush.rig >build.log 2>&1 || fail "build flush.rig $how: $(cat build.log)"
  out=$(quiet ./flush order 2>&1); expect_rc $? 134 "panic exit status $how"
  expect_eq "$out" "$want" "print, warn, and panic in order $how"
  err=$(quiet ./flush order 2>&1 >/dev/null)
  expect_eq "$err" $'two\nflush.rig:9:5: panic: four\nfive' "warn and panic write stderr $how"
  out=$(quiet ./flush index 2>&1); expect_rc $? 134 "runtime panic exit status $how"
  expect_has "$out" $'before\npanic: index out of bounds' "runtime panic after the output $how"

  # A reader that stops early: no error, status 0.
  first=$( (./flush many 2>err.txt; echo "rc=$?" >rc.txt) | head -1)
  expect_eq "$first" "line 0" "first line $how"
  expect_eq "$(cat rc.txt)" "rc=0" "closed pipe exit status $how"
  expect_eq "$(cat err.txt)" "" "closed pipe writes no error $how"

  # Any other failure to write stdout is reported, with status 1.
  out=$(./flush closed 2>&1 >&-); expect_rc $? 1 "closed stdout exit status $how"
  expect_eq "$out" "error: stdout: not open for writing" "closed stdout $how"

  # A failed write to stderr is dropped: `warn` writes nothing, and the
  # program goes on.
  out=$(./flush noerr 2>&-); expect_rc $? 0 "closed stderr exit status $how"
  expect_eq "$out" "after" "warn with stderr closed $how"
done

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
exit 0
