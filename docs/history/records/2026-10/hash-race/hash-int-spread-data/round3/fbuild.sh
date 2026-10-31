#!/bin/bash
# fbuild.sh MUL...: the bench with each multiplier, four layouts, p-MUL-NOPS.bin; checksums against main's
cd "$(dirname "$0")"
for m in "$@"; do for l in 0 5 13 29; do [ -x p-$m-$l.bin ] || PKG=pkg PFX=p ./mkm2.sh $m $l >/dev/null 2>&1 || echo FAIL $m $l; done; done
./p-0x4b33a62ed433d4a3-0.bin | awk '{print $1,$2,$4}' > chk-main.txt
for m in "$@"; do ./p-$m-0.bin | awk '{print $1,$2,$4}' | cmp -s - chk-main.txt && echo "$m checksums same" || echo "$m CHECKSUMS DIFFER"; done
