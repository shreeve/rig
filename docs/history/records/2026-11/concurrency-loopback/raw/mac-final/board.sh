#!/bin/bash
# Mac board for #1105 without the skip: main vs A/A vs branch (a0375e5fa), net and http.
set -u
cd /Users/shreeve/Data/Code/worktrees/rig/loopback-ceiling
D=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/mac1105
R=docs/history/records/2026-11/concurrency-loopback
mkdir -p $D
M=$(tools/baseline ea3704772)
echo "main rig: $M"
tools/heavy zig build 2>&1 | tail -2
B=$PWD/bin/rig
for a in main branch; do
  rig=$M; [ $a = branch ] && rig=$B
  RIG=$rig tools/heavy bench/net/bench-net --out $D/net-$a --build-only 2>&1 | tail -1
  RIG=$rig tools/heavy bench/http/bench-http --out $D/http-$a --build-only 2>&1 | tail -1
done
cp $D/net-main/rig-safe $D/net-aa; cp $D/http-main/rig-safe $D/http-aa
ls $D/net-main $D/http-main
tools/mac-claim --minutes 18 l1105-net python3 $R/board.py 20 $D/net.txt main=$D/net-main/rig-safe aa=$D/net-aa branch=$D/net-branch/rig-safe tokio=$D/net-main/tokio
python3 $R/med.py $D/net.txt 2>&1 | tail -20
tools/mac-claim --minutes 15 l1105-http python3 $R/http_ab.py 7 $D/http.txt $D/http-main/load main=$D/http-main/rig-safe aa=$D/http-aa branch=$D/http-branch/rig-safe hyper=$D/http-main/tokio
cat $D/http.txt | tail -40
