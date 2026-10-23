# APIs Stage 3, phase 6: adversarial review (2026-10-23)

A review of PR #607 ([phase6-notes.md](phase6-notes.md): implied
bounds, the rule that a `pub` generic states its bounds, and
`tools/state-bounds.py`). It hunted North Star 1: an implied bound
that lets a body do what an instance cannot, so a program is accepted
and then fails in Zig or misbehaves. About 85 probe programs, each run
with `rig check` and, when accepted, `RIG_SANITIZE=1 rig run`, several
compared with a build of `main` and with `rig emit`; the script run on
a tree of hard cases and on Trig. Each fix has its case in
`test/rig/types-apis.rig.test` or `test/cli/state_bounds.sh`.

## Findings, by severity

### Medium: the rule depended on the order of declarations

1. **A bound implied by a type declared later was not asked.** A bound
   check of an instance spelled inside a generic declaration
   (`Index[T]` in a method of `pub obj W[T]`) ran as the declaration
   was resolved, before the implied bounds of a type declared after it
   were known, and so asked nothing: `W` was accepted with `Index`
   below it and rejected with `Index` above it. Not unsound, since each
   instance is checked again with every bound known, but the rule's
   error, at the parameter, depended on the order, and so did the
   script's result. *Fixed:* every such check waits until declarations
   are resolved (`DeferredCheck.bounds`, which phase 6 used only for an
   argument made of other types), under the bounds a method adds to its
   type's parameters (`fun Wrap[T: Shape].boxed`), which the check
   records (`sema.snapshotWidened`, `sema.rewiden`). Case "apis pub
   states its bounds of a type declared later".

### Low: messages

2. **The fix named a bound the needed one implies.** For a parameter
   whose bound is implied (`K` of `Index[K]`, from its `Map[K, Int]`),
   the check asked the implications in enum order, so the error said
   ``needs `K: Eq`: write `[T: Eq]` ``; writing it, the next check asked
   `Hash`. *Fixed:* `sema.checkBounds` asks what a parameter's bounds
   name, written or implied, less what they imply (`sema.strongest`),
   before the rest: ``needs `K: Hash`: write `[T: Hash]` ``. The same
   case.
3. **A declaration over several lines.** The error named the
   declaration as written, newlines and comments included (`` `pub fun
   pick[\n  K,\n  T,  # ...\n]` ``), so it spanned lines and the script,
   which reads one line per error, stopped. *Fixed:* the declaration is
   named on one line, without comments (`` `pub fun pick[K, T]` ``).
   Case "apis pub states its bounds on lines of their own", and
   `test/cli/state_bounds.sh` writes into such brackets.

### Found, not phase 6's: recorded

4. **A call through a bound to an implementation's generic method
   checked at each instance.** `fun look[K](?@, k: ?K)` of a private
   `Sq: Keyed` hashes `k`; `probe[T: Keyed]` calls `t.look(?1.5)`: `rig`
   accepts it and Zig fails (`rig.hash: no .hash() of f64`). The same on
   `main`, from phases 2 and 3: the instance the witness call reaches
   is not checked. A `known: true` case, "apis a call through a bound
   checks the implementation's instance", for the session that owns
   calls through bounds.

## The builder's decisions, checked

- **Implied bounds are sound.** Every instance of a type or a function
  is checked against its implied bounds as against written ones
  (`typecheck`'s instance pass calls `sema.checkBounds`, which reads
  `Symbol.implied`), and an imported parameter carries them. No probe
  reached a body that uses an implied bound with an instance that lacks
  it: optionals of `Map` passed `none` at `K = Float`, empty
  `List[Set[K]]`, function types naming `Map`, explicit type arguments,
  a method's own parameter, an API method's own parameter, types
  implied through fields declared after their users, self- and mutually
  recursive types, a type with a value parameter, `*Frozen[Map[K,
  Int]]`, and implied `Copy`, `Ord`, and `Sends` from a program's own
  types, each in one module and across two and three.
- **Decision 3 (local tasks).** A task over an unbounded `T` in a `pub`
  generic is local (`rig check --tasks`), gives the right results, and
  is sanitizer clean under 20 seeds; with `[T: Sends]` it crosses. Trig
  has one task, in a function that is not generic
  (`declarations/checkerpool.rig`); std has none. No Trig or std task
  changed.
- **Decision 4 (`+x` asks `Copy`).** Right today: a private generic's
  `+a` at `T = String` is rejected per instance too, since no generic
  clone of an owning value is built.
- **Decision 5 (printing a view).** Rejects one sane program: a type
  with its own `Print` that ignores its `T` (`obj Box[T]: Print` whose
  `print` writes `"box"`) still asks `T: Print` of a `pub` generic that
  prints it, by value as well as by view; `main` accepted the view.
  Over-restrictive, as the rule for a value already was; a better rule
  stops at a type that prints itself. Not changed.
- **The script.** On a tree with multi-line brackets, a comment in them
  holding `,` and `[...]`, two parameters fixed on one line, a value
  parameter, a set parameter (left alone), generic methods public and
  private, an addition, a chain of three `pub` generics across modules,
  and a method call through an API: it converges, a second run writes
  nothing, and the result runs. It needed fix 3.
- **Trig's 13 element reads.** `rig.at(xs, i)` is `xs[index(i,
  xs.len)]`, and `rig.elemPtr(xs, i).*` loads the same element after the
  same test: the same copy of a `Copy` element, the form any `T: Copy`
  read takes. Both are one-line functions Zig inlines; no timing needed.
- **trig-migration.diff is unchanged.** With the fixes, the script over
  Trig's `main` (its trig program and one using every module) writes
  the same 51 type parameters of 49 declarations; the migrated tree
  checks clean, and so does `--tests` over every directory module.
