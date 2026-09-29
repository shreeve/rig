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
expect_has "$out" "error: bad" "fallible main"

printf 'sub main\n  print("sub")\n' >plain.rig
out=$(rig run plain.rig 2>&1); expect_rc $? 0 "sub main"
expect_eq "$out" "sub" "sub main"

printf 'fun main -> Int\n  9\n\ntest "t"\n  print("t")\n' >tested.rig
out=$(rig test tested.rig 2>&1); expect_rc $? 0 "rig test with fun main"
expect_has "$out" "1 passed, 0 failed" "rig test with fun main"
exit 0
