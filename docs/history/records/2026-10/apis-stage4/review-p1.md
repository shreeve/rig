# APIs Stage 4, phase 1: adversarial review (2026-10-23)

A review of PR #611 ([phase1-notes.md](phase1-notes.md)) after its
rebase onto `main` (the Core text, #596, and #610), against phase 1's
contract: nothing involving an API object reaches Zig, and every misuse
gets a clear Rig error. About 120 probe programs (110 single files and
10 of several modules), each run with `rig check`, and, when accepted,
`rig run`, plus `rig emit`, `--facts`, `=sema`, `=storage`, `=proofs`,
`=frames`, `--tasks`, `--time`, and `--tests`, on a self-check build
(which refuses a module that types an expression `invalid` with no
error); and `rig lsp` over every probe (open, about 2,800 requests of
semantic tokens, symbols, and folds on edits cut at each `{`, `}`, and
`+`, save, close), with no crash. Each fix has its case in
`test/rig/types-apis.rig.test`.

## Findings, by severity

### High: accepted, then failed in Zig

1. **A call through a type that holds an object reached Zig.**
   `Ph[S].mk()` with `type S = ?{Shape}`, `A.mk()` with `type A =
   Ph[^{Shape}]`, an alias of an alias, a generic enum's `E[S].k()`,
   `geo.A.mk()` from another module, and `Outer[S].go()` whose body
   calls `Ph[U].mk()`: each makes no value of the type, so neither the
   declaration rule nor `recordType` saw it, and emit wrote either the
   alias it had skipped ("use of undeclared identifier 'A'", "struct
   'geo' has no member named 'A'") or a type it cannot lower ("internal
   error: cannot emit a value of this type"). *Fixed:*
   `Checker.objectTypeNamed`, at a call through a type
   (`associatedCall`) and at a member of one, rejects a named type whose
   arguments hold an object, "`Ph[?{Shape}]` holds an API object, which
   is not built yet". A call through a bound at such an instance was
   already rejected at the generic function's instance. Cases "apis
   object not built: a call through its type", "... another module's
   type".

### Medium

2. **A frozen object was accepted.** `type F = *Frozen[^{Shape}]` and
   `*Frozen[List[^{Shape}]]` passed, though an object may hide a Cell
   (H10) and the design never freezes one (open question 15);
   `sema.frozenIn` let `.api_object` through as data. *Fixed:* it
   blocks freezing, with "`^{Shape}` is an API object, whose type is
   erased, so whether it can be frozen is not known: freeze the value
   before erasing it". Case "apis object never frozen".
3. **A container of objects met `Print`.** `Prints[List[^{Shape}]]` and
   `Prints[(?{Shape})?]` were accepted while `Prints[^{Shape}]` was
   not: `lacks` decided the object only at the top, and `printable` is
   structural (H13). *Fixed:* `sema.objectUnprinted` walks what
   `reachedTypeVars` walks and asks `objectMeets` of each object held;
   `List[^{Shape + Print}]` still prints. Case "apis object bounds
   through a container".
4. **Brace messages misled.** `List[^{Shape}]()` and `$size(?{Shape})`
   said "Rig has no braces", which SPEC now contradicts, and `?{}` and
   `?{Shape +}` said it of a `}` the type had opened. *Fixed* in
   `Parser.diagnostic`: a `{` touching a holding sigil or first in an
   expression's brackets says "an API object's type has no expression
   spelling: as a type argument in an expression, name it with a `type`
   alias, or annotate the binding instead", as slices and function
   types already do; a `}` after `{` or `+` says "unexpected `}`;
   expected a name"; the stray-brace messages are unchanged. Cases "apis
   object braces in an expression", "... in a builtin's argument", "...
   empty braces", "... after a plus".

## The builder's decisions

1. **Every value holding an object is rejected,** not only conversions
   and calls: right, and needed (an uncalled `s: ?{Shape}` or an empty
   `List[^{Shape}]` would reach emit). Finding 1 was the one gap, a type
   holding an object named with no value of it. `recordType`'s
   once-per-module report is sound: a quiet check's report is taken back
   with it, and the final check of each expression is not quiet.
2. **A `type` alias of an object type is accepted:** it is the only
   accepted surface, and after finding 1 nothing but `$name` reads one;
   a field, parameter, local, result, instance, `$size`, `$align`, a
   lambda's parameter, an enum payload, an error field, an extern
   parameter, and an API method's parameter through an alias are each
   rejected. Emit writes no alias for it, so a use that would name it in
   Zig must stay rejected until phase 2 lowers the type.
3. **Wordings:** each is a clear Rig error. `Map[?{Shape}, Int]` says
   "`?{Shape}` cannot be hashed" (and repeats it for the Map's
   iterators' instances) where the plan wrote "is not `Hash`"; either
   serves.

## For phase 2 (parked, not fixed)

- **Braces in an expression.** Phase 2's planned texts write
  `total[^{Shape}]` and `Table[^{Shape}, 4]` in expressions, which this
  phase's grammar spells only through an alias. Phase 2 adds an
  expression spelling (an atom `{...}` that only a type argument
  accepts) or keeps the alias rule and rewords its cases: a design
  point for the designer.
- **`Owned` and `Clone` through a container are conservative.**
  `List[^{Shape + Owned}]` lacks `Owned` ("may hold a loan") and
  `List[^{Shape + Clone}]` does not clone, though each object meets the
  bound: `reachOf` gives an object views whatever its braces name, and
  `deepCloneable` sees its unique value. Only false rejections; phase 2
  reads `Owned` from the braces in `reachOf` and a box's `Clone` in
  `deepCloneable`.
- **Operations on an object value consult no bound yet:** `print(s)` of
  a `?{Shape}` without `Print`, `s == s`, and `s.hash()` add no error of
  their own (the parameter is rejected as not built). Phase 2's print
  and operator paths ask `objectMeets`.
- **A call's arguments are not checked against the API's method**
  (`x.f(1)` of a two-parameter method says only "not built yet"); phase
  2 types the call from the declaration.
- Low: `+s` of a `?{Shape}` says "`+x` cannot clone a `{Shape}`: it
  holds a unique value" (phase 2's text: only a `^{Shape}` has `+`);
  `[T: {Shape}]` speaks of a value parameter; `?{Shape}?` reads as
  `?({Shape}?)` and is unsized, without suggesting `(?{Shape})?`;
  braces do not join lines outside brackets (`type A = ?{` then
  `Shape}` on the next line is "unexpected indentation").

## Probed without findings

The braces: in every type position (local, field, parameter, result,
optional, slice, array, fixed array, function type, results type, `^`,
`!^`, `?^`, `*^`, `~^`, `*`, `~`, error union, `unique`), spaced and
split across lines in brackets, nested, empty, with a comma, a sigil, a
member, parentheses, `Self`, `List[Int]`, a non-associated `[Item:
Int]`; stray braces in headers, values, calls, `match` arms, and after
a function header. What the braces name, and an API from another
module, transitively imported, not imported, and not public (a public
alias of a private API is accepted, as a public alias of a private type
is). Inference: `?T`, `^T`, a generic type's field, and a method's own
parameter at `{Shape}` each rejected as unsized; `T = ^{Shape}` through
`id`. Generic instances at an object through explicit arguments,
aliases, method-level parameters, calls through a bound (`t.make[S]()`,
`T.count()` at `Ph[S]`), `$name` inside a generic, API default bodies,
tasks, actors' state, error fields, enum payloads, extern functions,
lambdas, `from @field`, defaults. Bounds: each built-in API at each
form and nested in a List, an optional, and an array (`Eq`, `Hash`,
`Ord`, and `Sends` rejected nested; `Copy` of `[2]?{Shape}` met);
`Cell`, `Signal`, `Chan`, `Task`, `*Actor` of an object (their rules
apply at the value, as for any type). Callability (open question 5):
compile-time type, value, and set parameters, `Self` in a parameter, a
result, an optional, `?fun(?Self)`, and `List[Self]`, all left out with
why; a diamond (`Both: L + R`, both on `Base`) reaching `Base` once; two
APIs declaring one name, ambiguous and resolved by `A1.area(x)`; an API
cycle; an unknown method; `!` on a `?{G}`; an optional object. No
accepted program typed an expression `invalid` under the self-check
build, and none crashed `rig emit`, the facts, or `rig lsp`.
