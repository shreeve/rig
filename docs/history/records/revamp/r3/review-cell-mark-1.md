# Review: cell-mark (PR #100, head c0721793), round 1

Verdict: **not ready to merge**. There is one Critical hole (a use of freed memory in safe code) and one High (programs that `rig check` accepts but whose Zig does not compile). Both have the same cause: the PR now lets a handle that is held where it may not be written be lent as the handle itself, `!*T`. The fix for "`!w.h` hands out a `!*C`" covered only part of that class.

Probes: `.git/revamp/r3/review-cell-mark-1-probes/` (76 files). Each was run under `RIG_SANITIZE=1` in debug and in `--release`, and through `rig-oracle`. Probes that 78467727 rejects are noted.

## Critical

**C1. `!c` lends the handle slot of a binding that may not be written.**
In `requireAccess`, `lendsHandle` skips `requireBinding` in two places (typecheck.zig:1390 and :1430). In `lendsToWriteOperand`, a `?*T` binding becomes `!*T` (around :4319, `.read_view => if (handle_view) write_view(base)`). The fix in 17156971 (around :4306) lends as `!T` only when `place.blocked != null`. Bindings at `steps == 0` that may not be written still get `!*T`, and a callee taking `x: !*Cell[..]` can then repoint them:

- `p51_repoint_for_uaf`: `for c in v` (a read loop) with `k(v[0], !c)`. The callee repoints `c` and drops the old box while `a: ?Cell[Vec]` still views it. **Debug sanitizer: use of freed memory. `--release`: prints garbage (`0`).** The oracle accepts it.
- These also repoint something that may not be written. Each runs and is sanitizer-clean, and each was rejected on main:
  - `p44`, `p49`: a `const` binding
  - `p46`: a `|+c|` capture, which persists across calls
  - `p48`, `p53`: an element of a Vec reached by a read `for`, including through a `?Vec` parameter
  - `p54`: an element of a Vec field of a `*H`, written through a shared handle
  - `p50`: the optional behind `if o as c`
  - `p76`: `replace(!a, ..)` and `swap(!c, !b)` on such bindings

Class: a lend of a handle that skips the writability checks must never be a lend of the handle's own slot. Generalize the :4306 rule to every handle that cannot be written where it stands, not only blocked places. That covers const and global bindings, non-`!` parameters, captures, read-view bindings from `for`/`if as`/`match`, and `?*T` parameters. Then `!c` is `!T` there, and `swap`/`replace` of the handle is refused.

## High

**H1. Accepted programs whose emitted Zig fails to compile** (Rule 2; same cause as C1). Zig reports "expected `*T`, found `*const T`" for `p45` (non-`!` handle parameter passed to `!*Cell`), `p47` (`?*Cell` parameter) and `p69` (`match` payload of a `?E`). `p76` fails with "cannot assign to constant". The C1 fix closes these too.

## Medium

**M1. CORE sentence 4, "`?` promises that nothing changes", is false as the PR ships it.**
- A `?*Cell` view, a `|?c|` capture, or a `?S` that holds a handle can change the Cell: `!h.set(5)` (`p03`, `p07`, `p09`, `p10`). The PR body treats this as intended.
- A `?self` on a holder sees its Cell change during a call that lends another handle (`p43` prints 5).

None of these corrupts memory: no interior view of a Cell exists, so this is a precision issue in the docs. A read view of a handle can always clone `+h` and mark that, so refusing `!h.set` through `?h` would only be cosmetic. Suggested wording: "`?` promises that nothing changes through it, except a Cell reached through a handle, by a marked call". Or keep the sentence and refuse a lend to write through a read view of a handle.

## Checked and sound

- **Unmarked changes.**
  - `.value` access is refused (`p01`, `p02`).
  - `?self` calling a `!self` helper, marked or not, is refused (`p04`–`p06`).
  - `!` through a `?Cell` or `?H` is refused (`p55`, `p56`).
  - A generic `?T` is refused (`p11`).
  - Generic instantiation with `H` is refused, whether explicit or inferred (`p57`, `p58`, `p62`).
  - Signal re-entry is caught by the runtime panic, or runs clean (`p26`, `p27`).
- **Two write views at once (focus 2).** Aliasing `!Cell` or `!H` views are harmless, because nothing hands out a view into a Cell:
  - `?c[0]`, iterating a Cell, `get()` of an owner, and handle elements are all refused (`p13`–`p15`, `p36`–`p39`, `p41`).
  - A plain element used as a method receiver is copied (`p40`).
  - Index-assign and push whose argument reallocates the Vec are ordered correctly (`p28`, `p29`).
  - Two aliasing `!Cell` views swapped run clean (`p34`, `p35`).
  - A write view of a holder changes only its Cells: assign, push, lend, take, replace and swap of a plain field are all refused (`p17`–`p25`, `p30`, `p31`).
- **The four fixes.**
  - swap/replace of a holder: complete, including generics.
  - `!w.h` handing out `!*C`: complete for blocked places, incomplete otherwise (C1).
  - `(!c)[i] = view`: complete, across holders, `!H`, `?*H`, captures, Signal and push (`p72`–`p75`).
  - The emit fix for a method receiver and the `match !x` crash: complete across capture, `if as`, `match` (temporary, `!`, `?`), Box, read-view parameters, for loops and const fields (`p63`–`p68`).
- **Deleted pointer forms.** No write through a `*const` was found. Every accepted Cell write goes through the RcBox pointer, which is mutable. The writes in H1 fail to compile; they are not UB.

## Oracle
The oracle stays silent on C1. `test/oracle/lower.zig` (`handleSlot`) models the marked lend as the handle's slot, so a repoint of an unwritable binding is not modelled as a write of that binding.
