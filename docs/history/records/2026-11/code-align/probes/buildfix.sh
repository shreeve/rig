#!/bin/bash
# buildfix.sh S K...: placement K with align(64) on qsort alone (S/fix/sK),
# the shift a layout check would make when qsort's loop crosses 4 KiB.
set -euo pipefail
S=$1; shift; here=$(cd "$(dirname "$0")" && pwd)
for k in "$@"; do
  "$here/alignpkg.sh" "$S/w/o$k" "$S/fix/o$k" 64 qsort
  "$here/relink.sh" "$S/fix/o$k" "$S/fix/s$k"
done
