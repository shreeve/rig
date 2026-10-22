# Rig through Rust and Zig eyes

A read-only review of Rig on `main` (commit `cf644a0`), done by writing
the same four programs in Rig, Rust and Zig. The repo was not changed.

All code is in `purity/rustzig/`:

| Program | Rig | Rust | Zig | Emitted Zig |
|---|---|---|---|---|
| (a) BST, owned children | `bst.rig` | `bst.rs` | `bst.zig` | `bst.emit.zig` |
| (b) word frequency | `words.rig` | `words.rs` | `words.zig` | `words.emit.zig` |
| (c) mutate through a borrow, fail, handle | `stock.rig` | `stock.rs` | `stock.zig` | `stock.emit.zig` |
| (d) parent/child graph, strong down, weak up | `family.rig` | `family.rs` | `family.zig` | `family.emit.zig` |

The brief said the Rust and Zig versions did not need to compile. Both
toolchains were installed (rustc 1.98.1, Zig 0.16.0), so I compiled and
ran all twelve programs. Each set prints the same output, with two
small differences explained below. The Rig programs run leak-free under
`bin/rig run`. `probes/` holds about 25 small programs that test safety
and diagnostics. `bench/` holds a timing test and a Rust borrow-cursor
test.

---

## 1. The programs

### (a) Binary search tree

Rig (`bst.rig`, 44 code lines):

```rig
struct Node
  key: Int
  left: Box[Node]?
  right: Box[Node]?

  sub insert(!self, key: Int)
    if key < self.key
      if !self.left as l
        !l.insert(key)
      else
        self.left = Box(Node(key: key, left: none, right: none))
    else
      ...

  sub walk(?self, visit: ?sub(Int))
    if ?self.left as l
      l.walk(visit)
    visit(self.key)
    if ?self.right as r
      r.walk(visit)
...
  fun sorted(?self) -> Vec[Int]
    out: Vec[Int] = Vec()
    self.each(|!out, k| !out.push(k))
    out
```

Rust (58 lines) has the same shape: `Option<Box<Node>>`, `&mut self`,
and `impl FnMut`. Zig (77 lines) needs `destroy` by hand, an allocator
on every insert, `try` on every allocation, and a context-plus-function
callback. The error set must also be `anyerror`, because a recursive
function cannot infer its own.

### (b) Word frequency: the closest Rig gets today

Rig has no hash map, no owned or growable string, no string building,
and no way to view a `[]U8` as a `String`. So `words.rig` keeps
`Vec[Entry]` (word view, count), finds each word with a linear scan,
compares words with a hand-written case-insensitive `same_word`, and
sorts by insertion with `!xs.swap`. It cannot print a lowercased word,
so it prints the first spelling it saw. Its output starts `The 4`,
where Rust and Zig print `the 4`.

| | Rig | Rust | Zig |
|---|---|---|---|
| code lines | 40 | 19 | 31 |
| map | linear `Vec` scan | `HashMap` + `entry` | `array_hash_map.String` + `getOrPut` |
| split | hand byte loop | `split(..).filter(..)` | `std.mem.tokenizeAny` |
| lowercase | impossible to produce; compare only | `to_ascii_lowercase()` | `std.ascii.allocLowerString` |
| sort | hand insertion sort | `sort_by` | `std.mem.sort` (stable) |

Missing, confirmed by running probes:
- `Map[String, Int]` is an unbound name.
- `print(buf)` of a `Vec[U8]` prints `[116, 104, 101]`.
- `s: String = ?buf[..]` is rejected: ``expected `String`, got `[]U8` ``.

This is the one program where Rig loses on every measure. The cause is
the library, not the language core: the loops themselves read cleanly.

### (c) Mutate through a borrow, fail, handle

```rig
struct Stock
  items: Vec[Item]
  shipped: Int = 0

  fun take(!self, name: String, qty: Int) -> Int!
    i = self.find(name) ?? return StockError.unknown
    return StockError.short if self.items[i].qty < qty
    self.items[i].qty -= qty
    self.shipped += qty
    self.items[i].qty

fun ship(stock: !Stock, name: String, qty: String) -> Int!
  n = parse_qty(qty)!
  !stock.take(name, n)!

sub main
  ...
  for o in orders
    left = ship(!s, o[0], o[1]) catch |e|
      match e
        .short => print(o[0], "short")
        .unknown => print(o[0], "unknown")
        _ => print(o[1], "is not a number")
      continue
    print(o[0], "left", left)
```

This is Rig at its best. `!stock.take(name, n)!` says "writes `stock`,
may fail, pass the failure on" in two characters. Rust says
`stock.take(name, n)?` and hides the write. Zig says
`try stock.take(name, n)` and also hides the write.

Rig pays for this in one place: the `_ =>` arm. Rig functions do not
declare which errors they fail with, and every fallible function
lowers to `anyerror!T`. So a `match` on an error can never be
exhaustive, and a new error variant falls silently into the catch-all.
Rust's `match` on `StockError` and Zig's `switch` on `StockError!i64`
are both checked for exhaustiveness. My Zig `switch` needs no `else`.

### (d) Shared graph, strong down, weak up

```rig
struct Node
  name: String
  parent: ~Node?
  children: Cell[Vec[*Node]]

  drop(!self)
    print("free", self.name)

fun child(parent: ?*Node, name: String) -> *Node
  up = +parent                     # workaround, see below
  kid = *Node(name: name, parent: ~up, children: Cell(Vec()))
  parent.children.push(+kid)
  kid

fun depth(n: ?*Node) -> Int
  d = 0
  cur = +n
  while ?cur.parent as w
    up = w.upgrade() ?? break
    cur = <up
    d += 1
  d
```

Rust (46 lines) needs `Rc<Node>`, `Weak<Node>`, `RefCell<Vec<Rc<Node>>>`,
`Rc::downgrade(parent)`, `.borrow_mut()`,
`.as_ref().and_then(Weak::upgrade)`, and `impl Drop`. Rig says the
same things with `*`, `~`, `+`, `Cell`, and `drop(!self)`, in 35 lines.

Zig has no refcounting in std. The idiomatic Zig version (49 lines)
uses single ownership with a raw `?*Node` back-pointer that nothing
checks. It cannot express "drop `a` and `b` but keep the tree alive".
It also cannot express "a1 outlives root" without detaching a1 by hand
and clearing its parent pointer, or the pointer dangles. My first Zig
draft had a real double free: an `errdefer root.destroy()` was still
armed after the explicit `root.destroy()`. It would fire if the next
`print` failed. The Rig and Rust versions cannot make that mistake.

Drop order differs in one detail. Rust's `Vec` drops its elements
front to back (`free a`, `free b`). Rig's drops them back to front
(`free b`, `free a`). Both are consistent; a Rust user should know.

---

## 2. Comparison

### Line count and noise

Code lines, with comments and blanks removed. "Punct" counts
`{ } ( ) ;`.

| Program | Rig lines / punct | Rust lines / punct | Zig lines / punct |
|---|---|---|---|
| (a) BST | **44** / 58 | 58 / 129 | 77 / 201 |
| (b) words | 40 / 45 | **19** / 85 | 31 / 103 |
| (c) stock | **48** / 46 | 66 / 152 | 67 / 190 |
| (d) family | **35** / 48 | 46 / 132 | 49 / 134 |

Rig is shortest in three of four programs and has about a third of the
punctuation. The noise it adds is ownership sigils: roughly 10 to 22
per program. Each one carries meaning, so this is signal, not
ceremony. Rust's noise is `&`, `&mut`, `Some(..)`, `Box::new`,
`Rc::clone(&..)`, `.borrow_mut()`, and braces. Zig's is `try`,
`gpa` threaded everywhere, `defer`/`errdefer`/`deinit`, `.*`,
`catch {}` on writer calls, and braces.

### How visible ownership and failure are

| Effect | Rig | Rust | Zig |
|---|---|---|---|
| move | `<x`, always written | bare `x`, implicit | copy; nothing marks it |
| read borrow | `?x` | `&x` (auto-ref on methods) | `&x` or by value (auto-ref) |
| write borrow | `!x`, required even on a method call you own | `&mut x`, **hidden on method calls** | `&x`, hidden on method calls |
| clone / refcount bump | `+x` | `Rc::clone(&x)` / `.clone()` | by hand |
| drop now | `-x` | `drop(x)` | `x.deinit()` / `destroy` |
| weak | `~x` | `Rc::downgrade(&x)` | none |
| propagate failure | `f()!` | `f()?` | `try f()` |
| handle failure | `catch` | `match` / combinators | `catch` |
| allocation | by type (`Box`, `*`, `Vec`); not marked at `push` | by type; not marked | **explicit allocator at every allocating call** |
| mutation through shared state | `cell.set(..)`, `cell.push(..)`, no `!` | `.borrow_mut()` | by hand |

Rig makes ownership the most visible of the three. It is second only
to Zig on allocation, and it ties with both on failure.

Mutating a `Cell` needs no `!`: `parent.children.push(+kid)` mutates
without a sigil, while `!v.push(x)` on a plain Vec requires one. The
rule is principled (interior mutability, like Rust's `RefCell`), but
a reader has to learn it.

### What a reader can tell at a glance

Take one Rig line: `!stock.take(name, n)!`. A reader can tell that
`stock` is mutated, that the call can fail, and that the failure goes
up. Rust's `stock.take(name, n)?` shows only the failure. Zig's
`try stock.take(name, n)` shows the failure, and shows that the call
does not allocate (no `gpa`).

`archive(<log)` says the callee now owns `log`. Rust's `archive(log)`
might move or copy, depending on a trait the reader cannot see.

Two things Rig does not show:
- whether a call allocates (Zig does);
- which errors a call can fail with (Rust and Zig both do).

### Where Rig is clearer

1. **No lifetime syntax.** `fun pick(a: ?Wrap, b: ?Wrap, first: Bool) -> ?Wrap`
   and `struct View` / `box: ?Wrap` need no `<'a>`. The checker tracks
   where each borrow came from and still rejects misuse. I tested:
   returning a borrow of a local, pushing to a Vec while a returned
   element borrow lives, reassigning an optional box while `if ?root as n`
   borrows it, and mutating a Vec through a captured `|!v|` closure
   during `for x in ?v`. Each error names both places, as Rust's do.
2. **Mutation is visible at every call.** Rust's biggest readability
   hole is auto-`&mut self`; Rig closes it.
3. **Rc/Weak/RefCell code shrinks by about half** and reads as intent.
   `Cell` never lends a borrow, so there is no `BorrowMutError` panic
   at runtime. The price is the swap-out/swap-in pattern in
   `memo_canary.rig`.
4. **Closure captures state how each one is held**: `|+count, ~sig, !out, k|`.
   Rust's `move` is all or nothing, and Zig has no closures.
5. **A leaked cycle is reported, not silent.** A strong `*T` cycle in a
   Debug run prints ``rig: memory leak detected: 2 allocations (80 bytes)``.
   Rust leaks such a cycle without a word.
6. **Versus Zig: no allocator threading, no `deinit`, no `errdefer`
   bookkeeping.** The Zig family program shows why this matters: I wrote
   a double free on the first try.

### Where Rig is worse

1. **Strings and maps** (see program b). This is the largest gap.
2. **Errors are untyped at the boundary.** Every fallible function
   becomes `anyerror!T`, a `match` on an error needs a `_` arm, and
   errors carry no payload. Zig users lose explicit error sets; Rust
   users lose `enum` errors with data.
3. **A write-borrow cursor cannot be moved along in a loop.** Rust
   accepts this, which I compiled as `bench/cursor.rs`:
   ```rust
   fn insert(mut cur: &mut Option<Box<Node>>, key: i64) {
       while let Some(n) = cur {
           cur = if key < n.key { &mut n.left } else { &mut n.right };
       }
       *cur = Some(Box::new(Node { key, left: None, right: None }));
   }
   ```
   In Rig, `cur = !n.left` writes *through* `cur` instead of
   re-pointing it. `new cur = ...` re-points it, but only inside the
   loop body. So iterative insertion has to be recursive. The
   read-borrow cursor (`cur = ?n.left`) works.
4. **A handle does not lend its value.** `peek(?h)` with `h: *U` and
   `peek(u: ?U)` is rejected with ``expected `?U`, got `?*U` ``, and
   there is no spelling that works. Rust's `&*rc`, or its automatic
   deref, just works. Every helper must take `?*U`, or be a `?self`
   method, which does reach through.
5. **No weak handle from a borrowed handle.** `~parent` with
   `parent: ?*Node` is rejected. The workaround, `up = +parent; ~up`,
   adds a refcount increment and decrement that Rust's
   `Rc::downgrade(&parent)` does not need. That is a cost the
   language forces.
6. **No traits and no iterators.** Duck-typed generics are checked per
   instance with excellent errors, but a Rust user misses `impl Trait`,
   `Iterator` chains (`split().filter().enumerate()`), and `Display`.
   `for` never calls user methods.
7. **Reading an optional weak handle takes a detour.**
   `a1.parent.upgrade()` is rejected, and so is `?.` outside a function
   returning an optional. I wrote a `has_parent` helper around
   `if ?n.parent as w`.

### Error messages I hit while writing the Rig versions

| # | Message (verbatim) | Helped? |
|---|---|---|
| 1 | ``bare use of `Box` value `self.left` in binding would copy the box's pointer; a field cannot be moved out of its parent. Borrow it instead: `?self.left` or `!self.left` `` | **Yes**: named the fix. The rule is noisy, though: the receiver is already `?self`, and `if ?self.left as l` repeats it. |
| 2 | ``write `!stock.take(...)`: the call writes `stock` `` | **Yes**: clear and short. It was surprising, because `stock` is already a `!Stock` parameter. |
| 3 | ``type mismatch: expected `Box[Node]?`, got `!Box[Node]?`; only a number, `Bool`, `String`, or plain enum is copied out of a borrow: take the borrow where it goes (`?Box[Node]?` or `!Box[Node]?`)`` | **No**: misleading. The real issue is that assigning to a write-borrow local writes through it. The message should say that, and say whether re-pointing is possible. |
| 4 | ``bare use of write borrow `root` in binding would duplicate a unique borrow; use `<root` to move it`` | **Yes**. |
| 5 | ``` `cur` is assigned but never read; use it, or discard the value with `_ = ...` ``` (after `new cur = ...` in a loop) | Accurate, but it does not explain that `new` is scoped to the loop body. |
| 6 | ``` `~` weak reference requires a shared handle `*T`; got `?*Node` ``` | Partly. It is accurate but offers no workaround, and the restriction itself looks unnecessary. |
| 7 | ``cannot call `upgrade` on optional `~Node?`; take the value out first with `x ?? fallback` `` | Partly. There is no sensible fallback weak handle; `if ?x as w` is the real fix. |
| 8 | ``unexpected `?`; a function type takes no suffix; write `(*sub())?` `` | **Yes**. |
| 9 | ``type mismatch: expected `?U`, got `?*U` `` | **No**: no hint, and no spelling exists. |
| 10 | ``` `biggest[P]` cannot use `T = P`: the generic body applies `>` to `T`, which `P` does not support ``` plus a note at the `>` | **Excellent**: better than Zig's template error and as good as a Rust bound error. |
| 11 | ``cannot call write-receiver method `dep` through a shared handle (`*T`); other handles may exist. Use an interior-mutable `Cell[T]` for mutation through shared ownership.`` | **Excellent**. |
| 12 | ``use of `r` after move`` + ``note: `r` was moved here, in a previous iteration of the loop`` | **Excellent**, Rust-grade. |
| 13 | Runtime: `panic: integer overflow` / `index out of bounds`, with a trace into `__rig_main.zig:12:11` | Works, but the trace points at emitted Zig lines, not `.rig` lines. The roadmap lists this. |

Overall the diagnostics are unusually good for a young language. Two
real misses (#3 and #9) sit exactly where the borrow model is hardest.

### `bin/rig emit`: is it what a Zig programmer would write, and is the cost model honest?

The emitted Zig is **readable and structurally honest**. Structs stay
structs, methods stay methods, `f()!` becomes `try`, `catch |e|`
becomes `catch |e| switch`, and a loop stays a loop. From `stock.emit.zig`:

```zig
pub fn take(self: *Stock, name: []const u8, qty: i64) anyerror!i64 {
    const i: i64 = (self.find(name) orelse { return StockError.unknown; });
    if (self.items.at(i).qty < qty) {
        return StockError.short;
    }
    self.items.slot(i).*.qty -= qty;
    ...
```

A Zig programmer would recognize it. They would not have written it
this way, for these reasons:

- **`anyerror` everywhere**, instead of `StockError!i64`.
- **`i64` indexes** with `rig.len(x.len)` and `@intCast` at every
  length and index, instead of `usize`.
- **Alive flags on owning locals.** `var __rig_alive_out = true; defer if (__rig_alive_out) ...`
  appears even when the value is only moved at `return`. The roadmap
  lists removing this.
- **`@constCast(&self.hits).set(..)`** for a `Cell` reached through
  `*const`. It is sound, because every Cell the emitter produces lives
  in a `var` or on the heap. A Zig reviewer would still flag it on
  sight.
- **Closure parameters (`?sub(Int)`) become `rig.FnRef`**: a context
  pointer and an indirect call. This is `&mut dyn FnMut`, not Rust's
  monomorphized `impl FnMut` or Zig's `anytype` context plus
  `comptime fn`. It is cheap, but it is a real, unmarked indirect call.
- **Optional box unwrapping** is spelled
  `if ((&self.left).*) |*__rig_opt_1| { const l = __rig_opt_1; l.value.insert(key); }`.
  It is correct, just verbose.

**What the source does not show (the cost model):**

1. **Allocation.** `Vec`, `Box` and `*T` allocate, and the type says
   so. But `!v.push(x)` may reallocate with no mark, through a global
   allocator: `smp_allocator` in release builds, a leak checker in
   Debug. **Out of memory panics.** There is no way to handle it, pick
   an arena, or pass an allocator. For a Zig user this is the biggest
   change.
2. **Refcount traffic.** It is mostly visible as `+`, but
   `w.upgrade() != none` does an increment and decrement (the
   `rig.isNone` discard). Reassigning `cur = <up` drops the old handle.
   Both are reasonable, and Rust does the same.
3. **Deep `==`.** `==` compares Strings by content and structs field by
   field through `rig.eql`. Rust does this too; Zig would make you
   write `std.mem.eql`.
4. **Stdout buffering** by a process-wide writer.

Speed matched Rust in my test. Inserting 1,000,000 LCG keys into the
BST and summing them in order (`bench/`) took **0.36 s** for Rig
`--release` (ReleaseSafe, bounds and overflow checks on) and **0.30 s**
for Rust `-O`. A fresh Debug `rig run` compile takes about 1 s; a
cached one about 0.05 s.

---

## 3. Verdicts

### As a Rust programmer

**Would I switch for some projects? Yes, for a narrow band.** That band
is single-threaded tools and simulations, interpreters, and tree or
graph code heavy on `Rc<RefCell<..>>`, where a reviewer's ability to
read ownership matters more than libraries. I would not switch for
anything that needs threads, async, crates, text processing, or
hashing.

**What Rig does better than Rust:**
- **Lifetimes.** You never write one. Borrow-returning functions and
  borrowing structs just work, and the checker still caught every
  misuse I tried.
- **Borrow-checker ergonomics.** They are mixed. The shared case is
  much better (`*`, `~`, `+`, a `Cell` that never panics at runtime).
  The exclusive case is slightly worse: the loop cursor, the missing
  `?*T` to `?T` lending, and `~` of a borrowed handle.
- **Readability.** Clearly better. Every move, write, clone and drop
  is on the line, including mutating method calls, which Rust hides.

**What I miss:** traits and `impl Trait`; iterator chains; an owned
`String` and `format!`; `HashMap`; typed error enums with payloads and
exhaustive `match`; deref coercion; crates; `Send`/`Sync` and threads.

**Safety holes:** none found. My probes tried:
- use after move, including in loops;
- a conditional move, which drops correctly;
- iterator invalidation;
- a stale element borrow across `push`;
- reassigning a slot while it is borrowed;
- a borrow returned from a function;
- a closure that captured a write borrow;
- a write through a `*T`;
- `upgrade()` during drop, which correctly returns `none`;
- a drop body that re-enters its own `Cell[Vec]`, which is memory-safe
  and leaks only through the documented strong-cycle case;
- overflow and out-of-bounds, which panic in Debug and ReleaseSafe.

The `rig run` default reports leaks, which is stronger than Rust. One
caveat: `--release=fast` turns off Zig's overflow and bounds checks,
the same trade Rust makes with `unsafe`.

### As a Zig programmer

**Is Rig a nicer front end to Zig? For application code, yes.** It
gives you:
- no `gpa` threading;
- no `deinit`, `destroy`, `defer` or `errdefer` bookkeeping;
- no double free or dangling back-pointer;
- drop glue generated for you;
- a leak check by default;
- readable output Zig you can audit.

The family program shows it most: 35 safe lines against 49 lines
that I got wrong on the first draft.

**What you lose:**
- **Allocator control.** There is one global allocator, OOM panics,
  and no arenas, fixed buffers, or per-container allocators. This is
  the opposite of Zig's central idea.
- **Explicit error sets.** Everything is `anyerror`, with no
  exhaustive `switch`.
- **Most of comptime.** Rig has type parameters, and compile-time
  integer, Bool, String and enum values. It has no comptime code, no
  `@typeInfo` reflection, no `inline for`, and no comptime-computed
  sizes. The roadmap plans some of this.
- **Interop.** No Zig std access (inline Zig is reserved, and only
  `.rig` modules can be imported). C FFI carries only integers,
  floats and `Bool`, with no pointers or slices.
- **`usize` everywhere.** Indexes are `Int` (`i64`) and cast at every
  use.

**What is hidden that Zig would make explicit:** allocation at
`push`/`Box`/`*` (by type, not by call), OOM, indirect calls through
closure parameters, alive-flag bookkeeping, deep `==`, and stdout
buffering.

### Overall: better than Rust or Zig in its niche?

**Rig clears the bar on two of its four claims and falls short on
two.**

- **Readable: yes, clearly better than both.** It needs the fewest
  lines and the least punctuation in three of four programs, and it is
  the only one of the three where every ownership effect is on the
  line.
- **Safe: yes, as far as I could probe.** It is Rust-level safety
  without lifetime syntax, and it reports leaked cycles, which Rust
  does not.
- **Fast: close to Rust.** It runs within about 20% of Rust on the
  BST test, with safety checks on. A Zig user will notice the cost
  model is less explicit (allocation, OOM, `FnRef`), not slower.
- **Simple: not yet.** The rules at the edges are subtle, and
  newcomers will hit them within an hour:
  - `?self.left` inside a `?self` method;
  - `!stock.take` on a parameter that is already `!Stock`;
  - assigning to a `!T` local writes through it, while `new` re-points it;
  - a `Cell` mutates without `!`;
  - `?*U` is not a `?U`;
  - `~` needs an owned handle.

  More important, Rig is not yet a language you can write ordinary
  programs in: program (b) is the evidence. Without strings, maps and
  typed errors, "better than Rust or Zig" holds for ownership-heavy
  core code only, not for whole programs.

---

## 4. What Rig must fix or add before building its standard library (ranked)

1. **Owned text and string building.** This means `Text` (already
   decided in the roadmap), formatting, `[]U8` to `String` with UTF-8
   validation, and `print` of `[]U8`. Every stdlib module (I/O,
   parsing, maps with string keys, errors with messages) depends on
   it, and program (b) could not lowercase a word.
2. **Typed failures.** Let a function's signature name or infer its
   error set, make `match` on errors exhaustive, and consider payloads.
   This must come before the stdlib, because every stdlib signature
   will carry it and changing it later breaks them all.
3. **An allocation story.** At minimum, fallible allocation (`T!` on
   out-of-memory) for APIs that want it, plus a scoped way to choose an
   allocator (an arena for a region). Collections designed around
   "global allocator, OOM panics" are hard to retrofit.
4. **Close the borrow gaps found here**, since stdlib code will hit all
   of them constantly:
   - lend a `*T`'s value as `?T` (deref);
   - allow `~h` of a borrowed handle `?*T`;
   - a write-borrow cursor that can be moved along in a loop;
   - fix the misleading "copied out of a borrow" message (#3) and the
     hint-less `?*U` message (#9).
5. **A dispatch and interface mechanism.** Traits or bounds with
   visible dispatch, or at least a settled duck-typed protocol for
   `hash`, `eq`, `order`, `next` and `show`. `Map[K, V]`, `sort` and
   iterators need it to be written once and checked at the signature,
   not at each instance deep inside the stdlib.
6. **Raw pointers and a wider FFI** (slices, pointers, structs across
   C), and `drop` on generic types. Stdlib I/O has to call the OS, and
   a generic container that owns raw memory needs a destructor. Today
   `drop` is only for non-generic structs.
7. **Tighter emitted code.** Use `usize` indexes where safe, drop the
   alive flags where a value is moved only at return, avoid
   `@constCast`, and emit named error sets once (2) lands. This makes
   `rig emit` something a Zig reviewer accepts without comment.
8. **Source-mapped panics and traces** (`.rig:line:col` instead of
   `__rig_main.zig`), so stdlib bugs are debuggable in Rig terms.
9. **Concurrency** (thread-safe handles and structured tasks). It is
   last only because it can land after a single-threaded stdlib. It is
   the largest remaining reason a Rust user would not switch.
