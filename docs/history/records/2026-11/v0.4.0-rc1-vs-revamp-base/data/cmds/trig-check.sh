#!/bin/bash
# trig-check.sh RIG TRIGDIR N: `RIG check --time main.rig` in TRIGDIR (Trig's src/ modules with tools/trig/main.rig,
# laid out as tools/emit-diff lays it out), N times, each under /usr/bin/time for peak RSS. Prints every run's
# pass table and RSS; check-best.py takes the best of each pass.
set -u
RIG=$1; cd "$2"; n=${3:-7}
echo "# $(uname -sm) $(hostname -s) rig $($RIG --version 2>&1 | head -1) load: $(uptime | sed 's/.*load averages*: //')"
for i in $(seq 1 $n); do
  echo "## run $i"
  if [ "$(uname)" = Darwin ]; then /usr/bin/time -l $RIG check --time main.rig 2>&1 | grep -v "^ *[0-9]* *\(page\|block\|voluntary\|involuntary\|messages\|signals\|swaps\|average\|cycles\|instructions\)" | grep -v "^$"
  else /usr/bin/time -v $RIG check --time main.rig 2>&1 | grep -E -v "^\s+(Page|File|Socket|Signals|Swaps|Exit|Average|Minor|Major|Voluntary|Involuntary|Percent|User|System|Command)"; fi
done
