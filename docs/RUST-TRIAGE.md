# Rust triage: what Rig should take, and what it should leave

Rig and Rust share their central idea: ownership checked when the
program compiles, with no garbage collector. They differ in many places.
This page sorts every difference found in a side-by-side review
(2026-10-14) by what Rig should do about it. Some differences are gaps
to close. Some are advantages in disguise. Others can be closed in a
simpler way that keeps most of the benefit, and a few are better left
out.

This page is a plan, not a description of the compiler. What is built is
in [CORE](CORE.md) and [SPEC](../SPEC.md); what Rig changes for a Rust
programmer is in [BEYOND-RUST](BEYOND-RUST.md). Figures quoted here come
from Trig's ownership evidence pack (trig `docs/ownership/EVIDENCE.md`).

## Really need to add ASAP

- **Disjoint field loans (round A).** Lend one field while writing
  another. It is Trig's biggest sore spot, worth up to 14% of parse time.
  Approved by the owner; its brief is ready.
- **The `replace` fix (round C).** Taking a value out of a struct and
  putting it back leaves no false loan behind. Small; being built.
- **Map and Set, with `x.hash()`.** Insertion-ordered `hash.Map` and
  `hash.Set` in std. Trig's binder port cannot start without them.
- **`keeps s` (round B).** A function says which lent arguments it
  stores, and every other loan ends with the call. In tsc's checker, 63%
  of such parameters are never stored. Needed before Trig ports the
  checker. Approved.
- **Path tokens (round E2).** A method's result says which field it
  views (`-> ?String from self.text`), so it does not lend all of
  `self`. It removes 24 copies in Trig, all of the lexer's among them,
  and reuses the existing `from` clause.

## Should add soon

- **Concurrency, built on what Rig already has.** Scoped threads that
  always join before their scope ends; a thread-safe counted handle; and
  a rule for what may cross threads, derived from a type's parts as its
  kind is, so no `Send` or `Sync` traits are needed. Rig's existing rules
  make this simpler than in Rust: write views never sit in data, and a
  `Cell` holds no views.
- **Yielding projections** (`yields !T`). A function hands out a write
  view for one loop iteration, then resumes. That gives user-written
  mutable iterators and traversals without storing write views, as
  Hylo's subscripts and Swift's `_modify` accessors do.
- **Iterators as values.** Iterators that can be passed around and
  combined. Trig needs them for Go's `iter.Seq`.
- **Static traits (round R2).** Bounds such as `[T: Hash]`, and user
  traits for visitors. A generic's needs appear in its signature, and
  errors point at the user's type.
- **Partial moves.** Move a field out of a struct, not only an optional
  one, as Rust allows. Trig carries 12 `replace` workarounds for it.
- **`noalias` for write views.** Tell Zig what the ownership checker
  already proved, so values stay in registers. Its first target is
  RIG-NOTES 8, a List's length reloaded on every push. It lands only if
  it passes the speed rule.
- **Errors that carry data.** Round 1, `error` as an owning type, is
  landing; round 2 adds declared fields, after field loans.
- **Kind-grid tests and named requirements for std generics.** Test
  each generic at every kind of type, and turn every need from `T` into
  a named requirement, so library internals never appear in a user's
  error.
- **Two write slices of separate halves at once** (`split_at_mut` as
  locals). The same reasoning as field loans, over index ranges.

## Might want, but not necessary

- **Trait values (round R3).** `?Shape` and `^Shape` as values, for host
  interfaces. Wait until Trig reaches its native and editor layers.
- **A store whose additions never move what it holds.** It would
  dissolve most of the checker's 350 arena conflicts. Trig ports with
  index loops first, and measures the need.
- **Optional and listed callbacks** (Trig NEEDS 32). `(?fun(...))?`
  parameters and slices of callable views, for Go's nil callbacks.
  Closures round 2.
- **`keeps` clauses on function types.** Only if Trig's checker port
  shows sites that need them.
- **Async and await.** Only after scoped concurrency, and only as
  structured tasks, not Rust's model.
- **A narrow raw-pointer facility** for writing new low-level containers
  in Rig instead of Zig. It shrinks the trusted code Rig cannot check,
  but needs a careful boundary.
- **A machine-checked proof of the Core,** in Lean or Coq. The Core is
  small enough to formalize, which would close the assurance gap with
  Rust.
- **Field-precise re-pointing (n39).** Re-pointing a view field would
  affect only that field's loan, not the whole struct's. No Trig or tsc
  site needs it yet.

## Don't add: in Rust, but not needed, or better left out

- **Lifetime annotations and lifetime variance (`'a`).** Loan sets plus
  `from` cover the need. Variance is where Rust's soundness bugs #164250
  and #25860 live.
- **Write views stored in structs** (`&mut` fields). Keep the rule;
  yielding projections recover what it costs.
- **Implicit moves, autoref, auto-deref, and `Deref` coercions.** Each
  hides a move, a call, or a write. Keep `<x` and `!v` visible.
- **Higher-ranked bounds (`for<'a>`) and generic associated types.**
  They exist to serve lifetimes.
- **Loan checks at run time, as Rust's `RefCell` does.** A `Cell` behind
  `*`, holding no views, avoids a whole class of run-time panics.
- **`Pin` and self-referential structs.** "A value never holds a view of
  itself" removes the need.
- **The drop-check escape hatch (`#[may_dangle]`).** Rig's rule is
  simpler: a drop reads the views a value holds only if its type has a
  `drop` body.
- **Temporary lifetime extension.** Rig's temporaries end with their
  statement, which is easier to reason about.
- **Treating leaks as safe** (`mem::forget`). Rig counts a leak as a
  compiler bug, except a cycle of `*T` handles.
- **Wrapping overflow in release builds.** Rig's checked `--release` is
  safer, and `--release=fast` is the explicit way out.
- **Macros.** Substrate in the language, libraries in userland.
- **Rust's trait coherence and orphan rules.** Rig compiles whole
  programs, so its traits can stay simpler.
- **A broad `unsafe` superset.** Keep `raw` narrow, with the ownership
  checker still running inside it.
