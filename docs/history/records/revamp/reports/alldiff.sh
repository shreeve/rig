#!/bin/bash
# Diff `rig check` output of baseline vs new over every reject/known/torture test.
D=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad
R=/Users/shreeve/Data/Code/rig-place
cd $R
find test/reject test/torture test/known -name '*.rig' ! -path '*/*/*/*/*' | sort > $D/files.txt
find test/reject -name main.rig -path '*/*/*/*/*' >> $D/files.txt
while read f; do
  a=$($D/base/bin/rig check "$f" 2>&1 | grep -E "(error|note):"); b=$($R/bin/rig check "$f" 2>&1 | grep -E "(error|note):")
  if [ "$a" != "$b" ]; then echo "=== $f"; diff <(echo "$a") <(echo "$b"); fi
done < $D/files.txt
