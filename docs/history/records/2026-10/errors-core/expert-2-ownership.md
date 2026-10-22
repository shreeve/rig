# Expert 2 (ownership, soundness): "A failure moves its error"

Probes: `core-panel/probes2/e2_*.rig`, run with a `bin/rig` built from
main 6b2215ac4 in `core-panel/e2build/` (the main checkout's `bin/rig`
is from Oct 21 and predates declared sets).

## 1. The paragraph

**A failure moves its error.** An error set's member may carry fields,
as an enum's variant does; each field's type holds no loan, holds no
`*` or `~` handle anywhere inside it, and clones (sentence 2), so an
error never limits an owner, moves to any task, `+e` always works, and
dropping one runs no `drop` body. *(planned)* An error is plain or
owning by the enum rule (§1), and `error`, which holds an error of any
set, is owning. *(built)* A fallible call is lent, hidden, a write view
of a *slot*, an optional that holds its error, which the call only
writes, once, as it fails: the slot's type holds no loan, so the call
keeps nothing there, and its result views nothing of it (sentence 7).
A failing `return` moves its error, once made, into the function's own
slot, and then the scope's exits run, which cannot fail (§7). `e!`
lends the call the function's own slot and, when it fails, leaves as a
failing `return` does. `catch` lends the call a new, empty slot of its
statement: `catch |err|` takes the error out of it into the handler's
own binding, which drops where the handler ends, however it ends,
unless the handler moves it on (`return err`, `<err`); a `catch` that
binds no name, or `_`, drops it before its handler runs. A task holds
its call's error as it holds its result: `>t!` and `>t catch` take it,
as `>t` takes the result, and dropping the task drops it. *(built:*
`return`, `e!`, `catch |err|`, and `>t!` for every error; *planned:*
the slot of an error with fields, and a nameless `catch` dropping
before its handler.*)* Reading, matching (an error of a union, or
`error`, matches as an enum of its sets), printing, storing, and
cloning an error follow its type, as for any value. *(built)*

And in §7, **Defer**, one sentence (built; SPEC §defer already says it):

> They cannot fail out: a failure inside one is caught there, in a
> slot of its own.

## 2. Examples

Keep both current blocks (the `rig reject` use after move, and the
`rig pending` ParseError program). Add three `rig pending` blocks, each
probed today to fail for want of the rule ("only enums declare payload
variants"):

The field rule is a type fact, so a view nested in a list is caught:

```rig pending
error Load
  bad(names: List[?String])

sub main()
  print(1)
```

```error
an error's field never holds a loan
```

The error is made and moved before the exits run (the same program
with `!keep.push(<s)` is rejected so today):

```rig pending
error Load
  bad(msg: String)

fun load(s: String) -> Int!Load
  errdefer print(s)
  return Load.bad(msg: <s)

sub main()
  print(load(String("x")) catch -1)
```

```error
use of `s` after move
```

A task holds its error; `b`, left without a wait as `>a!` fails, is
dropped with it, leak-clean:

```rig pending
error Job
  bad(msg: String)

fun work(n: Int) -> Int!
  return Job.bad(msg: String("too big")) if n > 1
  n

fun both() -> Int!
  a = work(2)&
  b = work(3)&
  x = >a!
  y = >b!
  x + y

sub main()
  n = both() catch |err|
    print(err)
    0
  print(n)
```

```output
Job.bad(msg: "too big")
0
```

## 3. Decisions for the owner

1. **A task holds its error as it holds its result,** not "a task's
   call is lent a slot its `Task` owns". Read through sentences 4 and 5,
   a lend puts a write loan on the `Task` for the task's life, so it
   could not be moved into `Tasks`, returned, or consumed by `>t`. [yes]
2. **The slot is only written, once, and its result views nothing of
   it.** Without this, sentence 7 lets a `-> ?String` result carry a
   loan on the slot (its type could hold a `String` field), and the
   oracle would reject every bound view from a fallible call. [yes]
3. **§7 Defer says a defer cannot fail out** (built). It is what keeps
   a nested failure from writing the slot a leaving error holds. [yes]
4. **One slot per catching call** ("a new, empty slot of its
   statement"), not "a slot of its caller's", which reads as one per
   frame and lets a nested `catch` in a handler meet a full slot. [yes]
5. **Any failing `return`,** not only `return E.name(...)`: a caught
   binding, `+e`, an element, or a branch moves into the slot the same
   way. [yes]

## 4. Reasoning (from the §9 draft)

I walked every path: made (`return`, with a failing field and from a
branch), propagated (`e!`), caught (named, `_`, none, jumping, failing
handler), stored, cloned, narrowed, crossing a task (`>t!`, a dropped
task, an actor call, which waits and so lends the caller's slot), left
unread, and a nested failure in a defer. The draft covers each in
intent, but read literally it leaves five holes, which are the
decisions above.

Two more fixes. "Holds no handle" is now "no `*` or `~` handle":
§1 says `^T` "is held like a handle", and the spec admits `^T` and
`^error`. And the draft's "which keeps nothing" cannot be derived from a
signature: sentence 7's `keeps s` is not per destination, so a function
that keeps `s` in `@` may also, by sentence 7, store a view of `s` in
the slot. What closes it is the type fact (the error's type holds no
loan), so the paragraph says that. Spec §10.1's claim of an
independent oracle check for named functions holds only for functions
with no `keeps`.

The `catch` wording says "takes the error out", which is `<` (§5), and
the binding's drop follows from sentence 3. "Matching as an enum of its
sets" lets the oracle derive that `g: E =>` under `match e` binds a
view, as a payload enum's arm does; narrowing, with `<err` after the
`match`, runs today for sets without fields (probe `e2_narrow.rig`).
