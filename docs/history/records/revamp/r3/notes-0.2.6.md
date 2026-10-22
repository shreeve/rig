Rig 0.2.6 fixes programs that change a `Cell` through a read view: in optimized builds they could crash, print wrong values, or corrupt the heap. It also requires a parameter list on every function definition and gives Rig its own names for the safe compiler builtins. **Everyone on 0.2.5 or earlier should upgrade, especially anyone shipping `--release` builds.**

## Fixed
- **Changing a `Cell` through a read view was undefined behaviour in optimized builds.** A `?self` method or a `?T` parameter was compiled to a read-only Zig pointer, and the Cell was written through it anyway. Debug builds happened to work, but `--release` builds could hit a bus error or segmentation fault, lose the change, or double-free. Even a plain counter showed it:

  ```rig
  struct C
    c: Cell[Int]

    sub hit(?self)
      self.c.set(self.c.get() + 1)
  ```

  A view of a value that holds a Cell is now compiled as a mutable pointer, and its storage as a variable. The compiler decides this once, by whether the type holds a Cell by value, and writes the answer into every generated type, so the runtime never decides it again. No `@constCast` is left in the generated code.
- **Generic code** instantiated with a type that holds a Cell follows the same rule. A `?self` call that would have no place to keep the change is rejected when the generic is instantiated.

## Breaking changes
| 0.2.5 | 0.2.6 | Fix |
|---|---|---|
| `sub main` / `fun answer -> Int` | rejected | `sub main()` / `fun answer() -> Int`; the error shows the exact header to write |
| `@sizeOf(T)`, `@alignOf(T)`, `@TypeOf(x)`, `@typeName(T)` outside `raw` | rejected | `@size(T)`, `@align(T)`, `@type(x)`, `@name(T)`; Zig's own builtins keep their names inside `raw` |
| a `?self` method on part of a branch whose made value has no place to live, such as `(w if k else mk(5)).t.hit()` | rejected | bind the made value first; on 0.2.5 this wrote through read-only memory |

## Also new
- `./test/run style` checks the code style of tests, examples, std and doc examples: a parameter list on every definition, one blank line between top-level declarations, and no trailing whitespace.
- Tests can be marked `# release` to also run as an optimized build. A Cell grid of 131 programs runs in both debug and `--release` on macOS and Linux; 0.2.5 fails 47 of them in release.

## Verification
- The full suite, the reviewer corpus, the program matrix and the unit tests pass under the sanitizing allocator on Linux x86_64 and macOS, and the Cell grid passes in release on both.
- An independent review found no remaining write through read-only memory, and no wrong output in either build mode.
- Release binary sizes and a Cell-heavy benchmark are unchanged.
- CI passed on Linux and macOS.

## Requirements
Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #69 (parameter lists, builtins, style), #70 (Cells in release builds), and the version bump PR.
