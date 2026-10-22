Rig 0.1.4 is a patch release that fixes a memory-safety hole found in 0.1.3. `rig check` accepted a program whose view of a `match` payload could outlive the match and dangle, which breaks Rig's promise that safe code cannot corrupt memory. **Everyone on 0.1.3 or earlier should upgrade.**

## Fixed
- **A view of a read `match` binding returned or stored past the match.** For example:

  ```rig
  fun inner(e: ?E) -> ?Res
    match e
      .a(r) => ?r          # `r` was bound from a copy of the payload
      .b(r) => ?r
  ```

  Emit binds a read payload from a copy: a prong-local copy, a guarded match's subject copy, or a copy in a generic body. A view of the binding pointed into that copy after the match ended. Because the copy lives on the stack, the sanitizing allocator could not catch it. The same hole appeared for catch-all bindings (`x => ?x`), guarded matches, generic payloads, and a view stored into an outer binding or field, or given as the match's value.

  A view of a read `match` binding is now usable only within its arm. Returning or storing it is rejected: "a view of `r` does not outlive the `match` that reads `e`". The message suggests copying it (`+r`), taking the subject (`match <e`), or using it in the arm. A view of heap memory the payload owns, such as a `String` of its `Text`, may still leave the match, held by the loan on the subject.
- **A catch-all binding of a lent subject** (`match e` with `e: ?E`, arm `x => ...`) no longer fails to compile in Zig.

Every program 0.1.3 accepted that does not have the escaping shape still compiles to the same code.

## Verification
- A reject test covering 17 escape shapes, behavior tests for views used within an arm and for writes through `match !e`, and the reviewers' probes kept in the corpus.
- The program matrix gains `payload.<type>.<subject>.<use>` cells. A cell that runs must also print the payload's value.
- The full suite, all corpus programs, and the unit tests pass under the sanitizing allocator. CI passed on Linux and macOS.

## Requirements
Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #44 (fix), #45 (version).
