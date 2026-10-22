#!/bin/bash
# rig check every behavior test and example (entry files only); report rejections.
cd /Users/shreeve/Data/Code/rig-rv-tc
{ find test/behavior -mindepth 2 -maxdepth 2 -name '*.rig'; find test/behavior -mindepth 3 -name main.rig; find examples -name '*.rig'; } | sort | while read -r f; do
  out=$(${RIG:-bin/rig} check "$f" 2>&1) || echo "REJECT $f: $(echo "$out" | head -1)"
done
