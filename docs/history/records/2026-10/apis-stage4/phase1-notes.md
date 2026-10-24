# APIs Stage 4, phase 1: the type and its rules (2026-10-23)

Phase 1 of [build-plan.md](build-plan.md), built on the CORE text the
owner approved (`core-objects/6-final.md`) and Stage 4's 21 defaults
(#596). API objects are types the compiler checks; no value of one is
made yet.

## What is built

- **Grammar and lexer.** `{` and `}` are tokens; a type's atom may be
  `"{" oapi ("+" oapi)* "}"`, an `oapi` a name or an instance
  (`Source[Item: Int]`), so `?{A}`, `!{A}`, `^{A}`, `List[^{A}]`, and
  `^{A}?` parse by the existing rules. A brace the parser does not
  expect keeps "unexpected `{`; Rig has no braces: a block is the lines
  indented under its header" (`Parser.diagnostic`).
- **The type.** `Type.api_object: { api: ApiRef, builtins: Apis }`,
  printed `{Shape + Owned + Print}` (its API, then the built-in APIs in
  one order). `TypeInfo.object` marks every type that is or mentions
  one (`sema.mentionsObject`).
- **The braces** (`TypeResolver.resolveApiObject`): one API of a
  program's own; `Owned`, `Print`, `Clone` beside it; a type, a type
  parameter, two APIs, `Copy`, `Eq`/`Hash`/`Ord`, the number APIs, only
  built-in APIs, an unknown name, a name twice, `Sends`/`Syncs` (Stage
  5), an API with `type Item` unnamed, and `Iter`, each with its own
  message. `*{A}` and `~{A}` are Stage 5's.
- **Unsized** (`sema.misplaced`, `Misplaced.unsized`, the one decider
  of where a type may stand): a bare `{A}` stands only behind a view
  or a box, never as a value's, field's, parameter's, result's,
  element's, optional's, or function type's part, nor as a type
  argument, written or inferred (an instance's arguments go through
  the same classifier, so `put(!w1, !w2)` of two `!{Shape}` is
  rejected: H4).
- **Facts** in the existing classifiers: `holdsIn` (glue, not plain),
  `reachOf` (may hold any view, text, a Cell, a unique value; no write
  view), `runsDropBody` (yes), `blockerIn` (crosses no task), `provides`
  (no API: a box is not its value), and `lacks`, through
  `sema.objectMeets`: `?{A}` copies and so clones; `Print` from the
  braces or the API's supertraits; `Clone` and `Owned` of a box only
  from its braces; nothing else (H10, H11, H13). An error's field of
  one is rejected by the existing no-loan rule.
- **What a call reaches** (`sema.objectMethods`, open question 5): every
  method of the API and those it builds on, in table order (each API
  after those it builds on), with a slot, or left out with why:
  compile-time parameters, a set parameter, or `Self` outside self
  (through callable types too, H9). `typecheck.objectCall` reads it for
  `x.m()` and for `Shape.m(x)` of an object.

## Decisions beyond the design

1. **Where "not built yet" stands.** The plan rejects a conversion and
   a call. That alone would accept a parameter `s: ?{Shape}` of an
   uncalled function, or an empty `List[^{Shape}]`, which emit cannot
   lower (North Star 1). So every value whose type holds an object is
   rejected: at a declared local, parameter, result, or field
   (`misplacedAt`), at a generic function's instance, at `$size` and
   `$align`, at an erasure (`checkActual`), at a call, at a call or a
   member through a type that holds one (`Ph[S].mk()`,
   `Checker.objectTypeNamed`, from the review), and, for a value
   made with no type written (`Boxes()` of an alias), at its first
   expression (`SemContext.recordType`, which reports once unless a
   standing report already rejects the module, `objectRejected`).
   Bodies are still checked, so a call's reasons are reported.
2. **The messages name what is not built:** `` `?{Shape}` is an API
   object, which is not built yet (docs/design/apis.md, Stage 4) ``
   (`holds` for `List[^{Shape}]`), `` `s.area()` calls through
   `?{Shape}`, an API object, which is not built yet (...) ``, and ``
   `sq` would become a `?{Shape}`, an API object, which is not built
   yet (...) ``, for the plan's one text.
3. **A type alias of an object's type is accepted** and `$name` spells
   it; emit writes no Zig for such an alias (`Facts.mentionsObject`),
   since no value of it is made. This is the only accepted surface.
4. `?{Print}`, braces with no API of a program's own, is rejected:
   `` `?{Print}` names no API of a program's own, whose methods an
   object reaches: name one beside the built-in ones, `?{Shape + Print}` ``.
5. The number APIs: `` `Num` is provided by the built-in numbers alone,
   and an API object's methods are an API's of a program's own; take
   `Num` out of the braces ``. `Ord`: `` ... which `<` cannot order ``.
6. An inferred bare type argument: `` `{Shape}` has no size of its own,
   so it is no type argument, written or inferred ``.
7. `^{Int}`: a type with no API of its own gets `` ... or name an API in
   the braces ``; `^` says "for a box of it".
8. The oracle abstains on an API object (`Scan.walk`: "an API object"):
   no program the compiler accepts holds one, and phase 2 decides them
   from the type (open question 17).

## Not built (later phases)

The erasure (`LendStep.erase`, `SemContext.erasures`), `Dispatch.dynamic`
and one `Dispatch.viaApi()`, calls typed from the API's declaration,
the rules on `!{A}` writes, the frame copy, tables and `rig.ApiView` /
`rig.ApiBox`, boxes and `<@`, the oracle's kinds, and the phase-2 texts
(`` `Label` does not provide `Shape` ``, `` `total[^{Shape}]` cannot use
`T = ^{Shape}` ``, freezing). No default: a `^{A}` has none as any box
has none, and a bare `{A}` is never a value.

## Checks

- 34 cases, "apis object ..." in `test/rig/types-apis.rig.test`, and a
  `test/cli/facts_sema.sh` line; every brace case fails under main's
  compiler (a brace never lexed), the three stray-brace cases keep
  main's message.
- Trig's emitted Zig is byte-identical under main's compiler
  (6188cde8c) and this one: 12 of the 15 programs with a `main` in its
  `tools/` and `tests/`, built as its packs build them (536 Zig files;
  the other 3 are rejected by both alike), and the 49 files of `src/`
  that emit alone.
