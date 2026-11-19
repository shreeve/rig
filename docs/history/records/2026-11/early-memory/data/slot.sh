#!/bin/bash
# s1118-slot.sh NN MINUTES LABEL CMD...: runs CMD inside ab slot NN on pup, by pup's sharing rules:
# the timing lock, then no other slot, then no system timer due within MINUTES, then the quiet log,
# then the slot; the slot is closed and its quiet check printed on any way out. CMD gets
# MINUTES less one minute.
set -u
NN=$1 MIN=$2 LABEL=$3; shift 3
S=/zfs/trig-pup/bin/pup-slot; R=/zfs/trig-pup/runs
exec 9>/tmp/pup-timing.lock; flock -w 7200 9 || { echo "no lock $(date +%T)"; exit 1; }
echo "# lock $(date +%T)"
opened=0
for try in 1 2 3; do
  for i in $(seq 720); do $S state | grep -q "slot=none" && break; sleep 10; done
  $S state | grep -q "slot=none" || { echo "a slot stayed open two hours"; exit 1; }
  for i in $(seq 120); do w=$(bash $R/timers-clear.sh $MIN) && break; [ $i = 1 ] && echo "# waiting: $w ($(date +%T))"; sleep 60; done
  bash $R/timers-clear.sh $MIN >/dev/null || { echo "timers never cleared"; exit 1; }
  : > /zfs/trig-pup/quiet-log/$NN.txt
  o=$($S open $NN $MIN ab "$LABEL" 2>&1); rc=$?; echo "$o" | tail -n 3
  echo "$o" | grep -q "open until" && { opened=1; break; }
  [ $rc = 75 ] || { echo "slot refused rc=$rc"; exit 1; }
  echo "# open gave up waiting (75), try $try $(date +%T)"
done
[ $opened = 1 ] || exit 1
trap '$S close $NN 2>&1 | tail -n 1; bash $R/quiet-check.sh $NN' EXIT
trap 'exit 130' INT TERM HUP
echo "# $($S state)"
echo "# shell nproc $(nproc); $(taskset -p $$)"
timeout $(( MIN * 60 - 60 )) "$@"; echo "# cmd rc=$? $(date +%T)"
