# Origins: red team

Role: attack every origins design that the four reports (`formal.md`,
`prior-art.md`, `fit.md`, `impl.md`) propose or imply. I looked for
unsound programs, exception lists, API traps, diagnostics nobody can
explain, checking cost, and clashes with the Core and AGENTS.

Every Rig claim was checked with `bin/rig check`, and accepted programs
with `RIG_SANITIZE=1 bin/rig run`, on the revamp worktree (`d29be15f`).
Prototype claims were checked by applying `probes-impl/proto-inferred.diff`
to a scratch copy and building it. Probes are in `probes-red/`.

---

## 0. Bottom line

1. **Today's compiler has a use-after-free right next to this question
   (§1).** A callee can store a view of one write parameter into another
   write parameter, then grow the first. `rig check` accepts it, and the
   program reads freed memory under `RIG_SANITIZE=1`. Four shapes do
   this (`r3`, `r7`, `r8`, `r9`), and the frozen base compiler accepts
   them too.
   - **Cause:** in `walkFieldAssign`'s store-into-caller branch
     (`ownership.zig` ~2736–2753), a loan rooted at another parameter
     passes the "no local loan" check and is then dropped. It never
     enters the parameter's flow, so nothing keeps it in force for the
     rest of the body.
   - **Why it blocks origins:** every origins layer assumes a store
     through a write view is recorded in the target's flow (formal §2.2,
     a "weak update"). It must be fixed before any summary is built on
     top.
2. **Every design that keeps the signature as the contract survives,
   once two fixes are in.** Those designs are the type-based defaults
   (`produces`, L0) and the declared `from`, checked by the body walk.
   - **Fix 1:** origins must be part of a function value's *type*, with
     subsumption at one coercion point. Impl's "same shape, ignore
     origins" plan lets a `?fun` local re-pointed in a branch (`f2`), or
     a `?fun` result (`f4`), keep the narrower origins of the first
     function it held. That is unsound.
   - **Fix 2:** a summary token `(p, f)` must mean "what `p.f` views
     when the call returns". So the caller applies the call's stores
     before it reads the result. Otherwise L0 (`l0_absorb_order`), D2
     path tokens (`d2_repoint`), and L1b parts let a re-pointed field
     dangle.
3. **Body inference as the meaning of a call fails on principle, not
   just in practice.**
   - It breaks Core §10's "rules follow the value's type".
   - It needs a declared form anyway at every bodiless boundary.
   - The private-only variant is an exception list by construction.
4. **The prototype's recorder already computes a wrong mask, and is
   saved by coupling.** For `f(a: !Holder, b: []Int) -> []Int` with
   body `a.r = b; a.r`, it infers `mask=0x1` (`a` only), but the result
   views `b` (`p1`, `p2`).
   - The caller is safe only because today's store absorption puts `b`'s
     loan into the holder, and the result keeps a loan on the holder.
   - Any later narrowing of the store channel (`into`, D0, L1b parts)
     must keep that coupling, or the mask must be computed correctly
     (§1's fix does that).
5. **Several current rules are load-bearing for every origins design
   (§2).** These include: no view into a Cell's contents; a closure
   cannot return a view of its write captures; no value holds a `?fun`;
   a closure cannot store its parameter through a capture; `swap`
   refuses view-holding values.
   - Two of them are already scheduled to change: CORE §5 plans `swap`
     for any element, and formal proposes fixing `hr_store`.
   - Each needs an origins test before it changes.
6. **L0 and `produces` carry a semver hazard: they depend on private
   fields.** Adding `scratch: Vec[Item]` to a `Cursor` silently
   re-locks every caller of `next`.
   - Rig already accepts this class: a struct's kind follows its parts,
     as Rust's auto traits do. It must be documented, and the diagnostic
     must name the field.
   - `from self.items` is the stable contract.
7. **What "100%" can mean** (§6):
   - Every "which argument does this view come from" case that Rust
     accepts is expressible.
   - Every rejection caused by over-approximation names the one word to
     add.
   - Nothing unsound is admitted on the way.

   It cannot mean "never write anything": that needs inference as
   meaning, which item 3 rules out.

---

## 1. A use-after-free today: stores into a write parameter forget their loan

`probes-red/r3_store_then_grow.rig` (accepted today; the sanitizer
reports "use of freed memory"):

```rig
struct Holder
  r: []Int

fun f(a: !Holder, b: !Vec[Int]) -> Int
  a.r = ?b[..]          # a.r views b's buffer
  for i in 0..100
    !b.push(i)          # reallocates b: nothing says b is lent
  a.r[0]                # reads the freed buffer
```

**Siblings, all accepted, all crash under the sanitizer:**

| Probe | How the view gets into `a` |
|---|---|
| `r3_store_then_grow` | `a.r = ?b[..]` |
| `r7_store_via_method` | `!a.set(?b[..])`, where `set` stores into `self.r` |
| `r8_store_via_alias` | `k = !a; k.r = ?b[..]` |
| `r9_store_readparam` | `a.r = ?c[..]; t = a.r` (read back into a local) |

**Correctly rejected:**

- `r4`: the same store through a local write view in `main`.
- `r10`: the holder is an owned local.
- `r5`: storing a lend of a callee local.
- `r11`, `r12`: storing `?a.own` into `a.r` (a self-loan; the
  whole-root conflict catches it).
- In the caller, `r6`: the call absorbs `v` into `h`.

**Class:** a loan that escapes into memory the caller owns is dropped
from the callee's own view of the world. In Rust it would need
`b: &'a mut Vec`, with `'a` outliving the function, so `b` stays
borrowed for the rest of the body.

**Fix (one rule):**

- A value stored into a write parameter's target puts its loans into
  that parameter's flow.
- A write-lent parameter is live at every exit, because the caller
  reads it after the return.

So the stored loan stays in force until the function ends. This also
gives the recorder a single place to read stores: the parameter's flow
at exit, after defers. That replaces impl's list of four store sites,
which has to be complete.

**Sibling sites to check:**

- `walkFieldAssign` (the `v.ref != .none` branch);
- `storeThroughLocal`;
- `absorbLoans`' parameter branch;
- `reassign` through a `!T` parameter;
- capture absorption in `walkLambda`, and `defer` (`s5` and `s6` show
  the escape check runs there; the flow update must too);
- `swap` once it accepts view-holding values.

This is a consolidation fix (rejects only unsound programs), in scope
now, and it must land **before** any origins layer.

---

## 2. Load-bearing rules (tripwires)

Each rule below is true today, and some origins argument depends on it.
Changing any of them reopens the soundness argument.

| # | Rule today | Probe | What depends on it |
|---|---|---|---|
| T1 | A Cell's or Signal's contents cannot be lent (SPEC §10: "an element cannot be borrowed"; `get` copies) | — | Rig's existing write-to-read downgrade for String views (`addViewLoan` sets `kind = .read`); any future downgrade; L0's "Cell contents are owned edges" |
| T2 | A closure cannot return a view of what it captured to write: `?v[0]` inside `\|!v\|` is "local to this closure" | `c1`, `c3` (rejected); `c4` (read capture) runs | formal Lemma 1 (see §3.2): a `?fun` read view *can* reach a write path (`c2` calls a write-capturing closure through two read views) |
| T3 | No value holds a `?fun` ("only a parameter's, a local's, or a result's type") | `f3` | the read-receiver fix (fit §0.2): a `?self` body cannot reach a closure that stores |
| T4 | A closure cannot store its parameter through a capture | formal `hr_store` | the read-receiver fix; store summaries (closure environments are not an output channel today). Formal proposes lifting this: that adds a **third output channel** (a closure's environment), which every store summary must then include |
| T5 | `swap` refuses values that may hold a loan | `s1`, `s2` | the store recorder has no swap site. CORE §5 *plans* swap for any element: then swap is a two-way store |
| T6 | A type argument of a generic function, or of a generic type with methods, holds no view (SPEC "Generic bodies") | — | generic summaries are trivial. Formal's pointwise `T`-slot mapping is unnecessary today |
| T7 | No mutable module-level bindings (`SPEC.md:1604`) | — | impl's "loans on globals are static" |
| T8 | Self-loans are rejected by the whole-root conflict | `r11`, `r12`, impl `self_store` | L1a must replace this with an explicit self-loan rejection at every store site (impl §10.1) |
| T9 | Closure bindings are fixed (cannot be reassigned) | `f1` | impl's per-`Var` inferred closure origins. `?fun` locals *can* be re-pointed (`f2`), so the same trick is unsound for them |

**Recommendation:** add one `test/reject` file per tripwire, each
commented "origins depends on this". Also add a line to the ledger
listing them.

---

## 3. The designs, attacked

### 3.1 Status quo + `produces` (type filter; loans.md 6.2)

**What it is.** The result, and what a call stores, carry the loans of
every argument whose declared type *can lead to* a view of the result's
target type. An `Int` key cannot produce an `Item` view. There is no
syntax. Impl adds a check of the default against the body.

**Attacks:**

- **A missing edge is unsound in a trusted body only.**
  - Impl's body check makes a missing edge a false rejection in Rig
    bodies, which is a good design.
  - `extern zig` and built-ins are trusted, so `produces` must be
    exactly right for them.
  - The bytes class matters: `String`, `[]U8`, `[N]U8`, and Text's
    buffer are one memory class (SPEC 5284: "A `[]U8` and a `String`
    are the same bytes at run time").
  - **Survives** if the built-in table has a unit test per row (impl
    §13.4).
- **Type variable as a *target*.** `fun pick[T](a: ?T, k: ?Key) -> ?T`
  at `T = Key`.
  - Safe: the generic body is checked once with `T` opaque, so it
    cannot return `k` (T6).
  - The rule must still say that a type variable *as target* is reached
    by every source. Impl only states the source side ("type variables
    reach everything").
- **Recursive types, memoized per pair.** Impl memoizes `produces` and
  `ownReach` in a hash map.
  - The classic bug: a cycle `A → B → A` answers `false` for the
    in-progress `A`, the walk memoizes `B = false`, and a later query
    on `B` reuses that wrong answer.
  - With `produces`, that is a false rejection, caught by the body
    check. With `ownReach` (L0), it is **unsound**.
  - **Repair:** compute both per strongly connected component of the
    type graph, or never memoize a result computed while a cycle is
    open. Unit-test with mutually recursive nominals across modules.
- **API stability.** Adding a private `Text` field to `Key` makes
  `Key` produce `String`, and callers of `env.get(?k)` re-lock `k`.
  See §3.2.
- **Core fit.** It fits in one paragraph, follows the type, and needs
  no syntax.

**Verdict:** sound (given the body check, and an exact table for the
trusted functions), simple, and fits Rig. It is the safe first layer.
It fixes `index`, `produces`, `method_key`, `f2c`, and `p31_over`.

### 3.2 L0, the type-directed carry rule

**What it is.** A view whose loan is on holder `h` keeps that loan only
when `h`'s type reaches the target type through owned or write-view
edges. Otherwise the loan is replaced by `h`'s own loans. This is Rust's
supporting prefixes, stated on types. It generalizes `viewLoans`, which
works only for `String`.

**Attacks:**

- **Absorb order at a call** (`probes-red/l0_absorb_order.rig`,
  rejected today).
  - `next(!self, extra)` re-points `self.items = extra` and returns
    `?self.items[0]`.
  - If the call rule replaces the result's loan on `c` with `c`'s flow
    *before* it absorbs the call's stores into `c`, then `r` carries
    only `v` and outlives `w`.
  - **Repair:** fixed order: stores first, then the result, then carry.
    Keep this probe as a reject test.
- **Lemma 1 is false as stated for `?fun`.**
  - Formal: "a read view cannot reach a write path". But a `?fun` is a
    read view, and calling it can write through its write captures
    (`c2` runs, and writes `v` through two read views of `add`).
  - It is saved only by T2: a closure cannot return a view of what it
    writes.
  - **Repair:** state Lemma 1 for *projections* (field, element,
    payload, Box, handle) only, and let calls through `?fun` go through
    the call rule (callee value ∪ arguments), never through carry. Impl
    already classes closures as "reach everything", which is the safe
    choice. Formal's table puts `?fun` among the read edges, which is
    not. Pick impl's.
- **Write edge, then read edge.** Take `C { w: !Wrap }` and
  `Wrap { items: ?Vec[Item] }`, and the lend `?c.w.items[0]`.
  - The last view crossed is a read view, so the replacement is
    allowed.
  - The recursion replaces the loan on `c` by `c`'s write loan on the
    `Wrap` owner `W`, and then that by `W`'s read loan on the Vec.
  - That is sound: `W` may be re-pointed through `c`, but the view keeps
    the Vec's loan.
  - **Required test:** the opposite order (read edge, then write edge)
    cannot occur, because the checker already refuses to lend a write
    view held behind a read view (`rr2`).
- **Handles.** A `*T` edge must count as owned: `h.p = *Node(..)` drops
  the old box.
  - A `~T` edge must count as owned too, conservatively.
  - A read view *of* a handle (`p: ?*Node`) is a read edge, and that is
    correct: the box's contents change only through a Cell (T1).
- **Private-field hazard.**
  - `cursor.rig` passes under L0; `cursor_own.rig` (the same `Cursor`
    plus `scratch: Vec[Item]`) does not. Adding a private field to a
    library type re-locks every caller's second `next()`. The
    signature did not change, and no doc warns the user.
  - The same is true of `produces`, of Rig's existing "a struct's kind
    follows from its parts", and of Rust's auto traits.
  - **Repair:**
    - document it as part of a type's contract;
    - make the diagnostic name the field ("`Cursor` can own an `Item`
      itself, in field `scratch`, so the result keeps `c` lent");
    - offer `from self.items` as the stable form.
- **Temporaries keep an exception.** Impl keeps `keepViewTemps` for
  `String` results only.
  - So `print(!s.next(), !s.next())` works for a String iterator and
    fails for a `?Tok` iterator in the same position.
  - That exception exists today, and L0 leaves it visible.
  - **Repair:** the follow-up impl already lists (§11.1). Schedule it.
    Don't let it become permanent.
- **Cost:** one memoized type query per lend. Negligible.

**Verdict:** sound with the two repairs (per-component computation of
`ownReach`, and a fixed call order). Simple, type-based, and the largest
payoff (parser cursors). Ship it after `produces`.

### 3.3 Field-precise loans

**L1a, owner-side paths** (disjoint `!p.x` and `!p.y`):

- **Self-loans (T8).** Today every self-store dies on the whole-root
  conflict. With paths, `self.r = ?self.own` becomes reachable at
  every store site:
  - `walkFieldAssign`;
  - `absorbLoans` (which silently drops a loan on the target var,
    ~3226);
  - `storeThroughLocal`;
  - capture absorption.

  Each must reject. **Missing one is unsound.**
- **Whole uses** must take the whole path:
  - `<p`, `-p`, `p = e`, `+p`;
  - a `?self` or `!self` method call on `p` (the body may touch any
    field);
  - a closure capture of `p`, a `match` on `p`, a `defer` reading `p`;
  - a drop body.

  As a list, this is an exception list, and a forgotten entry is
  unsound.

  **Repair:** invert it. The *partial* uses are a positive list of one
  form, a member path (`p.f…`, ended by any index). Every other use is
  whole. That satisfies "one classifier, positive list": being partial
  is the fact, and whole is the safe default.
- **Index paths.** `!a[0].x` and `!a[1].y` must conflict (an index ends
  the path). Impl has this.

**L1b, holder-side parts** (`pair.rig`, `split.rig`):

- The same whole-use inversion applies to liveness.
- **Loops:** per-field last use must extend across the back edge, as
  per-symbol last use does.
- **Stores into a holder must update its parts.**
  - A call that absorbs `w` into `h` must put `w` into *every* part
    that the call could have written. Otherwise `parts[r]` keeps the
    old loans while the union grows, and a projection of `h.r` (D2,
    or a declared `from a.r`) misses `w`.
  - `d2_repoint` and `l0_absorb_order` are the shapes.
  - Impl specifies `joinFlow` dropping parts, but not *absorb*.
  - **Repair:** any weak update of a holder drops its parts, or unions
    the stored loans into every part, keeping the union invariant.
- **Beyond Rust.** Rust rejects `pair.rig` too (formal §1, row 13). So
  the cost buys precision Rust users do not expect, and its parity
  value is only `split.rig`.

**Verdict:** sound only with the whole-use inversion, the self-loan
rejections, and parts invalidated on absorb. It is the highest-risk
layer, so build it last and alone. L1b should wait for a real program,
as fit and formal both say.

### 3.4 Origins inferred from bodies (L2 as the meaning of a call)

**What it is.** A caller narrows using the callee's computed summary:
everywhere (design C), or for private functions only (impl §9).

**Attacks:**

- **Principle.**
  - Core §10 says "Its rules follow the value's type, never where the
    value came from". A summary inferred from a body is "where it came
    from", one level up.
  - The private-only variant is literally an exception ("private
    functions differ"). AGENTS forbids exception lists, and impl §9
    concedes this.
- **API stability** (fit §4.1, prior-art §4): a library adds `?? key`
  and its callers break, with no signature diff.
  - Inside one module this is milder, but a refactor of a helper
    changes which statements in *other functions* compile.
  - The diagnostic then chains through bodies.
- **Bodiless boundaries.** `?fun` parameters, `extern zig`, and `os.env`
  have no body to read. So the declared form is needed anyway, and
  inference only postpones learning it.
- **Fixpoint traps.**
  - Seeding a recursive group with "all" fixes at "all" (impl found
    this).
  - Seeding an *imported or unknown* callee at ⊥ is unsound.
  - Diagnostics must be re-sorted, because the walk order is no longer
    source order.
  - A quiet walk that stops at the first error leaves a partial
    summary. That is fine only because any error rejects the whole
    program: never let a quiet walk suppress errors in some mode (for
    example, an IDE or `--keep-going`).
- **Wrong masks today** (`p1`, `p2`, run on the prototype). The
  prototype prints `summary f: mask=0x1`, but `f` returns a view of
  `b` through `a.r`.
  - It is rejected only because the caller absorbs `b` into `h`.
  - With §1's fix the mask becomes `{a, b}`. Without it, inference is
    only as good as the store channel's conservatism.
- **Cost.** One walk per non-recursive function if done in component
  order. A recursive group of k functions costs k walks times its
  rounds, and each walk contains its own loop fixpoints. Recursive
  descent parsers are exactly the large recursive groups.

**Verdict:** sound if built carefully, but it does not fit Rig. **Keep
L2 inside the compiler only:**

- as the checker that proves each declared `from`;
- as the source of the exact help line.

Formal, prior-art, fit, and impl all reach this conclusion. I found no
attack that changes it.

### 3.5 Declared origins: `-> T from a`, on results, function types, and `extern zig`

**What it is.** The signature names which parameters (or paths into
them) the result views. The callee's body walk proves it. Callers read
only the type.

**Attacks:**

- **Argument mapping** (impl's `kw_args_trap`).
  - Keyword arguments, defaulted arguments, receivers, compile-time
    parameters, `T.m(x, y)`, and a function field `p.f(..)` all map
    arguments to parameters non-positionally.
  - **Repair:** one fact, the one emit uses, extended with the
    receiver. Impl has this. The reference checker must compute its
    own mapping (impl §14).
- **Function values keep the wrong origins.**
  - Impl §6.3 makes compatibility of function types "same shape",
    ignoring origins, and checks a value's fit "at lends".
  - But a `?fun` local can be re-pointed (`f2`: `h = ?left`, then
    `h = ?right` in a branch). A `?fun` result can come from either of
    two functions (`f4`: `choose(c)` returns `?left` or `?right`).
  - If `h` takes `left`'s type `from a`, and the reassignment passes
    as "same shape", then `h(?x, ?y)` narrows to `x`. `h` actually
    holds `right`, so `r` views `y`, which the caller may then free.
  - Both probes are rejected today, and must stay rejected.
  - **Repair:**
    - origins are part of the type;
    - one coercion function (`compatible`) allows narrow-to-wide;
    - a join of two function types takes the union of their origins;
    - an unannotated local's type is the declared default ("all"),
      never inferred narrower from its first value.

    The subset check then lives in typecheck at the one coercion point,
    not at "lends" in ownership, which is a syntax-shaped site. It also
    covers sentence 1's planned unwritten read lend, where the `?` is
    not written.
- **Closures.**
  - The environment must stay an input. For write captures, T2 must
    hold.
  - Formal makes the environment "always" part of the result. Then
    `apply(f, x) -> ?I from x` fails its body check whenever it returns
    `f(x)`, and must say `from f, x` even when `f` was declared
    `?fun(i: ?I) -> ?I from i`.
  - That reads oddly ("from f"?), but it is sound.
  - **Better:** let `from` in a function type omit the environment.
    A closure converts to that type only if its own mask, environment
    bit included, is a subset, checked at the same coercion point.
- **Path origins (`from self.src`, impl's D2 tokens).**
  - In `d2_repoint`, the body re-points `self.src = other`, then
    returns `?self.src[0]`.
  - If the projection rule yields `ext(self, src)` because `self`'s flow
    *started* as `{ext(self)}`, the declared `from self.src` passes,
    and the caller frees `other`'s owner.
  - Impl conditions the rule on the flow being exactly `{ext(p, 0)}`.
    That condition is load-bearing: test it.
  - Caller side: `(p, f)` is computed after the call's stores (§0
    item 2).
- **`from static` on an extern** (`os.env`).
  - It is trusted, and true today only because std has no `set_env`.
    POSIX `setenv` and `putenv` invalidate `getenv` results.
  - **Repair:** a comment on `os.env`'s declaration naming the
    invariant, and a review rule that adding environment mutation to
    std must revisit it.
- **Desugaring rule (AGENTS).** No existing form says "this result does
  not view `b`". So `from` cannot be specified as a desugaring in the
  strict sense.
  - Formal's "arguments are statement temporaries, and the result
    takes what Σ names" restates the rule rather than reducing it.
  - **Honest wording for INTERNALS:** `from` is sentence 7's planned
    refinement, and its checker rule is the call rule plus the body
    check. That is an existing Core sentence, so the "fits the Core"
    test is met.
- **Readability.**
  - `fun f(from: String) -> String from from` is legal under a
    contextual keyword. It is ugly but unambiguous; a lint or a doc
    note suffices.
  - `-> String? from s` reads correctly.
  - For write parameters, `h: !Holder from x` reads as "h comes from x"
    (wrong). Fit's `x: ?I into h` reads as the effect (§3.6).
  - Function types need parameter names (a grammar change, mirrored in
    Nexus).
- **Recursion and mutual recursion.** Assume–guarantee on the declared
  type works. Modules are a DAG; cross-module "recursion" through
  callbacks goes through function types. No attack found.
- **Generics.** The body is walked once (T6). No attack found.

**Verdict:** sound with the function-type repair (origins in the type,
subsumption at one coercion point), the mapping fact, and §1's fix.
Simple to read, and fits Rig: it is sentence 7's own planned half. This
is the core of the answer.

### 3.6 The store channel: `h: !H from x` versus `x into h`, and the default

**Attacks:**

- **The default "nothing stored"** (fit's `into`) rejects today's
  accepted setters: a change in meaning. That is after the freeze, as
  fit says.
- **The recorder must see every store** (§1). Fit's `f5`/`f5b`
  (loggers) are the payoff.
  - But a closure-created store (`s5`: `g = |!h, ?w| h.r = w`) is
    attributed when the closure is made, not when it is called.
  - An `into` check must use the same attribution, or a closure made
    and never called would demand an `into`. That direction is
    conservative, so it is acceptable.
- **T4 and T5:** fixing `hr_store`, or generalizing `swap`, adds store
  channels. `into` must then be expressible for a closure's environment,
  which has no parameter name to write it on.
- **D0 type narrowing of stores** (in the freeze) is sound if the store
  targets are the slots reachable from `q` through **owned and write**
  edges. Read edges cannot be stored through; handles only through a
  Cell, which takes no loans.

**Verdict:** `into`, with default "nothing", is the right final form and
sound once §1 holds. Before the freeze lifts, only D0's type narrowing
of stores.

### 3.7 Elision-style defaults (Rust's `self` rule) plus declared

**Attacks:**

- **The freeze.** Changing the default from "every argument" to
  "`self`" rejects bodies that return a view of a non-receiver
  argument.
- **Exception list:** methods and free functions would differ.
- **Rule 2 (one input) is already today's behavior.**
- **The only gain is rule 3** (a `?self` lookup with a same-typed key),
  and that is one `from self`, which the help line writes.

**Verdict:** sound if checked, but a meaning change plus an exception
list. Reject. Revisit only if a census of real code shows `from self` as
noise (prior-art §5 question 4).

### 3.8 Mojo-style origin parameters (`struct Span[o: Origin]`, `-> ref[a] T`)

**Attacks:**

- Origins enter types, so they appear in every signature that mentions
  the struct, and in every diagnostic (prior-art: Mojo's and Rust's
  noise).
- Rig's brackets mean compile time, and `?[4]Int` is a view of an
  array, so `?[a]T` is ambiguous to read.
- T6 forbids views in generic types that have methods. Origin
  parameters would have to lift that, reopening the generic-body
  ownership argument.
- It is lifetime variables under another name, which the North Star's
  "a reader never solves lifetime equations" rules out.

**Verdict:** sound (it is Rust), but does not fit Rig. Reject.

### 3.9 Hylo-style projections (no first-class views)

**Attacks:**

- Hylo has exactly today's over-approximation (`min[x, y]` projects
  both), so it does not answer the question at all.
- Adopting it removes views in fields and results: CORE §1, §5, and
  sentence 6 are built.

**Verdict:** not a solution. Reject.

### 3.10 The combination

The combination: §1 fix → read-receiver fix → `produces` + L0 (for
results and stores) → `from` (results, function types, externs),
checked by L2, with help lines → `into` after the freeze → L1a → L1b.

| Attack class | Outcome |
|---|---|
| Unsound program | none found once the repairs above are applied: §1; origins in function types; stores applied before the result; per-component `ownReach`; whole-use inversion; parts invalidated on absorb |
| Exception list | `extern zig` trust (the existing raw-like boundary); `keepViewTemps` String-only (schedule its removal) |
| API trap | L0/`produces` private-field dependence (documented, field named in the diagnostic, `from` as the stable form) |
| Diagnostic | every rejection caused by narrowing can name the word: L2 computes the minimal `from`/`into` |
| Cost | type queries memoized per component; one walk per function; no call graph |
| Core / AGENTS | one-paragraph sentence 7 (fit's or formal's draft); type-based; "desugaring" met as sentence 7's refinement (§3.5) |

**Verdict:** sound, simple per layer, and it fits Rig. The order
matters: §1 is a prerequisite, not a step.

---

## 4. Cross-cutting attack matrix

✓ = no attack found or repaired as noted; ! = needs the repair named.

| Context | `produces` | L0 | `from` | inferred | L1a/b |
|---|---|---|---|---|---|
| Recursion | ✓ | ✓ | ✓ assume–guarantee | ! seed at ⊥, never treat an import as ⊥ | ✓ |
| Mutual recursion across modules | ✓ (DAG) | ✓ | ✓ via function types | ! summaries exported, so bodies leak to importers | ✓ |
| Generics | ! type variable as target is reached by all | ✓ T6 | ✓ | ✓ | ✓ |
| Closures | ✓ (callable reaches all) | ! not a read edge (Lemma 1) | ! environment and T2 | ✓ per-closure recorder | ! a capture is a whole use |
| `?fun` parameters and locals | ✓ | ✓ | ! origins in the type; join; `f2`, `f4` | ✗ no body | — |
| `extern zig` | ! trusted table | ! unknown internals reach all | ! `from static` invariant (`os.env`) | ✗ no body | — |
| `*T` handles | ✓ edge | ✓ owned edge | ✓ | ✓ | ✓ handles only read |
| Cell | ✓ (T1) | ✓ (T1) | ✓ | ✓ | ✓ |
| Box | ✓ | ✓ owned | ✓ | ✓ | ✓ disjoint through Box |
| Text / String | ! bytes class | ✓ generalizes `viewLoans` | ✓ (`strip_prefix from s`) | ✓ | ✓ |
| Optionals | ✓ | ✓ | ✓ (`none` path) | ✓ | ✓ |
| Statement temporaries | ✓ (`temps` frozen) | ! `keepViewTemps` String-only | ✓ `u10_temp_ok`, `hdr_sep_temp` | ✓ | — |
| `defer` / `errdefer` | ✓ | ✓ | ! stores read at exit, after defers (§1) | ! same | ! a defer is a whole use |
| Reassigning a parameter | ✓ (forbidden) | ✓ | ✓ | ✓ | ✓ |
| Field assignment | ! §1 | ! absorb order | ! `d2_repoint` | ! `p1`/`p2` masks | ! self-loans; parts on absorb |
| Loops | ✓ | ✓ | ✓ | ✓ quiet rounds give subsets | ! per-field last use across the back edge |

---

## 5. Corrections to the four reports

- **formal §2.2 / §2.5.** "A store through a write view unions it into
  the target's slot (a weak update)" is the model, not today's
  checker, for parameter targets (§1). The invariant's case (c) is
  violated today (`r3`).
- **formal §2.3, Lemma 1.** The premise "a read view cannot reach a
  write path" is false for `?fun` (`c2`). Restrict the lemma to
  projections. Formal's slot table lists `?fun` as a read edge; use
  impl's "closures reach everything" instead.
- **formal §2.5, Generics.** The pointwise `T`-slot mapping is
  unnecessary: a type argument of a generic function, or of a generic
  type with methods, cannot hold a view (T6).
- **impl §0.1 and §2, lesson 3.** "The recorder needs nothing new from
  the walk": the prototype infers `mask=0x1` for `p1`/`p2`, whose
  result views `b`. It is safe only through store absorption (§3.4).
- **impl §3.3.** The store-site list must also cover `swap` once T5
  changes, and the flow update of §1. Reading stores from the
  parameter's flow at exit replaces the list.
- **impl §5 / §4.1.** Memoizing `ownReach` per type pair needs
  per-component handling (§3.1).
- **impl §6.3.** "Same shape, ignore origins" in typecheck, plus a fit
  check "at lends", is unsound for re-pointed `?fun` locals and `?fun`
  results (`f2`, `f4`).
- **prior-art §2.6 / §4 "Avoid a write-to-read downgrade".** Rig
  already downgrades for String views (`addViewLoan` sets
  `kind = .read`). That is sound because of T1: no view into a Cell's
  contents. The Rust argument applies only if T1 changes. A downgrade
  for other view results is a separate feature, not an origins one.
- **fit §0.2.** The read-receiver fix is sound. It rests on T3 (no
  value holds a `?fun`) and on the existing refusals in `rr1` and `rr2`
  (no assignment through `?self`, no lending of a held write view
  through it). Add those as the fix's sibling tests.

---

## 6. What "fix it 100%" can honestly mean

**What can be closed:**

1. **Soundness first.** Fix §1 (and keep T1–T9 under test). Without it,
   every summary rests on a store model the checker does not implement.
2. **No-syntax precision.** `produces` and L0 close the different-typed
   and cursor shapes, which are the common ones in parsers and lookups.
3. **One word for the rest.** `from` closes every same-typed "which
   argument" case, function values, and externs. `into` (after the
   freeze) closes stores. The compiler proves both from the body, and
   writes them in the help line.
4. **Parity, then beyond.** L1a gives disjoint field lends; L1b gives
   `split`-like holders, and per-field liveness that Rust lacks.

**What stays outside, and is not about origins:**

- views inside owned closures, Cells, and Signals (sentence 9);
- callbacks that store their argument (T4);
- type-level brands.

**BEYOND-RUST §2's trade, after layer 3:**

> Rig says which argument a result views with `from a`, and the
> compiler proves it from the body. Without `from`, a result views
> every argument whose type could hold such a view.

---

## Probe index (`probes-red/`)

- **Unsound today** (accepted; `RIG_SANITIZE=1` reports use of freed
  memory): `r3_store_then_grow`, `r7_store_via_method`,
  `r8_store_via_alias`, `r9_store_readparam`.
  - `r1_store_then_read` (plain `Int`; it breaks sentence 5 without a
    crash).
- **Correctly rejected today, and must stay rejected under each layer:**
  - `l0_absorb_order` (L0 call order);
  - `d2_repoint` (D2 / L1b parts);
  - `f2_fun_lent_var` and `f4_fun_result` (origins in function types);
  - `p1_store_return_writeparam` and `p2_store_return_readparam` (the
    prototype infers `{a}`; the caller is saved by absorption);
  - `c1_wcap_ret` and `c3_wcap_ret_view` (T2);
  - `f3_fun_field` (T3);
  - `s1_swap_holders` and `s2_swap_fields` (T5);
  - `r11_param_selfloan` and `r12_param_selfloan_in_body` (T8);
  - `f1_fun_reassign` (T9);
  - `rr1` and `rr2` (the read-receiver fix's siblings);
  - `r4`, `r5`, `r6`, `r10`, `s3`–`s7` (store-check siblings).
- **Accepted, and run clean:**
  - `c2_wcap_call_twice_lent` (`1 2 / 3 4 / 4`): a write-capturing
    closure called through two read views;
  - `c4_rcap_ret_view` (`1`).
- **Prototype build used:** a scratch copy at `d29be15f` plus
  `probes-impl/proto-inferred.diff`. It accepts `two.rig` with
  `mask=0x1`, and prints `mask=0x1` for `f` in `p1` and `p2`.
