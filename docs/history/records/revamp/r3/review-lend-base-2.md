# Review 2: PR #90 `lend-base` (bb46d1a0 vs main faceba15) — PARTIAL

**Status: PARTIAL.** Paused for a reboot. The sanitizer run of the 313-program generated grid had not finished.

Setup: I built fresh detached worktrees of bb46d1a0 and faceba15, each with `zig build` and `zig build oracle`. Every accepted probe ran under `RIG_SANITIZE=1` in debug and `--release`, and through `bin/rig-oracle`. The probes are in `.git/revamp/r3/review-lend-base-2-probes/`. That folder holds `p/` (a-j), `k/`, `m/`, `n/`, and `gen/` with its `gen.py` and `gen.chk`. `probe.sh` is the harness.

**Verdict so far.** I found no soundness finding and no regression: nothing that faceba15 rejects is newly accepted and wrong. One accept-means-correct hole is in this PR's own class (H1). It is not new, since faceba15 behaves the same. But the round says this class is closed ("the lend moved ... and a field holding functions ... are rejected wherever they stand"), and it is not. It is a fix-the-class miss.

---

## High

### H1. A call of a field that holds a function never reaches `lendBase`. A moved lend there is accepted, and its Zig fails to compile.

`synthMemberCall` types a data-field call (`x.f(args)` where `f: fun(...)`) through `dataField` and `callValue`, not `memberOf`. So the decider never sees the call's object. Only the `x.f[i](...)` form (`ct != null`) goes through `memberOf`/`indexInto`, which is why `(!t).ops[1](5)` is rejected. `emitMemberBase` still has no parentheses for a `.move` of a lend (review 1, H1), so `(<(?t)).f(3)` is emitted as `&t.f(3)`.

```rig
fun double(n: Int) -> Int
  n * 2

struct T
  f: fun(Int) -> Int
  n: Int

sub main()
  t = T(f: double, n: 1)
  y = (<(?t)).f(3)
  print(y)
```

- **Observed, both commits:** `rig check` accepts it. The Zig fails to compile: `const y: i64 = &t.f(3);` ("expected type 'i64', found pointer").
- **Expected:** rejected, as `(<(?t)).x` is, with the hint `y = t.f(3)`.

Siblings, all accepted on both commits with Zig that does not compile (probes `p/e02`, `e09`, `e11`, `n/n01`-`n03`, `n08`):
- `(<(!t)).f(1) + 1`;
- `if (<(!t)).g(1)` (`g` returns `Bool`);
- `y = (<(?w.ts[1])).f(5) + 1`;
- `y: Int = (<(!w.t)).f(5)`;
- an owned-closure field, `y = (<(?c)).cb(1)` with `cb: *fun(Int) -> Int`;
- `arr[(<(?t)).f(4)] = 1`.

When the value goes straight to `print`, or is a function's last value, the program happens to run (`e01`, `n05`-`n07`).

The same bypass leaves these accepted on both commits, and they run correctly: `(!t).f(1)`, `(?t).f(1)`, `(!h).f(1)` and `(?h).f(1)` on a `*T`, `(?ts[0]).f(2)`, and `(!c).cb(2)` (`p/d01`, `d02`, `d07`-`d09`, `d12`, `n/n04`). But INTERNALS now says that "a field holding functions, called, is" a path, and the PR body names `(!s).f(1)` as rejected. That claim has no test, and it is false (AGENTS rule 1). Review 1's M2 asked for one of two things: cover these forms, or document them as exempt. Neither was done for the direct call.

**Fix (the class):**
- Call `lendBase(callee, obj, obj_ty)` on the data-field branch of `synthMemberCall`, so a member that is called reaches the one decider.
- Add `.move` to `emitMemberBase`'s parenthesized kinds as defence in depth.
- Test `(!t).f(1)`, `(?t).f(1)`, `(<(?t)).f(1)+1`, and an owned-closure field.

---

## Medium

### M1. A hint drops the sigil where the context expects a view (the class behind review 1's M3.2)

`useOf` keeps the sigil only for a binding of a value that does not copy, a header, or a write receiver. Every other read goes bare, including reads where a `!T` or `?T` is expected. In each case below the hint is rejected, and the next error gives the right fix (`lend it to write: !p.x`). Probes are in `k/`.

| Written | Hint | Hint's error |
|---|---|---|
| `bump((!p).x)` with `bump(n: !Int)` | `bump(p.x)` | expected `!Int`, got `Int` |
| `grow((!p).items)` with `grow(v: !Vec[Int])` | `grow(p.items)` | expected `!Vec[Int]` |
| `bumpq((!p).q)`, `bump((!p.a)[1])`, `bump((!r).x)` (with `r = !p`) | the bare path | same |
| `w: !Int = (!p).x` | `w: !Int = p.x` | same |
| `ws: [1]!Int = [(!p).x]` | `[p.x]` | same |
| `fun f(p: ?P) -> ?Vec[Int] from p` / `(?p).items` (last value) | `p.items` | expected `?Vec[Int]`, got `Vec[Int]` |
| `fun first(p: !P) -> !Int from p` / `(!p.a)[0]`, or `return (!p).x` | the bare path | expected `!Int` |
| `W(r: (?p).items)` with `r: ?Vec[Int]` | `W(r: p.items)` | expected `?Vec[Int]` |
| `w = (!p).q if c else !p.q` | `w = p.q if c else !p.q` | the `!` is now read only |

The rule the hint needs is the expected type: where a view type is expected, the sigil goes on the whole path. The round's hint check missed this because its programs put the lend-base path where a value is expected, not a view.

### M2. A hint that applies only part of a rewrite

These are from `gen/`, in `hint.gen.txt`. All three come from a lend of a branch's path, `!(!c if k else !d).a`:
- `for z in !(!c if k else !d).a` gives the hint `for z in !(!c if k else !d).a`, unchanged in substance. It is rejected: "`xs` must be a binding, or a field or element of one".
- `(!(!c if k else !d).a[..])[1] = 3` gives a hint that is rejected: "only a named array ... can be sliced".

The program is rejected either way, so these are hint quality only.

---

## Low

- **L1. A lend under a lend.** `(!(<(!p))).x = 4` gives the hint `(<(!p)).x = 4`, which is rejected in turn (`p/a11`). Contrived.
- **L2. A hint hides the real error in a generic body.** In `fun get[T](p: ?T) -> Int` / `(?p).x`, the hint is `p.x`. The real error, "a generic parameter `T` has no fields", is dropped by `inLendBase`, and the hint's form is rejected for it (`p/b19`, `b20`). This is the same class as review 1's M3.1, for shared handles.

---

## Checked and fine

- **No newly accepted program.** In the generated grid (`gen.py`: 15 base wrappers x 26 operations x 4 contexts, 637 programs), no program is accepted on head and rejected on main.
  - The base wrappers: `(!c)`, `(?c)`, `<` of each, branches, moved branches, a lend of a branch, `??`, `catch`, a held view, `<w`, and a `!S` parameter.
  - The contexts: a statement, a closure, a function's last value, and a parameter.
  - 313 are accepted on both, 205 rejected on both, and 119 newly rejected.
  - Of the 182 lend-base hints in it, 179 compile. The 3 bad ones are M2.
- **Closures.** Every context I tried is reported:
  - expression and block bodies, and an assignment body (`|!p| (!p).x = 7`, `+=`);
  - closures passed to a plain and to a generic parameter (the quiet `lentLambdaType` pass, then a loud one);
  - an owned `*|+p|` closure, and a nested closure;
  - `<(!p).o` as a body.
- **Other contexts.** These are reported too:
  - a `while` step, `defer`, `raw`, and a `match` guard;
  - an index expression, a `for` range bound, `return`, and `break` with a value;
  - constructor arguments, `print` arguments, and inferred generic arguments (`gid`, `gmax`, a generic struct, a method with compile-time arguments);
  - a typed binding, an optional binding, and a test block.
- **The quiet passes.** `synthQuiet` and `lentLambdaType` shrink the diagnostics, but `lendBase` runs loud whenever `quiet == 0`, and nothing caches a type in a way that skips the loud pass. The early return "a lend its own check rejected" relies on an error that persists. I found no route where `lendBase` returns without an error once `lendsPlace` holds, except H1, which never calls it.
- **Kept forms, all clean in debug and `--release` with the oracle silent:**
  - branches through `??` and `catch` of `(!P)?` and `(!P)!` results, `e!` and `e?` as a base, `<` of those, `as` headers, take, and push (`p/g*`);
  - lends of slices in an `as` header, take, `for !`, `bump(!(…)[0])`, a temporary's slice, Text slices, and a slice of a slice (`p/h*`);
  - `<` of a slice lend (`p/a07`-`a09`).
- **Receivers moved.** `(<(!s)).insert`, `(<(?s)).count`, `.put[2]`, `push`, `fill`, `swap`, `add`, and `get` are rejected by the receiver checks, or run correctly (`p/a*`, `p/f*`).
- **Optionals.** `((!o)?).x` and its kin are rejected by other rules (`p/i*`, `p/j*`).

## Not yet covered

- The sanitizer, `--release`, and oracle run over the 313 programs both commits accept. It was stopped after 6 of them for the reboot. Rerun with `runall.sh gen.acc` under `heavy.sh`. Everything in it is accepted identically by faceba15, so it can only find holes that predate this PR.
- Cells (`Cell[T]` fields in a path), weak handles beyond the error case, and Text receivers through a lend base.
- Paths in an imported module, where the hint's source and the `d.module == 0` check apply.
- A deeper look at `inLendBase` spans, which last for the whole module, with more than one statement on one line.
