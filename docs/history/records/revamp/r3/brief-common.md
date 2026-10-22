# Common brief for REVAMP-3 subagents (Rig)

**Project.** Rig, a systems language that compiles to Zig. Repo: `/Users/shreeve/Data/Code/rig`.
The revamp branch `revamp` is checked out in the worktree `/Users/shreeve/Data/Code/rig-revamp`
(base: main `2d9e490f`, tag v0.1.0). The main checkout `/Users/shreeve/Data/Code/rig` stays on
`main`: never switch its branch, never commit there.

**North Star (fixed).** Rig is a fast, indentation-sensitive systems language that compiles to
Zig. A small algebra of sigils (`<x` move, `?x` read lend, `!x` write lend, `+x` clone, `-x`
drop, `*x` shared, `~x` weak, `e!`/`e?` propagate) makes ownership visible where it happens:
Python/Ruby readability, Zig/C cost model, Rust safety. No GC, no hidden allocation, refcount
traffic, or control flow. `docs/CORE.md` (the ownership model) is fixed: the compiler is being
made to follow it, never the reverse.

**Read first:** `AGENTS.md` (rules, especially "How we build"), `docs/CORE.md`, and for compiler
structure `docs/INTERNALS.md`. HANDOFF.md (the plan) is at
`/Users/shreeve/Data/Code/rig-handoff/HANDOFF.md`.

**Toolchain.** Zig 0.17.0 (pinned in `mise.toml`); `zig version` must print `0.17.0`, otherwise
`export PATH="$(mise where zig@0.17.0)/bin:$PATH"`. Nexus 2.0.0 at `../nexus/bin/nexus` (only for
`zig build parser`). References: `docs/zig-0.17.md` (every Zig API Rig uses) and
`~/Data/Code/zig/docs/ZIG-0.17.md`, plus the installed std source (`zig env` -> `std_dir`).
Your training may predate Zig 0.17. Verify every Zig std or language API against those references
or the installed source before you call it wrong, missing or deprecated, and before you write it.
Rig uses 0.17 idioms on purpose: never rewrite them into older ones.

**Feature freeze.** In scope: consolidation (no accepted program changes meaning; only wrong
rejections become acceptances) and building the Core's rules marked *(planned)* (each has a
` ```rig pending ` example in docs/CORE.md that must be promoted to an ordinary example in the same
change). Anything else that changes what Rig accepts or means is out of scope: report it, don't
build it. io, fs, Map/Set are out.

**Vocabulary.** *You lend a view; the compiler remembers the loan.* lend = the act (owner side),
view = the value handed over, loan = the owner-side record. Add no new "borrow" for the act in
new text (old text is renamed in a later dedicated step; don't rename existing identifiers or
diagnostics now).

**Shared machine.** At most `-j 2` for any test run. Before a heavy run check
`sysctl -n vm.loadavg` and wait while the 1-minute load is above about 12. Under load, a
timeout failure is often spurious: rerun it alone before trusting it.

**Commands** (from the worktree):
```
zig build                                   # builds bin/rig
./test/run -j 2 [filter]                    # suite (sanitizer on); see test/README.md
./test/run -j 2 corpus                      # all 4,273 reviewer probes (~20 min)
python3 test/matrix.py -j 2                 # form x context x type matrix
zig build test --cache-dir "$(mktemp -d)"   # unit tests (a plain rerun replays the cache)
RIG_SANITIZE=1 bin/rig run file.rig         # run one program, crash on use of freed memory
bin/rig check [--facts] file.rig ; bin/rig emit file.rig ; bin/rig parse|normalize file.rig
```
A frozen copy of the base compiler is `/Users/shreeve/Data/Code/rig/.git/revamp/r3/rig-base`.

**Conventions.** Never hand-edit `src/parser.zig` (edit `rig.grammar`, run `zig build parser`).
`rig.grammar`, `src/rig.zig`, `src/diag.zig` are mirrored in Nexus; report any change to them.
Comments are timeless (present tense, no history). Commits: short, imperative, no AI attribution,
no Co-Authored-By line. Rig's raw `@` builtins track Zig's names. Version stays 0.1.0.
