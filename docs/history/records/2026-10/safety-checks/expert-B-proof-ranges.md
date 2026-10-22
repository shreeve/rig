# Panel B: extending the proof pass (ranges, hoisting, slices, unwraps)

Design only. Everything below was measured on a build of `origin/main`
(3e3a88b02, 2026-10-21) unpacked in `probes-B/snap/`, against Trig
70c8cce. Probes, the ReleaseSafe asm harness, and the emitted Trig Zig are
in `probes-B/` (`p/*.rig`, `p/asm.sh`, `p/fn.sh`, `trigpack/out/*.zig`,
`trig-proofs.txt`).

## 0. What the measurements say first

**Where the checks are.** Trig's checker module, emitted (`trigpack/out/checker.zig`):

| Check | Sites written checked | Proven today |
|---|---|---|
| List index `.at/.slot/.constSlot` | 2532 | 404 `Proven` + 44 under a flag |
| slice index `rig.at/elemPtr` | 96 | 37 |
| array index `rig.index` | 4 | |
| length read `rig.len` (tests `len <= 2^62-1`) | 921 | |
| narrowing cast `@intCast(@as(u64, @intCast(...)))` | 105 | |
| widening cast `@as(i64, @intCast(@as(u32, x)))` | 2202 | (free, see below) |
| `rig.rem` (div by zero, `-1`) | 44 | |
| `rig.slice` (`a <= b <= len`) | 90 | |
| `.?`, `orelse unreachable`, bare-union access | **0** | |

The 2532 unproven List indexes, by index shape: a local 935 (of which 662 are
`program.files[f]` / `[file]`), `Int(x) - 1` 737 (all `files[Int(d.file) - 1]`),
`Int(u32)` 483, other expressions 240, literal 121, `Int(start) + k` 16.
**`program.files` alone is 1373 of 2783 static index sites** in the
checker's Rig source; `@store.types` is 236. In `ast.zig` the hot one is
`self.recs.at(n.id)` (491 sites, one per accessor function).

**What LLVM already removes** (ReleaseSafe asm of `p/ranges.rig` through
C-ABI wrappers so no input is constant; `p/fn.sh ranges FN`):

- `Int(a) + Int(b)` of `U32`s, `Int(x >> 3) + 1`, `Int(id / 256)`,
  `U8(x & 0xFF)`: no test at all.
- the lower test of `xs[Int(id)]`: gone; one unsigned compare remains.
- the `+= 1` of every `for` counter (685 in the checker): gone.
- `Int(start) + k` inside `for k in 0..Int(count)`: the overflow and lower
  tests are gone, **the upper test stays in the loop** (`sum`, `span_sum2`:
  `cmp x11, x8; b.hs` every iteration). LLVM's default pipeline has no
  range-check elimination (IRCE); it hoists only what Rig's flags make
  invariant (`range_sum`: unswitched, the fast loop has no bounds test).
- a repeated `db.recs[i]` after **any call**, even one taking `*const Db`,
  or after a write of another field: re-tested (`p/repeat.rig`,
  `two_reads_call`, `two_reads_write`, `file_twice`). LLVM must assume the
  call or the store may change `recs.len`; Rig knows it cannot.

So the proof pass pays exactly where LLVM's alias analysis and loop
passes stop: **after calls and stores, and across loop iterations**.
Local type ranges are something LLVM already exploits; a Rig value-range
analysis aimed at them would remove almost nothing. This explains
today's 0.5%: most of the 470 proven sites are `for i in 0..xs.len`
loops whose test LLVM could often drop too.

## 1. Ranges from types

### Rule

Not a general value-range analysis. Two narrow pieces:

**1a. Index terms.** Today a fact's subject is an own `Int` binding `i`
and a use's index is `i` or `i + c`. Widen the subject to a *term*, a
positive list of pure expressions whose value changes only where a
recorded write of its root says so:

| Term | Root(s) | Range it carries |
|---|---|---|
| `i` (own `Int` local or param) | `i` | none |
| `Int(u)`, `u` an own unsigned local/param | `u` | `0 <= t <= U.max` |
| `d.f`, `Int(d.f)`, `d` an own object (or read view of one) held by value, `f` a plain integer field, through fields held by value | `d` | `0 <= t <= U.max` when `f` is unsigned |
| any of the above `± c`, `c` a literal `<= 2^62` | same | shifted |
| `t & m` (`m` a literal `>= 0`), `t % m` (`m` a literal `> 0`), `t >> s` of an unsigned `t` | same | `[0, m]`, `[0, m)`, `[0, U.max >> s]` |

A term is compared by structure (same root symbol, same field path, same
conversion, same constant), interned per body like `Pass.paths`. Facts
`nonneg`, `below`, `eq` take a term where they took a `SymbolId`. The range
a term carries from its type is a *source* of facts (`nonneg(Int(u))`
always; `below(Int(u), 0, int(U.max))` as a constant bound), which the
existing `addFits` uses for `t + c` (`Int(u32) + c` cannot overflow). This
replaces the special case `fromUnsigned`.

**1b. Length reads of a List.** `rig.len(xs.len)` tests `len <= 2^62-1` at
each of 921 checker sites; LLVM cannot know a loaded `len` is small.
Every List's length is at most its capacity in elements, which the
allocator bounds far below `2^62` for any element of at least one byte.
Make that a runtime invariant of `ListOf` (`invariant(len <= max_len)`
after growth, and a real test only in `push` of a zero-sized `T`), and
have emit write `xs.lenInt()` for a List place. This is a fact of the
type, not of the flow; it costs no proof-pass code. Slices from Zig keep
the test.

### Kills

A term dies with any recorded write of its root (as `below(i, ...)` dies
with a write of `i` today); a field term of `d` dies with any write of `d`
(store into `d.g` too: conservative, as `Kills.movesLen` treats paths). A
read view root cannot be written in the body (Core sentences 5, 6).

### How emit uses it

Unchanged: emit reads `provenOf` on the index or add node. The runtime's
`atProven(i: Int, ...)` already takes an `Int`; a `U32` index `n.id` is
written `@as(Int, n.id)` there (one cast emit already writes for
`Int(u)`). No decision moves to emit.

### Debug assertion

Unchanged: `provenOffset` and `addProven` assert under `verify_proofs`.
`lenInt` asserts the invariant in debug (`invariant`).

### Coverage

Alone, ~0: LLVM drops these. It matters as the vocabulary 2 and 3 need:
737 `files[Int(d.file) - 1]` and 483 `[Int(u32)]` sites become subjects a
fact can be about. 1b: 921 length tests in the checker, 94 in ast, 158
in parser, each a shift and a branch.

## 2. Hoisting

Flags already hoist two loop shapes (INTERNALS "Flags"). Three extensions,
smallest first.

### 2a. "A check that ran", in any position that always runs (G2 generalized)

**Rule.** Today G2 fires only for `x = s[i]` (the index is the whole
value). Make it: every index (and `read`/`write`) in a unit at a position
that runs whenever the unit completes normally makes, on the unit's exit,
`nonneg(t)` and `below(t, c + width, len(s))`, unless `K(u)` ends it.
"Always runs" is a positive list (`rig.alwaysRuns(node, unit)`): operands
of operators but `and`/`or`'s right side, `??`'s fallback; call receivers
and arguments; field and index bases; constructor arguments; an
assignment's value and target. Not: a value `if`/`match` branch, a `catch`
handler, a closure body, a value loop's body, anything after a `?`/`!`
that may leave (a leaving path never reaches the next unit, so this one is
actually fine, but the list stays positive).

**Places through read-view fields.** `lenPlace` walks fields held by
value only, so `@prog.files[i]` is never a place (`p/viewfield.rig`:
`view_guarded` proves nothing, while `program = @prog; program.files[i]`
does). Allow a field whose type is a read view `?T` in the path: the
viewed owner cannot be written while the view lives (Core 5, 6), and the
field itself is reassigned only by a write of its holder, which is a
recorded write of the root. A write view field or a `*T` handle in the
path stays excluded (another holder of the handle may write it).

**Soundness.** The check ran (or the program stopped) on every path that
completes the unit; facts are added only after the unit and only if
nothing in `K(u)` names a root of the term or moves the length, exactly
as G2 today. A length cannot change after the check inside the unit
without a write in `K(u)`.

**Coverage.** 470 of 2783 static index sites in the checker repeat a
(place, index text) already indexed earlier in the same function (166 on
`files`, 46 `@inference_infos`, 30 `@inference_contexts`, 14 `types`);
writes between will kill some, so ~300-400. This is the case LLVM loses
after calls (`p/repeat.rig`).

### 2b. Affine loops: `s[t + k]` with a loop-invariant term `t`

**Rule.** A new flag shape: `for k in lo..e` (not `..=`) whose body
indexes `s[t + k + c]`, `t` a term (1a) the loop does not write, `e` a pure
term (a local, `Int(u)`, `d.f`, `s.len`; not a call, so the flag may read
it again before the source unit does), and `s` a place whose length the
loop does not move. Flag tests: `nonneg(t)` (dropped when `t` is unsigned
by type), `nonneg(lo)`, and `t + e + cmax <= s.len`, computed in `i128`
(`rig.okBelowSum(t, e, cmax, len)`) so the test cannot overflow. Under the
flag the walk holds a two-term fact `belowSum(t, k, cmax + 1, len(s))`
(from the binding's `below(k, 1, int(e))`), which proves `upper`, and
`lower` from `nonneg(t)` and `nonneg(k)`, and `no_overflow` of `t + k`
(`t + k < t + e <= len <= max_len`).

**Fit.** `Below` grows an optional second term (`i + j + k <= b`); `meet`,
`put`, and `derive` treat `(i, j)` as the key. `derive` stays one step.

**Emit.** As today: `atIf(..., flag)`; the add as `rig.addIf`.

**Coverage.** 16 sites in the checker (the `*_list_items` copy-outs and
`slice` helpers), each in a loop. Small alone; it is the shape 2c needs.

### 2c. Check summaries across calls (the large one)

Not in today's model, and the one that reaches Trig's hot loops. 366
calls `c.type_at(list, k)` (and the other `*_at`) sit in `for k in
0..list.len()` loops; 849 calls of `ast` accessors (`tree.kind(n)`,
`tree.flags(n)`, each `@recs[n.id]`) of which 341 repeat a node already
asked about in the same function; and `f` is passed down to callees that
each do `@program.files[f]` again.

**Rule.**
- *Entry checks.* For a function `F` that `calledFn` names (direct, not
  generic, not a closure or api method), record the index checks it makes
  on every path before it returns, whose term and place are built only
  from its parameters (`@` included) and whose place's root is a read
  view (`?@`, `?T`): `Entry(F) = { below(Int(list.start) + k, 1,
  len(@store.type_lists)), nonneg(...) }`. Found with the bodies, callees
  first, as `Summaries` finds result bounds.
- *After a call* (G2 across calls): a call unit of `F` whose arguments are
  terms gives the caller `Entry(F)`, substituted, on its exit. `F` made
  the test and wrote nothing of its read-view roots.
- *Before a call*: when the caller's facts prove all of `Entry(F)`
  substituted, the call is recorded `entry_proven`, and emit calls `F`'s
  twin, written from the same body with those checks as `atProven`
  (asserted in debug). Twins only for functions the inliner already
  inlines (`src/inlining.zig`), so no code grows after inlining.
- *Loops:* 2b's flag shape takes `Entry(F)` of a call in the body as the
  index it would have hoisted.

**Kills.** The read-view root of `Entry(F)`'s place must be unwritten
between the facts and the call, as for any fact. In 250 of the 350
accessor loops the body writes `!@` (makes types), which ends every fact
about `@store`. Those need **2d**.

### 2d. Lengths that only grow (owner decision)

A per-function effect summary: for each List field path of a parameter
type, whether `F` (transitively) may shrink it (pop, clear, truncate,
assign the field, lend it to an unsummarized function, `raw`, move out).
A write that may only grow `s` keeps `below(_, _, len(s))` and
`fits(s)` (a length that grew still exceeds the bound) but ends `eq(n,
s)`. Trig's store is an append-only arena, so its `!@` calls would keep
every bound on `@store.*_lists`. ~300 lines; unlocks the 250 writing
loops. Its soundness rests on the summary being a positive list of
grow-only operations (`push`, `reserve`, element store), with everything
else, including unknown calls, counted as a shrink.

## 3. Slice once, then index freely

**Built.** `s = xs[a..b]`, then `for i in 0..s.len: s[i]` is proven today
(`p/tags.rig`, `slice_then`: `atProven(s, i, .both)`).

**Missing, small:**
- *A constant index after a length guard:* `if s.len >= 2` then `s[0] +
  s[1]` tests both (backlog: 121 such sites in the checker). Rule: a
  literal index `c` is the term `0 + c` of a constant zero subject that is
  always `nonneg` and never written; the guard `s.len >= 2` already makes
  `below(0, 2, len(s))` once the zero subject exists. ~40 lines.
- *The slice's own test:* `xs[a..b]` tests `0 <= a <= b <= xs.len` (90
  `rig.slice` in the checker). A new `Use.slice` proven by `nonneg(a)`,
  `below(a, 0, int(b))`, and `below(b, 0, len(xs))`; and, as a check that
  ran, it makes those three facts and `eq`-like `s.len == b - a` for
  later. Emit: `rig.sliceProven`. ~80 lines; coverage not sampled, likely
  a few dozen.

Trig's own "slices" are `TypeList(start, count)` spans into store Lists,
not Rig slices; those are 2b-2d.

## 4. Optional unwraps and union tags

**Nothing to do.** Rig writes no checked unwrap: `a ?? b` is `orelse b`,
`if a as x` is `if (a) |x|`, `a?` is `orelse return null`, a niche
optional goes through `rig.some` (a compare the program asks for), and
`match`/`if s as .circle(r)` is a `switch` with a payload capture on a
`union(enum)` (`p/tags.rig`). The emitted checker has 0 `.?`, 0 `orelse
unreachable`, 0 bare unions. If the measuring agent finds unwrap or tag
cost, it is in Zig std code or hand-written shims, not in emitted Rig.

## 5. Soundness, and what a reviewer should try

The argument is today's (INTERNALS "Proven checks"): a fact holds after a
unit only if a test made it and no write in `K(u)` names its roots; writes
are recorded at every site (Core 4, 9); a view freezes what it views (Core
5, 6). Each extension adds to the positive lists and keeps the rest.

Adversarial cases:
- **Aliasing writes:** `a = xs[i].f; g(!xs); b = xs[i].g` (must test
  again); `!d` lent to a call between two `d.f`-term uses; `bump(!db)`
  between two `db.recs[i]` (`p/repeat.rig`, must stay tested: today's
  rule, a write of the root, ends it).
- **A check not always run:** `ok and xs[i] > 0` then `xs[i]`; `x ?? xs[i]`;
  a value `if` branch; a closure body that indexes and is never called.
- **Loops that change `len`:** `push` or `pop` in an affine loop's body;
  `!@` call in an accessor loop (must kill without 2d); with 2d, a callee
  that calls `clear` through two levels, or through a closure (an
  unsummarized call counts as a shrink).
- **Overflow inside the fact:** `t + e + cmax` with `t` near `Int.max`
  (flag test in `i128`); `Int(u64) + k` (an unsigned 64-bit term carries
  no `max_len` margin: `U64.max` is not `<= 2^62`, so no `no_overflow`);
  `t & -1` (mask must be a literal `>= 0`); `t % m` with signed `t`
  (negative remainder: only for unsigned `t`).
- **Views:** a read-view field reassigned by a `!@` call between facts and
  use; a place through a `*T` handle (must stay excluded: another handle
  holder writes it); a write view field.
- **Twins:** a callee whose check is on only one path (`return 0 if k <
  0` before it: not every path, no entry check); recursion; a callee in a
  module checked later (summaries callee-module first, as result bounds).
- **Tasks:** a task holding a write view cannot coexist with this body's
  read view (Core); handles pin to one thread but stay excluded.
- **`raw`:** ends everything, as today.

## 6. Tests

- `test/rig/proofs*.rig.test`, with `# proves:` / `# keeps:` marks
  (`test/cli/facts_proofs.sh` reads them), per rule: one proven, one each
  killed by an aliasing write, a not-always-run position, a length
  change.
- `code` cases that the test is gone: `"atProven(i, .both)"` after two
  reads of one index around a read-only call; `"rig.okBelowSum("` for an
  affine loop; `"__rig_proven"` twin for a repeated accessor.
- `bomb` cases that a real failure still fails where written: an affine
  loop with `start + count > len` (flag false; message "index out of
  bounds", never "a proven check failed"); a twin called where the
  caller's facts do not hold.
- Extend `test/matrix.py`'s `proof.` grid with term subjects, and its
  `unit.` grid with a write of the term's root in every slot.
- The differential run (`swarm test/rig.rip proofs`) covers debug vs
  `--release` vs `RIG_NO_PROOFS=1` unchanged; add a per-rule env switch
  (`RIG_NO_PROOFS=terms,affine,summaries`) so Trig can measure each.

## 7. Order and size

| Step | Work | Size | Coverage in Trig's checker |
|---|---|---|---|
| 1 | 1a terms + 2a G2 generalized + read-view field places | 300-450 lines, proofs.zig and a `rig.alwaysRuns` | ~300-400 of the 470 static repeats |
| 2 | 3: constant index, slice test | ~120 lines + `rig.sliceProven` | 121 + a few dozen |
| 3 | 1b List length invariant | ~30 lines runtime + emit | 921 length tests (1173 in checker+ast+parser) |
| 4 | 2b affine loop flags | ~150 lines + `rig.okBelowSum` | 16, per iteration |
| 5 | 2c check summaries + twins | 600-900 lines (proofs, sema record, emit twin) | 341 repeated accessor calls, 100 read-only accessor loops, `files[f]` passed down |
| 6 | 2d grow-only effects | ~300 lines | 250 writing accessor loops |

Measure Trig after each step (pup, core 3, fastest of 10, interleaved);
steps 1-4 are probably under 1% together, judged by today's 0.5% for 470
sites. Steps 5-6 reach the per-iteration and per-accessor tests and are
where a real fraction of the 11-16% can be, but each must clear the
"speed feature pays for its lines" rule. Before step 5, get the ceiling:
a Trig build whose runtime omits only the index tests (`index`,
`indexOf`) bounds what any proof work can win.

## 8. Owner decisions (defaults)

1. Check summaries with proven twins of inlined functions (2c). Default:
   yes, after steps 1-4 are measured.
2. Grow-only effect summaries (2d). Default: build only if 2c's
   measurement shows the writing loops matter.
3. A List's length as a type invariant, so `xs.len` stops testing the
   `2^62` margin (1b). Default: yes.
4. Places through read-view fields (2a). Default: yes; it follows from
   Core 5-6 and needs no Core change.
5. Typed indexes of append-only Lists (an ID valid by construction).
   Default: no; a type-system feature, out of the proof pass. The
   Trig-side alternative (passing `tree: ?Ast` instead of a file index
   `f`, which removes the `files[f]` lookups) is Trig's call.
6. A guard's false edge (`return 0 if i < 0` making `nonneg(i)`), the
   backlog item: default yes, with step 1, since Trig's early-return style
   puts most of its guards there (`p/viewfield.rig`, `own_guarded`).
