# Origins: the formal model and Rust parity

Role: the formal model, and parity with Rust's lifetimes. Every Rig
claim below was checked with `bin/rig check` (and `RIG_SANITIZE=1 bin/rig
run` where it runs) on the revamp worktree. Every Rust claim was checked
with rustc 1.98.1, edition 2024. The probes are in
`probes-formal/` (Rig) and `probes-formal/rust/` (Rust).

## 0. Bottom line

1. **Rig's loan sets are Polonius's origins.** Polonius defines an
   origin (`'a`) as a set of loans, which is what Rig's checker already
   tracks per value. The gap with Rust is not lifetimes versus no
   lifetimes. It is *granularity*, in three places:
   - Rust has one origin per reference position in a type; Rig has one
     loan set per value.
   - Rust has a signature that maps input origins to output origins;
     Rig unions every input.
   - Rust's lends of places stop at a shared dereference ("supporting
     prefixes"); Rig's stop only for `[]T` and `String`.
2. **The trade can be closed for everything that is about "which values
   a view comes from".** No lifetime variables are needed:
   - **L0**, a type-directed *carry* rule: no syntax. It generalizes
     today's String-only `viewLoans` rule, and with it `produces`.
   - **L3**, a declared `from` on outputs, checked against the body by
     **L2** inference.
   - **L1**, slot-precise values for holders of several owners' views.

   The residue is three things that are not about origins:
   - views inside owned closures and Cells (Core sentence 9);
   - callbacks that store their arguments;
   - type-level brands.
3. **The probes overturn two candidate assumptions:**
   - Rust **rejects** `pair.rig` and `mkpair.rig`. While a struct is
     live, every region in its type stays live. So field-precise
     *liveness* goes beyond Rust, and is not needed for parity.
   - Rust **accepts** `split.rig`. A struct holds views of two owners,
     and a method returns only one of them. Parity *does* need
     slot-precise holder values, for that shape.
4. **The single most valuable piece is L0.** It is type-based and needs
   no syntax and no interprocedural state. It fixes the
   iterator/cursor/parser shape (`cursor.rig`, `deep2.rig`,
   `prefix.rig`) and the shapes `produces` fixes (`method_key.rig`,
   `produces.rig`). The cursor shape is the common real-program one,
   and `produces` alone does not fix it.

---

## 1. What Rust's lifetimes express, probed

The probes are `probes-formal/X.rig` and, for Rust, `rust/accepted.rs`,
`rust/accepted2.rs`, or the file named. "Rig" is today's revamp
compiler.

| # | Rust feature | Program (short) | rustc | Rig today |
|---|---|---|---|---|
| 1 | Result tied to some arguments | `fn first<'a>(a:&'a V, b:&V)->&'a V`; caller writes `y` while `r` lives (`two.rig`) | accepts | **rejects** (`y` stays lent) |
| 2 | Same, result type `Option<&'a str>` | `strip_prefix(s, p)`; caller changes `p` (`strip.rig`); `text.cut(?t, ?sep)`, change `sep` (`cut.rig`) | accepts | **rejects** both |
| 3 | Same, for a write view | `fn pickm<'a>(a:&'a mut I, b:&mut I)->&'a mut I` (`firstmut.rig`) | accepts | **rejects** |
| 4 | Elision rule 3 (`&self` result from self) | `t.get(&k)`, then `k = 2` (`method_key.rig`) | accepts | **rejects** |
| 5 | An argument that cannot produce the result | `at(&a, &mut k) -> &'a Item`, then `k = 3` (`produces.rig`) | accepts | **rejects** |
| 6 | Generic over lifetimes and types | `fn gfirst<'a,T>(a:&'a T, b:&T)->&'a T` (`generic.rig`) | accepts | **rejects** |
| 7 | Recursion under a lifetime | `pick(a, b, n-1)` returns only `a` (`recur.rig`) | accepts | **rejects** |
| 8 | Struct lifetime ≠ lend lifetime (`&'s P<'b> -> &'b V`) | `r = geta(&p)`, then reassign `p` (`deep2.rig`) | accepts | **rejects** |
| 9 | `impl<'a> Cursor<'a> { fn next(&mut self) -> &'a Item }` | `a = c.next(); b = c.next()` (`cursor.rig`) | accepts | **rejects** (second `!c`) |
| 10 | Supporting prefixes stop at a shared deref | `r = &c.items[0]; c.i = 5` (`prefix.rig`) | accepts | **rejects** |
| 11 | Two lifetime params, method returns one | `line.split(sep)`, `first = parts.next()`, change `sep` (`split.rig`) | accepts | **rejects** |
| 12 | Storing into a `&mut` with a named lifetime | `fn set<'a>(h:&mut Holder<'a>, x:&'a I, y:&I)`, then write `y` (`store.rig`) | accepts | **rejects** |
| 13 | Struct with two lifetime params, live whole | `p = Pair{a:&x, b:&y}; y.push(1); p.a` (`pair.rig`, `mkpair.rig`, `rust/rejected_pair.rs`) | **rejects** E0502 | rejects |
| 14 | Higher-ranked fn values | `apply(f: impl for<'x,'y> Fn(&'x I,&'y I)->&'x I, ..)` (`funval.rig`); a closure returning its capture (`closure_ret.rig`) | accepts | **rejects** both |
| 15 | Non-higher-ranked callback storing its argument | `each(&arr, \|x\| h.r = x)` (`hr_store.rig`) | accepts | **rejects** (storing a closure parameter through a capture) |
| 16 | Views in owned closures | `Box<dyn Fn()->i64 + 'a>` (`owned_closure.rig`) | accepts | **rejects** (sentence 9) |
| 17 | `'static` parameter | `fn remember(c:&Cell<&'static str>, s:&'static str)` (`static_param.rig`) | accepts | **rejects**, even for a literal argument |
| 18 | Variance: `&mut` is invariant | `*r = x` with `r: &mut &'static str` (`rust/invariance.rs`) | rejects | rejects the twin (`variance.rig`): "`y` does not live long enough" |
| 19 | Reborrowing | `bump(&mut *v)` twice; `fx(&mut p) -> &mut i64` (`reborrow2.rig`) | accepts | accepts, and runs `2 7` |
| 20 | NLL problem case #3 | `nll3b.rig` / `rust/nll3.rs` | **rejects** E0506 | **accepts**, runs sanitizer-clean |
| 21 | Disjoint field lends | `&mut p.x` and `&mut p.y` together (`disjoint*.rig`, `rust/disjoint.rs`) | accepts | **rejects** ("second write borrow on `p`") |
| 22 | Mutable cursor (`&'a mut` out of `&mut self`) | `rust/cursor_mut.rs` | rejects (correctly) | not expressible (no `Vec` of write views yet) |

Three findings from the table:

- **Rows 13 and 20: Rig is already at or past Rust.** In row 13, Rig
  and Rust agree. In row 20, Rig accepts what Rust's current checker
  rejects.
- **Rows 18 and 19: variance and reborrowing need no new machinery.**
  Rig has no variance because origins are loan sets that only grow
  through a write view (a weak update), and are killed only by a
  strong update of a local. That is why `variance.rig` is rejected.
  Reborrowing is `reborrow()`: a view taken through a held write view
  carries both the new loan and the held ones, which is Rust's rule
  that a `&'s mut &'a mut T` yields only `&'s mut T`.
- **Row 21 is not about results at all.** It is about owner-side loan
  *paths*. It is listed because "field-precise loans" (candidate layer
  1) can mean either side, and the two halves have different value
  (§3).

**Elision as precedent.** Rust's three elision rules are a *default
contract*, checked against the body:

1. each elided input gets its own lifetime;
2. one input lifetime goes to every output;
3. `&self`'s goes to every output.

Rig's default today is "every input", which needs no check. §2.4
proposes a better default that is still checkless (L0 and `produces`),
and leaves narrowing to a declared, checked `from`. That is Rust's own
split: a default that is cheap to read, and annotations where it is
wrong.

---

## 2. The origin model

### 2.1 Slots: Rust's lifetime positions, without names

Each Rust lifetime in a type marks a *position that holds a view*.
Rig's version is the **slot**: a path through a type to a position that
holds a view. `Slots(T)` is defined by the type's structure:

| Type `T` | `Slots(T)` |
|---|---|
| plain scalar, plain enum | ∅ |
| a view `?U`, `!U`, `[]U`, `![]U` | `{ε} ∪ *.Slots(U)`: ε is the view's own loan set; `*` is what its target holds |
| `String` | `{ε}` (it views a Text's bytes, which hold nothing) |
| `?fun(..)`, closure value | `{ε}`: one opaque slot for the lend and every capture (Rust's `impl Fn + 'a`) |
| struct `S{f₁: T₁ …}` | `∪ fᵢ.Slots(Tᵢ)` |
| enum | `V.fᵢ.Slots(Tᵢ)` for each variant payload field |
| `X?` | `Slots(X)` (transparent: `none` holds nothing) |
| `Box[T]` | `Slots(T)` (a unique owner: transparent) |
| `[N]T`, `Vec[T]` | `[].Slots(T)`: every element shares one slot, as `Vec<&'a T>` does |
| `*T`, `~T` | `rc.Slots(T)` collapsed to one slot: every handle carries its contents' loans (sentence 9); the contents never change except through a `Cell`, which holds no loan |
| `Cell[T]`, `Signal[T]` | ∅ (they accept no loan) |
| type variable `T` (in a generic body) | `{T}`: one opaque slot |
| `Text` | ∅ (it owns its bytes) |

- **Recursive types.** A path whose type repeats an enclosing type on
  the same path collapses onto that type's slot. For example, every
  `val` along `next: Box[Node]?` is one slot. This keeps `Slots(T)`
  finite, and it is what Rust programmers write by hand
  (`struct List<'a> { next: Option<&'a List<'a>> }`).
- **The two kinds of edge.** A slot path crosses two kinds of edge:
  - **owned** edges: field, payload, element, Box, handle, optional;
  - **view** edges: the `*` after a view.

  A view edge is **read** (`?`, `[]`, `String`, `?fun`) or **write**
  (`!`, `![]`).

### 2.2 Values and holders

- **The abstract value.** A value of type `T` is a map
  `Slots(T) → LoanSet`. A loan is `(root var, read|write)`, plus an
  *external token* `(param, slot)` for what the caller handed in.
- **Today's representation is the collapse.** It keeps one set per
  value, so it cannot tell `p.a` from `p.b`, nor a view of `x` from
  what `x` views. One exception: it already reaches *inner* loans by
  indirection. `?c` of an owned `c` carries a loan on `c`, and `c`'s own
  flow holds the loans of what `c` views. `holderLive` keeps those in
  force while the loan on `c` is (`deep1.rig` is rejected, correctly).
  §2.3 exploits this: with flat values, outer and inner are already
  apart whenever the argument is a lend of an owned local.
- **Composition.** Each step works on the map:
  - a field read projects it (`v.f` keeps the `f.*` part);
  - a constructor builds it;
  - a join unions it pointwise;
  - a store through a write view unions it into the target's slot (a
    weak update);
  - a local assignment replaces it (a strong update).

  A whole-value use touches every slot: copy, move, pass, `print(p)`,
  `==`, a `drop` body, `match`. A field read touches only its own
  (L1b, §3).

### 2.3 L0: the *carry* rule (supporting prefixes, type-directed)

**Definition.** For a view of target type `V`, `ownReach(H, V)` holds
when type `H` reaches an object a `V` view can point into through
**owned edges and write-view edges only**. Handles count as owned
edges, because a handle keeps its box alive. Type variables and
unknown types reach everything.

The rule. Take a value of view type `V` that carries a loan on holder
var `h` (not an external token):

- if `ownReach(type(h), V)`, the loan is kept;
- otherwise it is **replaced by `h`'s own loans**, recursively, so
  each of those is judged the same way;
- an external token on a parameter `p` is kept if `produces(type(p), V)`
  holds (loans.md 6.2), and dropped otherwise.

The rule applies wherever a view value is made:

- a lend of a place whose path crosses a read view (`?c.items[0]`);
- a call's result;
- what a call stores through a write argument.

**Why it is right.** This is Rust's supporting-prefixes rule, expressed
on types:

- a view reached *through a read view* held in `h` points into memory
  `h` does not own, so its liveness needs that read view's loans, not
  a loan on `h`;
- a view reached *through owned or write edges* needs the loan on `h`:
  - for owned edges, because the memory is `h`'s;
  - for write edges, because exclusivity runs through `h`, which is
    Rust's `&'s mut &'a mut T → &'s mut T`.

**One classifier.** Today's `addViewLoan`/`mayOwnText` is exactly this
rule, specialized to `V = String` (`H` reaches Text). `produces` is the
same rule applied to external tokens. L0 makes them one positive
classifier, `carry(loan, V)`, recorded once per expression. That meets
"one classifier per fact", and the rule follows the value's type only.

**What it fixes, with flat values:**

| Probe | How L0 fixes it |
|---|---|
| `cursor.rig` | `Cursor` reaches `Item` only through `?[]` |
| `deep2.rig` | `Pair` holds only `?Vec` |
| `prefix.rig` | the lend `?c.items[0]` carries `c`'s loans, not a loan on `c` |
| `method_key.rig`, `produces.rig` | an `Int` reaches no `Item` |

What it does not fix: same-typed arguments (`two`, `strip`, `cut`,
`firstmut`, `recur`, `generic`), stores (`store`), function values,
`split`.

### 2.4 Function summaries

A function `f` has:

- **inputs**: `{(p, σ) | p a parameter (self included), σ ∈ Slots(type p)}
  ∪ {env}` (a closure's captures) `∪ {static}`;
- **outputs**: `{(result, π)} ∪ {(p, π) | π reachable from p through a
  write view}`, the caller-visible places the callee may store into,
  plus the sink **`program`** (a Cell or Signal set, an owned-closure
  capture);
- **a summary** `Σ_f : Output → 𝒫(Input)`.

**Call rule.** At `f(a₁ … aₙ)`, write `Arg(aᵢ).σ` for the loans of
argument `aᵢ` at slot σ.

- **Result.** For each slot π, `result.π = ⋃ { Arg(a_p).σ | (p,σ) ∈
  Σ(result, π) }`. Add the callee value's own loans when
  `env ∈ Σ(result, π)`.
- **Write outputs.** For each `(p, π)`, the caller's places that
  `a_p`'s write loans lead to absorb `⋃ Arg(a_q).σ` (a weak update).
  This is today's `absorbThroughWrites`, narrowed.
- **The `program` sink.** Every `Arg(a_q).σ` with
  `(q,σ) ∈ Σ(program)` must be static, or the call is rejected
  (loans.md 6.1).
- **Unused loans.** Every argument loan that no output takes ends with
  the call's statement. It is a temporary under Core §3, so no new
  form is needed.

**Splitting an argument with flat values.**

| Argument | `Arg.ε` | `Arg.*` |
|---|---|---|
| a lend `?x` / `!x` of an owned local | the new loan on `x` | `flows[x]` |
| anything else | the whole value | the whole value |

The "anything else" case is a sound over-approximation. L1b (§3) makes
`Arg.*.f` precise.

**The layers, as choices of Σ:**

| Layer | `Σ(o)` | Needs body? |
|---|---|---|
| today | every input | no |
| `produces` / L0 | `{(p,σ) | carry/produces admits type at σ for type at o}` | no |
| **L2** inferred | the least Σ the body's walk produces (below) | yes |
| **L3** declared | what `from` names; checked `Σ_L2 ⊆ Σ_L3` | to check only |

**L2 inference.** It extends the external loan Rig already puts on each
lent parameter (`ownership.zig`, param setup):

- give `(p, σ)` its own token, at least `(p, ε)` and `(p, *)`, and with
  L1b one per slot;
- walk the body;
- at every exit, read which tokens are in each output: every
  `return`/tail for the result; every exit, failing ones and defers
  included, for write outputs and `program`.

The result slots count only on success. Stores count on every exit,
because a caller that `catch`es sees them.

**L3 declared.** One rule: *`from e` on an output says it views only
what `e` views.*

- `e` is a parameter or a path into one: `from a`, `from self.src`,
  `from v[]` for elements.
- `from p` names every slot at or below `p`: `(p, ε)` and every
  `(p, *.π)`.
- `from p.f` names only the slots inside the value at `p.f`.

So:

- `fun next(!self) -> ?Tok from self.src` is Rust's `-> &'a Tok` in
  `impl<'a> Parser<'a>`;
- `fun peek(?self) -> ?Int from self` is `-> &'s Int`.

`from p` includes `p`'s inner slots, as Rust's implied bound
`'b: 'a` on `&'a P<'b>` does, so nothing is lost there.

**Where `from` goes:**

- result: `-> ?V from a`;
- write parameter: `h: !Holder from x`, Rust's
  `h: &mut Holder<'a>, x: &'a I`;
- function type: `?fun(a: ?I, b: ?I) -> ?I from a`;
- `extern zig` declarations (trusted, as `raw` is).

Without `from`, the default is the L0/`produces` Σ.

### 2.5 Soundness

**Invariant (loan coverage).** Take any reachable state, any live
holder `h`, and any slot π of its type. If at run time the view at
`h.π` points into object `o`, then one of these holds:

- (a) `o` is static;
- (b) `o` lies in storage owned, through owned edges, by a var `x` in
  scope, and `flows[h].π` contains a loan on `x` or on a holder `g`
  whose value covers `o` by this same invariant;
- (c) `o` lies in memory the caller handed in through parameter `p` at
  slot σ, and `flows[h].π` contains the token `(p, σ)` or a loan on a
  holder covering it.

Together with the existing rules, the invariant gives no dangling view:

- conflicts: a loan on `x` blocks writes, moves, drops, and
  reassignment as sentence 5 says;
- holder liveness: a loan is in force while its holder may be used;
- escape: no surviving value carries a loan on a var whose scope ends
  (`checkEscape`, `escapeVarsFrom`).

The reason: whenever `o` is freed or changed, some live holder's slot
would carry a loan on its owner, and that is rejected.

**Lemma 1 (carry).** Replacing a loan on `h` by `flows[h]`, when
`¬ownReach(type h, V)`, preserves the invariant.

*Proof.* Outside `raw`, a view of target `V` reached from `h` follows a
path of projections typed by the type graph. Since no owned/write-only
path from `type h` reaches `V`, the path crosses a read-view edge.

- Let `w` be the last read view on it, and `o` the object it reaches.
- `o` lies in `w`'s target, which `w`'s loans cover by the invariant.
- `w` is held in `h` at some slot, so its loans are in `flows[h]`.
- No write edge after `w` needs `h`'s exclusivity, because a read view
  cannot reach a write path.

**Lemma 2 (summaries).** If every call inside `f` uses a sound
summary, then `Σ_L2(f)` covers every terminating execution of `f`:
whenever an output's view points into memory reached from input
`(p,σ)`, then `(p,σ) ∈ Σ(o)`.

*Proof.*
- Take the invariant inside `f`'s body, with each input slot's memory
  covered by its own token (case (c)).
- At each exit, the output's slots contain exactly the tokens the walk
  computed.
- Declared Σ: `Σ_L2 ⊆ Σ_L3` is checked.
- Default Σ (L0/`produces`): it is a superset of every well-typed flow,
  by Lemma 1 and the type argument of loans.md 6.2.
- Bodies that contain `raw`: they get the default, or a declared Σ
  taken on trust, as `extern zig` does.

**Recursion.** A self-call uses `f`'s own Σ.

- **Declared (L3).** This is assume–guarantee, as in Rust. Every
  *returning* execution has finite call depth. By induction on depth,
  the body check with the assumed Σ covers depth `d+1`, given that
  depth `d` satisfies it.
- **Inferred (L2 as the default).**
  - Compute the least fixpoint over each strongly connected component
    of the module's call graph:
    1. start every Σ at ∅;
    2. walk the bodies quietly;
    3. union;
    4. repeat until stable;
    5. then run one reporting walk, as `walkLoop` does today.
  - The walk is monotone in callee summaries, and the lattice is
    finite (outputs × inputs, with recursive types collapsed). The
    same induction on depth shows the least fixpoint is sound.
  - A non-returning execution has no result. A store it made before
    failing is on a failing exit, which is included.
  - Mutual recursion is the SCC case.
  - Modules form a DAG (a cycle is an error, SPEC §14), so summaries
    are computed in import order and exported in the module
    interface, as generic requirements are today.

**Function values.** A call through a value of function type uses the
*type's* Σ: its `from`, or the L0 default, plus `env` always.

- A named function or closure may be used at that type only if its own
  Σ ⊆ the type's, after renaming parameters by position. This is
  Rust's HRTB subsumption.
- A closure's `env` is always an input, so what it returns from its
  captures is carried. That is today's "callee loans" rule.
- The default type Σ is sound for every function value, because every
  body's Σ is a subset of the default.

**Generics.** A generic body is walked once, with `T` as one opaque
slot. At an instance, the slot `T` maps *pointwise* onto the instance
type's slots: `result.T.π ← arg.T.π`.

- Pointwise is sound because a generic body cannot project into a `T`.
  Per-instance checking records arithmetic, ordering, `==`, literals,
  and copies, never a field.
- If member access on a `T` is ever allowed, summaries must be
  recomputed per instance.

**Hazards a builder must handle:**

- **Self-loans.** With owner-side field paths (L1a), `self.items =
  ?self.own` no longer conflicts. Today it is rejected (`selfref.rig`).
  A value would then hold a loan on its own root. Such a store must be
  rejected, or make the root permanently lent (Rust's
  `&'a mut S<'a>`).
- **Whole-use completeness (L1b).** Every whole use must touch every
  slot. A `drop` body is a whole use (Rust's drop check). A missed one
  is unsound.
- **Write-view results** must never take the L0 replacement through a
  write edge. Lemma 1 relies on the last view crossed being a read
  view.

---

## 3. What each layer expresses

Rows are the probes from §1 that Rust accepts. ✓ = accepted. "L1a" is
owner-side loan paths (disjoint lends of `p.x` and `p.y`). "L1b" is
holder-side slot maps (§2.2).

| Probe | produces | L0 | L2 (2-level tokens) | L3 `from` | needs L1 |
|---|---|---|---|---|---|
| two, strip, cut, firstmut, recur, generic | – | – | ✓ | ✓ | – |
| method_key, produces | ✓ | ✓ | ✓ | ✓ | – |
| cursor, deep2 | – | ✓ | ✓ (with L0 in the body) | ✓ | – |
| prefix (intraprocedural) | – | ✓ | – | – | – |
| store | – | – | ✓ (store summary) | ✓ (`h: !Holder from x`) | – |
| split | – | – | ✓ only with L1b | ✓ only with L1b (and a per-field result clause, or L2) | L1b |
| funval, closure_ret | – | – | – (no body) | ✓ (`from` in the fun type) | – |
| disjoint | – | – | – | – | L1a |
| hr_store | – | – | – | needs `from` on a fun-type *parameter* and closure store summaries | – |
| owned_closure | – | – | – | – | sentence 9 |
| static_param | 6.1 inferred, or declared | | | | |

**Formal relations:**

- **Precision.** Outside `raw`, a body cannot make a flow that types
  forbid, so: `Σ_L2 ⊆ Σ_L0 ⊆ Σ_produces ⊆ Σ_today`.
- **L2 and L3 are equally expressive wherever there is a body.** L2
  computes the least `from`. L3 lets a programmer write that, or any
  superset. L2 adds convenience, not power.
- **L3 is strictly more expressive than L2** at bodiless boundaries:
  function types, `extern zig`, and a stable public contract.
- **L0 is the only layer that fixes an intraprocedural case**
  (`prefix.rig`). It is also the one that removes most of the need for
  path-precise `from` (`from self.src`). Such a `from` is needed only
  when the holder *also owns* the target type, as in
  `Parser{src: ?Vec[Tok], scratch: Vec[Tok]}`.
- **L1b liveness goes beyond Rust** (`pair.rig`, `mkpair.rig`: Rust
  rejects both). L1b's *parity* value is narrower: it is needed only
  for holders of two owners' views, as in `split.rig` and Rust's
  `Split<'a, &'b str>`.
- **L1a is the Rust parity item that is unrelated to results:**
  disjoint field lends.

**Design A versus design C.**

- **Design A:** the signature is the contract. The default is L0;
  `from` narrows it; L2 only checks `from` and suggests it in
  diagnostics.
- **Design C:** L2 inference is the default everywhere.

They accept the same programs once every narrowing `from` that A needs
is written. C to A is never a step, but A to C later only turns
rejections into acceptances. So **A first is the safe order**:

- it keeps checking modular, as Rust is, so no SCC fixpoint and no
  callers depending on bodies;
- it keeps "which arguments stay lent" visible in the signature, which
  is the North Star's "effects stay visible";
- it lets a diagnostic offer the exact fix: "`first` returns only a
  view of `a`; write `-> ?Vec[Int] from a` and `y` is free after the
  call".

C remains available for private functions if the annotations prove to
be noise in real programs. The std/text functions would want `from s`:
`strip_prefix`, `strip_suffix`, `cut`, `split`, `trim*` (the `trim*`
functions take one argument, so they need nothing).

---

## 4. The best combination, and what is left

**Best combination:** L0 + L3, checked by L2 + L1a + L1b (+ 6.1 for
`static`). It expresses everything in §1 that Rust accepts, except
these rows:

1. **Callbacks that store their argument** (row 15, `hr_store.rig`).
   - Rust ties `FnMut(&'a Item)` to `v: &'a [Item]`. Rig rejects every
     store of a closure parameter through a capture.
   - It could be closed: `from` on a function-type parameter
     (`f: ?sub(x: ?Item from v)`), plus a store summary for the closure
     literal that the call composes.
   - It costs about as much as L1b, and a `for` loop already says the
     same thing.
   - **Matters little** in Rig's loop-first style.
2. **Views inside owned closures, Cells, Signals** (row 16, and
   `Cell<&'a T>`).
   - Sentence 9 forbids them, so this is not an origins question.
   - It is closable by the rule `*T` already follows: a `*fun`, or a
     unique `Cell`, carries its contents' loans on every handle.
   - **Matters moderately**, for iterator adaptors returned as values
     and for event wiring over views.
3. **Branded (generative) lifetimes**: GhostCell, `for<'id>` index
   brands, `thread::scope`'s invariant `'scope`.
   - Rig has no type-level origin variables, so it cannot say "these
     two values share a brand".
   - **Matters little**: these are unsafe-backed library patterns. The
     part of `thread::scope` that matters, a callback whose views
     cannot escape, Rig's stack closures already guarantee.
4. **Per-field origins of a struct *result* in declared form.**
   - `-> Split from s, sep` is coarse. Rust writes `Split<'a, 'b>`.
   - Closed either by inference (L2) or by a per-field clause, for
     example `-> Split(rest from s, sep from sep)`.
   - **Matters only with L1b**, and only for constructors of
     two-owner holders.
5. **Not gaps, for the record:**
   - array and Vec elements sharing one slot (`Vec<&'a T>` does too);
   - recursive types collapsing to one slot (Rust needs polymorphic
     recursion to do better, and has none);
   - `split_at_mut`-style disjoint *index* lends (Rust needs a library
     function too);
   - the mutable cursor (Rust rejects it too).

**Where Rig is past Rust**, worth saying in BEYOND-RUST:

- per-path loans (NLL #3, built);
- field-precise struct liveness (with L1b);
- a lending iterator `fun next(!self) -> ?Item` into self's own buffer
  needs no GAT.

**Proposed Core sentence 7.** One paragraph, no exception list:

> **7.** A function returns a view only of what it was lent, or of
> something that lives for the whole program. A view carries the loans
> of what it views: a view through a read view (`?c.items[0]`, with
> `items: ?Vec[Item]`) carries `c.items`'s loans, not a loan of `c`. A
> call's result, and what it stores through a write argument, views
> what the arguments that could hold such a view view, or only those
> its signature names with `from`, which the checker proves from the
> body. Every other argument's loan ends with the call's statement.

**The desugaring, for INTERNALS.**

- `r = f(e₁, …, eₙ)` is `tᵢ = eᵢ` for each argument, as statement
  temporaries, then `r = f(t₁ … tₙ)`.
- `r` takes the slots of the `tᵢ` that Σ names. The rest end with the
  statement (Core §3).
- The checker rule is the call rule of §2.4. Nothing new is emitted.

**Order and cost** (rough, for the lead):

1. **L0** (~150–250 lines in `ownership.zig` and sema; it generalizes
   `addViewLoan`, `throughReadSlice`, and `walkCall`'s view tail).
   Low-to-medium risk, and the largest payoff. It needs the
   one-ownership-branch slot.
2. **L3 + L2-as-checker** (grammar `from`, sema storage, exit
   collection, call rule; ~400–600 lines).
3. **6.1 `program` sink**, on the same summary machinery.
4. **L1a** owner paths, with the self-loan rule.
5. **L1b** slot maps: the largest change, at the highest risk, and the
   least parity value. Do it last, or only when `split`-like code
   pushes for it.

---

## 5. A side finding (not origins)

`r = fx(!p)` with `fx(..) -> !Int` binds `r` as a **copy**. SPEC §7:
"a borrow of a number … reads as the value". So `r += 6` leaves `p.x`
unchanged:

- `reborrow.rig` prints `7` then `2 1`;
- the annotated `r: !Int = fx(!p)` writes through (`reborrow2.rig`
  prints `2 7`).

This follows SPEC, but the line shows a `!` and silently drops it. That
is worth a readability look, under "effects stay visible".

## Probe index

- **Rig** (`probes-formal/`):
  - **Rejected today, accepted by Rust:** `two` (parent dir), `strip`,
    `cut`, `firstmut`, `method_key`, `produces`, `generic`, `recur`,
    `deep2`, `cursor`, `prefix`, `split`, `store`, `funval`,
    `closure_ret`, `hr_store`, `hr_store2`, `owned_closure`,
    `static_param`, `disjoint`, `disjoint2`.
  - **Rejected, correctly or as Rust does:** `deep1`, `variance`,
    `selfref`, `selfref2`, `pair` and `mkpair` (Rust rejects both).
  - **Accepted:** `nll3b` (parent dir), `lexer`, `prefix2`,
    `reborrow`, `reborrow2`, `static_lit`.
- **Rust** (`probes-formal/rust/`):
  - **Accepted:** `accepted.rs` and `accepted2.rs` compile and run;
    `split.rs` compiles.
  - **Rejected:** `rejected_pair.rs`, `nll3.rs`, `cursor_mut.rs`,
    `invariance.rs`.
  - **Compiles and runs** (`11 6`): `disjoint.rs`.
