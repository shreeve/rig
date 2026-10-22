# Rig principles audit: did the sigils hold?

Repo: `/Users/shreeve/Data/Code/rig` at `cf644a0` (main). Read-only review.
Probe programs: `scratchpad/purity/principles/p*.rig` (each one was run
with `bin/rig run`, and most were also inspected with `bin/rig emit`).

## Verdict

**Mostly held. It did not cave on the core.** Moves, borrows, clones,
shares, weak handles, and failure propagation are marked at the site,
and the compiler enforces this. The emitted Zig confirms that
reference-count traffic happens only where `+`, `*`, `~`, `upgrade()`,
or a drop appears (probes p08 and p25). A bare name never silently
copies an owning value. `for x in v` over a Vec is rejected until you
write a sigil. Default field values cannot allocate.

The purity breaks in five places. In three of them the design breaks
its own written promises, and all of them are worth fixing before the
standard library freezes conventions:

1. **Interior mutability.** Through `Cell` and `Signal`, a call that
   looks read-only (`c.peek()`, `inspect(?c)`) can change the value
   and allocate memory. A private field can hide this from other
   modules. There is also a checker hole: a by-value parameter can be
   changed through a `?self` method.
2. **Failure by value.** A bare `.name` in a `T!` function either
   fails or succeeds, depending on whether `T` happens to have a
   variant with that name.
3. **`!` in a Bool value.** In a binding or an argument,
   `dup = !s.insert(1)` means "insert", while every C, Rust, or JS
   reader sees "not insert". The design promised this could never
   happen.
4. **Swallowed and hidden runtime failures.** `print` ignores write
   errors. Releasing a deep chain of handles can allocate memory, and
   can abort if that allocation fails.
5. **Error names are global.** `Disk.timeout` is caught by a check
   for `Net.timeout`.

Beyond those, several concessions are defensible but go further than
the docs admit:

- drops at scope end and on assignment;
- the implicit move of a bare name at the end of a function;
- writing through a `!T` binding with plain `=`;
- a bare `match s` reading its subject;
- `print` reading its arguments without `?`;
- allocation in `push` and out-of-memory as a panic.

Several sentences in WELCOME.md and DESIGN.md are literally false
today; they are listed at the end.

Classification key:
- **(a) principled**: the effect is visible elsewhere and the rule is uniform.
- **(b) defensible concession**: an effect without a mark at the site, for a good reason.
- **(c) real violation**: hidden control flow, a hidden move, clone, allocation, refcount change, or mutation, or an effect the reader cannot see.

---

## 1. Inventory: every effect that happens without a sigil at the site

| # | What happens with no sigil or keyword | Class | Probe |
|---|---|---|---|
| 1 | Writing through a `Cell`, `Cell[Vec]`, or `Signal` from a read path (`?self` method, `?T` param, `=!` binding) | **c** | p04, p28_mod, p33 |
| 2 | A by-value parameter changed through a `?self` method that writes a Cell (the spec says this is rejected) | **c** (checker hole) | p33 |
| 3 | `.name` or an error-typed binding as a `T!` function's value silently means *fail* | **c** | p06, p06b, p06c |
| 4 | `x = !s.insert(k)`, `print(!s.insert(k))`: the `!` reads as "not" but means write-borrow | **c** | p18 |
| 5 | `print` discards I/O errors (exit status 0 with stdout closed) | **c** (minor) | p24 |
| 6 | Releasing a deep chain (more than 256 nested) allocates a queue entry, and aborts if memory runs out | **c** (minor) | runtime.zig:318, :480 |
| 7 | `x =! y` and `x = !y` mean different things; only a space differs | **c** (minor) | p19 |
| 8 | Error identity is by name alone: `Disk.timeout == Net.timeout` | **c** (semantic) | p29 |
| 9 | Drop at scope end (runs user `drop` bodies at a dedent) | b | p02 |
| 10 | Assigning to an owning binding or field drops the old value | b | p02 |
| 11 | A bare name at the end of a function moves, including branch tails and `a if c else b` | b | p21 |
| 12 | Write-through: `w = 5`, `t.count += 1` change a variable declared elsewhere | b | p03, p23 |
| 13 | `match s` (bare) read-borrows the subject; `p.m()` read-borrows the receiver | b | p26 |
| 14 | `print(v, r, h)` reads owning values with no `?` | b | p07 |
| 15 | Structs holding a `Cell` are Copy: `b = a` forks mutable state | b, borderline c | p22, p33 |
| 16 | Allocation in `!v.push`, `Box(v)`, `*x`, `*\|..\|` (two allocations), `Vec(capacity:)`; running out of memory is a panic | b | runtime.zig:185, :788 |
| 17 | Calling a stack closure that captured `\|!x\|` changes `x` | b | SPEC §11 |
| 18 | `sig.set(v)` runs every subscriber (user code) | b | p05 |
| 19 | Large Copy values are copied silently (`y = x` copies 8000 bytes) | b | p01 |
| 20 | `new x = ...` keeps the old owner alive, unnamed, until scope end | b | p02 |
| 21 | Runtime panics: overflow, bounds, conversions, `copy` length, stack guard, leak check exit | b | SPEC §1 |
| 22 | `-n` on a Copy value, as a statement, is accepted and does nothing | b (tiny) | p11c |
| 23 | Plain data is copied on use (numbers, Strings, plain structs, arrays) | a | p01 |
| 24 | Reading through `*T` (field or `?self` method): no count change | a | p08 emit |
| 25 | Box auto-deref for `b.f`, `!b.m()`; `?b`/`!b` lend the inner value | a | p09 |
| 26 | Refcount changes only at `+`, `*`, `~`, `upgrade()`, and drops | a | p08, p25 emit |
| 27 | `for x in xs` over an array, slice, String, range, or call result | a | p14 |
| 28 | Default field and parameter values (cannot allocate: `Vec(capacity:)` is rejected) | a | p14 |
| 29 | `??`, `catch`, `?? return`, `catch break` | a | keywords/operators |
| 30 | Integer literal to float, `T` to `T?`, `T` to `T!`, temporary array to `[]T` | a | p10 |
| 31 | `defer`, `errdefer` | a | keywords |
| 32 | Closure captures (each carries its sigil); stack closures allocate nothing | a | p12 emit |
| 33 | String literals (static; nothing allocates strings) | a | |
| 34 | Match payload bindings copy plain data | a | p13 |
| 35 | Generic instantiation (one Zig instance per type; no hidden effects) | a | p15 |
| 36 | `raw` (block only, narrow: builtins and `extern` calls) | a | p16 |
| 37 | `e!` and `e?` run defers and drops on the early exit | a | p17 |
| 38 | A held read borrow or `![]T` lent as a read with no sigil | a | p10 |

DESIGN.md already admits only four implicit effects: copying plain
data, reading through a shared handle, lending a `?self` receiver, and
`return x`. Everything in rows 9 to 22 goes beyond that list.

---

## 2. The real violations (c), with examples and the Zig they become

### C1. Interior mutability hides mutation and allocation behind a read

```rig
struct Counter
  hits: Cell[Int]
  log: Cell[Vec[Int]]

  fun peek(?self) -> Int
    self.hits.set(self.hits.get() + 100)
    self.log.push(self.hits.get())        # allocates; no `!`
    self.hits.get()

fun look(c: ?Counter) -> Int
  c.peek()

sub main
  c = Counter(hits: Cell(0), log: Cell(Vec()))
  a = c.peek()          # looks like a read
  b = look(?c)          # a *read* borrow, and `c` changes
  print(a, b, c.hits.get(), c.log.len)   # 100 200 200 2
```

The emitted Zig casts away `const` to write:

```zig
pub fn peek(self: *const Counter) i64 {
    @constCast(&self.hits).set(self.hits.get() + 100);
    @constCast(&self.log).vecPush(self.hits.get());
```

Across modules it is invisible. In `p28_mod/`, `cache.rig` has a
private field `seen: Cell[Vec[Int]]` and `pub fun lookup(?self, ...)`.
The importer writes `c.lookup(2)` and `inspect(?c)`, and cannot see
the field that changes and grows.

This contradicts three statements:
- DESIGN line 60: "at a call, `!` marks exactly the values it may change";
- WELCOME line 117: "so every mutation is visible";
- DESIGN line 304: "`x =! e` marks a binding that never changes". In
  p33, `m =! Counter(...)` followed by `m.hit()` changes `m`.

**The checker hole (p33).** SPEC §10 says: "A by-value parameter is
immutable … so neither can be changed (or lent to something that
could change it)." A direct `c.hits.set(9)` on such a parameter is
rejected, and so is `k.hit()` on a loop binding. But this is accepted:

```rig
sub viaMethod(c: Counter)
  c.hit()          # hit(?self) sets a Cell; accepted
  c.hit()
  print("param changed to", c.hits.get())   # 2
```

It is memory-safe, because the parameter is a local copy
(`var c = __rig_arg_1`). But it is a spec-versus-checker mismatch: the
compiler accepts a program the spec says it rejects. By the repo's own
rules this needs a failing test first.

### C2. Failure by value: whether it fails depends on a declaration elsewhere

```rig
error E
  missing

enum Color
  red
  green

fun pick(k: Int) -> Color!
  return .red if k == 0
  .missing              # fails, because Color has no `missing`

sub main
  print(pick(0) catch Color.green, pick(1) catch Color.green)  # .red .green
```

Add `missing` to `Color` (p06b) and the same body now *succeeds* and
prints `.red .missing`. There is no error and no warning. The emitted
Zig changes from `return error.missing;` to `return .missing;`.

Likewise, `e = E.bad` followed by `e` as the last line (p06c) is a
failure, with no `return` and no keyword. SPEC §13 allows both
("`.name` when `T` has no variant of that name", "a binding of an
error set's type"). This is a failure path the reader cannot see at
the site, and the meaning flips when an unrelated declaration changes.
DESIGN explicitly condemns that ("adding a local elsewhere can never
change a closure's meaning").

### C3. `!` in a Bool value position reads as "not"

```rig
struct Set
  items: Vec[Int]

  fun insert(!self, k: Int) -> Bool
    ...

sub main
  s = Set(items: Vec())
  dup = !s.insert(1)          # Rust/JS/C reader: "not inserted"
  print("dup?", dup)          # prints: dup? true   (it WAS inserted)
```

It becomes `const dup: bool = s.insert(1);`. Rig rejects this form in
conditions and as an operand of `and`, `or`, or `not`, but deliberately
accepts it in bindings, arguments, and return values (SPEC line 805,
and `test/behavior/types/receiver_sigil_bool_value.rig`). DESIGN says:
"A habit can make a program fail to compile, never change what it
means." This is a habit that changes what the program means.

### C4. `print` swallows failures

`print` writes with `catch {}`, and the final flush does too
(runtime.zig:1217, :1225). Build p24 and run `./p24 >&-`: the exit
status is 0 and all output is lost silently. Rust's `println!` panics
here, and Zig forces you to handle the error. This is a hidden failure
in the one I/O primitive Rig has.

### C5. A release can allocate, and can abort

When releases of `*T` or `Box` nest deeper than 256, the runtime
pushes onto a global `drop_queue` using `smp_allocator`, followed by
`catch oom()` (runtime.zig:318, :480). So `-x`, or a plain scope end,
can allocate memory and can panic. This contradicts "no hidden
allocation" and DESIGN's "A sigil never fails at run time" (for `-x`).
In practice it is rare, since it needs very deep chains and real
memory exhaustion.

### C6. Spacing changes meaning: `=!`

```rig
sub main
  y = 1
  x =! y       # fixed binding: a copy of y
  z = !y       # write borrow of y
  z += 5
  print(x, y)  # 1 6
```

Both forms compile. DESIGN says a spacing "can be wrong but never mean
something else". The only thing rejected is the touching form
`x =!y`. Harm is usually limited, because later misuse gets caught,
but the principle is broken.

### C7. Errors are identified by name alone

```rig
error Net
  timeout

error Disk
  timeout
  full

fun write(k: Int) -> Int!
  return Disk.timeout if k == 0
  k

sub main
  r = write(0) catch |e|
    if e == Net.timeout
      print("network timed out?")    # prints: a disk error matched as a network one
    0
  print(r)
```

This is documented (SPEC §13) and inherited from Zig's global error
set. It is not an ownership leak, but it is an effect the reader
cannot see: an arm written for one library's error catches another's.
A standard library full of error sets (`eof`, `timeout`, `invalid`)
will make this common.

---

## 3. Defensible concessions (b): examples and reasons

**B1. Drops at scope end.** `a = Noisy(1)` then a dedent runs
`drop 1`. The Zig is `defer rig.drop(&a)`, with a guard flag when the
value may move first. This is RAII, as in Rust and C++. The type
announces it, `-x` exists for releasing early, and DESIGN admits it
("`-x` and scope exit release"). It still contradicts WELCOME line 54,
"A reader sees every … drop … on the line where it happens."

**B2. Assignment drops the old value (p02).**
```rig
a = Res(n: 1)
a = Res(n: 2)      # prints "drop 1" here, with no sigil
h.r = Res(n: 4)    # prints "drop 3"
```
The Zig is `{ const __rig_new_1 = Res{.n=2}; rig.drop(&a); a = __rig_new_1; }`.
Rust does the same, and any other rule would leak or need
`-a; a = ...`. It is defensible, but it runs user code at a plain `=`,
and the docs do not list it among the implicit effects.

**B3. Tail moves (p21).** `return x`, a bare `x` as the last line,
**and** the last line of an `if` branch or a ternary `a if c else b`
all move with no `<`. Yet `break a` from a value loop requires `<a`,
and `<(a if c else b)` is rejected. It is defensible because the
scope ends anyway, but the rule is wider than documented ("only a bare
name returned directly") and inconsistent with `break`. It also
contradicts WELCOME line 218: "a bare name never moves an owning
value."

**B4. Writing through a `!T` binding or field (p03, p23).**
```rig
struct Tally
  count: !Int

sub main
  n = 0
  t = Tally(count: !n)
  u = <t
  u.count += 10       # changes n; nothing on this line says so
  print(n)            # 11
```
The borrow is marked where it is taken (`!n`), and the rule is
uniform. Rust would make you write `*w = 5` at the write. This is the
largest "action at a distance" in the language, and still defensible:
the `!` marks the loan, and the type records it.

**B5. Bare `match s` and bare `p.m()` read-borrow.** DESIGN admits
the receiver case. But `match s` on an owning enum reads with no `?`,
while `for x in v` over a Vec is rejected until you write `?v`, and
`if m as x` on an owning optional requires `?m`, `<m`, or `+m` (p26).
These are three spellings of the same effect, and only one of them
may be left bare.

**B6. `print` reads its arguments bare (p07).** `print(v, r, h, b)`
takes a Vec, a struct with `drop`, a `*T`, and a `Box` with no `?`.
It is a builtin that only reads, so it is harmless. But a user
function cannot get the same courtesy (p20: `f(p)` for a `?P`
parameter is rejected with a hint to write `?p`).

**B7. Copying a value that holds a Cell (p22, p33): borderline.**
```rig
a = Counter(hits: Cell(0))
b = a            # silent copy of the Cell
b.hit(); b.hit(); a.hit()
print(a.hits.get(), b.hits.get())   # 1 2
```
It is consistent with "plain data copies", but copying interior-mutable
state is a classic trap. Rust's `Cell` is not `Copy`. In p33,
`viaMethod(k)` copies the Counter, so the callee's changes are lost
with no sign at the call.

**B8. Allocation, and running out of memory.** `!v.push(x)` may
reallocate. `Box(v)`, `*x`, and `Vec(capacity: n)` allocate. `*|…|`
makes **two** allocations (the environment and the count box: see the
p12 emit), although DESIGN's cost table says `*x` is "one allocation".
Every allocation failure is `@panic("out of memory")`. This is the
same as Rust, and the allocating operations are known by type (WELCOME
lists them). But Zig, whose cost model Rig claims, makes both the
allocator and its failure explicit. `Cell[Vec].push` allocates with no
`!` at all (see C1).

**B9. A closure that captured `|!x|` changes `x` when called**
(`add(1)` in SPEC §11). It is visible at the capture, and the same
reasoning as B4 applies.

**B10. `Signal.set` runs user callbacks (p05).** It is a method call,
and methods can do anything. The trap is that `Cell.set` is a plain
store while `Signal.set` runs arbitrary code.

**B11. Large Copy values copy silently (p01).** `y = x` copies an
8000-byte struct, and passing it by value copies it again. Rust
arrays behave the same way. This is a cost, not a correctness issue.

**B12. `new x` keeps the old owner alive (p02).** The shadowed `a`
still holds `Res(2)` until the end of the scope, where it drops with no
name visible. Rust does the same.

**B13. Safety panics.** Overflow, bounds, checked conversions, `copy`
length mismatch, the stack-guard exit, and the leak-check exit in
Debug. These are standard for safe modes.

**B14. `-n` on a Copy value.** As a statement it is accepted and does
nothing (p11c). The fix is to reject it; see section 5.

---

## 4. Does each sigil mean one thing everywhere?

| Char | Roles | Harm |
|---|---|---|
| `!` | write borrow (expression and type), `T!` fallible, `e!` propagate, `sub f()!`, `=!` fixed binding, `!=` not-equal | **High.** C3 (`dup = !s.insert(k)` reads as "not") and C6 (`=!` vs `= !`). `!=` is the one place `!` *does* mean "not", despite WELCOME's "`!` never means 'not'". |
| `-` | drop (statement), negate (value), subtract, `-%` | **Medium.** Whether `-x` drops or negates depends on whether the enclosing `if` or branch value is used (p11, p11d): in a `fun`'s value-branch `-x` negates, and in a statement branch the same text drops. Most misreads are caught ("use of `y` after drop"), but `-n` on a Copy value silently does nothing. |
| `?` `!` `<` vs `+` `*` `~` `-` before `p.m()` | the first three bind to the **receiver**; the other four bind to the **result** | **Medium.** `<p.f` moves (takes) the field, but `<p.f()` moves `p`. `!p.f` borrows the field, but `!p.f()` borrows `p`. `?p.m()` borrows `p`, but `+p.m()` clones the result. A reader must look ahead for a `(` to know what the prefix touches. |
| `<` | move, less-than, `<<`, `<=`, and "take, leave `none`" on an optional field | **Low to medium.** The position rule is clean (`a <b` is a comparison). But `<p.f` on an optional field *writes* the struct (it leaves `none`), while `<x` on a binding only ends its use. One sigil, two effects. |
| `?` | read borrow (expression and type), `T?` optional, `e?` propagate none, `??` fallback, `?fun` borrowed callable | **Low.** The position rule keeps these unambiguous; `?User?` and `(T?)?` take practice. |
| `*` | share (expression), shared handle (type), multiply, owned closure `*\|..\|`, `*%` | **Low in Rig, real for Zig readers.** A Zig reader, the target audience, reads `*T` as a pointer. `rig emit` then shows Rig `!T` as Zig `*T` and Rig `*T` as `*rig.RcBox(T)`. |
| `+` | clone (a count change for handles, a copy for Copy values), add, `+%` | Low. |
| `~` | weak only | None. |
| `\|` | closure bars, bitwise or, `catch \|e\|` | Low. |

Overall, the "position picks the category" law is real and well
enforced: the grammar has no conflicts, and a prefix must touch its
operand. The overloading hurts in exactly three places: `!` meets
Bool, `-` depends on whether a value is used, and the receiver-sigil
exception splits the prefixes into two binding rules.

---

## 5. What to change before the standard library, ranked

**1. Settle interior mutability (C1, B7, and the checker hole).**
- **Fix the hole first.** Reject lending a by-value parameter to a
  `?self` method that may write a Cell, as the spec says and as the
  loop-binding check already does. Cost: tiny, plus a reject test.
- **Make any type that holds a `Cell` non-Copy.** Then `b = a` is
  rejected and `+a` copies explicitly. Cost: small, a few tests.
- **Allow Cell writes through a read path only when the Cell sits
  behind a `*` handle** (`*Cell[T]`, or a field of something reached
  through `*T`). A Cell stored inline in a value would then be written
  only through `!self` or `!x`. This restores "`!` marks exactly what
  a call may change" except for shared state, and there the sharing is
  visible in the type.
  - Cost: moderate. Counter-style examples (`hits: Cell[Int]` with
    `hit(?self)`) become `!self` or use `*Cell`; `memo_canary` needs a
    look.
  - Why now: stdlib caches, memoizers, and iterators will copy
    whichever convention exists.
- At minimum, if you keep today's rule, correct DESIGN lines 60 and
  304 and WELCOME line 117.

**2. Make failing explicit (C2).** A failure should need the error
set's name (`return E.missing`, or `E.missing` as the last line), or a
keyword. A bare `.name` should never resolve to an error, and an
error-typed binding as a function's value should need `return`.
- Cost: small. It is a typecheck change plus a few doc and test lines.
- Why now: the stdlib will add many enums and error sets that share
  names like `.eof`, `.timeout`, and `.invalid`.

**3. Give errors their set as identity (C7).** Emit set-qualified Zig
error names (for example `error.Net__timeout`), so that
`Disk.timeout != Net.timeout`. A bare `.timeout` in a pattern or
comparison would then need an unambiguous set.
- Cost: moderate. It touches the emitter, printing (`.timeout` output),
  and `catch |e|` matching.
- Why now: this is breaking once libraries exist.

**4. Close the `!`-as-"not" gap (C3).** Require the long form
`(!s).insert(k)` wherever a write-borrowing call's `Bool` value is
used, not only in conditions.
- Cost: tiny. It is one check, three SPEC lines, and one behavior test
  moved to reject.

**5. Decide the allocation and out-of-memory story (B8, C5).**
- **Minimum.** Say plainly that running out of memory panics; fix
  DESIGN's "a sigil never fails at run time" and "one allocation".
  Make releases allocation-free: an intrusive link in the `RcBox`/`Box`
  header, or reusing the dying box's own memory, instead of
  `drop_queue.append(...) catch oom()`. Cost: small.
- **Larger.** ROADMAP already lists "allocators" for the stdlib.
  Decide now whether containers take an allocator and offer fallible
  `try_push -> T!`. After the stdlib ships, this is not reversible.
- Also mark `Cell[Vec].push` (it allocates through a read path) under
  item 1.

**6. Give `print` a failure policy (C4).** Panic on a write error (as
Rust does), or remember the failure and exit non-zero in `finish()`.
- Cost: tiny.
- Why now: stdlib I/O needs the same policy, and `print` sets the
  precedent.

**7. One rule for implicit reads and moves (B3, B5).** Either require
`match ?s` when the subject owns resources, matching `for x in ?v`, or
allow the bare form in both. Make `break x` follow the same tail-move
rule as `return x`, or require `<` in branch tails.
- Cost: small, with some test and doc churn.

**8. Tidy the sigil edges.**
- Reject a statement `-x` on a Copy value (it does nothing).
- Consider requiring parentheses when `+`, `*`, `~`, or `-` stands
  before a method call (`+(n.first())`), so that every prefix directly
  before `p.m()` is a receiver sigil. Cost: small.
- Replace `=!` with a word (for example `fix x = e`) so that spacing
  cannot change meaning. Cost: syntax churn across the docs; lowest
  priority.

**9. Doc truth pass.** Each of these sentences is false today:
- WELCOME line 54: "A reader sees every move, borrow, clone, drop, and
  failure path on the line where it happens." Scope-end drops,
  assignment drops, tail moves, and C2 contradict it.
- WELCOME line 117: "every mutation is visible". C1 and B4 contradict
  it.
- WELCOME line 218: "a bare name never moves an owning value". Tail
  moves contradict it.
- WELCOME line 51: "`!` never means 'not'". `!=` does.
- DESIGN line 60: "`!` marks exactly the values it may change". C1
  contradicts it.
- DESIGN line 110: "`*x` … one allocation". Owned closures make two.
- DESIGN line 118: "A sigil never fails at run time". `*x` can run out
  of memory, and `-x` can too (C5).
- DESIGN line 304: "`x =! e` marks a binding that never changes". C1
  (p33) contradicts it.
- DESIGN line 330: "A habit can make a program fail to compile, never
  change what it means". C3 contradicts it.
- DESIGN line 455: "a spacing can be wrong but never mean something
  else". C6 contradicts it.
- DESIGN lines 54 to 57: the list of what stays implicit omits scope-end
  and assignment drops, write-through, bare `match`, and `print`.
