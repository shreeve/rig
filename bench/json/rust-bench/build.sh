#!/bin/sh
# usage: build.sh native|generic   (builds with 2 jobs)
set -e
B=$(cd "$(dirname "$0")" && pwd)
case "$1" in
  native)  export RUSTFLAGS="-C target-cpu=native"; export CARGO_TARGET_DIR="$B/target-native" ;;
  generic) unset RUSTFLAGS; export CARGO_TARGET_DIR="$B/target-generic" ;;
  *) echo "usage: $0 native|generic" >&2; exit 2 ;;
esac
export CARGO_BUILD_JOBS=2
for c in serde_default serde_fr simdjson sonic; do
  (cd "$B/$c" && cargo build --release -j 2)
done
