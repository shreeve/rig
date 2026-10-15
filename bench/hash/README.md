# Hash map benchmark

Times `std/hash.rig`'s Map against Zig's `std.HashMap`
(`AutoHashMapUnmanaged` and `StringHashMapUnmanaged`), both allocating
from `smp_allocator`, as a Rig program does. It is not part of the test
suite or CI.

```sh
D=$(mktemp -d)
cpuq run --cores 2 --label rig:hash -- bench/hash/bench-hash --out $D --build-only
cpuq run --exclusive --cores 1 --label rig:hash -- bench/hash/bench-hash --out $D --time-only
```

It needs `bin/rig` built first. `bench/hash/bench-hash --help` lists the
variants (`rig-safe` and `zig-safe` by default; `rig-fast` and
`zig-fast` on request) and the options. Each program inserts a million
keys into an empty map, looks each up, looks up a million it does not
hold, and walks the map, for Int and String keys; the runs are
interleaved and the fastest of each operation counts. The Rig program
also times the three ways to write the value under a key whether or
not it is new (`ensure`, `ensure_with`, and `edit` then `put`), on
misses and on hits, which Zig's has no rows for.
