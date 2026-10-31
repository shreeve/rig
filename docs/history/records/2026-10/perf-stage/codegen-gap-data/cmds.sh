# The variants timed by time-rot.sh: Trig 2ba0719's PGO builds by Rig main
# 179c50afa (main; nochk: every check's panic unreachable, built -Ofast;
# hand: the safe hand edits; hashmap: Trig's lookup-only caches as
# HashMap), and tsrs shipped, Go mode, one thread, one checker.
W=/zfs/worktrees/rig/codegen-gap
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
V=${V:-"main nochk hand hashmap tsrs"}
cmd_of() {
  t="-p tsconfig.trig.json --noEmit --singleThreaded"
  s="-p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers"
  case $1 in
    tsrs) echo "env RAYON_NUM_THREADS=1 $TSRS $s" ;;
    *) echo "$W/v/$1/bin $t" ;;
  esac
}
