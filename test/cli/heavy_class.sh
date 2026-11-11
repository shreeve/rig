# tools/heavy: a correctness job goes ahead of a job that asked before it,
# --status names the holder and the queue without taking a slot, and a
# waiter gives up after RIG_HEAVY_WAIT seconds with exit status 75 and the
# holder's command. While a live timing claim holds, a plain job takes no
# slot and a correctness job does; a claim whose mac-claim died holds no
# one. A repository and a claim file of their own keep the test off the
# real lock and claim other runs hold.
# timeout: 60
source "$ROOT/test/cli/_lib.sh"

git init -q repo || fail "git init"
export GIT_DIR=$PWD/repo/.git RIG_HEAVY_SLOTS=1 RIG_MAC_CLAIM=$PWD/mac-timing.txt
unset RIG_HEAVY_HELD RIG_HEAVY_CLASS RIG_MAC_CLAIMED
H=$ROOT/tools/heavy

# One holder; then a plain job, then a correctness job.
"$H" sleep 4 &
holder=$!
for _ in $(seq 50); do [[ -d $GIT_DIR/rig-heavy.lock ]] && break; sleep 0.1; done
[[ -d $GIT_DIR/rig-heavy.lock ]] || fail "the holder took no slot"
"$H" sh -c 'echo plain >>order' &
plain=$!
sleep 0.5
"$H" --class correctness sh -c 'echo correctness >>order' &
corr=$!
sleep 0.5

st=$("$H" --status); rc=$?
expect_rc $rc 0 "--status"
case $st in *"PID $holder"*"sleep 4"*) ;; *) fail "--status names no holder: $st" ;; esac
case $st in *"waiting 1: PID $corr (correctness)"*"waiting 2: PID $plain (other)"*) ;; *) fail "--status queue: $st" ;; esac

wait $holder $plain $corr
expect_eq "$(cat order)" "correctness
plain" "a correctness job runs first"

# A waiter that gives up says what holds the slot.
"$H" sleep 6 &
holder=$!
for _ in $(seq 50); do [[ -d $GIT_DIR/rig-heavy.lock ]] && break; sleep 0.1; done
out=$(RIG_HEAVY_WAIT=2 "$H" echo never 2>&1); rc=$?
expect_rc $rc 75 "a waiter gives up"
case $out in *"gave up"*"PID $holder"*"sleep 6"*) ;; *) fail "the give-up names no holder: $out" ;; esac
kill $holder 2>/dev/null; wait $holder 2>/dev/null

"$H" --class nonsense true 2>/dev/null
expect_rc $? 2 "an unknown class"
[[ -z $(ls "$GIT_DIR/rig-heavy.lock.q") ]] || fail "a ticket outlived its waiter"

# A live claim: a plain job waits for it to clear; a correctness job goes.
sleep 30 & live=$!
echo "board, at most 19 min, started 20:00, pid $live" >"$RIG_MAC_CLAIM"
out=$(RIG_HEAVY_WAIT=2 "$H" true 2>&1); rc=$?
expect_rc $rc 75 "a plain job inside a claim"
"$H" --class correctness true
expect_rc $? 0 "a correctness job inside a claim"
( sleep 2; : >"$RIG_MAC_CLAIM" ) &
t0=$(date +%s)
"$H" true
expect_rc $? 0 "a plain job once the claim clears"
(($(date +%s) - t0 >= 2)) || fail "a plain job ran inside the claim"
RIG_MAC_CLAIMED=1 "$H" true <<<"" ; expect_rc $? 0 "a job inside the claim's own run"
# A line whose mac-claim died holds no one.
sh -c 'exit 0' & dead=$!; wait $dead
echo "board, at most 19 min, started 20:00, pid $dead" >"$RIG_MAC_CLAIM"
"$H" true
expect_rc $? 0 "a plain job beside a dead claim"
# A line naming no PID holds only while under 20 minutes old.
echo "by hand" >"$RIG_MAC_CLAIM"
out=$(RIG_HEAVY_WAIT=2 "$H" true 2>&1); rc=$?
expect_rc $rc 75 "a plain job beside a fresh line naming no PID"
touch -t "$(date -v-30M +%Y%m%d%H%M 2>/dev/null || date -d '-30 min' +%Y%m%d%H%M)" "$RIG_MAC_CLAIM"
"$H" true
expect_rc $? 0 "a plain job beside a 30-minute-old line naming no PID"
kill $live; wait $live 2>/dev/null
exit 0
