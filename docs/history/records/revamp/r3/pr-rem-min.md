## Summary

On x86_64, `Int.min % -1` killed the program with "Arithmetic exception". Rig's `%` lowered to Zig's `@rem`, and the machine's division instruction traps on the minimum value divided by -1. On aarch64 the same program printed 0. So `rig check` accepted a program whose behaviour depended on the target: an "accept means correct" bug.

`%` now lowers to `rig.rem`, a small runtime function. For a signed integer whose divisor is -1 it returns 0, the minimum included; otherwise it is `@rem`. Sema's constant folding already gave 0 here, so constant and run-time remainders now agree. A divisor of 0 still panics, as before.

Found by the stricter corpus runner on the `test-infra` branch. `corpus/review-std-m5` prints `math.mod(Int.min, -1)`, and the old runner passed it on Linux because no failure pattern matched.

## Tests

`test/behavior/types/remainder_by_minus_one.rig` covers, with every divisor known only at run time:
- `Int`, `I32` and `I8` minimums `% -1`;
- `%=`;
- `math.mod`;
- a generic `T % T`;
- ordinary signed, unsigned and float remainders.

## Verification

- On pup (Linux x86_64), main's compiler aborts on `print(Int.min % neg(1))` with status 134. This branch prints 0.
- On the Mac, `./test/run behavior/types std review-std examples doc` gives 792 passed, 0 failed.
- Full gates on pup (Linux x86_64) at e447452c:

  | Gate | Result |
  |---|---|
  | suite | 2704 passed, 7 pending |
  | corpus | 6422 passed |
  | matrix | 3817 programs, 0 failed |
  | unit | 124/126, 2 skipped |
  | oracle, doc, vocab | 326 passed |
