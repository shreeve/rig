#!/bin/bash
# gate1161.sh: Linux gates and a pup bench/actors + bench/tasks check for #1161 (actor-room 29204a71a) against main
# 2dc9a46f5, with an A/A copy of main; ab slot 605.
H=29204a71a; M=2dc9a46f5
cd ~/Data/Code/worktrees/trig/rig-light && for i in 1 2 3 4; do tools/pup-rig $H > /dev/null 2>&1; rc=$?; [ $rc -ne 75 ] && break; done; echo "pup-rig rc=$rc"
for i in 1 2 3; do TRIG_RIG_OVERRIDE=1 PUP_RIG=/zfs/trig-pup/rig-$H/bin/rig tools/light > /tmp/light-1161.txt 2>&1; rc=$?; [ $rc -ne 75 ] && break; done
echo "trig light rc=$rc"; grep -E 'expected jobs|light gate' /tmp/light-1161.txt
ssh pup "bash -s" <<REMOTE
S=/zfs/trig-pup/bin/pup-slot; O=/zfs/trig-pup/gate1161; T=/zfs/trig-pup/rig-873f3e883; mkdir -p \$O
export PATH=\$HOME/.local/go/bin:\$HOME/.cargo/bin:\$HOME/.local/bin:\$PATH PYTHONUNBUFFERED=1
free() { for i in \$(seq 240); do \$S state | grep -q slot=none && return 0; sleep 30; done; exit 1; }
free; cd /zfs/trig-pup/rig-$H; for m in Debug ReleaseSafe ReleaseFast; do free; s=\$(date +%s); taskset -c 12-19 zig build test -Doptimize=\$m -Dnexus=\$HOME/Data/Code/nexus/bin/nexus > \$O/ut-\$m.log 2>&1; echo "pup zig build test (\$m) rc=\$? \$((\$(date +%s)-s)) s"; done
cd \$T; for a in main:$M room:$H; do n=\${a%%:*}; free; for b in actors tasks; do RIG=/zfs/trig-pup/rig-\${a#*:}/bin/rig taskset -c 12-19 python3 bench/\$b/bench-\$b --out \$O/\$b-\$n --build-only --variants rig-safe > \$O/build-\$b-\$n.log 2>&1 || echo "build \$b \$n failed"; done; done
for b in actors tasks; do rm -rf \$O/\$b-aa; cp -a \$O/\$b-main \$O/\$b-aa; done
exec 9>/tmp/pup-timing.lock; flock -w 7200 9 || exit 1; free; bash /zfs/trig-pup/runs/timers-clear.sh 30 || exit 1
: > /zfs/trig-pup/quiet-log/605.txt; o=\$(\$S open 605 30 ab "#1161 actor room: bench/actors and tasks" 2>&1); echo "\$o" | tail -n 1; echo "\$o" | grep -q "open until" || exit 1
trap '\$S close 605 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 605' EXIT
for r in 0 1 2 3 4; do for a in main room aa; do for b in actors tasks; do taskset -c 0-11 timeout 300 python3 bench/\$b/bench-\$b --out \$O/\$b-\$a --time-only --reps 9 --variants rig-safe > \$O/t-\$b-\$a-\$r.txt 2>&1; done; done; done
python3 - \$O <<'PY'
import re,statistics,glob,sys,collections
o=sys.argv[1]; rows=collections.defaultdict(lambda: collections.defaultdict(list))
for f in glob.glob(o+"/t-*.txt"):
    _,b,a,r=f.rsplit("/",1)[1][:-4].split("-")
    for l in open(f):
        m=re.match(r"(\w+)\s+([\d.]+) (\S+)",l)
        if m and m.group(1)!="rig": rows[b+"/"+m.group(1)][a].append(float(m.group(2)))
for k,d in sorted(rows.items()):
    md={a:statistics.median(v) for a,v in d.items()}
    print("%-16s main %s room %s aa %s   room/main %.3f aa/main %.3f"%(k,md.get("main"),md.get("room"),md.get("aa"),md["room"]/md["main"],md["aa"]/md["main"]))
PY
REMOTE
