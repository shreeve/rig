# binarytrees in 200 ms: panel brief (2026-11-21)

**The owner's goal:** natural Rig should run the benchmarks game's binarytrees (depth 21) in
about 200 ms on the Mac (Apple M5, 10 cores). New mechanisms are welcome, including ones Rig
doesn't have yet but could build. Find every way to get there and rank them.

**Where things stand (Mac, wall clock, fastest run;
~/Data/Code/rig/compare/rig/benchmarksgame/results.md lines 161-172):**

| Program | Wall | CPU | Peak memory |
|---|---:|---:|---:|
| Rust fast (rust-5, bumpalo + rayon), mimalloc | 205 ms | 1.69 s | 322 MB |
| Rust fast (rust-5) | 233 ms | 1.94 s | 248 MB |
| Rust plain (typed-arena) | 408 ms | 2.92 s | 211 MB |
| Rig fast `--release` (a `List[Node]` pool with I32 indexes, reused by `!pool.keep(0)`) | 219 ms | 1.79 s | 250 MB |
| Rig plain `--release` (a `^Tree` box per node) | 877 ms | 6.25 s | 149 MB |

Sources: `binarytrees.rig` (plain) and `binarytrees-fast.rig` in
~/Data/Code/rig/compare/rig/benchmarksgame/binarytrees/, with notes.md; the Rust sources in
the same folder's `rust/`. `compare/` is local only (not in the repo). The fast port already
hits about 210 ms, but with integer links the checker can't verify. The goal is that speed
with code close to the plain port.

**Already decided (2026-11-21):** an `Arena[T]` behind `*`, whose `!a.add(x)` gives a `?T`
from `a`; contents that copy, so dropping it is one free; one CORE change, values in an arena
viewing one another. Record: ~/Data/Code/rig/docs/history/records/2026-11/arenas/ (SYNTHESIS.md
first; runtime.md estimated the plain port with an arena at 0.35-0.45 s). docs/CORE.md has the
planned "Arenas" paragraph after sentence 9. So the question is what gets past ~400 ms to ~200.

**Rig facts:** compiles to Zig 0.17. Release builds allocate from src/alloc.zig (a heap per
thread). The ownership model is docs/CORE.md; CORE §10 says a feature's rules follow the value's
type, never where it came from (an optimization that changes no rule is not a rule). Compiler
map: docs/internals/INTERNALS.md. Rig's `Table`/`Slot` (src/table.zig) take the narrowest index.

**Rules:** read only in every repo: change no file, make no commit. Small `bin/rig check`,
`run`, `emit` and `build` probes are fine, in ~/Data/Code/Claude/rig/rig/bt200-panel/probes-<you>/.
Timing only as AGENTS.md allows: `tools/mac-claim LABEL CMD` from ~/Data/Code/rig, at most 10
minutes in all, never `tools/heavy` suites, never pup. Say which numbers you measured and which
you estimate.

**Output:** full report in ~/Data/Code/Claude/rig/rig/bt200-panel/<your-file>.md. Return at
most 400 words: the mechanisms ranked by milliseconds gained against cost to build, the path you
recommend to ~200 ms, the decisions it needs from the owner (each with your default), and the
biggest risk. Cite files and lines.
