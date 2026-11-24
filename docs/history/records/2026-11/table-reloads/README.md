# Table-head reloads in Trig: a measured negative (2026-11-24)

**Result.** Trig retires 5-23% more loads than tsrs 0.23.0 at c1. The extra loads are reloads of the
Checker's own fields: Table heads (`store.*.slots`), `program`, `ids`, `binder_syms`. On pup's E-cores
they fill the load buffer, at about 5% of cycles. On a P-core they cost nothing. Stalls on loads that
hit L1 are 0.8-1.3% of cycles below tsrs's (slot 747). The ceiling that would remove the Table-head
loads (Tables at fixed offsets, no head to load) was not built, because the P-core excess it targets is
below the 1.5% rule. At c1 Trig main 3c6d8627 is level with tsrs on Compiler and typeorm, and ahead on
webpack and supabase-studio. Nothing in Rig or Trig changed.

## The question

The top-down split of slot 746 (P-core 3, Trig ec477026 against tsrs) showed Trig's c1 cycles about 2%
memory-bound beyond tsrs's on the cells it lost, with miss counts level. The guess was dependent-load
latency: a handle, then a Table head in the Checker, then the slot. tsrs has no head to load, since its
types are direct pointers.

## E-core diagnosis (pup E-core 18; diagnosis only)

Arms: Trig main 3c6d8627, the PGO half without BOLT, against tsrs 0.23.0 built from source with PGO on
Trig's training set and no BOLT. That is the matched pair of the 2026-11-23 c1-check study. Three
interleaved rounds of five `perf stat` sets; stdout identical on every run
([data/ecore-RESULTS.txt](data/ecore-RESULTS.txt), [data/ecore-rows.txt](data/ecore-rows.txt)).

- **Load-buffer stalls.** `mem_scheduler_block.ld_buf` is 4.7-9.7x tsrs's: +4.7% (typeorm) to +6.3%
  (webpack) of cycles, with instructions scaled. Stalls on loads that miss the last level are at or
  below tsrs's (0.74-0.93x). Stalls on loads that hit L2 are +1.0-1.8%.
- **More loads.** Trig retires 1.10-1.20x tsrs's loads at 0.91-0.97x its instructions.
- **Loads by Checker field.** All-loads samples with data addresses, on the PGO build, share of all
  loads (webpack / typeorm / Compiler):

  | field | share |
  |---|---|
  | Checker object, in all | 18.3 / 16.8 / 17.7% (23-25% of loads in checker functions) |
  | Table heads (`store.*`) | 5.8 / 5.5 / 5.4% |
  | `program` | 2.2 / 2.1 / 2.5% |
  | `ids` | 1.2 / 1.0 / 1.7% |
  | `binder_syms` | 0.9 / 0.9 / 1.0% |

  In absolute loads this matches Trig's excess over tsrs on typeorm (0.25G against an excess of 0.24G)
  and Compiler (0.075G against 0.070G). On webpack it is 0.47G against 0.23G. No function holds more
  than 0.35% of all loads in these fields. The loads come back after calls and stores, which LLVM
  cannot see past for a field of `self` (a static count found about 10% of loads in the relater's and
  instantiation's functions).
- **What blocks retirement.** A PEBS sample of `ld_head.any_at_ret` lands on the blocked load itself
  (72% of the sample IPs are loads). Table-head loads are 0.1% of the blocked loads: they hit L1 and
  finish early. The blocked loads spread over the AST's lists (about 25%: words 9%, node records 8.5%,
  positions 3.7%), the store's Tables (about 10%) and maps. No chain is above about 2%. tsrs's largest is
  its AST node header (23%).

So on the E-core the cost is the number of loads, not the latency of a chain. An E-core's load buffer
is small, so the question was whether a P-core pays it too.

## The P-core (slot 747)

P-core 3, c1, seven scored rounds, arms shuffled each round:
- T: Trig main 3c6d8627, PGO+BOLT.
- T2: the same binary again, the A/A.
- G: tsrs 0.23.0 as raced.

Stdout identical. Script: [data/slot-pcore.sh](data/slot-pcore.sh). Rows and summary:
[data/pslot-747-rows.txt](data/pslot-747-rows.txt), [data/pslot-747-summary.txt](data/pslot-747-summary.txt).
"L1-bound" is `exe_activity.bound_on_loads` less `memory_activity.stalls_l1d_miss`: execution stalled
on loads that hit L1.

| project | cycles T/G | cycles T2/G | A/A cycles (T2/T) | loads T/G | L1-bound T/G | L1D-miss stalls T/G |
|---|---:|---:|---:|---:|---:|---:|
| Compiler | 1.008 | 1.011 | 1.004 | 1.225 | 0.82 | 1.14 |
| typeorm | 1.007 | 1.007 | 1.000 | 1.215 | 0.89 | 1.10 |
| webpack | 0.981 | 0.979 | 0.998 | 1.144 | 0.83 | 1.09 |
| supabase-studio | 0.908 | 0.900 | 0.992 | 1.053 | 0.74 | 0.97 |

The per-run spread of cycles is 1.2-6.7% within an arm. The extra loads cost no stall cycles on the
P-core: L1-bound cycles are below tsrs's in every project, by 0.8-1.3% of cycles with instructions
scaled. The E-core's load-buffer stalls do not carry over, as the E-core's dTLB misses did not before
(the 2026-11-23 like-for-like slot 732).

## Why the ceiling was not built

The plan held one condition: build the ceiling only if the P-core load excess were at least 1.5% of
cycles. The ceiling was a scratch build from post-processed generated Zig, with every reserved Table of
the Checker's Store mapped at a fixed address and every `self.store.F.at/slot/constSlot` reading through
a compile-time base. The patch is [data/ceil.py](data/ceil.py), unused. The excess it targets is
negative on the P-core, so the ceiling has nothing to remove, and no Rig proposal follows. The general
form, a Table reached from its owner with no load (base = self + K), stays an idea with no measured
case.

## noalias

`noalias` on loans stays held for FORMAL stage 2 ([formal-plan.md](../../../../design/formal-plan.md)).
It would remove only the reloads that follow stores, and most follow calls. On Trig in October it gave
0.1-0.2% fewer instructions and no time ([loop-hoist.md](../../2026-10/perf-stage/loop-hoist.md)).

## The L1-miss residue

What remains of Trig's c1 excess on the P-core is stalls with an L1D miss outstanding
(`memory_activity.stalls_l1d_miss`).
- Scaled by instructions, it is +1.7-2.2% of G's cycles on all four projects.
- Raw against G's cycles, it is +1.3% on Compiler, +1.3% on typeorm, +1.2% on webpack and -0.5% on
  supabase-studio.

On the E-core the matching excess is in loads that hit L2 (+1.0-1.8%). It is spread thin: no Table,
map or AST list holds more than about 2% of the retire-blocking loads. Earlier records found miss counts
level with tsrs's. It was not pursued, because at about 1.2-1.3% raw it cannot clear the 1.5% bar even
if every bit of it were attributed and removed.

## Where things are

- Scripts in [data/](data/):
  - [one.sh](data/one.sh): an E-core `perf stat` run.
  - [rec.sh](data/rec.sh): sampling.
  - [drive.sh](data/drive.sh): interleaving, one run per locked call.
  - [dump.py](data/dump.py): samples to file addresses.
  - [summ.py](data/summ.py): medians and excess.
  - [lat.py](data/lat.py): latency and retire samples by inlined accessor.
  - [ckld.py](data/ckld.py): loads by Checker field from DWARF offsets.
  - [headins.py](data/headins.py): the instruction at each retire sample.
  - [statload.py](data/statload.py): the static count of Table-head loads.
- The raw perf data was deleted.
- On pup, `/zfs/trig-pup/trial/dload/` keeps the text results, the scripts and the PGO+BOLT binary.
