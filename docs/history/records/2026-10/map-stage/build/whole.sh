#!/bin/sh
# whole.sh BUILD RIGSRC INSTR: Trig (fork)'s whole.py on /tmp/sp-BUILD.data (spillrun.sh's samples), INSTR the instructions per run.
b=$1; src=$2; instr=$3
perf script -i /tmp/sp-$b.data -F ip,sym,symoff 2>/dev/null | awk '{print $2}' | sort | uniq -c > /tmp/sp-$b.offs
n=$(awk '{s += $1} END {print s}' /tmp/sp-$b.offs)
scale=$(python3 -c "print($instr / $n / 1e6)")
python3 /zfs/trig-pup/trial/dis/whole.py /zfs/worktrees/rig/map-stage/packs/$b/bin /tmp/sp-$b.offs $scale $src
