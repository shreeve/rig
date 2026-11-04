# Revamp of the compiler, phase 1: front end and types (2026-11-03)

## Owner's inputs (2026-11-03, late evening)
1. Scope: phase 1 is the front end and types: rig.grammar, src/rig.zig,
   sema.zig, resolve.zig, modules.zig, typecheck.zig, cteval.zig,
   inlining.zig, proofs.zig (61,358 lines). Ownership, storage, facts, and
   emit are phase 2.
2. Rewrite-level items (a lowered IR, one program-wide type table, context
   passed down) stay the owner's rewrite decision
   (records/2026-10/compiler-review/rewrite-review.md).
3. The lead merges on green gates; rules, names, and CORE go to the owner.

## North Star
AGENTS.md "The North Star". For this phase: accept means correct, and one
classifier per fact. CORE is fixed; every finding about what the checker
should accept or reject cites the CORE section or SPEC rule, with the oracle
as arbiter.

## Base and toolchain
- Base: main a4e4ce6a8 (after the runtime revamp, #901-#913).
- Zig 0.17.0; ZIG-0.17.md; Nexus 2.0.0.

## Baseline
- Core suite on main: 7,032 jobs, 0 died.
- Guards json/hash/text: clean.
- bench/check/guard.py: fails as documented (without --rig it builds its
  own rig, which fails at once); with --rig bin/rig it runs. The workload
  takes 2,234M instructions against guard.txt's 1,895M (10-13), 17.9% more;
  pre-revamp edc481031 and main measure alike (2,217M), so the growth came
  between 10-13 and 11-03. Scaling exponents all 1.00-1.02.

### Check speed since guard.txt (bench/check's workload, rig check, instructions, median of 3)

| main at | date | instructions |
|---|---|---|
| 6c7b409e9 | 10-15 | 2,091M |
| adce60f6e | 10-16 | 2,288M |
| 8177ae290 | 10-20 | 2,351M |
| 9303c2b11 | 10-22 | 2,483M |
| 099c1bff3 | 10-27 | 2,649M |
| 36be46744 | 10-31 | 2,654M |
| deda825dc | 11-01 | 2,143M (row 33A's check-speed round) |
| 824e130d7 | 11-02 | 2,174M (#875 parser reset) |
| 758b86eda | 11-02 | 2,195M (#873 word objects) |
| 94873583e | 11-03 | 2,215M (#883 matches) |
| a81eeb864 | 11-03 | 2,239M (#885 chains) |
| a4e4ce6a8 | 11-03 | 2,216M |

No single regression: each feature adds about 1% to programs that do not
use it, and the spread between runs of one commit is about 1%. guard.txt
(1,895M, 10-13) was never updated after 33A. Plan: fix the hot paths the
audits found (sema's per-module method origins, about 5%; the front end's
directory-module lexing, F7), then update guard.txt with the result, and
fix guard.py's own build (without --rig its rig fails at once).

### Audits and triage (2026-11-03 night)

Five audits: audit-frontend.md (F1-F14), audit-sema.md (M1-M6, D1,
S1-S2, C1-C5), audit-types.md (T1-T17; typecheck read only in part),
audit-types-2.md (U1-U13: typecheck 136-11510 and cteval, line by line),
audit-types-3.md (V1-V12: typecheck 11500-end and inlining). No proof
omits a check a run could fail (proofs.zig read in full, probes under
RIG_SANITIZE=1).

Accepted programs that misbehave, crash the compiler, or fail in Zig:
- Front end: F1 (an enum variant named like a built-in vanishes from the
  type), F3 (a closure reads a captured path after `new` rebinds its
  root), F4 (13 or more chain stages panic).
- Sema: M1 (a generic type crosses to a task with a `?T` field whose T
  does not sync), M2 (a read view counted as 8 bytes when it is a copy,
  so a large frame overflows), M3 (an enum holding its own optional fails
  in Zig).
- Types: U1 (ill-typed compile-time calls accepted in type positions),
  V1 (a duplicate `mailbox:` crashes the compiler), V2 (an implicit lend
  to an actor skips the Syncs check).

Three implementers, each with its own files: rv-sema (sema.zig), rv-front
(rig.grammar, rig.zig, resolve.zig, modules.zig, diag.zig), and rv-types
(typecheck.zig, cteval.zig, inlining.zig, proofs.zig).

For the owner:
- F6: `!` on a `for` source is the loop's mode, while `?` is the call's
  self; the default is to make `!` follow the self-sigil rule.
- U4: SPEC says `collect` of views is rejected, but the code accepts
  `List[String]`'s `filter(...).collect()` as `List[?String]`, which is
  memory-safe (the oracle agrees). The default is that SPEC says what
  the code does.

### Phase 1 landed (2026-11-03 night): #914-#917

Each PR passed: the core suite with the oracle silent; emit-diff; `rig check`
no slower; loco's and Trig's light gates; and every real .rig file under
~/Data/Code (1,286, Trig's sources among them) giving the same accept or
reject as main (931/355 at every step), so no program in use is newly
rejected. Each soundness change had an independent Opus review, and every
review found something that was fixed before merge.

- #914 sema: M1 (generic fields walked as they hold each argument for
  crossing), its sibling (a value held both by value and through a view),
  and, from the review, a recursive generic's parameters read whole
  (a field-order hole) and `local` in the walk's key; M2 (a copied view
  at the value's size); M3; M4 in part; M5/M6 (one print walk); C1, C3,
  C4/S2 (2,000 chained objects 130 to 37 ms); S1 (the tables' member
  origins once per process); ten walks share one list of a value's parts.
- #915 front end: F3; F4 (chains to 64 stages, stated in SPEC); built-in
  type names found through a scope around the module (F1, F2, F7, no
  `__rig_prelude` in messages; a 400-file directory module lexes in 21 ms
  where it took 409); F5, F9-F12; emit's `unwrapsField` read an imported
  variant's payload types from the wrong module's store (fixed).
- #916 types: V1; U1-U3 (one argument check for compile-time calls), and
  from the review typed enum constants and compile-time-call arguments;
  V2+V3; a slice crossing needs Sync for its elements; T1 (select's arms
  joined, a never-returning arm not deciding); V6; T2, T3/V4, U5, U6, U8,
  U12, U13, V5, V7, V11, T12; T7, T8 (one std-form lookup, one closure
  type); cleanups.
- #917 (found by #916's review, on main, North Star 2): a select's
  capturing arm closure read a dead frame; storage gives a select's arm
  parts the life `select` so emit keeps them in the select's block; a later
  failing arm leaked an earlier send arm's String; the ownership checker
  keeps an arm's loans until the select returns; from its review, each
  arm's channel is made in the arm's turn (SPEC's order).

Check speed (bench/check, instructions): 2,234M at the base, 2,129M after
#917 (4.7% fewer). guard.py's own build wrote bin/rig and ran a path that
did not exist; fixed, and guard.txt holds the new baseline.

Not done, with reasons in the PRs: F6 and U4 (the owner's), F8, F13, F14,
T4, T9 (no smaller), T10, U11 (grammar), V12 (emit), D1 and M4's slice half
and C2 (sema and typecheck together), U12's 131 sibling messages, and the
CallSite constructor (it changes origins the ownership checker reads:
phase 2).
