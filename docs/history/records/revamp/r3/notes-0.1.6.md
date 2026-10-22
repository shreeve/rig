Rig 0.1.6 is a patch release that fixes a memory-safety hole and a leak found in 0.1.5, plus two programs that failed to compile. `rig check` accepted a program that then read freed memory, which breaks Rig's promise that safe code cannot corrupt memory. **Everyone on 0.1.5 or earlier should upgrade.**

## Fixed

- **A header that makes a temporary bound a copy of its subject.** Two shapes failed:

  ```rig
  match pick(?mkh(?Text("…")))      # the view pointed into a temporary already freed
    .a(s) => print(s)
  match !arr[idx(?Text("a"))]       # the write landed in a copy and was lost
    …
  ```

  `if … as`, `while … as`, a guarded `match`, and a Cell change through a header copy behaved the same way. Every `match`, `if … as`, `while … as` and `for` header that makes a statement temporary is now rejected, with the hint "bind the index (the argument) to a name first". A header that takes what it binds, a `for` over a slice, and plain data read from a value made in the header are unaffected.
- **A callable held in a field, called with arguments evaluated first, leaked.** In `s.cb(Text(…), …, gf(2)!)`, arguments were matched to the wrong parameters, so the owned Text was never freed. Arguments now go to their own parameters.
- **Two programs that `rig check` accepted failed to compile in Zig:**
  - a guarded `match` on an element of a `?Vec[E]` parameter;
  - a name holding `?x` of a copied type (Int, String, a plain enum) that was bound again to a call's result. This includes a generic method's result.

**Programs 0.1.5 accepts that are now rejected:** headers that lend a value they make, such as `if ?opt(3) as p`, `match ?mk()` and `match ?(mk())`. Bind the value to a name first, or write `match mk()`.

## Verification

- **Tests:** new reject tests for every header form, all accepted by 0.1.5. Behavior tests for the forms that keep working, and for the leak and the Zig failures. Matrix contexts for header temporaries.
- **Gates:** the full suite, the reviewer corpus, the program matrix and the unit tests pass under the sanitizing allocator. CI passed on Linux and macOS.
- **Equivalence with 0.1.5:** across 6,374 programs, the only differences are the new tests, the rejections listed above, and six programs whose generated Zig changed with the same output.

## Requirements

Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #48 (fix), #49 (version).
