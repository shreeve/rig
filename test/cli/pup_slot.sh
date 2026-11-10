# tools/pup-slot (Linux only; elsewhere it checks the script parses): a
# board slot pauses a build and close resumes it; a board slot waits, and
# gives up with 75, when too few free 2 MiB blocks remain or a test suite
# runs, leaving nothing paused. Its state, log, block count and the
# processes it may touch are the test's own, so no real build is paused.
# timeout: 90
source "$ROOT/test/cli/_lib.sh"

S=$ROOT/tools/pup-slot
bash -n "$S" || fail "pup-slot does not parse"
[[ $(uname) == Linux && -r /proc/buddyinfo ]] || exit 0

export PUP_SLOT_NOSUDO=1 PUP_SLOT_TICK=1 PUP_SLOT_WAIT=4
export PUP_SLOT_BUILD_RE='[p]upslottest-build' PUP_SLOT_SUITE_RE='[p]upslottest-suite'
export PUP_SLOT_LOG=$PWD/slots.log PUP_SLOT_CORRECTNESS=$PWD/corr
buddy() { echo "Node 0, zone   Normal 1 1 1 1 1 1 1 1 1 $1 0" >"$PWD/buddy"; }
export PUP_SLOT_BUDDYINFO=$PWD/buddy
pstate() { ps -o stat= -p "$1" | cut -c1; }

bash -c 'exec -a pupslottest-build sleep 60' &
b=$!
sleep 0.3

# A board slot with room pauses the build; close resumes it.
buddy 100
export PUP_SLOT_TMP=$PWD/t1; mkdir -p "$PUP_SLOT_TMP"
out=$("$S" open 7 5 board "a test"); rc=$?
expect_rc $rc 0 "a board slot opens"
expect_has "$out" "slot 7 (board) open" "the open line"
expect_eq "$(pstate $b)" T "the build is paused"
expect_has "$("$S" state)" "blocks=100" "state"
out=$("$S" close 7); rc=$?
expect_rc $rc 0 "close"
expect_eq "$(pstate $b)" S "the build is resumed"
expect_has "$(cat slots.log)" 'open 7 board 5min label="a test" blocks=100' "the log"

# Too few free blocks: it gives up with 75 and leaves the build running.
buddy 10
export PUP_SLOT_TMP=$PWD/t2; mkdir -p "$PUP_SLOT_TMP"
out=$("$S" open 8 5 board 2>&1); rc=$?
expect_rc $rc 75 "a board slot without room"
expect_has "$out" "only 10 free 2 MiB blocks" "the reason"
expect_eq "$(pstate $b)" S "nothing left paused"
[[ ! -e $PUP_SLOT_TMP/slot-active ]] || fail "a slot opened without room"

# A test suite running: it waits rather than pausing the suite's builds.
buddy 100
bash -c 'exec -a pupslottest-suite sleep 60' &
s=$!
sleep 0.3
export PUP_SLOT_TMP=$PWD/t3; mkdir -p "$PUP_SLOT_TMP"
out=$("$S" open 9 5 board 2>&1); rc=$?
expect_rc $rc 75 "a slot while a suite runs"
expect_has "$out" "test suites running (PIDs $s)" "the reason"
expect_eq "$(pstate $b)" S "nothing paused while a suite runs"
kill $s

# A running correctness build: a board slot waits for it; a file whose
# start time is not its PID's (a reused PID) counts for nothing.
mkdir -p corr
bash -c 'exec -a pupslottest-corr sleep 60' &
c=$!
sleep 0.3
start=$(sed 's/^.*) //' /proc/$c/stat | awk '{ print $20 }')
echo "run $start" >corr/$c
export PUP_SLOT_TMP=$PWD/t4; mkdir -p "$PUP_SLOT_TMP"
out=$("$S" open 10 5 board 2>&1); rc=$?
expect_rc $rc 75 "a board slot while a correctness build runs"
expect_has "$out" "correctness builds running (PIDs $c)" "the reason"
echo "run 1" >corr/$c
export PUP_SLOT_TMP=$PWD/t5; mkdir -p "$PUP_SLOT_TMP"
out=$("$S" open 11 5 board); rc=$?
expect_rc $rc 0 "a stale correctness file is ignored"
"$S" close 11 >/dev/null
[[ -e corr/$c ]] || fail "pup-slot removed a file it does not own"
kill $c $b
exit 0
