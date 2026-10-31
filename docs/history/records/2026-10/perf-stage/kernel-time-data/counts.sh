#!/bin/sh
# counts.sh N "KT..." [PROJECTS]: the prototype build under each RIG_KT, N
# runs each, interleaved, on E-core 15: wall, user and kernel cycles (both
# core types summed), page faults, minor faults, peak RSS. Exploration only;
# never a timing.
set -u
N=$1; KTS=$2; PROJS=${3:-ts-pattern zod3}
W=/zfs/worktrees/rig/kernel-time
P=$W/trig/misc/projects
O=$W/counts; mkdir -p $O
B=$W/packs/proto-rel/bin
for proj in $PROJS; do
  cd $P/$proj
  for r in $(seq 1 $N); do
    for kt in $KTS; do
      k=$kt; [ $k = none ] && k=
      RIG_KT=$k /usr/bin/time -f "%M %R" -o $O/time perf stat -x, -e duration_time,cycles:u,cycles:k,page-faults -o $O/perf taskset -c 15 $B -p tsconfig.trig.json --noEmit --singleThreaded > $O/out 2>&1
      f=$(awk -F, '/^[0-9]/ { k=$3; s[k]+=$1 } END { for (k in s) printf "%s=%s ", k, s[k] }' $O/perf)
      echo "$proj r=$r kt=$kt $f $(tail -n1 $O/time | awk "{print \"rss_kb=\" \$1, \"minflt=\" \$2}")"
    done
  done
done
