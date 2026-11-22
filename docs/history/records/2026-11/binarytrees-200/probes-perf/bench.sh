#!/bin/bash
cd "$(dirname "$0")"
t() { /usr/bin/time -l "$@" 2>&1 >/dev/null | awk '/real/ {printf "wall %s user %s sys %s ", $1, $3, $5} /maximum resident/ {printf "rss %.0fMB\n", $1/1048576}'; }
echo "== rig binaries"
for i in 1 2 3; do echo -n "plain: "; t ./bt-plain 21; echo -n "fast:  "; t ./bt-fast 21; done
echo "== floor probes (n=21)"
for m in b16 b8 b16p b16d nb fl; do for i in 1 2; do echo -n "$m/64/10: "; t ./floor $m 10 21 2>&1; ./floor $m 10 21 2>&1 >/dev/null | tail -1; done; done
for m in b16 fl; do for i in 1 2; do echo -n "$m/depth/10: "; SPLIT=depth t ./floor $m 10 21; SPLIT=depth ./floor $m 10 21 2>&1 >/dev/null | tail -1; done; done
for m in b16 b8; do echo -n "$m/64/4: "; t ./floor $m 4 21; ./floor $m 4 21 2>&1 >/dev/null | tail -1; echo -n "$m/64/1: "; ./floor $m 1 21 2>&1 >/dev/null | tail -1; done
echo -n "fl/64/1: "; ./floor fl 1 21 2>&1 >/dev/null | tail -1
echo "== profile plain n=22"
./bt-plain 22 >/dev/null & p=$!; sleep 0.05; sample $p 2 1 -mayDie -file prof-plain.txt >/dev/null 2>&1; wait $p
./bt-fast 22 >/dev/null & p=$!; sleep 0.05; sample $p 1 1 -mayDie -file prof-fast.txt >/dev/null 2>&1; wait $p
echo done
