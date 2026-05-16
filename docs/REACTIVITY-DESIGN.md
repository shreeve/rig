# Rig Reactivity Design Note

## Purpose

This note records the substrate decisions Rig needs to make in order to
support a future reactive library (Rip-style `Cell` / `Memo` / `Effect`).
The library itself is deferred until the prerequisite M20+ items land.
This note is the **forcing function for those prerequisites**: each
decision below identifies a use case that is broader than reactivity
but where reactivity provides the clearest stress test.

The library is the eventual deliverable. The substrate is the immediate
one.

## Status

D1, D2, D3, D4, D5 have landed in SPEC.md (§Shared Ownership,
§Weak Reference, §Pin, §Unsafe / Raw, §V1 Scope, §V2/V3 Ideas).
D6, D7, D8, D9 remain design proposals; they land alongside the
implementation work in their respective M20+ items per
`docs/ROADMAP.md`.

M20+ now-blocking items #1 (instance methods + `self`
semantics + receiver-style calls) and #5 (methods on enums)
landed in M20a per ROADMAP. The receiver-mode rules in this
note (D6's Cell sketch + the "Why this is a substrate question"
table) now have real syntax in the language — `cell.set(2)`
auto-borrows `?cell`, `(!cell).set(2)` is required for write
receivers, `(<cell).consume()` is required for consuming
receivers.

M20a.1 added the `?self` / `!self` sigil-on-name sugar for the
common borrow-receiver case, validated to only fire on `self`
inside a nominal body. The library sketches below now use the
sugar form (`fun get(?self)` instead of `fun get(self: ?Self)`).

Subsequent items (generic methods, `Option(T)`, real `*`/`~`
Rc/Weak, interior mutability, closure capture) remain M20+ work.

## Motivating use case

In Rip (CoffeeScript-to-JS), reactivity is spelled:

```rip
count := 1                # state cell
double ~= count * 2       # computed (auto-tracking)
~> print double           # effect (auto-tracking)
```

Steve wants the same idea available in Rig. The eventual surface might
be the same `:=` / `~=` / `~>` sugar (Phase C, optional, V2+); the
substrate underneath must lower to explicit constructs that real users
can write today (once prerequisites land).

The explicit V1 form — what the sugar lowers to, what users write
without sugar:

```rig
reactor = Reactor()

count  = *Cell(Int, value: 1, reactor: reactor)
double = *Memo(Int, deps: [count], reactor: reactor)
  count.get() * 2

eff = *Effect(deps: [double], reactor: reactor)
  print(double.get())

count.set(2)
reactor.flush()
```

Two things in this sketch differ from naive first-draft attempts and
matter:

1. `deps: [count]` lists **strong** handles to dependencies. The weak
   back-edge (`Cell.subscribers : Vec(~Memo)`) lives inside the runtime,
   not in the user-visible API. A user-facing `~`-prefix on the dep
   would put weakness on the wrong edge.
2. `count.set(2)` is a method call on a shared handle (interior
   mutability), **not** `!count.set(2)`. Write-borrowing a `*Cell`
   exclusively would lie — aliases exist by construction.

## Why this is a substrate question, not a sugar question

Reactivity is one of several use cases that all need the same substrate
primitives:

| Use case | Needs `*T` | Needs `~T` | Needs interior mut | Needs callback storage |
|---|:-:|:-:|:-:|:-:|
| Reactive (`Cell` / `Memo` / `Effect`) | yes | yes (subscriber back-edge) | yes | yes |
| GUI tree (parent owns child, child weak-refs parent) | yes | yes | yes | sometimes |
| Observer pattern (subject holds list of weak observers) | yes | yes | usually | yes |
| Graph data structures (cyclic) | yes | yes | usually | no |
| ECS (entities with stable handles) | yes | yes | yes | sometimes |
| Compiler self-referential types (recursive `Type` nodes) | yes | yes | no | no |
| Cache with weak entries | yes | yes | yes | no |

Any one of these is enough motivation. All of them together make this
V1-blocking substrate work, not a reactivity tangent.

## Substrate decisions

Each decision states the question, the recommendation, and what it
unblocks beyond reactivity.

### D1. `*T` semantics

**Decision.** Promote `*T` from "parsed but lightly enforced" to real
V1 semantics.

**Spec language to add to SPEC §Shared Ownership:**

```
*T  single-threaded reference-counted strong handle to T
    - construction increments strong count
    - drop decrements strong count
    - last strong drop runs T's destructor synchronously, before
      the *T handle itself is gone
    - NOT Send, NOT Sync (no atomics — single-threaded V1)
    - cycles leak by default; lint where possible, document loudly
```

This is exactly `Rc<T>`. Nothing fancier. No cycle collection. No
thread story. Pick boring.

**Unblocks.** All shared-ownership use cases. Required before stdlib
seed (`Vec` / `HashMap` / `String` ergonomics improve dramatically
with `Rc`).

### D2. `~T` semantics

**Decision.** Promote `~T` from "parsed but lightly enforced" to real
V1 semantics.

**Spec language:**

```
~T  single-threaded weak handle paired with *T
    - does NOT keep T alive
    - upgrade() returns *T?  (optional shared handle)
    - after the last *T is dropped, all ~T.upgrade() return none
```

Exactly `Weak<T>`. Required to break ownership cycles in all the use
cases above.

**Hard constraint.** D1 and D2 are an "all or nothing" commitment.
Both AI reviewers in the design conversation agreed independently:
shipping `*` / `~` as parsed-but-fake is **more dangerous** than not
shipping them. Either real semantics in V1, or reserve the sigils
until V2. The fake middle creates false-promise APIs that calcify.

### D3. `*T` drop ordering

**Decision.** Add to SPEC §Ownership Semantics:

> When the last `*T` strong handle is dropped, the value's destructor
> runs **synchronously**, before the `*T` handle itself is gone. Any
> `~T` weak handles to the same value upgrade to `none` after this
> point. Destructors during a reactive flush (or any callback
> dispatch) are allowed; re-entrant destruction is the calling
> library's policy to handle.

**Unblocks.** `defer` / `errdefer` interaction with shared values;
reactive subscriber cleanup; any RAII pattern over shared state.

### D4. `@T` (pin) — explicitly deferred to V2

**Decision.** Demote `@T` from V1 sigil to V2 reserved.

**Rationale.** Pinning is a `Pin<P>` discipline, not a sigil. The V1
use cases (the subscribe-in-init bug we caught in the Zig sketch,
self-referential structs) are real but workable via `alloc.create`
returning a `*Self` with a stable heap address. The substrate cost of
pin (pin projection, `Unpin` taxonomy, move-while-pinned errors) is
too high for V1's benefit. Reconsider when async / futures / intrusive
lists land.

**SPEC update.** §V1 Scope: move `@x` from "parsed but lightly
enforced" to V2/V3 Ideas.

### D5. `%T` (raw) — unsafe-tainting effect

**Decision.** `%x` and `zig "..."` and dangerous `@builtin(...)` calls
must require an **unsafe context** — not just a glyph at the
expression. The SPEC needs an unsafe-effect lattice (this was already
flagged in the M18 design discussion).

```rig
unsafe
  ptr = %buffer.ptr

sub raw_op() unsafe
  ptr = %buffer.ptr
```

Safe Rig calling unsafe Rig requires the call to be inside an `unsafe`
block, or for the callee to wrap the unsafe in a safe contract.

**Builtin classification needed.** `@sizeOf` / `@alignOf` / `@typeName`
etc. are safe; `@ptrCast` / `@intFromPtr` / `@memcpy` are unsafe. A
whitelist lives in `effects.zig` (or its successor in `types.zig`).

**Unblocks.** Stdlib seed (it wraps unsafe Zig with safe Rig
signatures); the broader safety story.

### D6. Interior mutability

**Question.** How does `count.set(2)` mutate the value inside a shared
`*Cell` without lying about exclusive borrow?

**Two options, not mutually exclusive:**

**Option A — `Cell(T)` library type.** The mutation lives in the type,
not the sigil. `Cell.set(self: ?Cell(T), value: T)` is a method that
internally uses `unsafe` to update behind the shared handle. The
method takes a *read* borrow of the handle (`?self`) — the handle
itself is not exclusive — and mutates the cell's value through a
controlled `unsafe` block. Caller writes `count.set(2)` (the `?`
auto-borrow is implicit at method call sites). Mirrors Rust's `Cell<T>`
/ `RefCell<T>`.

**Option B — `mutates(self)` effect annotation.** Method signatures
declare visible mutation as an effect:

```rig
sub Cell.set(self: ?Cell(T), value: T) mutates(self)
```

Diagnostics / formatter flag "this call mutates `count`" even without
a sigil at the call site. The effect propagates: any caller of a
`mutates(self)` method is itself in a mutating context.

**Recommendation.** Ship **Option A in V1** (cheaper; matches the Rust
playbook; no new effect-system surface). Reserve Option B for V2 when
the effect system grows beyond fallibility. The interior-mutability
*capability* is what's required; the visibility *channel* can mature
later.

**Hard rule.** Whichever option ships, do **NOT** let `!handle.set(v)`
paper over interior mutability. `!` must mean exclusive write borrow.
A shared `*Cell` cannot be exclusively write-borrowed because aliases
exist by construction — using `!` on it is a category error and would
silently undermine the ownership model.

### D7. Closure capture mode — visible in syntax

**Decision.** Add explicit closure capture syntax. Today Rig has
lambdas (`fn params block`) and bar-capture in iteration / catch
(`|user|`, `|err|`), but no way to declare whether a captured outer
name is held strongly, weakly, by-value, or by move inside the closure
body.

**Proposed syntax (one option, not a final pick):**

```rig
eff = *Effect(deps: [double]) |double|
  print(double.get())                # strong capture (default for *T): leaks the cycle

eff = *Effect(deps: [double]) |~double|
  if double.upgrade() catch null as *d
    print(d.get())                   # weak capture: cycle broken
```

Capture modes match the sigil family: `<name` move-capture, `?name` /
`!name` borrow-capture (lifetime-bounded), `+name` clone-capture,
`~name` weak-capture, default = strong-clone for `*`-handles, value-copy
for `Copy` types, error for owned non-`Copy` types.

**Rationale.** This is the single most important critique GPT-5.5
raised in the design conversation. Without explicit capture, weak dep
lists become **decorative** — the closure body silently re-captures the
value strongly and leaks the cycle the weak dep was meant to break.
This is **independent of reactivity**; it affects every callback-storing
API.

**Unblocks.** Async (eventually), callback-based stdlib APIs, defer
bodies that close over moved values, iterator adapters that store
their fn.

### D8. `pre`-time AST extraction

**Decision.** `pre` needs to grow the ability to walk an expression
body's AST and collect syntactic reactive reads (`x.get()` calls where
`x : *Cell(_)`). This enables `pre fun memo(body) { ... }`-style
ergonomic builders that desugar to the explicit-deps primitive.

**Hard constraint #1.** The extraction must collect **syntactic**
reactive reads, not arbitrary free identifiers. An opaque function
call `f(x)` cannot infer dependency behavior — it must either fail to
compile (forcing explicit deps) or be marked with a reactive-effect
signature on `f`.

**Hard constraint #2.** Do **NOT** design `pre`-static extraction with
a runtime-tracking fallback. The sugar must pick one path explicitly
(`reactive.static_memo { ... }` vs `reactive.dynamic_memo { ... }` vs
`Memo.new(deps: [...])`). Silently falling back makes performance and
lifetime behavior proof-dependent — debugging "why is this not
recomputing?" becomes detective work.

**Unblocks.** Derive-style code generation; serialization helpers;
reactive sugar (Phase C); any DSL built on top of Rig.

### D9. Reactor / scoped context — defer the language mechanism

**Decision** (general substrate, not reactivity-specific). Rig needs an
eventual story for "scoped ambient context passed through a call tree"
— reactivity wants a `Reactor`, allocator-aware code wants an
`Allocator`, tracing wants a `Span`. The general pattern is "this
function takes an implicit parameter that's set by an enclosing scope."

**Recommendation.** Defer the language-level mechanism. For V1,
libraries pass the reactor (or allocator, or span) explicitly:

```rig
reactor = Reactor()
count = *Cell(Int, value: 1, reactor: reactor)
```

Verbose but honest. V2 may add scoped-context syntax (akin to Scala's
`given` / `using` or Koka's effects), but only after the V1 explicit
form proves itself across `rig-reactive`, an allocator-aware stdlib,
and a tracing experiment.

## What the V1 library looks like

A sketch of `rig-reactive` once D1–D9 land. Not implementation; just
shape, to validate the substrate decisions hang together:

```rig
type Reactor
  # opaque; owns the dirty queue and flush epoch state

sub Reactor.new() -> *Reactor
sub Reactor.batch(?self, body: fn())
sub Reactor.flush(?self)

type Cell(T)
  # interior-mutable shared cell

sub Cell.new(value: T, reactor: ?Reactor) -> *Cell(T)
sub Cell.get(?self) -> T
sub Cell.set(?self, value: T)                 # dirty-mark + maybe queue

type Memo(T)

sub Memo.new(deps: [?Reactive], compute: fn() -> T, reactor: ?Reactor) -> *Memo(T)
sub Memo.get(?self) -> T                      # lazy pull; recomputes if dirty

type Effect

sub Effect.new(deps: [?Reactive], run: fn(), reactor: ?Reactor) -> *Effect
# Effect detaches on drop; weak-stored in dep subscriber lists
```

(`Reactive` is a marker interface or sum type covering `Cell` / `Memo` /
anything that exposes a subscriber list. Exact shape TBD; depends on
whether Rig grows traits / interfaces.)

**Implementation strategy** (also forced by the design discussion):

- **Push invalidation on `set`.** Mark direct subscribers dirty,
  propagate transitively, queue affected effects exactly once per
  flush epoch.
- **Pull recomputation on `get`.** `Memo.get` recomputes only if dirty;
  reads its deps recursively, which recomputes them up the chain. This
  is the topology-ordering fix — `B.get()` pulls `A` current before
  returning, so flat subscriber iteration is never needed.
- **Explicit batching via `Reactor.batch`.** No event loop assumed.
  Either each top-level `Cell.set` does an implicit begin-flush-end,
  or callers wrap with `reactor.batch { ... }` then `reactor.flush()`.
- **Reentrancy = queued epochs.** Effect writes during flush schedule
  a follow-up epoch. If the same effect keeps scheduling itself
  forever, the reactor trips a max-iteration error. Strict mode
  (writes during effect = runtime error) available as a debug
  toggle.
- **Errors stay typed, not graph-propagated.** Fallible memos type as
  `*Memo(T!)`; consumers handle with `catch` or propagate. No invisible
  global error handler.

## What changes in M20+ ordering

Based on the decisions above, the M20+ items reorder as follows. **This
is the concrete deliverable of this design note** and is mirrored in
`docs/ROADMAP.md` §M20+.

**Now-blocking (required for any non-trivial library, reactive or
otherwise):**

**Already-landed substrate** (M12 + M14 partial; gaps below):

- Namespaced struct methods (`User.greet()`) — M12
- Generic struct declaration + instantiation + construction — M14

**Now-blocking (required for any non-trivial library, reactive or
otherwise):**

1. Instance methods + `self` semantics + receiver-style calls
   (`cell.set(v)`) — completes M12
2. Real generic-instance member typing (`b.value` on `Box(Int)`
   currently types as `unknown`) — completes M14
3. Generic methods on generic types (M14-deferred; depends on 1+2)
4. `Option(T)` / `Result(T, E)` as generic enum types (D6
   precursor; M14-deferred due to grammar conflict)
5. Methods on enums (parsed, not emitted; depends on 1)
6. `*T` / `~T` real Rc/Weak semantics (D1, D2 — text landed in
   SPEC; runtime implementation TBD)
7. Interior mutability (D6, Option A: `Cell(T)` library type;
   depends on 1+4+6)
8. Closure capture mode syntax (D7)

**Soon (substrate maturity):**

9. `%T` unsafe-effect lattice + `unsafe` block / fn-effect (D5)
10. `pre` AST extraction for derive-style macros (D8)
11. Explicit error sets in `T!E` (already in M20+ list)
12. M15b cross-module signature import (already in M20+ list)

**Deferred to V2 or later:**

13. `@T` pin (D4)
14. Reactor / scoped context language mechanism (D9 — V1 libraries
    pass context explicitly)
15. Reactive sugar (`:=` / `~=` / `~>` — Phase C, optional)
16. Multi-threaded `Arc` / `AtomicCell` / `Send` / `Sync`

## Phase plan

**Phase A — this note.** Decisions captured. SPEC additions
recommended (D1, D2, D3, D4, D5 each need SPEC language updates;
proposed wording is in this doc). Steve reviews and approves SPEC
changes separately.

**Phase B — after now-blocking items 1–7 land.** Build `rig-reactive`
in a branch as the substrate validation. Goal: ~500-line library that
supports the explicit V1 form above end-to-end (Cell / Memo / Effect /
Reactor with push-invalidate, pull-recompute, batching, weak-subscriber
back-edges, typed errors). If anything in items 1–7 doesn't compose,
**fix the language, not the library** — the library is the canary.

**Phase C — V2+, optional, possibly never.** Reactive sugar as
parser-level desugar (the mapping below). Defer indefinitely until the
library is mature and someone actually wants the syntax. The library
must be ergonomic enough on its own that sugar is a luxury, not a
necessity.

## Sugar mapping (for future Phase C reference)

If Steve decides to add Rip sugar to Rig in V2+, the lowering is:

```
Rip surface                    Rig explicit form
─────────────────────────────  ─────────────────────────────────────────
x := e                         x = *Cell(T, value: e, reactor: reactor)
x := e2  (subsequent)          x.set(e2)
y ~= expr                      y = *Memo(T, deps: [⟨extracted⟩], reactor: reactor)
                                 ⟨expr_with_reads⟩
~> body                        _ = *Effect(deps: [⟨extracted⟩], reactor: reactor)
                                 ⟨body⟩
```

Where:

- `⟨extracted⟩` is the `pre`-time syntactic-reactive-read collection
  from D8.
- `⟨expr_with_reads⟩` rewrites bare `x` (when `x : *Cell(_)`) to
  `x.get()`.
- The implicit `reactor` is whichever is in scope (which means by V2+
  Rig probably needs D9 — scoped context — at the language level).

## Provenance

This note synthesizes a multi-turn design discussion between Claude
(Opus 4.7) and GPT-5.5 in the user-ai conversation `c_5c1d09d53ebe2f62`
(rounds 2 and 3 — the original Rig-thesis review is round 1). Two
critiques were load-bearing:

- **GPT-5.5 (round 3):** `!count.set(2)` lies about ownership; weak
  belongs on the subscriber back-edge, not the user-facing dep list;
  closure capture can silently reintroduce cycles independent of any
  sigil discipline.
- **Both AIs (round 3):** `*` / `~` must be real `Rc` / `Weak` in V1
  or reserved entirely; the "parsed but lightly enforced" middle
  position is more dangerous than absence.

If a substrate decision below conflicts with later SPEC or library
experience, this note is wrong and SPEC wins; patch the note.
