# Rig: A Master Summary

*A detailed synthesis of Rig's vision, design, surface language, semantics, compiler architecture, substrate ladder, and development history — drawn from the May 14–20, 2026 design-and-implementation chats and cross-checked against `SPEC.md`, `README.md`, `HANDOFF.md`, `docs/INFLUENCES.md`, and `docs/ROADMAP.md`.*

---

## 1. What Rig Is

Rig is a systems programming language that compiles (transpiles) to Zig 0.16. Its identity is captured in one line the project uses internally: **"Zig-fast, Rust-safe, Ruby-readable."** It fuses:

- **Zig-level performance** — no VM, no GC, no runtime scheduler; Rig emits Zig source and inherits Zig's optimizer, LLVM backend, cross-compilation, and ABI handling.
- **Rust-inspired ownership safety** — moves, borrows, clones, drops, reference-counted shared/weak handles, and RAII-style deterministic cleanup, all statically checked.
- **Ruby/Rip-style surface elegance** — whitespace-sensitive indentation instead of braces, paren-less calls, short three-letter keywords (`fun`, `sub`, `pre`, `raw`, `new`, `pub`).
- **A Lisp-shaped compiler core** — the entire IR is a normalized S-expression tree, emitted directly by grammar actions.

The language is built around **two complementary invariants** — "the thesis" — against which every feature is graded:

1. **Important effects are visible directly in the syntax.** Ownership transfer, borrowing, cloning, dropping, shared/weak handles, failure propagation, compile-time specialization, closure capture modes, and the raw-escape boundary each have an explicit, short marker. No inferred ownership transfers, no hidden refcount bumps, no silent compile-time evaluation, no unmarked unsafe regions.

2. **Visible source effects survive as visible semantic Tags through lowering.** Every syntactic effect emits as a first-class IR node — `(move src)`, `(clone src)`, `(drop x)`, `(propagate expr)`, `(raw_block body)` — that the checkers and the Zig emitter consume *by name*. Tools reading the IR see the same facts the compiler does, without speculation.

A memorable formulation from the later chats: **"Rust optimizes for correctness through rigor. Rig optimizes for correctness through visibility."** And on AI-tooling relevance: *"Rig is not trying to make AI infer what code means. It is trying to make the language carry the facts AI usually has to guess"* — while explicitly refusing to market itself as "the AI language" (a locked non-goal).

---

## 2. Origin and Vision

Rig was born on **May 14, 2026**, when Steve asked for "a new language that transpiles to Zig," implemented in Zig 0.16, built on two of his sister projects:

- **Nexus** — a self-hosting LR parser generator that emits a single self-contained Zig module from a `.grammar` file, with grammar actions that emit S-expressions directly (no separate AST types).
- **Zag** — a prior effort whose grammar was "Rip syntax over Zig semantics" (Rip itself being Steve's CoffeeScript-to-JS language, the aesthetic ancestor).

The founding brief had seven points: a beautiful syntax amalgamating Zig, Rust, Ruby, Python, JavaScript, Java, Kotlin, Clojure, and Lisp; Zig's raw speed and toolchain; Rust's safety; Ruby/Python elegance; the expressive power of S-expressions; Nexus's lexer/rewriter/parser machinery; and the new capabilities of AI-assisted development. A key early strategic decision: **Zag's surface was adopted wholesale as the "V1 substrate"** (control flow, `defer`/`errdefer`, `extern`/`pub`, `@builtin`, indentation handling), with Rig's novel ownership layer added on top. `SPEC.md` was framed as the *novel semantic layer*, not a complete language description.

In roughly 36 hours the project went from an empty repo to a working compiler with a type checker, ownership checker, generics, and modules (352 tests). Six days later it stood at **1,145+ tests passing** with a complete ownership/resource substrate and a running userland reactive library.

---

## 3. The Surface Language

### 3.1 The nine-sigil ownership algebra

The core of Rig is a set of unary, value-attached sigils — deliberately "visually distinct and emotionally intuitive." From `SPEC.md`:

```
<x       move ownership
?x       read borrow
!x       write borrow
+x       clone/copy
-x       drop/end ownership
*x       shared strong ownership (Rc)
~x       weak reference
@x       pinned/stable address     (RESERVED for V2; sema rejects in V1)
%x       raw access                (requires a `raw` block)
```

The cost story (the canonical answer to "you only have RC types?"): only `*x`/`~x` involve refcounting, and only when you opt in. `?x`/`!x` **are** Rig's plain lifetime-checked pointers — statically verified by the ownership checker with zero runtime cost, lowering to plain Zig. `<x` moves are compile-time-only ownership transfer. `%x` inside a `raw` block gives the full unchecked pointer/FFI surface. The default idiom — owned values, borrows, explicit moves — has the same cost shape as Rust/Zig.

| Sigil | Runtime cost | Rust analog |
|---|---|---|
| `<x` move | none (bookkeeping is static) | move / `std::move` |
| `?x` read borrow | zero, statically checked | `&T` |
| `!x` write borrow | zero, statically checked | `&mut T` |
| `+x` clone | type-defined; refcount bump for shared | `Clone::clone` |
| `-x` drop now | one destructor call | `drop(x)` |
| `*x` shared | Rc allocation; explicit clones bump a non-atomic V1 refcount | `Rc::new` / `.clone()` |
| `~x` weak | weak-count bump | `Rc::downgrade` |
| `%x` raw | zero — raw pointer, inside audit boundary | `*const T` / `*mut T` |

### 3.2 The `?`/`!` triangle

A landmark day-two design cleanup resolved a collision between fallible returns and write borrows. The resolution gives every spelling exactly one positional meaning:

```
?x / !x   prefix on expression  →  read / write borrow
?T / !T   prefix on type        →  read / write-borrowed parameter
T?        suffix on type        →  optional T
T!        suffix on type        →  fallible T
expr!     suffix on expression  →  propagate failure
expr?     RESERVED (future optional-propagation)
```

So `fun load(id: Int) -> User!` declares fallibility as a type, and `user = load(1)!` propagates it visibly at the call site (lowering to Zig `try`). One casualty: Ruby-style predicate names (`valid?`) were dropped because they collide with `Bool?`; the convention is `is_valid`.

### 3.3 Keywords, bindings, and shape

- `fun` — function that returns a value; `sub` — routine that doesn't. `pre` replaces Zig's `comptime` (compile-time execution/specialization). `raw` marks the unsafe escape block. `pub` controls cross-module visibility; `new x =` is explicit shadowing.
- Bindings: `=` (mutable), `=!` (fixed/immutable), `x <- y` as sugar for `x = <y` (ownership visually flows leftward).
- Blocks are indentation-based. `print` (V1: single-argument) is paren-less in unary form: `print "hello, rig"`.
- Ownership-aware iteration: `for x in ?xs` (borrow), `for x in <xs` (consume); resource-element Vecs *require* the `?` source borrow.

A complete flavor sample (the README's third-tier example, verified to run):

```rig
struct Owner
  cell: *Cell(Int)

  drop self: !Owner
    print(self.cell.get())

sub main()
  c: *Cell(Int) = *Cell(value: 42)
  o: Owner = Owner(cell: <c)
  print(0)
```

Output is `0` then `42`: lexical scope exit runs the user `drop` (which reads the cell), then structural glue releases the `*Cell` refcount. No GC, no finalizer queue.

### 3.4 Types, methods, generics, pattern matching

- Structs, enums, error sets, payload-bearing enum variants, exhaustive `match` with destructuring, range patterns, and value-position `if`/`match` expressions all shipped in the first two days (M6–M18).
- Instance methods declare their receiver mode visibly: `fun greet(self: ?User)` (read; auto-borrowed at the call site), `sub modify(self: !User, n: String)` (write; the caller must write `(!u).modify(...)`), `sub consume(self: User)` (by value; `(<u).consume()`). Sugar `?self` / `!self` exists for the receiver only. A locked rule: **auto-`?` only, never auto-`!`** — write borrows are a core visible effect and are never inserted silently.
- Generics use parenthesized type parameters (`type Box(T)`, `enum Option(T)`), with expected-type-driven constructor checking (`b: Box(Int) = Box(value: 42)`). Generic enums lower to idiomatic Zig `pub fn Option(comptime T: type) type { return union(enum) {...} }`. `Option(T)`/`Result(T, E)` are ordinary generic enums, not compiler magic.

### 3.5 Closures and capture modes

Closure literals are bare bars with **explicit capture modes** — the direct application of the visible-effects thesis to captures:

```
|x|  body     capture by copy (Copy types only)
|+x| body     capture by clone (refcount bump for *T)
|~x| body     capture weakly (requires an outer *T; binds ~T)
|<x| body     capture by move (outer binding invalidated)
```

Multi-capture (`|+a, +b|`) shipped in M28. Bare lambdas are strictly **non-escaping**; the only escaping shape is heap-owned construction, `*Closure(|+count| body)`, which produces an ordinary `*T` handle — clonable, moveable, weakable, returnable, dropped exactly once on last strong release. Capturing a resource with the default `|x|` mode is rejected: the programmer must choose `+`/`~`/`<`. Captured resources are non-consumable inside the body (no `<cap`, `-cap`, `return cap`) because retained subscribers are invoked repeatedly — a use-after-free class caught and closed during Phase B. Arity-bearing closures (`Closure1(T)`, `Closure2(A, B)`, Copy args, void returns) landed in M24; as of the final chat Steve had design-locked a nicer unified-bars replacement (`cb: *sub(Int) = *|+v, a| v.set(a)`) as the next arc.

### 3.6 The raw boundary and FFI

Rig's escape hatch went through a deliberate arc: an `unsafe` keyword (block + function modifier) shipped first, then M22 renamed it **`raw` and made it block-only** — one IR tag, one checker state, structurally eliminating a discovered state-leak bug class. Inside a `raw` block you get `%x` raw access and Zig's full unsafe surface; outside, `@builtin(...)` is default-unsafe with an eight-entry safe whitelist (`@sizeOf`, `@alignOf`, `@TypeOf`, `@typeName`, `@hasDecl`, `@hasField`, `@len`, `@This`). `extern` declarations (body-less `extern fun puts(s: String) -> Int` since M23) are raw-by-default at call sites. The `raw` block is an **audit boundary, not a performance ceiling** — the generated code is just Zig pointer code. As one independent AI conversation put it, converging with Rig's choice: "unsafe is a warning label; raw is a mode."

---

## 4. The Semantic Model

### 4.1 Ownership and borrows

The M2-era checker enforces the classic discipline: use-after-move, write-while-read-borrowed, read-while-write-borrowed, use-after-drop, fixed-binding reassignment, and borrow-escape (returning a borrow of a local) are all compile errors with source-pointed diagnostics. Refinements: *temporary* borrows (`print ?user`) end at statement end, while *bound* borrows (`r = ?user`) persist to scope exit; branch snapshot/merge handles `if` arms; primitives are Copy and exempt from move/drop tracking.

### 4.2 Shared ownership, weak handles, auto-drop

`*T` is a real single-threaded `Rc`: `*expr` **moves** the value into a heap `RcBox(T)` (write `*(+x)` to keep the original); `+rc` bumps the strong count; `~rc` derives a weak handle; `w.upgrade()` returns `(*T)?` (a method, not a sigil — see §7). **Cycles leak by default**, exactly like Rust's `Rc`. The alias-footgun rule is central: bare `rc2 = rc` or passing a handle bare is rejected — you must `+` clone, `<` move, or `-` drop. Automatic cleanup (M20e) is implemented not with a compiler-built drop elaborator but with **Zig `defer` guards**:

```zig
var __rig_alive_rc = true;
defer if (__rig_alive_rc) { __rig_alive_rc = false; rc.dropStrong(); };
```

Explicit drops, moves, and returns disarm the guard; Zig's `defer` handles early returns, branches, and error paths path-sensitively. `*T` auto-deref is **read-only** — mutation through a shared handle requires interior mutability.

### 4.3 Interior mutability, user Drop, and the non-Copy rule

- `Cell(T)` provides interior mutation through shared handles (`rc.set(5)`, `rc.get()`), visible at the call site. M26 extended Cell to non-Copy resource `T`: `set(<new)` drops the old value first; `replace(<new) -> T` swap-and-yields; `get()`/`.value` are rejected for drop-glue `T` (would alias a resource into a double-free).
- **User-defined Drop (M25)** — `drop self: !Self`, exactly one per plain struct, no params/return/fallibility. The compiler *also* auto-generates structural drop glue for any struct with resource fields (user body first, then fields in reverse declaration order, Rust-style). Drop bodies cannot consume `self` or race the structural walk (`<self.field`, resource-field reassignment rejected).
- The load-bearing cross-cutting rule: **any type with drop glue is non-Copy.** Bare alias/assignment/call-arg of such values is rejected at the ownership layer; `<x` move is the only V1 multi-binding shape. Corollary (M26.1): a discarded resource-typed expression-statement is a leak and is rejected.

### 4.4 Resource-aware containers and the reactive substrate

- `Vec(T)` is itself a resource **value** (it owns a buffer even for Copy elements): bare copy is rejected as would-double-free; push of resource elements requires explicit `+`/`<`; drops cascade through a comptime `dropElement` dispatch. Iteration is `for x in ?vec` with the element bound as a read borrow of the slot.
- `Signal(T)` (Copy `T`, heap-owned `*Signal(T)` only) is the one trusted reactive primitive: `subscribe(+closure)`, synchronous `set`-notify, multi-subscriber, with the PB4 reentrancy policy — reentrant `set` queues and coalesces to the latest value; reentrant `subscribe` panics.
- Everything above Signal — `Reactor`, `Memo`, `Effect`, batching, topology — is **locked as userland library work**, matching the Rust/Zig position. The proof is the canary chain: `rig-reactive` v0 (a monomorphic `IntSource` with subscribe/set/notify built from `*Cell(Vec(*Closure()))`) runs end-to-end, including the cross-source cascade:

```rig
sub main()
  count = IntSource.new(0)
  total = IntSource.new(0)

  body_a: *Closure() = *Closure(|+count, +total|
    total.set(count.get() * 10))
  count.subscribe(+body_a)

  body_b: *Closure() = *Closure(|+total| print(total.get()))
  total.subscribe(+body_b)

  count.set(1)         # total becomes 10, prints 10
  count.set(7)         # total becomes 70, prints 70
```

That `*Cell(Vec(*Closure()))` shape is deliberately explicit — it is Rust's `Rc<RefCell<Vec<Box<dyn Fn()>>>>` with every effect on the surface, meant to be wrapped by libraries and, eventually, Phase C sugar (Rip's `:=` / `~=` / `~>`), which is deferred and will never be core language.

### 4.5 Honesty invariants

Two floor-raising campaigns produced language-wide guarantees:

- **No fake surfaces (M22.1):** every accepted V1 form has enforced semantics and working lowering, OR a clean "reserved" sema rejection. No emit-time placeholder errors. Currently reserved: `@x` pin, `for *x`, `pre` block/expr forms, value-`try` blocks, `zig "..."`.
- **Module honesty (M15b/M15b.1/M15b.2):** cross-module references carry the same checked contracts as same-file code — fallibility, arity, borrow modes, visibility. `pub` is real; nominal identity carries origin (`a.Box ≠ b.Box`); public APIs cannot leak private types; `unknown` may exist only as poison after a diagnostic, never as silent success; every unbound name errors at sema time.

---

## 5. Compiler Architecture

```
Rig source
  → BaseLexer (Nexus, regex) → Lexer (hand-written token rewriter, src/rig.zig)
  → BaseParser (Nexus LALR, grammar actions emit S-expressions directly)
  → normalized semantic IR (S-expressions; effects as first-class Tags)
  → sema        (src/types.zig — SymbolResolver, TypeResolver, ExprChecker, type interner)
  → effects     (src/effects.zig — fallibility, raw-context, extern-call enforcement)
  → ownership   (src/ownership.zig — move/borrow/clone/drop/capture checking)
  → emit        (src/emit.zig — Zig 0.16 codegen)
  → zig build   → native binary
```

Distinctive machinery:

- **The classification cascade.** The lexer rewriter uses adjacency, spacing, and prior-token context to split one character into distinct tokens (`star` vs `share_pfx`, `question` vs `suffix_q`, `ident` vs `kwarg_name`), keeping the grammar LALR-clean. The kwarg syntax `Type(name: value)` would have exploded parser conflicts 21→200; a lexer-level `kwarg_name` token solved it with zero.
- **Grammar as source of truth.** `rig.grammar` declares both syntax and IR shape; each rule's action emits a specific node (`(fun_type 3 5)`, `(lambda captures params returns body)`, `(set <kind> name type expr)`). `src/parser.zig` is generated (`zig build parser`) and never hand-edited. The conflict count is a build-breaking contract (`@conflicts = 75`, all reviewed benign shift/reduce).
- **Uniform IR doctrine**, born from Steve's pushback on `for_read`/`for_write`/`for_move` fragmentation: one head Tag with the variant as a child slot; `_` (nil) for absence; underscored Tag names are a smell. A one-line silent-drop bug Steve insisted "SHOULD already work" was found and fixed *in Nexus itself*, letting the grammar emit fully normalized IR directly.
- **The runtime** (`src/runtime.zig`, ~510 lines, shipped as a Zig string constant written as a sibling `_runtime.zig`): `RcBox(T)` (strong/weak counts, `__rig_drop` last-strong hook), `WeakHandle(T)`, `Cell`, `Closure0`/`Closure1`/`Closure2` (type-erased `ctx`/`invoke_fn`/`drop_fn` vtables), `Vec` (with `dropElement` dispatch), and `Signal`.
- **CLI:** `bin/rig parse | normalize | check | build | run`.
- The emitter is deliberately "dumb": an early version auto-inserted `try` at fallible call sites and was ripped out as a thesis violation — safety lives in the checkers, not in codegen cleverness.

---

## 6. The Substrate Ladder

The conceptual map ordering all V1 work (`docs/INFLUENCES.md` §1) — each layer a prerequisite for those above:

| # | Layer | Milestones | Status |
|---|---|---|---|
| 0 | Static types + grammar | M0–M5 | ✅ |
| 1 | Ownership / borrow checking | M2, M20a–c | ✅ |
| 2 | Resource lifetimes (Rc/Weak/auto-drop) | M20d, M20e | ✅ |
| 3 | Interior mutability (`Cell(T)`) | M20f | ✅ |
| 4 | Closure captures with explicit modes | M20g | ✅ |
| 5 | Stored callable state (heap-owned closures) | M20h | ✅ |
| 6 | Resource-aware containers (`Vec(T)`) | M20i | ✅ |
| 7 | Reactivity substrate (`Signal`) | PB2–PB4 | ✅ |
| 7.5–7.8 | User Drop, Cell-non-Copy, auto-deref, multi-capture | M25–M28 (+M29/M30) | ✅ |
| 8 | Structured concurrency | — | deferred |
| 9 | Async | — | deferred |

The ladder embodies the project's deepest external lesson, distilled from Rust's async success and Zig's async retreat: **async is fundamentally about storing partial execution safely** — suspended state, ownership of that state, resumption safety, cancellation safety. Rust unified those through `Future` + the borrow checker; Zig shipped coroutines without the ownership foundation and had to retreat. Rig's plan is to not "solve async" as a feature but to let it fall out of the substrate: ownership → reactivity → structured concurrency → async, in that order. M20h's heap-owned closure is explicitly understood as the *zero-suspension-point case* of stored partial execution (`Closure0.ctx` ≈ frame pointer, `invoke_fn` ≈ poll, `drop_fn` ≈ cancellation).

Rig has **no user-written lifetime parameters**. The safety questions Rust answers with `'a` are distributed across borrow validity (checker), refcount lifetime (RcBox), and scope-exit cleanup (defer guards) — keeping the "succinct" goal intact until reactivity/async pressure proves more is needed.

---

## 7. Development History, Chronologically

**Chat 1 (May 14–15) — Founding.** Empty repo → 352 tests. Grammar + rewriter + generated parser (M0), semantic normalizer (M1), ownership checker with all seven SPEC cases (M2), Zig emitter + CLI (M3/M4), a hardening pass after a GPT-5.5 audit found nine critical bugs (M4.5), then the type system sprint: real sema (M5), structs (M6), enums/error sets (M7), match (M8), payload variants (M9), destructuring + exhaustiveness (M10), qualified enum access (M11), struct methods (M12), range patterns (M13), generics (M14), modules with cycle detection (M15), robustness incl. a real segfault fix (M16), if/match-as-expression (M17/M18), typed mutable bindings (M19). The `?`/`!` triangle was settled here, as was the "one head Tag" IR doctrine.

**Chat 2 (May 15–16) — Reactivity as forcing function; methods and generics.** 352 → 496 tests. Steve asked whether Rip's reactivity (`:=`, `~=`, `~>`) could live in Rig; the analysis (with GPT-5.5 catching three load-bearing errors — Cell needs interior mutability rather than a dishonest `!` borrow; dependents hold strong refs while dependencies hold weak back-edges; closures need explicit capture modes) produced `docs/REACTIVITY-DESIGN.md` and the Phase A/B/C plan: design note now, library later, sugar never-core. Implementation: instance methods + `self` semantics (M20a), `?self`/`!self` sugar (M20a.1), receiver soundness hardening (M20a.2), real generic-instance member typing (M20b, five sub-commits; GPT-5.5 blocked the commit with five findings), generic enums `Option(T)`/`Result(T,E)` (M20c). `HANDOFF.md` was created as the session-handoff artifact.

**Chat 3 (May 17, small) — Context.** A Ziggit forum thread about Bun's AI-generated 4× Zig-compile-time speedup and Zig's no-AI-code upstream policy — directly relevant to Rig's own toolchain and its openly AI-assisted methodology.

**Chat 4 (May 16–17) — The resource substrate.** 496 → 648 tests. Real `Rc`/`Weak` for `*T`/`~T` with the alias-footgun rejection and read-only auto-deref (M20d, M20d.1); the `^` upgrade-sigil debate resolved to a method (M20d.2); auto-drop via Zig defer guards, replacing a proposed mini-MIR drop elaborator (M20e, with M20e.1 fixing a double-drop UAF and a move-assign segfault); `Cell(T)` interior mutability, Copy-only for now (M20f); closure-capture grammar foundation (M20g 1/5).

**Chat 5 (May 17 morning) — Captures complete, Phase B opens.** 648 → 706. M20g finished (sema/ownership/emit/guards/docs): closures lower to anonymous Zig structs with capture fields and an `invoke` method; strict non-escaping rules. PB0 reactive canary scaffolded. The M20h design was locked after GPT-5.5 **caught a use-after-free in the proposed ABI** — leading to the type-erased `Closure0` vtable + `RcBox.__rig_drop` last-strong hook design.

**Chat 6 (May 17 evening, small) — The strategy digest.** Steve's ChatGPT conversation on Rust async, Zig's retreat, and Clojure was distilled: the stored-partial-execution framing; the meltdown-risk analysis (hidden magic, async complexity, semantic inconsistency); the strategic rule **"Do not add features. Unify effects"**; and the Clojure shopping list (immutability discipline and persistent collections yes — as stdlib; STM no, or much later).

**Chat 7 (May 17, ~10 hours) — Escaping closures, Vec, Signal.** 706 → 804. M20h owned closures shipped end-to-end (including a grammar fight where the naive lambda-body rule exploded conflicts 38→227, solved with a narrow inline-body production at 69). `docs/INFLUENCES.md` written, including the substrate ladder — with GPT-5.5 deflating two overstatements and the "Primacy of Rig's own goals" clause added at Steve's calibration. M20i resource-aware `Vec(T)` (GPT-5.5's key insight: Vec is itself a resource value). PB2 single-subscriber `Signal(T)`. HANDOFF rewritten with the "First 3 minutes" and "Non-negotiable invariants" sections.

**Chat 8 (May 17–18, marathon) — Phase B complete; raising the floor.** 804 → 982. Resource-Vec iteration `for x in ?vec` (M20i.1 — GPT-5.5 rejected an internal `foreach` callback in favor of the external form). Multi-subscriber Signal with the R2 reentrancy policy, preceded by the captured-resource consumption audit that closed a real UAF (PB3). Then the pivotal strategic exchange: Steve's *"Rust nor Zig support reactivity, do they???"* led GPT-5.5 to reverse its own `Reactor`-builtin recommendation — PB4 locked the **library/substrate boundary** (reentrant-set queueing; no more reactive builtins). Then the credibility arc: `unsafe` boundary (M21), the `unsafe`→`raw` block-only simplification (M22), the fake-surface audit fixing a real anonymous-temporary leak and retracting five unenforced surfaces (M22.1), and cross-module sema honesty (M15b, M15b.1) — which incidentally uncovered that `raw` blocks had been silently skipping all checks.

**Chat 9 (May 19, small) — The cost-grid defense.** Produced the canonical answer to the "only RC types?" performance challenge (§3.1 above) and slotted a "Performance model" section into the README.

**Chats 10–11 (May 18–20) — Identity, Drop, and the `fn` extinction.** 982 → 1,149. The "ideal code representation in the AI age" discussion crystallized Rig's AI-era positioning and produced `AGENTS.md`, the semantic-Tags invariant text, the `rig sema --json` V1.x tooling plan (export before graph projections), and the explicit non-goal of AI-language marketing. Shipped: private-type-leak rejection (M15b.2); user-defined Drop with structural glue and the non-Copy rule (M25/M25.1); Cell-non-Copy + `replace` (M26/M26.1); the rrlib v0 canary, which — exactly as designed — exposed M27 (auto-deref through member access) and M28 (multi-capture closures), completing the cascade canary. Steve then drove the syntax cleanup: M29 dropped `fn` from closure literals (bare bars), M30 folded function-type `fn(...)` into `fun(...)` — `fn` is extinct in Rig. M23 (body-less extern) and M24 (arity closures) closed the FFI/callback gaps, though Steve rejected M24's construction syntax and design-locked a unified-bars replacement (`*|+v, a| v.set(a)` with `sub(Int)` types) as the next arc. In parallel: the README's progressive-disclosure examples (hello → borrow → drop), `FAQ.md` for hostile questions, doc renames (`IR.md`, `REACTIVITY.md`), deletion of the stale Zag-inheritance doc, and a six-pass audit of all ~14K lines of docs (~70 fixes) so the documentation matches the implementation.

---

## 8. The Methodology (a defining feature of the project)

Rig was built under a **non-negotiable cadence**, later codified in `AGENTS.md`:

```
GPT-5.5 design checkpoint (user-ai MCP, conversation c_5c1d09d53ebe2f62)
  → 3–5 sub-commits, M5-style numbering: Mxx(n/total)
  → post-implementation review (GPT-5.5)
  → commit (all tests passing at every sub-commit)
```

This is not ceremony — the peer review caught genuine correctness bugs in essentially every arc: the UAF in M20h's proposed closure ABI, the `in_set_rhs` escape-rule leak, the M20e reassignment double-drop, the emit reverse-scan fragility in Vec iteration, the captured-resource consumption UAF before PB3, the `pending_fn_unsafe` state leak in M21, the anonymous-resource-temporary leak in M22.1, and more. Steve's steering style — short, sharp challenges ("Why are these all so different?", "Is that the best example?", "Did that unsafe context sort of suck?", "Rust nor Zig support reactivity, do they???") — repeatedly redirected the design at exactly the right moments, and several of the language's best decisions trace directly to those interventions.

The canary discipline is the other methodological pillar: **the library is the canary; if it doesn't compose, fix the language.** rrlib v0 was intentionally kept ugly because its job was to reveal substrate gaps — and it revealed exactly two (M27, M28), both fixed in the language rather than papered over in the library.

---

## 9. Notable Debates and Rejected Ideas

- **`^x` upgrade sigil** — rejected: every sigil is a *total* transformation; upgrade can fail, so it's a method (`w.upgrade() -> (*T)?`). Sigils = total transformations; methods = operations with logic.
- **`Reactor`/`Memo`/`Effect` as builtins** — GPT-5.5 initially proposed, then reversed after Steve's challenge: userland, locked at PB4.
- **Auto-inserted `try`** — ripped out as a thesis violation.
- **Persistent CHAMP collections first** — rejected: they work in Steve's Nexis (Clojure-on-Zig) *because Nexis has a GC*; Rig never will. Conditional stdlib item, later.
- **STM** — "a complexity magnet"; library at most, much later.
- **`unsafe fn` modifier** — dropped in favor of block-only `raw` (a real expressivity trade, documented, accepted to eliminate a bug class).
- **`fun`-reuse for lambdas, `lam`, `pro`** — rejected in favor of bare bars.
- **Predicate `?` names, `:tag` sigils in Nexus, the "sexer" naming** — all rejected (the last one "not worth the extra smirk").
- **Macro system in V1** — no; `pre` plus library design covers the use cases.
- **AI-language marketing** — locked non-goal: visible effects help AI tooling as a *byproduct* of designing a serious systems language for humans.

---

## 10. Where Rig Stands

As of the end of the covered period: **1,145–1,149 tests passing, 0 failing**, on `main`. The substrate ladder Layers 0–7.8 are complete; the reactive cascade canaries run end-to-end; every accepted surface form is enforced or cleanly reserved; cross-module contracts are honest; the docs match reality. The grammar sits at 75 reviewed-benign conflicts. The forward menu:

- **Category A (cleanup):** legacy global name-scan retirement; the unified-bars closure syntax redesign.
- **Category B (extensions):** Layer 8 structured concurrency, Phase C reactive sugar, `pre` AST extraction, conditional persistent collections — with async (Layer 9) deliberately last, downstream of cancellation discipline, poll/wake ABI, and pin.
- **Category C (tooling):** `rig sema --json` v0, the stable versioned semantic export that turns the IR invariant into an external contract.

The closing self-assessment from the strategy chat remains the best one-line risk statement: Rig survives if it stays **"a coherent semantic system"** rather than becoming "a collection of cool features" — and its best evidence so far is that its features keep *lowering* complexity: one sigil algebra, one ownership story, one effect story, one lowering philosophy.
