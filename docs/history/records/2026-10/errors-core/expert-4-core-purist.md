# Expert 4 (Core purist): "A failure moves its error"

## 1. The paragraph, ready to paste

**A failure moves its error.** An error set is an enum (§1), whose
members may carry fields as variants do. *(planned)* An error is plain
or owning by the enum rule, and `error`, which holds an error of any
set, is owning. *(built)* Each field's type is a no-loan home (sentence
9), holds no handle, and clones (sentence 2), so an error never limits
an owner, goes to any task, always has a `+`, and drops without running
a `drop` body. *(planned)* A fallible call is lent, to write, a hidden
`E?` of its statement (§3), `E` its set, empty until the call fails; the
`!` or `catch` every fallible call carries (sentence 10) is that lend's
mark, and as an error holds no view, the call keeps nothing (sentence
7). *(planned)* `return E.name(...)` stores the made error through that
view and leaves, the error in place before the scope's exits run, as
any returned value is. On a failure the caller takes the error out with
`<` (§5): `e!` returns the same error to its own caller, and `catch
|err|` makes it the handler's own binding, which drops when the handler
ends unless the handler moves it on (`return err`, `<err`). *(built)* A
`catch` that binds no name, or `_`, takes it nowhere, a statement `<`,
so it drops before its handler runs (sentence 2). *(planned)* A `Task`
holds its call's hidden `E?` as it holds its result, so `>t!` and `>t
catch` take the error as from any call, and dropping the task drops it.
*(planned)* Reading, matching, printing, storing, and cloning an error
follow its type, as for any value. *(built)*

## 2. Examples

- Keep the `rig reject` (`use of `err` after move`): it tests the built
  owned binding.
- Keep the `rig pending` ParseError example: fields, `e!`, match, print.
- Add a pending rejection for the field rule, so the no-loan clause is a
  test (it passes as pending today, rejected with another message):

```rig pending
error Bad
  at(src: ?String)

sub main()
  pass
```

```error
an error's field never holds a loan
```

- Add a pending task example for the `Task` sentence (the builder
  confirms the `&` and `>t catch` spelling against SPEC §18):

```rig pending
error E
  bad(msg: String)

fun work() -> Int!E
  return E.bad(msg: String("no"))

sub main()
  t = work()&
  n = >t catch |err|
    print(err)
    0
  print(n)
```

```output
E.bad(msg: "no")
0
```

## 3. Decisions for the owner (default first)

1. **No new word "slot" in CORE.** "Slot" already means a Table's place
   and `Slot[n]` (§5), and names an example `obj Slot`. CORE says "a
   hidden `E?` of its statement"; INTERNALS keeps `__out` and "slot".
   Default: yes.
2. **`e!` is take-and-return** (`<` the hidden `E?`, then `return`), not
   "passes the slot on". Same error, same moves; passing `__out` on is
   the lowering, equal by I1. It needs no write-view widening from
   `!(E?)` to `!(error?)`, which the page does not cover. Default: yes.
3. **`_` drops at two times.** In a destructure `_` drops at the
   statement's end; in `catch |_|` before the handler. No program can
   tell (an error has no `drop` body and no loan), so this is memory,
   not meaning. Default: keep the approved rule, stated as a statement
   `<`; alternative: drop at the statement's end like every `_`.
4. **CORE has no Task rule anywhere.** Default: keep one consequence
   sentence (a Task holds the error as it holds its result); task
   ownership itself stays in SPEC §18. Alternative: leave tasks to SPEC.
5. **The field rule reuses "no-loan home"** (sentence 9), so the oracle
   extends its existing C8 check rather than learning a new one. Default:
   yes.

## 4. Reasoning (300 words)

The §9 draft is sound in substance but adds three things the Core does
not already have. (a) **"Slot"** is a second meaning of a word §5 owns.
(b) **"A write view of a slot of its caller's"** does not say the
place's type, its empty state, its scope, or how the error leaves it,
so the oracle's author would guess; and under `e!` the slot is not the
caller's at all. Spelling it as a hidden `E?` statement temporary, lent
to write and emptied with `<`, makes every step a form on the page: a
write lend of an optional (§4 row `X?`), assignment through a view
(§6), `<` of an optional place (§5), a statement `<` dropping now
(sentence 2), and `return`. The oracle then models it with ops it has:
a hidden var, a write loan for the call, and on the failure edge a move
into the binding, the return, or a drop. Today's `fallback` models
`err` as a fresh `make`, which would hide a double take. (c) **The
hidden write lend breaks sentence 4** ("so is every write lend
[written]") unless something on the page marks it; sentence 10 already
requires `!` or `catch` on every fallible call, so naming that as the
lend's mark makes it a consequence, not an exception.

The field rule's "holds no loan" is sentence 9's no-loan home; one word
per idea. "Keeps nothing" is derived from the type, not stipulated.
"Before the scope's exits run" is how every `return` orders its value,
so it is a consequence.

Two things remain imperfect: the nameless-catch timing differs from
destructure `_` (decision 3, unobservable), and the `Task` sentence
leans on a type CORE never introduces (decision 4). Marks follow the
brief: the moves are built, since the hidden `E?` carries the same
moves the checker enforces today; the place, the field rule, the
nameless drop, and the task form are planned.
