# Hash map benchmark

Times the built-in Map (`std/prelude.rig`) and std.hash's
unordered Map (`std/hash.rig`) against the fastest hash tables in four
languages:

| Variant | Table | Hash | Source |
|---|---|---|---|
| `zig-*` | Zig's `std.HashMap` (`AutoHashMapUnmanaged`, `StringHashMapUnmanaged`) | Zig's | `map.zig` on `table_std.zig` |
| `zig-foa` | a port of boost's `unordered_flat_map` to Zig, the base of Rig's `HashMap` | Rig's Int hash, Wyhash for text | `map.zig` on `foa.zig` |
| `zig-dense` | a port of ankerl's `unordered_dense` 5.3.3 to Zig, the base of Rig's ordered `Map` | Rig's Int hash, Wyhash for text | `map.zig` on `dense.zig` |
| `zig-hash`, `zig-ordered` | the designs Rig's `HashMap` and ordered `Map` will take, grown from the ports | Rig's Int hash, Wyhash for text | `map.zig` on `hash.zig`, `ordered.zig` |
| `zig-hash-checked`, `zig-ordered-checked` | the same with the bounds tests safe Rig keeps put back: what Rig must prove away | the same | `.checked = true` |
| `zig-hash` | the design Rig's unordered `HashMap` will take, grown from `zig-foa` | its own: one multiply for an Int, folded multiplies for text up to 32 bytes (Wyhash above) | `map.zig` on `hash.zig` |
| `zig-ordered` | the design Rig's ordered `Map` will take: dense entries in insertion order, an index of tags and 32-bit entry indexes | Rig's Int hash, Wyhash for text | `map.zig` on `ordered.zig` |
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

Every contestant times the rows in [WORKLOADS.md](WORKLOADS.md), which
says exactly what each does; `rust/src/main.rs` is the reference, and the
checksums of every variant must agree:

| Rows | What they time |
|---|---|
| `int16` ... `int4000000` | insert, remove, hit, miss, iterate on keys `i * MUL`, in order: the first round's rows, kept as they were |
| `rnd16` ... `rnd4000000` | the same on random 64-bit keys, hits in shuffled order, at eight sizes: 16, 24, 1,000, 1,500, 100,000, 150,000, 3,000,000, 4,000,000, so each table is caught at more than one fill |
| `lat16` ... `lat4000000` | one lookup at a time, each key the value the last one found: latency, where the other rows let a core overlap lookups |
| `churn16` ... `churn4000000` | a map of a fixed size turned over, a remove and an insert a step, for tombstones and drift |
| `mix16` ... `mix4000000` | lookups half of which hit, in an order no predictor learns |
| `str16` ... `str1000000` | text keys of 7 to 27 bytes, moved into the map and found by equal texts made apart: insert, remove, hit, miss |
| `big16` ... `big1000000` | a value of 64 bytes: insert, remove, hit, iterate |

The `int` rows are not for judging tables: FxHash keeps their keys'
stride, and their in-order lookups hand a dense map its entries in
sequence; the scoreboard leaves them out. `--mem` adds each variant's
peak memory per entry for one map of 4,000,000 Int keys, from two runs
of its program (`mem` and `mem0`, the keys alone), read by `wait4`.

Then the Rig and Zig programs insert a million
keys into an empty map, look each up, look up a million they do not
hold, and walk the map, for Int and String keys; they insert, look up
and miss a million keys of two words as well, shaped as Trig's packed
cache keys are, and of three, shaped as its instantiation keys are
(`AutoHashMapUnmanaged` for Zig). The Rig program
also times the three ways to write the value under a key whether or
not it is new (`ensure`, `ensure_with`, and `edit` then `put`), on
misses and on hits, which Zig's has no rows for.

Every Zig contestant allocates from libc's `malloc`, as the C++ and Rust
ones do, so a row times the table and not the allocator. Go allocates
from its own heap and collects garbage while it runs. A variant may name
another allocator after a colon, to race allocators under one table:
`zig-foa:smp` (Zig's `smp_allocator`), `zig-foa:rig` (Rig's release
allocator, `src/alloc.zig`), `zig-foa:arena` (an `ArenaAllocator` over
`page_allocator`, freed after each row), and `zig-foa:mimalloc`
(mimalloc, pinned by `fetch-deps`); and any variant as `:thp`
(`boost:thp`), the same program run with
`GLIBC_TUNABLES=glibc.malloc.hugetlb=1`, so that on Linux glibc's
`malloc` asks for transparent huge pages. The map.zig allocator is the
module `alloc` (`alloc/*.zig`). None of these is in `--all`.

Every program hides from the optimizer what each round of a row reads,
the keys or the map, as Rust's `black_box` does (`opaque` in map.cc,
`hide` in map.zig), so no round's work is hoisted out of the loop or
merged with another's; the checksums show the work was done. Every
contestant builds for the CPU it runs on, as `rig` and `zig` do by
default: C++ (and abseil's library) with `-mcpu=native` on Arm and
`-march=native` on x86, Rust with `-C target-cpu=native`, and Go with
`GOARM64=v8.5` or `GOAMD64=v3`.

The runs are interleaved and the fastest of each operation counts. A
variant whose first run takes more than a minute runs only once, and
the report says so: Zig's `std.HashMap` takes minutes on the churn
rows, where the tombstones its removes leave pile up (91 µs a step at
100,000 keys, against hashbrown's 7.5 ns). Each
program prints `KEYS OP NS CHECK` per operation, and the checksums of
every variant must agree. The report gives each row's fastest variant
and compares every variant with `--base` (default: the first Zig one),
then a scoreboard: first places by variant over the rows every variant
times, the `int` rows left out. `--spread PCT` lists each row whose runs of a
variant spread more than PCT%, to run again.
