#!/bin/bash
# On pup, under `cpuq lease pup-bench --exclusive`: ws_stage built by
# main (ws_main) and by widemasks (ws_new), the Zig reference with the
# study's best x86 mask (bitcast held by an empty asm) and the plain
# bitcast, then cls_stage by main and by widemasks; each set interleaved,
# fastest of 21, pinned to P core 2. Build first with pup-build.sh.
set -euo pipefail
cd ~/Data/Code/wm-bench
uptime
for f in citm_catalog.json:2000 twitter.json:5000; do
  file=${f%%:*}; n=${f##*:}
  taskset -c 2 python3 inter.py 21 "./ws_main $file $n" "./ws_new $file $n" "./ws_ref best $file $n" "./ws_ref bitcast $file $n"
done
for f in citm_catalog.json:301 twitter.json:801; do
  file=${f%%:*}; n=${f##*:}
  taskset -c 2 python3 inter.py 21 "./cls_main $file $n" "./cls_new $file $n"
done
uptime
