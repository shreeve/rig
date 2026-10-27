#!/bin/sh
# quiet.sh: wait until pup runs no build (zig build, rig build, release-slot, zig cc), logging what it waited for.
while :; do
  b=$(ps -eo args | grep -E "^(sh )?[^ ]*(release-slot|zig build|zig-0.17.0/zig|rig build|zig cc|zig clang)" | grep -v grep)
  [ -z "$b" ] && break
  echo "$(date +%T) waiting for: $(echo "$b" | head -n 2 | cut -c1-120 | tr "\n" ";")" >> ${QLOG:-res/quiet.log}
  sleep 30
done
