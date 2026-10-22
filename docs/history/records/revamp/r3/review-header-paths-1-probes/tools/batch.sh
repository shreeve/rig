#!/bin/bash
# usage: batch.sh DIR OUT [release]
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad
export REL=$3
ls $1/*.rig | xargs -P 4 -n 1 $S/hp1/bin/one.sh
cat $1/*.rig.res > $2
rm -f $1/*.rig.res
