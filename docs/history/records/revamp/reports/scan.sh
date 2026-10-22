#!/bin/bash
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad
for d in review-text review-text2 review-text3 review-text4; do
  cd $S/$d
  for f in *.rig; do
    perl -e 'alarm 30; exec @ARGV' /Users/shreeve/Data/Code/rig-text/bin/rig run $f 2>$S/scan_err.txt | head -c 20000 > $S/scan_out.txt
    rc=${PIPESTATUS[0]}
    head -c 20000 $S/scan_err.txt > $S/scan_e.txt
    if grep -a -q "__rig_main.zig:\|leak detected\|internal error\|unsupported\|Segmentation\|double free\|incorrect alignment" $S/scan_e.txt; then echo "=== $d/$f"; grep -a -m2 "__rig_main.zig:\|leak\|internal\|unsupported\|Segm\|double\|alignment" $S/scan_e.txt; fi
    if grep -a -q "panic" $S/scan_e.txt; then echo "--- $d/$f panic: $(grep -a -m1 panic $S/scan_e.txt)"; fi
    if LC_ALL=C grep -a -q '[^[:print:][:space:]]' $S/scan_out.txt; then echo "=== $d/$f garbage"; fi
  done
done
echo scan-done
