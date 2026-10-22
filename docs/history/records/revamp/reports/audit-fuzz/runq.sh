#!/bin/bash
# run harness over each dir in sequence
cd "$(dirname "$0")"
for d in "$@"; do
  python3 harness.py "$d" 10 > "$d.log" 2>&1
done
