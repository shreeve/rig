#!/bin/bash
D=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/review-text4
for f in "$@"; do echo "=== $f"; echo "-- new"; /Users/shreeve/Data/Code/rig-text/bin/rig run "$f" 2>&1 | grep -v '^  \|^ *\^' | head -${N:-12}; echo "-- old"; $D/base/bin/rig run "$f" 2>&1 | grep -v '^  \|^ *\^' | head -${N:-12}; done
