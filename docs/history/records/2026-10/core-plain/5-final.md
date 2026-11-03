# `$plain(T)` narrowing: the final text for the owner

The panel was a designer, an adversary and a reviewer. The adversary found six holes, two of them high. The revised draft closed all six, and the reviewer accepted it with five fixes, which are folded in below. The verdict: sound, and no new soundness hole. A missing bit gives `false`, which costs only speed. The rule needs no CORE change: it's a SPEC generics paragraph, since CORE's scope line puts generics' per-instance checks in SPEC.

## The SPEC paragraph (generics, after the per-instance check)

> `$plain(T)` is `true` where `T` is plain data (CORE §1): it copies,
> owns nothing, and views nothing, as a type that provides both `Copy`
> and `Owned` does. Each instance answers it when the program compiles,
> so a generic body that tests it is two bodies. Where `T` is a type
> parameter or an associated type, and `$plain(T)` is an operand of a
> condition's `and` chain, the instances where `T` is plain compile the
> body as written. In them, what runs only once the test has held (the
> operands after it and the code the condition guards) is checked with
> `T` as it is elsewhere, and also known to copy and to hold no loan.
> What that code needs of an instance is checked at those instances
> alone. Every other instance compiles the body without that code, as
> if the test were `false`.

Also reworded: SPEC's copy sentence, "where the body copies a `T`, every instance must be" **plain data or a read view**. That's what the compiler already does.

## Why
- **The packed Map:** 4.4% of Trig's ts-pattern cycles on the replay of Trig's real map traces, and map memory from 103 to 69 MB.
- **It needs exactly this:** a free slot is filled with a copy of a real entry, which a generic body can do only where K and V are plain.
- **The language-free routes lose:**
  - `Entry?` slots are half again as big;
  - a second map type breaks the one-map target.

## How it's built (the fixes folded in)
- **Plain is one fact.** Sema decides `$plain` once per instance (`Copy ∧ Owned`, CORE §1's kind) and emit passes it as a `comptime` Bool. Emit never computes it from the Zig type, because views of scalars and API objects share Zig types with plain data.
- **The bits pass through generics.** Every generic that builds a Map from its type parameters gets the bits, with no defaults, so a missed site is a Zig compile error. A bit passed on is computed as `$plain` of the argument itself.
- **What narrows:** only `and` chains narrow, in `if`, `elif`, `while`, and arm and statement guards; never under `or` or `not`. Facts cached per type are untouched.
- **The oracle** learns the rule in kinds.zig and lower.zig, about 100 lines, gated on its abstention count not rising.
- **Gate:** `rig emit` is byte-identical for programs that don't test `$plain`. On Trig nothing splits: none of its 113 Map and 9 Set instances takes `Static` or `?String`.
- **Size:** about 540 lines plus tests.

## Decisions (each with the panel's default)
1. `$plain`, not `$copies`: yes.
2. Sema's per-instance bit, passed through generics; `Static` is plain: yes.
3. "`T` as it is elsewhere, and also plain", not "bounds added": yes.
4. Every condition's `and` chain narrows, and nothing else: yes.
5. One meaning of plain (rename `isPlainData`): yes.
6. The copy sentence reworded: yes.
7. The oracle change reaches lower.zig: yes.
8. No CORE change: yes.

Reports: BRIEF.md, 1-design.md, 2-adversary.md, 3-draft.md, 4-review.md.
