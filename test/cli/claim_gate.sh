# test/claim.rip, the gate test/rig.rip passes before each job: a live
# claim holds a job until its line clears, a line whose mac-claim has died
# holds no one, a line naming no PID holds only while under 20 minutes
# old, a job run inside the claim (RIG_MAC_CLAIMED) goes ahead, and a wait
# past its bound fails naming the claim. A claim file of its own keeps the test off the real one.
# timeout: 60
source "$ROOT/test/cli/_lib.sh"
command -v rip >/dev/null || { echo "no rip on PATH: skipped"; exit 0; }

export RIG_MAC_CLAIM=$PWD/mac-timing.txt RIG_MAC_CLAIM_POLL_MS=200
unset RIG_MAC_CLAIMED
cat >held.rip <<RIP
import { claimHeld } from '$ROOT/test/claim.rip'
console.log claimHeld()
RIP
cat >wait.rip <<RIP
import { claimWait } from '$ROOT/test/claim.rip'
t = Date.now()
claimWait()
console.log Math.round((Date.now() - t) / 1000)
RIP

: >"$RIG_MAC_CLAIM"
expect_eq "$(rip held.rip)" false "an empty claim file"
sleep 60 & live=$!
echo "board, at most 19 min, started 20:00, pid $live" >"$RIG_MAC_CLAIM"
expect_eq "$(rip held.rip)" true "a live claim"
expect_eq "$(RIG_MAC_CLAIMED=1 rip held.rip)" false "a job inside the claim"
sh -c 'exit 0' & dead=$!; wait $dead
echo "board, at most 19 min, started 20:00, pid $dead" >"$RIG_MAC_CLAIM"
expect_eq "$(rip held.rip)" false "a claim whose mac-claim died"
echo "an older line with no pid" >"$RIG_MAC_CLAIM"
expect_eq "$(rip held.rip)" true "a fresh line naming no PID"
touch -t "$(date -v-30M +%Y%m%d%H%M 2>/dev/null || date -d '-30 min' +%Y%m%d%H%M)" "$RIG_MAC_CLAIM"
expect_eq "$(rip held.rip)" false "a line naming no PID, 30 minutes old"
echo "board, at most 19 min, started 20:00, pid $live" >"$RIG_MAC_CLAIM"
out=$(RIG_HEAVY_WAIT=1 rip wait.rip 2>&1) && fail "a wait past its bound went ahead: $out"
expect_has "$out" "held for timing past" "the bound's message"

# A job waits while the live claim holds, and goes once it clears.
echo "board, at most 19 min, started 20:00, pid $live" >"$RIG_MAC_CLAIM"
( sleep 3; : >"$RIG_MAC_CLAIM" ) &
waited=$(rip wait.rip)
(( waited >= 2 )) || fail "the job did not wait for the claim: ${waited} s"
kill $live; wait $live 2>/dev/null
exit 0
