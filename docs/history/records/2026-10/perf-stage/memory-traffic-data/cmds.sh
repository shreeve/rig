# Sourced: the programs measured, and where.
W=/zfs/worktrees/rig/memory-traffic
P=/zfs/trig-pup/full/trig/misc/projects
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
cmd_of() {
  case $1 in
    rel|fp|trace) echo "$W/packs/$1/bin -p tsconfig.trig.json --noEmit --singleThreaded" ;;
    tsrs) echo "env RAYON_NUM_THREADS=1 $TSRS -p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers" ;;
    tsrs-src) echo "env RAYON_NUM_THREADS=1 /zfs/trig-pup/tsrs/bin/tsrs -p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers" ;;
  esac
}
# Wait while anyone times on core 8.
quiet8() { while pgrep -af 'taskset -c 8' | grep -v pgrep > /dev/null; do sleep 5; done; }
