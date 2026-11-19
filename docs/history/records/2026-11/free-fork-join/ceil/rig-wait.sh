#!/bin/bash
# rig-wait.sh: fork.rig (bin/rig) with the preemption monitor's period
# while work waits at 10 ms, not 50 us (RIG_PREEMPT_WAIT_US).
RIG_PREEMPT_WAIT_US=10000 exec "$(dirname "$0")/bin/rig"
