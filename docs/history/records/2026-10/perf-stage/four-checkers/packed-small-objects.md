# Small integer objects held as one word (design note, 2026-11-02)

For the owner. Item 1 of store-forward.md. No code yet.

## What it changes

An object whose fields are all integers, `Bool`s, plain enums, or other
such objects, 8 bytes or less in all, is emitted as a Zig
`packed struct(u64)` (or `u32`, `u16`), not a plain `struct`. Zig holds a
packed struct as one integer: a field write is a shift and an `or` in a
register, a store is one 8-byte store, and it travels to a call and
back in a register.

Trig has about 40 such types: the list spans (`TypeList`, `SymList`,
`NodeList`, `SigList`, `InfoList`: start and count), `NodeRef` (file and
node), id pairs and cache keys of two ids (`SubstitutionTypeKey`,
`EnumRelationKey`, `Loc`), and some 2–3-flag option objects.

Nothing in the language changes: no new syntax, no new rule. It is a
representation that storage decides and emit writes. Ownership is
unchanged: these objects are plain copy values with nothing to drop,
so it fits CORE in a sentence and needs no Core change.

## Why: the blocked loads

Zig passes and returns a plain struct by reference, so an 8-byte object
of two `U32`s lives in memory between calls. Its writer stores it a
field at a time (two 4-byte stores), and LLVM merges the reader's two
field loads into one 8-byte load, which cannot be forwarded from two
stores. That is 34% of Trig's blocked loads on ts-pattern (2.7–4.3M of
12.7M; store-forward.md, pattern A). The top chain:
`get_implied_constraint` writes a `NodeRef` field by field and passes
its address down to `get_type_from_type_reference`, whose first load
reads it whole. As one word, the writer makes one 8-byte store (or none,
passing it in a register), and the reader's load forwards.

## Why #816 lost, and why this differs

#816 replaced `rig.rt` around inlined objects with a `var` in place. A
`var` of a plain struct is still memory, written field by field and read
whole, so the blocks stayed where they were (ts-pattern 1.7% fewer,
zod3 13% more), and Trig was 1.1% and 1.7% slower. #816 moved the
temporary; it did not change how the object is held. This changes how
it is held: there is no field-by-field image in memory to read whole.
The codegen-gap record's 1.1% hand ceiling bound parameters directly
and added five loop and inlining edits, timed together, and did not
survive the complete build. Neither result predicts this one.

## Soundness conditions (each a recorded fact, decided once in storage)

1. **Fields:** integers, `Bool`, enums with an integer tag, and other
   objects that are themselves held as words; 64 bits or less in all.
   No pointers, Strings, Lists, optionals, or unions.
2. **No field lent as a place, anywhere in the program.** Zig gives a
   packed struct's field only a bit pointer (`*align(1:0:8) u32`), which
   is not a `*u32`. So a type is held as a word only if no `!x.f` (and
   no `?x.f` view of a nested object) is lent anywhere. A read of a
   scalar field is a value and is fine. This is a fact for the whole
   program, decided where inlining and symbols already decide such
   facts. A type that fails it stays a plain struct, with nothing
   rejected.
3. **The runtime's generic helpers** treat the type as its integer:
   `rt.hash` and `rt.eql` (the same hash as today, so a `HashMap`'s order
   does not change), `nicheOf` (an optional `NodeRef?` takes its none
   from a spare value of the whole word, not of a field), and
   `cloneValue` and the printers.
4. **Layout:** a `u64` aligns to 8 where two `u32`s aligned to 4. Inside
   a containing object, emit gives the field `align(4)`, so records and
   Tables keep today's size and peak memory does not move. The ceiling
   checks this by peak RSS.

## The hand ceiling (before any compiler change)

1. From the emitted Trig package (store-forward.md's base, Rig
   caa6f8560), make `NodeRef` and `ast.Node`, then the five span types,
   `packed struct`s. Fix each compile error by hand; each one is a
   field lent as a place, which condition 2 would have kept plain, and
   the count shows how often condition 2 bites. Teach `rt.hash`, `eql`,
   and `nicheOf` the packed case.
2. Cross-build base and the arm as plain binaries (not switched at run
   time). Check that the output matches on all six projects, at 1 and 4
   checkers.
3. Time in a pup slot: time-ab.sh, 60 rounds, an A/A copy, 1 and 4
   checkers. Report user cycles, blocked loads, instructions, and peak
   RSS.
4. The bar: Trig's (more than 2% faster, or ≥1% fewer instructions with
   time no worse), with no Map or `HashMap` row slower.

Estimate: up to 1.0–1.9% of ts-pattern's user cycles (2.7–4.3M blocks at
12–18 cycles each), less what the shifts cost.

## Decisions for the owner (defaults)

1. Build the hand ceiling as above: **yes**.
2. If it clears the bar, build it in storage and emit as a recorded fact,
   applied to every program, with no opt-in: **yes**.
3. A type with a field lent as a place stays a plain struct, silently,
   rather than being rejected: **yes**.
4. 16-byte keys (`CacheKey`, two `U64`s) as `packed struct(u128)`,
   returned in two registers: **later**, as a second arm once 1 is
   measured. It is pattern B's root, about 21% of blocks.
