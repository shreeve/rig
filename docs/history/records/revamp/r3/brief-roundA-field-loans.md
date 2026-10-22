# Round A brief: disjoint field loans (NEEDS 28)

Owner-approved 2026-10-14: brief items 1a-1e as they stand, order C, A,
B, E2. Starts after round C (`replacefix`) is on main. Reviewed by Trig
(2026-10-14); corrections applied.

## Sources (read all)

- `.git/revamp/r3/proposal-field-loans.md`: the design. §3 is the
  approved CORE text (1a), §4 the desugaring, §5 the one classifier
  (`resolvePlace` decides the path), §7 every form decided, §8 what
  stays conservative, §9 sibling sites and test plan.
- `.git/revamp/r3/owner-brief-ownership-regex.md` §1: decisions 1a-1e.
- Trig (read only): `docs/ownership/EVIDENCE.md` §3.2, §5, §6, §7.2;
  `docs/ownership/proposal-notes.md` "A" and "Diagnostics";
  `docs/ownership/acceptance/` (`accept/field_*`, `reject/field_*`,
  `beyond/`) with its `verdicts` runner.

## The rule (approved; no wording changes without the owner)

A place is a name and the fields after it, through a write view the
name holds and through a box (1b). The path stops at an element, a
handle, or an optional's value. Two places conflict when one path is a
prefix of the other. A use touches the path it names; `p`, `<p`,
`p = x`, `(!p).m()` and `!p.m()` touch all of `p`. A value never holds
a view of itself (1c). A `!self` or `?self` method's view result still
lends all of `self` (1e; E2 follows). Field-precise re-pointing (n39)
is not in this round (1d).

**A path ends where a read view begins** (Trig's note A.3): a path
through a field that is itself a read view (`self.scanner.text` with
`text: ?String`) carries that view's loans, not the holder's. Enforce
and test it both ways.

Desugaring (state in docs/INTERNALS.md): for loans, a struct binding, a
write view's referent and a box's value are each a group of bindings,
one per field, nested; using the whole uses every binding in the group.
Emit is unchanged. (`accept/field_through_write_param` and
`field_box_fields` test the last two.)

## Required

1. **Tests first.**
   - Import Trig's 17 `accept/field_*` as test/behavior/ownership.
     Each must run sanitizer-clean with its `# expect:`.
   - Import the 19 `reject/field_*` as test/reject/ownership, with the
     post-change diagnostics in each header.
   - Import the 3 `beyond/` programs as `rig pending` doc examples or
     known tests. They stay rejected this round.
   - 16 of the 17 accepts fail on main (Trig's verdicts.txt);
     `field_swap_general` passes today and must keep passing.
   - `beyond/method_view_result_path` depends on A.3 and E2, so it flips
     in round E2, not here.
2. **One classifier.** The path is decided once, by `resolvePlace`, and
   recorded as a fact; no pass re-derives it from syntax. The ownership
   checker consumes it by name. The oracle (test/oracle) reads the same
   fact, or a classified difference is recorded.
3. **Diagnostics** name both paths, with the note at the lend; a
   whole-receiver call while a field is lent adds the idiom note ("lend
   the fields it writes, `(!self.ast).add(...)`, or make it a function
   of those fields"). Text per Trig's proposal-notes "Diagnostics".
4. **The A grid in test/matrix.py** ("fix the class"):
   - sibling places: fields; nested fields; a field through a read-view
     field; `self` in a method; a box's field;
   - × a first loan (read, then write) × the second use: a read lend, a
     write lend, a move, an assignment (most accepts are rejected today
     with "cannot assign to `p.n` while `p` is lent");
   - × context: straight line, a loop back edge
     (`reject/field_loop_carried`, `field_loop_push_into_iterated`), a
     closure capture, which uses the whole place
     (`reject/field_closure_captures_whole`);
   - × every exit: fall-through, return, break, continue, error
     propagation, a failing guard.
   Each cell is rejected or runs sanitizer-clean.
5. **Docs:**
   - CORE gets exactly the approved §3 text;
   - SPEC describes places and paths;
   - every `rig` example is run by the suite;
   - mark built/pending honestly.
6. **Gates:**
   - Mac fast gate;
   - full gates on pup (`GATES_DELTA=1`, suite, corpus, matrix, unit,
     oracle/doc/vocab);
   - one independent adversarial review (separate agent);
   - Trig's tree on the PR head: `tools/parser/test` passes on all 18,568
     inputs with Trig's `fieldloans` branch (parser-A.diff on the
     reorder commit, with the two identifier sites as the
     function-of-fields idiom `new_identifier(!self.ast,
     !self.identifier_count, !self.statement_has_await_identifier,
     self.scanner.token_value)`), which also proves the idiom the
     diagnostic recommends; and Trig's
     `docs/ownership/acceptance/verdicts` with the PR's bin/rig gives
     each of the 39 A programs its post-A verdict.
7. **Measurement** (in the PR body):
   - Trig's `docs/ownership/experiment/bench-ab` in a quiet Mac window,
     base against A, built by the PR's compiler, reported as "N% faster";
     this replaces the experiment's numbers;
   - peak memory at 1 parse (expected equal) and at the plateau (about
     14% higher, bounded), attributed to allocator retention across
     parses, with Trig's per-size-class counts if available;
   - `rig check --time` on Trig's parser root, before and after, quiet
     window, best of 3: the ownership phase grows by no more than 10%
     (1.7 ms; today 17.1 ms of 152.5).
8. **A second soundness round stops the feature** (AGENTS.md). If review
   or the grid finds a hole after the first fix round, stop and report.

## Out of scope

E1 (declined: a function of the fields is the idiom); E2 (next round);
B; n39; Map/Set's argument keeping.

## Trig's gate (pushed 2026-10-14)

Trig's `fieldloans` is at github.com/shreeve/trig, bc3d044, on main 9425dfb. Gate 6, from a checkout of `fieldloans`:

```
RIG=<PR bin/rig> tools/parser/test --sets tokens,ast,parser,parse-only,clean,all-ts,all-js,fixtures
```

It must give 18,568/18,568, and `rig check src/parser` must be clean; today's rig rejects it with 24 loan-conflict errors. For bench-ab, base is Trig main and exp is `fieldloans`, both built by the PR's compiler. If A rejects a site Trig expected to pass, report the line to Trig before changing the rule or the port.
