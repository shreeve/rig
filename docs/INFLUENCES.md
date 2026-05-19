# INFLUENCES.md — design lineage and external pressures

**What this document is.** A snapshot of the external ideas and
internal observations that have shaped — and continue to shape —
Rig's design at the M20h/Phase B boundary. NOT a roadmap (that's
`ROADMAP.md`), NOT a spec (that's `SPEC.md`), NOT a checklist
(that's `CHECKLIST.md`). This file answers: *"Why does Rig lean
the way it does?"*

**Primacy of Rig's own goals.** Rig is its own language with its
own thesis. The original goals — **powerful, safe, performant,
clean, elegant, succinct**, with explicit ownership and visible
effects as the unifying spine — come FIRST. Nothing in this
document is a direction override. Every external idea cited here
is a **selective extraction**: a pattern worth borrowing
*because* it serves a Rig goal Rig is already pursuing, NOT a
recommendation to make Rig look like the source. Where any
external influence conflicts with Rig's thesis, **the thesis
wins** and the idea gets demoted, deferred, or rejected. The
Nexis project (§7) and Clojure (§5) are referenced as
mature-project lessons and Zig-target case studies; neither is
a playbook Rig is following. The whole point of writing this
document down is so the next session can tell the difference
between "Rig should borrow X" and "Rig is becoming X-like" —
the former is healthy, the latter would be drift.

**Sources synthesized here:**

1. **A ChatGPT-5 digest** Steve forwarded (2026-05-17) on Rust's
   async runtime architecture, why Zig retreated from async,
   what Rig already gets for free, and what to borrow from
   Clojure.
2. **Claude's analysis** of that digest, filtered against Rig's
   actual M20+ shape.
3. **GPT-5.5's post-implementation review** of that analysis,
   which corrected two material overstatements (annotated
   inline below).
4. **Direct inspection of `/Users/shreeve/Data/Code/nexis`** —
   Steve's sister Clojure-on-Zig project — for grounded
   evidence on what Clojure-style persistent collections
   actually cost when ported to a non-GC'd Zig target.
   (Spoiler: Nexis solves that by bringing its own GC. Rig
   can't.)

This file should be re-read before the M20i checkpoint, the
eventual async-design milestone, and any "should we bring in
persistent collections?" conversation.

---

## 1. The substrate ladder

Rig's V1 substrate work, post-M20h, is best understood as a
dependency hierarchy: each layer is a prerequisite for the
ones above it, and every layer below the current frontier
must be solid before the frontier moves up. This is the
partial order of safety prerequisites that languages without
explicit ownership often push into runtime convention, GC, or
discipline. The order below is partial — some layers could
have shipped in parallel — but Rig's actual build order has
been linear, one layer at a time, with design checkpoints
between each.

| # | Layer | What it solves | Rig milestone(s) | Status |
|---|---|---|---|---|
| 0 | **Static types + grammar** | Catch type mismatches before runtime; have a parseable surface | M0–M5 | ✅ |
| 1 | **Ownership / borrow checking** | Who owns each value; who can read/write it; when ownership transfers | M2 + M20a–c (nominal/generic type substrate) | ✅ |
| 2 | **Resource lifetimes (shared + weak + drop)** | Reference-counted handles; weak-without-keeping-alive; cleanup when the last owner drops | M20d (`*T`/`~T` real `Rc`/`Weak`) + M20e (auto-drop via defer-guards) | ✅ |
| 3 | **Interior mutability** | Mutate through a shared handle without breaking borrow rules; mutation visible at call site | M20f (`Cell(T)`) | ✅ |
| 4 | **Closure captures with explicit modes** | Pull outer values into a captured context; mode sigils make refcount/copy/move visible | M20g (`fn \|+x\|` / `\|<x\|` / `\|~x\|` / `\|x\|`) | ✅ |
| 5 | **Stored callable state (heap-owned closures)** | Closures that outlive their defining scope; first abstraction where captured execution context lives past the local stack; UAF-safe drop on last strong. The first step toward "stored partial execution" — async generalizes this to multi-suspension state machines. | M20h (`*Closure(fn ...)`) | ✅ |
| 6 | **Resource-aware containers** | Collections that handle `*T` / `~T` element ownership correctly (no memcpy of refcount handles, drops cascade properly) | M20i (resource-aware Vec / container) | ✅ shipped (1-5/5 — runtime + sema + ownership + emit + tests) |
| 7 | **Reactivity (substrate)** | Push/pull dependency tracking; subscriber notification; Cell → Effect | PB2 + PB3 + PB4 (Phase B) | ✅ substrate complete (Signal multi-subscriber + R2 reentrancy + library/substrate boundary locked in userland) |
| 7.5 | **User-defined Drop (cross-cutting)** | Plain-struct user `drop self: !Self` + auto-generated structural drop glue for any struct with resource fields; "any type with drop glue is non-Copy" alias rule | M25 | ✅ shipped (1-5/5 — grammar + sema + ownership + emit + tests + docs) |
| 7.6 | **Cell-non-Copy + replace** | Cell over resource T (drop-old-on-set, replace swap-and-yield primitive, unified `dropElement` dispatch); the second half of the userland-reactive-library unblock. `take` and `borrow` deferred. | M26 | ✅ shipped (1-5/5 — sema + runtime + ownership + emit + tests + docs) |
| 7.7 | **Auto-deref through member-access in method bodies** | Emit insertion of `.value` RcBox-deref for `self.field.method()` patterns through `*Cell` / shared-handle struct fields. Unlocks the rrlib v0 monomorphic IntSource (single-source reactive). | M27 | ✅ shipped + rrlib v0 running |
| 7.8 | **Multi-capture closures** | `fn \|+a, +b\| body` lifts single-capture limitation. Unlocks the cross-source reactive cascade canary (`count → total → print`). One-grammar-rule + lexer probe extension; downstream pipeline already loop-shaped. | M28 | ✅ shipped + cascade canary running |
| 8 | **Structured concurrency** | Scope-bound tasks, automatic cancellation propagation, no orphan tasks (Trio/Anyio-style) | post-Phase B | deferred |
| 9 | **Async** | Multi-suspension state machines; poll/wake; pin discipline; executor; should be paired with Layer 8 cancellation discipline | post-structured-concurrency | deferred |

### Why this exact order

Each upward edge in the dependency graph:

- **0 → 1**: Can't reason about ownership without a type
  system that distinguishes a value from its handle.
- **1 → 2**: Refcounted handles need borrow rules to be safe;
  the borrow checker decides when a `*T` is OK to read/write.
- **2 → 3**: `Cell(T)` is "interior mutation through a shared
  pointer" — the shared pointer must exist first.
- **2 → 4**: Captures of resource types need refcount
  discipline (clone bumps, move transfers).
- **3 + 4 → 5**: Heap-owned closures combine Rc allocation
  (Layer 2), capture modes (Layer 4), and `__rig_drop` for
  last-strong-cleanup. Cell (Layer 3) is what closures most
  commonly capture, so it must compose cleanly.
- **2 → 6**: A `Vec(~Effect)` needs to drop element handles
  correctly when the Vec drops; that's Layer 2's discipline
  applied to a container.
- **5 + 6 → 7**: Reactivity is "list of escaping callbacks" +
  "notify on state change" — needs both heap closures AND
  resource-aware containers.
- **5 + 6 → 8**: Structured concurrency is parallel to 7 in
  dependency terms (also needs Layers 5 + 6) but Rig sequences
  7 first because Phase B's reactive canary is the active
  validation milestone.
- **5 → 9**: Async generalizes Layer 5 from callable stored
  state to multi-suspension state machines.
- **8 → 9** (policy companion, not strict prerequisite): Rig
  should not ship production async without structured
  concurrency / cancellation discipline. But async lowering
  is technically possible without it — plenty of systems
  demonstrate this; they are simply less safe and less
  composable.

### Cross-cutting concerns (NOT layers)

Several Rig concerns thread through every layer rather than
sitting in the hierarchy:

- **Effects** (fallibility `T!`, optionality `T?`) —
  type/effect properties, distributed across layers.
- **Modules** (M15) — namespace organization, orthogonal to
  the ownership hierarchy.
- **`%` / unsafe** (M20+ item #9) — escape boundary that must
  be audited at every layer; not a foundation rung.
- **`@` / pin** (currently reserved) — side prerequisite to
  async; will become load-bearing alongside Layer 9.
- **User-defined `Drop`** — M20d/M20e implement
  resource-specific drop for Rig-owned runtime handles.
  General Drop remains deferred and will matter before
  arbitrary non-Copy resources become first-class.

### Where we are now

Layer 5 shipped (M20h, commits `f4b448c..1c86aca`). Layer 6
shipped (M20i, commits `4675fca..d6d6c83`). Layer 7 is
**half-shipped**: PB2 single-subscriber `Signal(T)`
primitive landed (commits `5918a15..ea91145` + docs);
multi-subscriber generalization (PB3) is gated on resource-
Vec iteration (M20i.1 / M20j), which is the next concrete
substrate frontier. The reactive canary now demonstrates
the full PB0 + M20g + M20h + PB2 chain end-to-end
(`examples/reactive_canary.rig`, output `1\n3\n13\n7\n99`).
Layers 8 and 9 are deferred — they're designed only after
Phase B exposes what they actually need to solve.

### A note about "lifetimes"

Rust exposes many borrow-validity relationships through
explicit lifetime parameters (`'a`). Rig does not currently
have user-written lifetime parameters. Instead, the relevant
safety questions are distributed across three mechanisms:

- **Borrow validity** (Layer 1, M2) — "is this `?x` borrow
  safe to use here?"
- **Refcount lifetime** (Layer 2, M20d) — "when does this
  `*T`'s underlying Rc drop?"
- **Scope-exit cleanup** (Layer 2, M20e) — "what gets dropped
  when this scope ends?"

These mechanisms cover Rig's V1 lifetime story without
user-written `<'a>` annotations. They do not yet express the
full range of Rust-style lifetime relationships — especially
borrowed returns and async suspension lifetimes; those are
deferred until reactivity validation exposes the concrete
need. The "succinct" goal is preserved in the meantime —
lifetime tracking is implicit in the ownership shape, not
explicit in the type signature.

### What this ladder is NOT

**Not a fast-forward roadmap.** Each layer landed (or will
land) through multiple sub-commits with design checkpoints
+ post-implementation reviews. The ladder is the conceptual
scaffold; `ROADMAP.md` has the actual commit-by-commit
history.

**Not a rigid linear chain.** Layers 3 and 4 are siblings
under Layer 2; Layers 7 and 8 are siblings under Layers 5+6.
The strict prerequisite edges are what matter: a layer
cannot be treated as reliable while one of its dependencies
still has known safety gaps.

**Not a feature wishlist.** Layers 8 and 9 are explicitly
deferred. They are mentioned here to make the dependency
chain visible, NOT to commit Rig to building them in V1.

---

## 2. The deepest framing: async is stored-partial-execution

The digest's strongest single claim — and the one Rig should
internalize — is this:

> Async is fundamentally about storing partial execution safely.
> Not promises, not syntax sugar, not event loops.

The four sub-problems are:

1. **Suspended state** — locals that must outlive the
   suspension point.
2. **Ownership of that state** — who frees it, when, and how.
3. **Resumption safety** — at resumption, the state must still
   be valid (no use-after-free, no torn references).
4. **Cancellation safety** — if the consumer drops the
   computation mid-flight, the state and resources must drop
   cleanly.

Rust unified these via `Future` (the suspended-state struct) +
the borrow checker (validity across suspension points). That
unification — not Tokio, not `async fn` syntax — is what makes
Rust async coherent.

Zig retreated from async because it tried to ship coroutines
without the ownership-of-state foundation: allocator questions,
frame lifetimes, cancellation, ABI, debugging, and error-set
interactions exploded with no static analysis to corral them.

The takeaway for Rig: **async is not a feature to bolt on. It
is the natural outcome of solving stored-partial-execution
first.** When ownership, suspension, and cancellation are clean
substrate primitives, async falls out cheaply. When they aren't,
async corrupts the rest of the language.

---

## 3. M20h, in this light

M20h shipped owned closures: `*Closure(fn |+count| body)`. With
the stored-partial-execution framing, M20h reads as the
**zero-suspension-point case** of stored partial execution.

| Async concept | M20h analog |
|---|---|
| Frame pointer | `Closure0.ctx: *anyopaque` |
| poll / resume entry | `Closure0.invoke_fn` |
| Cancellation / drop frame | `Closure0.drop_fn` (called via `RcBox.__rig_drop`) |
| Stored locals | Capture fields in the per-literal `Env` struct |
| Cleanup on last owner | `RcBox.dropStrong` → `__rig_drop` → `drop_fn` |
| State machine | Trivial: single state (just-constructed) |

This mapping is real, but **GPT-5.5 specifically corrected the
overstatement that "M20h already validated the load-bearing
async ABI"**. The accurate framing is narrower:

> M20h validates a *reusable substrate* for async: owned heap
> environments with explicit captures and correct last-owner
> cleanup. Async will reuse this pattern but still needs:
>
> 1. **State-machine layout** — multi-state union with per-state
>    liveness analysis (compiler work, not just ABI).
> 2. **Borrow-across-suspension rules** — Rust's hard problem.
>    M20h doesn't address this; captures in V1 are owned
>    handles, not borrows.
> 3. **Poll/wake protocol** — `Future::poll → Ready|Pending`
>    with executor-side waker registration. M20h's `invoke()`
>    is run-to-completion.
> 4. **Per-state drop glue** — only currently-live variant's
>    locals get dropped on cancellation. M20h drops the whole
>    env.
> 5. **Pin/address stability** — the `@` sigil finally becomes
>    load-bearing (self-referential frames after first poll).
> 6. **Executor + reactor + cancellation tokens** — Tokio-class
>    runtime work the language alone doesn't provide.

So the correct claim is:

> M20h proves one prerequisite for async: owned suspended-state
> environments with explicit capture and last-owner cleanup.
> It does not make async implementation-ready. Async still
> requires compiler-lowered state machines, borrow-across-
> suspension rules, poll/wake ABI, per-state drop glue,
> pinning, and an executor/runtime.

This also means: when we eventually do design async, the M20h
ABI (`Closure0` vtable, type erasure via `*anyopaque`,
`__rig_drop`-on-last-strong) is a solid foundation to extend,
not a sketch to throw away.

**Action**: add a short retrospective paragraph to SPEC §Owned
Closures noting the stored-partial-execution framing.

---

## 4. The sigil algebra and async

The digest proposes `^` for suspension. After GPT-5.5's
review, this is best treated as a **plausible candidate**, not
a commitment. Recording it here so the eventual async
checkpoint has a starting point.

### Candidate spelling (NOT locked)

| Form | Meaning |
|---|---|
| `^expr` (prefix on expression) | await — suspend on a future |
| `^T` (prefix on type) | `Future<T>` |
| `expr^` (suffix on expression) | **NOT proposed in V1.** Would parallel `expr!` for propagate-fail, but adding a second control-flow-modifying suffix sigil bloats the cognitive load on the suffix family. |

The sigil-family discipline matters: each sigil should encode
**one effect** in each position. `^` as await is clean. `^T` as
future-type is clean. A `expr^` suffix would mean
"propagate-suspension" which conceptually parallels
`expr!`-as-propagate-fail, but the family stays smaller without it
— users can write `^(expr!)` or similar if both effects
compose.

### What async would activate

- `@` (pin) becomes load-bearing. Currently reserved; an async
  state machine that contains self-referential pointers needs
  pin discipline.
- `?` and `!` semantics across suspension boundaries need
  rules (Rust's "no borrow across await" generalization).
- The runtime gains an executor, reactor, cancellation token
  story (Tokio-class work).

### What we do NOT do now

- Do not reserve `^` for async in the parser. Keep it
  syntactically free until the async checkpoint formally
  scopes the work.
- Do not document `^` in SPEC as forthcoming. INFLUENCES.md
  is the right place to capture the lean; SPEC stays factual.

---

## 5. Clojure influences — what to borrow, what to skip

The digest's Clojure section was the most actionable part.
After GPT-5.5's review, the recommendations sort cleanly into
take / skip / defer. The point of this section is **selective
adoption** in service of Rig's existing goals — Rig is a
systems language with explicit ownership, not a Lisp; nothing
below tries to change that.

### Take — applies to Rig idioms now

**Cultural preference for immutability.** Rig should encourage
`=!` (fixed binding) in idiomatic code; mutation should be
the visible exception, not the default reading. This is a
style-guide change, NOT a surface-syntax flip. (See §6 for
why we explicitly don't flip.)

**Mutation visible at the call site, not just the binding.**
Cell already does this (`count.set(1)` is visibly mutating).
Future Rig idioms should prefer interior-mutable types over
mutable bindings where mutation is part of the design.

**Values over objects** as a design discipline. Records,
constructors returning new instances, transformations not
in-place updates. Rig's ownership story makes this cheap; the
Clojure principle is just to lean on it.

### Defer — interesting, NOT in immediate scope

**Persistent collections (CHAMP / radix trie).** See §7 below
for the long form. Short version: these are a target, NOT
M20i. The path from "we want Vec for subscribers" to "we ship
CHAMP-backed PersistentVec" goes through a non-trivial design
(Cell non-Copy relaxation, refcount-aware node lifetime,
element drop discipline). M20i should design the
**minimal resource-aware container** for Phase B first;
persistent collections can be M20j+ or never.

**Lazy sequences / transducers.** Post-V1. They compose
beautifully with persistent collections, but neither one is a
V1 substrate primitive.

**Macros.** Rig has `pre` for compile-time evaluation. Clojure-
style macros (operating on Forms before compilation) are a
deferred topic. The `pre` discipline already covers the V1
use cases.

### Skip — explicitly NOT adopted

**STM (`ref` / `dosync`).** GPT-5.5 was firm and Claude agrees:
STM has never paid for itself outside Clojure's persistent-
collection-plus-GC niche. Rig's ownership model + Cell + future
async are the V1 concurrency story. STM is a complexity
magnet with no V1 use case.

**Lazy-everywhere semantics.** Rig is eager. Streams as an
explicit construct may come later; lazy as a global default
would conflict with the visible-effects thesis (deferred
computation has hidden cost).

**Agents.** A JVM artifact. Async + structured concurrency
will cover the real use case.

### The cultural rule worth stealing wholesale

> **Prefer values over objects.**

Immutable records, persistent collections (when they ship),
transformations returning new values, mutation only at visible
boundaries (`!x`, `<x`, `Cell.set`, `-x`).

### Compact summary table

| Clojure / Nexis influence | Rig action |
|---|---|
| Persistent collections (CHAMP, plain trie) | Target for M20j+, after resource-aware Vec ships and Phase B exposes the actual need |
| Transients / builders | Consider alongside persistent collections |
| Immutability culture | Style + idiom now; no surface flip |
| `seq` as central abstraction | Defer; revisit if persistent collections land |
| Keyword-as-function (`(:key obj)`) | Defer; no immediate use case |
| Macros (Form-on-Form) | Defer; `pre` covers V1 compile-time evaluation |
| STM | Skip — never |
| Lazy-everywhere sequences | Skip — Rig is eager by default |
| GC implementation strategy | Skip — incompatible with ownership thesis |
| CHAMP > HAMT, plain trie > RRB | Borrow when/if persistent collections land |
| xxHash3 > Murmur3 | Borrow if hashing decisions get formalized |
| `fn*` / `let*` primitive + macro bootstrap | Borrow if Rig grows a macro system |

---

## 6. The "flip immutable-by-default surface" question

The digest's strongest Clojure pitch is **immutable by
default, with mutation visible**. In Rig terms, this would
mean making `x = expr` reserved for fixed bindings and
requiring something like `var x = expr` or `x := expr` for
mutable.

**Claude's analysis: don't flip now.** GPT-5.5 endorsed this.

Reasons:

1. **The semantic property already holds.** M19's per-binding
   mutation pre-scan in the emitter emits `var` only when the
   binding is actually reassigned. Bindings are
   immutable-by-emission unless mutated. The user just doesn't
   *see* this in their source.
2. **Surface flip would churn every example.** `i = 0; i += 1`
   patterns are pervasive. A surface flip is a Rig 0.2 event,
   not an M20-sub-commit.
3. **Cell already provides "visible mutation" cleanly.**
   `count.set(1)` is the visible-mutation idiom. The visibility
   thesis is honored via interior-mutable types, not via
   binding-syntax noise.
4. **The right immediate move is cultural, not language.**
   Style guide + idiomatic examples should lean toward `=!` for
   anything that doesn't need to change.

**Action**: do NOT add a roadmap item for "flip immutable-by-
default". If Steve ever wants this, it becomes a separate Rig
0.2 design conversation with its own checkpoint.

---

## 7. Nexis as the Clojure-on-Zig reality check

**Role of this section.** Nexis is referenced as a mature
sibling project — a working data point for what's been proven
feasible on a Zig substrate — NOT as a model Rig should
emulate. Rig and Nexis have different theses (Rig: ownership +
visible effects + zero-cost on a small substrate; Nexis: full
Clojure surface + persistent collections + durable refs on a
GC'd runtime). The findings below extract ideas that survive
the translation back into Rig's thesis; everything that
requires Nexis's runtime model (especially the GC) is excluded.

`/Users/shreeve/Data/Code/nexis` is Steve's sister project —
Clojure language design on a Zig-native runtime. It exists,
it works, and crucially **it documents the cost of taking
Clojure's persistent collections seriously on a non-JVM
target.** That cost framing is the load-bearing reason to
reference it: Rig now knows what shape the design space looks
like *with full implementation detail*, which is much better
than design from speculation.

### What Nexis ships (Phase 1 complete)

| Component | Where | Lines | Notes |
|---|---|---|---|
| **CHAMP HAMT** (not classic Bagwell) | `src/coll/champ.zig` | ~3,667 | Persistent map + set. Subkind taxonomy. Array-map fast path for ≤8 entries; CHAMP promotion at 9. |
| **Plain 32-way radix trie vector** (NOT RRB) | `src/coll/vector.zig` | ~853 | Same shape Clojure shipped for 17 years. RRB deferred to v2. |
| **Transient wrapper** | `src/coll/transient.zig` | ~585 | Owner-token discipline. Shallow semantics in v1. |
| **Persistent list** | `src/coll/list.zig` | n/a | Conventional cons cell. |
| **Precise mark-sweep GC** | `src/gc.zig` | ~469 | Explicit-only (caller invokes `collect`), non-reentrant, no write barriers. STW. |
| **xxHash3** (not Murmur3) | `src/hash.zig` | n/a | Faster, better-distributed. |

### Why Nexis matters for Rig: the GC question

**Nexis brought its own GC.** The CHAMP/vector/transient code
depends on a precise mark-sweep collector with explicit roots.
Persistent collections — by their structural-sharing nature —
produce a graph of shared nodes where "when does this node
drop?" is hard to answer without tracing.

If Rig wants Clojure-style persistent collections, it has
four options to weigh:

1. **Add a GC.** Massive philosophical violation. Rig's whole
   point is no GC; ownership replaces it. Reject.
2. **Refcount every CHAMP node.** Doable, but every interior
   trie node becomes an `RcBox(Node)`. Refcount overhead on
   every node-share. Element drop on root-drop requires
   walking; structural-sharing means walking is non-trivial.
   Possible but expensive.
3. **Arena-allocate per snapshot.** Each persistent collection
   value owns an arena; structural sharing across snapshots
   is forbidden. Defeats the point of persistent collections.
4. **Region/epoch-owned persistent structures for bounded
   lifetimes.** GPT-5.5 flagged this as a design-space option
   worth recording. For reactive snapshots specifically (where
   the snapshot lives for the duration of one notification
   pass), an epoch/region lifetime might give us the
   structural-sharing benefit within a single pass without
   per-node refcounting. Not a recommendation; an option to
   weigh if/when persistent collections move from "interesting
   target" to "concrete design work."

GPT-5.5's specific warning:

> Clojure's collections rely on GC. Rig does not. Porting CHAMP
> to Rig means designing node ownership/drop. PersistentVec
> still contains resource handles in nodes. When a PersistentVec
> root drops, it decrements node refcounts; when a node's
> refcount hits zero, it must drop element handles in that
> node. If a path is shared between versions, element drops
> must happen exactly once.

**Implication**: persistent collections in Rig are a *real*
project, not a "port the Nexis code" weekend. Option 2
(refcount-every-node) is the only viable path, and it changes
the performance story materially.

### What Rig CAN borrow from Nexis: architecture, not implementation

The clean rule, per GPT-5.5: **borrow Nexis's architectural
lessons; do not borrow its GC-backed implementation.**

Borrowable (when/if persistent collections become real Rig
work):

- **CHAMP, not classic HAMT.** Better cache locality, better
  equality checks, better iteration. Nexis's `CLOJURE-REVIEW.md`
  documents the choice with citations.
- **Plain 32-way radix trie for vectors.** Clojure doesn't even
  ship RRB; we shouldn't either in V1.
- **xxHash3, not Murmur3.** Modern, faster.
- **Transients via isolate-local owner token**, not thread
  identity. The transient/builder pattern is the performance
  story for "construct a persistent value via many ops."
- **Single hash function exposed to users** (Clojure's
  `hashCode`/`hasheq` split is JVM baggage Rig doesn't inherit).
- **Compiler primitives + macro bootstrap pattern** (`fn*` /
  `let*` / `loop*` as primitives, `fn` / `let` / `loop` as
  macros). Applicable when/if Rig grows a macro system.
- **Keyword/symbol asymmetry**: keywords interned, symbols
  interned-in-common-case-with-heap-fallback-for-metadata.

These are all **language-design wins**, not implementation
imports.

NOT borrowable:

- The GC. Period.
- Direct code reuse of `champ.zig` / `vector.zig` — every node
  type assumes a `HeapHeader` + GC tracing.
- Lazy sequences (Nexis defers them too; Clojure's
  laziness-everywhere is JVM-cultural).

### Tone-check from Nexis CLOJURE-REVIEW.md

Nexis's review document is a model for what `docs/INFLUENCES.md`
should aspire to:

- **Citation-anchored**: every claim points at a specific
  Clojure source file or function with line counts.
- **Take / Adapt / Reject** structure: zero ambiguity about
  what's incoming, what's modified, what's rejected.
- **Concrete deltas**: every PLAN.md section that changed is
  enumerated with the reason.

Rig's INFLUENCES.md doesn't need to be exhaustive (we're not
porting Clojure, we're being influenced by it), but the
take/adapt/reject discipline is worth keeping.

---

## 8. The M20i pivot (the most concrete consequence)

Pre-digest, Claude's M20i lean was: "builtin mutable `Vec(T)`
parallel to Cell, for subscriber lists." The digest pushed
toward "persistent Vec first."

**Post-review position: persistent first is wrong. M20i remains
resource-aware mutable Vec.**

GPT-5.5's pushback on the "PersistentVec first" lean was
detailed and persuasive (and confirmed by the Nexis review):

1. **PersistentVec drags in too much.** CHAMP + vector trie
   code + Cell-non-Copy relaxation + per-node refcount + element
   drop discipline. Phase B doesn't need any of that yet.
2. **The performance constants are bad for small lists.** A
   subscriber list with 3 effects doesn't benefit from
   structural sharing. The trie overhead dominates.
3. **It conflicts with Cell-Copy-only.** Putting a
   PersistentVec inside `*Cell(...)` requires relaxing Cell to
   non-Copy types, which is itself a substantial substrate
   change (needs replace/take/drop semantics).
4. **The "no memcpy on resize" claim is misleading.**
   Persistent collections still drop element handles when
   their containing node hits refcount zero. We've replaced
   "memcpy on resize" with "graph-walk on drop". Different
   work, not less work.

**The cleaner M20i shape**:

```
M20i = resource-aware mutable Vec(T)
       with a narrow API: push / pop / len / get / clear / iter
       and explicit policies for what push consumes
       (move-into vs clone-into) and how drop cascades.
```

GPT-5.5's framing for the M20i checkpoint:

> **Ask: "What is the smallest resource-aware container needed
> for subscriber lists?"**
>
> **Not: "Do we implement Clojure collections now?"**

Persistent collections can be M20j or M21 — after the mutable
Vec ships and we've inspected whether the structural-sharing
benefit is actually visible in Phase B's notification path.

**Open question for the M20i checkpoint**: weak vs strong
storage of subscribers. `Vec(~Effect)` (weak) lets the
subscriber's owner control its lifetime; `Vec(*Effect)`
(strong) keeps subscribers alive as long as the publisher
exists. Phase B's design likely wants weak — explore at the
checkpoint.

---

## 9. The five carry-forward questions, answered

From the digest's closing five:

### Q1. Does the "ownership → reactivity → structured concurrency → async" sequencing deliver Rust-grade safety?

**Yes, conditionally.** The condition is that each layer must
be honest about what it permits:

- **Ownership** (done through M20h) is solid. Rc + Weak + scope
  defers + owned closures form a coherent substrate.
- **Reactivity** (M20i + PB2/PB3) must stay **strictly
  synchronous**. Push-based notification, no deferred
  callbacks, no async-shaped subscribers. The moment
  reactivity smuggles in async-flavored callbacks, the
  safety story splinters because async safety hasn't been
  designed yet.
- **Structured concurrency** is the next layer above reactivity:
  scope-bound tasks, automatic cancellation propagation,
  no orphan tasks. This can be designed before async (Trio /
  Anyio model from Python; structured nurseries).
- **Async** ships LAST. The four problems below it (ownership,
  reactivity, structured concurrency) must be done first.

Skipping a layer = importing complexity prematurely.

### Q2. Can `Effect(deps: [~cell]) |~cell|` express suspension-boundary capture?

**Almost. It expresses ONE suspension boundary
(construction → invocation).** That's M20h. For multi-suspension
state machines (async fn with multiple `^expr` points), the
compiler needs liveness analysis at each suspension point,
which is strictly more work than M20h's "one fixed env at
construction time".

The DEPS-as-explicit pattern is good as-is. It makes captures
visible. The async generalization is: each suspension point
has its own (subset of) DEPS, and the compiler figures out
the union for the frame.

### Q3. What's the minimum viable CHAMP-backed persistent collections needed before reactivity becomes pleasant?

**Zero.** Phase B can be built on resource-aware mutable Vec
(M20i). The persistent-collection question is "do we want
snapshot-safe notification?" — and the answer is "maybe,
later, after we've seen Phase B's actual notification path."

If we ever do want them:

- `PersistentVec(T)` for subscriber lists.
- `PersistentMap(K, V)` for Memo caches (but Memo's V1
  cache is one slot + dirty flag — a Map is over-engineering).
- Set is nice-to-have for "subscribed cell IDs" tracking.

But all of this is M20j+ at the earliest.

### Q4. How should the sigil algebra extend to suspension/cancellation without semantic drift?

**`^` is a plausible candidate**, not a commitment. See §4.
The async-design milestone will scope syntax, ABI, drop model,
borrow rules. Until then, INFLUENCES.md captures the lean;
SPEC stays factual.

### Q5. Is "correctness through visibility" actually provable, or is it a UX framing?

**It's UX framing.** The actual safety is proven by the
ownership checker, type checker, effects checker. Visibility
helps the *programmer* reason about WHAT the system is doing,
but it doesn't itself prove anything.

Rig should claim **"rigor + visibility"**, not "visibility
therefore rigor." The visibility thesis is a usability story
on top of a rigor foundation. If we over-claim visibility-as-
correctness, users will hit cases where their visibly-tagged
code is buggy because the underlying analysis missed
something.

---

## 10. The strategic rules

These are the rules INFLUENCES.md is committing to memory:

1. **Add features only when they make an existing semantic
   effect explicit OR unify multiple ad-hoc mechanisms.** The
   "Do not add features. Unify effects." maxim from the digest,
   refined per GPT-5.5. M20h passes this test (unified
   Rc-allocation + closure capture + last-owner drop). M20f
   passes it (made interior mutation safely explicit). M20i
   should too (unify resource-aware storage + collection
   semantics). A feature that adds capability without making
   anything more explicit OR unifying anything is suspect.

2. **Reactivity stays synchronous until async is designed.**
   No callback queuing, no deferred notification, no
   async-shaped escape hatches in Phase B. The reactive
   canary's `flush()` is a synchronous walk.

3. **Visibility is UX; rigor is the foundation.** Don't claim
   correctness via visibility alone. Always keep the checkers
   doing the heavy lifting.

4. **No GC, ever.** Rig's ownership model is the alternative.
   If a feature requires GC, the feature needs redesigning,
   not the language.

5. **Cultural immutability now; surface flip not now.**
   Encourage `=!`. Don't change `=` semantics.

6. **STM never.** No exceptions.

7. **Persistent collections are post-M20i and conditional.**
   Only ship them if Phase B's actual notification pattern
   shows snapshot-iteration is worth the per-node refcount cost.

8. **A sigil may be reused across positions only if each
   position has one unambiguous meaning.** This preserves the
   existing Rig pattern (`?x` borrow vs `?T` borrowed-param
   vs `T?` optional vs `x?` reserved-for-future-propagate) —
   four positions, four distinct meanings, no drift. When
   async ships, `^expr` (await) and `^T` (Future<T>) are the
   candidates; `expr^` is deliberately NOT proposed to keep
   the suffix-sigil family small.

9. **Rig is the contract for human and tool consumption. AI
   works in the language, not around it.** The visible-effects
   thesis (SPEC §Overview second paragraph,
   `docs/SEMANTIC-SEXP.md` design rule) is what makes Rig
   useful to AI tooling — every effect that other languages
   push to runtime convention is a first-class IR Tag in Rig.
   Tools (and AI) read those facts; they do not have to guess.
   That is the AI-relevant claim, and it is downstream of
   rules 1, 3, and 8 — not an independent direction.
   **Do NOT pivot Rig's positioning to "the AI language."**
   That framing invites natural-language-input + opaque-
   generation expectations, the inverse of Rig's thesis. The
   right action when AI consumability matters is to expose
   the existing semantic facts cleanly (e.g., the V1.x
   `rig sema --json` export in `docs/ROADMAP.md`), not to
   restructure the language around AI-shaped use cases.
   Per the GPT-5.5 review (conversation
   `c_351a16579461fb9b`): fix the contract, not the diagram.

---

## 11. What this means for the current arc

Concrete actions falling out of this document:

| Action | Where | Status |
|---|---|---|
| Add stored-partial-execution retrospective paragraph | `SPEC.md` §Owned Closures (M20h) | TODO when SPEC next touches |
| M20i checkpoint focuses on minimal resource-aware container, NOT CHAMP | `HANDOFF.md` Minute-2 block + M20i checkpoint scope | TODO at checkpoint |
| Future async arc preview (deferred, NOT roadmap commitment) | `HANDOFF.md` "Future arcs" section | TODO this commit |
| Style-guide leans toward `=!` for non-mutated bindings | Future style guide doc | TODO post-Phase B |
| Persistent collections explicitly demoted to M20j+ in roadmap | `ROADMAP.md` M20+ list | TODO this commit |

---

## 12. Sources cited

- **ChatGPT-5 digest** (2026-05-17, forwarded by Steve) — the
  initial impetus.
- **GPT-5.5 conversation `c_5c1d09d53ebe2f62`** — entry 20
  (M20h post-implementation review) provided the corrections
  on async overstatement, PersistentVec overreach, and
  immutability flip caution.
- **Nexis project at `/Users/shreeve/Data/Code/nexis`** —
  CHAMP/vector/transient/GC reference implementation; the
  `CLOJURE-REVIEW.md` document there was particularly useful.
- **Rust async references** — `async-book`, `Pin and Suspending`
  (Niko Matsakis), Aaron Turon's pre-MVP design notes — for
  the state-machine + ownership-of-state framing.
- **Andrew Kelley's Zig async post-mortem** — for the "what
  exploded without ownership" cautionary tale.

---

## 13. Open questions for future sessions

These are not answered above; they are deliberately left open.

1. **When does the M20i decision get revisited as "we DO want
   persistent collections"?** Answer probably comes from Phase
   B's actual notification path (PB2/PB3). Watch for: cases
   where mid-iteration mutation in the subscriber list causes
   real bugs vs. theoretical ones.

2. **How does Cell relax to non-Copy without breaking M20f's
   V1 contract?** This is a near-term substrate question
   (GPT-5.5 flagged it). Needs replace/take/drop semantics.
   May be a precondition for persistent collections, or may
   ship independently when an example demands it.

3. **What's the right structured-concurrency model?** Trio-style
   nurseries? Kotlin-style coroutine scopes? Go's bare
   goroutines + context.Context? This is the layer between
   reactivity and async. Worth a dedicated design checkpoint
   when Phase B is done.

4. **Should `pre` (compile-time evaluation) ever grow into a
   macro system?** Clojure-style macros operate on Forms. Rig
   doesn't have a Form-level reader — it has a grammar. A
   macro system would be a substantial design milestone.
   INFLUENCES.md flags it; no commitment.

5. **What's Rig's story for `Drop`?** Currently auto-drop fires
   via M20e defer-guards on `*T` / `~T`. User-defined Drop
   (run code at last-strong-drop on a user-defined type) is
   deferred. The `__rig_drop` runtime hook from M20h is
   already extensible to user Drop when we get there.

---

*Document version: 1.0 — 2026-05-17. Reviewed with GPT-5.5
(`c_5c1d09d53ebe2f62` entry 21). Nexis review pass: file walk
through `champ.zig` / `vector.zig` / `transient.zig` /
`gc.zig` / `CLOJURE-REVIEW.md` / `PLAN.md` (intro).*

*Companion to `SPEC.md` (language facts), `ROADMAP.md`
(commitments), `CHECKLIST.md` (milestone tracking),
`HANDOFF.md` (session-to-session continuity). When in doubt,
those four override this one. This file is "why we lean";
they are "what we do."*
