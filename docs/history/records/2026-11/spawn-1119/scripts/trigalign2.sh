#!/bin/bash
# trigalign2.sh (trigalign.sh with its builds overlapped): Trig on pup: base = fae440c77 (before 2026-11-19's runtime changes; spawnfix/trig-base), main 636fd02a5,
# anc bf981bde5 (main + rig_text on a 16 KiB boundary on Linux). Gates on anc: Trig light. Slot 700 (35 min): Trig c1 (40)
# and c4 (60), six projects. Slot 701 (25 min): fork board 12 rounds and tasks 8 rounds at two placements, main vs anc.
set -u
MAIN=636fd02a5; ANC=bf981bde5
for i in $(seq 60); do ssh pup "test -x /zfs/trig-pup/rig-$ANC/bin/rig" && break; sleep 10; done
cd ~/Data/Code/worktrees/trig/rig-light && for h in $MAIN $ANC; do for i in 1 2 3 4; do tools/pup-rig $h > /dev/null 2>&1; rc=$?; [ $rc -ne 75 ] && break; done; echo "pup-rig $h rc=$rc"; done
for i in 1 2 3; do TRIG_RIG_OVERRIDE=1 PUP_RIG=/zfs/trig-pup/rig-$ANC/bin/rig tools/light > /tmp/light-$ANC.txt 2>&1; rc=$?; [ $rc -ne 75 ] && break; done; echo "trig light $ANC rc=$rc $(grep -E 'light gate' /tmp/light-$ANC.txt | tail -1)"
ssh pup "bash -s" <<REMOTE
S=/zfs/trig-pup/bin/pup-slot; O=/zfs/trig-pup/trigalign; X=/zfs/trig-pup/spawnfix; T=/zfs/trig-pup/rig-873f3e883; F=/zfs/trig-pup/standings-1118/order/src/fork-order/fork.rig
R=/zfs/trig-pup/runs/rig-light; P=\$R/.zig-cache/trig-tests/packs/trig-release
export PATH=\$HOME/.local/go/bin:\$HOME/.cargo/bin:\$HOME/.local/bin:\$HOME/.local/share/mise/shims:\$PATH PYTHONUNBUFFERED=1 TMPDIR=/zfs/trig-cache; mkdir -p \$O/src
free() { for i in \$(seq 240); do \$S state | grep -q slot=none && return 0; sleep 30; done; exit 1; }
for a in main:$MAIN anc:$ANC; do n=\${a%%:*}; h=\${a#*:}; ( cd \$R && RIG=/zfs/trig-pup/rig-\$h/bin/rig TRIG_RIG_OVERRIDE=1 RIG_OUT_DIR=\$O/out-trig-\$n RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS='10,11 1,2 0,5' TRIG_RELEASE_GB=14 tools/release-slot tools/trig/gen-libtrees \$P/src /zfs/trig-pup/rig-\$h/bin/rig build --release -o \$O/trig-\$n \$P/src/main.rig > \$O/build-trig-\$n.log 2>&1; echo "trig-\$n build rc=\$?" ) & sleep 90; done
cp \$X/trig-base \$O/trig-base
cp \$T/bench/tasks/tasks.rig \$O/src/tasks-p1.rig; printf '  print("pad0") if args.len == 99\n  print("pad1") if args.len == 98\n' >> \$O/src/tasks-p1.rig
cd \$T
for a in main:$MAIN anc:$ANC; do n=\${a%%:*}; RG=/zfs/trig-pup/rig-\${a#*:}/bin/rig
  RIG=\$RG taskset -c 12-19 python3 bench/tasks/bench-tasks --out \$O/tasks-\$n --build-only --variants rig-safe > \$O/bt-\$n.log 2>&1 || { echo "tasks \$n failed"; exit 1; }
  rm -rf \$O/tasks-\${n}1; cp -a \$O/tasks-\$n \$O/tasks-\${n}1; rm -f \$O/tasks-\${n}1/rig-safe
  RIG_OUT_DIR=\$O/tasks-\${n}1/out taskset -c 12-19 \$RG build --release -o \$O/tasks-\${n}1/rig-safe \$O/src/tasks-p1.rig > \$O/bt-\${n}1.log 2>&1 || { echo "tasks \${n}1 failed"; exit 1; }
  RIG_OUT_DIR=\$O/fork-out-\$n taskset -c 12-19 \$RG build --release -o \$O/fork-\$n \$F > \$O/bf-\$n.log 2>&1 || { echo "fork \$n failed"; exit 1; }; done
rm -rf \$O/tasks-aa \$O/tasks-aa1; cp -a \$O/tasks-main \$O/tasks-aa; cp -a \$O/tasks-main1 \$O/tasks-aa1; cp \$O/fork-main \$O/fork-aa; echo "benches built"
wait; for n in base main anc; do a=\$(readelf -SW \$O/trig-\$n | grep " rig_text " | sed "s/.*PROGBITS *//" | cut -d" " -f1); echo "trig-\$n rig_text @0x\$a mod64=\$((0x\$a % 64)) mod4096=\$((0x\$a % 4096))"; done; echo built
exec 9>/tmp/pup-timing.lock; flock -w 7200 9 || exit 1; free; bash /zfs/trig-pup/runs/timers-clear.sh 35 || exit 1
: > /zfs/trig-pup/quiet-log/700.txt; o=\$(\$S open 700 35 ab "Trig: Linux section anchor" 2>&1); echo "\$o" | tail -n 1; echo "\$o" | grep -q "open until" || exit 1
trap '\$S close 700 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 700; rm -f \$R/tools/bench/ab-fixed' EXIT
cd \$R && cp /zfs/trig-pup/abAI/ab-fixed tools/bench/ab-fixed
timeout 800 python3 tools/bench/ab-fixed --cores 6 --rounds 40 --projects "mitt neverthrow superstruct tiny-invariant zod3 ts-pattern" --args "-p tsconfig.trig.json --noEmit --singleThreaded" --json \$O/c1.json base=\$O/trig-base main=\$O/trig-main anc=\$O/trig-anc > \$O/c1.txt 2>&1; echo "c1 rc=\$?"
timeout 1000 python3 tools/bench/ab-fixed --cores 0,6,8,10 --rounds 60 --projects "mitt neverthrow superstruct tiny-invariant zod3 ts-pattern" --args "-p tsconfig.trig.json --noEmit --checkers 4" --json \$O/c4.json base=\$O/trig-base main=\$O/trig-main anc=\$O/trig-anc > \$O/c4.txt 2>&1; echo "c4 rc=\$?"
rm -f \$R/tools/bench/ab-fixed; \$S close 700 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 700; trap - EXIT
free; bash /zfs/trig-pup/runs/timers-clear.sh 25 || exit 1
: > /zfs/trig-pup/quiet-log/701.txt; o=\$(\$S open 701 25 ab "Linux section anchor: fork, tasks" 2>&1); echo "\$o" | tail -n 1; echo "\$o" | grep -q "open until" || exit 1
trap '\$S close 701 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 701' EXIT
cd \$T; taskset -c 8 timeout 700 python3 /zfs/trig-pup/runs/s1118-order-board.py 12 \$O/fork-samples.txt rayon=/zfs/trig-pup/standings-1118/order/bin-rayon main=\$O/fork-main anc=\$O/fork-anc aa=\$O/fork-aa > \$O/fork.txt 2>&1; echo "fork rc=\$?"
V="main main1 anc anc1 aa aa1"; N=6
for r in \$(seq 0 7); do for k in \$(seq 0 5); do idx=\$(( (k+r) % N + 1 )); a=\$(echo \$V | cut -d" " -f\$idx); taskset -c 0-11 timeout 120 python3 bench/tasks/bench-tasks --out \$O/tasks-\$a --time-only --reps 9 --variants rig-safe > \$O/t-\$a-\$r.txt 2>&1; done; done
\$S close 701 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 701; trap - EXIT
for f in c1 c4; do echo "== \$f"; awk '/rounds, seed/{p=\$1} /(main|anc|aa) +against/{print p": "\$0}' \$O/\$f.txt; done
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
    for a in ("aa","main","anc"):
        if not x[a] or not x[a+"1"]: continue
        m0=statistics.median(x[a]); m1=statistics.median(x[a+"1"]); b0=statistics.median(x["main"]); b1=statistics.median(x["main1"])
        print("  %-4s p0 %7.1f %.3f  p1 %7.1f %.3f   (against main)"%(a,m0,m0/b0,m1,m1/b1))
PY
REMOTE
