# Brief: HANDOFF step 3, "Reads and lends" (REVAMP-3)

Read `/Users/shreeve/Data/Code/rig/.git/revamp/r3/brief-common.md` first (North Star, Zig 0.17
references, conventions, shared machine), then AGENTS.md "How we build", docs/CORE.md
(sentence 1, sentence 4, §3, §4, §1's planned bullet), and HANDOFF.md step 3, including
"Inherited from step 1".

You are the ONLY branch allowed to change `src/ownership.zig` and typecheck's classification.

## The plan
`/Users/shreeve/Data/Code/rig/.git/revamp/r3/audit-steps3-6.md`, section "Step 3: reads and lends",
commits 3.1a, 3.1b, 3.2, 3.3 and 3.4, with its soundness risks (1)–(5). Line numbers predate steps 1–2,
so re-find each site. Step 2 gives you `sema.handsOver`, `valueParts`/`valueLeaves`, the recorded
`Use` fact, and `exitTo`. Use them: never classify by syntax again (the `classify` lint in
`test/run` enforces this).

## Design owner's settled decisions
- **A read lend may go unwritten only where the view lasts for the use:** arguments to view
  parameters, `for` sources, `as` conditions, `match` subjects, receivers. A lend kept in a binding or
  a field is always written: `r = b` with `r: ?T` stays an error with a hint. A write lend is always
  written.
- **`?o` of `S?` stays `?(S?)`.** `(?S)?` and `String?` are lend targets of the `lendsAs` table.
- **A made value where a view argument is expected** (`size(mk())`) is lent as a statement
  temporary, after bare names work.
- **`*T` lends:** the view's loan sits on the handle's binding; `!h` lends the handle, never `!T`.
- **`v.get(i)`** for a non-copyable element stays copy-only, with a hint to `?v[i]`.
- **Header subjects** (Core §3, with step 2's positive list): a place or a lend is viewed; a made
  value is taken (held in a `var`); a branch whose type moves is taken leaf by leaf, or rejected.
  Whether a branching subject may instead be viewed per leaf is an open Core question, so take the
  conservative reading and list it.

## Inherited from step 1 (HANDOFF step 3)
Order matters; each was stopped once for soundness.
1. **Specify** the header-subject classification and in-place binding as a desugaring in
   docs/INTERNALS.md BEFORE any code (AGENTS: a feature is specified as a desugaring).
2. **Bind every type's** loop element and read-match payload by that classification: a view of a
   place, or an owned value of a taken made subject.
3. **Restore Cell ⇒ unique** (commit 2cab5408's rule, its seven `<` rewrites, its three reject
   tests; promote CORE §1's pending example, then the bullet becomes *(built)*). Turn on the oracle's
   `--planned` Cell rule by default in the same commit.
4. **Item 1.7:** a by-value parameter's Cell is a place (`requireCellPlace`), with one rule in SPEC
   §10.
5. **The acceptance set:**
   - the 7 `test/known/ownership/header_*` and `match_made_part_cell_holder` tests must pass and move
     out of `test/known/`;
   - the round-1/round-2 probes (`.git/revamp/r3/probes/review-step1/`) must each run
     sanitizer-clean with the Core's meaning, or be rejected;
   - retire `match_copy_of_cell_holder.rig`, `loop_copy_of_cell_holder.rig`, and
     `match_payload_view_escapes.rig` (they state today's "a copy" reasons).

## Pending examples to promote when built
CORE L144 (`for x in v`) and L485 (`sort.sort(!v)` on a Vec), plus §1's Cell example. Mark each
CORE status *(built)* only if true everywhere.

## Proof and gates (lean regime)
- Per commit: `zig build`, `./test/run -j N`, `./test/run -j N oracle`. The oracle's hard gate
  ("compiler accepts what the oracle rejects") must never fire.
- At the end: one `test/equiv.py <step base binary> bin/rig` run, explaining every difference by
  commit (only listed rejections → acceptances, flips, promotions, and new tests); then the four
  gates through `/Users/shreeve/Data/Code/rig/.git/revamp/r3/heavy.sh`.
- N is 4 when the 1-minute load is below 6, otherwise 2.
- An independent review follows.

Statement temporaries have had two soundness slips; a third stops that feature. Don't change
`holdTemp`, `dropStmtTemps`, `emitTempSlots`, `tempSlot`, or `rig.keep`, unless the desugaring in (1)
requires it and you say so in the report.

**Stop and report** if an accepted program would change meaning beyond these decisions, or if the
oracle fires.

Commits short and imperative, no AI attribution, no Co-Authored-By. Don't push.

**Report in two parts:**
1. after 3.1a, 3.1b and 3.4 (the lend table);
2. after 3.2, 3.3 and the inherited items, with the final gates.
