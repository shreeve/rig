# Proposal: multiple results, not tuples

Design study, 2026-10-15, for the owner's question: *"Should Rig add
support for tuples? Is it a huge lift? Is it worth it? Or should there be
a simple object type that collects values like a tuple would?"*

Six reviewers answered independently: a language designer, a Go veteran,
a Rust and Swift veteran, a Python and Ruby programmer, an
ownership-checker reader, and a compiler engineer. Their probes are in
the session scratchpad (`scratchpad/tuples/{lead,go,rustswift,py,own,probes,zabi,eng}`).
Nothing in the repo was changed. The grammar was prototyped in a scratch
worktree outside it, which has since been removed.

Nothing here is decided. Every spelling is the owner's to choose. Any
change to `docs/CORE.md` goes through the owner's expert process.

---

## 1. Recommendation

All six reviewers agree on the shape of the answer.

| Candidate | Verdict | Vote |
|---|---|---|
| **A. Multiple results**: several results bound by name at once, never a value | **Yes, next.** It is the only form that can hand back a write view with something else, and it needs no partial moves. | 6 of 6 yes (5 say next, 1 says when asked) |
| **B. First-class tuples**: `(String, Int)` stored, in Lists, as Map keys | **No.** Revisit only after traits land, and only if a real program needs it. | 6 of 6 no |
| **C. A named object** for stored groups | **Yes, today, at no cost.** It already works, including as a Map key. Document it as the answer. | 6 of 6 yes |

In one line: **Rig gets Go's multiple results, not Rust's or Python's
tuples. A group that outlives its statement is a named object.** This is
the same choice Go made in 2009, and for the same reason. Go's checker
names all 41 of its composite map keys as structs, even though Go could
have used something else.

On the owner's three questions:
- **"Is it a huge lift?"** B is large: 25 to 40 days, a new structural
  type constructor in every per-type classifier, and a permanent rule for
  every future trait. A is medium: 8 to 16 days for the whole round, of
  which 2 days are ownership work.
- **"Is it worth it?"** A is worth it. B is not.
- **"A simple object type?"** It exists today. It does not need to be a
  new kind of type; at most, a one-line declaration form (decision D10).

Separate items the study surfaced, each its own round and none needing
tuples:

- **A Map lookup by a key built from views.** Build a
  `Map[Key, V]` key from a `?String` without copying the String
  (`find_as`, §8). Size M.
- **Small results in registers.** This is an emit choice, measured on its
  own. It serves C and A alike (§7).
- **Habit diagnostics** for things true today:
  - `for i, x in [5, 6]` silently swaps index and element when both are
    `Int`;
  - the `for k, v in m.items()` error suggests the wrong fix;
  - a bare "unexpected `,`" should name the habit it comes from.
- **`match a, b` over two values.** A separate, later feature. A comma
  already means alternatives inside a pattern, and matching two values
  needs an exhaustiveness matrix of their product.

---

## 2. Why not B

Six independent reasons. Each reviewer verified at least one.

1. **A write view cannot be stored, so `(?K, !V)` can never be a tuple
   type.** The case that motivates A most is a value's place plus a flag,
   `w, added = (!m).ensure_added(k, 0)`, and that is exactly what B
   cannot express. If A is spelled with parentheses, `(Int, Int)` means
   "two results". If B were added later, it would need an exception list
   ("a tuple type, unless it holds a `!`"), which CORE §10 forbids.
   Allowing `!V` results deliberately closes B; this is decision D2.
2. **Traits.** A structural type needs `==`, `.hash()`, printing, clone,
   and later every trait impl, at every arity:
   - Swift's tuples never got protocol conformance (SE-0283 was accepted
     and never built);
   - Rust implements its traits for tuples up to arity 12 by macro.

   Rig would owe a rule for tuples in every trait, forever.
3. **Partial moves.** Rig cannot move a field out of an object (RUST-TRIAGE,
   "Partial moves"). An owning tuple could therefore only be taken apart
   whole. The Rust and Swift probes confirmed this; the Go probes found
   Trig's glob `Parsed` already needing `take()` for the same reason.
4. **Syntax.**
   - `t.0` lexes as a REAL token, and `w.0.1` as `.0` followed by `.1`
     (verified). Only the rewriter could split them.
   - `(a, b)` would sit beside grouping `(a)`, type grouping `(?V)?`, and
     `(!s).insert(k)`.
5. **Readability.** `.0` and `.1` in long-lived code are what Python's
   namedtuple, Rust's lints, and Swift's labeled tuples all exist to
   avoid. A Rig object reads `e.key`, `e.value`.
6. **Size.** B is 25 to 40 days (compiler engineer), or 4 to 8 weeks plus
   permanent trait debt (language designer). It also overlaps the
   generic-loans work and #216, and composite keys need a new read-view
   fact per type.

**C already covers stored groups.** Objects get structural `==` and
`.hash()` (SPEC around line 3089). A generic `Pair[T, U]` works as a
`hash.Map` key (verified by the compiler engineer). An object may hold
read views and becomes a view itself. `std.hash`'s own `Item[K, V]` is
this pattern.

---

## 3. The evidence: lines that failed in real programs

CORE §10's last bullet asks that a feature answer "a line that failed in
a real program". A answers several.

**Trig, ported from TypeScript-Go:**
- **TypeScript-Go:** 888 to 933 of about 15,300 Go functions return more
  than one result (Rust/Swift and Go reviewers, counted separately). By
  shape:
  - about 498 are `(X, error)`, which maps to `X!`;
  - about 170 are `(X, bool)` meaning absence, which maps to `X?`;
  - about 220 return several real values.
- **Trig's core scope:** 220 multi-result functions. About 95 of them
  (43%) return two or three real values, mostly in the checker, which is
  not ported yet. The language designer's lower bound, counting
  single-line signatures only, found 106 in the core directories, of
  which about 32 are real pairs.
- **Trig's workarounds today:**
  - 26 one-use carrier objects, such as `SearchResult` and
    `LineAndByteOffset`, and `ModuleExportName`, which
    `parser.rig:2353` unpacks straight back into locals;
  - split calls, sentinel values, and one function left unported.

  The projection is 60 to 80 more carrier objects without A.
- **Callbacks:** 112 Go function types have several results, 5 of them in
  the checker. So **function types must take result lists too**.

**std.hash:**
- **`ensure_added`** (the value's place plus "was it new") was dropped
  because no object may hold a `!V`. A program can work around it today in
  either of two ways. Both run (`scratchpad/tuples/probes/q1.rig`,
  `q3.rig`), and both are clumsy:
  - a closure that captures a flag:
    `w = (!m).ensure_with(7, |!added, _| ...)`;
  - a length compare: `n = m.len`, then `ensure`, then
    `added = m.len != n`.
- **Trig NEEDS 42** (Go's `OrderedMap.EntryAt(index)`) is really "`hash.Map`
  has no O(1) index". C answers it today with a std method,
  `at(?self, i: Int) -> Item[?K, ?V]? from self`. A only changes the
  spelling, to `k, v = m.at(i)` or `while level.at(i) as k, v`.

**std.json:**
- **RIG-NOTES 9:** `take_digits` hands its value back through `m: !U64`.
  A two-field result object would already keep `m` in a register inside
  the callee and remove the per-byte memory traffic. Measure that first;
  see §7 for what registers do and do not buy.

---

## 4. The recommended design for A

These are the reviewers' consensus spellings. Every one is an owner
decision (§5).

```rig
fun divmod(a: Int, b: Int) -> (Int, Int)
  return a / b, a % b

sub main()
  q, r = divmod(17, 5)          # each name declares or assigns, as `x = e` does
  print(q, r)                   # 3 2
  _, r = divmod(9, 4)           # `_` discards; an owned result drops at the statement's end
  new q, r = divmod(1, 1)       # shadows, as `new x = e` does
  const a, b = divmod(8, 3)
```

**A write-view result**, which no other form can express:

```rig
pub fun ensure_added(!self, k: K, v: V) -> (!V, Bool) from self, k, v
  ...
  return w, false

sub count(m: !hash.Map[String, Int], word: String)
  w, added = (!m).ensure_added(<word, 0)
  w += 1
  print("new") if added
```

- `w` keeps the write loan on `m`, exactly as `ensure`'s single result
  does today.
- `added: Bool` carries no loan, because a call result's loans are
  narrowed by its type.

**Fallible and optional groups.** The `!` or `?` applies to the whole
list:

```rig
fun parse(s: ?String) -> (Glob, ?String)! from s
  ...

fun cut(s: ?String, sep: U8) -> (?String, ?String)? from s
  ...

sub use_them(s: ?String)
  g, rest = parse(s)!              # on failure nothing is bound
  head, tail = cut(s, 58) ?? return
  if cut(s, 61) as key, value and key.len > 0
    print(key, value)
```

**Function types and forwarding:**

```rig
sub walk(visit: ?fun(Node) -> (Bool, Bool))
  ...

fun again(a: Int, b: Int) -> (Int, Int)
  return divmod(a, b)              # forwarding a whole group is allowed
```

**Rejected, with these diagnostics:**

```rig reject
sub main()
  p = divmod(17, 5)
```
```error
`divmod` gives 2 results; bind each: `q, r = divmod(17, 5)`
```

```rig reject
sub main()
  print(divmod(17, 5))
```
```error
a call that gives several results stands only where each result is bound
```

```rig reject
sub main()
  q, r, s = divmod(17, 5)
```
```error
`divmod` gives 2 results, but 3 names are bound
```

```rig reject
sub main()
  xs: List[(Int, Int)] = List()
```
```error
`(Int, Int)` is a function's results, not a type a value can have: name an object for a stored pair
```

```rig reject
fun divmod(a: Int, b: Int) -> (Int, Int)
  (a / b, a % b)
```
```error
Rig has no tuple values: give several results with `return a / b, a % b`
```

```rig reject
sub main()
  a = 1
  b = 2
  a, b = b, a
```
```error
write `swap(!a, !b)` to exchange two places
```

```rig reject
fun split(s: ?String) -> (?String, ?String) from s
  return s[..1], s[1..]

sub main()
  s = String("ab")
  s, rest = split(?s)
```
```error
cannot bind `s` while `rest` views it
```

**Not in v1:**
- targets that are fields or elements (`i, xs[i] = f()` has an evaluation
  order the checker would have to fix);
- type annotations on targets;
- named results and naked returns;
- parallel assignment;
- `for k, v in ...`;
- groups as generic arguments;
- nesting a group inside another group.

---

## 5. Decisions for the owner

Each decision has a recommendation. All spellings are the owner's.

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Build A, and when | now (next round) / when Trig's checker port asks | **Next.** Trig has 26 carrier objects now and a projected 60-80 more; `ensure_added`; 95 real multi-value functions in scope. Run it strictly before or after the parked `keeps` round, generic-loans, and viewvalue-assign (they share `sema.Origins` and sentence 7), never in parallel. |
| D2 | Close B: no tuple values, `(A, B)` means results only | close / keep open | **Close.** Allowing `!V` results makes B impossible without an exception list. Revisit only after traits, with a real program's need. |
| D3 | Result type spelling | `-> (Int, Int)` / `-> Int, Int` / named `-> (q: Int, r: Int)` | **`-> (Int, Int)`, parentheses required.** The bare form is ambiguous inside a parameter list (`make: ?fun(?K) -> V, h: U64` exists in `std/hash.rig`). Make it a type-level node (`tuple_type` in `tatom`), so `!`, `?`, and `fun(...) -> (A, B)` follow, and sema restricts where it may stand. |
| D4 | Return spelling | `return a, b` / also a bare last line `a, b` / `(a, b)` | **`return a, b` only, in v1.** A bare last-line `a, b` is an LALR conflict (§9). A parenthesized last line would be B's tuple literal by the back door, so `(a, b)` stays an error with a hint. |
| D5 | Destructuring | `q, r = f()` with each name declaring or assigning / Go's `:=` split | **`q, r = f()`**, each name following today's `x = e` rule. This avoids Go's shadowed-`err` bug. `new q, r` and `const q, r` as for one name. `_` discards. Every result must be bound. Names only in v1. |
| D6 | Write-view results | allow none (ship plain results first) / allow at most one per call / allow several, checked by the callee's sentence 5 | **Allow them, at most one write-view result per call in v1**, and reject at the declaration a write-view result whose `from` parameter another result also views. That is simple and extensible; disjoint write views (`split_at_mut`-like) come later through sentence 5. Ship plain results and view results in the same round only if the oracle models both. |
| D7 | Parallel assignment and swap | allow `a, b = b, a + b` through temporaries / reject and point to `swap(!a, !b)` | **Reject in v1**, with the `swap` hint. `swap(!a, !b)` exists (SPEC "Replace and swap", sanitizer-clean). If allowed later, it must lower through temporaries: Zig's `a, b = .{ b, a }` prints `2 2`, verified in Zig 0.17. |
| D8 | Named results | documentation only, with a check that a binding's names don't swap the declared order / not in v1 | **Not in v1.** They invite Go's assignable result variables and naked returns. Positional with good function names reads well enough; revisit with Trig's checker port. |
| D9 | `for k, v in it` | decide now that `for` binds as many names as `next` gives / forbid in v1 | **Forbid in v1.** `for x, i in xs` already means element then index, so `for k, v` over a group-yielding iterator collides. Keep `for e in m.items()` with `e.key`, `e.value`. Decide after A lands, together with the iterators-as-values work. |
| D10 | A shorter object declaration for C | `obj Span(start: Int, end: Int)` on one line, the field list an enum variant already uses / nothing | **Consider separately.** It makes C as cheap to write as a namedtuple. It is pure syntax and needs no ownership work. |
| D11 | Optional groups `-> (A, B)?` | v1 / later | **v1, consumed whole only**: `?`, `?? return` or `?? break`, `if f() as a, b`, `while next() as a, b`. Not as a value and not as a `??` default. The `if ... as a, b` form has not had a conflict check yet (§9). |
| D12 | Fallible groups `-> (A, B)!` | v1 with every `catch` form / v1 with a `catch` that jumps only | **v1, `!` plus a `catch` that only jumps** (`catch return`, `catch break`). A `catch` yielding default values (`catch 0, 0`) waits. |

---

## 6. Where the experts disagree

| Topic | Positions | Resolution proposed |
|---|---|---|
| **Timing of A** | Language designer: later, when Trig's checker port or `ensure_added` asks (CORE §10: no line forces it yet). Go, ownership, compiler, Rust/Swift, Python/Ruby: next. | Next (D1). Trig's 26 carriers and `parser.rig:2353` are lines that already failed; the checker port is when the projected 60-80 more would land. |
| **Write-view results** | Go veteran: at most one per call (two would alias). Ownership expert: several, sound through the callee's sentence-5 check (disjoint fields pass, elements of one List are rejected: probe `c5`). Language designer: reject at the declaration when a write result and another result view the same parameter. Rust/Swift: one `from` covers all view results. | At most one in v1, plus the language designer's declaration check (D6). Lift it later through sentence 5. |
| **Parallel assignment and swap** | Python/Ruby: allow `a, b = b, a + b` through temporaries. Go veteran and compiler engineer: reject, and point to `swap(!a, !b)`. | Reject in v1 (D7). |
| **Named results** | Language designer: documentation only, with a check against binding them in swapped order. Compiler engineer and Go veteran: not in v1. | Not in v1 (D8). |
| **Size** | Ownership: 4-6 agent-days for the round (2 of them ownership). Go: 8-10. Language designer: 8-11 plus review. Python/Ruby: 1.5-2 weeks. Rust/Swift: about 2 weeks. Compiler engineer: 12-16. | Plan for about 2 weeks. The compiler engineer's list of passes (§10) is the most complete; the low figure counts the ownership change alone. |
| **`for k, v`** | Rust/Swift and language designer: decide "for binds as many names as the source yields". Compiler engineer, Python/Ruby: no destructuring in `for` headers. | Forbid in v1 (D9). |
| **Bare last-line results** | Language designer, Go, Python/Ruby wanted `a / b, a % b` as a function's last line. The compiler engineer measured a conflict. The language designer suggests parsing a comma list as one statement form and sorting it in the rewriter. | `return a, b` only in v1 (D4); the rewriter route can be prototyped later. |
| **How to desugar** | Ownership: N results in hidden statement temporaries, bound left to right. Language designer: for owned and read results, a `match` over a one-variant enum (`.results(a, b)`), which runs today (probe `d1.rig`); a write-view result extends "a binding may hold `!T`". Compiler engineer: `__res = f(a)`, then `q = <__res.0`, `r = <__res.1`. | These are the same desugaring seen from three sides; §7 states it once. |

---

## 7. The desugaring

### At the call

```rig
q, r = f(x)
```

means:

```rig
__res = f(x)          # a statement temporary (CORE §3), holding N results
q = <__res.0          # each bound left to right, by the rule `x = e` already has:
r = <__res.1          # declare or assign; an assigned name drops its old value
```

- **The temporary is the statement's own.** It lives only to the end of
  the statement, as every CORE §3 temporary does. Nothing ever names it,
  so a write view inside it is held, as soon as the statement starts, by
  the binding that receives it, just as `w = (!m).ensure(k, v)` holds one
  today. The Core paragraph must say this plainly: it is an extension of
  "a binding may hold `!T`", not of CORE §5's containers.
- **Owned and read results** need nothing new. They are exactly
  ```rig
  match f(x)
    .results(q, r)
      ...
  ```
  over a one-variant enum. The rest of the block is the arm, and a
  binding that assigns an existing name assigns it. The language designer
  ran this form today (`probes/d1.rig`).
- **`_`** drops an owned result at the end of the statement, the same as
  a `_` field of a variant pattern.
- **`f(x)!` and `?? return`:** the test comes before any binding, so on
  failure nothing is bound. This is today's `T!` and `T?` path, applied
  to the group.
- **Loans per result.** Every result carries the loans CORE sentence 7
  gives a single result: the union of the argument loans, narrowed by
  *that result's* type. In the code, `carryResult(ty_j)` is run once per
  result over the same union `walkCall` collects (ownership expert,
  verified). So a `Bool` beside a `!V` carries nothing.
- **The one change in rule:** an argument's write lend ends at the
  return only when *no* result keeps it to write.

### In the callee

```rig
return a, b
```

- Each part is walked as `return x`, left to right, and a bare owner
  moves (CORE sentence 1, extended to "each part of `return x, y`").
- `defer` and `errdefer` run as for one result, after every part has
  been evaluated (to test: `own/r2_ret_defer.rig`, `r3_ret_order.rig`).

### Emit (compiler engineer, verified on Zig 0.17)

- **Signatures** use `@Tuple(&.{ ... })`. The callee writes
  `return .{ a, b }`, with each element going through today's
  single-result paths.
- **The call site** uses a hidden `__rig_res_N`, then one step per
  target: drop flags, the `_` drop, and the old value's drop.
- **Zig's own destructure** `const q, r = f()` mixes a new constant with
  an existing variable. `struct { *V, bool }` is legal Zig; the rule
  against storing a write view is Rig's.

**Registers.** Speed is not a reason to choose A over C. Zig's default
calling convention returns two words through memory on both arm64 and
x86_64, for a struct and for a tuple alike. Three reviewers measured this
independently.
- `callconv(.c)` with an extern struct uses x0/x1 and rax/rdx, but it
  rejects slice parameters.
- A `u128` return does come back in registers, even with a slice
  parameter.

So "small plain results in registers" is a later, separate emit fact: pack
results of up to two words of integers, Bools, and pointers into a
`u128`. It serves objects and groups alike, and lands only if it passes
the speed rule. RIG-NOTES 9 should not be sold as A's payoff.

---

## 8. A Map lookup by a key built from views (separate)

The question B raised was looking up a `Map[(String, Int), V]` by
`(?String, Int)` without copying the String. It has a fix that needs no
tuples (Rust/Swift reviewer, probes in `rustswift/`):

- **Today:** `Key(name: ?s)` is rejected for a `Map[Key, _]`, though the
  hashes already agree. A `KeyView` object hashes the same as `Key`,
  because text hashes its bytes.
- **The fix:**
  - a "read image" of a generic key, so `Key[?String]` stands for
    `Key[String]`;
  - `==` across those instances;
  - `Map.find_as[Q](k: Q)`.

  That is hashbrown's `Equivalent`, without a trait. Size M, about a
  week, and it can land before traits. Rust cannot do this for tuples,
  which is one more reason not to build B to get it.

---

## 9. Grammar conflict check

Nexus 2.3.0 ran `nexus check` in a scratch worktree of `main` (since
removed). `main` is clean, at 1160 LALR states. The diffs are in
`scratchpad/tuples/eng/{a1,a2,b,c,all}.diff`.

| Variant | Change | Result |
|---|---|---|
| a1 | `returns` takes a list of result types | no conflicts (1178 states) |
| a2 | `tuple_type` in `tatom`: `"(" type "," types ")"` and named `"(" name ":" type, ... ")"` | no conflicts (1173). Preferred even for A: `(Int, Int)!`, `(A, B)?`, and `fun(...) -> (A, B)` follow |
| b | a `destructure` statement (`dtargets "=" tail`, with `new`/`const`) and `return a, b` (`rvals`) | no conflicts (1180) |
| c | tuple values `(a, b)` plus `.0` fields (B) | no conflicts (1182) |
| a2+b+c | all together | no conflicts (1202) |
| tail | a bare last-line `q, r` as a result | **conflict**: state 41 on `,`, shift into `dtargets` versus reduce `unary` |

Caveats:

- **`.0` lexes as REAL.** B's field access would need the rewriter to
  split it.
- **`if f() as a, b` and `while next() as k, v`** (D11) were not part of
  the check. They must be prototyped before D11 is settled, next to the
  joined `and` bindings.
- **Rig declares no conflicts today**, and the grammar's policy keeps it
  that way.

---

## 10. Size and build order (A)

**About two weeks for the round.**

**Passes** (compiler engineer):
1. Grammar and rewriter. Sema reports "not built" until the round lands,
   with `rig pending` doc examples.
2. Resolve: the kind of a result-list type.
3. Typecheck:
   - the destructure statement;
   - a positive list of the places a several-result call may stand: a
     destructure, `return f()`, `!`, `?? jump`, `if`/`while ... as`.
4. Storage: a new `StorageKind` for results, with N target steps in
   order, and temporary facts for `_`.
5. Ownership, then the full matrix:
   - a `walkDestructure` that splits the call's `Value` by result type;
   - `walkReturnValue` for each part.
6. The oracle: a hidden variable plus a take per target. It must model A
   before A lands (ownership expert).
7. Emit.
8. Proofs: `ResultBound.fields` per result.
9. Docs:
   - SPEC: functions and results;
   - SYNTAX;
   - CORE, after the owner's process;
   - QUICK;
   - WELCOME: "Go's multiple results and Python's tuples in Rig".
10. Tests:
    - about 10 behavior and 12 reject tests;
    - a `destructure` form in `test/matrix.py`;
    - then the deep gate.

**Soundness grid to test first** (ownership expert):
- results that view one owner:
  - `(?K, !V)` and `(!A, !B)` from one owner;
  - the same parameter returned twice;
- the targets:
  - a target viewed by a pending result;
  - element targets;
  - write-view-local targets;
- `_` on an owner and on a `!`;
- the callee's `return`:
  - a later part failing;
  - `errdefer`;
  - forwarding;
- a temporary receiver;
- each context: `if`, `match`, loops, closures capturing a destructured
  view, `defer`, generics, and a call as a direct argument;
- the frame account counting the hidden temporary.

A first sign of a second soundness round stops A for redesign. The one
the ownership expert expects is `(?K, !V)` from one owner, and v1 avoids
it through D6.

---

## 11. Core impact

The owner's expert process must approve this before CORE changes. The
proposed text, merged from the ownership expert's, the language
designer's, and the Go veteran's:

> **Sentence 7, added paragraph.** A function may give several results,
> `-> (A, B)`. Its call stands only where every result is bound at once,
> `a, b = f()`, `if f() as a, b`, or `return f()`; the results never form
> a value, so §5 is untouched. Each is a result as above, carrying the
> loans its own type could hold, and held from the start by its binding,
> so one may be a write view as `-> !V` is. An argument's write lend ends
> at the return only when no result keeps it to write. A `_` drops an
> owned result at the end of the statement. *(planned)*
>
> **Sentence 1, amended.** "...it moves only where the value leaves for
> good: `return x`, each part of `return x, y`, `break x`, ..."

That is one paragraph with no exception list, written as a desugaring
into §3 temporaries plus the existing binding rules. It adds no
per-type fact (CORE §9). The "at most one write-view result" of D6 is a
v1 restriction in SPEC §18, not a Core rule, since the Core's sentence 5
already implies the general case.

B would have needed a new structural type in every one of CORE §9's
per-type facts, plus a new read-view fact for keys.

---

## 12. What it unblocks

- **Trig:**
  - the about 95 two- and three-value functions of its checker port, and
    the 112 callback types with several results;
  - retiring 26 carrier objects, or keeping them where they really are
    stored;
  - NEEDS 42's spelling, `k, v = m.at(i)`. The capability itself needs
    only a std `Map.at` returning `Item[?K, ?V]?` today.
- **std.hash:** `ensure_added(!self, k, v) -> (!V, Bool)`, the call
  dropped for lack of a way to return it. It is one probe and one insert,
  where the length-compare workaround costs an extra read.
- **std.json:** `take_digits` can return its position and value as
  results, not through `m: !U64`. The register gain is §7's separate emit
  item.
- **Newcomers:** `q, r = divmod(a, b)` works as Go and Python programmers
  type it. `(a, b)`, `a, b = b, a`, and `List[(Int, Int)]` get a
  diagnostic that names the Rig form.
- **Later:**
  - iterators yielding groups (D9);
  - `find_as` keys (§8);
  - small results in registers (§7);
  - `match a, b`.

  None of these needs B.

## Owner decisions (2026-10-16)
- Build A (multiple results). Not B.
- v1 takes the proposal's recommendations: at most one write-view result per call; `a, b = b, a` rejected with a hint to `swap(!a, !b)`; no named results; no `for k, v`; results written `return a, b`; run one at a time with keeps/generic-loans.
- Owner idea for a future tuple spelling: `{ a, b }`. Braces are unused anywhere in Rig today, so this would keep tuple values (`{A, B}`) distinct from result lists (`(A, B)`), and B would need no exception list against A. Not built; not reserved yet (owner to decide whether braces go to tuples or to future map/set literals).
- Owner (2026-10-16): agrees with all recommendations. Likes a LATER `for (k, v) in m` (parentheses mark "two results per step", distinct from `for x, i` = element, index), once iterators can return results. `(a, b) = (b, a)`: no; `swap(!a, !b)` is clearer. Named results: probably never.
- Queued side items, owner-approved: (1) a diagnostic for the index-first habit (`for i, x in xs` when the first name is a conventional index name); (2) `find_as`: Map lookup by a key built from views, without copying; (3) small results returned in registers (a u128 packing emit item, for objects and results alike).
- Owner (2026-10-16): also likes 'for (k, v), i in m' (key, value, plus the insertion-order index) for the later for-results form.
- Owner (2026-10-16): destructure is the bare form only, 'q, r = f()'; '(q, r) = f()' rejected with a hint. One spelling.

- Note (2026-10-15): parked branches are archived as tags: archive/viewvalue-assign (the assign-through-call half), archive/keeps, archive/inline, archive/mapset-inline, archive/symbols-prototype.
