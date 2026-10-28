# The variants timed, sourced by time.sh, huge.sh, and prof.sh.
W=/zfs/worktrees/rig/tsrs-standing
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
TSRC=/zfs/trig-pup/tsrs/bin/tsrs
V="main-pgo main-rel f7ed-rel a38f-rel tsrs tsrs-src"
cmd_of() {
  case $1 in
    main-pgo) echo "$W/packs/36422da59-pgo/bin -p tsconfig.trig.json --noEmit --singleThreaded" ;;
    main-rel) echo "$W/packs/36422da59-rel/bin -p tsconfig.trig.json --noEmit --singleThreaded" ;;
    f7ed-rel) echo "$W/packs/f7edd5cb5-rel/bin -p tsconfig.trig.json --noEmit --singleThreaded" ;;
    a38f-rel) echo "$W/packs/a38ff34b7-rel/bin -p tsconfig.trig.json --noEmit --singleThreaded" ;;
    tsrs) echo "env RAYON_NUM_THREADS=1 $TSRS -p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers" ;;
    tsrs-src) echo "env RAYON_NUM_THREADS=1 $TSRC -p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers" ;;
  esac
}
