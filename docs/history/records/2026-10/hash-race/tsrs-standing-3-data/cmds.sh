# The variants timed, sourced by time.sh: Trig 2ba0719's PGO build by Rig main
# 1b2f4b59d and by standing-2's main 773978d1d; standing-2's own build (Trig
# 403a823 by 773978d1d, the same binary); and tsrs shipped and from source,
# Go mode, one thread, one checker.
W=/zfs/worktrees/rig/tsrs-standing-3
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
TSRC=/zfs/trig-pup/tsrs/bin/tsrs
V="1b2-pgo 773-pgo 773-403-pgo tsrs tsrs-src"
cmd_of() {
  t="-p tsconfig.trig.json --noEmit --singleThreaded"
  s="-p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers"
  case $1 in
    1b2-pgo) echo "$W/packs/1b2f4b59d-pgo/bin $t" ;;
    773-pgo) echo "$W/packs/773978d1d-pgo/bin $t" ;;
    773-403-pgo) echo "$W/packs/773978d1d-403-pgo/bin $t" ;;
    tsrs) echo "env RAYON_NUM_THREADS=1 $TSRS $s" ;;
    tsrs-src) echo "env RAYON_NUM_THREADS=1 $TSRC $s" ;;
  esac
}
