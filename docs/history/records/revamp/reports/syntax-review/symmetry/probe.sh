#!/bin/bash
# usage: probe.sh name <<< program ; runs check then run
f="$1.rig"; cat > "$f"
out=$(/Users/shreeve/Data/Code/rig/bin/rig run "$f" 2>&1 | head -${2:-4})
echo "== $1: $out"
