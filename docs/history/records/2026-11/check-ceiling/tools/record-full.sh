#!/bin/zsh
# record-full.sh RUNS: Time Profiler traces of webpack full (c1) with c8-check/A/bin (the checked build), exported for leaf.py.
B=~/Data/Code/Claude/rig/rig/c8-check/A/bin; D=~/Data/Code/Claude/rig/rig/ceiling/census; T=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/68cf72db-f7d7-4a2a-9602-3d1de812c626/scratchpad/traces
mkdir -p $T $D/xml; cd ~/Data/Code/trig/misc/corpus/webpack
for r in $(seq 1 $1); do
  rm -rf $T/f$r.trace
  env -u TRIG_PREBUILT_LIBS xcrun xctrace record --quiet --template 'Time Profiler' --output $T/f$r.trace --launch -- $B --singleThreaded --noEmit -p tsconfig.json > /dev/null 2>&1
  xcrun xctrace symbolicate --quiet --input $T/f$r.trace --dsym $B.dSYM > /dev/null 2>&1
  xcrun xctrace export --input $T/f$r.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > $D/xml/full$r.xml 2>/dev/null
  rm -rf $T/f$r.trace
done
echo done
