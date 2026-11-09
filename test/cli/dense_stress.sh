#!/usr/bin/env bash
# timeout: 120
# Dense stacks under load, in a release build, which is the only build
# that seals a guard into its executable (`sealDenseGuard`): bursts of
# tasks that are all alive at once end together on every worker, so the
# free stacks past what the workers keep are returned to the system
# (`sched.trimDense`) by several workers at a time, again and again.
# Workers that trimmed apart once overran the list of stacks whose pages
# went back: a segfault in about one run of thirty, so this loops for
# 25 seconds; the unit test "workers that return dense stacks at once"
# forces that overlap every time. A build that sanitizes retires each
# stack as its task ends (`retireDense`) and runs the same program clean.
source "$ROOT/test/cli/_lib.sh"

cat > stress.rig <<'RIG'
use std.task
use std.time

fun nap(i: Int) -> Int
  time.sleep(ms: 2) catch return -1
  i

fun round(n: Int) -> Int
  ts = Tasks[Int]()
  for i in 0..n
    !ts.add(nap(i)&)
  xs = >ts
  total = 0
  for x in xs
    total += x
  total

fun rounds(k: Int, n: Int) -> Int
  total = 0
  for _ in 0..k
    total += round(n)
  total

sub main()
  t = rounds(40, 4000)&
  print(>t)
RIG
"$RIG" check stress.rig >check.txt 2>&1 || fail "stress.rig: $(cat check.txt)"
"$RIG" emit stress.rig 2>&1 | grep -q 'spawnDense(nap' || fail "stress.rig: nap is not on a dense stack"
"$RIG" build --release=fast -o stress stress.rig >build.txt 2>&1 || fail "build stress.rig: $(cat build.txt)"
python3 - <<'PY' || fail "stress: no guard was written into the executable"
import sys
d = open("stress", "rb").read()
i = d.find(b"rig-dense-guard!")
sys.exit(0 if i >= 0 and int.from_bytes(d[i + 16:i + 24], "little") > 0 else 1)
PY
want=$(python3 -c 'print(40 * sum(range(4000)))')
end=$(( $(date +%s) + 25 ))
run=0
while (( run < 3 || $(date +%s) < end )); do
    run=$(( run + 1 ))
    out=$("$TIMEOUT_CMD" 60 ./stress 2>err.txt) || fail "stress run $run (status $?): $out $(tail -3 err.txt)"
    expect_eq "$out" "$want" "stress run $run"
done

RIG_SANITIZE=1 "$RIG" build --release=fast -o sanitized stress.rig >build-s.txt 2>&1 || fail "build stress.rig, sanitized: $(cat build-s.txt)"
out=$(RIG_SANITIZE=1 "$TIMEOUT_CMD" 60 ./sanitized 2>err-s.txt) || fail "sanitized stress (status $?): $out $(tail -3 err-s.txt)"
expect_eq "$out" "$want" "sanitized stress"
echo ok
