Rig 0.2.8 closes use-after-free holes in assignments whose value contains a block, and keeps a `match` arm's temporaries inside the arm. **Everyone on 0.2.7 or earlier should upgrade.**

## Fixed
- **An assignment could write through a view its own value had invalidated.** In `w[0] = <value>`, the store happens after the value is computed, but the checker treated the target's view as unused while it checked a block inside the value. So a block that grew or moved the owner could leave the store writing into freed memory:

  ```rig
  w = !v[0..1]
  w[0] = if k
    grow(!v)        # reallocates v; w's view would dangle
  else
    3
  ```

  This is now rejected. The target's uses count after its value, for `=` and `op=` and for element, field and index targets, with block-bodied `match` arms, `if` blocks and `catch` blocks in the value.
- **A `match` arm's temporaries live in the arm.** A temporary made in an arm is dropped when the arm ends, while the arm's binding is still alive. A temporary viewing the binding (rejected by 0.2.7) now works, and an older form that read a temporary's copy after its scope is fixed.

## Changed
- `match ?x[0]` with an arm `.circle(_) => print(grow(!v))` is accepted, as the block-bodied arm already was: `x` is not used after the header.

## Known remaining
Two cases of the same assignment-order class remain, present in earlier releases too, and are fixed next by specifying assignment as `{ tmp = value; place = tmp }` in both the checker and the generated code:
- the value's last nested block re-points the target's view at one of that block's locals;
- a store through a write-view name (`w = …`) takes the pointer before computing the value.

Also open: a `match` guard that changes a Cell through a view of the binding can produce Zig that does not compile.

## Verification
- Fast gate: the full suite, the reviewer corpus, the program matrix (with a new 120-program assignment-target axis, where 0.2.7 fails 18 with use of freed memory) and the unit tests pass under the sanitizing allocator; targeted grids pass in debug and `--release`; two independent reviews; CI passed on Linux and macOS.
- Across every test, example and std module, the only programs 0.2.7 accepts that are now rejected are the unsafe ones above.

## Requirements
Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #78, and the version bump PR (which also drops Zag from DESIGN.md's influences).
