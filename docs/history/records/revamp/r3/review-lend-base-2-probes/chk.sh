#!/bin/bash
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad
D=$1
for f in $D/*.rig; do
  n=$(basename $f .rig)
  $S/r2head/bin/rig check $f >/dev/null 2>$D/$n.h.err; hr=$?
  $S/r2base/bin/rig check $f >/dev/null 2>$D/$n.b.err; br=$?
  echo "$n $hr $br"
done > $D/../$(basename $D).chk
