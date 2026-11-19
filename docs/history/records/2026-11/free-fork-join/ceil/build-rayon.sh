#!/bin/bash
# build-rayon.sh OUT: the Rayon twins (rayon/, rayon3/), cargo build
# --release --offline, each in its own folder here; binaries copied to OUT.
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:?usage: build-rayon.sh OUT}
mkdir -p "$OUT"
(cd rayon && cargo build --release --offline -q)
(cd rayon3 && cargo build --release --offline -q)
cp rayon/target/release/fork-rayon "$OUT/rayon"
cp rayon3/target/release/fork-rayon3 "$OUT/rayon3"
