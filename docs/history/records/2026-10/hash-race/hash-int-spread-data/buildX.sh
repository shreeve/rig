#!/bin/bash
# buildR.sh: the byte-scan rehash (${PKG:-pkgB}) with main's multiplier and two finalists, four layouts, as p-0x${TAG:-RR}....
cd "$(dirname "$0")"
for pair in 0x4b33a62ed433d4a3:0x${TAG:-RR}4b33 0xfb59148934afb5bd:0x${TAG:-RR}fb59 0xa1b9b543bccba13c:0x${TAG:-RR}a1b9; do m=${pair%%:*}; n=${pair#*:}
  for l in 0 5 13 29; do [ -x p-$n-$l.bin ] && continue; PKG=${PKG:-pkgB} PFX=q ./mkm2.sh $m $l >/dev/null 2>&1 && mv q-$m-$l.bin p-$n-$l.bin || echo FAIL $m $l; done; done
ls p-0x${TAG:-RR}* | wc -l
