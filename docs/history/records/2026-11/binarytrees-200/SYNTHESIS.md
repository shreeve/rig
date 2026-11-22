# binarytrees in 200 ms: synthesis (2026-11-21)

Panel: performance ([perf.md](perf.md)), language and ownership ([language.md](language.md)),
compiler ([compiler.md](compiler.md)), from [brief.md](brief.md). All three measured on the
Mac under `tools/mac-claim` while other sessions ran, so single numbers are about ±10%.

## Where the time goes (measured)

Rig's plain port: 0.81-0.96 s wall, 5.5-6.0 s CPU. Freeing each node is 52% of the CPU,
allocating 20%, building 13%, walking 14% (perf.md, `sample`). Each node makes three runtime
calls that are never inlined: `alloc`, `free`, and a `task()` read on every box release
(runtime.zig `releaseNested`, checked: it guards the drop depth). On macOS every thread-local
read is a call (`_tlv_get_addr`), 22.5% of the CPU alone. A node is 16 bytes, the same as
Rust's, so node size is not the plain port's problem.

**The floor.** A C model with 8-byte nodes and an inlined bump runs 203 ms; with 16-byte
nodes 231-237 ms. Rust fast with mimalloc is 205 ms, Rig's fast port 208-219. So 200 ms is
the machine's floor for this workload: reaching it means matching the best hand-tuned code.

## Where the experts agree and differ

| Mechanism | perf | language | compiler | Verdict |
|---|---|---|---|---|
| No per-node free (arena or region) | ~400 ms | in model | -590 ms with bump (measured) | the big win, decided |
| Bump allocation inlined at `add`, window in the arena value | 10-40 ms | in model | ~20 ms (0.32 vs 0.34 s, measured) | small, cheap: build |
| `add` takes the node's place before its argument (rust-5's layout) | — | 30-40 ms (model, measured) | — | build with the arena |
| Warm chunk cache per heap | needed | "return memory warm" | stretch tree's fresh chunks suspected | build with the arena |
| Splitting each depth across tasks | +40-60 ms (estimate) | 0 (measured) | 0 (measured) | drop: two measurements say no |
| 8-byte nodes via 4-byte links | 20-30 ms | 10-20 ms (model) | 0 ms (measured) | defer; measure after the rest |
| Typed drop glue (one `task()` read per drop root) | — | — | -150 to -250 ms today | build now, helps every program |
| Faster thread-local read on macOS | 877 to ~700 ms | — | — | build now, helps every program |
| Region inference (the plain port unchanged) | — | unsound as a rule | ~0.28 s (measured), high cost, silent use-after-free if wrong | not now |
| Boxes in an arena, arena from context | — | unsound or 0 | — | set aside |

## The path

1. **Now, for every program:** typed drop glue and a faster thread-local read on macOS.
   Today's plain port to roughly 0.65-0.7 s (estimate).
2. **`Arena[T]`, built fast:** `!a.add(x)` inlined in the emitted Zig, its bump window in the
   arena value rather than behind a thread-local, and a dropped arena's chunks kept warm for
   the next. Expected 0.26-0.30 s.
3. **Place-first `add`:** the node's slot is taken before its argument runs, so a tree is laid
   out parent before children, as rust-5's is. The checker must prove the argument cannot
   move, reassign or drop the arena's handle. Expected 0.22-0.26 s.
4. **Profile what is left:** `rig.tickCall()` per call, the load through the `*Arena` handle,
   fresh chunks for the stretch tree.
5. **Only if still short, 4-byte links** (`arena obj`, Goose's self-relative offsets): 8-byte
   nodes, half the memory, 10-30 ms, at the cost of a new kind of type and a CORE paragraph.

Natural Rig lands at about 220-260 ms with steps 1-3, near 205-215 ms with step 5; 200 ms is
the floor that Rust's best and Rig's hand pool already sit on.

## The owner's decisions (2026-11-21): all seven defaults approved

1. Typed drop glue now, outside the arena work. **Yes.**
2. A faster thread-local read on macOS, as its own runtime change. **Yes.**
3. Build `Arena[T]` with an inlined `add`, the bump window in the arena value, and warm
   chunk reuse. **Yes.**
4. Place-first `add`, proved by the checker. **Yes.**
5. 4-byte arena links: **defer** until 3-4 are measured.
6. Region inference: **not now**; revisit if unchanged plain code must be fast (~280 ms).
7. Splitting each depth across tasks: **no**.

## Risks

- The target is the floor: any per-call overhead the models lack (the preemption tick, the
  counted handle, task switches) shows up as the last 20-50 ms.
- Place-first `add` dangles if the checker's condition is wrong; it needs cases both ways.
- The arena's own self-view rule (records/2026-11/arenas) still comes first.
