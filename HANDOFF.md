# Rig — Session Handoff (M20d Implementation)

**You are picking up a Rig compiler session in mid-arc.** This document
captures everything you need to continue cleanly. Read top-to-bottom
once; then it's a reference.

---

## TL;DR

- **Project**: Rig is a systems language ("Zig-fast, Rust-safe, Ruby-readable")
  that compiles to Zig 0.16. Repo: `/Users/shreeve/Data/Code/rig`.
- **Where we are**: Just shipped **M20c** (generic enums — `Option(T)`,
  `Result(T, E)`). Last commit: `21b6ba3`. **496 tests passing, 0 failing.**
  Clean tree on `main`, all pushed.
- **Next milestone**: **M20d** — real `*T` / `~T` `Rc` / `Weak` semantics.
  Design is locked (with GPT-5.5 review); implementation hasn't started.
- **Owner**: Steve (`shreeve@github`). Collaborates with you AND consults
  GPT-5.5 for design checkpoints + post-implementation reviews.
- **Established cadence**: design checkpoint → implement in 3–5 sub-commits
  (M5-style: `Mxx(n/total)`) → post-implementation review → commit. Each
  sub-commit must keep all tests passing.

---

## 1. Project orientation (read these first)

Authoritative project docs, in order of importance:

| File | Purpose |
|---|---|
| `SPEC.md` | Language spec. Ownership sigils, `?/!` triangle, V1 scope, etc. |
| `docs/ROADMAP.md` | Milestone history (M0–M20c done). M20+ "now-blocking" list at the bottom. |
| `docs/REACTIVITY-DESIGN.md` | Substrate design note. The forcing function for M20+ work. |
| `docs/SEMANTIC-SEXP.md` | Sema IR shape. What the grammar emits, what the checker walks. |
| `docs/INHERITED-FROM-ZAG.md` | Grammar/lexer surface inherited from the Zag/Nexus stack. |
| `rig.grammar` | Nexus grammar. Conflict count currently **34** — verify after any grammar edit. |

Codebase highlights:

| File | Role |
|---|---|
| `src/rig.zig` | Lexer rewriter + Tag enum. Add new IR tags here. |
| `src/parser.zig` | **Generated** by `zig build parser` from `rig.grammar`. Don't edit by hand. |
| `src/types.zig` | Sema: SymbolResolver, TypeResolver, ExprChecker, Type interner, lookup helpers. ~5000 lines. |
| `src/emit.zig` | Zig codegen. ~2200 lines. |
| `src/ownership.zig` | M2-era borrow/move checker. Less touched recently. |
| `src/effects.zig` | Fallibility (`T!`) checker. Subordinate to sema. |
| `src/modules.zig` | Multi-file projects via `use foo`. M15. |
| `src/main.zig` | CLI driver: `parse`/`normalize`/`check`/`build`/`run`. |
| `build.zig` | Build steps. `zig build`, `zig build parser`, `zig build test`. |
| `test/run` | Test driver. `./test/run` to verify; `./test/run --update` to regenerate goldens. |
| `examples/*.rig` | Source-form test inputs. Auto-discovered by `test/run` for raw_sexp/semantic_sexp/errors goldens. |
| `test/golden/{raw_sexp,semantic_sexp,errors,emitted_zig}/*.{sexp,txt,zig}` | Goldens. |
| `EMIT_TARGETS` in `test/run` | Names of `examples/` to run end-to-end (emit + ast-check + actual `bin/rig run`). |

---

## 2. M20+ status (the big picture)

| # | Item | Status | Where |
|---|---|---|---|
| 1 | Instance methods + `self` semantics + receiver-style calls | ✅ | M20a + M20a.1 + M20a.2 |
| 2 | Real generic-instance member typing | ✅ | M20b(4/5) |
| 3 | Generic methods on generic types | ✅ | M20b(4/5) + M20b(5/5) |
| 4 | `Option(T)` / `Result(T, E)` as generic enum types | ✅ | **M20c** (just landed) |
| 5 | Methods on enums | ✅ | M20a |
| 6 | **`*T` / `~T` real `Rc` / `Weak` semantics** | ⬜ | **M20d (next — design ready)** |
| 7 | Interior mutability — `Cell(T)` library type | ⬜ | After M20d |
| 8 | Closure capture mode syntax (`|name|` / `|~name|` etc.) | ⬜ | After M20d |

Notes:
- M20d ships the substrate for #7 (interior-mutable types live behind `*T`).
- The Cell/Memo/Effect reactive sketch in REACTIVITY-DESIGN needs M20d + #7 to be fully buildable.
- `T?` / `T!` desugar to user-defined `Option(T)` / `Result(T, E)` is **strongly deferred**.

---

## 3. M20d design (DO NOT DEVIATE without re-checkpointing GPT-5.5)

Design checkpoint with GPT-5.5 is on record in conversation
`c_5c1d09d53ebe2f62` (the user-ai MCP server's persistent thread). It was
extensive and corrected several of my initial proposals. The corrected
design below is what to implement.

### Core decisions (locked)

**Type representation** (parallel to M20b's `borrow_read`/`borrow_write`):

```zig
pub const Type = union(enum) {
    ...
    borrow_read:  TypeId,
    borrow_write: TypeId,
    shared:       TypeId,   // M20d: *T — Rc<T>
    weak:         TypeId,   // M20d: ~T — Weak<T>
    ...
};
```

Add to: interner equality/hash (in `TypeStore.typeEqual`), `formatType`,
`compatible`, `substituteType`, `typeEqualsAfterSubst`, `emitType`,
`classifyReceiverType`.

For `compatible`: `*User == *User` only; `*User != User`; `~User != *User`.
**Do NOT make shared/weak wildcard-like.** Strict structural equality only.

**Grammar additions**:

```text
type = ...
     | SHARE_PFX type    → (shared 2)   # *T
     | "~"       type    → (weak 2)     # ~T
```

`SHARE_PFX` exists from the M20a-era unary rules (`*x` at expression
position). `~` is plain `"~"` operator token — verify the type-position
addition doesn't bump the conflict count above 34.

At expression position, `*Foo(...)` already parses as
`(share (call Foo ...))`. M20d sema types this as `shared(nominal(Foo))`
(was `unknown`).

**Per GPT-5.5: use distinct tag names**:
- Type-position: `(shared T)` and `(weak T)`
- Expression-position: `(share x)` and `(weak x)` already exist
- Don't reuse the exact same tag if phase walkers are position-sensitive

So new Tag entries: `shared` (type-position; distinct from existing
expression-position `share`). Note: `weak` is reused — be careful with
sema dispatch.

### Runtime: `_rig_runtime.zig` sibling file

Driver (`main.zig`) writes both `_rig_runtime.zig` and the main module
into `/tmp/rig_<name>/`. Emitted modules `@import("_rig_runtime.zig")`.

Suggested runtime shape (per GPT-5.5):

```zig
pub fn RcBox(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        strong: usize,                 // NOT u32, per GPT-5.5
        weak: usize,                   // includes implicit +1 while strong > 0
        value: T,

        const Self = @This();

        pub fn new(allocator: std.mem.Allocator, value: T) !*Self {
            const box = try allocator.create(Self);
            box.* = .{ .allocator = allocator, .strong = 1, .weak = 1, .value = value };
            return box;
        }

        pub fn clone(self: *Self) *Self {
            std.debug.assert(self.strong > 0);
            self.strong += 1;
            return self;
        }

        pub fn weakRef(self: *Self) WeakHandle(T) {
            std.debug.assert(self.strong > 0);
            self.weak += 1;
            return .{ .ptr = self };
        }

        pub fn drop(self: *Self) void {
            std.debug.assert(self.strong > 0);
            self.strong -= 1;
            if (self.strong == 0) {
                // Future: run user-defined Drop on `value` here.
                // M20d V1: no user destructors yet.
                self.weak -= 1; // release implicit weak
                if (self.weak == 0) self.allocator.destroy(self);
            }
        }
    };
}

pub fn WeakHandle(comptime T: type) type {
    return struct {
        ptr: ?*RcBox(T),

        const Self = @This();

        pub fn clone(self: Self) Self {
            if (self.ptr) |p| p.weak += 1;
            return self;
        }

        pub fn drop(self: *Self) void {
            if (self.ptr) |p| {
                std.debug.assert(p.weak > 0);
                p.weak -= 1;
                if (p.weak == 0 and p.strong == 0) p.allocator.destroy(p);
                self.ptr = null;
            }
        }

        pub fn upgrade(self: Self) ?*RcBox(T) {
            const p = self.ptr orelse return null;
            if (p.strong == 0) return null;
            p.strong += 1;
            return p;
        }
    };
}

pub fn defaultAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

pub fn rcNew(value: anytype) !*RcBox(@TypeOf(value)) {
    return RcBox(@TypeOf(value)).new(defaultAllocator(), value);
}
```

**Per GPT-5.5: store the allocator in the box.** No mutable global. The
runtime helper `rcNew(anytype)` lets emit avoid needing expression-type
info for `*expr`.

### Operator lowering

```text
*expr        → rig.rcNew(expr) catch @panic("Rig Rc allocation failed")
+rc          → rc.clone()
-rc          → rc.drop()                  # statement-only
~rc          → rc.weakRef()
+w (weak)    → w.clone()
-w (weak)    → w.drop()                   # statement-only
<rc          → move handle; no runtime call (sema-only ownership transfer)
w.upgrade()  → returns ?*RcBox(T)   →   Rig type `optional(shared(T))` i.e. `*T?`
              **NOT** user-defined `Option(*T)` yet
```

**Per GPT-5.5: `*expr` CONSUMES `expr` into the Rc.** If the user wants to
keep `expr`, they write `*(+expr)` (explicit clone then move into Rc).
Otherwise `*x` duplicates ownership of `x` — a bug.

**OOM policy**: `*expr` panics (Rust-style). Runtime primitive `rcNew(...)`
returns `!*RcBox(T)` for future recoverable-allocation APIs.

### Auto-deref: READ-ONLY ONLY (the big design point)

**This is the architectural correction from GPT-5.5's design review.** The
ergonomic temptation is to let `rc.method()` work for all receiver modes —
DO NOT do that.

`*T = Rc<T>` is shared. You can get a read view of `T` but you CANNOT get:
- `!T` (unique mutable borrow) — other handles may exist
- `T` (by-value / consuming) — other handles may exist

Rules:

```text
*T auto-deref ALLOWS:
  rc.field             (read field access)
  rc.method()          where method takes ?self

*T auto-deref REJECTS:
  rc.write_method()    where method takes !self
  rc.consume_method()  where method takes self (by-value)
  !rc.field = X        field assignment through shared handle
```

Diagnostic example:
```
cannot call write-receiver method `rename` through shared handle `*User`;
use an interior-mutable type
```

Implementation: extend `checkReceiverMode` to accept a new
`ReceiverTypeKind.shared` and reject `.write` / `.value` receivers
against it. Mirror of M20a.2's consume-through-borrow rejection but
for the shared case.

**For mutation through `*T`, users will need interior mutability**
(M20+ item #7 — `Cell(T)` library type). `Cell.set` will take `?self`
(read borrow) and internally do controlled `unsafe` mutation. M20d
ships the substrate; #7 ships the user-facing pattern. Together they
unlock the reactive sketch in REACTIVITY-DESIGN.

**For weak handles, do NOT auto-deref.** Weak handles require explicit
`.upgrade()`.

### Helper extensions

- Extend `lookupDataField` to peel `shared` for the read-only field
  access path. Per GPT-5.5: **add a separate helper** for read-only
  unwrap rather than broadly modifying `unwrapBorrows`. Suggestion:
  `unwrapReadAccess(ctx, ty_id)` peels `borrow_read` + `borrow_write` +
  `shared` (NOT `weak`, NOT `optional`/`fallible`).
- Extend `lookupMethod` similarly; combined with the receiver-mode
  rejection above, this lets method calls go through the helper but
  fail correctly on write/consume receivers.
- Add `nominalSymOfReceiver` already handles peeling for diagnostics —
  audit whether it should peel `shared` too. Probably yes.

### Drop discipline (OPEN QUESTION — needs Steve)

**Status: UNRESOLVED.** Two valid approaches:

**A) Explicit-`-x`-only (V1 minimum):**
- `-rc` and `-w` decrement counts
- Without explicit `-x`, handles leak at scope exit
- Document loudly in SPEC + ROADMAP
- Smaller scope; less new machinery
- Honest about what Rig V1 does

**B) Automatic scope-exit drop:**
- Compiler inserts `-x` at scope exit for any `*T` / `~T` binding not
  moved out
- Matches Rust RAII expectations
- Requires extending `ownership.zig` (or a new pass) to emit synthesized
  drop nodes for shared/weak bindings
- Bigger scope; closer to actual Rc<T> semantics users expect
- Risk: subtle double-drop / use-after-free bugs if ownership tracking
  is off (GPT-5.5 specifically flagged this as a hazard class)

**Decision required from Steve before M20d(4/5) or M20d(5/5).** If (B),
add it as a dedicated sub-commit (M20d's plan becomes 6 commits, not 5).

GPT-5.5's recommendation: do (B) eventually, but (A) is acceptable for
V1 if documented honestly. Don't silently imply Rust RAII if Rig doesn't
emit it.

### What's IN vs OUT

**IN (M20d):**
- Type variants + grammar
- Runtime file (`_rig_runtime.zig`) + driver integration
- Operator emit for `*expr`, `+rc`, `-rc`, `~rc`, `+w`, `-w`
- Read-only auto-deref (field + `?self` method)
- Receiver-mode rejection for write/consume through `*T`
- `weak.upgrade()` returning `optional(shared(T))` i.e. `*T?`
- SPEC text already covers cycle leaks — keep as-is

**OUT (deferred):**
- User-defined `Drop` (no infra yet; document gap honestly)
- Multi-threaded `Arc<T>` / `Send` / `Sync` (V2)
- Cycle detection (never; leak-by-default per SPEC)
- Operator overloading through `*T` (defer; `*a + *b` won't work)
- Multi-level auto-deref chains (`*(*T)` weird; defer)
- Recoverable allocation surface in user code (runtime has it; user
  syntax doesn't until later milestones)
- `T? → Option(T)` desugar (strongly deferred — separate milestone)

---

## 4. M20d implementation plan (5 sub-commits)

Each commit must keep all tests passing. M5-style; commit messages
should follow the M20a–c pattern (motivation, what changed, GPT-5.5
attribution where applicable, test count delta).

### M20d(1/5) — Grammar + Type variants + sema typing

- Add `shared` / `weak` Type variants to `src/types.zig`. Extend
  `TypeStore.typeEqual`, `formatType`, `compatible`, `substituteType`,
  `typeEqualsAfterSubst`, `classifyReceiverType`, `unwrapBorrows`
  (NOT this one — keep narrow per GPT-5.5; add `unwrapReadAccess`
  instead).
- Add `shared` IR Tag (distinct from expression-position `share`).
- Grammar: add `SHARE_PFX type → (shared 2)` and `"~" type → (weak 2)`.
  Run `zig build parser`; verify conflict count stays at 34.
- Sema: `(share x)` at expression position now types as
  `shared(typeOf(x))`. `(weak x)` requires its operand to be
  `shared(T)` and types as `weak(T)` — fire diagnostic if applied to
  non-shared. Type-position `*T` / `~T` resolve via new arm in
  `resolveType`.
- No emit changes in this commit.
- Tests stay at 496.

### M20d(2/5) — Runtime + driver integration

- Create `src/runtime.zig` or similar (in-tree source) with the
  `RcBox` / `WeakHandle` / `rcNew` / `defaultAllocator` code from
  §3 above.
- Driver: in `bin/rig build`/`run`, write `_rig_runtime.zig` to the
  same `/tmp/rig_<name>/` directory as the main emitted module.
  Source of `_rig_runtime.zig` content lives at compile-time in the
  Rig binary (embed via `@embedFile` or just a string constant).
- Emitted modules: add `const rig = @import("_rig_runtime.zig");` to
  the prelude of every emitted module.
- Multi-module note: if `use foo` produces multiple `.zig` files,
  they all need to be in the same dir so `@import("_rig_runtime.zig")`
  resolves consistently. Audit `src/modules.zig` for this.
- Tests stay at 496 (no behavior change in any existing example).

### M20d(3/5) — Operator emit

- `emitExpr` for `(share x)` → `rig.rcNew(x) catch @panic(...)`.
- `emitExpr` for `(clone x)` where x has type `shared(_)` → `x.clone()`.
- `emitStmt` for `(drop x)` where x has type `shared(_)` → `x.drop();`.
- `emitExpr` for `(weak x)` where x has type `shared(_)` → `x.weakRef()`.
- `(clone w)` / `(drop w)` for weak handles → `w.clone()` / `w.drop()`.
- `(move x)` for shared handles: NO runtime call (handle transfer is
  sema-only).
- `emitType` for `(shared T)` → `*rig.RcBox(<T>)`.
- `emitType` for `(weak T)` → `rig.WeakHandle(<T>)`.
- Add 2–3 positive examples to verify end-to-end (e.g., construct an
  `*Int`-like wrapper, clone it, drop it; weak ref + upgrade).

### M20d(4/5) — Read-only auto-deref

- New helper `unwrapReadAccess(ctx, ty_id)` peels `borrow_read` +
  `borrow_write` + `shared` (NOT weak, NOT optional/fallible).
- `synthMember` uses it for the value-member branch.
- `lookupDataField` / `lookupMethod` use it.
- Receiver-mode validation: extend `ReceiverTypeKind` with `.shared`
  and update `checkReceiverMode` to reject `.write` / `.value`
  receivers when receiver is `.shared`.
- `checkSet` rejects `obj.field = X` when `obj` is `shared`.
- Negative tests for write-through-shared, consume-through-shared,
  field-assign-through-shared.

### M20d(5/5) — Tests + drop discipline + ROADMAP

- **First: get Steve's decision on the drop-discipline question**
  (§3 above). If (B), this becomes M20d(5/5) = automatic scope drop
  and M20d(6/5) = tests/docs. If (A), this commit is just docs +
  tests + the explicit-only behavior documented.
- Positive tests: shared int wrapper, weak/upgrade cycle break,
  generic enum + shared interaction (`*Option(Int)`).
- Negative tests: shared-of-shared (`**T`), weak-of-non-shared
  (should error in M20d(1/5) already), `weak.upgrade()` returning
  `*T?` correctly typed.
- ROADMAP M20d entry following the M20a/M20b/M20c template.
- REACTIVITY-DESIGN status note: M20+ item #6 landed.
- Update M20+ "now-blocking" table to mark #6 done.

---

## 5. Open questions for Steve (BEFORE M20d(5/5))

**Q1 — Auto-drop discipline.** Does Rig V1 do automatic scope-exit drop
of `*T` / `~T` handles, or explicit `-x` only? Options A and B in §3
above. Affects scope of M20d and SPEC language.

**Q2 — Multi-module runtime resolution.** Confirm that `_rig_runtime.zig`
being a sibling file works for `use foo` projects (multi-file). The
M15 module system writes per-module `.zig` files to `/tmp/rig_<name>/`;
ensure they all share the same dir for the import to resolve.

**Q3 — `*expr` consume vs clone.** GPT-5.5 says `*expr` MOVES `expr`
into the Rc (so `x = User(...); rc = *x;` invalidates `x`). The
alternative is implicit clone. Implicit clone is friendlier but
duplicates ownership of `x`. Confirm Steve agrees with the move
semantics before M20d(3/5).

**Q4 — Existing `share`/`weak` expression-position semantics.** Today
`(share x)` and `(weak x)` are M3-era ownership wrappers that
silently pass through. Verify nothing depends on the current
no-op behavior before M20d changes their meaning. Specifically:
search for `(share` and `(weak` in `examples/` and `test/golden/`.

---

## 6. Working conventions

### Git

- All commits on `main`. No feature branches in current practice.
- Sub-commit style: `Mxx(n/total): short summary` (M5-style).
- Commit messages: motivation + what changed + GPT-5.5 attribution
  where applicable + test count delta. See M20a–c commits for
  templates.
- ALWAYS pass via HEREDOC for multi-line messages:
  ```
  git commit -m "$(cat <<'EOF'
  Title

  Body
  EOF
  )"
  ```
- Push after every commit (this project doesn't accumulate locally).

### Testing

- `./test/run` — run all 496 tests + Zig unit tests
- `./test/run --update` — regenerate goldens (review diffs before committing)
- New examples auto-discovered for raw_sexp / semantic_sexp / errors
- For end-to-end (emit + ast-check + actual run): add example name to
  `EMIT_TARGETS` in `test/run`
- Every sub-commit must keep tests green

### GPT-5.5 collaboration

**This is non-negotiable per Steve.** Established pattern:

1. **Design checkpoint BEFORE coding**: send proposed design (with
   alternatives + your lean on each question) to GPT-5.5 via the
   `user-ai` MCP server's `discuss` tool with `conversation_id:
   "c_5c1d09d53ebe2f62"` and `model: "openai:gpt-5.5"`.
2. **Implement** against the design (with corrections applied).
3. **Post-implementation review**: send the full diff back via the
   same conversation. Attach diffs as file paths (write to `/tmp/`
   first). Expect 1–2 rounds of fixes.
4. **Commit only after sign-off.**

**Set `max_tokens` >= 6000** when asking GPT-5.5 — its responses are
substantive. The `max_tokens: 4000` default once produced an empty
response (eaten by reasoning budget).

**Key prior reviews to skim** (in the conversation thread): M5(1–6)
audit (way back), M20a design pass, M20a.2 hardening (caught
soundness bugs), M20b design + 2 review rounds, M20c design + review,
M20d design (the one you'll build against).

### Editing conventions

- DO NOT edit `src/parser.zig` directly — it's generated.
  Edit `rig.grammar`, run `zig build parser`, commit both.
- DO NOT touch `.zig-cache/` — that's build artifacts.
- DO NOT add emojis to code or docs unless explicitly requested.
- DO use the `ReadLints` tool after substantive edits to check for
  linter warnings in modified files.
- DO use `TodoWrite` for multi-step tasks (any 3+ step plan).

---

## 7. The user-ai MCP conversation

Persistent conversation ID: **`c_5c1d09d53ebe2f62`**

It contains, in order:
1. M20a thesis review (the first turn — Rig's design from scratch)
2. Reactivity design discussion (3+ rounds)
3. M20a design pass → implementation → 2 review rounds
4. M20a.1 sugar → review
5. M20a.2 hardening → 2 review rounds
6. M20b design checkpoint → 5 sub-commits → 2 review rounds
7. M20c design checkpoint → 3 sub-commits → review
8. **M20d design checkpoint (the most recent turn)** — locked-in
   design captured in §3 above

To continue the thread, pass `conversation_id: "c_5c1d09d53ebe2f62"`
and `model: "openai:gpt-5.5"` (or `"openai:gpt-5.5-pro"` for harder
questions). Models live in
`/Users/shreeve/.cursor/projects/Users-shreeve-Data-Code-rig/mcps/user-ai/tools/`.

---

## 8. Hazards / things to NOT do

1. **Don't allow `*T` to silently produce `!T`.** Write-through-shared
   breaks the aliasing model. M20d(4/5)'s receiver-mode rejection is
   the safety check.
2. **Don't broadly extend `unwrapBorrows` to peel `shared`.** Add a
   narrower `unwrapReadAccess` helper instead, so existing
   write-borrow / consume paths don't accidentally compose with
   shared.
3. **Don't auto-deref `weak`.** Weak handles require explicit
   `.upgrade()`.
4. **Don't tie `weak.upgrade()` to user-defined `Option(*T)`.** Use
   built-in `optional(shared(T))` i.e. `*T?`. The `T? → Option(T)`
   desugar is a separate (deferred) milestone.
5. **Don't use a mutable global allocator.** Store allocator in the
   `RcBox`.
6. **Don't use `u32` for refcounts.** Use `usize` per GPT-5.5.
7. **Don't `@constCast(sema)` in emit.** Phase discipline. The
   `typeEqualsAfterSubst` helper (added in M20b(5/5)) is the
   non-mutating alternative for emit-time type comparisons.
8. **Don't ship M20d(5/5) without an explicit decision on auto-drop
   (Q1 above).** Either way is OK; silent ambiguity is not.
9. **Don't make `Option` / `Result` the built-in optional/fallible
   representation.** `T?` and `T!` are separate built-in types
   (`Type.optional` / `Type.fallible`). Confusion here would cascade.
10. **Don't skip the GPT-5.5 review loop.** It has caught real bugs in
    every milestone so far (M20a soundness gap, M20b allocator
    lifetimes, M20a.2 consume-through-borrow, etc.). Cost is ~$0.30 per
    round; value is preventing days of debugging.

---

## 9. If you get stuck

- **Tests failing after a change**: `./test/run 2>&1 | grep FAIL`
  shows just the failures. Most failures are golden diffs from
  intended changes — verify with `git diff test/golden/` and
  `./test/run --update` if intentional.
- **Grammar conflict count changed**: revert and reconsider. The 34
  conflicts are all reviewed and intentional. Adding more without
  understanding is a code smell.
- **Sema diagnostic isn't firing**: check that the IR shape reaches
  the right walker. `bin/rig normalize path/to/file.rig` prints the
  semantic IR — useful for confirming what sema sees.
- **Zig compile error in emitted code**: `bin/rig build path/to/file.rig`
  prints both the emitted Zig AND any Zig errors. Often the issue is
  sema "succeeded" with `unknown` types that propagated.
- **General confusion**: read REACTIVITY-DESIGN.md. It's the design
  note that drives the M20+ ordering and explains *why* each
  substrate piece matters.

---

## 10. Closing notes from the prior session

- The user is Steve. Communicates clearly; pushes back when the design
  feels off. Trusts the GPT-5.5 collaboration loop.
- Pace expectation: M5-style sub-commits with reviews; not "big drop
  every few days." Each sub-commit must be self-validating.
- The Rip→Rig syntax connection is important to Steve (he made Rip,
  a CoffeeScript-to-JS language, and Rig inherits the syntactic
  philosophy). REACTIVITY-DESIGN.md exists because of his Rip
  reactivity model — Cell/Memo/Effect is the validation target for
  the entire M20+ arc.
- The Rig-as-a-whole "wow factor" emerges from the *combination* of
  features, not any single one. Don't over-promise individual
  features; the value is in the synthesis.
- Have fun. This is a beautifully scoped project and the trajectory
  is sound.

Good luck. Read SPEC.md, then ROADMAP.md M20+ section, then the M20d
design above. Then start M20d(1/5).
