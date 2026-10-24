# APIs Stage 4, phase 3: adversarial review (2026-10-23)

A review of PR #614 ([phase3-notes.md](phase3-notes.md)) against the
approved CORE text (§4, "An API object hides its value's type, never
its loans"), the panel's holes H1 to H13 ([core-panel/](core-panel/)),
and phase 3's contract: a `^T` moves into a `^{A}` keeping its
allocation, the box drops through its table, `<@` ends it once, and
every misuse is a Rig error. About 225 probe programs (one of two
modules), each run with `RIG_SANITIZE=1 RIG_LEAK_TRACE=1 rig run` and
the oracle (`rig-oracle -v`); the task probes under seeds 1 to 20. Each
fix has its case; the full suite is green.

## Findings, by severity

### High: accepted, then failed in Zig

1. **A value holding a channel or an actor could not be erased.** Every
   table holds a print entry, made for the hidden type whether or not
   the braces name `Print`, and printing a `*Chan[T]` or a `*Actor[T]`
   reached `value.value.get()`, which only a Cell of one word has. So
   `b: ^{Shape} = ^Pipe(ch: +ch)`, and `?{Shape}` of the same value
   (phase 2), failed in Zig with no `print` in the program. The cause
   is older than objects: `print(ch)` itself failed in Zig on `main`.
   *Fixed:* a channel prints as `<chan>` and an actor as `<actor>`, as
   a function prints `<fun>` (SPEC's table of printed forms). Case
   "apis object box of a value holding a channel or an actor".

### Medium: a stated rule got past

2. **A task hidden in an object** (the Stage 5 designer's first hole).
   `task.isolate(|| mk())` with `mk() -> ^{Shape}` returning a `^Job`
   whose field is a running `Task[Float]` was accepted: isolate rejects
   a value whose type shows a task, and the object hid it. The same
   hides a task from an error's field and from a crossing. *Fixed:* an
   erasure, of a view or a box, rejects a value whose type holds a task
   or a set of tasks, naming the field (`erasable`, `taskField`): "`Job`
   is erased to `^{Shape}`, which would hide a task from the rules that
   wait for one, and its field `t` is a `Task[Float]`: wait for the task
   before erasing". Case "apis object box hides no task".
3. **An object printed through a generic body.** `sub show[T](x: T)
   print(x)` at `T = ?{Shape}`, and `show_view(?b)` at `T = ^{Shape}`,
   printed the hidden value with no `Print` in the braces or the API,
   against H13 and open question 12. Phase 2's views had it too. The
   `printable` requirement of a generic body checked only `[]U8`.
   *Fixed:* the requirement also needs `objectUnprinted` to find
   nothing, and the error names the object. Cases "apis object printed
   through a generic body" and "... by the braces".

### Oracle: the ref-gap was a gap, and wider

4. **The oracle never read an API's `keeps` or `from`.** `findFun`, which
   finds a declaration's clauses by position, walked modules, objects,
   and enums but not `api` or `api_add` nodes, so a call through an
   API's declaration (dynamic, by the API's name, or through a bound)
   kept nothing and took its result's loans by type. That is the
   `ref-gap` the builder listed, a dynamic call's `keeps` into a box,
   and the same gap for a static `Shape.watch(!n, ?t)` on a plain value:
   the compiler's rejections were right (a box whose drop reads a
   dropped `t` is a use after free). *Fixed:* `findFun` walks both; the
   allowlist entry is gone, and the oracle now rejects three functions
   it accepted or abstained on (added to `test/oracle/rejections`).
   Case "apis a call by the API's name keeps what the API keeps".

## The builder's decisions

1. **`Ph[^{Shape}].mk()` at object arguments:** sound. A body that
   copies a `T` (`Ph(a: x, b: x)`, `@a` returned), compares one (`==`),
   hashes one (`Map[SB, Int]`, `Set`), clones one, or calls a method on
   one is rejected at the instance; one that moves, pushes, and lends
   (`?@items[0]`) runs clean. Printing was the one hole (finding 3).
2. **Zig types with the braces:** right; `$name` spells `^{Shape}`,
   `^{Shape}?`, `^{shapes.Shape + Clone}` across modules.
3. **The no-default message suggests `^{Shape + Owned}?`:** right, as
   the table's no-view rule rejects `^{Shape}?`.
4. **Any task given an object runs locally:** replaced by the owner's
   decision (below), after the Stage 5 designer's second hole; as built it was otherwise sound: `?b.area()&`,
   `(!b).grow()&`, `<b.close()&` (fallible too), `f(<b)&`, `f(?b)&`,
   ten boxes closed in tasks, each clean under seeds 1 to 20, and a
   box lent to a task blocks a move, a write, and a scope's end.
5. **`??` does not erase its fallback:** right as built; where the left
   is already a `^{A}?` the fallback is erased against its type and
   runs clean both ways.

## The second hole: objects and local tasks

A `^{Shape}` hiding an owned closure reaches two local tasks at once:
`area_of(?b)&` and `?b.area()&` with `b = ^Holder(f: *|| 2.0)` are both
accepted, where SPEC keeps an owned closure (and a set of tasks, a
`?fun`) from every task, a local one included; `?b.area()&` of the
`^Holder` itself is rejected. The designer's recommended default, put
to the owner: an API object without the crossing bound a task needs
goes to no task, a local one included (narrowing Stage 4's default 14).
The owner approved it ("Yes, that is the best route"), and it landed
as its own commit with its case, "apis object box goes to no task".

## Parked

- Low, older than objects: the oracle rejects a closure literal handed
  to a `?fun` parameter whose result may hold a view (`run(|| mk())`,
  `task.isolate(|| mk())`), as if the result viewed the closure itself;
  the compiler is right to accept (a closure's own captures cannot be
  returned as views). No case in the suite has it.
- Low: an object prints its hidden text quoted at the top level,
  `print(b)` of a `^{Shape + Print}` holding `String("x")` gives `"x"`
  where `print(s)` of a `^String` gives `x`; the print entry passes no
  `top`.
- Low: `swap(!h.g, v)` of a `^{Shape}` is rejected, as a value that may
  hold a view; `^{Shape + Owned}` swaps.
- Low: a task whose result is an object, `make()&` with `make() ->
  ^{Shape + Owned}`, is rejected even though it could run locally.

## Probed without findings

Drop order: a box whose drop body reads a loan, the owner declared
before and after it (rejected after), reassigned, moved, or dropped
while the box lives, and through `keeps` by a dynamic call, by the
API's name, into a List's element, an optional's value, and a moved
box. `<@` methods: freeing once, failing midway (`catch |e|`, `!` in a
fallible caller), in loops with `break` and `continue` (a second
iteration's use rejected), conditionally, through `if <b as x`, by the
API's name, through views and `?^{A}` (rejected), under `defer`
(rejected), in tasks. Replacement while a `?{A}` or `!{A}` of the old
box lives (rejected), through `!^{Shape}` parameters, of fields, of
List elements, of `match !e` payloads. Clones: independent of their
originals through nested boxes, Lists of boxes, and optionals; `Clone`
of a type holding a box without `Clone` rejected. Prints of nested
boxes and Lists of them. `List[^{A}]`: insert, remove, swap, pop, keep,
clear, sort by a key, 1,000 elements, views live across each
(rejected). `Map[String, ^{A}]`: put over an old value, get, edit, take,
a view across a put (rejected). Recursion: 100,000 and 200,000 long
chains through two APIs, depth-12 trees. Objects of objects, a List of
boxes inside a box, mutated through `!@`. Boxes returned through
`return`, `if`, a ternary, `match`, optionals, several results, and
generic `^T` and `^T?` parameters. `+ Owned` over views reached through
generic instances, enums, Lists, optionals, nested boxes, and object
views (each rejected, naming the field). Closures: stack captures by
`?`, `!`, and `<`, owned closures of `Owned` boxes kept in a List and
returned. Actors' results and state, `par.each`, `*Frozen` of a holder
and of a List of boxes (each rejected). Modules: another module's API,
its additions to `Int` and `String` boxed, `+` and `<@` through them.
Hidden types holding Maps, Sets, Lists, `*Int`, owned closures,
`*Signal`s, and frozen handles, erased and cloned. Every
accepted program ran clean under the sanitizer and the leak tracer;
the oracle agreed or abstained on each, but finding 4 and the parked
closure case.
