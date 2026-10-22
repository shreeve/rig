# Final verification: revamp @ 94df525

Build ok; `./test/run` 1077 passed, 0 failed. All fixes below were prototyped in a scratch copy (`final-scratch/patched`); with them the suite stays 1077/0.

## Issues

1. **HIGH, false rejection from the previous round (5f47356, `absorbThroughWrites` in src/ownership.zig).** Any call that passes a write borrow stores every other argument's loan in it, even when the pointee can't hold a borrow. Ordinary code is rejected:
   `fun f(a: !Int, b: !Int)` called as `f(!x, !y)` twice → "cannot take a second write borrow on `x`".
   `f(!acc, ?y)` then `y += 1` → "cannot reassign `y` while borrows are live".
   Inside `fun g(out: !Vec(Int))`: `t = 5; f(!out, ?t)` → "cannot let this call store a borrow of `t` in `out`".
   The corpus probe audit-emit/p46.rig, valid and accepted at 14d6044, is rejected now.
   Fix: restore the type guard the old `containerRoot` had. In `absorbThroughWrites`, skip a root `r` when `!self.mayCarryBorrow(self.pointee(self.vars.items[r].ty))`. With the fix, p46 is accepted and runs correctly, the corpora change nothing else, and loans stored into `!Ref(Int)`, `!H{r: ?Int}`, and advC/rf8 are still rejected.
2. **MEDIUM, accepted but the Zig fails to compile (pre-existing, src/emit.zig `emitValueAs`).** An `if`, ternary, or `match` that yields `?x` where `(?T)?` is expected, with `T` held by pointer (drop glue or a Cell), dereferences the borrow:
   `fun pick(a: ?D, k: Int) -> (?D)?` with body `?a if k == 0 else none` emits `(a).*` → "expected ?*const D, found D". The same happens in a generic `-> (?T)?` method.
   Fix: in `emitValueAs`, unwrap one optional level of `ty` before the `isPtrBorrowTy` test. Verified.
3. **MEDIUM, accepted but the Zig fails to compile (pre-existing, touched by b330e46).** Inside `type Bag(T)` with `items: Vec(T)`, `fun first(?self) -> ?T` whose body is `?self.items[0]` emits `rig.lend(&self.items.slot(0).*)`, and `slot` needs `*Self` ("discards const qualifier"). It fails for every T, including Int.
   Fix: `emitBorrowOf` sets `read_place = true` for a `.read` borrow, so the emitter writes `constSlot`. Verified.
4. **LOW-MEDIUM, wrong output (new, 1258a63).** The float-literal division rule does not reach generic bodies. `type Box(T)` with `fun f(?self) -> T` whose body is `self.v + 1 / 2`, called as `Box(v: 3.0).f()`, prints `3.0`. Under SPEC §6 ("integer literals in float arithmetic are floats") it should print `3.5`.
   Fix: where sema types the literal's `/` as a type parameter, emit `rig.div(@as(T, 1), @as(T, 2))`. Otherwise reject integer-literal `/` of type `T`.
5. **LOW-MEDIUM, accepted but the Zig fails to compile (new, e7c219b).** The range check sees only individual literals, not constant expressions. `w: F32 = 1e38 * 10.0`, `K: F32 =! 1e38 * 10.0`, and `v: F32 = 3.4e38 + 3.4e38` all fail with "type 'f32' cannot represent". Meanwhile `x: Float = 1e308 * 10.0` silently prints `inf` although `1e400` is rejected.
   Fix: fold float-literal constant expressions in sema and range-check the folded value. Or lower them through `rig.rt` so they are runtime values.
6. **LOW (new, `floatLiteralValue` in typecheck.zig).** The literal text is truncated to 128 bytes. `x: Float = 1` followed by 400 zeros and `.0` is accepted and prints `inf`. `0.` followed by 200 zeros and `1e600` would pass the check the same way.
   Fix: parse the whole literal, or reject any literal the buffer can't hold.
7. **LOW, data loss (new, 42b8137, main.zig).** On macOS's case-insensitive filesystem, `rig build -o prog.RIG prog.rig` overwrote the source `prog.rig` with the executable (reproduced).
   Fix: check the `.rig` suffix case-insensitively, and refuse an `-o` that resolves to the input file.
8. **LOW, false rejection (pre-existing).** A guard as the last statement of a `-> Void!` function is rejected: `return E.bad if i == 3` gives "`if` used as a value requires an `else` branch". The same guard works in a `sub`.
9. **LOW, code quality.** `zig fmt --check` fails on src/typecheck.zig: `floatLiteralValue` and the doc comment after it sit at column 0 inside `Checker`. It also fails on src/runtime.zig (`full[start .. if ...]`). The `defer drop` branch of `hoistReceiver` looks unreachable: sema rejects every resource-owning temporary as a receiver ("bind it to a name first").
10. **Doc nit.** SPEC §18's table shows `.rect(w: 2, h: 3)`, but a one-field payload prints unnamed (`.one(4)`, `.some(2.5)`). Say so in the table.

## Part A: reviewed and held up

- **`rig.ReadBorrow(T)`.** Tested with Int, String, a plain struct, a Cell-holding struct, `[2]CC`, `CC?`, a Cell-payload enum, `Cell(Int)`, a drop-glue struct, `*T`, `~T`, `*sub()`, `*Signal`, and nested `Box(Box(..))`. Also covered: generic enums with `?T` payloads, `?Self`, reborrows (`?r`, `o = ?self`), and methods returning `?T` that are matched, passed to non-generic `?Concrete` functions, stored in `Ref(T)`, or used with imported types. All were correct and leak-free, apart from items 2 and 3.
- **Receiver-first hoisting.** Receivers tested: array/Vec index with a call, a temporary Copy value (`?self` and `!self`), `f()!`, `?mk()`, borrow-returning calls (`?K`, `!K`), fields of temporaries, a chained `.subw()`, shared-handle fields, `o?.m`. Each was combined with keyword-reordered arguments and failing arguments, and also placed in a `while` condition, a `match` scrutinee, a guard, a `defer`, or an owned closure. Evaluation order and drops were correct. Ownership rejects every aliasing case I built (`v[i()].m(grow(!v))` and its variants).
- **Float-context division.** Tested `%`, `+=`, comparisons, ternaries, returns, arrays, optionals, `F32`, `=!` constants, imported constants, and shifts. All correct except item 4.
- Also held up:
  - slice, String-byte, and `.len` write rejection (22 bypass attempts, all rejected)
  - `eqlOpt`
  - `main` not callable (methods named `main` and `lib.main` still work)
  - module-qualified names
  - `.5` defaults
  - comptime-known shifts and imported constants (24 overflow cases, all correct)
  - `while` step propagation
  - trailing commas
  - BOM columns
  - printing `std`/`rig` type names
  - the previous round's Cell, capture, and defer rules

## Part B: corpora (new build vs d80bd87, differential and `# expect`)

Every file in the 15 corpora was checked with both builds: 14,698 files, 11,253 accepted. Acceptance changed only intentionally: `advB/c23` is now accepted and correct, and 8 out-of-range float literals are now rejected. No crash, hang, or diagnostic without a position.

3,933 accepted programs with a `sub main` were run:

| Corpus | Run | Exit 0 | Runtime panics |
|---|---|---|---|
| audit-frontend | 258 | 251 | 7 |
| audit-sema | 75 | 75 | 0 |
| audit-typecheck | 215 | 206 | 9 |
| audit-ownership | 22 | 22 | 0 |
| audit-emit | 79 | 77 | 2 |
| audit-gaps | 48 | 47 | 1 |
| audit-docs | 7 | 6 | 1 |
| fuzz | 1995 | 1961 | 28 |
| refuzz | 1113 | 1098 | 13 |
| adv / advA / advB / advC | 10 / 11 / 82 / 16 | 10 / 10 / 76 / 15 | 0 / 1 / 6 / 1 |
| tcbug | 2 | 2 | 0 |

Every panic is a defined runtime check: index or slice bounds, overflow, shift, casts, `Signal.subscribe` during a notification, or division by zero. The 6 segfaults are drop bodies that recurse forever, which is permitted.

Output matches d80bd87 everywhere, stack addresses aside. The 3 leaks are strong `*Signal` cycles. There were 2 timeouts: many100000 (Zig compile time) and a mutant with an infinite loop. The remaining `# expect` mismatches are the known intended changes listed in audit-refuzz.md.

Fresh fuzzing:
- gen_own: 250 of 250 matched the model.
- gen_own_fail: 150 of 150 matched.
- mutfuzz: 3,000 mutations, with no crash, hang, or diagnostic without a position. 473 unique mutants were accepted and run. None had a Zig error or leak; the 3 panics were overflow, bounds, and float-cast checks. Their output matches 14d6044 except for 2 intended new features.

Checking acceptance against 14d6044 also exposed issue 1. The other changes are intended rejections of unsound probes: adv*, advC df/rf, fix/w.

## Verdict

Not ready as-is. Issue 1 is a serious false rejection of ordinary code, found in the corpus. Issues 2 and 3 break "accept means correct". All three have small fixes that I verified here. With those three fixes in, and items 4 to 7 fixed or tracked, I consider the branch ready. I found no memory-safety hole in this round or the previous one.
