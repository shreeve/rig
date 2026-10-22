# Origins: prior art

How other languages say which inputs a returned or stored view depends
on, and what Rig should take or avoid. Role: prior-art survey for the
R3 origins question. Date: 2026-10-03.

Sources were checked on the web where a URL is given. Claims marked
**(memory)** were not re-verified for this report.

---

## 0. Bottom line

1. **Nobody gets this from bodies.** Every language with a stable
   story puts the dependency in the signature: Rust (lifetimes), Swift
   (`@lifetime`), Mojo (`ref[a]`), Dada (`ref[a]`), C++
   (`[[clang::lifetimebound]]`), Cyclone (`` `r ``), Austral (`[R:
   Region]`). Cyclone said why in so many words: without the body it
   cannot know which parameter `strcpy` returns, and it still did not
   look at the body. Rust calls this its golden rule. Swift resolves
   dependencies "at function declaration time". Mojo requires the
   origin on every returned `ref`. Two languages do infer from bodies,
   and neither checks anything with it: Clang's lifetime analysis does
   it to *suggest* annotations (experimental, a bug finder rather than
   a verifier), and Vale does it for regions (still a prototype).
2. **The "all lent arguments" default is mainstream, and it is the
   one that stays stable.** Hylo projects every argument that is not
   `sink`. Swift function types default to depending on every
   same-type parameter plus their captures. Sean Baxter's
   lifetime-free Safe C++ draft used it for free functions. Rust's
   2024 edition switched `impl Trait` to capture every lifetime in
   scope and made narrowing an opt-in list (`use<..>`). Rig's sentence
   7 is the same choice. What Rig lacks is the opt-in narrowing.
3. **The languages converge on one way to narrow: name the parameter
   (the place), not a lifetime variable.** Mojo writes `-> ref[a] T`
   and `ref[a, b]`. Dada writes `ref[a] String`, `ref[ch.name, ch1.name]`
   and `ref[self.list]`. Swift writes `@lifetime(copy a)`. Rust's own
   2026 roadmap plans place-based lifetimes (`'map`, `'self.text`).
   Rust's Polonius already defines an *origin* as a set of loans,
   which is exactly what Rig's checker tracks. A Rig clause such as
   `-> ?T from a` is the same idea in Rig's vocabulary. It is what
   Core sentence 7 already plans ("narrowing that to the loans its
   signature names").
4. **Type-based defaults are common and sound.** Rust's elision counts
   only parameters that carry a lifetime. Swift ignores `Escapable`
   sources and has a same-type default. P1179 uses type-aware defaults
   **(memory, details)**. This backs loans.md 6.2 (`produces`) as a
   rule that needs no syntax and follows the value's type.
5. **"100%" needs four pieces, and prior art has each of them:**
   (a) declared `from` with parameter names, (b) field-precise loans
   for locals, (c) a depth distinction: did the result view *the
   argument itself* or *what the argument views*? (Swift `borrow` vs
   `copy`; Baxter's "references to references" failure), and (d) the
   same clause for a write-lent parameter that receives a view (Swift
   `@lifetime(dst: copy src)`, Clang `lifetime_capture_by`). Without
   (c) and (d), some programs Rust expresses stay rejected.

---

## 1. The design space

| Axis | Options seen |
|---|---|
| What is named | lifetime/region variables (Rust `'a`, Cyclone `` `r ``, Austral `R`, Crubit `$a`); **places** (Mojo, Dada, Rust's planned place lifetimes, Swift's parameter names); positions (SPARK: "the first parameter") |
| Where it is written | on the result (Mojo `-> ref[a] T`, Dada); on the parameter (Clang `lifetimebound`, Austral's type args); as a declaration attribute (Swift `@lifetime(...)`) |
| Default when nothing is written | every input (Hylo, Swift function types, Baxter, Rust RPIT 2024); a single input or `self` (Rust elision, Swift single-parameter rule); same type (Swift); heap or static (Cyclone returns); none, so annotation is required (Mojo returns, Rust with several inputs) |
| Inference | none across signatures (Rust, Swift, Mojo, Cyclone, Austral); local only (all of them inside a body); from bodies as a *suggestion* (Clang); from bodies, in a prototype (Vale) |
| Function values | the dependency is part of the function type, with subset subtyping (Swift); origin parameters inferred at the indirect call (Mojo 1.0); lifetimes in `fn` types (Rust `for<'a>`) |
| Depth | `copy` vs `borrow` (Swift); separate lifetimes per layer (Rust `&'a &'b T`); none (Baxter, which is why he gave up) |
| Other outputs (a view stored into an argument) | Swift `@lifetime(dst: copy src)`; Clang `lifetime_capture_by(X)`; Rust via shared lifetime variables |

---

## 2. Language by language

### 2.1 Swift: `~Escapable` and lifetime dependencies

**Status.** SE-0446 (`~Escapable`) is implemented in Swift 6.2, and it
explicitly defers dependency syntax. The dependency attribute is
experimental: `@_lifetime` behind `-enable-experimental-feature
Lifetimes`. It was announced as a "supported experimental feature" in
March 2025, with a promise that it stays usable for three releases
after deprecation. Pitch #3 (Feb 2026, "Compile-time lifetime
dependency annotations") supersedes the earlier proposal PR #2750.

**Syntax.** `@_lifetime(target: <scope> source)`, where
`<scope> ::= borrow | & | copy` and the target defaults to the
result:

```swift
@_lifetime(copy a)            // result inherits a's dependencies
func first(a: Span<Int>, b: Span<Int>) -> Span<Int>

@_lifetime(borrow self)       // result depends on the access to self
func span() -> Span<T>

@_lifetime(dst: copy dst, copy src)   // an inout parameter is a target too
func store(dst: inout Span<Int>, src: Span<Int>)

@_lifetime(immortal)          // depends on nothing: lives for the program
```

- **`borrow` and `&`** start a new access to the caller's argument,
  shared or exclusive, held for every use of the target. This is
  Rig's lend.
- **`copy`** passes the argument's *existing* dependencies on to the
  target. This is Rig's "the result carries the loans the argument's
  value already holds".
- **Checking.** "The `@lifetime` annotation is enforced both in the
  body of the function and at each call site."

**Defaults.** Swift introduced defaults slowly, "after developers have
enough experience" ([LifetimeAnnotation.md][swift-guide]):

- *same type*: if the result type equals a parameter type, the default
  is `copy a`;
- *single parameter*: `borrow a`, or `&a` when `a` is inout;
- every `~Escapable` inout parameter gets `a: copy a` implicitly;
- an implicit setter or memberwise init copies from its arguments;
- **function types** default to `copy` of every parameter plus
  `captures`, the closure's context.

**Type-based filter.** Dependencies whose source or target is
`Escapable` "may be ignored". A value that cannot carry a dependency
contributes none. This is loans.md 6.2's `produces` in Swift's terms.

**Function values.** The dependency is part of the function type. For
conformance and for conversion, "the interface has a superset of the
function's lifetime dependencies": a function depending on `a` can be
used where the type says `a, c`. `immortal` matches any interface.
There is one known gap: assigning a `copy`-annotated function to a
`borrow`-typed variable is sound but not implemented
([forums, Aug 2026][swift-subtyping]). Function types have no argument
labels, so annotations name internal parameter names.

**FFI.** Imported C and C++ APIs get dependencies from
`lifetimebound` or `lifetime_capture_by` annotations in headers
**(memory)**.

**API stability.** Dependencies come from the declaration only, never
from the body. They are fixed "at function declaration time", and
generic context at the call is not considered. Narrowing an annotation
later breaks callers' bodies. Widening it breaks callers.

**Pain points and reception.**
- More than two years in pitches, still underscored and experimental.
- People worry it is "Rust lifetimes again". A forum quote: "Lifetimes
  are easily one of the most tricky parts of Rust to understand."
- A suggestion to move the attribute onto the result type, near what
  it describes.
- Conditionals: a dependency on a `var` is a dependency on an access
  to it, so it can be conditional. Ternaries that consume both
  branches are an acknowledged "implementation deficiency"
  ([forums][swift-cond]).
- The inout default is subtle enough that it was redesigned.
- Swift uses one dependency set per value, with no per-field
  lifetimes on a struct **(memory; per-component dependencies are a
  listed future direction)**.

**For Rig.** `copy` vs `borrow` is the depth axis Rig lacks. Two
things fit Rig directly: function-type defaults to "all, plus
captures" with subset subtyping, and the inout-as-target idea for a
`!` parameter that receives a view.

### 2.2 Mojo: origins

**Status.** Mojo 1.0 shipped on 2026-08-11. Origins were called
*lifetimes* until 2024 **(memory, rename date)**.

**Syntax** ([manual][mojo-origins]):

```mojo
def __getitem__(ref self, index: Int) -> ref[self] String: ...
def pick(ref a: String, ref b: String) -> ref[a, b] String: ...  # union
struct Span[mut: Bool, //, T: AnyType, origin: Origin[mut]]: ...
```

- **Declared:** a returned `ref` *must* name its origin, using
  argument names directly, or `origin_of(x)`.
- **Inferred:** the origins of `ref` *arguments*, as inferred
  compile-time parameters.
- **Unions:** `ref[a, b]`. A union is mutable only if every member is.
- **Struct origins:** origins are explicit struct parameters
  (`Span[..., origin]`), as Rust's lifetime parameters are.
- **Special origins:** `ImmStaticOrigin` (literals), untracked origins,
  and unsafe wildcard origins.

**New in 1.0.**
- *Interior origins* (experimental): `List`, `Dict` and `String`
  element refs are bound to an interior origin, so holding one across
  a mutation is rejected.
- Dynamic function pointers with unbound origin parameters can be
  called. The compiler infers the parameters from the call's
  arguments and specializes before the indirect call
  ([1.0 notes][mojo-1]).
- Unified closures declare an explicit capture list `{...}`. The
  closure's type carries the origins of its captures
  ([Mojo forum][mojo-closures]).
- The implicit conversion to `UnsafeAnyOrigin` is deprecated.
  "Origins are now preserved", which pushes users to spell origins.

**Pain points.** Origin parameters on structs read like Rust lifetimes
with another name, and appear all through library signatures. Users
found the rename and the parametric mutability (`Origin[mut]`) hard
**(memory: forum reception)**.

**For Rig.** `-> ref[a] T` names the argument at the result. It is the
closest existing syntax to Rig's planned clause. Rig should *not* use
its bracket form; see §4.

### 2.3 Hylo (formerly Val): no first-class references

There are no reference types. Subscripts `yield` projections; bindings
`let`, `inout` and `sink` project or consume; "remote parts" and
stored projection types `[let T]` and `[inout T]` let objects capture
projections ([spec][hylo-spec]).

- **Dependency rule** (spec §Projections 6): "The projection yielded
  by a `let` or `inout` subscript call or property access projects the
  arguments bound to the subscript or property's parameters."
  - The example `let z = min[x, y]` projects *both* `x` and `y`.
  - Arguments to `sink` parameters are consumed, not projected.
  - So Hylo has exactly Rig's sentence 7, filtered only by passing
    convention, and accepts the same false rejections.
- **Captures:** "An object may capture a projection at its
  initialization"; the captured projections of a product type are
  those used to initialize it. That is Rig's pair.rig over-approximation.
- **Inference:** each binding's dependency set is computed inside the
  body, through the transitive "extended live range" R+(b)
  ([discussion #754][hylo-754]). Nothing is inferred from callee
  bodies.
- **Pain points.** Remote parts "aren't allowed to escape their local
  scope", and are limited to structural types and memberwise
  initializers. There is no syntax to narrow a projection's
  dependencies.

**For Rig.** Hylo validates Rig's starting point. It also shows the
ceiling: with no narrowing syntax, `min[x, y]`-shaped false rejections
are permanent.

### 2.4 Vale: regions

- **Status:** "Regions as a whole are still a work-in-progress";
  immutable region borrowing is prototyped ([part 1][vale-1]).
- **Syntax:** `pure func printShipNames<r'>(tenShips &r'List<r'Ship>)`.
  Region markers "are often inferred by the compiler, and usually not
  seen in Vale code".
- **Model:** regions are coarse, about *whether data may change*
  (immutable regions skip generation checks). They are not about
  which argument a result views. Memory safety rests on generational
  references at runtime; regions remove checks. They are not the
  soundness argument.

**For Rig.** Little applies. Vale can infer because a wrong region
costs a runtime check, not soundness. Rig has no such fallback.

### 2.5 C++

**`[[clang::lifetimebound]]`** marks a *parameter* (or `this`) whose
referent the result may view ([LifetimeSafety][clang-ls]).
**`[[clang::lifetime_capture_by(X)]]`** marks a parameter whose
referent is stored into `X` (`this`, another parameter, or global).
That second output channel is the one Swift's inout targets cover.

**Clang Lifetime Safety analysis.**
- A Polonius-inspired, intra-procedural data-flow analysis of loans
  and origins.
- Unannotated calls are treated optimistically: they are assumed to
  have no lifetime effect.
- It *suggests* `lifetimebound` from bodies (`-Wlifetime-safety-suggestions`).
- Experimental TU-wide inference: `-flifetime-safety-inference`.
- Its own description: "designed for bug finding, not verification".

**P1179 lifetime profile** (Sutter, MacIntosh).
- Tracks psets: points-to sets of owners.
- Default: a returned Pointer derives from the function's inputs.
- Uses type-aware defaults to reduce false positives
  ([P1179R1][p1179]). **(memory: the exact filter is the input
  Pointers and Owners whose pointee type is compatible with the
  return.)**
- Overridden by attribute contracts **(memory: the spelling changed
  across revisions)**.
- Shipped as MSVC's `/analyze` lifetime checker and an experimental
  Clang fork. It was never a sound checker, and the profiles effort
  has been strongly criticised ([circle-lang "Why Safety Profiles
  Failed"][profiles-failed]).

**Safe C++ draft "Memory Safety without Lifetime Parameters"**
(Baxter, Oct 2024) ([safecpp][baxter]). This is the closest experiment
to Rig's current rule.
- Free functions: every reference parameter constrains the return.
- Members: only `this` does.
- His conclusion: the scheme is "under-specified when dealing with
  references to references", and lifetime parameters are "the only
  known viable solution for first-class safe references without
  garbage collection".

His failure case is the depth axis (§3.3). Rig avoids the
"first-class" part, because views cannot be stored in owning
containers forever and are tracked per value. It still meets the
depth question.

**Crubit** (Google) ([design][crubit]): Rust-style lifetimes for C++
via `[[lifetime(a)]]` or `$a`, with Rust's elision. A tool infers the
annotations from current bodies, *once*, as a migration aid.

**For Rig.**
- Clang's *suggestion* mode is the right use of body inference:
  compute it, then propose the clause in a diagnostic.
- `lifetime_capture_by` names a real gap: views stored into a `!`
  argument.
- Baxter's paper is the warning that an all-inputs default without a
  depth distinction does not scale to layered views.

### 2.6 Rust

**Elision** ([reference][rust-elision]):
- each elided input gets its own lifetime;
- if there is exactly *one* input lifetime, the output gets it;
- if there is `&self` or `&mut self`, the output gets self's lifetime;
- otherwise you must annotate (`fn frob(s: &str, t: &str) -> &str` is
  an error).

So `fn substr(s: &str, until: usize) -> &str` works: `usize` has no
lifetime. That is a type-based filter. Rust's default for several
inputs is "write it", not "all of them".

**Golden rule.** "The signature is right and the body is wrong"; Rust
does not infer signatures, so errors stay local
([Klabnik][golden]). The exception, impl-Trait auto-trait leakage
(`Send` leaks from the body), is a well-known API-stability hazard
([Atkinson][golden-no]).

**`impl Trait` captures.** The 2024 edition changed the default to
capture *all* in-scope generic and lifetime parameters, with precise
capturing `+ use<'a, T>` (Rust 1.82) to narrow ([edition
guide][rpit]). The rationale is consistency: everything else already
captured all. The lesson for Rig: Rust tried "capture only what is
named" as the default, reverted to "all, narrow by list", and made
narrowing a promise in the signature.

**NLL and Polonius.**
- NLL rejects problem case #3; Polonius accepts it.
- Polonius Alpha was enabled on nightly in Aug 2026, with
  stabilization expected by year end ([blog][polonius-blog]).
- Polonius reformulates `'a` as an **origin**, a set of loans such as
  `shared(a.b.c)` ([Matsakis, "Borrow checking without
  lifetimes"][bcwl]). Rig's per-value loan sets *are* Polonius origins,
  computed per path, which is why Rig already accepts problem case #3
  (nll3b.rig runs).

**Roadmap "The borrow checker within"** ([goals 2026][bcw]):
- *view types* (in experiment): `&{golden_tickets} self`, a method
  that touches only some fields;
- *place-based lifetime syntax* (future): "lifetimes that name their
  source, such as `'map` or `'self.text`";
- *internal references* (`&'self.text str`).

Rust is moving from lifetime variables toward naming places, the
direction Rig starts from.

**Pain points (memory, widely reported).**
- Lifetime parameters on structs spread to every user.
- `'a` puzzles for beginners.
- `fn get(&mut self) -> &T` keeps `self` *exclusively* borrowed while
  the result lives. There is no downgrade from exclusive to shared.
  The soundness reason is interior mutability: `Cell::get_mut` or
  `Mutex::get_mut` can turn exclusive access into a view of contents
  that a shared handle could later change. Rig has this limit too
  (probe `downgrade.rig`, below), and has `Cell`, so any downgrade
  rule needs the same care.
- Struct-wide borrows when only one field is used (fixed per place for
  locals by NLL; across calls only by view types).

**For Rig.** Take Rust's direction (places) rather than its past
(`'a`). Keep the "all, narrow by list" default from RPIT 2024. Keep
the golden rule.

### 2.7 Dada (Matsakis's research language)

**Permissions** `my`, `given`, `shared`, `ref[place]`, `mut[place]`
([internal references][dada-ir]):

```dada
fn character_and_name(ch1: given Character, name1: ref[ch1] String) { ... }
class Message(list: String, items: Vec[ref[self.list] String])
// after a join: name has type ref[ch.name, ch1.name] String
```

- **Named:** places, including field paths.
- **Unions:** written by the user, or produced by the type inferencer
  at joins.
- **Strong updates:** moving the source re-types the views.

This is the fullest "name the place" design. It also shows the cost:
the place sets are *types*, so they appear in type annotations and in
diagnostics.

**For Rig.** It confirms field paths as origins (`from p.a`) are a
coherent extension. Rig keeps place sets out of types, in the checker,
and writes them only at function boundaries.

### 2.8 Ada / SPARK: observers and borrowers

There is no syntax for dependencies; a positional rule stands in for
it ([SPARK UG 5.9][spark]).

- **Observer:** an anonymous access-to-constant view. It may not be
  stored in composite types.
- **Traversal function:** "The value returned by the function should
  be a part of the first parameter". The *first parameter* is the
  only source.
- While the result lives, that parameter is read-only (observer) or
  inaccessible (borrower).
- Pledges (`At_End_Borrow`) relate a borrower to its parameter in
  postconditions, for proof.

**For Rig.** A positional default is simple and rigid. It cannot say
"from the second argument" at all. Avoid it.

### 2.9 Cyclone: regions

([manual][cyclone]; [Grossman et al.][cyclone-paper])

**Syntax:** `int *`r p`; region variables are implicitly generalized.

**Defaults.**
- "in function-argument types, a fresh (polymorphic) region name is
  used, while in function-return types, `` `H `` is used", meaning the
  heap.
- The manual says of `strcpy`, which returns a parameter: "we cannot
  determine which parameter (or component of a parameter) the function
  might return" without the body. So it must be annotated.

**Inference** is intraprocedural only. There are region subtyping
(outlives) constraints and effects (`regions_of`) for generics.

**Reception.** Expressive, but the annotation burden and the error
messages were the main complaints **(memory)**. Rust inherited and
simplified it.

**For Rig.** A default of "static" for results would reject every view
result. Rig's "all lent" default is strictly friendlier. Cyclone's
refusal to read bodies is deliberate and matches everyone else's.

### 2.10 Austral: linear types and lexical regions

([tutorial][austral])

- A reference type is `&[T, R]`, or `&![T, R]` for writing, for a
  region `R`.
- The region is introduced by a lexical `borrow x as x' in R do ... end`.
- Functions are generic over regions: `generic [R: Region] function
  length(buf: &[ByteBuffer, R])`.
- References cannot leave the borrow statement, because "Reg is not
  known to the compiler outside".
- There is no inference beyond ordinary type-argument inference.

**For Rig.** Austral is maximally explicit and lexical. That is the
opposite of Rig's last-use loans and readability goals. It shows the
cost of naming regions as types.

### 2.11 Carbon

There is no lifetime design yet. The project states a safe subset is
long-term and "won't be in the 0.1 design", and it is "watching"
Rust-style annotations ([summary][carbon]) **(memory: no newer safety
proposal found as of Oct 2026)**.

### 2.12 Zig

There is no tracking at all. Slices and pointers carry no provenance.
This matters to Rig only at `extern zig`: SPEC trusts the Rig
signature of a Zig-backed std function, and treats a view result with
no view parameter as living for the whole program. A declared `from`
on an `extern zig` declaration would be a trusted promise in the same
way, which is fine because only std may declare one.

---

## 3. The Rig problem classes, mapped to prior art

Probes are in `probes-prior-art/`. Each was run with `bin/rig check`
on the revamp build; accepted ones were run with `RIG_SANITIZE=1`.

| Probe | Today | What it needs | Who solves it, how |
|---|---|---|---|
| `two.rig`: `first(?x, ?y)` returns a | rejected | declared narrowing | Mojo `ref[a]`, Swift `copy a`, Rust `'a`, Dada `ref[a]` |
| `index.rig`: `pick(?rows, ?i) -> ?Row`, then `i = 0` | **rejected** | type filter (an `Int` cannot produce a `Row`) | Rust elision (only reference-typed inputs count), Swift (`Escapable` sources ignored), loans.md 6.2 |
| `pair.rig`: `Pair(a: ?x, b: ?y)`, write `y`, read `p.a` | rejected | field-precise loans on locals | Rust only with one lifetime parameter per field (`Pair<'a, 'b>`); with one `'a` it rejects too. Dada place paths; Hylo does *not* |
| `nested.rig`: `left(p: ?Pair) -> ?Vec[Int]` returns `p.a`, then reassign `p` | **rejected** | depth: the result copies a view `p` *holds*; it does not view `p` | Swift `copy p` vs `borrow p`; Rust `&'a Pair<'b> -> &'b Vec`; Baxter's scheme failed here |
| `downgrade.rig`: `bump(!c) -> ?Vec[Int]`, then read `c.n` | rejected | write-to-read downgrade | Rust rejects it too (unsound with `Cell::get_mut`); Swift distinguishes `&` from `borrow` but does not downgrade **(memory)** |
| `store2.rig` / `store3.rig`: `put(!h, ?b)` stores `?b` in `h.v` | store2 correctly rejected; **store3 rejected** (writing `a`, no longer viewed) | a `!` parameter as a dependency *target*, with replacement | Swift `@lifetime(h: copy x)` plus `immortal` for full replacement; Clang `lifetime_capture_by` |
| `funval.rig`: `apply(?first, ?x, ?y)` | accepted | a `?fun` type with no `from` means "all" | Swift: function types default to all plus captures; subset subtyping |
| `nll3b.rig` | accepted, runs clean | — | Rig matches Polonius here, ahead of Rust stable |

`nested.rig` is the important new class. Under any "from the
argument" rule the result carries the call's own loan on `p`, even
though the result's type can only be reached through `Pair`'s *view*
fields. The type graph can tell these apart:

- a result reachable only through view fields gets only the loans the
  argument's value carries (Swift's `copy`);
- a result reachable through an owning path gets the call's own loan
  too (Swift's `borrow`).

This is a type-based rule, so it fits "rules follow the value's type".
It extends `produces` (6.2) from one bit (produces or not) to two (by
which kind of path). It needs the checker to keep, at the call, the
lend's own loan separate from the loans the lent value carries. The
checker owner should confirm that it does.

---

## 4. What fits Rig, and what to avoid

### Adopt

1. **Keep "everything it was lent" as the default** (sentence 7). This
   is backed by Hylo, Swift function types, Baxter's default, and Rust
   RPIT 2024's "capture all". It is sound, needs no syntax, and is the
   stable default: a narrower one becomes a promise when it is
   written, and an inferred one would change when the body does.

2. **Declared narrowing that names parameters, at the result:**

   ```rig
   fun first(a: ?Vec[Int], b: ?Vec[Int]) -> ?Vec[Int] from a
   fun pick(t: ?Table, k: ?Key) -> ?Row from t
   fun either(a: String, b: String, c: Bool) -> String from a, b
   ```

   - **Reading:** it reads as English (Python and Ruby goal). It sits
     beside the result it describes; Swift users asked for exactly
     that, against Swift's detached attribute.
   - **Lexing:** `from` is not a keyword today. Like `of`, it can be
     contextual: a keyword only after a function's result type.
   - **Semantics:** this is Mojo's `-> ref[a] T` and Dada's
     `ref[a] T`, written as a clause.
   - **Desugaring** (for INTERNALS):
     - At a call, the result's loan set is the union of the named
       arguments' loans, not all arguments'.
     - In the body, every returned value's `ext` loans must be on
       named parameters; this is today's `checkEscape`, with the
       parameter set narrowed.
     - Nothing else changes. Both halves are checks the checker
       already makes on a smaller set, so it is the "planned" half of
       sentence 7. The Core paragraph needs no exception list: "A
       function's result carries the loans of the arguments its
       signature names after `from`, or of every argument it was
       lent."
   - **Why not Mojo's or Dada's bracket form (`?[a] Vec[Int]`):**
     Rig's brackets mean "known at compile time", and `?[4]Int`
     already means a view of an array. `?[a]Int` beside `?[N]Int`
     would be ambiguous to a reader, and it puts origins into the
     type, which Rig keeps out.

3. **The type filter as the default refinement** (loans.md 6.2). It is
   backed by Rust elision, Swift's `Escapable` rule, and P1179's
   type-aware defaults. It is sound, needs no syntax, and follows the
   type. Extend it with the depth rule above (Swift's copy vs borrow,
   derived from the type graph rather than written). It fixes
   `index.rig` and `nested.rig` without any annotation.

4. **Field-precise loans for locals.** Loan sets are keyed by field
   path, and Polonius-style loans are already path-shaped
   (`shared(a.b.c)`). This fixes `pair.rig` inside one function, with
   no syntax. Rust gets the same precision only by giving `Pair` one
   lifetime parameter per field, so Rig would beat Rust here without
   writing anything. Do *not* add
   per-field origins to struct types (Rust's `Pair<'a, 'b>`, Mojo's
   struct origin parameters). That is where those languages' signature
   noise comes from. Across a call, `from p.a` (a Dada or Rust-roadmap
   place path) is a natural later extension once parameter names work.

5. **Function values: Swift's rule.**
   - A `?fun(...)` or `*fun(...)` type without `from` means "all
     arguments, plus the closure's captures"; today's behavior keeps
     `funval.rig` accepted.
   - A function declared `from a` converts to a type naming a superset:
     fewer dependencies is a subtype. That conversion is free and
     sound.
   - The reverse conversion is rejected at the conversion.
   - A function type that wants `from` names its parameters
     (`?fun(a: ?T, b: ?T) -> ?T from a`). Swift learned that function
     types without names force awkward internal-label rules.
   - Mojo's "infer the origin parameters at the indirect call" needs
     origins in types. Skip it.

6. **Body inference only as a diagnostic.** This is Clang's
   `-Wlifetime-safety-suggestions` pattern. When a call keeps an
   argument lent and the callee's body shows its result never carries
   that argument's loans, the error says so and offers the clause:

   ```text
   cannot write-borrow `y` while a read borrow is live
     note: `first` returns a view of `a` only; declare it:
       fun first(a: ?Vec[Int], b: ?Vec[Int]) -> ?Vec[Int] from a
   ```

   Callers never depend on bodies, so the golden rule, Swift's
   declaration-time resolution, and local errors are kept. Effects
   stay visible (Rule 4): the narrowing is written where it happens.

7. **The same clause for a `!` parameter that receives a view**
   (Swift's inout targets, Clang's `lifetime_capture_by`). This is the
   `store3.rig` class. It needs a spelling for "h's new contents come
   from x", for example `sub put(h: !Holder, x: ?Vec[Int]) h from x`.
   It is lower priority than result origins, so design it after them,
   and do not invent a second mechanism.

### Avoid

- **Lifetime or region variables** (`'a`, `` `r ``, `[R: Region]`,
  `$a`). Every language that has them reports them as the hardest part
  to learn, and Rust itself is moving to place names.
- **Exported body-inferred origins.** They make a body edit a breaking
  API change: Rust's auto-trait leakage is the cautionary tale, and
  every surveyed language with stable APIs refuses them. They also
  move errors to callers. A module-private variant is tempting, but it
  still makes the checker interprocedural (fixpoints, recursion
  guards), and it breaks "one classifier per fact" across functions.
  If it is wanted at all, gate it on non-`pub` functions, and only
  after the declared form exists.
- **Positional or receiver defaults** (SPARK's "first parameter";
  Rust's and Baxter's `self` rule as the *default*). The `self` rule
  is Rust's most-loved elision. In Rig, though, changing the default
  would newly reject bodies accepted today, a change in meaning that
  the feature freeze forbids. A declared `from self` gets the benefit
  without changing the default.
- **A write-to-read downgrade rule.** Rust's experience shows it is
  unsound once interior mutability exists, and Rig has `Cell`. Do not
  do this without a proof that no path from a `!` lend yields a view
  into a `Cell`'s contents.
- **Unchecked annotations** (Clang `lifetimebound` is a promise the
  body is not held to; P1179 is a bug finder). Rig's `from` must be
  checked against the body, as Swift's is. The only exception is
  `extern zig` in std, which is trusted like the rest of its
  signature.
- **Origins in types** (Dada's `ref[a] T`, Mojo's struct origin
  parameters). They are precise, but they put the checker's sets into
  every annotation and error. Rig's strength is that a view type is
  just `?T`.

---

## 5. Open questions for the design team

1. **Does `from` need Swift's `copy` vs `borrow` split in syntax?**
   The depth rule in §3 derives it from the type graph. Is there any
   Rig type where both kinds of path reach the result type, so the
   author must say which? Example: a struct with both an owned
   `Vec[Int]` and a `?Vec[Int]` field, returning `?Vec[Int]`. If so,
   `from a` stays the union, and a finer `from a.f` (a place path)
   resolves it, rather than a new keyword.
2. **A spelling for "lives for the whole program"** (Swift
   `immortal`, Mojo `StaticConstantOrigin`). Does a function lent
   arguments, whose result views only literals, need `from` with an
   empty list? `none` is already the absent optional, so reusing it
   would mislead. This may be unnecessary if loans.md 6.1's static
   fact covers the cases that occur.
3. **Generic instances:** with `T` reaching anything, `produces` says
   yes, so a generic function's narrowing comes only from `from`.
   Swift had the same issue ("resolved at declaration time, generic
   context at the call not considered").
4. **Methods:** is `from self` common enough to deserve a default
   later, as a *new* declaration-site rule rather than a change to
   existing code? Rust's data suggests it would remove most
   annotations in practice. Defer until real programs show it.

---

## Sources

- Swift SE-0446 Nonescapable types: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md
- [swift-guide] Swift `@_lifetime` reference guide: https://github.com/swiftlang/swift/blob/main/docs/ReferenceGuides/LifetimeAnnotation.md
- Swift lifetime dependencies proposal PR #2750 (closed, superseded by #3146): https://github.com/swiftlang/swift-evolution/pull/2750
- Swift experimental support announcement (Mar 2025): https://forums.swift.org/t/experimental-support-for-lifetime-dependencies-in-swift-6-2-and-beyond/78638
- Swift Pitch #3 (Feb 2026): https://forums.swift.org/t/pitch-3-compile-time-lifetime-dependency-annotations/84968
- [swift-cond] Lifetime dependencies and conditionals: https://forums.swift.org/t/lifetime-dependencies-and-conditionals/83594
- [swift-subtyping] Lifetime annotations and function subtyping: https://forums.swift.org/t/lifetime-dependency-annotations-and-function-subtyping/89243
- [mojo-origins] Mojo manual, lifetimes and origins: https://mojolang.org/docs/manual/values/lifetimes
- [mojo-1] Mojo 1.0 release notes: https://mojolang.org/releases/v1.0.0/
- [mojo-closures] Mojo closures 2026: https://forum.modular.com/t/mojo-closures-2026/3013
- [hylo-spec] Hylo specification: https://github.com/hylo-lang/specification/blob/main/spec.md
- [hylo-754] Hylo remote parts and closure captures: https://github.com/orgs/hylo-lang/discussions/754
- [vale-1] Vale immutable region borrowing: https://verdagon.dev/blog/zero-cost-borrowing-regions-part-1-immutable-borrowing
- [clang-ls] Clang Lifetime Safety: https://clang.llvm.org/docs/LifetimeSafety.html
- Clang intra-procedural lifetime analysis RFC: https://discourse.llvm.org/t/rfc-intra-procedural-lifetime-analysis-in-clang/86291
- [p1179] P1179R1 Lifetime safety: https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2019/p1179r1.pdf
- [profiles-failed] Why Safety Profiles Failed: https://www.circle-lang.org/draft-profiles.html
- [baxter] Memory Safety without Lifetime Parameters: https://safecpp.org/draft-lifetimes.html
- [crubit] Crubit lifetime annotations for C++: https://crubit.rs/design/lifetime_annotations_cpp.html
- [rust-elision] Rust reference, lifetime elision: https://doc.rust-lang.org/reference/lifetime-elision.html
- [rpit] Rust 2024 RPIT capture rules: https://doc.rust-lang.org/edition-guide/rust-2024/rpit-lifetime-capture.html
- [golden] Rust's Golden Rule: https://steveklabnik.com/writing/rusts-golden-rule/
- [golden-no] Rust doesn't actually follow its Golden Rule: https://lukasatkinson.de/2023/rust-no-golden-rule/
- [polonius-blog] Polonius alpha on nightly (Aug 2026): https://blog.rust-lang.org/2026/08/04/enabling-polonius-alpha-on-nightly/
- [bcwl] Borrow checking without lifetimes: https://smallcultfollowing.com/babysteps/blog/2024/03/04/borrow-checking-without-lifetimes/
- [bcw] The Borrow Checker Within roadmap (2026): https://goals.rust-lang.org/2026/roadmap-borrow-checker-within.html
- Rust view types: https://smallcultfollowing.com/babysteps/blog/2021/11/05/view-types/
- [dada-ir] How Dada enables internal references: https://smallcultfollowing.com/babysteps/blog/2026/02/27/dada-internal-references/
- [spark] SPARK UG 5.9, pointers and ownership: https://docs.adacore.com/spark2014-docs/html/ug/en/source/access.html
- [cyclone] Cyclone for C programmers: https://www.cs.umd.edu/projects/cyclone/online-manual/main-screen002.html
- [cyclone-paper] Region-based memory management in Cyclone: https://www.cs.umd.edu/projects/cyclone/papers/cyclone-regions.pdf
- [austral] Austral borrowing: https://austral-lang.org/tutorial/borrowing
- [carbon] Carbon safety summary: https://develop.secure.software/carbon-aims-to-fix-c-memory-safety-and-other-big-flaws
