#!/bin/bash
cd "$1"; rm -f .runs
grep "rc=0" .status | awk '{print $1}' | xargs -P 4 -n 1 /private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/review-place/run1.sh
