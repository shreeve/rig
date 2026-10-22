#!/bin/bash
# usage: p.sh name 'source' [cmd] [lines]
R=/Users/shreeve/Data/Code/rig/bin/rig
printf "%b" "$2" > "$1.rig"
echo "== $1 (${3:-check})"
$R ${3:-check} "$1.rig" 2>&1 | head -${4:-8}
echo "[exit ${PIPESTATUS[0]}]"
