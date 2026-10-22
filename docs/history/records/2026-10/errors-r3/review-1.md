# R3 review: errors that carry fields (branch `errdata`, PR #555)

An adversarial review of the branch before it landed, by probe programs
run under RIG_SANITIZE=1 (the probes are not kept; each finding below
names its own, and its case in test/rig/errors-data.rig.test keeps it).
Every finding reproduced with the branch's `bin/rig`.

## Confirmed findings, by severity

### 1. A temporary error value as a `match` or `if ... as` subject is evaluated twice and leaks (silent wrong behavior)
- p05c_match_temp_twice.rig, p05a/p05b, p64_temp_ifas.rig, p17_testleak.rig
- `match mk(1)` (read or `<`) and `if mk(1) as .bad(m)`, where `mk`
  returns an `E` with fields: emit switches on `rig.rt(mk(n)).code`, then
  reads the fields through `placeText(info)`, which for a temporary
  re-emits the call: `rig.rt(mk(n)).fieldsAs(E__bad)`. The call runs
  twice (its side effects twice: "mk called 1" printed twice) and the
  first result leaks (leak check fails).
- Cause: emit.zig match lowering, `err_value and info.reread.len == 0`
  -> `info.reread = placeText(info)` with `info.temp`. A temporary
  subject needs to be held once (as `headerPoints`/temp paths do for
  other subjects).

### 2. Hashing an error value hashes its raw bytes: `Set[E]` / `Map[E, V]` give wrong answers (silent)
- p47_set_key.rig: two `E.bad(msg: "a")` added to a `Set[E]` give
  `len 3` with `E.plain` twice; `s.has(E.bad(msg: String("a")))` is
  false; `Map[E, Int].get` of an equal key gives none.
- `rig.hashAs` treats `ErrorValue` as a plain struct: it hashes `code`
  and `data.bytes`, which hold a String's pointer (and undefined bytes
  for a member without fields, so even `E.plain` may hash differently
  in a release build). Values `==` calls equal must hash equal.
  Needs `__rig_own_hash` (or a glue `hash`) on ErrorValue, or the
  checker must refuse an error with fields as a key.

### 3. A `catch` inside the arguments or receiver of a call that takes a slot clobbers that call's slot (Zig error)
- p18_catch_in_args.rig `print(f(f(1) catch 0) catch -1)`,
  p19_catch_in_args_bang.rig `f(f(1) catch 0)!`,
  p76_catch_in_receiver.rig `(mk(n) catch P(n: 0)).next()!`
- Zig: "expected 2 argument(s), found 1". `openCatchSlot` overwrites
  `self.fail_slot` without saving it, and `closeCatchSlot` sets it to
  null, so the outer call (pending from an outer `catch` or `!`) loses
  its slot. `.propagate` saves and restores; the catch must too.

### 4. `return x` of a held error of a set without fields, from a function that takes a slot (Zig error)
- p41_return_plain_into_any.rig (`m(n) catch |e| return e` in a `T!`
  function, `e: M`), p43_held_plain_value.rig (`x: M`, `return x`).
- Emit writes `rig.failValue(__out, e)` for any failing leaf that does
  not name a member; `e` is a bare Zig error, not an `ErrorValue`.
  The test needs `isErrorValueTy(typeOf(leaf))`.

### 5. Views of an error with fields: `?E` / `!E` parameters, and `match`/`if as` on a view (Zig error)
- p28_lend_error.rig: `fun show(e: ?E)` emits the parameter as
  `rig.ErrorValue` by value while the call passes `&x`.
- p29_write_view_error.rig: same for `sub reset(e: !E)`.
- p61_for_match.rig: `for e in l` then `match e` emits
  `@as(*const E, @errorCast(e.*.code))` (the view type, not the set).
  p63_for_ifas.rig: `if e as .bad(m)` in the same loop; p60 via a
  `?List[E]` parameter.
- `isErrorValueTy` answers true for a view type (setHasFields looks
  through it), so `emitTypeTy` prints `rig.ErrorValue` for `?E`; and
  `writeErrorCode` is given the unpeeled view type.

### 6. `==` between two error values with fields (Zig error)
- p48_eq_values.rig `x == y`, `x != z`; p49_eq_call.rig
  `e == E.bad(msg: String("a"))`.
- Emits Zig `==` on `rig.ErrorValue` ("operator == not allowed"). The
  glue's `eql` exists (`ErrorValue.eql`) but `==` never routes to it.

### 7. `e == .plain` / `e != .plain` on an error with fields (Zig error)
- p70_dot_plain_eq.rig, p69_dot_member_test.rig
- Emits `rig.isVariant(e, rig.ErrorValue.of(...))`; `E.plain` (qualified)
  works through `isError`, the dotted form does not.
- Related, minor: `e == .bad` (dotted, member with fields) is rejected
  ("carries a payload") while `e == E.bad` is accepted.

### 8. A function of a set without fields lent where a slot-taking function type goes (Zig error)
- p07_fnval_coerce.rig (`m: Int!M` to `?fun(Int) -> Int!`),
  p75_thunk_union.rig (to `?fun(Int) -> Int!L`, L = E | M),
  p24_within_named.rig (`time.within(ns, m)`).
- Zig: runtime.zig `ofFn` "expected 1 argument(s), found 2". The
  thunk that lends it (runtime `ofFn`) passes the slot to a
  function that takes none. Widening from a set with fields works
  (p50_thunk_widen.rig).

## Pre-existing (also on main's binary), not from this branch
- p73b_list_lit_any.rig: `l = [String("a"), mk(n)!]` leaks `String("a")`
  when `mk` fails (same with no fields in the program, and with
  `/Users/shreeve/Data/Code/rig/bin/rig`). An object constructor in the
  same position does not leak (p72_build.rig).

## Checked and clean
- Handlers that `break`/`continue`/`return`/`!` with a bound error
  (p01, p02, p36), nested catches (p03), failure in an error's field
  initializer (p04, p72_wrap), `match <e` with guards, alternatives,
  catch-alls, jumps (p36), consuming loops (p66), moves out of a reading
  match rejected (p37), `if <e as` and `while pop() as` (p38), returns
  of held errors (p27), catch yielding optionals (p39), catch reached
  by address (p20, p52-p55), nested fallible closures with `__out_N`
  (p33), function values in lists and fields (p35), generic functions
  (p08, p59), generic duck-typed methods rejected (p22, p23), defer and
  errdefer with catch (p32), errors in objects, enums, maps, closures
  (p31, p68), three modules with a union (mm/p57_main.rig), String
  formatting (p74).
- Concurrency under 20 seeds (p16, p34): `task.all` with both failing,
  `par.map` with many failing chunks, `Tasks` wait_first with the rest
  failing, all failing, supervise with restarts, deadlines while
  failed tasks with fields are waited or canceled, spawned methods
  (p46), isolate of named functions (p26). No leak or sanitizer trap.

## Resolution

All eight were fixed in #555 before it landed, each with a case in
`test/rig/errors-data.rig.test`; the full suite (9,710 jobs) and Trig's
light gate were green at cc01ac95f.

1. A match on an error that may carry fields rereads its subject
   (`storage.decideMatchRereads`), so a temporary subject is held once
   in the match's block. Case: "a match on an error made there runs it
   once".
2. `ErrorValue` has `__rig_own_eq` and `__rig_own_hash`, through the
   glue's `eql` and `hash` by code. Sema records which members' fields
   compare and hash (`member_compares`), and the glue lists only those.
   The checker walks an error set's payload fields for `==` and hashing,
   as an enum's, and a union's sets. Case: "an error with fields keys a
   Set and a Map".
3. A `catch`'s slot keeps the slot lent to the call around it and gives
   it back when its block closes (`CatchSlot.saved`). Case: "a catch in
   the arguments of a call that takes the slot".
4. A failing leaf goes through `rig.failValue` only when it is an
   `ErrorValue` (`holdsErrorValue`); an error of a set without fields
   leaves as its code. Case: "a `T!` function passes on an error of a
   set without fields".
5. `isErrorValueTy` is false for a view type, so `?E` and `!E` are
   pointers to an `ErrorValue`, and a match's code is read through the
   peeled type. Case: "a view of an error with fields".
6. `==` on two errors that may carry fields is `rig.eql`. The checker
   requires every member's fields to compare (a set has `==` when every
   field does), and rejects two errors of any set compared whole, as
   spec §4.3 says (owner's default, approved with #555). Cases: "two
   errors with fields compare, as their set's fields do", "two errors
   of any set compared whole", "an error whose fields have no `==`".
7. Beside an error that may carry fields, a dotted `.name` is a member
   test of the one set that has it, and emit tests the code
   (`rig.isError`) before the payload-enum path. Case: "a dotted member
   tests an error of a set, a union, or any set".
8. `FnRef`'s thunks pass a callee only the arguments it takes
   (`argsFor`), so a function that fails without fields is called
   without the slot. Case: "a function without fields lent where one
   with them goes".

The pre-existing leak (p73b) was fixed separately in #559, and the
`Stop.canceled` after a failed `par.map`, found while building R3, in
#558.
