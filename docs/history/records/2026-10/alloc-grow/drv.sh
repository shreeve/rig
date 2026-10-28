# drv.sh TREE: the driver on malloc and on TREE's src/alloc.zig, as prof-malloc and prof-TREE.
D=/zfs/worktrees/rig/alloc-grow
T=$1
python3 $D/mkprof.py $D/main/bench/hash/map.zig $D/$T/bench/hash/map-prof.zig
cd $D/$T/bench/hash
for a in malloc $T; do
  A=$([ $a = malloc ] && echo alloc/malloc.zig || echo ../../src/alloc.zig)
  zig build-exe -OReleaseFast --dep table --dep alloc -Mroot=map-prof.zig --dep alloc -Mtable=table_ordered.zig -Malloc=$A -lc -femit-bin=$D/prof-$a --cache-dir $D/zc || exit 1
done
