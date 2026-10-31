#!/bin/sh
# The timing audit's #678 run: Trig 8e2f21f built by #678's parent and merge.
set -u
D=/zfs/worktrees/rig/timing-audit; cd $D
B=$D/trig-678-base/trig; P=$D/trig-678-pr/trig
date +%H:%M:%S > 678.start
python3 measure.py 20 base=$B pr=$P > 678-one.out 2> 678-one.err
FOUR=1 python3 measure.py 20 base=$B pr=$P > 678-four.out 2> 678-four.err
python3 census-time.py 20 base=$B pr=$P > 678-six.out 2> 678-six.err
date +%H:%M:%S > 678.end
# #678 on today's main: Trig 2ba0719 by main 179c50afa, with prefault_big and without.
M=$D/trig-main/trig; N=$D/trig-main-nopf/trig
python3 measure.py 20 main=$M nopf=$N > 678m-one.out 2> 678m-one.err
FOUR=1 python3 measure.py 20 main=$M nopf=$N > 678m-four.out 2> 678m-four.err
python3 census-time.py 20 main=$M nopf=$N > 678m-six.out 2> 678m-six.err
date +%H:%M:%S > 678m.end
