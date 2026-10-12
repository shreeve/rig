#!/bin/sh
# A ZIG for rig that applies the study's patches (OP_PATCH, a build.py
# variant such as ws_tbl+utf8_kl) to each emitted package's json.zig once,
# then runs zig. To check a patch against the JSON tests:
#   OP_PATCH=ws_tbl ZIG=$PWD/bench/json/opcodes/opzig.sh RIG_BUILD_STORE=$(mktemp -d) \
#     test/json/compare.py
H=$(cd "$(dirname "$0")" && pwd)
for a in "$@"; do
  case "$a" in
    *.zig) d=$(dirname "$a")
      if [ -n "$OP_PATCH" ] && [ -f "$d/json.zig" ] && ! grep -q "opcode-study" "$d/json.zig"; then
        python3 "$H/build.py" --apply "$d" "$OP_PATCH" || exit 1
        [ -n "$OPZIG_LOG" ] && echo "$d" >> "$OPZIG_LOG"
        grep -q "opcode-study" "$d/json.zig" || echo "// opcode-study: $OP_PATCH" >> "$d/json.zig"
      fi;;
  esac
done
cmd="$1"; shift
# OP_MODE=-Osafe builds the tests' programs optimized: on x86 a Debug
# build uses Zig's own backend, where the patches take their portable
# fallbacks, so only an LLVM build checks the target's instructions.
if [ -n "$OP_MODE" ]; then
  for a in "$@"; do shift; [ "$a" = -Odebug ] && a=$OP_MODE; set -- "$@" "$a"; done
fi
exec zig "$cmd" -j"${CPUQ_CORES:-2}" "$@"
