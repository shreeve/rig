#!/bin/bash
# slot-np.sh (no arguments): Rig's narrow-placement measurement (2026-11-24, after narrow-split). One Trig binary, the
# PGO+BOLT build of phase-wide-trig 995763d59 (bind-in-load-2 825fe139 + task.widen() before the load, task.narrow()
# after the bind) on Rig's scratch narrow-place d77e182d0 (Final Push), in six arms:
#   M = nothing set (main's path); W = RIG_WIDE=1 (race 754's W); S = W + RIG_SPREAD=1; P = S + RIG_PIN=1;
#   F = P + RIG_GIVE=1; Q = RIG_PIN=1 alone (main's path, one worker per physical core).
# 16 board projects at c2/c4/c8 (no switch acts at c1), 10 rounds, wall, peak RSS and phases. Harness phases-sweepNP.sh.
# About 40 minutes; stopped at 55. Output: /zfs/trig-pup/trial/np/races/board16. Run only in a slot Rig opened.
set -u
D=/zfs/trig-pup/trial/np; H=$D/phases-sweepNP.sh; BIN=$D/bin-bolt
fatal() { echo "FATAL: $*"; exit 1; }
[ -x $BIN ] && $BIN --version >/dev/null 2>&1 || fatal "$BIN missing or does not run"
[ "$(sha256sum < $BIN | cut -c1-16)" = "$(cat $D/bin-bolt.sha16)" ] || fatal "$BIN is not the build checked"
[ -f $H ] || fatal "no harness $H"
case "$(/zfs/trig-pup/bin/pup-slot state)" in *slot=none*) fatal "no timing slot is open; only Rig opens slots" ;; esac
cd -P /zfs/trig-pup/corpus/webpack || fatal "no webpack"
peak() { taskset -c 0-11 $BIN -p tsconfig.json --noEmit --checkers 4 > /dev/null 2>&1 & local p=$! m=0 n; while kill -0 $p 2>/dev/null; do n=$(ls /proc/$p/task 2>/dev/null | wc -l); [ $n -gt $m ] && m=$n; sleep 0.002; done; echo $m; }
t0=$(env -u RIG_WIDE bash -c "$(declare -f peak); BIN=$BIN; peak"); t1=$(RIG_WIDE=1 bash -c "$(declare -f peak); BIN=$BIN; peak")
echo "# peak threads, webpack c4 on 0-11: RIG_WIDE unset $t0, RIG_WIDE=1 $t1"
[ "$t1" -gt "$t0" ] || fatal "RIG_WIDE=1 does not widen ($t0 -> $t1)"
# The pin: under RIG_PIN=1 (arm Q) the workers' affinity is one core's sibling pair; print the distinct masks once (non-fatal).
pins() { env -u RIG_WIDE RIG_PIN=1 taskset -c 0-11 $BIN -p tsconfig.json --noEmit --checkers 4 > /dev/null 2>&1 & local p=$!; sleep 0.25
  grep -h Cpus_allowed_list /proc/$p/task/*/status 2>/dev/null | awk '{print $2}' | sort | uniq -c | tr '\n' ' '; wait $p; }
echo "# affinity under RIG_PIN=1, webpack c4 at 0.25 s (count mask): $(pins)"
mkdir -p $D/races; s=$(date +%s)
echo "# slot-np start $(date +%T) BIN=$(cat $D/bin-bolt.sha16) state: $(/zfs/trig-pup/bin/pup-slot state)"
PROJS="supabase-studio mikro-orm formbricks-web cal-diy xstate-main webpack Compiler Compiler-Unions next-packages-next next-root storybook nuxt playwright drizzle-orm typeorm date-fns" \
  BIN=$BIN OUT=$D/races/board16 TP=/tmp/tp-np timeout 3300 bash $H 10
rc=$?
awk '/^# out /{k=$3" c"substr($4,2); d[k]=d[k]" "$5} END{bad=0; for (k in d) {n=split(d[k], x, " "); for (i=2;i<=n;i++) if (x[i]!=x[1]) {print "# OUTPUT DIFFERS: " k ":" d[k]; bad=1; break}} if (!bad) print "# outputs: all six arms agree in every case"}' $D/races/board16/runs | tee -a $D/races/board16/runs
echo "# slot-np done $(date +%T), $(( $(date +%s) - s )) s, harness rc=$rc; state: $(/zfs/trig-pup/bin/pup-slot state)"
