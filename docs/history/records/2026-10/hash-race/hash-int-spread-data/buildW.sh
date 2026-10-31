#!/bin/bash
# buildW.sh: the register-word rehash (pkgW) with main's multiplier, four layouts, as p-0xWW4b33-NOPS.bin
cd "$(dirname "$0")"
for l in 0 5 13 29; do [ -x p-0xWW4b33-$l.bin ] && continue; PKG=pkgW PFX=w ./mkm2.sh 0x4b33a62ed433d4a3 $l >/dev/null 2>&1 && mv w-0x4b33a62ed433d4a3-$l.bin p-0xWW4b33-$l.bin || echo FAIL $l; done
./p-0xWW4b33-0.bin | awk '{print $1,$2,$4}' > chk-0xWW4b33.txt; cmp chk-0xMM4b33.txt chk-0xWW4b33.txt && echo CHECKSUMS-SAME
