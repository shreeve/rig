# What Trig pays for its safety checks (Mac, c1)

Trig faeb512b, built three ways from Rig 383a1b2b5 on 2026-11-23. None of these builds is
meant to land.

| arm | Rig | Zig mode | Rig's own index, slice and length checks |
|---|---|---|---|
| **checked** | 383a1b2b5 (`tools/baseline 383a1b2b5`) | `-Osafe` | on |
| **zigfast** | 383a1b2b5 + `zigfast.patch` | `-Ofast` | on |
| **ceiling** | 383a1b2b5 + `ceiling.patch` | `-Ofast` | off (`unreachable`, so the optimizer treats them as facts it can assume) |

checked→zigfast is what Zig's own checks cost: integer overflow, `@intCast` conversions,
Zig's slice bounds, union tags, optional unwraps, alignment. zigfast→ceiling is what Rig's
runtime index, slice and length checks cost. All three builds print byte-identical stdout on
all six runs (checked with `cmp`, and by SHA-1 on every timed run).

## The patch (`ceiling.patch`, two files)

- `src/main.zig` `Mode.zigFlag`: `.safe => "-Ofast"` (it was `-Osafe`).
- `src/runtime.zig`: `indexPanic`, `slicePanic` and `lenPanic` become
  `if (!builtin.optimize.runtimeSafety()) ceilingUnreachable else <the old fn>`. Here
  `ceilingUnreachable` is an `inline fn` whose body is `unreachable`. Every checked helper
  (`index`, `indexHeld`, `indexBelow`, `List.at/slot/constSlot`, `rig.at`, `bounds`,
  `atProven` with one test left, the `*If` forms, `heldLen`) goes through one of these three
  functions.
- I did not change emit. Emit already writes plain `+`, `@intCast`, `@divTrunc` and `.?`, and
  Zig's safe mode is what checks those, so `-Ofast` removes them.
- `zigfast.patch` is the same patch with `ceiling_unchecked = false`.

Proof that the checks are gone: in `called fun pick(xs, i, s, a, b)` (a List index, a byte
index, `+`, `*`, `U8(a)`), the checked build has `cmp; b.hs indexPanic` and three
`adds; b.vs integerOverflow`. The ceiling build is `ldr; ldrb; add; add; ret` (7
instructions). Counted over the whole Trig binary (`tools/panics.py`, which counts the
conditional branches whose target reaches a panic call):

| binary | instructions | cond. branches | to a panic | parser+lexer instr. | parser+lexer branches | to a panic |
|---|---:|---:|---:|---:|---:|---:|
| checked | 2,824,186 | 410,679 | 100,427 (24%) | 135,768 | 20,141 | 6,468 (32%) |
| zigfast | 2,757,637 | 370,090 | 60,456 | 127,084 | 16,495 | 3,222 |
| ceiling | 2,584,530 | 309,375 | 7,050 | 111,959 | 12,184 | 49 |

What the ceiling keeps is `table.fullPanic` (a full Table), `oom`, and `bytesPanic` (180
sites, from `read`/`write` of N bytes, which I did not patch). None of those is an index,
overflow or conversion check. Removing the checks makes the code 8.5% smaller.

## Measurements

Command, run from the project's folder:
`/usr/bin/time -l env -u TRIG_PREBUILT_LIBS BIN --singleThreaded [--noCheck] --noEmit -p CFG`.
11 rounds, the three arms interleaved with the order rotating each round, medians, all under
`tools/mac-claim --minutes 15 rig-ceiling-ab3 python3 tools/measure.py 11 runs3.tsv checked=… zigfast=… ceiling=…`.
Raw rows are in `data/runs3.tsv`. An earlier two-arm board (`data/runs.tsv`, `data/sum-run1.md`) agrees to
within 1 to 3 points. `/usr/bin/time` reports wall time only to 10 ms, so the short runs'
wall times are coarse. Read the cycles columns.

### checked vs ceiling (everything off)

| project | mode | checked instr. | ceiling instr. | fewer instructions | checked cycles | ceiling cycles | fewer cycles | checked wall s | ceiling wall s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Compiler | noCheck | 0.793B | 0.689B | 13.1% | 0.205B | 0.191B | 6.4% | 0.05 | 0.04 |
| Compiler | full | 1.956B | 1.713B | 12.4% | 0.541B | 0.500B | 7.5% | 0.13 | 0.12 |
| webpack | noCheck | 2.993B | 2.666B | 10.9% | 0.811B | 0.770B | 5.0% | 0.19 | 0.18 |
| webpack | full | 11.777B | 10.379B | 11.9% | 3.208B | 2.989B | 6.8% | 0.75 | 0.70 |
| supabase-studio | noCheck | 14.271B | 13.225B | 7.3% | 4.034B | 3.931B | 2.6% | 0.95 | 0.92 |
| supabase-studio | full | 47.437B | 43.308B | 8.7% | 12.959B | 12.562B | 3.1% | 3.05 | 2.98 |

### Split: Zig's checks (checked→zigfast) vs Rig's index checks (zigfast→ceiling)

| project | mode | fewer instructions, Zig's checks off | fewer instructions, then Rig's index checks off | fewer cycles, Zig's | fewer cycles, Rig's |
|---|---|---:|---:|---:|---:|
| Compiler | noCheck | 2.5% | 10.8% | 1.3% | 5.3% |
| Compiler | full | 2.0% | 10.6% | 1.7% | 5.9% |
| webpack | noCheck | 3.2% | 7.9% | 3.2% more | 8.0% |
| webpack | full | 2.4% | 9.7% | 1.8% | 5.1% |
| supabase-studio | noCheck | 3.1% | 4.4% | 1.3% | 1.2% |
| supabase-studio | full | 2.0% | 6.8% | 1.1% | 2.0% |

(The full tables, with wall times, are in `data/sum-checked-zigfast.md` and `data/sum-zigfast-ceiling.md`.)
The zigfast arm's cycles on webpack --noCheck are within the noise of a 0.2 s run.

**Rig's own index, slice and length checks cost about three to four times what Zig's
overflow, conversion and other checks cost.** Rig's: 4 to 11% of instructions and 1 to 8% of
cycles. Zig's: 2 to 3% of instructions and about 1 to 2% of cycles. The checks cost about
half as much in cycles as in instructions: they are well predicted, so they ride along in
spare issue slots.

## Where it goes: profile of webpack --noCheck, c1

`xctrace` Time Profiler, 20 checked runs and 12 ceiling runs, about 1 ms samples
(`tools/leaf.py`; inlined frames are folded into the real function).
Frame-pointer-less task stacks make inclusive time unreliable, so these figures are self
time.

| area | checked ms/run | ceiling ms/run | less time |
|---|---:|---:|---:|
| system (libc, kernel: openat, fstatat, memmove, read) | 66.3 | 58.8 | noise |
| parser | 40.0 | 35.8 | 11% |
| lexer (scanner) | 32.1 | 29.4 | 8% |
| binder | 30.2 | 26.0 | 14% |
| other Trig | 26.5 | 24.3 | 8% |
| ast | 21.2 | 18.3 | 14% |
| rig runtime / std | 21.1 | 17.0 | 20% |

Check kinds weighted by where time goes (each function's branches to a panic per
instruction × its self samples; `tools/weighted.py`), for all of Trig, then for
parser+lexer+ast alone:

| kind | all | parser+lexer+ast |
|---|---:|---:|
| Rig index (`indexPanic`: List, String, array) | 58% | 59% |
| conversion (`@intCast`: `U32(…)`, `I32(…)`) | 14% | 20% |
| integer overflow (`+`, `-`, `+= 1`) | 12% | 10% |
| Rig slice (`s[a..b]`) | 6% | 8% |
| Zig slice and other bounds | 5% | 2% |
| other (alignment, unwraps, union tags, `unreachable`) | <2% | <1% |

Hottest parser/lexer/ast functions in the checked build (`data/hot-checked.txt`):

| self | function | instr. | branches | to a panic | kinds |
|---:|---|---:|---:|---:|---|
| 7.6% | lexer.Scanner.scan | 239 | 36 | 7 | index 5, slice 2 |
| 3.1% | parser.Parser.create_identifier_with_diagnostic | 614 | 100 | 30 | conversion 11, index 8, slice 6, overflow 4 |
| 2.1% | ast.Ast.set_parent_of_children | 2491 | 525 | 338 | index 338 |
| 1.5% | lexer.Scanner.scan_comment | 677 | 144 | 28 | overflow 10, index 10 |
| 1.3% | ast.Names.intern_hashed | 997 | 192 | 26 | index 13, conversion 7 |
| 0.9% | ast.Binding.index_flow_runs | 453 | 85 | 24 | index 17 |
| 0.9% | parser.Parser.finish_source_file_worker | 2388 | 436 | 188 | index 121, conversion 27 |
| 0.7% | parser.Parser.parse_literal_expression | 1687 | 276 | 76 | conversion 39, index 15 |
| 0.5% | parser.Parser.parse_statement | 4246 | 564 | 187 | conversion 120, index 67 |

In the ceiling build, Scanner.scan went from 18.1 to 14.7 ms per run, and
create_identifier_with_diagnostic from 7.5 to 5.1. Most of the parser's checks are not
written in parser.rig. They come from ast.rig's helpers inlined into it (`new_node`,
`add_text`, `finish_node`, `set_original_keyword_kind`, `parent_child`).

## Checks left in the parser and scanner (static)

`rig check --facts=proofs src/parser` and `src/lexer` (normal Rig, the scratch main.rig's src)
list only the proven tests: 88 in parser and 74 in lexer (83 index, 3 read, 22 `+`, 35 `+=`,
19 under a flag). The tests the proof pass leaves are counted from the emitted Zig
(`tools/srccount.py`, call sites; `data/srccount.txt`):

| check | parser.zig | lexer.zig | ast.zig |
|---|---:|---:|---:|
| List index, unproven | 22 | 3 | 714 |
| List index, one test left (`Proven .lower/.upper`) | 35 | 12 | 87 |
| List index, proven both | 20 | 4 | 21 |
| List index under a flag (`*If`) | 9 | 6 | 446 |
| String/slice index, unproven (`rig.at`) | 12 | 68 | 38 |
| String/slice index, partly proven | 21 | 9 | 9 |
| Array index (`indexBelow`) | 0 | 12 | 80 |
| Slice `s[a..b]` | 68 | 56 | 34 |
| Narrowing conversion | 14 | 16 | 192 |
| `+` / `-` / `*` (Zig overflow) | 81 | 171 | 313 |
| `+=` / `-=` / `*=` | 44 | 229 | 100 |
| `+` proven (`addProven`) / under a flag | 15 / 0 | 42 / 4 | 8 / 292 |

## The patterns that most need proving

Rig's own index checks cost most, so they come first.

1. **Node handles into grow-only parallel Lists** (ast): `@recs[n.id]`, `@locs[n.id]`,
   `@words[d + k]`. A `Node` is made only by `new_node`, as `U32(@recs.len - 1)`, and
   `recs`/`locs` never shrink, so every `n.id` is in range for good. This is the largest
   item: 714 unproven List indexes in ast.zig, 338 panic branches in
   `set_parent_of_children` alone. It wants a handle type tied to its List, or `Table` +
   `Slot`, which emit already writes with no test.
2. **One range test for several adjacent words**: `parent_child(d), (d+1) … (d+5)` against
   `@words`. One test that `d + 5 <= len`, made per arm, would cover all six indexes and all
   five `+` overflows.
3. **Narrowing of lengths and positions**: `U32(xs.len)` and `U32(xs.len - 1)` for new ids,
   and `I32(pos)` / `I32(end)` in `finish_node`. These are three tests each: the `- 1`
   overflow, the sign, and the u32 range. A List or text whose length is bounded below 2^31
   or 2^32 proves them. This is 20% of the weighted checks in the parser.
4. **Cursor fields of self** (scanner): `@body[@pos]`, `@pos += 1`,
   `@body[@token_start..@pos]`. An object invariant `0 <= token_start <= pos <= body.len`
   would remove the index, the slice and the overflow checks in `scan`, `scan_comment`,
   `scan_identifier` and the jsdoc scanners. Today's proofs reach only locals.
5. **Counters**: `count.* += 1` (identifier_count and the like). Each one's overflow test is
   cheap, but it sits on every token.

**Conclusion.** The whole ceiling is 7 to 13% of instructions and 3 to 8% of cycles, and it
is mostly Rig's own index checks. Patterns 1 to 3 cover most of it. The fix is the proof pass
and bounded or handle-typed Lists, not an unchecked build.

## Files and commands

- `tools/build.sh NAME RIG`: c8-check/build.sh without the checkerpool swap. It ran `checked`
  (1668 s, including the queue), `ceiling` (2153 s) and `zigfast` (573 s).
- `patches/ceiling.patch`, `patches/zigfast.patch`: the Rig patches, applied on a detached worktree at
  383a1b2b5, built with `tools/heavy zig build -Dnexus=…`.
- `tools/measure.py`, `tools/summary.py`: the board. `data/runs3.tsv`/`data/runs.tsv` are its raw rows,
  and `data/sum-*.md` its tables.
- `tools/leaf.py`, `tools/groups.py`, `data/groups.txt`: the profile (its `prof-*.tsv` were not kept).
- `tools/panics.py`, `tools/hot.py`, `tools/weighted.py`, `data/static.txt`, `data/hot-checked.txt`,
  `data/weighted.txt`: the panic-branch census of the disassembly
  (`objdump -d --section=__text --section=__rig_text`). Trig's code is in `__rig_text`.
- `data/proofs-parser.txt`, `data/proofs-lexer.txt`, `data/srccount.txt`: the proof dumps and the counts of
  unproven tests.
- Each arm's stdout per project and mode was identical (not kept).
