# Origins: the recommended design (synthesis, power lens)

Role: the synthesizer, with expressive power and parity with Rust as
the lens. Written as the decision for the language owner. It draws on
the five reports in this directory (`formal.md`, `prior-art.md`,
`fit.md`, `impl.md`, `red-team.md`). Every "today" claim was checked with
`bin/rig check` on the revamp worktree. The probes I added are in
`probes-power/`:

| Probe | Today |
|---|---|
| `table_get` | rejected |
| `table_get_free` | rejected |
| `parser_scratch` | rejected |
| `logger` | rejected |
| `from_ident` | accepted: `from` is an ordinary name today |
| `funtype_names` | parse error: function types take no parameter names today |

The user's question was: *"Rust can say which argument a result views,
and Rig cannot. How can we fix this 100%?"*

---

## 0. The decision in one page

**What "100%" means here, stated so it can be tested:**

1. **Expressible.** Rust can tie a result, or a value a function
   stores, to some of its inputs. Every such program can be written in
   Rig, with no lifetime variable and no lifetime parameter on a struct.
   §6 lists the few exceptions. None of them is about which argument a
   view comes from.
2. **Proven.** The compiler checks every such statement against the
   function's body. Only `extern zig` declarations are trusted, as they
   are today.
3. **Guided.** Sometimes a false rejection could be removed by a word in
   the callee's signature. The error then names that word, and the line
   that proves it fits the body. The compiler can always say this,
   because it already works out the smallest origins of every body.
4. **Sound.** Nothing unsound is admitted on the way. That includes two
   holes that exist today and are fixed first (§4.1).

**The design, called "signature-first, three tiers":**

| Tier | What the user writes | What it covers | Like |
|---|---|---|---|
| **T0: what the type allows** (no syntax) | nothing | An argument whose type cannot hold the result's view gives no loan. A view reached *through* a read view carries that view's loans, not a loan on the value holding it. | Rust's elision rules and its "supporting prefixes" rule; today's `String` rule, made general |
| **T1: `from`** on a result | `-> String? from s`, `-> ?Tok from self.toks`, `-> String from static` | Any choice among arguments of the same type, function values, `extern zig`, and stable public APIs | Rust `'a`; Mojo `ref[a]`; Swift `@lifetime(copy a)` |
| **T2: `into`** on a parameter | `n: String into self` | Which arguments a function keeps in what it was lent to write. Once T2 lands, the default is "nothing kept". | Rust `Holder<'a>` + `&'a`; Swift `@lifetime(dst: copy src)`; Clang `lifetime_capture_by` |
| **T3: field precision** (no syntax, plus one clause for factories) | `-> Split(rest from s, sep from sep)` in the rare factory | Disjoint field lends; a holder of two owners' views | Rust `&mut p.x` with `&mut p.y`; `Split<'a, 'b>` |

**Body inference has one role: it checks the signature and suggests it.**
It never decides what a call means. A caller reads only the callee's
*type*, and `from`/`into` are part of that type. So:
- no call graph;
- no fixpoint;
- nothing new to export across modules;
- the Core's "rules follow the value's type" holds literally.

**What I chose, and why:**
- **Signature-first.** All five reports agree on it, and I found no
  attack that changes it.
- **Path-precise `from` (`from self.toks`) in the first syntax stage,
  not later.** The power lens wants this: parsers are where Rig most
  needs it.
- **`into` with a "nothing kept" default as the end state.** It removes
  the most common false rejection in real programs, the logger or
  context (fit §0.1).

**Staging:**

| Stage | When | What |
|---|---|---|
| 0 | inside the feature freeze | soundness prerequisites |
| 1 | inside the freeze | T0: acceptance-only, sound by construction |
| 2 | inside the freeze | T1: Core sentence 7 already marks it *planned* |
| 3 | after the freeze, as a Core change | T2 |
| 4 | after the freeze, as a Core change | T3 |
| 5 | when a real program asks | sentence-9 and callback items |

§7 gives the cost of each stage.

---

## 1. The rule

### 1.1 Core sentence 7, final form (one paragraph, no exception list)

> **7. A function returns a view only of what it was lent, or of
> something that lives for the whole program, and keeps a view of what
> it was lent only in its result or in what it was lent to write.** A
> view carries the loans of what it views: a view reached through a read
> view carries that read view's loans, not a loan on the value holding
> it. A call's result carries the loans of every argument whose type
> could hold such a view. If the signature says `from`, it carries only
> the loans of what `from` names. A call keeps an argument's view in a
> write argument only where the signature says `into`. The compiler
> proves each signature from the function's body. Every other loan a
> call was lent ends with the call's statement.

Three words, each with one meaning:
- **lend** is the act at the call;
- **view** is what the result or the stored field holds;
- **loan** is what stays with the caller's owner, and ends when its
  views end.

`from` and `into` are part of the function's type. So "the call's
loans follow the callee's type" is a rule about a value's type, as Core
§10 requires.

**The interim wording, for stages 1–2** (inside the freeze, before
`into` exists). It replaces the `into` sentence with:

> What a call stores through a write argument carries the loans of
> every argument whose type could be stored there.

### 1.2 The checker rule (one call rule, one body rule)

**Call rule.** At `f(e₁ … eₙ)`, map arguments to parameters with *the
fact emit uses* (`call_slots`, extended with the receiver: impl §3.2).
Let `A[i]` be the value of the argument that fills parameter `i`. Let
`S = origins(type of f)`: the declared clauses, or the T0 default.

1. **Stores first.** For each write parameter `q`:
   - every caller place that `A[q]`'s write loans lead to absorbs
     `⋃ A[j]` for `j ∈ S.into[q]` (a weak update);
   - with T3, it also invalidates or widens that holder's per-field
     parts (red-team §3.3).
2. **Then the result:** `result = callee value ∪ ⋃ A[i]` for
   `i ∈ S.from`. A `from p.f` path projects `A[p]` to the loans held
   at `f`, read *after* step 1.
3. **Then carry** (T0) over the result's loans.
4. **Everything else in the arguments ends with the statement.**
   `temps`, `holdTemp`, `dropStmtTemps` and `capture` are not touched
   (impl §11.1).

**Body rule.** Each parameter gets its own external token, plus one per
path that `from` names. At the end of the body, the recorder reads two
things:

- **the result's tokens,** at every `return` and tail value: what
  `checkEscape` already does today, against a smaller set;
- **each write parameter's flow,** at every exit and after defers. The
  stage 0 fix guarantees that every store lands there.

The function is accepted only if:
- `actual.from ⊆ S.from`;
- `actual.into[q] ⊆ S.into[q]`;
- `from static` was written, and the result carries no token at all.

The same check runs when `S` is the T0 default, as defense in depth: a
type edge missing from the default becomes a false rejection in the
callee, never a hole in a caller.

### 1.3 The desugaring (for INTERNALS)

**T0, a view through a read view.** `?c.items[0]`, where
`items: ?Vec[Item]`, is `t = c.items; ?t[0]`:
- copying a read view copies the view and carries its loans (Core §0);
- reading `c.items` is a plain field read, whose use ends with the
  statement;
- so the lend carries the loans of `c.items`, and none on `c`.

That is a true desugaring into built forms. A call result follows the
same rule by its type: a value of type `?Item` made inside a callee
from a `Cursor` that owns no `Item` can only be such a copied-out view.
The callee's body check proves this.

**T1 and T2, a call.** `r = f(e₁ … eₙ)` is
`t₁ = e₁; …; tₙ = eₙ; r = f(t₁ … tₙ)`, where the `tᵢ` are statement
temporaries (Core §3):
- `r` holds the `tᵢ` that `from` names;
- each write target holds the `tⱼ` that its `into` names;
- every other `tᵢ` is a view used only within its statement, exactly
  like `?Text(a, b)` passed to `starts_with` today.

**Honest note (red-team §3.5).** No existing form *says* "this result
does not view `b`", so `from` is a refinement rather than a pure
desugaring. INTERNALS should call it what it is: sentence 7's planned
half. Its checker rule is the call rule plus the body check, and both
already exist today for a larger set.

---

## 2. Syntax

### 2.1 The words

| Form | Where | Meaning |
|---|---|---|
| `-> T from a, b` | after a result type: `fun`, method, function type, `extern zig` declaration | the result views only what `a` and `b` view (themselves, and anything they hold) |
| `-> T from self.toks` | the same | only what the place `self.toks` views. Needed when the holder *also* owns the target type (`parser_scratch.rig`). Otherwise T0 already gives it. |
| `-> T from static` | the same | the result views only what lives for the whole program |
| `x: T into h` | on a parameter | the function may keep `x`'s views in what `h` was lent to write (`h` is `self` or a write parameter) |
| `?fun(it: ?Item) -> String from it` | function types | function types gain optional parameter names, which are not part of type identity, so `from` can name them |
| `-> Split(rest from s, sep from sep)` | stage 4 only | per-field origins of a struct result, mirroring the constructor `Split(rest: s, sep: sep)` |

**Lexing.** `from`, `into` and `static` are contextual:
- `from` is a keyword only right after a result type;
- `into` only right after a parameter's type;
- `static` only right after `from`.

`from` stays an ordinary name everywhere else: `from_ident.rig`
declares a parameter `from` and is accepted today. Grammar cost is
about 15 lines in `rig.grammar` and 20 in `src/rig.zig`, both mirrored
in Nexus. Report the change.

**Rejected spellings:**

| Spelling | Why rejected |
|---|---|
| `?[a]T` | brackets mean compile time, and `?[4]Int` exists |
| `'a` | lifetime variables |
| a marker sigil on the parameter | cannot say which output, nor name a path |
| `@attr` | `@` means raw builtins |
| `h: !H from x` for stores | reads backwards; `into` reads as the effect |

### 2.2 Four realistic examples

**1. Text helpers in std (T1, three words in all of std).**

```rig
pub fun strip_prefix(s: String, prefix: String) -> String? from s
  return none if not starts_with(s, prefix)
  s[prefix.len..]

pub fun cut(s: String, sep: String) -> Cut? from s
  i = find(s, sep)?
  Cut(before: s[..i], after: s[i + sep.len..])

sub main
  for name in names
    key = Text(name, "=")
    if text.strip_prefix(?line, ?key) as v
      !found.push(v)          # rejected today: `key` does not live long enough
```

**2. A parser: T0 needs nothing; T1 paths when the parser owns tokens
too.**

```rig
struct Parser
  toks: []Tok
  scratch: Vec[Tok]
  pos: Int

  fun next(!self) -> ?Tok from self.toks
    t = ?self.toks[self.pos]
    self.pos += 1
    t

sub main
  p = Parser(toks: ?ts[..], scratch: Vec(), pos: 0)
  a = !p.next()
  b = !p.next()               # rejected today (parser_scratch.rig)
  print(a.kind, b.kind)
```

Without `scratch`, `Parser` cannot own a `Tok`. T0 then frees `p` with
no word written (`cursor.rig`, `f7_parser_cursor.rig`).

**3. A symbol table and a logger (T1 on lookups, T2 on setters).**

```rig
struct Env
  keys: []String
  vals: []String
  name: String
  count: Int

  fun get(?self, key: String) -> String? from self     # Rust: elision rule 3
    for i in 0..self.keys.len
      if self.keys[i] == key
        return self.vals[i]
    none

  sub log(!self, msg: String)                          # keeps nothing (stage 3 default)
    self.count += 1
    print(self.name, msg)

  sub rename(!self, n: String into self)               # keeps `n`: says so
    self.name = n

sub main
  q = Text("HO", "ME")
  v = env.get(?q) ?? "?"
  !q.add("X")                 # rejected today (table_get.rig)
  for i in 0..3
    !env.log(?Text("step ", i))   # rejected today (logger.rig, fit f5c)
```

**4. Function values and `extern zig`.**

```rig
fun best(xs: []Item, key: ?fun(it: ?Item) -> String from it) -> (?Item)? from xs
  ...

extern zig "os.zig"
  # Lives as long as the program; std has no set_env (see §4.4).
  pub fun env(name: String) -> String? from static
```

A closure `|it: ?Item| it.name` converts to `key`'s type, because its
own origins (`it`, and no captures) fit inside `from it`. A closure
that returns a view of something it captured does not convert to that
type. It converts to the default `?fun(?Item) -> String`, which means
every argument plus the captures.

### 2.3 The diagnostics a user sees

They use the lend and loan vocabulary. Today's messages still say
"borrow", and they move to the new words with the SPEC rewrite.

**At the caller, when one word in the callee would remove the
rejection.** The help line comes from the body walk.

```text
two.rig:8:3: error: cannot lend `y` to write while a read loan is live
  !y.push(1)
  ^
two.rig:7:17: note: `r` carries the loan: without `from`, the result of
  `first(?x, ?y)` carries the loans of every argument that could hold it
two.rig:9:9: note: `r` is used here
help: `first` returns a view of `a` only (two.rig:2). Say so, and `y`
  is free after the call:
    fun first(a: ?Vec[Int], b: ?Vec[Int]) -> ?Vec[Int] from a
```

**At the callee, when the body exceeds its signature.** The error lands
on the author, never on the caller.

```text
pick.rig:4:5: error: `first` returns a view of `b`, but its signature
  says it views only `a`
    b
    ^
help: widen the signature: `-> ?Vec[Int] from a, b`
```

**T0's private-field dependence.** The note names the field.

```text
main.rig:23:8: error: cannot lend `p` to write while a write loan is live
note: `a` keeps `p` lent: `Parser` can own a `Tok` itself, in field
  `scratch` (parser.rig:3), so `next`'s result may view `p`
help: `next` returns a view of `self.toks` only. Say so:
    fun next(!self) -> ?Tok from self.toks
```

**A function value narrowed wrongly.** There is one coercion point, in
typecheck.

```text
cb.rig:9:12: error: this closure returns a view of `prefix`, which it
  captured, but `key` must view only `it`
note: `key: ?fun(it: ?Item) -> String from it` (cb.rig:1)
help: drop `from it` from `key`'s type, or return a view of `it` only
```

**Stores, from stage 3 on.**

```text
env.rig:21:5: error: `rename` keeps a view of `n` in `self` after it
  returns
    self.name = n
    ^
help: say so: `sub rename(!self, n: String into self)`
```

There is also an optional report, `rig check --origins file.rig`. It
prints each function's declared origins beside the minimal ones the
body walk found:

```text
text.rig:48 strip_prefix  result from s      (minimal: s)
env.rig:9   get           result: default    (minimal: self; narrow with "from self")
```

Docs generators print the clauses as part of the signature.

---

## 3. Inferred, declared, defaults, and each boundary

| Item | Rule |
|---|---|
| **Inferred** | Loan sets inside a body, per path, as today; NLL problem case #3 keeps working (`nll3b.rig`). A closure literal's origins, as part of its inferred *type*: a closure binding cannot be reassigned (red-team T9), so it is fixed like any local's type. The minimal `from`/`into` of every function, used only to check signatures and to write help lines. |
| **Declared** | `from`, `into`, `from static`, and the stage-4 per-field result clause. Each is part of the function type. |
| **Default: result** | (T0) every parameter whose declared type could hold a view of the result's target, plus the static values. The carry rule applies to holders. |
| **Default: stores** | stages 1–2: every argument whose type could be stored in a view slot reachable from `q` through owned and write edges. From stage 3: nothing. |
| **Function values** | Origins are part of `FunctionType`: hashed, compared, and copied at every construction site, including generic substitution and `importType`. One coercion function allows narrow to wide. A join of two function types takes the union. An unannotated `?fun` local or result gets the type's default, never the narrower origins of its first value (red-team `f2`, `f4`). Calls through the value use the type's origins plus the value's own loans, which are its captures. |
| **`extern zig`** | Declared clauses are trusted, as the rest of an extern signature is today. The default is T0 (trusted). `from static` on `os.env` carries a comment naming its invariant (no `set_env` in std). Built-ins: a table, one unit test per row. |
| **Generics** | The body is walked once with `T` opaque, and gets a mask that holds for every instance. A type variable reaches everything, as a source and as a target (red-team §3.1). Generic types cannot hold views today (T6), so per-instance slot mapping is unnecessary. |
| **Recursion** | Assume–guarantee on the declared type. No fixpoint, because callers never wait for bodies. |
| **Modules** | The function type is the contract, and it is already imported. Narrowing a `from` is compatible; widening one is a visible signature change. Nothing about a body crosses a module. |
| **Methods** | `self` is a parameter like the others: `from self`, `from self.toks`, `into self`. There is no Rust-style `self` default: that would be an exception list and a change in meaning. The help line writes `from self` when it is needed. |

---

## 4. Soundness

### 4.1 Prerequisites: two holes today, fixed before any narrowing (stage 0)

1. **A store into a write parameter forgets its loan** (red-team §1).
   - `r3`, `r7`, `r8` and `r9` are accepted today, and read freed
     memory under `RIG_SANITIZE=1`. I re-ran `r3`: accepted.
   - **Fix:** a value stored into a write parameter's target puts its
     loans into that parameter's flow, and a write-lent parameter is
     live at every exit.
   - **Sibling sites:**
     - `walkFieldAssign`;
     - `storeThroughLocal`;
     - `absorbLoans`' parameter branch;
     - `reassign` through `!T`;
     - capture absorption;
     - `defer`.
   - This also makes the recorder exact. It fixes the prototype's wrong
     `mask=0x1` on `p1` and `p2`.
2. **A method on a receiver lent to read absorbs its arguments' loans**
   (fit §0.2, `f2g`; `table_get.rig` shows the same shape).
   - **Fix:** `walkCall`'s `recv_root` absorb runs only when the
     receiver is lent to write.
   - **Siblings:** `rr1`, `rr2`, `f3` (T3: no value holds a `?fun`).

Each tripwire T1–T9 in red-team §2 gets a reject test commented
"origins depends on this".

### 4.2 The argument

**Invariant (loan coverage).** Take any live holder `h`, and any view
inside it that points into object `o`. Then one of these holds:
- `o` is static;
- `o` is owned by a var `x` in scope, and `h` carries a loan on `x`, or
  on a holder that covers `o`;
- `o` came from the caller through parameter `p`, and `h` carries `p`'s
  token, or a holder covering it.

**The existing conflict, liveness and escape rules turn the invariant
into "no dangling view".** Freeing or changing `o` needs a write, move
or drop of its owner, and sentence 5 rejects that while a covering loan
is live.

**Lemma 1 (carry), restricted to projections:** field, element,
payload, Box, and handle.
- A view of target `V` reached from `h`, where `h`'s type reaches `V`
  only through a read view, ends below some read view `w` that `h`
  holds.
- `w`'s loans cover `o`, and they are in `h`'s flow. So replacing the
  loan on `h` by `h`'s flow keeps the invariant.
- **Excluded:**
  - calls through a `?fun`, which go through the call rule, since a read
    view of a closure can write through its captures (`c2`);
  - write-view edges, which keep the loan on `h`.

**Lemma 2 (summaries).** Every function body is checked against its
type's origins (§1.2), and the recorder sees every store (§4.1).
- At each call, the result and the stored values carry every token of
  the input the callee's memory may reach.
- Recursion: every *returning* run has finite depth, so induction on
  depth closes the assume–guarantee.
- Function values: the coercion subset check makes the callee's real
  origins a subset of the type's.

**Trust boundary.** These are taken on trust, exactly as today:
- `extern zig` clauses;
- the built-in table;
- `raw`.

### 4.3 Red-team attacks, and how the design survives them

| Attack (probe) | Survives by |
|---|---|
| Store forgets its loan (`r3`, `r7`, `r8`, `r9`) | stage 0 fix 1; the recorder reads parameter flows at exit |
| Read receiver absorbs (`f2g`) | stage 0 fix 2 |
| Positional mapping of keyword arguments (`kw_args_trap`) | one mapping fact, shared with emit and extended with the receiver. The reference checker computes its own. |
| `?fun` local re-pointed, `?fun` result from two functions (`f2`, `f4`) | origins in the function type; subsumption at one coercion point; union at joins; default for unannotated locals |
| Re-pointed field read before stores are applied (`l0_absorb_order`, `d2_repoint`) | the fixed call order: stores, then result, then carry. A path token is minted only when the parameter's flow is still exactly its entry token. |
| Wrong inferred mask saved by coupling (`p1`, `p2`) | the mask is never a call's meaning; with fix 1 it is exact anyway |
| Memo of `ownReach` wrong inside a type cycle | computed per strongly connected component of the type graph; unit tests with mutually recursive nominals across modules |
| Lemma 1 false for `?fun` (`c2`) | the lemma is for projections only; a callable reaches everything |
| Type variable as a target | reached by every source |
| Private field re-locks callers (`cursor` vs `cursor_own`) | the same class as "a struct's kind follows its parts", so it is documented; the note names the field; `from self.toks` is the stable form |
| `from static` on `os.env` | invariant comment; a review rule: adding environment mutation to std revisits it |
| Self-loans once field paths exist (`r11`, `r12`, `self_store`) | stage 4 rejects a stored loan rooted at the receiving var, at every store site |
| Whole-use completeness (stage 4) | "partial use" is a positive list of one form, a member path ended by any index. Every other use is whole, so a missed whole use is impossible by construction. |
| Parts stale after absorb (stage 4) | any weak update of a holder unions the stored loans into every part |
| Per-field last use across loops | it extends across the back edge, as per-symbol last use does |
| Fixpoint and quiet-walk traps | do not arise: no interprocedural inference |
| String-only `keepViewTemps` | a separate temporaries-touching follow-up after stage 1, run against the full corpus |

---

## 5. Parity with Rust

The rows are formal.md §1's probes, which rustc 1.98.1 checked, plus
the fit and prior-art probes. ✓ = accepted and sanitizer-clean.

| Rust feature (probe) | rustc | Today | Rig after the stage named |
|---|---|---|---|
| Result tied to some arguments (`two`, `strip`, `cut`, `generic`, `recur`, `firstmut`) | ✓ | ✗ | ✓ stage 2 (`from a`) |
| Elision rule 3, `&self` result (`method_key`, `table_get`) | ✓ | ✗ | ✓ stage 1 when the key type differs; stage 2 (`from self`) when it is the same |
| An argument that cannot produce the result (`produces`, `index`, `f2c`, `p31_over`) | ✓ | ✗ | ✓ stage 1 |
| `&'s P<'b> -> &'b V` (`deep2`, `nested`) | ✓ | ✗ | ✓ stage 1 (T0 carry) |
| Cursor `next(&mut self) -> &'a T` (`cursor`, `f7`) | ✓ | ✗ | ✓ stage 1 |
| The same cursor, where the holder also owns the target (`parser_scratch`, `cursor_own`) | ✓ | ✗ | ✓ stage 2 (`from self.toks`) |
| Supporting prefixes (`prefix`) | ✓ | ✗ | ✓ stage 1 |
| Higher-ranked function values (`funval`, `closure_ret`) | ✓ | ✗ | ✓ stage 2 (origins in function types) |
| `'static` extern results (`f8_env_static`) | ✓ | ✗ | ✓ stage 2 (`from static`) |
| Storing into `&mut Holder<'a>` (`store`, `store3`) | ✓ | ✗ | ✓ stage 3 (`into`) |
| Logger, context, builder (`f5*`, `logger`) | ✓ (elided lifetimes keep nothing) | ✗ | ✓ stage 3 (default nothing) |
| Disjoint field lends (`disjoint`) | ✓ | ✗ | ✓ stage 4 (owner-side paths) |
| Two-lifetime holder, method returns one (`split`, `f6b`, `f3_two_buffers`) | ✓ | ✗ | ✓ stage 4 (parts + `from self.rest` + per-field factory clause) |
| Live struct, write one of its owners (`pair`, `mkpair`) | **✗** | ✗ | ✓ stage 4: **beyond Rust** |
| NLL problem case #3 (`nll3b`) | **✗** | ✓ | ✓: beyond Rust (Polonius-level) today |
| Variance, reborrowing (`variance`, `reborrow2`) | as Rust | as Rust | unchanged |
| Write-to-read downgrade (`downgrade`) | ✗ | ✗ | ✗, as Rust (unsound with `Cell`-like interior writes) |
| Static-required parameter (`static_param`) | ✓ | ✗ | ✓ with loans.md 6.1 (a separate HANDOFF item, on the same recorder) |
| Callback that stores its argument (`hr_store`) | ✓ | ✗ | stage 5 (§6) |
| Views in owned closures, Cells, Signals (`owned_closure`) | ✓ | ✗ | stage 5, a sentence-9 change (§6) |

**The new BEYOND-RUST §2 "trade" paragraph (after stage 2):**

> Rig says which argument a result views by naming it: `-> ?V from a`,
> or a place, `from self.toks`. The compiler proves it from the body,
> as Rust proves a lifetime, but there is no lifetime variable to
> declare and none to thread through a struct. Without `from`, a result
> views every argument whose type could hold such a view, and the error
> that this causes names the word to add.

---

## 6. The residual gap, stated honestly

After stage 4, Rig cannot express these, all of which Rust can:

1. **A callback that keeps its argument** (`hr_store`: `each(?arr,
   |!h, x| h.r = x)`).
   - Rig rejects every store of a closure parameter through a capture
     (T4).
   - Closable with the same word, `into`, naming the function
     parameter: `sub each(xs: []Item into f, f: ?sub(it: ?Item into f))`.
     Here "into f" means into what `f` captured to write.
   - Cost is about that of L1b, plus a third output channel that every
     store summary must include.
   - Wait for a real program: a `for` loop says the same thing today.
2. **Views inside owned closures, Cells and Signals** (`Box<dyn Fn + 'a>`,
   `Cell<&'a T>`).
   - Sentence 9 forbids it. That is not an origins question.
   - Closable by the rule `*T` already follows: such a value carries its
     contents' loans on every handle.
   - Matters for iterator adaptors returned as values, and for event
     wiring.
   - It is a sentence-9 Core change, not part of this decision.
3. **Generic types holding views** (`Wrapper<&'a T>` with methods).
   - T6 forbids them today. Adjacent to origins, and not solved here.
4. **Branded lifetimes** (GhostCell, `for<'id>` index brands, an
   invariant `'scope`).
   - Rig has no type-level origin variables, so two values cannot share
     a brand.
   - These are unsafe-backed library patterns. The part of
     `thread::scope` that matters, a callback whose views cannot
     escape, is already what Rig's stack closures guarantee.

**Not gaps (Rust has the same limit):**
- elements of a `Vec` or array of views share one origin;
- recursive types collapse to one origin;
- a result whose origin depends on a run-time value takes the union;
- a mutable cursor handing out `&'a mut` items;
- the write-to-read downgrade;
- self-referential structs.

**The residue in one sentence:** every "which argument does this view
come from" program that Rust accepts is expressible in Rig once stage 4
lands, except items 1–4. None of the four is about naming an argument.

---

## 7. Staging, cost and risk

Line counts come from impl §12, adjusted for red-team's repairs.
"Freeze" means today's rule: consolidation only, plus building the
Core's *(planned)* rules.

| # | Stage | Scope | Lines | Risk | Changes what Rig accepts |
|---|---|---|---|---|---|
| 0 | **Soundness prerequisites.** The store-into-parameter fix (§4.1, item 1) and the read-receiver fix (§4.1, item 2). Tripwire tests T1–T9. Correct the two misleading notes (`f2e`, `f5c`). | **freeze** (consolidation: rejects unsound programs, and turns wrong rejections into acceptances) | ~150 + tests | medium (item 1 touches four store sites) | `r3`, `r7`, `r8`, `r9` become rejections (they are unsound); `f2g` becomes accepted (`table_get` still needs `from self`, stage 2) |
| 1a | **Origins core.** The mapping fact (`call_params` with the receiver), `Origins` on `FunctionType`, the recorder, and the call rule with the default "all". The IR is unchanged. | freeze | ~150 | low | nothing (equivalence check: `test/equiv.py`) |
| 1b | **T0 `produces` default for results and stores,** with the body check | freeze, but CORE sentence 7's built text ("everything it was lent") must change to "every argument whose type could hold it". The owner signs off on the wording. | ~190 | low–medium | acceptances only: `produces`, `index`, `method_key`, `p31_over`, `f2c` |
| 1c | **T0 carry** (one `carry` classifier replacing `viewLoans`/`addViewLoan`/`throughReadSlice`; `ownReach` per type component) | freeze (generalizes a built rule) | +160 / −60 | medium | acceptances only: `cursor`, `deep2`, `prefix`, `f7` |
| 2 | **T1 `from`** on results, function types (with optional parameter names) and `extern zig`; `from static`; `from self.f` path tokens; origins in the function type with one coercion point; help lines from the recorder; `rig check --origins`; std writes `from s` three times and `from static` on `os.env` | **freeze**: sentence 7 already marks it *(planned)*. Add a `rig pending` example to CORE now, and promote it in this change, with SPEC, DESIGN "Borrows without lifetimes", BEYOND-RUST §2 and INTERNALS. Grammar mirrored in Nexus. | ~350 + 120 (paths) + 35 (grammar) | medium | acceptances only, and only where a signature says so |
| 3 | **T2 `into`,** stores default to nothing | **after the freeze, as a Core change** (it rejects today's setters until they write `into`; the help line writes it; about 4 of 45 functions in the repo) | ~200 (the recorder and the store channel exist by then) | medium | flips: setters need `into`. Accepts loggers, contexts, builders. |
| 4a | **Owner-side field paths** (disjoint `!p.x`, `!p.y`), with self-loan rejections at every store site and "partial use" as a positive list | after the freeze, Core change (CORE §5 "each field is a place", extended to lends) | 350–500 | **high**; alone on the ownership branch | acceptances: `disjoint` |
| 4b | **Holder-side parts:** per-field liveness, parts invalidated on absorb, per-field factory clause `-> Split(rest from s, sep from sep)` | after the freeze, Core change | 600–900 + ~100 | **high**; alone | acceptances: `split`, `f6b`, `f3_two_buffers`, `pair` (past Rust) |
| 5 | Callback `into f`; sentence-9 loans on `*fun`/Cell; static parameters (loans.md 6.1, on the same recorder) | when a real program asks; the static parameters follow HANDOFF's own schedule | 300–450 each | medium | acceptances |

**Gates on every stage:**
- The four suites stay green (suite, corpus, matrix, unit).
- `test/origins.py` (impl §13.3) is added in stage 1a and grows with
  each stage. It writes its own expected verdicts, and runs every
  accepted cell under `RIG_SANITIZE=1`.
- The reference checker gets its own mapping, `produces`/`ownReach`,
  and a mask comparison per body (impl §14). A `prod-unsound`
  disagreement blocks the merge.
- The AGENTS rule "a second soundness round stops the feature" applies
  per stage. Stages 4a and 4b are where it is most likely to trigger.
  If it does, the gap stays at Rust-minus-`split`, which is acceptable.

**What the user gets inside the freeze, stages 0–2:**
- every result-origin case Rust accepts, except two-owner holders;
- two use-after-free holes closed;
- a help line for every remaining over-approximation.

The store channel (logger) waits for stage 3. Until then it is partly
eased: stage 0 frees read receivers, and stage 1b narrows stores by
type.

---

## 8. The three strongest objections, and my answers

### Objection 1: "This is Rust's lifetimes with a new spelling. Rig promised no lifetimes."

**Answer.** What Rig promised (DESIGN, "Borrows without lifetimes") is
that a reader never solves lifetime equations. The design keeps that
promise:
- There are no variables, so there is no `'a` to introduce, unify, or
  bound.
- Structs never get origin parameters. Rust's signature noise comes
  from `Parser<'a>` spreading to every user, and Mojo's from its struct
  origin parameters; Rig has neither.
- A clause names a parameter or a place, in English, at the result:
  `-> String? from s`. This is where Rust itself is heading (place-based
  lifetimes, `'self.text`), and what Mojo, Dada and Swift converged on.
- The burden is measured: three clauses in all of std, and about 5% of
  view-returning functions in the tests. T0 removes the common cases
  (cursors, keyed lookups) with no syntax.
- The clause is *never* needed for safety, only to free an argument,
  and the error that asks for it writes it out.

The honest cost: a library author who wants callers to keep fewer loans
must say so in the signature. That is the price of a stable API, and
Rust charges the same price.

### Objection 2: "The compiler already computes the exact origins. Use them, and the user writes nothing: real 100%."

**Answer.** Inference is the meaning of `from`, not of a call. Making it
the meaning of a call fails on four counts, and each is independent:

1. **Bodiless boundaries.** `?fun` parameters, `extern zig` and
   `os.env` have no body, so the declared form must exist anyway.
   Inference only postpones meeting it.
2. **API stability.** A library adds `?? key` to a body, and callers in
   other modules stop compiling with no signature change (fit §4.1).
   Rust's auto-trait leakage is the cautionary tale.
3. **Errors that cite library internals.** The reasoning chain grows
   with the call graph.
4. **The Core.** §10 says "rules follow the value's type, never where
   the value came from". A private-only variant is an exception list,
   which AGENTS forbids.

What inference *does* buy, the design keeps. Every over-approximation
error names the exact word, and `rig check --origins` lists them all.
The work a user does is copying one help line, once, into the
signature, where it then documents the API.

The door stays open. Turning inference on later only adds acceptances
(formal §3), so if real programs show `from` to be noise, private
inference can be revisited without breaking anyone.

### Objection 3: "The type-based default (T0) makes a private field part of the API: adding `scratch: Vec[Tok]` silently re-locks every caller. And two mechanisms (type default and `from`) is one too many."

**Answer.** The dependence is real. It is the same class Rig already
has, and Rust has through auto traits:
- a struct's kind follows its parts;
- adding an owning field already changes whether the struct copies.

The design makes it visible:
- The error note names the field: "`Parser` can own a `Tok` itself, in
  field `scratch`".
- `from self.toks` is the stable contract, and std's public view-returning
  methods should write their clause explicitly.
- `rig check --origins` flags any `pub` function whose default is wider
  than its minimal origins.

The two mechanisms are one rule at two precisions, and they compose:
- The type default is what the signature's *types* already say. It is
  the generalization of today's `String` rule, which no user has
  noticed, because it simply does what they expect.
- `from` is what the signature's *words* say.
- Both are proved by the same body check, and read by the same call
  rule.

Dropping the type default would put a clause on every cursor and keyed
lookup, which is most of the burden. Dropping `from` would leave every
same-typed case (`strip_prefix`, `get`) unexpressible. That is the trade
the user asked to remove.
