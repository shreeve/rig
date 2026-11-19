#!/bin/bash
# s1118-order.sh: the fork-order record's four programs on pup (Rig main 08b2caf1a): build on E-cores with no slot open,
# then 20 rounds in ab slot 590. Output /zfs/trig-pup/standings-1118/order.
set -u
S=/zfs/trig-pup/bin/pup-slot; R=/zfs/trig-pup/rig-08b2caf1a; RIG=$R/bin/rig; O=/zfs/trig-pup/standings-1118/order
F=$O/src/fork-order
export PATH=$HOME/.cargo/bin:$HOME/.local/bin:$PATH PYTHONUNBUFFERED=1
mkdir -p $O; $S state | grep -q slot=none || { echo "a slot is open; no build"; exit 1; }
for p in fork fork-left; do RIG_OUT_DIR=$O/pkg-$p taskset -c 12-19 $RIG build --release -o $O/$p $F/$p.rig > $O/build-$p.log 2>&1 || { tail -5 $O/build-$p.log; exit 1; }; done
cp $O/fork $O/fork-aa
for d in rayon rayon-right-first; do (cd $F/$d && CARGO_TARGET_DIR=$O/target-$d taskset -c 12-19 cargo build --release -q > $O/build-$d.log 2>&1) || { tail -5 $O/build-$d.log; exit 1; }; cp $O/target-$d/release/$(grep '^name' $F/$d/Cargo.toml | head -1 | cut -d'"' -f2) $O/bin-$d; done
ls -la $O/fork $O/fork-left $O/bin-rayon $O/bin-rayon-right-first
exec 9>/tmp/pup-timing.lock; flock -w 7200 9 || { echo "no lock"; exit 1; }
for i in $(seq 360); do $S state | grep -q slot=none && break; sleep 10; done
bash /zfs/trig-pup/runs/timers-clear.sh 30 || { echo "timers in the way"; exit 1; }
: > /zfs/trig-pup/quiet-log/590.txt
o=$($S open 590 30 ab "fork-order: four programs, 1 and 12 workers" 2>&1); echo "$o" | tail -n 1; echo "$o" | grep -q "open until" || exit 1
trap '$S close 590 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 590' EXIT
taskset -c 8 python3 /zfs/trig-pup/runs/s1118-order-board.py 20 $O/samples.txt fork=$O/fork rayon=$O/bin-rayon fork-left=$O/fork-left rayon-right-first=$O/bin-rayon-right-first fork-aa=$O/fork-aa
