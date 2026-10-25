# Adversarial review: returning a view lent through a write-view binding

Snapshot `wv/bin/rig` and `rig-oracle`, 23 probe files with about 95 functions (scratchpad `review/p01..p23.rig`, `r1.rig`, `acc.rig`). Accepted programs ran clean under `RIG_SANITIZE=1`. No line showed prod=accept with ref=reject.

## Soundness holes

None found.

## Findings

**1. Oracle gap, medium: it accepts a push while a `break` value views an element.**
```rig
fun bp(!@) -> !Int from @
  r = for s in !@xs
    break !s.items[0]
  else
    !@a.items[0]
  !@xs.push(Slot(key: 1, items: List[Int]()))
  r
```
- The compiler rejects this, which is correct. The oracle accepts it (`stricter`), so the oracle would pass a real use of freed memory.
- The oracle also accepts a loop-body `defer s.items = …` beside `break !s.items[0]` (p06 `bd`, p14 `q3`), and `from @a` returning a view of `@b` (p09 `f1`, `f2`).
- **Fix:** record these as oracle limits, or give the oracle the break-value and `from @path` loans, so it cannot vouch for such programs.

**2. Over-rejection, low: a `for` over a local write view.**
```rig
lv = !@xs
for s in !lv
  return !s.items[0]
```
- This is rejected with "cannot return a view of `lv`". The same shape is accepted through `o = !@slots[j]` / `if !o as s` (p10 `t4`) and `t = !s` (p09 `f6`).
- The `for` source's lend on `lv` is not marked `deref` (`bindLoopElems` makes its own loan, not through `lendOn`).
- **Fix (optional):** route the source loan through `throughBinding`, or record it as a limit.

**3. Over-rejection, low, pre-existing: `errdefer` is treated as running on success.**
- `errdefer @a.items = …` / `r = !@a.items[0]` / `mayfail(j)!` / `r` is rejected with or without a binding (p20 `e4`). Bin 0.2.9 rejects it too, so this change did not cause it.

## What held

- **Rejected writes and re-points while the view lives:** writing or re-pointing `s`, `s.items`, `o = none`, or `@slots[j]`; moving `s` (`<s`); pushing to `@xs`. This held in the function and in callers, including `from @slots` callers.
- **Locals, temporaries and owned subjects are rejected:** views of locals (`s = !x`, `new s = !x`, a branch re-point to a local, `for s in !xs`), a `match !m` on a local owner or a view of one, owned optionals, temporaries, and closure locals.
- **`from @a` paths are checked:** returning a view of `@b` or of whole `@` is rejected.
- **Defers, closures, tasks and drop bodies:** writes or overlapping reads of `s` (or `t`, `o`, `m`) are rejected in every position tried:
  - the same scope, an outer scope, an inner block with a value, `match` arms, `catch` handlers, guarded returns, `break` (also with `s` outside the loop), nested `as` chains, and `and` joins;
  - deferred `|!s|` closures, tasks on `!s`, and drop bodies (objects hold only read views).
  - Disjoint paths are accepted and sound, for example `defer s.key = 0` with `!s.child…`.
- **Loops:** an earlier pass's binding used in a later pass is rejected, for `for`, a loop-body `s`, and `while … as s`.
- **Several results** (H5) are closed already by the signature rule: at most one write-view result, which cannot share a source with another result.
- **Shadowing:** `new s = !@b` while a view of the old `s` lives is accepted and sound.
- **Accepted and run clean under the sanitizer:** generics (`Box[T]`), inline-array slices, `match` on a call result, and the new accept test.

## Resolution (the build)

- **1:** the `break` value's loans and `from @a` are recorded as the oracle's gaps (`ref-gap` in test/oracle/differences); the compiler rejects each.
- **2:** fixed: a `for` source that is a write view a binding holds lends on through `throughBinding`, carrying the binding's loans, so `lv = !@xs` / `for s in !lv` / `return !s.items[0]` is accepted and the same over `lv = !xs` of a local is rejected (cases in test/rig/ownership-write.rig.test).
- **3:** left as it is: it predates this change.
