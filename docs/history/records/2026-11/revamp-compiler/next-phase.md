# Compiler revamp, phase 2: ownership, storage, facts, and emit (brief)

Phase 1 (#914-#917) revamped the front end and the type checker; ledger.md
beside this file has the method, the gates, and what each review found.
Phase 2 covers src/ownership.zig, src/storage.zig, src/facts.zig,
src/emit.zig, and the IR helpers they share, under the same rules: CORE
fixed; rewrite-level items (a lowered IR, one type table, context passed
down) left for the owner's rewrite decision; the lead merges on green gates.

Known items to start from:
- North Star 4: emit still decides some things itself (the 10-31 review,
  review-ownership-emit.md: whether a binding is used, built-ins by name,
  lowerings by method name, pointer or copy). Each decision becomes a
  recorded fact that emit reads.
- The CallSite constructor with explicit origins (audit-types-3): it
  closes the actor-call class of V2/V3 for good, but changes origins the
  ownership checker reads.
- V12: a run-time shift past the width panics with Zig's message, not
  Rig's.
- The `select` storage life `select` (#917) is new: check other std forms
  whose arm or closure parts emit hoists.
- U11 (a parenthesized range-pattern end that fails to parse, grammar),
  U12's 131 sibling messages ("a `{s}`" before a type name), D1, M4's slice
  half, C2.

Method that worked:
- Full audits by at most three Opus agents, each reading every line of
  its scope. One agent cannot read 20,000 lines: split the file, and ask
  each auditor for the exact ranges it read.
- An independent Opus review of every soundness change. Every review in
  phase 1 found something that was fixed before merge.
- The corpus check before each merge: `rig check` of every real .rig file
  in ~/Data/Code/rigs.txt (minus worktree copies) with main's rig and the
  branch's, six at a time, about 4 minutes.
- The gates: the oracle, emit-diff, the check guard, the json, hash, and
  text guards when emit changes, and loco's and Trig's light gates.
