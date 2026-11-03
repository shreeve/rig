# Panel brief: keep or cut Rig's unused Rust-like features (2026-10-28)

The owner asked which of the Rust-like features Rig has built it probably doesn't need. A usage census of real Rig code found these with no use, or nearly none. It counted code only, no comments, across about 9,500 lines of std, examples and benchmarks, plus about 198,000 lines of Trig, the TypeScript checker written in Rig (`~/Data/Code/trig/src`):

| Candidate | Rust analogue | std | examples/bench | Trig |
|---|---|---|---|---|
| Weak handles: the type `~T`, making `~x`, capture `\|~x\|`, upgrading `*w` to `*T?` | `Weak` | 0 | 0 | 0 |
| API objects' holding forms `^{A}`, `*{A}`, `~{A}` (and, for comparison, the view forms `?{A}`, `!{A}`) | `Box<dyn>`, `Rc<dyn>`, `Weak<dyn>`, `&dyn` | 0 | 3 | 0 |
| `*Frozen[T]`, a value no one changes, shared across tasks | `Arc<T>` of immutable data | 0 | 0 | 0 |
| `once ?fun`, a callable view called at most once | `FnOnce` | 1 | 0 | 0 |
| Boxes `^T` | `Box<T>` | 0 | 3 | 0 |
| For comparison, keep-but-freeze: user-level `api` declarations and `add T: A` | traits and impls | 0 | 2 | 0 |

Well used, for contrast: several results (`a, b = f()`), `Table`/`Slot`, `*T` counted handles, `Copy`/`Clone` bounds, error sets, `keeps`, `Simd`.

## Rules
- **Recommendations only: change no file in any repository.** Write only your report, in this directory.
- Repo: `~/Data/Code/rig`. Read origin/main with `git -C ~/Data/Code/rig show origin/main:PATH` or `git grep ... origin/main`.
- Read `AGENTS.md` first: the North Star, the vocabulary (lend, view, loan; never "borrow"; "object", not "struct"; `@` is self), and "Taste".
- To test a claim, run Rig: `GIT_DIR=$(git -C ~/Data/Code/rig rev-parse --git-common-dir) ~/Data/Code/rig/tools/baseline origin/main` prints the path of a `rig` built at main. Work in your own scratch directory with `RIG_OUT_DIR` set to it.
- Low use is evidence, not proof: Trig is a compiler written arena-style. Consider GUIs, graphs, plugins, servers and tasks.
- Cutting a feature rejects programs a release accepted. A cut touching ownership goes through CORE review and the owner (AGENTS North Star 5).

## Report
Write `expert-<name>.md` here: a table with one row per candidate, giving your verdict (**cut**, **fold** into another feature, **keep**, **keep but freeze**), its default, and the reason; then at most 500 words. Reply in ≤150 words.
