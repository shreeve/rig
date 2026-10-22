## Summary

v0.1.5 has two live bugs. This fixes both, plus two programs that failed to compile in Zig.

- **A header that makes a temporary binds a copy of its subject.**
  - `match pick(?mkh(?Text("…")))` with `.a(s) => print(s)` reads freed memory.
  - A guarded `match !arr[idx(?Text("a"))]`, `if !arr[idx(?Text("a"))] as n`, `while … as`, and `if (… if c else !w) as n` lose their writes.
  - `if ?arr[idx(?Text("a"))] as x` followed by `x.c.set(5)` loses the Cell change.
- **A callable held in a field, called with arguments evaluated first, leaks.** In `s.cb(Text(…), ?mkh(5).q, gf(2)!)` the arguments were matched to parameters shifted by one. The owned Text was held as a pointer with no drop, so it leaked when `gf(2)!` failed.
- **Zig compile errors.**
  - A guarded match on an element of a `?Vec[E]` parameter.
  - A name holding `?x` of a copied type (Int, String, plain enum) that is bound again to a call's result. This includes a generic method's result.

## Cause and fix

**Headers.**
- **Cause:** emit evaluates a header that makes a temporary inside a block that drops the temporary and yields the subject's value. So `match`, `if … as`, `while … as` and `for` bind into a copy.
- **The rule:** typecheck now rejects every such header, whatever it binds, at the temporary: "bind the index (the argument, `e`) to a name first". Emit's `hasTemps` and the rule read the same function (`sema.firstStmtTemp`).
- **Exemptions:**
  - headers that take what they bind;
  - a `for` over a slice;
  - plain data that is only read, from a value made in the header;
  - a `match` on a view a call returns.
- **That last exemption:** the ownership checker reports the view when its loans reach the header's own temporaries. That is the use of freed memory above.

**Field callables.**
- **Cause:** emit decided "this call has a receiver" in four places, from the shape `value.f(...)`.
- **Fix:** typecheck records when `value.f` resolves to a callable held in a data field. Emit (`receiverOf`) and the ownership checker read that one fact.

**Zig compile errors.**
- A guarded match takes a read element's address with `constSlot`.
- A name bound to a read view that copies its value holds the copy.

**Programs v0.1.5 accepts that are now rejected.** Each is a header that lends a value it makes: `if ?opt(3) as p`, `while ?opt(0) as q`, `match ?e(5)`, `match ?(mk())`, `match ?mk()`. Bind the value first, or write `match mk()`.

## Tests

- **Reject tests:**
  - `header_temporary_rejected.rig` (10 forms, all accepted by v0.1.5);
  - `match_view_into_header_temporary.rig`;
  - `header_taken_value_views_temporary.rig`;
  - `header_temporary_view_bound.rig`, updated.
- **Behavior tests:**
  - `header_temporary_bound_first.rig`;
  - `hoisted_field_callable_args.rig`, which leaks on v0.1.5;
  - `guarded_match_element_of_read_vec.rig` and `read_view_rebound_to_call.rig`, which fail in Zig on v0.1.5.
- **Matrix:** new contexts `match_subject_temp` and `as_temp`.
- **Corpus:** six probes.
- **SPEC §7:** one rejected and one accepted example.

## Verification

- **Gates:** the full suite (2348 passed), corpus (4291), matrix (1968 programs, 0 failed) and unit tests are green under `RIG_SANITIZE=1`.
- **Equivalence against v0.1.5:** 36 of 6374 programs differ.
  - 13 are new files.
  - 6 are now rejected: 4 corpus probes and 2 edited tests, each a header that lends a value it makes.
  - 13 already-rejected programs now show the header message first.
  - 6 differ only in emitted Zig, with the same output.

## Core conformance

- **Headers:** CORE §3, "A header's temporaries end with the header; what the header binds lives through the body." When the header's value is a copy, what it binds is not the subject, so a write lend (sentence 4) or a Cell change would miss its owner. The match-view report follows §3: "A view of a temporary may be used only within its statement."
- **Field callables:** sentence 3. An owned argument is dropped once, also when a later argument fails. Sentence 4: each argument is lent or moved to its own parameter.
- **Zig errors:** sentence 1 and §1. A read view of a copied type is its value.
