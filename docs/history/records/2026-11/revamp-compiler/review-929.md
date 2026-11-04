# Review of PR #929 (rv-order): what a call holds before its hoisted arguments

Probes are in `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/45a7b8df-588d-46f9-ab76-f1ed2a2c6a62/scratchpad/p929/`.
`run.sh F.rig` runs the branch's rig under `RIG_SANITIZE=1`, then the oracle, then main's rig (dd355f669).

## Verdict

The four fixes do what the PR says. Every form I probed now runs its self, handle, channel, or
reached callee before the arguments, sanitizer-clean, with no leak.

One issue remains in the PR's own class (E2), and it is serious: **a callee that is a name or a
field path is still read after the hoisted arguments.** The gate's comment says the checker holds
such a callee for the call. That is true when the callee owns (an owned closure), and false when
it copies (a `fun` value): the checker treats that read as a copy taken in its turn and keeps no
loan. So a later argument may reassign or free what the callee reads. The compiler and the oracle
both accept these programs. Main has the same bug: the PR does not cause it, but it does not fix
it either.

## Issue 1 (critical): a copied callee on a field path runs after the arguments, and reads freed memory

- **Where:** `src/storage.zig:416`, the gate `!contains(recv, .index) and !setActs(recv) and ...`,
  which returns null before line 419, `.invoked and !ownsValue -> .value`, is reached. Also
  `src/storage.zig:238`, where `heldFirst` returns null for any name (`callee == .src`), so a
  local of `fun` type is never held.
- **Probes:**
  - `g4.rig`: `b = ^H(f: add, s: ...)`, then `b.f(String("de"), consume(<b)!)`. The emitted Zig is
    `b.value.f(...)` after `consume` frees the box. The branch crashes with "use of freed memory".
    The oracle accepts the program.
  - `g5.rig`: the same through a `*H` handle. Same crash.
  - `g3.rig`: `h.f(String("de"), consume(<h)!)` with a plain local. It reads a moved-from field;
    harmless today only because a move does not poison.
  - `a3.rig`: `h.f(String("abc"), swap(!h, 1)!)`, where `swap` sets `h.f = mul`. It prints 15 (calls
    `mul`); the source order gives 8 (`add`). `a4.rig` gives the same wrong 15 with a local
    `f: fun(...)` and `swap(!f, 1)`.
  - `a5.rig`: the same call when it is not hoisted. It prints 8. So one source line gives two
    different results depending on whether the call is hoisted.
- **Fix:**
  1. In `decideSelfHold`, test `first.kind == .invoked and !ownsValue(ctx, recv)` before the gate,
     so every copied callee of a hoisted call is copied in its turn. The cost is one function
     pointer.
  2. In `heldFirst`, return a name callee bound to a local or a parameter (not a module
     function or a constant) as `.invoked`.
  3. Add cases a3, a4, g4, and g5 to `hoisted callee first`.
  4. Correct the comment at storage.zig:396-401: the checker holds an owning callee, not a
     copied one.
  5. Expect `tools/emit-diff` to change for hoisted calls with `x.f(...)` callees.

## Checked, clean (branch; oracle silent)

- **Selves:** keyword arguments out of order; an API object `?{Shape}`; a boxed API object from a
  call; a generic `[T: Shape]` body; a generic `gpick(?xs, 0).mix`; a method chain
  `s.next(5).next(6).mix`; `(mk(k) catch ..)`, `mk(k)!`, and a self of a ternary binding
  (`b1.rig`). The order matches the source; main got the same results here.
- **An optional self that owns** (`(o?)`, `o ?? return`; `f1.rig`): held through `rig.somePtr` into
  the place. Main ran these in the wrong order.
- **Actors** (`c1.rig`): `(!mka(1)).add(b:, a:)`, a made handle before an argument that fails,
  `(!hs[0])`, `hs[0].mix(.., fails()!)`, a ternary handle, and the task forms `&`. All in order,
  with no leak. Main leaks one allocation here.
- **Select arms** (`d3.rig`): pick 0, mks, pick 1, mkv. The order is right, and a made channel
  handle is dropped. Main runs it in the wrong order.
- **Std forms** (`h1.rig`): `!pickm(!ms, 0).put(..)` and `!ms[say(0)!].put(..)` run in order.
- **Growth or a move after a held self or handle** (`a1`, `a2`, `a7`, `g1`, `d2`, `g7`): every one
  is rejected by the checker, so a pointer-held self cannot dangle. `g2` (`fs[0](.., consume(<fs)!)`)
  is fixed by the copy: main crashes on it, and the branch prints 3.

## The weak spot (`&(rig.rt(mkh())).q`)

The PR makes the form reachable. `idh(?h).q(String, say()!)` (`e4.rig`) and the generic
`idg(?h).q(..)` (`e8.rig`) emit `const __rig_fn_N = &(rig.rt(idh(&h))).q;`.

In both, the call returns a pointer view, so the address lands inside `h`, not inside a Zig
rvalue, and the result is correct. Every form with a made temporary is rejected before emit:
`mkh(1).q(..)`, `(mkh(1) if c else b).q(..)`, `(oh?).q(..)`, and `(oh ?? ..).q(..)` (`e1`, `e3`,
`e7`). I found no path that takes the address of an rvalue.

**Minor, existing on main:** `(a if c else b).q(..)` over two locals (`e2.rig`) is rejected as "a
temporary that owns", which over-rejects.
