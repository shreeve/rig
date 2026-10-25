# `os.exit(code)` writes out what `print` buffered, to a file or a pipe,
# and ends the process with `code` at once, in every build mode: no drop,
# `defer`, or leak check runs, so a debug build that ends with live memory
# reports no leak. A program that returns from `main` is still
# leak-checked (test/cli/leaks.sh).
# builds: shared
source "$ROOT/test/cli/_lib.sh"

cat >ends.rig <<'EOF'
use std.os

obj Noisy
  name: ?String

  drop(!@)
    print("drop", @name)

sub main()
  defer print("defer ran")
  n = Noisy(name: "a")
  v: List[Int] = List()
  for i in 0..1000
    !v.push(i)
  h = *Noisy(name: "shared")
  print("lines", v.len)
  warn("to stderr")
  os.exit(5)
EOF

for mode in "" --release --release=fast; do
    rig build $mode -o ends ends.rig >build.log 2>&1 || fail "build $mode: $(cat build.log)"
    ./ends >out.txt 2>err.txt; expect_rc $? 5 "exit status $mode"
    expect_eq "$(cat out.txt)" "lines 1000" "stdout to a file $mode"
    expect_eq "$(cat err.txt)" "to stderr" "stderr, no leak report $mode"
    out=$(./ends 2>/dev/null | cat); expect_eq "$out" "lines 1000" "stdout to a pipe $mode"
done

# Under `rig run` too, whose debug build checks for leaks.
rig run ends.rig >out.txt 2>err.txt; expect_rc $? 5 "rig run status"
expect_eq "$(cat out.txt)" "lines 1000" "rig run stdout"
expect_eq "$(grep -c 'memory leak' err.txt)" "0" "no leak report from os.exit"
exit 0
