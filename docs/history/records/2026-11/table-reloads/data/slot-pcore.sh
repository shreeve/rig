#!/bin/bash
# slot-pcore.sh (no arguments): do Trig's extra loads cost cycles on a P-core? c1 on P-core 3, inside a board slot
# that Rig has opened (this script opens none). Arms, shuffled each round: T = Trig main 3c6d8627 PGO+BOLT, T2 = the
# same binary again (the A/A), G = tsrs 0.23.0 as raced. Projects: Compiler, typeorm, webpack, supabase-studio, in
# phases-sweepBC5.sh's c1 form. One unscored warm-up per arm, then ROUNDS (7) scored rounds. perf stat -x, user only:
# cycles, instructions, mem_inst_retired.all_loads, exe_activity.bound_on_loads, memory_activity.stalls_l1d_miss.
# About 5 minutes; FATAL past 20. Output: /zfs/trig-pup/trial/dload/pslot/rows and summary.txt (dload agent, 2026-11-24).
# Test outside a slot only: SLOT_STUB=1 C1=18 ROUNDS=1 PROJS=Compiler (E-core events: EVPMU=cpu_atom, which lacks
# two of the events, so the test reads cycles and instructions only).
set -u
D=/zfs/trig-pup/trial/dload; O=${OUT:-$D/pslot}; mkdir -p $O; : > $O/rows
T=$D/T-bolt; G=/zfs/trig-pup/tsrs-0.23.0/package/tsrs
TSHA=53037bf875c43738e5e8f1d91a63b579df02b1b62f96fd898ca4edbcbb8186fc; GSHA=4bb990f7f8d63dad9da575baf771b31e9331cf2c0f22932d2e3e1dbba109db00
fatal() { echo "FATAL: $*" | tee -a $O/rows; exit 1; }
[ "$(sha256sum < $T | cut -d' ' -f1)" = $TSHA ] || fatal "$T is not 3c6d8627's PGO+BOLT build (sha256)"
[ "$(sha256sum < $G | cut -d' ' -f1)" = $GSHA ] || fatal "$G is not tsrs 0.23.0 as raced (sha256)"
tv=$($T --version 2>&1) || fatal "$T --version failed"; gv=$($G --version 2>&1) || fatal "$G --version failed"
case "$gv" in *"tsrs 0.23.0-"*) ;; *) fatal "tsrs is not 0.23.0: $gv" ;; esac
st=$(/zfs/trig-pup/bin/pup-slot state)
if [ -z "${SLOT_STUB:-}" ]; then case "$st" in *slot=none*) fatal "no board slot is open (Rig runs this inside its slot): $st" ;; esac; fi
P=${EVPMU:-cpu_core}
if [ $P = cpu_core ]; then EVS="cycles instructions mem_inst_retired.all_loads exe_activity.bound_on_loads memory_activity.stalls_l1d_miss"; else EVS="cycles instructions"; fi
for e in $EVS; do perf list 2>/dev/null | grep -qE "^ +$e( |$)" || [ $e = cycles ] || [ $e = instructions ] || fatal "event $e not in perf list"; done
EV=$(for e in $EVS; do printf "%s/%s/u," $P $e; done | sed 's/,$//')
perf stat -x, -e "$EV" -o $O/stat -- taskset -c ${C1:-3} true || fatal "perf stat refused $EV"
grep -q "not supported\|not counted" $O/stat && fatal "an event is not supported: $(grep -h 'not' $O/stat | head -2)"
C1=${C1:-3}; R=${ROUNDS:-7}; s=$(date +%s)
echo "# slot-pcore start $(date +%T) core=$C1 rounds=$R state: $st; T $tv; G $gv" | tee -a $O/rows
cmd() { case $1 in T|T2) echo "env -u TRIG_PREBUILT_LIBS $T --singleThreaded";; G) echo "env RAYON_NUM_THREADS=1 $G --singleThreaded --checkerAssignment go --noLazyMembers";; esac; }
one() { local p=$1 a=$2 r=$3
  [ $(( $(date +%s) - s )) -gt 1200 ] && fatal "past 20 minutes; stopped"
  perf stat -x, -e "$EV" -o $O/stat -- taskset -c $C1 $(cmd $a) -p $cfg --noEmit --extendedDiagnostics > $O/out 2>&1
  local m=$(grep -vE '^[A-Za-z][A-Za-z ()/._:+-]*: +[0-9]' $O/out | md5sum | cut -c1-8)
  local ck=$(awk '/^Check time:/{print $3}' $O/out | tr -d s)
  [ $r = 0 ] || echo "$a $p ld $r $m check_s=$ck $(awk -F, '!/^#/ && NF>3 {n=$3; sub(/^cpu_(core|atom)\//,"",n); sub(/\/u$/,"",n); printf "%s=%s ", n, $1}' $O/stat)" >> $O/rows; }
for p in ${PROJS:-Compiler typeorm webpack supabase-studio}; do
  case $p in
    webpack) d=/zfs/trig-pup/corpus/webpack/.; cfg=tsconfig.json;;
    typeorm) d=/zfs/trig-pup/corpus/typeorm/packages/typeorm; cfg=tsconfig.json;;
    Compiler) d=/zfs/trig-pup/corpus/typescript-benchmarking/cases/solutions/Compiler/.; cfg=tsconfig.json;;
    supabase-studio) d=/zfs/trig-pup/corpus/supabase-studio/apps/studio; cfg=tsconfig.trig.json;;
    *) fatal "no project $p";;
  esac
  cd -P $d || fatal "no $d"
  for a in T T2 G; do one $p $a 0; done
  [ $p = Compiler ] && echo "# after Compiler's warm-up: $(( $(date +%s) - s )) s" >> $O/rows
  for r in $(seq 1 $R); do for a in $(shuf -e T T2 G); do one $p $a $r; done; done
  echo "# $p done $(date +%T), $(( $(date +%s) - s )) s" | tee -a $O/rows
done
python3 -I - $O/rows > $O/summary.txt <<'PY'
import sys, collections, statistics as S
d = collections.defaultdict(lambda: collections.defaultdict(list)); md5 = collections.defaultdict(set)
for l in open(sys.argv[1]):
    f = l.split()
    if len(f) < 6 or l.startswith('#'): continue
    a, p, _, r, m = f[:5]; md5[p].add(m)
    for kv in f[5:]:
        k, v = kv.split('=', 1)
        try: d[(p, a)][k].append(float(v))
        except ValueError: pass
med = lambda x, k: S.median(x[k]) if x.get(k) else float('nan')
print('medians; ratio to G; A/A = T2/T. excess = (X - G*insX/insG)/G cycles, in %; l1_bound = bound_on_loads - stalls_l1d_miss')
for p in sorted({k[0] for k in d}):
    g = d[(p, 'G')]
    print(f'## {p}  stdout (stats stripped) md5 {sorted(md5[p])}  n={len(g.get("cycles", []))}')
    for x in (d[(p, 'T')], d[(p, 'T2')], g):
        if 'exe_activity.bound_on_loads' in x and 'memory_activity.stalls_l1d_miss' in x:
            x['l1_bound'] = [a - b for a, b in zip(x['exe_activity.bound_on_loads'], x['memory_activity.stalls_l1d_miss'])]
    gi, gc = med(g, 'instructions'), med(g, 'cycles')
    for k in sorted(g):
        t, t2, gv = med(d[(p, 'T')], k), med(d[(p, 'T2')], k), med(g, k)
        line = f'  {k:34s} T {t:12.5g} T2 {t2:12.5g} G {gv:12.5g}  T/G {t/gv:6.3f} T2/G {t2/gv:6.3f} A/A {t2/t:6.3f}'
        if k not in ('cycles', 'instructions', 'check_s'):
            ti, t2i = med(d[(p, 'T')], 'instructions'), med(d[(p, 'T2')], 'instructions')
            line += f'  excess T {100*(t - gv*ti/gi)/gc:+6.2f}% T2 {100*(t2 - gv*t2i/gi)/gc:+6.2f}%'
        if k in ('cycles', 'check_s'):
            sp = lambda x: (max(x[k]) - min(x[k])) / S.median(x[k]) * 100 if x.get(k) else float('nan')
            line += f'  spread T {sp(d[(p, "T")]):.1f}% T2 {sp(d[(p, "T2")]):.1f}% G {sp(g):.1f}%'
        print(line)
PY
cat $O/summary.txt
echo "# slot-pcore done $(date +%T), total $(( $(date +%s) - s )) s" | tee -a $O/rows
