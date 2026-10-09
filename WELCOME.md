# Welcome to Rig

Rig is a systems language for people who want Python's readability,
Zig's cost model, and Rust's memory safety in one place. There is no
garbage collector and no hidden allocation. Blocks are indented, types
are inferred, and most lines look like pseudocode. The compiler checks
the program, then writes [Zig](https://ziglang.org), and Zig optimizes,
generates code, and links.

This guide is for programmers arriving from another language. It shows
Rig's central idea, tours five small programs, translates the forms you
already know, and lists the habits that will trip you up, with what the
compiler says when they do. [SYNTAX.md](SYNTAX.md) then shows how every
form is written, and [SPEC.md](SPEC.md) says what each one means.

Every `rig` example here is compiled and run by the test suite. A
program followed by an `output` block prints exactly that, with no
leaks; a program marked as rejected fails with the errors shown.

## Contents

- [The central idea](#the-central-idea)
- [A quick tour](#a-quick-tour)
- [Running a program](#running-a-program)
- [From Rust and Zig](#from-rust-and-zig)
- [From C, Python, Ruby, JavaScript, and Go](#from-c-python-ruby-javascript-and-go)
- [Habits that trip people up](#habits-that-trip-people-up)
- [What Rig does not have](#what-rig-does-not-have)
- [Where to go next](#where-to-go-next)

## The central idea

Everything that happens to a value's ownership is written where it
happens, as a one-character **sigil**:

| Sigil | Meaning | Rust | Zig |
|---|---|---|---|
| `<x` | move `x` | `x` (implicit move) | copy, then stop using `x` |
| `?x` | lend `x` to read | `&x` | `x` or `&x` |
| `!x` | lend `x` to write | `&mut x` | `&x` |
| `+x` | clone: a new owner | `x.clone()`, `Rc::clone(&x)` | copy, or a manual refcount bump |
| `-x` | drop now | `drop(x)` | `x.deinit()` |
| `*x` | move into a shared, counted box | `Rc::new(x)` | a hand-written refcounted box |
| `~x` | weak handle | `Rc::downgrade(&x)` | a hand-written weak count |
| `e!` | propagate failure | `e?` | `try e` |
| `e?` | propagate `none` | `e?` on an `Option` | `e orelse return null` |

**Prefix or suffix.** A prefix sigil says how you hold a value (`?x`
and `!x` lend it, `<x` moves it, `+x` clones it, `-x` drops it, `*x`
and `~x` make handles), and a suffix `?` or `!` is control flow (`e?`
passes `none` up, `e!` passes a failure up). Types follow suit: `?T`
and `!T` are views, `*T` a shared handle and `~T` a weak one, while
`T?` is an optional and `T!` a `T` that may fail. Rig has no `!` for
"not": logical negation is `not`, so `!v.pop()` lends `v` to write,
and never negates (`if !done` is an error that says to use `not`; see
[below](#habits-that-trip-people-up)). The one look-alike is `-`: only
`-name` standing alone as a statement drops; as a value, `-n` is
arithmetic negation (`y = -n`):

```rig
sub main()
  v: Vec[Int] = Vec()
  !v.push(1)
  !v.push(2)
  done = false
  while not done
    print(!v.pop() ?? 0)
    done = v.len == 0
```

```output
2
1
```

Suffixes read left to right, and a view covers the whole type after
it: `S?!` is an `S?` that may fail, `?D?` a view of a `D?`, and
`(?D)?` an optional view of a `D`.

**You lend a view; the compiler remembers the loan.**

- The `?` or `!` is written on the owner (`print(?v)`, `grow(!v)`), so
  the owner **lends**.
- What the receiver gets is a **view**: it reads the value, or with
  `!` changes it. The receiver may return or store it; a read view also
  copies, while a write view moves, so only one can change the value.
- What stays behind is a **loan**: until the last use of every view,
  the owner can't change, move, or drop what it lent.

Rust calls all three a "borrow". Rig gives each its own word, named from
the side the sigil is on ([CORE](docs/CORE.md)).

A reader sees every move, lend, clone, drop, and failure path on the
line where it happens, and the compiler checks each one: no use after
move, no double free, no dangling view, no leak. The one leak it does
not prevent is a cycle of strong handles, as in Rust and Swift; a weak
handle breaks it.

## A quick tour

### A first program

```rig
fun label(n: Int) -> String
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
values and separates them with spaces.

### Structs, methods, and lending

```rig
struct Account
  owner: String
  balance: Int

  fun can_pay(?self, amount: Int) -> Bool
    self.balance >= amount

  sub pay(!self, amount: Int)
    self.balance -= amount

sub main()
  a = Account(owner: "ada", balance: 100)
  if a.can_pay(30)
    !a.pay(30)
  print(a.owner, a.balance)
```

```output
ada 70
```

`?self` reads the receiver and `!self` writes it. The call site says
the same: a read is implicit (`a.can_pay(30)`), but a write is always
spelled out, `!a.pay(30)`, so every mutation is visible, except inside
a `Cell`, which changes through any path ([SPEC §10](SPEC.md#cell)).

### Moves, clones, and drops

```rig
struct File
  name: String

  drop(!self)
    print("closing", self.name)

sub archive(f: File)
  print("archiving", f.name)

sub main()
  log = File(name: "log.txt")
  archive(<log)
  cfg = *File(name: "cfg.toml")
  cfg2 = +cfg
  <cfg
  print("still open:", cfg2.name)
```

```output
archiving log.txt
closing log.txt
still open: cfg.toml
closing cfg.toml
```

`<log` moves the file into `archive`, which owns it and closes it on
return. `*File(...)` puts a file in a reference-counted box, `+cfg`
makes a second owner, `-cfg` drops the first now, and the file closes
when `cfg2`, its last owner, goes out of scope.

### Optionals and errors

```rig
error ParseError
  empty

fun parse_len(s: String) -> Int!
  return ParseError.empty if s == ""
  s.len

fun first_even(xs: ?[4]Int) -> Int?
  for x in xs
    return x if x % 2 == 0
  none

sub main()
  print(parse_len("four")!, parse_len("") catch -1)
  print(first_even(?[1, 3, 4, 5]) ?? 0)
```

```output
4 -1
4
```

`Int!` may fail, and every call says what happens to the failure: `!`
propagates it, `catch` handles it. `Int?` may be `none`, and `??`
supplies a fallback. `return x if ...` is a guarded statement, Ruby's
statement modifier.

### Closures

```rig
sub main()
  count: *Cell[Int] = *Cell(0)
  step = 5
  tick = |+count, +step| count.set(count.get() + step)
  tick()
  tick()
  print(count.get())
```

```output
10
```

A closure has no keyword: it starts with its bar list. Each captured
name carries a sigil that says how it is held: `+step` copies, `<x`
would move, `?x` and `!x` would lend, and `~x` would hold a handle
weakly. A bare name is a parameter, as `a` is in `|+step, a| a + step`;
captures come first, and a parameter may not reuse a local's name, so
`|step|` here would be rejected. `*Cell[Int]` is a shared cell, the way
to share state that changes (a `*Signal` also tells its subscribers).

## Running a program

```bash
bin/rig run hello.rig        # check, build, and run (Debug, leak-checked)
bin/rig run hello.rig -- a b # the same, passing the program `a` and `b`
bin/rig build -o hello hello.rig
bin/rig test hello.rig       # run the program's `test` blocks
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
| binding | `let x = 1;` | `const x = 1;` | `x = 1` (fixed: `const x = 1`) |
| reassignment | `let mut x = 1;` then `x = 2;` | `var x: i64 = 1;` then `x = 2;` | `x = 1`, then `x = 2` |
| typed binding | `let x: u8 = 1;` | `const x: u8 = 1;` | `x: U8 = 1` |
| shadowing | `let x = x + 1;` | not allowed | `new x = x + 1` |
| function | `fn f(a: i64) -> i64 { a }` | `fn f(a: i64) i64 { return a; }` | `fun f(a: Int) -> Int` / `  a` |
| no result | `fn f() {}` | `fn f() void {}` | `sub f()` |
| fallible, no result | `fn f() -> Result<(), E>` | `fn f() !void` | `sub f()!` |
| result views one argument | `fn f<'a>(a: &'a T, b: &T) -> &'a T` | (no check) | `fun f(a: ?T, b: ?T) -> ?T from a` |
| call | `f(a)` | `f(a)` | `f(a)` |
| struct literal | `P { x: 1 }` | `P{ .x = 1 }` | `P(x: 1)` |
| method receiver | `&self`, `&mut self`, `self` | `self: *const P`, `self: *P`, `self: P` | `?self`, `!self`, `<self` |
| mutating call | `v.push(x)` | `try v.append(gpa, x)` | `!v.push(x)` |
| enum variant | `Shape::Circle { r: 2 }` | `.{ .circle = .{ .r = 2 } }` | `.circle(r: 2)`, or `.circle(2)` for one field |
| match | `match x { A => .., _ => .. }` | `switch (x) { .a => .., else => .. }` | `match x` / `.a => ..` / `_ => ..` |
| optional | `Option<T>`, `None` | `?T`, `null` | `T?`, `none` |
| unwrap or | `x.unwrap_or(0)` | `x orelse 0` | `x ?? 0` |
| unwrap or leave | `let Some(v) = x else { return }` | `x orelse return` | `v = x ?? return` |
| if let | `if let Some(v) = x` | `if (x) \|v\|` | `if x as v` |
| fallible | `Result<T, E>` | `E!T` | `T!` |
| propagate | `f()?` | `try f()` | `f()!` |
| handle | `f().unwrap_or(0)` | `f() catch 0` | `f() catch 0` |
| lend | `&x`, `&mut x` | `&x` | `?x`, `!x` |
| slice | `&v[a..b]`, `&mut v[a..]` | `v[a..b]`, `v[a..]` | `?v[a..b]`, `!v[a..]` |
| reference count | `Rc::new(x)`, `Rc::clone(&r)` | by hand | `*x`, `+r` |
| weak | `Rc::downgrade(&r)`, `w.upgrade()` | by hand | `~r`, `w.upgrade()` |
| interior mutability | `Rc<RefCell<T>>` | by hand | `*Cell[T]` |
| heap box | `Box<T>` | `allocator.create(T)` | `Box[T]` |
| growable array | `Vec<T>` | `std.ArrayList(T)` | `Vec[T]` |
| closure | `move \|a\| a + n` | a struct with a method | `\|+n, a\| a + n` |
| closure argument | `f: &dyn Fn(i64) -> i64` | a context pointer and a function | `f: ?fun(Int) -> Int` |
| drop early | `drop(x)` | `x.deinit()` | `-x` |
| destructor | `impl Drop` | `deinit` + `defer` | `drop(!self)` |
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

struct W[T]
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
| generic type | `struct Wrap<T> { v: T }` | `fn Wrap(comptime T: type) type` | `struct Wrap[T]` |
| type arguments | `Vec::<i64>::new()` | `std.ArrayList(i64)` | `Vec[Int]()` |
| generic method | `fn map<U>(&self, f: fn(T) -> U) -> Wrap<U>` | `fn map(self: Self, comptime U: type, f: *const fn (T) U) Wrap(U)` | `fun map[U](?self, f: fun(T) -> U) -> Wrap[U]` |
| compile-time value | `fn f<const N: usize>(x: i64)` | `fn f(comptime n: usize, x: i64)` | `fun f[n: Int](x: Int)` |
| its call | `f::<3>(x)` | `f(3, x)` | `f[3](x)` |
| an array of it | `fn sum<const N: usize>(xs: [i64; N])` | `fn sum(comptime n: usize, xs: [n]i64)` | `fun sum[n: Int](xs: [n]Int)` |
| its length inferred | `sum([1, 2, 3])` | `sum(3, .{ 1, 2, 3 })` | `sum([1, 2, 3])` |
| a type with a value | `struct Ring<T, const N: usize>` | `fn Ring(comptime T: type, comptime n: usize) type` | `struct Ring[T, n: Int]` |
| its instance | `Ring<i64, 4>` | `Ring(i64, 4)` | `Ring[Int, 4]` |
| a filled array | `[0; N]` | `@as([n]i64, @splat(0))` | `[n of 0]` |

Square brackets hold everything known at compile time, types and
values alike, and parentheses what is known when the program runs. Zig
passes types and compile-time values the same way, as `comptime`
parameters, and Rig puts them all in brackets, so a call shows which
arguments shape the code. Brackets also keep type arguments apart from
construction: `Wrap(v: 3)` builds a `Wrap`, and `Wrap[Int](v: 3)`
cannot be misread as a call. Go (`Max[float64](1, 2)`), Mojo, and
Python's type hints (`list[int]`) write them the same way.

There are no traits or bounds. A generic body is checked once, and each
instance a program makes is checked against what the body does with
`T`, like a Zig `comptime T: type` function but with the error at the
call ([SPEC §3](SPEC.md#generic-bodies)).

### What a program becomes

`rig emit file.rig` prints the Zig a program becomes. The main
correspondences:

| Rig | Zig |
|---|---|
| `Int`, `U8`, `Float`, `String` | `i64`, `u8`, `f64`, `[]const u8` |
| `Text` | `rig.Text`, a growable byte buffer the runtime frees |
| `struct`, plain `enum`, payload `enum` | `struct`, `enum`, `union(enum)` |
| `U8(x)`, `Int(e)` of a plain enum | `@as(u8, @intCast(x))`, `@as(i64, @intCast(@backingInt(e)))` |
| `a +% b`, `U8.max` | `a +% b`, the constant `std.math.maxInt(u8)` |
| `error E` | an error set, each member named with its set (`error.@"E.name"`), so two sets' members never coincide |
| `struct Wrap[T]` | `fn Wrap(comptime T: type) type` |
| `fun max[T](a: T, b: T) -> T`, `max(3, 7)` | `fn max(comptime T: type, a: T, b: T) T`, `max(i64, 3, 7)` |
| `fun f[n: Int](x: Int)`, `f[3](x)` | `fn f(comptime n: i64, x: i64) i64`, `f(3, x)` |
| `[n of x]` | `@as([n]T, @splat(x))` |
| `T?`, `none`, `a ?? b` | `?T`, `null`, `a orelse b` |
| `T!`, `f()!`, `catch` | `anyerror!T`, `try f()`, `catch` |
| a `?T` parameter | a copy of a scalar or view (a number, `Bool`, `String`, a slice, a plain enum); `*const T` for a struct, an array, or a generic instance |
| `!T` | `*T` |
| `[]T`, `![]T` | `[]const T`, `[]T` |
| `*T`, `~T` | a runtime `RcBox(T)` pointer, a weak handle |
| `Vec[T]`, `Cell[T]`, `Box[T]`, `Signal[T]` | runtime generic types |
| an owning local | a `defer` that releases it, guarded by a flag if it may move first |
| a stack closure | a local struct holding its captures, with an `__rig_invoke` method |
| `?fun(A) -> R` | `rig.FnRef`: a context pointer and a call function |
| an owned closure | a counted, type-erased closure |
| `defer`, `errdefer` | `defer`, `errdefer` |
| `sub main()` | `pub fn main(__rig_init: std.process.Init.Minimal) void`, which reports a failure it propagates as `error: E.name` and exits 1; in Debug it checks for leaks on exit |

The runtime, `src/runtime.zig`, is written next to every emitted
program; [INTERNALS](docs/INTERNALS.md) describes it.

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
| class | `struct` + functions | `class` | `class` / `struct` + methods | `struct` with methods |
| `this` / `self` | a pointer argument | `self` (implicit in Ruby) | `this` / a receiver | `self`, always written |
| switch | `switch` | `match` / `case` | `switch` | `match` |
| do nothing | `;` | `pass` / `nil` | `{}` | `pass` |
| exceptions | error codes | `raise` / `try` | `throw` / `error` returns | `T!`, `f()!`, `catch` |
| string formatting | `printf` | f-strings / `#{}` | template strings / `Sprintf` | `print(a, b)`, `Text(a, b)`: no interpolation |
| memory | `malloc`, `free` | a garbage collector | a garbage collector | owners, released where their scope ends |

A Rig program frees what it allocates at a point you can see: when its
owner's scope ends, or where `-x` drops it. There is no collector, and
a Debug build reports any allocation still live when `main` returns.

## Habits that trip people up

Each habit below is a compile error, and the error names the Rig
spelling.

**Another language's keywords.** Rig has `fun`, `sub`, `struct`,
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
Rig has no `let`; bind a name with `x = 5`, or `const x = 5` for one that never changes
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
lowercase, the receiver is `self` and always written, and a line is
printed with `print`:

```rig reject
struct Counter
  n: Int

  fun get(?self) -> Int
    this.n

  fun twice(?self) -> Int
    n * 2

sub main()
  x: Int? = null
  ok = True
  println(Counter(n: 1).get())
```

```error
use of unbound name `this`; a method's receiver is `self`
use of unbound name `n`; did you mean `self.n`?
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
struct Counter
  n: Int

  sub bump(!self)
    self.n += 1

sub main()
  c = Counter(n: 0)
  c.bump()
```

```error
method `bump` needs its receiver lent to write
```

**Moves without `<`.** A bare name moves an owning value only where its
scope ends with the move (`return x`, `break x` of a name the loop
declares, or `x` as the last value of the function or block that
declares it); anywhere else the error names the fix:

```rig reject
struct Res
  n: Int

  drop(!self)
    print("released", self.n)

sub eat(r: Res)
  print(r.n)

sub main()
  r = Res(n: 1)
  eat(r)
```

```error
Use `<r` to move ownership
```

**Rust's `?` on a failure.** `?` propagates `none`; a failure propagates
with `!`:

```rig reject
fun parse(s: String) -> Int!
  s.len

fun twice(s: String) -> Int!
  parse(s)? * 2
```

```error
`?` propagates `none`, and `parse(s)` fails with an error instead: propagate the failure with `parse(s)!`, or handle it with `catch`
```

**`+` on strings.** A `String` is a view of text it does not own, so
there is nothing for `+` to write into. Rig's `String` is Go's or
Odin's `string`; Rust's `String` is Rig's `Text`. Text is built in a
`Text`, which owns its bytes: `Text(a, b)` writes each value as
`print` would, and `!t.add(...)` appends more ([SPEC §10](SPEC.md#text)):

```rig reject
sub main()
  name = "ada"
  print("hi " + name)
```

```error
Rig has no `+` on text: build it with `Text(a, b)` or `!t.add(...)`
```

```rig
sub main()
  name = "ada"
  t = Text("hi ", name)
  !t.add(", you are ", 36)
  print(t)
  print(Text("bye ", name).len)
```

```output
hi ada, you are 36
7
```

A Text built only to be read, as that last one is, is dropped when its
statement ends.

**Inclusive ranges.** A range excludes its end, and there is no `..=`:

```rig reject
sub main()
  for i in 0..=3
    print(i)
```

```error
a range excludes its end: `..=3` is written `..4`
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
`Box(v)`, `Vec`, and owned closures are the only things that allocate
(besides the runtime's list of the program's arguments), and the
compiler frees them.

## What Rig does not have

You will reach for these and not find them:

- **traits and bounds**: a generic body may do with `T` only what each
  instance supports;
- **string interpolation**: text is built with `Text(...)` and
  `!t.add(...)`, which write values as `print` does;
- **concurrency and async**;
- **a large standard library**: beyond `print`, `Cell`, `Vec`, `Box`,
  `Text`, `Signal`, and the slice methods (`copy`, `fill`, `swap`, `read`,
  `write`), [the standard library](docs/STD.md) has only `std.math`,
  `std.os`, `std.time`, `std.random`, `std.sort`, `std.slices`, and
  `std.text` so far;
- **raw pointers**;
- **macros**, which Rig does not plan to have.

[SPEC §18](SPEC.md#18-reserved-and-unsupported-forms) lists every form
the compiler rejects as reserved or not supported yet, and the
[roadmap](docs/ROADMAP.md) lists the plans.

## Where to go next

- [SYNTAX.md](SYNTAX.md): how every form is written
- [SPEC.md](SPEC.md): what every form means, and the rules the compiler
  enforces
- [docs/STD.md](docs/STD.md): the standard library, imported with
  `use std.NAME`
- [examples/](examples/README.md): complete programs
- [docs/DESIGN.md](docs/DESIGN.md): why Rig is the way it is
- [FAQ.md](FAQ.md): common questions
