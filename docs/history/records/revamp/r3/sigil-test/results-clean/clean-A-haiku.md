## First guesses

Written from p01.rig, p02.rig and p03.rig only, before reading questions.md.

**Prefix symbols**

- `?` before a type in a parameter (`it: ?Item`, `items: ?Vec[Item]`, `best: ?Entry?`): a read-only (shared) view of the value.
- `?` before an expression (`first = ?items[0]`, `for it in ?items`, `report(?top)`): take a read-only view of that value at this point.
- `!` before a type in a parameter (`it: !Item`, `entries: !Vec[Entry]`, `from: !Account`): a mutable (exclusive) reference.
- `!` before an expression (`!items.push(...)`, `restock(!items[1], 5)`, `add(!entries, w)`, `while (!ws).next()`): a mutable borrow or mutating access.
- `|` in `catch |e|`: delimiters around the name bound to the error.

**Postfix symbols**

- `?` after a type (`-> Int?`, `top: Entry? = none`): an optional type, which may hold `none`.
- `!` after a return type (`-> Int!`, `sub transfer(...)!`): a fallible function or sub, which may return an error.
- `!` after a call (`withdraw(!from, n)!`, `transfer(!ann, !bob, 30)!`): propagate the error if there is one. Possibly it also unwraps.
- `[ ]` after an expression (`items[0]`, `entries[i]`): indexing.
- `.` after an expression (`it.qty`, `text.words`): member access.
- `()` after a name (`Item(...)`, `Vec()`): construction or call.

**Keywords I do not recognize**

- `struct`: declares a record type with named fields.
- `fun`: a function with a return type after `->`.
- `sub`: a procedure with no `->` return type.
- `error`: declares a named error type with variants (`Bank.insufficient`).
- `use`: imports a module (`use std.text`).
- `none`: the empty value of an optional type.
- `as`: binds a value to a name in an `if` or `while` condition (`if find(...) as i`).
- `catch`: handles an error. `catch |e|` binds it. `catch 0` gives a fallback value.
- `return X if cond`: a conditional return placed after the expression.
- `??`: a fallback when the left side is `none` (`find(...) ?? -1`).
- `and`, `or`, `not`: boolean operators, probably like Python.
- `print`, `Vec`, `text`: probably built-ins or library names, not keywords.

## Answers

**p01 — inventory**

1. Prints `32`. High.
2. Prints `bolt 4`. High.
3. Lines 20, 21, 22 (push) and 26 (`restock` through `!items[1]`). Line 19 only initializes `items`. High.
4. Line 32 runs once (only for `gear`, qty 2). Line 33 prints `37 0`. High.

**p02 — word counter**

1. No. `find` takes `?Vec[Entry]`, a read-only parameter. High.
2. Lines 16 (`entries[i].count += 1`) and 18 (`!entries.push`). High.
3. Prints `top: cat 2`. High.
4. Prints `6 3 -1`. The entries are the, cat, saw, dog, and, ran, so `dog` is at index 3, and `cow` is absent. High.

**p03 — bank ledger**

1. After line 27: `ann` 70, `bob` 50. High.
2. Line 28 prints a `failed:` line with the error (`insufficient`). The exact rendering of the error value is uncertain. No balance changes, because `withdraw` returns before `a.balance -= n`. High on balances, low on the text.
3. It passes the failure on. The trailing `!` propagates the error to the caller. High.
4. Line 33 calls `report(ann)`, which prints `ann 70`. The condition is false, so `check ann` is not printed. Line 35 prints `bob 45`. Output: `ann 70` then `bob 45`. High.

**p04 — job queue**

1. It removes the first job from `q.jobs` (mutable access) and binds it to `job`. High.
2. The loop continues while the queue is not empty. High.
3. In order: `ran 1 5`, `ran 3 1`, `ran 4 0`. Job 2 is skipped (cost 7 > budget 5). High.
4. Prints `2 0 0 false`. High.

**p05 — expression parser**

1. When `text.is_digit(b)` is false, meaning `b` is not an ASCII digit. High.
2. Yes. `number(s, !pos)` advances `pos` past the digits through the mutable reference. High.
3. Prints `-1 -2`. `sum("4+x")` fails on `x`. `sum("5++6")` fails on the empty number. High.
4. Prints `700 none 0`. `700` and `0` are high confidence. The text `none` for an absent optional is medium. Line 31 uses postfix `?`, which returns `none` early for `"up7"`. Medium.

**p06 — binary tree**

1. Lines 33 (`insert(!root, k)` in the loop) and 38 (`insert(!root, 45)`). Line 31 only initializes `root`. High.
2. `walk` may not modify `root`. It may modify `keys`, through `!out` and the `push` on line 27. High.
3. Prints `[20, 30, 40, 50, 70] 210`. The values are high confidence. The list format is medium.
4. Yes, line 38 runs (45 is absent). Line 39 prints `255 true`. High.

**p07 — shared configuration**

1. Prints `2 2`. High.
2. No. `web` and `db` still hold handles to `base`. Line 20 only releases one of three. High.
3. Line 25 (`<web`). Releasing `web` drops its last handle to `base`. High.
4. `db`. Line 28 moves it into `running` with `<db`. High.

Full output in order: `2 2`, `dropped base handle`, `9 2`, `released base`, `dropped web`, `1 9`, `end of main`, then `released debug` when `running` goes out of scope. The final line is medium confidence, because it depends on when scope-end drops run.

**p08 — files**

1. Prints `2 3`. High.
2. No. `backup` gets its own copy of the lines through `+log.lines`, so `log` still has 2 lines. Medium, because it depends on `+` copying a plain `Vec`.
3. `log`, which `<log` moved into `archive`. High.
4. In order: `archive app.log 2`, `close app.log`, `after archive`, `close tmp`, `end 3`, `close app.bak`. Medium, because of drop timing and the copy semantics above.

**p09 — shapes**

1. Yes. `grow(!shapes[1], 2)` changes the rectangle in place to `w=5`, `h=8`. High.
2. Prints `12`, `40`, `0`, one per line. High.
3. Prints `big circle 2`. High.
4. Prints `400 false`. `400` assumes `@size(Pixel)` is 4 bytes, since there are four `U8` fields. Medium.

**p10 — stack calculator**

1. `(!stack).pop()` removes the last element and returns it as an optional. If the stack is empty, it returns `none`, and `take` reports `underflow`. High.
2. A failure propagation. The `!` after the call passes the error up. High.
3. Prints `14` and `2`. High.
4. Line 35 prints `-1 -2`. Line 39 prints `6`. High.

**p11 — task list**

1. `none`. Line 24 finds `call` has no due date, so `postpone` does nothing. High.
2. In order: `rent -4`, `call -1`, `taxes 20`. High.
3. Prints `2 8`. `open` is 2, and `"bring id"` has 8 characters. High, assuming `Text` is a built-in string type. `Text` is not declared and `std.text` is not imported. Medium.
4. Yes, line 32 pops `taxes` out of `tasks`. Line 34 prints `2`. High.

**p12 — game**

1. No. `start = +players` makes a copy, so `start` is a snapshot. Medium-high.
2. Lines 20, 21 (push), 27 (`for p in !players`), 28 (`bump` through `!p.score`), 29 (`!players[...]` creates a write handle), and 30 (`target.lives -= 1`). Line 19 only initializes. Medium on line 29.
3. `done` is true when neither player is alive, meaning both have `lives <= 0`. High.
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. High.

## Rejected programs

- **r01: line 11.** `charge` writes `a.balance -= n` through `a: ?Account`, which is a read-only parameter. High.
- **r02: line 18.** `r.pages.len` reads `r` after `<r` on line 16 released it. High.
- **r03: line 14.** `cart.items.pop()` is a mutating call without the `!` write marker. The other mutating calls in the programs all use `!`. High.
- **r04: line 14.** `!list.push` mutates `list` while `top = ?list[1]` still holds a shared borrow that line 15 reads. Medium. The conflict could also be reported at line 15.

## Revised meanings

| Symbol | Final meaning | First guess |
|---|---|---|
| `?` prefix (type or expression) | Read-only borrow. At call sites the marker is optional, so `value(items)` and `value(?items)` both work. | Read-only view. Correct, but I had not noticed the marker is optional at call sites. |
| `!` prefix | Mutable borrow, required at call sites that write. It is also required before mutating methods (`!items.push`, `(!stack).pop()`). | Mutable reference. Correct. |
| `!` postfix on a call | Propagate the error to the caller, like `try` in other languages. | Propagate, possibly unwrap. Correct except for the unwrap. |
| `?` postfix on a type | Optional type. | Optional type. Correct. |
| `?` postfix on an expression | Unwrap the optional, or return `none` from the enclosing function if it is absent (`digit(s[0])? * 100`, `due? - today`). | Not in my list. I did not know this form. |
| `!` postfix on a return type | The function or sub can return an error. | Fallible. Correct. |
| `*` prefix on a constructor, `*T` type | Create or type a reference-counted shared handle. | Not in my list. Not seen in p01–p03. |
| `+` prefix on an expression | Make a new handle for a `*` value (refcount +1). On a plain value such as `+players` or `+log.lines`, it copies. | Not in my list. I assumed unary plus. |
| `<` prefix on an expression | Release or move a value. A standalone `<x` releases a handle, and `f(<x)` moves `x` into `f`. | Not in my list. I assumed comparison. |
| `drop(!self)` in a struct | Destructor. It runs when the last handle is released or the value goes out of scope. | Not in my list. |
| `@size(T)` | Compile-time size of a type in bytes. | Not in my list. |
| `X if c else Y` | Conditional expression. | Not in my list. |
| `match` with `.variant(x) => ...` | Pattern on an enum. `_` is the wildcard. `pass` is a no-op. | Not in my list. |
| `for x in !c` / `?c` | Iterate mutably / read-only. | Not in my list. |
| `catch`, `??`, `none`, `as`, `error`, `sub`, `fun`, `use`, `not`, `and`, `or`, `print`, `Vec` | As I guessed. | As I guessed. |

## Where I hesitated

- **p01 line 31, `not it.qty > 3`.** I first wondered whether `not` applied only to `it.qty`. It has to bind loosely, because `not` on an `Int` would not type-check.
- **p02 line 33, `e.count != 1 and not e.word == "the"`.** Same question about `not` precedence. Resolved the same way.
- **p03 line 17, the final `!` of `withdraw(!from, n)!`.** I considered whether it negates or unwraps. It propagates the failure.
- **p03 line 33, `not bob.frozen or report(ann) != 70`.** I first thought `or` might short-circuit and skip `report`. The left side is false, so `report` runs and prints `ann 70`.
- **p04 line 15, `(!self.jobs).remove(0)`.** I was unsure whether `remove` returns `Job` or `Job?`. The declared `-> Job` settles it.
- **p05 line 15, `digit(s[pos]) ?? return Parse.bad`.** I had to work out that the `return` is the fallback.
- **p05 line 14, the constant `43`.** Inferred as ASCII `'+'` from the `- 48` in `digit`. Medium confidence.
- **p05 line 25, `number(s, !pos)!`.** I first read `!pos` as negation. It is a mutable borrow, and it changes `pos`.
- **p05 line 31, `digit(s[0])? * 100`.** I did not know postfix `?` on an expression. I first thought it was an optional type again.
- **p06 line 8, `insert(!n.left if key < n.key else !n.right, key)`.** I had to work out the conditional expression and that each branch is a mutable borrow.
- **p06 line 10, `slot = Box(...)` in the else branch.** I was unsure whether assigning through a `!` parameter is allowed. It is.
- **p07 line 10 and line 16, `*Config`.** I first thought of a pointer dereference. It is a shared handle.
- **p07 line 17, `config: +base`.** I first thought of unary plus. It makes a new handle.
- **p07 line 20, `<base` as a bare statement.** I first thought it was a comparison. It releases a handle.
- **p07 end of output, `released debug`.** Drop timing at scope end is an assumption. Medium.
- **p08 line 21, `+log.lines`.** I was unsure whether `+` shares or copies the `Vec`. I concluded copy from the program's structure. Medium.
- **p08 line 24, `archive(<log)` and the `close` line.** I had to infer that the callee drops its owned parameter at the end of the call. Medium.
- **p09 line 34, `@size(Pixel)`.** I had not seen `@` before. I assumed 4 bytes.
- **p09 line 32, `.circle(r) if r > 1`.** I first took `if` after a pattern as a guard. It is one.
- **p10 line 36–38, `catch |e|` followed by an indented block.** I had to work out that the block's last value is the fallback.
- **p11 line 15, `due? - today`.** I first thought of `!`-style propagation. It returns `none` when `due` is absent.
- **p11 line 29, `Text`.** `Text` is not declared and `std.text` is not imported, unlike `String` in p02. I assumed a built-in string type.
- **p12 line 22, `start = +players`.** I was unsure whether `start` aliases `players`. I concluded it is a copy.
- **r01.** I considered line 16 (`charge(?acct)`, where `acct` is a local) before settling on line 11.
- **r04.** I considered line 15 (the read of `top`) before settling on line 14 (the conflicting mutation).

## Overall

**6/10.** The core is readable once the markers are learned. Structure, types, loops, and `if ... as x` read like Python with Rust-like ownership. The per-line rejection rule (`!` for writes, `?` for reads, `!` for mutating methods) is consistent, and the rejected programs were easy to explain.

What made it harder:

- `?`, `!` and `+` each appear as both prefix and postfix, and `!` also means "not" in `!=`. The same character can mean a borrow, an error propagation, or a fallible type depending on position.
- The call-site `?` marker is optional, but `!` is required for writes. That is a rule I had to infer from the programs.
- `*`, `+` and `<` are ownership operators with handle, copy and release meanings. None of these were in my first guesses, and they are the source of most of the output subtlety.
- `Text` is used without an import, unlike `String`.
- Printed formats for lists, `none` and error values are not shown anywhere, so I had to guess them.
