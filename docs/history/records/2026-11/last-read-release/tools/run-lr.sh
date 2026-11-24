#!/bin/bash
# ~/cpuq/tmp/lastread/run-lr.sh BIN OUTDIR TAG PROJECT MODE: one run of BIN on a corpus project as the race runs it
# (-p CONFIG --noEmit; c1 = --singleThreaded on one core and its sibling, c4 = --checkers 4 on 6 cores and their
# siblings, as pup's 6 P-cores), stdout to OUTDIR/TAG-PROJECT-MODE.out, stderr (the census) to .err, peak RSS (KiB,
# /usr/bin/time) to .time. CPUS overrides the CPU list.
set -u
. ~/cpuq/tmp/setup1123/env.sh
BIN=$1 OUT=$2 TAG=$3 P=$4 M=$5
mkdir -p "$OUT"
read -r D CFG < <(cd "$TRIG_MAIN" && TRIG_PROJECTS_ROOT=$TRIG_MAIN/misc python3 -c "
import sys; sys.path.insert(0, 'tools/check'); import checklib as L
p = L.projects()['$P']; print(p.dir, p.config)")
case $M in
  c1) args=--singleThreaded; cpus=${CPUS:-42,90} ;;
  c4) args="--checkers 4"; cpus=${CPUS:-36-41,84-89} ;;
  c8) args="--checkers 8"; cpus=${CPUS:-36-41,84-89} ;;
  *) echo "mode c1, c4 or c8" >&2; exit 2 ;;
esac
cd "$D"
f=$OUT/$TAG-$P-$M
/usr/bin/time -f "%M %e" -o "$f.time" taskset -c "$cpus" "$BIN" -p "$CFG" --noEmit $args > "$f.out" 2> "$f.err"
echo "$TAG $P $M status=$? rss_kb_wall=$(cat "$f.time") out=$(md5sum < "$f.out" | cut -c1-8)"
