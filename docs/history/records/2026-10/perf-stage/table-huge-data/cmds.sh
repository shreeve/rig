# The arms timed, sourced by time.sh: Trig 2ba0719's PGO build by Rig main
# and by the jit arm (build.sh).
W=/zfs/worktrees/rig/table-huge
V=${V:-"main jit"}
REF=main
bin_of() { echo "$W/packs/$1/bin"; }
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
