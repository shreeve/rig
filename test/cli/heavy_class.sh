# tools/heavy: a correctness job goes ahead of a job that asked before it,
# --status names the holder and the queue without taking a slot, and a
# waiter gives up after RIG_HEAVY_WAIT seconds with exit status 75 and the
# holder's command. A repository of its own keeps the test off the real
# lock other runs hold.
# timeout: 60
source "$ROOT/test/cli/_lib.sh"

git init -q repo || fail "git init"
export GIT_DIR=$PWD/repo/.git RIG_HEAVY_SLOTS=1
unset RIG_HEAVY_HELD RIG_HEAVY_CLASS
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
exit 0
