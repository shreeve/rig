#!/bin/bash
# hitgen.sh S N K J: placement K plus J short never-taken prints, built
# with RIG_PROBE_ALIGN=N by the probe rig, into S/hit/aN-kK-jJ; prints
# qsort's offset within 4 KiB. (To find a placement whose partition loop
# crosses 4 KiB under function alignment N.)
set -euo pipefail
S=$1; N=$2; K=$3; J=$4; here=$(cd "$(dirname "$0")" && pwd)
n=a$N-k$K-j$J; f=$S/hit/$n.rig
python3 "$here/gen.py" "$K" "$f"
for j in $(seq 1 "$J"); do echo "  print(\"q\") if t2.elapsed() == $((2000 + j))" >> "$f"; done
RIG_PROBE_ALIGN=$N RIG_OUT_DIR=$S/hit/o-$n "$S/rigsrc/bin/rig" build --release "$f" -o "$S/hit/$n" >/dev/null
a=$(nm "$S/hit/$n" | awk '/ ___rig_main.qsort$/{print $1}')
printf "%s qsort mod 4096 %x\n" "$n" $((0x$a % 4096))
