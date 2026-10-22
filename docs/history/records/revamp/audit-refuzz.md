# Re-fuzz of the merged revamp (snapshot 5263941)

Compiler: `scratchpad/rig-5263941` (the snapshot; `bin/rig` was not used). Base for comparison:
`206ea77`, built from a temporary worktree into `scratchpad/refuzz/rig-base` (worktree removed).
Harness: `scratchpad/refuzz/h2.py` runs `rig check`, then `rig run` on accepted programs, with a
private `RIG_OUT_DIR` per program under `scratchpad/refuzz/out/<tag>/`. It kills the whole process
group on a timeout. Results are in `scratchpad/refuzz/res/<tag>.json`, compared with `cmp.py`. New
probes are in `scratchpad/refuzz/{t1..t10,p}/`.

Housekeeping: 7 orphaned `zig run` processes from the earlier fuzz audit (hung mutants from
00:24, ppid 1, about 4 cores busy for 2h40m) were killed before this run.

## Findings (deduplicated by root cause)

Classes: a = accepted, then Zig compile error or internal error; b = accepted, then leak, double
free, use-after-free, crash, or wrong output; c = compiler crash or hang; d = rejection with no
position or a misleading message; e = a plainly safe program is rejected (regression against
206ea77). **All four a/b bugs below also reproduce on 206ea77.** They are gaps the fixes did not
reach, not regressions.

| ID | class | minimal program | observed | suspected location |
|---|---|---|---|---|
| RF1 | b (critical) | see RF1 below | Accepted. Prints `1` and then `-6148914691236517206`: the loop reads `a.v` after `b.v = Vec()` freed it. Moving a borrow (`<r`) or a borrow holder (`<e` with `e = Ed(t: !x)`) into an argument or constructor field ends that name's loans. A later argument of the same call can then borrow the same root again. Variants: `race(<w, !x)` with `w = !x` (two live `!x`); `P(r: <r, b: <x)` (a borrow and its moved owner in one struct); `(!x).eat(<r)` (panics, index out of bounds); `.two(a: <e, b: Ed(t: !x))` then `match` binding both (UAF). A plain `race(r, !x)` is correctly rejected. | `src/ownership.zig` `moveVar`: `markInvalid(id, .moved)` drops the moved name's loans, and `walkCall` / the constructor walk do not keep a moved argument's loans live until the call or constructor completes, as an argument borrow would be. |
| RF2 | b (critical) | see RF2 below | Accepted. Prints `1` and then a freed-memory value. Two nested `match h` statements on an enum whose payload holds a write borrow (`Ed{t: !Box}`) bind two payload views of the same `!Box`. A write through the inner binding frees the Vec that the outer binding is iterating. | `src/ownership.zig` `walkMatch` / `bindPayload`: a payload binding that carries a write loan neither write-lends its scrutinee while it is live nor checks the root's loans when written through (O3/O4 covered field scrutinees and bare holders, not this). |
| RF3 | b (high) | see RF3 below | Accepted. Prints `-1` and then `rig: memory leak detected: 1 allocation`. The receiver temporary of a consuming method call (`mk().take(...)`) is lost when a later argument propagates. When `N` owns no heap memory, there is no leak report, but its `drop` body never runs (`fuzz/progs/ex/ex_propagate_consuming_receiver_temp.rig` expects `drop 1`). Plain arguments, constructor fields, `*P(...)`, and a moved receiver `(<x).take(...)` are all fixed. | `src/typecheck.zig` `checkArgs` → `recordCallSlots` and `src/emit.zig` `emitArgs` / `emitSlots`: call slots cover the arguments, not the receiver, so the emitted `(mk()).take(try n())` has no temporary and no `errdefer` for the receiver. |
| RF4 | a (high) | see RF4 below | `rig check` accepts it. `rig run` prints `8:7: internal error: cannot emit a clone of a value with drop glue (sema should have rejected it)`. The diagnostic also has no file name. `+b` on the owner is correctly rejected. | `src/typecheck.zig` `synthClone`: it calls `ownsResource(inner, ...)` on the borrow type `?B` instead of on the unwrapped `value`, so a borrow of a type with drop glue passes. Emit rejects it at `src/emit.zig:1943`. `Emitter.unsupported` prints no path. |
| RF5 | d (low) | `type Acc(T)`↵`  t: T`↵`  fun is(?self) -> Bool`↵`    self.t == 1.5`↵`sub main()`↵`  a = Acc(t: 1)`↵`  print(a.is())` | ``error: `Acc(Int)` cannot use `T = Int`: the generic body applies `==` to `T`, which `Int` does not support``, with the note `(a float literal)`. `Int` supports `==`; the problem is the float literal. `self.t + 1.5` gets the same message with `+`. On 206ea77 this ran and printed `false`, so it is also a small class e. | `src/typecheck.zig` `checkGenericInstantiations`: the message for the float-literal requirement. |
| RF6 | e (low) | `struct N`↵`  id: Int`↵`  sub bump(!self)`↵`    self.id += 1`↵`  drop self: !N`↵`    self.bump()`↵`    print("drop", self.id)`↵`sub main()`↵`  x = N(id: 1)` | Rejected: ``cannot call `bump`, which takes `!self`, inside the drop body: it could replace `self` ...``. On 206ea77 this printed `drop 2`. This is the deliberate F10 safeguard (6fe785e), but it also blocks every mutating helper called from a drop body, including ones that only touch a Copy field. Four more `fuzz/progs/db/*` probes changed the same way. | `src/ownership.zig` / `src/resolve.zig`, the drop-body lending rule. A narrower rule would reject only methods that assign `self` (or pass it on as `!`). |

### Minimal reproducers

RF1 (`refuzz/p/dw14.rig`; the variants are `dw11`, `dw13`, `mv1`, `mv2`, `dw6`)
```rig
struct Box
  v: Vec(Int)

sub race(a: ?Box, b: !Box)
  for x in ?a.v
    b.v = Vec()
    print(x)

sub main()
  x = Box(v: Vec())
  (!x.v).push(1)
  (!x.v).push(2)
  r = ?x
  race(<r, !x)
```

RF2 (`refuzz/p/mh1.rig`)
```rig
struct Box
  v: Vec(Int)

struct Ed
  t: !Box

enum Hold
  none_
  has(e: Ed)

sub main()
  x = Box(v: Vec())
  (!x.v).push(1)
  (!x.v).push(2)
  h: Hold = .has(Ed(t: !x))
  match h
    .has(a)
      for n in ?a.t.v
        match h
          .has(b)
            b.t.v = Vec()
            (!b.t.v).push(0)
          .none_
            print("n")
        print(n)
    .none_
      print("none")
```

RF3 (`refuzz/p/ex1.rig`; `refuzz/p/ep2.rig` f4 shows `mk(4).pair(mk(40), n()!)`, which drops 40 but not 4)
```rig
struct N
  id: Int
  v: Vec(Int)

  drop self: !N
    print("drop", self.id)

  fun take(self: Self, k: Int) -> Int
    self.id + k

error E
  bad

fun n() -> Int!
  return E.bad

fun mk() -> N
  x = N(id: 1, v: Vec())
  (!x.v).push(5)
  x

fun f() -> Int!
  mk().take(n()!)

sub main()
  print(f() catch -1)
```

RF4 (`refuzz/p/clone1.rig`; `clone3.rig` is the same with a struct that only holds a `Vec`)
```rig
struct B
  n: Int

  drop self: !B
    print("drop", self.n)

sub main()
  b = B(n: 1)
  x = ?b
  y = +x
  print(y.n)
```

No class c finding: no compiler crash, panic, or hang on any input, including 4,000 fresh mutants,
the 2,400 front-end mutants, and every deep and stress program. The remaining slow cases are fixed:
`r01_mutual_fanout` takes 0.01 s (it hung before), the 3,000-module chain takes 3.0 s (it
segfaulted), 100,000 locals take 1.3 s to check, and `manyerr.rig` takes 2.75 s, capped at 100
errors (it took 40 s). `fuzz/deep/many100000.rig` still times out in `rig run`, but that is Zig
compiling 100,000 locals, not Rig. No rejection without a position appeared anywhere.

## Not bugs (checked and set aside)

- Intended changes: whole floats print as `1.0` (8 fuzz, 7 typecheck, and 1 frontend expectation
  diffs); leftover loop elements drop in reverse (`vec_for_consume_break`, F14 depth order); owned
  closures that capture borrows are rejected (12 ownership probes); `Signal(...)` only directly under
  `*` (`sg02`); `x =!y`, `t.5`, `0777`, and raw tabs are rejected; `main` must be `sub main()`; the
  root file must end in `.rig`; module alias and case imports are rejected; `while` steps are
  restricted; enum values are checked; `E!` is rejected; defers that read a returned (moved) local
  are rejected (`p64`, `p64e`, `p29`, `p30`, `p40`: O2); constant `@enumFromInt` is rejected;
  imported generic instances are rejected transitively (`m13`); more than 32 parameters with a `pre`
  are rejected; a Signal that captures itself (`signal_strong_cycle` and 2 mutants) is an allowed
  strong-cycle leak.
- Runtime panics that are intended safety checks: overflow, shift amount out of range, float to int
  out of range, index out of bounds, negative capacity, division by zero, and `Signal.subscribe`
  during notify. 26 across the corpora.
- Fuzz expectations that were wrong: `clo_self_referential_via_cell` (0 is correct),
  `generic_self_ref_through_handle` (fields drop in reverse declaration order), and `pr_empty`
  (`print("", "")` prints the separator). Output unchanged from base: nested Strings print unescaped
  (`H(s: "x"y")`, `["a<newline>b"]`), `Cell(value: 3)`, and single-field payloads print positionally.
  The spec does not decide these, and the fuzz audit did not charge them.
- The F2 symlink program now prints `1 1`, which is the intended fix: `use` resolves in the display
  directory.
- E1 (a `catch |e|` block used as a statement must yield `Int`) and phase-C gap features
  (break-with-value, field defaults, module constants, nested capture, slices) are still rejected,
  as on base: 69 of the 83 `audit-gaps` probes.

## Counts per corpus (206ea77 → 5263941)

"a/b/c" counts programs that `rig check` accepted and then failed, or that crashed or hung the
compiler. "f" counts programs that failed on base and now pass or are cleanly rejected. Intended
runtime panics are counted separately.

| corpus | programs | base a / b / c | new a / b / c | f (fixed) | notes |
|---|---|---|---|---|---|
| audit-sema | 147 | 18 / 2 / 1 | 0 / 0 / 0 | 21 | 4 newly rejected, all intended (m13, pre01, v04, v09) |
| audit-typecheck (b*/) | 357 | 26 / 0 / 0 | 0 / 0 / 0 | 26 | 8 → 9 intended panics (`s01` now accepted, overflow panic); T1 prints 2.5; RF5 |
| audit-ownership | 69 | 1 / 26 / 0 | 0 / 0 / 0 | 27 | 9 double frees and 13 UAF/OOB panics now rejected; 3 now print the missing `drop` |
| audit-emit | 126 | 15 / 6 / 0 | 0 / 0 / 0 | 21 | EM-4 order (`x 7 y 1`), EM-11 single evaluation, EM-25 array print, all verified |
| audit-gaps | 83 | 4 / 0 / 0 | 0 / 0 / 0 | 4 | gap features not merged yet (69 still "not supported yet", as on base) |
| audit-docs | 43 | 4 / 0 / 0 | 0 / 0 / 0 | 4 | |
| audit-frontend (top level, tiny, mods, stdroot, q, cli) | 198 | 13 / 0 / 3 | 0 / 0 / 0 | 20 | `rig test` on `q/a"b.rig`, `__rig_test`, and test-name escapes, plus extensionless `rig build`, all verified by hand |
| audit-frontend/fuzz (mutants) | 2,400 | 13 emit panics among 519 accepted | 0 among 506 accepted | 13 | 16 newly rejected, all intended (top-level statements, shift range, borrow capture) |
| fuzz final/min/diag/deep/progs | 1,019 | 37 / ~36 / 1 | 0 / 1 (RF3) / 0 | 83 | the other 19 "b" are expectation mismatches listed above |
| fuzz gen1/gen2/genf (model-checked) | 950 | 0 of 908 valid | 0 of 908 valid | — | 42 invalid (the generator reuses loop variables), as before |
| fresh gen_own (seed 424242) + gen_own_fail (seed 777001) | 500 | — | 0 | — | all 500 match the model |
| old accepted mutants (`fuzz/mut_done`) | 532 | 9 Zig errors | 0 | 9 | |
| fresh mutants (`refuzz/mutfuzz.py 4000 31337`) | 4,000 check / 595 run | — | 0 / 0 / 0 | — | 0 crashes, hangs, or unpositioned diagnostics |
| new targeted probes (`refuzz/t1..t10`, `p/`) | ~130 | — | RF1–RF4 | — | borrow representation (O1), error-path temporaries (O9), holders (O4), generics (T1–T3), labels, function values, numeric constants, print depth, modules |

Total fixed (f) across the audit and fuzz corpora: about 228 previously failing programs now pass or
are rejected with a positioned diagnostic.
