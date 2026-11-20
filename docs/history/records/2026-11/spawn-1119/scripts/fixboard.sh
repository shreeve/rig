#!/bin/bash
# fixboard.sh: #1181 (spawn-fill ad1c009b4) and #1182 (fork-maker 4e9e6f076), separately and together (fix-both e5d9f0fe6),
# against main fae440c77 (built as 4b14d6213, the same tree) and pre-stack 07d3b06c5, on pup. Gates: unit tests and Trig
# light for both PRs. Slot 680: fork.rig (20 rounds, with Rayon) and bench/tasks at two placements (12 rounds).
# Slot 681: Trig c1 (40) and c4 (60) for base, fm, sf, then zod3 c4 at 100 rounds.
set -u
SF=ad1c009b4; FM=4e9e6f076; BOTH=e5d9f0fe6; MAIN=4b14d6213; PRE=07d3b06c5
cd ~/Data/Code/worktrees/trig/rig-light && for h in $SF $BOTH; do for i in 1 2 3 4; do tools/pup-rig $h > /dev/null 2>&1; rc=$?; [ $rc -ne 75 ] && break; done; echo "pup-rig $h rc=$rc"; done
for h in $SF $FM; do for i in 1 2 3; do TRIG_RIG_OVERRIDE=1 PUP_RIG=/zfs/trig-pup/rig-$h/bin/rig tools/light > /tmp/light-$h.txt 2>&1; rc=$?; [ $rc -ne 75 ] && break; done; echo "trig light $h rc=$rc $(grep -E 'light gate' /tmp/light-$h.txt | tail -1)"; done
ssh pup "bash -s" <<REMOTE
S=/zfs/trig-pup/bin/pup-slot; O=/zfs/trig-pup/fixes; T=/zfs/trig-pup/rig-873f3e883; F=/zfs/trig-pup/standings-1118/order/src/fork-order/fork.rig
R=/zfs/trig-pup/runs/rig-light; P=\$R/.zig-cache/trig-tests/packs/trig-release
export PATH=\$HOME/.local/go/bin:\$HOME/.cargo/bin:\$HOME/.local/bin:\$HOME/.local/share/mise/shims:\$PATH PYTHONUNBUFFERED=1 TMPDIR=/zfs/trig-cache; mkdir -p \$O/src
free() { for i in \$(seq 240); do \$S state | grep -q slot=none && return 0; sleep 30; done; exit 1; }
for h in $SF $FM; do cd /zfs/trig-pup/rig-\$h; for m in Debug ReleaseSafe ReleaseFast; do free; taskset -c 12-19 zig build test -Doptimize=\$m -Dnexus=\$HOME/Data/Code/nexus/bin/nexus > \$O/ut-\$h-\$m.log 2>&1; echo "unit \$h \$m rc=\$?"; done; done
free; cd \$R && RIG=/zfs/trig-pup/rig-$SF/bin/rig TRIG_RIG_OVERRIDE=1 RIG_OUT_DIR=\$O/out-trig-sf RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS='10,11 1,2 0,5' TRIG_RELEASE_GB=14 tools/release-slot tools/trig/gen-libtrees \$P/src /zfs/trig-pup/rig-$SF/bin/rig build --release -o \$O/trig-sf \$P/src/main.rig > \$O/build-trig-sf.log 2>&1; echo "trig-sf build rc=\$?"
cp \$T/bench/tasks/tasks.rig \$O/src/tasks-p1.rig; printf '  print("pad0") if args.len == 99\n  print("pad1") if args.len == 98\n' >> \$O/src/tasks-p1.rig
free; cd \$T
for a in pre:$PRE main:$MAIN sf:$SF fm:$FM both:$BOTH; do n=\${a%%:*}; RG=/zfs/trig-pup/rig-\${a#*:}/bin/rig
  RIG=\$RG taskset -c 12-19 python3 bench/tasks/bench-tasks --out \$O/tasks-\$n --build-only --variants rig-safe > \$O/bt-\$n.log 2>&1 || { echo "tasks \$n failed"; exit 1; }
  rm -rf \$O/tasks-\${n}1; cp -a \$O/tasks-\$n \$O/tasks-\${n}1; rm -f \$O/tasks-\${n}1/rig-safe
  RIG_OUT_DIR=\$O/tasks-\${n}1/out taskset -c 12-19 \$RG build --release -o \$O/tasks-\${n}1/rig-safe \$O/src/tasks-p1.rig > \$O/bt-\${n}1.log 2>&1 || { echo "tasks \${n}1 failed"; exit 1; }
  RIG_OUT_DIR=\$O/fork-out-\$n taskset -c 12-19 \$RG build --release -o \$O/fork-\$n \$F > \$O/bf-\$n.log 2>&1 || { echo "fork \$n failed"; exit 1; }; done
rm -rf \$O/tasks-aa \$O/tasks-aa1; cp -a \$O/tasks-main \$O/tasks-aa; cp -a \$O/tasks-main1 \$O/tasks-aa1; cp \$O/fork-main \$O/fork-aa; echo built
exec 9>/tmp/pup-timing.lock; flock -w 7200 9 || exit 1; free; bash /zfs/trig-pup/runs/timers-clear.sh 50 || exit 1
: > /zfs/trig-pup/quiet-log/680.txt; o=\$(\$S open 680 50 ab "#1181/#1182 fixes: fork and tasks" 2>&1); echo "\$o" | tail -n 1; echo "\$o" | grep -q "open until" || exit 1
trap '\$S close 680 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 680' EXIT
taskset -c 8 python3 /zfs/trig-pup/runs/s1118-order-board.py 20 \$O/fork-samples.txt main=\$O/fork-main rayon=/zfs/trig-pup/standings-1118/order/bin-rayon pre=\$O/fork-pre sf=\$O/fork-sf fm=\$O/fork-fm both=\$O/fork-both aa=\$O/fork-aa > \$O/fork.txt 2>&1; echo "fork rc=\$?"
V="main main1 pre pre1 sf sf1 fm fm1 both both1 aa aa1"; N=12
for r in \$(seq 0 11); do for k in \$(seq 0 11); do idx=\$(( (k+r) % N + 1 )); a=\$(echo \$V | cut -d" " -f\$idx); taskset -c 0-11 timeout 120 python3 bench/tasks/bench-tasks --out \$O/tasks-\$a --time-only --reps 9 --variants rig-safe > \$O/t-\$a-\$r.txt 2>&1; done; done
\$S close 680 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 680; trap - EXIT
free; bash /zfs/trig-pup/runs/timers-clear.sh 40 || exit 1
: > /zfs/trig-pup/quiet-log/681.txt; o=\$(\$S open 681 45 ab "#1181/#1182 fixes: Trig" 2>&1); echo "\$o" | tail -n 1; echo "\$o" | grep -q "open until" || exit 1
trap '\$S close 681 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 681; rm -f \$R/tools/bench/ab-fixed' EXIT
cd \$R && cp /zfs/trig-pup/abAI/ab-fixed tools/bench/ab-fixed
timeout 1500 python3 tools/bench/ab-fixed --cores 6 --rounds 40 --projects "mitt neverthrow superstruct tiny-invariant zod3 ts-pattern" --args "-p tsconfig.trig.json --noEmit --singleThreaded" --json \$O/c1.json base=\$O/trig-base fm=\$O/trig-fm sf=\$O/trig-sf > \$O/c1.txt 2>&1; echo "c1 rc=\$?"
timeout 1500 python3 tools/bench/ab-fixed --cores 0,6,8,10 --rounds 60 --projects "mitt neverthrow superstruct tiny-invariant zod3 ts-pattern" --args "-p tsconfig.trig.json --noEmit --checkers 4" --json \$O/c4.json base=\$O/trig-base fm=\$O/trig-fm sf=\$O/trig-sf > \$O/c4.txt 2>&1; echo "c4 rc=\$?"
timeout 900 python3 tools/bench/ab-fixed --seed 2 --cores 0,6,8,10 --rounds 100 --projects "zod3" --args "-p tsconfig.trig.json --noEmit --checkers 4" base=\$O/trig-base fm=\$O/trig-fm sf=\$O/trig-sf > \$O/c4z.txt 2>&1; echo "c4 zod3 rc=\$?"
for f in c1 c4 c4z; do echo "== \$f"; awk '/rounds, seed/{p=\$1} /(fm|sf) +against/{print p": "\$0}' \$O/\$f.txt; done
grep -E "^\| (1|12) " \$O/fork.txt
python3 - \$O <<'PY'
import re,statistics,glob,sys,collections
o=sys.argv[1]; d=collections.defaultdict(lambda: collections.defaultdict(list))
for f in glob.glob(o+"/t-*.txt"):
    a=f.rsplit("/",1)[1][2:].rsplit("-",1)[0]
    for l in open(f):
        m=re.match(r"(spawn|yield|chain|hog)\s+([\d.]+) ",l)
        if m: d[m.group(1)][a].append(float(m.group(2)))
for row in ("spawn","chain","yield","hog"):
    x=d[row]; print(row)
    for a in ("main","aa","pre","sf","fm","both"):
        m0=statistics.median(x[a]); m1=statistics.median(x[a+"1"]); b0=statistics.median(x["main"]); b1=statistics.median(x["main1"])
        print("  %-5s p0 %6.1f %.3f  p1 %6.1f %.3f"%(a,m0,m0/b0,m1,m1/b1))
PY
REMOTE
