#!/bin/sh
# movers.sh PROJECT EVENT A B [RUNS]: perf record EVENT over RUNS runs of
# builds A and B; the symbols whose samples moved most.
W=/zfs/worktrees/rig/map-stage
p=$1; ev=$2; a=$3; b=$4; runs=${5:-20}
cd $W/trig/misc/projects/$p
for x in $a $b; do
  cat > /tmp/mv-loop.sh <<LOOP
for i in \$(seq $runs); do $W/packs/$x/bin -p tsconfig.trig.json --noEmit --singleThreaded; done
LOOP
  taskset -c 8 perf record -q -e $ev -c ${PERIOD:-2000003} -o /tmp/mv-$x.data -- sh /tmp/mv-loop.sh > /dev/null 2>&1
  perf report -q -i /tmp/mv-$x.data --no-children --sort symbol -F overhead,sample,sym 2>/dev/null > /tmp/mv-$x.txt
done
python3 - /tmp/mv-$a.txt /tmp/mv-$b.txt <<'PY'
import sys, re, collections
def load(f):
    d = collections.Counter(); tot = 0
    for line in open(f):
        m = re.match(r'\s*([\d.]+)%\s+(\d+)\s+\[\.\]\s+(\S+)', line)
        if not m: continue
        sym = re.sub(r',true', '', m.group(3))
        d[sym] += int(m.group(2)); tot += int(m.group(2))
    return d, tot
a, ta = load(sys.argv[1]); b, tb = load(sys.argv[2])
print(f"samples {ta} -> {tb} ({(tb-ta)/ta*100:+.2f}%)")
ba = sum(v for k, v in a.items() if '__rig_builtin' in k); bb = sum(v for k, v in b.items() if '__rig_builtin' in k)
print(f"builtin Map/Set symbols {ba} -> {bb}")
mv = sorted(set(a) | set(b), key=lambda s: -abs(b[s] - a[s]))
for s in mv[:40]:
    print(f"  {b[s]-a[s]:+7d}  {a[s]:7d} {b[s]:7d}  {s[:110]}")
PY
