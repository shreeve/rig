#!/bin/bash
# spawnprof.sh: after spawnboard.sh, an ab slot (20 min) on P-cores 0-11: a spawn-only program (bench/tasks' spawn, 5 times)
# for pre, main, A, A+B. perf stat (instructions, cycles, L1d/L1i misses, branch misses) at RIG_WORKERS=1 and 12, 5 runs each;
# perf record on A+B and pre at 12 workers, reported by thread (the maker, main's worker, against the rest) and symbol.
set -u
for i in $(seq 160); do grep -q "slot 691 closed" ~/Data/Code/Claude/rig/rig/psum-gap/spawnboard.txt 2>/dev/null && break; sleep 30; done
grep -q "slot 691 closed" ~/Data/Code/Claude/rig/rig/psum-gap/spawnboard.txt || { echo "board not done"; exit 1; }
ssh pup 'bash -s' <<'REMOTE'
set -u
S=/zfs/trig-pup/bin/pup-slot; O=/zfs/trig-pup/spawnctr
export PATH=$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH TMPDIR=/zfs/trig-cache
free() { for i in $(seq 240); do $S state | grep -q slot=none && return 0; sleep 30; done; exit 1; }
for a in pre:07d3b06c5 main:63fc4bb68 a:a3318df85 ab:baa618b9f; do n=${a%%:*}; free
  RIG_OUT_DIR=$O/out-$n taskset -c 12-19 /zfs/trig-pup/rig-${a#*:}/bin/rig build --release -o $O/spawn-$n $O/spawn.rig > $O/b-$n.log 2>&1 || { echo "build $n failed"; tail -3 $O/b-$n.log; exit 1; }; done
echo built
exec 9>/tmp/pup-timing.lock; flock -w 7200 9 || exit 1; free; bash /zfs/trig-pup/runs/timers-clear.sh 20 || exit 1
: > /zfs/trig-pup/quiet-log/692.txt; o=$($S open 692 20 ab "spawn profile: counters and perf record" 2>&1); echo "$o" | tail -n 1; echo "$o" | grep -q "open until" || exit 1
trap '$S close 692 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 692' EXIT
E=instructions,cycles,L1-dcache-load-misses,L1-icache-load-misses,branch-misses
for w in 1 12; do for r in 1 2 3 4 5; do for n in pre main a ab; do
  RIG_WORKERS=$w taskset -c 0-11 perf stat -x, -e $E -o $O/st-$n-w$w-r$r.csv $O/spawn-$n > $O/out-$n-w$w-r$r.txt 2>&1; done; done; done
for n in ab pre; do RIG_WORKERS=12 taskset -c 0-11 perf record -q -F 9999 -o $O/perf-$n.data $O/spawn-$n > /dev/null 2>&1; done
$S close 692 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 692; trap - EXIT
python3 - $O <<'PY'
import sys,glob,statistics,re
o=sys.argv[1]
for w in (1,12):
  print("== RIG_WORKERS=%d, per spawn (500k tasks), median of 5"%w)
  base=None
  for n in ("pre","main","a","ab"):
    ev={}; ns=[]
    for f in glob.glob(o+"/st-%s-w%d-r*.csv"%(n,w)):
      for l in open(f):
        p=l.strip().split(",")
        if len(p)>3 and p[0].replace(".","").isdigit(): ev.setdefault(p[2],[]).append(float(p[0]))
    for f in glob.glob(o+"/out-%s-w%d-r*.txt"%(n,w)):
      for l in open(f):
        m=re.match(r"spawn\s+([\d.]+)(ns|us|µs|ms|s)?\s",l)
        if m: ns.append(float(m.group(1))*{"ns":1,"us":1e3,"µs":1e3,"ms":1e6,"s":1e9}[m.group(2) or "ns"]/100000)
    med={k:statistics.median(v)/500000 for k,v in ev.items()}
    print("  %-4s spawn-ns %6.1f  "%(n,statistics.median(ns) if ns else -1)+"  ".join("%s %.1f"%(k.split("-load")[0],v) for k,v in med.items()))
PY
for n in ab pre; do echo "== perf $n: by thread"; nice taskset -c 12-19 perf report -i $O/perf-$n.data --stdio --sort tid -q 2>/dev/null | head -14
  echo "== perf $n: busiest thread by symbol"; T=$(nice taskset -c 12-19 perf report -i $O/perf-$n.data --stdio --sort tid -q 2>/dev/null | awk 'NR==1{print $2}' | cut -d: -f1)
  nice taskset -c 12-19 perf report -i $O/perf-$n.data --stdio --tid $T --sort sym -q 2>/dev/null | head -22; done
REMOTE
