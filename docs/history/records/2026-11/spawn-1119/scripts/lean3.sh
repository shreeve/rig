#!/bin/bash
# lean3.sh: which commit of spawn-lean slows fork.rig's qsort at 1 worker (leanboard: sp f95c21aff 9% slower than ab),
# and what spawn-lean-2 adds. Arms against ab = baa618b9f (#1181, main's runtime): bu 8bcfc88a9 (burst), sp f95c21aff
# (one wait a pass), cl 068f60998 (record class at compile time, on sp), ck d0995a086 (clock once per 16 pauses, on cl),
# al 11f9c6e6a (counters only), aa = copy of ab. Batch 1 binaries from /zfs/trig-pup/lean; cl and ck built here.
# Slot 697 (50 min): fork board 20 rounds and tasks 12 rounds at two placements. Slot 698 (15 min): spawn-only counters.
# Slot 699 (35 min): Trig c1 (40) and c4 (60) for base = ab, sp, ck; zod3 and tiny-invariant c4 at 100 rounds.
set -u
ssh pup "bash -s" <<'REMOTE'
S=/zfs/trig-pup/bin/pup-slot; O=/zfs/trig-pup/lean2; L=/zfs/trig-pup/lean; X=/zfs/trig-pup/spawnfix; C=/zfs/trig-pup/spawnctr; T=/zfs/trig-pup/rig-873f3e883; F=/zfs/trig-pup/standings-1118/order/src/fork-order/fork.rig
R=/zfs/trig-pup/runs/rig-light; P=$R/.zig-cache/trig-tests/packs/trig-release
export PATH=$HOME/.local/go/bin:$HOME/.cargo/bin:$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH PYTHONUNBUFFERED=1 TMPDIR=/zfs/trig-cache; mkdir -p $O/src
free() { for i in $(seq 240); do $S state | grep -q slot=none && return 0; sleep 30; done; exit 1; }
CL=068f60998; CK=d0995a086
free; cd /zfs/trig-pup/rig-$CK; taskset -c 12-19 zig build test -Doptimize=ReleaseFast -Dnexus=$HOME/Data/Code/nexus/bin/nexus > $O/ut-ReleaseFast.log 2>&1; echo "unit $CK ReleaseFast rc=$?"
free; cd $R && RIG=/zfs/trig-pup/rig-$CK/bin/rig TRIG_RIG_OVERRIDE=1 RIG_OUT_DIR=$O/out-trig-ck RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS='10,11 1,2 0,5' TRIG_RELEASE_GB=14 tools/release-slot tools/trig/gen-libtrees $P/src /zfs/trig-pup/rig-$CK/bin/rig build --release -o $O/trig-ck $P/src/main.rig > $O/build-trig-ck.log 2>&1; echo "trig-ck build rc=$?"
cp $T/bench/tasks/tasks.rig $O/src/tasks-p1.rig; printf '  print("pad0") if args.len == 99\n  print("pad1") if args.len == 98\n' >> $O/src/tasks-p1.rig
free; cd $T
for a in cl:$CL ck:$CK; do n=${a%%:*}; RG=/zfs/trig-pup/rig-${a#*:}/bin/rig
  RIG=$RG taskset -c 12-19 python3 bench/tasks/bench-tasks --out $O/tasks-$n --build-only --variants rig-safe > $O/bt-$n.log 2>&1 || { echo "tasks $n failed"; exit 1; }
  rm -rf $O/tasks-${n}1; cp -a $O/tasks-$n $O/tasks-${n}1; rm -f $O/tasks-${n}1/rig-safe
  RIG_OUT_DIR=$O/tasks-${n}1/out taskset -c 12-19 $RG build --release -o $O/tasks-${n}1/rig-safe $O/src/tasks-p1.rig > $O/bt-${n}1.log 2>&1 || { echo "tasks ${n}1 failed"; exit 1; }
  RIG_OUT_DIR=$O/spawn-out-$n taskset -c 12-19 $RG build --release -o $O/spawn-$n $C/spawn.rig > $O/bs-$n.log 2>&1 || { echo "spawn $n failed"; exit 1; }
  RIG_OUT_DIR=$O/fork-out-$n taskset -c 12-19 $RG build --release -o $O/fork-$n $F > $O/bf-$n.log 2>&1 || { echo "fork $n failed"; exit 1; }; done
for n in ab al bu sp aa; do for k in tasks-$n tasks-${n}1 spawn-$n fork-$n; do rm -rf $O/$k; cp -a $L/$k $O/$k; done; done
cp $X/trig-ab $O/trig-base; cp $L/trig-sp $O/trig-sp; echo "built $(date +%T)"
exec 9>/tmp/pup-timing.lock; flock -w 7200 9 || exit 1; free; bash /zfs/trig-pup/runs/timers-clear.sh 50 || exit 1
: > /zfs/trig-pup/quiet-log/697.txt; o=$($S open 697 50 ab "spawn-lean culprit: fork and tasks" 2>&1); echo "$o" | tail -n 1; echo "$o" | grep -q "open until" || exit 1
trap '$S close 697 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 697' EXIT
taskset -c 8 timeout 1500 python3 /zfs/trig-pup/runs/s1118-order-board.py 20 $O/fork-samples.txt rayon=/zfs/trig-pup/standings-1118/order/bin-rayon ab=$O/fork-ab bu=$O/fork-bu sp=$O/fork-sp cl=$O/fork-cl ck=$O/fork-ck aa=$O/fork-aa > $O/fork.txt 2>&1; echo "fork rc=$?"
V="ab ab1 bu bu1 sp sp1 ck ck1 aa aa1"; N=10
for r in $(seq 0 11); do for k in $(seq 0 9); do idx=$(( (k+r) % N + 1 )); a=$(echo $V | cut -d" " -f$idx); taskset -c 0-11 timeout 120 python3 bench/tasks/bench-tasks --out $O/tasks-$a --time-only --reps 9 --variants rig-safe > $O/t-$a-$r.txt 2>&1; done; done
$S close 697 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 697; trap - EXIT
free; bash /zfs/trig-pup/runs/timers-clear.sh 15 || exit 1
: > /zfs/trig-pup/quiet-log/698.txt; o=$($S open 698 15 ab "spawn-lean culprit: counters" 2>&1); echo "$o" | tail -n 1; echo "$o" | grep -q "open until" || exit 1
trap '$S close 698 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 698' EXIT
E=instructions,cycles,L1-dcache-load-misses,L1-icache-load-misses,branch-misses
for w in 1 12; do for r in 1 2 3 4 5; do for n in ab al bu sp cl ck aa; do
  RIG_WORKERS=$w taskset -c 0-11 perf stat -x, -e $E -o $O/st-$n-w$w-r$r.csv $O/spawn-$n > $O/out-$n-w$w-r$r.txt 2>&1; done; done; done
$S close 698 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 698; trap - EXIT
free; bash /zfs/trig-pup/runs/timers-clear.sh 35 || exit 1
: > /zfs/trig-pup/quiet-log/699.txt; o=$($S open 699 35 ab "spawn-lean culprit: Trig" 2>&1); echo "$o" | tail -n 1; echo "$o" | grep -q "open until" || exit 1
trap '$S close 699 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 699; rm -f $R/tools/bench/ab-fixed' EXIT
cd $R && cp /zfs/trig-pup/abAI/ab-fixed tools/bench/ab-fixed
timeout 800 python3 tools/bench/ab-fixed --cores 6 --rounds 40 --projects "mitt neverthrow superstruct tiny-invariant zod3 ts-pattern" --args "-p tsconfig.trig.json --noEmit --singleThreaded" --json $O/c1.json base=$O/trig-base sp=$O/trig-sp ck=$O/trig-ck > $O/c1.txt 2>&1; echo "c1 rc=$?"
timeout 900 python3 tools/bench/ab-fixed --cores 0,6,8,10 --rounds 60 --projects "mitt neverthrow superstruct tiny-invariant zod3 ts-pattern" --args "-p tsconfig.trig.json --noEmit --checkers 4" --json $O/c4.json base=$O/trig-base sp=$O/trig-sp ck=$O/trig-ck > $O/c4.txt 2>&1; echo "c4 rc=$?"
$S close 699 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 699; trap - EXIT
for f in c1 c4; do echo "== $f"; awk '/rounds, seed/{p=$1} /(sp|ck) +against/{print p": "$0}' $O/$f.txt; done
grep -E "^\| (1|12) " $O/fork.txt
python3 - $O <<'PY'
import re,statistics,glob,sys,collections
o=sys.argv[1]; d=collections.defaultdict(lambda: collections.defaultdict(list))
for f in glob.glob(o+"/t-*.txt"):
    a=f.rsplit("/",1)[1][2:].rsplit("-",1)[0]
    for l in open(f):
        m=re.match(r"(spawn|yield|chain|hog|fanout|produce)\s+([\d.]+) ",l)
        if m: d[m.group(1)][a].append(float(m.group(2)))
for row in ("spawn","chain","fanout","yield","hog","produce"):
    x=d[row]; print(row)
    for a in ("aa","ab","bu","sp","ck"):
        if not x[a] or not x[a+"1"]: continue
        m0=statistics.median(x[a]); m1=statistics.median(x[a+"1"]); b0=statistics.median(x["ab"]); b1=statistics.median(x["ab1"])
        print("  %-4s p0 %7.1f %.3f  p1 %7.1f %.3f   (against ab)"%(a,m0,m0/b0,m1,m1/b1))
for w in (1,12):
  print("== spawn-only, RIG_WORKERS=%d, per spawn (500k), median of 5"%w)
  for n in ("ab","al","bu","sp","cl","ck","aa"):
    ev={}; ns=[]
    for f in glob.glob(o+"/st-%s-w%d-r*.csv"%(n,w)):
      for l in open(f):
        p=l.strip().split(",")
        if len(p)>3 and p[0].replace(".","").isdigit(): ev.setdefault(p[2],[]).append(float(p[0]))
    for f in glob.glob(o+"/out-%s-w%d-r*.txt"%(n,w)):
      for l in open(f):
        m=re.match(r"spawn\s+([\d.]+)\s",l)
        if m: ns.append(float(m.group(1))/100000)
    med={k.replace("cpu_core/","").split("-load")[0].rstrip("/"):statistics.median(v)/500000 for k,v in ev.items()}
    print("  %-4s %6.1f ns  "%(n,statistics.median(ns) if ns else -1)+"  ".join("%s %.1f"%(k,v) for k,v in med.items()))
PY
REMOTE
