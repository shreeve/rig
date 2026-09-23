# Rig examples

Short programs that show what Rig looks like. Each one is run by
`./test/run` and must print exactly its `# expect:` block with no leaks.

| File | Shows |
|---|---|
| `hello.rig` | the smallest program |
| `ownership_tour.rig` | move `<x`, read borrow `?x`, shared `*x`, clone `+x`, drop `-x` |
| `shapes.rig` | payload enums, `match`, methods, a generic type |
| `resources.rig` | a user-defined `drop` plus compiler-generated drop glue |
| `counter_closure.rig` | an owned closure capturing a shared `Cell` |
| `memo_canary.rig` | a small reactive source built from `Cell`, `Vec`, and `Closure1` |

The full test suite lives in `test/` (see `test/README.md`).
