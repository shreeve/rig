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

Shared strong ownership.

Intended to lower to library/runtime-managed shared ownership.

---

## Weak Reference

```rig
weak = ~shared
```

Weak shared reference.

---

## Pin

```rig
pinned = @user
```

Value may no longer move while pinned.

---

## Unsafe / Raw

```rig
ptr = %buffer.ptr
```

Escape hatch from ownership guarantees.

`%` intentionally looks visually dangerous.

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
user = loadUser(id)?
```

Binds if new.

Assigns if existing.

---

## Fixed Binding

```rig
user =! loadUser(id)?
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

Rig uses suffix `?` for propagation.

## Propagation

```rig
user = loadUser(id)?
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

The `?` form is intentionally reserved for propagation only.

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
expr?              propagate failure
expr catch |err|   recover locally
```

This keeps `?` lightweight and visually obvious.

---

## Multi-Line Fallible Blocks

Rig supports value-producing `try/catch` blocks.

```rig
view = try
  user = loadUser(id)?
  profile = loadProfile(user.id)?
  UserView(?user, ?profile)
catch |err|
  log.warn "failed to build view: {err}"
  UserView.empty()
```

Meaning:

```text
run the block
any expression marked with ? may propagate into catch
try yields the final successful expression
catch yields the fallback expression
```

This preserves:

- explicit failure propagation
- visible control flow
- typed errors
- no hidden exceptions

while still providing ergonomic block recovery.

Only expressions marked with `?` may escape to `catch`.

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
distinct role:

```text
   ?x   prefix on expression  read borrow
   !x   prefix on expression  write borrow
   ?T   prefix on type        read-borrowed parameter / return
   !T   prefix on type        write-borrowed parameter / return
   T?   suffix on type        optional T (T or null)
   T!   suffix on type        fallible T (T or error)
   x?   suffix on expression  propagate failure
```

So:
- **Prefix `?` / `!`** = borrow (in either expression or type position).
- **Suffix `?` / `!`** = type modifier (optional / fallible).
- **Suffix `?` on expression** = propagate.

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
  loadUser(id)?
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
user =! loadUser(id)?
user = refreshUser(id)?
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

- ownership sigils
- borrowing
- moves
- clone/drop
- binding rules
- generics
- pre/comptime
- error propagation
- iteration ownership
- Zig lowering
- ownership checking

Rig V1 may parse but lightly enforce:

- shared ownership
- weak refs
- pinning
- unsafe/raw

---

# V2/V3 Ideas

Possible future features:

- advanced shared ownership
- async model
- concurrency traits
- actor/task ownership transfer
- allocator traits
- reflection
- interfaces/traits
- advanced lifetime inference
- richer compile-time metaprogramming

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

