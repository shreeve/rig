#!/bin/sh
# measure.sh ROUNDS [ARMS]: Trig built by each Rig arm on the empty
# project, mitt and neverthrow at 1 and 4 checkers, on E-cores 12-15.
# Each round runs every arm 5 times under perf stat, in rotated order.
# Writes raw/ARM.PROJ.C.ROUND (perf -x, output), rss/, out/ and strace/.
W=/zfs/worktrees/rig/item15
P=/zfs/trig-pup/full/trig/misc/projects
CORES=${CORES:-12-15}
rounds=${1:-4}; shift
arms=${*:-base fix3 fix2}
E=task-clock,page-faults,cpu_atom/cycles/u,cpu_atom/cycles/k,cpu_atom/instructions/u,cpu_atom/instructions/k
mkdir -p $W/raw $W/rss $W/out $W/strace
dir() { [ $1 = empty ] && echo $W/empty || echo $P/$1; }
cat /proc/buddyinfo > $W/buddyinfo.start
for proj in ${PROJS:-empty mitt neverthrow}; do
  cd $(dir $proj)
  for c in ${CS:-1 4}; do
    for a in $arms; do
      B=$W/v/$a/bin
      taskset -c $CORES $B -p tsconfig.trig.json --noEmit --checkers $c > $W/out/$a.$proj.$c 2>&1; echo "exit $?" >> $W/out/$a.$proj.$c
      taskset -c $CORES strace -f -o $W/strace/$a.$proj.$c -e trace=mmap,munmap,madvise,openat $B -p tsconfig.trig.json --noEmit --checkers $c > /dev/null 2>&1
      for i in 1 2 3 4 5; do /usr/bin/time -f %M -a -o $W/rss/$a.$proj.$c taskset -c $CORES $B -p tsconfig.trig.json --noEmit --checkers $c > /dev/null 2>&1; done
    done
    r=1; set -- $arms
    while [ $r -le $rounds ]; do
      for a in "$@"; do
        taskset -c $CORES perf stat -r 5 -x, -e $E $W/v/$a/bin -p tsconfig.trig.json --noEmit --checkers $c > /dev/null 2> $W/raw/$a.$proj.$c.$r
      done
      # rotate the arms
      first=$1; shift; set -- "$@" $first
      r=$((r + 1))
    done
  done
done
cat /proc/buddyinfo > $W/buddyinfo.end
echo "$(date +%T) measured"
