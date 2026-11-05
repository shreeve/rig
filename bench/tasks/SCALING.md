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
  707M). The yield check's countdown sits on the chain of adds each turn
  depends on.
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
