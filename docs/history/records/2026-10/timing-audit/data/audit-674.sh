#!/bin/sh
# #674 on today main: Trig 2ba0719 by main 179c50afa, with leads() and without (only prefault_big).
set -u
D=/zfs/worktrees/rig/timing-audit; cd $D
M=$D/trig-main/trig; N=$D/trig-main-nolead/trig
date +%H:%M:%S > 674m.start
python3 measure.py 20 main=$M nolead=$N > 674m-one.out 2> 674m-one.err
FOUR=1 python3 measure.py 20 main=$M nolead=$N > 674m-four.out 2> 674m-four.err
python3 census-time.py 20 main=$M nolead=$N > 674m-six.out 2> 674m-six.err
date +%H:%M:%S > 674m.end
