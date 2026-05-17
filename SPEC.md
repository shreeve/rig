# Rig — Design Master Spec (V1)

## Overview

Rig is a systems programming language that combines:

- Zig-level performance
- Rust-inspired ownership safety
- Rip/Zag-style syntax simplicity
- A Nexus S-expression compiler pipeline
- Zig as the native backend

Rig is not trying to become "Rust with prettier syntax." The core philosophy is:

> Important effects should be visible directly in the syntax.

Rig aims to make ownership, mutation, transfer, failure propagation, compile-time specialization, and iteration semantics explicit and lightweight.

Rig compiles to Zig.

Rig itself performs:

- parsing
- semantic normalization
- type analysis
- ownership analysis
- borrow checking
- lowering to Zig

Zig then performs:

- optimization
- code generation
- register allocation
- linking
- ABI/platform handling

---

# Compiler Pipeline

```text
Rig source
→ Nexus parser
→ raw S-expressions
→ normalized semantic S-expressions
→ type analysis
→ ownership checker
→ Zig generation
→ Zig compiler
→ machine code
```

Rig does NOT need to implement:

- LLVM backend
- register allocator
- object format generation
- linker
- optimizer backend

Rig leverages Zig for those responsibilities.

---

# Language Philosophy

Rig intentionally favors:

- explicit ownership
- lightweight syntax
- visible effects
- minimal ceremony
- ownership-aware APIs
- compile-time specialization
- strong local readability

Rig intentionally avoids:

- giant trait systems
- complex lifetime syntax
- excessive keywords
- hidden ownership transfer
- implicit mutation
- macro-heavy programming models

Rig should feel:

- simpler than Rust
- safer than Zig
- more explicit than Ruby
- cleaner than C++

---

# Core Ownership Algebra

Rig ownership is represented through sigils.

## Ownership Sigils

```text
<x       move ownership
?x       read borrow
!x       write borrow
+x       clone/copy
-x       drop/end ownership
*x       shared strong ownership
~x       weak reference
@x       pinned/stable address
%x       unsafe/raw access
```

These operators are intentionally:

- unary
- local
- visually distinct
- emotionally intuitive
- attached directly to values

The ownership model is the core of Rig.

---

# Ownership Semantics

## Move

```rig
send <packet
```

Ownership transfers into `send`.

`packet` becomes invalid afterward.

```rig
other <- packet
```

is sugar for:

```rig
other = <packet
```

Ownership visually flows leftward.

---

## Read Borrow

```rig
print ?user
```

Read-only borrow.

Many read borrows may coexist.

Read borrows prohibit:

- moves
- writes
- drops

while active.

---

## Write Borrow

```rig
rename !user
```

Exclusive mutable access.

While write-borrowed:

- no reads
- no writes
- no moves
- no drops

may occur.

---

## Clone

```rig
backup = +user
```

Creates a new owned value.

Original remains valid.

---

## Drop

```rig
-user
```

Ends ownership immediately.

Drop is statement-only.

This is NOT valid:

```rig
y = -x
```

because that remains numeric negation.

---

## Shared Ownership

```rig
shared = *user
```

Single-threaded reference-counted shared ownership. V1 semantics:

- `*expr` allocates a new `RcBox(T)` and **moves** `expr` into it
  (per the M20d design pass: implicit clone would silently
  duplicate ownership; users wanting to keep the original write
  `*(+expr)` to clone-then-share).
- `+rc` increments the strong count (`cloneStrong`); the original
  handle stays valid alongside the new one.
- `-rc` decrements the strong count (`dropStrong`); when the count
  reaches zero, the value's slot is released. **V1 does NOT yet run
  a user-defined destructor on the inner T** (no user `Drop` infra
  yet; see M20+ roadmap).
- NOT `Send`, NOT `Sync` (no atomics — single-threaded V1).
- Cycles leak by default; document loudly and lint where possible.

This is exactly `Rc<T>`. Multi-threaded shared ownership (`Arc<T>`,
`Send` / `Sync` marker, atomic refcounting) is deferred to V2.

### V1 Drop Discipline (automatic, with explicit early-drop)

**V1 has automatic scope-exit drop for `*T` / `~T` handles.** A
binding of resource type that is not explicitly discharged is
dropped at the end of its enclosing scope. Explicit `-rc` / `-w`
still work and act as **early drop** — the handle is released at
the explicit point, and the scope-exit auto-drop is a runtime no-
op for that binding.

Discharge markers that suppress auto-drop:

- `-x` — explicit drop. Runs the runtime drop call at the explicit
  point.
- `<x` — move out (move-as-argument, move-as-assignment, etc.).
  Transfers the handle to the receiver; the original binding's
  auto-drop is suppressed.
- `return x` (bare) — consuming move-out via the function's return
  channel. Same suppression as `<x`.
- Reassignment `x = <new>` — drops the previous handle, re-arms
  the auto-drop for the new one. Exactly one drop per allocation.

Non-discharging (binding stays live, auto-drop applies):

- `+x` (clone) — original stays valid; both the original and the
  cloned handle auto-drop independently at scope exit.
- `~rc` (weak ref) — the shared original stays live; the new weak
  handle gets its own auto-drop.
- `w.upgrade()` — returns a fresh `(*T)?` but does not consume w.
- Field access (`rc.field`) and method calls (`rc.method()`) via
  M20d read-only auto-deref — these are non-consuming reads.

Implementation (per the M20e design pass with GPT-5.5): every
resource binding emits a Zig `defer` guarded by a runtime alive
flag. Explicit discharges disarm the flag before the defer fires.
Zig's defer behavior gives Rig path-sensitive cleanup across
branches, early returns, break / continue, try / catch (when
try-block emit lands), and labeled-block recipes — without any
Rig-side static drop-elaboration analysis.

V1 panic / unreachable: Zig defers run on `return` and on normal
scope exit; they do NOT run on `@panic` / `unreachable`. Programs
that panic with live resource handles leak those handles (the
process is dying anyway). Document for clarity, not for change.

### Interior mutability via `Cell(T)` (M20f)

The M20d rules reject write-receiver and consume-receiver methods
through `*T` — shared ownership cannot grant unique mutable access.
The user-facing escape hatch is `Cell(T)`, a built-in interior-
mutability container:

```rig
rc: *Cell(Int) = *Cell(value: 0)
rc.set(5)
print(rc.get())            # 5
```

`Cell(T)` is a built-in generic nominal (registered alongside
primitives at sema init; runtime implementation lives in
`_rig_runtime.zig`). It provides:

- `get(self: ?Cell(T)) -> T` — returns the current value by copy
- `set(self: ?Cell(T), value: T)` — interior mutation; trusted
  runtime implementation does the actual write
- `value: T` — synthetic data field for the constructor sugar
  `Cell(value: ...)`

Both methods take `?self` (read borrow) so M20d's auto-deref
permits them through any access path (bare value, `?Cell(T)`
borrow, `*Cell(T)` shared handle). The interior mutation is
guaranteed safe by Cell's contract: single-threaded V1 has no
concurrency, and Cell's only methods are the trusted runtime
ones.

**V1 restriction: `T` must be a Copy type.** Allowed: `Int`,
`Bool`, `Float`, `String`, the literal pseudo-types. Rejected:
nominal structs, resource handles (`*U` / `~U`), slices,
generic instantiations of non-Copy types. Non-Copy `Cell(T)`
would let `Cell.set` corrupt ownership (overwriting a `*User`
without dropping the previous handle, etc.); deferred until V1
grows replace/take/Drop semantics.

```rig
c: Cell(*User) = ...     # error: Cell(T) in V1 requires Copy T
```

### Resource temporaries (named-binding RAII boundary)

**V1 auto-drop applies to named bindings and parameters.** Unbound
`*expr` temporaries — for example `consume(*User(name: "a"))` or
`(*User(name: "a")).field` — are NOT automatically dropped by
M20e. They are only safe in positions where the receiving context
takes ownership of the handle:

- ✅ `consume(*User(...))` where `consume` has a `*User`
  parameter (the callee owns it; its own M20e guard drops it).
- ⚠️ `(*User(...)).field` — read access on an unbound temporary
  leaks the allocation.
- ⚠️ `*User(...)` as a bare expression-statement — leaks.

For V1, bind the result to a name and let M20e auto-drop handle
it:

```rig
rc = *User(name: "a")
print(rc.field)
# rc auto-drops at scope exit
```

A future ergonomics milestone may either reject leak-shaped
temporaries with a clear diagnostic or lower them to hidden
guarded bindings; for V1 the binding-only boundary is the
contract.

### Alias Discipline (M20d, enforced now)

Bare `*T` / `~T` handles cannot be reused without making the
ownership effect visible. Specifically:

```rig
rc = *User(...)
rc2 = rc              # error: bare alias; use `<rc` (move) or `+rc` (clone)
takes_rc(rc)          # error: bare alias; use `<rc` (move into callee)
```

The fix matches Rig's `?x` / `!x` / `<x` / `+x` algebra: the
ownership effect appears at the call site. Move (`<rc`) transfers
the handle without bumping the count; clone (`+rc`) bumps the strong
count and produces a fresh handle.

Read-only access through a shared handle is unrestricted:

```rig
print(rc.field)       # OK — read-only auto-deref
print(rc.read_method()) # OK — method declared with `self: ?T`
```

Write or consume through shared is rejected (other handles may
exist; we can't hand out unique mutable access):

```rig
rc.write_method()     # error: write-receiver method through `*T`
rc.consume()          # error: consume through `*T`
rc.field = X          # error: field-target assign through `*T`
```

The user-facing escape hatch for controlled mutation through shared
ownership is interior mutability (`Cell(T)` / `RefCell(T)`, planned
as M20+ item #7).

### Type-position precedence: `*T?` vs `(*T)?`

Prefix `*` and `~` bind LOOSER than suffix `?` and `!` (consistent
with `?T?` parsing as `(borrow_read (optional T))`):

```text
*User?     parses as  shared(optional(User))   # "shared handle to optional User"
(*User)?   parses as  optional(shared(User))   # "optional shared handle"
~User?     parses as  weak(optional(User))
(~User)?   parses as  optional(weak(User))
```

`WeakHandle.upgrade()` returns `(*T)?` (optional shared handle) —
the spelling requires parens because the suffix would otherwise bind
inside the prefix.

### Drop Order

When the last `*T` strong handle is dropped, the value's destructor
**will run** synchronously before the `*T` handle itself is gone
(see the V1 caveat above — V1 currently has no user-defined
destructors; the synchronous-run-before-handle-loss guarantee is the
contract once user `Drop` lands). Any `~T` weak handles to the same
value upgrade to `none` after this point. Destructors during a
callback dispatch (reactive flush, observer notify, etc.) are
allowed; re-entrant destruction is the calling library's policy to
handle.

---

## Weak Reference

```rig
weak = ~shared
```

Single-threaded weak handle paired with `*T`. V1 semantics:

- does NOT keep `T` alive
- after the last `*T` is dropped, all `~T.upgrade()` calls return
  `none`

Exactly `Weak<T>`. Required for cycle-free shared-graph structures
(GUI parent/child, observer subscriber lists, reactive subscriber
back-edges, ECS handles, graph data structures, compiler
self-referential types).

### Built-in method: `upgrade() -> (*T)?`

Every weak handle (`~T`) supports the built-in method:

```rig
w.upgrade()    # returns (*T)?
```

`upgrade` is a **built-in method on `~T`**, not a sigil and not a
user-overridable function. Semantically:

- Returns `(*T)?` — an optional shared handle. The optional carries
  the failure mode: weak references exist precisely because the
  referent may have been dropped, and `upgrade` reports that
  honestly rather than panicking.
  - Note the type spelling: `(*T)?` is `optional(shared(T))`
    ("optional shared handle"). The prefix-suffix precedence rules
    (see §Shared Ownership) mean `*T?` parses as
    `shared(optional(T))` instead — a different type.
- Takes no arguments. `w.upgrade(arg)` is a sema error.
- Only available on weak handles. `rc.upgrade()` where `rc: *T` is
  a sema error with a targeted suggestion (use `~rc` first), UNLESS
  the underlying type `T` defines its own `.upgrade()` method, in
  which case auto-deref through shared dispatches to the user's
  method.
- Built-in `upgrade` on `~T` takes precedence over any user-defined
  `.upgrade()` only when the receiver is actually weak. Users
  cannot override the built-in via a method on `T`.

Why a method and not a sigil: every other Rig ownership sigil
(`<`, `?`, `!`, `+`, `-`, `*`, `~`, `@`, `%`) is total within its
domain — it succeeds in normal control flow and only fails on
sema-detectable errors or environmental conditions (OOM). `upgrade`
is fundamentally fallible (the referent may be gone), so spelling
it as a method makes the failure mode visible at the call site and
keeps the sigil family's "sigil = total transformation" invariant
intact. A future sugar candidate (`^w` for upgrade) was considered
during M20d.2 design and deferred — see HANDOFF / ROADMAP for the
discussion. The method form is the V1 commitment.

**Constraint.** `*T` and `~T` are an "all or nothing" V1
commitment. Shipping them as parsed-but-fake is more dangerous than
not shipping them — fake handles create false-promise APIs that
calcify. Either both have real semantics in V1, or both are
reserved for V2. See `docs/REACTIVITY-DESIGN.md` for the design
discussion.

---

## Pin

```rig
pinned = @user
```

**Deferred to V2.** Pinning is a `Pin<P>` discipline, not a sigil;
the substrate cost (pin projection, `Unpin` taxonomy,
move-while-pinned errors) is too high for V1's benefit. V1 use
cases (self-referential structs, subscribe-in-init callbacks) are
workable via `alloc.create` returning a `*Self` with a stable heap
address.

The `@x` sigil parses but is not enforced in V1; use it sparingly
until V2 lands the real discipline. (`@` also prefixes Zig builtin
calls — `@sizeOf(T)` etc. — which is a separate, unrelated use of
the symbol.)

---

## Unsafe / Raw

```rig
unsafe
  ptr = %buffer.ptr
```

Escape hatch from ownership guarantees. `%` intentionally looks
visually dangerous, but the sigil alone is not enough — `%x`,
`zig "..."`, and dangerous `@builtin(...)` calls require an
**unsafe context**: either an `unsafe` block, or a function
declared with the `unsafe` modifier.

```rig
sub raw_op() unsafe
  ptr = %buffer.ptr
  do_something_with(ptr)
```

Safe Rig calling unsafe Rig requires the call to be inside an
`unsafe` block, or for the callee to wrap the unsafe operation in
a safe Rig contract (the standard Rust bargain).

**Builtin classification.** Not all `@builtin(...)` calls are
unsafe. Pure compile-time / type operations (`@sizeOf`,
`@alignOf`, `@typeName`, etc.) are safe; pointer manipulation
(`@ptrCast`, `@intFromPtr`, `@ptrFromInt`, `@memcpy`, etc.) is
unsafe. The whitelist lives in the effects / types checker.

**Safety bargain.** Rig's safety guarantee applies to safe Rig
code and to calls whose contracts are known to the Rig checker.
Raw Zig, raw pointers, unchecked builtins, and unsafe externs are
outside the guarantee and require explicit unsafe context. Safe
APIs may wrap unsafe implementations only by declaring and
upholding Rig-visible ownership / effect contracts.

---

# Binding Model

Rig intentionally removes:

- const
- var
- let
- :=

Core binding operators:

```text
=      bind/assign
=!     fixed binding
new    explicit shadow
<-     move assignment
```

## Binding

```rig
user = loadUser(id)!
```

Binds if new.

Assigns if existing.

---

## Fixed Binding

```rig
user =! loadUser(id)!
```

Creates an immutable/fixed binding.

Reassignment becomes illegal.

Equivalent Zig lowering:

```zig
const user = try loadUser(id);
```

---

## Explicit Shadowing

```rig
new user = User(name: "guest")
```

Implicit shadowing is illegal.

Rig requires shadowing to be explicit.

---

## Move Assignment

```rig
other <- user
```

Equivalent to:

```rig
other = <user
```

---

# Function Syntax

## Functions

```rig
fun add(a: Int, b: Int) -> Int
  a + b
```

Functions return values.

---

## Procedures

```rig
sub main()
  print "hello"
```

Procedures return nothing.

---

## Methods and `self` Receivers

A `fun` or `sub` declared inside a `struct`, `enum`, or `errors`
body is a method. If its first parameter is named `self`, it's an
instance method (callable as `value.method(args)`); otherwise it's
an associated/static method (callable as `Type.method(args)`).

The receiver type uses the same `?T` / `!T` borrow-prefix rules as
any other parameter:

```rig
struct User
  name: String

  fun greet(self: ?User) -> String       # read-borrowed self
    self.name

  sub modify(self: !User, n: String)     # write-borrowed self
    self.name = n

  sub consume(self: User)                # by-value (consuming) self
    print(self.name)
```

`Self` is a type alias for the enclosing nominal, usable in
method signatures (and constructors):

```rig
struct User
  name: String

  fun make(default: String) -> Self
    User(name: default)
```

### Sigil-on-name Sugar for `self`

For the very common borrow-receiver case, Rig accepts a sigil-on-
name shorthand at parameter position — **only when the name is
literally `self`**:

```rig
fun greet(?self) -> String       # sugar for `self: ?Self`
sub modify(!self, n: String)     # sugar for `self: !Self`
sub consume(self: Self)          # by-value uses the long form
```

The sugar lowers to the canonical `self: ?Self` / `self: !Self`
form during sema; the IR shape, emit output, and ownership rules
are identical to the explicit form. Both spellings are valid; the
sugar exists purely as an ergonomic shortcut for the common case.

This is the **only** position where a sigil-prefix may attach to a
parameter name. Writing `?xs` or `!other` is a sema error
("sigil-prefixed parameter is only allowed for `self`; for other
parameters use `xs: ?Type`"). The rule defends against the
foot-gun where users might assume `?name` is a general "borrowed
parameter" form — borrow-ness belongs on the type, per the
`?` / `!` triangle.

The sugar is also rejected outside a nominal body (since `Self`
has no enclosing type to resolve to).

---

## Lambdas

A `fn` expression is a lambda — an anonymous function value bound
to a local, then invoked via call-receiver syntax:

```rig
sub main()
  n =! 7
  add = fn |n|
    n * 2
  print(add())            # 14
```

The body is an indented block (or a single expression). The
lambda has no name; its `fn` keyword stands alone (contrast `fun
name(...)`).

V1 lambdas are **non-escaping by default**: a bare closure
value (`f = fn |...| body`) may appear ONLY as a `(set ...)`
RHS or as the callee of a `(call ...)` form. Returns, call
arguments, struct/enum field values, and any other position
are rejected by the ownership checker. Closure values are also
**non-copyable** — `g = f` is rejected, and the closure binding
is implicitly fixed so reassignment is disallowed too. The
combined effect: a stack-local closure stays anchored to its
original binding and is invoked there.

For **escaping callbacks** — closures stored past their defining
scope, returned from a function, retained in a subscriber list,
etc. — Rig provides the **owned-closure handle** `*Closure()`
described in §Owned Closures (M20h) below. The escape is opt-in
and visible at the construction site via the `*` sigil; bare
lambdas remain non-escaping.

### Capture modes

A lambda may capture exactly ONE outer name in V1, prefixed by
a mode sigil between the `fn` keyword and the params:

```rig
fn |x|   body            # cap_copy  — Copy-only; rejects *T / ~T
fn |+x|  body            # cap_clone — refcount-bump for shared/weak
fn |~x|  body            # cap_weak  — requires *T; captures ~T
fn |<x|  body            # cap_move  — transfers ownership; disarms outer
```

The mode sigils mirror the M20d ownership family (`+x` clone,
`<x` move, `~x` weak). Multi-capture (`|+rc, n|`) is a follow-up;
V1 grammar accepts a single capture node.

Per the visible-effects thesis, the default `|x|` form requires a
Copy type (`Int` / `Bool` / `Float` / `String` and the literal
pseudo-types — same set as `Cell(T)`'s V1 restriction). For
shared / weak handles, the user MUST pick a mode explicitly. A
bare `|rc|` capture of a `*T` outer fires:

```text
error: bare capture `|rc|` of shared handle `*T` would hide a
       refcount bump; use `|+rc|` to clone, `|<rc|` to move, or
       `|~rc|` to capture a weak ref
```

The capture-mode validation table (enforced by sema):

| Mode      | Outer Type   | Bound Type | Effect on Outer |
|-----------|--------------|------------|-----------------|
| `|x|`     | Copy (non-resource) | same | none |
| `|+x|`    | `*T`         | `*T`       | `.cloneStrong()` at construct |
| `|+x|`    | `~T`         | `~T`       | `.cloneWeak()` at construct |
| `|+x|`    | Copy         | same       | copy (degenerate clone) |
| `|~x|`    | `*T`         | `~T`       | `.weakRef()` at construct |
| `|<x|`    | any          | same       | outer enters `.moved` state |

Other shapes are diagnostic errors (e.g., `|+x|` on a non-Copy
non-resource type, `|~x|` on a non-shared outer, etc.).

### Closure-instance lifetime (auto-drop integration)

For each RESOURCE capture, an M20e-style guard + `defer` is
installed at the CLOSURE-INSTANCE'S enclosing scope — NOT inside
the body (closures may be invoked multiple times; per-invocation
drop would be a use-after-free on the second invoke). The guard
keys on the closure binding's lifetime; the captured handle drops
exactly once at the closure binding's scope exit.

```rig
sub main()
  rc: *Cell(Int) = *Cell(value: 0)
  read = fn |+rc|              # cloneStrong: rc strong refcount 1 → 2
    rc.get()
  print(read())                # closure body uses cloned handle
  print(read())                # multiple invocations: handle still alive
  # scope exit (LIFO):
  #   1. read's capture defer  → dropStrong on read.cap_rc (refcount 2 → 1)
  #   2. rc's binding defer    → dropStrong on rc          (refcount 1 → 0 → freed)
```

For `|<rc|` move-capture, the outer's M20e guard disarms at the
construction site via the standard move-and-yield labeled-block
recipe; the closure-instance guard takes ownership from there.

### Capture / parameter name collisions

A capture and a parameter with the same name are rejected:

```rig
f = fn |x|(x: Int)
  x
# error: lambda parameter `x` conflicts with captured variable `x`
#   note: captured here
```

Captures bind before params in the lambda body scope, so a
silent shadowing would surprise readers. The diagnostic forces a
rename of one or the other.

### Nested-lambda capture limitation

A lambda nested inside another lambda's body cannot capture a
name from the OUTER lambda's body scope in V1:

```rig
outer = fn |+rc|
  inner = fn |+rc|     # error: nested closure capture of `rc` is
    rc.get()           #        not supported in V1; lift the
  inner()              #        capture to the outer scope or
                       #        refactor
```

Emit would have to clone the outer closure's `self.cap_rc` field
into the inner closure — a layer of indirection V1 deliberately
omits. Lift the captured value to the outermost enclosing scope
and capture it directly in both lambdas, or refactor to a single
flat closure.

### Inline-invoke grammar limitation

The conceptual `(fn |...| body)()` shape — invoking an inline
lambda literal without binding it to a name — is accepted by
the ownership checker (call-receiver position is allowed) but
currently rejected by the parser due to the indented-block /
suffix-call composition. For V1, use the
`f = fn |...| body; f()` shape.

### Owned Closures (M20h)

Bare lambdas can't escape their defining scope; the
**owned-closure handle** `*Closure()` opts into escape via an
explicit constructor that allocates the closure's env on the
heap and tracks the lifetime through a refcounted handle:

```rig
sub main()
  count: *Cell(Int) = *Cell(value: 0)
  cb: *Closure() = *Closure(fn |+count| count.set(count.get() + 1))
  cb()
  cb()
  print(count.get())                # 2
```

The construction shape is fixed: `*Closure(fn |...| body)` —
exactly one argument, which MUST be a lambda. Bare `Closure(fn
...)` (no `*`), `*Closure(42)` (non-lambda), `*Closure()` (no
arg), and `*Closure(fn ..., fn ...)` (multiple args) all
produce tailored sema diagnostics.

`*Closure()` is itself an ordinary `*T` shared handle:

```rig
fun make_counter() -> *Closure()
  count: *Cell(Int) = *Cell(value: 0)
  *Closure(fn |+count| count.set(count.get() + 1))

sub main()
  cb = make_counter()       # returned, alive past defining scope
  cb2 = +cb                 # clone — refcount 1 → 2
  -cb                       # drop  — refcount 2 → 1
  cb2()                     # cb's gone, cb2's env still alive
```

Invocation is via the natural `cb()` syntax (sema rejects
`cb(args)` — M20h closures are no-arg / void-return only). The
emitter lowers `cb()` to `cb.value.invoke()` (a Closure0 vtable
jump). Auto-drop at scope exit cascades through
`RcBox.dropStrong` → `Closure0.__rig_drop` → a per-literal
drop thunk that releases each captured resource and frees the
heap-allocated env.

**ABI: type erasure via Closure0.** Each `*Closure(fn ...)`
literal generates a unique anonymous env struct holding its
captures plus an `invoke`/`drop` thunk pair tailored to that
layout. The env pointer is type-erased through `ctx: *anyopaque`
so every `*Closure()` literal produces the SAME surface type
(`*rig.RcBox(rig.Closure0)`). Returning, storing, aliasing,
and weak-ref-ing all flow through the existing `*T` paths
unchanged.

**Capture semantics** are inherited from M20g: `|+count|` clones,
`|<count|` moves, `|~count|` weak-references. The same mode-
validation table applies — Copy types for `|x|`, etc. Drop
happens at LAST-strong-drop of the closure handle (NOT at each
binding's scope-exit defer); the type-erasure design + the
`RcBox.__rig_drop` runtime hook are what make `cb2 = +cb; -cb;
cb2()` safe.

**V1 restrictions:**

- `*Closure()` is the only legal arity. `Closure(Int)` errors
  with "expects 0 type arguments, got 1"; bare `Closure`
  errors with "must be written with empty parentheses; write
  `Closure()`". Arity-bearing closure types (`Closure1<T>`,
  etc.) are deferred.
- The closure body returns `void`. Returning a value is
  deferred until typed `Closure()` arities ship.
- Multi-line closure bodies require pre-binding into a named
  helper (the grammar accepts inline-call bodies via a
  narrow `FN captures call` form; multi-stmt bodies need
  `INDENT/OUTDENT` which doesn't compose inside `(...)`
  parens).
- `*Closure()` doesn't replace the M20g non-escaping closures —
  use the bare `f = fn |...| body; f()` form for stack-local
  callbacks (cheaper: no heap allocation, no refcount, no
  vtable indirection). Reach for `*Closure()` only when the
  closure needs to outlive its defining scope.

---

# Function Calls

Rig allows Ruby-style omitted parentheses.

## Preferred Style

```rig
send <packet
print ?user
rename !user, "Steve"
```

---

## Parentheses Recommended For Nesting

```rig
send(encode <packet)
```

instead of:

```rig
send encode <packet
```

Rig should prefer readability over clever omission.

---

# Constructors

Rig uses:

```rig
User(name: "Steve")
```

instead of:

```rig
User.new(...)
```

or:

```rig
User{...}
```

The rule:

```text
Type(...) means “construct a value of this type.”
```

The compiler may lower to:

- struct literal
- init function
- allocator-backed initialization

based on the type.

Example:

```rig
buf = Buffer(arena, size: 4096)
```

may lower to:

```zig
const buf = try Buffer.init(arena, 4096);
```

Allocation should remain visible through arguments.

Failure should remain visible through result handling.

---

# Fallibility / Error Propagation

Rig uses suffix `!` for error propagation. The `!` family is errors;
the `?` family is optionality / null. Each spelling has exactly one
meaning — see "## The ?/! Triangle" above.

## Propagation

```rig
user = loadUser(id)!
```

Meaning:

```text
unwrap success
or propagate failure upward
```

Equivalent Zig lowering:

```zig
const user = try loadUser(id);
```

The suffix `!` form is reserved for error propagation. (Suffix `?` on
expression is reserved for future optional-propagation, e.g.,
`firstUser()?` if `firstUser` returns `User?`.)

---

## Local Error Handling

Rig uses `catch` for local recovery.

```rig
user = loadUser(id) catch |err|
  log.warn "load failed: {err}"
  User(name: "guest")
```

Meaning:

```text
evaluate expression
if failure occurs, bind failure to err and execute recovery block
```

This maps naturally to Zig:

```zig
const user = loadUser(id) catch |err| {
    ...
};
```

Rig intentionally separates:

```text
expr!              propagate failure
expr catch |err|   recover locally
```

This keeps `!` lightweight and visually obvious — and consistent with
the `T!` (fallible type) spelling: a function returning `T!` is
called with `f()!` to propagate.

---

## Multi-Line Fallible Blocks

Rig supports value-producing `try/catch` blocks.

```rig
view = try
  user = loadUser(id)!
  profile = loadProfile(user.id)!
  UserView(?user, ?profile)
catch |err|
  log.warn "failed to build view: {err}"
  UserView.empty()
```

Meaning:

```text
run the block
any expression marked with ! may propagate into catch
try yields the final successful expression
catch yields the fallback expression
```

This preserves:

- explicit failure propagation
- visible control flow
- typed errors
- no hidden exceptions

while still providing ergonomic block recovery.

Only expressions marked with `!` may escape to `catch`.

---

## Fallible Function Return

```rig
fun loadUser(id: U64) -> User!
```

Meaning:

```text
this function returns User-or-failure
```

The suffix `!` on a type makes it **fallible** (an error union).

---

## The `?` / `!` Triangle

Rig keeps the meaning of `?` and `!` clean by giving each position a
distinct role, and by giving each *family* a single domain:

```text
   ?x   prefix on expression  read borrow
   !x   prefix on expression  write borrow
   ?T   prefix on type        read-borrowed parameter / return
   !T   prefix on type        write-borrowed parameter / return
   T?   suffix on type        optional T (T or null)
   T!   suffix on type        fallible T (T or error)
   x!   suffix on expression  propagate failure
   x?   suffix on expression  RESERVED for future optional-propagation
                              (Swift-style "if null, propagate null")
```

So:
- **Prefix `?` / `!`** = borrow (in either expression or type position).
- **`?` family** = optionality / null. Suffix-on-type and (future)
  suffix-on-expression both belong to the optional/null world.
- **`!` family** = errors / failure. Suffix-on-type (`T!` fallible)
  and suffix-on-expression (`x!` propagate) both belong to the
  error-handling world.

The propagation symbol matches the type it operates on: a function
returning `User!` is called with `f()!` to propagate the error; a
function returning `User?` (someday) is called with `f()?` to
propagate the null.

The two halves never collide; each spelling has exactly one meaning.

---

# Expression-Oriented Philosophy

Rig strongly prefers expression-oriented semantics.

Most constructs naturally yield values:

```rig
x = if ok
  1
else
  2
```

```rig
x = try
  loadUser(id)!
catch |err|
  User(name: "guest")
```

Assignment is optional consumption of the resulting value.

This is also valid:

```rig
if ok
  print "yes"
else
  print "no"
```

The value is simply ignored.

Core philosophy:

```text
Most constructs are expressions.
Assignment optionally consumes their values.
```

---

# Generics

Rig supports lightweight generic types/functions.

## Generic Type

```rig
type Box(T)
  value: T
```

Equivalent Zig lowering:

```zig
pub fn Box(comptime T: type) type {
    return struct {
        value: T,
    };
}
```

---

## Generic Function

```rig
fun first(T, xs: ?[]T) -> T?
  xs[0]
```

Rig hides Zig comptime syntax for generic parameters.

Note the `?` / `!` triangle in action:
- `xs: ?[]T` — prefix `?` on type → **read-borrowed slice** of T (param)
- `-> T?`    — suffix `?` on type → **optional** T (return may be missing)

---

## Type Parameters

Type parameter names are NOT keywords.

All valid:

```rig
Box(T)
Box(Item)
Map(Key, Value)
```

---

# Compile-Time Specialization (`pre`)

Rig replaces Zig `comptime` with `pre`.

## Compile-Time Parameter

```rig
fun parse(pre mode: ParseMode, input: ?Bytes) -> Ast
  if pre mode == .strict
    parseStrict ?input
  else
    parseLoose ?input
```

Meaning:

```text
mode is known at compile time
compiler specializes the generated runtime code
unused branches disappear
```

This generates separate specialized versions.

---

## Compile-Time Block

```rig
pre
  assert(sizeOf(Header) == 32)
```

---

## Compile-Time Function

```rig
pre fun buildTable() -> Table
  ...
```

---

## Compile-Time Condition

```rig
if pre mode == .strict
```

---

# Iteration

Rig iteration carries ownership semantics.

## Read Iteration

```rig
for user in ?users
  print ?user
```

Equivalent composable form:

```rig
?users.each |user|
  print ?user
```

---

## Mutable Iteration

```rig
for user in !users
  normalize !user
```

Equivalent:

```rig
!users.each |user|
  normalize !user
```

---

## Consuming Iteration

```rig
for packet in <queue
  send <packet
```

Equivalent:

```rig
<queue.each |packet|
  send <packet
```

Meaning:

```text
queue consumed
packet ownership transferred
queue invalid afterward
```

---

# Immutability Philosophy

Rig respects Clojure’s insight that:

> uncontrolled mutation creates complexity.

Rig differs by solving this through ownership rather than GC/persistent structures.

Rig posture:

```text
reading is explicit
mutation is explicit
ownership transfer is explicit
rebinding can be fixed
```

Rig is:

- immutable-friendly
- mutation-explicit
- ownership-visible

without requiring garbage collection.

---

# Ownership Checker V1

## Value States

Each binding is:

```text
valid
moved
dropped
```

---

## Borrow Rules

### Read Borrow

```text
many allowed
blocks move/write/drop
```

### Write Borrow

```text
exclusive
blocks all other access
```

---

## Borrow Lifetime

V1 conservative rule:

```text
temporary borrows end at statement end
bound borrows live until scope exit or explicit drop
```

Example:

```rig
print ?user
rename !user
```

allowed.

But:

```rig
r = ?user
rename !user
```

is illegal while `r` exists.

---

## Borrow Escape Rule

Returned borrows must originate from borrowed parameters.

Allowed:

```rig
fun name(user: ?User) -> ?String
  ?user.name
```

Illegal:

```rig
fun bad() -> ?String
  user = User(name: "Steve")
  ?user.name
```

---

# Normalized Semantic S-Expressions

Ownership checking occurs after normalization.

Example:

```rig
send <packet
log ?packet
```

Normalizes to:

```lisp
(block
  (call send (move packet))
  (call log (read packet)))
```

Rig ownership analysis should operate on semantic S-expressions.

---

# Semantic IR Nodes

```lisp
(block ...)
(bind name expr)
(bind-fixed name expr)
(assign name expr)
(shadow name expr)

(move expr)
(read expr)
(write expr)
(clone expr)
(drop expr)

(share expr)
(weak expr)
(pin expr)
(raw expr)

(call fn args...)
(return expr)
(if cond then else)
(for mode binding collection body)
```

---

# Ownership Checker State

Per binding:

```text
name
type
state: valid | moved | dropped
fixed: bool
read_borrows
write_borrow
scope_id
```

---

# V1 Test Cases

## Use After Move

```rig
send <packet
log ?packet
```

Must error.

---

## Write While Read Borrowed

```rig
r = ?user
rename !user
```

Must error.

---

## Read While Write Borrowed

```rig
w = !user
print ?user
```

Must error.

---

## Use After Drop

```rig
-user
print ?user
```

Must error.

---

## Explicit Shadow

```rig
x = 1
new x = 2
```

Allowed.

---

## Fixed Binding Reassignment

```rig
user =! loadUser(id)!
user = refreshUser(id)!
```

Must error.

---

## Borrow Escape

```rig
fun bad() -> ?String
  user = User(name: "Steve")
  ?user.name
```

Must error.

---

# Relationship To Zig

Rig is NOT replacing Zig.

Rig provides:

- ownership analysis
- syntax simplification
- semantic normalization
- safety guarantees

Zig provides:

- performance
- optimizer
- native backend
- ABI/platform support
- comptime machinery
- mature systems ecosystem

Rig is effectively:

```text
Rust-inspired ownership semantics
over
a Zig backend
```

---

# Relationship To Rust

Rig intentionally borrows:

- ownership
- moves
- borrowing
- explicit mutation
- compile-time safety

Rig intentionally avoids (for V1):

- complex trait systems
- advanced lifetime syntax
- heavy generics machinery
- async complexity
- advanced type-level programming

Rig aims for:

```text
simpler than Rust
safer than Zig
```

---

# Relationship To Clojure

Rig respects the idea that mutation should be controlled.

Rig differs by:

- no GC
- explicit ownership
- systems-level performance

Rig can still support:

- immutable collections
- persistent structures
- structural sharing

as library/runtime features.

---

# V1 Scope

Rig V1 should fully support:

- ownership sigils (core + shared / weak)
- borrowing
- moves
- clone / drop
- binding rules
- generics
- pre / comptime
- error propagation
- iteration ownership
- Zig lowering
- ownership checking
- single-threaded reference-counted shared ownership (`*T` as `Rc<T>`)
- weak references (`~T` as `Weak<T>`) with `upgrade() -> *T?`
- unsafe context (`unsafe` block / `unsafe` fn modifier; required
  for `%x`, `zig "..."`, dangerous `@builtin(...)`)

Rig V1 may parse but does not enforce:

- pinning (`@T`) — deferred to V2 per §Pin

---

# V2/V3 Ideas

Possible future features:

- multi-threaded shared ownership (`Arc<T>`, `Send` / `Sync`,
  atomic refcounting)
- pinning (`@T`) as a real `Pin<P>` discipline
- async model
- concurrency traits
- actor / task ownership transfer
- allocator traits
- reflection
- interfaces / traits
- advanced lifetime inference
- richer compile-time metaprogramming
- scoped context syntax (akin to Scala `given` / Koka effects) for
  ambient reactor / allocator / tracing parameters
- effect annotations on methods (`mutates(self)` etc.)
- reactive sugar (`:=` / `~=` / `~>` as parser-level desugar over
  `Cell` / `Memo` / `Effect`; see `docs/REACTIVITY-DESIGN.md`)

These are intentionally deferred.

---

# Core Rig Thesis

Rig is a systems programming language with:

- Zig performance
- Rust-inspired ownership safety
- Rip/Zag syntax simplicity
- Nexus S-expression compilation
- lightweight explicit ownership algebra

Rig makes:

- ownership visible
- mutation visible
- failure visible
- compile-time specialization visible

while keeping the syntax small, direct, and expressive.

