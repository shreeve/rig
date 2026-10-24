# Shared and crossing API objects: the draft CORE text (2026-10-23)

A draft for the Core panel (a Core purist, a compiler implementer, an
adversary, and a reviewer), then the owner. Nothing here is approved,
and no code waits on less. It extends Stage 4's approved text (CORE §4,
"An API object hides its value's type, never its loans"; [Stage 4's
core panel](../apis-stage4/core-panel/6-final.md)) and sentences 8 and 9,
in CORE's words: an *API object*; *lend*, *view*, *loan*; `@` is self.
The design behind it is [docs/design/apis.md](../../../../design/apis.md),
Stage 5, and its defaults are [open-questions.md](open-questions.md);
13 and 14 are the owner's to decide with this text.

## §1: one row widened

| Kind | Examples | A plain use | Status |
|---|---|---|---|
| **handle** | `*T` (counted; `*{A}` too), `~T` (weak; `~{A}` too), owned closures (`*fun`) | moves; `+h` adds a count | built; `*{A}`, `~{A}` planned |

## §4: one row widened

| Owner `x` | `?x` lends | `!x` lends | Status |
|---|---|---|---|
| `*T`, `*{A}` | the read views of `T`; of a `*{A}`, the `?{A}` it holds | nothing of the value (`!h` lends the handle itself) | built; `*{A}` planned |

## Sentences 8 and 9: a clause each

Sentence 8, after "so a holding sigil over a held value (`^*T`, `**T`,
`*~T`) is rejected":

> ; an API object is held the same three ways, `^{A}`, `*{A}`, and
> `~{A}` (§4).

Sentence 9, after "its handles are counted atomically and go to any
task":

> , and erased they are a `*{A + Syncs}` (§4)

## Stage 4's list: its last line

"`*{A}` and `~{A}` are Stage 5's. *(planned)*" becomes "`*{A}` and
`~{A}` count, and an object crosses, as below."

## The paragraph, after Stage 4's

> **A shared API object counts a value of hidden type, and an object
> crosses tasks only by a bound in its braces.** `*{A}` is a counted
> handle to a value of some type that provides `A`, and `~{A}` is its
> weak handle. A `*T` moves into a `*{A}` and keeps its allocation;
> `*S(...)` and `*<x` make one where a `*{A}` is expected, and nothing
> else becomes one. Like every handle it only reads: a call through it
> reaches `?@` methods, `?s` lends the `?{A}` it holds, and `+s` adds a
> count, atomic as the hidden allocation's is, fixed where the type is
> erased. It carries the loans of what it holds until its last count is
> dropped. `Sends` and `Syncs` in the braces, or in the API they name,
> are facts of the hidden value, checked where its type is erased, as
> `Owned` is. Each form then crosses as its kind does: a box or a write
> view goes to another task when its value sends, a box or a read view
> is read by several tasks when its value syncs, and a `*{A + Syncs}`
> holds only a handle counted atomically, a frozen value's. An object
> whose braces and API name no such bound goes to no other task, a
> local one included, and no object hides a task. *(planned)*

### What each sentence derives from

| Sentence | Derives from |
|---|---|
| `*{A}` is a counted handle ..., `~{A}` its weak handle. | Sentence 8 (`*T`, `~T`, `*w`); Stage 4's paragraph (`?{A}`, `!{A}`, `^{A}` hold a value of some type that provides `A`) |
| A `*T` moves into a `*{A}` and keeps its allocation; `*S(...)` and `*<x` make one ...; nothing else becomes one. | Stage 4's "A `^T` moves into a `^{A}` and keeps its box"; sentence 8 (`*<x`, `*S(...)`; one way on the heap); "Only the value reached is erased" |
| Like every handle it only reads: `?@` methods, `?s` lends the `?{A}`, `+s` adds a count ... fixed where the type is erased. | Sentence 8 ("Handles only read"); §4's `*T` row; §1 (`+h` adds a count); Stage 4's "checked on the value's type where it is erased" |
| It carries the loans of what it holds until its last count is dropped. | Sentence 9 ("a `*T` carries the loans of what it holds"); sentence 6; Stage 4's "it may hold anything" |
| `Sends` and `Syncs` ... are facts of the hidden value, checked where its type is erased, as `Owned` is. | Stage 4's list ("each checked on the value's type where it is erased"); Stage 3 (an API's bounds hold of every type that provides it) |
| Each form then crosses as its kind does ... a `*{A + Syncs}` holds only a handle counted atomically, a frozen value's. | §1 (each form keeps its kind); SPEC §18's table; sentence 9 (a frozen value's handles are counted atomically and go to any task) |
| An object ... with no such bound goes to no other task, a local one included, and no object hides a task. | Stage 4's "it may hold anything", so "the crossing rules reject it where a handle may not go"; SPEC §18 (a local task takes no owned closure, "whose captures its type does not show"); docs/design/concurrency.md rule 1 (a task's drop uses its loans and waits) |

## Examples

A shared object, its weak handle, and the last count's drop:

```rig pending
api Shape
  fun area(?@) -> Float

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

sub main()
  s: *{Shape} = *Square(side: 2.0)
  w = ~s
  if *w as h
    print(h.area())
  <s
  if *w as h
    print("still here")
  else
    print("gone")
```

```output
4.0
gone
```

A frozen value erased, read by two tasks:

```rig pending
api Shape
  fun area(?@) -> Float

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

fun area_of(s: *{Shape + Syncs}) -> Float
  s.area()

sub main()
  s: *{Shape + Syncs} = *Frozen(Square(side: 2.0))
  a = area_of(+s)&
  b = area_of(+s)&
  print(>a + >b)
```

```output
8.0
```

A box whose value sends, given to a task:

```rig pending
api Job
  fun run(?@) -> Int

obj Sum: Job
  xs: List[Int]

  fun run(?@) -> Int
    n = 0
    for x in @xs
      n += x
    n

fun work(j: ^{Job + Sends}) -> Int
  j.run()

sub main()
  j: ^{Job + Sends} = ^Sum(xs: List([1, 2, 3]))
  t = work(<j)&
  print(>t)
```

```output
6
```

A `*T` whose count is not atomic is no `*{A + Syncs}`:

```rig pending
api Shape
  fun area(?@) -> Float

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

sub main()
  s: *{Shape + Syncs} = *Square(side: 2.0)
  print(s.area())
```

```error
`*Square` is erased to `*{Shape + Syncs}`, which several tasks read, but its count is not atomic: freeze the value, `*Frozen(...)`
```

An object whose braces name no `Sends` goes to no task:

```rig pending
api Job
  fun run(?@) -> Int

obj Sum: Job
  xs: List[Int]

  fun run(?@) -> Int
    @xs.len

fun work(j: ^{Job}) -> Int
  j.run()

sub main()
  j: ^{Job} = ^Sum(xs: List([1, 2, 3]))
  t = work(<j)&
  print(>t)
```

```error
`<j` is given to a task, and `^{Job}` hides its value's type without naming `Sends`: write `^{Job + Sends}`
```

## For SPEC §18 (not CORE): the crossing table's rows

| Type | sends | syncs |
|---|---|---|
| `?{A}` | when its braces or API name `Syncs` | the same |
| `!{A}` | when they name `Sends` | never |
| `^{A}` | when they name `Sends` | when they name `Syncs` |
| `*{A}` | when they name `Syncs` (its count is then atomic) | the same |
| `~{A}` | never | never |

## For the panel to probe

The adversary's starting list; each needs a rule above or a case.

1. **Loans to the last count.** A `*{Shape}` of a value holding `?t`
   with a `drop` body, `+s` stored in a `List` that outlives the line
   where `t` changes: the loan lasts to the drop of every count.
2. **A weak handle of a frozen value.** `~` of a `*{A}` that hides a
   frozen allocation is allowed (atomic weak count), `~` of a
   `*{A + Syncs}` is not: does any path upgrade on another core?
3. **Counts in a drop.** `+s` or `*w` from inside the hidden value's
   `drop` body, while the last count is being dropped (`strong == 0`).
4. **Generic erasure.** `[T: Shape]` erasing to `*{Shape + Syncs}` from
   a `*Frozen[T]`, and to `^{Shape + Sends}` from a `^T`: by the bound,
   or per instance?
5. **The hidden Cell.** A `*{Tick}` of a type holding a `Cell[Int]`,
   its `?@` method changing it while a `?{Tick}` lent from it is in use.
6. **Through a field.** A `List[^{Job + Sends}]`, a `^{Job + Sends}?`, and
   an object holding one, given to a task; an actor's state holding a
   `*{A}` (never crosses: a handle).
7. **Write views.** `!{A + Sends}` lent to a task while the owner is
   lent elsewhere; it is never read by two tasks.
8. **Owned closures as objects** (phase 4): `+f`, `~f`, and `*w` of a
   `*fun` lowered with a table, and a closure's drop reaching its own
   handle.
9. **Holes 13 and 14** of [open-questions.md](open-questions.md): an
   owned closure hidden from a local task, a task hidden from
   `task.isolate`; whether the rules above close every path (a field, an
   optional, a `List`, a generic argument).

## Accepted limits

No conversion between forms (`^{A}` to `*{A}`, or back), no upcast or
downcast, no Cell of an object, no frozen value holding an object, and
no task over an object whose braces and API name no crossing bound.
