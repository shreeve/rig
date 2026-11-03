# Errors-with-data track: handoff from the fork (2026-10-26)

**Status:** the errors-with-data track's state when its session ended
(2026-10-26). Its "still in flight" items are as of that day; HANDOFF.md
and the ledger say where they stand now. The probes and PR bodies it kept
were scratch and are not.

The fork of Rig (OG) that carried errors with data (session d74fe786) is
being deleted. Everything it knew that is not already in git is here.

## State: nothing open

- **Landed:**
  - #535, Ctrl-C;
  - #542, R2: declared sets;
  - the clone round: deep copy across modules, and Map's `+`;
  - R3a;
  - #555, R3: fields on members;
  - #566, Option U: `error` is always `rig.ErrorValue`, and every `T!` frame takes `__out`, zero-bit when no set has fields;
  - #565, R4: std.json `JsonError`, with `load` beside an unchanged `parse`;
  - #569, R2.5: generic error sets, merged as 463de5898.
- **Cleaned up:** none of the track's worktrees or branches are left, and neither are its pup clones.
- **Records:** in `docs/history/records/2026-10/`, under `errors-core`, `errors-r2`, `errors-r25`, `errors-r3`, `errors-r3a`, `errors-r4` and `clone`. The spec and the panel are in `revamp/r3/errors-panel/`.

## Still in flight elsewhere

1. **Trig `--pgo` and the tsrs gap.** The owner asked Trig to ship its release build with `--pgo` (#698). He also asked it to re-measure time, instructions and peak memory against tsrs, on one checker and at the default count, with every win since Oct 23 in:
   - 03216a79c: fewer yield checks;
   - f1067c358 and c7c9292ec: allocator faults taken ahead;
   - 4f5f22d75: no frame pointers;
   - 69f0fa7b3: Map table rebuild;
   - cb5a28e7e: `par.workers`.

   The request went to Trig session local_b0bdea02, which forwarded it to Trig's current session, "Trig: adopt tsrs's lessons, instantiation first" (local_5938f7cd-58d7-470c-b60f-7fcf84f1772e). **Send future Trig matters there.** Trig was asked to send its numbers to Rig for HANDOFF, which still says tsrs is 1.69× faster on ts-pattern and uses 1.7× less memory. My estimate for all the wins stacked was mid-to-high teens on ts-pattern, unmeasured.
2. **Feedback for the consolidation round**, sent to the session named "Rig" (PLAN rows 39–45):
   1. `tools/emit-diff BASE`. Byte-identical emitted Zig would skip a timing round; R2.5 did this by hand over 22 programs and 48 Trig modules.
   2. *(Resolved.)* The stray `examples/json_tour.rig.debug/`, fixed by a36f7fb18 and 5b8959fa4.
   3. `tools/baseline SHA`, a cached known-good compiler per commit, because the main checkout's `bin/rig` goes stale.
   4. A unit test that every call the runtime makes to a Rig function value goes through `argsWithSlot`, in the style of the `@constCast` ban. It is the class of the `task.select` bug.
   5. A type-argument conflict with the expected result is called "argument 0".
   6. A bracketed generic call is named `` `expression` `` in messages (`id[Int](n)!`).
   7. A generic mismatch says "expected `Int!E`, got `Int`" where the non-generic message names the whole function types.

## R2.5 review: the full version

The tracked `errors-r25/review-1.md` is condensed to 55 lines. The full
184-line review, with every probe, is `r25/review-1.md` here, and the
probe programs are in `r25/review/`. The two items left as they are:

- the LOW on the inner-type mismatch message (item 7 above);
- the pre-existing `` `expression` `` naming (item 6 above).

## Other things only this chat had

- **R4's slowdown was code placement** (`errors-r4/codegen.md` has the record):
  - On x86, every hot function moved exactly 32 bytes. Twitter was 2.0–2.3% slower while executing 0.08–0.19% fewer instructions.
  - Printing an error with fields pulls in about 2.4 KB of cold print code, which can push hot code after it.
  - The owner approved a one-time exception.
- **The json instruction guard's baseline (guard.txt) is stale on main.** It flags twitterescaped at 2.5% even for main's own compiler. Refreshing it is a one-line job, reported to Rig and possibly not yet done.
- **Language-design opinions given to the owner** (none are decisions):
  - **APIs Stages 3–5:** build 3 and 4 as written. Before Stage 5, reopen the bound name `Moves`, which clashes with Rig's core meaning of "moves"; `Shares` clashes less. Two notes:
    - `add Wrap[T: Shape]: Shape` puts two colons to two jobs. Keep it, and add a doc case.
    - Highlight `add` as a keyword only at the start of a declaration.
  - **Iteration:** Rig's pull `next()` is right: it gives plain `break`, composes for zip and peek, keeps loans visible, and inlines. Two ways to get Ruby's Enumerable ease:
    - lazy default methods on Stage 3's `Iter` (`each_slice`, `partition`, `group_by`, `tally`, `min_by`);
    - later, generators (`yield` is reserved), a design round of their own because the saved state holds loans. Trig's tree walkers would be the first user.
  - **Lean:** extend λRig in step with CORE. The next slices are `from`/`keeps` and CORE's "A failure moves its error" paragraph; λRig has no error values yet. The highest-value step is a validator that checks the loans `rig check --facts` exports against Lean.
  - **Replacing Zig:** measure first what share of `rig build` time Zig and LLVM take. The middle path is to drop Zig the language but keep Zig the toolchain: emit LLVM `.ll`, then optimize, link and cross-compile with zig/clang. A small Rig backend fits debug builds; LLVM stays for release builds. Hand the checkers' facts (noalias, nonnull, proven bounds) down.
  - **Linux 7.4 slab sheaves:** `src/alloc.zig` already does the per-CPU part. Two candidates, each measured on a multi-checker Trig run first:
    - batch remote frees per owning heap, one compare-and-swap per chain, as snmalloc does;
    - a shared pool of empty pages between heaps, which bears on Trig's memory gap.
  - **Linux 7.4 workqueue flush:** `src/sched.zig` scans every worker in `earliestDue`, `claimWaiting`/`takeWaiting`, `busyDescriptors`/`serviceAll`, stealing, and the "any work" check. It doesn't matter at 10–22 cores. Backlog candidate: "scans over all workers: track the active ones (a bitmask, or one shared earliest deadline) once Rig runs on 64 or more cores".
  - **Rig for AI authors:** the design suits them better than Rust's (accept means correct, errors that carry the fix, one mechanism per idea). Rust wins today on training data and ecosystem. That can be measured by iterations-to-green on the same tasks.
- **R2.5 design facts worth keeping**, also in `errors-r25/design.md`:
  - A FnRef of any fallible function takes the ErrSlot, uniformly.
  - Generic-set frames always take `__out`.
  - Frames without `__out` lend a fresh local slot (`openCatchSlot`/`closeCatchSlot`) and never `rig.unwritten_slot`, which was the bus-error bug.
  - `task.select` calls its arms through `rig.selectInto(arms, slot)`.

## What is in this folder

Source-only copies of the session's scratchpad: probe programs, review
reports, PR bodies and timing text (`r4/mac-time.txt`, `r4/pup2.txt`).
Build output and generated Zig were left out, since git and the tools
regenerate them.

- `r2-review/`, `clone-review/`, `r3a-review/`, `r3/review/`, `r25/review/`: each round's probes.
- `core-panel/`: the errors-core CORE panel.
- `u/`: Option U's prototype and probes.
- `usermsgs.txt`: an index of the session's messages.
