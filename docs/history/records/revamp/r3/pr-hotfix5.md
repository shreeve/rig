## Summary

v0.1.4 has three ways a method receiver could read freed memory. This fixes all three:

- **A branching receiver's view.** A `?self` method called on a receiver that branches, such as `(a if c else b).inner()`, returned a view that carried no loan on `a` or `b`. The program was accepted and read freed memory once `a.t` was replaced. The same hole existed through a field or element base, `??`, `catch` and `o?`.
- **A kept receiver of a call whose arguments run first.** For example `mk("a").pick(y: f(1), x: f(2))`. The temporary receiver was copied out of its statement slot and dropped twice. A branching receiver copied the same way, `(a if … else b).size(y: …, x: …)`, was also dropped by the call's block.
- **A view a method stores of its receiver.** A method may store what its receiver lends or holds in a write argument: `sub put(?self, out: !Holder)` with `out.r = ?self.items[..]`. The caller kept no loan on the receiver, so `s.put(!h); -s; print(h.r[0])` read freed memory.
- **A write view of a temporary receiver.** A `!self` method on a temporary, as a function's tail (`!mk(42).at()`), returned a pointer into the dead receiver. `--release=fast` printed 0 instead of 42.
- **A change to a branching receiver.** A method that changes its receiver, called on a value that branches (`(h1 if c else h2).q.bump()`), changed a copy, so the change was lost. With a `!self` method on a plain struct, the generated Zig failed to compile.
- **A view of a plain-data temporary receiver** (`r = mk().arr()`, or a part that holds a Cell) could outlive its statement.

## Cause and fix

**Checker.** A `?self` method whose result may keep a view lends its receiver, exactly as `?e` does:
- **A temporary receiver goes through `lendTemp`.** A branching value that may be a name's value is rejected, with a hint to lend each branch: `(?a if c else ?b).m()`.
- **Any other temporary, plain data included, is kept in a slot** until its statement ends.
- **A receiver that is not a place is lent where its path starts.** The ownership checker does this, so the view keeps the temporary's loan through plain fields and elements.

**Receiver stored in a write argument.**
- **The receiver counts as an argument.** What it lends or holds goes where the arguments' loans may go: into write arguments whose type could hold a view (`walkCall`, `absorbThroughWrites`).
- **Coverage:** `?self`, `!self` and consumed receivers, including fields, elements, values reached through a handle, and temporaries.
- **The write-receiver conflict check runs before those stores.**

**`!self` receivers and changes to a branching receiver.**
- **A temporary receiver is kept in its statement's slot** for `!self` methods too, whenever the call may keep a view through its result or a write argument. The existing checks then reject the view in every tail position: a function or closure tail, `return`, an `if` or `match` arm, a `break` value, and a binding.
- **A call that may change a branching receiver is rejected,** or a call on a field or element of one. That covers `!self` methods, and `?self` methods on a value that holds a Cell. The hint points to the form that works: `(?h1 if c else ?h2).q.bump()`, `(!a if c else !b).inc()`.

**Emit.**
- **A kept receiver evaluated before its arguments is held by its address.** It sits in its statement's slot (it may also be a field or element of what the slot holds), and is reached as `const __rig_recv_N = &(rig.keep(...).*)`. Only the slot drops it.
- **The call's block never drops a hoisted copy of a branching receiver.**

The rejection costs one form: a view-returning method on a branching receiver is rejected even when the view is used only within its statement, e.g. `print((a if c else b).inner())`. The diagnostic gives the form that works: `(?a if c else ?b).inner()`. Methods whose result holds no view, such as `(a if c else b).size()`, are unaffected.

## Tests

- **Reject tests:**
  - `test/reject/ownership/receiver_view_of_branch_lends_it.rig`: `if`, field base, index base, `??`, `catch` and `o?`, with String, `?Text` and `?[4]Int` results.
  - `test/reject/ownership/receiver_view_of_temporary_outlives_statement.rig`.
  - `test/reject/ownership/origin_receiver_stored_in_argument.rig` and `receiver_stored_in_argument_siblings.rig`. v0.1.4 accepts both, and both read freed memory.
  - `receiver_view_of_temporary_leaves_tail.rig` (11 tail forms) and `branch_receiver_change_lands_in_copy.rig`. v0.1.4 accepts both.
  - Behavior tests `write_receiver_view_in_statement.rig` and `branch_receiver_change_through_lends.rig` cover the forms that keep working.
- **Behavior tests:**
  - `test/behavior/emit/kept_temporary_receiver_in_place.rig` and `test/behavior/emit/branch_receiver_copy_not_dropped.rig`. Both crash on v0.1.4.
  - `test/behavior/ownership/receiver_view_used_in_statement.rig`.
- **Corpus, matrix and SPEC:**
  - Two corpus probes.
  - Matrix contexts `recv_view`, `recv_view_then_write` and `recv_view_held_then_write`. On v0.1.4, `shared.recv_view_held_then_write.ternary` uses freed memory.
  - SPEC examples: one accepted, one rejected.

## Verification

- **Gates:** the full suite (2338 passed), corpus (4285), matrix (0 failed) and unit tests are green under `RIG_SANITIZE=1`.
- **Equivalence against v0.1.4:** 17 of 6359 programs differ. 14 are new tests or examples. In the other 3, a plain temporary receiver is now kept in a slot. That change is emit-only, and the output is the same.

## Core conformance

- **Checker:** CORE §3, "A view of a temporary may be used only within its statement", and its status note that a lend of a branching value is planned; today each branch is lent. The rule rests on sentence 4: a `?self` receiver whose result keeps a view is `T.m(?x)`.
- **Receiver stores:** sentence 4, "the owner lends". A method call lends its receiver as `?s` or `!s` would, and sentence 6 keeps that loan live while a stored view carries it.
- **`!self` and branching receivers:** sentence 4 for `!x`; §3's "A view of a temporary may be used only within its statement"; and §3's note that a branching value which may be a name's is not lent as a whole. Today each branch is lent instead.
- **Emit:** sentence 3, "A value no name holds is dropped where its statement ends". It is dropped once, by its slot. Also §3, "Reading never moves a name, whatever form reads it": a branch's copy reads its leaf's value and never drops it.
