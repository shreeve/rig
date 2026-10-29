# The variants, sourced by the scripts: Trig 403a823's PGO build by Rig
# main 773978d1d (#754) and by 2c01f07dd (main before #754), the binaries
# tsrs-standing-2 timed, and shipped tsrs 0.18.0 in Go order and in its
# default mode. cmd_of VARIANT N prints the command for N checkers.
S=/zfs/worktrees/rig/tsrs-standing-2
W=/zfs/worktrees/rig/scaling-2
P=$S/trig/misc/projects
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
cmd_of() {
  case $1 in
    t773|t2c0)
      b=$S/packs/773978d1d-pgo/bin; [ $1 = t2c0 ] && b=$S/packs/2c01f07dd-pgo/bin
      if [ $2 = 1 ]; then echo "$b -p tsconfig.trig.json --noEmit --singleThreaded"
      else echo "$b -p tsconfig.trig.json --noEmit --checkers $2"; fi ;;
    tsgo)
      if [ $2 = 1 ]; then echo "env RAYON_NUM_THREADS=1 $TSRS -p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers"
      else echo "$TSRS -p tsconfig.trig.json --noEmit --checkers $2 --checkerAssignment go --noLazyMembers"; fi ;;
    tsdef) echo "$TSRS -p tsconfig.trig.json --noEmit --checkers $2" ;;
  esac
}
# The E-cores a run of N checkers is pinned to.
cores_of() {
  case $1 in 1) echo 12 ;; 2) echo 12,13 ;; 4) echo 12-15 ;; 8) echo 12-19 ;; esac
}
