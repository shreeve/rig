#!/bin/bash
# trigAH3.sh: confirm or dismiss the c4 flags of trigAH2 (Trig with Rig c014f5e3f vs 3bea1c455): the six small projects at
# --checkers 4 on 0,6,8,10, seeds 2 and 3, 60 rounds. Same binaries in /zfs/trig-pup/abAH. ab slot 556.
F=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/45a7b8df-588d-46f9-ab76-f1ed2a2c6a62/tasks/bmb585z55.output
for i in $(seq 40); do grep -q "light rc=" $F 2>/dev/null && break; sleep 30; done
ssh pup "bash -s" <<'REMOTE'
set -u
S=/zfs/trig-pup/bin/pup-slot; AB=/zfs/trig-pup/abAH; cd /zfs/trig-pup/runs/rig-light || exit 1
export PATH=$HOME/.local/share/mise/shims:$PATH PYTHONUNBUFFERED=1
exec 9>/tmp/pup-timing.lock; flock -w 3600 9 || { echo "no lock"; exit 1; }
for i in $(seq 360); do $S state | grep -q slot=none && break; sleep 10; done
sleep 30; : > /zfs/trig-pup/quiet-log/556.txt
o=$($S open 556 40 ab "Trig A/B c4 confirm: Rig c014f5e3f vs 3bea1c455" 2>&1); echo "$o" | tail -n 1
echo "$o" | grep -q "open until" || { echo "slot refused"; exit 1; }
for seed in 2 3; do echo "=== c4 seed $seed"
  timeout 1200 tools/bench/ab --seed $seed --cores 0,6,8,10 --rounds 60 --projects "mitt neverthrow superstruct tiny-invariant zod3 ts-pattern" --args "-p tsconfig.trig.json --noEmit --checkers 4" --json $AB/c4-s$seed.json old=$AB/trig-old new=$AB/trig-new > $AB/c4-s$seed.txt 2>&1; echo "rc=$?"
  grep -E "^[a-z-]+ \(|against old" $AB/c4-s$seed.txt
done
$S close 556 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 556
echo "# done $(date +%T)"
REMOTE
