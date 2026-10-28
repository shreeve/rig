set -e
cd /Users/shreeve/Data/Code/worktrees/rig/alloc-grow/bench/hash
B=/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-rig-cleanup-merged-branches-8b3cc5/6e4f3c7d-9d60-49e2-a72c-b6ef7d890297/scratchpad/hbmac
for n in main grow; do
  A=$([ $n = main ] && echo $B/alloc-main.zig || echo /Users/shreeve/Data/Code/worktrees/rig/alloc-grow/src/alloc.zig)
  zig build-exe -OReleaseFast --dep table --dep alloc -Mroot=map.zig --dep alloc -Mtable=table_ordered.zig -Malloc=$A -lc -femit-bin=$B/zo-rig-$n --cache-dir $B/zc
done
zig build-exe -OReleaseFast --dep table --dep alloc -Mroot=map.zig --dep alloc -Mtable=table_ordered.zig -Malloc=alloc/malloc.zig -lc -femit-bin=$B/zo-malloc --cache-dir $B/zc
RM=$(/Users/shreeve/Data/Code/worktrees/rig/alloc-grow/tools/baseline 1d0f4dc58)
RIG_OUT_DIR=$B/ro-main $RM build --release=fast -o $B/rigmap-main map.rig
RIG_OUT_DIR=$B/ro-grow /Users/shreeve/Data/Code/worktrees/rig/alloc-grow/bin/rig build --release=fast -o $B/rigmap-grow map.rig
ls -la $B
