# PR: bit methods and the wrapping left shift

## What
- `x.leading_zeros()`, `x.trailing_zeros()`, `x.count_ones()` on every integer type: an `Int`,
  lowered to `@as(Int, @clz/@ctz/@popCount(@as(T, x)))`. Signed types count the bit pattern; zero
  gives the width. `x.swap_bytes()` (`@byteSwap`) in the receiver's type. All ride the `x.not()`
  mechanism (`ElemOp`, `bitCall` in typecheck, `emitElemCall`), so no new classifier or fact.
- `<<%` (wrapping left shift) and `<<%=`, beside `+%`, `-%`, `*%`. Same precedence as `<<`. The amount
  is `@intCast` as for `<<`, so an amount at or over the width is a constant rejection or a runtime
  panic, never masked. Lowers to Zig `<<` on the operand's type; `<<` still emits `@shlExact`.
- Constant folding wraps `<<%` in its type like the other wrapping operators.
- Grammar: two tokens (`lshift_wrap`, `lshift_wrap_assign`); zero conflicts (generation passes).
  No existing source has `<<%` or `<< %` (`%` has no prefix form).

## Not done
- `rotate_left(n)` / `rotate_right(n)`: take an argument whose range rule (mod width or below width)
  is a new decision, so they do not fit the no-special-case mechanism.

## Decisions to confirm
- Bit methods on negative signed values count the two's-complement pattern (`(-1).count_ones()` is 64
  for `Int`, `I8` -1 gives 8). Documented in SPEC.
- A non-integer receiver gets the ordinary "type `Float` has no method `count_ones`" message.
- Should `rotate_left` / `rotate_right` reduce the amount mod the width, or require it below the width
  as shifts do?
