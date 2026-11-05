#!/bin/bash
# abn3.sh OUT ROUNDS NAME=BIN...: Trig binaries side by side, every job shuffled each round:
# ts-pattern and zod3 at 1, 4 and 8 checkers, the other four race projects at 4, on E-cores
# (1: 12; 4: 12-15; 8: 12-19). Each job runs twice: under exitwatch (the wall, and the exit:
# reaped less at-exit) and under perf stat and /usr/bin/time untraced (wall, task-clock,
# instructions and cycles of all threads, peak RSS).
# Copy the binaries to tmpfs first and run inside a timing slot.
set -u
OUT=$1; N=$2; shift 2; P=/zfs/trig-pup/full/trig/misc/projects; W=/zfs/rig-work/scaling/eh/exitwatch
: > $OUT
cores() { case $1 in 1) echo 12;; 4) echo 12-15;; 8) echo 12-19;; esac; }
jobs() {
  for arm in "$@"; do name=${arm%%=*}
    for pc in ts-pattern:1 ts-pattern:4 ts-pattern:8 zod3:1 zod3:4 zod3:8 mitt:4 neverthrow:4 superstruct:4 tiny-invariant:4; do
      for how in watch stat; do echo "$name:$pc:$how"; done
    done
  done
}
bin() { for arm in "$@"; do [ "${arm%%=*}" = "$name" ] && echo "${arm#*=}"; done; }
for r in $(seq 1 $N); do
  for job in $(jobs "$@" | shuf); do
    IFS=: read name proj c how <<< "$job"; b=$(bin "$@"); cd $P/$proj
    a="-p tsconfig.trig.json --noEmit --checkers $c"
    if [ $how = watch ]; then
      line=$(taskset -c $(cores $c) $W $b $a 2>&1 >/dev/null | grep '^exitwatch')
    else
      line=$(perf stat -x, -e task-clock,duration_time,cpu_atom/instructions/,cpu_atom/cycles/ /usr/bin/time -f "maxrss %M" taskset -c $(cores $c) $b $a 2>&1 >/dev/null | grep -E 'task-clock|duration_time|instructions|cycles|maxrss' | tr '\n' ' ')
    fi
    echo "r=$r arm=$name proj=$proj c=$c how=$how $line" >> $OUT
  done
done
