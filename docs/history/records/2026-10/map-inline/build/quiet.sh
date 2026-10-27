#!/bin/sh
# quiet.sh: wait until pup runs no build (zig build, rig build, release-slot,
# zig cc), no Trig full suite (tools/full-main, /zfs/trig-pup/full jobs), and
# it is not within 25 minutes after a cron suite start (00, 04, ... 20:00).
while :; do
  b=$(ps -eo args | grep -E "^(sh )?[^ ]*(release-slot|zig build|zig-0.17.0/zig|rig build|zig cc|zig clang)|full-main|/zfs/trig-pup/full/" | grep -v grep)
  h=$(date +%-H); m=$(date +%-M)
  if [ -z "$b" ] && ! { [ $((h % 4)) -eq 0 ] && [ $m -lt 25 ]; }; then break; fi
  echo "$(date +%T) waiting for: ${b:-the cron window}" | head -n 2 | cut -c1-200 | tr "\n" ";" >> ${QLOG:-res/quiet.log}; echo >> ${QLOG:-res/quiet.log}
  sleep 30
done
