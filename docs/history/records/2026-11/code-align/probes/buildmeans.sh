#!/bin/bash
# buildmeans.sh S K...: for each placement K (its package in S/w/oK), the
# bitcode route with no option (S/bc/sK, an A/A of the route), with LLVM's
# -align-loops=64 (S/al64/sK) and =32 (S/al32/sK), and qsort's loop padded
# by hand to 64 bytes (S/lp/sK).
set -euo pipefail
S=$1; shift; here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$S/bc" "$S/al64" "$S/al32" "$S/lp"
for k in "$@"; do
  for v in bc al64 al32; do
    rm -rf "$S/$v/o$k"; mkdir -p "$S/$v/o$k"
    (cd "$S/w/o$k" && find . -name '*.zig' -not -path './.zig-cache/*' | cpio -pdm --quiet "$S/$v/o$k")
  done
  "$here/bcbuild.sh" "$S/bc/o$k" "$S/bc/s$k"
  "$here/bcbuild.sh" "$S/al64/o$k" "$S/al64/s$k" -falign-loops=64
  "$here/bcbuild.sh" "$S/al32/o$k" "$S/al32/s$k" -falign-loops=32
  "$here/looppad.sh" "$S/w/o$k" "$S/lp/o$k" 6
  "$here/relink.sh" "$S/lp/o$k" "$S/lp/s$k"
done
