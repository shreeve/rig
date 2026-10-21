# `rig build --pgo=FILE -- WORKLOAD` builds the program counting where it
# runs, runs the workload, writes the profile FILE, and builds by it: a
# function the run never entered is cold and never inlined. The program
# prints the same in every build. The profile names each function by a
# hash of its text, so an edited function loses its counts, and a build
# by the profile alone (no workload) reads it as it is.
source "$ROOT/test/cli/_lib.sh"

cat >p.rig <<'EOF2'
fun sq(n: Int) -> Int
  n * n

fun never(n: Int) -> Int
  if n > 100
    return n - 1
  n + 1

fun hot(n: Int) -> Int
  if n == 5000
    return 0
  if n % 7 == 0
    return n * 3
  n + 2

fun wide(n: Int) -> Int
  a = n
  a = a * 3 + n % 7
  a = a * 5 + n % 11
  a = a * 7 + n % 13
  a = a % 100003 + n % 17
  a = a * 5 + n % 19
  a = a * 7 + n % 23
  a = a * 3 + n % 29
  a = a % 100003 + n % 31
  a = a * 7 + n % 37
  a = a * 3 + n % 41
  a = a * 5 + n % 43
  a = a % 100003 + n % 47
  a = a * 3 + n % 53
  a = a * 5 + n % 59
  a = a * 7 + n % 61
  a = a % 100003 + n % 67
  a = a * 5 + n % 71
  a = a * 7 + n % 73
  a = a * 3 + n % 79
  a = a % 100003 + n % 83
  a = a * 7 + n % 89
  a = a * 3 + n % 97
  a = a * 5 + n % 101
  a = a % 100003 + n % 103
  a

sub main()
  s = 0
  for i in 0..1000
    s += hot(i) + wide(i) % 3
  if s < 0
    print(never(s))
  print(s + sq(3))
EOF2

want=$("$RIG" run p.rig 2>&1) || fail "rig run: $want"
out=$(RIG_OUT_DIR=$PWD/out "$RIG" build --pgo=p.profile -o prog p.rig -- ./prog 2>&1); expect_rc $? 0 "build --pgo with a workload: $out"
expect_has "$out" "wrote the profile p.profile" "the note of the profile written"
expect_eq "$(./prog)" "$want" "the program built by its profile"
prof=$(cat p.profile)
expect_has "$prof" "# rig profile 1" "the profile's header"
grep -q '^fun __rig_main.zig hot [0-9a-f]\{16\} 1000$' p.profile || fail "hot ran 1000 times: $prof"
grep -q '^fun __rig_main.zig never [0-9a-f]\{16\} 0$' p.profile || fail "never never ran: $prof"
grep -q '^fun __rig_main.zig main [0-9a-f]\{16\} 1$' p.profile || fail "main ran once: $prof"
# One of hot's arms ran on 143 of its 1000 calls: its block's count.
grep -q '^fun __rig_main.zig wide [0-9a-f]\{16\} 1000$' p.profile || fail "wide ran 1000 times: $prof"
grep -q '^  [0-9]* 143$' p.profile || fail "the arm of hot that ran 143 times: $prof"

# The build by the profile: `never` cold and out of line, nothing counted.
zig=out/__rig_main.zig
grep -q 'pgoHit' "$zig" && fail "a build by a profile counts its sites"
grep -A1 'noinline fn never(' "$zig" | grep -q 'branchHint(.cold)' || fail "never is not cold: $(grep -A2 'fn never(' "$zig")"
grep -q 'noinline fn hot(' "$zig" && fail "hot, which ran, is out of line"

# Hints from the counts: an arm that never ran in a function that ran
# 1000 times is cold, and one that never ran in a block that ran once is
# unlikely; a hot function larger than the rule inlines is inlined.
awk '/fn hot\(/,/^}/' "$zig" | grep -q 'branchHint(.cold)' || fail "hot's arm that never ran is not cold: $(awk '/fn hot\(/,/^}/' "$zig")"
awk '/fn __rig_run_main\(/,/^}/' "$zig" | grep -q 'branchHint(.unlikely)' || fail "main's arm that never ran is not unlikely"
grep -q 'inline fn wide(' "$zig" || fail "the hot function wide is not inlined"
RIG_OUT_DIR=$PWD/plainout "$RIG" emit p.rig >/dev/null 2>&1 || fail "emit p.rig"
grep -q 'inline fn wide(' plainout/__rig_main.zig && fail "wide is inlined without a profile: the test needs a larger function"
grep -q 'branchHint(.unlikely)\|branchHint(.likely)' plainout/__rig_main.zig && fail "a build without a profile has hints"

# The profile alone, with no workload: the same build.
out=$(RIG_OUT_DIR=$PWD/out "$RIG" build --pgo=p.profile -o prog2 p.rig 2>&1); expect_rc $? 0 "build by the profile alone: $out"
expect_eq "$(./prog2)" "$want" "the program built by the profile alone"
grep -A1 'noinline fn never(' "$zig" | grep -q 'branchHint(.cold)' || fail "never is not cold when built by the profile alone"

# An edited function loses its counts: no longer cold.
sed 's/    return n - 1/    return n - 2/' p.rig >q.rig
out=$(RIG_OUT_DIR=$PWD/qout "$RIG" build --pgo=p.profile -o q q.rig 2>&1); expect_rc $? 0 "build an edited program by the profile: $out"
grep -A1 'fn never(' qout/__rig_main.zig | grep -q 'branchHint(.cold)' && fail "an edited function kept its counts"

# Usage: --pgo is build's, `--` after it is the workload, and the workload
# must run the program it built.
out=$("$RIG" run --pgo=p.profile p.rig 2>&1); expect_rc $? 2 "--pgo on run"
out=$("$RIG" build --pgo=missing.profile -o x p.rig 2>&1); expect_rc $? 1 "a missing profile"
expect_has "$out" "cannot read the profile" "a missing profile"
out=$(RIG_OUT_DIR=$PWD/out "$RIG" build --pgo=n.profile -o prog3 p.rig -- true 2>&1); expect_rc $? 1 "a workload that never runs the program"
expect_has "$out" "left no counts" "a workload that never runs the program"
exit 0
