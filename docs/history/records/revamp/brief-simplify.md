# Brief: simplification pass (no behavior change)

Rig at /Users/shreeve/Data/Code/rig: an indentation-sensitive systems language; the compiler (Zig 0.16) emits Zig. You work in your own git worktree. Expected base SHA: 279823ee72f1145da6c8248777cd1a05021b5e7d. First run `git rev-parse HEAD`; if it differs, `git reset --hard <that sha>`. Read AGENTS.md (binding: never hand-edit src/parser.zig; commit messages short and imperative, NO AI attribution lines; comments explain the code as it is).

Goal: make your files clearly SMALLER and CLEARER with NO change in behavior. The source grew by ~1,150 lines during this revamp (new safety checks and features, written by several agents in parallel), so expect duplicated helpers, near-identical diagnostic paths, one-caller wrappers, parallel code paths that differ in one detail, dead code left by removed features, verbose comments that restate code, and inconsistent naming of the same concept. Find them and remove them. Useful tools: read the file top to bottom; grep for functions with one caller; compare similar functions side by side; `zig build` warns nothing about unused private functions, so grep each private fn's callers.

Constraints:
- No behavior change: every diagnostic message, every emitted program's behavior, and the IR stay the same. The full suite `./test/run` (1035 tests; parallel, ~40 s warm) must stay green at every commit, and so must `zig build`. Don't edit tests, except a unit test inside your file whose subject you deleted (say so).
- Only your files. Don't touch docs except a doc comment inside your files.
- Don't rename things for taste alone; rename only to make two names for one concept into one.
- No new abstraction layers or generic frameworks; a helper must replace at least two real copies.
- Small themed commits, each green. Run `zig fmt` on your files and check the diff is only your change.
- Performance must not regress: before and after, time `bin/rig check` on /private/tmp/claude-501/-Users-shreeve-Data-Code-rig/2da6db25-40f6-400b-889b-321dc5a34c57/scratchpad/bench/big.rig (54k lines) built with `zig build -Doptimize=ReleaseFast -p <your scratch dir>` (installs <dir>/bin/rig).

Report back (under 30 lines): commits (sha + subject), lines before/after per file, what kinds of simplification you made, anything you found that looks like a real bug (don't fix bugs here: describe them with a repro), and the ./test/run summary line.
