#!/bin/bash
# s1118-boards.sh: the two 2026-11-18 standings boards on pup, back to back, each in its own ab slot
# (s1118-slot.sh): 557, bench/fork against Rayon, 20 rounds; 558, std.json against its competitors,
# 20 rounds on P-core 6. Rig a303f69fd; builds by s1118-build.sh in /zfs/trig-pup/standings-1118.
O=/zfs/trig-pup/standings-1118; X=$O/scripts; cd $O
bash $X/s1118-slot.sh 557 15 "Rig a303f69fd standings: bench/fork vs Rayon, 1 and 12 workers, A/A, 20 rounds" \
  taskset -c 8 python3 $X/s1118-fork-board.py 20 $O/fork-samples.txt $O/fork/rig $O/fork/rig-aa $O/fork/rayon > $O/fork-board.txt 2>&1
echo "# fork slot done $(date +%T)"
bash $X/s1118-slot.sh 558 25 "Rig a303f69fd standings: std.json vs yyjson/simdjson/sonic-rs/simd-json/serde_json/Go, CPU 6, A/A, 20 rounds" \
  taskset -c 8 python3 $X/s1118-json-board.py $O/src/bench/json $O/json-build 6 20 $O/json-samples.txt \
  rig-safe,rig-aa,yyjson,simdjson-dom,sonic-rs,simd-json-tape,serde_json,go-v2 > $O/json-board.txt 2>&1
echo "# json slot done $(date +%T)"
