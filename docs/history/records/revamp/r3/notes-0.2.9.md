Rig 0.2.9 defines assignment by one rule, `place = value` runs as `{ tmp = value; place = tmp }`, and closes the assignment holes 0.2.8 listed as remaining, plus several more found in review. It also makes repeated test runs much faster. **Everyone on 0.2.8 or earlier should upgrade.**

## Fixed
- **Assignment computes its value completely, then stores.** All of the value runs first, with every block inside it finished and its locals dropped, and only then is the place evaluated and written. The checker and the generated code now follow exactly this order, for `=` and `op=` and for name, field, element and nested index targets. That closes every known way for a store to write through a view its own value invalidated, including:
  - the value's last `match` arm, `else` block or `catch` handler re-pointing the target's view at its own local;
  - a store through a write-view name (`w = …`) taking the pointer before the value ran;
  - a struct field target re-pointed by the value, and an index computed from a view the value re-points (`a[r[0]][r[0]] = …`).
- A `break` out of an assignment's value is accepted when nothing uses the target afterwards.

## Tooling
- **Rerun only what changed.** `./test/run --delta` and `test/matrix.py --delta` check every program but skip running one whose emitted package, test, harness and settings are unchanged since a recorded pass. A round with nothing changed checks in about 3 minutes; a change to diagnostics only, about 4. A run is recorded only if its inputs held throughout and the sanitizer stayed fully on.

## Known remaining
Four over-rejections, the same in 0.2.8: a later `match` arm's guard keeping a view live inside an earlier arm, and three related reassignment shapes. Also open: a `match` guard that changes a Cell through a view of the binding can produce Zig that does not compile.

## Verification
- Fast gate: the full suite, the reviewer corpus, the program matrix (its assignment-target axis has 402 programs; 0.2.8 fails 36) and the unit tests pass under the sanitizing allocator; a targeted grid of 783 programs passes in debug and `--release` with the reference checker agreeing on all; one independent review found no soundness hole; CI passed on Linux and macOS.
- Across every test, example and std module, the only programs 0.2.8 accepts that are now rejected are the unsafe ones above.

## Requirements
Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #80 (rerun only what changed), #81 (assignment), and the version bump PR.
