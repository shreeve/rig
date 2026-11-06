# Panel 2026-11-06, lens "macos": what the Mac's VM gives Rig, and whether Trig's Mac gap has a memory part

In short, the Mac has no huge-page lever, and Trig's memory costs there are small. Nothing on the Mac clears the speed bar. The Mac is most useful as the **control** for pup: tsrs gets no huge pages there either.

## How it was measured

- The machine: an Apple M5 (10 cores, 32 GB, 16 KiB pages), Darwin 27.0.1.
- `.mac-quiet` was absent. Every run went through `tools/low`.
- The load was 5-7: another session was building five Trig release arms. Counts (faults, footprint, instructions) don't depend on load. Times are rough, which is fine for bounding shares.
- The Trig binary is a release build of Trig main `c040e92` with Rig main, copied from that session's `sb/b0/bin`. Its output was normal (exit 2, ts-pattern's usual TS errors).
- Scratch files (sources, raw outputs, traces) are in [macos-data/](macos-data/) (the sources and text outputs; binaries and traces not kept):
  - `vm.c`: faults, prefault, madvise, exit;
  - `mt.c`: concurrent faults;
  - `ex.c`: exit against mappings;
  - `hook.c` and `launch.c`: Trig's exit time;
  - `st8.trace`: an Instruments System Trace, with `vmparse*.py` and `sc*.py` to read it.

## 1. Does Apple Silicon macOS give user memory any form of huge page? No.

- **Superpages.** The SDK's `mach/vm_statistics.h` says of `VM_FLAGS_SUPERPAGE_*`: "Deprecated; not supported on any current hardware". It also marks `VM_FLAGS_SUPERPAGE_MASK` "Currently unused". `mach_vm_allocate(..., VM_FLAGS_SUPERPAGE_SIZE_2MB)` and `..._SIZE_ANY` both return `KERN_INVALID_ARGUMENT` (vm.c).
- **Contiguous hint.** In XNU's public source, `ARM_PTE_HINT` (the arm64 contiguous bit) is used only in `osfmk/arm64/arm_vm_init.c` (the kernel's boot-time mappings) and is checked in `machine_routines.c`. The user `pmap_enter` path never sets it. User anonymous memory is always mapped with single 16 KiB L3 entries.
- **Block mappings.** These would be 32 MiB L2 blocks with a 16 KiB granule. No user API offers them.
- **madvise.** There is no `MADV_HUGEPAGE` and no `MAP_POPULATE`. On Darwin 27, `MADV_WILLNEED` on anonymous memory does fault the range in (measured below), and so does `mlock`. Rig already uses `MADV_FREE_REUSABLE` and `MADV_FREE_REUSE` correctly in `alloc.zig` `decommit` and `recommit` (lines 413-435). The newer `MADV_ZERO` (11) zeroes resident pages in place.
- **16 KiB against 4 KiB.** A 16 KiB page gives 4 times the TLB reach and 4 times fewer faults per MiB than pup's 4 KiB pages, and it costs nothing to use. That is all the Mac offers. Without bigger pages there is no TLB lever to pull.
- **tsrs agrees.** `tsrs_core/src/reserve.rs` sets `HUGE_CHUNK = GRANULE` (64 KiB) off Linux, says "macOS has no huge pages for anonymous memory", and advises nothing there.

## 2. What Rig's allocator does on the Mac

All of these are in `src/alloc.zig` on origin/main:

- **Segments.** They are carved from one 64 GiB `MAP_NORESERVE` region (`reserveRegion`, about line 900), as on Linux.
- **Prefault.** `prefault` (about line 138) does nothing off Linux, so faults are lazy.
- **Huge-page advice.** `adviseHuge`, `hugeFree` and `hugeFreeFor` return early off Linux.
- **Large blocks.** Each comes from its own `mmap` (`mapPages`) and is not aligned (`mapLarge` returns early).
- **Tables.** `reserveTable` returns null off Linux (line 988). So `table.zig` `reserve` (line 118) `mmap`s every Table on its own and `munmap`s it when the Table is dropped (line 143). Trig's checkers make about 43 Tables each.
- **Kept blocks.** A heap that faults ahead (`faultsAhead`, which each of Trig's checker heaps does) keeps its freed large blocks resident. The `MADV_FREE_REUSABLE` cold path is only for server workers.

## 3. Micro costs on the M5

### Faults

A zero-fill fault of one 16 KiB page costs:

| Case | Cost per fault |
|---|---|
| One thread | 650-715 ns (0.042-0.046 ms per MiB) |
| 4 threads, a mapping each | 1.5-1.6 µs |
| 4 threads, one shared mapping | 2.9-3.8 µs |
| 8 threads, a mapping each | 2.2-2.4 µs |
| 8 threads, one shared mapping | 4.2-4.4 µs |

Faults contend in the kernel even into separate mappings, and about twice as much into one shared VM object, whose lock each fault takes.

### Prefault

- **`MADV_WILLNEED`:** 0.036 ms per MiB against 0.045 for lazy faults, on one thread over 256 MiB. Over 64 MiB, and at 4-8 threads over 32 MiB a thread, it was 10-25% slower than lazy faults.
- **`mlock`:** 0.037-0.043 ms per MiB, plus `munlock` at 0.013.
- So prefaulting saves at most the trap, about 20% of a fault, and only on one thread.

### madvise pitfall

- After `MADV_FREE`, touching the pages again cost 10 ms per 256 MiB, with no counted faults: arm64 emulates the referenced and modified bits.
- `FREE_REUSABLE` costs 0.006 ms per MiB and `FREE_REUSE` 0.022 ms per MiB, after which a touch is free.
- Rig's choice of `FREE_REUSABLE` is the right one.

### Exit and teardown

- A dense resident range costs 0.010-0.012 ms per MiB at exit, about the same as `munmap` (0.009). Pup's figure is 0.09-0.13 ms per resident MiB, so the Mac tears memory down about 10 times cheaper per MiB.
- Page-table pages dominate when the touched pages are sparse. 344 mappings of 1 GiB, each with 32 pages touched 32 MiB apart (172 MiB resident), cost 163 ms at exit.
- The number of mappings doesn't matter. The same touch pattern costs 6.8-7.4 ms in 1 mapping and 7.1-7.9 ms in 344.

## 4. Trig on the Mac: the measured shares

### `/usr/bin/time -l`, ts-pattern

| Checkers | Wall | Faults (16 KiB) | Peak footprint | sys |
|---|---|---|---|---|
| 1 | 0.56-0.65 s | 14,470 | 203 MB | 0.02-0.05 s |
| 4 | 0.43-0.58 s | 15.1-15.9K | 199-204 MB | 0.09-0.11 s |
| 8 | 0.36-0.41 s | 17.2-17.3K | 186-189 MB | 0.10 s |

For comparison, zod3 at 1 checker had 4.7K faults and a 56 MB footprint, and at 8 checkers 8.3K faults and 101-110 MB.

### Exit

The exit was measured with an interposed `exit()` timestamp and the parent's `wait4`:

| Checkers | From `exit()` to the parent's wait | Share of the run |
|---|---|---|
| 1 | 3.4-4.5 ms | under 1% |
| 4 | 3.7-4.7 ms | about 2% |
| 8 | 4.4-5.0 ms | about 2% (of 205-234 ms) |

About half of it is resident pages (190 MB × 0.011 ms per MiB ≈ 2 ms). The rest is page-table pages and threads. On pup, the same exit is 22 ms of 0.275 s.

### System Trace at 8 checkers

These are traced times, which inflate each fault.

- **Faults.** 15,844 zero fills took 42.7 ms across all threads. The busiest thread had 7.9 ms of its ~210 ms (3.8%); the main thread had 1.2 ms.
- **The segment region.** The 1 GiB granule touched by all 10 threads had 1,997 faults at 3.89 µs each. Granules touched by fewer threads cost 1.4-2.0 µs.
- **Syscalls.** They took 37 ms on core: `munmap` 420 calls and 17.5 ms, `mmap` 747 calls and 5.5 ms, `mprotect` 2.3 ms.
  - Each thread spends about 0.3-0.75 ms on `mmap` at start.
  - Each checker spends 2-4 ms on `munmap` as its work ends; for the last checker that is 2.3 ms, on the critical path.

### What the shares add up to

- **Faults:** about 1.7% of the run at 1 checker (14.5K × 0.7 µs ≈ 10 ms of 0.58 s), and at most about 4% at 8.
- **Memory syscalls:** about 2% of the busiest thread.
- **Exit:** about 2%.
- **Total memory-side kernel cost:** about 5-8% of Trig's time on the Mac.
- tsrs pays the same kinds of cost per MiB on the same kernel, with no huge pages. On the Mac, only a difference in footprint can make a memory gap between them.

## 5. Designs considered

Each is bounded by its measured share. None clears the bar (more than 1.5% faster, or at least 1% fewer instructions).

| # | Design | Code path | Bound and basis | RSS cost | Verdict |
|---|---|---|---|---|---|
| A | Prefault on Darwin with `MADV_WILLNEED` (or `mlock`/`munlock`) in `prefault` | alloc.zig:138 | At most 20% of faults = 0.3-0.8%. Measured 10-25% slower at 4-8 threads. | None, or a little | DROP |
| B | A VM object per heap: on Darwin, tag each heap's segment mappings with `VM_MAKE_TAG(240 + heap % 16)`, or give each heap its own sub-region, so faults stop sharing one object lock | `reserveRegion` / `mapSegment`, alloc.zig:890-912 | 1,997 faults × 2.4 µs ≈ 4.8 ms of CPU across 8 threads ≈ 0.3% of wall. It grows with cores (an M5 Max has 18). | None | DROP for now. Revisit only if a run on 16+ cores shows segment faults above 2%. |
| C | `reserveTable` on Darwin: one Tables region and no `mmap` per Table. A dropped Table's range would be zeroed with `mmap(MAP_FIXED)` or `MADV_ZERO` and reused. | alloc.zig:987, table.zig:118/141 | Saves `mmap` at start (≤0.75 ms a thread) and the bookkeeping part of the last checker's `munmap` (≤1 ms). Exit is unchanged: the count of mappings doesn't matter, only page-table pages do. ≤1%. | `MADV_ZERO` keeps pages resident, so RSS would be higher; `MAP_FIXED` keeps it level | DROP |
| D | A cheaper exit: skip the drops at exit, or `_exit` early | Trig's own exit path, and runtime exit | Exit is 2%, mostly page and page-table freeing. Skipping the drops only moves that freeing into exit's teardown, which is still in the measured window. Notifying the parent early would game the benchmark. | None | DROP |
| E | Fewer resident bytes, which on the Mac is the only memory lever: every MiB not touched saves 0.045 ms of faulting (1.5-2.4 µs per page under concurrency) plus 0.011 ms of teardown | Trig's stores and Rig's kept blocks | General footprint work, not a Mac design. 10% less footprint ≈ 0.5% of the run. | Lower | Not Mac-specific; belongs to the footprint work |
| F | Larger TLB pages, or a contiguous-hint layout | none | No user API; XNU never sets the hint | — | DROP: the Mac has no such lever |

## 6. What this means for the panel's question

- tsrs's huge-page edge doesn't exist on the Mac. Its arena's `MADV_HUGEPAGE` is compiled only for Linux, and mimalloc's THP code is Linux-only.
- Both programs fault 16 KiB pages lazily there, and exit teardown is 10 times cheaper per MiB than on pup.
- So **the Mac isolates the huge-page part of the gap**. Pup's gap minus the Mac's gap, with the same builds and both at their fastest, bounds what huge pages and fault work are worth on pup.

The measurement that would settle it (NEW):

- Run tsrs on the Mac against Trig: `tools/cli/bench` with a darwin-arm64 tsrs. The npm package `@tsrs/darwin-arm64` would need downloading, which needs the owner's approval; otherwise build it from `misc/tsrs` with `CARGO_TARGET_DIR` outside the Trig tree.
- Measure at 1, 4 and 8 checkers, with `/usr/bin/time -l` page reclaims and footprint.
- Compare the ratio with pup's. If ts-pattern at 8 checkers is much closer on the Mac than pup's 0.275 against 0.229 s, the difference is pup's memory component, and the Linux and allocator lenses should take it. If the Mac's gap is as large as pup's, the gap is not memory, and huge-page work on Linux is capped at the THP share recorded there.
- The first step needs no pup: one Mac run with tsrs once it is available.

## Risks and caveats

- Load was 5-7, so times are rough. The fault, footprint and syscall counts are firm.
- System Trace inflates each fault, from about 0.7-2.4 µs untraced to 2.7 µs average traced, so the shares above are upper bounds.
- The Trig binary is another session's build of main (`c040e92`). Its exact Rig commit was not recorded, but it is Rig main as of 2026-11-06 00:20.
