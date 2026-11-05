# A slice measured in time, in hand-written Zig (2026-11-05)

The question: with the loop split ([loop-disassembly.md](loop-disassembly.md)), 1,024 tasks on one worker still ran about 8% over Rust, because each task yields every 1,024 turns of `spin`, about every 3 µs. Would a slice measured in time remove that cost, and what would it cost the task that waits behind a computation (`hog`)?

**Setup:** the split-loop build of `tasks.rig` (main 39e1ed89f, `--release=fast`), with its copy of `sched.zig` edited:
- each worker notes when it switches a fiber in (`runFiber` and the handoff), from the arm64 counter `CNTVCT_EL0`;
- `sched.tick` yields to waiting work only once the fiber has run `slice_us` microseconds.

Each arm was rebuilt with the same `zig build-exe -Ofast`.

**Measured** on the Mac, 9 rounds interleaved in shuffled order, the fewest cycles or the shortest time of each. The load was 3 to 4.
- The first column is `even-tasks` at `RIG_WORKERS=1`, in whole-process cycles, against Rayon's `even` at one thread.
- The others are `tasks.rig`'s five benchmarks at every worker, per operation, as bench-tasks reports them.

| arm | even-tasks cycles, 1 worker | vs Rust | spawn | chain | fanout | yield | hog |
|---|---|---|---|---|---|---|---|
| plain | 932M | 1.31x | 107 ns | 44 ns | 81.6 ms | 5 ns | 100.9 us |
| split | 742M | 1.05x | 114 ns | 44 ns | 68.7 ms | 5 ns | 76.6 us |
| slice20 | 722M | 1.02x | 63 ns | 44 ns | 68.6 ms | 5 ns | 459.1 us |
| slice50 | 723M | 1.02x | 113 ns | 44 ns | 68.1 ms | 5 ns | 759.3 us |
| slice100 | 719M | 1.01x | 111 ns | 44 ns | 68.0 ms | 5 ns | 1.6 ms |

What it shows:
- **The loop split alone does most of it.** On this quieter run it is 1.05 times Rust, and it closes `fanout` (81.6 ms to 68.7 ms; Tokio 69.0 ms, Go 69.6 ms on the same Mac).
- **A slice in time buys about 3% more** (1.05 to 1.01-1.02 times), on the case built to show it: 1,024 CPU tasks on one worker.
- **It costs the waiting task 6 to 20 times** (`hog` from 77 µs to 0.46-1.6 ms). The waiting task sits behind several computations, each now running a whole slice before it yields.

So Rig keeps yielding at once when work waits. The ideal is the split loop's cheap check, plus signal preemption (#952) as the backstop for code that has no checks: calls into Zig and C, and loops whose turns are slow. It is not a longer slice.
