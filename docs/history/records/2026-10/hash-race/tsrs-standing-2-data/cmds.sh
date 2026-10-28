# The variants timed, sourced by time.sh: Trig 403a823's PGO build by three
# Rigs, and tsrs shipped and from source, Go mode, one thread, one checker.
W=/zfs/worktrees/rig/tsrs-standing-2
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
TSRC=/zfs/trig-pup/tsrs/bin/tsrs
V="773-pgo 2c0-pgo 364-pgo tsrs tsrs-src"
cmd_of() {
  t="-p tsconfig.trig.json --noEmit --singleThreaded"
  s="-p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers"
  case $1 in
    773-pgo) echo "$W/packs/773978d1d-pgo/bin $t" ;;
    2c0-pgo) echo "$W/packs/2c01f07dd-pgo/bin $t" ;;
    364-pgo) echo "$W/packs/36422da59-pgo/bin $t" ;;
    tsrs) echo "env RAYON_NUM_THREADS=1 $TSRS $s" ;;
    tsrs-src) echo "env RAYON_NUM_THREADS=1 $TSRC $s" ;;
  esac
}
