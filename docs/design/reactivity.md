# Reactivity

*(planned, after 1.0; not started)*

Reactivity is values that keep themselves up to date: state that is set,
values computed from it, and effects that run again when what they read
changes. Rig gives it as a library, `std.signal`, never as syntax. This
page records why, what the library looks like, and what must be true
before any of it is built.

## The shape

Three types, each made by a constructor:

| Type | What it is |
|---|---|
| `Signal(v)` | state: a value that is read and set |
| `Computed(f)` | a value computed from signals, kept up to date |
| `Effect(f)` | an action that runs once, then again whenever what it reads changes |

```rig pending
use std.signal

sub main()
  x = Signal(5)
  y = Computed(|?x| x.get() * 3 + 2)
  z = Effect(|?x, ?y| print(x.get() * y.get()))

  !x.set(6)
  !x.set(6)
  print(y.get())
```

```output
85
120
20
```

- `x = Signal(5)` allocates one cell, visibly, at its constructor.
- `Computed` and `Effect` name what they read in their captures, so the
  compiler knows each one's dependencies before the program runs.
- `!x.set(6)` is the only thing that makes code run again: `y` is
  recomputed and `z` prints `120`. Setting the value a signal already
  holds runs nothing.
- A computed value is updated when a signal it reads is set, never when
  it is read, so `y.get()` is a load and runs no code.
- `z` is an ordinary value. Dropping it ends the effect. At the end of
  the scope `z` drops first and stops listening, then `y`, then `x`.

## Why words, not sigils

A sigil in Rig marks an ownership mechanic: a move, a view, a write, a
clone. Reactivity is not one; it is a library, and a library gets words.
The sigils still appear where they already mean something: `?x` in a
capture is a read view of the signal, and `!x.set(6)` is a write.

## Why not syntax

Reactive languages and UI frameworks write it more briefly. Rip has:

```text
x := 5               # state
y ~= x * 3 + 2       # computed
z ~> print(x * y)    # effect
x = 6                # reruns y and z
```

As syntax this breaks Rig's rules:

1. **Hidden control flow.** A plain `x = 6` would run other code, which
   breaks North Star 3: every effect stays visible where it happens.
2. **Hidden allocation.** The dependency graph would be allocated with
   nothing in the source showing it.
3. **Ownership.** An effect views what it reads for as long as it lives.
   With a value and its drop, the checker proves those places outlive
   it, and no hidden reference counting is needed.
4. **Punctuation doing a library's job.** Three operators for one
   mechanism, where Rig's rule is a mark for a mechanic and a word for
   a library.

Shorter forms were weighed and set aside: `!x = 6` calling `set`, and a
`Computed` standing for its value (`print(y)`). Each needs a hook in the
language (an assignment hook and a read hook, as Rust's `Deref` is), and
`x = 6` beside `!x = 6` would differ by one character while one replaces
the signal and the other updates it. `.get()` and `.set()` match `Cell`,
which already reads and writes that way, so a signal is a cell that tells
others when it changes: one mechanism, not two. Zig refuses operator
overloading for the same reason: what a line costs is read from the line.

## Names

`Signal`, `Computed` and `Effect` are the words Solid, Vue and Angular
already use for these. Names are the owner's call; these are the
candidates. Six-letter alternatives to `Computed` (`Derive`, `Mirror`,
`Answer`) were weighed and set aside: none says "a value computed from
others" as plainly.

## How it can be fast

Captures are explicit, so the dependency graph is known at compile time.
`set` can then be emitted as straight-line updates in dependency order,
as Svelte's compiler does, with no tracking on each read and no runtime
list of subscribers to search. A graph that changes at run time (an
effect made in a loop) falls back to a list the effect owns.

## Before it is built

1. **A program that needs it.** Candidates: Trig's language server
   (recomputing only what an edit changes, as Salsa does for
   rust-analyzer) or a `std.terminal` UI.
2. **The owner approves** the design and its names.
3. **The ownership rule.** An effect holding read views of signals for
   its whole life must fit CORE in a paragraph (CORE §10), with
   reference-checker and Lean cases both ways.
4. **Concurrency.** Whether a signal may be set from another task, and
   how, is decided before the first release of the library; the first
   form is one task only.

Syntax is considered only after the library has proved itself in such a
program, and even then a write that makes code run again stays marked at
the call.
