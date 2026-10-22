# `*Frozen[T]`: a value many tasks read

2026-10-22. A proposal, Rig's review of it, and the decisions it was
built from.

## The gap

Three handles are counted atomically and so cross cores: `*Actor[T]`,
`*Chan[T]`, and the one-word `*Cell[T]`. Every other `*T` is confined to
one task, since its count is not atomic. So a finished value that many
tasks read, and that outlives any one waiting scope, is copied for each
reader: a cache's page an actor hands out, a configuration swapped
while the program runs, a result many callers share. Porting the LWN
article's `render_page` example showed it: an actor that returns a
`*String` is rejected ("`*String` is a `*` handle whose count is not
atomic, so two cores could change it at once"), so it returns a copy of
the page on every call. Rust spells the missing handle `Arc<T>`.

Lending `?x` to tasks a scope waits for already shares a value for free,
and an actor holds what changes; neither covers a value no scope owns.

## The proposal

The pattern of `*Actor`, `*Chan`, and `*Cell`: the mark is the mechanic,
a counted handle, and the word after it is the kind. A frozen value is
one nobody can change again, so any core may read it, and its count is
atomic.

```rig fragment
obj RenderState
  cache: Map[String, *Frozen[String]]
  template: String

  fun render(!@, name: ?String) -> *Frozen[String]
    +(!@cache).ensure_with(String(name), |?@template, k| *Frozen(fill(@template, k)))
```

1. **Making one:** `*Frozen(v)` moves a value in, as `*Actor(v)` does.
2. **What goes in:** a value nothing can change through: plain data,
   owners, `String`s, `List`s, objects and enums of such, and other
   `*Frozen` values. No `*T`, `~T`, `Cell`, `Signal`, `*Actor`,
   `*Chan`, closure, or loan anywhere inside (Rig's review, point 1).
3. **Reading:** as through a `*T`: fields and read methods, and `?f`
   lends a `?T` that keeps the handle lent. Nothing writes through it.
4. **The count:** `+f` adds one atomically, and a drop takes one away;
   the last drop drops the value, on whichever core gets there last.
5. **Crossing:** it moves and shares: an actor's result, a channel's
   element, a capture `|+f|` in `par`, a field of anything that
   crosses. It never makes a task local.
6. **Cost:** reads cost nothing; only `+f` and a drop are atomic, and
   only where a program chose `Frozen`. A plain `*T` stays non-atomic.
7. **Changing it:** impossible; build a new value and freeze that.

Alternatives weighed: every `*T` counted atomically once a program makes
tasks, as a one-word `*Cell` is (no new word, but every handle in a
concurrent program, Trig's included, pays atomics, and `~T` needs an
atomic upgrade; only if Trig measured under 2% slower); or nothing.

## Rig's review (2026-10-22)

(a) Worth building as approach A: it fills a real gap and costs nothing
where unused. Trig does not need it now (its checkers share the
`Program` by loans, `?program`), so it is built on its own track, gated
by Trig's light gate and a check that Trig's output is unchanged.

(b) Holes and shapes:

1. **Deep-frozen.** "T moves and shares" still admits a one-word
   `*Cell[Int]`, an `*Actor`, and a `*Chan`, which change through their
   handles; exclude them, so the word is true.
2. **One classifier.** Fold the `.shared` case of `blockerIn`
   (`isWordCell or actorValue or chanValue`) into one predicate,
   `sema.atomicHandle`, used by `blockerIn`, `blockerReason`, and
   anything else that asks whether a count is atomic; two classifiers
   that disagreed were a hole (#549, `crossingTypeOf`).
3. **The count's order:** an increment with `.monotonic`, a decrement
   with `.release`, an `.acquire` fence before the last drop (as Arc
   does); share `*Actor`'s helper if it has that shape. A value freed
   on another core goes through the allocator's remote free list
   (measured fine, G9); a sanitizer case frees on another worker.
4. **Generics:** `*Frozen(x)` in a generic body needs a bound, or a
   check per instance (`boundBlocker`); a `fail` case for a `T` that
   holds a `*U`.
5. **Local tasks:** a `*Frozen` never pins a task; `rig check --tasks`
   prints nothing for an actor that returns `*Frozen[String]`.
6. **Views:** `?f` lends a `?T` tied to the handle's binding, as for
   `*T`; a test that a view lent to a task keeps the handle until the
   wait.
7. **`*Frozen` of a `*Frozen`:** nest or reject, consistently with `*`
   of a `*T` ("would nest handles").

(c) Name: `Frozen` (Ruby's `freeze`, JavaScript's `Object.freeze`).
`Fixed` is Rig's word for `=!` bindings; `Const` carries C's and Zig's
compile-time meaning.

(d) Rebase onto #549 (typecheck's crossing code) once it lands;
coordinate the full suite with Rig.

## The decisions

The owner asked for the proposal to go past Rig, and to be recorded and
built once both agreed: "Can you run it past Rig to get his approval
and then, if you both decide this is a valuable feature, save the
documented plan and proposal in a suitable location ... and then
implement this feature."

1. Approach A, `*Frozen[T]`, deep-frozen as review point 1 says.
2. The name `Frozen`.
3. No weak `~Frozen[T]` for now.
4. Equality, hashing, and printing forward to the value, so a
   `*Frozen[String]` is a Map key and prints as its text.
5. CORE's paragraph through the small review: one reviewer, then the
   owner's pass.
6. Built with `seeds: 20` and sanitizer cases, through Trig's light gate.
