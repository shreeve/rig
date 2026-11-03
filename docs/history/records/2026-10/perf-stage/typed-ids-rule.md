# Ids typed by their container (design note for the owner, 2026-11-02)

Beat-tsrs item 1, default 2 of phase-b.md. No code. The measurements
are phase-b.md's, plus one more arm below.

## The rule is already in CORE

CORE §5, **Tables** *(built)*: a `Table[T, n]` holds `n` slots from the
moment it is made, each `T()` until written, and a `Slot[n]` is plain
data, "a number below `n` that only `push`, `of`, and literals make".
That is an id typed by its container, and it answers the soundness
questions by construction:

- **What makes one valid:** `!t.push(x)` returns the slot it wrote;
  `t.of(i)` turns an `Int` into a `Slot[n]` with one test, where an id
  comes in from data that is not typed (input, a count); a literal is
  checked at compile time.
- **What invalidates one:** nothing. Every table of `n` has all `n`
  slots for its whole life, so a `Slot[n]` names a slot of any of them.
  A slot is never taken away, only assigned.
- **A container that shrinks or reuses slots:** a table does not
  shrink. Clearing or reusing a slot assigns it (dropping the old
  value), and a stale id then reads the new value or `T()`. That is a
  logic error, as a stale List index is today, never a read outside
  memory.
- **Ids read from memory:** a field of type `Slot[n]` holds a `Slot[n]`,
  so a node or symbol id read from a record needs no test. This is what
  the measured reach is: the ceiling's sites are ids read from fields
  and call results.

**It desugars** to CORE's own form: `t[s]` is element `s` of an array of
`n` elements the table owns, with no test; `t.of(i)` is a test and then
that.

Phase A used it with a mask (`(x -% 1) & MASK`), because Trig stores
ids as `U32`. Storing them as `Slot[n]` reads the same, and makes the
mask a type.

## What blocks it: an implementation limit, not a rule

A table of values that own memory (`ast.File`, `InferenceContext`) is
allowed by CORE but **made**: Rig builds all `n` slots on the heap, each
`T()`, up front. At Trig's `FILES = 2^19` that is far too much memory,
which is why research 20 left `files` a List.

**The change (Rig, storage and runtime; CORE unchanged):** a `T` whose
`T()` is all zero bytes (an object of empty Lists, Strings and plain
fields, which emit already marks `__rig_zeros`) is **reserved** like
plain data. Its slots are zero pages until written, and dropping the
table drops the slots below its highest write. Every slot never written
is `T()` and owns nothing, so this is the same as dropping all `n`. It
applies to every program, with no opt-in.

## Coverage of the 3,438 sites (counts, pup E-core 14, median of 5)

| what | sites | ts-pattern instructions / cycles fewer | zod3 instructions / cycles fewer |
|---|---:|---:|---:|
| the whole ceiling after phase A | 3,438 | 3.74% / 2.25% | 4.98% / 3.94% |
| **covered:** containers once per program or checker (`files`, `inference_contexts`, `inference_infos`, the checker's Lists, declarations and transformers) | 2,554 | **1.22% / 0.18%** | **1.17% / 1.17%** |
| spans (stack with item 19, or with this as `t[s + k]` once `s + k` is shown below `n`) | 40 | 0.89% / level | 0.63% / 0.49% |
| **not covered:** containers once per file (each AST's `recs`, `words`, `lists`; each binder's `symbols`, `flows`) | about 844 | about 1.6% / about 2.0% | about 3.2% / about 2.3% |

Per-file containers are not covered because a table per instance means
a reservation per file, and phase B measured that loss (research 21,
#858). Reaching them takes one of:
- program-wide tables the files' nodes are copied into after parse and
  bind (phase-b.md: net about 0.2–0.5%, 800–1,500 lines);
- a Rig feature that lends disjoint ranges of one table to parallel
  tasks, so parse tasks write it directly. That is a CORE §4 change
  (a loan of a slot range), its own design round.

## How Trig reads

Before (aliases.rig; emitted as a range test, then the load):

```rig fragment
return d if @program.files[Int(d.file) - 1].ast.kind(d.node) == .SourceFile
```

After (`files: Table[ast.File, FILES]`, `NodeRef.file: Slot[FILES]`,
slot 0 the empty file that stands for none, as phase A's tables do):

```rig fragment
return d if @program.files[d.file].ast.kind(d.node) == .SourceFile
```

## Fit with CORE (§10)

It adds no rule. `Table` and `Slot` are CORE §5 as built: one paragraph
already, with no exceptions; their rules follow the type
(`Slot[n]`), not where the value came from; and they desugar into an
owned array indexed with no test. The change is in how a table of
owning, zero-default values is held, which CORE leaves to the
implementation, and the sanitizer and the regression corpus check it as
any storage change.

## Decisions for the owner (defaults)

1. Reserved Tables for owning values whose default is zero bytes,
   dropped to the highest write: **yes** (Rig storage and runtime; no
   CORE change, so no expert round).
2. Trig moves `files` and the checker's grow-only Lists to Tables with
   `Slot` ids: **yes**, after 1, timed with an A/A arm. Reach up to
   1.2% of instructions and 0.2–1.2% of cycles.
3. The per-file part (about 1.6–3.2% of instructions): **a separate
   design round** for slot-range loans (a CORE §4 change), not part of
   this.

## Correction (2026-11-02, 03:20): the zero default does not hold

Reading the runtime before building (queue row 57): an object of
empty Lists and Strings is **not** all zero bytes. `List` holds
`buf: []T = &.{}` and `String` holds Zig's `std.ArrayList(u8)`
`.empty`; both carry a slice pointer that Zig requires to be non-null,
and LLVM marks it `nonnull`. That is why `sema.tableFill` takes a
String or a List as `.made`, and an object holding one as `.made` too.
A zero page read as such an object would be undefined behaviour. So
decision 1 as written is unsound.

What would make it sound is **a zero-byte empty form for every owning
container**: `List` and `String` holding an `allowzero` pointer and a
capacity in place of a slice, and `Map`/`Set`'s storage likewise.
Then `T()` of an object of empty containers is all zero bytes, and
`tableFill` can take it as `.zeros`. Its cost and risk:
- it is the runtime's hottest types, every List and String access;
- LLVM loses `nonnull` on their pointers;
- every free and growth path must treat a zero pointer as no storage.

That is a runtime representation change of its own, to be measured
(bench/hash, std.json, Trig) before it is proposed. It is not the small
`tableFill` and drop change this note assumed. The coverage and reach
above stand; the route to them is this larger change.
