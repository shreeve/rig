#!/bin/bash
d=$1; name=$(echo "$d" | tr '/' '_')
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad
cd "$S/$d" || exit
[ -f main.rig ] || exit
out=$(RIG_OUT_DIR=$S/fix11/runs/$name gtimeout 120 /Users/shreeve/Data/Code/rig/bin/rig run main.rig 2>&1); rc=$?
if [ $rc -eq 0 ]; then kind=OK
elif grep -q "\.zig:[0-9]*:[0-9]*: error\|internal error\|leak\|panic" <<<"$out"; then kind=BAD
elif grep -q "\.rig:[0-9]*:[0-9]*: error" <<<"$out"; then kind=REJECT
else kind=OTHER; fi
n=$(grep -c "\.rig:[0-9]*:[0-9]*: error" <<<"$out")
echo "$kind $d errors=$n"
