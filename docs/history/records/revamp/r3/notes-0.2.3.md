Rig 0.2.3 fixes memory-safety holes found in 0.2.2, fixes a remainder that crashed on x86_64, decides once whether a value copies, and builds four rules the Core already stated: `!` lends any value to write, plain structs copy out of a view, views fill containers, and `|+x|` clones what it captures. **Everyone on 0.2.2 or earlier should upgrade.**

## Fixed
- **A `while … as h: step` loop could read freed memory.** The checker walked the step where it is written, before the body. So when the step used the condition's binding (`while mk(?v) as h: k += h.s[0]`), the body could grow the Vec or Text `h` views, and the step then read the freed buffer. The checker now walks the loop in the order it runs: condition, body, step. A step that reads a view the body invalidates is rejected.
- **A labeled `continue` from a nested loop could skip the outer loop's step.** When the outer loop had a joined condition (`… as h and …`) or a jump in its condition (`catch break`), `continue :outer` from a nested `while` did not run the outer step. The program could then use a value after it was moved and freed, or the emitted Zig failed to compile. Every `continue` now reaches its own loop's step at any depth.
- **A write view could be copied out of a read view.** With `r: ?W?`, where `W` holds a write view, `x = r ?? W(...)` and `x = r?` copied the write view out of something only lent to read, and then wrote through it. Whether a value may be duplicated is now one fact, `copies`, asked at every site that duplicates one, and a value holding a write view does not copy.
- **Fallible and optional views emitted Zig that didn't compile.** Returning a `?P` from a `(?P)!` function, `catch` of a fallible view, and `??` or `catch` of a view stored into a `P?` now work.
- **`Int.min % -1` killed the program on x86_64** with "Arithmetic exception", while printing 0 on aarch64. A signed remainder by -1 is now 0 on every target, as constant folding already gave.

## New
- **`!` lends any value to write, named or temporary.** `!mk().bump()`, `x = !mk().take()`, `!mk().items.push(1)`, `grow(!mk())` and `(!mk()).r = v` now work. A temporary lent to write lives until its statement ends; a view of it is usable only within that statement. A write method on a temporary without `!` is still rejected, with the hint "add `!`".
- **Plain structs, arrays and optionals copy out of a view** wherever a value is expected (`p: Point = r` with `r: ?Point`). A binding with no type keeps the view: `b = r` is still a `?Point`.
- **Read views as container elements:** `fill`, `copy` and `[n of x]` take read-view elements; each copy carries its loan.
- **`|+x|` captures what `+x` gives,** so it deep-clones an owner such as a Vec.
- **A value holding a write view cannot be cloned,** as the Core says; `+h` and `|+h|` are rejected.

## Programs 0.2.2 accepts that are now rejected
The loop forms above whose step reads a view the body invalidates, and the write-view copies above. Each was unsafe on 0.2.2. A fallback that would give up a value holding a write view (`(r ?? W(...)).w.len`) is also rejected. Comparisons over every test and probe show one more: a loop that grows the Vec only on a path that returns before the step (`w48`), rejected because the checker tracks liveness by position, not by path.

## Known remaining
Reviews of the loop fix found two more cases of the same class, present in 0.2.2 and not fixed in 0.2.3. Both are being fixed next by lowering every loop through one shape that the checker walks:
- **The step runs before the body's drops.** A loop with a joined or `catch break` condition, whose step reads the condition's binding and whose body has no `continue`, runs the step before the body's `defer`s and drops.
- **An unlabeled `continue` in a nested loop's `else`** skips the outer loop's step.

Reusing a label name in a nested loop can also make the emitted Zig fail to compile; this is not a safety issue.

## Verification
- New reject and behavior tests for every form, plus every reviewer probe in `test/corpus/`.
- The full suite, the reviewer corpus, the program matrix and the unit tests pass under the sanitizing allocator on Linux x86_64 and macOS.
- Independent reviews of each change. The reference checker reports no program the compiler accepts and it rejects.
- CI passed on Linux and macOS.

## Requirements
Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #58 (`!` on any value), #59 (loop holes), #60 (remainder), #61 (the copies fact), and the version bump PR.
