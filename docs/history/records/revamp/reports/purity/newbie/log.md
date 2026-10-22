# Newcomer error log

Persona: knows Python, Ruby, TypeScript; never used Rust, Zig, or C.
Every program was run with `bin/rig run file.rig` (Rig on `main`, cf644a0).
"Told me?" means: did the message alone tell me what to write instead?
Yes / Partly / No / Misleading.

All final programs run and exit cleanly with no leak report.

## 1. FizzBuzz (`fizzbuzz.rig`) - 2 tries

| # | I wrote | Message | Told me? |
|---|---|---|---|
| 1 | `elsif i % 3 == 0` | ``Rig has no `elsif`; write `else if` `` | Yes |

Try 2 ran and printed 1..100 correctly.

### Variant: label function with string building (`fizzbuzz2.rig`) - 3 tries, then a redesign

| # | I wrote | Message | Told me? |
|---|---|---|---|
| 2 | `print(f"{i}: {label(i)}")` | ``unexpected `"{i}: {label(i)}"` `` | No. Nothing says "no f-strings; pass values to `print` separately". |
| 3 | `s += "Fizz"` (s is `""`) | ``` `+=` requires a numeric target; `s` has type `String` ``` | No. Doesn't say strings can't be built at all yet. |
| 4 | `s = str(n)` | ``use of unbound name `str` `` | No. There is no int-to-string conversion anywhere. |
| 5 | `for i in range(1, 16)` | ``use of unbound name `range` `` | No. Could say "write `1..16`". |

I could not write the Python version at all: there is no way to build
"FizzBuzz" from "Fizz" + "Buzz" or turn 7 into "7". I redesigned the
function to return `String?` (`none` for plain numbers) and used
`if label(i) as s`. That works, but only because the docs had shown
`if x as v`.

## 2. To-do list in a Vec of structs (`todo.rig`) - 3 tries

| # | I wrote | Message | Told me? |
|---|---|---|---|
| 6 | `self.items.push(Todo(...))` | ``method `push` requires a write-borrowed receiver; use `!receiver.push(...)` `` | Yes |
| 7 | `for i, item in enumerate(self.items)` | ``use of unbound name `enumerate` `` followed by ``type `Int` has no field `done` `` and ``type `Int` has no field `title` `` | No, and the cascade is misleading (why is my item an Int?) |
| 8 | `todos.add("buy milk")` (x4) | ``method `add` requires a write-borrowed receiver; use `!receiver.add(...)` `` | Yes |
| 9 | `for item, i in self.items` | ``write `for item, i in ?self.items` to read the Vec's elements`` | Yes, but surprising: `self` is already read-only inside `show(?self)`. |

Extra probes (`todo_extra.rig`):

| # | I wrote | Message | Told me? |
|---|---|---|---|
| 10 | `len(items)` | ``use of unbound name `len`; a length is a member: `x.len` `` | Yes |
| 11 | `items.length` | ``no field `length` on type `Vec` `` | No (no "did you mean `len`") |
| 12 | `items.len()` | ``no method `len` on type `Vec[Todo]`; `len` is a field: write `items.len` `` | Yes |
| 13 | `items[5].done = true` (2 items) | Runtime: `panic: index out of bounds`, then a stack trace through `runtime.zig:1007 indexPanic`, `__rig_main.zig:26 items.slot(5).*.done = true`, `std/start.zig` | No. No Rig file:line; the trace is emitted Zig. |
| 47 | `for i, item in ?items` then `item.title` | ``type `Int` has no field `title` `` | No. WELCOME promises an "element first" hint for this habit, but it fires only when the index is used to index `xs`; with a Vec of structs I got a type error on the wrong variable. |

## 3. Optional and fallible functions (`optional_fail.rig`) - 6 tries

| # | I wrote | Message | Told me? |
|---|---|---|---|
| 14 | `raise MathError.DivideByZero` | ``unexpected name `MathError` `` | No. Should say "Rig has no `raise`; `return MathError.x`". (WELCOME's example showed `return ParseError.empty`, which is how I fixed it.) |
| 15 | `try` / `except e` block | ``unexpected keyword `try`; `try` blocks are reserved: propagate with `e!` or handle with `e catch ...` `` | Yes |
| 16 | `for x, i in xs` (xs a by-value `Vec[String]` param) | ``write `for x, i in ?xs` to read the Vec's elements`` | Yes |
| 17 | `return None` | ``use of unbound name `None`; Rig's absent value is `none` `` | Yes |
| 18 | `print(divide(10, 2) catch \|e\| print("error:", e))` | ``type mismatch: expected `Int`, got `Void` `` | Partly. True, but doesn't say "the handler must give an `Int`; use a block ending in a value". |
| 19 | `find_index(names, "bob")` | ``bare use of `Vec` value `names` in call argument would copy the buffer pointer and double-free on scope exit; use `<names` to move ownership`` | Misleading. Jargon ("buffer pointer", "double-free"), and the only fix offered (move) was wrong for me: I call it twice. |
| 20 | (followed the hint) `find_index(<names, ...)` twice | ``use of `names` after move`` + note ``` `names` was moved here ``` | Partly. Clear what went wrong, but no "lend it with `?names` and take `?Vec[String]`". I found that in the README's `greeting(?ada)` example. |

Probes on optionals (`probe_opt.rig`), Python/TS habits:

| # | I wrote | Message | Told me? |
|---|---|---|---|
| 21 | `if i` (i: `Int?`) | ``type mismatch: expected `Bool`, got `Int?` `` | No. Could say "`if i as n`". |
| 22 | `i + 1` | ``operator `+` requires numeric operands; got `Int?` `` | No. Could say "unwrap with `i ?? 0` or `if i as n`". |
| 23 | `i or 0` | ``type mismatch: expected `Bool`, got `Int?` `` (twice) | No. The `\|\|` habit gets a `??` hint; `or` does not. |

## 4. Bank account "class" (`bank.rig`) - 5 tries

| # | I wrote | Message | Told me? |
|---|---|---|---|
| 24 | `class Account` | ``Rig has no `class`; declare a type with `struct` `` | Yes |
| 25 | `def deposit(...)` | ``Rig has no `def`; declare a function with `fun` (it returns a value) or `sub` `` | Yes |
| 26 | `sub deposit(self, amount: Int)` | ``` `self` parameter requires an explicit receiver type; use `?self`, `!self`, or `<self` ``` | Partly. A menu; it could see I assign `self.balance` and say `!self`. |
| 27 | `return BankError.invalid_amount` in a plain `sub` | ``a `sub` that cannot fail returns no error; declare it fallible to fail: `sub deposit(...)!` `` | Yes, excellent |
| 28 | `acct.deposit(100)` | ``method `deposit` requires a write-borrowed receiver; use `!receiver.deposit(...)` `` and ``fallible call to `acct.deposit` must be wrapped with `!` (propagate) or `catch` (handle)`` | Yes (result: `!acct.deposit(100)!`) |

### Part 2: transfer between two accounts in a Vec (`bank2.rig`) - 3 tries

| # | I wrote | Message | Told me? |
|---|---|---|---|
| 29 | `transfer(!accounts[0], !accounts[1], 40)!` | ``cannot take a second write borrow on `accounts` `` + note ``write borrow taken here`` | Partly. Says what, not how. I copied both out, transferred, wrote both back. That's a trap: forget the write-back and money vanishes silently. |
| 30 | `for a in ?accounts` after a local `a` | ``` `for` binding `a` shadows the local `a`; use a different name ``` | Yes (surprising rule, friendly message) |

## 5. Recursive expression evaluator (`expr.rig`) - 8 tries

| # | I wrote | Message | Told me? |
|---|---|---|---|
| 31 | `add(left: Expr, right: Expr)` | ``` `Expr` contains itself by value through `add`, so it would have no finite size; hold it through a shared handle (`*Expr`) ``` | Misleading. I followed it; `*Expr` turned out to be a dead end (below). SPEC's own evaluator uses `Box[Expr]`. |
| 32 | `Expr.mul(Expr.add(...), ...)` positional | ``a variant with more than one field sets them by name: `.mul(left: ...)` `` | Yes |
| 33 | `eval(l)` with `l: *Expr` | ``type mismatch: expected `Expr`, got `*Expr` `` (x7) | No |
| 34 | changed to `eval(e: ?Expr)` and `eval(?l)` | ``type mismatch: expected `?Expr`, got `?*Expr` `` (x7) | No. Now the types have two sigils. |
| 35 | changed to `eval(e: ?*Expr)` | ``cannot `match` on a value of type `?*Expr`; match works on enums, errors, integers, and Bool`` + 5 x ``` `.num` is an enum variant, but the expected type `?*Expr` is not an enum ``` | No. Also `*Expr` by value: same error. So a shared handle to an enum can't be matched at all, and the compiler's hint led me here. |
| 36 | rewrote with `Box[Expr]` from SPEC §10; a `.div(l, r) =>` arm followed by an indented block | ``unexpected indentation`` | No. The fix is to drop the `=>` (found in the SYNTAX grammar summary). |
| 37 | `print(eval(?bad) catch \|err\| print("error:", err))` | ``type mismatch: expected `Float`, got `Void` `` | Partly (the same mistake as #18) |
| 38 | `eval(?bad) catch \|err\|` + block with `print` (statement) | ``type mismatch: expected `Float`, got `Void` `` | Partly. As a statement the value is thrown away, so this surprised me; `sub` calls allow it. |

Try 8 (`result = ... catch |err|` block ending in `0.0`) ran: `-20.0`,
`error: .divide_by_zero`, `0.0`.

## 6. Counter shared between two owners (`shared.rig`) - 3 tries

| # | I wrote | Message | Told me? |
|---|---|---|---|
| 39 | Two `Clicker` structs each given `counter: counter` (a plain `Counter` struct), then `!left.click()` etc. (`shared_v1_silent_copy.rig`) | **No error.** It ran and printed `total clicks: 0`. | Silent. Python and TS would print 3. `Counter` is "plain data", so each Clicker got a copy. Nothing in WELCOME warns about this. |
| 40 | `counter: *Counter`, `!self.counter.increment()` | ``cannot call write-receiver method `increment` through a shared handle (`*T`); other handles may exist. Use an interior-mutable `Cell[T]` for mutation through shared ownership.`` | Yes (but "interior-mutable" is jargon) |

Try 3 with `*Cell[Int]` and `+counter` for each owner printed 1, 2, 3, total 3.

### Bonus: JavaScript-style closure counter (`probe_closure.rig`) - 3 tries

| # | I wrote | Message | Told me? |
|---|---|---|---|
| 41 | `count = 0` then a closure `\|\|` doing `count += 1` | ``` `count` is a local of the enclosing function; capture it to use it inside the closure (`|+count|` copies or clones it, `|<count|` moves it, `|?count|` or `|!count|` borrows it, `|~count|` holds it weakly) ``` | Partly. Five options, no recommendation. |
| 42 | picked `\|!count\|` and returned the closure | ``closures cannot escape their defining scope; bind the closure to a local ... or make it owned (`*|...| body`) to pass, store, or return it`` and ``bare use of captured write borrow `count` in return value would hand the unique borrow out of the closure environment, again at each call; use it inside the closure instead`` | First: Yes. Second: hostile jargon. |

Fixed by copying `examples/counter_closure.rig` (`*Cell` + `*|+count|`).

## Other probes

| # | I wrote | Message | Told me? |
|---|---|---|---|
| 43 | `balances = {"ada": 100}` | ``unexpected `{`; Rig has no braces: a block is the lines indented under its header`` | Misleading (I wanted a dict, not a block) |
| 44 | `Map[String, Int]` | ``use of unbound type `Map` `` | No (and there is no hash map) |
| 45 | `input("name? ")` | ``use of unbound name `input` `` | No (no way to read input) |
| 46 | `"foo" + "bar"` | ``operator `+` requires numeric operands; got `String` `` | No |
| 48 | `a.upper()` | ``type `String` has no method `upper` `` | Fair; there are no string methods |
| 49 | `2 ** 10` | ``` `**` is not a Rig operator ``` | Partly (no alternative given) |
| 50 | `nums = [1, 2, 3]` then `!nums.push(4)` | ``type `![3]Int` has no method `push` `` | No. `![3]Int` is baffling; should say "an array has a fixed length; use `Vec`". |
| 51 | `fun f() -> (Int, Int)` / `return a, b` | ``unexpected `,`; expected `)` `` | No (no tuples) |
| 52 | `!v.sort()` | ``no method `sort` on type `Vec` `` | No |
| 53 | `w = v` (Vec) | ``bare use of `Vec` value `v` in binding would copy the buffer pointer and double-free on scope exit; use `<v` to move ownership`` | Partly (jargon) |
| 54 | `w = +v` (want a copy of a Vec) | ``` `+x` cannot clone a `Vec[Int]`; only `*T` and `~T` handles (or optionals of them) and plain values can be cloned ``` | Partly. There is no way to copy a Vec. |
| 55 | `for c in "foo"` | no error; prints `102 111 111` | Surprise: bytes as numbers |
| 56 | `x = 5` then `-x` then `print(x)` | ``use of `x` after drop`` | Clear, but `-x` on a line by itself reading as "drop" rather than "negate" is odd. |

Things that just worked first time: `while true` + `break if n > 3`,
`for i in 0..xs.len` with `xs[i]`, default field values, default
parameter values (`greeting: String = "hello"`), `P(1)` for a
one-field struct, `print(p)` of a struct (`P(x: 1)`), `print` of an
array, string `==` and `<`, `a if c else b`, `return x if cond`.

Edit-run cycle: about 1 second after a code change.
