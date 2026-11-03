# Traits panel 1: ownership through traits

Expert: ownership and borrow checking. Read against origin/main 59a8c9a18:
CORE.md, SPEC §3 (Objects, Methods outside the body, Generic types,
functions, and bodies), §7 (How long a loan lasts, Second-class views,
Clone), §11 (closures), §16, §18 (task crossing table, actors), DESIGN
"Per-instance checking", formal/README, test/oracle.

Two facts from today's Rig shape everything below:

- **A generic body's ownership is already checked once,** as if `T` owns a
  resource. Moves and drops are right for every instance. Only a handful
  of per-type facts are found per instance: copies, clones, holds no loan
  (needed to store a `T` in a Cell, Signal, or owned closure), and task
  crossing. These are exactly CORE §9's "per type, one fact each."
  (Checked with `bin/rig check`: `dup[T](x: ?T) -> T = +x` fails at
  `dup[R]` and `dup[U]` with a note at `+x`.)
- **Rig already has one trait object:** an owned closure is
  `*Env` with one method, `fun invoke(?@, ...)`, and its environment
  holds no loan (SPEC "Owned closures"). Also, "a function called as a
  value is known only by its type, which names no `from` or `keeps`," so it
  is treated conservatively. And `par.each` rejects `?cb` "since its type
  does not show its captures." A good trait design generalizes these
  three precedents rather than adding a new model.

## Q1. How a trait method declares self and parameters, and how an impl matches

A trait method is written the way a method is today, with no body (or with a
default body):

```rig
trait Source
  fun peek(?@) -> ?Item from @
  sub watch(!@, s: ?String) keeps s
  fun into(<@) -> List[Item]
```

The sigil at a call site is then checked against the trait in a generic
body (`!x.watch(?t)`) and against the impl in concrete code, exactly as
today.

**Option A: exact match.** The impl restates the signature: the same
self sigil, parameter types and modes, `once`, and result type.
- Pro: the reader sees one contract, the vtable ABI is uniform, and the
  Lean and oracle obligations are smallest.
- Con: a `!@` requirement that one type meets by only reading still
  takes a write lend.

**Option B: the impl may take less.** `?@` may meet a `!@`
requirement, and `?T` may meet a `!T` parameter.
- Pro: sound, since a write view gives a read.
- Con: a second relation to specify and prove. A concrete `c.m()` and a
  generic `!x.m()` of the same method read differently. A `?@` meeting a
  `<@` requirement would need hidden drop glue, so that pairing is out
  whatever we choose.

**Option C: exact in modes, narrower in clauses.** Self and parameter
modes match exactly. The impl's `from` names a subset of the trait's, and
its `keeps` names a subset of the trait's.

```rig
impl Source for Buf
  fun peek(?@) -> ?Item from @            # same
  sub watch(!@, s: ?String)                # keeps nothing: narrower, allowed
  fun into(<@) -> List[Item]
```

A call through the trait uses the trait's clauses. A concrete call uses
the impl's narrower ones. The body is checked against its own clauses,
which is today's check.

**Default: C.** The trait's `from` and `keeps` are upper bounds. Everything
else matches exactly. `once` must match: an impl without `once` could call
twice, and one with `once` could move out of captures that a non-once
literal never gave it. Widening in the other direction (an impl that keeps
`s` when the trait does not) is rejected at the impl. It is a soundness
hole, not a style issue, because a dynamic call would end `s`'s loan while
the impl still holds a view of it.

A default method body is a generic body over `Self: Trait`. It is checked
once, with `Self` assumed to own a resource.

## Q2. What a bounded body may assume about T

Moves and drops need no bound: every `T` moves, and every `T` drops
(conservatively, as if its drop runs a body that reads its views). The
open facts are copies, clones, no-loan, and crossing.

**Option A: bounds for methods only.** Ownership facts stay per-instance.
- Pro: the smallest change.
- Con: the signature still hides "copies," the unwritten contract DESIGN
  complains about.

**Option B: built-in marker bounds, required everywhere.** Any body that
copies a `T` must say `T: Copy`.
- Pro: fully visible.
- Con: breaks every unbounded generic today, and makes `max[T]` need
  `Copy + Order`.

**Option C: marker bounds; a bounded parameter is held to its bounds.**
An unbounded `[T]` keeps today's per-instance rules (the Zig model). A
parameter with any bound is checked against its bounds alone, in the body.

```rig
fun twice[T: Copy](x: T) -> Pair[T, T]       # copy allowed in the body
  Pair(first: x, second: x)

fun cache[T: Owned](c: *Cell[T?], x: T)       # may go in a Cell: holds no loan
  !c.set(x)

fun spawn_all[T: Moves](xs: List[T]) -> ...   # may go to another task
```

The marker set is derived from CORE §9, and no user `impl` may claim one.
Each follows from the type's parts, as kinds do (CORE §10: "rules follow
the value's type"):

| Bound | Means | Holds for |
|---|---|---|
| `Copy` | a bare use copies | plain kind, and read views |
| `Clone` | `+x` makes a new owner | `sema.cloneable != .no`; implied by `Copy` |
| `Owned` | carries no loan | no part is a view (`Static` is fine) |
| `Moves` | may move to another task | the "moves" column of §18 |
| `Shares` | may be read by several tasks | the "shares" column of §18 |

`Owned` also improves precision. A `T: Owned` taken by value is not
counted as returning or storing a parameter's loans, which SPEC "Generic
bodies" must assume today for any `T`.

**Default: C.** It is explicit where it matters and gives an easy
migration. A later, separate decision could require bounds on `pub`
generics, where the unwritten contract crosses modules.

### Views as type arguments

`T = ?String` is legal today (`same(?v)` gives `T = ?List[Int]`). Two
options for how a view meets a trait bound:

- **Option (a):** `?X` meets `Trait` when `X` does and every method of
  `Trait` takes `?@` (the trait is "read-only," which can be decided from
  its declaration). Dispatch passes the view itself, since "a read view of
  a read view is that read view." A result `from @` views what the view
  views, as "a view reached through another view" does today.
- **Option (b):** a view never meets a non-marker bound. Callers write
  `x: ?T` and lend.

**Default: (a).** Otherwise inference from `show(?v)` picks
`T = ?List[Int]` and fails, which is surprising. `!X` is never a type
argument, and `<@` and `!@` methods are never reached through `?X`.
Handles need no auto impls: the lend table already turns `?b` of a `^X`
or `*X` into a view of `X`.

## Q3. Trait objects

A trait object stands for some type that implements `Tr`. Its forms
follow the four kinds:

| Form | Kind | Methods callable | Copy and clone | Notes |
|---|---|---|---|---|
| `?Tr` | read view | `?@` | copies | second-class like `?T`; a fat pointer |
| `!Tr` | write view | `?@`, `!@` | never copied or stored | bound to a local or parameter only |
| `^Tr` | owner (box) | `?@`, `!@` (via `!b`), `<@` (`<b.m()` frees the box) | `+b` only if `Tr` requires `Clone` | |
| `*Tr` | counted handle | `?@` only (handles only read) | `+s` counts | `~Tr` is weak |

A bare `Tr` by value is rejected, since its size is unknown. Methods
that mention `Self` outside `@`, that have their own type parameters, or
that take no self are not callable through an object, and the error says
why. The trait itself stays usable as an object.

Making one: `area(?c)` lends `?Shape` where one is expected. This adds a
new lend-table row ("a `T` that implements `Tr`: `?x` lends `?Tr` when
`?Tr` is expected"), and the read lend may go unwritten as an argument, as
today. `b: ^Shape = ^<c` converts at a written expected type.

### What the checker must know about loans

**Option A: no-loan homes, like owned closures.** `^Tr` and `*Tr`
require the packed type to be `Owned`.
- Pro: simple. The object type's facts are fixed, and it can be stored
  anywhere.
- Con: rules out `^Tr` over a type holding a `?String`. It also mostly
  forbids `keeps` methods on boxed objects, which could keep only a
  `Static`.

**Option B: carry the loans they were made from.** `^Tr` and `*Tr`
carry the loans of what they were made from, as `^T` and `*T` already
do ("`*T` carries the loans of what it holds"; `^?v` keeps `v` lent).
Erasing the type erases no loan, because loans follow the value.
- Facts of an unbounded object type: may hold a loan, drop reads its
  views (the drop body is unknown, so loans last to the drop, not the
  last use), not `Copy`.
- `^(Tr + Owned)` opts back into Option A's freedom. It is required to
  put the object in a Cell, Signal, owned closure, actor, or channel.
- `^(Tr + Moves)` and `?(Tr + Shares)` are required to cross tasks.
  This generalizes the `par.each` rule.

**Default: B.** It agrees with `^T` and `*T`, and markers recover the
no-loan and crossing cases. The cost is that loans held by an unbounded
`^Tr` last to its drop.

### `from` and `keeps` through dynamic dispatch

A call through `?Tr`, `!Tr`, `^Tr`, or `*Tr` uses the **trait method's
declared clauses**, not the conservative rule for function values. Under
Q1-C, every impl's clauses are within the trait's, so this is sound:

- `from @` makes the result carry the object's loans (and the loan on
  the holder's place for `^Tr`).
- `keeps s` makes what is stored land in what the write self sees. For
  `!b.watch(?t)` on `b: ^Watcher`, `b` then carries `t`'s loan.
- An owned closure is the case where the trait has one `invoke(?@)`
  method and no clauses, so today's rule falls out unchanged.

The IR records, at each dynamic call, the trait method it dispatches to,
so the oracle reads the same clauses. Lowering: `?@` becomes a const
pointer through a thunk (a `?@` impl of a small plain type takes self by
copy), `!@` a mutable pointer, and `<@` a pointer plus a box free.

## Q4. What each checker must add (new rules only)

**src/ownership.zig (and sema facts)**
1. **Method resolution on a bounded `T` and on a trait object:** the
   self, modes, `from`, and `keeps` come from the trait declaration.
   The existing call rules then apply unchanged.
2. **Impl conformance (new, soundness-relevant):** modes match exactly,
   `once` matches, and the impl's `from` and `keeps` are subsets of the
   trait's.
3. **Bounded-parameter facts:** for a parameter with any bound, copying
   or cloning without `Copy`/`Clone`, storing in a no-loan home without
   `Owned`, or crossing tasks without `Moves`/`Shares` is an error in the
   body. Instances are checked against the markers structurally.
4. **Trait-object types and their facts** (table above). A conversion
   carries the source's loans.
5. **A read view meets a read-only trait** (Q2 (a)).

**test/oracle**
- `kinds.zig` computes trait-object and bounded-parameter facts itself,
  never from the compiler.
- `lower.zig` reads the trait's `from` and `keeps` for bounded and
  dynamic calls, as `declaredFrom` and `declaredKeeps` do now.
- New rule (call it C10): an impl's clauses are within its trait's. The
  oracle must check this independently, because the compiler getting it
  wrong is a dangling view.
- New rule: a copy of a bounded `T` needs `Copy`.
- Until these land, the oracle abstains on dynamic calls.

**formal/ (Lean)**
λRig today has only Int and `^Int`, with no functions, so traits have
nothing to attach to yet. The new obligations, in order:
1. Functions with `from` and `keeps` (a prerequisite).
2. A **subsumption lemma:** a call checked against wider clauses is sound
   for any callee whose body meets narrower ones. This is what makes
   dynamic dispatch sound.
3. **Packing:** a value of erased type keeps its loan tags, and `Rel`
   holds with the most conservative facts (owning, drop reads).
4. `Copy` restricted to plain kinds in the copy step.

**Default:** no Lean change in the first traits slice. Record items 2 to
4 in `docs/design/formal-plan.md`.

## Summary of defaults

1. Signatures match exactly. Only `from` and `keeps` may narrow in the
   impl. The trait's clauses bound dynamic calls.
2. Built-in markers `Copy`, `Clone`, `Owned`, `Moves`, `Shares` are
   derived from the type's parts and never impl'd. A bounded parameter is
   checked against its bounds; an unbounded one keeps today's
   per-instance rules.
3. A read view `?X` meets read-only traits.
4. Trait objects are `?Tr`, `!Tr`, `^Tr`, and `*Tr` (and `~Tr`). They
   carry their source's loans. `+ Owned`, `+ Moves`, and `+ Shares` are
   needed for no-loan homes and for tasks.
5. Dynamic calls use the trait's `from` and `keeps`, and the owned
   closure becomes the one-method special case.
6. Add the oracle conformance and copy rules, and only obligations for
   Lean.
