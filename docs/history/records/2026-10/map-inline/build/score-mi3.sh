#!/bin/sh
# score-mi.sh N PROJECT...: Trig (fork)'s score2.sh, its method unchanged
# (each variant once a round, interleaved; fastest wall, its instructions,
# median peak RSS and faults), with main's PGO build (T) against
# map-inline's (TP), one checker on core 8 (not 3) and four on 6-9 (not 0-11).
n=$1; shift
W=/zfs/worktrees/rig/map-inline
T=$W/packs/base-pgo/bin
TP=$W/packs/new-pgo/bin
TS=$W/packs/newc-pgo/bin
out=$(mktemp -d /zfs/trig-cache/score.XXXXXX)
variants="main1 inl1 split1 main4 inl4 split4"
cmd_of() {
  case $1 in
    main1) echo "taskset -c 8 $T -p tsconfig.trig.json --noEmit --singleThreaded" ;;
    inl1) echo "taskset -c 8 $TP -p tsconfig.trig.json --noEmit --singleThreaded" ;;
    main4) echo "taskset -c 6-9 $T -p tsconfig.trig.json --noEmit --checkers 4" ;;
    split1) echo "taskset -c 8 $TS -p tsconfig.trig.json --noEmit --singleThreaded" ;;
    split4) echo "taskset -c 6-9 $TS -p tsconfig.trig.json --noEmit --checkers 4" ;;
    inl4) echo "taskset -c 6-9 $TP -p tsconfig.trig.json --noEmit --checkers 4" ;;
  esac
}
for p in "$@"; do
  cd $W/trig/misc/projects/$p
  for i in $(seq 1 $n); do
    QLOG=$W/res4/quiet.log sh $W/quiet.sh
    for v in $variants; do
      s=$(date +%s%N)
      perf stat -x, -e instructions:u,page-faults -o $out/$v.$i.stat /usr/bin/time -f "%M" -o $out/$v.$i.rss $(cmd_of $v) >/dev/null 2>&1
      e=$(date +%s%N)
      echo $(( (e - s) / 1000 )) > $out/$v.$i.wall
    done
  done
  for v in $variants; do
    best=999999999; bi=1
    for i in $(seq 1 $n); do w=$(cat $out/$v.$i.wall); [ $w -lt $best ] && { best=$w; bi=$i; }; done
    ins=$(grep -h "instructions" $out/$v.$bi.stat | cut -d, -f1 | awk "{s+=\$1} END{print s+0}")
    f=$(grep -h ",page-faults," $out/$v.*.stat | cut -d, -f1 | sort -n | sed -n "$(( (n + 1) / 2 ))p")
    r=$(tail -qn1 $out/$v.*.rss | sort -n | sed -n "$(( (n + 1) / 2 ))p")
    printf "%-12s %-7s wall %7.1f ms  instr %6.2fG  rss %4d MB  faults %6d\n" $p $v $(echo "$best / 1000" | bc -l) $(echo "$ins / 1000000000" | bc -l) $((r / 1024)) $f
  done
  rm -f $out/*
done
rm -rf $out
