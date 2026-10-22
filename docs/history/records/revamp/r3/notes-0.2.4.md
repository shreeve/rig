Rig 0.2.4 closes the loop holes that 0.2.3 listed as known. Every loop now compiles through one shape, the same one the ownership checker walks, so a loop's step, its body's drops and defers, and its jumps run in exactly the order the checker assumes. **Everyone on 0.2.3 or earlier should upgrade.**

## Fixed
- **A loop's step could run before the body's drops.** In a loop with a joined condition (`… as h and …`) or a jump in its condition (`catch break`), whose step reads the condition's binding, the step ran before the body's `defer`s and drops when the body had no `continue`. A program could then read memory after it was freed.
- **An unlabeled `continue` in a nested loop's `else` skipped the outer loop's step.** A loop whose only progress was its step could then run forever, or use memory after it was moved and freed.
- **Reusing a label name in nested loops** could make the emitted Zig fail to compile, or send a jump to the wrong loop.
- **A step that reads the condition's binding only inside a closure** (`while f() as h: s = apply(|+h, x: Int| x + h, s)`) was accepted, then failed with an internal error. It now runs.

## Changed
- **A `continue` in a loop's condition always runs the step,** as SPEC says. Where the step reads a binding of the condition, that pairing has no binding for the step to read, so it is now rejected (`while (f() catch continue) as h: step(h)`). On 0.2.3 the step was silently skipped.

## Programs 0.2.3 accepts that are now rejected
Only the condition-`continue` pairing above. A comparison over 9,172 programs shows no other change; the rest differ only in the emitted Zig of loops.

## Tooling
- Tests run much faster: a shared, content-addressed build store cuts a full check of a new branch from about 33 minutes to about 4.5 on a laptop.
- A test now passes only when its program provably ran. A program that never started, or was killed by a signal, fails instead of passing.

## Verification
- A loop matrix of 200 shapes (outer loop × inner loop × jump × body-end), where 0.2.3 fails 44, and 4,300 generated loop programs up to three deep (on one 1,500-program grid of these, the old lowering failed 378). All pass.
- The full suite, the reviewer corpus, the program matrix and the unit tests pass under the sanitizing allocator on Linux x86_64 and macOS.
- Independent reviews found no remaining soundness hole. The reference checker reports no program the compiler accepts and it rejects.
- `--release` binaries of the examples are the same size as before the change, and a loop-heavy benchmark runs in the same time.
- CI passed on Linux and macOS.

## Requirements
Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #63 (test tooling), #64 (loop lowering), and the version bump PR.
