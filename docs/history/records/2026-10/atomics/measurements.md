# What seq_cst costs: Rig's atomics measured on Apple M5

These measurements back [the design note](README.md)'s claim that Rig can keep
seq_cst as its only ordering, provided built-in forms cover the cases
where Rust programmers reach for Relaxed or Acquire/Release.

## Verdict

On arm64 (M5), **seq_cst costs nothing we could measure against
acquire, release, or acq_rel.** For stores and read-modify-writes it is
the same instruction: `stlr` for a store, `ldaddal`/`casal`/`swpal` for an
RMW. For loads, `ldar` (seq_cst) and `ldapr` (acquire) ran at the same
speed in every test: alone, after an `stlr` (the store-then-load
pattern), contended, and inside a CAS loop.

**Ordering does cost something against *relaxed*,** in four places:

1. **A load run back to back, or contended:** `ldar` and `ldapr` were 2.6×
   slower than `ldr` in a tight loop with one thread (0.22 vs 0.08 ns), and
   2.5× slower with three readers and one writer (0.74 vs 0.29 ns).
2. **Summing many slots while writers add to them:** 16 ordered loads take
   86 ns with 4 writers and 200 ns with 8. Relaxed loads take 6 and 13 ns,
   14–15× faster, because only relaxed loads let their cache misses
   overlap. Acquire loads were no faster than seq_cst.
3. **Stores to a contended word:** `stlr` took 2.43 ns and `str` 0.71 ns
   (3.4× slower). release is identical to seq_cst here.
4. **The first load of a CAS loop:** with one thread, a relaxed first
   load made `update(f)` 2.4× faster (507M vs 213M a second). An `ldar`
   or `ldapr` after the previous `casal` stalls. It made no difference
   under contention.

All four fit inside built-in forms that stay seq_cst to the program:

- `update(f)` loads its first guess relaxed. The CAS checks the guess,
  so the result is still one seq_cst RMW.
- A sharded counter reads its slots relaxed. A sum of shards is never
  an atomic snapshot anyway.
- A snapshot cell's reader is `stlr; ldar`. That ran as fast as the
  unsound release/acquire version, and 3.2× faster than Rust's
  `fence(SeqCst)` way.

Contended RMWs, counters, and false sharing are dominated by cache
coherence. There seq_cst and Relaxed were within noise of each other.

On x86-64 (asm only, not timed), only the seq_cst **store** differs:
`xchg` where every other ordering gets `mov`. Loads and RMWs are the same
instruction at every ordering.

## Setup

- Apple M5 (4 P-cores, 6 E-cores), macOS (Darwin 27.0). macOS cannot pin
  threads to cores.
- Zig 0.17.0, `-O ReleaseFast`, native CPU (`apple_m5`, so LSE and RCPC).
- Rust 1.98.1, `cargo build --release` with the default target CPU
  (apple-m1 features: `lse`, `rcpc`, `rcpc2`). std only.
- **arc-swap was not compared.** Downloading crates was not approved, so
  the snapshot section compares the Zig ceiling with Rust's std-only
  `RwLock<Arc<T>>` and `Mutex<Arc<T>>`.
- Every timed run went through `/Users/shreeve/Data/Code/rig/tools/low`
  (`nice -n 19`). A check showed nice did not move single-thread runs
  off P-cores (0.081 ns/op either way).
  `/Users/shreeve/Data/Code/mumps-compare/.mac-quiet` was checked before
  each round, and was never present.
- Each run measures for 200 ms after a start barrier. 171 configurations
  ran in 9 rounds, the Zig and Rust binaries mixed in a shuffled order
  each round (`run.py`, `configs.py`). A second batch of 9 rounds
  (`run2.py`, `configs2.py`) re-ran `update` and `read` with two more
  variants. Its numbers replace the first batch's for those modes.
- **Statistic:** single-thread rows use the best of 9 (the median is
  within 5% everywhere except the noisy `mixed_load_*` rows).
  **Multi-thread rows use the median.** Contended runs are bimodal,
  depending on whether the threads land on the P or E cluster, and the
  best of 9 is often a run where one thread kept the line for itself.
  For example, `counter seq_cst 4` in Rust: 211M once, 70–101M in the
  other 8 runs. Every best and median is in `results/table.txt`.
- Two of 1,809 runs timed out after 30 s: a Zig `spin_hint cold` run in
  round 7 and a Rust `park cold` run in round 8. The machine's load
  average was 5–7 in those two rounds, and they took 70 s instead of
  40 s. The cause was not found. The other 8 runs of each completed
  normally.

## 1. The price of seq_cst, per op

### Instructions (arm64, Zig and Rust identical)

| Form | seq_cst | acquire / release / acq_rel | relaxed |
|---|---|---|---|
| load | `ldar` | `ldapr` (acquire) | `ldr` |
| store | `stlr` | `stlr` (release) | `str` |
| fetch-add | `ldaddal` | `ldaddal` (acq_rel); `ldadda`/`ldaddl` (acquire/release) | `ldadd` |
| swap | `swpal` | | |
| CAS | `casal` | `casal` (acq_rel/acquire) | `cas` |
| store; load | `stlr; ldar` | `stlr; ldapr` | `str; ldr` |
| store; fence; load | | `str; dmb ish; ldapr` | |
| spin hint | `isb` (Zig `spinLoopHint`, Rust `spin_loop`) | | |

### Instructions (x86-64, cross-compiled, not timed)

| Form | seq_cst | acquire / release / acq_rel | relaxed |
|---|---|---|---|
| load | `mov` | `mov` | `mov` |
| store | `xchg` | `mov` | `mov` |
| fetch-add | `lock xadd` (`lock add` if unused) | same | same |
| CAS / update | `lock cmpxchg` | same | same |
| store; load | `xchg; mov` | `mov; mov` (not ordered) | |
| store; fence; load | | Zig `mov; mfence; mov`, Rust `mov; lock or [rsp-64]; mov` | |
| spin hint | `pause` | | |

The full listings are in `asm/zig-arm64.txt`, `asm/zig-x86_64.txt`,
`asm/rust-arm64.txt`, and `asm/rust-x86_64.txt`, built from `asm/forms.zig`
and `asm/forms.rs`. Excerpts:

```
; Zig update(f), seq_cst both ways (arm64)        ; Rust fetch_update(AcqRel, Acquire) (arm64)
ldar   x8, [x0]                                   ldapr  x8, [x0]
add    x9, x8, x8, lsl #1                         mov    x9, x8
add    x10, x9, #1                              L: add   x10, x8, x8, lsl #1
casal  x9, x10, [x0]                              add    x10, x10, #1
cmp    x9, x8 ; loop on casal's result            casal  x9, x10, [x0]
                                                  cmp    x9, x8 ; b.ne L
```

The benchmark loops were checked in the asm of `zig/bench.zig`. The
three `update` loops differ only in the first load (`ldar` / `ldapr` /
`ldr`). The snapshot reader is `str; dmb ish; ldapr; ldr; ldr; stlr` in
the fence variant, and `stlr; ldar; ldr; ldr; stlr` in the seq_cst one.

### Timing, ns per op (lower is better)

One thread, a private word, 256 ops per batch (best of 9):

| Op | seq_cst Zig / Rust | acquire·release·acq_rel Zig / Rust | relaxed Zig / Rust |
|---|---|---|---|
| load | 0.225 / 0.212 | 0.218 / 0.216 | 0.083 / 0.082 |
| store | 0.249 / 0.253 | 0.247 / 0.252 | 0.246 / 0.246 |
| fetch-add | 1.528 / 1.524 | 1.525 / 1.526 | 1.525 / 1.526 |
| store A; load B | 0.280 / 0.282 | 0.286 / 0.282 (rel/acq) | 0.129 / 0.130 |
| store A; fence; load B | | 1.311 / 1.308 | |
| load among 4 plain loads + 4 stores | 2.23 / 2.62 | 2.14 / 2.05 | 2.10 / 2.77 (noisy, ±15%) |
| store among the same work | 0.893 / 0.892 | 0.892 / 0.892 | 0.885 / 0.880 |
| fetch-add among the same work | 1.649 / 1.651 | 1.654 / 1.658 | 1.646 / 1.636 |

Contended (median of 9). Loads: 3 readers and 1 thread storing to the
same word. Stores and fetch-adds: 4 threads on one word. Store A;
load B: 2 threads, each storing its own word and loading the other's
(Dekker):

| Op | seq_cst Zig / Rust | acquire·release·acq_rel Zig / Rust | relaxed Zig / Rust |
|---|---|---|---|
| load (3 readers + 1 writer) | 0.738 / 0.685 | 0.718 / 0.679 | 0.290 / 0.289 |
| store (4 threads) | 2.43 / 2.42 | 2.43 / 2.44 | 0.709 / 0.704 |
| fetch-add (4 threads) | 42.0 / 41.2 | 41.5 / 41.2 | 45.2 / 45.1 |
| Dekker store; load (2 threads) | 52.1 / 50.3 | 51.7 / 50.1 (rel/acq, **not a valid Dekker**) | 0.554 / 0.551 (not valid) |
| Dekker store; fence; load | | 59.7 / 59.5 | |

On this machine, then, seq_cst costs nothing beyond acquire or release.
Ordered loads and stores cost against relaxed only when the loop is
nothing but loads, or the line is contended. The correct Dekker forms,
seq_cst and fence, cost the same coherence round trip. The fence form
was 15% slower.

## 2. A counter many threads add to (adds per second, higher is better)

Median of 9. Sharded: 16 slots, each padded to 128 bytes, one per
thread.

| Threads | one seq_cst word (Rig today), Zig / Rust | Rust `fetch_add(Relaxed)` (Zig monotonic) | sharded, `ldadd` monotonic | sharded, owner's `ldr`+`str` |
|---|---|---|---|---|
| 1 | 647M / 642M | 649M (643M) | 645M | 1,250M (best 1,905M) |
| 2 | 150M / 167M | 165M (151M) | 1,238M | 2,481M |
| 4 | 92M / 100M | 93M (88M) | 2,423M | 4,934M |
| 8 | 25M / 51M | 50M (49M) | 4,392M | 6,686M |

At 8 threads both one-word counters are bimodal, with runs at 25M and at
50M, depending on which cores the threads land on. Every result was
exact: the final value equalled the adds counted.

Relaxed buys nothing over seq_cst for a shared counter. Sharding gives
88× at 8 threads (4,392M vs 50M). Seq_cst adds to padded per-thread words
run as fast as monotonic ones (section 6: 2,425M at 4 threads both ways),
so a sharded counter built from seq_cst Cells would add as fast. The cost
is in reading it.

**Reading** (ns per read; a reader thread runs while N writers add, median):

| Writers | one word, seq_cst `ldar` | sum of 16 slots, monotonic | 16 slots, acquire | 16 slots, seq_cst |
|---|---|---|---|---|
| 0 | 0.216 | 2.06 | 3.71 | 3.87 |
| 4 | 0.864 | 5.95 | 86.4 | 85.8 |
| 8 | 1.82 | 13.2 | 200 | 202 |

Summing with ordered loads is 14–15× slower under writers, and acquire is
no better than seq_cst. A Rig program that sums padded Cells with `get()`
pays this. A built-in sharded counter that reads its slots relaxed does
not.

## 3. `update(f)`, f = x*3+1 (updates per second, median)

| Threads | Zig seq_cst both ways (ldar + casal) | Zig seq_cst CAS, relaxed first load | Rig today: `get` + `compare_swap` loop | Zig acq_rel/acquire | Rust `fetch_update(AcqRel, Acquire)` | Rust `fetch_update(SeqCst, SeqCst)` |
|---|---|---|---|---|---|---|
| 1 | 214M | **507M** | 212M | 212M | 213M | 212M |
| 4 | 8.9M | 8.9M | 10.3M | 8.9M | 9.9M | 9.9M |
| 8 | 3.8M | 3.8M | 4.0M | 3.8M | 3.8M | 3.9M |

seq_cst and AcqRel run at the same speed. With one thread the ordered
first load is the whole cost: relaxed, it is 2.4× faster than both Rig's
and Rust's usual loops. A built-in `update(f)` should use it. It is
still correct, because the CAS checks the guess and is itself seq_cst.
Under contention all variants are bound by the cache line.

The first batch's single-thread `acq_rel` best values (271M Zig, 310M
Rust) were outliers from round 7. The other 17 runs were 192–229M.

## 4. Waiting for a condition

Hot ping-pong: two threads take turns, so each wait is short. Round
trip in ns (median of 9):

| Way | Zig | Rust |
|---|---|---|
| spin on a seq_cst load | 104 | 110 |
| spin with a hint (`isb`) | 95 | 100 |
| futex (`std.Io.futexWait`/`futexWake`, ulock), park every time | 2,240 | |
| `thread::park` / `unpark` | | 2,329 |
| `Condvar` + `Mutex` | | 2,770 |

Cold wake: the signaler sleeps 1 ms, stamps the clock, then signals,
200 times per run. Latency is measured from the stamp to the waiter
seeing the flag, p50 / p90 in ns. CPU is the process's user+sys time
over wall time (100% is one core):

| Way | Zig p50 / p90 (best run) | Zig median of runs | CPU % | Rust p50 / p90 (best) | Rust median | CPU % |
|---|---|---|---|---|---|---|
| spin | 83 / 125 | 84 / 125 | 93–100 | 84 / 125 | 125 / 167 | 96–100 |
| spin + hint | 83 / 125 | 84 / 146 | 94–100 | 83 / 125 | 84 / 166 | 97–100 |
| futex / park | 3,334 / 5,666 | 7,084 / 13,750 | 0.5–0.9 | park 2,542 / 3,958 | 6,770 / 14,396 | 0.4–1.2 |
| condvar | | | | 4,875 / 7,750 | 6,875 / 13,958 | 0.6–1.1 |

Spinning wakes 40–85× faster and burns a whole core. Parking costs about
2 µs a round trip and nothing while waiting. Ordering plays no part: the
wait is a cache-line transfer or a syscall. On M5 the `isb` hint gave
9–10% shorter round trips. Zig 0.17 has no `std.Thread.Futex`; the futex
is the free functions `std.Io.futexWait` / `futexWake`, on macOS
`__ulock_wait2` / `__ulock_wake`.

## 5. A snapshot cell (reads per second, median)

The value is a 1 KB `[128]u64`. One writer replaces it every
millisecond (about 140 swaps per 200 ms run). Each read gets the
current value, checks `v[127] == v[0] + 127`, and lets it go. No read
saw a torn value.

The Zig ceiling is an epoch scheme. Each reader owns a padded slot,
odd while it reads. To read, it stores its slot odd, loads the
pointer, reads, and stores the slot even. The writer swaps the
pointer (seq_cst), waits until every slot that was odd has changed,
then frees the old value. This is correct only if the slot store comes
before the pointer load, a store-to-load order that seq_cst gives and
release/acquire does not.

| Readers | Zig epoch, seq_cst (`stlr; ldar`) | Zig epoch, `str; dmb ish; ldapr` (Rust's fence idiom) | Zig epoch, `stlr; ldapr` (**unsound**, ceiling only) | Rust `RwLock<Arc<T>>` | Rust `Mutex<Arc<T>>` |
|---|---|---|---|---|---|
| 1 | 2,139M | 669M | 2,140M | 205M | 210M |
| 4 | 8,378M | 2,505M | 8,382M | 4.6M | 80M |
| 8 | 13,070M | 6,383M | 13,012M | 2.8M | 61M |

The seq_cst reader runs at the unsound ceiling. It is 3.2× faster than
the fence form at one reader and 2.0× faster at eight. M5 does not stall
an `ldar` behind an earlier `stlr` to a line it owns. Rust's std-only
forms are 10–4,700× slower, because every read updates a shared Arc
count (and, for RwLock, a shared reader count). **arc-swap would belong
in this table, but its crate could not be downloaded.** The scheme needs
one slot per reader, which a Rig runtime would keep per worker.

## 6. False sharing (adds per second, median)

Each thread does a fetch-add on its own word. The words are either
adjacent (8 bytes apart, one line) or each aligned to 128 bytes.

| Threads | adjacent seq_cst Zig / Rust | padded seq_cst Zig / Rust | slowdown | adjacent monotonic Zig / Rust | padded monotonic Zig / Rust |
|---|---|---|---|---|---|
| 2 | 165M / 166M | 1,282M / 1,280M | 7.8× slower | 165M / 165M | 1,283M / 1,284M |
| 3 | 122M / 122M | 1,820M / 1,819M | 15× slower | 115M / 116M | 1,820M / 1,820M |
| 4 | 84M / 84M | 2,425M / 2,426M | 29× slower | 86M / 88M | 2,423M / 2,426M |

This reproduces the Rig probe's 4–10× and goes further: 8× slower at 2
threads, 29× at 4, the same in Zig and Rust, and the same at relaxed.
Padding is the whole fix, and ordering plays no part.

## Files

The sources and raw runs are not kept here (records keep no bulk data). They are in the owner's session folder, `~/Data/Code/Claude/rig/rig/atomics-bench/`:

- `zig/bench.zig`: every Zig ceiling; `bench MODE VARIANT THREADS`.
- `rust/src/main.rs`, `rust/Cargo.toml`: the Rust versions, with the same command line.
- `asm/forms.zig`, `asm/forms.rs`, and `asm/*.txt`: the instruction listings for arm64 and x86-64.
- `configs.py`, `run.py`, `configs2.py`, `run2.py`: the configurations and the interleaving driver.
- `summarize.py`, `table.py`, `dist.py`: best-of, best-and-median, and per-run distributions.
- `results/raw.txt` (1,539 runs), `results/raw2.txt` (270 runs), `results/table.txt`.
- `cacheline/`: the Rig probe of adjacent `*Cell`s (`adjacent.rig`, `apart.rig`, `alone.rig`, `time.py`). Built with `rig build --release` at main 1b2f4b59d and timed fastest of 9 through `tools/low`, twice: adjacent 0.366 and 0.153 s, apart 0.038 and 0.037 s, alone 0.036 and 0.035 s.
