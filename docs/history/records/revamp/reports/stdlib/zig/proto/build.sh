#!/bin/sh
# Build the hand-edited package in Debug (leak-checked) and ReleaseSafe,
# run both on the same input, and compare.
set -e
cd "$(dirname "$0")"
zig build-exe __rig_main.zig -femit-bin=prog-debug --cache-dir .zig-cache
zig build-exe -O ReleaseSafe __rig_main.zig -femit-bin=prog-release --cache-dir .zig-cache
printf 'one\n\nthree is longest\nfour' > stdin.txt
echo "== Debug"; RIG_PROTO=set ./prog-debug extra < stdin.txt; echo "exit=$?"
RIG_PROTO=set ./prog-release extra < stdin.txt > release.out; echo "== ReleaseSafe exit=$?"
RIG_PROTO=set ./prog-debug extra < stdin.txt | diff - release.out && echo "outputs match"
