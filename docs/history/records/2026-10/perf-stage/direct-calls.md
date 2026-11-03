# Row 40: a known function argument made direct (Trig NEEDS 67), closed (2026-11-01)

Trig's parser (trig#231, `parser-tsrs`) hands each list's element function to `parse_list_index`
through a closure, as Go does: `parse_list(kind, parse_element)` passes
`|?parse_element, p, _| parse_element(!p)`, so each element costs two indirect calls, the closure's
thunk and `parse_element`'s `FnRef`. Rig - Rust's xctrace profile (Mac, parsing the libs and the
projects' sources, 12,489 samples): the `FnRef(*Parser) -> Node` thunk 1.87%, the closure's thunk
0.29%, the look_ahead callback 0.32%. tsrs's `impl Fn` arguments are monomorphized, so its calls
are direct.

## The ceiling

Hand-edited emitted Zig (Rig main 928b44bf2): `parse_list`, `parse_list_index`,
`parse_delimited_list`, and `parse_delimited_list_opt` copied with the element function a Zig
`comptime` parameter, and the 22 call sites that pass a known function calling them; the
look_ahead callback untouched. Outputs identical on empty, mitt, zod3, and ts-pattern. `.text`
17 KB larger (0.18%).

Mac (arm64, `tools/low`, 11 interleaved rounds, fewest of each, `--singleThreaded`):

| Project | Instructions | Cycles | Footprint |
|---|---|---|---|
| empty | 1.03% fewer | 1.28% fewer | level |
| mitt | 1.04% fewer | 0.78% fewer | level |
| zod3 | 0.22% fewer | 0.42% fewer | level |
| ts-pattern | 0.04% fewer | 1.39% fewer (instructions level: layout) | level |

pup (x86-64, cross-built on the Mac with `-mcpu=meteorlake`; run by Rig - Swiss with abn.sh,
core 3 with core 4 idle, builds paused, 10 rounds in each order, fastest task-clock):
mitt 21.7 to 21.2 ms (2.3% faster, 3.9% fewer instructions, both orders agree); zod3 156.6 to
155.6 ms (0.6%, level); ts-pattern 818.9 to 818.2 ms (level). Raw: pup:/tmp/r40-a.txt, /tmp/r40-b.txt.

## Why it closed

mitt clears 1.5% by the letter, but the gain is small-project-only, and the compiler change is
not one fact and one emit path. The ceiling's gain needs the closure in `parse_list` made a
compile-time function too, so the change would be a program-wide fact (a function parameter only
called, passed on, or captured by a closure that only calls it, with a known function or such a
closure at every call) plus five emit paths: the parameter, the call site's argument, the call
inside, the capturing closure (no env struct, its capture no field), and passing that closure.
That reaches into closure emission and its captures, which sema and storage also describe: a
small gain woven through the compiler (AGENTS, "A speed feature pays for its lines").

## Trig-side routes (Rig - Rust's call)

- Drop `parse_list`'s closure layer: the closure's thunk, about 0.3% of parse samples.
- Dispatch the element function by a `match` on the `ParsingContext` in `parse_list_index`,
  calling each directly: the `FnRef` call, about 1.9%, with no compiler change.

The packages, the editing script, and the binaries are in Rig language analysis's scratchpad
(`r40/`), and the x86 binaries in pup:/zfs/trig-pup/r40/.
