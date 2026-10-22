#!/bin/bash
# split.sh FILE OUTDIR : split "=== name" sections into OUTDIR/name.rig
awk -v d="$2" '/^=== /{f=d"/"$2".rig"; next} {print > f}' "$1"
