#!/usr/bin/env bash
# usage: probe.sh label <<< program ; prints diagnostics
SB=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/sb
cat > $SB/r_$1.rig
echo "--- $1"
/Users/shreeve/Data/Code/rig/bin/rig check $SB/r_$1.rig 2>&1 | grep -E "error|note" | sed "s|$SB/||"
