# Expert 1 (specification): "A failure moves its error"

Probes: `probes/e1/` (run with `~/Data/Code/worktrees/rig/frozen/bin/rig`;
`~/Data/Code/rig/bin/rig` is from Oct 21 and does not parse `T!E`).
Findings used below: a declared set without fields copies (`a = e; b = e`
after `catch |e|`); `catch |_|` is accepted; `+e` and `List[error]` work;
`>t catch |e|` works; an error set may not declare `drop` ("`drop` bodies
are only for non-generic objects, not error sets"); a member with fields
is rejected ("only enums declare payload variants"); a fallible call
with neither `!`, `catch`, nor `&` is rejected, so the three cases below
are exhaustive.

## 1. The paragraph

**A failure moves its error.** An error set's member may carry fields,
as an enum's variant does. Each field's type can hold no loan, holds no
handle (§1) anywhere inside it, and clones (sentence 2), so an error
never limits an owner, goes to any task, always clones, and drops
without running a `drop` body. *(planned)* An error set's kind follows
from its members' fields by the enum rule (§1), so it is plain or
owning, and `error`, which holds an error of any set, is owning.
*(built)* A failing `return` moves its error out of the function once
the error is made and before the scopes the `return` leaves end; `e!`
passes the same error on to its caller; and `catch |err|` moves it into
a local `err` of the handler, which follows sentences 1 to 3 as any
local of its type: an owning one drops where the handler ends unless
the handler moves it on (`return err`, `<err`). *(built)* This is a
desugaring. Each fallible call is lent a hidden write view of a slot
that holds at most one error: under `catch`, a slot the caller owns for
that call alone; under `e!`, the view the caller was itself lent, lent
on (§4); under `&`, a slot the call's `Task` owns. The failing `return`
moves its error into the slot, `catch |err|` takes it out as `<` takes
from an optional place (§5), and since an error holds no loan, what a
call stores in its slot carries none (sentence 7). *(planned)* A
`catch` that binds no name, or binds `_`, drops the error before its
handler runs, so a handler that jumps (`catch continue`) leaves nothing
behind. *(planned)* `>t!` moves a task's error from its slot into the
slot its waiter was lent, `>t catch` takes it as `catch` does, and
dropping a `Task` drops what its slot holds. *(built* for `>t!` and
`>t catch`; the task's slot is *planned)* Reading, matching, printing,
storing, and cloning an error follow its type, as for any value.
*(built)*

## 2. Examples

Keep both current blocks: the `rig reject` ("use of `err` after move")
is built and still right; the `rig pending` `ParseError` program shows
fields, `e!`, `catch |err|`, `match`, and printing, and fails today.

Add three `rig pending` blocks (each fails today on "only enums declare
payload variants"; the field-less forms of the first two run today,
probed as `p1.rig` and `p2.rig`):

The field rule:

```rig pending
error E
  bad(name: ?String)

sub main()
  print(1)
```

```error
an error's field never holds a loan: hold a `String` or a `Static`
```

A nameless `catch` that jumps leaves nothing behind (the leak check is
the test):

```rig pending
error E
  odd(msg: String)

fun even(n: Int) -> Int!E
  return E.odd(msg: String("odd ", n)) if n % 2 == 1
  n

sub main()
  total = 0
  for n in [1, 2, 3, 4]
    total += even(n) catch continue
  print(total)
```

```output
6
```

A task owns its error; the task dropped on the error path drops its own:

```rig pending
error E
  bad(msg: String)

fun f(n: Int) -> Int!
  return E.bad(msg: String("no ", n)) if n < 0
  n

fun both(a: Int, b: Int) -> Int!
  t = f(a)&
  u = f(b)&
  x = >t!
  x + >u!

sub main()
  print(both(1, 2) catch -1)
  n = both(-1, -2) catch |e|
    print(e)
    0
  print(n)
```

```output
3
E.bad(msg: "no -1")
0
```

## 3. Decisions for the owner

1. **Derive "no loan in the slot" from the type, not from "keeps
   nothing".** [yes] The draft's "which keeps nothing (sentence 7)" is
   not derivable: sentence 7 lets a function declaring `keeps s` store
   `s` in any write view it is lent, and says a function value's stores
   are never narrowed. "An error holds no loan, so what a call stores in
   its slot carries none" follows from sentence 7 as written, for named
   functions and function values alike, and follows the value's type
   (§10).
2. **Behavior and desugaring in separate sentences**, so each gets one
   honest mark: what programs see is built; the slot is planned. [yes]
3. **Say where `&` and `>t` come from.** CORE never introduces tasks; the
   paragraph names them by their forms only and leaves the rest to SPEC.
   [yes, as written] Alternative: a one-line gloss, `t = f()&`.
4. **Signal.** "Goes to any task" holds because a `Signal` has no `+`
   (SPEC §clone). Sentence 2 marks "a deep copy of a type holding a
   `Signal`" *planned*; if that is built, a Signal field passes the
   field rule and an error no longer goes to any task. [the change that
   builds it keeps errors from holding one, with a test] Alternative:
   drop that planned clause from sentence 2 now.
5. **Add the three pending examples above.** [yes]

## 4. Reasoning (≤300 words)

Changes from the §9 draft, each for precision:

- **"a slot of its caller's"** is false under `e!`: the call is lent the
  view the caller was itself lent, which belongs to some frame above.
  The rewrite names the three cases (`catch`, `e!`, `&`), which are
  exhaustive: a fallible call with none is rejected (probe).
- **"which keeps nothing"**: decision 1.
- **"`return E.name(...)`"** covered only a made error; `catch |e|
  return e` and `return v if c else E.x(...)` fail too. "A failing
  `return`" covers every operand sentence 10 allows.
- **"before the scope's exits run"**: CORE never defines "exits". "Before
  the scopes the `return` leaves end" uses sentence 3's and §7's own
  phrase, so it orders the move before every `defer`, `errdefer`, and
  drop, and after the error is made (`return E.x(msg: g()!)` runs `g`
  first).
- **"moves to any task"**: CORE's word is "goes to any task" (§7, §9).
  One word per idea.
- **`catch |err|`'s binding** is an ordinary local, so its drop and moves
  come from sentences 1 to 3, not a rule of its own; the draft restated
  them.
- **"`>t!` ... take the error from the task"**: `>t!` does not pass a
  slot on as `e!` does; it moves the error from the task's slot into
  the waiter's. Said so.
- **"dropping one runs no `drop` body"** holds also because a set cannot
  declare `drop` (built rejection); no text needed.

Nothing in the draft contradicts another CORE sentence except "keeps
nothing" against sentence 7, and the Signal note against sentence 2.
