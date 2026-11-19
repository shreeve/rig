#!/bin/bash
# trigAI.sh: Trig A/B, main ee994781b against #1156+#1158 stacked (644e8e694); release builds at 14 GB.
# each arm is built directly from the staged release pack's src with a 14 GB reservation (tools/release-slot), then
# Trig's rows run in ab slot 600 (tools/bench/ab, A/A built in).
set -u
ssh pup "bash -s" <<'REMOTE'
set -u
R=/zfs/trig-pup/runs/rig-light; P=$R/.zig-cache/trig-tests/packs/trig-release; AB=/zfs/trig-pup/abAI; S=/zfs/trig-pup/bin/pup-slot
mkdir -p $AB; cd $R || exit 1
export PATH=$HOME/.local/share/mise/shims:$PATH PYTHONUNBUFFERED=1 TMPDIR=/zfs/trig-cache
for a in old:ee994781b new:644e8e694; do n=${a%%:*} sha=${a#*:}; s=$(date +%s)
  $S state | grep -q slot=none || { echo "a slot is open"; exit 1; }
  RIG=/zfs/trig-pup/rig-$sha/bin/rig TRIG_RIG_OVERRIDE=1 RIG_OUT_DIR=$AB/out-$n RIG_NO_CRASH_REPORT=1 TRIG_RELEASE_SLOTS='10,11 1,2 0,5' TRIG_RELEASE_GB=14 \
    tools/release-slot tools/trig/gen-libtrees $P/src /zfs/trig-pup/rig-$sha/bin/rig build --release -o $AB/trig-$n $P/src/main.rig > $AB/build-$n.log 2>&1
  rc=$?; echo "$n build rc=$rc $(( $(date +%s)-s )) s"; [ $rc = 0 ] && [ -x $AB/trig-$n ] || { tail -8 $AB/build-$n.log; exit 1; }
  echo $sha > $AB/trig-$n.rig
done
cmp -s $AB/trig-old $AB/trig-new && echo "WARNING: identical binaries"
for p in mitt zod3; do for n in old new; do (cd misc/projects/$p && timeout 60 $AB/trig-$n -p tsconfig.trig.json --noEmit --singleThreaded | md5sum | sed "s/^/$p $n /"); done; done
exec 9>/tmp/pup-timing.lock; flock -w 7200 9 || { echo "no lock"; exit 1; }
for i in $(seq 360); do $S state | grep -q slot=none && break; sleep 10; done
sleep 60; : > /zfs/trig-pup/quiet-log/600.txt
o=$($S open 600 60 ab "Trig A/B: main vs huge pages + early start" 2>&1); echo "$o" | tail -n 1
echo "$o" | grep -q "open until" || { echo "slot refused"; exit 1; }
cp /zfs/trig-pup/abAI/ab-fixed tools/bench/ab-fixed
r() { local tag=$1; shift; echo "=== $tag"; timeout 2400 python3 tools/bench/ab-fixed "$@" --json $AB/$tag.json old=$AB/trig-old new=$AB/trig-new > $AB/$tag.txt 2>&1; echo "rc=$?"; grep -E "^[a-z0-9-]+ \(|against old" $AB/$tag.txt; }
r c1 --cores 6 --rounds 30 --projects "mitt neverthrow superstruct tiny-invariant zod3 ts-pattern" --args "-p tsconfig.trig.json --noEmit --singleThreaded"
r c4 --cores 0,6,8,10 --rounds 60 --projects "mitt neverthrow superstruct tiny-invariant zod3 ts-pattern" --args "-p tsconfig.trig.json --noEmit --checkers 4"
rm -f tools/bench/ab-fixed
$S close 600 2>&1 | tail -n 1; bash /zfs/trig-pup/runs/quiet-check.sh 600
echo "# done $(date +%T)"
REMOTE
