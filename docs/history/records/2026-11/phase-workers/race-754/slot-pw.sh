#!/bin/bash
# slot-pw.sh (no arguments): the owner-approved phase-wide measurement (owner "Yes", 2026-11-24, via Rig). One Trig binary,
# the PGO+BOLT build of phase-wide-trig 995763d59 (bind-in-load-2 825fe139 + task.widen() before the load and
# task.narrow() after the bind) on Rig's scratch phase-wide e26d0196a (Final Push), in four arms:
#   M = RIG_WIDE, TRIG_BIND_IN_LOAD unset (main's path); W = RIG_WIDE=1 (the front end on all 12 hardware threads of
#   P-cores 0-11, the check on the 6 workers before it); X = RIG_WIDE=1 + TRIG_BIND_IN_LOAD=1; B = TRIG_BIND_IN_LOAD=1.
# 16 board projects at c1/c2/c4/c8, 10 rounds, wall, peak RSS and phases. c1 is an A/A/A/A. Harness phases-sweepPW.sh.
# About 46 minutes; stopped at 55. Output: /zfs/trig-pup/trial/pw/races/board16. Run only in a slot Rig opened.
set -u
D=/zfs/trig-pup/trial/pw; H=$D/phases-sweepPW.sh; BIN=$D/bin-bolt
fatal() { echo "FATAL: $*"; exit 1; }
[ -x $BIN ] && $BIN --version >/dev/null 2>&1 || fatal "$BIN missing or does not run"
[ "$(sha256sum < $BIN | cut -c1-16)" = "$(cat $D/bin-bolt.sha16)" ] || fatal "$BIN is not the build checked"
[ -f $H ] || fatal "no harness $H"
case "$(/zfs/trig-pup/bin/pup-slot state)" in *slot=none*) fatal "no timing slot is open; only Rig opens slots" ;; esac
cd -P /zfs/trig-pup/corpus/webpack || fatal "no webpack"
( TRIG_BIND_IN_LOAD=1 TRIG_PHASE_LINES=1 taskset -c 13 $BIN -p tsconfig.json --noEmit --checkers 2 --extendedDiagnostics 2>&1 >/dev/null | grep -q 'bound in the load' ) || fatal "no TRIG_BIND_IN_LOAD in $BIN"
peak() { taskset -c 0-11 $BIN -p tsconfig.json --noEmit --checkers 4 > /dev/null 2>&1 & local p=$! m=0 n; while kill -0 $p 2>/dev/null; do n=$(ls /proc/$p/task 2>/dev/null | wc -l); [ $n -gt $m ] && m=$n; sleep 0.002; done; echo $m; }
t0=$(env -u RIG_WIDE bash -c "$(declare -f peak); BIN=$BIN; peak"); t1=$(RIG_WIDE=1 bash -c "$(declare -f peak); BIN=$BIN; peak")
echo "# peak threads, webpack c4 on 0-11: RIG_WIDE unset $t0, RIG_WIDE=1 $t1"
[ "$t1" -gt "$t0" ] || fatal "RIG_WIDE=1 does not widen ($t0 -> $t1)"
mkdir -p $D/races; s=$(date +%s)
echo "# slot-pw start $(date +%T) BIN=$(cat $D/bin-bolt.sha16) state: $(/zfs/trig-pup/bin/pup-slot state)"
PROJS="supabase-studio mikro-orm formbricks-web cal-diy xstate-main webpack Compiler Compiler-Unions next-packages-next next-root storybook nuxt playwright drizzle-orm typeorm date-fns" \
  BIN=$BIN OUT=$D/races/board16 TP=/tmp/tp-pw timeout 3300 bash $H 10
rc=$?
awk '/^# out /{k=$3" c"substr($4,2); d[k]=d[k]" "$5} END{bad=0; for (k in d) {n=split(d[k], x, " "); for (i=2;i<=n;i++) if (x[i]!=x[1]) {print "# OUTPUT DIFFERS: " k ":" d[k]; bad=1; break}} if (!bad) print "# outputs: all four arms agree in every case"}' $D/races/board16/runs | tee -a $D/races/board16/runs
echo "# slot-pw done $(date +%T), $(( $(date +%s) - s )) s, harness rc=$rc; state: $(/zfs/trig-pup/bin/pup-slot state)"
