#!/bin/bash
cd "$(dirname "$0")"
printf '%s\n' "$@" | xargs -P 8 -I{} sh -c './t1.sh {} > {}.res 2>&1'
for f in "$@"; do cat "$f.res"; done
