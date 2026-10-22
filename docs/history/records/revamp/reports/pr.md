This PR is a full pass over the compiler, tests and docs before the standard library work begins. It fixes memory-safety and "accept means correct" bugs, builds in the approved language decisions, and splits the docs into syntax, meaning and a guide for newcomers.

## Correctness
- **Memory-safety holes closed.** The ownership checker accepted some programs that freed memory twice or used it after freeing. Examples: `?? return` over a borrowed optional, `for x in <w` over a borrowed Vec, a borrow of a temporary stored past its statement, joined `as` chains, and stores lost in guards. Each is now rejected, with a test.
- **Accepted programs whose Zig failed are fixed or rejected:** a `defer` that declares a name, `_ = +x`, integer operators on float literals, a generic `T!` filled with an error set, a `!T` lent as a copied `?T`, imported aliases, and taking an element out of a `Cell[Vec[T?]]`.
- **An errdefer now runs when a branch block's final value fails the function.**
- **Cell and Signal count toward the size limits,** so a large value can no longer get past the stack guard.
- **Converting NaN to an integer panics.**

## Language changes (approved)
- **`match` must be exhaustive everywhere.**
- **Aliases work fully as types,** including `Byte(x)` and `Byte.max`.
- **Labeled jumps are allowed after `??` and `catch`.**
- **A function may return a slice of a `?[N]T` parameter.**
- **`for x, i` keeps its order and gets a hint.**
- **A borrow of a temporary is allowed where it cannot outlive the temporary:** a call argument, a `print` argument, a `match` subject, a `for` source, or the optional an `if`/`while … as` binds.

## Diagnostics
- **Did-you-mean suggestions** for unknown names, types, fields and methods.
- **Hints for habits from other languages,** such as `null`, `True`, `v.len()`, `&x` and `{`.
- **Clearer messages** for missed guarded match arms, stores through a borrow, and optional propagation in a `sub`.

## Front end and internals
- **The lexer lost its position-specific tokens.** 11 were merged into their base tokens (124 tokens → 114, 659 parser states → 636), and the text-scanning heuristic for `]` is gone. The grammar is still conflict-free.
- **One constant evaluator.** Module constants and local constants are now folded by the same code.
- **The ownership pass is skipped on modules that have type errors,** so a type error no longer produces follow-on ownership errors.
- **Performance fixes:**
  - `nested_loops_settle_quickly` went from 106s to 0.01s.
  - Exponential constant checks and deep struct chains no longer blow up.
  - Tarjan's cycle search (used for recursive types) is now iterative.

## Docs
- **SYNTAX.md** is now only how each form is written.
- **SPEC.md** is what each form means, in §1–18.
- **WELCOME.md** is new: a guide for programmers from Rust, Zig, C, Python, Ruby, JavaScript and Go, where each common habit is shown with the error it produces.
- **The other docs were checked for truth:** INTERNALS, DESIGN, FAQ, the Zig notes and ROADMAP.
- **ROADMAP** now lists the compiler debts, the open language questions and the settled standard-library decisions.
- **Every `rig` example is run by the suite,** and there are no broken links.

## Tests and CI
- **Faster runs:** per-program caches, the longest tests first, a perl fallback when `timeout` is missing, `# errors: N` and `# timeout: N` directives, and pruning of stale output.
- **The pruning is safe:** the runner deletes only in output directories it has marked as its own.
- **CI:** concurrency groups and a cached Nexus build.

## Numbers (5f2bdbc → this branch)

| | Before | After |
|---|---|---|
| Hand-written source | 29,490 lines | 30,341 lines |
| Grammar | 886 lines | 848 lines |
| Generated parser | 5,450 lines | 5,387 lines |
| Tests | 1,671 | 1,729 |
| Docs | 11,745 lines | 10,025 lines |

The tests number is after removing 63 duplicate doc examples; about 120 tests are new. The source grew because of the language changes, the hints and the new safety checks.

Local verification: `./test/run` passes (1729 passed, 0 failed, 0 known), and `zig build test` passes.
