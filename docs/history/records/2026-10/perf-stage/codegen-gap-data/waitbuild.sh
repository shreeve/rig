#!/bin/sh
# Starts builds.sh once the Trig suite at 04:00 has built its Rig (rig.built
# rewritten after 04:00), or at 04:30 if it had no Rig to build.
cd /zfs/worktrees/rig/codegen-gap
while [ "$(date +%H%M)" -lt 0405 ]; do sleep 30; done
while :; do
  m=$(date -r /zfs/trig-pup/full/rig.built +%H%M)
  [ "$m" -ge 0400 ] && [ "$m" -lt 0500 ] && break
  [ "$(date +%H%M)" -ge 0430 ] && break
  sleep 30
done
echo "$(date +%T) starting builds (rig.built $(date -r /zfs/trig-pup/full/rig.built +%T))"
exec sh builds.sh
