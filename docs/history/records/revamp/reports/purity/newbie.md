# Rig through a newcomer's eyes

Reviewer persona: comfortable in Python, Ruby, and TypeScript; has never
written Rust, Zig, or C. Read-only review of `/Users/shreeve/Data/Code/rig`
on `main` (cf644a0). Programs and the full error log are in
`scratchpad/purity/newbie/` (`log.md` has every message verbatim).

## Verdict in one paragraph

Rig is a softer landing than Rust and much softer than Zig, and for
plain code (loops, `if`, structs, `match`, `print`) it really does feel
like Python or Ruby. The compiler has clearly been trained on
newcomers: `class`, `def`, `elsif`, `None`, `try`, `len(x)` and
`x.len()` all get a message that names the Rig spelling. But the moment
a program shares data, returns a recursive type, or needs text, the
landing gets hard. There is no way to build a string or turn a number
into one, the compiler once pointed me down a dead end (`*Expr` for a
recursive enum), and the worst moment of the hour was a program that
compiled cleanly and printed the wrong answer because a struct was
silently copied. I finished all six programs, taking 2 to 8 tries each,
but two of them only because I found a working example in SPEC or
`examples/` and copied its shape.

## 1. Reading the docs as a newcomer

### README.md

Good: short, every example has its output, "Status: early" is honest.

Confusing moments, in reading order:

- "lowers the program to Zig": "lowers" is compiler jargon.
- "Borrows are checked, never counted": assumes I know what a
  refcount is and why borrowing would ever be "counted".
- `drop(!self)` in the second example, before `!self` has been
  explained anywhere.
- `-a` as a statement: it reads as negation. The README says "drops one
  now", but what "dropping" means to someone with a garbage collector is
  never said.
- The "Closures and a little reactivity" example
  (`*|~clicks, +total|`, `clicks.upgrade() as c`) is the densest code
  in the file, and it comes in the first screen of the tour. It scared
  me more than anything else in the README.
- "drop glue", "arity", "stack and owned closures", "per-instance
  checking", "trait bounds" in the Status list: all unexplained.

### WELCOME.md

Good: "Habits that trip people up" is the best newcomer section I have
seen in a young language. It shows the exact error for `def`, `elif`,
`let`, `:`, `//`, `++`, `this`, `null`, `True`, `println`, `!done`,
`||`, and index-first loops. Those messages are real and they helped.

Confusing moments:

- "The central idea" table explains every sigil by comparing it to Rust
  and Zig. For me both comparison columns were empty. Nowhere does the
  guide say, in GC terms, what "own", "move", "borrow" and "drop" mean,
  or why I should care. The Python section is one table row: "memory:
  a garbage collector → owners, released where their scope ends".
- "From Rust and Zig" (a 40-row table plus a generics table and a Zig
  mapping table) comes before "From C, Python, Ruby, JavaScript, and
  Go", which is a single 20-row table. The guide that is "for
  programmers arriving from another language" is mostly for Rust and
  Zig programmers.
- The first example program uses `?[4]Int` and `?[1, 3, 4, 5]`. Why
  does an array literal need a `?`?
- `x =! 1` for a "fixed binding" looks like a typo of `!=`.
- `*Cell[Int]` is "the one way to share state that changes", with no
  explanation of why a plain shared struct can't change.
- **Missing entirely:** the difference between a *Copy* value and an
  *owning* value. SPEC §2 says a struct of numbers and strings is
  copied on every assignment and pass, like a Python int, while a
  struct with a `Vec` in it moves. This is the single rule that
  decides whether `a = b` shares, copies, or is an error, and it cost
  me a silently wrong program (see §3). It is not in WELCOME.
- "What Rig does not have" is honest but the list hurts: no string
  building, no interpolation, no standard library. A Python programmer
  reads that as "I can't write most of my programs yet", and they are
  right.

### SYNTAX.md and SPEC.md

I went to them four times: how to fail (`return E.x`), how to read an
error with `catch |e|`, how to write a recursive enum (SPEC §10's
`Box[Expr]` evaluator saved me), and how to write a `match` arm with a
block body (the grammar summary: drop the `=>`). They are thorough and
every example has output, but they are references, not teaching
material: the ownership chapter starts with a table of sigils and goes
straight to rules.

## 2. The six programs

| Program | Tries | Notes |
|---|---|---|
| FizzBuzz (`fizzbuzz.rig`) | 2 | Only `elsif` → `else if`. Felt like Ruby. |
| FizzBuzz with a label function (`fizzbuzz2.rig`) | 3 + redesign | Impossible as written: no `+` on strings, no `str(n)`, no f-strings. Rewrote to return `String?`. |
| To-do list in a `Vec` of structs (`todo.rig`) | 3 | `!self.items.push`, `!todos.add`, `for item, i in ?self.items`. |
| Optional + fallible function (`optional_fail.rig`) | 6 | `raise` gave a useless message; passing a `Vec` gave a jargon message whose suggested fix was wrong for me. |
| Bank account (`bank.rig`, `bank2.rig`) | 5 + 3 | Very good messages for `class`, `def`, a `sub` that returns an error. A transfer between two accounts in one `Vec` is rejected with no suggested fix. |
| Recursive evaluator (`expr.rig`) | 8 | The compiler's hint (`*Expr`) was a dead end; SPEC's `Box[Expr]` example worked. |
| Counter with two owners (`shared.rig`) | 3 | First version compiled and printed `0` instead of `3`. |

All final versions run with no leak report. The edit-run cycle is about
one second, which feels like a scripting language.

## 3. Best and worst moments

**Best**

- `return BankError.invalid_amount` inside a plain `sub`:
  "a `sub` that cannot fail returns no error; declare it fallible to
  fail: `sub deposit(...)!`". It told me the concept and the exact fix.
- `try` / `except`: "`try` blocks are reserved: propagate with `e!` or
  handle with `e catch ...`".
- `len(items)`: "a length is a member: `x.len`"; and `items.len()`:
  "`len` is a field: write `items.len`".
- `!self.counter.increment()` through a `*Counter`: "other handles may
  exist. Use an interior-mutable `Cell[T]`", which is exactly the
  concept, in one line.
- Plain code worked first time: `while true` / `break if n > 3`,
  `for i in 0..xs.len`, default field values, default parameters,
  `a if c else b`, `return x if cond`, and `print(p)` of a struct
  printing `P(x: 1)`.

**Worst**

1. **A silent wrong answer.** Python habit: give two objects the same
   counter.

   ```rig
   counter = Counter()
   left = Clicker(name: "left", counter: counter)
   right = Clicker(name: "right", counter: counter)
   !left.click()
   !right.click()
   !right.click()
   print("total clicks:", counter.count)   # prints 0
   ```

   No error, no warning. `Counter` holds only an `Int`, so it is "plain
   data" and each `Clicker` got its own copy. By the language's rules
   the program is correct, but for a Python or TypeScript programmer it
   is the most dangerous kind of surprise, and nothing in WELCOME warns
   about it.
2. **The compiler sent me the wrong way.** For `add(left: Expr, right:
   Expr)` it said "hold it through a shared handle (`*Expr`)". I did,
   and then got `expected ?Expr, got ?*Expr`, then "cannot `match` on a
   value of type `?*Expr`". An enum behind a `*` handle cannot be
   matched at all. SPEC's own evaluator uses `Box[Expr]`, which the
   hint should suggest.
3. **Jargon that explains the implementation, not my mistake.** Passing
   a `Vec` to a function: "would copy the buffer pointer and double-free
   on scope exit; use `<names` to move ownership". I followed it, then
   got "use of `names` after move" because I called the function twice.
   What I needed was "lend it: take `?Vec[String]` and pass `?names`",
   which neither message mentions.
4. **An index out of bounds** gives a Zig stack trace through
   `runtime.zig`, `__rig_main.zig`, and `std/start.zig`, with no Rig
   file and line.
5. **Strings.** FizzBuzz-with-a-function, the to-do "summary line", a
   bank statement, and printing an expression tree all need "build a
   string". None can be written.

## 4. The sigils after an hour

They are not line noise, but they are not equal.

| Sigil | After an hour |
|---|---|
| `!x` write borrow | **Makes sense and I like it.** `!acct.deposit(100)` tells me this line changes `acct`. The compiler taught it to me in three errors. Reading `!` as "changes" rather than "not" took about ten minutes. |
| `e!` propagate failure | Makes sense. `!acct.withdraw(30)!` (a bang on both ends) looks odd at first, then reads as "changes acct, may fail". |
| `?x` read borrow | Mostly makes sense ("just looking"). Confusing where it is required: `for x in ?self.items` inside a method whose `self` is already `?self`. |
| `T?`, `??`, `if x as v` | Natural (TypeScript's `?` and `??`). The errors for Python habits (`if x`, `x or 0`, `x + 1`) don't mention them. |
| `<x` move | Clear once it bites you; the error names it. But I never wanted to move anything: I wanted to lend, and the compiler suggested moving. |
| `*x` shared, `+x` clone | Understandable as "shared object" and "another reference". Needing `*Cell[...]` to change shared state is a real concept to learn, though the error teaches it. |
| `-x` drop | Rarely needed; reads as negation. |
| `~x` weak | Didn't need it. The README puts it in the first screen anyway. |
| Stacked sigils | `?*Expr`, `![3]Int`, `?~Node`, `*|~clicks, +total|` are where it turns into line noise. |

The rule "prefix = borrow, suffix = optional or failure" is the key
that makes them readable, and it is stated clearly in WELCOME. Seeing
every change marked with `!` is the part a Python programmer might
actually miss when going back.

## 5. Rules that surprised me

- A plain struct is copied on assignment and on passing, but a struct
  containing a `Vec` cannot be assigned at all without `<`. Same syntax,
  three behaviours (copy, move, error), decided by what is inside the
  type.
- Changing state through a `Cell` needs no `!`: `left.click()` with
  `click(?self)` changed the shared counter. So "every mutation is
  visible" is not quite true for shared state.
- `for x in ?v` is required for a Vec even when `v` is already a
  borrow of a struct field.
- A `for` variable may not reuse the name of an earlier local.
- A value-returning call used as a statement with `catch |e|` must
  still produce a value in the handler (`expected Float, got Void`).
- A `match` arm with a block has no `=>`.
- Iterating a `String` gives numbers (`102 111 111`).
- A `Vec` cannot be cloned (`+v`); there is no way to copy one.
- Two write borrows into one `Vec` (a transfer between accounts) are
  rejected; the workaround (copy out, change, copy back) is easy to get
  silently wrong.

## 6. Where I needed to understand ownership

1. Mutating methods and calls (`!self`, `!x.m()`): the errors taught it.
2. Passing a `Vec` to a function: I needed "lend vs give". The README's
   `greeting(?ada)` example taught it; the compiler's message did not.
3. Sharing a counter: I needed "copy vs share" and "shared objects are
   read-only unless the part that changes is a `Cell`". The silent copy
   taught it the hard way; the `*Counter` error then taught `Cell` well.
4. A recursive enum: I needed "a type can't contain itself; put the
   child in a `Box`". The compiler's hint pointed at the wrong tool.
5. Returning a closure: I needed "the closure outlives the function, so
   it must own what it captures". The five-way capture menu and the
   "unique borrow out of the closure environment" message did not teach
   it; `examples/counter_closure.rig` did.

Did the docs teach it well enough? For someone from Rust, yes. For
someone from Python, no: there is no page that says, in GC terms,
"here is what owning, lending, and giving away mean, here is which
values are copied and which are owned, and here is how to share
something that changes". The pieces are all in SPEC §2, §7, §9, §10,
but a newcomer has to assemble them from errors.

## 7. More approachable than Rust? Than Zig?

- **Than Rust: yes, clearly.** No lifetimes, no `&`/`&mut`/`Box<dyn>`,
  no `impl`/traits, no semicolons or braces, and errors that name the
  Rig spelling of Python habits. The ownership ideas are the same as
  Rust's, so the hard part (copy vs move vs borrow, shared mutation) is
  still there, but the syntax around it is far lighter and every effect
  is visible where it happens.
- **Than Zig: yes, much more.** No allocators to pass, no `try`/`defer`
  plumbing for every allocation, no `comptime` to learn for generics,
  and leaks are reported at the end of every Debug run. Zig's
  "everything is explicit" is replaced by "the compiler frees it".
- **Than Python or TypeScript: no, and it doesn't pretend to be.** The
  missing string, map, and input basics matter more to a newcomer than
  the sigils.

## 8. Error-message scorecard

About 55 distinct errors or surprises over the hour (full list in
`log.md`):

| Rating | Count | Examples |
|---|---|---|
| Told me exactly what to write | 17 | `class`, `def`, `elsif`, `None`, `try`, `len(x)`, `x.len()`, `!receiver.push(...)`, `sub f(...)!`, fallible call needs `!` or `catch`, `for x in ?v`, named variant fields, `Cell` for shared mutation |
| Partly (what, not how; or a menu with no pick) | 10 | `self` receiver menu, capture menu, second write borrow, `expected Int, got Void` after `catch`, use after move with no "borrow instead", `**`, `+v` on a Vec |
| No help (a bare "unexpected" or "unbound") | 22 | f-strings, `raise`, `range`, `enumerate` (plus a misleading cascade), `if opt`, `opt + 1`, `opt or 0`, `items.length`, `[1,2,3].push` (`![3]Int`), `=>` before a block arm, tuples, `?*Expr` |
| Misleading or hostile | 5 | `*Expr` hint for a recursive enum; "copy the buffer pointer and double-free" with a move suggestion; `{"a": 1}` explained as a block; "hand the unique borrow out of the closure environment, again at each call"; index-out-of-bounds Zig stack trace |
| Silent | 1 | Shared counter copied; printed `0` |

Pattern: the parser-level habit errors (keywords, operators, names)
are excellent. The weak spots are (a) the type checker's errors on
optionals and sigil-typed values, which say what's wrong but not what
to write, (b) the ownership errors that describe the implementation
("buffer pointer", "unique borrow", "closure environment") instead of
the intent, and (c) runtime panics, which show emitted Zig. Also,
WELCOME's promised index-first hint does not fire for the most common
case (`for i, item in ?items` over structs gives "type `Int` has no
field `title`").

## 9. Ranked changes for the newcomer experience (before the standard library)

1. **Strings you can build and format.** `+` or a builder, number to
   string (`str(n)` or `"{n}"` interpolation), and `print` of a
   formatted line. Today FizzBuzz-as-a-function cannot be written. This
   is the first thing every newcomer hits.
2. **Warn about or explain silent copies of structs.** At least a
   WELCOME section "copy vs owning vs shared" with the
   `Clicker(counter: counter)` example; ideally a diagnostic when a
   copied struct is later written through `!` and the original is read
   again, or a lint for "you gave the same plain value to two owners".
3. **Fix the recursive-type hint** to suggest `Box[Expr]` (and show the
   `?Box[Expr]` / `eval(?l)` shape), or make `match` work through
   `*T` and `?*T`.
4. **An ownership chapter for GC programmers** in WELCOME: owning,
   lending, giving away, copying, sharing, and `Cell`, with one small
   program each and the error each mistake produces. Move the Python /
   Ruby / JS section above the Rust / Zig one, or split the guide.
5. **Ownership errors that suggest the borrow first.** For a bare `Vec`
   argument: "lend it with `?names` (and take `?Vec[String]`), or move
   it with `<names`". Drop "buffer pointer" and "double-free" from the
   main line (keep them in a note). Same for use-after-move: add
   "did you mean to lend it (`?x`)?".
6. **A hash map** (`Map[K, V]`) with get / set / contains / iterate.
   Together with strings, this is most of what small programs need.
7. **Reading input and files**: a line from stdin, command-line args,
   read a file into a string. Without these, no program can do anything
   but print constants.
8. **Habit messages for the type checker**: `if opt` → `if opt as v`;
   `opt or 0` and `opt + 1` → `??`; `raise E.x` → `return E.x`;
   f-strings → "no interpolation; pass values to `print`"; `range(a, b)`
   → `a..b`; `enumerate(xs)` → `for x, i in xs` (and make the
   element-first hint fire when the "element" is used as a struct);
   `.length` / `.size` / `.count` → `.len`; `.push` on an array → "use
   `Vec`"; `=>` before a block arm → "drop the `=>`";
   `{"a": 1}` → "no dict literals".
9. **Runtime panics with Rig locations**: "index 5 out of bounds for
   length 2 at todo_extra.rig:17:3", not a Zig trace. Hide the Zig
   frames unless asked.
10. **Common Vec and String methods**: `remove(i)`, `insert(i, x)`,
    `contains`, `sort` (with a key or comparator), `reverse`, a way to
    copy a Vec, string `split`, `trim`, `upper`, `starts_with`, char
    iteration that yields characters, not byte numbers.
11. **A suggested fix for two write borrows into one collection**
    (e.g. "`!v.pair(i, j)`" or a `swap`-style helper), so the
    copy-out-copy-back workaround isn't needed.
12. **Tuples or multiple return values**, and `**` (or a named `pow`).
13. **Trim the README tour for newcomers**: move the reactive
    `Signal` example and weak handles later; open with a program that
    uses a `Vec` and a struct.
14. **Pick one receiver in the `self` error** based on the body (assigns
    → `!self`, reads → `?self`), and recommend one capture mode in the
    closure-capture error (`|+x|` for a value, `|!x|` to change a local
    in a stack closure).
15. **Explain the catch-handler type rule in the error**: "the handler
    must give a `Float` like the call it replaces; end the block with a
    value, or use `catch return`".
