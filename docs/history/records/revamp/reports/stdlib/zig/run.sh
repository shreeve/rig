#!/bin/sh
# Reproduce the prototype: emit the stand-in program with the Rig
# compiler, hand-edit it onto the shims (handedit.py), and build and run
# it in Debug (leak-checked) and ReleaseSafe.
set -e
cd "$(dirname "$0")"
RIG=${RIG:-/Users/shreeve/Data/Code/rig/bin/rig}
"$RIG" check standin.rig
"$RIG" emit standin.rig 2>/dev/null > standin.emitted.zig
python3 handedit.py
cp input.txt proto/input.txt
proto/build.sh
