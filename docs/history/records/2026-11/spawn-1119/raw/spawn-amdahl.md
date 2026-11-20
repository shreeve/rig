# Spawn, Amdahl-style (pup, 2026-11-19, A+B baa618b9f; spawn-only program, 500k tasks; slot 692)

Per spawn (median of 5): 1 worker: pre 99.9 ns, main 100.1, A 96.7, A+B 101.2 (cycles 490-502, instructions 963-993):
the work of one spawn alone never regressed. 12 workers (cores 0-11 = 6 P-cores with their siblings): pre 126.1,
main 142.4, A 136.3, A+B 124.5 ns; instructions 1644/1732/1673/1618, all-thread cycles 2370/2491/2436/2281, L1d misses
11.8/13.1/12.7/11.8, L1i 18.4/20.4/19.0/18.8. 12 workers cost ~25 ns a spawn more than 1: coordination.

Threads: all 12 run evenly (6.9-10.6% each); the maker (main's worker) is 10.2%: no single-thread bottleneck.

Share of all cycles at 12 workers (A+B), by area, with the hot instruction (perf annotate):
| area | share | what |
|---|---|---|
| idle spin in search | ~11.7% | 63% of search (18.5%) is `pause`: idle workers spinning, on SMT siblings of busy ones |
| contended atomics | ~11.5% | wakeIn: xchg into the run-next slot (41% of wakeIn = 4.3%), xchg on a worker u32 at +0x8d4 (29% = 3.0%), load of global `searching` (17% = 1.8%); search: lock incl `searching` (1.7%) and its loads |
| rest of finding work | ~20% | loop 6.7, stealFrom 6.7, next 4.5, rest of search |
| running a task | ~12.6% | Record.start 4.4, runFiber 3.5, fiber start/end, prepare |
| alloc/free a record | ~4.0% | classAligned 2.3, allocRecord 0.8, freeRecord 0.9 |
| finish and join | ~3.1% | finishApart 2.1, waitInto 1.0 |
| make the record (spawnApart) | 1.7% | the 30 stores, the checks |
| other | rest | 0xa06 stub 2.9%, kernel |

Ranking: (1) a burst of spawns rotates each new task through the run-next slots with a seq_cst xchg on a line stealers
cmpxchg; only the last of a burst needs the slot (the ring's batch mode exists); (2) the +0x8d4 seq_cst xchg on every
wake; (3) global `searching` line ping-pong; (4) spinning on SMT siblings (spin length, park sooner); (5) lean record and
no alignment check: at most ~1%.
