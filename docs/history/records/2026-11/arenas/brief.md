# Arenas in Rig: panel brief (2026-11-21)

**Question (the owner's):** Rig has no arena, but it could: it compiles to Zig, which is
known for arenas. How could Rig gain arena-based allocation in a language where
allocation is never spoken of? Rig programs never name an allocator.

**Why now:** the benchmarks game's binarytrees port ties Rust on the Mac but is 6% slower
on pup, because Rig has no arena and the fast port uses a `List[Node]` pool where Rust
uses bumpalo (compare/rig/benchmarksgame/README.md). Goose (github.com/aardappel/goose)
gets most of its speed from data that dies together: bump-allocated stacks and pools freed
at scope exit (Rig's review: docs/history/records/2026-11/goose/review.md). docs/IDEAS.md
already has "A region freed at once": values made in a named region are views of it,
dropping the region frees them all; needs a CORE paragraph, a design round, and first a
measure of how much of Trig's time and memory is in data that dies together.

**Facts to start from (verify them):**
- Release builds allocate from Rig's own allocator, src/alloc.zig, a heap per thread;
  debug builds go through a leak checker; the test suite through a sanitizing allocator
  (docs/internals/INTERNALS.md, "The runtime", the `defaultAllocator` row).
- "No box, List, or closure stores an allocator. Allocation failure panics." (same row)
- Owning kinds: `List[T]`, `^T`, `String`, `error`; handles `*T` (counted), `~T` (weak);
  views `?T`, `!T`, `[]T`. Drop glue is generated and runs at visible points.
  The whole ownership model is docs/CORE.md; the reasons are docs/DESIGN.md.
- `src/table.zig` has `Table` and `Slot` (index handles in a reserved table).
- Trig (~/Data/Code/trig) is Rig's large real workload, a TypeScript checker.

**Repos:** Rig at ~/Data/Code/rig (main checkout, read only; `bin/rig` is built there).
Read-only for everyone: change no file in any repo, make no commit, start no heavy job
(no `tools/heavy`, no pup, no timing claims). Small `bin/rig check`/`run` probes are fine,
in a folder of your own under ~/Data/Code/Claude/rig/rig/arenas-panel/probes-<you>/.

**Output:** write your full report to ~/Data/Code/Claude/rig/rig/arenas-panel/<your-file>.md
(as long as it needs, with Rig code sketches in plain ```text blocks, since none runs).
Return a summary of at most 400 words: your recommended design, the 2-4 decisions it needs
from the owner (each with your default), and the biggest risk. Cite files and lines.
