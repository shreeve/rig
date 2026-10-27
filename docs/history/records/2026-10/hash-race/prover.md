# Hash race: the prover's record (2026-10-27)

The prover owns bench/hash's harness and checks that a first place is
true, fair and repeatable. This page holds the fairness audit, the
allocator race (the owner's question: "is malloc ideal? does zig use an
arena?"), and the confirmation runs.

## 1. Fairness audit

| Check | Finding | State |
|---|---|---|
| Native builds | `zig build-exe` and `rig build` build for the host CPU by default; C++ (and libabsl) `-mcpu=native` / `-march=native`; Rust `-C target-cpu=native` for rustc and cargo; Go `GOARM64=v8.5` / `GOAMD64=v3`. | Fair. Go's levels gate only atomics and a few intrinsics, not the map. |
| One allocator | Zig (both map.zig's arrays and the tables), C++ (`operator new`) and Rust (the system allocator, no `#[global_allocator]`) all call libc `malloc`. Go has its own heap and its GC runs during the timed loops. | Fair, Go apart as labelled. |
| The hash | The Zig ports call the context's hash as it is (avalanching, no extra mix), as `boost-mix` and `dense-mix` mark theirs; Int is Rig's `hashWord` everywhere `-mix` or `zig-*` says so; text is Wyhash in the Zig ports and each C++/Rust table's own string hash. | As labelled. |
| The builders' hashes | `zig-ordered` uses the context's hash (Rig's Int hash, Wyhash for text), as `zig-foa` does. `zig-hash` hashes with its own: an Int with one multiply, text up to 32 bytes with folded multiplies over reads that cover every byte (Wyhash above). That is a table's own hash, like `rust`'s FxHash or `boost`'s, now labelled so in the README; the owner's decision 7 allows the multiply only if it is over 2% faster on the small rows with nothing slower, which the race must show against a `zig-hash` on Rig's hash. On random keys one multiply loses nothing; on the `int` rows' strided keys it would, and those rows are off the scoreboard. | As labelled; decision 7's check still owed. |
| The work | bench-hash stops on any checksum that differs between variants. Every timed loop folds the values it finds, removes or walks into its row's CHECK. | Proved. |
| Black boxes | **Unequal, fixed.** map.cc and map.rs hide each round's keys (or map) from the optimizer (`opaque`, `black_box`), and keep the maps after a remove row; map.zig did neither, so LLVM was free to hoist or merge rounds for the Zig contestants only. map.zig now does the same (`hide`, `keep`). Measured before and after on the Mac (7 runs each): no row moved beyond its noise, so the old Zig numbers stand; the harness is now symmetric. | Fixed. |
| Timers | Every program reads a monotonic clock (Zig `.awake`, C++ `steady_clock`, Rust `Instant`, Go `time.Now`) around the same loops; key arrays are made before, maps dropped after. | Fair. |
| Code layout | One binary per table and per allocator; every program runs the rows in the same order. Moving code shifts a hot loop by 5-7% on Apple cores, so a gap under that between two binaries is not a table's. | As fair as separate binaries allow. |
| Huge pages | See below. | Unequal on pup only where noted. |
| Text keys | Each language's own string: C++ `std::string` keeps up to 22 bytes inline on the Mac (libc++), 15 on pup (libstdc++), so on the Mac about half the keys sit in the slot; Rust `String` and Zig slices always point to the heap. | A real difference between the languages, kept: it is what each program would do. |

### Huge pages on pup (THP `madvise`, defrag `madvise`)

Measured, not read from source: each program built one map of 4M Int
keys (`mem`) while a probe sampled `/proc/PID/smaps_rollup` every 2 ms.

| Program | Peak RSS | Backed by THP |
|---|---|---|
| zig-foa (glibc malloc), boost, absl, dense, hashbrown | 150-235 MiB | 0 |
| go (its own heap) | 205 MiB | 0 |
| rig-fast, zig-foa:rig (Rig's allocator) | 178, 234 MiB | 0 |
| zig-foa:smp, zig-foa:arena (Zig's page_allocator) | 225, 289 MiB | 0 |
| zig-foa:mimalloc (mimalloc 3.5.3, defaults) | 232 MiB | 230 MiB (99%) |
| zig-foa:thp, boost:thp, hashbrown:thp (`GLIBC_TUNABLES=glibc.malloc.hugetlb=1`) | 222-233 MiB | 214-226 MiB (96-97%) |

So the default race is level: no contestant has huge pages on pup. A
`:thp` run gives glibc's contestants huge pages, and mimalloc takes
them on its own. On the Mac, with 16-KiB pages, no program asks.

### The memory column on the Mac

macOS's `malloc` keeps the large blocks a growing table frees, and they
count in peak RSS and in the peak footprint alike (`/usr/bin/time -l`:
302 MB both, for zig-foa's 4M map). So on the Mac a malloc contestant's
bytes per entry hold every earlier generation of its table: zig-foa
67.1 there, 50.3 on pup (old and new arrays during the last rehash).
Rig, Go, smp and mimalloc reuse or unmap those blocks. Read the
Mac's memory column as table and allocator together, and pup's as
the table's.

### Repeatability on the Mac

The Mac has 4 performance cores and 6 efficiency cores, and `tools/low`
runs at nice 19; with the builders' runs beside it, a run may land on an
efficiency core. The fastest of N absorbs that only if each variant gets
one run on a performance core, so the report's `--spread` (new) lists
rows whose runs spread more than a bound, to run again.

The `str* remove` rows time `free` of each key and are bimodal on the
Mac from run to run (zig-foa `str1000 remove`: 18 to 38 ns in four
runs of one binary): read them only as the fastest of many runs.

## 2. The allocator race

One table, `zig-foa`, timed with six allocators: `bench-hash --variants
zig-foa,zig-foa:malloc,zig-foa:thp,zig-foa:smp,zig-foa:rig,zig-foa:arena,zig-foa:mimalloc
--reps 7 --mem` (`:thp` on pup only), the Mac through `tools/low`, pup
on core 8. `zig-foa:malloc` is a second build of the default, the
control. The full reports are
[prover-alloc-mac.txt](prover-alloc-mac.txt) and
[prover-alloc-pup.txt](prover-alloc-pup.txt); the table below is each
allocator's time against malloc's, the geometric mean over a group of
rows (under 1.00 is faster).

| Rows | n | Mac smp | Mac rig | Mac arena | Mac mimalloc | pup thp | pup smp | pup rig | pup arena | pup mimalloc |
|---|---|---|---|---|---|---|---|---|---|---|
| Int: insert, remove, turnover | 20 | 1.06 | 0.97 | 1.10 | 1.01 | 0.95 | 1.08 | 1.01 | 1.26 | 0.95 |
| Int: lookups, iterate | 32 | 1.09 | 1.00 | 1.03 | 1.01 | 0.98 | 1.03 | 0.98 | 0.99 | 0.97 |
| Int: 3M and 4M rows | 13 | 1.00 | 0.98 | 1.05 | 1.03 | **0.89** | 1.00 | 1.00 | 1.01 | **0.86** |
| Text: insert, remove | 8 | 0.46 | 0.53 | **0.40** | 0.56 | 0.87 | 0.80 | 0.70 | **0.65** | 0.70 |
| Text: hit, miss | 8 | 0.74 | 0.98 | 0.74 | 1.00 | 0.96 | 0.98 | 0.96 | **0.71** | 0.87 |
| Big values: insert | 4 | 1.50 | 1.37 | 1.44 | 0.93 | 0.98 | **2.36** | **1.75** | **2.45** | 1.03 |
| All 84 rows | 84 | 0.97 | 0.96 | 0.95 | 0.95 | 0.96 | 1.05 | 0.99 | 1.02 | **0.94** |
| Peak bytes per entry, 4M map | | 50.3 | 54.5 | 67.1 | 50.5 | 50.3 | 50.3 | 54.7 | 67.1 | 51.9 |

malloc's own: 67.1 B/entry on the Mac, 50.3 on pup. The control's
geometric mean is 1.00 on pup in every group; on the Mac it is 0.93 to
0.99, so under the builders' load **the Mac cannot tell apart two
allocators, or two tables, within about 5%**.

What each does, and why:

- **Text rows** allocate a key per entry, so they time the allocator's
  small blocks. Every allocator beats libc's malloc there: on the Mac
  by 1.8-2.5x on insert and remove (macOS malloc's small blocks are
  slow), on pup by 1.25-1.5x. Lookups move with where the keys land: an
  arena packs them, so pup's `str100000 hit` is 13.3 ns against
  malloc's 41.9.
- **Big-value inserts** grow a table past 32 KiB again and again. On pup
  Rig's allocator is 1.75x malloc's time on them (`big1000000 insert`
  92 ns against 45, `big1000` 44 against 29), smp 2.4x and the arena
  2.5x; on the Mac Rig's is 1.37x. Rig's `allocLarge` serves a block
  over 32 KiB only from a freed one of the same size, keeps at most
  16 MiB of them, and otherwise maps fresh pages; glibc serves blocks
  under its mmap threshold (up to 32 MiB) from a heap already faulted
  in. The 1,000 live maps of `big1000` (150 MB) never fit in 16 MiB.
- **The 4M rows on pup** want huge pages: with `hugetlb=1` the same
  malloc program is 11% faster on them (`rnd4000000 insert` 25.4 ns
  against 35.9, `hit` 15.5 against 18.4, `lat4000000` 139 against 147),
  and mimalloc, which madvises its own arenas, 14%. Nothing else moves
  them.
- **The arena** never gives back an outgrown table, so it holds 67.1
  bytes an entry against 50.3, and pays fresh pages at every growth.

### What this means for Rig

1. **Is malloc ideal?** No. It is the fair choice for the race, since
   every C++ and Rust table uses it, and on Int keys the allocator moves
   no row past the noise but the large-block ones. But glibc's malloc
   leaves the 4M rows 11% slower than huge pages would, and macOS's
   small blocks are the slowest of all five. Rig's own allocator is
   already better than malloc on small blocks: 47% less time on the Mac,
   30% on pup, on text insert and remove.
2. **Does Zig use an arena?** Zig has no default allocator; a program
   passes one. std offers `ArenaAllocator` for data freed together, and
   `smp_allocator` (or `c_allocator` when linked with libc) as a
   general one. For a hash table an arena is the wrong tool: the fastest
   text rows, but the slowest big inserts and a third more memory.
3. **Rig's allocator has two gaps the race exposes.**
   - Large blocks, 32 KiB to a few MiB, reused only by exact size and
     at most 16 MiB of them. Many mid-size tables built and dropped pay
     fresh page faults: 1.75x malloc's time on pup's big inserts. A
     keep that serves a smaller request from a larger freed block, or a
     larger keep, would close it; that is a design question for
     `src/alloc.zig`, not the race.
   - No huge pages: worth about 11% on pup's 4M rows, which supports
     the panel's decision 11 (THP for blocks of 2 MiB or more, judged
     against Trig's peak memory).
4. **A Rig program and a Zig prototype differ by allocator.** The race
   times `zig-hash` and `zig-ordered` on malloc. Emitted by Rig, the same
   tables run on Rig's allocator: expect the text rows faster and the
   big-insert rows slower than the prototype's numbers, until (3) is
   fixed. The race between `rig-fast` and the malloc contestants is not
   allocator-neutral on those rows.

## 3. Confirmation runs

(none yet)
