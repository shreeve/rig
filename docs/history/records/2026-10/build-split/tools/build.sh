#!/bin/bash
# build.sh DIR N OUT: build the N units in DIR (from split.py) in parallel,
# each a `zig build-obj`, then link them with DIR/entry into OUT. Logs go
# to DIR/log/: one /usr/bin/time -l per unit, the link's, the whole
# build's wall time, and the summed RSS of every zig process, sampled
# every 0.2 s (rss.txt, KB), whose maximum is the build's peak memory.
set -u
DIR=$1 N=$2 OUT=$3
FLAGS="-OReleaseSafe -fomit-frame-pointer"
mkdir -p "$DIR/log"
rm -rf "$DIR"/u*/.zig-cache "$DIR"/entry/.zig-cache "$DIR"/u*/u*.o
( while :; do ps -axo rss=,comm= | awk '$2 ~ /zig$/ {s += $1} END {print s + 0}'; sleep 0.2; done ) > "$DIR/log/rss.txt" &
SAMPLER=$!
T0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
PIDS=()
for ((k = 0; k < N; k++)); do
    ( cd "$DIR/u$k" && /usr/bin/time -l zig build-obj $FLAGS --cache-dir .zig-cache __rig_unit_root.zig -femit-bin=u$k.o > "$DIR/log/u$k.txt" 2>&1 ) &
    PIDS+=($!)
done
wait "${PIDS[@]}"
T1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
OBJS=$(for ((k = 0; k < N; k++)); do echo "$DIR/u$k/u$k.o"; done)
( cd "$DIR/entry" && /usr/bin/time -l zig build-exe $FLAGS --cache-dir .zig-cache __rig_unit_root.zig $OBJS -femit-bin="$OUT" > "$DIR/log/link.txt" 2>&1 )
T2=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
kill $SAMPLER
echo "units $(echo "$T1 - $T0" | bc) s, link $(echo "$T2 - $T1" | bc) s, total $(echo "$T2 - $T0" | bc) s" | tee "$DIR/log/wall.txt"
echo "peak summed RSS: $(sort -n "$DIR/log/rss.txt" | tail -1) KB" | tee -a "$DIR/log/wall.txt"
grep -l "error:" "$DIR"/log/*.txt && exit 1
ls -la "$OUT"
