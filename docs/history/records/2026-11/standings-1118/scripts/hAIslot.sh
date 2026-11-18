#!/bin/bash
# hAIslot.sh NEW: board AI, #1077's HTTP check (String of text pieces): main after #1145-#1148 and the drafts (arm NEW) against old main m10
# (c014f5e3f, board AG's), an A/A copy of NEW (aa), and hyper, load-spin. (1) CPU a request at 150k, trivial and mix,
# 3 rounds; (2) one core (0,5), 10,000 idle: p50/p99/p99.9 at 120k, 80k, 40k, 7 rounds; (3) the ceiling at 160k/200k,
# 4 rounds; (4) closed loop on 0-11, 7 rounds; (5) bench/net pinned 6,7 and on 0-11, 15 rounds; (6) bench/tasks on 0-11,
# 5 rounds. Slots 553 (60 min) and 554 (45 min, bench/tasks).
set -u
R=/zfs/trig-pup/runs; S=/zfs/trig-pup/bin/pup-slot; U=/zfs/trig-pup/hyper-1116; A=$U/arms; O=$U/bAI; T=/zfs/trig-pup/rig-873f3e883
NEW=${1:?arm}; ARMS="m11 $NEW aa"
rm -rf $A/aa; cp -a $A/$NEW $A/aa
for a in $ARMS; do for f in $A/$a/ok $A/$a/mixed/rig-safe $A/$a/http/rig-safe $A/$a/net/rig-safe; do [ -s "$f" ] || { echo "missing: $f"; exit 1; }; done; done
for i in $(seq 200); do w=$(bash $R/timers-clear.sh 60) && break; [ $i = 1 ] && echo "# waiting: $w ($(date +%T))"; sleep 60; done
exec 9>/tmp/pup-timing.lock; flock -w 7200 9 || { echo "no lock $(date +%T)"; exit 1; }
for i in $(seq 360); do $S state | grep -q "slot=none" && break; sleep 10; done
echo "# slot free $(date +%T); gap ${GAP:-60} s"; sleep ${GAP:-60}
mk() { mkdir -p $1; printf '#!/bin/sh\nexec taskset -c 0,5 %s "$@"\n' $2 > $1/$3; printf '#!/bin/sh\nexec taskset -c 1,2,3,4,6-11 %s "$@"\n' $4 > $1/load; chmod +x $1/*; }
D=$U/ai; rm -rf $D
for a in $ARMS; do mk $D/$a $A/$a/mixed/rig-safe rig-safe $U/mixed/load-spin; done
mk $D/hyper $U/mixed/tokio tokio $U/mixed/load-spin
: > /zfs/trig-pup/quiet-log/553.txt; mkdir -p $O
o=$($S open 553 40 board "board AI: #1077 String of text vs main, HTTP rows" 2>&1); echo "$o" | tail -n 1
echo "$o" | grep -q "open until" || { echo "slot refused"; exit 1; }
cd $T; export PYTHONUNBUFFERED=1
run() { local n=$1 to=$2; shift 2; s=$(date +%s); timeout $to "$@" > $O/$n.txt 2>&1; echo "$n rc=$? $(( $(date +%s)-s )) s"; }
P=$(for a in $ARMS; do printf "%s=%s " $a $A/$a/mixed/rig-safe; done; echo hyper=$U/mixed/tokio)
run stat-trivial 400 bash $R/pstat.sh 3 $O/stat-trivial 150000 1000000 -- $P
run stat-mix 400 bash $R/pstat.sh 3 $O/stat-mix 150000 4 -- $P
M=$(for a in $ARMS; do printf "%s=%s:rig-safe " $a $D/$a; done; echo hyper=$D/hyper:tokio)
run tail 1100 taskset -c 0-11 python3 $R/mixarms.py 7 $O/tail.jsonl bench/mixed/bench-mixed --idle 10000 --rates 120000,80000 --duration 4 -- $M
HA=$(for a in $ARMS; do printf "%s=%s " $a $A/$a/http/rig-safe; done; echo hyper=$U/http/tokio)
run http12 700 taskset -c 0-11 python3 /zfs/trig-pup/loopback-1105/http_ab_linux.py 7 $O/http12.raw $U/http/load $HA
$S close 553 2>&1 | tail -n 1; bash $R/quiet-check.sh 553
for f in stat-trivial stat-mix; do echo "== $f"; grep -h -E "median|of main" $O/$f.txt | cut -c1-120; done
python3 - $O/tail.jsonl <<'PY'
import json,sys,statistics
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
key=lambda r:(r["variant"],r.get("rate"))
for v,rate in dict.fromkeys(key(r) for r in rows):
    rs=[r for r in rows if key(r)==(v,rate)]; m=lambda k: statistics.median(sorted(r[k] for r in rs if k in r) or [0])
    print("%-6s %-7s p99 runs %s  median %d  p50 %d  p99.9 %d  timer_p99 %d  server %.2f  achieved %d" % (v,rate," ".join(str(r["p99"]) for r in sorted(rs,key=lambda r:r["p99"])),m("p99"),m("p50"),m("p999"),m("timer_p99"),m("server_cores"),m("achieved")))
PY
grep FAILED $O/*.txt
echo "== http12"; tail -n 8 $O/http12.raw
echo "# done $(date +%T)"
