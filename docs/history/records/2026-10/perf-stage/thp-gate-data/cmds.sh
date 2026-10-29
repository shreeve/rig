# The builds timed, sourced by time.sh: Trig 403a823's PGO build by each Rig.
W=/zfs/worktrees/rig/thp-frag
T2=/zfs/worktrees/rig/tsrs-standing-2
V=${V:-"a b c d"}
bin_of() {
  case $1 in
    a) echo "$T2/packs/773978d1d-pgo/bin" ;;   # main 773978d1d
    b) echo "$T2/packs/2c01f07dd-pgo/bin" ;;   # the #760 revert (2c01f07dd's src/)
    c) echo "$W/packs/c-pgo/bin" ;;            # (b) with no segment advice
    d) echo "$W/packs/d-pgo/bin" ;;            # (b) with no MADV_HUGEPAGE
    e) echo "$W/packs/e-pgo/bin" ;;            # (a) gated on free 2 MiB blocks, 16 spare
    g) echo "$W/packs/g-pgo/bin" ;;            # the thp-gate branch, 5b103b53f
    e2) echo "$W/packs/e2-pgo/bin" ;;          # (a) gated on free 2 MiB blocks, 128 spare
  esac
}
