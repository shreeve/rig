#!/bin/bash
# Peak RSS of each arm, interleaved, 5 rounds, on E-cores (RSS does not need quiet cores).
# Each line: project checkers arm peak-KiB seconds free-2MiB-blocks-before (huge-page mode:
# the allocator asks for huge pages for Tables when that count is over 64).
R=/zfs/worktrees/rig-rust-ports/slack; P=/zfs/trig-pup/full/trig/misc/projects
mkdir -p /tmp/slack && for a in m n k h all; do cp $R/trig-$a /tmp/slack/$a; done
free2m() { awk '{ s += $14 + 2 * $15 } END { print s }' /proc/buddyinfo; }
out=$R/rss.txt; : > $out
for r in 1 2 3 4 5; do
  for p in mitt neverthrow superstruct tiny-invariant zod3 ts-pattern; do
    for a in m n k h all; do
      cd $P/$p
      f=$(free2m); /usr/bin/time -f "%M %e" -o /tmp/slack/t taskset -c 14 /tmp/slack/$a -p tsconfig.trig.json --noEmit --singleThreaded > /dev/null 2>&1
      echo "$p 1 $a $(cat /tmp/slack/t) $f" >> $out
      f=$(free2m); /usr/bin/time -f "%M %e" -o /tmp/slack/t taskset -c 16-19 /tmp/slack/$a -p tsconfig.trig.json --noEmit --checkers 4 > /dev/null 2>&1
      echo "$p 4 $a $(cat /tmp/slack/t) $f" >> $out
    done
  done
done
echo RSS DONE >> $out
