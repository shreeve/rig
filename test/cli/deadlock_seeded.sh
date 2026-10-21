# A wait on channels alone that nothing can end: a deterministic run
# (RIG_SEED, as `rig test` sets) panics, naming the deadlock, since no
# outside event exists there; any other run waits on, since an
# interrupt may still cancel `main` (docs/internals/scheduler.md,
# "Deadlock").
# timeout: 120
source "$ROOT/test/cli/_lib.sh"

cat >stuck.rig <<'EOF'
sub main()!
  ch = *Chan[Int](1)
  print("before")
  print((!ch).recv()! ?? -1)
EOF
rig build -o stuck stuck.rig >build.log 2>&1 || fail "build stuck: $(cat build.log)"
for seed in 1 2 3; do
    out=$(RIG_SEED=$seed quiet ./stuck 2>&1); rc=$?
    [[ $rc -ne 0 ]] || fail "seed $seed: exited 0"
    expect_has "$out" "before" "seed $seed: output before the wait"
    expect_has "$out" "every task is waiting on another, and none can run: a deadlock" "seed $seed: the report"
done
# Not deterministic: no report; the program still waits after a second.
RIG_WORKERS=2 ./stuck >out.txt 2>err.txt & pid=$!
sleep 1
kill -0 $pid 2>/dev/null || fail "an unseeded run ended: $(cat out.txt err.txt)"
# Output is written as the program ends, so only its errors are read.
[[ ! -s err.txt ]] || fail "an unseeded run reported: $(cat err.txt)"
kill -9 $pid; wait $pid 2>/dev/null
exit 0
