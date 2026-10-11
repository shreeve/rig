#!/bin/sh
# A ZIG for rig (RIG ZIG=this script; NIB_MODE, NIB_JOBS, NIB_LOG): patches the package's json.zig with nibble.py $NIB_MODE (once), then runs zig with -j$NIB_JOBS.
N=$(cd "$(dirname "$0")" && pwd)
for a in "$@"; do
  case "$a" in
    *.zig) d=$(dirname "$a")
      if [ -f "$d/json.zig" ] && ! grep -q "nibOf" "$d/json.zig"; then
        python3 "$N/nibble.py" "$d" "$NIB_MODE" >> "${NIB_LOG:-/dev/null}" 2>&1 || exit 1
      fi;;
  esac
done
cmd="$1"; shift
exec zig "$cmd" -j${NIB_JOBS:-2} "$@"
