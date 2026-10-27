# Hash map benchmark

Times the built-in Map (`std/__rig_builtin.rig`) and std.hash's
unordered Map (`std/hash.rig`) against the fastest hash tables in four
languages:

| Variant | Table | Hash | Source |
|---|---|---|---|
| `zig-*` | Zig's `std.HashMap` (`AutoHashMapUnmanaged`, `StringHashMapUnmanaged`), from `smp_allocator` as a Rig program allocates | Zig's | `map.zig` |
| `rust` | Rust's `HashMap`, which is hashbrown | FxHasher, written out (no crate) | `map.rs` |
| `hashbrown` | the hashbrown crate, SwissTable | foldhash, its default | `rust/` |
| `indexmap` | the indexmap crate: entries in a dense `Vec` in insertion order, a hashbrown table of indices; a remove is `swap_remove` | foldhash | `rust/` |
| `absl` | `absl::flat_hash_map`, SwissTable | `absl::Hash` | `map.cc` |
| `boost` | `boost::unordered_flat_map`: groups of 15 slots and an overflow byte | `boost::hash`, mixed by boost | `map.cc` |
| `dense` | `ankerl::unordered_dense::map`: entries in a dense array, a table of buckets | ankerl's wyhash | `map.cc` |
| `go` | Go's built-in map, SwissTable since Go 1.24; a remove is a lookup and a `delete` | the runtime's | `map.go` |

Every variant but `go` and `zig-*` comes also as `-mix` (`rust-mix`,
`absl-mix` ...): the same table with Rig's hash of an Int (`hashWord` in
`src/runtime.zig`, one full multiply folded), so the tables race on one
hash and a gap between two is the table's. `rust` is kept because
tsrs and rustc hash with FxHasher. It is a multiply, so on these keys,
which are `i * MUL`, its hashes keep the keys' stride; that stride
favours it, as sequential ids in a type checker do.

```sh
bench/hash/fetch-deps                    # once: abseil, boost, ankerl, pinned
D=$(mktemp -d)
bench/hash/bench-hash --out $D --build-only --all
bench/hash/bench-hash --out $D --time-only --all --base hashbrown
```

It needs `bin/rig` built first, and `clang++`, `cargo`, and `go` for
the variants that use them. `fetch-deps` clones abseil-cpp, boost's
unordered and the boost libraries it includes, and ankerl's
unordered_dense, each at a release tag, into `bench/hash/upstream/`
(which git ignores), and builds abseil into `upstream/libabsl.a`. The
Rust crates are pinned in `rust/Cargo.lock`. `bench/hash/bench-hash
--help` lists the variants and options; `--all` builds every fast
variant. `hash-*` builds map.rig with each `type X = Map[...]` alias
rewritten to `hash.Map[...]`, so the same program times std.hash; it
needs a `bin/rig` whose std has std.hash, so it is not in `--all`. A
build kept in `--out` is reused, so variants built by different `rig`s
(`RIG=... --build-only --variants hash-fast`) can be timed together.

The sized rows (`int16`, `int1000`, `int100000`, `int4000000`) time
Int keys at four sizes, 4,000,000 operations a row, reported per
operation: insert puts the keys into empty maps (a million keys a
batch: 62,500 maps of 16, 1,000 of 1,000, 10 of 100,000, or one of
4,000,000), remove takes each back out, hit and miss look keys up in
one map of that size, and iterate walks it. The keys are `i * MUL`, and
each loop takes them in order. The random rows (`rnd16` ... `rnd4000000`)
time the same operations on random 64-bit keys (splitmix64 of 0, 1,
...), read from arrays made before the timing, and look the hits up in
an order shuffled once (Fisher-Yates, seeded alike in every program).
So no hash gains from the keys' stride, and no map gains from meeting
its entries in the order it stores them. Every variant times both sets.

Then the Rig and Zig programs insert a million
keys into an empty map, look each up, look up a million they do not
hold, and walk the map, for Int and String keys; they insert, look up
and miss a million keys of two words as well, shaped as Trig's packed
cache keys are (`AutoHashMapUnmanaged` for Zig). The Rig program
also times the three ways to write the value under a key whether or
not it is new (`ensure`, `ensure_with`, and `edit` then `put`), on
misses and on hits, which Zig's has no rows for.

The runs are interleaved and the fastest of each operation counts. Each
program prints `KEYS OP NS CHECK` per operation, and the checksums of
every variant must agree. The report gives each row's fastest variant
and compares every variant with `--base` (default: the first Zig one).
