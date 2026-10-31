# The variants timed, sourced by time.sh: Trig 2ba0719's PGO build by Rig main
# af6e0e6bf; standing-3's PGO build of the same Trig by 1b2f4b59d, timed again
# the same day; and tsrs shipped, Go mode, one thread, one checker.
W=/zfs/worktrees/rig/tsrs-standing-4
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
V="af6-pgo 1b2-pgo tsrs"
cmd_of() {
  t="-p tsconfig.trig.json --noEmit --singleThreaded"
  s="-p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers"
  case $1 in
    af6-pgo) echo "$W/packs/af6e0e6bf-pgo/bin $t" ;;
    1b2-pgo) echo "$W/packs/1b2f4b59d-pgo/bin $t" ;;
    tsrs) echo "env RAYON_NUM_THREADS=1 $TSRS $s" ;;
  esac
}
