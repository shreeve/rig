# std.json against yyjson: the panel's synthesis (2026-11-05, Mac)

Three experts (yyjson's reader, tape algorithms, Zig codegen) worked from instruction counts only; nothing was timed. Their full reports are yyjson.md, tape.md and zig.md in this folder.

## Where the gap is
- **Formatting whitespace is a large part of it, by instructions:** 61% of twitter's gap, 39% of citm_catalog's, and all of github_events'. Minified, std.json is ahead of yyjson on github_events.
  - This corrects the conclusion of skip-space-2026-11-05.md. Those three tries computed how far to skip, which serializes the loop. yyjson instead guesses from the separator: `,\n`, `: `, or a newline after a bracket, each a two-byte compare, then indentation a fixed amount at a time. Every step is a predicted branch.
- **The token work, per minified citm_catalog's gap:** keys 34%, integers 28%, objects 24%, arrays 14%. Strings of 16 bytes or more are already cheaper than yyjson's.
- **The tape layout is fine:** 1.1-1.3 words per token, against yyjson's 2.

## Ranked, merged
| # | change | evidence | kind | owner |
|---|---|---|---|---|
| 1 | Separator-aware whitespace: `,\n`/`: `/after-bracket newline, then indentation 8 then 2 at a time | tape: 12.4% / 19.4% / 14.8% fewer instructions on twitter / citm / github; canada 1.6% more, minified 2-4.5% more | algorithm | std.json source |
| 2 | Tape arithmetic with wrapping operators (entry encodings, depth) | measured by all three: 2.4% fewer on citm, 1.4% on twitter | codegen via source | std.json source |
| 3 | `List.push` inline, `len` read once (also String.push, pushInt, pushKeep) | zig: 0.21 / 0.47 instructions per byte on citm / twitter | codegen | runtime.zig (Rig's say: #972 territory) |
| 4 | A key path with a lower fixed cost: hand the stop byte back, test `:` before skip_space, drop repeated tests | est. 9-14% of citm's gap, up to 31-35% of twitter's | algorithm | std.json source |
| 5 | Separate object and array states (no `top & 1`, `closing`, `top < 0` after each value) | est. 8-10% | algorithm | std.json source |
| 6 | Integer fast exit (one table test for `.eE`) | measured 18 fewer per short int (7% of citm's gap); floats 17 more, so re-place it | algorithm | std.json source |
| 7 | Position arithmetic proven (`i+8`, `i+16`, `i+1` under the MAX_INPUT bound) | zig: 0.23 / 0.22 per byte | compiler | proofs.zig |

## Rejected (measured)
- Inlining short strings' scan (V1): 10.6% worse on twitter.
- A byte loop for the first 4 digits (V2b).
- The tape in a local (register window): worse, because `document` (3,686 instructions) spills.

## Warnings
std.json's speed rides on LLVM inlining one large `document` function, and any added path moves its inlining choices. Every change gets timed (20 interleaved rounds) on the Mac, never judged by instructions alone.

## Plan
Item 1, then 2 (std.json source only), timed. Then ask Rig for runtime.zig (item 3). Then 4-6, one at a time.
