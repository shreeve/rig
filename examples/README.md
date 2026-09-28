# Rig examples

Short programs that show what Rig looks like, from the smallest program
to a small reactive library. Each file ends with the output it prints,
in an `# expect:` block, and `./test/run` runs every one of them
leak-checked. Run one with:

```bash
bin/rig run examples/ownership_tour.rig
```

| File | Shows |
|---|---|
| [hello.rig](hello.rig) | the smallest program: a `sub main` and a `print` |
| [ownership_tour.rig](ownership_tour.rig) | the ownership sigils at work: move `<x`, read borrow `?x`, shared `*x`, clone `+x`, drop `-x`, and automatic drop at the end of scope |
| [shapes.rig](shapes.rig) | data modeling: an enum with payload variants, exhaustive `match`, a struct method with a `?self` receiver, and a generic `Pair[T]` |
| [resources.rig](resources.rig) | a user-defined `drop` body, followed by the compiler-generated drop glue that releases a shared field |
| [generics.rig](generics.rig) | a generic `Stack[T]` holding shared handles, a generic method `map[U]`, and generic functions whose type arguments are inferred (the value `pick` does not return is dropped); a ring buffer `Ring[T, n: Int]` whose capacity is part of its type, and an array length inferred from the argument (`total(recent.items)`) |
| [sort.rig](sort.rig) | closures passed to functions: a generic `sort` taking a comparator `?fun(?T, ?T) -> Bool`, called with closure literals (one counting into a local with `\|!compares\|`) and a function, and a `map` that infers its result type from the closure |
| [tree.rig](tree.rig) | a generic binary search tree owning its nodes through `Box[Node[T]]?`: insertion walks down with write borrows (`if !slot as n`) and stores a new leaf in place; lookups walk with read borrows |
| [counter_closure.rig](counter_closure.rig) | closures over a shared `Cell`: a stack closure, and an owned closure `*fun(Int) -> Int` returned from a factory function |
| [memo_canary.rig](memo_canary.rig) | a reactive source with derived values, built only from `Cell`, `Vec`, and owned closures; each derived source is held weakly by its listener, so the chain frees itself |

[WELCOME.md](../WELCOME.md) introduces the language, and
[SPEC.md](../SPEC.md) is its reference; the full test suite lives in
[test/](../test/README.md).
