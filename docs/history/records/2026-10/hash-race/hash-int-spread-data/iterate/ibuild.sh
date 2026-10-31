#!/bin/bash
# ibuild.sh MUL...: the probe with main's walk (M) and the windowed walk (W), each multiplier: p-0x{M,W}<mul>-0.bin
cd "$(dirname "$0")"
for m in "$@"; do for a in M W; do n=0x$a${m#0x}; [ -x p-$n-0.bin ] && continue
  PKG=pkg$a PFX=t ./mkm2.sh $m 0 >/dev/null 2>&1 && mv t-$m-0.bin p-$n-0.bin || echo FAIL $a $m; done; done
