## Summary
B4b, the checker half of step 10's lowering work. B4a made emit point at a header's subject and match it in place. B4b makes the checker accept what emit now does correctly:
1. A header whose subject reaches a place past its temporaries binds the place's own (`match v[idx(?Text("a"))]`, `if !v[i(?t)] as x`, `for x in !m[k(?t)]`).
2. A read match's payload views outlive the arm wherever the match reads its subject in place.
3. Bare `break x` moves a name the loop declares (E1).

It also fixes a write-match bug that predates this branch and adds one shared "consumed" fact. Nothing a release accepted is rejected now.

## Commits
- **Switch a write match on a Vec element where it is.** This bug predates the branch (v0.2.0 through v0.2.9). `match !v[i]` on a Vec element was accepted, then failed in Zig with "cannot assign to constant", because emit switched on `v.at(i)`. It now switches on `(&v.slot(i).*).*`. Test: `test/behavior/emit/match_write_vec_element.rig`.
- **Accept a header whose subject reaches a place past its temporaries.**
  - `rejectHeaderCopy` returns early where `storage.headerPoints` holds.
  - Headers that copy stay rejected: a value made in the header, or a place inside one (`header_place_inside_temporary.rig` and the sema unit test are unchanged).
  - Oracle: a catch-all over a lent Box sees the boxed value.
- **Let a read match's payload views outlive the arm where the match reads in place.**
  - `arm_view` is set only where the match reads a copy (not `storage.matchesInPlace`), or captures a catch-all's value as a copy.
  - New fact `storage.catchAllByAddress`. A generic catch-all on a match that reads in place is captured by pointer, as `payloadByAddress` binds a payload; without that, `match getgh(e).e  x => ?x` returned a pointer to a copy.
  - Oracle: its arm-local rule is removed. A read lend of a view a call returns (`?get(e)`) is that view, not a temporary. It abstains on a header subject reached through a lend (`(?v[i..2])[1]`).
- **Record the bindings a use may move as a fact emit and the checker share.**
  - `SemContext.consumed`, from `storage.plan`, replaces emit's syntactic usage scan for drop flags.
  - The ownership checker reports an internal error for any move the fact leaves out.
  - No program's output changed (equivalence: 0 differ).
- **Move a loop-local name out with a bare break.**
  - `break x` of an owning name declared in the loop moves it, as `return x` does. `break <x` stays valid. An outer name still needs `<x`.
  - The CORE pending example is now ordinary.
  - The oracle's `--planned` mode is gone; the rule is always on.
  - Docs state one rule: "Write `<x` when `x` stays in scope after the move; where `x`'s scope ends with the move, the move is plain."
- **Match a branch over places as the copy it is, and capture a guarded generic catch-all by the same fact.** These are the part 2 review fixes, each as a class:
  - `matchesInPlace` counts a branching subject only when it is a view held as a pointer, or when its header points.
  - A branching subject whose type moves or may (`moves != .no`, a type parameter's included) is rejected.
  - The guarded path binds a catch-all through the same `catchAllByAddress` fact.
  - A binding captured by address puts no `no_cell` requirement on the instance, so a Cell change through it reaches the subject.
- **Mark bare break and payload views past the arm built in CORE sentence 1.** Status words only. It needs the owner's approval and can be dropped on its own.
- **Update HANDOFF for B4b.**

## Tests
- **Behavior, all `# release`, with stack clobbers where views escape:**
  - header_points_through_temporary, header_temporary_points, header_branch_points, header_points_view_escapes (corpus a07, a08 and a27 with their stated output).
  - match_payload_view_outlives_arm, generic_view_field_escape (corpus g21), generic_catch_all_view_guarded (review-2 H1), generic_in_place_cell_holder.
  - break_moves_loop_local.
- **Reject:**
  - header_temporary_rejected and header_copy_plain_read: the copies only.
  - match_payload_view_escapes: what stays rejected — a view of a local subject's payload returned, the subject reassigned, moved or out of scope while the view lives, a held temporary.
  - match_generic_branch_of_places (review-2 C1), break_outer_name, and the generic Cell-holder copies.
- **Corpus:**
  - The review probes test/corpus/review-b4b-1-* (64) and review-b4b-2-* (62).
  - Stale probe comments are fixed (a07, a08, a27, a27b, a38, a14).
  - r3-or-arm-unsound and r3-or-break-planned now state the built verdicts.

## Verification
- **Grids:** each accepted program is compared with a reference and run in debug and `--release`.
  - **Headers:** 520 cells (13 forms x 8 subject shapes x 5 payload types). The reference is the same program with the index bound to a name. 374 accepted, 0 wrong.
  - **Payload views:** 15 subjects x 6 types x 5 escapes, plus a variant that changes the owner while the view lives. 462 accepted, all print the payload after a stack clobber; the 120 owner-change variants are all rejected.
  - **Generic bodies:** 12 subjects x guarded/unguarded x payload/catch-all, for Pt and Text. 44 correct, 48 owner-change variants rejected, 4 branch-over-places cells rejected.
  - **Bare break:** loop shapes x 6 types, compared with `break <x` on main. 36 equal.
- **Gates on 6b00e981:**

  | Gate | Result |
  |---|---|
  | `./test/run --delta` | 2877 passed, 0 failed |
  | corpus `--delta` | 7294 passed, 0 failed |
  | `matrix.py --delta` | 5735 programs, 3114 ran clean, 0 failed |
  | unit | 128/129 (1 skip) |
  | oracle sets | inside the suite, green |

- **Equivalence against main 62d0e0b5:** 9710 programs, 223 differ, and no accepted program became rejected.
  - 130 went from rejected to accepted; all are corpus or tests that run sanitizer-clean.
  - 81 are still rejected, with a different message.
  - 8 changed emit: the write match `(&v.slot(i).*).*`, and the generic catch-all `|*x| x.*`.
- **Reviews:** part 1 was clean (two Lows, both folded in). Part 2 had one Critical and one High, both generic-only and both regressions against main. Both are fixed as classes in 6b00e981.

## Known and left open
- **Over-rejections, also on main** (probes review-b4b-2-p22, p24/p25, p43):
  - a payload view pushed into a Vec in a `for` stays rooted on the loop binding;
  - a view from a match nested on an outer payload binding is rooted on that binding;
  - a write-view local a payload view came through cannot be re-pointed while the view lives.
- **`as` over a call's view:**
  - `if pick(?cv, ?Text("a")) as c` over a Cell holder stays rejected (open item: decide separately).
  - `if !pickw(!tv, ?Text("a")) as t` stays rejected as a copy.
- **A bug that predates this branch (on main):** `match wrap(x) .some(v) => v` in a generic, where `wrap[T](x: ?T) -> Opt[?T]`, passes check and then fails in Zig ("expected type 'T', found '*const T'").
- **Part 4, payload fields by name, is not built.** Every pass that zips bindings with fields by position would need one accessor, and whether a by-name pattern may leave fields out (or mix with positional ones) is a design question; it is in HANDOFF's open questions.
