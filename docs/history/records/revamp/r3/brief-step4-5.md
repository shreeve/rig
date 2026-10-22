# Brief: HANDOFF step 4 ("Containers hold anything") + the rest of step 5 (REVAMP-3)

Read `/Users/shreeve/Data/Code/rig/.git/revamp/r3/brief-common.md` first (North Star, Zig 0.17
references, conventions, shared machine), then AGENTS.md "How we build", docs/CORE.md (sentences 1
and 2, §4, §5, §6), and HANDOFF.md steps 4 and 5. You are the ONLY branch allowed to change
`src/ownership.zig` and typecheck's classification.

## The plan
`/Users/shreeve/Data/Code/rig/.git/revamp/r3/audit-steps3-6.md`, sections "Step 4" and "Step 5", with
their soundness risks. Line numbers predate steps 1–3; re-find each site. Use what is built:
- step 1's type facts (`copyable`, `moves`, `cloneable`, `isUnique`, …);
- step 2's `handsOver`, `valueParts`, the `Use` fact, and `exitTo`;
- step 3's `lendsAs` table, implicit lends, and the `Header` fact.

**Already done, skip:**
- 5.1 (fail only through `return`), 5.2 (the Bool long form), 5.3 (`const`);
- 4.5 (`new x: T = e` and `new const x = e`): step 5a built them.

**To build, in this order:**
1. **4.1a:** admit owners in Vec, arrays and slices. `Vec[Text]`, `Vec[Vec[Int]]`, records owning Text, arrays of Boxes; promote CORE's pending example near L535.
2. **4.1b:** views in a Vec. The Vec holds the union of pushed loans; a write view is unique per push.
3. **4.2:** every element is a place. `?v[i]`, `!v[i]`, `<v[i]` of `T?` leaves `none`; `v[i] = x` drops the old value once; `x = v[i]` of an owner is rejected; emit never bit-copies an owning element with `at(i)`.
4. **4.3:** loops and `get` over owning elements.
5. **4.4:** one rule for assigning to a borrow place (Core §6 "Borrow places", pending example near L589). A view re-points; a value writes through; locals and fields alike; a re-pointed field *replaces* its loans (fixes `n39`). Parameters stay immutable (only `!T` writes through).
6. **4.6:** `std/sort` and `std/slices` search takes `x: ?T`.
7. **5.4:** a taken tail or `break` moves its name, at one take point before the scope's exit (through `exitTo`). Emit reads the recorded move.
8. **5.5:** `+x` clones Vec, Box and owning structs (sentence 2, pending example near L185), via `cloneable` and a runtime comptime recursive clone. Not cloneable: a type with a `drop` body, a `unique` type.
9. **Dead code from 5a**, now unreachable: the failing-tail-block exits (`.failing_result` exit, `ret_block` in ownership, `markReturningBlocks` in emit, the INTERNALS text "a final value whose type is, or may be, an error"). Remove the checker and emit sides together.

## Design owner's settled decisions
- **`v.get(i)`** for a non-copyable element stays copy-only, with a hint to `?v[i]`.
- **Sorting:** CORE §5's sentence becomes "`swap` and `sort_by` work for any element; `sort` needs `<`" (a status/precision change the owner asked for). `<` on Text is a new feature and stays out.
- **A bare held write view on an assignment's right side** writes through (local and field).
- **Which names move bare:** only a name whose own scope ends at that use: `return x`, a function's or block's last value, `break x` for a name local to the loop body. An outer name still needs `<x`. Update CORE sentence 1's status words only.
- **Cell[T] admission:** owner API only (set, replace, take); no new member forwarding.
- **`[n of x]`, `copy`, `fill`** stay copyable-only.

## Proof and gates (lean regime)
- Per commit: `zig build`, `./test/run -j N`, `./test/run -j N oracle`. The oracle's hard gate must never fire. If it does, stop and report: it is a likely hole.
- At the end: `test/equiv.py <base> bin/rig`, explaining every difference by commit (listed rejections → acceptances, the planned rules, promotions, new tests); then the four gates through `/Users/shreeve/Data/Code/rig/.git/revamp/r3/heavy.sh`.
- N is 4 when the 1-minute load is below 5, else 2.
- Wait while `~/Data/Code/mumps-compare/.mac-quiet` exists before every batch. Heavy runs only through heavy.sh.
- An independent review follows.

**Grammar:** if anything touches `rig.grammar`, `src/rig.zig` or `src/diag.zig`, write the exact change in your report for the Nexus mirror.

Commits short and imperative, no AI attribution, no Co-Authored-By. Don't push.

**Report in two parts:**
1. after step 4 (4.1–4.6);
2. after 5.4, 5.5 and the dead code, with the final gates.
