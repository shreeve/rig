# Allocator lens: how tsrs lays out its memory, and what Rig's allocator and Tables would do differently

Panel of 2026-11-06. Read only; no runs (pup out of reach, nothing here needed the Mac). Every number is from a record, cited.
Line numbers are `origin/main` (`c93e94b30`).

## 1. What tsrs does, exactly

**The reservation** (`crates/tsrs_core/src/reserve.rs`):

- One 32 GiB `PROT_NONE`, `MAP_NORESERVE` mapping at a fixed address, `0x4001_0000_0000` (`reserve()`). Every arena
  chunk of every thread is carved from it with a first-fit free list (`Chunks::take`) and committed by `mprotect`.
- A *huge* chunk (`alloc_chunk(size, huge=true)`) is aligned to 2 MiB and is a multiple of 2 MiB. `commit` advises it
  `MADV_HUGEPAGE` *before* the `mprotect`, so the new read-write range merges with its advised neighbour rather than
  splitting. Advice survives `mprotect`. There is no gate: it asks every time and leaves the outcome to the kernel
  (`defrag=madvise` compacts in the fault, or falls back).
- Region slabs (per-file regions, the LSP) are released piecemeal and stay on 4 KiB pages.

**The thread arena** (`arena.rs:32-45, 185-233`):

- One bump finger per thread, moving down. The first chunk is 1 MiB on 4 KiB pages, so a thread that allocates little
  pins no 2 MiB page. After that, chunks double, 2 → 4 → … → 64 MiB (`MAX_CHUNK`). Every chunk of 2 MiB or more is a
  huge chunk, rounded to 2 MiB "since an unused tail would be resident with the huge page it shares" (`arena.rs:36`).
- Records of every kind go into that one arena: types, symbols, lists, links. A `P<T>` is a 32-bit handle read as
  `base + (h << 3)`.
- `trim_own_arena_tail` (`arena.rs:1086-1109`) runs `MADV_DONTNEED` on the part of the finger's 2 MiB block that was
  never handed out, for a checker that finishes while others still check. A finished thread also hands its arena to the
  next thread (97 arenas → 33 at 32 checkers).

**The heap.** mimalloc v3 is built `no_thp`, so the heap is not advised: its per-thread, per-size-class pages would each
pin 2 MiB (0.7 GiB of a 2.0 GiB front end on 64 vCPUs; `notes/mem-no-thp.md`). `init_mimalloc`
(`allocator.rs`) undoes mimalloc-safe's `PR_SET_THP_DISABLE`, so the arena keeps its huge pages. Disabling THP for the
whole process cost 4-10% of check time.

**Why the RSS cost is small.** There is one partly used 2 MiB block per thread, the one under the finger. On average
half of it is unused.

- `mem-linux-residency-32.md`: 57-71 MiB unused but resident across 97 thread arenas at 32 checkers, 0.6-0.7 MiB each,
  2.1-2.7% of peak. With the hand-over and the trim it falls to 0-2 MiB.
- `linux-x86-round.md`: huge pages for the arena moved peak RSS by 0.1-0.7%, and `AnonHugePages` equalled the
  arena's RSS (2.72 of 2.72 GiB). Their verdict: "the arena is dense".
- What it bought: 1.7-5.9% less wall time, minor faults from 740K-1,070K down to 22-36K, and dTLB misses down
  50-65%.

## 2. What Rig and Trig do

**The heap** (`src/alloc.zig`):

- Segments are 4 MiB, aligned to their size, and carved into 64 KiB class pages handed out in order (`newPage`,
  `alloc.zig:313-331`). So each heap is one finger, as tsrs's arena is. Its pages are advised huge while the heap
  `faultsAhead` and free 2 MiB blocks number its need plus `huge_floor` 8 (`adviseHuge` 546, `hugeFreeFor` 608).
- Large blocks of 16 MiB or more (`huge_large`, 516) are aligned and advised. Smaller ones keep 4 KiB pages.
- The segment change (`seg`, table-huge.md) is the proof that one finger costs little. It gave huge pages to dense
  segments for **0.1-2.0 MB of peak RSS**.

**The Tables** (`src/table.zig:118-139`, `alloc.zig:987-1017`):

- Each `Table` takes its own range of the Tables' region, whole 2 MiB pages, sized for all `n` slots: 24 MiB to
  4 GiB, 53 GiB per checker.
- The first 2 MiB (the "head") is advised `NOHUGEPAGE`.
- The rest (the tail) is advised `HUGEPAGE` only if `hugeFree()` (more than 64 free blocks, spare 64, 568) when the
  Table is *reserved*. On pup that is usually shut (5-69 free).

**How many growing ranges Trig touches.** A checker reserves 43 Tables (`trig/src/checker/store_generated.rig:592-654`,
`checker.rig:43-44,319`, `symbols.rig:109-113`). They are of two kinds:

- **Push-dense: about 36.** The 20 per-kind type Tables, the extras, signatures, mappers, the 8 list arenas, `syms`.
  Each is written from the front, so each is its own finger.
- **Sparse: 7 link Tables** (`*_links`, "by symbol or program-wide node id"). Each checker writes only the ids of its
  own files and the lib nodes it uses.

Measured on ts-pattern:

- At one checker, 40 Tables are touched. About 10 pass 2 MiB, with page counts 5545, 4503, 4004, 3977, 3286, 2655,
  2100, 1324, 1224, 602… (`fault-ahead/kernel.md` §4).
- At eight checkers (`scaling/investigation.md` §3), 409 heads hold 95 MiB on 4 KiB pages, **0.23 MiB per head**.
  410 tails hold 46 MiB.
- The page tables are 3.4 MiB, which is about 870 distinct 2 MiB windows touched to hold 220 MiB. That is **about
  0.25 MiB per touched window**, against tsrs's ~2 MiB.
- The other ranges: one heap finger per thread, plus large blocks.

### The RSS cost per range, and why Rig's huge pages raised RSS where tsrs's did not

A range backed by huge pages pins whole 2 MiB windows wherever it is written:

| range | huge-page RSS cost | evidence |
|---|---|---|
| tsrs thread arena / Rig heap segment (one finger) | ≤ 2 MiB, avg ~1 MiB per thread | residency-32: 0.6-0.7 MiB/arena; seg: +0.1-2.0 MB |
| a Trig push-dense Table past 2 MiB (one finger each, ~4-10 per checker) | avg ~1 MiB per Table | `table-prefault` arm 5/6 (frontier windows only): +5 MB at 1 checker, +15 MB at 4 (383 → 398 MB, 3.9%) |
| a sparse link Table, per touched window | 2 MiB − ~0.25 MiB | arm 3 (all tails) vs arm 6 (push-only): +20 MB more at 4 checkers (398 → 418) |
| a head (first 2 MiB), if advised | 2 MiB − 0.23 MiB, per Table written | `archive/kernel-leads` lead 1: "about 2 MiB of RSS for each Table a checker writes", 27% to 408% more peak RSS |

**So yes, this is the reason.** tsrs has *one* finger per thread, and all its kinds of record are interleaved in one
dense range. Trig has ~36 fingers and 7 sparse ranges per checker. With huge pages:

- the RSS floor is about the number of large dense Tables × 1 MiB, plus about 1.75 MiB per sparse window touched;
- so "huge pages at no RSS cost" is impossible for Trig's present layout, whoever decides when to advise.

The tail-on-huge, head-on-small design is already the best density threshold for many separate ranges. It is why main
with its gate open costs only 5% (ts-pattern 1 checker quiet 259 vs 247 MB gate shut, table-huge.md).

## 3. How much of the gap is huge pages and how much is bytes touched

**The "1.6×" is out of date.** It is peak RSS from 2026-10-22, ts-pattern at one checker: 327 vs 207 MB
(RESULTS.md line 911). Since then Trig's memory work (#209-#216, #211, the checker drop) has closed it. Today
(`scaling/investigation.md` §1, §3, 2026-11-04):

| ts-pattern | Trig | tsrs Go mode | ratio |
|---|---:|---:|---:|
| anonymous memory, 1 checker | 150 MiB | 152 MiB | 0.99× |
| anonymous memory, 8 checkers | 220 MiB | 230 MiB | 0.96× |
| of it on huge pages, 1 / 8 checkers | 72 / 46 MiB (48% / 21%) | 100 / 138 MiB (66% / 60%) | |
| peak RSS, 1 / 8 checkers | 216 / 264 MiB | 207 / 242 MiB | 1.04× / 1.09× |
| mappings, 8 checkers | 1,304 | 107 | |

The peak-RSS remainder (9-22 MiB) is mostly file-backed: the embedded pre-built libs and a larger binary. That is not
anonymous bytes touched.

**Bound.**

- **Bytes touched: about 0% of the gap.** It is not a lever.
- **Page size and layout: all of it.** Measured shares (investigation §2, §4; exit/os.md), ts-pattern:
  - **1 checker:** faults plus `madvise`-populate are 5.56% of cycles against tsrs's 4.66%, 0.9 points. The exit is
    13.1 against 6.8 ms, about 0.5% of wall. Total ≈ **1.5%**.
  - **8 checkers:** 9.8% against 5.1%, 4.7 points of cycles. The exit is 25 against 11-12 ms, about 3% of a 435 ms wall.
    The zero-page shootdowns are 0.4%. Total ≈ **7-8%**.
  - Page walks add 3-4 points on E-cores, and about nothing on P-cores (panels/table-arena).
- **Where it sits.** At 8 checkers most of it is in the **heads**: 95 MiB on 4 KiB pages, against tsrs's 92 MiB of
  4 KiB in all (os.md: 174 vs 92 MiB on 4 KiB at 8 checkers). At one checker it is in the **tails**, and the tails
  get huge pages only when the reserve-time gate is open.
- **Scope.** The scoreboard (RESULTS 2026-11-05, P-cores) has Trig at parity on one thread (ts-pattern 0.97-1.02).
  The all-cores gap is mostly file assignment and idle time (research 29). The ~7% layout share at 8 checkers is the
  part of it that is Rig's.

## 4. Designs

### D1. NEW: a typed record arena (one finger per checker, tsrs's layout, no read test). Top recommendation.

**What.** A std/language type, `Arena[n]` (name the owner's), with:

- `!a.push(x)` → `Ref[T, n]`, a 32-bit word offset typed by its record;
- `a[r]`, which reads `T` at `base + r*8`;
- `!a[r].f = v`, which writes inside a record already written.

It reserves `n` words like a reserved Table, from `reserveTable` (`alloc.zig:987`). Records are 8-aligned plain data
whose default is all zeros (`fillsWithZeros`, `table.zig:62`).

**Why it is sound, and why it needs no read test.**

- A `Ref` is bounded below `n` by its type, as `Slot[n]` is. An arena never moves, so a read is a plain load.
- A `Ref` from one arena read in another of the same `n` reads zeros, under the same rule that makes a `Slot[n]` of
  one Table good in any other.
- It is a CORE §10 paragraph ("Tables"), so CORE first, with the owner.

**What is different from the closed attempts.**

- `archive/table-arena` packed *Tables* that must answer any index below `n`. That forces a `cap` test on every read
  (14-18% more instructions).
- Here no Table is packed. *Records* are, each named by a handle that exists only because its push wrote it.
- tsrs's `P<T>` is exactly this, and the read is no more instructions than a Table read: one `lea` for a 24-byte
  record where `base + i*24` takes two.

**How Trig would use it.** Trig moves its ~36 push-dense Tables into one arena per checker; its link Tables stay
keyed Tables. Then:

- the heads go from 43 per checker to about 8 (1 arena + 7 links);
- the arena's head fills in the first milliseconds, so almost all of its memory lies past 2 MiB and is dense.

**Expected gain** (bounded by measured shares, not more):

- ts-pattern on P-cores: up to about 1.5% at one checker and 5-7% at 4-8 checkers. investigation.md fix 1 put the
  ceiling for density, page walks included, at 9.6% / 10.4% at 4 / 8 checkers, E-cores.
- Only with free 2 MiB blocks for the huge part. With none, it still saves mappings (1,304 → about 150), page tables
  (3.4 → about 1 MiB) and their teardown, worth about 1 ms (os.md).

**RSS.**

- Against main with the gate shut: one frontier window per checker, about 1 MiB more per checker (0.5% more at 1 checker,
  3% more at 8 on ts-pattern).
- Against main with the gate open: lower, since ~4-10 Table frontiers become one.
- The heads' 4 KiB slack is unchanged (negligible).

**Risks.**

- It is a language feature and a large Trig refactor (TypeId becomes a word offset).
- Records holding owned values are excluded.
- One arena means one write lend for the whole store at a time: Trig's push sites must not hold a view of one record
  across a push of another, which is the loan rule a Table already has.

**Measurement, first step (cheap, no language work).** A ceiling arm that produces the arena's memory shape with
Trig's code unchanged:

- a Trig build whose push-dense Table capacities are right-sized to ts-pattern ×2 (experiment only);
- `reserveTable` handing out ranges at 4 KiB rather than 2 MiB granularity (`alloc.zig:990`), with the push Tables'
  region advised `HUGEPAGE` whole and the link Tables kept `NOHUGEPAGE`.

Their heads then share windows as one arena's would. Run time-ab on pup at 1/4/8 checkers on P-cores, at quiet,
leave35 and natural levels, with faults, `AnonHugePages`, mappings, VmPTE, exit and peak RSS. If the ceiling is under
the bar, D1 is dead before the CORE round.

### D2. NEW: a hook-free just-in-time window advice: a guard window at each Table's frontier

**What.** jit (table-huge.md) gave per-window decisions with no stalls (0 in 240 runs), but its hook in `push` cost
0.8% of instructions by outlining 5 more `push` bodies. Move the hook into the MMU instead:

- `reserveTable` maps a Table's tail `PROT_NONE`.
- The runtime's SIGSEGV handler, which already exists and chains (`runtime.zig:7049-7063, 7448-7465`), takes a fault
  in a Table region. It `mprotect`s the faulting window read-write and advises it `HUGEPAGE` if `hugeFreeFor(1)`
  (floor 8, a current reading, never a stall) and the window is the frontier's next. Otherwise it stays 4 KiB: a
  sparse link window, or no free blocks.
- `push` is untouched.

**Cost.** About 5-10 µs per window crossed: 47 on ts-pattern at one checker (0.05%), up to about 870 at eight across
threads. A frontier window opened next to the read-write range merges with it, so no new VMA.

**Gain, by its share.** jit's Table windows were worth about 2.2% gross on ts-pattern where the gate is shut but blocks
exist: hybrid's 1.4% net at leave35, plus its 0.8% hook. Nothing at about 6 free blocks, and level when quiet if the
handler also grants sparse windows above the 64-spare level. It does nothing for the heads, so little at 4-8 checkers.

**RSS.** jit's: 1.3-1.5% more at one checker on ts-pattern, about 3.9% more at four (the arm 5/6 frontier slack). That is the
same as main pays when its gate is open, and the owner's trade.

**Risks.**

- A syscall that writes into an unopened window (`read(2)` into a Table's `items()` slice) gets `EFAULT`, not a fault.
  This needs a pre-open in any std path that hands a Table's memory to the kernel.
- `mprotect` takes `mmap_lock` for writing while checkers run.
- Signals interact with preemption and with `RIG_SANITIZE`'s handler.
- `userfaultfd` (`UFFD_USER_MODE_ONLY`) is the cleaner kernel form, but per-window unregistering splits VMAs.

**Measurement.** First a micro model: `tabjit.c` with a guard arm, on pup at natural, light and quiet levels. Then a
Trig A/B against main at leave35 and 6 free blocks.

### D3. IMPROVED of kernel-leads lead 2: huge pages exactly over the large-block windows that prefault already commits

**What.** `allocLarge` (`alloc.zig:488-506`) populates `likelyFilled` (3/4 of the block, up to 8 MiB) when the heap
faults ahead. Those bytes are resident anyway. Change it to:

- align blocks from 2 MiB rather than 16 (`mapLarge`, 523);
- advise `HUGEPAGE` only the whole windows inside the populated prefix, populate them, then set them back to
  `NOHUGEPAGE`. The THPs stay, and the VMA is uniform again, so `remap`'s `mremap` (1490), which needs one VMA, still
  works.

The tail stays 4 KiB. Lead 2 advised whole blocks: 0.96% more RSS.

**Gain.** Zero RSS by construction, but small: blocks of 2-16 MiB take about 6.7K faults on ts-pattern at one checker
(fault-ahead/kernel.md §4). That is about 1,300 cycles saved per 4 KiB populated, **≈ 0.2%**.

**Verdict.** DROP unless it is stacked with others. Below the bar alone.

### D4. RETRY-lite of lead 3: advise a heap's second and later segments even when it does not fault ahead

**What.** Lead 3 *prefaulted* the first segment of every heap: +1.2-34% RSS, because prefault commits. Advice alone
commits nothing until a page is touched, and carving is in order, so the only slack is the frontier window. This means
decoupling `adviseHuge` from `faultsAhead` in `newPage` (`alloc.zig:326`) from the second segment on, with floor 8,
as tsrs does from its second chunk.

**Gain.** It helps only checker heaps of 4-8 MiB at 4-8 checkers: at most ~1%, likely less.

**RSS.** At most 2 MiB (about 1 on average) per heap past 4 MiB.

**Verdict.** Low priority; measure only stacked with D1 or D2.

### Candidates of the brief, checked

- **One shared bump arena per checker that small Tables live in.** As stated, DROP: a Table in a shared arena must
  answer any index below `n`, which is the closed `archive/table-arena` (read test, 6-12% slower). D1 is the form that
  works: records, not Tables.
- **Tables grouped into one huge-page-backed region.** Already built (`table_regions`, #832). Adjacency does not
  help, since each Table spans `n` slots of address space, so its head is 24 MiB+ from the next. DROP.
- **Huge pages for a Table only once it passes 2 MiB filled.** This is main's design (head small, tail huge), decided
  at reserve behind a 64-spare gate. Its per-window form needs a hook (jit, closed) or the MMU (D2). Its RSS floor is
  ~1 MiB per large Table (§2), not zero.
- **Segment size and alignment.** Segments are already one dense finger, aligned and advised (seg landed). Larger or
  doubling segments change only a few dozen syscalls a run. No share. DROP.
- **A head offset**, starting a Table 256 KiB before a 2 MiB boundary so it goes huge sooner. It moves more Tables
  (the 0.23 MiB heads) into frontier slack and raises RSS. DROP.
- **Link Tables never huge.** It saves main's quiet-state sparse windows (about 5 MB per checker at 4 checkers), but
  jit's quiet loss of 1.8% came partly from those windows: their TLB reach helps random reads. Not free. Trig's lever
  is denser link ids (per-checker numbering).
- **Trig-side, no Rig change.** Fewer Tables: merge the list arenas of 4-byte ids, and number link slots per checker.
  table-arena.md said the same. It is the poor man's D1, and it helps under every page size.

## 5. Ranking

1. **D1, the record arena (NEW).** The only design whose RSS floor is tsrs's: one window per checker. It addresses
   the heads, where the 4-8-checker share sits. Run the cheap ceiling arm first; CORE and the owner come after the
   number.
2. **D2, guard-window JIT (NEW).** jit's gain without its 0.8%. One-checker share, about 2% gross where some blocks are
   free. Higher risk (signals, syscalls into Tables).
3. **D4 and D3:** small; only stacked.
4. **Machine setting, not Rig's:** 64 KiB mTHP would cut the heads' faults 16-fold with no 2 MiB slack. It is off on
   pup and on default systems.
