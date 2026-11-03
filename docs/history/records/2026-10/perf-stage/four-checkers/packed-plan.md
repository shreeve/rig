# Item 19: small integer objects held as one word, the implementation plan

Design only, for the moment the owner says yes. The design note is
packed-small-objects.md; the ceiling (store-forward.md, arm p) cleared
Trig's bar on every project with no memory cost. Rig main 472d4f675.

## The fact, and where it is decided

**Word-held** (the fact's name): an object type emitted as a Zig
`packed struct(u8|u16|u32|u64)`.

- **Decided once, for the whole program,** in the pass that already
  runs after every module is checked (`main.zig` calls
  `inlining.decide` there). A new `storage.decideWords(graph)` runs
  just before it. The lends that disqualify a type can come from any
  module, so no per-module pass can decide it. The result is recorded
  on the declaring module's sema (`sema.word_held`, keyed by the
  declaration's position), as `inlining` records `sema.inlined`.
- **Candidates:** non-generic `obj` declarations whose fields are all
  `Int`-family, `Bool`, plain enums (an integer tag), `Slot[n]`, or
  other word-held objects, 64 bits or less in all. Excluded: a field
  with a `Cell` or a handle, unique types, error types, types with a
  `drop`, generic objects, and API objects.
- **Nested types first:** in dependency order, to a fixed point (`ast.Node`
  before `NodeRef`).
- **Disqualifier, read from the one classifier:** every recorded lend
  (`SemContext.facts.lends`, each `Lend`'s steps) in every module.
  A lend made **by address** (`!lendByValue`) whose steps take a field
  of a candidate (the lent place is inside the object) disqualifies the
  candidate. A read of a scalar field (`?p.a`) is lent by value and
  does not. Nor does a lend of the whole object (`?p`, `!p`), or an
  assignment to a field (`p.a = v`, `p.a += 1`). A disqualified type
  stays a plain struct, and nothing is rejected.
- **Read views:** `sema.copiedByReadView` answers true for a word-held
  type, so `?@`, `?x` and `?T` parameters take it by value (the
  ceiling's one hand fix, `NodeRef.is_none`). The runtime's
  `copiedByReadView` mirrors it from the Zig type (a `packed struct`
  is copied).

## What emit reads (`facts.zig`, emit decides nothing)

- `Facts.isWordHeld(ty)`: the struct declaration is written
  `packed struct(uN)`, with `N` the fields' bits rounded up to 8, 16,
  32 or 64. Field order and defaults are unchanged.
- **Inside a plain object,** a field whose type is word-held and wider
  than 32 bits is written `align(4)` (`name: T align(4) = …`), so
  records keep their size. A pointer type to a word-held type is
  written `*align(4) T` (and `*align(4) const T`), so pointers to such
  fields and to whole values coerce to it. Write views (`!x.r`) work
  through it.
- `__rig_zeros` is unchanged: a word-held type's default is all zero
  bytes exactly when its fields' are.

## The runtime (`src/runtime.zig`)

- **`rt.hash`, `rt.eql`:** today they walk a struct's fields; a
  `packed struct` is taken as its backing integer (`@bitCast` to `uN`),
  hashed as one word and compared with `==`. A `Map` keyed by a
  word-held type stays in insertion order. A `HashMap`'s order may
  differ from today's, as for any change of hash; its order is not
  specified.
- **`nicheOf`:** a `NodeRef?` keeps its none in a spare value. For a
  packed struct the niche is taken on the backing integer's bits (its
  field's bit offset, `@bitOffsetOf`), not a byte offset into a struct.
  The ceiling compiled and ran `NodeRef?` unchanged; a case pins it.
- **Printing, `typeName`, cloning:** they walk `@typeInfo(T).@"struct"`
  fields, which a packed struct has. Cases pin them.

## Failing cases first (`test/rig/word-objects.rig.test`, a new area)

`code` cases for the emitted form:
1. `obj P` of two `U32`: `"pub const P = packed struct(u64) {"`.
2. Nested: `obj N` of one `U32` and `obj R` of a `U32` and an `N`:
   `"packed struct(u32)"` and `"packed struct(u64)"`.
3. A record holding `R` and a `U32`: `"r: R align(4) ="`.
4. A type with a field lent to write anywhere (`bump(!p.a)`): stays
   `"= struct {"`.
5. Across modules (`whole: true`): a second module lends `!p.a`, and
   the first module's `P` stays `"= struct {"`.
6. A read view method (`fun P.sum(?@)`): `"fn sum(__rig_in_self: P)"`.

`test` cases (behaviour, each run clean under the sanitizer):

7. `bump(!p.a)`, the lend that keeps `P` plain: prints the new value.
8. `!rec.r` lent to a sub that writes `r.file`: the record prints the
   change (the `align(4)` write view).
9. `R?`: none, then some, then `??`: prints both.
10. `Map[R, Int]` and `HashMap[R, Int]`: put, get, iterate.
11. `Table[R, n]`, `List[R]`: push, read, assign a field in place.
12. `print(r)`, `r == r2`, `r != r3`.
13. A `U32` field at its maximum, `+= 1`: a `bomb` with "overflow"
    (the arithmetic is still checked).

The oracle's `rejections` and `coverage` must not change: this adds no
ownership rule.

## Gates

- `swarm test/rig.rip all`, green (sanitizer and oracle as the runner
  sets them; the oracle silent).
- `zig build test`; the runtime changes run on pup with
  `-Doptimize=debug`, `safe` and `fast`.
- `tools/emit-diff`: changes expected in Trig and in std types that
  qualify; examples and benches listed.
- Trig's light gate GREEN; loco's light gate GREEN.
- `bench/json/guard.py` within 2% on all six files.
- `bench/hash/guard.py`: no `Map` or `HashMap` row slower.
- Trig timed on pup in a slot, with an A/A arm (60 rounds, 1 and 4
  checkers, peak RSS), against the ceiling's numbers.

## Size

| part | lines |
|---|---:|
| `storage.decideWords` (candidates, fixed point, lend walk) | 120–160 |
| sema (`copiedByReadView`, the fact's set) and `facts.zig` | 20–30 |
| emit (`packed struct`, `align(4)` fields and pointers) | 40–60 |
| runtime (`hash`, `eql`, `nicheOf`, `ReadView`) | 30–50 |
| cases | about 150 |
| docs (INTERNALS "Storage facts", CHANGELOG, HANDOFF) | about 40 |

About 210–300 lines of compiler and runtime, plus cases and docs. No
SPEC or CORE change: the language means the same.

## As built (draft shreeve/rig#873, 2026-11-02)

Where the build departs from the plan above, and why:

- **Two facts, not one.**
  - *Word-sized* (`sema.wordBits`, per declaration) decides read views
    by value. The checkers need it while checking, before any
    whole-program pass runs.
  - *Word-held* (`storage.decideWords`, whole program, before inlining)
    decides the packed struct.
  - A copy where a pointer was checked is safe: the loan is kept either
    way (a scalar's `q = ?r.k` still holds its loan).
- **Candidates:**
  - integers, slots, and nested word-sized objects, filling 8, 16, 32 or
    64 bits exactly;
  - Bool and enums are left out, since a 1-bit Bool loses the niche the
    plain object's optional had;
  - excluded too: a named none, a `drop`, own Eq/Ord/Hash/Print, and a
    program's own APIs.
- **The disqualifier is syntactic over typed facts.** `facts.lends`
  records type conversions, not places, so `decideWords` walks every
  `(write …)` chain. It keeps a type plain where a step takes a field of
  a word, or a 64-bit word held in another object or an optional. It then
  takes a fixed point: a word holding a plain word is plain.
- **The marker is `__rig_word_sized`.** `__rig_word` is Cell's own decl,
  a bool, and reusing the name made Cells copy by read view.
- **Memory.** A 64-bit word keeps four-byte alignment everywhere it is
  stored, or containers grow:
  - an `align(4)` field;
  - `rig.WordOpt`, a 12-byte optional;
  - Map and Set keys and values (`rt.wordAlign`).

  Write views follow: `*align(4) T`, and `rig.WritePtr(T)` in generic
  code. Zig's pointer types differ by any written alignment, even the
  natural one, so `WritePtr` writes it only where it differs.
- **Emit fixes the by-value views needed:**
  - `(?P)?` is routed as `P?` (`optionalRouted`);
  - `??` and `catch` fallbacks treat a word's view as the word
    (`sameValue`);
  - an optional lend into a routed view is packed.
- **Size:** about 420 lines of compiler and runtime, and 23 cases.
