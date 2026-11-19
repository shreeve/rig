#!/bin/bash
# zfull.sh: Zig 0.17.1 against 0.17.0 on pup, about 25 minutes of timing: the same Rig source (main 2dc9a46f5
# built with 0.17.0, arm m13; zig-0171 53d983b53 built with 0.17.1 and compiling with it through bin/rig-z, arm
# z71; aa a copy of m13) against hyper, Rayon and the JSON parsers. Builds on E-cores with no slot open; timing in
# board slot 603 (45 min). Output /zfs/trig-pup/zfull.
set -u
S=/zfs/trig-pup/bin/pup-slot; R=/zfs/trig-pup/runs; U=/zfs/trig-pup/hyper-1116; A=$U/arms; O=/zfs/trig-pup/zfull; T=/zfs/trig-pup/rig-873f3e883
OLD=/zfs/trig-pup/rig-2dc9a46f5/bin/rig; NEW=/zfs/trig-pup/rig-z71/bin/rig; ST=/zfs/trig-pup/standings-1118
export PATH=$HOME/.local/go/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH PYTHONUNBUFFERED=1
free() { for i in $(seq 240); do $S state | grep -q slot=none && return 0; sleep 30; done; echo "no free slot"; exit 1; }
mkdir -p $O /zfs/trig-pup/rig-z71/bin; ln -sf /zfs/trig-pup/rig-z0171-53d983b53/bin/rig-z $NEW
free
# HTTP, net arms (barm.sh builds bench/mixed, http, net with /zfs/trig-pup/rig-NAME/bin/rig)
[ -s $A/m13/ok ] || bash $R/barm.sh m13 2dc9a46f5 || exit 1
[ -s $A/z71/ok ] || bash $R/barm.sh z71 z71 || exit 1
rm -rf $A/aa; cp -a $A/m13 $A/aa
# bench/tasks
cd $T; for a in m13:$OLD z71:$NEW; do n=${a%%:*}; RIG=${a#*:} taskset -c 12-19 python3 bench/tasks/bench-tasks --out $O/tasks/$n --build-only --variants rig-safe > $O/tasks-build-$n.log 2>&1 || { echo "tasks build $n failed"; exit 1; }; done
rm -rf $O/tasks/aa; cp -a $O/tasks/m13 $O/tasks/aa
# fork (the fork-order record's fork.rig) and its Rayon twin from the standings
F=$ST/order/src/fork-order/fork.rig
RIG_OUT_DIR=$O/pkg-old taskset -c 12-19 $OLD build --release -o $O/fork-m13 $F > $O/fork-build.log 2>&1 || exit 1
RIG_OUT_DIR=$O/pkg-new taskset -c 12-19 $NEW build --release -o $O/fork-z71 $F >> $O/fork-build.log 2>&1 || exit 1
cp $O/fork-m13 $O/fork-aa
# std.json (competitors reused from the standings' builds)
cd $ST/src; for a in rig-safe:$OLD rig-z:$NEW; do v=${a%%:*}; RIG=${a#*:} taskset -c 12-19 python3 bench/json/bench-json --out $O/json-$v --build-only --variants rig-safe > $O/json-build-$v.log 2>&1 || { echo "json build $v failed"; exit 1; }; done
for f in twitter twitterescaped canada citm_catalog gsoc-2018 github_events; do
  for v in rig-safe rig-z; do rm -rf $ST/json-build/$f-$v; cp -a $O/json-$v/$f-rig-safe $ST/json-build/$f-$v; done
  rm -rf $ST/json-build/$f-rig-aa; cp -a $ST/json-build/$f-rig-safe $ST/json-build/$f-rig-aa; done
echo "# built $(date +%T)"
# timing
exec 9>/tmp/pup-timing.lock; flock -w 7200 9 || { echo "no lock"; exit 1; }
free; bash $R/timers-clear.sh 45 || { echo "timers"; exit 1; }
mk() { mkdir -p $1; printf '#!/bin/sh\nexec taskset -c 0,5 %s "$@"\n' $2 > $1/$3; printf '#!/bin/sh\nexec taskset -c 1,2,3,4,6-11 %s "$@"\n' $4 > $1/load; chmod +x $1/*; }
D=$O/mk; rm -rf $D; ARMS="m13 z71 aa"; for a in $ARMS; do mk $D/$a $A/$a/mixed/rig-safe rig-safe $U/mixed/load-spin; done; mk $D/hyper $U/mixed/tokio tokio $U/mixed/load-spin
: > /zfs/trig-pup/quiet-log/603.txt
o=$($S open 603 45 board "Zig 0.17.1 vs 0.17.0: HTTP, net, tasks, fork, JSON" 2>&1); echo "$o" | tail -n 1; echo "$o" | grep -q "open until" || exit 1
trap '$S close 603 2>&1 | tail -n 1; bash $R/quiet-check.sh 603' EXIT
cd $T
run() { local n=$1 to=$2; shift 2; s=$(date +%s); timeout $to "$@" > $O/$n.txt 2>&1; echo "$n rc=$? $(( $(date +%s)-s )) s"; }
P=$(for a in $ARMS; do printf "%s=%s " $a $A/$a/mixed/rig-safe; done; echo hyper=$U/mixed/tokio)
run stat-trivial 300 bash $R/pstat.sh 3 $O/stat-trivial 150000 1000000 -- $P
run stat-mix 300 bash $R/pstat.sh 3 $O/stat-mix 150000 4 -- $P
M=$(for a in $ARMS; do printf "%s=%s:rig-safe " $a $D/$a; done; echo hyper=$D/hyper:tokio)
run tail 700 taskset -c 0-11 python3 $R/mixarms.py 5 $O/tail.jsonl bench/mixed/bench-mixed --idle 10000 --rates 120000,80000 --duration 4 -- $M
HA=$(for a in $ARMS; do printf "%s=%s " $a $A/$a/http/rig-safe; done; echo hyper=$U/http/tokio)
run http12 400 taskset -c 0-11 python3 /zfs/trig-pup/loopback-1105/http_ab_linux.py 5 $O/http12.raw $U/http/load $HA
REC=/zfs/trig-pup/loopback-1105/rig/docs/history/records/2026-11/concurrency-loopback
NA=$(for a in $ARMS; do printf "%s=%s " $a $A/$a/net/rig-safe; done)
run net12 300 taskset -c 0-11 python3 $REC/board.py 10 $O/net12.raw $NA
for r in 0 1 2; do for a in m13 z71 aa; do taskset -c 0-11 timeout 300 python3 bench/tasks/bench-tasks --out $O/tasks/$a --time-only --reps 9 --variants rig-safe > $O/tasks-$a-$r.txt 2>&1; done; done; echo "tasks done"
run fork 400 taskset -c 8 python3 $R/s1118-order-board.py 10 $O/fork-samples.txt m13=$O/fork-m13 rayon=$ST/order/bin-rayon z71=$O/fork-z71 aa=$O/fork-aa
run json 900 taskset -c 8 python3 $R/s1118-json-board.py $ST/src/bench/json $ST/json-build 6 10 $O/json-samples.txt rig-safe,rig-z,rig-aa,yyjson,simdjson-dom
echo "# timed $(date +%T)"
