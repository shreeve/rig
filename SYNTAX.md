# Rig Syntax: A Guide for Zig and Rust Programmers

Rig is a systems language with Python's layout, Zig's cost model, and
Rust's ownership rules, compiled to Zig. This guide teaches its syntax
to a programmer who already knows Zig and Rust: a short tour first, then
every construct in order, each with an example, and cheat sheets at the
end.

Every `rig` example here is compiled and run by the test suite. A
program followed by an `output` block prints exactly that, with no
leaks; a program marked as rejected fails with the error shown. The
normative rules live in the [language reference](SPEC.md); this guide
links to it rather than repeating every rule.

## Contents

**Part I: Tour**

1. [The shape of Rig](#1-the-shape-of-rig)
2. [Five small programs](#2-five-small-programs)
3. [Rust and Zig to Rig at a glance](#3-rust-and-zig-to-rig-at-a-glance)

**Part II: Reference**

4. [Source files and layout](#4-source-files-and-layout)
5. [The spacing rule](#5-the-spacing-rule)
6. [Names, keywords, and literals](#6-names-keywords-and-literals)
7. [Types](#7-types)
8. [Bindings and assignment](#8-bindings-and-assignment)
9. [Functions and calls](#9-functions-and-calls)
10. [Operators](#10-operators)
11. [Control flow](#11-control-flow)
12. [Structs and methods](#12-structs-and-methods)
13. [Enums, error sets, generics, and aliases](#13-enums-error-sets-generics-and-aliases)
14. [Ownership: the sigils](#14-ownership-the-sigils)
15. [Drop](#15-drop)
16. [Shared and weak handles](#16-shared-and-weak-handles)
17. [Cell, Vec, and Signal](#17-cell-vec-and-signal)
18. [Closures](#18-closures)
19. [Optionals](#19-optionals)
20. [Errors](#20-errors)
21. [Arrays, strings, and slices](#21-arrays-strings-and-slices)
22. [Modules and constants](#22-modules-and-constants)
23. [raw, extern, and builtins](#23-raw-extern-and-builtins)
24. [Compile-time parameters](#24-compile-time-parameters)
25. [Tests](#25-tests)
26. [Printing](#26-printing)
27. [What Rig does not have (yet)](#27-what-rig-does-not-have-yet)

**Appendices**

- [A. Sigil and operator cheat sheet](#a-sigil-and-operator-cheat-sheet)
- [B. How Rig lowers to Zig](#b-how-rig-lowers-to-zig)
- [C. Grammar summary](#c-grammar-summary)
- [D. Habits to unlearn](#d-habits-to-unlearn)

---

# Part I: Tour

## 1. The shape of Rig

A Rig file is a list of declarations. Blocks are indented, with no
braces and no semicolons. Most lines carry no annotations at all:
types are inferred, and a binding is `name = value`.

What Rig adds to that plain surface is a small set of one-character
**sigils** that mark every ownership effect where it happens:

| Sigil | Meaning | Rust | Zig |
|---|---|---|---|
| `<x` | move `x` | `x` (implicit move) | copy, then stop using `x` |
| `?x` | read borrow | `&x` | `x` or `&x` |
| `!x` | write borrow | `&mut x` | `&x` |
| `+x` | clone (a new owner) | `x.clone()`, `Rc::clone(&x)` | copy, or a manual refcount bump |
| `-x` | drop now | `drop(x)` | `x.deinit()` |
| `*x` | move into a shared box | `Rc::new(x)` | a hand-written refcounted box |
| `~x` | weak handle | `Rc::downgrade(&x)` | a hand-written weak count |
| `e!` | propagate failure | `e?` | `try e` |
| `e?` | propagate `none` | `e?` on an `Option` | `e orelse return null` |

The same characters prefix types: `?T` and `!T` are borrowed types,
`*T` a shared handle, `~T` a weak one. As suffixes, `T?` is an optional
and `T!` a fallible `T`. Suffix `?` and `!` always mean absence and
failure; prefix `?` and `!` always mean borrowing, so `!` is never
"not" (that is `not`). Before a method call, `!` and `<` mark the
receiver: `!v.push(x)` write-borrows `v` for `push`
([§12](#receiver-sigils-vpushx-and-pclose)).

The compiler checks every sigil: no use after move, no double free, no
dangling borrow, no leak (except a cycle of strong handles, as in Rust).
There is no garbage collector and no hidden allocation. Then it writes
Zig, and Zig does the optimizing, code generation, and linking.

```bash
bin/rig run hello.rig        # check, build, and run (Debug, leak-checked)
bin/rig build -o hello hello.rig
bin/rig emit hello.rig       # print the Zig it generates
```

## 2. Five small programs

### Hello

```rig
sub main
  print("hello, rig")
```

```output
hello, rig
```

`sub` declares a function that returns nothing; `fun` declares one
that returns a value. `print` takes any number of values.

### Structs, methods, and borrows

```rig
struct Account
  owner: String
  balance: Int

  fun can_pay(?self, amount: Int) -> Bool
    self.balance >= amount

  sub pay(!self, amount: Int)
    self.balance -= amount

sub main
  a = Account(owner: "ada", balance: 100)
  if a.can_pay(30)
    !a.pay(30)
  print(a.owner, a.balance)
```

```output
ada 70
```

`?self` reads the receiver and `!self` writes it. The call site says the
same: reading is implicit (`a.can_pay(30)`), but writing is always
spelled out, `!a.pay(30)`. A reader sees every mutation.

### Moves, clones, and drops

```rig
struct File
  name: String

  drop self: !File
    print("closing", self.name)

sub archive(f: File)
  print("archiving", f.name)

sub main
  log = File(name: "log.txt")
  archive(<log)
  cfg = *File(name: "cfg.toml")
  cfg2 = +cfg
  -cfg
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
makes a second owner, `-cfg` drops the first now, and the box closes
when `cfg2` goes out of scope.

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

sub main
  print(parse_len("four")!, parse_len("") catch -1)
  print(first_even(?[1, 3, 4, 5]) ?? 0)
```

```output
4 -1
4
```

`Int!` may fail, and every call says what happens to the failure: `!`
propagates it, `catch` handles it. `Int?` may be `none`, and `??`
supplies a fallback.

### Closures

```rig
sub main
  count: *Cell(Int) = *Cell(value: 0)
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
would move, `~x` would hold a handle weakly.

## 3. Rust and Zig to Rig at a glance

| Idea | Rust | Zig | Rig |
|---|---|---|---|
| immutable binding | `let x = 1;` | `const x = 1;` | `x = 1` (fixed: `x =! 1`) |
| mutable binding | `let mut x = 1;` | `var x: i64 = 1;` | `x = 1`, then `x = 2` |
| typed binding | `let x: u8 = 1;` | `const x: u8 = 1;` | `x: U8 = 1` |
| shadowing | `let x = x + 1;` | not allowed | `new x = x + 1` |
| function | `fn f(a: i64) -> i64 { a }` | `fn f(a: i64) i64 { return a; }` | `fun f(a: Int) -> Int` / `  a` |
| no return value | `fn f() {}` | `fn f() void {}` | `sub f` |
| struct literal | `P { x: 1 }` | `P{ .x = 1 }` | `P(x: 1)` |
| method receiver | `&self`, `&mut self`, `self` | `self: P`, `self: *P` | `?self`, `!self`, `self: Self` |
| mutating call | `v.push(x)` | `try v.append(gpa, x)` | `!v.push(x)` |
| enum variant | `Shape::Circle { r: 2 }` | `.{ .circle = .{ .r = 2 } }` | `.circle(r: 2)` |
| match | `match x { A => .., _ => .. }` | `switch (x) { .a => .., else => .. }` | `match x` / `.a => ..` / `_ => ..` |
| optional | `Option<T>`, `None` | `?T`, `null` | `T?`, `none` |
| unwrap or | `x.unwrap_or(0)` | `x orelse 0` | `x ?? 0` |
| if let | `if let Some(v) = x` | `if (x) \|v\|` | `if x as v` |
| fallible | `Result<T, E>` | `E!T` | `T!` |
| propagate | `f()?` | `try f()` | `f()!` |
| handle | `f().unwrap_or(0)` | `f() catch 0` | `f() catch 0` |
| borrow | `&x`, `&mut x` | `&x` | `?x`, `!x` |
| reference count | `Rc::new(x)`, `Rc::clone(&r)` | by hand | `*x`, `+r` |
| weak | `Rc::downgrade(&r)`, `w.upgrade()` | by hand | `~r`, `w.upgrade()` |
| interior mutability | `RefCell<T>` / `Cell<T>` | by hand | `Cell(T)` |
| growable array | `Vec<T>` | `std.ArrayList(T)` | `Vec(T)` |
| closure | `move \|a\| a + n` | a struct with a method | `\|+n, a\| a + n` |
| drop early | `drop(x)` | `x.deinit()` | `-x` |
| destructor | `impl Drop` | `deinit` + `defer` | `drop self: !Self` |
| cleanup | scope guard | `defer`, `errdefer` | `defer`, `errdefer` |
| generic type | `struct Box<T>` | `fn Box(comptime T: type) type` | `type Box(T)` |
| compile-time param | const generics | `comptime n: i64` | `pre n: Int` |
| unsafe | `unsafe { }` | (everything) | `raw` block |
| logical ops | `&&`, `\|\|`, `!` | `and`, `or`, `!` | `and`, `or`, `not` |
| ternary | `if c { a } else { b }` | `if (c) a else b` | `a if c else b` |

---

# Part II: Reference

## 4. Source files and layout

A source file is UTF-8 and its name ends in `.rig`. A program that runs
declares `sub main`.

**Comments** run from `#` to the end of the line. There are no block
comments and no doc-comment syntax.

**Indentation** makes blocks. A deeper line opens a block and a return
to an enclosing column closes it. Use spaces; a tab in indentation is an
error. Anything that takes a block (`if`, `while`, `for`, `match`, a
function, a struct) takes the indented lines after it.

**Line joining.** Inside `( )` and `[ ]`, a newline is plain whitespace,
so a call or array can span lines at any indentation. A trailing `\`
joins the next line anywhere. Lists may end with a comma: arrays, call
arguments, parameter lists, closure bar lists, and pattern bindings.

```rig
fun volume(
  w: Int,
  h: Int,
  d: Int,
) -> Int
  w * h * d

sub main
  v = volume(
    2,
    3,
    4,
  )
  total = v + \
    1
  print(v, total, [
    1,
    2,
  ])
```

```output
24 25 [1, 2]
```

**Statements** are one per line. A statement is an expression, a
binding, or a control-flow form. There is no `;`.

## 5. The spacing rule

The characters `<` `+` `-` `*` `?` `!` `~` are both operators and
prefix sigils, and `(`, `[`, `.` both continue a value and start a new
one. One rule decides every case:

> A character that touches its operand and not the value before it is a
> prefix. Otherwise it is an infix operator, or it continues the value
> before it.

| Source | Means |
|---|---|
| `a < b`, `a<b` | comparison |
| `f <x` | `f(<x)`: call `f` with `x` moved |
| `a - b`, `a-b` | subtraction |
| `f -x` | `f(-x)` |
| `a * b` | multiplication |
| `f *x` | `f(*x)`: call `f` with `x` shared |
| `f(x)`, `a[i]`, `a.b` | call, index, member access |
| `f (x)`, `f [1, 2]`, `f .red` | a paren-free call whose argument is `(x)`, `[1, 2]`, `.red` |
| `T?`, `T!`, `e!`, `e?` | suffixes: optional, fallible, propagate |
| `-x` alone on a line | drop `x` (negation where the line's value is used) |

```rig
fun twice(n: Int) -> Int
  n * 2

sub main
  a = 5
  b = 3
  c = twice -b
  print(a - b, a-b, c, twice(a) - b)
```

```output
2 2 -6 7
```

The rule is uniform, so it has one edge to know: `a -1` calls `a` with
`-1`. Write `a - 1`.

```rig reject
sub main
  a = 5
  b = a -1
```

```error
`a` has type `Int` and cannot be called
```

Two values may not touch with nothing between them (`t.5`, `print"x"`),
and `=!` / `<-` may not touch the operand after them (`x =!y`), since
each could be read two ways.

## 6. Names, keywords, and literals

**Names** are ASCII: a letter or `_`, then letters, digits, and `_`.
Types are conventionally `CamelCase`, everything else `snake_case`. `_`
alone discards: `_ = f()`, or an ignored parameter.

**Keywords** are all reserved:

```text
and  as  break  catch  continue  defer  drop  else  enum  errdefer
error  extern  false  for  fun  if  in  match  not  or  pre  pub  raw
return  struct  sub  test  true  try  type  use  while  zig
```

A keyword may still name a member, wherever the position makes that
clear: a field or method (`type: Int`, `fun error(?self)`), a member
access (`t.type`), or a keyword argument (`Token(type: 1)`). `new` is a
keyword only at the start of a statement. `none` is reserved for the
absent optional.

```rig
struct Token
  type: Int
  in: Bool

  fun error(?self) -> Bool
    self.type < 0

sub main
  t = Token(type: -1, in: true)
  print(t.type, t.in, t.error())
```

```output
-1 true true
```

Zig's `var`, `fn`, and `const` are ordinary names in Rig.

**Literals:**

| Kind | Examples |
|---|---|
| integer | `42`, `1_000_000`, `0xff`, `0b1010`, `0o17` |
| float | `3.14`, `.5`, `1e10`, `2.5e-3` |
| string | `"escapes: \t \n \x41 \u{e9}"`, `'raw: no escapes, '' is a quote'` |
| bool | `true`, `false` |
| absent | `none` |
| array | `[1, 2, 3]` |
| enum variant | `.red`, `.circle(r: 2)` |

Radix prefixes are lowercase, a decimal has no leading zero, and a
literal has no type suffix: its type comes from context. A string holds
no raw control characters; write `\t` and `\n`. There is no string
interpolation; `print` takes several values.

```rig
sub main
  print(0xff, 0b101, 0o17, 1_000, .5, 1e3)
  print("tab\there", 'it''s raw: \n')
```

```output
255 5 15 1000 0.5 1000.0
tab	here it's raw: \n
```

## 7. Types

### Primitives

| Rig | Zig | Rust |
|---|---|---|
| `Int` (= `I64`) | `i64` | `i64` |
| `I8` `I16` `I32` `I64` | `i8` ... `i64` | `i8` ... `i64` |
| `U8` `U16` `U32` `U64` | `u8` ... `u64` | `u8` ... `u64` |
| `Float` (= `F64`), `F32` | `f64`, `f32` | `f64`, `f32` |
| `Bool` | `bool` | `bool` |
| `String` | `[]const u8` | `&'static str` |
| `Void` | `void` | `()` |

There are no implicit numeric conversions. A literal adapts to the type
its context expects and must fit it. Convert explicitly by calling the
type: `I32(x)`, `Float(n)`, `Int(f)`. A conversion is checked: a value
that does not fit panics (a constant one is rejected at compile time).

```rig
sub main
  small: U8 = 200
  sum = small + 55
  avg = Float(7) / Float(2)
  print(sum, avg, Int(-7.9), U8(sum - 100))
```

```output
255 3.5 -7 155
```

```rig reject
sub main
  a: I32 = 1
  b: Int = 2
  print(a + b)
```

```error
operands have different types `I32` and `Int`
```

### Type constructors

| Type | Meaning | Rust | Zig |
|---|---|---|---|
| `T?` | optional | `Option<T>` | `?T` |
| `T!` | fallible (return types only) | `Result<T, E>` | `anyerror!T` |
| `?T` | read borrow | `&T` | `T` or `*const T` |
| `!T` | write borrow | `&mut T` | `*T` |
| `*T` | shared handle | `Rc<T>` | `*RcBox(T)` |
| `~T` | weak handle | `Weak<T>` | a weak reference |
| `[N]T` | fixed array | `[T; N]` | `[N]T` |
| `[]T` | read-only slice | `&[T]` | `[]const T` |
| `fun(A, B) -> R`, `sub(A)` | function or stack closure | `fn(A, B) -> R`, `impl Fn` | `*const fn (A, B) R` |
| `*fun(A) -> R`, `*sub(A)` | owned closure | `Rc<dyn Fn(A) -> R>` | a boxed closure |
| `Cell(T)`, `Vec(T)`, `Signal(T)` | built-in generics | `RefCell<T>`, `Vec<T>` | runtime types |
| `Name(T)` | generic instance | `Name<T>` | `Name(T)` |
| `mod.Name` | imported type | `mod::Name` | `mod.Name` |

Suffixes bind tighter than prefixes: `*User?` is a shared handle to an
optional `User`, and an optional shared handle is `(*User)?`. Prefixes
compose right to left: `?*Node` is a read borrow of a shared handle.

### Copy and owning values

A **Copy** value is plain data: numbers, `Bool`, `String`, plain enums,
and arrays and structs of Copy values. Using one copies it, as in Zig.

An **owning** value holds something that must be released exactly once:
a `*T` or `~T` handle, a `Vec`, a `Signal`, an owned closure, or any
struct, enum, or generic instance that holds one or declares a `drop`
body. Owning values move instead of copying, like Rust's non-`Copy`
types, and the compiler generates their release code (their **drop
glue**).

## 8. Bindings and assignment

| Form | Meaning |
|---|---|
| `x = e` | declare `x`, or assign the visible `x` |
| `x: T = e` | declare with a type |
| `x =! e`, `x: T =! e` | declare a fixed `x`, which cannot be reassigned |
| `new x = e` | declare a new `x` shadowing the old one; `e` may read the old |
| `x <- y` | move-assign, the same as `x = <y` |
| `x += e`, and `-=` `*=` `/=` `%=` `&=` `\|=` `^=` `<<=` `>>=` | compound assignment |
| `p.f = e`, `xs[i] = e` | assign a field or an element |
| `_ = e` | evaluate and discard; an owning value is dropped now |

There is no `let`, `var`, or `const`. The first `x = e` in a scope
declares `x`, and later ones assign it. `x =! e` reads as "set,
dammit!": this value, final. The compiler emits a Zig
`const` unless the binding is reassigned or written through.

```rig
sub main
  x = 1
  x = x + 1
  limit =! 10
  new x = "now a string"
  total = 0
  total += limit
  print(x, total)
```

```output
now a string 10
```

**No implicit shadowing.** A local may not reuse a visible name; `new`
says the shadowing is intended. That also rules out a local that
accidentally shares a name with a module-level function:

```rig reject
fun total -> Int
  0

sub main
  total = 5
```

```error
local `total` has the same name as the module-level declaration `total`
```

**No unread locals.** Because `=` both declares and assigns, a typo
would silently declare a new variable. So a local that is never read is
an error, as in Zig; discard a value on purpose with `_ = e`. A value
with drop glue counts as used by its own release, so a guard that exists
only to be released at the end of the block is fine.

```rig reject
sub main
  total = 0
  totl = 5
  print(total)
```

```error
`totl` is assigned but never read
```

Parameters, loop variables, and names bound by patterns and `as` are
immutable.

## 9. Functions and calls

### Declaring

```rig
fun area(w: Int, h: Int) -> Int
  w * h

fun sign(n: Int) -> Int
  return 1 if n > 0 else -1 if n < 0 else 0

sub report(label: String, n: Int)
  print(label, n)

sub main
  report("area", area(3, 4))
  report("sign", sign(-7))
```

```output
area 12
sign -1
```

- `fun name(params) -> R` returns an `R`; `sub name(params)` returns
  nothing. A `sub` is Rust's `fn` with no `->` and Zig's `fn ... void`.
- The body's last expression is its value, as in Rust. `return e`
  leaves early.
- Declarations live only at module level: there are no nested
  functions. Use a closure.
- A function with no parameters may drop the empty `()`: `sub main` is
  the same as `sub main()`, and this guide writes the shorter one.
- A name alone never runs code; parentheses or arguments always do.
  `greet` is the function itself, a value; `greet()`, `greet(1)`, and
  the paren-free `greet 1` call it. That is why a paren-free call needs
  at least one argument.

**Every statement must have some use.** A value that is returned,
bound, or passed may be anything, but one that would be thrown away must
come from something that does work: a call, a propagation (`e!`, `e?`),
or a `catch`. A lone name, literal, or field read has no logical use and
is an error, and a lone function name is taken for a forgotten call:

```rig
sub greet
  print("hi")

fun pick -> sub()
  greet

sub main
  greet()
  say = pick()
  say()
```

```output
hi
hi
```

```rig reject
sub greet
  print("hi")

sub main
  greet
```

```error
`greet` is a function; call it with `greet()`
```

### Parameters

A parameter may have a literal default. A call passes its arguments:

- by position, in parameter order: `scaled(3, 2)`;
- by keyword, in any order: `scaled(by: 4, n: 5)`;
- mixed, positional arguments first and then keywords:
  `scaled(3, by: 2)`;
- leaving out parameters that have defaults: `scaled(3)`.

Each parameter gets one argument, and every parameter without a default
needs one. Arguments are evaluated in the order written. A parameter
the body ignores may be named `_`.

```rig
fun scaled(n: Int, by: Int = 10, _: Bool = false) -> Int
  n * by

sub main
  print(scaled(3, 2), scaled(by: 4, n: 5), scaled(3, by: 2), scaled(3))
```

```output
6 20 6 30
```

```rig reject
fun scaled(n: Int, by: Int = 10) -> Int
  n * by

sub main
  print(scaled(n: 3, 2))
```

```error
positional arguments must come before keyword arguments
```

A parameter's type says how it receives its argument, and the call site
repeats it:

| Parameter | Call | Receives |
|---|---|---|
| `x: T` (Copy `T`) | `f(x)` | a copy |
| `x: T` (owning `T`) | `f(<x)` | ownership |
| `x: ?T` | `f(?x)` | a read borrow |
| `x: !T` | `f(!x)` | a write borrow; `x = v` writes the caller's value |

### Calling without parentheses

A call may drop its parentheses when it ends a statement: a line, the
value of a binding, or a `return`. A paren-free call takes the rest of
the line as its arguments, and its last argument may itself be a
paren-free call. Inside `( )`, every argument is an ordinary
expression, so a call there keeps its parentheses.

```rig
fun add(a: Int, b: Int) -> Int
  a + b

sub main
  print add 1, 2
  print add(1, 2), add 3, 4
  print (1 + 2) * 3
```

```output
3
3 7
9
```

`print (1 + 2) * 3` is a paren-free call whose argument is
`(1 + 2) * 3`, by the spacing rule: `(` does not touch `print`.

```rig reject
fun twice(n: Int) -> Int
  n * 2

sub main
  print(1, twice -3, 5)
```

```error
a call inside parentheses needs its own parentheses
```

### Function values

A function name is a value of a function type, and so is a method named
through its type, whose first parameter is the receiver:

```rig
fun twice(n: Int) -> Int
  n * 2

fun apply(f: fun(Int) -> Int, x: Int) -> Int
  f(x)

struct Counter
  n: Int

  sub bump(!self)
    self.n += 1

sub main
  g = twice
  print(apply(g, 5), apply(twice, 1))
  c = Counter(n: 0)
  bump = Counter.bump
  bump(!c)
  bump(!c)
  print(c.n)
```

```output
10 2
2
```

A function type writes its result after `->`, like the declaration it
describes: `twice` has type `fun(Int) -> Int`. `sub(Int)` returns
nothing.

## 10. Operators

From lowest to highest precedence:

| Operators | Notes |
|---|---|
| `a if c else b`, `e catch f` | ternary; error fallback |
| `or` | short-circuit |
| `and` | short-circuit |
| `not` | |
| `==` `!=` `<` `>` `<=` `>=` | not chainable |
| `??` | optional fallback, right-associative |
| `..` | half-open range, for `for` and patterns |
| `\|` | bitwise or |
| `^` | bitwise xor |
| `&` | bitwise and |
| `<<` `>>` | shifts |
| `+` `-` | |
| `*` `/` `%` | |
| `-x` and the sigils | prefix |
| `f(x)` `a[i]` `a.b` `e!` `e?` | postfix |

- `and`, `or`, `not` take `Bool`. `not` binds looser than comparison,
  so `not a == b` is `not (a == b)`. `&&` and `||` are rejected with a
  hint.
- Prefix `!` is a write borrow, never "not". Wherever `!x` would be
  read as a `Bool` (a condition, an operand, a binding, an argument),
  it is rejected: ``!` is a write borrow; use `not` for negation``.
  The only `!flag` is one passed where a `!Bool` is expected. A `!`
  before a method call marks the receiver ([§12](#12-structs-and-methods)),
  and is rejected too when the method only reads it (`!q.is_empty()`).
- Postfixes bind tighter than prefixes: `-a.len` is `-(a.len)`. The
  one exception is `!` or `<` before a method call, which applies to
  the receiver: `!v.push(x)` is `(!v).push(x)`.
- Arithmetic needs one numeric type on both sides. Integer `/`
  truncates toward zero and `%` takes the dividend's sign, like Zig's
  `@divTrunc` and `@rem`. Overflow panics in Debug and `--release`
  builds.
- Integer literals in float arithmetic are floats: `h: Float = 7 / 2`
  is `3.5`.
- `==` works on numbers, `Bool`, `String` (by content), enums, and
  optionals of those. Structs have no `==`.
- There is no `**`; there is no `++` or `--`.

```rig
sub main
  a = 7
  print(-7 / 2, -7 % 2, a & 3, a | 8, a ^ 1, a << 2, a >> 1)
  print(not a == 3, a > 3 and a < 10, false or true)
  h: Float = 7 / 2
  print(h, "ab" == "ab", 1 if a > 5 else 2)
```

```output
-3 -1 3 15 6 28 3
true true true
3.5 true 1
```

```rig reject
sub main
  done = false
  while !done
    done = true
```

```error
`!` is a write borrow; use `not` for negation
```

## 11. Control flow

### if

`if` takes a `Bool` condition and an indented block. `else if` chains.
When its value is used, `if` is an expression, and every branch must
yield one type.

```rig
fun classify(x: Int) -> String
  if x > 0
    "positive"
  else if x < 0
    "negative"
  else
    "zero"

sub main
  n = 5
  label = if n > 3
    doubled = n * 2
    doubled + 1
  else
    0
  print(classify(-2), label, "big" if n > 3 else "small")
```

```output
negative 11 big
```

The one-line form is Python's `a if c else b`, not C's `c ? a : b`.

### Guards

Any simple statement (a call, binding, `return`, `break`, `continue`)
may end with `if cond`, and then runs only when `cond` holds. This is
Ruby's statement modifier.

```rig
fun first_over(limit: Int) -> Int
  i = 0
  while true
    i += 1
    return i if i > limit

sub main
  x = 5
  print("big") if x > 3
  print(first_over(3))
```

```output
big
4
```

### while

```rig
sub main
  i = 0
  while i < 5 : i += 1
    continue if i == 1
    break if i == 4
    print(i)
  else
    print("never: the loop broke")
  n = 3
  while n > 0
    n -= 1
  else
    print("done")
```

```output
0
2
3
done
```

- `while cond : step` runs `step` after each iteration, like Zig's
  `while (c) : (step)`. The step is an assignment or a call.
- `else` runs when the loop ends without `break`, like Zig's
  `while ... else`.
- `while e as x` loops while the optional `e` has a value
  ([§19](#19-optionals)).

### for

`for x in source` walks a range `a..b`, an array, a slice, a `Vec`, or a
`String` (its bytes). `for x, i in xs` also binds the index. A range is
half-open: `0..3` is 0, 1, 2.

```rig
sub main
  total = 0
  for i in 0..5
    total += i
  for c, i in ["a", "b"]
    print(i, c)
  print(total)
  xs = [1, 2, 3]
  for x in !xs
    x *= 10
  print(xs)
```

```output
0 a
1 b
10
[10, 20, 30]
```

A sigil on the source says how the loop holds it, and the same sigils
mean the same thing everywhere:

| Loop | Element |
|---|---|
| `for x in xs` | a copy (Copy elements) |
| `for x in ?v` | a read borrow of each slot (owning elements) |
| `for x in !xs` | a write borrow: assigning `x` writes the element |
| `for x in <v` | ownership of each element; `v` is consumed |

### Labels, break, continue

Label a loop with `:name` and name it from an inner loop. A `match` or
`raw` statement may be labeled too, and `break :name` leaves it.

```rig
sub main
  :outer for i in 0..3
    for j in 0..3
      continue :outer if j > i
      break :outer if i == 2
      print(i, j)
```

```output
0 0
1 0
1 1
```

### Loops as values

A loop that `break`s with a value is an expression. It needs an `else`
value for the case where it ends without breaking (`while true` needs
none). This is Zig's loop-with-`else` expression.

```rig
fun index_of(xs: ?[4]Int, target: Int) -> Int
  for x, i in xs
    break i if x == target
  else
    -1

sub main
  xs = [3, 1, 4, 1]
  print(index_of(?xs, 4), index_of(?xs, 9))
  n = 27
  steps = 0
  last = while true
    break steps if n == 1
    n = n / 2 if n % 2 == 0 else 3 * n + 1
    steps += 1
  print(last)
```

```output
2 -1
111
```

### match

`match` works on enums, integers, and `Bool`. An arm is
`pattern => statement` or a pattern followed by an indented block. The
first matching arm runs; there is no fallthrough.

| Pattern | Matches |
|---|---|
| `.name` | an enum variant |
| `.name(a, b)` | a payload variant, binding its fields in order |
| `42`, `-1`, `true` | a literal |
| `lo..hi` | an integer in `lo` up to, not including, `hi` |
| `_` | everything else |
| a name | everything else, bound to that name |

A `match` whose value is used must be exhaustive; a statement `match`
need not be. Duplicate and unreachable arms are errors.

```rig
enum Shape
  circle(r: Int)
  rect(w: Int, h: Int)
  point

fun area(s: ?Shape) -> Int
  match s
    .circle(r) => 3 * r * r
    .rect(w, h) => w * h
    .point => 0

fun size(n: U8) -> String
  match n
    0..10 => "small"
    10..100 => "medium"
    100..256 => "large"

sub main
  print(area(?Shape.rect(w: 2, h: 5)), size(42))
  match 7
    1 => print("one")
    other
      print("got", other)
```

```output
10 medium
got 7
```

### defer and errdefer

`defer` runs a statement or block when its enclosing block exits, in
reverse order, exactly as in Zig. `errdefer` runs only when the function
fails. Deferred code may not move or drop outer values or propagate.

```rig
sub main
  defer print("cleanup 1")
  defer
    print("cleanup 2")
  print("body")
```

```output
body
cleanup 2
cleanup 1
```

## 12. Structs and methods

A `struct` lists fields, then methods. Construct it by naming every
field that has no default: `Point(x: 1, y: 2)`. A field default is a
literal.

```rig
struct Point
  x: Int
  y: Int = 0

  fun origin -> Self
    Point(x: 0)

  fun length2(?self) -> Int
    self.x * self.x + self.y * self.y

  fun plus(?self, other: ?Point) -> Point
    Point(x: self.x + other.x, y: self.y + other.y)

  sub shift(!self, dx: Int)
    self.x += dx

sub main
  p = Point.origin()
  q = Point(x: 3, y: 4)
  r = p.plus(?q)
  !r.shift(10)
  print(r, q.length2())
```

```output
Point(x: 13, y: 4) 25
```

| Receiver | Rust | Meaning | Call |
|---|---|---|---|
| `?self` | `&self` | reads | `p.m()`: the read borrow is implicit |
| `!self` | `&mut self` | writes | `!p.m()` |
| `self: Self` | `self` | consumes | `<p.m()`, or on a temporary |
| (none) | associated fn | | `Point.origin()` |

`Self` names the enclosing type. Inside a `!self` method, `self.f = v`
and `self = v` write the caller's value. A binding that already holds a
write borrow (a `!T` parameter, or `self` in a `!self` method) calls
writing methods directly, `self.bump()`, because the borrow it holds is
what it lends.

### Receiver sigils: `!v.push(x)` and `<p.close()`

`!` or `<` directly before a place (a name, then any `.field` or
`[index]` steps) that a method call follows applies to that place, the
method's receiver; anything after the call applies to its result.

| Long form | Short form | Meaning |
|---|---|---|
| `(!v).push(x)` | `!v.push(x)` | write-borrow `v`, then push |
| `(!self.items).push(k)` | `!self.items.push(k)` | a field of `self` in a `!self` method |
| `(!grid[r]).bump()` | `!grid[r].bump()` | an element, changed in place |
| `while (!q).pop() as j` | `while !q.pop() as j` | the loop binds what `pop` returns |
| `(<conn).close()` | `<conn.close()` | move `conn` into `close` |

Only `!` and `<` reach the receiver, because they are exactly the
receiver modes a method declares (`!self`, `self: Self`), and on a
call's result they would mean nothing: a result is already a
temporary the caller owns. The other sigils keep their meaning on the
whole expression:

- `*Point.origin()` shares the new `Point` in a handle.
- `+n.first()` clones the handle `first` returns.
- `-a.len` negates the length.
- `!x.v` with no call after it borrows the field `x.v`, as for a
  `v: !Vec(Int)` parameter.

The long form stays valid everywhere, and parentheses around the call
keep their meaning: `!(v.pop())` borrows the result (and is rejected,
since a temporary cannot be write-borrowed).

```rig
struct Stack
  items: Vec(Int)

  sub push(!self, k: Int)
    !self.items.push(k)

  fun pop(!self) -> Int?
    !self.items.pop()

  fun total(self: Self) -> Int
    sum = 0
    for k in ?self.items
      sum += k
    sum

sub main
  s = Stack(items: Vec())
  !s.push(1)
  !s.push 2
  !s.items.push(3)
  print(!s.pop() ?? 0)
  print(<s.total())
```

```output
3
3
```

Three mistakes this rules out, each a compile error. `!` on a `Bool`
is never negation:

```rig reject
sub main
  ready = true
  if !ready
    print("waiting")
```

```error
`!` is a write borrow; use `not` for negation
```

`!` before a method that only reads its receiver (`?self`) is the
same habit:

```rig reject
struct Queue
  items: Vec(Int)

  fun is_empty(?self) -> Bool
    self.items.len == 0

sub main
  q = Queue(items: Vec())
  if !q.is_empty()
    print("items")
```

```error
`is_empty` does not write its receiver; for negation use `not`
```

And a write-borrowing call whose value is a `Bool` takes the long form,
so `!set.insert(k)` can never be read as "not inserted":

```rig reject
struct Set
  items: Vec(Int)

  fun insert(!self, k: Int) -> Bool
    for x in ?self.items
      return false if x == k
    !self.items.push(k)
    true

sub main
  set = Set(items: Vec())
  if !set.insert(1)
    print("new")
```

```error
a write-borrowing call that returns `Bool` is written `(!set).insert(...)`, so it is never read as negation
```

```rig
struct Set
  items: Vec(Int)

  fun insert(!self, k: Int) -> Bool
    for x in ?self.items
      return false if x == k
    !self.items.push(k)
    true

sub main
  set = Set(items: Vec())
  if (!set).insert(1)
    print("new")
  if not (!set).insert(1)
    print("seen")
```

```output
new
seen
```

For Zig, Rust, and C readers: in Rig, `!` never means "not"; `not`
does, and every place where the habit would change a program's meaning
is a compile error.

**Fields read data; methods run code.** `x.name` without parentheses
reads stored data and never runs code; `x.name()` is a call. Rig has no
properties or getters. So `xs.len` (an array's, string's, slice's, or
`Vec`'s length) is a field read, and anything that computes is a method.
The cost of that honesty: a stored field cannot later become a computed
one without every `p.x` becoming `p.x()`, so a value that might ever be
computed should be a method from the start. Fields are public wherever
their struct is; private fields are on the
[roadmap](docs/ROADMAP.md).

```rig reject
struct Counter
  n: Int

  sub bump(!self)
    self.n += 1

sub main
  c = Counter(n: 0)
  c.bump()
```

```error
method `bump` requires a write-borrowed receiver
```

## 13. Enums, error sets, generics, and aliases

### Enums

An `enum` lists variants, which may carry payload fields or explicit
integer values, and may have methods. Write a variant as `.name` where
its type is known from context, or `Type.name`.

```rig
enum Status
  ok = 200
  missing = 404

enum Shape
  circle(radius: Int)
  rect(w: Int, h: Int)

  fun area(?self) -> Int
    match self
      .circle(r) => 3 * r * r
      .rect(w, h) => w * h

sub main
  s: Shape = .rect(w: 2, h: 5)
  c = Shape.circle(radius: 2)
  st: Status = .missing
  print(s.area(), c.area(), s, st == .missing)
```

```output
10 12 .rect(w: 2, h: 5) true
```

A payload variant is built with its fields named, exactly like a struct:
`.circle(radius: 2)`. A pattern binds the fields in order, under names
of your choosing: `.circle(r) =>`. An enum with payloads is Rust's data-carrying enum and
Zig's `union(enum)`.

### Error sets

`error Name` declares a set of error values, used like the variants of
a plain enum and returned from fallible functions ([§20](#20-errors)).

```rig
error NetError
  timeout
  refused

sub main
  e: NetError = .timeout
  print(e, e == NetError.timeout)
```

```output
.timeout true
```

### Generic types

`type Name(T, ...)` declares a generic struct and `enum Name(T, ...)` a
generic enum. Type arguments are inferred from the constructor's values
or named in the type (`Box(Int)`). There are no generic functions yet,
and no traits: a generic body may only do with `T` what every
instantiation allows, which is checked per instance, like Zig's
`comptime T: type`.

```rig
type Pair(T, U)
  first: T
  second: U

  fun left(?self) -> T
    self.first

enum Option(T)
  some(value: T)
  nothing

sub main
  p = Pair(first: 42, second: "answer")
  o: Option(Int) = .some(value: p.left())
  match o
    .some(v) => print(v, p.second)
    .nothing => print("none")
```

```output
42 answer
```

### Aliases

`type Name = T` is a transparent second name for `T`. An alias of a
local struct or enum constructs values and names variants.

```rig
type UserId = Int

struct Point
  x: Int

type P = Point

sub main
  id: UserId = 5
  p = P(x: id)
  print(p.x + 1)
```

```output
6
```

## 14. Ownership: the sigils

Rig's ownership model is Rust's, with two differences a Rust programmer
notices at once: **every transfer is written** (`<x` moves, a bare name
never moves an owning value), and **borrows have no lifetime syntax**
(the checker tracks where every borrow came from instead).

### Move: `<x`

A move passes ownership on. Afterwards `x` is unusable until it is
assigned again. Passing an owning value to a by-value parameter,
storing it, or binding it to another name needs `<`. Only a bare name
returned directly (`return x`, or `x` as a function's last expression)
moves without it.

```rig
struct Packet
  id: Int

  drop self: !Packet
    print("released", self.id)

sub send(p: Packet)
  print("sent", p.id)

fun make(id: Int) -> Packet
  p = Packet(id: id)
  p

sub main
  p = make(1)
  send(<p)
  p = make(2)
  q = <p
  print(q.id)
```

```output
sent 1
released 1
2
released 2
```

```rig reject
struct Packet
  id: Int

  drop self: !Packet
    print("released")

sub send(p: Packet)
  print(p.id)

sub main
  p = Packet(id: 1)
  send(<p)
  print(p.id)
```

```error
use of `p` after move
```

A bare name where an owning value would be copied is an error, because
two owners would release it twice. The fix is always one sigil: `<x` to
move, `+x` to clone a handle.

```rig reject
struct Box
  n: Int

sub main
  a = *Box(n: 1)
  b = a
```

```error
bare use of shared (`*T`) handle `a` in binding would alias the handle
```

For a Copy value `<x` also means "done with `x`": the value is copied
out, and `x` cannot be used until reassigned.

### Borrow: `?x` and `!x`

`?x` lends a read-only view and `!x` an exclusive writable one. The
same prefix on a type (`?T`, `!T`) says a parameter, return value,
local, or field holds such a borrow.

**The aliasing rule** is Rust's: any number of read borrows or one
write borrow, never both. While a read borrow is live the owner cannot
be written, moved, or dropped; while a write borrow is live the owner
cannot be used at all.

```rig
struct Account
  balance: Int

fun balance_of(a: ?Account) -> Int
  a.balance

sub deposit(a: !Account, n: Int)
  a.balance += n

sub main
  acct = Account(balance: 100)
  deposit(!acct, 50)
  r = ?acct
  print(balance_of(r), r.balance)
```

```output
150 150
```

```rig reject
struct User
  name: String

sub main
  u = User(name: "ada")
  r = ?u
  w = !u
  print(r.name)
```

```error
cannot write-borrow `u` while a read borrow is live
```

A borrow lasts until its last use (like Rust's non-lexical lifetimes),
and a borrow passed to a call ends when the call returns.

### Borrows without lifetimes

A borrow can be held by a local, a struct field (a **view**), a
closure, or a function's result, and there is no `'a` to write. The
checker follows each borrow from where it was made:

- A function may return a borrow only of something its caller lent it;
  the result borrows from every borrowed argument.
- A struct holding a borrow keeps the borrowed value borrowed while the
  struct lives.
- A borrow may not outlive what it borrows.

```rig
struct Box
  payload: Int

struct View
  box: ?Box

fun pick(a: ?Box, b: ?Box, first: Bool) -> ?Box
  a if first else b

sub main
  x = Box(payload: 1)
  y = Box(payload: 2)
  r = pick(?x, ?y, false)
  v = View(box: ?x)
  print(r.payload, v.box.payload)
```

```output
2 1
```

```rig reject
struct User
  name: String

fun make -> ?User
  u = User(name: "ada")
  ?u
```

```error
returned borrow of `u` does not originate from a borrowed parameter
```

### Clone: `+x`

`+x` makes a new owner: a refcount bump for a `*T` or `~T` handle, a
copy for a Copy value. A struct with drop glue has no clone; share it
with `*` and clone the handle. `+p.a` clones the handle in a field.

### Drop: `-x`

`-x` as a statement releases `x` now. Every owning value still live is
dropped automatically when its block ends, on every path (early
`return`, `break`, error propagation), in reverse order of
declaration. So `-x` is only for releasing something early, like
Rust's `drop(x)`.

### Share and weak: `*x` and `~x`

`*x` moves a value into a new reference-counted box and `~h` makes a
weak handle to one ([§16](#16-shared-and-weak-handles)).

### Where the sigils appear

The same sigils mean the same thing in every position:

| Position | Read | Write | Move | Clone | Weak |
|---|---|---|---|---|---|
| expression | `?x` | `!x` | `<x` | `+x` | `~x` |
| type | `?T` | `!T` | | | `~T` |
| receiver | `?self` | `!self` | `self: Self` | | |
| method call | `p.m()` | `!p.m()` | `<p.m()` | | |
| `for` source | `for x in ?v` | `for x in !v` | `for x in <v` | | |
| closure capture | | | `\|<x\|` | `\|+x\|` | `\|~x\|` |
| assignment | | | `a <- b` | | |

In a method call the sigil goes on the receiver, `!p.m()` for
`(!p).m()` ([§12](#receiver-sigils-vpushx-and-pclose)); before any
other expression, a sigil applies to all of it: `+n.first()` clones
what `first` returns.

## 15. Drop

A struct may declare one `drop` body, Rust's `impl Drop`. It takes
exactly `self: !Self` and runs when the value is released, before the
value's owning fields are released in reverse order.

```rig
struct Conn
  id: Int

  drop self: !Conn
    print("close", self.id)

struct Pool
  a: *Conn
  b: *Conn

  drop self: !Pool
    print("pool")

sub main
  p = Pool(a: *Conn(id: 1), b: *Conn(id: 2))
  print("built")
```

```output
built
pool
close 2
close 1
```

A drop body may read and assign fields and call `?self` and `!self`
methods. It may not move, drop, or reassign `self` directly. Only
structs have `drop` bodies; enums and generic types get the generated
glue only.

## 16. Shared and weak handles

`*T` is a single-threaded reference-counted handle, like Rust's `Rc<T>`.
`*expr` boxes a value (`*<x` for a named one), `+h` adds an owner, and
the value is released with the last strong handle.

```rig
struct User
  name: String

  drop self: !User
    print("released", self.name)

sub main
  a = *User(name: "ada")
  b = +a
  -a
  print(b.name)
  w = ~b
  -b
  print(w.upgrade() == none)
```

```output
ada
released ada
true
```

Access through a handle is **read-only**: other handles see the same
value. Shared mutable state goes in a `Cell`, so `*Cell(T)` is Rust's
`Rc<RefCell<T>>` without the run-time borrow flag.

```rig reject
struct User
  age: Int

sub main
  u = *User(age: 1)
  u.age = 2
```

```error
cannot assign through shared handle
```

`~h` is a weak handle; `w.upgrade()` returns `(*T)?`, a new strong
handle while the value lives and `none` after. A cycle of strong
handles leaks, as in Rust; break it with a weak handle.

## 17. Cell, Vec, and Signal

These three built-in generic types are the substrate for mutable,
growable, and reactive state.

**`Cell(T)`** holds one value that can be replaced through any path,
including a read borrow or a shared handle: `c.get()` copies it out
(Copy `T`), `c.set(v)` stores, and `c.replace(v)` stores and returns the
old value. These calls need no `!`: a Cell's contents are never lent
out, only replaced, so any holder may change them. That is also why
there is no run-time borrow flag, unlike Rust's `RefCell`.

**`Vec(T)`** is a growable array that owns its elements, like Rust's
`Vec<T>`. Elements are Copy values, plain data, or handles.

| Member | Meaning |
|---|---|
| `Vec()`, `Vec(capacity: n)` | an empty Vec, typed by context |
| `!v.push(x)` | append |
| `!v.pop()` | remove the last element, as `T?` |
| `!v.clear()` | drop every element |
| `v.len` | the number of elements |
| `v[i]`, `v[i] = x`, `v.get(i)` | element access (Copy elements) |

```rig
struct Task
  id: Int

  drop self: !Task
    print("done", self.id)

sub main
  nums: Vec(Int) = Vec()
  !nums.push(3)
  !nums.push(4)
  nums[0] = 30
  print(nums, nums.len)
  tasks: Vec(*Task) = Vec()
  !tasks.push(*Task(id: 1))
  !tasks.push(*Task(id: 2))
  for t in ?tasks
    print("task", t.id)
  while !tasks.pop() as t
    print("popped", t.id)
```

```output
[30, 4] 2
task 1
task 2
popped 2
done 2
popped 1
done 1
```

**`Cell(Vec(T))`** is the shared, growable list. It answers the Vec's own
members through any path to the cell, without `!` (`!c.push(x)` is
rejected), like `set`: `c.push(x)`, `c.pop()`, `c.clear()`, `c.len`, and for Copy elements
`c[i]`, `c.get(i)`, and `c[i] = x`. Each is done at once inside the
runtime, with no user code running while the list is in use (`clear`
empties the cell before it drops the elements), so it is sound without
a borrow flag.

```rig
sub main
  log: *Cell(Vec(Int)) = *Cell(value: Vec())
  other = +log
  log.push(1)
  other.push(2)
  log[0] = 10
  print(log.len, log[0], other.get(1), log.get(9))
  if log.pop() as last
    print("popped", last)
```

```output
2 10 2 none
popped 2
```

For anything else, take the value out with `replace`, change it, and
put it back: `v = c.replace(Vec())`, `!v.push(x)`, `c.set(<v)`.

**`Signal(T)`** holds a Copy value and a list of subscribers (owned
closures) that run on every `set`. It lives behind a shared handle,
`*Signal(value: v)`.

```rig
sub main
  clicks: *Signal(Int) = *Signal(value: 0)
  clicks.subscribe(*|~clicks|
    if clicks.upgrade() as c
      print("clicked", c.get()))
  clicks.set(1)
  clicks.set(2)
```

```output
clicked 1
clicked 2
```

## 18. Closures

### The bar list

A closure is a bar list and a body, with no keyword. The bar list holds
**captures**, each with a sigil, then **parameters**, bare names with
optional types:

| Entry | Meaning |
|---|---|
| `+x` | capture a copy of a Copy value, or a clone of a handle |
| `<x` | move `x` in |
| `~x` | hold a shared handle weakly |
| `a`, `a: Int` | a parameter |
| `\|\|` | no captures, no parameters |

A closure reaches outer locals only through captures, unlike Rust's
implicit capture: the capture mode is written, not inferred.

```rig
sub main
  n = 10
  add_n = |+n, a: Int| a + n
  hello = || print("hello")
  hello()
  print(add_n(5))
  clamp = |x: Int|
    return 100 if x > 100
    x
  print(clamp(700), clamp(7))
```

```output
hello
15
100 7
```

A parameter's type may come from context, and so may the return type:

```rig
fun apply(f: fun(Int) -> Int, x: Int) -> Int
  f(x)

fun twice(n: Int) -> Int
  n * 2

sub main
  add: fun(Int, Int) -> Int = |a, b| a + b
  print(add(2, 3), apply(twice, 4))
```

```output
5 8
```

### Stack closures and owned closures

A plain closure is a **stack closure**: its captures live in the
function's frame, like a Zig struct with an `invoke` method, so it
cannot escape. It may be bound to a local and called, or called where
it is written.

`*` before the bar list makes an **owned closure**: its environment is
on the heap behind a shared handle of type `*fun(A) -> R` or `*sub(A)`,
which can be stored, returned, cloned, and held weakly. This is Rust's
`Rc<dyn Fn>`. Its parameters and result are plain Copy values, and it
cannot capture a borrow.

```rig
fun make_counter(start: Int) -> *fun(Int) -> Int
  count: *Cell(Int) = *Cell(value: start)
  *|+count, step|
    count.set(count.get() + step)
    count.get()

sub main
  next = make_counter(100)
  print(next(1), next(10))
  handlers: Vec(*fun(Int) -> Int) = Vec()
  !handlers.push(<next)
  !handlers.push(*|x| x * 10)
  for h in ?handlers
    print(h(3))
```

```output
101 111
114
30
```

```rig reject
fun make -> fun() -> Int
  n = 1
  |+n| n
```

```error
closures cannot escape their defining scope
```

### Multi-line bodies inside brackets

When a bar list ends a line inside `( )`, the body below is laid out in
blocks as usual. A paren-free call takes a trailing closure the same
way.

```rig
sub each(n: Int, f: *sub(Int))
  for i in 0..n
    f(i)

sub main
  each(2, *|i|
    print("saw", i))
  each 2, *|i|
    print("trailing", i)
```

```output
saw 0
saw 1
trailing 0
trailing 1
```

## 19. Optionals

`T?` holds a `T` or `none`. A `T` converts to `T?` where one is
expected.

| Form | Meaning | Zig |
|---|---|---|
| `a ?? b` | the value in `a`, or `b` | `a orelse b` |
| `a == none` | test for absence | `a == null` |
| `if a as x` | bind the value; `else` for `none` | `if (a) \|x\|` |
| `while a as x` | loop while `a` has a value | `while (a) \|x\|` |
| `a?` | the value, or return `none` from the function | `a orelse return null` |

Fields and methods are not reached through an optional; unwrap it
first (`a?.name`, or `if a as v`).

```rig
struct User
  name: String
  boss: Int?

fun find(id: Int) -> User?
  return User(name: "ada", boss: 2) if id == 1
  return User(name: "grace", boss: none) if id == 2
  none

fun boss_name(id: Int) -> String?
  find(find(id)?.boss?)?.name

sub main
  print(boss_name(1), boss_name(2))
  if find(2) as u
    print(u.name)
  print(find(9) == none, boss_name(3) ?? "nobody")
```

```output
grace none
grace
true nobody
```

Note the direction: `?x` (prefix) borrows, `x?` (suffix) unwraps.

## 20. Errors

A function returning `T!` may fail. It fails by producing an error
value where a `T` is expected, usually `return E.name`. Every call to
it says what happens to the failure:

- `f()!` propagates it (Zig's `try`, Rust's `?`). The operator is the
  suffix of the type it acts on: a `T!` propagates with `e!`, as a
  `T?` does with `e?` ([§19](#19-optionals)), so a line shows which kind
  of early exit it can take;
- `f() catch v` handles it with a fallback;
- `f() catch |err| handler` names the error for the handler, which may
  be a block.

```rig
error ParseError
  empty
  too_long

fun parse_len(s: String) -> Int!
  return ParseError.empty if s == ""
  return .too_long if s.len > 5
  s.len

fun doubled(s: String) -> Int!
  parse_len(s)! * 2

sub main
  print(doubled("abc")!, parse_len("") catch -1)
  n = parse_len("abcdefg") catch |err|
    print("failed:", err)
    0
  print(n)
```

```output
6 -1
failed: .too_long
0
```

A bare call to a fallible function is rejected, so a failure can never
be ignored silently:

```rig reject
fun parse_len(s: String) -> Int!
  s.len

sub main
  n = parse_len("abc")
```

```error
must be wrapped with `!` (propagate) or `catch` (handle)
```

Functions do not declare which errors they return (every fallible type
lowers to `anyerror!T`), so `err` may be any error; compare it with
`err == E.name` or `match` it by name. `sub main` and `test` blocks may
propagate. Closures, `defer`, and `drop` bodies may not.

## 21. Arrays, strings, and slices

**Arrays** are fixed-size, `[N]T`, and hold plain data. `xs.len` is the
length and `xs[i]` a bounds-checked element.

**Strings** are immutable UTF-8 bytes, a Copy value. `s.len` is the
byte length, `s[i]` a byte (`U8`), and `for b in s` walks the bytes.
They compare by content with `==` and have no ordering.

**Slices** view part of an array, `Vec`, or string. `s[a..b]` of a
`String` is a `String`; of an array or a `Vec` of plain data it is
written `?xs[a..b]` and is a `[]T`, a read-only view that borrows `xs`
like any `?` borrow. Bounds are checked.

```rig
fun total(xs: []Int) -> Int
  n = 0
  for x in xs
    n += x
  n

sub main
  s = "hello, world"
  print(s[0..5], s.len, s[0])
  a = [1, 2, 3, 4]
  mid = ?a[1..3]
  print(mid, mid.len, total(mid), total(?a[0..4]))
```

```output
hello 12 104
[2, 3] 2 5 10
```

A slice is read-only: `mid[0] = 5` is rejected.

## 22. Modules and constants

`use name` imports `name.rig` from the root file's directory. The
module's `pub` declarations are reached as `name.decl` and its types as
`name.Type`.

```rig file=shapes.rig
pub struct Point
  x: Int
  y: Int

  fun sum(?self) -> Int
    self.x + self.y

pub fun origin -> Point
  Point(x: 0, y: 0)

pub unit =! 10
```

```rig
use shapes

sub main
  p: shapes.Point = shapes.Point(x: 1, y: 2)
  print(p.sum(), shapes.origin().sum(), shapes.unit)
```

```output
3 0 10
```

Only `pub` declarations are visible outside a module. A struct's
fields and methods are visible wherever the struct is.

**Constants.** A module-level binding is a constant, written with `=!`
and known at compile time: literals, `.variant`, earlier constants, and
operators and arrays over them. There are no mutable globals.

```rig
limit =! 10
half =! limit / 2
names =! ["low", "high"]

sub main
  print(limit, half, names[1])
```

```output
10 5 high
```

## 23. raw, extern, and builtins

A `raw` block is Rig's `unsafe`: the one place a program may call Zig
builtins outside the safe list and `extern` C functions. Everything else
in it is still checked, and a `raw` block may yield a value, so a safe
function can wrap raw code for its callers.

```rig
extern fun abs(n: I32) -> I32

fun safe_abs(n: I32) -> I32
  raw
    abs(n)

sub main
  x = 300
  raw
    small: U8 = @intCast(x - 100)
    print(small)
  print(safe_abs(-5), @sizeOf(Int))
```

```output
200
5 8
```

- `extern fun name(params) -> R` and `extern sub name(params)` declare C
  functions, and `extern name: T` a C variable of a number or `Bool`
  type. Only integers, floats, and `Bool` cross the boundary.
- `@name(args)` calls a Zig builtin. `@sizeOf`, `@alignOf`, `@TypeOf`,
  and `@typeName` are safe anywhere; the rest need `raw`.

## 24. Compile-time parameters

`pre name: T` marks a parameter known at compile time, lowered to a Zig
`comptime` parameter. Its argument must be a literal, an enum value, a
constant, or another `pre` parameter.

```rig
enum Mode
  strict
  loose

fun check(pre mode: Mode, n: Int) -> Bool
  n > 10 if mode == .strict else n > 0

sub main
  print(check(.strict, 5), check(.loose, 5))
```

```output
false true
```

## 25. Tests

A `test "name"` block is checked like a function body that may fail;
`f()!` inside it fails the test. `rig test file.rig` runs every test
block of the program and its modules; `rig run` ignores them.

```rig
fun area(w: Int, h: Int) -> Int
  w * h

test "area of a square"
  print(area(3, 3))

sub main
  print(area(2, 3))
```

```output
6
```

## 26. Printing

`print(a, b, ...)`, or `print a, b`, writes its values separated by
spaces, then a newline. A whole `Float` keeps its point (`2.0`), and a
NaN prints as `nan` on every platform. It prints any value except a
`[]U8`:

```rig
struct User
  name: String
  age: Int

enum Shape
  dot
  circle(r: Float)

sub main
  u = User(name: "ada", age: 36)
  n: Int? = none
  h = *User(name: "bob", age: 1)
  print(u, n, ["a", "b"], 2.0, Shape.circle(r: 1.5), Shape.dot)
  w = ~h
  print(h, w)
```

```output
User(name: "ada", age: 36) none ["a", "b"] 2.0 .circle(r: 1.5) .dot
User(name: "bob", age: 1) ~(alive)
```

## 27. What Rig does not have (yet)

Coming from Rust or Zig, you will reach for these and not find them:

- **generic functions and traits**: generics are on types only;
- **heap strings and string building**: `String` is an immutable view;
- **stack closures as arguments**: pass an owned closure (`*|...|`);
- **concurrency and async**;
- **a standard library** beyond `print`, `Cell`, `Vec`, and `Signal`;
- **raw pointers**;
- **macros**, which Rig does not plan to have.

The exact list of rejected and reserved forms, with their diagnostics,
is [SPEC §19](SPEC.md#19-reserved-and-unsupported-forms), and the plans
are in the [roadmap](docs/ROADMAP.md).

---

# Appendices

## A. Sigil and operator cheat sheet

**Prefix sigils (expressions)**

| Form | Name | Type | Effect |
|---|---|---|---|
| `<x` | move | `T` | ownership leaves `x` |
| `?x` | read borrow | `?T` | shared, read-only loan |
| `!x` | write borrow | `!T` | exclusive, writable loan |
| `+x` | clone | `T` | a new owner |
| `-x` | drop (statement) | | release now |
| `-x` | negate (in an expression) | `T` | arithmetic negation |
| `*x` | share | `*T` | move into a counted box |
| `~x` | weak | `~T` | non-owning handle |
| `!p.m()` | write receiver | | `(!p).m()`: `p` lent to a `!self` method |
| `<p.m()` | move receiver | | `(<p).m()`: `p` moved into a `self: Self` method |

`!` is never "not": logical negation is `not x`.

**Suffixes**

| Form | Meaning |
|---|---|
| `T?` | optional type |
| `T!` | fallible type |
| `e?` | unwrap, or return `none` |
| `e!` | unwrap, or propagate the error |

**Type prefixes:** `?T` read borrow, `!T` write borrow, `*T` shared,
`~T` weak, `[N]T` array, `[]T` slice.

**Binding operators:** `=` bind or assign, `=!` fixed binding, `<-`
move-assign, `new x =` shadow, compound `+=` `-=` `*=` `/=` `%=` `&=`
`|=` `^=` `<<=` `>>=`.

**Other punctuation:** `->` return type, `=>` match arm, `..` range,
`??` optional fallback, `:name` label, `|...|` closure bar list,
`.name` enum variant, `@name(...)` builtin, `#` comment, `\` line join.

**Keywords by role**

| Role | Keywords |
|---|---|
| declarations | `fun` `sub` `struct` `enum` `error` `type` `use` `pub` `extern` `test` `drop` |
| control | `if` `else` `while` `for` `in` `match` `break` `continue` `return` `defer` `errdefer` |
| expressions | `and` `or` `not` `as` `catch` `true` `false` |
| bindings | `new` (statement start only) |
| boundaries | `raw` `pre` |
| reserved | `try` `zig` |

## B. How Rig lowers to Zig

`rig emit file.rig` prints the Zig a program becomes. The main
correspondences:

| Rig | Zig |
|---|---|
| `Int`, `U8`, `Float`, `String` | `i64`, `u8`, `f64`, `[]const u8` |
| `struct`, plain `enum`, payload `enum` | `struct`, `enum`, `union(enum)` |
| `error E` | an error set |
| `type Box(T)` | `fn Box(comptime T: type) type` |
| `T?`, `none`, `a ?? b` | `?T`, `null`, `a orelse b` |
| `T!`, `f()!`, `catch` | `anyerror!T`, `try f()`, `catch` |
| `?T` parameter | the value for plain data; `*const T` for owning types |
| `!T` | `*T` |
| `*T`, `~T` | runtime `RcBox(T)` pointer, weak handle |
| `Vec(T)`, `Cell(T)` | runtime generic types |
| an owning local | a `defer` that releases it, guarded by a flag if it may move first |
| a stack closure | a local struct holding its captures, with an `invoke` method |
| an owned closure | a counted, type-erased closure |
| `defer`, `errdefer` | `defer`, `errdefer` |
| `pre n: Int` | `comptime n: i64` |
| `sub main` | `pub fn main() void`, which checks for leaks on exit in Debug |

The runtime (`src/runtime.zig`) is written next to every emitted
program; [INTERNALS](docs/INTERNALS.md) describes it.

## C. Grammar summary

A condensed, informal view of [rig.grammar](rig.grammar), the
authoritative grammar. `[x]` is optional, `x*` repeats, `INDENT` /
`DEDENT` are the block structure.

```text
program   = decl*
decl      = ["pub"] (fun | sub | struct | enum | errors | typedef | const | test)
          | use | extern
use       = "use" name
fun       = "fun" name ["(" params ")"] ["->" type] block
sub       = "sub" name ["(" params ")"] block
param     = name ":" type ["=" literal] | "pre" name ":" type | "?self" | "!self"
struct    = "struct" name INDENT (field | fun | sub | drop)* DEDENT
field     = name ":" type ["=" literal]
enum      = "enum" name ["(" params ")"] INDENT (variant | fun | sub)* DEDENT
variant   = name | name "=" integer | name "(" field, ... ")"
errors    = "error" name INDENT name* DEDENT
typedef   = "type" name "=" type
          | "type" name "(" params ")" INDENT (field | fun | sub)* DEDENT
const     = name [":" type] "=!" expr
drop      = "drop" "self" ":" "!Self" block
test      = "test" string block
extern    = "extern" ("fun" | "sub") name ["(" params ")"] ["->" type]
          | "extern" name ":" type

type      = ("?" | "!" | "*" | "~" | "[" [integer] "]") type
          | type ("?" | "!")
          | name | name "(" type, ... ")" | mod "." name | "(" type ")"
          | "fun" "(" type, ... ")" "->" type | "sub" "(" type, ... ")"

stmt      = simple ["if" expr] | ":" label stmt
simple    = expr | call-without-parens
          | target ("=" | "=!" | "<-" | "+=" | ...) expr
          | name ":" type ("=" | "=!") expr | "new" name "=" expr
          | "-" name | "return" [expr] | "break" [":" label] [expr]
          | "continue" [":" label] | "defer" (simple | block)
          | "errdefer" (simple | block) | "raw" block
block     = INDENT stmt* DEDENT

expr      = if | while | for | match | closure | value
if        = "if" cond block ["else" (block | if)]
cond      = expr | expr "as" name
while     = "while" cond [":" step] block ["else" block]
for       = "for" name ["," name] "in" ["?" | "!" | "<"] expr block ["else" block]
match     = "match" expr INDENT (pattern ("=>" simple | block))* DEDENT
pattern   = "." name ["(" name, ... ")"] | integer | "-" integer
          | "true" | "false" | integer ".." integer | "_" | name
closure   = ["*"] "|" (("+" | "<" | "~") name | name [":" type]), ... "|" (expr | block)
value     = logic "if" logic "else" value | logic "catch" ["|" name "|"] value | logic
logic     = logic "or" logic | logic "and" logic | "not" logic | infix
infix     = unary (op unary)*          # precedence table in section 10
unary     = ("-" | "<" | "+" | "?" | "!" | "*" | "~") unary | postfix
postfix   = postfix ("." name | "[" expr "]" | "(" args ")" | "!" | "?") | atom
args      = (expr | name ":" expr), ...
atom      = name | literal | "." name | "@" name "(" args ")" | "[" expr, ... "]" | "(" expr ")"
```

The grammar reads `!v.push(x)` as `!` applied to `v.push(x)`, like any
prefix; the compiler then moves a `!` or `<` before a place and a method
call onto the place, giving the tree of `(!v).push(x)`
([§12](#receiver-sigils-vpushx-and-pclose)).

## D. Habits to unlearn

**From Rust**

- A bare name never moves an owning value; write `<x`. Returning `x`
  as the last expression is the exception.
- Mutation needs a visible write borrow even on a value you own:
  `!v.push(x)`, not `v.push(x)`. The `!` marks the write on the
  receiver; it does not negate the call.
- There are no lifetimes to write, no `mut`, and no `let`.
- `?` is spelled `!` for errors (`f()!`) and `?` only for optionals
  (`x?`); a prefix `?x` is a borrow.
- `Rc<RefCell<T>>` is `*Cell(T)`; there is no run-time borrow flag,
  because a Cell's contents are only replaced, never borrowed.
- Closures capture nothing implicitly: list every capture with its
  mode.
- `&&`, `||`, and `!` are `and`, `or`, and `not`. A `!` that would
  read as "not" (`if !done`, `!q.is_empty()`) is a compile error.
- `v.len()` is `v.len`: a field, since reading it runs no code.
- Every variable must be read; an unused one is an error, as in Zig.
- A name alone never calls: `greet` is the function as a value, and
  `greet()` or `greet 1` calls it. A lone `greet` statement is an error.

**From Zig**

- No braces, semicolons, or `const` / `var`: the compiler picks `const`
  or `var`.
- `!` is not logical not: write `not ok`. Prefix `!` is a write borrow
  (`&x` for a pointer you may write through), and `!v.push(x)` marks
  that `push` writes `v`; `if !ok` is a compile error.
- Allocation is never hidden and never needs an allocator argument:
  `*x`, `Vec`, and owned closures are the only things that allocate,
  and the compiler frees them.
- `try f()` is `f()!`, `orelse` is `??`, and `if (x) |v|` is
  `if x as v`.
- Error sets are not written in function types; every fallible
  function returns `T!`.
- `.{ .x = 1 }` is `P(x: 1)`: constructors name the type and every
  field.
- Spacing is significant around sigils: `f -x` is a call and `a - x`
  a subtraction.
- A function with no parameters needs no `()` in its declaration,
  `sub greet`, but a call still does, `greet()`.
- A value nobody uses is an error, as in Zig; `_ = e` discards on
  purpose.
- `switch` is `match`, and its `else =>` arm is `_ =>`.
- A payload variant is built with named fields, `.circle(r: 2)`, not
  `.{ .circle = 2 }`.
