# How tasks scale over cores

`bench/tasks/bench-scale` (README.md, "Scaling") times the same work in
Rig, Tokio, Rayon, and Go at each worker count, and measures what a
sleeping task holds as the kernel counts it. Each table gives the time
at one worker and at every worker, the speedup between them, and the
benchmark's fixed cost (`empty`: the same tasks with no work). The full
tables, with each worker count and the counters of every row, are in
[docs/history/records/2026-11/taskbench/](../../docs/history/records/2026-11/taskbench/README.md).

## arm64 (Apple M5, 4 performance and 6 efficiency cores)

2026-11-04, Rig at main 39e1ed89f, fastest of 5 interleaved runs.

| Benchmark | Runtime | 1 worker | 10 workers | Speedup | Empty at 10 |
|---|---|---|---|---|---|
| even | rig par.map | 200.2 ms | 26.8 ms | 7.46x | 0.2 ms |
| even | rig tasks | 204.7 ms | 26.9 ms | 7.60x | 0.3 ms |
| even | tokio | 157.3 ms | 21.0 ms | 7.49x | 0.2 ms |
| even | rayon | 154.5 ms | 21.4 ms | 7.21x | 0.03 ms |
| even | go | 155.2 ms | 21.3 ms | 7.27x | 0.2 ms |
| skew | rig par.map | 192.7 ms | 27.1 ms | 7.12x | 0.2 ms |
| skew | rig tasks | 200.2 ms | 26.6 ms | 7.51x | 0.2 ms |
| skew | tokio | 154.2 ms | 20.9 ms | 7.37x | 0.2 ms |
| skew | rayon | 153.5 ms | 20.9 ms | 7.36x | 0.03 ms |
| skew | go | 153.1 ms | 21.1 ms | 7.25x | 0.3 ms |
| tree | rig tasks | 193.8 ms | 27.3 ms | 7.10x | 0.7 ms |
| tree | tokio | 151.6 ms | 20.7 ms | 7.33x | 0.3 ms |
| tree | rayon | 151.7 ms | 20.9 ms | 7.27x | 0.03 ms |
| tree | go | 152.0 ms | 21.2 ms | 7.17x | 0.2 ms |
| alloc | rig par.map | 264.7 ms | 39.0 ms | 6.79x | 0.2 ms |
| alloc | rig tasks | 268.3 ms | 39.5 ms | 6.80x | 0.3 ms |
| alloc | tokio | 527.6 ms | 170.3 ms | 3.10x | 0.2 ms |
| alloc | rayon | 538.8 ms | 188.6 ms | 2.86x | 0.02 ms |
| alloc | go | 536.0 ms | 292.0 ms | 1.84x | 0.3 ms |

| Memory per sleeping task | Total | Of it, page tables |
|---|---|---|
| rig | 32.7 KiB | 16.1 KiB |
| tokio | 267 B | 0 B |
| go | 2.9 KiB | 5 B |

What the arm64 numbers show:

- **Rig spreads work as well as the others:** 7.1 to 7.6 times at ten
  workers, as Tokio, Rayon, and Go, on even, skewed, and recursive work.
- **Rig's CPU work is 25 to 32% slower at every worker count**, in the
  loop itself: Rig runs fewer instructions than Go (975M against 1.10G
  for `even` at one worker) in about 27% more cycles (898M against
  707M). The yield check's branch splits the loop, and LLVM then puts
  two extra adds on the chain each turn waits on
  ([loop-disassembly.md](../../docs/history/records/2026-11/taskbench/loop-disassembly.md)).
- **A split of the tree costs about 2 µs at one worker** (`empty` 2.0
  ms for 1,023 splits; Rayon's 0.01 ms): each split gets a stack of its
  own, and more splits wait at once than a worker keeps stacks for.
- **Allocation scales in Rig and not elsewhere:** Rig's heap per thread
  is twice as fast as the system allocator at one worker and 4.4 times
  Tokio at ten, where macOS's malloc and Go's collector stop scaling at
  2 to 3.7 times.
- **A sleeping task holds 32.7 KiB:** one page of its stack and, about
  as much again, the page tables of its own mapping. `bench-tasks`'s
  `memory` column, from `ru_maxrss`, counts only the first.

## x86-64 (pup: Intel Core Ultra 9 185H)

2026-11-05, Rig at main 39e1ed89f, fastest of 5 interleaved runs, on
named cores (1, 2 and 4 workers on distinct performance cores; 16 on ten
performance-core threads and six efficiency cores).

| Benchmark | Runtime | 1 worker | 16 workers | Speedup | Empty at 16 |
|---|---|---|---|---|---|
| even | rig par.map | 186.3 ms | 17.3 ms | 10.80x | 0.4 ms |
| even | rig tasks | 191.2 ms | 16.7 ms | 11.44x | 1.2 ms |
| even | tokio | 178.8 ms | 14.9 ms | 12.04x | 0.5 ms |
| even | rayon | 179.6 ms | 14.9 ms | 12.02x | 0.05 ms |
| even | go | 159.3 ms | 13.5 ms | 11.76x | 0.6 ms |
| skew | rig par.map | 181.7 ms | 17.3 ms | 10.51x | 1.1 ms |
| skew | rig tasks | 187.2 ms | 16.8 ms | 11.18x | 1.2 ms |
| skew | tokio | 176.0 ms | 14.9 ms | 11.83x | 0.4 ms |
| skew | rayon | 176.3 ms | 14.7 ms | 12.01x | 0.04 ms |
| skew | go | 157.1 ms | 13.5 ms | 11.66x | 0.5 ms |
| tree | rig tasks | 205.5 ms | 18.4 ms | 11.19x | 1.6 ms |
| tree | tokio | 176.2 ms | 15.1 ms | 11.66x | 0.2 ms |
| tree | rayon | 176.0 ms | 14.8 ms | 11.87x | 0.02 ms |
| tree | go | 156.6 ms | 13.5 ms | 11.60x | 0.3 ms |
| alloc | rig par.map | 282.2 ms | 36.9 ms | 7.64x | 0.6 ms |
| alloc | rig tasks | 290.1 ms | 37.1 ms | 7.82x | 1.1 ms |
| alloc | tokio | 625.2 ms | 53.6 ms | 11.67x | 0.5 ms |
| alloc | rayon | 511.6 ms | 54.3 ms | 9.41x | 0.04 ms |
| alloc | go | 750.1 ms | 352.8 ms | 2.13x | 0.6 ms |

| Memory per sleeping task | Total | Of it, page tables |
|---|---|---|
| rig | 8.9 KiB | 4.3 KiB |
| tokio | 388 B | 1 B |
| go | 2.9 KiB | 7 B |

What the x86 numbers show:

- **Rig spreads work nearly as well:** 10.5 to 11.4 times at sixteen
  workers, against 11.6 to 12.0 times for Tokio, Rayon, and Go. The gap
  is Rig's slower loop and its higher fixed cost (`empty`), which weigh
  more at 17 ms than at 190.
- **Rig's CPU loop is 4 to 17% slower** at one worker (186 ms against
  Rayon's 180 and Go's 159): less than on arm64, the same cause.
- **A split of the tree costs about 1.3 µs** at one worker (Rayon's
  0.02 ms for 1,023).
- **Allocation is Rig's at every worker count:** 1.8 to 2.7 times
  faster at one worker, and 37 ms against Tokio's 54 and Go's 353 at
  sixteen. glibc's arenas per thread scale Tokio and Rayon further than
  macOS's malloc does, but from twice Rig's time.
- **Tasks cost TLB shootdowns:** `alloc` as a set of tasks takes 900 to
  3,400 shootdowns across 2 to 8 workers, where `par.map`, which runs
  few tasks, takes 6 to 25, and Rayon 5 to 18. These are a task's
  stack pages being released, which every core must forget.
- **A sleeping task holds 8.9 KiB,** half of it page tables, against
  Tokio's 388 B and Go's 2.9 KiB.
