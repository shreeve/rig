Rig 0.2.5 makes `<` mean one thing everywhere: **`<` always leaves its source done.** Making the rule exact closed several ways to use freed memory through `<` that 0.2.4 accepted. **Everyone on 0.2.4 or earlier should upgrade.**

## The rule
- `<name` ends the name, whatever its type.
- `<s.o`, on an optional field or element, takes the value and leaves `none`.
- `<` anywhere else is rejected. That covers a field or element that isn't optional, a part of a value made in the statement, a part of a branching value, a capture, a function and a constant. An owning part still moves out with `replace` or `swap`.

What `<` does to its source is now decided by one fact. Every place `<` can appear asks it: an argument, `return`, `break`, `for x in <e`, `match`, a constructor field, and each branch of an `if`, `??`, `catch`, `?` or `!` operand.

## Fixed
These programs were accepted by 0.2.4 and used freed memory:
- `w = <(a if c else b).v` moved a Vec out of `a` while `a` still dropped it.
- `for x in <mk().v`, and variants such as `<(<a).v`, `<(+a).v` and `<[<a, <b][0].v`, took a part out of a value that was then freed.
- `<(mk().v if c else w)`, `<(get() catch mk().v)` and `<mk().o?` did the same through a branch.

## Breaking changes
Each was accepted by 0.2.4. In every case where a copy was meant, the fix is to remove the `<`.

| 0.2.4 | 0.2.5 | Fix |
|---|---|---|
| `m = <s.n` with a plain field: copied, `s.n` stayed usable | rejected | `m = s.n` |
| `e = <v[0]` with plain elements: copied | rejected | `e = v[0]` |
| `<(n if c else 5)`, `<(o ?? n)`, `<o?`: copied, or did not empty | rejected | move inside the branch (`<n`), or before the `?` (`(<o)?`) |
| `<n` on a `\|+n\|` copy capture: left it unchanged for the next call | rejected | `n` |
| `<mk().n`, `<(!mk()).o`: did nothing | rejected | `mk().n` |
| `<f` of a function | rejected | `f` |

A survey of every test, example, std module and doc example found 12 programs that relied on the old behaviour, none of them in examples, std or the docs.

Also new: a consuming (`<self`) method now takes a copy of a receiver that copies, so `s.p.into()` works on a plain field, and through a view.

## Verification
- A generated grid of 28,815 programs (sources × wrappers × carriers × types): every program the compiler accepts runs with no leak and no use of freed memory, and the reference checker agrees with the compiler on every one.
- Two independent reviews. Every reviewer probe is kept in `test/corpus/`.
- The full suite, the reviewer corpus, the program matrix and the unit tests pass under the sanitizing allocator on Linux x86_64 and macOS.
- CI passed on Linux and macOS.

## Docs
WELCOME and SYNTAX now state three rules on their first pages: a prefix sigil says how you hold a value and a suffix `?`/`!` is control flow, with negation written `not`; in `|…|`, a sigil marks a capture and a bare name a parameter; there is no implicit shadowing.

## Requirements
Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #66 (docs), #67 (`<`), and the version bump PR.
