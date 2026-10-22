Rig 0.2.7 lets a temporary that holds a `Cell` be lent to read and changed through its Cell, returns Rig's own type names from `@name`, and fixes a checker crash and two compiler errors that 0.2.6 could hit.

## New
- **A temporary holding a Cell works like any other temporary.** It lives until its statement ends, a change through its Cell lands in it, and its `drop` sees the change:

  ```rig
  bump(?mkc())             # lend it to read; bump changes its Cell
  mkc().hit()              # a ?self method on it
  made().hits.set(4)       # set, replace, push, pop, clear, c[i] = e
  ```

  The same holds for a value that branches, such as `(a if c else mk()).hit()`, which changes `a` in place or the made value in its slot. A branch that would have to copy a unique value, such as `?(a if c else mkc())`, is still rejected.
- **`@name(T)` returns Rig's names:** `@name(Int)` is `"Int"`, not `"i64"`; `@name(Point)` is `"Point"`, not `"__rig_main.Point"`; and `@name(Vec[Int])`, `@name(Int?)` and `@name(?Point)` now work, directly and inside generic code. Every name comes from the compiler's one type printer.

## Fixed
- **The ownership checker could crash** on a value made in a `catch` handler and viewed after the handler, such as `(f() catch mk().t).me().c.get()`. The checker now holds a handler's temporaries for the whole statement, as the generated code does.
- **`mk(5).get(0)` on a `Cell[Vec]` leaked** the Vec; a `<`-moved branch lent to write (`poke(!((<a) if k else M))`) failed with an internal error. Both are fixed.
- **A `none` in a branching optional,** such as `(o if k else none)?.hit()`, could fail with an internal error or a Zig compile error. A `none` branch now has its own place in the one leaf walk the compiler uses for branching values.

## Changed
- `(<c).push(1)`, a Cell method on a moved receiver, is rejected, as `(<c).set(…)` already was. Bind the value first.

## Tooling
- CI runs each system's tests in four parallel shards: about 10 minutes instead of about 25.
- The test runner compares output through a pipe, which removes a false failure on macOS ("Bad file descriptor").
- The roadmap gains a kernel and freestanding-code track.

## Known follow-ups
- A temporary made in a `match` arm that views the arm's binding is rejected; a later round will keep an arm's temporaries in the arm.
- Two older edge cases: a `defer` that reads a name lent to write is rejected when the statement `continue`s, and the drop order on `?? continue` differs from SPEC's "last made first".

## Verification
- Two independent reviews found no soundness hole. More than 10,000 generated programs that the compiler accepts print exactly the expected output in both debug and `--release` builds on macOS and Linux, with no use of freed memory, no leak, no checker panic (with Debug and ReleaseSafe compilers) and no disagreement with the reference checker.
- The full suite, the reviewer corpus, the program matrix and the unit tests pass under the sanitizing allocator. CI passed on Linux and macOS.

## Requirements
Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #72 (CI shards), #73 (roadmap), #74 (`@name`), #75 (test runner), #76 (Cell temporaries), and the version bump PR.
