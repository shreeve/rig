#!/bin/zsh
# record.sh BIN PROJECT RUNS: Time Profiler traces of PROJECT full (c1) with BIN, exported for leaf.py as xml/PROJECT.N.xml.
B=$1; P=$2; C=~/Data/Code/trig/misc/corpus; D=~/Data/Code/Claude/rig/rig/ceiling/census; T=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/68cf72db-f7d7-4a2a-9602-3d1de812c626/scratchpad/traces
case $P in
  webpack) W=$C/webpack; F=tsconfig.json;;
  typeorm) W=$C/typeorm/packages/typeorm; F=tsconfig.json;;
  Compiler) W=$C/typescript-benchmarking/cases/solutions/Compiler; F=tsconfig.json;;
  Compiler-Unions) W=$C/typescript-benchmarking/cases/solutions/Compiler-Unions; F=tsconfig.json;;
esac
mkdir -p $T $D/xml; cd $W
for r in $(seq 1 $3); do
  rm -rf $T/f$r.trace
  timeout 240 env -u TRIG_PREBUILT_LIBS xcrun xctrace record --quiet --template 'Time Profiler' --output $T/f$r.trace --launch -- $B --singleThreaded --noEmit -p $F > /dev/null 2>&1
  xcrun xctrace symbolicate --quiet --input $T/f$r.trace --dsym $B.dSYM > /dev/null 2>&1
  xcrun xctrace export --input $T/f$r.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > $D/xml/$P.$r.xml 2>/dev/null
  rm -rf $T/f$r.trace
done
echo "$P done"
