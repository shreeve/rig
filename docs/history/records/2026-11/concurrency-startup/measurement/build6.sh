#!/bin/bash
# build6.sh MAIN_RIG TREE_RIG RAYON_BIN [OUT]: build board6.py's binaries
# into OUT (default prog/): startup.rig and bench/{tasks,actors,net} with
# main's rig and with the fix's, `rig build --release`, each main build
# copied as the A/A arm (`-aa`), and the Rayon twin (rayon/, built with
# `cargo build --release`) copied as `rayon`. Run from the checkout's root.
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
main=$1 tree=$2 rayon=$3 out=${4:-$S/prog}
mkdir -p "$out"
for p in startup:$S/startup.rig tasks:bench/tasks/tasks.rig actors:bench/actors/actors.rig net:bench/net/net.rig; do
    name=${p%%:*} src=${p#*:}
    RIG_OUT_DIR=$out/out-main-$name "$main" build --release -o "$out/$name-main" "$src"
    RIG_OUT_DIR=$out/out-tree-$name "$tree" build --release -o "$out/$name-tree" "$src"
    cp "$out/$name-main" "$out/$name-aa"
done
cp "$rayon" "$out/rayon"
