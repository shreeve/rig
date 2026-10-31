#!/bin/sh
# The audit's #754 claim on zod3: standing-2's cached PGO builds, one thread.
set -u
cd /zfs/worktrees/rig/timing-audit
date +%H:%M:%S > 754.start
TRIG_PROJECTS=zod3,ts-pattern python3 census-time.py 20 base=/zfs/worktrees/rig/timing-audit/w-2c01f07dd pr=/zfs/worktrees/rig/timing-audit/w-773978d1d > 754-six.out 2> 754-six.err
python3 measure.py 20 base=/zfs/worktrees/rig/timing-audit/w-2c01f07dd pr=/zfs/worktrees/rig/timing-audit/w-773978d1d > 754-one.out 2> 754-one.err
date +%H:%M:%S > 754.end
