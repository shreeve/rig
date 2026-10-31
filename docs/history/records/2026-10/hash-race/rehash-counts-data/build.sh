#!/bin/bash
# build.sh: main 344257fc0 (pkgM) and the PR (pkgP), main's multiplier, four layouts: p-0xMAIN00-N.bin, p-0xPR0000-N.bin
cd "$(dirname "$0")"
for spec in pkgM:0xMAIN00 pkgP:0xPR0000; do IFS=: read pkg n <<< "$spec"
  for l in 0 5 13 29; do [ -x p-$n-$l.bin ] && continue; PKG=$pkg PFX=y ./mkm2.sh 0x4b33a62ed433d4a3 $l >/dev/null 2>&1 && mv y-0x4b33a62ed433d4a3-$l.bin p-$n-$l.bin || echo FAIL $spec $l; done; done
./p-0xMAIN00-0.bin | awk '{print $1,$2,$4}' > chk-M.txt; ./p-0xPR0000-0.bin | awk '{print $1,$2,$4}' > chk-P.txt; cmp chk-M.txt chk-P.txt && echo CHECKSUMS-SAME
