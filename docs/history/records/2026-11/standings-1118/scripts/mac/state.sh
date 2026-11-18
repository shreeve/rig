#!/bin/bash
# bb/state.sh: how quiet the Mac is: load averages and every process over 20% of a core
echo "state $(date +%H:%M:%S) load $(sysctl -n vm.loadavg)"
ps -Ao pcpu,comm -r | awk 'NR>1 && $1>=20 {printf "  %s%% %s\n",$1,$2}' | head -8
