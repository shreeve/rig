#!/bin/bash
# usage: mac-build.sh MAIN_RIG NEW_RIG
# Builds, in this directory, ws_stage (../json-tools/ws_stage.rig) with
# main's compiler (ws_main) and the widemasks compiler (ws_new), and the
# Zig reference with the study's best mask (ws_ref); then checks each
# checksum once (citm, N=200: 99922600). Time them with mac-time.py.
set -euo pipefail
cd "$(dirname "$0")"
WS=../json-tools/ws_stage.rig
D=/Users/shreeve/Data/Code/rig/test/json/data/simdjson
RIG_OUT_DIR=$PWD/out-main "$1" build --release -o ws_main "$WS"
RIG_OUT_DIR=$PWD/out-new "$2" build --release -o ws_new "$WS"
zig build-exe -OReleaseSafe ws_ref.zig --cache-dir zc -femit-bin=ws_ref
./ws_main "$D/citm_catalog.json" 200
./ws_new "$D/citm_catalog.json" 200
./ws_ref best "$D/citm_catalog.json" 200
