#!/bin/sh
# runs.sh BUILD: run Trig build b/BUILD/bin on empty, zod3, ts-pattern at one checker,
# E-cores 12-19, with MEMWALK_DIR (stage snapshots) and /usr/bin/time -v.
M=/zfs/trig-pup/memwalk; B=$M/b/$1/bin; R=$M/r/$1
for proj in empty zod3 ts-pattern; do
  case $proj in empty) dir=/zfs/trig-cache/fe-proj/empty;; *) dir=/zfs/trig-pup/full/trig/misc/projects/$proj;; esac
  o=$R/$proj; rm -rf $o; mkdir -p $o; cd $dir
  MEMWALK_DIR=$o taskset -c 12-19 /usr/bin/time -v $B -p tsconfig.trig.json --noEmit --singleThreaded --checkers 1 > $o/out 2> $o/err; echo $? > $o/status
  for i in 1 2 3; do taskset -c 12-19 /usr/bin/time -f "maxrss_kb %M" $B -p tsconfig.trig.json --noEmit --singleThreaded --checkers 1 > /dev/null 2>> $o/plain.err; done
  echo "$proj status $(cat $o/status) $(grep -c MEMWALK $o/err) snaps; $(grep maxrss_kb $o/plain.err | tr '\n' ' ')"
done
