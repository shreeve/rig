#!/bin/sh
# quiet.sh: wait until no release build runs and the 1-minute load is under 1.5.
while pgrep -f "[r]elease-slot|[z]ig build-exe" >/dev/null || [ $(awk "{print (\$1 < 1.5)}" /proc/loadavg) = 0 ]; do sleep 30; done
uptime
