# `fun main -> Int` sets the process's exit status, after main's drops,
# its output, and the leak check; `sub main` exits 0, or 1 when it
# propagates an error.
source "$ROOT/test/cli/_lib.sh"

cat >status.rig <<'EOF2'
struct Guard
  n: Int

  drop(!self)
    print("drop", self.n)

fun main -> Int
  g = Guard(n: 3)
  print("status", g.n)
  g.n
EOF2
out=$(rig run status.rig 2>&1); expect_rc $? 3 "exit status"
expect_eq "$out" $'status 3\ndrop 3' "exit status after the drops"
rig build -o status status.rig >/dev/null 2>&1 || fail "build status.rig"
./status >/dev/null; expect_rc $? 3 "built program's exit status"

printf 'fun main -> Int\n  256\n' >big.rig
out=$(rig run big.rig 2>&1); rc=$?
[[ $rc -ne 0 ]] || fail "an exit status out of range exits 0"
expect_has "$out" "exit status 256 is not in 0..255" "exit status out of range"

cat >fails.rig <<'EOF2'
error Oops
  bad

fun check(n: Int) -> Int!
  if n > 1
    return Oops.bad
  n

fun main -> Int
  print(check(1)!)
  check(2)!
EOF2
out=$(rig run fails.rig 2>&1); expect_rc $? 1 "fallible main"
expect_has "$out" "error: Oops.bad" "fallible main"

# Every form of `main`: `sub main!` and `fun main -> Int!` exit 1 with
# the error when they fail, and the latter sets the status otherwise.
cat >forms.rig <<'EOF2'
use std.os

error Oops
  bad

fun check(n: Int) -> Int!
  if n > 1
    return Oops.bad
  n

fun main -> Int!
  n = os.args().len - 1
  print("args", n)
  check(n)!
EOF2
out=$(rig run forms.rig 2>&1); expect_rc $? 0 "fun main -> Int!: 0"
out=$(rig run forms.rig -- a 2>&1); expect_rc $? 1 "fun main -> Int!: 1"
expect_eq "$out" "args 1" "fun main -> Int!: 1"
out=$(rig run forms.rig -- a b 2>&1); expect_rc $? 1 "fun main -> Int! fails"
expect_eq "$out" $'args 2\nerror: Oops.bad' "fun main -> Int! fails"
printf 'error Oops\n  bad\n\nsub main!\n  print("before")\n  return Oops.bad\n' >subfails.rig
out=$(rig run subfails.rig 2>&1); expect_rc $? 1 "sub main! fails"
expect_eq "$out" $'before\nerror: Oops.bad' "sub main! fails"

printf 'sub main\n  print("sub")\n' >plain.rig
out=$(rig run plain.rig 2>&1); expect_rc $? 0 "sub main"
expect_eq "$out" "sub" "sub main"

printf 'fun main -> Int\n  9\n\ntest "t"\n  print("t")\n' >tested.rig
out=$(rig test tested.rig 2>&1); expect_rc $? 0 "rig test with fun main"
expect_has "$out" "1 passed, 0 failed" "rig test with fun main"
exit 0
