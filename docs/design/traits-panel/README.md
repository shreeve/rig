# Traits panels

Two panels of three experts designed traits for Rig, with no code. The
first proposed; the second reviewed the proposal. Each report is kept
as written. The owner approved the decisions below, which
[traits.md](../traits.md) records in full; where a report differs from
them, the decisions hold.

| Report | Expert |
|---|---|
| [1-types.md](1-types.md) | type systems and generics |
| [1-ownership.md](1-ownership.md) | ownership and borrow checking |
| [1-backend.md](1-backend.md) | compiler backend and dispatch |
| [2-adversary.md](2-adversary.md) | adversarial soundness |
| [2-library.md](2-library.md) | standard library and migration |
| [2-syntax.md](2-syntax.md) | syntax, readability, and teaching |

## Decisions

1. Traits, dispatched at compile time; a bounded generic body is
   checked once against its bounds.
2. Built in five stages, each when a program needs it: method calls on
   a type parameter, checked per instance; built-in bounds; user traits;
   trait objects behind a view or a box; shared trait objects and
   crossing tasks.
3. Conformance is written on the type's header, `obj Square: Shape`.
   `impl Type: Trait` is only for a type one does not own, written in
   the trait's module, or a conformance under a bound.
4. Every bound goes in the brackets, `[T: Ord + Print]`,
   `[S: Source, S.Item: Ord]`; there is no `where`.
5. A type parameter is capitalized and a value parameter is not.
6. An implementation matches its trait exactly in how it takes self,
   its parameters' views, and `once`; `from` and `keeps` may only
   narrow, compared by position.
7. The adversarial review's rules are adopted: a view meets only the
   built-in bounds at first, nothing assigns through a trait object, an
   actor meets no user trait, a trait's result that could view writes
   its `from`, coherence over the whole program, and derived `==` and
   hashing that call a type's own methods.
8. The built-in traits are `Copy`, `Clone`, `Owned`, `Moves`, `Shares`,
   derived and never declared, and `Eq`, `Hash: Eq`, `Ord: Eq`,
   `Print`, `Iter`, and the number traits, which a type may give its
   own meaning by naming them on its header.
9. std takes bounds: `Map[K: Hash, V]`, `Set[K: Hash]`, `sort[T: Ord]`,
   `contains[T: Eq]`, and the rest; `BigInt` is unchanged.
10. A `pub` generic states its bounds once user traits land; a private
    generic may keep per-instance checking.
11. A trait object is the trait in braces behind a holding sigil:
    `?{Shape}`, `!{Shape}`, `^{Shape}`, `*{Shape}`, `List[^{Shape}]`. A
    bare `{Shape}` is rejected, and braces hold only traits. The
    reports' `dyn`, `Dyn[...]`, and `any` gave way to braces.
12. Trait objects come after static traits: views and boxes first,
    shared handles and crossing tasks last.
