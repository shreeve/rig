# Rules for every builder (Rig - Merges (fork), 2026-10-30)

**What this is:** the rules given to the Rust-port builders (2026-10-30).
The work queue it names is Rig - Swiss's `queue.md`, session notes outside
the repository; the base check is `tools/basecheck`.

These apply to every builder I start. The current round has three: mem-runtime, opt-out-param and push-byval.

- **Your worktree only.** Work in `~/Data/Code/worktrees/rig/<name>` (branch `<name>`, made with `wt new <name>` off the current origin/main). Never touch `~/Data/Code/rig` (the owner's checkout), another builder's worktree, Trig or loco: those last two are read-only, for gates.
- **Read `AGENTS.md` first and follow it:**
  - the North Star;
  - the vocabulary: lend, view, loan, never "borrow"; "object", never "struct"; `@` is self;
  - timeless prose; docs are tests; the oracle rules;
  - "one classifier per fact"; "emit decides nothing".
- **No AI attribution anywhere** (no Co-Authored-By, no "Generated with"). Commits are `area: what it now does`, with a prose body.
- **Two other builders run at the same time.**
  - Run every build and Swarm run through `tools/heavy`. Run benchmarks through `tools/low`.
  - While iterating, run single areas. Run the full suite (`tools/heavy swarm test/rig.rip all -q -w 6`, backgrounded) once, at the end.
  - Hold while `~/Data/Code/mumps-compare/.mac-quiet` exists.
  - Probes go in your own `mktemp -d`, with `RIG_OUT_DIR` set to it.
- **A failing case first** for each fix, in the right `test/rig/*.rig.test`; fix the class, not the instance. Mark a case `known: true` only if it won't be fixed here.
- **The oracle:** never weaken it.
  - Never lower `test/oracle/coverage`.
  - Never drop a rejection to make a run pass.
  - Compiler-only rejections go in `test/oracle/differences`.
- **Docs in the same change:**
  - SPEC, SYNTAX, CORE and STD say what is now true;
  - CHANGELOG under the unreleased section; a change that rejects programs a release accepted lists them there;
  - the HANDOFF status line.
- **Gates, all after the full suite is green:**
  - `tools/emit-diff origin/main`. Identical emit for the benches, std and Trig settles speed.
  - Otherwise the std.json guard, `PATH=$PWD/bin:$PATH tools/low bench/json/guard.py` (within 2% of guard.txt on all six), and the Map guard, `PATH=$PWD/bin:$PATH tools/low bench/hash/guard.py` (no row slower; on a single noisy row, re-run it).
  - loco: `cd ~/Data/Code/loc && git pull -q && rig/tools/light RIG=<your worktree>/bin/rig` → GREEN.
  - Trig: `cd ~/Data/Code/trig && git pull -q`, then `tools/pup-rig <pushed COMMIT>` and `PUP_RIG=... tools/light` → GREEN. `tools/pup-rig` has no target-directory option, so read it and build into your own `/zfs/trig-pup/rig-<name>`, never `rig-next`. Remove that directory when done. If ssh to pup exits 255 mid-build (the network dropped connections on 2026-10-30), run `ssh -O exit pup` and retry, or build on pup by hand with `ssh -o ControlMaster=no pup` and then run `tools/light` against that build.
- **The runtime or scheduler** (`src/runtime.zig`, `sched.zig`, `net.zig`, `tasks.zig`, `alloc.zig`): also run `zig build test` on pup with `-Doptimize=debug`, `safe` and `fast`, and run bench/tasks, bench/actors, bench/net and bench/http on the Mac and on pup. Add a row for each machine to each bench's PROGRESS.md, and time x86 on pup only.
- **Before the gates,** `git fetch` and rebase onto origin/main if it moved (other builders' PRs may land).
- **The PR:** push and open a **draft** whose body is a checklist of the steps and gates, with numbers. `gh pr ready` only when every gate is green. **Never merge.**
- **Report to Rig - Merges (fork) in ≤300 words:** the PR number, head SHA, your decisions, gate results with numbers, and anything left for the backlog.
- **Coordination (Rig - Swiss's queue, owner's request, 2026-10-30):** read the work queue (`queue.md`, Rig - Swiss's session notes, outside the repository). Work starts only with a row there; run `tools/basecheck BASE` before starting, before each gate run, and before reporting ready (exit 1: rebase, rerun affected tests, send Swiss the new base). pup timing (benches, Trig time) waits for a pup-lane slot from Swiss; light-gate builds through slot.sh need none. Merges: "merging #N" to Swiss first, the owner's own approval, one at a time in queue order.
- **pup lane rules (Swiss, 2026-10-30):** while any job times on pup, pin your builds and tests with `taskset -c 12-19` (E-cores) or run them through slot.sh; an unpinned `zig build test` broke a timing run. Never time across Trig's cron full suite (00, 04, 08, 12, 16, 20:00; /zfs/trig-pup/full/cron.log).
- **Merging (Swiss, 2026-10-30):** Swiss says the owner gave it standing approval to merge queue PRs. When every gate is green, run basecheck on the head and report to me; I send Swiss "ready #N <head SHA>". A PR that makes any bench row slower still goes to the owner first.
- **Stricter pup rule (Swiss, 2026-10-30):** while anyone times on pup, everything else runs only on the E-cores, slot.sh builds included: `taskset -c 12-19` or `TRIG_RELEASE_SLOTS="12,13 14,15 16,17"`. Light gates wait until the timing ends.
- **pup memory (Swiss, rule 4, 2026-10-31):** queue a release build only for the timing slot you've been promised next; slot.sh needs 12 GB free and Trig release builds take about 8.5 GB each. When no one is timing, use slot.sh's default slots (P-cores); while someone times, use the E-cores.
