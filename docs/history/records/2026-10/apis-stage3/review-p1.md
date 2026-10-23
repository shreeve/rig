# APIs Stage 3, phase 1: adversarial review (2026-10-23)

A review of PR #579 ([phase1-notes.md](phase1-notes.md)) after its
rebase onto `main` (the consolidation fixes #573 to #576), hunting North
Star 1: a program `rig check` accepts that then fails in Zig, crashes,
leaks, or misbehaves, and a construct silently dropped. About 90 probe
programs, each run with `rig check` and, when accepted, `RIG_SANITIZE=1
rig run`, on a self-check build (which refuses a module that types an
expression `invalid` with no error). Each fix has its case in
`test/rig/types-apis.rig.test`.

## Findings, by severity

### High: accepted now, and phase 2 could lower it wrong

1. **A provision implied through an API escaped the home rule.** A type
   that provides `Named` provides `Shape` when `api Named: b.Shape`
   (decision 2), but an addition was checked only against `Named`'s
   module. So `add Int: Named` in module `c` gave `Int` a second
   `b.Shape` beside `b`'s own `add Int: Shape`; two modules `c` and `d`
   could each give `Int` its own `area`, neither seeing the other; a
   header `obj Tile: b.Shape` and an `add a.Tile: Named` elsewhere were
   both accepted; and `sema.provides` answered yes in `c` and no in the
   root module, which searches only its own, the API's, and the type's
   module. *Fixed:* an addition gives the APIs its API builds on too, so
   it is written where each of them may be: in the type's module (under
   a bound), or in a module that declares every API it gives. With that,
   every provision of a type and an API lies in the type's module or the
   API's, so `provides` searches enough and the per-module duplicate
   check is complete (phase1-notes decision 3's argument holds again).
   Cases "apis own home of what it builds on", "apis own builds on,
   added".
2. **Compile-time parameters were compared by count alone.** Against
   `fun conv[U: Print](?@, u: ?U)`, implementations with `[U: Print +
   Ord]`, `[U]`, and `[U: Shape]` were accepted, as were `[n: U8]` and
   a type `[N]` against `[n: Int]`; a call through the API would pass a
   `U` the body cannot use, or a value where a type goes. *Fixed:* each
   is the same kind, of the same type, with the same bounds, compared
   by what the bounds imply and build on (`[K: Hash]` meets `[K: Eq +
   Hash]`). Cases "apis own compile-time parameters", "apis own
   compile-time bounds".

### Medium

3. **No addition to `String` could take `?@`.** A `?String` is the view
   of text (`string_view`), not a `read_view`, so every `add String: A`
   with a `?@` method was rejected as taking no self. *Fixed* in
   `classifyReceiver`. Case "apis own string".
4. **An addition could name a built-in type's own member** (exposed by
   3): `add String: Has` declaring `push` or `len`, `add List[T]: Has`
   declaring `is_empty` or `len`, `add Symbol: Named` declaring `text`,
   which the design forbids ("an addition may not define a method the
   type already has"); the check saw only declared types' methods.
   *Fixed* (`builtinMember`). Case "apis own add has a built-in member".
5. **Defaults' bodies and additions' methods are not checked at all,**
   not even for a name that names nothing (`nosuch + 1` is accepted),
   though the notes said "resolved": unbound names are the
   typechecker's. Nothing wrong reaches Zig (they are never emitted, and
   nothing calls them: `5.area()` and `s.describe()` are rejected), but
   such programs will be rejected once phase 2 checks the bodies.
   *Parked to phase 2,* with the case "apis own default unchecked"
   (`known: true`), and decision 1 corrected in the notes.

### Low

6. **`api Int`, `api Float`, `api U8` were accepted** and could never be
   named (`[T: Int]` reads as a value parameter). The class: `obj Int`,
   `enum U8`, and `type Bool = ...` were accepted before this PR and
   never reached, since the name names the built-in type. *Fixed:* a
   type, an API, or an alias named as a built-in type is reserved, as
   `String` was. No such name in std or Trig. Case "apis own named like
   a type".
7. **`[T: geo.Shape]` with no `use geo`** said "a compile-time value
   parameter starts with a lowercase letter". *Fixed:* "use of unbound
   name `geo`", with the other-file hint. Case "apis own bound of a
   module not imported".
8. **`add Slot[n]` and `add Table[T, n]`** said to write `add Slot[T]`.
   *Fixed:* "an addition to a type with a compile-time value parameter
   is not built yet", checked before the arguments; the instance message
   now names the type's own parameters (`add Map[K, V]`). Case "apis own
   add a value parameter".
9. **An unprovided bound's fix suggested `add fun() -> Int: Shape`.**
   *Fixed:* a view, an optional, a handle, a function type, an array, or
   a slice "provides no API of a program's own". Case "apis own
   unprovided function".
10. `rig.unpub`'s doc comment sat above `isApiDecl`. *Fixed.*

## For phase 2 (design points, not fixed)

- **Parameter defaults are not compared.** `fun f(?@, x: Int = 1)` in an
  API is met by `x: Int = 2` or by no default; a call through the bound
  must take one of them. Swift forbids defaults in a protocol's
  requirements. Default suggestion: phase 2 rejects a default in an
  API's method, or requires the implementation's to be the same.
- **Parameter names are not compared.** `pick(?@, first: Int, second:
  Int)` is met by `pick(?@, second: Int, first: Int)`; a call through
  the bound with keywords binds by the API's names and passes them by
  position to the implementation's other names. Swift requires the same
  labels. Default suggestion: require the same names.
- **Decision 2 against Rust's rule.** With finding 1 fixed, a built-in or
  another module's type can provide an API built on another module's
  API only when one module declares both. Rust's rule (an API's
  requirements are provided separately) would allow `add Int: Named` in
  `c` beside `b`'s `add Int: Shape`. A question for the owner only if a
  real program needs it.
- **Two defaults across modules.** `X: A` on its header and `X: B` by an
  addition in `B`'s module, both defaulting `name`, are each seen in one
  module, so decision 8 does not fire; the design's call-site rule
  (`x.name()` names the API when two give it) must be phase 2's check.
- `api Marker` with no methods and no APIs it builds on is a parse
  error; `api Job: Moves` parses.

## Probed without findings

Direct calls to an addition's method (`5.area()`) and to an unwritten
default (`s.describe()`), rejected; an addition in a third module,
rejected; generic types with headers (`obj Box[T]: Shape`, `obj Box[T:
Shape]: Shape`, `enum Tag[T]: Shape`); enums and `unique` objects
providing an API; `*Actor[A]`, `*Frozen[T]`, closures, and function
values meeting no bound; cycles (`api A: B`, `api B: A`, `api C: C`);
`Shape + Ord` mixing a program's API and a built-in one; `api Print`;
locals and parameters named like an API; additions to `Map`, `Set`,
`Cell`, `Signal`, `List`, `Int`, `Float`, `Bool`, `Symbol`, `Static`,
type aliases (`add I: Shape` and `add I64: Shape` are one type);
duplicate and conditional additions (`List[T]` and `List[U: Print]`,
header and addition of one API); nested conditions (`Wrap[Wrap[Int]]`);
contextual keywords (`api = 1`, fields and methods named `api` and
`add`, `!s.add(x)`, `add` in a body); `trait` and `impl`; `pub add`,
`pub` inside `api`; an API as a type, alias, field, generic argument,
and value (`Shape.area(c)`); detached methods (`fun Square.area`);
bounds through bounds (`[T: Named]` calling `[U: Shape]`), and an
unbounded generic instancing a bounded one, in the module and across
modules (bounds checked at each instance); `self`, parameters, `once`,
results, sets, `from`, `keeps`, `Self` in parameters and results, a
`Self` that is a generic type; `api Job: Moves` and `api A: Copy`
against a provider that cannot; `rig emit`, `rig check --facts=sema`,
`=storage`, `=proofs`, `--time`; and `rig lsp` (open, every prefix of
each file as an edit, semantic tokens, symbols, folding, save) on five
API programs, with no crash and no leak. No accepted program typed an
expression `invalid` under the self-check build.
