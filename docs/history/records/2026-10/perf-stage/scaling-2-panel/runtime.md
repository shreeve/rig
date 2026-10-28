# Workers panel: the runtime and memory (2026-10-28)

Traces on pup (E-cores 12-15, ts-pattern), in
`/zfs/worktrees/rig/scaling-2/panel-runtime/`.

**1. `mremap` is not the IPI source.** By each flush's kernel stack,
about 1,230 of the check's 1,400 shootdowns are copy-on-write breaks of
the zero page (`wp_page_copy`): a Table slot read before it is written.
`rig.alloc.remap` makes 148 (10%). At about 10 µs of CPU per shootdown,
all of them cost about 3 ms of wall at four, and `mremap` about 0.4 ms.
Keep `mremap`: it lowered peak memory 2.8%. mimalloc (tsrs) copies.

**2. Exit without the drops.** The drops after the output take 13.5 ms
on one thread, then `exit_group` takes 6.5 ms to unmap (tsrs takes
7-8). About two thirds of the drops' cost is freeing pages, which exit does anyway. Skipping the drops saves about 5-8 ms at four and
2-4 ms at one, not 12-14. `os.exit` already skips them, but it skips
the leak check too. The proposal: in a release build, `main`'s last
drop points skip owners whose type's drop only gives memory back. That
is a per-type fact (CORE §9): no `drop` body and no handle inside.
Debug builds, `RIG_SANITIZE`, and the leak check are unchanged. Trig
keeps what `command_line` makes in `sys`. Tests: release `code` cases (no
free at main's end; a helper's locals still drop) and a `drop` body
that still prints. This goes to the owner.

**3. Huge pages.** Table faults rise from 9.0K at one checker to 25.5K
at four, 21K of them in each Table's 2 MiB small-page prefix. Most of #754's 10 MB a checker
is one sparse Table per checker: 1,280 MiB reserved, written one page
every 80 MiB. A size cap misses it, since its pages lie past 8 MiB. On
the pre-#754 build, simulating an 8 MiB prefix raises one-checker
faults from 7.3K to 19.9K. Do not cap; Trig should index that table
densely.

**4. Four to eight checkers.** The work grows alike: task-clock 7.7%
against 6.6%, with cycles per instruction flat. The cores in use go
from 2.8 to 3.3 for Trig and from 3.0 to 4.4 for tsrs. The partition (one
288 ms file), the serial head and tail, and the slow heavy group cause
it, not the scheduler or bandwidth. Table faults add about 7
ms at eight.

**5. Unattributed 0-14 ms.** It is noise: tsrs's four-checker median
moved from 394 to 425 ms between sessions.
