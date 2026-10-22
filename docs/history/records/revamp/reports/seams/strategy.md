# Is there merit in Rig? A strategy review

Read-only review of `main` (8a82fab) and the `text-core` branch
(`../rig-text`, 15 commits, +1,157/-124 lines in `src/`). I read the
README, AGENTS.md, DESIGN, WELCOME, SPEC (skimmed; §7 Temporaries and
§10 Text in full), STD, ROADMAP, the examples, the earlier evaluations
in `purity/` and `stdlib/`, and the revamp ledger. I wrote three
programs on the branch build; they and a few probes are in
`seams/strategy/`.

## The short answer

**Yes, there is real merit, and it is narrower than the project's
current effort suggests.** Rig's core idea, that every ownership effect
is a one-character mark at the place it happens, checked by the
compiler, in a syntax a Python programmer can read, is new in its
combination and it works. The earlier evidence holds up: shorter than
Rust and Zig in 3 of 4 programs, a third of Rust's brackets, no safety
holes found, near-Rust speed.

The danger is not that the idea is wrong. It is that the project is
spending its complexity budget at the edges (how long a temporary in an
`if` header lives) while the center is still missing (a `Vec` of
records that hold owned text is rejected today). A language dies of
that pattern more often than of a bad core idea. The fix is to stop,
shrink the newest rule to one sentence, finish the center, and write a
real program before adding anything else.

---

## What it felt like to write Rig

Three programs a working programmer would write, run with
`rig-text/bin/rig`:

| Program | Tries | Result |
|---|---|---|
| `rpn.rig`: an RPN calculator with an error set, per-line error reporting | 2 | Works. |
| `words.rig`: word frequency, lowercase into a `Text`, count views of it, sort | 1 | Works first time. |
| `tasks.rig`: a task list, records with an owned name, sorted, with a text report | failed | Cannot be written. `tasks_box.rig` is the closest workaround, and it cannot sort. |

**The good.** The failure handling in `rpn.rig` reads better than
Python and says more than Rust:

```rig
b = pop(!stack)!                                   # writes stack, may fail, passes it on
n = text.parse_int(tok) catch return CalcError.unknown_token
v = eval(line) catch |e|
  print(line, "=> error:", e)
  continue
```

`words.rig` is Rig at its best. A `Vec[Entry]` whose entries hold
`String` views into one lowered `Text`, checked by the compiler, no
lifetimes written, no copies made:

```rig
low = lowered(input)
counts = count_words(?low)       # Entry(word: <view of low>, count: n)
sort.sort_by(!counts[..], |a, b| a.count > b.count or (a.count == b.count and a.word < b.word))
for e in ?counts[..3]
  print(e.word, e.count)
```

It compiled and ran first time. In Rust this is a lifetime parameter on
`Entry`. In Zig it is an unchecked slice that can dangle.

**The bad.** Small frictions: a block `match` arm written `_ =>`
followed by an indented body gives a bare "unexpected indentation" with
no hint. There is no character literal and no `match` on a String, so
the calculator matches `tok[0]` against `43`, `45`, `42`.
`!board[2].done = true` is a parse error ("unexpected `=`").

**The serious one.** The most common data shape in everyday code, a
list of records that each own a string, does not compile:

```text
tasks.rig:21:10: error: `Vec[T]` requires `T` to be a Copy type ..., plain data ...,
  a shared handle, a weak handle, or a box (`Box[T]`); got `Task`
```

With `Vec[Box[Task]]` the program can build and print the list. But
`!board[2]` is rejected ("iterate with `for x in ?v` instead"). I had
to write `for t, j in !board` and `t.done = true if j == 2`. Sorting is
impossible: "cannot slice a `Vec[Box[Task]]`". `Vec[Text]` is rejected
too, by design, in favor of `Vec[Box[Text]]`.

So the branch added a thousand lines to let `print(Text(...))` and
`if text.cut(?Text("k=v"), "=") as kv` work. Meanwhile a to-do list
still cannot be sorted. That is the whole strategy problem in one
example.

---

## 1. Merit: is there a real niche?

### What is genuinely new or better

1. **Ownership effects are visible at the call site, as a closed
   algebra.** `f(?x)`, `f(!x)`, `f(<x)`, `+h`, `-x`, `*v`, `~h`, plus
   `e!` and `e?`. No mainstream language does this. Rust shows `&` and
   `&mut` at some call sites but hides them on method calls, the
   most common case (`v.push(x)` mutates silently). Rig requires
   `!v.push(x)`. Swift, Mojo and Hylo put conventions in signatures
   only. Mojo has one sigil (`x^` for transfer), not a system.
2. **Rust-grade checking without lifetime syntax, in practice.** The
   second-class-borrow model (Swift, Hylo, Mojo) combined with borrows
   in struct fields and returned borrows tracked by origin. `words.rig`
   stores views in a `Vec` of structs with no annotations, and misuse
   is rejected with both locations named.
3. **Per-variable closure capture modes** (`|+total, ~sig, !out, k|`).
   Rust's `move` is all-or-nothing. Swift's capture lists are close
   but optional, and strong by default.
4. **"A habit can break the compile but never change the meaning."**
   `&&`, `!done`, `x++`, `class`, `None` are each rejected with the Rig
   spelling. This is a real, testable design stance that few languages
   hold.
5. **Leak checking by default in every Debug run**, including strong
   cycles, which Rust leaks silently.
6. **Zig as the backend, emitting readable Zig.** You get
   cross-compilation, C ABI and an optimizer for free, plus an audit
   path: `rig emit` shows exactly what runs.

### What is not new (and should not be sold as new)

- The ownership model itself is Rust's: move, shared-xor-mutable,
  Rc/Weak, RAII drop.
- Second-class references come from Swift, Hylo and Mojo.
- Python-style syntax compiled to a systems language already exists:
  Nim, Mojo, Lobster.
- Duck-typed generics checked per instance are Zig's and C++'s, with
  the same weakness: signatures do not say what `T` needs.
- Error unions and optionals are Zig's and Swift's.

The novelty is the combination and the visibility. That is enough to
justify a language, but only if the combination stays small. A large
Rig is just Rust with different punctuation.

### Who Rig serves better than the alternatives

| Language | Where Rig is better for its niche | Where the alternative wins |
|---|---|---|
| **Rust** | Readability of ownership (mutation visible on method calls), no lifetimes, Rc/Weak/RefCell code about half the size, no runtime `BorrowMutError`, leak check | Maturity, crates, traits, iterators, threads and async, allocation control, a sound formal core |
| **Zig** | Safety, no allocator plumbing, no `deinit`/`errdefer` bookkeeping (the Zig family program had a double free on the first draft) | Allocator control, explicit error sets, full comptime, C interop, "no hidden anything" |
| **Go** | No GC, deterministic drop, value types, speed, Rust-level safety for resources | Simplicity, tooling, concurrency, ecosystem, stability |
| **Swift** | No hidden ARC traffic (every count change is written), cross-platform by default | Ecosystem, protocols, concurrency; Swift's ownership features are catching up |
| **Odin** | Memory safety | Simplicity, C-level control, game-dev libraries |
| **Nim** (closest in look) | No macros, no hidden copies or moves, one way to do things, borrow checking rather than ARC/ORC plus a cycle collector | Maturity, ecosystem, metaprogramming, C/C++/JS backends |
| **Mojo** (closest in intent) | Fully open, a general-purpose target, a sigil system rather than keywords, no Python-compatibility baggage | Python interop, MLIR, a funded team, GPU |
| **Vale** | Shipping and simpler: static borrows, not generational references plus regions | Research ideas (regions, generational refs) |
| **Hylo** | Borrows can live in fields and results, not only in parameters; it exists and runs | A cleaner theory (mutable value semantics), subscripts |
| **Austral** | Far less verbose; Python-readable | Austral is small enough to verify by hand; linear types plus capabilities |
| **Lobster** | General-purpose, explicit rather than inferred ownership | Lobster's inference means you write nothing; it is game-focused |

**The niche, stated plainly.** Single-threaded systems and tool code
where a reader must be able to see what the code does to memory. That
means CLI tools, interpreters and compilers, simulations, data-structure
and graph code, and embedded-style logic built with the Zig toolchain.
It serves three kinds of people:

1. **Zig users who want safety** for application code without leaving
   the Zig toolchain.
2. **Python and Ruby programmers who need native speed** and bounce off
   Rust's syntax.
3. **Reviewers and teachers.** Anyone who must read ownership in code
   they did not write: code review, auditing generated code, and
   teaching ownership. Rig may be the clearest notation yet for
   teaching Rust's model.

It does **not** serve, and should not try to serve: concurrent
servers, async I/O, anything that lives on an ecosystem, or anyone who
needs allocator control (use Zig) or trait-heavy abstraction (use
Rust).

**Merit verdict: yes.** It is a real, defensible niche, and a genuinely
new idea: visible, checked, one-character ownership. It is not a Rust
replacement, and it should not measure itself as one. Its realistic
wins are: a language its author and a small circle are more productive
and safer in than Rust or Zig; a readable front end to Zig; and an
idea other languages borrow. All three need Rig to stay small.

---

## 2. The risk: where Rig could fail

### The four risks, ranked for this project

**1. A checker that is too hard to keep sound. This is the highest
risk, and it is live.** Soundness in Rig is established by adversarial
probing, not by construction. The ledger shows the pattern on every
phase: brackets (Phase C found use-after-free and double drop), the
revamp audits (three critical ownership bugs, including an unchecked
block tail after `?? return`, and a dangling temporary borrow), and
text-core (four review rounds). The typecheck audit counted about 13
separate place and writability predicates where one place-access
analysis should be. That refactor has been deferred twice. Each new
rule about *where* a value stands (a `print` argument, an `==` operand,
an `if` header, a `while` header for one pass, a branch of a `??`)
multiplies against every existing rule. With no formal core, only more
probing can find the gaps.

**2. Complexity creep. Live.** Measures:

- About 31 carve-outs a learner must memorize, and 24 "not yet"
  restrictions (designer review).
- SPEC is 5,242 lines on the branch.
- The hand-written compiler is about 32k lines, and grew by about 1k
  for Text.
- 114 tokens, 10 of them classified by a lexer rewriter.

That is roughly the size of a finished language's specification (Go's
is in the same range). Rig's covers a language that cannot yet sort a
list of records with names.

**3. Dependence on the Zig toolchain. Real, but managed.** Zig is
pre-1.0 and breaks its std and build APIs on most releases
(`docs/zig-0.16.md` is 1,100 lines of what changed). The good news:
emitted code touches Zig's std in only a handful of places (for
example `std.process.Init` for `main` and `std.mem.order` for String
comparison). Almost everything goes through `src/runtime.zig` (127
`std.` uses) and the `std/*.zig` shims (about 34). So a Zig upgrade
mostly touches a few files, not the emitter. The remaining risk is Zig-language changes (for example, to
`defer` or error unions, which Rig's semantics lean on) and being tied
to Zig's release cadence. It is manageable if the surface stays
narrow.

**4. Ecosystem. Structural, not fixable, and acceptable.** Rig will not
have crates. Two things make this acceptable: C FFI and Zig-backed
declarations give it a borrowing route, and its niche (tools a person
writes and owns) needs a good standard library more than an ecosystem.
It becomes fatal only if Rig tries to compete for server or async
work.

**A fifth risk, specific to how Rig is built:** the ledger shows about
800 commits in one week, from parallel implementer agents. That
velocity produces code faster than one person can hold it in their
head. The single maintainer's understanding of the checker is the real
soundness backstop, and velocity erodes it. Review rounds find
critical bugs because the code grows faster than its invariants are
written down.

### Early warning signs, and whether they are present

| Warning sign | Present? | Evidence |
|---|---|---|
| A feature needs 3 or more fix rounds to become sound | **Yes** | Text and temporaries: 4 rounds. Brackets: 3 or more. |
| A rule is stated as a list of positions, not as a property of a value | **Yes** | SPEC §7 Temporaries lists `print`/`Text(...)` arguments, `==` operands, `match` subjects, part reads, `?` lends, then `if`/`match`/`for` headers extended, and `while` headers per pass |
| A value's rules depend on where it came from, not on its type | **Yes** | A generic body storing `T` in a `Cell` "cannot be instantiated with a `T` that holds a String, even when every String passed is a literal" |
| Edge features land before center features | **Yes** | Header-scoped temporaries shipped; `Vec[Task]` with a `Text` field, `?v[i]` on owning elements, and `Map` did not |
| The docs call things "settled" that are not built | **Yes** | ROADMAP: `?v[i]`/`!v[i]` and generic method calls on `T` are "settled", and both are still rejected |
| Checker lines grow faster than programs that work | **Yes, on this branch** | About +1k lines. The new everyday programs it enabled are mostly `print(Text(...))` and headers without a binding. |
| A known consolidation refactor keeps being deferred | **Yes** | The place-access unification (13 predicates to 1) |
| The "not yet" list grows faster than it shrinks | Roughly flat | New features add rejections (for example `Vec[Text]`) about as fast as others are removed |
| Fuzzing finds accept-means-correct failures each round | Yes, but fixed each time | Healthy process, but a symptom of risk 1 |

Most of the warning signs are present. None is fatal yet. The trajectory,
if it continues, leads to a checker nobody can confidently change, and
to a SPEC nobody reads.

---

## 3. Scope discipline: what Rig should deliberately not do

### The "don't" list

1. **No user-facing lifetimes. Keep this, permanently.** Accept that
   some Rust programs cannot be written. The workaround is always a
   clone, a `*T`, or a restructure. This is Rig's main
   readability win. Give it up and Rig has no reason to exist.
2. **No traits, interfaces, or dynamic dispatch.** Keep duck-typed
   generics checked per instance. Build the already-decided "method
   call on `T`, checked at each use" (for `hash`, `eq`, `less`,
   `next`), and name those few conventions in SPEC. Do not add
   coherence, orphan rules, associated types, blanket impls, or trait
   objects. When dispatch is needed, a struct of `*fun` fields is
   explicit and enough.
3. **No operator overloading.** `==` and `<` stay built in for numbers,
   Strings, and plain data. No user `+`, and no `+` on text (Rig
   already says this: text is built with `Text(...)`).
4. **No macros, no comptime reflection, no compile-time code
   execution** beyond constant arithmetic. Drop "compile-time functions"
   from the roadmap unless a real program needs one. Conditional
   compilation on OS, architecture, and build mode is fine: it is a
   table lookup, not a language.
5. **No async, and no concurrency in the core language for now.** Keep
   it on the roadmap as research. The niche is single-threaded. If
   threads come, do it as one structured `spawn` scope plus an atomic
   `*T`, nothing more.
6. **No allocator parameters and no fallible allocation.** One global
   allocator, and out-of-memory panics, as Rust's std does. Say so as a
   non-goal in DESIGN, not as a gap. Zig users who need arenas use
   Zig. (A scoped arena might come later, as a library type, if a real
   program needs it.)
7. **No more implicit reads or conversions that depend on position.**
   Either adopt one rule ("a bare place is lent for reading where a
   `?T` is expected") or keep today's rules. Do not add a third
   variant.
8. **No more string types.** `String` (view) and `Text` (owned) only.
   No `Cow`, no `OsString`, no `CString`, no `Char` type; bytes are
   `U8`. A character literal is fine as sugar for a `U8`.
9. **Nothing in the runtime that a library could do.** `Signal` is a
   reactive primitive in the core runtime, which is in tension with
   "no built-in reactive framework". Move it to `std` (or examples)
   once owned closures can express it.
10. **No Rust-style temporaries beyond one sentence.** See below.

### Rust-style temporaries, evaluated explicitly

What the branch does: a fresh owning value (a call, a constructor,
`*x`, `+x`, `<x`, a literal, or an `if`, `match`, `??`, `catch`, or
block whose branches are all fresh) that is only read lives until its
statement ends. A borrow of it may be used anywhere in the statement.
The temporaries of `if`, `match`, and `for` headers live through the
whole statement, including the body. A `while` header's temporaries
live one pass.

**What it buys:** `print(Text("n=", n))`, `f(?Text(...))`,
`make().len`, `text.trim(?Text(" x ")) == "x"`, and
`if text.cut(?Text("k=v"), "=") as kv` with no binding. These save one
line each, and each is a line where the author names a value that
matters.

**What it costs:**

- Four review rounds, and about 60 mentions of temporaries in
  `typecheck.zig`, 38 in `emit.zig`, and 19 in `ownership.zig`.
- A SPEC section written as a list of positions.
- Rust's own history: Rust 2024 changed the temporary scope of tail
  expressions and of `if let` scrutinees, because the old rules caused
  deadlocks and surprises. C++'s lifetime-extension rules are a
  standard interview trap. Rig imported the part of Rust that Rust
  itself regrets.

**Recommendation: keep one sentence, cut the rest.**

> *A call's or constructor's owning result that is only read lives
> until its statement ends; nothing may keep a borrow of it past the
> statement.*

That covers `print(Text(...))`, `f(?Text(...))`, `make().len`, and the
`==` case, which is most of the convenience. Then:

- **Cut** freshness through `if`, `match`, `??`, `catch`, blocks,
  `e!`, and `e?`. Those values must be bound.
- **Cut** header extension: an `as` binding in an `if`, `while`,
  `match`, or `for` header may not hold a borrow of a temporary.
  The diagnostic says "bind it to a name first", which already
  exists.

Judging by the commit messages of the fix rounds ("check if-header
temporaries", "owner branches", "decide temporaries by one fresh-value
predicate", "check if-header views at joins"), the cut parts are where
most of rounds 2 to 4 went. I have not measured how many lines it
would remove. Measuring that is step 1 of the plan. The cut is
backward compatible to widen later, which is the right direction to
err in.

### The smallest feature set that makes Rig a real, usable language

Already there: structs, enums, `match`, optionals, errors per set,
generics, modules with paths, the ownership sigils and checker,
`Cell`, `Box`, `*T`, `~T`, closures, `raw`/`extern`, `test` blocks,
exit codes, and (on the branch) `Text` plus `String` views.

Missing, and required, in this order:

1. **Owning values in containers**: `Vec[T]` for any `T` (a `Vec[Task]`
   whose `Task` holds a `Text`, and `Vec[Text]`); `?v[i]` and `!v[i]`;
   sorting such a Vec. This is the center. Without it Rig cannot hold
   ordinary data.
2. **`Map[K, V]`** (insertion-ordered, as decided) with String and Int
   keys first, then keys of any type with `eq` and `hash` via method
   calls on `T`.
3. **Basic I/O**: read a file into a `Text`, write a file, stdin lines,
   stderr, and a `print` that does not end the line.
4. **Panics and traces with `.rig` line numbers.**
5. **`assert` in tests.**
6. **A character literal and `match` on Strings.** These are small, and
   the calculator needed both.

That is it. Everything else on the roadmap (value parameters on
generic types beyond integers, compile-time functions, raw pointers,
traits, async, a `try` block, drop bodies for generic types unless a
container needs one) waits for a real program to demand it.

### Is the planned standard library scope right?

**Mostly yes. The order is wrong.** The phases are: (1) foundation,
done; (2) Text, fmt, io, fs, parse; (3) owning elements plus Map and
Set; (4) generics on `T` and polish. The scope is roughly right: a
"batteries for CLI tools" library in the Go style, written in Rig over
thin Zig shims.

The flaw is that phase 3 is not a library phase. "Owning elements" is
a language feature, and phase 2 already collides with it (`Vec[Text]`
is rejected, and so is a record with a `Text` field in a `Vec`). Move
owning elements, `?v[i]`/`!v[i]`, and method calls on `T` ahead of io
and fs.

Cap the library at: math, os, time, random, sort, slices, text, fmt,
io, fs, and collections (Vec, Map, Set). No networking, regex, JSON,
crypto, or threads in `std` until there is a design that needs them.
Those can be userland packages.

One readability note: `text.cut(text.trim(line), " = ")` reads worse
than `line.trim().cut(" = ")`. Methods on `String` from a std module
would suit the Python/Ruby audience. This is not urgent, but decide it
before the text API freezes.

---

## 4. Guiding principles: decision rules for every future feature

Each rule is testable by a person or a script at review time.

1. **One paragraph, no position lists.** A feature is explainable in
   one SPEC paragraph that states a property of values or types, with
   no "except" and no list of more than three syntactic positions.
   *Test:* the feature's SPEC paragraph, counted for "except",
   "unless", "but", and enumerated positions.

2. **The checker sees only core forms.** New syntax desugars, in the
   grammar or the `rig.zig` IR rewrite, into IR nodes the checkers
   already handle. The ownership checker gains a new node kind only
   when the language gains a new effect, which means a new sigil.
   *Test:* the PR's diff to `ownership.zig`'s node switch is empty, or
   the PR adds a sigil.

3. **Rules follow the type, not the history.** Whether a value may be
   stored, moved, or kept depends on its type and on the borrows the
   checker tracks, never on where the value came from syntactically
   (a literal, a header, a branch). *Test:* SPEC contains no "even
   when" or "only when written as" for the feature.

4. **Center before edges.** A feature enters only if a line in a real
   Rig program (the dogfood tool, `examples/`, or `std/`) fails without
   it, and the PR makes that program run. Convenience that saves a
   binding is an edge. Holding ordinary data is the center.
   *Test:* the PR links the failing program and the friction-list
   entry.

5. **Pay for what you add.** Every feature PR reports its net
   hand-written compiler lines and its change to the carve-out count
   (kept as a list in SPEC or DESIGN). A feature that adds a carve-out
   removes one. More than about 300 net checker lines needs the
   author's explicit sign-off, with the reason written in the PR.
   *Test:* a CI script prints both numbers.

6. **Restrict first, widen later.** When a rule is uncertain, ship the
   narrow version as a rejection with a Rig diagnostic that names the
   workaround (usually "bind it to a name first"). Widening later
   breaks no program; narrowing later breaks many. *Test:* every new
   rejection has a `test/reject` case whose message names the fix.

7. **When to say no.** Say no (or "not yet") if **any** of these hold:
   - It saves less than one line per use over an existing spelling.
   - It needs a second fix round for soundness after its first
     adversarial review. Cut it back to the part that passed, rather
     than patching a third time.
   - A library could do it.
   - It cannot be explained to a Python programmer in three sentences.
   - It exists only to match Rust or Zig, and not for a Rig program.

   *Test:* the PR description answers each point.

---

## 5. A three-step plan to get back on track (ordered)

### Step 1: Simplify and land Text. Freeze new features. (About 1 to 2 weeks)

- Cut temporaries to the one-sentence rule (§3): remove header
  extension and branch freshness, turn their tests into rejections
  that say "bind it to a name first", and measure the lines deleted.
  Then land `text-core`.
- Do the deferred place-access unification in `typecheck.zig`
  (13 predicates into one analysis). This is soundness by construction
  instead of by probing, and it is the best investment against risk 1.
- Adopt principles 1 to 7 in AGENTS.md. Add the CI script for rule 5
  (checker line delta and carve-out count).
- Fix ROADMAP: nothing is "settled" unless it is built. Mark the rest
  "decided, not built".
- Slow the agent velocity. One feature branch at a time, and the
  maintainer reads every checker diff.

### Step 2: Finish the center. (The minimum usable language)

In this order, each with tests first, and principle 4 as the gate:

1. `Vec[T]` of owning values (records holding `Text`, and `Vec[Text]`),
   `?v[i]` and `!v[i]`, sorting them. Success means `tasks.rig` in
   this directory compiles as first written.
2. Method calls on `T` in generic bodies (the `eq`/`hash`/`less`
   conventions).
3. `Map[K, V]` with insertion order.
4. Basic io and fs, and panics with `.rig` lines.
5. A character literal and `match` on Strings.

Nothing else enters.

### Step 3: Dogfood, then freeze the core.

- Write one real program of 500 to 1,000 lines (the planned
  mini-emdb, or a CLI tool such as a log analyzer or a CSV query tool)
  and keep a friction list. Only friction-list items may enter the
  roadmap.
- Then declare "Rig core 0.1": the sigils, the borrow rules, and the
  temporaries sentence are frozen. After that, new work goes to
  `std`, diagnostics, the formatter, and source maps, not to the
  checker.
- Pin the Zig version in `rig` itself, with a clear error on a
  mismatch. Move the few direct Zig std calls left in the emitted code
  into `runtime.zig`, so that all Zig std use lives there and in the
  `std/*.zig` shims.

---

## Files

- `seams/strategy/rpn.rig`: RPN calculator (works).
- `seams/strategy/words.rig`: word frequency over Text views (works
  first time).
- `seams/strategy/tasks.rig`: task board as a programmer would write
  it (rejected: `Vec[Task]` with a `Text` field, indexing, sorting).
- `seams/strategy/tasks_box.rig`: the boxed workaround (works, but
  cannot sort).
- `seams/strategy/probe1.rig` to `probe6.rig`: String `match`, char
  literal, sorting a `Vec[Box[T]]`, views in a Vec, String methods.
