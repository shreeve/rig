# Proving away Rig's checks: a survey and plan (2026-10-24)

The owner's order: remove the runtime checks Rig does not need, and let
LLVM know they are gone, "without trust-me hints". A team of experts
reading the code should conclude that the options were weighed and the
cleanest, fastest one was chosen.

The rule this plan keeps: **every check that goes is either proven by
`src/proofs.zig` and recorded once, or made unnecessary by the shape of
the emitted code**. No check is removed on a guess. No unproven fact
reaches LLVM: no `@setRuntimeSafety(false)` around unproven code, no
`assume`, `!range`, `nsw`, or `nuw` of a fact the compiler has not
proven. A check that can fail still fails where the source has it, with
its own message.

Sources: Rig main 0068bfa3b, Trig main a16e538 (stores on `Table`/`Slot`
since #186, symbol places #187). pup timing on core 6 with core 7 idle,
fastest of 10, interleaved, output byte-identical across variants. The
scripts, prototypes, and stand-in recipe are in
[checks-data/](checks-data/). The literature notes behind §3 are cited
inline.

## 1. Where the cost is now

The 2026-10-21 ceiling (11.2% on ts-pattern,
[safety-checks/measurement.md](../safety-checks/measurement.md)) is out
of date. Since then #538 dropped the length test, and Trig moved its
stores onto `Table`/`Slot` (3.5% faster) and its symbols into one record
(0.6% faster). Measured again with the same switch
(`RIG_MEASURE_UNCHECKED`, never landed: safety-checks/data/measure-switch.diff on
main, its two `main.zig` hunks redone by hand; [build.sh](checks-data/build.sh),
[ceiling.txt](checks-data/ceiling.txt)):

| project (first run) | every check removed: fewer instructions / fewer cycles / faster | index tests only: fewer instructions / fewer cycles / faster |
|---|---|---|
| ts-pattern | 11.6% / 6.4% / **7.4%** | 7.6% / 4.1% / **5.9%** |
| zod3 | 13.7% / 8.9% / **9.1%** | 8.8% / 7.7% / **8.9%** |
| tiny-invariant | 20.2% / 13.1% / **12.1%** | 14.3% / 10.9% / **9.6%** |

A second run read every check removed at 5.6% on ts-pattern (base
1331 ms against 1353 ms in the first); the instruction counts are the
same in both. **Index tests are about 80% of what is left.** Casts,
overflow, Zig's own bounds tests and the rest together are about 1.5%
on ts-pattern.

The census of the base binary has 122,497 check sites (143,584 on
2026-10-21): index 65,680, cast 23,805 (the length test is gone),
overflow 22,655, other 6,562, Zig's bounds 2,217.

**By family** (perf, 356,958 cycle samples over 8 runs of ts-pattern;
a sample counts toward a check site when it falls on the branch to a
panic or on the compare before it; attributed to the innermost frame
outside the runtime; [sites.py](checks-data/sites.py)). 4.39% of all
cycles fall directly on check branches. That share understates the
cost, which the ablation measures, but it shows where the cost is:

| family | share of check samples | kinds | example |
|---|---|---|---|
| symbol and id accessors | 31.4% | index 89% | `@program.bindings[@ids.sym_file_of(s)].symbols[Int(@ids.local_sym(s))]`, `@syms[@checker_symbol(s)]`, `@symbol_data[k]` |
| Map/Set probing (std) | 19.7% | index 57%, overflow 26%, cast 17% | `Map.find`: `@table.at[i]`, `@es[j]`, `Int(h & U64(ts.len - 1))` |
| other checker code | 15.0% | index 73% | `instantiate_type_with_alias`, `conditional_flow_step` |
| AST records | 11.5% | index 75%, overflow 17% | `@recs[n.id]` in `kind`, `pos`, `parent`; `1 + @more_declarations.len` |
| store spans | 11.0% | index 45%, overflow 29%, cast 26% | `type_at`: `@store.type_lists[Int(list.start) + k]` |
| other | 6.7% | | |
| allocator | 2.2% | Zig bounds | `freeSmall` |
| `text.Interner` | 1.8% | index | `@ends[i]` |

What this says: **most of what is left is a lookup by a stored id.**
Rig's proof pass works from facts about locals in one body. It cannot
reach an index that was read out of memory (`s` from `sym_loc`, `j` from
`@table.at[i]`, `n.id` from a node record): no guard in the body bounds
it. A flow proof does not remove these checks. A type does: an index
that cannot be out of range by construction, as `Slot` already is for
the stores.

## 2. What LLVM removes on its own, and where it stops

Prototypes: [shapes.zig](checks-data/shapes.zig) and
[span.zig](checks-data/span.zig), built `-OReleaseSafe` for x86_64-linux
and aarch64-macos with Zig 0.17. Each line was read from the assembly.

| shape | checks left | why |
|---|---|---|
| `recs[n]` twice, nothing between | 1 | same length value; the second compare folds |
| `recs[n]` twice, a call taking the `*const Ast` between | **2** | the length is loaded again after the call: Zig emits no type-based alias information, and LLVM must assume the callee wrote it |
| the same, with the List read once into a slice local | 1 | the length is a register; nothing can change it |
| guard `n < len`, a call, then `recs[n]` | **2** | as above: the guard's fact is about a length the call may have changed |
| `for k in 0..count`: `s[Int(start) + k]` | 1 per iteration | the bound is `count`, not the length; LLVM's default pipeline has no IRCE |
| the same as a `Span` (`start + count <= n` by construction), `k < count` tested | **0**, and the loop is unrolled 8x and vectorized | `k < count` is the loop's own test; IndVarSimplify folds it |
| `h & (n - 1)` into `n` slots, after `n != 0` | 0 | the mask is at most `n - 1`; the whole linear probe loop has no check |
| the same without `n != 0` | 1 | for `n = 0` the index would be out of range, so the test is real |
| `h >> (64 - b)` into `1 << b` slots | 1 | not folded |
| `@intCast` of a `u64` length to `u32` | 1 | a real test, unless the length's type is narrow |
| two-level `bindings[f].symbols[l]` | 2 | two independent stored indexes |

The pattern matches the survey's: **LLVM keeps every fact that lives in a
register and loses every fact about memory across a call or a store**.
ConstraintElimination (in the default pipeline) uses both edges of every
dominating branch and the induction facts of loops, and SCEV and
IndVarSimplify fold a check that runs on every iteration when the loop's
bound is the same value as the length. Inductive range check elimination
(IRCE) and loop predication are not in the default pipeline. Rig's proofs pay
exactly where LLVM stops: after calls and stores (Rig knows a read view
freezes what it views, Core sentences 5 and 6), and on indexes whose
bound LLVM cannot see. Panel B found the same
([expert-B-proof-ranges.md](../safety-checks/expert-B-proof-ranges.md) §0).

## 3. What other compilers do, and what carries over

| compiler | mechanism | carries over to Rig? |
|---|---|---|
| ABCD (Bodík, Gupta, Sarkar, PLDI 2000) | difference constraints `x - y <= c` from `x := len`, `x := y + c`, both edges of a branch, and a check that passed; solved on demand over e-SSA | the fact shapes, yes: they are proofs.zig's `below`/`nonneg`/G2. A demand-driven solver is not needed at Rig's scale |
| Go `prove` (cmd/compile, prove.go, loopbce.go) | a fact table with posets over SSA values, both branch edges, `len >= 0`, induction variables found by `findIndVar` | the same facts; Go reports what it proved (`-d=ssa/check_bce`), as `rig check --facts=proofs` does |
| .NET RyuJIT (assertionprop.cpp, rangecheck.cpp, loopcloning) | assertions keyed by value number; `a[x % a.Length]` and `a[a.Length - c]` in range by shape; **loop cloning**: one test before the loop picks a check-free copy or the checked one | cloning is Rig's flag (INTERNALS "Flags"), already built: the fast copy only where a test that ran says so |
| HotSpot C2 / Graal | range check elimination by pre/main/post loops; **loop predication** with deoptimization when the hoisted test fails | predication needs deoptimization; ahead of time the equivalent is the checked copy (Rig's flag). Moving a panic earlier is not allowed by Rig's rule |
| Swift (BoundsCheckOpts, RedundantOverflowCheckRemoval) | hoists checks to the preheader (they may trap earlier, which Swift accepts); "an op that did not trap" is a fact | the second, yes (G2). The first, no: a Rig panic stays where it is written |
| Rust | no bounds-check pass of its own: iterators (`slice::Iter` is two pointers), re-slicing once (`&s[..n]`) so the length is a register, `chunks_exact`; `Range::next` uses an `add nuw` proven by its own `start < end` | **the code shape is the proof**: iterate a slice, take a span once, then index it freely. Rig already lowers `for x in xs` to a Zig `for` with no per-element check |
| WebAssembly engines | reserve 4 GiB and guard pages, so a 32-bit index needs no test | Rig's `Table[T, n]` and `Slot[n]` (#536) |

Sources: ABCD, https://homes.cs.washington.edu/~bodik/ucb/research/pldi00.html;
Go, https://github.com/golang/go/blob/master/src/cmd/compile/internal/ssa/prove.go;
RyuJIT, https://github.com/dotnet/runtime/blob/main/src/coreclr/jit/rangecheck.cpp and loopcloning.h;
C2, https://github.com/openjdk/jdk/blob/master/src/hotspot/share/opto/loopPredicate.cpp;
Swift, https://github.com/swiftlang/swift/blob/main/lib/SILOptimizer/LoopTransforms/BoundsCheckOpts.cpp;
Rust, https://github.com/rust-lang/rust/blob/main/library/core/src/slice/iter.rs and https://github.com/Shnatsel/bounds-check-cookbook;
LLVM, PassBuilderPipelines.cpp, ConstraintElimination.cpp, IndVarSimplify.cpp, InductiveRangeCheckElimination.cpp, LangRef.

**What Zig emits matters for the reach-LLVM question** (checked against
the IR Zig 0.17 writes):

- With safety on, `a + b` is `llvm.sadd.with.overflow` and a branch; with
  safety off it is `add nsw`. ConstraintElimination and CVP turn the
  former into the latter when they can prove it.
- With safety off, `@intCast` is **`llvm.assume`** of the range, plus a
  `range` attribute on the result. That is the unproven hint the owner
  declined. It is sound only where the range is proven.
- `for (slice) |x|` makes no per-element test (one length-equality test
  for several slices).
- Narrow integer types carry their range structurally: a `u8` index into
  `[256]T` needs no test, and Zig emits no `!range` metadata anywhere.
- Zig emits no type-based alias information, so a length read through a
  pointer is reloaded after any store or call.

## 4. Techniques, ranked by the share they reach

The ranking, by the share of ts-pattern's time each reaches (the
ceiling is 5.6-7.4% across two runs). The subsections follow the build
order of §6, which puts what can be built today before what waits on
the owner.

| rank | technique | share (ts-pattern; zod3) | how it is known | status |
|---|---|---|---|---|
| 1 | 4.1 index types: `Span[n]`, AST nodes and binder symbols on slots | **1.3%; 3.8%** (x86), 1.9%; 3.7% (arm64) | stand-in build | Rig: `Span[n]`; Trig: the data moves |
| 2 | 4.4 Map/Set entry index (`find` handing back the entry) | about 1% | the 1.3-1.9% Map/Set ceiling of 2026-10-22, less 4.2's part | waits on the ownership limit's Core decision |
| 3 | 4.2 length arithmetic from `fits` | 0.2-0.4% | share of the sampled overflow and cast sites | buildable now |
| 4 | 4.3 facts that outlive calls and stores | 0.1-0.5% | ROADMAP's 0.1% for false edges and constant indexes; 0.5% for every proof today | buildable now |
| 5 | 4.5 check summaries across calls | not yet known | measure after 1, 3, 4 | later |
| 6 | 4.6 affine loop flags | under 0.1% | 16 sites | only if needed |

### 4.1 Index types that need no test, extended: `Span[n]`, and ids as slots (the large one)

**What it proves, and how.** Nothing at run time. The index's type makes
the check unnecessary, as `Slot[n]` does for `Table[T, n]` (#536): a
table of n slots holds all n from the start (reserved, zero-filled, and
resident only where written), and only the table makes a `Slot[n]`. Any
slot is in range of any table of the same n, so no test is needed.

Two extensions:

- **`Span[n]`, a run of slots a table made.** `t.append(xs) -> Span[n]`
  (and `sp.sub(a, b)`, tested once: `0 <= a <= b <= sp.count`). A span holds
  `start + count <= n` by construction. `t[sp]` is a read view `?[]T` of
  those slots, made with no test, and `t[sp][k]` is an ordinary slice
  index. Its test `k < count` is the loop's own test, which LLVM folds
  (span.zig: zero checks, and the loop unrolled and vectorized, against
  one check per iteration today). It is plain data like a slot, so a
  record can hold it. This is what Trig's `TypeList(start, count)`,
  `SymList`, `SigList` and the other spans into the store's
  `*_lists` are.
- **More stores on slots.** The AST's node records (`Node.id` into
  `Ast.recs`) and the binder's symbols (`Sym` into the program's
  bindings, through `Ids.sym_loc`) are the same pattern as the stores
  were: ids made by one append-only store, used everywhere. Two shapes
  fit `Table`/`Slot` as built: one program-wide table of binder symbol
  records (one `Slot` replaces `sym_loc[s]`, `bindings[f]` and
  `symbols[l]`), and a node table per file or for the program. Where an id
  is read back from a `U32` word (the AST's `words`), `Slot[n].of(w)` makes
  one test where it is decoded, not one at each of the record's fields.

**Families.** Symbol and id accessors (31.4% of check samples), store
spans (11.0%), AST records (11.5%): together **54% of the check samples**.

**Prototype on real Trig.** Stand-in builds: base's emitted Zig with the
reads made with no test, as a slot or a span would make them
([stand.sh](checks-data/stand.sh)). *typed1*: every AST record read
(`recs`), every store span read (`*_lists`), and every `Ids` list.
*typed2*: typed1, and the symbol lists (`bindings`, `symbols`, `syms`,
`symbol_data`), as one table of binder symbols and slot ids would make
them. Output byte-identical to base on every project.

| build | ts-pattern | zod3 | tiny-invariant |
|---|---|---|---|
| Mac (arm64), typed1 against base, fastest of 30 | 1.3% faster | 1.6% faster | 2.2% faster |
| Mac (arm64), typed2 against base | **1.9% faster** | **3.7% faster** | **5.6% faster** |
| pup (x86), typed2 against base, fastest of 10: time (instructions) | **1.3% faster** (3.6% fewer) | **3.8% faster** (4.5% fewer) | **1.8% faster** (8.0% fewer) |
| pup, every check removed, same run | 5.6% faster (11.6% fewer) | 8.8% faster (13.7% fewer) | 9.4% faster (20.2% fewer) |

So typed indexes in these three families reach about a quarter of the
ceiling on ts-pattern and over two fifths on zod3, with no proof at run
time. The Mac ran at load 3 to 12 (`tools/low`); a first Mac run at
load 8-10 read typed1 4% slower on ts-pattern and the next 0.7% faster,
so only the 30-round run is quoted.

**How it reaches LLVM.** Nothing to convey: the emitted code has no
compare (`&slots[s]`), and the span's view is a Zig slice whose length is
a register, so LLVM's own passes fold the loop's test.

**Who builds what.** Rig: `Span[n]` (the type, `append`, `sub`, the
view `t[sp]`), about the size of `Slot`'s first PR. Its open design
question is the committed fallback (wasm32, Windows), where a table holds
only a prefix: a slot past it reads a static zero, but a span past it
cannot be viewed as a slice; only a span made by another table can name
one. The AST nodes and binder symbols need nothing new from Rig, unless
Trig finds a gap (for example `NodeRec` declares no defaults, which the
zero rule needs, and the made fill stops at 64 MiB). The data moves are
Trig's design calls and Trig's performance plan: this record hands Trig
the measured share and the stand-in recipe.

### 4.2 Length arithmetic proven from `fits` (overflow and cast)

**What it proves.** The proof pass already knows, at every length read,
`0 <= s.len <= max_len` (`fits(s)`, which #538 made true by
construction). Since #538 LLVM no longer knows it, so arithmetic on a
length tests overflow again. Four new uses, each proven from facts the
pass has:

| use | proven by | example (hot) |
|---|---|---|
| `s.len + c`, `c + s.len`, `0 <= c <= 2^62` | `fits(s)` | `1 + @more_declarations.len` (ast `declaration_count`, 0.06% of cycles directly) |
| `s.len - c`, `0 <= c <= 2^62` | `fits(s)` | `ts.len - 1` in Map/Set `find`, `place`, `remove` |
| `U64(s.len - c)` | `fits(s)` and a guard `s.len >= c` (or `> c - 1`) on every path | `U64(ts.len - 1)` after the empty-table return |
| `Int(u & U64(m))` | `0 <= m <= max_len` (a length minus a constant, under the above) | `Int(h & U64(ts.len - 1))`: the home slot |

The third needs the guard on its **false edge** (`return none if
@table.tags.len == 0`), which the backlog item adds
(ROADMAP, "Bounds proofs from a guard's false edge"): a guard part
whose false edge leads to the rest of the block makes the negated fact
there, as Go's prove and ConstraintElimination do.

**Family.** Overflow and cast in Map/Set and AST. Of the samples on
overflow and cast branches (0.77% and 0.47% of cycles), these sites hold
about a sixth: the Map/Set home slot (449 samples), `declaration_count`
(209), `free_slot` (108), against 4,432 on all overflow and cast sites.
**Expected share: 0.2-0.4% on ts-pattern.** The whole non-index ceiling
is about 1.5%, and much of it is Trig's own counters (`KeyBuilder.n +=
4`), products such as the Map's `(@es.len + 1) * 5`, which `fits` does not
bound, and the length invariant's one test per growth in
`reallocSlice`.

**How it reaches LLVM.** The add as `rig.addProven` (`add nsw`, a proven
fact), and a proven conversion as `@bitCast` (signed to unsigned of a
non-negative value) or `@truncate` (a value that fits). Neither leaves an
`llvm.assume` behind. The proven index path's own
`@intCast` under safety off (`provenOffset`) leaves an assume of a proven
fact. That is sound, but under this plan's rule it becomes `@bitCast` too,
measured in the same PR.

### 4.3 Facts that outlive calls and stores

**What it proves.** Panel B's steps 1-3, which this plan keeps unchanged:
a check that ran, in any position that always runs, is a fact after its
unit (G2 generalized); places through read-view fields (`@prog.files[i]`);
a guard's false edge (shared with 4.2); a constant index after a length
guard (`xs[0]` under `xs.len >= 2`). Their soundness is the Core's: a read
view freezes what it views, so a call that is lent `?x` cannot change
`x`'s lengths. LLVM cannot know that, because Zig emits no alias
information (the `guard_then_call` prototype re-tests).

**Family.** Other checker code (15.0%) and the parts of every family
where the same index is used twice. **Expected share: 0.1-0.5%**
(ROADMAP: false edges and constant indexes measured at about 0.1%;
`RIG_NO_PROOFS=1` costs ts-pattern 0.5% for everything proven today).

**How it reaches LLVM.** Omitted, as every proven test is today
(`atProven`, `addProven`).

### 4.4 Map and Set probing

**What it proves.** Three separate pieces:

1. *A masked probe.* `i = (i + 1) & mask` after one `n != 0` test: LLVM
   folds every bound test of the probe loop (prototype `probe_loop`:
   zero checks). Today's form, two passes of a loop whose test is the
   bounds test, already has none, so this only simplifies the code.
2. *One length for `tags` and `at`.* `@table.at[i]` after
   `ts[i]` tests again, because they are two Lists. A table that keeps
   its tags and entry indexes as two columns of one allocation with one
   length (a two-column List) proves both with one test. Merging them
   into one record per slot would also do it, but the probe's scan of
   the tags would then read eight bytes a slot where it reads one.
3. *`@es[j]` with `j` read from `at[i]`*: a stored index again (4.1's
   kind), whose type would be an entry index only the Map makes. That is
   Panel B's decision 5 and the HANDOFF's ownership limit (`find`
   handing back the entry): owner decisions.

**Family.** Map/Set probing, 19.7% of check samples. The last measured
ceiling for every Map/Set check is 1.3-1.9% on ts-pattern; proving the
probe indexes alone gained nothing
([len-and-map-notes.md](../safety-checks/len-and-map-notes.md)). 4.2
takes this family's overflow and cast tests. **Expected share of 2: under
0.3%; of 3: the rest of the ceiling, about 1%, after the owner's Core
decision.**

### 4.5 Check summaries across calls (Panel B 2c, 2d)

An accessor's test repeated by its caller (`tree.kind(n)` then
`tree.pos(n)`), proven once by a summary of what the callee tests on
entry, and a twin of the callee with that test omitted. 600-900 lines.
4.1 removes most of its targets (AST and store accessors) by type.
**Not ranked until 4.1 and 4.3 land and the residue is measured
again.**

### 4.6 Affine loop flags (Panel B 2b)

`s[t + k]` for `k` in `lo..e`: one flag test `t + e + c <= s.len`, then
the check-free copy. It is the flag form of 4.1's span, for code that is
not a span (16 sites in the checker). **Under 0.1%; built only if a
program needs it.**

## 5. How a proof reaches LLVM, and what never does

| form | emitted Zig | what LLVM gets | decided by |
|---|---|---|---|
| proven index | `ptr[offset]` via `atProven`, or `atIf(.., ok)` under a flag | no compare (the flag's copy: unswitched) | proofs.zig fact |
| typed index | `&slots[s]`, `s` a `SlotOf(n)` | no compare | the type |
| span | `t.slots[start..][0..count]`, then `v[k]` | a slice whose length is a register; the loop's own test folds | the type |
| iteration | `for (xs.items()) \|x\|` | no per-element test | the shape (built) |
| mask | `h & (n - 1)` after `n != 0` | the AND bounds the index | the shape |
| proven add | `rig.addProven` | `add nsw` of a proven sum | proofs.zig fact |
| proven conversion | `@bitCast` / `@truncate` | no compare and no assume | proofs.zig fact |

Never: `@setRuntimeSafety(false)` on code a fact does not cover;
`@intCast` under safety off for an unproven range (Zig turns it into
`llvm.assume`); a range on a load or a parameter that the program does not
make true (the len-range patch the owner declined on 2026-10-22). Every
omitted test is still made in a debug build and under
`RIG_VERIFY_PROOFS=1`, which assert the proof ("a proven check failed
(compiler bug)"). `RIG_NO_PROOFS=1` writes every test, for the
differential run. A typed index's omitted test is asserted in debug
builds as `Slot`'s is (`s < n`).

Emit decides nothing: each fact is recorded once (`SemContext.recordProven`,
and for 4.1 the slot and span types), and emit reads it through
`Facts.provenOf`.

## 6. Build order

Each step is its own PR, measured on real Trig against main: exclusive
time, interleaved, fastest of 10, on pup (x86, core 6 with core 7 idle,
one release build at a time through Trig's slot lock) and on the Mac
(arm64, quiet). A step is kept only if it clears the speed bar on Trig
(more than 2% faster, or at least 1% fewer single-thread instructions and
no slower), measured on runs it was not tuned on. Steps 2, 4 and 5 are
each likely under that bar alone on Trig; each is measured as it is
built and, if it falls short, held and measured again together with the
next one that touches the same code, rather than landed for a gain in
the noise. Each step leaves `swarm test/rig.rip all` and Trig's light
gate green.

1. **`Span[n]`** (Rig, 4.1). The type, `append`, `sub`, the view
   `t[sp]`, the committed fallback, `rig check --facts` for it, cases
   (a span of another table of the same n; `sub` out of range;
   wasm32's fallback), SPEC and STD. It is measured on Trig's spans
   (`TypeList` and its siblings) moved onto it, in a branch, against
   main; whether and when Trig moves them on its main is Trig's call.
   **The first PR.**
2. **Length arithmetic from `fits`, and false-edge guards** (Rig, 4.2
   with 4.3's false edge). proofs.zig's uses for `s.len ± c`,
   `U64(s.len - c)`, `Int(u & U64(m))`; the guard's false edge; emit's
   `@bitCast` for a proven conversion (and in `provenOffset`). About
   150-250 lines. Measured on Trig, and on std.json and bench/hash,
   whose out-of-line functions lost the length's range with #538 (the
   overflow tests candidate A answered with a real test,
   consolidation/speed-baseline.md).
3. **Trig's side of 4.1** (AST nodes and binder symbols on
   `Table`/`Slot`, and its spans once `Span[n]` lands) is Trig's to plan
   and can start now; Rig answers what `Table` lacks.
4. **G2 generalized, read-view field places, constant indexes** (Rig,
   4.3; Panel B steps 1-2).
5. **Map/Set: a two-column table under one length** (Rig std, 4.4 item 2).
6. **Measure the residue again**, then decide 4.5 (summaries) and the
   Map's entry index (4.4 item 3) with the owner.

## 7. Owner decisions (defaults)

1. Build `Span[n]` as a std type beside `Table` and `Slot`, a run of
   slots a table makes, viewed as a slice with no test. Default: yes.
2. Proven conversions are written `@bitCast`/`@truncate`, so no
   `llvm.assume` is left even for a proven fact (including
   `provenOffset`'s). Default: yes, kept only if not slower.
3. Guards make facts on their false edge too. Default: yes, with step 2.
4. The Map's entry index and `find` handing back the entry wait for the
   ownership limit's Core decision. Default: wait; nothing here changes
   the Core.
5. Check summaries across calls (4.5). Default: not before step 6's
   measurement.
