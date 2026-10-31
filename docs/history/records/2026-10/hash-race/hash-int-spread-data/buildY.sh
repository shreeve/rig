#!/bin/bash
# buildY.sh: main (pkgM), the rehash fix (pkgA), and the fix with fb59, four layouts each:
# p-0xMM4b33, p-0xAA4b33, p-0xAAfb59 -NOPS.bin
cd "$(dirname "$0")"
for spec in pkgM:0x4b33a62ed433d4a3:0xMM4b33 pkgA:0x4b33a62ed433d4a3:0xAA4b33 pkgA:0xfb59148934afb5bd:0xAAfb59; do
  IFS=: read pkg m n <<< "$spec"
  for l in 0 5 13 29; do [ -x p-$n-$l.bin ] && continue; PKG=$pkg PFX=y ./mkm2.sh $m $l >/dev/null 2>&1 && mv y-$m-$l.bin p-$n-$l.bin || echo FAIL $spec $l; done
done
ls p-0xMM* p-0xAA* | wc -l
