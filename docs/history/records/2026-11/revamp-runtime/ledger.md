# Revamp of the runtime and std (2026-11-03)

## North Star
AGENTS.md, "The North Star": accept means correct; safe code cannot corrupt memory;
effects stay visible; one classifier per fact; ownership features fit the Core; docs
claim only what runs. For the runtime and std: no GC, no hidden allocation, the cost
model of Zig and C, std.json/Map/HashMap/std.text never slower (guards within 2%).

## Owner's inputs (2026-11-03 ~05:45)
1. Scope: runtime + std first (src/runtime, sched, tasks, net, alloc, ordered,
   unordered, table, nametable, split, units; std/). Compiler phases later.
2. Landing: themed PRs from worktree `revamp`; I merge on green gates and clean
   basecheck. Overnight (~05:50) he gave full authority: "performance and
   efficiency and consistency"; CORE and language rules stay fixed.
3. std's public API may change when clearly better, with CHANGELOG, migration
   note, and a Trig note and script before merge.

## Base and toolchain
- Base: main edc481031 (after #900). Worktree ~/Data/Code/worktrees/rig/revamp.
- Zig 0.17.0 (mise.toml); reference ZIG-0.17.md; std at
  ~/.local/share/mise/installs/zig/0.17.0/lib/std. Nexus 2.0.0.

## Baseline
- `zig build` (ReleaseSafe): 76 s under tools/heavy, bin/rig 9.2 MB.
- Scope size: 36,266 lines (src runtime pieces 24,0xx; std 13,082, of which
  generated tables ~1,700).
- Guards on base (instructions, Mac): json, hash (Map and HashMap), text all within 1.1% of guard.txt.
- Core suite: 7,008 jobs, 0 died, 110 s with 6 workers (3:20 with the build).

## Findings, decisions, status
(audits: audit-runtime.md, audit-concurrency.md, audit-std.md beside this file)

### Triage (2026-11-03 ~06:40)

72 findings: audit-runtime.md (R1-R18), audit-concurrency.md (C1-C22),
audit-std.md (S1-S32). No memory-safety bug in safe code. Eight hangs or
spins, every one reproduced by a probe. Spot-checked: R1, R3, C2, C3, C5
(cited lines read).

Round 1, three implementers on Opus, each in its own worktree and PR:

| PR | Findings | Files |
|---|---|---|
| rv-output | R1, R2, R3 (one writer: no user code under output_lock, String(...) in one pass), R4, then R5-R18 | src/runtime.zig (print, String, finish), src/alloc.zig |
| rv-tasks | C2-C6 (panic paths, slots, spin waits), C1 (accept waiters), C7, C9, C13, C14, C15, C20, C22, C11, C17, C18, C19, C21 | src/tasks.zig, src/sched.zig, src/net.zig, runtime.zig `fail` only, std/task, net, time, file, os, docs |
| rv-std | S3, S4, S5, S6, S8, S11, S12, S13, S14-S19, S21, S24, S25, S26-S29 | std/*, src/ordered.zig, src/unordered.zig, docs/STD.md |

Deferred:
- To the owner (names and behavior): S2 (a per-process hash seed changes
  HashMap order run to run; Map's order unchanged), S10 (needles taken as
  views: a signature change for Trig), the API-consistency table (json's
  names, compare -> Order, equal, to_float, powf), S9 (remove std.iter),
  S32 (random's sequence changes), the BigInt Eq/Ord rule, small-block
  memory returning to the system, print depth by address.
- Round 2 (needs Trig or bench timing on pup): S7 (Interner load factor),
  C8 (file I/O without `lent`), C10 (accept's poller), S1 (terminal
  bounds, Ghostty conformance), S22, S23, S20, S30, S31, C12, C16.
