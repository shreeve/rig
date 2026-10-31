#!/bin/sh
# pgo-one.sh ARM [SLOTS]: one Trig 2ba0719 PGO build (--release --pgo, trained by
# tools/trig/bolt-train) by Rig main's code (179c50afa = 36be46744 in src/std),
# ARM main (built-in std), meta (std-meta), or instr (instrumented rig + std-instr,
# plain --release), through slot.sh. Run only when Swiss's lane allows it.
set -u
W=/zfs/worktrees/rig/trig-fileio
export TRIG_RELEASE_SLOTS=${2:-'12,13 14,15 16,17'}
arm=$1 out=$W/packs/$1
rig=$W/bins/rig-main; std=
case $arm in
  main) ;;
  meta) std=$W/std-meta ;;
  instr) rig=$W/bins/rig-instr; std=$W/std-instr ;;
  *) echo "arm?"; exit 2 ;;
esac
rm -rf "$out" && mkdir -p "$out/src"
for s in $W/trig/src/*/; do ln -s "$s" "$out/src/$(basename "$s")"; done
cp $W/trig/tools/trig/main.rig "$out/src/main.rig"
cd "$out/src"
if [ -n "$std" ]; then export RIG_STD=$std; else unset RIG_STD; fi
start=$(date +%s)
if [ $arm = instr ]; then
  RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 taskset -c 12-19 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release -o "$out/bin" "$out/src/main.rig" > "$out/build.log" 2>&1
else
  RIG_OUT_DIR="$out/out" RIG_NO_CRASH_REPORT=1 taskset -c 12-19 sh /zfs/trig-pup/trial/slot.sh "$rig" build --release --pgo --pgo-profile="$out/trig.profdata" -o "$out/bin" "$out/src/main.rig" -- $W/trig/tools/trig/bolt-train "$out/bin" > "$out/build.log" 2>&1
fi
st=$?
rm -rf "$out/out"
echo "$(date +%T) $arm exit $st in $(( $(date +%s) - start )) s: $(sha256sum $out/bin 2>/dev/null | cut -c1-16)"
