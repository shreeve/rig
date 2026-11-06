# Huge-pages panel, lens: Linux (7.0 mm, THP, compaction, fault path, teardown)

Rig `origin/main` `9d73afdf1`, read only. No experiment was run: pup was
out of reach, and the Mac has no THP for user memory, so a Mac probe would
say nothing about this lens. Every Linux number below comes from the
records. Kernel code was checked against mainline `mm/huge_memory.c` and
`mm/mempolicy.c`, and the quotes below are from those files. Scratch:
the panel's scratch folder (not kept)
(empty).

## 0. Short answer

- **Why tsrs gets huge pages and Rig's Tables do not.** tsrs asks every
  time, with no gate (`reserve.rs` `commit`: `madvise(MADV_HUGEPAGE)` and
  then `mprotect`, one 2 MiB chunk at a time, just before its bump pointer
  reaches the chunk). Its faults take the free 2 MiB blocks first. After
  that they compact in the fault, and on pup's natural, build-made
  fragmentation that compaction often succeeds. tsrs plays that lottery and
  pays for it inside its own kernel time. When the lottery fails, tsrs takes
  35.9K faults rather than 15.6K and is 6% slower (Trig RESULTS.md:1735).
  Rig's Table gate (`hugeFree`, alloc.zig:597; `huge_spare` 64,
  alloc.zig:568) is all or nothing and judged once, at reserve. pup sits at
  30-140 free blocks, so the gate is shut in most runs, and the Tables then
  take none of the free blocks there are.
- **No stall-free way to get a 2 MiB page beyond the free blocks exists in
  7.0 for anonymous memory under `enabled=madvise`.** Every way to get one
  goes through `vma_thp_gfp_mask`, which gives a madvised range
  `__GFP_DIRECT_RECLAIM` under `defrag=madvise`. That covers the fault,
  `MADV_POPULATE_WRITE`, `MAP_POPULATE` and khugepaged; `MADV_COLLAPSE`
  always uses `GFP_TRANSHUGE`. User space cannot reach `__GFP_NORETRY`.
  mTHP is set in sysfs only. The prctl modes can only disable. So the free
  blocks a reading shows are the only stall-free supply. The question is
  whether Rig takes all of them, and today it does not.
- **The earlier attempts were not premature on the kernel side.** pup ran
  7.0.0-38 then as now, and nothing relevant has landed since. They were
  incomplete in two ways. The Table gate does not spend from its reading
  (the segments' gate does), and it decides at reserve, not at growth.
  Where the gate is shut, the hook at growth (jit) cost 0.8% of
  instructions through `push`'s inlining. A hook off the push path was
  never built.
- **New, outside pup: Rig misreads two THP modes.** Under `enabled=always`
  (the Fedora, RHEL and Arch defaults), the kernel gives an unadvised range
  huge pages with no stall. There Rig's `MADV_HUGEPAGE` adds the stall, and
  its unadvised segment region and large blocks get huge pages Rig meant to
  keep small. This changes nothing on pup.
- **Exit.** PMD mappings could remove about 6-8 ms of Trig's 22 ms at eight
  checkers (2-3% of 0.275 s), and only in runs with about 30 or more free
  blocks to spare. About half of what is resident on small pages sits in
  Tables' first 2 MiB windows. That memory cannot go huge without raising
  RSS by up to 2 MiB a Table, which is about 344 Tables at eight checkers.

## 1. How a Rig request meets the 7.0 fault path

### When the PMD path is taken

`__handle_mm_fault` calls `create_huge_pmd` → `do_huge_pmd_anonymous_page`
only when all of these hold:

- the PMD is none: no 4 KiB page of that 2 MiB has been faulted yet;
- `thp_vma_allowable_order` passes. Under `enabled=madvise` this needs
  `VM_HUGEPAGE`, no `VM_NOHUGEPAGE`, and no prctl disable;
- the aligned 2 MiB lies inside one VMA (`thp_vma_suitable_order`).

Rig satisfies all three where it asks:

- **Segments** are 4 MiB, 4 MiB-aligned in one 64 GiB region
  (alloc.zig:899-913). `adviseHuge` (alloc.zig:546) splits the region's VMA
  per segment, and neighbouring advised segments merge again. The
  `MADV_POPULATE_WRITE` of the first 1 MiB (alloc.zig:328) takes the PMD
  path, so a 2 MiB folio arrives with the first populate.
- **Tables** come from 2 MiB-aligned ranges of a region advised
  `NOHUGEPAGE` (alloc.zig:1057). When the gate is open, `[start+2M, end)` is
  advised `HUGEPAGE` (alloc.zig:996-998).
- **Large blocks** of 16 MiB or more are aligned by `mapLarge`
  (alloc.zig:524). Since 6.7, and restricted in 6.12 to lengths that are a
  multiple of 2 MiB, 7.0 aligns such anonymous mappings by itself, which the
  code's comment notes.

A read of an unwritten advised window maps the huge zero page; the write
that follows allocates a THP in recent kernels. If Trig ever reads Table
slots past `len` before writing them, `thp_zero_page_alloc` and
`thp_fault_fallback` will show it. That check costs nothing when pup
returns.

### What one fault asks the allocator for (`mm/huge_memory.c`, `vma_thp_gfp_mask`)

| `defrag` | advised range | unadvised range (`enabled=always` only) |
|---|---|---|
| `always` | `GFP_TRANSHUGE` (direct reclaim and compaction, retried) | `GFP_TRANSHUGE \| __GFP_NORETRY` (compacts once) |
| `defer` | `GFP_TRANSHUGE_LIGHT \| __GFP_KSWAPD_RECLAIM`: never stalls, wakes kcompactd | the same |
| `defer+madvise` | direct reclaim | kswapd only: never stalls |
| **`madvise`** (pup, Ubuntu) | **`GFP_TRANSHUGE_LIGHT \| __GFP_DIRECT_RECLAIM`** | `GFP_TRANSHUGE_LIGHT`: free block or fall back, never stalls |
| `never` | `GFP_TRANSHUGE_LIGHT` | the same |

### Why a failed stall costs so much on pup (`mm/mempolicy.c`, `alloc_pages_mpol`)

A PMD-order allocation under the default policy is tried twice:

1. `gfp | __GFP_THISNODE | __GFP_NORETRY` on the local node: async
   compaction, giving up on SKIPPED or DEFERRED;
2. if it fails and the gfp has `__GFP_DIRECT_RECLAIM` (madvised), the full
   gfp again, on all nodes: async compaction, then direct reclaim, then
   sync-light compaction. Not being `__GFP_RETRY_MAYFAIL`, it then gives up.

On one node the second try repeats the first with more effort. A fault that
finds no free block can therefore run compaction up to four times, with a
reclaim pass between, before it falls back to a 4 KiB page. That is the
"failed compaction stall". The records put a price on it:

- Trig's old `hugepages` branch: 360 stalls cost 0.29 s of system time
  (0.15 → 0.44 s), about 0.8 ms each;
- the micro test (thp-fragmented.md): 64 MiB took 904 ms at the heavy
  level, up to 28 ms per 2 MiB fault, and still ended in small pages.

A successful huge page saves:

- about 511 small faults: 2.2-2.5 µs each at four checkers on E-cores, or
  about 5,000 kernel cycles each (fault-ahead/kernel.md, four-checkers
  kernel.md), which is about 0.5-1 ms;
- about 0.25 ms of exit (§4);
- plus TLB reach.

**So asking beyond the free blocks pays only while direct compaction
succeeds more than about half the time.** Rig's synthetic `frag.c` makes it
fail almost always. pup's natural fragmentation sometimes lets it succeed,
and that is where tsrs gets its huge pages. Rig rightly declines to depend
on it: it is a lottery, and it depends on the machine.

### What the buddyinfo reading misses

`freeHugeBlocks` (alloc.zig:719) adds up the blocks of order 9 and above,
DMA excluded, over every zone and node. The cases:

- **Migratetypes.** It counts every migratetype. A movable THP request may
  take a whole free pageblock of another type (`__rmqueue_fallback` allows
  stealing whole pageblocks even under `ALLOC_NOFRAGMENT`), so the count is
  right. The exception is `MIGRATE_HIGHATOMIC` reserves, which are not
  usable. They are a small overcount, usually zero.
  `/proc/pagetypeinfo`, which would show the types, is root-only.
- **Per-CPU THP lists.** Since 5.14 the pcp lists hold order-9 pages, so a
  THP freed by an exiting run waits on that CPU's list, invisible to
  buddyinfo. That is an undercount of about one block per CPU. It does not
  matter.
- **Watermarks and the DMA32 `lowmem_reserve`.** With GiBs free, as on pup,
  neither binds. On a small machine they would, but such a machine has no
  free blocks anyway.
- **Nodes: a real misjudgment, though not on pup.** The first try is
  `__GFP_THISNODE` on the local node. On a two-socket host whose free blocks
  are all on the other node, the summed count opens the gate, yet every
  fault first compacts locally (NORETRY, async) and only then takes the
  remote block. **Fix:** count only the node of the asking thread
  (`getcpu`, then its `Node N` lines). pup has one node, so this is
  correctness for users and does nothing for the race.
- **Not counting, but judging.** The reading is taken at reserve, for a
  Table that grows over seconds (the known gap). And `hugeFree` never spends
  from the kept reading (alloc.zig:597-600), while `hugeFreeFor` does
  (alloc.zig:608-613). So every checker's burst of 43 Tables is judged on
  one reading. That is harmless at the spare of 64, since the need is about
  50 windows at one checker and about 30 at four (four-checkers kernel.md:
  15.5K Table pages went huge). But it is why the spare must equal the whole
  program's need, which shuts the gate at pup's usual 30-64.

### Why pup has so few free blocks with 14 GB free (hypothesis)

table-huge.md saw 18 free 2 MiB blocks with 14 GB free, and 1,953 free
1 MiB blocks. That pattern means pageblocks pinned by unmovable pages,
which neither `compact_memory` nor kcompactd can move. pup runs ZFS. The ARC
is unmovable kernel memory spread across all of RAM, and `drop_caches`
shrinks it only partly. An ext4 desktop's page cache is movable and compacts
well. If this holds, pup is more fragmented than a typical user's machine,
and in a way that compaction cannot fix. **Check** as root on pup:

- `/proc/pagetypeinfo` (unmovable pageblocks with free pages);
- `arcstats` `size`;
- `compact_*` in vmstat after a `compact_memory`.

## 2. Kernel features, one by one

| Feature | What it does for Rig | Verdict |
|---|---|---|
| prctl `PR_SET_THP_DISABLE` with `PR_THP_DISABLE_EXCEPT_ADVISED` (merged in the second half of 2025; I believe 6.18, not confirmed) | lets a process under `enabled=always` act as `madvise`. It only disables and changes no `defrag`. tsrs's notes: disabling costs 4-10% | DROP |
| per-process or per-VMA defrag policy | does not exist in 7.0. The BPF THP-order work was RFC-stage as far as I know; it would need `CAP_BPF` in any case | DROP |
| mTHP (`hugepages-64kB/enabled`) | the right tool for the Tables' first windows: 16 times fewer faults, folio frees and swap-throttle checks, with no 2 MiB slack. Order-4 blocks are plentiful (thousands on pup). On Intel it gives no TLB gain (no contiguous-PTE coalescing). It is **per system only**: sysfs, root, `never` on pup and Ubuntu, and no prctl turns it on. Turning it on for the race would be a machine state users do not have | DROP for Rig. Worth one line in the docs for users who administer their own machines |
| `MADV_COLLAPSE` | synchronous and always `GFP_TRANSHUGE`; it copies. Measured at 33 ms per 64 MiB quiet (against 5.9 ms for huge faults and 15.7 ms for small pages), and it fails when fragmented | DROP (closed; nothing new) |
| `MAP_POPULATE`, `MADV_POPULATE_WRITE` on advised ranges | the same fault path and the same gfp, so the same stall. Populating moves only the trap (fault-ahead/kernel.md: about 850 cycles per page). Segments already populate | nothing new |
| `__GFP_NORETRY` | user space cannot reach it. On a madvised range the first `THISNODE` try already has it; the stall is the second try | n/a |
| `vm.defrag_mode` (6.15) and `compaction_proactiveness` | system sysctls. Proactive compaction on pup cannot move unmovable pageblocks either | DROP (admin) |
| khugepaged | scans 4096 pages every 10 s by default, too slow for a 0.3 s run. Its compaction runs in its own thread, but it collapses by copying | DROP |
| hugetlbfs, `MAP_HUGETLB` | needs `nr_hugepages` or `nr_overcommit_hugepages` from root; both are 0 by default, so mmap fails. Hugetlb pages are also left out of RssAnon and of rusage maxrss, so using them would **hide memory from the RSS measurement**. That fails the honesty rule | DROP |
| tmpfs `huge=always` with an unadvised `MAP_SHARED` mapping | the one stall-free "huge only if free" mode in the kernel: shmem uses `vma_thp_gfp_mask`, and an unadvised range under `defrag=madvise` gets `GFP_TRANSHUGE_LIGHT`. But it needs a tmpfs mount with `huge=`: root, or a user namespace, which Ubuntu 24.04's AppArmor restricts. Memory would show as RssShmem | DROP: say it exists |
| `userfaultfd` with `UFFD_USER_MODE_ONLY`, as a growth hook with no push test | possible unprivileged, but a thread, two context switches per window, a VMA split per window, and SIGBUS on any kernel-mode access to a Table (`read(2)` into it). Docker's seccomp profile blocks it | DROP |
| `process_madvise` on self (6.13+) with batched DONTNEED TLB flushes | saves system calls and shootdowns on the Tables' give-back: under 1 ms (os.md) | DROP |

## 3. Proposals

### P1 (IMPROVED): Tables advised at growth by a sampler off the push path, spending from the reading

**What.** jit's idea, the fork the records never built: the check moves out
of `push` and into a path that is already cold.

- **The registry.** `reserveTable` (alloc.zig:987) records each range in a
  small array beside `table_regions`: `{start, end, advised_to}`, under
  `tables_lock`. It advises nothing at reserve. The region stays
  `NOHUGEPAGE`, as now.
- **The check.** It runs where the allocator already makes a system call:
  the 1 MiB populate stretch in `newPage` (alloc.zig:316, `s.used %
  pages_per_prefault == 0`), and `allocLarge`/`remap` (alloc.zig:501). It
  looks at a few registered ranges round-robin. For a range whose frontier
  has reached `advised_to − 2 MiB` (by `mincore` of that window's first
  page, about 0.5-1 µs), it advises the next W windows `HUGEPAGE`. W
  doubles with what the Table has filled: 1, 2, 4, and so on. Advised
  windows the Table never reaches cost no memory.
- **The budget.** It advises only if `hugeFreeFor(W)` passes: floor 8, and
  W spent from the kept reading (alloc.zig:608).
- **The unadvised remainder.** A Table that outruns its advice faults small
  pages there: a missed gain, never a stall.
- **Give-back.** `unreserveTable` already re-advises `NOHUGEPAGE`
  (alloc.zig:1016).

This takes min(need, free − floor) blocks without ever asking beyond the
reading. That is the stall-free maximum the kernel allows. It adds no
instruction to `push` and no field to a Table.

**Expected gain.** The prize is the measured gap between an open and a shut
Table gate: ts-pattern 3.1% faster at one checker and 2.3% at four on
E-cores (four-checkers kernel.md), 3.9 points quiet (thp-fragmented.md);
zod3 about 0. At pup's usual 30-140 free, the sampler gets most of the
roughly 30-50 windows needed, so about 1.5-3% on ts-pattern and 0 on zod3.
**This is marginal against the bar.** hybrid, the nearest built form, gave
1.4% on ts-pattern and was 0.8% slower on zod3.

**RSS.** As main's when the gate is open: 12 MB on ts-pattern at one
checker (271 against 259 MB, 4.6%), and about 14% at four (four-checkers
kernel.md), from each growing Table's partly filled last window. **This
raises peak RSS wherever today's gate is shut, so it is the owner's
trade.**

**Risks:**

- the frontier can pass an unadvised window between checks (lost gain only);
- `mincore` in a busy loop is cheap but not free;
- the registry must be right about Tables dropped and reused.

**Settle.** The arm against main on pup, quiet and at frag LEAVE=35 and 55,
20 interleaved rounds, at one and four checkers. Count `compact_stall`
(must be 0 of its own), `thp_fault_alloc`, instructions (must be level) and
RSS. **First step:** before building, one pup run of main with the gate
forced open at 30-60 free, counting Table windows faulted. That bounds the
prize at today's state in an hour.

### P2 (NEW): read the THP mode once and act on it

**Where.** A `thpMode()` read once from
`/sys/kernel/mm/transparent_hugepage/{enabled,defrag}`, used in
`adviseHuge` (alloc.zig:546), `hugeFree` (alloc.zig:597), `reserveRegion`
(alloc.zig:899), `newTableRegion` (alloc.zig:1053) and `table.zig`'s
`reserve` (table.zig:118):

- `enabled=never`: no buddyinfo read at all.
- `defrag` is `defer` or `never`: advise with no gate. It never stalls,
  and `defer` wakes kcompactd. This was thp-fragmented.md's candidate 1,
  kept as a short cut.
- `enabled=always` with `defrag` `madvise` or `defer+madvise`:
  - **advise nothing** where Rig wants huge pages: the kernel takes free
    blocks with `GFP_TRANSHUGE_LIGHT` and never stalls;
  - `NOHUGEPAGE` only where Rig wants small pages: each Table's first
    window, segments of heaps that do not fault ahead, and large blocks
    under 16 MiB.
  - **Caveat:** madvise has no "clear both flags". A range given back after
    `NOHUGEPAGE` must be remapped with `MAP_FIXED` to return to neutral, as
    tsrs's `decommit` does.
- Every other mode: today's gate.

**Gain.** None on pup (`madvise`/`madvise`).

- On `enabled=always` systems it removes Rig-made stalls (today Rig advises
  when the gate opens and turns a stall-free huge page into a compacting
  one).
- It gets the Tables huge pages there with no gate.
- It restores Rig's own RSS intent: today the unadvised segment region and
  large blocks over 2 MiB get THP on such systems, which alloc-thp16
  measured as higher peak memory.

**RSS.** Lower than today on those systems.

**Settle.** Rig's unit tests with a fake sysfs, as the buddyinfo tests do,
plus one run on an `enabled=always` VM or container host (not burst). No
Trig gate is needed beyond the usual.

### P3 (NEW, small): count the asking thread's node only

As described in §1, in `freeHugeBlocks` (alloc.zig:719): `getcpu`, then
sum only the lines of that node. Correctness on NUMA servers, with no pup
effect. Settle with a unit test with a two-node buddyinfo.

### P4 (measurement, top): settle why tsrs wins on pup before building anything

One pup slot, at quiet, natural and LEAVE=35:

1. **tsrs and Trig side by side**, with vmstat deltas `compact_stall`,
   `compact_success`, `compact_fail`, `thp_fault_alloc` and
   `thp_fault_fallback`, and kernel cycles. This settles whether tsrs's huge
   pages come from free blocks (P1 can match them) or from successful
   compaction (P1 cannot, and Rig should not chase them).
2. **smaps of Trig at eight checkers at its peak**: `Rss` and
   `AnonHugePages` per region (segments, Tables' first windows, Tables past
   them, large blocks). This bounds §4's exit prize.
3. **As root:** `/proc/pagetypeinfo` and ZFS `arcstats`, to name pup's
   fragmentation.

### DROP (nothing new)

- asking always (tsrs's way): measured 3.9-96% slower at fragmented levels;
- spares below 64 at reserve (thp-spare.md);
- `MADV_COLLAPSE`, the breaker, and stash on one core (table-huge.md);
- every kernel feature in §2.

## 4. Exit teardown: what PMD mappings would remove

- **Rates** (os.md): 0.087 ms/MiB at one checker, 0.124-0.135 ms/MiB at
  four and eight. A huge page frees for about 1-3 µs (one PMD, one folio,
  one buddy free): about 0.001 ms/MiB. Moving X MiB to PMD saves about
  0.12·X ms at eight checkers.
- **Trig at eight:** 174 MiB on small pages, about 22 ms (os.md). For
  comparison, tsrs has 92 MiB small and exits in 10.8 ms.
- **What can go huge without RSS growth:**
  - **Tables past their first window.** At four checkers with the gate
    open, 15.5K Table pages (60 MiB) went huge. Take about 50-60 MiB at
    eight: **6-7.5 ms**.
  - **Segments.** Already huge at floor 8 whenever 10 or more blocks are
    free, so little is left.
  - **Large blocks of 2-16 MiB.** Small pages by design (alloc-thp16, for
    RSS). About 1-2 ms.
  - **Tables' first windows.** At four checkers they took 21K faults, about
    82 MiB over 172 Tables, about 0.5 MiB each; at eight, about 344 Tables.
    Huge pages there would cost up to 2 MiB a Table, hundreds of MB. Only
    mTHP (admin) or packing the small Tables densely (the table-arena
    panel's density condition) fixes this share.
- **Total:** about 6-8 ms of the 22 ms, 2-3% of ts-pattern's 0.275 s at
  eight checkers. It needs about 30 blocks free for the Tables beyond the
  segments', and it is the same prize as P1's (the same windows), not an
  extra one. It is part of P1's measured gain, never added to it.
- **About half of the gap to tsrs's exit is out of reach** of any huge-page
  policy that keeps RSS level.

## 5. Were the earlier attempts premature?

- **Kernel: no.** pup was on 7.0 throughout, and no stall-free mechanism
  has appeared since, as §2 shows.
- **The spare of 64: right for a gate decided at reserve.** It equals the
  program's need. thp-spare showed that 32 stalls when a run drains the
  blocks. What was missing is a gate that need not equal the whole need: a
  per-window spend, P1.
- **jit: right in form, wrong in where its hook sat.** Its 0.8% came from
  `push`'s inlining, not from the kernel. P1 is the same policy with the
  hook moved to the allocator's cold populate path. That has not been tried.
- **The buddyinfo reading: about right on pup;** wrong on NUMA (P3). The
  real misjudgment is elsewhere: Rig's synthetic fragmenter defeats
  compaction, pup's natural state sometimes does not, and tsrs profits from
  that difference.

## 6. Top recommendation

P4 first: one slot, three counters, no code. Build P1 only if P4 shows
pup's natural free blocks cover at least about 30 Table windows in most
runs, and only with the owner's yes on the RSS trade (4.6% at one checker,
about 14% at four, where today's gate is shut). P2 and P3 are small
correctness changes for users' machines, worth landing on their own merits,
with no claim of speed on pup.

Sources for the kernel version of the prctl flag:
[patchew, man-page patch](https://patchew.org/linux/20250901160903.2801339-1-usamaarif642@gmail.com),
[LKML v2](https://lkml.iu.edu/2511.0/08484.html). Kernel code from
mainline `mm/huge_memory.c` (`vma_thp_gfp_mask`,
`vma_alloc_anon_folio_pmd`) and `mm/mempolicy.c` (`alloc_pages_mpol`).
