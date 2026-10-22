#!/bin/bash
# usage: pup-build.sh MAIN_RIG NEW_RIG   (on pup, in ~/Data/Code/wm-bench)
# Builds ws_stage and cls_stage with main's compiler (ws_main, cls_main)
# and the widemasks compiler (ws_new, cls_new), and the Zig reference
# with the study's best mask (ws_ref); checks each checksum once and
# counts the lane-by-lane moves (pextrb/pinsrb) in each Rig binary.
set -euo pipefail
export PATH=$HOME/.local/zig-0.17.0:$PATH
cd ~/Data/Code/wm-bench
MAIN=$1
NEW=$2
RIG_OUT_DIR=$PWD/out-main $MAIN build --release -o ws_main ws_stage.rig
RIG_OUT_DIR=$PWD/out-new $NEW build --release -o ws_new ws_stage.rig
RIG_OUT_DIR=$PWD/out-cmain $MAIN build --release -o cls_main cls_stage.rig
RIG_OUT_DIR=$PWD/out-cnew $NEW build --release -o cls_new cls_stage.rig
zig build-exe -OReleaseSafe ws_ref.zig --cache-dir zc -femit-bin=ws_ref
for b in ws_main ws_new; do ./$b citm_catalog.json 2; done
./ws_ref best citm_catalog.json 2
for b in cls_main cls_new; do ./$b citm_catalog.json 3; done
for b in ws_main ws_new cls_main cls_new; do
  echo "$b lane moves: $(objdump -d --no-show-raw-insn -M intel $b | grep -c -E 'pextrb|pinsrb' || true)"
done
