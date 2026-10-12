#!/bin/sh
# usage: smoke.sh [N]  -- every binary x flavor x corpus file; rough MB/s only
B=$(cd "$(dirname "$0")" && pwd)
D="$B/../../../test/json/data/simd-json"
N=${1:-20}
for fl in native generic; do
  for p in serde_json_value serde_json_value_fr simdjson_tape simdjson_value; do
    for f in twitter canada citm_catalog gsoc-2018 github_events; do
      file="$D/$f.json"
      bytes=$(wc -c < "$file" | tr -d ' ')
      out=$("$B/target-$fl/release/$p" "$file" "$N" 2>/dev/null); rc=$?
      ns=${out%% *}; chk=${out#* }
      mbs=$(awk -v b="$bytes" -v n="$N" -v t="$ns" 'BEGIN{ if (t>0) printf "%.0f", b*n/t*1000; else print "?" }')
      printf '%-8s %-20s %-14s rc=%d check=%-10s %6s MB/s\n' "$fl" "$p" "$f" "$rc" "$chk" "$mbs"
    done
  done
done
"$B/target-native/release/simdjson_tape" "$D/twitter.json" 1 2>&1 >/dev/null
"$B/target-generic/release/simdjson_tape" "$D/twitter.json" 1 2>&1 >/dev/null
