#!/bin/bash
# leanboard.sh: spawn-lean on pup. Arms: main 63fc4bb68, ab baa618b9f (#1181), al 11f9c6e6a (no alignment check),
# bu 8bcfc88a9 (burst to the ring), sp f95c21aff (one stealNext wait a pass), aa = copy of ab.
# Gates for sp: pup unit tests (3 modes), Trig light. Trig arm trig-sp built (trig-ab, trig-base from spawnfix).
# Slot 694 (50 min): fork board 20 rounds (main ab sp aa + Rayon), tasks 12 rounds at two placements, actors 10 rounds.
# Slot 695 (20 min): spawn-only counters at 1 and 12 workers for all arms, perf record of sp and ab.
# Slot 696 (40 min): Trig c1 (40) and c4 (60) for base, ab, sp, then zod3 and tiny-invariant c4 at 100 rounds.
set -u
MAIN=63fc4bb68; AB=baa618b9f; AL=11f9c6e6a; BU=8bcfc88a9; SP=f95c21aff
cd ~/Data/Code/worktrees/trig/rig-light && for h in $AL $BU $SP; do for i in 1 2 3 4; do tools/pup-rig $h > /dev/null 2>&1; rc=$?; [ $rc -ne 75 ] && break; done; echo "pup-rig $h rc=$rc"; done
for i in 1 2 3; do TRIG_RIG_OVERRIDE=1 PUP_RIG=/zfs/trig-pup/rig-$SP/bin/rig tools/light > /tmp/light-$SP.txt 2>&1; rc=$?; [ $rc -ne 75 ] && break; done; echo "trig light $SP rc=$rc $(grep -E 'light gate' /tmp/light-$SP.txt | tail -1)"
ssh pup "bash -s" <<REMOTE
S=/zfs/trig-pup/bin/pup-slot; O=/zfs/trig-pup/lean; X=/zfs/trig-pup/spawnfix; C=/zfs/trig-pup/spawnctr; T=/zfs/trig-pup/rig-873f3e883; F=/zfs/trig-pup/standings-1118/order/src/fork-order/fork.rig
R=/zfs/trig-pup/runs/rig-light; P=\$R/.zig-cache/trig-tests/packs/trig-release
export PATH=\$HOME/.local/go/bin:\$HOME/.cargo/bin:\$HOME/.local/bin:\$HOME/.local/share/mise/shims:\$PATH PYTHONUNBUFFERED=1 TMPDIR=/zfs/trig-cache; mkdir -p \$O/src
free() { for i in \$(seq 240); do \$S state | grep -q slot=none && return 0; sleep 30; done; exit 1; }
cd /zfs/trig-pup/rig-$SP; for m in Debug ReleaseSafe ReleaseFast; do free; taskset -c 12-19 zig build test -Doptimize=\$m -Dnexus=\$HOME/Data/Code/nexus/bin/nexus > \$O/ut-\$m.log 2>&1; echo "unit $SP \$m rc=\$?"; done
free; cd \$R && RIG=/zfs/trig-pup/rig-$SP/bin/rig TRIG_RIG_OVERRIDE=1 RIG_OUT_DIR=\$O/out-trig-sp RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS='10,11 1,2 0,5' TRIG_RELEASE_GB=14 tools/release-slot tools/trig/gen-libtrees \$P/src /zfs/trig-pup/rig-$SP/bin/rig build --release -o \$O/trig-sp \$P/src/main.rig > \$O/build-trig-sp.log 2>&1; echo "trig-sp build rc=\$?"
cp \$X/trig-base \$O/trig-base; cp \$X/trig-ab \$O/trig-ab
cp \$T/bench/tasks/tasks.rig \$O/src/tasks-p1.rig; printf '  print("pad0") if args.len == 99\n  print("pad1") if args.len == 98\n' >> \$O/src/tasks-p1.rig
free; cd \$T
for a in main:$MAIN ab:$AB al:$AL bu:$BU sp:$SP; do n=\${a%%:*}; RG=/zfs/trig-pup/rig-\${a#*:}/bin/rig
  RIG=\$RG taskset -c 12-19 python3 bench/tasks/bench-tasks --out \$O/tasks-\$n --build-only --variants rig-safe > \$O/bt-\$n.log 2>&1 || { echo "tasks \$n failed"; exit 1; }
  rm -rf \$O/tasks-\${n}1; cp -a \$O/tasks-\$n \$O/tasks-\${n}1; rm -f \$O/tasks-\${n}1/rig-safe
  RIG_OUT_DIR=\$O/tasks-\${n}1/out taskset -c 12-19 \$RG build --release -o \$O/tasks-\${n}1/rig-safe \$O/src/tasks-p1.rig > \$O/bt-\${n}1.log 2>&1 || { echo "tasks \${n}1 failed"; exit 1; }
  RIG_OUT_DIR=\$O/spawn-out-\$n taskset -c 12-19 \$RG build --release -o \$O/spawn-\$n \$C/spawn.rig > \$O/bs-\$n.log 2>&1 || { echo "spawn \$n failed"; exit 1; }
  RIG_OUT_DIR=\$O/fork-out-\$n taskset -c 12-19 \$RG build --release -o \$O/fork-\$n \$F > \$O/bf-\$n.log 2>&1 || { echo "fork \$n failed"; exit 1; }
  RIG=\$RG taskset -c 12-19 python3 bench/actors/bench-actors --out \$O/actors-\$n --build-only --variants rig-safe > \$O/ba-\$n.log 2>&1 || { echo "actors \$n failed"; exit 1; }; done
rm -rf \$O/tasks-aa \$O/tasks-aa1 \$O/actors-aa; cp -a \$O/tasks-ab \$O/tasks-aa; cp -a \$O/tasks-ab1 \$O/tasks-aa1; cp -a \$O/actors-ab \$O/actors-aa; cp \$O/fork-ab \$O/fork-aa; cp \$O/spawn-ab \$O/spawn-aa; echo built
exec 9>/tmp/pup-timing.lock; flock -w 7200 9 || exit 1; free; bash /zfs/trig-pup/runs/timers-clear.sh 50 || exit 1
: > /zfs/trig-pup/quiet-log/694.txt; o=\$(\$S open 694 50 ab "spawn-lean: fork, tasks, actors" 2>&1); echo "\$o" | tail -n 1; echo "\$o" | grep -q "open until" || exit 1
trap '\$S close 694 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 694' EXIT
taskset -c 8 timeout 900 python3 /zfs/trig-pup/runs/s1118-order-board.py 20 \$O/fork-samples.txt main=\$O/fork-main rayon=/zfs/trig-pup/standings-1118/order/bin-rayon ab=\$O/fork-ab sp=\$O/fork-sp aa=\$O/fork-aa > \$O/fork.txt 2>&1; echo "fork rc=\$?"
V="main main1 ab ab1 al al1 bu bu1 sp sp1 aa aa1"; N=12
for r in \$(seq 0 11); do for k in \$(seq 0 11); do idx=\$(( (k+r) % N + 1 )); a=\$(echo \$V | cut -d" " -f\$idx); taskset -c 0-11 timeout 120 python3 bench/tasks/bench-tasks --out \$O/tasks-\$a --time-only --reps 9 --variants rig-safe > \$O/t-\$a-\$r.txt 2>&1; done
  [ \$r -lt 10 ] && for a in ab sp aa; do taskset -c 0-11 timeout 120 python3 bench/actors/bench-actors --out \$O/actors-\$a --time-only --reps 9 --variants rig-safe > \$O/a-\$a-\$r.txt 2>&1; done; done
\$S close 694 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 694; trap - EXIT
free; bash /zfs/trig-pup/runs/timers-clear.sh 20 || exit 1
: > /zfs/trig-pup/quiet-log/695.txt; o=\$(\$S open 695 20 ab "spawn-lean: counters and profile" 2>&1); echo "\$o" | tail -n 1; echo "\$o" | grep -q "open until" || exit 1
trap '\$S close 695 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 695' EXIT
E=instructions,cycles,L1-dcache-load-misses,L1-icache-load-misses,branch-misses
for w in 1 12; do for r in 1 2 3 4 5; do for n in main ab al bu sp aa; do
  RIG_WORKERS=\$w taskset -c 0-11 perf stat -x, -e \$E -o \$O/st-\$n-w\$w-r\$r.csv \$O/spawn-\$n > \$O/out-\$n-w\$w-r\$r.txt 2>&1; done; done; done
for n in sp ab; do RIG_WORKERS=12 taskset -c 0-11 perf record -q -F 9999 -o \$O/perf-\$n.data \$O/spawn-\$n > /dev/null 2>&1; done
\$S close 695 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 695; trap - EXIT
free; bash /zfs/trig-pup/runs/timers-clear.sh 40 || exit 1
: > /zfs/trig-pup/quiet-log/696.txt; o=\$(\$S open 696 40 ab "spawn-lean: Trig" 2>&1); echo "\$o" | tail -n 1; echo "\$o" | grep -q "open until" || exit 1
trap '\$S close 696 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 696; rm -f \$R/tools/bench/ab-fixed' EXIT
cd \$R && cp /zfs/trig-pup/abAI/ab-fixed tools/bench/ab-fixed
timeout 900 python3 tools/bench/ab-fixed --cores 6 --rounds 40 --projects "mitt neverthrow superstruct tiny-invariant zod3 ts-pattern" --args "-p tsconfig.trig.json --noEmit --singleThreaded" --json \$O/c1.json base=\$O/trig-base ab=\$O/trig-ab sp=\$O/trig-sp > \$O/c1.txt 2>&1; echo "c1 rc=\$?"
timeout 1000 python3 tools/bench/ab-fixed --cores 0,6,8,10 --rounds 60 --projects "mitt neverthrow superstruct tiny-invariant zod3 ts-pattern" --args "-p tsconfig.trig.json --noEmit --checkers 4" --json \$O/c4.json base=\$O/trig-base ab=\$O/trig-ab sp=\$O/trig-sp > \$O/c4.txt 2>&1; echo "c4 rc=\$?"
timeout 500 python3 tools/bench/ab-fixed --seed 2 --cores 0,6,8,10 --rounds 100 --projects "zod3 tiny-invariant" --args "-p tsconfig.trig.json --noEmit --checkers 4" base=\$O/trig-base ab=\$O/trig-ab sp=\$O/trig-sp > \$O/c4z.txt 2>&1; echo "c4 recheck rc=\$?"
\$S close 696 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 696; trap - EXIT
for f in c1 c4 c4z; do echo "== \$f"; awk '/rounds, seed/{p=\$1} /(ab|sp) +against/{print p": "\$0}' \$O/\$f.txt; done
grep -E "^\| (1|12) " \$O/fork.txt
python3 - \$O <<'PY'
import re,statistics,glob,sys,collections
o=sys.argv[1]; d=collections.defaultdict(lambda: collections.defaultdict(list))
for f in glob.glob(o+"/t-*.txt"):
    a=f.rsplit("/",1)[1][2:].rsplit("-",1)[0]
    for l in open(f):
        m=re.match(r"(spawn|yield|chain|hog|fanout|produce)\s+([\d.]+) ",l)
        if m: d[m.group(1)][a].append(float(m.group(2)))
for row in ("spawn","chain","fanout","yield","hog","produce"):
    x=d[row]; print(row)
    for a in ("main","aa","ab","al","bu","sp"):
        if not x[a] or not x[a+"1"]: continue
        m0=statistics.median(x[a]); m1=statistics.median(x[a+"1"]); b0=statistics.median(x["ab"]); b1=statistics.median(x["ab1"])
        print("  %-4s p0 %7.1f %.3f  p1 %7.1f %.3f   (against ab)"%(a,m0,m0/b0,m1,m1/b1))
a=collections.defaultdict(lambda: collections.defaultdict(list))
for f in glob.glob(o+"/a-*.txt"):
    n=f.rsplit("/",1)[1][2:].rsplit("-",1)[0]
    for l in open(f):
        m=re.match(r"(\w+)\s+([\d.]+) ",l)
        if m: a[m.group(1)][n].append(float(m.group(2)))
for row,x in sorted(a.items()):
    if x["ab"] and x["sp"]: print("actors/%-8s ab %.1f sp %.1f aa %.1f  sp/ab %.3f"%(row,statistics.median(x["ab"]),statistics.median(x["sp"]),statistics.median(x["aa"]),statistics.median(x["sp"])/statistics.median(x["ab"])))
for w in (1,12):
  print("== spawn-only, RIG_WORKERS=%d, per spawn (500k), median of 5"%w)
  for n in ("main","ab","al","bu","sp","aa"):
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
for n in sp ab; do echo "== perf \$n all threads"; nice taskset -c 12-19 perf report -i \$O/perf-\$n.data --stdio --sort sym -q 2>/dev/null | head -16
  for s in rig.sched.wakeIn rig.sched.search; do echo "-- \$n \$s hot"; nice taskset -c 12-19 perf annotate -i \$O/perf-\$n.data --stdio -s \$s 2>/dev/null | grep -E "^\s+[0-9]+\.[0-9]+" | sort -rn | head -4; done; done
REMOTE
