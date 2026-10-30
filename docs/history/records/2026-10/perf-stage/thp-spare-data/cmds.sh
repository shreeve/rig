# The arms timed, sourced by time.sh: Trig 2ba0719's PGO build by Rig main
# 277fba515 with each huge-page gate (build.sh).
W=/zfs/worktrees/rig/thp-spare
V=${V:-"s128 s64 s32 s16 always never"}
REF=s128
bin_of() { echo "$W/packs/$1-pgo/bin"; }
