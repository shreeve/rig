# std.json → Rig: where it stands, and what it needs from the compiler

From the "Rig - json.rig" session, which owns std.json. 2026-10-14.

## 1. Where std.json stands

Measured on the **honest harness** (#204): the benchmark calls `parse`
from two places, so the parser stays a function, as in a real program.
Exclusive timing, fastest of 15 interleaved runs, safe mode with every
check kept.

**Mac (Apple silicon):**
- Fastest of seven parsers on five of the six corpus files.
- On twitter, zimdjson is 5% faster (3584 vs 3419 MB/s), and it runs
  without safety checks.
- By geomean, std.json is 10% faster than sonic-rs, 26% faster than
  zimdjson, 44% faster than simd-json, 4.5x serde_json, and 4.9x Zig's
  std.json.

**x86 (pup):**
- On the old harness, std.json was about 1% ahead of sonic-rs by
  geomean, with citm and github 12% behind.
- The honest-harness table is built on pup and waits for an exclusive
  slot after #203.

**Next competitors:** simdjson (C++, DOM and On-Demand) and yyjson (C) are
built and smoke-tested in `bench/json/cbench`. Timing waits for a Mac
window.

**The owner's rule for std.json:** it never gets slower. Every change
must keep or improve its speed on both machines (within 2% is parity),
and should leave the code cleaner and leaner.

## 2. What holds it back, ranked by measured cost

### A. Doc state reached through `self` (RIG-NOTES 8): 3-12% time, the biggest item

- On the honest harness, main is 3-12% slower than with the parser
  inlined into `main` (7% by geomean on the Mac). It runs 7-18% more
  instructions.
- Minimal program (`rn8/field.rig`, `rn8/local.rig`, sent earlier): every
  push loads the List's pointer, len and cap from memory and stores len
  back. The `str len` takes 33-44% of samples, because each push waits on
  the previous push's store.
- This holds even for a local List, because push's slow path is
  `noinline fn grow(self: *Self, ...)`, which takes the List's address
  (src/runtime.zig:974).

**Fixes, in order:**
1. **`growval`** (your round, running). grow takes and returns the
   buffer by value, so a local List can live in registers.
2. **My follow-up.** `document` holds the tape in a local (`replace` out
   at its start, back at its end), and I time it against the speed rule.
3. **`noalias` for write views** (RUST-TRIAGE, "Should add soon"). While
   `document` holds `!self`, the ownership checker has already proved
   nothing else writes the Doc. Telling Zig so would let every Doc field
   stay in registers, with no restructuring in std.json. Please rank it by
   this measured 7% (12% on citm). It is the cleanest route to overtaking
   zimdjson on twitter.

### B. Choosing code by CPU (`target.arch`): 6% on x86, round running

`TIER = 0 if target.arch == .x86_64 else 16`:
- **x86**, exclusive: 6% faster by geomean, no file slower. twitter and
  github are 10% faster, which makes github tie sonic-rs.
- **Mac:** TIER=0 is 5-9% slower on three files, so the Mac keeps 16.

When the round lands, I set TIER, add tests, and time both machines.

### C. Cold paths (RIG-NOTES 7): 6-17% when inlined; owner's decision pending

- **`utf8_text`:** inlined into `document`'s loop, it cost 6-17% more
  instructions on five files, including files with no non-ASCII byte.
  Today it stays out only because it is too large to inline: size
  standing in for coldness.
- **`number` vs `utf8_text`:** they have the same structure but opposite
  temperatures. `number` is called 111,126 times per parse of canada;
  `utf8_text` is reached by at most 4% of strings, and by none in three
  files. No static rule can separate them.
- **New today:** every form of the whitespace bitmap for citm in one
  `document` costs the other files 7-15% in instructions. It does save
  citm 10-17%, so it fails the speed rule. The forms tried:

| form | twitter | gsoc | github | citm |
|---|---|---|---|---|
| bitmap run inlined | +14.5% | +9.6% | +13.2% | −17.0% |
| run kept out of line | +9.1% | +6.0% | +8.2% | −11.0% |
| flag held in a local | +10.1% | +6.8% | +9.0% | −9.7% |

  Holding the flag in a local doesn't help, so the cost is the call sitting
  in the hot loop (spills around it), not the flag's load. A way to mark
  the dense branch cold, or hot/cold splitting, is the missing tool.
  Specializing `document` instead (wsspec) needs `number` inlined in both
  copies. oncecall did that, but cost canada about 8% (#196, closed).

So citm, the last file behind sonic-rs on x86, waits on C (a cold marker
or inferred coldness) or on A (if registers stop being scarce, the call
may stop costing).

## 3. Smaller language gaps found today

- **A guard cannot bind** (RIG-NOTES 26). `return i + k if m.first() as k`
  fails with "unbound name `k`". Either the guard should bind, as
  `if … as` does, or the error should say that it cannot.
- **No byte write into a String.** `s[p] = b` is rejected, and `!s.set`
  does not exist. A test had to rebuild the string from slices. This may
  be intended (String is text); if so, the error could suggest the
  idiom.
- **A field and a method with the same name.** It is reported as
  "duplicate member", which is right, but downstream errors (an enum
  literal "needs a known type") pile on after it.

## 4. Lessons for the gates (now in RESULTS and RIG-NOTES)

- **Instruction counts are not speed** (RIG-NOTES 25). A vector
  whitespace skip ran 12-29% fewer instructions and was 32-41% slower
  (#199). guard.py would have passed it. Judge any hot-loop change by
  exclusive time on both machines.
- **Shared-core perf counts can mislead.** A 2-core, non-exclusive cycle
  count said TIER=0 made gsoc 11% worse; exclusive timing showed it 3%
  faster.
- **Harness shape matters.** A single call of `parse` let LLVM inline the
  parser and flattered std.json by 7%. #204 makes the honest harness the
  standard and re-baselines the guard. Every later round is judged on it.

## 5. What I need from Rig, in order

1. **`growval`.** Then I land the local-tape change in `document`,
   judged on the honest harness.
2. **`noalias` for write views**, first target `document`'s `!self`.
3. **`target.arch`.** Then TIER=0 on x86.
4. **The owner's decision on `cold`** (or inferred coldness), with C's
   data above. That unblocks the citm whitespace bitmap.

## 6. What I do meanwhile

- Time simdjson and yyjson on the Mac (honest harness), and the x86
  table on pup after #203.
- Move `bench/json/cbench` to its own PR after #204 merges.
