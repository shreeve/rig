# Welcome to Rig

Rig is a systems language for people who want Python's readability,
Zig's cost model, and Rust's memory safety in one place. There is no
garbage collector, and only the few types that own memory allocate it.
Blocks are indented, types are inferred, and most lines look like
pseudocode. The compiler checks
the program, then writes [Zig](https://ziglang.org), and Zig optimizes,
generates code, and links.

This guide is for programmers arriving from another language. It shows
Rig's central idea, translates the forms you already know, and lists
the habits that will trip you up, with what the compiler says when they
do. The [journeys](docs/learn/README.md) teach the language from the
first line. [SYNTAX.md](SYNTAX.md) shows how every form is written, and
[SPEC.md](SPEC.md) says what each one means.

Every `rig` example here is compiled and run by the test suite. A
program followed by an `output` block prints exactly that, with no
leaks; a program marked as rejected fails with the errors shown.

## Contents

- [The central idea](#the-central-idea)
- [A first program](#a-first-program)
- [Running a program](#running-a-program)
- [From Rust and Zig](#from-rust-and-zig)
- [From C, Python, Ruby, JavaScript, and Go](#from-c-python-ruby-javascript-and-go)
- [Habits that trip people up](#habits-that-trip-people-up)
- [What Rig does not have](#what-rig-does-not-have)
- [Where to go next](#where-to-go-next)

## The central idea

**Sigils are the language's mechanics; words are its libraries.** How
data is bound, taken, lent, held, failed, and run at the same time is
written where it happens, as a one-character **sigil**, and a sigil
means the same thing wherever it appears:

| Mechanic | Sigils |
|---|---|
| Binding | `x = e` binds, `x =! e` binds for good |
| Taking and copying | `<x` moves (alone on a line, drops), `+x` copies or makes another handle |
| Lending | `?x` lends to read, `!x` to write; as types, `?T` and `!T` |
| Holding | `*x` shared (`*w` upgrades a weak handle), `^x` boxed, `~x` weak, `@` self |
| Failure and absence | `T?` may be absent, `T!` may fail; `e?` and `e!` pass them on |
| Concurrency | `f(x)&` sends work off, `>t` takes its result back |

What a library chooses is a word: canceling a task, `<t.cancel()`, or
waiting for the first of several, `<ts.wait_first()`.

Next to Rust and Zig:

| Sigil | Meaning | Rust | Zig |
|---|---|---|---|
| `<x` | move `x` | `x` (implicit move) | copy, then stop using `x` |
| `?x` | lend `x` to read | `&x` | `x` or `&x` |
| `!x` | lend `x` to write | `&mut x` | `&x` |
| `+x` | clone: a new owner | `x.clone()`, `Rc::clone(&x)` | copy, or a manual refcount bump |
| `^x` | move into a box with one owner | `Box::new(x)` | `allocator.create(T)` |
| `*x` | move into a shared, counted handle | `Rc::new(x)` | a hand-written refcounted box |
| `e!` | propagate failure | `e?` | `try e` |
| `f(x)&` | run the call as a task | `tokio::spawn(f(x))` | `std.Thread.spawn(...)` |
| `>t` | wait for the task and take its result | `t.await` | `t.join()` |

The [sigils journey](docs/learn/01-sigils.md) teaches them one at a
time, and [QUICK](docs/QUICK.md) fits them on a page. Four points are
the ones that surprise readers from other languages:

- **Names say what a value is; sigils say how you hold it.** Every named
  type is an owner (`List[T]`, `String`, `Cell[T]`, an object of yours),
  and a view is never a name: it is written `?T` or `!T`, or is a slice
  `[]T`, so the read view of text is `?String`. `^T` is a box, a `T`
  alone on the heap, like Rust's `Box<T>`; `*T` is a counted pointer,
  like Rust's `Rc<T>`.
- **Prefix or suffix.** A prefix sigil says how you hold a value, and a
  suffix `?` or `!` is control flow (`e?` passes `none` up, `e!` passes
  a failure up). Types follow suit: `T?` is an optional and `T!` a `T`
  that may fail. The by-position table of `?` and `!` is in
  [the sigils journey](docs/learn/01-sigils.md#-and--one-idea-each).
- **`!` is never "not".** Logical negation is `not`, so `!v.pop()` lends
  `v` to write and never negates (`if !done` is an error that says to
  use `not`; see [below](#habits-that-trip-people-up)). A move to
  nowhere is a drop: `<x` standing alone as a statement drops `x` now,
  and `-n` is only ever arithmetic negation.
- **You lend a view; the compiler remembers the loan.** The owner
  lends with `?` or `!`, what the callee gets is a view, and what stays
  behind is a loan. Rust calls all three a "borrow"; Rig gives each its
  own word, named from the owner's side ([CORE](docs/CORE.md)).

A reader sees every move, clone, write, and failure path on the line
where it happens; reading is unmarked, and, as in Rust, a value is
dropped where its scope ends unless `<x` drops it sooner. The compiler
checks each one: no use after move, no double free, no dangling view,
no leak. The one leak it does not prevent is a cycle of strong handles,
as in Rust and Swift; a weak handle breaks it.

## A first program

```rig
fun label(n: Int) -> ?String
  match n % 15
    0 => "fizzbuzz"
    3, 6, 9, 12 => "fizz"
    5, 10 => "buzz"
    _ => "-"

sub main()
  for n in 1..7
    print(n, label(n))
```

```output
1 -
2 -
3 fizz
4 -
5 buzz
6 fizz
```

`fun` declares a function that returns a value, and `sub` one that
returns nothing. The last expression of a `fun` is its value. `1..7`
counts from 1 up to, not including, 7. `print` takes any number of
values and separates them with spaces. Objects, moves, optionals,
errors, and closures are taught in [docs/learn/](docs/learn/README.md).

## Running a program

```bash
bin/rig run hello.rig        # check, build, and run (Debug, leak-checked)
bin/rig run hello.rig -- a b # the same, passing the program `a` and `b`
bin/rig build -o hello hello.rig
bin/rig test hello.rig       # run the file's own `test` blocks
bin/rig emit hello.rig       # print the Zig it generates
```

The [README](README.md#install) says how to build `bin/rig`.

## From Rust and Zig

Rig's ownership model is Rust's, with two differences you notice at
once: every transfer is written (write `<x` when `x` stays in scope
after the move; where `x`'s scope ends with the move, the move is
plain: `return x`, `break x` of a name the loop declares, or `x` as the
last value of the function or block that declares it), and there is no
lifetime syntax (the
checker follows where each view came from instead). Its cost model is
Zig's: the emitted program is plain Zig, with no runtime beyond a small
support file.

| Idea | Rust | Zig | Rig |
|---|---|---|---|
| binding | `let x = 1;` | `const x = 1;` | `x = 1` (fixed: `x =! 1`) |
| reassignment | `let mut x = 1;` then `x = 2;` | `var x: i64 = 1;` then `x = 2;` | `x = 1`, then `x = 2` |
| typed binding | `let x: u8 = 1;` | `const x: u8 = 1;` | `x: U8 = 1` |
| shadowing | `let x = x + 1;` | not allowed | `new x = x + 1` |
| function | `fn f(a: i64) -> i64 { a }` | `fn f(a: i64) i64 { return a; }` | `fun f(a: Int) -> Int` / `  a` |
| no result | `fn f() {}` | `fn f() void {}` | `sub f()` |
| fallible, no result | `fn f() -> Result<(), E>` | `fn f() !void` | `sub f()!` |
| result views one argument | `fn f<'a>(a: &'a T, b: &T) -> &'a T` | (no check) | `fun f(a: ?T, b: ?T) -> ?T from a` |
| call | `f(a)` | `f(a)` | `f(a)` |
| object literal | `P { x: 1 }` | `P{ .x = 1 }` | `P(x: 1)` |
| method self | `&self`, `&mut self`, `self` | `self: *const P`, `self: *P`, `self: P` | `?@`, `!@`, `<@` |
| mutating call | `v.push(x)` | `try v.append(gpa, x)` | `!v.push(x)` |
| enum variant | `Shape::Circle { r: 2 }` | `.{ .circle = .{ .r = 2 } }` | `.circle(r: 2)`, or `.circle(2)` for one field |
| match | `match x { A => .., _ => .. }` | `switch (x) { .a => .., else => .. }` | `match x` / `.a => ..` / `_ => ..` |
| optional | `Option<T>`, `None` | `?T`, `null` | `T?`, `none` |
| unwrap or | `x.unwrap_or(0)` | `x orelse 0` | `x ?? 0` |
| unwrap or leave | `let Some(v) = x else { return }` | `x orelse return` | `v = x ?? return` |
| if let | `if let Some(v) = x` | `if (x) \|v\|` | `if x as v` |
| if let, a variant | `if let Circle(r) = s` | `switch (s) { .circle => \|c\| .., else => {} }` | `if s as .circle(r)` |
| fallible | `Result<T, E>` | `E!T` | `T!` |
| propagate | `f()?` | `try f()` | `f()!` |
| handle | `f().unwrap_or(0)` | `f() catch 0` | `f() catch 0` |
| lend | `&x`, `&mut x` | `&x` | `?x`, `!x` |
| slice | `&v[a..b]`, `&mut v[a..]` | `v[a..b]`, `v[a..]` | `?v[a..b]`, `!v[a..]` |
| reference count | `Rc::new(x)`, `Rc::clone(&r)` | by hand | `*x`, `+r` |
| weak | `Rc::downgrade(&r)`, `w.upgrade()` | by hand | `~r`, `*w` |
| interior mutability | `Rc<RefCell<T>>` | by hand | `*Cell[T]` |
| heap box | `Box<T>` | `allocator.create(T)` | `^T` |
| growable array | `Vec<T>` | `std.ArrayList(T)` | `List[T]` |
| closure | `move \|a\| a + n` | a struct with a method | `\|+n, a\| a + n` |
| closure argument | `f: &dyn Fn(i64) -> i64` | a context pointer and a function | `f: ?fun(Int) -> Int` |
| drop early | `drop(x)` | `x.deinit()` | `<x` alone on a line |
| destructor | `impl Drop` | `deinit` + `defer` | `drop(!@)` |
| cleanup | a scope guard | `defer`, `errdefer` | `defer`, `errdefer` |
| unsafe | `unsafe { }` | (everything) | a `raw` block |
| logic | `&&`, `\|\|`, `!` | `and`, `or`, `!` | `and`, `or`, `not` |
| ternary | `if c { a } else { b }` | `if (c) a else b` | `a if c else b` |

**No implicit shadowing.** A name is never shadowed silently: a local
may not reuse the name of another local, a parameter, or a module-level
declaration, a closure parameter may not reuse a local's name, and a
generic parameter may not reuse a module-level name. Zig has the same
rule; where Rust writes `let x = x + 1`, Rig shadows on purpose with
`new x = x + 1` ([SPEC §4](SPEC.md#4-bindings-and-assignment)).

```rig reject
T = 3

obj W[T]
  v: T
```

```error
generic parameter `T` has the same name as the module-level declaration `T`; use a different name
```

### Generics

| | Rust | Zig | Rig |
|---|---|---|---|
| generic function | `fn max<T: PartialOrd>(a: T, b: T) -> T` | `fn max(comptime T: type, a: T, b: T) T` | `fun max[T](a: T, b: T) -> T` |
| explicit type argument | `max::<f64>(1.0, 2.0)` | `max(f64, 1, 2)` | `max[Float](1, 2)` |
| what `T` may do | what its bounds say | what each instance compiles | what each instance supports, checked per call |
| generic type | `obj Wrap<T> { v: T }` | `fn Wrap(comptime T: type) type` | `obj Wrap[T]` |
| type arguments | `Vec::<i64>::new()` | `std.ArrayList(i64)` | `List[Int]()` |
| generic method | `fn map<U>(&self, f: fn(T) -> U) -> Wrap<U>` | `fn map(self: Self, comptime U: type, f: *const fn (T) U) Wrap(U)` | `fun map[U](?@, f: fun(T) -> U) -> Wrap[U]` |
| compile-time value | `fn f<const N: usize>(x: i64)` | `fn f(comptime n: usize, x: i64)` | `fun f[n: Int](x: Int)` |
| its call | `f::<3>(x)` | `f(3, x)` | `f[3](x)` |
| an array of it | `fn sum<const N: usize>(xs: [i64; N])` | `fn sum(comptime n: usize, xs: [n]i64)` | `fun sum[n: Int](xs: [n]Int)` |
| its length inferred | `sum([1, 2, 3])` | `sum(3, .{ 1, 2, 3 })` | `sum([1, 2, 3])` |
| a type with a value | `obj Ring<T, const N: usize>` | `fn Ring(comptime T: type, comptime n: usize) type` | `obj Ring[T, n: Int]` |
| its instance | `Ring<i64, 4>` | `Ring(i64, 4)` | `Ring[Int, 4]` |
| a filled array | `[0; N]` | `@as([n]i64, @splat(0))` | `[n of 0]` |

After a name, square brackets give compile-time arguments, types and
values alike, and parentheses give run-time ones. Indexing is the one
familiar exception. Zig
passes types and compile-time values the same way, as `comptime`
parameters, and Rig puts them all in brackets, so a call shows which
arguments shape the code. Brackets also keep type arguments apart from
construction: `Wrap(v: 3)` builds a `Wrap`, and `Wrap[Int](v: 3)`
cannot be misread as a call. Go (`Max[float64](1, 2)`), Mojo, and
Python's type hints (`list[int]`) write them the same way.

There are no traits or bounds. A generic body is checked once, and each
instance a program makes is checked against what the body does with
`T`, the methods it calls on one included, like a Zig `comptime T: type` function but with the error at the
call ([SPEC §3](SPEC.md#generic-bodies)).

### What a program becomes

`rig emit file.rig` prints the Zig a program becomes. The main
correspondences:

| Rig | Zig |
|---|---|
| `Int`, `U8`, `Float`, `?String`, `Static` | `i64`, `u8`, `f64`, `[]const u8` |
| `String` | `rig.String`, a growable byte buffer the runtime frees |
| `obj`, plain `enum`, payload `enum` | `struct`, `enum`, `union(enum)` |
| `U8(x)`, `Int(e)` of a plain enum | `@as(u8, @intCast(x))`, `@as(i64, @intCast(@backingInt(e)))` |
| `a +% b`, `U8.max` | `a +% b`, the constant `std.math.maxInt(u8)` |
| `error E` | an error set, each member named with its set (`error.@"E.name"`), so two sets' members never coincide |
| `obj Wrap[T]` | `fn Wrap(comptime T: type) type` |
| `fun max[T](a: T, b: T) -> T`, `max(3, 7)` | `fn max(comptime T: type, a: T, b: T) T`, `max(i64, 3, 7)` |
| `fun f[n: Int](x: Int)`, `f[3](x)` | `fn f(comptime n: i64, x: i64) i64`, `f(3, x)` |
| `[n of x]` | `@as([n]T, @splat(x))` |
| `T?`, `none`, `a ?? b` | `?T`, `null`, `a orelse b` |
| `T!`, `f()!`, `catch` | `anyerror!T`, `try f()`, `catch` |
| a `?T` parameter | a copy of a scalar or view (a number, `Bool`, `?String`, a slice, a plain enum); `*const T` for an object, an array, or a generic instance |
| `!T` | `*T` |
| `[]T`, `![]T` | `[]const T`, `[]T` |
| `*T`, `~T` | a runtime `Shared(T)` pointer, a weak handle |
| `List[T]`, `Cell[T]`, `^T`, `Signal[T]` | runtime generic types |
| an owning local | a `defer` that releases it, guarded by a flag if it may move first |
| a stack closure | a local struct holding its captures, with an `__rig_invoke` method |
| `?fun(A) -> R` | `rig.FnRef`: a context pointer and a call function |
| an owned closure | a counted, type-erased closure |
| `defer`, `errdefer` | `defer`, `errdefer` |
| `sub main()` | `pub fn main(__rig_init: std.process.Init.Minimal) void`, which reports a failure it propagates as `error: E.name` and exits 1; in Debug it checks for leaks on exit |

The runtime, `src/runtime.zig`, is written next to every emitted
program; [INTERNALS](docs/internals/INTERNALS.md) describes it.

## From C, Python, Ruby, JavaScript, and Go

| Idea | C | Python / Ruby | JavaScript / Go | Rig |
|---|---|---|---|---|
| block | `{ }` | indentation / `end` | `{ }` | indentation |
| comment | `//`, `/* */` | `#` | `//` | `#` |
| statement end | `;` | end of line | `;` (optional) / end of line | end of line |
| function | `int f(int a)` | `def f(a):` / `def f(a)` | `function f(a)` / `func f(a int) int` | `fun f(a: Int) -> Int` |
| no result | `void f()` | `def f():` | `func f()` | `sub f()` |
| else if | `else if` | `elif` / `elsif` | `else if` | `else if` |
| absent value | `NULL` | `None` / `nil` | `null` / `nil` | `none`, in a `T?` |
| booleans | `1`, `0` | `True` / `true` | `true` | `true`, `false` |
| logic | `&&`, `\|\|`, `!` | `and`, `or`, `not` | `&&`, `\|\|`, `!` | `and`, `or`, `not` |
| increment | `i++` | `i += 1` | `i++` | `i += 1` |
| counting loop | `for (i = 0; i < n; i++)` | `for i in range(n)` / `n.times` | `for i := 0; i < n; i++` | `for i in 0..n` |
| index and element | by hand | `for i, x in enumerate(xs)` | `for i, x := range xs` | `for x, i in xs` (element first) |
| class | `struct` + functions | `class` | `class` / `struct` + methods | `obj` with methods |
| `this` / `@` | a pointer argument | `@` (implicit in Ruby) | `this` / a method's own parameter | `@`, always written |
| switch | `switch` | `match` / `case` | `switch` | `match` |
| a name as a value | an `enum` | a string / `:width` | a string constant | `:width`, a `Symbol` ([SPEC](SPEC.md#symbols)); `f(width: 3)` names an argument |
| do nothing | `;` | `pass` / `nil` | `{}` | `pass` |
| exceptions | error codes | `raise` / `try` | `throw` / `error` returns | `T!`, `f()!`, `catch` |
| several results | out-parameters | `return q, r`, a tuple | an array / `return q, r` | `-> (Int, Int)`, `return q, r`, `q, r = f()` |
| string formatting | `printf` | f-strings / `#{}` | template strings / `Sprintf` | `print(a, b)`, `String(a, b)`: no interpolation |
| memory | `malloc`, `free` | a garbage collector | a garbage collector | owners, released where their scope ends |

A Rig program frees what it allocates at a point you can see: when its
owner's scope ends, or where a statement `<x` drops it. There is no collector, and
a Debug build reports any allocation still live when `main` returns.

### Go's multiple results and Python's tuples

A function gives several results as Go's does: `-> (Int, Int)`, given by
`return q, r`, and bound by name where they arrive, `q, r = divmod(a,
b)`, each name declared or assigned as `x = e` would. `_` discards
one. Unlike Python's tuple, the group is never a value: it is not
stored, passed, or printed whole, and `(a, b)` builds nothing. A group
that lives on is an object, which names its parts. Go's `(T, error)` is
Rig's `T!`, and its `(T, bool)` is `T?`.

```rig
fun divmod(a: Int, b: Int) -> (Int, Int)
  return a / b, a % b

obj Span
  start: Int
  end: Int

sub main()
  q, r = divmod(17, 5)
  s = Span(start: q, end: q + r)
  print(q, r, s.end)
```

```output
3 2 5
```

## Habits that trip people up

Each habit below is a compile error, and the error names the Rig
spelling.

**Tuples and parallel assignment.** `(a, b)` is no value, and `a, b =
b, a` assigns nothing in parallel: exchange two places with `swap`.

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
  print(a, b)
```

```error
Rig has no parallel assignment: write `swap(!a, !b)` to exchange two places
```

**Another language's keywords.** Rig has `fun`, `sub`, `obj`,
`else if`, and `match`, and no semicolons:

```rig reject
def main
  print(1)
```

```error
Rig has no `def`; declare a function with `fun` (it returns a value) or `sub`
```

```rig reject
sub main()
  x = 1
  if x > 1
    print(1)
  elif x > 0
    print(2)
```

```error
Rig has no `elif`; write `else if`
```

```rig reject
sub main()
  let x = 1;
  print(x)
```

```error
Rig has no `let`; bind a name with `x = 5`, or `x =! 5` for one that never changes
```

A block's header takes no `:`, a comment starts with `#`, and `i++`
is `i += 1`:

```rig reject
sub main()
  i = 0
  if i > 0:
    print(i)
```

```error
unexpected `:`; a block's header ends without one: remove the `:`, and indent the block below
```

```rig reject
sub main()
  i = 0 // start
  print(i)
```

```error
comments start with `#`; Rig has no `//` or `/* */` comments
```

```rig reject
sub main()
  i = 0
  i++
  print(i)
```

```error
Rig has no `++`; write `x += 1`
```

**Other languages' names.** The absent value is `none`, booleans are
lowercase, self is `@` and always written, and a line is
printed with `print`:

```rig reject
obj Counter
  n: Int

  fun get(?@) -> Int
    this.n

  fun twice(?@) -> Int
    n * 2

sub main()
  x: Int? = null
  ok = True
  println(Counter(n: 1).get())
```

```error
use of unbound name `this`; a method's self is `@`
use of unbound name `n`; did you mean `@n`?
use of unbound name `null`; Rig's absent value is `none`
use of unbound name `True`; Rig writes `true`
use of unbound name `println`; Rig prints a line with `print(...)`
```

A misspelled name, type, field, or method is answered with the nearest
one in scope: ``use of unbound name `totla`; did you mean `total`?``.

**Calls without parentheses.** Every call has them, as in Rust and Zig:

```rig reject
sub main()
  x = 1
  print x
```

```error
unexpected name `x`; `print` is called with parentheses: `print(...)`
```

**`!` is not "not".** Prefix `!` lends to write; negation is `not`.
Where it would start a condition, or an operand of `and`, `or`, or
`not`, the habit is an error:

```rig reject
sub main()
  done = false
  while !done
    done = true
```

```error
`!` lends to write; use `not` for negation (a `Bool` is lent to write only where a `!Bool` is expected: `f(!flag)`)
```

**`&&` and `||`.** They are `and` and `or`; for an optional's fallback,
`??`:

```rig reject
sub main()
  a = true
  print(a || false)
```

```error
`||` is not a Rig operator; use `or`, or `??` for an optional's fallback
```

**Mutation without `!`.** A call that writes a value shows it, even on
a value you own (Rust writes `v.push(x)`):

```rig reject
obj Counter
  n: Int

  sub bump(!@)
    @n += 1

sub main()
  c = Counter(n: 0)
  c.bump()
```

```error
method `bump` needs `self` lent to write
```

[Writing is marked](docs/learn/01-sigils.md#writing-is-marked) teaches the rule.

**Moves without `<`.** A bare name moves an owning value only where its
scope ends with the move (`return x`, `break x` of a name the loop
declares, or `x` as the last value of the function or block that
declares it); anywhere else the error names the fix:

```rig reject
obj Res
  n: Int

  drop(!@)
    print("released", @n)

sub eat(r: Res)
  print(r.n)

sub main()
  r = Res(n: 1)
  eat(r)
```

```error
`eat` takes ownership of a `Res`, and `r` can't be copied: write `<r` to move it; if `eat` only reads it, make its parameter a `?Res`
```

[Giving a value away](docs/learn/01-sigils.md#giving-a-value-away) and the [ownership journey](docs/learn/02-ownership.md) teach the rule.

**Rust's `?` on a failure.** `?` propagates `none`; a failure propagates
with `!`:

```rig reject
fun parse(s: ?String) -> Int!
  s.len

fun twice(s: ?String) -> Int!
  parse(s)? * 2
```

```error
`?` propagates `none`, and `parse(s)` fails with an error instead: propagate the failure with `parse(s)!`, or handle it with `catch`
```

**`+` on strings.** A `?String` is a view of text it does not own, so
there is nothing for `+` to write into. Rig's `?String` is Go's or
Odin's `string`; Rust's `String` is Rig's `String`. A literal is a
`Static`: a `?String` known to view only text that lives for the whole
program, so it can also be kept in a `Cell` ([SPEC](SPEC.md#static)).
Text is built in a
`String`, which owns its bytes: `String(a, b)` writes each value as
`print` would, and `!t.add(...)` appends more ([SPEC §10](SPEC.md#string)):

```rig reject
sub main()
  name = "ada"
  print("hi " + name)
```

```error
Rig has no `+` on text: build it with `String(a, b)` or `!t.add(...)`
```

```rig
sub main()
  name = "ada"
  t = String("hi ", name)
  !t.add(", you are ", 36)
  print(t)
  print(String("bye ", name).len)
```

```output
hi ada, you are 36
7
```

A String built only to be read, as that last one is, is dropped when its
statement ends.

**Inclusive ranges.** `a..b` excludes its end, as Python's `range` and
Rust's `..` do; `a..=b` includes it, and reaches a type's largest value
without stepping past it:

```rig
sub main()
  count = 0
  for 0..=U8.max
    count += 1
  print(count)
```

```output
256
```

**Index first.** `for x, i in xs` binds the element, then the index, the
reverse of Python's `enumerate` and Go's `range`. Written the other
way, the error says so where a binding is used as the other one:

```rig reject
sub main()
  xs = ["a", "bb"]
  for i, x in xs
    print(xs[i])
```

```error
`x` is the index here: Rig writes the element first, `for x, i in xs`
```

**Unread and shadowed locals.** `x = e` both declares and assigns, so a
typo would declare a new variable silently. A local that is never read
is an error (as in Zig), and so is a local that reuses a visible name
without `new`:

```rig reject
fun total() -> Int
  0

sub main()
  count = 0
  cuont = 5
  print(count)
  total = 1
  print(total)
```

```error
`cuont` is assigned but never read
local `total` has the same name as the module-level declaration `total`
```

Some habits need no error, only a different spelling: `xs.len` is a
field, not `xs.len()`, since reading it runs no code; a constructor
names its fields, `P(x: 1)`, not `.{ .x = 1 }`; `switch`'s `else =>` is
`match`'s `_ =>`; and an allocator is never passed, because `*x`,
`^v`, `List`, and owned closures are the only things that allocate
(besides the runtime's list of the program's arguments), and the
compiler frees them.

## What Rig does not have

You will reach for these and not find them:

- **traits and bounds**: a generic body may do with `T` only what each
  instance supports;
- **string interpolation**: text is built with `String(...)` and
  `!t.add(...)`, which write values as `print` does;
- **a large standard library**: [the standard library](docs/STD.md)
  covers text and Unicode, hashing, JSON, files, time, tasks and
  parallel loops, TCP and an HTTP server, and a terminal; TLS, an HTTP
  client, and DNS are not there yet;
- **raw pointers**;
- **macros**, which Rig does not plan to have.

[SPEC §19](SPEC.md#19-reserved-and-unsupported-forms) lists every form
the compiler rejects as reserved or not supported yet, and the
[roadmap](docs/ROADMAP.md) lists the plans.

## Where to go next

- [docs/learn/](docs/learn/README.md): the journeys, which teach the
  language from the first line
- [docs/QUICK.md](docs/QUICK.md): the language on one page
- [docs/BEYOND-RUST.md](docs/BEYOND-RUST.md): how Rig differs from
  Rust's model, for readers who know Rust
- [SYNTAX.md](SYNTAX.md): how every form is written
- [SPEC.md](SPEC.md): what every form means, and the rules the compiler
  enforces
- [docs/STD.md](docs/STD.md): the standard library, imported with
  `use std.NAME`
- [examples/](examples/README.md): complete programs
- [docs/DESIGN.md](docs/DESIGN.md): why Rig is the way it is
- [FAQ.md](FAQ.md): common questions
