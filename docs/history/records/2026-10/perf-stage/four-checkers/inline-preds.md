# Small functions left out of line, and why (2026-11-02)

Measured only. Trig fb60a18 at Rig caa6f8560 (`/tmp/uc/m`), one
checker.

## Method

- **Self samples:** E-core 14, `cpu_atom/cycles/u`; ts-pattern 10 runs
  (period 3,000,017, 13,929 samples), zod3 30 runs (period 1,000,003,
  8,329). Each sample goes to its out-of-line function (`nm -S`), whose
  size in bytes is the symbol's.
- **Calls:** P-core 6, LBR filtered to calls (`-j any_call,u`), 20 runs
  of ts-pattern (241,261 call records) and 40 of zod3 (95,915). Each
  function's share of call targets is scaled by `perf stat`'s total
  calls (ts-pattern 101.5M, zod3 19.6M).
- **Why:** the inliner's own decision for each function, printed by a
  scratch copy of Rig caa6f8560 (`inline-why/`, never committed). It
  adds one `RIG_INLINE_WHY` dump after `pass.fit()`: size in nodes,
  eligibility, marker, use as a value, whether the function is on a
  cycle, the frame test, and the decision before and after `fit`. Run
  as `rig check` on Trig's sources.
- Data: pup `/zfs/worktrees/rig-rust-ports/pc/` (`z.*`, `lbr.*`,
  `tgt.*`, `m.nm`); `inline-why/why.txt` (10,169 functions).

## A correction first

`type_target`, `is_literal_type`, `is_tuple_type` and
`interface_type_parameters`, named in per-call.md as kept out of line,
are inlined: emit writes them `inline fn`. Their samples there were
their own lines inside inference, read from the inline chain.
per-call.md is corrected.

## The hot small functions left out of line (top 15 of about 100)

| function | nodes | call sites | bytes | ts-pattern % | calls | zod3 % | calls | why |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| get_actual_type_variable | 54 | 15 | 332 | 0.70 | 2.04M | 0.12 | 33k | on a cycle |
| get_signatures_of_structured_type | 40 | 19 | 230 | 0.44 | 417k | 0.43 | 96k | on a cycle |
| is_type_reference_with_generic_arguments | 33 | 4 | 267 | 0.41 | 1.12M | 0.43 | 234k | on a cycle |
| ast `text` | 5 | 7 | 138 | 0.44 | 2.91M | 0.38 | 556k | used as a value |
| get_recursion_identity_target | 69 | 5 | 303 | 0.24 | 1.30M | 0.40 | 354k | on a cycle, and over 60 |
| maybe_type_of_kind | 32 | 42 | 232 | 0.09 | 239k | 0.43 | 233k | on a cycle |
| get_symbol_of_declaration | 16 | 138 | 257 | 0.10 | 90k | 0.38 | 61k | on a cycle |
| has_matching_recursion_identity | 35 | 2 | 269 | 0.27 | 980k | 0.20 | 265k | on a cycle |
| is_empty_anonymous_object_type | 42 | 17 | 376 | 0.15 | 607k | 0.30 | 238k | on a cycle |
| get_regular_type_of_literal_type | 39 | 36 | 305 | 0.18 | 406k | 0.10 | 38k | not eligible |
| get_element_types | 17 | 11 | 335 | 0.19 | 129k | 0.02 | 1k | on a cycle |
| get_homomorphic_type_variable | 27 | 6 | 222 | 0.12 | 77k | 0.08 | 25k | on a cycle |
| instantiate_type_alias | 25 | 5 | 175 | 0.11 | 640k | 0.08 | 81k | on a cycle |
| set_structured_signatures | 62 | 6 | 269 | 0.09 | 322k | 0.11 | 70k | over 60 nodes |
| get_index_infos_of_type | 8 | 27 | 235 | 0.09 | 228k | 0.05 | 12k | on a cycle |

## By reason (every hot small Trig function out of line)

| why left out | functions | self, ts-pattern | self, zod3 | calls ts / zod3 | call cost at 6 cycles, ts / zod3 |
|---|---:|---:|---:|---:|---:|
| **on a cycle of calls** | **69** | **3.74%** | **4.18%** | 8.3M / 1.8M | 1.22% / 1.63% |
| used as a value | 6 | 0.46% | 0.47% | 3.0M / 0.6M | 0.44% / 0.55% |
| on a cycle and over 60 nodes | 3 | 0.38% | 0.43% | 1.3M / 0.4M | 0.19% / 0.32% |
| not eligible | 7 | 0.22% | 0.35% | 0.4M / 0.1M | 0.07% / 0.06% |
| over 60 nodes | 5 | 0.19% | 0.25% | 0.5M / 0.2M | 0.07% / 0.15% |
| frame or expansion (`fit`) | 7 | 0.01% | 0.20% | | |

None is left out for crossing modules, a Table read, or a recursion
guard. The rule has no such tests.

## Why "on a cycle" covers most of them

The inliner leaves out every function in a strongly connected
component of the call graph (`findCycles`, `isCyclic`). A checker is
one huge mutually recursive component, so a 16-node
`get_symbol_of_declaration` is excluded because some path from it
leads back to it. Zig only needs every cycle to keep one out-of-line
function, or an inline body would expand forever. `cutCycles` already
computes such a set for yield checks: a feedback vertex set, with the
largest functions taken first.

## The one rule change

**A function on a cycle may be inlined unless the cycle cut takes it.**
Compute a feedback vertex set for inlining, as `cutCycles` does for
checks (the largest bodies first, so small ones stay inlinable), and
apply the size, value, frame and `fit` tests as now. Every cycle keeps
an out-of-line member, so Zig's expansion stays finite. It covers 69
of the about 100 hot functions, and 3.7–4.2% of all self samples.

**Reach (upper bounds):** the call overhead alone, at about 6 cycles a
call (call, return, saves), is 1.2% of ts-pattern's cycles and 1.6% of
zod3's. Inlining also lets LLVM fold flag tests and loads into the
caller, which can add to that; code growth (`get_symbol_of_declaration`
has 138 call sites) can take from it, and `max_expanded` bounds it.
Estimate 0.5–1.5%.

A second, smaller change: a function **used as a value** (ast `text`,
2.9M calls, passed as a `FnRef` somewhere) could get an inline twin for
its direct calls and keep the plain function for the value. That is
about 0.4–0.5%.

## Ceiling plan (before any compiler change)

In the base package, mark the 15 functions above `inline fn` by hand,
except where they form a cycle among themselves (Zig reports one).
Cross-build a plain binary, check outputs, and time it with base and
an A/A copy in a slot.

## Correction: self-recursive functions stay out (2026-11-02, 01:30)

A first ceiling with the top 15 crashed Zig (exit 139): five of them
call themselves directly (`get_actual_type_variable`,
`is_type_reference_with_generic_arguments`, `maybe_type_of_kind`,
`has_matching_recursion_identity`, `is_type_parameter_at_top_level`),
and Zig expands a self-recursive `inline fn` until it overflows rather
than reporting it. Any cycle cut keeps a self-recursive function out of
line, so the rule cannot reach them.

Of the 69 cyclic functions, 9 call themselves, and they are among the
hottest: 1.64% of ts-pattern's self samples (4.7M calls) and 1.31% of
zod3's. **What the rule can reach is the other 60:** 2.10% and 2.87% of
self samples, 3.6M and 1.0M calls, a call cost at 6 cycles of 0.53% and
0.88%. **Revised estimate: 0.3–0.9%.** The self-recursive ones would
need something else: inlining the non-recursive entry (`if` tests that
answer most calls) into callers, with the recursion kept in a helper.

The ceiling (arm i) is the 15 hottest of the 60, none calling another
(checked).

## The ceiling timed (2026-11-02, 01:55–02:12): no gain

Arm i (`sf-ceiling/arm_i.py`): the 15 hottest of the 60 reachable
functions emitted `inline fn` in the base package, cross-built as a
plain binary. `.text` grows 87,504 bytes (11,044,073 to 11,131,577,
0.79%). On ts-pattern at one checker it makes 2.8% fewer calls (101.45M
to 98.62M) and 0.45% fewer instructions. Its output is base's on all
six projects at 1 and 4 checkers. Timed on pup by time-ab.sh
(`sf/inl.conf`), 60 rounds, with an A/A copy of base. Paired median time
and user cycles against base:

| | time | rounds faster | user cycles | instructions | A/A time |
|---|---:|---:|---:|---:|---:|
| ts-pattern, 1 checker | 0.31% slower | 25/60 | 0.32% more | 0.47% fewer | 0.05% slower |
| ts-pattern, 4 | 0.64% slower | 19/60 | 0.41% more | 0.46% fewer | 0.24% slower |
| zod3, 1 | 0.20% faster | 37/60 | 0.19% more | 0.64% fewer | 0.04% faster |
| zod3, 4 | 0.31% faster | 34/60 | level | 0.61% fewer | 0.25% faster |
| mitt, neverthrow, superstruct, tiny-invariant | 1.65% faster to 0.74% slower | | within 0.7% | 0.0–0.4% fewer | 0.15–1.38% |

Peak RSS is level. The calls saved (2.8M on ts-pattern) cost about what
the larger code takes back: cycles are level or slightly up, and
ts-pattern at four checkers is slower in 41 of 60 rounds. **The rule
change does not pay on Trig and is not proposed.** The 6-cycle call
cost assumed above overstated what inlining these functions saves:
their calls were already cheap, predicted, and leaf-like.
