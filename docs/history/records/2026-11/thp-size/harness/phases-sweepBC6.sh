#!/bin/bash
# phases-sweepBC4.sh N (v4, 2026-11-12: ARMS overrides the per-project arm list; adds M2/M8, B2/B8, G2/G8 for c2 and c8 on the same cores 0-11).
# BC5 (Rig, 2026-11-23): copy of BC4 that adds R2/R8, so a fourth Trig arm (RELOCBIN) runs at every count.
# BC6 (Rig, 2026-11-23): BC5 plus X (BOLTBIN with RIG_HUGE_MIN_MB=8) and Y (=32) at every count, for the huge-page threshold race.
# BC5 also: TSRSCLEAN (optional) adds H1/H2/H4/H8, the race-free tsrs (no xstate/webpack training), same flags as G.
# phases-sweepBC.sh N: phase breakdown (config/parse/bind/check) at c1 and c4 of sweep groups B and C (16 projects), Trig MAINBIN (M, required)
# against tsrs exact (G); peak RSS, major and minor faults (lead request, 2026-11-11: which phase owns the c4 gap). PROJS overrides the list.
# (Adapted from phases-sweep.sh.) v2 2026-11-11: adds voluntary/involuntary context switches (vcsw, ivcsw) and mui-docs as a 17th project
# v3: BOLTBIN (optional) adds B1/B4, a PGO+BOLT arm of the same commit; RELOCBIN adds R1/R4, its non-bolted twin (PGO relinked with relocations).
# (reported apart from the 16-project sums, so they compare with 1beae10 line for line).
# T1/T4 run the head-to-head binary (m4611476h, TRIG_PREBUILT_LIBS=0); P1/P4 the prebuilt binary (m4611476p, libs prebuilt);
# M1/M4 current main (MAINBIN, default /zfs/rig-main/e33d51ef8/trig-pgo, PGO on the prebuilt recipe) with its default libs.
# Per run: wall, user, sys, peak RSS, major faults (/usr/bin/time) and Parse/Bind/Check/Total from --extendedDiagnostics. Arms of a case interleaved, shuffled each round.
# Fresh tmpfs copies of nfz and tsrs's package, as race-8 makes them; cleared on exit. Run only in a slot with every build paused.
set -u
N=${1:-20}; T=/zfs/trig-pup/trial/t3; O=${OUT:-$T/races-0321665/phases-sweepBC-r1}; mkdir -p $O; : > $O/runs
TSRS0=/zfs/trig-pup/tsrs-0.23.0/package/tsrs; P=/zfs/trig-pup/full/trig/misc/projects
TP=${TP:-/tmp/tp}; trap "rm -rf $TP" EXIT; rm -rf $TP; mkdir -p $TP
cp -r $(dirname $TSRS0) $TP/tsrs-pkg; if [ -n "${TSRSCLEAN:-}" ]; then cp -r $(dirname $TSRSCLEAN) $TP/tsrs-clean; fi
MB=${MAINBIN:?set MAINBIN}; MA=; if [ -x $MB ]; then cp $MB $TP/trigm; MA="M1 M4"; fi; BA=; if [ -n "${BOLTBIN:-}" ]; then cp $BOLTBIN $TP/trigb; BA="B1 B4"; fi; if [ -n "${RELOCBIN:-}" ]; then cp $RELOCBIN $TP/trigr; BA="$BA R1 R4"; fi  # current main (Rig), if it has landed
TR=$TP/trig; TRP=$TP/trigp; TRM=$TP/trigm; TRB=$TP/trigb; TRR=$TP/trigr; TS=$TP/tsrs-pkg/tsrs; TH=$TP/tsrs-clean/tsrs
taskset -cp 13 $$ > /dev/null
echo "# start $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg) main=$([ -n "$MA" ] && sha256sum $TRM | cut -c1-12 || echo none) bolt=$([ -n "$BA" ] && sha256sum $TRB | cut -c1-12 || echo none) $($TS --version 2>&1 | head -1)" | tee -a $O/runs
c1="taskset -c ${C1:-3}"; cN="taskset -c ${CN:-0-11}"  # C1, CN: test outside a slot on an E-core
arm() { case $1 in  # arm -> command (after the cores), env first
  T1) echo "$c1 env TRIG_PREBUILT_LIBS=0 $TR --singleThreaded" ;;
  P1) echo "$c1 env -u TRIG_PREBUILT_LIBS $TRP --singleThreaded" ;;
  M1) echo "$c1 env -u TRIG_PREBUILT_LIBS $TRM --singleThreaded" ;;
  M4) echo "$cN env -u TRIG_PREBUILT_LIBS $TRM --checkers 4" ;;
  B1) echo "$c1 env -u TRIG_PREBUILT_LIBS $TRB --singleThreaded" ;;
  B4) echo "$cN env -u TRIG_PREBUILT_LIBS $TRB --checkers 4" ;;
  M2) echo "$cN env -u TRIG_PREBUILT_LIBS $TRM --checkers 2" ;;
  M8) echo "$cN env -u TRIG_PREBUILT_LIBS $TRM --checkers 8" ;;
  B2) echo "$cN env -u TRIG_PREBUILT_LIBS $TRB --checkers 2" ;;
  B8) echo "$cN env -u TRIG_PREBUILT_LIBS $TRB --checkers 8" ;;
  X1) echo "$c1 env -u TRIG_PREBUILT_LIBS RIG_HUGE_MIN_MB=8 $TRB --singleThreaded" ;;
  X2) echo "$cN env -u TRIG_PREBUILT_LIBS RIG_HUGE_MIN_MB=8 $TRB --checkers 2" ;;
  X4) echo "$cN env -u TRIG_PREBUILT_LIBS RIG_HUGE_MIN_MB=8 $TRB --checkers 4" ;;
  X8) echo "$cN env -u TRIG_PREBUILT_LIBS RIG_HUGE_MIN_MB=8 $TRB --checkers 8" ;;
  Y1) echo "$c1 env -u TRIG_PREBUILT_LIBS RIG_HUGE_MIN_MB=32 $TRB --singleThreaded" ;;
  Y2) echo "$cN env -u TRIG_PREBUILT_LIBS RIG_HUGE_MIN_MB=32 $TRB --checkers 2" ;;
  Y4) echo "$cN env -u TRIG_PREBUILT_LIBS RIG_HUGE_MIN_MB=32 $TRB --checkers 4" ;;
  Y8) echo "$cN env -u TRIG_PREBUILT_LIBS RIG_HUGE_MIN_MB=32 $TRB --checkers 8" ;;
  G2) echo "$cN env $TS --checkers 2 --checkerAssignment go --noLazyMembers" ;;
  G8) echo "$cN env $TS --checkers 8 --checkerAssignment go --noLazyMembers" ;;
  R1) echo "$c1 env -u TRIG_PREBUILT_LIBS $TRR --singleThreaded" ;;
  R4) echo "$cN env -u TRIG_PREBUILT_LIBS $TRR --checkers 4" ;;
  R2) echo "$cN env -u TRIG_PREBUILT_LIBS $TRR --checkers 2" ;;
  R8) echo "$cN env -u TRIG_PREBUILT_LIBS $TRR --checkers 8" ;;
  P4) echo "$cN env -u TRIG_PREBUILT_LIBS $TRP --checkers 4" ;;
  G1) echo "$c1 env RAYON_NUM_THREADS=1 $TS --singleThreaded --checkerAssignment go --noLazyMembers" ;;
  H1) echo "$c1 env RAYON_NUM_THREADS=1 $TH --singleThreaded --checkerAssignment go --noLazyMembers" ;;
  H2) echo "$cN env $TH --checkers 2 --checkerAssignment go --noLazyMembers" ;;
  H4) echo "$cN env $TH --checkers 4 --checkerAssignment go --noLazyMembers" ;;
  H8) echo "$cN env $TH --checkers 8 --checkerAssignment go --noLazyMembers" ;;
  L1) echo "$c1 env RAYON_NUM_THREADS=1 $TS --singleThreaded --checkerAssignment go" ;;
  T4) echo "$cN env TRIG_PREBUILT_LIBS=0 $TR --checkers 4" ;;
  G4) echo "$cN env $TS --checkers 4 --checkerAssignment go --noLazyMembers" ;;
  F4) echo "$cN env $TS --fast --checkers 4" ;;
  TD) echo "$cN env TRIG_PREBUILT_LIBS=0 TRIG_CHECKERS=dynamic $TR" ;;
  FD) echo "$cN env $TS --fast" ;;
esac; }
ph() { awk '/^Config time:/{k=$3} /^Parse time:/{p=$3} /^Bind time:/{b=$3} /^Check time:/{c=$3} /^Total time:/{t=$3} /file graph \(parse/{g=$NF} END{printf "config=%s parse=%s bind=%s check=%s total=%s graph=%s", k, p, b, c, t, g}' $1 | sed 's/\([0-9]\)s/\1/g'; }
one() { local proj=$1 a=$2 r=$3; set -- $(arm $a); local pre="$1 $2 $3"; shift 3; local envs=(); while [ "$1" != "$TR" ] && [ "$1" != "$TRP" ] && [ "$1" != "$TRM" ] && [ "$1" != "$TRB" ] && [ "$1" != "$TRR" ] && [ "$1" != "$TS" ] && [ "$1" != "$TH" ]; do envs+=("$1"); shift; done
  local t0=$EPOCHREALTIME; env "${envs[@]}" /usr/bin/time -f "%e %U %S %M %F %R %w %c" -o $O/time $pre "$@" -p $cfg --noEmit --extendedDiagnostics > $O/out 2>&1; local t1=$EPOCHREALTIME
  read w u s m f r2 vcs ivcs < <(tail -n1 $O/time); echo "$proj arm=$a round=$r wall_ms=$(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.2f", (b-a)*1000}') user=$u sys=$s rss_kb=$m majflt=$f minflt=$r2 vcsw=$vcs ivcsw=$ivcs $(ph $O/out)" >> $O/runs; case $proj in supabase-studio|cal-diy|mui-docs|webpack) cp $O/out $O/full.$proj.$a.$r ;; esac; }  # the full --extendedDiagnostics block, for the serial gaps
C=/zfs/trig-pup/corpus
SWEEP_JSON=$T/m4611476p/tools/bench/sweep-projects.json
where() { python3 -I -c 'import json,os,sys; C=sys.argv[2]; p=[x for x in json.load(open(sys.argv[3]))["projects"] if x["name"]==sys.argv[1]][0]; r=os.path.join(C,"typescript-benchmarking",p["suite_dir"]) if "suite_dir" in p else os.path.join(C,p["name"]); f=os.path.join(r,p.get("project") or "."); print(f, "tsconfig.json") if os.path.isdir(f) else print(os.path.dirname(f), os.path.basename(f))' "$1" "$C" "$SWEEP_JSON"; }
case_() { local proj=$1; shift; if [ $proj = mui-docs ]; then d=$T/projects/mui-docs; cfg=tsconfig.trig.json; else read d cfg < <(where $proj); fi; cd -P $d || { echo "FATAL: no $d" >&2; exit 1; }; [ -f tsconfig.trig.json ] && cfg=tsconfig.trig.json; echo "# $proj: $d $cfg" >> $O/runs
  for a in "$@"; do one $proj $a 0; done  # one unscored warm-up run per arm
  for r in $(seq 1 ${NR:-$N}); do for a in $(shuf -e "$@"); do one $proj $a $r; done; done; echo "# $proj done $(date +%T)" | tee -a $O/runs; }
[ -n "$MA" ] || { echo "FATAL: no main binary $MB" >&2; exit 1; }
for p in ${PROJS:-supabase-studio mikro-orm formbricks-web cal-diy xstate-main webpack Compiler Compiler-Unions next-packages-next next-root storybook nuxt playwright drizzle-orm typeorm date-fns mui-docs}; do case_ $p ${ARMS:-M1 G1 M4 G4 $BA}; done
echo "# done $(date +%T) state: $(/zfs/trig-pup/bin/pup-slot state)" | tee -a $O/runs
