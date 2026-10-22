# Audit: ownership checker (`src/ownership.zig`), revamp @ 5f2bdbc

I read all of `src/ownership.zig` (4,194 lines), SPEC §8–13 and INTERNALS "Ownership", and wrote
about 280 probe programs (287 files counting common includes, plus 5 two-module directories) in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/audit-ownership/`.
The runner is `t.sh` / `t1.sh`: `rig check`, then `rig run` (Debug, checking allocator) when the check accepts.
Probe files `pNN_*.rig` are prefixed by area: a=prior findings, b=`??` jumps, c=while step, d=match,
e=take, f=closures, g=views, h=loops, i=copy/replace/swap, j=generics, k=Box trees, l=defer, m=temps/drop
bodies, n=joined `as`/guards, o=multi-borrow/arrays, p=Cell/Signal reentrancy, q=cross-module, r=labels,
s=early exits, t=drop order, u=conditional moves, v=write-through, w=fill literals.

All nine critical findings of the previous ownership audit (O1–O9) and F1/F3 are fixed: the `a*` probes
are rejected or run clean. **I found three new soundness holes. Each is a program `rig check` accepts
that frees memory it still uses.** All three come from one pattern: the state of a path that leaves
through a jump, or through a failing condition, is dropped instead of checked.

## Findings

| ID | file:line | category | severity | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| C1 | ownership.zig:1341-1345 (the generic `else` arm of `walkList` walks `??` sequentially); 1156-1158, 1250-1252 (`if (!reachable) break`) | unchecked code → use after move, double free, use after free | CRITICAL | `a ?? return v` / `?? break` / `?? continue` walks the jump as an ordinary operand. The jump sets `reachable = false`, so **every later statement in the same block is never checked**. A loop body's state after it never reaches the back edge either. A `catch return` is handled correctly: `walkCatch` joins its handler as a branch. | `b04_nullish_return_df.rig`: `n = make(k) ?? return -1` then `eat(<a)` twice → `panic: rig: double free`. `b06_nullish_return_borrow.rig`: `r = ?w; n = make(k) ?? return -1; w = W(..); print(r.v[0])` → `panic: index out of bounds` (reads freed buffer). `h12_coalesce_break_value.rig` / `h13_coalesce_continue_move.rig`: `eat(<t)` in a loop after `?? break`/`?? continue` → `assert(self.strong > 0)` panic (use after free of an Rc). `b02`, `b05`: repeated moves accepted. | Give `.@"??"` its own case in `walkList`. When `ir.@"??".right` is a `return`/`break`/`continue`: walk the left side; `base = here()`; walk the jump; `s = leave(base)`; `apply(join(stateAt(base), s))`; return the left side's value (as `walkCatch` does). Otherwise keep the sequential walk. Add a reject test per jump kind. | +10 | low |
| C2 | ownership.zig:2957 (`walkIfJoined`: `failed = captureBelow(base, base.vars)`), 3277 (`loopIteration`, joined `while`) | dangling borrow → use after free | CRITICAL | The failing path of a joined condition drops its `as` bindings. `captureBelow` silently **filters out** loans on those bindings held by outer vars. When the then-branch or body does not fall through (`return`, `break`, `continue`), `popScope` runs unreachable and does not report. So a borrow of a binding, stored into an outer value by a later part, survives on the else/after path. | `n04_joined_as_heap.rig`: `if <o as x and put(!vw, ?x)` / `return` / `print(vw.b.v[0])` → `panic: index out of bounds`. `r06_while_joined_return_store.rig` (same through `while`) → `index out of bounds`. `n01`: prints the dropped value's field after `drop 1`. Controls `n02` and `n03` (then-branch falls through or breaks) are rejected. | Before capturing `failed`/`exit`, report every loan on a var `>= base.vars` held by a live var below it. That is the loop already in `exitState` (3388-3392); factor it into `reportEscapes(depth)` and call it from all three places. | +6 | low |
| C3 | ownership.zig:3041-3062 (`walkMatch`: every arm starts from `base`) | dangling borrow → use after free | CRITICAL | A guard runs on the path to the later arms, but each arm is walked from the match's entry state. What a failing guard did (a store through `!vw` of a borrow of the arm's binding, or of an outer var) is not carried to later arms or to the no-arm path. When the guarded arm's body jumps, it is lost entirely. SPEC says a guard "changes nothing it matches", but a guard may still write-borrow other values. | `n08_guard_store_consume_uaf.rig`: `match <o` / `.some(x) if put(!vw, ?x) => return` / `_ => ...` then `junk = mk(12345)`; `print(vw.b.v[0])` prints **12345**, a freed buffer reused by `junk`. `n09_guard_store_outer_then_reassign.rig`: `3 if put(!vw, ?y) => return`; then `y = mk(12345)` is accepted while `vw` still borrows `y`. Controls `n06` and `r07` (the arm falls through or `continue`s) are rejected. | Either (a) carry guard effects: after walking a guard, `reportEscapes(base.vars)`, then fold `captureBelow(base, base.vars)` into a `guards` state that later arms and the no-match path start from (≈12 LOC); or (b) reject any write borrow or `!`-argument call inside a guard, completing the SPEC rule (≈5 LOC in typecheck). I recommend (b): a guard is a `Bool` test. | +5 / +12 | low |
| H1 | typecheck/emit (not ownership) | accept-means-correct | HIGH | `while !o as x : x.n += 1` with `o: Box[P]?` is accepted, but the emitted Zig does not compile: `use of undeclared identifier 'x'` in the `while (...) \|*__rig_opt_1\| : ({ x.value.n += 1; })` step. The step may read a condition binding only when it is plain data; a write borrow into a box passes that check. | `c01_while_step_wb.rig`: `rig check` exits 0; `rig run` fails with a Zig compile error. | Reject a step that reads a binding that is a borrow (`?T`/`!T`) or reaches through a box, or bind the capture in emit before the step. | +3 | low |
| M1 | ownership.zig:997-1020 (`indexUses`), 1062-1069 (`liveFrom`) | borrow rule (stale read) | MEDIUM | Liveness is textual. A `while` step (`: step`) comes before the body in the source but runs after it. So a condition binding whose last use is in the step counts as dead during the body, and the body may write the value it borrows. Memory stays safe only because the step may read plain-data bindings alone, which are copies. | `c02_while_step_rb.rig`: `while ?o as x : print(x.n)` with `o = none` in the body is accepted and prints the stale `1`. | In `indexUses`, record a use inside `ir.While.step` at the loop's end position (`extent(node).hi`). | +4 | low |
| M2 | ownership.zig:2369-2384 (`walkFieldAssign`) | false rejection | MEDIUM | A field store through a **local** write borrow (`w = !vw; w.b = ?y`) takes the "caller owns it" path and rejects every local loan, even when `y` outlives `vw`. The whole-value store `w = View(b: ?y)` is accepted (`storeThroughLocal`, `v04`). | `i03_field_assign_through_local_wb.rig`: "cannot store a borrow of `y` in `w.b`: `w` borrows `vw`, which outlives it". `y` is declared before `vw`. | For `v.kind == .local and v.ref == .write and borrowedRoot(id) != null`, call `storeThroughLocal(id, pos, value)` (which absorbs into `vw`, so `g02` stays rejected). | +2 | low |
| M3 | ownership.zig:3035 (`walkMatch`: the scrutinee's temporary borrow lasts the whole statement) | false rejection | MEDIUM | `match !t` / `match ?t` keeps its temporary loan on `t` through every arm. An arm cannot reassign or use `t` even after its bindings are dead. Rust NLL accepts this. | `k16_match_write_local_assign_root_after.rig` and `k15`: `.node(l, _)` / `l = ...` / `t = .leaf(v: 5)` gives "cannot reassign `t` while borrows are live", pointing at the `!t` of the scrutinee. | After `scrut_value = walk(scrut)`, shrink `temps` back to their length before the scrutinee. Bindings already carry their own loan on the root (`bindPayload`) or `scrut_value.loans`. | +2 | low |
| M4 | ownership.zig:3410-3451 (`walkDefer`/`runDefers` do not distinguish `errdefer`) | false rejection | MEDIUM | An `errdefer` is re-checked at every exit, including normal ones where it never runs. The standard pattern is rejected: `errdefer` cleans up a resource that the success path later moves into the result. | `l02_errdefer_reads_moved.rig`: `errdefer print(t.n)`; `n = fail(k)!`; `eat(<t)` gives "use of `t` after move". `l03`, which moves before the `!`, is rightly rejected. | Add `err_only` to `Deferred`. Skip it in `popScope` and at a plain `return`/`break`/`continue`. Run it only from `walkPropagate` (`!`) and from `return E.x` in a fallible function. | +6 | low |
| L1 | ownership.zig:1476 (`checkReadable` returns before the write-loan check for Copy types) | borrow rule | LOW | A Copy owner can be read while a write borrow of it is live: `w = !n; print(n); w = 5`. SPEC: "while a write borrow is live the owner cannot be used at all". This is memory-safe, because values are copied. | `i01_copy_read_while_wb.rig` and `i02` (String) are accepted. | Check `findLoan(id, .write)` before the `isCopy` return. This may reject existing `f(!n, n)` code; run the suite. | ±0 | med |
| L2 | ownership.zig:1868-1875 area, `absorbLoans` message 2315 | diagnostic | LOW | Storing into a `for vw in !arr` element says "the caller's value outlives it"; there is no caller. | `v11_wb_for_elem_store.rig` | Name the loop's collection in the message. | +1 | low |
| L3 | ownership.zig:3223-3266 (`walkLoop`) | performance | LOW | Each loop needs at least two quiet rounds plus the final walk, and a nested loop redoes its whole fixpoint in every outer round. The cost is exponential in nesting depth, about 1.8× per level: 12 nested loops take 0.05 s, 14 take 0.17 s, and the extrapolation is about 6 s at 20. Chains of loans converge fast (`perf_chain_*`: at most 0.02 s), and 800 live views take 0.06 s. | `perf_n{8,10,12,14}.rig` | Warm-start an inner loop's head from its previous converged head when the outer entry only grew (joins are monotone). The cost is then roughly linear in depth. | +10 | med |
| L4 | ownership.zig:1230-1241 (`walkStmtValue`) | performance | LOW | Every statement copies the whole `temps` list into a fresh `gpa` ArrayList and frees it. `here()` also dupes `temps` into the arena at every branch, loop, defer and lambda. | code reading | Save `temps.items.len` and restore by filtering (temps below the mark are only ever removed by `releaseVarsFrom`, which already filters by root). | −4 | low |
| L5 | ownership.zig:3268-3283 and 2951-2969 | simplification | LOW | The joined-condition walk exists twice (for `if` and `while`), each with its own capture of the failing state. C2 has to be fixed in both. | code reading | Extract `walkJoinedParts(cond, body, base) -> State` (it reports escapes, then returns the failed state) and use it from both. | −8 | low |

### Minimal reproducers

C1 (`b04_nullish_return_df.rig`): `eat 1 / eat 1 / panic: rig: double free or free of memory that was never allocated`
```rig
fun make(k: Int) -> Int?
  k if k > 0 else none

sub eat(v: Vec[Int])
  print("eat", v.len)

fun f(k: Int) -> Int
  a: Vec[Int] = Vec()
  !a.push(1)
  n = make(k) ?? return -1
  eat(<a)
  eat(<a)
  n

sub main
  print(f(3))
```

C2 (`n04_joined_as_heap.rig`): `panic: index out of bounds` reading `vw.b.v[0]`
```rig
struct Big
  v: Vec[Int]

struct View
  b: ?Big

fun put(v: !View, t: ?Big) -> Bool
  v.b = t
  false

sub main
  x0 = Big(v: Vec())
  !x0.v.push(0)
  vw = View(b: ?x0)
  o: Big? = Big(v: Vec())
  if <o as x and put(!vw, ?x)
    return
  junk = Big(v: Vec())
  !junk.v.push(12345)
  print("after", vw.b.v.len, vw.b.v[0])
```

C3 (`n08_guard_store_consume_uaf.rig`): prints `after 1 12345`. `vw.b` points into the dropped payload, whose buffer `junk` reused.
```rig
struct Big
  v: Vec[Int]

struct View
  b: ?Big

enum O
  some(x: Big)
  nothing

fun put(v: !View, t: ?Big) -> Bool
  v.b = t
  false

fun mk -> Big
  b = Big(v: Vec())
  !b.v.push(7)
  <b

sub main
  x0 = Big(v: Vec())
  !x0.v.push(0)
  vw = View(b: ?x0)
  o: O = .some(x: mk())
  match <o
    .some(x) if put(!vw, ?x) => return
    _ => print("other")
  junk = Big(v: Vec())
  !junk.v.push(12345)
  print("after", vw.b.v.len, vw.b.v[0])
```

### What held up

Every probe in these areas was rejected with a good diagnostic, or ran leak-free with the right output:
- **Take and path writes.** Take (`<p.f`) was right through every path tried (`e01`–`e16`): match views, `?T` parameters, loop elements, shared handles, captures, fixed bindings, temporaries.
- **Replace and swap.** `replace`/`swap` held for disjoint and nested fields, through `!T` parameters, and with elements (`i05`–`i12`).
- **Match.** Match payload views, `match !e` / `match <e`, guards that move, alternatives, and consuming arms in loops all behaved (`d*`).
- **Closures.** Stack, lent and owned closures, nested closures, stores through write captures, `|<x|`/`|+x|`/`|~x|` environments, and lent-callable conflicts all behaved (`f*`).
- **Views and write-through.** Views across scopes, write-through local borrows in all their forms (`!T` params, moved `<w`, returned `!T`, `match !e`, `if !o as`) and view nesting behaved (`g*`, `v*`).
- **Loops and early exits.**
  - Labels, `break`/`continue` with moves, loop `else`, and break values that borrow loop locals behaved (`h*`, `r*`).
  - Early exits with owning values in flight (`?`/`!`/`catch return` after an owning argument, constructors, `Box(...)`, consuming receivers, `for x in <v` with `break`/`return`/`!`) are leak-free (`s*`, `u*`).
- **Generics, Box and modules.** Generic functions and types with owning `T` (plain requirements, element takes, clone) behaved (`j*`), including across modules and through a third module (`q*`). Box trees and `Vec[Box[T]]` behaved (`k*`).
- **Drop order, arrays and runtime.**
  - Drop order for `drop` bodies that read borrows held through `Vec`, `*T`, `T?`, enums, generics and write-borrow params (`t*`).
  - Arrays of borrows, slices of arrays and Vecs, and fill literals (`o*`, `w*`).
  - Reentrant `Cell.set`/`replace`/`push`/`pop`/`clear` and `Signal.set` from `drop` bodies and subscribers (`p*`).

## Restrictions

| rule | where | serves North Star? | recommendation |
|---|---|---|---|
| Only whole bindings move; a non-optional field cannot be moved out (`return <n.v` in a generic list pop, `j10`) | ownership.zig:1901-1919 | yes (no per-field drop flags) | keep; the `T?` field + take idiom covers it (document the generic pop idiom) |
| A read loan excludes every write to its root, even a disjoint field (`replace(!p.a, +p.b)`, `two(!p.a, !p.b)`) | 606-619, 2580-2600 (swap only) | partly | keep for now; `walkSwapCall`'s `disjointFields` could extend to all calls later |
| The scrutinee's temporary borrow lasts the whole `match` | 3035 | no | relax (M3) |
| An `errdefer` is checked at normal exits | 3410-3451 | no | fix (M4) |
| A field store through a local write borrow rejects every local loan | 2369-2384 | no | fix (M2) |
| Stack closures cannot escape; closure bindings cannot be copied or moved | 2731-2737, 1445-1456 | yes | keep |
| Owned closures, Cells and Signals hold no borrows | 2470-2497, 2748-2764 | yes (aliasing through every handle) | keep |
| A guard may write-borrow values other than what it matches | typecheck | no (C3) | reject write borrows in guards |
| `for t in v` over `v: ?Vec[*T]` needs `?v` although `v` is already a borrow (`h04`) | typecheck | weakly | consider accepting a borrowed parameter as is |
| A loop that does not settle in 100,000 rounds is rejected | 3237-3247 | yes (never accept an unsettled state) | keep; unreachable with monotone joins |
| Generic bodies are checked for a `T` that holds no borrow; instances are re-checked | 460-516 | yes | keep |
| Copy owners are readable while write-borrowed | 1476 | contradicts SPEC | decide: fix (L1) or relax the SPEC sentence for Copy values |

## LANGUAGE QUESTIONS

1. **Guards.** Should a guard be forbidden to write-borrow anything, not only "what it matches"? That is fix (b) for C3, and it is the smallest change that makes guards side-effect-free for the checker.
2. **Copy owners under a write borrow (L1).** Enforce SPEC ("cannot be used at all") and reject `w = !n; print(n)`, or amend SPEC to allow reading a Copy owner, since it is a copy? Enforcing may reject existing code of the form `f(!n, n)`.

## Biggest simplification opportunity

All three critical holes come from one move: a path that leaves (a jump, a failing condition part, a failing guard) is captured with `captureBelow`, which drops loans on out-of-scope vars **without reporting them**. The reporting lives only in `exitState` and `popScope`. A single helper `leavePath(target: Point, depth) -> State` that always reports escaping loans before it captures would close C2 and C3 structurally. It would replace the three ad-hoc `captureBelow` call sites and `exitState`'s inline loop, and together with L5 (one joined-condition walker for `if` and `while`) it removes about 20 lines. Adding `??`-with-jump to the same "branch that may leave" treatment as `catch` (C1) makes every expression-level jump go through one join path. The checker then has exactly one way to model "control may leave here". Everything else in the checker held up under ~280 adversarial programs.
