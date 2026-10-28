# Table fault-ahead, and why fewer faults did not make Trig faster (2026-10-28)

A reserved Table faulted in the 64 KiB past each push with one
`MADV_POPULATE_WRITE` (branch `table-ahead`, archived as
`archive/table-ahead`). The memory-traffic study
([../memory-traffic.md](../memory-traffic.md)) had measured 2.7% fewer
cycles for it. Built into the runtime and timed on pup, Trig 20
interleaved rounds against main, it gave ts-pattern 65% fewer page faults
and 6.3% fewer kernel cycles, but only 0.4% fewer cycles in all, with 1.8%
more instructions and 0.5% more peak memory (zod3: 43% fewer faults, 0.7%
fewer cycles, 1.9% more peak memory). Two experts found why
([kernel.md](kernel.md), [user.md](user.md)):

- **Populating a page saves only its trap.** The kernel still takes each
  4 KiB page through `handle_mm_fault`: page allocation, the page-table
  lock, memcg, the LRU, the swap-throttle check (pup has swap on), and
  zeroing. An avoided fault saved about 850 of the 5,000-5,600 kernel
  cycles a fresh page costs Trig.
- **The check cost the rest.** Testing the frontier in `push` made it too
  large to inline: 877 calls where main inlined 113, about 19 instructions
  more on each of 8.5 million pushes. With a free check (`len >= limit` in
  place of `len == n`) the ceiling is 0.9% on ts-pattern, under the bar.
- **The experiment's 2.7%** compared two arms of one binary whose base arm
  already paid the call; against the plain build, its gain was 0.1-1.1%.
- **The gap is page size.** Trig and tsrs touch about 210 MiB alike, Trig
  in 53,600 pages of 4 KiB and tsrs with 129 MiB in 63 pages of 2 MiB:
  Trig spends 320M kernel cycles on ts-pattern, tsrs 174M. Huge pages for
  table memory past each table's first 2 MiB (about 55M fewer, for about
  9 MiB more peak) and for the allocator's segments still in 4 KiB pages
  (about 45M fewer) would close it; the owner approved both (2026-10-28).
