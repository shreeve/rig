#!/bin/bash
# build-time.sh N: N clean `zig build`s of the checkout in the current directory (ReleaseSafe, the default),
# each after removing .zig-cache, zig-out and bin/rig; the global Zig cache stays as it is. Prints wall time,
# warnings and bin/rig's size for each.
set -u
n=${1:-2}
echo "# $(uname -sm) $(hostname -s) commit $(git rev-parse --short=9 HEAD) zig $(zig version) load: $(uptime | sed 's/.*load averages*: //')"
for i in $(seq 1 $n); do
  rm -rf .zig-cache zig-out bin/rig
  s=$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')
  out=$(zig build 2>&1); rc=$?
  e=$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')
  w=$(printf '%s\n' "$out" | grep -ci 'warning')
  sz=$(stat -c %s bin/rig 2>/dev/null || stat -f %z bin/rig)
  printf 'build %d rc=%d wall_s=%.1f warnings=%d bin_rig_bytes=%s\n' $i $rc $(echo "$e - $s" | bc) $w $sz
  echo "  bin/rig sha256 $( (sha256sum bin/rig 2>/dev/null || shasum -a 256 bin/rig) | cut -c1-16) parser.zig sha256 $( (sha256sum src/parser.zig 2>/dev/null || shasum -a 256 src/parser.zig) | cut -c1-16) nexus $(${NEXUS:-nexus} --version 2>/dev/null)"
  [ $w -gt 0 ] && printf '%s\n' "$out" | grep -i -A3 warning | head -40
done
