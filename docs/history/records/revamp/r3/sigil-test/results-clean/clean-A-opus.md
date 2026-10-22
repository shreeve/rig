# Rig reading exercise

## Step 1: First guesses (after reading only p01–p03)

**Prefix symbols**
- `?T` on a parameter type (`it: ?Item`, `?Vec[Entry]`): a read-only (shared) borrow. The function can look at the value but not change it.
- `!T` on a parameter type (`it: !Item`, `a: !Account`): a mutable borrow. The function can change the caller's value.
- `?expr` at a call site or in an assignment (`?items[0]`, `?entries`, `?top`): explicitly lends the value read-only. In p03 `report(ann)` has no prefix, so I guess plain passing is also a read-only lend and `?` just makes it explicit.
- `!expr` at a call site (`!items.push(...)`, `restock(!items[1], 5)`, `transfer(!ann, ...)`): lends the value for writing. In `!items.push(x)` I think the `!` applies to `items`, the receiver, and not to the result of the call. `(!ws).next()` is the same thing with brackets to make the binding clear.
- `-1`: ordinary unary minus.

**Postfix symbols**
- `T?` (`Int?`, `Entry?`): an optional type, meaning a value or `none`. `?Entry?` is a read-only borrow of an optional Entry.
- `T!` (`Int!`): a result that may be an error. `sub transfer(...)!` means this procedure can fail.
- `expr!` (`withdraw(!from, n)!`, `transfer(...)!`): if the call fails, pass the error on to the caller (like Rust's `?`). In `main` I guess an unhandled error would abort.
- `a ?? b`: use `b` when `a` is `none`.

**Keywords I don't recognise**
- `fun` / `sub`: `fun` returns a value (the last expression is the result). `sub` is a procedure with no result.
- `error Bank` followed by indented names: declares a set of error values (`Bank.frozen`, …).
- `none`: the empty optional.
- `if X as i` / `while X as w`: if the optional (or iterator step) has a value, bind it to `i` and run the body.
- `return v if cond`: a trailing-condition guard.
- `catch |e| stmt` / `catch 0`: handle an error, either binding it as `e` and running a statement, or swapping in a default value.
- `use std.text`: imports a module.
- `not`, `and`, `or`: boolean operators. `not` seems to bind looser than comparisons (`not it.qty > 3` = `not (it.qty > 3)`).

---

## Step 2: Answers

### p01 — inventory
1. `32` (12 + 0 + 20). **High**
2. `bolt 4` **High**
3. Lines 20, 21, 22 (`push`) and 26 (`restock(!items[1], 5)`). Line 19 is the initial value. **High**
4. Line 32 runs **once** (`low: gear`). Line 33 prints `37 0` (the nut now has qty 5, so 12 + 5 + 20). **High**

### p02 — word counter
1. No. `find` takes `?Vec[Entry]`, which is read-only. **High**
2. Lines 16 and 18. **High**
3. `top: cat 2` **High**
4. `6 3 -1` **High**

### p03 — bank ledger
1. ann 70, bob 50. **High**
2. It prints `failed: insufficient`; it might be rendered as `failed: Bank.insufficient`, since I can't tell how errors print. No balance changes: the withdraw fails before deducting anything, and `to.balance += n` never runs. **High** on behaviour, **medium** on the exact text.
3. It passes a failure on. **High**
4. `ann 70` then `bob 45`. `check ann` is not printed: `not bob.frozen` is false, so `report(ann)` runs, prints, and returns 70. Bob is at 45 because line 29 withdrew 5. **High**

### p04 — job queue
1. It takes `q` mutably and removes and returns the first job (`jobs.remove(0)`). **High**
2. It keeps going while `q` is not empty. **High**
3. `ran 1 5`, `ran 3 1`, `ran 4 0`. Job 2 (cost 7) is skipped. **High**
4. `2 0 0 false` **High**

### p05 — expression parser
1. When `b` is not an ASCII digit character. **High**
2. Yes. `pos` is passed as `!pos`, and `number` moves it forward to the `+` or the end of the string. **High**
3. `-1 -2`. `"4+x"` gives `Parse.bad` and `"5++6"` gives `Parse.empty`. **High**
4. `700 none 0`. The postfix `?` passes `none` up for `"up7"`. **Medium**, because I'm not sure `none` prints literally as `none`.

### p06 — binary tree
1. Lines 33 and 38. Line 31 is the initial value. **High**
2. `walk` cannot modify `root` (read-only `?` parameter, passed with no prefix). It can modify `keys` (`!keys`). **High**
3. `[20, 30, 40, 50, 70] 210` **High** on the values, **medium** on the list format.
4. Yes, line 38 runs because 45 isn't in the tree. Line 39 prints `255 true`. **High**

### p07 — shared configuration
1. `2 2` **High**
2. No. `web` and `db` still hold handles. **High**
3. Line 25 (`<web`). Line 23 had already moved `db` off base, so `web` held the last handle. **High**
4. `db`, which was moved into `running` by `<db`. **High**

### p08 — files
1. `2 3` **High**
2. No. `+log.lines` made a separate copy. **High**
3. `log` **High**
4. **Medium-high** (I'm assuming locals are dropped at the end of `main`):
```
archive app.log 2
close app.log
after archive
close tmp
end 3
close app.bak
```

### p09 — shapes
1. Yes. `shapes[1]` becomes `rect(w: 5, h: 8)`, because w += 2 and h *= 2. **High**
2. `12`, `40`, `0`, one per line. **High**
3. `big circle 2` **High**
4. `400 false`. Pixel is 4 bytes and `@size` is the size in bytes. **Medium**

### p10 — stack calculator
1. `stack` is borrowed mutably and its top element is popped. If one existed it is bound to `x`; otherwise the code falls through to the underflow error. **High**
2. Failure propagation. **High**
3. `14` and `2` **High**
4. Line 35: `-1 -2` (underflow, then leftover). Line 39: `6`; the catch block doesn't run. **High**

### p11 — task list
1. `none`. `postpone` only acts if there is a value. **High**
2. `rent -4`, `call -1`, `taxes 20` **High**
3. `2 8` **High**
4. Yes, it pops `taxes`, and line 33 prints `dropped taxes 25`. Line 34 prints `2`. **High**

### p12 — game
1. No. `+players` is an independent copy. **High**
2. Lines 20, 21, 27–28 (the `for p in !players` / `bump`), and 29–30 (`target = !players[...]`, then `target.lives -= 1`). **High**
3. When both players have 0 lives left. **High**
4. Line 32: `4 ana 10`. Line 33: `0 true`. **High**

### Rejected programs
- **r01, line 11:** `a.balance -= n` writes through `a: ?Account`, which is read-only. **High**
- **r02, line 18:** `r.pages.len` uses `r` after it was moved out by `archive(<r)` on line 16. **High**
- **r03, line 14:** `cart.items.pop()` changes `cart.items` without the `!` write marker. It needs `(!cart.items).pop()`. **High**
- **r04, line 14:** `!list.push(...)` changes `list` while the read borrow `top = ?list[1]` is still live (it's used on line 15). **High**

---

## Step 3

### Revised meanings
- `?x` / `?T`: read-only borrow. Confirmed. The `?` at a call site is optional (`walk(root, …)`, `report(ann)`), but the parameter's `?` type always applies.
- `!x` / `!T`: write borrow. Confirmed. It is required at every place where a value is modified, including method receivers (`!q.add`, `(!stack).pop()`, `for t in !tasks`, `match !s`, `if !due as d`).
- `T?`, `??`, `if … as`: confirmed.
- Postfix `expr?` (new): pass `none` up from a function that returns an optional (`digit(s[0])? * 100`, `due? - today`). It is the optional version of `expr!`.
- `T!`, `expr!`, `catch`: confirmed. `catch |e|` can also take an indented block whose last expression is the value (p10 lines 36–38).
- `*T` (new): a shared, reference-counted handle.
- `+x` (new): duplicate. On a `*` handle it adds another handle; on a plain value it makes an independent deep copy (p08, p12).
- `<x` (new): move the value out or end it. On its own as a statement it drops the variable now; as an argument it hands ownership over. Either way the variable can't be used afterwards.
- `drop(!self)`: a destructor. `@size(T)`: a compile-time builtin. `match` with `.variant(...)` patterns, `_`, and `if` guards. `pass` is an empty statement. `a if c else b` is a conditional expression.
- **Wrong first guess:** I thought plain passing was just an implicit `?`. That was right for reads, but I hadn't realised `!` is *required* for any write. Leaving it out is a compile error (r03). Otherwise my guesses held up, though they were incomplete: I hadn't yet seen `*`, `+`, `<`, `@`, or postfix `?`.

### Where I hesitated
- `!items.push(x)`: whether the `!` applies to `items` or to the whole call result. I read it as the receiver, because the brackets in `(!q).next()` show the same idea.
- `not it.qty > 3` / `not e.word == "the"`: this could be `(not it.qty) > 3`. I chose `not (…)` because the other reading wouldn't type-check.
- `?Entry?` and `!Box[Node]?`: two `?`s with different meanings on either side of the type name. Easy to misread.
- `?` appears in four roles: read borrow, optional type, `??`, and postfix none-propagation (`due? - today` looks a lot like the ternary operator from C-like languages).
- `!` also has four roles: write borrow, error type, error propagation, and in `transfer(...)!` / `sub …()!` both the declaration and the use. Question 3 on p03 and question 2 on p10 are exactly this trap.
- `+` as a prefix looks like unary plus, and `<base` on a line by itself looks like a stray comparison.
- `+log.lines`: whether it is a shared handle or a deep copy. I decided it's a copy because the field type is `Vec[String]`, not `*Vec`.
- p03 line 33: whether `or` short-circuits. That decides whether `report(ann)` prints. I assumed it does short-circuit, so `report(ann)` runs only because the left side is false.
- How `none`, error values and Vecs print (`none`, `insufficient` vs `Bank.insufficient`, `[a, b]`).
- p07: `db.config = +debug` silently releases the old handle. That is easy to miss when working out which line prints `released base`.
- p12 line 29: whether `target = !players[...]` counts as the modifying line, or only line 30 does.

### Overall
**6/10.** The indentation-based layout, `fun`/`sub`, trailing `if`, and `as`-binding were easy to read straight away. Marking every write with `!` actually helps answer "where is this modified?" questions quickly. The cost is that `?` and `!` are each overloaded four ways, and the meaning flips depending on whether the symbol is before or after a name. The ownership sigils `*`, `+` and `<` can't be guessed from p01–p03 and look like arithmetic or comparison operators. After seeing a few examples it reads consistently, but on first contact it's easy to get wrong.
