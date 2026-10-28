# table-ahead: why 65% fewer faults gave 0.4% (user side, and the experiment)

Fault expert 2, 2026-10-28, pup core 1 (sibling 2 idle). Load during the runs
was 2.4-3.1 (another expert on core 3, a release build of trig-zig-ceiling).
Files here: `symdiff.py`, `pushcount.py`, `xrun.sh`, `xsum.py`, `fault.c`,
`xrun/` (10 rounds), `xrun2/` (20 rounds), `xrun*-summary.txt`, `micro.txt`,
`ins-{main,new}.data` (perf record -e instructions:upp -c 200003, ts-pattern),
`dis-{main,new,x}.txt` (objdump).

## 1. The 170M extra user instructions: push stopped being inlined

The extra code is neither layout noise nor the bare check. The check made
`Table.push` too large for LLVM to inline, so nearly every push became a call.

- Call sites of `Table(...).push` (objdump): **main 113, new 877**. The
  memory-traffic `rel` build has 113; its experiment binary `x` has 877.
- Per-symbol instructions (ts-pattern, samples x period): the `push` symbols
  go from 6.6M to 242.6M (+236M); every other function together goes down
  72M (the inlined push bodies leave the callers). Net +164M; perf stat says
  +170M. No other function moves by more than sampling noise (about 18M on
  800M-instruction functions, in both directions).
- About **8.5M pushes** on ts-pattern (each push symbol's instructions over
  its fast-path length): `Table(u32)` 4.4M, `CheckerSymbol` 1.25M,
  `TypeMapper` 1.0M, `Type` 0.64M, `StructuredType` 0.44M, the rest 0.8M.
- **About 19 instructions more per push.** The out-of-line fast path is 28
  instructions (`Table(u32).push`, new) against about 8 inlined in main:
  - the check itself, 9: `inc; je ovf; mov; shr $62; jne ovf; shl $2;
    cmp ahead; ja cold`. Four of them are ReleaseSafe's overflow checks on
    `(len+1) * @sizeOf(T)`, which LLVM cannot drop, since `len != n` does
    not bound `len + 1` for it;
  - the call: `call`, `ret`, and a prologue and epilogue that save rbx and
    rbp and pad the stack (`push` x3, `add`, `pop` x2) on the fast path too,
    because the cold `faultAhead` call is not shrink-wrapped;
  - the argument moves at each of the 877 call sites.
- **User cycles 0.35% more** is the sum of two things: the extra code costs
  about 0.7% (~30M cycles for 170M cheap, well-predicted instructions), and
  the traps no longer taken save about 0.4% of user cycles (section 3).

## 2. Why the experiment showed 2.7% and this shows 0.4%

**The experiment's base arm paid for the outlined push too.** `mkx.py` put
`if (rt.xflags & 2 != 0) {...}` in `push` for every arm, so its one binary
has push outlined at 877 sites in both arms. x2 against x0 measured the fault
saving with the outlining cost on both sides of the subtraction. Five arms,
interleaved, order reversed every other round: `rel` (memory-traffic's plain
build), `x` under RIG_X=0 and 2, and table-ahead's `main` and `new`. Medians
of per-round ratios:

| | ts-pattern, 10 rounds | ts-pattern, 20 rounds | zod3, 10 | zod3, 20 |
|---|---:|---:|---:|---:|
| x0 vs rel, instructions | 2.19% more | 2.24% more | 2.00% more | 1.87% more |
| x0 vs rel, total cycles | 2.39% more | 2.14% more | 1.78% more | 1.68% more |
| x2 vs x0, total cycles | 1.12% fewer | 0.08% fewer | 1.31% fewer | 0.10% fewer |
| x2 vs x0, kernel cycles | 4.92% fewer | 5.55% fewer | 1.18% fewer | 1.16% fewer |
| x2 vs x0, user cycles | 0.66% fewer | 0.51% more | 0.79% fewer | 0.06% fewer |
| new vs main, total cycles | 1.09% more | 0.83% more | 0.05% more | 1.06% more |
| new vs main, kernel cycles | 5.41% fewer | 6.48% fewer | 1.44% fewer | 0.93% fewer |

The interquartile ranges are about 1.5% either way, so single cycle cells are
at noise level; instruction counts are exact (x0's 9,492M is the record's
base arm to the million). Under this load new vs main came out slightly
slower, where the owner's 20 rounds had it 0.4% faster: the same small
effect inside the noise.

- **The 2.7% did not reproduce.** On core 1, with load like the
  experiment's, x2 vs x0 gives 0.1-1.1% fewer total cycles, never 2.7%.
  The kernel saving reproduces (about 5%); the experiment's 2.3% fewer user
  cycles does not (here 0.7% fewer to 0.5% more). The record said arms of
  the same code moved about 1%; its 2.7% is about 0.9% of effect plus noise.
- **Not the measure:** the experiment and the owner's run both count
  total = user + kernel cycles.
- **Not mainly load:** these runs were as loaded and did not show it.
- **The check and the outlining** account for the rest of the gap: x2
  carries the check (0.77% more instructions than x0) but not the outlining,
  which x0 also carries; table-ahead carries both against a main with
  neither.

## 3. The ceiling: a check that costs nothing

Microbenchmark (`fault.c`, core 1): 160 MiB of fresh pages written in order,
one store per line, with reads of a warm 1 MiB set between stores.

| per 4 KiB page | kernel cycles | user cycles lost to the trap |
|---|---:|---:|
| fault on touch | ~4,800 | ~500-1,000 |
| populate 64 KiB ahead | ~3,700 | ~0 |
| 2 MiB pages (fault on touch, `MADV_HUGEPAGE`) | ~1,850 | ~0 |

Populate saves about a quarter of a page's kernel cost (the trap: entry,
exit, the walk to the fault handler); allocation, zeroing, the memcg charge
and the PTE remain. This agrees with fault expert 1's hypothesis.

On ts-pattern table-ahead removes 26K traps:
- kernel: measured 21M cycles (6.3% of 335M), about 800 per trap;
- user: about 18M cycles (26K x ~700), the refill after each trap;
- **ceiling: about 39M cycles, 0.9% of 4.45G**, if the check cost nothing.
  zod3 less (4K fewer traps: about 0.4%).

The free check is easy: hold `limit`, the slot count faulted in so far
(capped at `n`), and make the fast path `if (self.len >= self.limit)
self.slowPush(value)`: one compare against a field in place of the compare
against the immediate `n`, no multiply and no overflow checks, so push stays
the size it is on main and stays inlined. The cold path panics at `n` or
faults ahead.

At 0.9% it is under Trig's bar (more than 1.5% faster, or 1% fewer
instructions), for 0.5-1.9% more peak memory. Not worth having alone.

## 4. What would turn the fault cut into time

The pages still cost ~3,700 kernel cycles each after populate. Tables write
~133 MB, ~32K pages: ~120M cycles, ~2.7% of the run. Only fewer fresh pages,
or larger ones, remove that:
- **2 MiB pages for tables** (one allocation and charge per 512 pages; about
  60% less kernel time per byte in the microbenchmark): #740's `tbl` arm,
  3.3-3.9% faster on ts-pattern, but 4-16% more peak memory from each
  table's 2 MiB slack.
- **One frontier for all tables** (tsrs's arena): the huge-page saving with
  one slack, not forty. A layout change, Trig's and Rig's.
- **Fewer bytes:** smaller records (Trig-side splits, memory-traffic §4).

The folded `limit` check is the right hook for either: it is where a table
would advise its next region huge.

## Recommendation

Do not land table-ahead as it stands: its check outlines push and spends most
of the saving. If faults are pursued, build the folded-limit form (no extra
instructions on the fast path) together with 2 MiB pages or a shared
frontier; fault-ahead alone is worth at most about 0.9%.
