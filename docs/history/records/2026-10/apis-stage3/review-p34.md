# APIs Stage 3, phases 3 and 4: adversarial review (2026-10-23)

A review of PR #588 ([phase3-notes.md](phase3-notes.md): method-level
bounds, additions to types with value parameters) and PR #594
([phase4-notes.md](phase4-notes.md): associated types, `Iter`,
std.iter). It hunted North Star 1, 2, and 4: a program `rig check`
accepts that then fails in Zig, crashes, leaks, or misbehaves under
`RIG_SANITIZE=1`; a construct silently dropped; a second classifier
beside `sema.iterItem`. 111 probe programs, each run with `rig check`
and, when accepted, `RIG_SANITIZE=1 rig run`, with the oracle
(`bin/rig-oracle`) on each, several compared with `rig emit`, and
`rig tokens` and `rig parse` compared between the two branches. Each
fix has its case in `test/rig/types-apis.rig.test`.

## Findings, by severity

### Critical: safe code read freed memory (phase 4)

1. **An item that views memory its iterator owns.** A generic body
   tracks no view a value of a type parameter holds, and an associated
   type lets the provider choose a view: `next(!@) -> (?String)? from @`
   returning `?@buf`, a `String` the next call replaces. `keep[I: Iter]`
   pushing each item into a list, or `first[S: Source]` holding the
   first `take` across the second, read freed memory; the same loop
   over `Buf` itself is rejected (`b` kept lent while the item lives).
   *Fixed:* each instance rejects an associated type that may view memory
   its base owns, by the ownership checker's own reach
   (`sema.viewReach` is `owned`), in `sema.checkBounds`. Items that own
   what they hold, or view only what the iterator views (`text.split`'s,
   any `Int`, `String`, or `Float` item), are taken as before. It is an
   interim rule, and costly: it judges the instance, not the body, so
   `iter.count`, which holds no item, is rejected for such an iterator
   too, and so are a Map's and a Set's iterators, whose items the
   ownership checker cannot show to lie outside them (a loop over one
   holding an item across `next` is rejected the same way). Cases "apis
   iter an item that views its iterator" and "iter a map's iterator";
   SPEC, STD, CHANGELOG, and phase 4's decision 9 say it. The design
   question is below.

### High: accepted, then failed in Zig

2. **A method under a bound that takes no self** (phase 3):
   `fun Wrap[T: Shape].mk(x: T) -> Wrap[T]`, called `Wrap.mk(...)`, took
   its witnesses first but its call passed them after the first
   argument. *Fixed:* the call passes them after self only when the
   method takes self. Case "apis own method bounds with no self".
3. **A method's bound beside its type's** (phase 3): with `obj
   Box[T: Shape]` and `fun Box[T: Named].f`, an instance of `Box` first
   named while the method's bounds widened `T` (`Box[U]` in a body
   bounded `[U: Shape + Named]`, or the method's own `Box[T]`) recorded
   the method's witness among the type's arguments, and Zig found three
   for two. *Fixed:* such an instance is recorded after the method's
   check, by its declaration's bounds. Case "apis own method bounds
   beside the type's".
4. **A bound by `Iter` met by a view** (phase 4): `f[I: Iter](it: I)`
   called `f(?c)` took `I = ?Count`, and emit's `rig.IterItem(*const
   Count)` failed; with `[I: Iter + Copy]` a body advanced a read view.
   *Fixed:* a view is no iterator to the bound (`sema.iterLack`), as the
   loop already says of `for x in ?it`. Case "apis iter a view, a private
   next, and another shape".

### Medium

5. **A private `next` through `[I: Iter]`** (phase 4): a body in one
   module walked another module's type whose `next` is private, which
   the loop and a Stage 1 call both reject. *Fixed:* `sema.iterLack`
   names it, with the fix `pub fun next`. Same case as 4, whose third
   message also now says why a `next` of another shape is none
   (`its next takes more than @`), not "declares no `next`".

### Low

6. **`?Item` at `Item = String`** (phase 4): `fun first(?@) -> ?Item`
   could not be met by `-> ?String`, the one text view, since the match
   saw a text view where it looked for a view. *Fixed:* `sema.matchAssoc`
   reads `?String` as `?Item` at `String`. Case "apis own associated
   type behind a text view".

### Found, not these phases' (parked)

7. **Build output:** both PRs carried a debug run's tree,
   `examples/json_tour.rig.debug/`, which main also tracked; #597
   removed it there and ignores `*.rig.debug/`, and both commits are
   rebuilt without it.
8. **Stage 2:** `[T: Clone]` rejects `+x` on `x: ?T` ("does not give a
   value that copies"), though `Clone` is the bound that gives `+x`.
9. **The oracle is stricter in one shape:** `swap[H: Holder, H.Item:
   Copy]` reading `x = a.get()` (`from @`) and then writing `a` is
   rejected by the oracle and accepted by the compiler. With finding 1's
   rule the compiler is sound there (no accepted instance has an item
   that views its base); no test holds the shape.

## A design question for the owner

How a generic body treats a value of an associated type that may view
its base. Finding 1's rule rejects instances; the alternatives move the
judgment into the body:

1. **Keep the instance rule** (built): sound and small; std's Map and Set
   iterators never go through `[I: Iter]`, and `iter.count` is refused
   where it would be safe.
2. **The body tracks it:** a value of `S.Item` from a call on `s` keeps
   `s` lent, as the concrete loop does, unless the item's bounds make it
   an owner (`Num`, or `Owned`). Precise per body; SPEC's `most[S:
   Source, S.Item: Ord + Copy]` and std-iter's `show` would add
   `Owned`, and a body holding `text.split`'s items across `next` would
   be refused.
3. **Both:** the body records whether it holds an item across a change
   of its base, and the instance rule applies only to such bodies.
   Precise for both; the most code (the ownership checker records a fact
   for generic bodies). A nested generic that passes its iterator on
   without naming `J.Item` also needs it, where today's rule sees only a
   type variable.

*Default:* 3, as its own change before Stage 3's last phase; until then
1 keeps #594 sound.

## Decisions checked

- **Phase 4, decision 2** (an associated type is what the methods
  give): two required methods that disagree are rejected at the
  provider ("matched exactly"); an API whose two associated types come
  from two methods (`Item`, `Key`) infers both; `Source + Sink` both
  declaring `Item`, or `Source + Iter`, makes `S.Item` ambiguous, with
  an error. No ambiguity found beyond finding 6.
- **Phase 4, decision 6** (`keeps a, b` for two `!I`): sound, since the
  caller then treats each as holding the other's views, and finding 1
  leaves only items that view outside both iterators. Over-broad for
  items that hold no view at all (`Int`), which the body cannot tell
  apart; narrowing it is the backlog's view-tracking item.
- **One classifier:** the loop (`iteratorShape`), the bound (`lacks`),
  `I.Item` (`assocType`), and `iterNextCall` all read `sema.iterItem`;
  `rig.IterItem` in Zig reads the same `next` result emit writes, and
  witnesses' `pub const Item` come from `Conformance.assoc`. The view
  and visibility rules of `sema.iterLack` are a bound's additions on top
  of it, as the loop's own `?it` and visibility checks are on top of it.
- **Grammar:** `[n: Int]`, `Map[K, V]`, `x[i]`, `one[Int](3)`,
  `sz[4]()`, `Grid[2, Int](...)`, and slices tokenize and parse
  identically on both branches; `[S: Iter, S.Item: Int]` says `Int`
  names no API; `T.Item` naming another bracket's parameter, and
  `S.Item.Item`, are errors.

## Probed without findings

Phase 3: method bounds with `?@`, `!@` (through a bound, by name, as a
task, on a list element, in a loop), `<@`, and no self; results `from @`
and `from o` outliving their source rejected; chains of methods under
bounds across generic types three deep; a method bound by
`Shape + Print`; built-in bounds (`Eq` on `String`); a method under a
bound called from an addition's method, from a closure, inline, and
recursively; two methods of one name under different bounds rejected;
a method naming its type's parameters out of order rejected; actors
calling one in their methods; across three modules with additions to
`Int` and `Slot[n]` in the API's module. Additions: `Slot[n]` at two
`n` in one program, `Table[T, n]` of `Int`, `String`, and objects with
defaults (one addition reading its `n` and its elements through a
bound), `Ring[T: Shape, n]` nested in itself, a slot and its table each
providing the API, two additions to `Slot` or `Table` rejected, and
tables of tables rejected for want of a default.

Phase 4: `I.Item` owned (`String`) pushed into lists, kept in maps,
stored in a generic type's field, returned, dropped by a `break`;
`iter.count` consuming (a second count gives 0), `iter.sum` over `Int`,
`Float`, an empty iterator (`none`), `U8` overflow (panics, as `+=`
does), and map values (rejected: `?Int` is no number); std iterators
from strings, maps, and sets; user iterators of generic types; `Iter`
as a supertrait; `[I: Iter]` in generic types (`Box[S: Iter, S.Item:
Ord]`) and in method bounds (`fun Wrap[T: Iter].nx`); associated types
through additions with their own parameters (`add Wrap[T: Copy]:
Source`), through `add Int: Source`, two nested generic types, and
across modules; `next` that fails, takes an argument, or takes `?@`
rejected by the bound and the loop alike.
