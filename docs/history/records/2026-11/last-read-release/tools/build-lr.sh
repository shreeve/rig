#!/bin/bash
# ~/cpuq/tmp/lastread/build-lr.sh DIR: a native (burst) release build of DIR/tree into DIR/trig for the last-read
# census, as setup1123/build.sh builds (CHECK_IDS off, libs pre-built, Rig at the pin, stripped, 32 units), but the
# generated Zig kept in DIR/out. PATCH=1: the generated Zig patched by lastread-zig (the census hooks) first.
set -eu
. ~/cpuq/tmp/setup1123/env.sh
D=$(cd "$1" && pwd)
[ -d "$D/tree/src" ] || { echo "build-lr.sh: no $D/tree/src" >&2; exit 2; }
rm -rf -- "$D/bld" "$D/out"; mkdir -p "$D/bld/src"
for m in "$D"/tree/src/*/; do n=$(basename "$m"); [ "$n" = checks ] && continue; ln -s "${m%/}" "$D/bld/src/$n"; done
mkdir "$D/bld/src/checks"
for f in "$D"/tree/src/checks/*; do [ "$(basename "$f")" = checks.rig ] || cp "$f" "$D/bld/src/checks/"; done
sed 's/^pub CHECK_IDS = true$/pub CHECK_IDS = false/' "$D/tree/src/checks/checks.rig" > "$D/bld/src/checks/checks.rig"
grep -q '^pub CHECK_IDS = false$' "$D/bld/src/checks/checks.rig"
cp "$D/tree/tools/trig/main.rig" "$D/bld/src/main.rig"
unset TRIG_TARGET_CPU
export RIG_OUT_DIR=$D/out TRIG_REAL_ZIG=$(command -v zig)
if [ "${PATCH:-0}" = 1 ]; then
  export REAL_ZIG=$HOME/cpuq/tmp/zig-$([ "${STRIP:-1}" = 1 ] && echo strip || echo cpu) ZIG=${LRZIG:-$HOME/cpuq/tmp/lastread/lastread-zig}
else
  export ZIG=$HOME/cpuq/tmp/zig-strip
fi
units=${UNITS:-32}
"$D/tree/tools/trig/gen-libtrees" "$D/bld/src" "$RIG" build --release $([ "$units" -gt 1 ] && echo --units=$units) -o "$D/trig" "$D/bld/src/main.rig" > "$D/build.log" 2>&1 || { tail -30 "$D/build.log" >&2; exit 1; }
rm -rf -- "$D/bld"
echo "built $D/trig $(sha256sum "$D/trig" | cut -c1-16)"
