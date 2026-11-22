#!/bin/bash
cd "$(dirname "$0")"
t() { /usr/bin/time -l "$@" 2>&1 >/dev/null | awk '/real/ {printf "wall %s user %s sys %s ", $1, $3, $5} /maximum resident/ {printf "rss %.0fMB | ", $1/1048576}'; }
r() { label=$1; shift; echo -n "$label: "; t "$@"; "$@" 2>&1 >/dev/null | tail -1; }
for m in b16 b16p b16d nb b8; do r "$m/64/10" ./floor2 $m 10 21; r "$m/64/10" ./floor2 $m 10 21; done
SPLIT=depth r "b16/depth/10" ./floor2 b16 10 21
SPLIT=depth r "b16/depth/10" ./floor2 b16 10 21
SPLIT=depth r "b8/depth/10" ./floor2 b8 10 21
for m in b16 b16p nb; do r "$m/64/4" ./floor2 $m 4 21; r "$m/64/1" ./floor2 $m 1 21; done
r "fl/64/4" ./floor2 fl 4 21
r "b16/64/6" ./floor2 b16 6 21
r "b16/64/8" ./floor2 b16 8 21
r "b16/64/12" ./floor2 b16 12 21
echo -n "plain: "; t ./bt-plain 21; echo; echo -n "fast: "; t ./bt-fast 21; echo
