# Origins: one recommended design (synthesis, simplicity lens)

Decision paper for the language owner. It answers: *how does Rig say
which values a view comes from, and how do we close "Rust can say which
argument a result views, and Rig cannot" completely?*

Inputs: `formal.md`, `prior-art.md`, `fit.md`, `impl.md`,
`red-team.md` (all in this folder), CORE, BEYOND-RUST, DESIGN ("Lend,
view, loan", "Borrows without lifetimes"), AGENTS "How we build", and
`core-audit/loans.md` §6. Every Rig claim here was checked with
`bin/rig check` on the revamp worktree (`d29be15f`), or is quoted from
a report that checked it. My own probes are in `probes-simplicity/`
(`s1`–`s4`).

Vocabulary: *lend* is the act, *view* the value, *loan* the owner-side
record. Existing diagnostics still say "borrow"; the new messages below
use the new words.

---

## 0. The decision on one page

**The gap is real, but it is narrow, and closing it needs no
lifetimes.** Rig already tracks per value the set of loans it carries.
Polonius, Rust's newer checker, calls such a set an *origin*. Rig is
missing precision, not a concept. The checker computes the exact answer
inside every function body and then throws it away at the call.

**The design, in three ideas a user can hold in their head:**

1. **A view comes only from what could hold it.** No syntax. One
   classifier on types. It decides that an `Int` key cannot be the
   source of an `Item` view. It also decides that a view reached
   *through another view* carries that view's loans, not a loan on its
   holder. This fixes, with nothing written, the parser cursor, the
   keyed lookup, the index argument, and the nested pair. Those are the
   shapes real programs hit most after loggers.
2. **A signature can say which, and the compiler holds the body to
   it.** One contextual word on the result, `-> T from a`, and (after
   the freeze) one on a parameter the callee keeps, `n: String into
   self`. Without `from`, a result views every argument that could hold
   it, which is today's rule narrowed by idea 1. Without `into`, a call
   keeps nothing it was lent. The body walk proves both clauses. When a
   call is rejected only because a clause is missing, the error writes
   the clause for you.
3. **Each field keeps its own loans.** This comes later, only when real
   programs ask for it. It adds `from self.items` paths, disjoint field
   lends, and holders of two owners' views (`Split`).

**What we never do:**

- infer a call's meaning from the callee's body (inference is the
  checker and the source of help lines, never the rule);
- add lifetime or origin variables, or origin parameters on struct
  types;
- add Rust's `self` elision default.

**Prerequisites:**

- **A use-after-free in today's checker:** a store into a write
  parameter forgets its loan (`probes-red/r3`, `r7`, `r8`, `r9`, which
  crash under `RIG_SANITIZE=1`). Fix it first.
- **The read-receiver absorb bug** (`probes-fit/f2g`). Fix it first
  too.

**"100%" means three promises, and all three can be kept:**

1. Nothing unsound is admitted.
2. Every "which argument does this view come from" program that Rust
   accepts can be written in Rig. Rig also accepts some programs Rust
   rejects: NLL problem case #3 today, and `pair.rig` once fields land.
3. Every rejection caused by over-approximation, at a direct call,
   names the one word that fixes it.

It cannot honestly mean "never write anything". That would need
body inference as meaning, which breaks API stability, Core §10, and
has no answer at bodiless boundaries (`?fun`, `extern zig`).

---

## 1. The rule

### 1.1 Core sentence 7, as it should read when the design is built

> **7. A call passes on only the loans its signature shows.** A
> function returns a view only of what it was lent, or of something
> that lives for the whole program. A view carries the loans of only
> what could hold what it views: a view reached through another view
> carries that view's loans, not a loan on its holder. So a call's
> result carries the loans of the arguments whose types could hold it,
> or of only those its signature names after `from`; and a call keeps a
> view in a write argument only where that parameter says `into`. The
> compiler checks each body against its signature. Every other loan the
> call made ends with its statement.

That is one paragraph with no exception list. Every clause follows the
*type* or the *signature*, never a body or where a value came from
(Core §10).

**The asymmetry is one principle.** A result's view type (`-> ?T`) is
visible in the signature, so a result may carry what could produce it.
A write parameter's type (`!Ctx`) does not show "and I keep `msg`", so
a store must be written. This is AGENTS rule 4, "effects stay visible",
applied to the store channel.

**Before the freeze lifts,** the `into` clause is replaced by the type
rule, which changes no accepted program: "and what it stores through a
write argument carries the loans of only the arguments whose types
could be held there".

### 1.2 The one classifier: `reach(H, V)`

"Could hold" is decided by a single type query with three answers. It
is computed once per type pair, recorded, and used by every site:

| `reach(H, V)` | Meaning | Effect on a loan on a holder of type `H`, for a view of target `V` |
|---|---|---|
| `owned` | `H` reaches memory of type `V` through owned edges or write views (field, payload, element, optional, `Box`, `*T`/`~T`, a `Cell`'s contents, `!T`, `![]T`); or `H` is a closure, a type variable, or unknown | keep the loan on the holder |
| `through_view` | `H` reaches `V` only by crossing a read view (`?T`, `[]T`, `String`) | replace the loan with the holder's own loans, then judge each of those the same way |
| `none` | `H` cannot lead to `V` at all | drop the loan |

**What it replaces.** Today's String-only `viewLoans`/`addViewLoan`/
`mayOwnText`, the `[]T`-only `throughReadSlice`, the planned
`produces` (formal's L0 and loans.md 6.2), and `ownReach`. That is
five ad-hoc rules folded into one fact, as AGENTS' "one classifier per
fact" asks:

- `produces` is `reach ≠ none`;
- `ownReach` is `reach = owned`.

**Built in from the red team:**

- Closures reach everything as `owned`. A call through a `?fun` can
  write through its captures (`probes-red/c2`), so a `?fun` is never a
  read edge.
- A type variable as *target* is reached by every source.
- `reach` is computed per strongly connected component of the type
  graph, never memoized while a cycle is open. A wrong `false` would be
  unsound for the `through_view` replacement.
- The bytes class: `String`, `[]U8`, `[N]U8`, and a `Text`'s buffer
  are one memory class.

### 1.3 Desugaring and checker rule (for INTERNALS)

**Lending through a read view is copying it out first.** This is a
strict desugaring into existing forms. With `items: ?Vec[Item]`:

```
?c.items[0]          ≡   t = c.items      # a read view copies, with the same loans (Core §1)
                         ?t[0]            # lends through the copy: carries v's loan, not c's
```

The `through_view` row of §1.2 is this rule stated on types, which is
Rust's "supporting prefixes". A write view never copies, so a path
through a write view keeps the holder's loan (`probes-simplicity/s1`
must stay rejected).

**A call is its arguments as statement temporaries,** as Core §3
already says:

```
r = f(e1, …, en)     ≡   t1 = e1; …; tn = en        # statement temporaries
                         r = f(t1, …, tn)
   r       holds the loans of t_i for i ∈ Σf.result
   owner of each write t_q holds the loans of t_i for i ∈ Σf.into[q]
   every other t_i's loans end with the statement (Core §3)
```

**The checker rule.** `Σf` is the callee *type's* origins: what
`from`/`into` declare, or the default the type rule gives. The callee's
own body walk proves `Σactual ⊆ Σf`.

`from` restricts a set that sentence 7 already defines. It is not a new
construct, and no existing form says "does not view `b`". So,
following the red team's honest wording, INTERNALS should call it
*sentence 7's refinement*: its desugaring is the call desugaring above,
with Σ as named, and its proof obligation is the body check.

### 1.4 Checker structure: one fact per question

| Question | Answered once, by | Read by |
|---|---|---|
| Which parameter does each argument fill (keywords, defaults, receiver)? | `call_params`, the fact emit already uses (`call_slots`), extended with the receiver | emit, ownership, the reference checker (which computes its own, to cross-check) |
| Can a holder of type `H` hold a view of `V`, and how? | `reach(H, V)` (§1.2) | every lend, call result, call store, and default mask |
| Which arguments may a call's result view, or a write parameter receive? | `Origins` in the callee's function type: declared, or the default from `reach` over the parameter types | `walkCall` (the one call rule) |
| What did the body actually do? | one recorder: the result's loans at every return or tail, and each write parameter's flow at every exit, after defers | the body check (`Σactual ⊆ Σf`) and the help lines |

**Why it cannot regress quietly:**

- **A missing `reach` edge** in a default mask turns into a false
  rejection *in the callee's own body check*, not an unsound caller.
  `extern zig` and built-ins are the exception: they are trusted, and
  get a unit-test table.
- **A declared mask the body exceeds** is an error at the line that
  exceeds it.
- **The reference checker** recomputes `Σactual` per body and its own
  argument mapping. A disagreement of class `prod-unsound` is a
  failing test.

---

## 2. Inferred, declared, defaults

| What | Inferred? | Declared? | Default when nothing is written |
|---|---|---|---|
| A call's **result** (a function, method, or `extern zig`) | never the meaning; computed to check `from` and to write help lines | `-> T from a, b` (parameters, `self`, or `static`) | the arguments whose types could hold the result (`reach ≠ none`), which is today's rule narrowed |
| A call's **stores** into a write argument | same as above | `x: T into h` on the parameter being kept (after the freeze) | in the freeze: the arguments whose types could be held there. After the freeze: **nothing** |
| A **lend through a path** (`?c.items[0]`) | the `reach` classifier, per type | — (paths in `from` come in stage 3) | `through_view` carries the inner view's loans |
| A **`?fun` value** (a lent function, closure, or `?fun` parameter) | no | not in v1 (stage 3a) | the default over its parameter types, plus its captures. **A function's `from` is not part of the value**: lending `?first` gives a plain `?fun` type |
| **`extern zig`** | no body | `from`/`from static`, trusted like the rest of the signature (std only) | the type default, trusted |
| **Generics** | — | `from` works on generic functions | the generic signature's default; the body is walked once with `T` opaque; a type variable reaches everything |
| **Recursion** | — | assume–guarantee on the declared or default mask | no fixpoint and no call graph |
| **Modules** | nothing body-derived crosses a module | origins live in the function type, which `importType` already copies | the default, computed from imported types |
| **Closures** | — | — | the environment is always an input, so what a closure returns from its captures is carried |

**The one simplification beyond the five reports.** In v1, function
values do not carry narrowed origins: a `?fun` type always means the
default.

- **Soundness.** It is sound because every body satisfies its type's
  default.
- **Red-team attacks closed.** It closes `f2` (a re-pointed `?fun`
  local) and `f4` (a `?fun` result chosen from two functions) by
  construction.
- **Where it is built.** Origins live in the declaration's
  `FunctionType`, so direct calls and method calls find them. The one
  place a function becomes a value is `lendCallable`, which today
  compares interned types by identity (`plain == fn_ty`). It becomes
  `withoutOrigins(plain) == fn_ty`, and records the stripped type. That
  is one line at one coercion point, with no subsumption logic.
- **What it costs.** Narrowed function types (`funval.rig`,
  `closure_ret.rig`) wait for stage 3a. That stage adds origins to the
  function type, the red team's single coercion point (narrow converts
  to wide, a join takes the union), and optional parameter names in
  function types.

---

## 3. Syntax

### 3.1 Forms

**`from`** sits after a result type, in `fun` and `extern zig`
declarations:

- `-> T from a`
- `-> T from a, b`
- `-> T from self`
- `-> T from static`

The rules:

- It is a keyword only directly after a declaration's result type.
  Everywhere else it is an ordinary name, as it is today:
  `struct Move` with `from: Int`, and `fun span(from: Int, …)` both
  check and run (`probes-simplicity/s2`).
- Each name must be a parameter, `self`, or `static`.
- A named parameter whose type cannot hold the result is an error
  (`reach = none`). This catches typos and meaningless clauses.

**`into`** follows a parameter's type, after the freeze:

- `n: String into self`
- `x: ?Item into h`
- It is likewise a keyword only after a parameter type.
- The name must be a write parameter, or `self` lent to write.

**Rejected, with the reports' reasons:**

| Form | Why not |
|---|---|
| `'a`, region variables, `struct S[o: Origin]` | lifetimes by another name, noise in every signature |
| `?[a]T` (Mojo/Dada brackets) | brackets mean compile time; `?[4]Int` is already an array view |
| `of`, `in`, `where` | `of` fills, `in` belongs to `for`, `where` reads as a constraint |
| a sigil on the source parameter | sigils are operations at use sites; a sigil cannot say which output |
| `@` attributes | `@` is raw builtins, and Rig has none |
| `h: !Holder from x` for stores | reads as "h comes from x"; `x into h` reads as the effect |

Grammar cost:

- About 15 lines in `rig.grammar` and about 20 in `src/rig.zig` (the
  contextual-keyword test, as `new` has).
- Both files are mirrored in Nexus: report the change.
- v1 needs no change to function types.

### 3.2 Four realistic examples

**1. Text helpers with a computed pattern (std writes `from s` three
times).**

```rig
# std/text.rig
pub fun strip_prefix(s: String, prefix: String) -> String? from s
pub fun strip_suffix(s: String, suffix: String) -> String? from s
pub fun cut(s: String, sep: String) -> Cut? from s

# user code: every `key` dies each iteration while `v` lives on in `found`
for name in names
  key = Text(name, "=")
  if text.strip_prefix(?line, ?key) as v
    !found.push(v)
```

This is rejected today ("`key` does not live long enough",
`probes-fit/f1_prefix_loop`), and accepted once std writes the clause.
Call sites change nowhere.

**2. A symbol table keyed by `String` (one word, written once by the
table's author).**

```rig
struct Env
  vars: Vec[Var]

  fun get(?self, name: String) -> String? from self
    for i in 0..self.vars.len
      if self.vars[i].name == name
        return self.vars[i].value
    none

sub main
  env = load()
  for n in ["HOME", "PATH"]
    q = Text("RIG_", n)
    if env.get(?q) as v
      !seen.push(v)
```

`from self` is needed because a `String` key could be the source of a
`String` result. With a `Key` or `Int` key, nothing is written: the
type rule frees it.

**3. A parser cursor (nothing written).**

```rig
struct Parser
  src: String
  toks: []Tok
  pos: Int

  fun next(!self) -> ?Tok
    t = ?self.toks[self.pos]
    self.pos += 1
    t

sub main
  p = Parser(src: ?src, toks: ?toks, pos: 0)
  kw = !p.next()
  name = !p.next()
  print(kw.kind, name.kind)
```

This is rejected today ("use of `p` while a write borrow is live",
`probes-fit/f7_parser_cursor`). A `Parser` reaches `Tok` only through
the read view `toks`, so `reach = through_view`: `kw` carries `toks`'s
loan, not a loan on `p`. If the cursor had to *own* the `Tok`s too, it
would stay rejected (`probes-simplicity/s3`) until stage 3's
`from self.toks`. The diagnostic says why (§3.3).

**4. A logger and a setter (after the freeze).**

```rig
struct Ctx
  name: String
  count: Int

  sub log(!self, msg: String)              # keeps nothing: nothing written
    self.count += 1
    print(self.name, msg)

  sub rename(!self, n: String into self)   # keeps `n`: says so
    self.name = n

sub main
  ctx = Ctx(name: "app", count: 0)
  for i in 0..3
    !ctx.log(?Text("step ", i))
```

This is rejected today (`probes-fit/f5b`, `f5c`, `f5d`), and it is
fit's most frequent pain. In a census of 45 functions lent both a write
view and a view argument, about 4 (the setters) write `into`.

### 3.3 Diagnostics

**At a call, when a missing clause is the reason** (the help line comes
from the callee's recorded `Σactual`):

```
two.rig:8:3: error: cannot lend `y` to write while a read loan is live
  !y.push(1)
  ^
two.rig:7:17: note: `r` carries the loan: `first(?x, ?y)` returns a view,
  and without `from` a result carries the loans of every argument that could hold it
two.rig:9:9: note: `r` is used here
help: `first` returns a view of `a` only (two.rig:1). Say so, and `y` is free after the call:
    fun first(a: ?Vec[Int], b: ?Vec[Int]) -> ?Vec[Int] from a
```

**In the callee, when the body exceeds its clause:**

```
pick.rig:4:5: error: `first` returns a view of `b`, but its signature says `from a`
    b
    ^
help: write `-> ?Vec[Int] from a, b`, or return a view of `a` only
```

**A clause that names an argument which cannot hold the result:**

```
at.rig:1:43: error: `from k`: `k: ?Int` cannot hold a view of an `Item`
```

**The type rule, when a field keeps the holder lent** (the red team's
private-field hazard, named in the message):

```
cursor.rig:21:8: error: cannot use `c` while a write loan is live
cursor.rig:20:8: note: `a = !c.next()` keeps `c` lent: `Cursor` can own an `Item` itself,
  in field `scratch`, so a view of an `Item` from it may point into `c`
```

The help line is added in stage 3, when path clauses exist:
`fun next(!self) -> ?Item from self.items`.

**A store the signature does not show** (after the freeze; the error
lands on the author, not the caller):

```
ctx.rig:9:5: error: `rename` keeps a view of `n` in `self` after it returns
    self.name = n
    ^
help: say so in its signature: `sub rename(!self, n: String into self)`
```

**Through a function value:**

```
note: `h(?x, ?y)` calls a function value, which carries the loans of every argument
  that could hold its result
```

There is no help line here: no single body answers the question. Stage
3a adds `?fun(a: ?T, b: ?T) -> ?T from a`.

---

## 4. Soundness

**Invariant (loan coverage), from formal §2.5.** Every live view that
points into memory `o` is covered:

- `o` lives for the whole program; or
- the view's holder carries a loan on the owner of `o`; or
- it carries a loan on a holder whose views cover `o`; or
- it carries the caller's token for the parameter that handed `o` in.

The checks the checker already makes then forbid freeing or changing
`o` while it is covered. Those checks are conflicts (sentence 5),
holder liveness (sentence 6), and the escape check.

**Lemma 1, for projections only** (the red team's correction):

- Replacing a loan on `h` by `h`'s own loans is sound when the path to
  the view crosses a read view: field, payload, element, `Box`, handle.
  The memory belongs to that read view's target, and the read view's
  loans are in `h`'s flow.
- Calls through `?fun` never use this rule. Closures are `owned`, so
  they go through the call rule.
- A write view never copies out, so the replacement never crosses a
  write edge.

**Lemma 2 (summaries).** If every call inside `f` uses a sound `Σ`, the
recorder's `Σactual(f)` covers every terminating run of `f`. Three
cases make that a property of every caller:

- **Declared `Σ`:** the body check `Σactual ⊆ Σdeclared`.
- **Default `Σ`:** the same check, which can fail only on a missing
  `reach` edge, and then fails in the callee.
- **Recursion:** assume–guarantee. Every returning run has finite
  depth, so induction on depth.

**Function values (v1).** A `?fun` type's `Σ` is the default, and
every body satisfies its default, so any function or closure is safe at
any `?fun` type.

### Red-team attacks, and how the design survives each

| Attack (probe) | Outcome |
|---|---|
| A store into a write parameter forgets its loan (`r3`, `r7`, `r8`, `r9`: use after free today, base compiler too) | **Stage 0 prerequisite.** A value stored into a write parameter's target joins that parameter's flow, and write parameters are live at every exit. This also makes the recorder read stores in one place, the flows at exit, instead of a list of store sites. |
| Positional argument mapping (`kw_args_trap`) | The one mapping fact shared with emit, receiver included. The reference checker computes its own. Every call shape gets an origins-matrix cell. |
| A re-pointed `?fun` local or a `?fun` result keeps narrow origins (`f2`, `f4`) | Impossible in v1: a function value's type never carries narrowed origins. In stage 3a, origins become part of the type, with one coercion point and a union at joins. |
| Call order: carrying the result before the call's stores (`l0_absorb_order`) | One fixed order in the call rule: apply stores, then compute the result, then apply `reach`. The probe is kept as a reject test. |
| Lemma 1 false for `?fun` (`c2`) | Closures classify as `owned`; the lemma is stated for projections. |
| Recursive types memoized wrong | `reach` is computed per type component; unit tests cover mutually recursive nominals across modules. |
| A type variable as target | It is reached by every source (§1.2). |
| Wrong inferred mask (`p1`, `p2`: prototype says `{a}`, result views `b`) | After stage 0, `b`'s loan enters `a`'s flow, so the mask is `{a, b}`. The `into` default change must keep this: a store recorded into `a` makes `b` part of any result read through `a`. |
| Path origins after re-pointing (`d2_repoint`) | No paths in v1. In stage 3, a projected token is issued only while the parameter's flow is exactly its own token, and stores are applied before the result. |
| Self-loans when fields get paths (`r11`, `r12`, `self_store`) | No paths in v1. In stage 3, every store site rejects a loan rooted at the receiving variable. |
| Whole uses missed by field liveness | Stage 3 only: *partial* is a positive list of one form (a member path); everything else is whole. |
| `from static` on `os.env` | Trusted, and true while std has no `set_env`. The declaration carries a comment naming that invariant. |
| Private fields change the type rule's answer (`cursor` vs `s3`) | Accepted as a property of types, as "a struct's kind follows its parts" already is. The diagnostic names the field, and stage 3's `from self.items` is the stable contract. |
| Tripwires T1–T9 (no view into a Cell, a closure cannot return what it writes, no value holds a `?fun`, `swap` refuses view holders, …) | One reject test each, commented "origins depends on this", before stage 1. CORE's planned `swap` for any element must add `swap` as a store site first. |

---

## 5. What it expresses, compared with Rust

The rows are formal.md §1's probes that Rust accepts, plus fit's and
prior-art's.

| Probe | Today | Stage 1 (type rule + `from`) | Stage 2 (`into`) | Stage 3 (function types, fields, static) |
|---|---|---|---|---|
| `two`, `strip`, `cut`, `firstmut`, `generic`, `recur`, `f1`, `f2d` | ✗ | ✓ with `from` | | |
| `method_key`, `produces`, `index`, `f2c`, `p31_over` | ✗ | ✓, no syntax | | |
| `cursor`, `deep2`, `prefix`, `nested`, `f7` | ✗ | ✓, no syntax | | |
| `f2g`, `f2e` (read receiver) | ✗ | ✓ (stage 0) | | |
| `f8` `os.env`, `s4` (result views only literals) | ✗ | ✓ with `from static` | | |
| `store`, `f5`, `f5b`, `f5c`, `f5d` (loggers, setters) | ✗ | ✗ | ✓ (loggers write nothing; setters write `into`) | |
| `funval`, `closure_ret` | ✗ | ✗ | ✗ | ✓ 3a: `?fun(a: ?I, b: ?I) -> ?I from a` |
| `s3` / `cursor_own` (holder also owns the target) | ✗ | ✗ (diagnostic names the field) | | ✓ 3b: `from self.items` |
| `split`, `f3`, `f6b` (two-owner holders) | ✗ | ✗ | | ✓ 3b: per-field loans |
| `disjoint` (`!p.x` with `!p.y`) | ✗ | ✗ | | ✓ 3b: owner-side paths |
| `static_param` | ✗ | ✗ | | ✓ 3c: loans.md 6.1 static obligations |
| `pair`, `mkpair` (Rust **rejects**) | ✗ | ✗ | | ✓ 3b: past Rust |
| `nll3b` (Rust NLL **rejects**) | ✓ | ✓ | ✓ | ✓ |

**The residual gap after every stage, stated plainly:**

- **Callbacks that store their argument through a capture**
  (`hr_store`; Rust ties `FnMut(&'a T)` to the input).
  - It is closable, at about the cost of field precision, with `into`
    on a function-type parameter and a store summary for closure
    literals.
  - A `for` loop says the same thing today.
  - I would not schedule it until a program needs it.
- **Views inside owned closures, `Cell`s, `Signal`s.** That is
  sentence 9, not origins. The `*T` rule (every handle carries its
  contents' loans) is the likely answer, as a separate decision.
- **Branded lifetimes** (GhostCell, `thread::scope`'s invariant
  `'scope`). Rig has no type-level origin variables, by choice. Stack
  closures already give the part of `scope` that matters.
- **Per-field `from` on a struct result** (`-> Split(rest from s, sep
  from sep)`). It is wanted only once stage 3b exists, and only by
  constructors of two-owner holders.
- **Not gaps, because Rust has them too:**
  - the elements of a `Vec` of views share one origin;
  - recursive types collapse to one origin;
  - a mutable cursor handing out `!T` into its own buffer;
  - a result whose source depends on a run-time value (the union is
    right).

**BEYOND-RUST §2's trade, rewritten for when stage 1 lands:**

> Rig says which argument a result views with `from a`, and the
> compiler proves it from the body. Without `from`, a result views
> every argument that could hold such a view, so a key, an index, or a
> counter never stays lent.

---

## 6. Staging

The freeze allows consolidation (only wrong rejections become
acceptances) and building rules the Core marks *planned*. The narrowing
to "the loans its signature names" **is** planned in sentence 7, so
`from` is in scope. The type rule changes no accepted program, but it
rewrites sentence 7's *built* text, "carries the loans of everything it
was lent". So it needs the owner's approval of the new paragraph,
though it fits inside the freeze. Only the `into` default ("nothing
stored") changes meaning, and it waits for the freeze to lift.

| Stage | What | Freeze status | Size (impl.md's estimates, adjusted) | Risk |
|---|---|---|---|---|
| **0** | (a) Stores into a write parameter join its flow, and write parameters are live at every exit (fixes the use after free: `r3`, `r7`, `r8`, `r9`). (b) A `?self` receiver absorbs nothing (`f2g`). (c) Fix the misleading notes ("`env` still borrows it", "bind the value to a name first"). (d) Tripwire reject tests T1–T9. | **Consolidation, now.** No Core change. | small: ~50–100 lines plus tests | low (a only rejects unsound programs; b only accepts) |
| **1a** | The mapping fact (`call_params` plus receiver), the `Origins` record in `FunctionType`, the recorder, and the one call rule, still with "all" as the default. The equivalence check (`test/equiv.py`) must show no change. | consolidation | ~150 | low; the mapping is the one unsound spot, so it gets the origins matrix (`test/origins.py`) |
| **1b** | `reach` (§1.2), replacing `viewLoans`, `mayOwnText`, and `throughReadSlice`. Default masks for results and stores come from it, and the callee checks its own default. | **Core change to sentence 7** (acceptance-only, owner sign-off); fits in the freeze | ~250 net (+300 / −60) | medium: a missing `owned` edge is unsound in a projection, hence the per-component computation, the unit table, and the reference checker's own `reach` |
| **1c** | `from` on results and on `extern zig`, plus `from static`, the body check, the help lines, and std's three `from s` (`strip_prefix`, `strip_suffix`, `cut`) and `os.env`'s `from static`. Promote sentence 7's `pending` example. Update SPEC "Second-class borrows", DESIGN "Borrows without lifetimes", BEYOND-RUST §2, and INTERNALS. | **planned in the Core** (in scope) | ~250 + grammar ~35 (mirrored in Nexus) | medium |
| **2** | `into` on parameters, and stores default to nothing. Setters in std, tests, and examples write `into` (about 4 in today's code). | **after the freeze**: a meaning change, because unannotated setters become errors with a fix-it | ~150–200 | medium: the store recorder must be complete, which stage 0a makes structural |
| **3a** | Function types: optional parameter names, `from` in the type, origins part of type identity, narrow-to-wide at the one coercion point, union at joins. | after the freeze (new syntax that is not in the Core) | ~150 + grammar | medium |
| **3b** | Fields: `from self.items` path clauses, owner-side paths (disjoint lends), holder-side per-field loans and liveness. Every store site rejects self-loans; whole use is the default. | after the freeze; one branch alone; on demand | ~1,000–1,400 | **high** |
| **3c** | Static obligations (loans.md 6.1) on the same recorder. | Core change | ~300–450 | medium |

**Dependencies on the HANDOFF plan:** the "may hold a loan" type fact
(step 1), and `exitTo` as the one exit primitive (step 2).

- Once `exitTo` exists, the recorder's result hook moves into the
  `.return` exit.
- Each stage takes the one-ownership-branch slot.
- Each stage passes the four gates: suite, corpus, matrix, and the new
  origins matrix.

---

## 7. The three strongest objections, and my answers

### Objection 1: "The user asked to fix it 100%, and you still make people write annotations. That is lifetimes again, which Rig promised to avoid."

**`from a` names a parameter, not a variable.** There is nothing to
declare, nothing to thread through struct types, and no equation to
solve.

**The common cases need nothing.** Keys, indexes, counters, cursors,
nested views, and loggers (after stage 2) write nothing.

**The census shows the clause is rare:**

- 3 clauses in all of std;
- about 5% of view-returning functions in the tests;
- about 4 setters for `into`.

**The compiler writes the clause for you** in the help line, because it
already computed the exact answer.

**The zero-annotation alternative cannot be built.** It means body
inference as the meaning of a call, which:

- makes a library's body edit break its callers without a signature
  change;
- puts errors in the caller that cite another module's internals;
- breaks Core §10's "rules follow the value's type";
- still needs the declared form at every `?fun` and `extern zig`.

Every language with a stable story made this same choice: Rust, Swift,
Mojo, Cyclone. Clang infers only to *suggest*, which is exactly the
role this design gives inference. Turning private-function inference on
later would only add acceptances, so the door stays open if real code
shows the clauses are noise.

### Objection 2: "Two defaults (results carry what could hold them, stores carry nothing) and two words (`from`, `into`) are an exception list wearing a principle's clothes. One keyword and one default would be simpler."

**The single principle is "a call passes on only the loans its
signature shows".** A result's view type already shows it, and a write
parameter's type does not. So the store must be written, or nothing is
passed on.

**A single default fails one way or the other:**

- "Nothing" for results would make every view-returning function
  write `from`, which is Cyclone's path.
- "Could hold" for stores would leave every logger on a struct with a
  `String` field rejected. That is fit's most frequent pain, and no
  type rule can fix it.

**A single word reads wrong in one of the two places.**
`!self from n` reads as "self comes from n". So does `into` as a
result clause. Each word sits where the caller asks the question, and
each has one meaning.

**The Core cost is one sentence per channel.**

### Objection 3: "Leaving function values at the default (and fields to stage 3) means `funval`, `closure_ret`, `split`, and `disjoint` stay rejected. That is not 100%, and stripping `from` at a lend is itself an exception."

**These cases are staged, not dropped.** The decision already contains
3a and 3b, with the red team's repairs specified.

**Doing them last is the simplicity argument:**

- the red team found both of the function-value holes (`f2`, `f4`);
- it found all of the field holes (self-loans, whole uses, parts on
  absorb, re-pointing).

Deferring them means v1 has none of that soundness surface.

**Stripping is not an exception.** A function value has no declaration
of its own, so it has the default of its type, exactly as a `?fun`
*parameter* does. It happens at the one existing coercion point,
`lendCallable`.

**The census says what is delayed is the least common:**

- callbacks that return a view of their argument appear in no program
  in the repo (fit: callbacks already work);
- two-owner holders show up in `std.text.Split` with a computed
  separator, and in one showcase type.

**The trade that motivates each layer is stated plainly:**

- Rust rejects `pair.rig` too;
- `split` is the only parity case that needs per-field loans.

Each later stage is acceptance-only on top of the earlier ones, so
nothing built in stage 1 is undone.

---

## 8. Summary of the recommendation

1. **Stage 0 now:**
   - fix the store-forgets-its-loan use after free and the read-receiver
     absorb;
   - add the tripwire tests.
2. **Stage 1, inside the freeze, with the owner's approval of the new
   sentence 7:**
   - one type classifier, `reach`, for every lend, result, and store;
   - `from` on results and `extern zig`, checked against the body, with
     help lines that write the clause;
   - function values take their type's default.
3. **Stage 2, after the freeze:** `into`, with stores defaulting to
   nothing.
4. **Stage 3, on demand:** function-type `from`, field paths and
   per-field loans, and static obligations.
5. **Never:**
   - body inference as meaning;
   - lifetime or origin variables;
   - origins in struct types;
   - a `self` elision default.

With stages 0–2, every common "which argument" program, in parsers,
lookups, text helpers, loggers, and setters, is accepted, with at most
one word that the compiler offers. Stage 3 reaches full Rust parity for
origins, and passes it on per-field liveness.
