#!/bin/bash
n=0; for f in $(ls test/behavior/*/*.rig examples/*.rig | head -580); do "$1" check "$f" >/dev/null 2>&1; n=$((n+1)); done; echo files=$n
