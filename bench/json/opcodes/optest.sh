#!/bin/sh
# optest.sh VARIANT [compare.py args]: the JSON tests (test/json/compare.py,
# every input, sanitizer on) against std/json.rig with a build.py variant's
# patches applied to its emitted Zig. Run it under cpuq.
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../../.." && pwd)
V=$1; shift
# `src:NAME+patches`: the parser in src/NAME.rig, then the patches.
J=$R/std/json.rig
case $V in src:*) N=${V#src:}; N=${N%%+*}; J=$H/src/$N.rig
  case $V in *+*) V=${V#*+};; *) V=base;; esac;; esac
LOG=$(mktemp -d "${TMPDIR:-/tmp}/optest.XXXXXX")
OP_PATCH=$([ "$V" = base ] || echo "$V") ZIG=$H/opzig.sh JSON=$J OPZIG_LOG=$LOG/applied \
  python3 "$R/test/json/compare.py" "$@"
rc=$?
n=$(cat "$LOG/applied" 2>/dev/null | wc -l | tr -d ' ')
echo "optest: $V patched $n package(s)"
rm -rf "$LOG"
[ "$V" = base ] || [ "$n" -gt 0 ] || { echo "optest: no package was patched"; exit 1; }
exit $rc
