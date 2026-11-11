# tools/mac-claim: it writes the claim line while its command runs and
# clears it after; it waits while another claim holds the Mac and while a
# correctness job holds a heavy slot; it starts its command only once
# heavy's jobs have gone quiet, and gives the claim up when they do not;
# it stops a command past its limit with exit status 124; and it gives up
# waiting with 75. A repository and
# a claim file of their own keep the test off the real ones.
# timeout: 90
source "$ROOT/test/cli/_lib.sh"

git init -q repo || fail "git init"
# The quiet test waits for the whole machine, which a test cannot
# make quiet: a bar no load reaches, but in the cases that test it.
export GIT_DIR=$PWD/repo/.git RIG_HEAVY_SLOTS=1 RIG_MAC_CLAIM=$PWD/claim/mac-timing.txt RIG_MAC_QUIET_S=1 RIG_MAC_QUIET_CPU=1000000
unset RIG_HEAVY_HELD RIG_HEAVY_CLASS
C=$ROOT/tools/mac-claim

out=$("$C" "test run" cat "$RIG_MAC_CLAIM"); rc=$?
expect_rc $rc 0 "a claim"
expect_has "$out" "test run, at most 19 min" "the claim line while it runs"
out=$("$C" "env run" sh -c 'echo $TRIG_MAC_CLAIMED$RIG_MAC_CLAIMED'); rc=$?
expect_eq "$out" "11" "the job knows it holds the claim"
[[ ! -s $RIG_MAC_CLAIM ]] || fail "the claim outlived its job: $(cat "$RIG_MAC_CLAIM")"

# Another claim holds the Mac: wait for it.
echo "someone else, at most 1 min" >"$RIG_MAC_CLAIM"
( sleep 2; : >"$RIG_MAC_CLAIM" ) &
t0=$(date +%s)
"$C" second true; rc=$?
expect_rc $rc 0 "a claim after another"
(($(date +%s) - t0 >= 2)) || fail "it ran inside another claim"

# A correctness job in tools/heavy: wait for it.
"$ROOT/tools/heavy" --class correctness sleep 3 &
gate=$!
for _ in $(seq 50); do [[ -s $GIT_DIR/rig-heavy.lock/class ]] && break; sleep 0.1; done
st=$("$C" --status)
expect_has "$st" "$gate (running)" "--status names the correctness job"
t0=$(date +%s)
"$C" third true; rc=$?
expect_rc $rc 0 "a claim after a correctness job"
(($(date +%s) - t0 >= 2)) || fail "it ran while a correctness job held a slot"
wait $gate

# A process that keeps a core busy, in heavy or not: the claim waits for
# quiet, then gives up with 75, names the busiest processes, and clears
# its line. The spinner ends itself, so a test killed early leaves none.
perl -e '$e = time + 20; 1 while time < $e' &
spin=$!
sleep 2
out=$(RIG_MAC_QUIET_WAIT=3 RIG_MAC_QUIET_CPU=30 "$C" busy true 2>&1); rc=$?
expect_rc $rc 75 "a claim beside a busy process"
expect_has "$out" "did not go quiet" "the quiet give-up message"
expect_has "$out" "Busiest:" "the give-up names the busiest processes"
[[ ! -s $RIG_MAC_CLAIM ]] || fail "the claim outlived its give-up"
kill $spin; wait $spin 2>/dev/null
# A quiet machine (here, a bar no load reaches): the claim goes ahead.
out=$(RIG_MAC_QUIET_WAIT=5 RIG_MAC_QUIET_CPU=1000000 "$C" quiet echo ran 2>&1); rc=$?
expect_rc $rc 0 "a claim on a quiet machine"
expect_has "$out" "ran" "the command ran"

# Past its limit: stopped, 124, and the claim cleared.
out=$(RIG_MAC_CLAIM_LIMIT_S=1 "$C" slow sleep 30 2>&1); rc=$?
expect_rc $rc 124 "a job past its limit"
expect_has "$out" "passed its" "the limit message"
[[ ! -s $RIG_MAC_CLAIM ]] || fail "the claim outlived a stopped job"

# A claim that never clears: give up.
echo "stuck, at most 20 min" >"$RIG_MAC_CLAIM"
out=$(RIG_HEAVY_WAIT=2 "$C" fourth true 2>&1); rc=$?
expect_rc $rc 75 "a waiter gives up"
expect_has "$out" "stuck" "the give-up names the claim"
: >"$RIG_MAC_CLAIM"

"$C" --minutes 30 x true 2>/dev/null
expect_rc $? 2 "a limit over 20 minutes"
exit 0
