# R2.5: generic error sets (design)

Round R2.5 of errors with data, from the approved spec
(docs/history/records/revamp/r3/errors-panel/errors-spec.md §3.5, panel
D7, decision 11), started 2026-10-22 on Rig's word: "Start R2.5 (generic
error sets) now. It's the one language feature in flight."

## 1. The form

```rig
error Bad
  empty
  long(n: Int)

sub check(s: ?String)!Bad
  return Bad.empty if s.len == 0
  return Bad.long(n: s.len) if s.len > 3

sub each[E](xs: []?String, f: ?sub(?String)!E)!E
  for x in xs
    f(x)!

sub main()
  each(["a", "", "b"], check) catch |e|
    match e
      .empty => print("empty")
      .long(n) => print("long", n)
```

Without it a declared set collapses to `T!` at the first callback.

## 2. The rules

1. **A set parameter.** A function's type parameter written after `!`
   (`T!E`, `sub f()!E`, `?sub(...)!E`) is a set parameter. It is bound
   only to an error set: a declared set, a union, or `error`. Binding
   anything else is rejected at the call: "`E` names an error set, and
   `Int` is not one".
2. **Where it is written.** In the function's signature a set parameter
   appears only after `!`, and only in a callable view
   (`?fun(...) -> T!E`). As a value's type (`e: E`, `-> E`, `List[E]`)
   it is rejected: "`E` is an error set: it goes after `!` (`T!E`), and a
   value of it is caught (`catch |e|`)". In a function value's or an
   owned closure's type (`fun(Int) -> Int!E`, `*fun(...)`) it is
   rejected too: "a function that fails with `E`, a set parameter, is
   lent: take it as `?fun(...) -> T!E`" (§3 says why). The body may
   name `E` in a local's type, where it is an error. Only a function's
   own parameters; an object's are not sets (out of scope).
3. **Inference.** The set binds from the failure of a function-typed
   argument: a callback failing with `Bad` binds `E = Bad`, a `T!`
   callback binds `E = error` (D7: `T!` still goes where `!E` does).
   Two callbacks with different sets conflict, as two types do today;
   the caller names a union, `each[L](...)`. A closure literal binds no
   set: it is checked against the set another argument, the expected
   result, or brackets give, and with none of them the set is `error`
   (sets inferred from a body stay out, spec §13). Named in brackets the
   set is checked like any type argument.
4. **In the body.** `!` passes a failure of `E` into a function that
   declares `E`; any other set, `T!` included, does not fit (`E` may be
   any set, so only `E` and `error` hold `E`). A `catch |e|` of a call
   failing with `E` binds `e: E`. A value of `E` does what an `error`
   does (a `match` with `_`, narrowing `g: Bad =>`, member patterns,
   `print`, widening to `error`, `?e` where `?error` goes), and a
   failing `return e` re-raises it into `!E`. A `match` that misses `_`
   says "`match` on `error` is not exhaustive", as one on `error` does.
   A task over such a function needs a set that holds `task.Stop`, as
   every task does.
5. **At the call.** The result's set is `E` substituted: `each(xs,
   check)` fails with `Bad`, so its catch binding is a `Bad`, matched
   without `_`.

## 3. What it lowers to

- `E` is a `comptime E: type` parameter, as a type parameter is; the
  call passes the set's Zig error set (`Bad`, a union's merged set, or
  `anyerror` for `error`), never its value type (`GenericCall.sets`).
- A frame failing with `E` is `E!T` in Zig and takes `__out`, as a `T!`
  frame does, whatever set an instance binds: its callers pass a slot
  (`GenericCall.fails_by_set`), and fields pass through it unchanged.
- **One callable type in every instance.** A callable view of any
  fallible function takes the slot, whatever its set: `?fun(Int) ->
  Int!E` is `FnRef(&.{ i64, ErrSlot }, E!i64)`, and the instance `Bad`
  must be the same Zig type as the caller's `?fun(Int) -> Int!Bad`.
  `FnRef` already drops the slot for a function that takes none
  (`argsFor`), so a set without fields lends as before. A frame with no
  slot of its own that calls such a view, or a function generic over its
  set, lends a slot of its own, as a `catch` does: a re-raise
  (`return e`) copies the slot whatever the member. The runtime calls a
  fallible arm of `task.select` with the slot its `!` or `catch` lends
  (`selectInto`).
  No program in std, examples, or Trig lends a callback with a declared
  set, so no existing code changes; in a program whose sets have no
  fields the slot has no bits. A function value or an owned closure has
  no such adapter, which is why rule 2 keeps `E` out of their types.
- A value of `E` in the body is a `rig.ErrorValue`, as `error`'s is
  (option U): built from the code and the slot at the catch, failed
  with `@errorCast` to `E`, which holds the code by typing; its `match`
  switches on the whole code, as `error`'s does.

No `T!` frame and no frame of a declared set changes, so json and Trig
emit the same Zig (checked with `emit` diffs).

## 4. Where it is built

| Pass | Change |
|---|---|
| resolve | `markSetParams` flags a type parameter written after `!` in its signature (`SymbolFlags.set_param`) before any type names it; `resolveFailSet` takes it and records an `.error_set` requirement; `setParamAsValue` checks rule 2 |
| sema | `isSetParam`; `isErrorValue`, `holdsIn`, `deepCloneable`, and `errorSubset` see a set parameter as an `error` that only itself holds; a fallible's set is one of its child types (`TypeChildren`), so `T!E` mentions `E` |
| typecheck | `bindArg` and `bindReturns` bind the set (`bindSet`); the `.error_set` requirement; a `match` reads `E` as `error`; `E` and `?E` meet `error` and `?error`; `GenericCall.sets` and `fails_by_set` |
| emit | `isErrorValueTy` and `isErrorSetTy` take a set parameter; a set type argument is written as its Zig set; the callable slot rule above |
| runtime | `selectInto` |

## 5. Out of scope

Unions over a parameter (`error L[E] = E | Io`), a set parameter on an
object, sets inferred from a body, and errors generic over a type
(`SendError[T]`) stay out, as spec §13 says.
