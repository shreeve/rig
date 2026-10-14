# Rig, emdb, and WebAssembly

A plan, not a feature: what it would take to run Rig on WebAssembly, to
run emdb there, to use emdb from Rig, and later to write emdb's core in
Rig. Nothing here is built yet; the status of each part is at the end.
Discussed with the owner on 2026-10-13.

## What emdb is

[emdb](https://github.com/shreeve/emdb) is the owner's embedded
key-value database in pure Zig 0.17, Rig's own toolchain: a
memory-mapped, copy-on-write B+ tree with MVCC in LMDB's architecture,
written from a formal specification. Reads return a slice straight into
the mapped file (zero copy), commits are crash-safe without a log,
readers never block, every page is checksummed, and it leads LMDB and
libmdbx on most of its benchmark rows. It runs on Linux and macOS.

It is small: 11 files, 18,198 lines, of which 11,245 are code.

| File | Code lines | Role |
|---|---:|---|
| `txn.zig` | 3,741 | transactions, commit, the free list |
| `platform.zig` | 1,267 | the operating system: files, `mmap`, sync, locks |
| `page.zig` | 962 | page layout |
| `c.zig` | 948 | the C API |
| `bulk.zig` | 862 | bulk loading |
| `simd.zig` | 794 | SIMD and CRC |
| `btree.zig` | 766 | the B+ tree |
| `cursor.zig` | 570 | cursors |
| `emdb.zig` | 472 | the public Zig API |
| `verify.zig` | 456 | whole-file verification |
| `main.zig` | 407 | the `emdb` command |

## Why it fits Rig

The delicate rule in an LMDB-style store is how long a read's pointer
stays valid: a slice from `get` points into the mapped file and is good
only until its transaction ends. In C or Zig that rule lives in the
programmer's head. In Rig, `get` would return a view that keeps the
transaction lent, so the compiler rejects any use of it after the
transaction commits or aborts: zero-copy reads that are safe by
construction, at no run-time cost. No other systems language checks
this so cheaply, which makes emdb a showcase for Rig's ownership model,
and a second real workload beside std.json and Trig that exercises
pages, trees, and copy-on-write rather than parsing.

## The four parts

### 1. emdb on WebAssembly (emdb's repo, in Zig)

Nearly all of emdb's operating-system work is already in
`platform.zig`, so a WebAssembly port is one new backend for that file,
not a rewrite. The Emdb session checked this plan against emdb as it is
(2026-10-14), and the details below are its.

- **Finish moving the OS calls behind `platform.zig`.** `txn.zig`,
  `page.zig`, and `cursor.zig` already make none. What remains is two
  `std.c.access` calls in `emdb.zig`, the aarch64 `getauxval` CPU probe
  in `simd.zig`, and the backup's file writer in `c.zig`; `main.zig`,
  the command-line tool, does not run on WebAssembly.
- **One process, one thread.** wasm32-wasi has no threads by default, so
  a large commit seals its pages on one thread instead of up to eight,
  and the writer lock's process-shared futex becomes a flag in memory.
- **Add a `wasm32-wasi` backend:**

| emdb uses | WebAssembly has | The backend |
|---|---|---|
| `mmap` of the database file, written through | no `mmap` (WASI only emulates it by copying) | the pages in WebAssembly memory, so reads stay zero-copy; a commit writes its dirty pages back with `fd_pwrite` at their offsets, then `fd_sync`, then the meta page last, building on emdb's staged-append write path |
| readers in several processes, file locks | one process | the reader table in memory, with no locks |
| `fsync` and `F_FULLFSYNC` for crash safety | WASI `fd_sync`; a browser's OPFS sync handles | the same commit protocol over those calls; durability is the host's `fd_sync` |
| the CPU's CRC instructions | WebAssembly SIMD only | the software CRC emdb already falls back to |

- **Size.** wasm32's memory is 4 GB, so a database is capped below that,
  less the heap, unless the build targets memory64.
- **The specification first.** emdb's SPEC gains a single-process
  platform profile: what WebAssembly guarantees and what it does not (no
  lock file, no reader table shared across processes, durability as the
  host provides it).
- **Tests under wasmtime:** the unit, integration, property, and audit
  suites. The multi-process scripts, crash injection (which captures
  `mmap` images), the disk-full tests, and the command-line smoke test do
  not apply. A browser backend over OPFS (the browser's private file
  storage) can follow.

The Emdb session owns this work; it is a few days by estimate.

### 2. Rig on WebAssembly (Rig's repo)

- **The allocator.** Rig's runtime uses Zig's `smp_allocator`, which
  does not compile on a single-threaded target such as wasm32. That is
  the one thing blocking Rig on WebAssembly today. Choosing Zig's
  `wasm_allocator` there made two Rig programs run under wasmtime in the
  Zig 0.17 audit (`.git/revamp/r3/zig-audit.md`).
- **The target.** `rig build --target wasm32-wasi`, and the standard
  library's modules that touch the OS (`std.os`, `std.time`) working
  under WASI.
- **Keeping it working.** A slice of the test suite runs under wasmtime
  in CI.

**What Trig needs from it** (trig's docs/WASM.md; WebAssembly is
Trig's eventual target, not urgent):

1. **Exported functions.** A host calls `check(files) -> diagnostics`:
   Rig functions exported with the C calling convention, the same
   feature `c.zig` needs in part 4, so one design serves both.
2. **Bytes across the boundary:** exported `alloc` and `free`, and text
   passed as a pointer and a length.
3. **wasm32-freestanding, or WASI with a small shim,** for browsers and
   editors, which have no WASI. Trig's core makes no OS calls.
4. **`Simd[T, n]` lowered to WebAssembly's 128-bit SIMD,** so Trig's
   lexer and std.json keep their speed. SIMD round 2 (#156) already
   tested its operations on wasm SIMD and found two LLVM bugs there (a
   shift of a vector under 16 bytes in optimized builds, and a shift by
   a per-lane amount passed through a call at -O0); the runtime works
   around the first.
5. **Stack depth.** WebAssembly stacks are small and fixed, and a
   TypeScript parser and checker recurse deeply. Rig must state the
   limit on each target and report running out of stack as a clear
   panic, never a silent crash.
6. **Traits** (round 2), for a `Host` interface; already queued.

When `rig build --target wasm32-wasi` works, Trig will run its lexer and
parser test sets (all 18,547 parser inputs) under wasmtime and report
speed and memory against native, as an early check for stack and
allocator surprises.

### 3. Rig calling emdb (a binding)

- **Using a Zig library from a Rig program.** Today Rig calls Zig only
  through files shipped inside its own standard library. A Rig program
  that depends on an outside Zig package, such as emdb, needs a way to
  declare that dependency and link it. This is the real missing piece,
  and every later Rig binding to a Zig library needs it too.
- **A Rig module over emdb's Zig API**, declared with `extern zig`: an
  environment, transactions, `get`, `put`, and cursors. The design point
  is that `get` returns a view the compiler ties to its transaction.
- **The proof.** A test that `rig check` rejects using a `get` result
  after its transaction ends, and a benchmark showing the binding is as
  fast as calling emdb from Zig directly (Rig's rule: the same speed or
  faster).

### 4. emdb's core in Rig (later)

| Part | Code lines | In a Rig port |
|---|---:|---|
| B+ tree, transactions, pages, cursors, bulk load, verify, SIMD | about 9,000 | Rig: where the ownership checker earns its keep |
| `platform.zig`, the OS calls | 1,267 | Zig behind `extern zig`, by choice: they are calls Rig cannot check, so rewriting them adds no safety, and the Rig side sees a safe interface (a mapped page as a view tied to its transaction), the pattern `std.unicode` and `std.json` use |
| `c.zig`, the C API | 948 | Zig until Rig can export functions with the C calling convention, which it cannot yet; with that feature it can move |

**Size.** The ported part would be roughly a third smaller in Rig:
5,500 to 6,500 lines for those 9,000. Indentation removes the 1,698
lines that are only a closing brace; ownership removes the hand-written
cleanup (`defer x.deinit()`, `errdefer`) and the allocator threaded
through every call; Rig's `expr!` and `T!` are terser than `try` and
error-set types. Byte-level page code (layouts, bit packing, offsets,
CRCs) stays about as dense in any language. One data point: Trig's
parser went from 9,064 lines of Go, already compact, to 8,991 of Rig.

**Language features it needs first:** errors that carry data, multiple
results, traits (for the cursor and comparator interfaces), safe forms
for byte-level page layouts, and C export for `c.zig`. Most of these
are on the roadmap for Trig as well.

## Order

1. Now, in parallel: part 1 (the Emdb session) and part 2 (Rig).
2. Next: part 3, once both run, as a spike that proves the
   use-after-transaction rejection and the speed.
3. Later: part 4, after errors with data, multiple results, and traits
   land, and behind Trig's core needs (Map and Set, the two ownership
   proposals, the strings and slices parity pass). It is held to the
   same rule as everything else: as fast as the Zig original.

## Status (2026-10-13)

| Part | Status |
|---|---|
| 1. emdb on WebAssembly | approved by the owner and sent to the Emdb session (2026-10-14); starts after emdb's current queue |
| 2. Rig on WebAssembly | not started; the allocator cause is known |
| 3. The binding | not started; needs Zig-package dependencies in Rig |
| 4. emdb's core in Rig | later |
