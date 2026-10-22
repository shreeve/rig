# Audit: syntax-cleanup-2 (adversarial review, R13)

Branch `syntax-cleanup-2` at 67f1309, reviewed against `main` using the
existing `bin/rig`. A build of `main` in the scratch dir was used to
classify regressions. The full suite is green (`1413 passed, 0 failed,
0 known`). Nexus regenerates the grammar with no LALR conflicts.

Repro files are in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R13/repro/`,
each with its captured output in `<name>.rig.out`. Every finding was
reproduced twice.

## Findings

| # | Sev | Kind | Area | Summary |
|---|---|---|---|---|
| F1 | Medium | wrong meaning / wrong accept | handle precedence, expression type args | A chain of handles such as `Cell[*~N?]` or `Cell[~*N?]` means a handle to an optional in an expression, but an optional handle in a type |
| F2 | Low | bad hint | `;` hint | `[U8; 4]` (a sized type, all capitals and digits) gets the hint "a fill literal puts its count first: `[4 of U8]`" |
| F3 | Low | bad diagnostic | handle precedence | `x: *N! = 1` says "... (a fallible handle is `*T!`)", which contradicts the rejection it belongs to |
| F4 | Low | type print does not round-trip (regression) | handle precedence | A handle to a borrow, `*(?Int)`, is accepted as a type but prints as `*?Int`, which no longer parses |
| F5 | Low | hint suggests code that does not parse | `;` hint | `a = 1; b = 2` gets "drop the `;`", which leaves `a = 1 b = 2` |
| F6 | Low | misleading diagnostic (pre-existing, now more likely) | positional variants | `Opt.some(1, 2)` and `Opt.some()` report "cannot infer `T`" instead of the arity problem |
| F7 | Low | diagnostic without a hint (pre-existing) | handle precedence | `sub()?` and `*sub()?` give a bare "unexpected `?`"; the documented spelling `(sub())?` is not suggested |
| F8 | Low | message misprints the type | handle precedence | `Cell[*N!](...)` reports "a fallible type `N!`", dropping the `*` |
| F9 | Low | diagnostic without a hint | fill literal | `[a, 2 of 3]` gives a bare "unexpected `of`" |
| P1 | Low | type print does not round-trip (pre-existing) | printer | `(N?)?` prints as `N??`, which lexes as the `??` operator (`*N??` likewise) |

### F1: nested handle chains in expression type arguments (Medium)

In a type, `*~N?` parses as `thandle(*, thandle(~, N))?`, which is
`optional(shared(weak N))` and prints as `*~N?`. In an expression the
tree is `(share (weak (propagate_none N)))`. `optionalHandleArg` only
lifts the suffix when the share or weak node's direct operand is
`propagate_none`. With a nested handle it returns null. The generic
path then wraps the inner result, and the type becomes
`shared(optional(weak N))`, printed `*(~N?)`. So the same spelling
names two different types, which contradicts SPEC §17 ("In an
expression, `*T?` as a type argument is an optional handle, as in a
type") and the SYNTAX.md type-argument text. The type fuzzer found the
same divergence for `~*Cell[geo.N]?`, `~~Cell[geo.N]?` and `*~~Int?`.

Repro `F1a_nested_handle_typearg.rig`:

```rig
struct N
  a: Int

sub main
  x: Cell[*~N?] = Cell[*~N?](value: none)
  old = x.replace(none)
  print(old == none)
```

```
F1a_nested_handle_typearg.rig:5:37: error: `none` needs an optional type; `*(~N?)` is not optional (write `*(~N?)?`)
F1a_nested_handle_typearg.rig:5:19: error: type mismatch: expected `Cell[*~N?]`, got `Cell[*(~N?)]`
```

This is a wrong accept under the documented meaning.
`F1b_nested_handle_accept.rig` runs and prints `accepted`:

```rig
  w: ~N? = ~n
  c = Cell[*~N?](value: *(<w))      # accepted: the cell holds `*(~N?)`
  d: Cell[*~N?] = Cell(value: none) # the annotation reads it as `*~N?`
```

Written as an annotation, `c: Cell[*~N?] = Cell(value: *(<w))` is
rejected with "expected `~N`, got `~N?`".

- Suspected code: `src/typecheck.zig:2824` (the share/weak arm of
  `typeArg`) and `src/typecheck.zig:2866` (`optionalHandleArg`), plus
  `src/rig.zig:1346` (`noteParenSuffix`), which only looks at the
  `propagate_none` chain directly under a handle.
- Fix: in `optionalHandleArg`, first walk the chain of `share` / `weak`
  nodes. Each nested handle must start exactly one byte after its
  parent's sigil; otherwise parentheses intervene, as in `*(~N?)`,
  which should get the alias rejection. Then take the `propagate_none`
  suffixes under the innermost handle and wrap them outside the whole
  chain. `noteParenSuffix` needs the same walk, so that `*(~N?)` is
  flagged and `*~N?` is not. Add `*~N?`, `~*N?`, and `*(~N?)` cases to
  `test/reject/types/handle_to_optional.rig` and
  `optional_handle_binding.rig`.

### F2: wrong `;` hint for sized types (Low)

```
F2_sized_type_semicolon.rig:2:10: error: unexpected `;`; a fill literal puts its count first: `[4 of U8]`
  xs: [U8; 4] = [4 of 0]
```

The same happens for `[I64; 2]`, `[F64; 3]`, and other sized types.
`[N; 4]` (a one-letter constant) is read as a type (`[4]N`), and
`[?x; 2]` gives `[2]?x`. The heuristic in `semicolonMessage`
(`src/rig.zig:1174`, the `typelike` test) requires a lowercase letter
unless the name is one character long.

Fix: also treat `[UIF][0-9]+` (or any capitalised name ending in
digits) as a type. Better, decide from what precedes the `[`: after
`:` or `->`, or inside a type-argument list, it is a type; elsewhere it
is a fill literal.

### F3: contradictory fallible-type parenthetical (Low)

```
F3_fallible_handle_msg.rig:5:6: error: a fallible type `*N!` is only allowed as a function's return type (a fallible handle is `*T!`)
```

The old text contrasted `(*T)!` with `*T!`. After the change the
parenthetical restates the rejected spelling as if it were the fix.
Code: `src/resolve.zig:1412`. Fix: drop the parenthetical, or say "`*T!`
is a fallible handle; it is only a return type".

### F4: a handle to a borrow prints unparseably (Low, regression)

`*?T` parsed on `main`. Now `*` and `~` take only a `thandle` or a
`ptype`, so `*?Int` is a parse error with a bare "unexpected `?`"
(`f4b`). The type still exists: `*(?Int)` is accepted as a parameter
type, and a value can be built with `*(?y)`, although the borrow
checker still confines it. `formatHandle` prints it without
parentheses:

```
F4_handle_of_borrow_print.rig:2:12: error: type mismatch: expected `Int`, got `*?Int`
```

The type fuzzer also found `(*?Int)?`, `~?W[Int]`, `fun(*?W[Int]) -> Int`
and `*~!Vec[Int]`. Code: `src/sema.zig:3069` (`formatHandle`) and
`takesNoSuffix`. Fix: have `formatHandle` also parenthesise
`borrow_read` and `borrow_write` operands (`*(?Int)`). Alternatively,
reject a handle to a borrow in `resolveType`, which a `*T` of a borrow
arguably should be.

### F5: "drop the `;`" between statements (Low)

```
F5_semicolon_statements.rig:2:8: error: unexpected `;`; Rig ends a statement at the end of its line; drop the `;`
  a = 1; b = 2
```

Dropping the `;` gives `a = 1 b = 2`, which does not parse. Code:
`src/rig.zig:1177`. Fix: when something other than a comment follows on
the line, say "put each statement on its own line"; keep "drop the `;`"
only for a trailing `;`.

### F6: variant arity reported as an inference failure (Low, pre-existing)

```
F6_variant_arity_infer.rig:6:11: error: cannot infer `T` for `Opt` from the arguments; ...
  z = Opt.some(1, 2)
```

`Opt.some()` gives the same message. Now that `.some(x)` is the normal
form, `.some(a, b)` is a likelier mistake. Code:
`src/typecheck.zig:3802` (the `.payload` pattern matches only when
`args.len == 1`), before `checkFieldArgs` can report the arity. Fix:
for `.payload`, when a single-field variant gets more than one
positional argument (or none), report "variant `some` has one field"
before inference.

### F7: function type followed by a suffix (Low, pre-existing)

```
F7_fun_type_suffix.rig:2:11: error: unexpected `?`
  s: sub()? = none
```

The SPEC now states the rule: "a function type takes none, so an
optional of one is written in parentheses". The parser wrapper could
add the hint "an optional function type is written `(sub())?`",
covering `*sub()?` as well.

### F8: the `*` goes missing from the fallible-type message (Low)

```
F8_typearg_fallible_msg.rig:5:13: error: a fallible type `N!` is only allowed as a function's return type
  c = Cell[*N!](value: none)
```

In a type, `*N!` is `fallible(shared N)`. The message names only the
inner `N!`. Code: `src/typecheck.zig:2842`, which is reached from the
share arm. Fix: report from the outer handle node, or format the lifted
type.

### F9: `of` in a list literal (Low)

```
F9_of_in_list.rig:3:14: error: unexpected `of`
  xs = [a, 2 of 3]
```

`[2 of 3, 4]` gives "unexpected `,`; expected `]`", which is acceptable.
Suggested hint: "a fill literal `[n of x]` holds one count and one
element; it cannot share brackets with a list".

### P1: double optional prints as `??` (Low, pre-existing)

`x: (N?)? = 1` reports "expected `N??`". `N??` lexes as the `??`
operator, so the printed spelling does not parse. `*N??` is affected
the same way. Fix: `formatSuffixed` should print `(N?)?` when the inner
type is itself an optional.

## Clean (probed, behaves as documented)

**Fill literal `[n of x]`**
- `of` works as a name in every position probed: locals, fields,
  parameters, keyword arguments (`g(of: 5)`), methods (`q.of()`),
  fields (`p.of`), closure parameters (`|of: Int|`), loop labels
  (`:of for ...` / `continue :of`), `[of]`, `[a, of]`, `xs[of - 3]`,
  `[2 of of]`, `[2 of [of]]`, `[x.of of 1]` (rejected only as not
  compile-time), `Vec[of]` ("`of` is not a type"), and inside closure
  islands laid out in brackets.
- Line joins work: `[2\n of 5]`, `[2 of\n 5]`, and `[2 # c\n of 5]`.
- The count must be compile-time. `[k of 0]`, `[m of 1]` (with
  `m =! k * 2`), `[(k) of 2]`, `[k + 1 of 3]`, and `[N of 7]` in a
  module constant are accepted; a run-time local is rejected.
- Owning elements are rejected: `Vec`, a struct holding a `Vec`, `*P`,
  a payload enum holding a `Vec`, and owned closures. A borrow (`?s`)
  is rejected. Moves and clones (`<x`, `+x`) behave as expected.
- A call with side effects is evaluated once: `[3 of bump(!c)]` leaves
  `c == 1`.
- Nested fills and fills in constants work, as do fills in generic
  bodies. `fill[T, n]` works with `Int` and `String`. `T = Vec[Int]` is
  rejected at the instance with a note pointing into the body.
- `[n of x]` works in `Ring[T, n](items: [n of x])` and with fallible
  (`mk()!`), optional (`[2]Int? = [2 of none]`), struct, enum, and
  string elements. All of these run leak-free.
- Fuzzing about 2,800 random bracket, `of`, comma, and sigil bodies,
  plus 1,800 random type strings, produced no crash and no hang (10 s
  limit), and every rejection had a `file:line:col`.
- The `;` hints are correct for `[x; n]`, `[0;4]`, `[-1; 2]`,
  `[LIMIT; 4]`, `[Int; 3]`, `[Vec[Int]; 2]`, `[Point(x: 1); 2]`,
  `[[0; 2]; 3]` (the inner one), `[x;` (the generic message), and
  `[1, 2; 3]`.
- The IR reads `array_fill` by role everywhere (emit, ownership,
  typecheck).

**Handle precedence**
- Each of these types parses and prints as documented, and the printed
  form round-trips: `*N?`, `*(N?)`, `(*N)?` → `*N?`, `~N?`, `~(N?)`,
  `?N?`, `!N?`, `?*N?`, `?(*N)?`, `(?N)?`, `*[]Int`, `*[]Int?`,
  `([]Int)?`, `[]Int?`, `*[2]Int`, `(*[2]Int)?`, `*fun(Int) -> Int?`,
  `(*fun(Int) -> Int)?`, `fun(Int) -> *N?`, `(*sub(Int))?`,
  `*Vec[Int]?`, `*(Vec[Int]?)`, `Cell[Int]?`, `*Cell[Int]?`,
  `~Cell[Int]?`, `*(N?)?`, `*((N)?)` → `*(N?)`, `*(N)?`, `~[]Int?`,
  `*N?!`, `*(*N?)`, and `*geo.N?`.
- `**N`, `*(*N)?`, `*?N`, `*!N`, and `[]*N` are rejected, as on `main`.
- In expression type arguments, a single handle behaves as documented:
  `Cell[*N?]`, `Cell[*(N)?]`, `Cell[(*N)?]`, `Cell[*((N))?]`,
  `Cell[~N?]`, `*geo.N?`, `*(geo.N)?`, `*W[Int]?`, and `*W[Int?]?`.
  `*(N?)`, `*((N)?)`, `*((N?))`, `*(N?)?`, and `*(geo.N?)` are rejected
  with the alias hint. The same holds for `id[...]`, `geo.id[...]`,
  `geo.W[...]`, `W[...].mk`, `Opt[...].so`, `Vec[...]()`, and nested
  `Cell[Vec[*(N?)]]`.
- `hasParenSuffix` is robust to line joins and to comments inside the
  parentheses: `*(\n N?)` is rejected, and `*(N\n )?` and
  `*( # c\n N)?` are accepted. It does not misfire on `(*N?)`
  (parentheses outside the sigil).
- The "annotate the binding" route works: `c: Cell[*(N?)] = Cell(value: *none)`.
  The SPEC's `type Held = *(Node?)` route works too.
- Migration kept every meaning. On `main` the old `*X?` (a shared
  optional) appeared only in `test/ir/types.rig`, which was correctly
  swapped to `*(Node?)`; the s-expression snapshot is unchanged. Every
  `(*X)?` became `*X?`, and `Cell[(*N)?]` became `Cell[*N?]`.
- Runtime checks ran leak-free: `!*N?` write-borrow assignment,
  `?*N?` peeking, `~N?` bindings, `*(N?)!` and `*N?!` return types,
  and a recursive `next: *(Node?)`.
- Nexus reports no conflicts, and INTERNALS says so.

**`<self`**
- Plain, generic (`first[T](<self, ...)`), and generic-type
  (`Box[T].take`) methods work, as do enum methods, imported types
  (`<b.count()` on `lib.Bag`) and imported generic enums
  (`<o.or(1)`), a temporary receiver (`Bag(...).total()`), closures
  capturing `|<self|` (plain and owned `*|<self|`), and
  `<self.twice().x` inside a `<self` method. All run leak-free.
- Use after `x = <self` is rejected, and returning `<self` works.
- Rejected as expected: `drop(<self)` ("`drop` takes its receiver
  write-borrowed"), `<self` in a free function, `<self` not first,
  `<x`, a `<self` member, `!q.c()` on a `<self` method, and `<p.a()` on
  a `?self` method. Calling without `<` gives "consumes the receiver".
- The long forms `self: ?Self`, `self: !Self`, and `self: Self` are
  still accepted, as SYNTAX claims.

**Positional variants**
- These all work and print correctly: `.circle(2)`, `Shape.circle(3)`,
  `.pt(P(x: 1, y: 2))` (a struct field), `Opt.some(7)` (inferred),
  `Opt[String].some("s")`, nested `.inner(.circle(4))`,
  `.opt(none)` / `.opt(5)` (an optional field), `.tup(.some(6))`,
  `Opt[Int?]` `.some(none)`, `Opt.some(Opt.some(1))`, `.some(.no)`,
  `.cb(*|x| x + 1)`, and the expected type through `Shape?`, a return
  type, generic parameters (`get(.some(6), 0)`), `[2 of .circle(1)]`,
  and `Vec.push(.circle(9))`.
- Imported enums work (`lib.Opt.some(4)`, `.some("x")`, `wrap(3)` in a
  generic body). `==` works with a payload literal, including an
  optional left side.
- Owning payloads work: `Opt.some(<v)`, `.sh(+n)`, `.wk(~n)`,
  `.maybe(+n)`, `.maybe(none)`, and nested `Vec`. A bare owner
  (`.sh(n)`, `.maybe(n)`) is rejected, and a generic body copying `T`
  positionally is rejected at the instance. All runs are leak-free.
- Rejected as expected: `Shape.rect(2, 3)`, `Shape.rect(2)`,
  `Shape.circle(2, 3)`, `.circle(r: 2, 3)`, `.circle(2, r: 3)`,
  `Shape.dot(1)`, `P(1)`, `Wrap(3)`, `Wrap[Int](3)`, `geo.N(1)`,
  `geo.W(3)`, `geo.W[Int](3)`, and `Opt.some(none)` ("cannot infer",
  which is correct there). Patterns are unaffected.

**Docs and hints**
- No stale `[x; n]` remains; the only ones left are the Rust columns
  in SYNTAX.md and the `;` hint tests. No `(*X)?`-as-required and no
  `self: Self`-only text remains. INTERNALS, DESIGN, SPEC, and SYNTAX
  describe the new grammar consistently, apart from F1.
- These hints were checked to compile: `(?N)?`, `(*sub())?`,
  `*(Node?)?`, `.circle(value)`, `<self`, `x: Type`, the
  `[n]T? = [n of none]` hint, and the `[n of x]` compile-time length
  hint.

## Pre-existing (not caused by this branch, noted for triage)
- `@sizeOf(*N)`, `@sizeOf(N?)`, and `@sizeOf(~N?)` give "unsupported
  type expression"; `builtinTypeArg` calls `resolveType` on an
  expression tree.
- A variant with payload defaults cascades into "variant `c` ... takes
  no payload".
- `fun f(a: Int, ?self)` gives two errors at the same position, and so
  does `<self`.
- `fun f(?self: ?Self)` gives a bare "unexpected `:`".
- The `<self`/`?self` outside-method message mentions an "errors
  declaration", but an error set cannot declare methods.
- `geo.N(1)` says "fields of `N`" instead of `geo.N`.
- `*(?0)` into `Cell[*(?Int)]` reports "expected `?Int`, got `?Int`".
