# Queued round: destination-passing for large aggregates

Owner-approved 2026-10-15, to run after #230 (the own-stack thread).

## Why

Zig's debug code makes hidden temporaries for aggregates moved by value, so
real frames are 2-6× Rig's count on aarch64 debug and up to 13× on x86_64
debug (Zig's own backend). The own-stack thread (#230) makes overflow safe.
This round makes the count honest and debug stacks small.

## The codegen review's measurements (units of one 800 KB value)

| Form | Today (LLVM debug / x86 self-hosted) | Spelling that hits the count everywhere |
|---|---|---|
| fill `[n of x]` | 2 / 2 (`@splat` also 2 in release) | `var x: T = undefined; @memset(&x.a, v)` → 1 |
| `x = mk()` | 2 / 3; callee's `return T{..}` 2 | out-parameter `mk(&x, n)` → 1, callee 0 |
| copy `y = x` | 3-4 | `@memcpy` → 2 (exact) |
| by-value argument | callee 1 / caller 2-3 | `*const T`: callee 0, caller 1 |
| `if` / `??` / `catch` value | 3 / 4 | each branch writes through `&x` → 1 |
| `A?` wrap | 3 / 4 | `var o: ?T = @as(T, undefined); fill(&o.?)` → 1 |
| `A!` wrap | 3 / 4 | out-parameter plus `E!void`: no wrap |
| literal holding arrays | 5 / 7 | per field: `@memcpy(&t.a, …)`, `@memset(&t.b, …)` |

The review's scratch files: scratchpad `stk/` (f.zig, g.zig).

## The rule

For aggregates larger than K bytes (about 64 KiB), emit uses destination-passing style:

- **Bindings** of such types are `var x: T = undefined`. Emit gains an `emitInto(dest, expr)` path for calls, literals, fills, branches, wraps and `return`.
- **Functions** returning such types take a hidden `out: *T`. Large parameters become `*const T`, or `*T` when the argument is moved.
- **One fact, decided once in `storage.zig`:** "the destination is disjoint from the right-hand side". When it fails (`x = f(?x)`), emit uses a hidden binding plus a `@memcpy`. Hidden bindings are counted, so the checker checks exactly what is emitted.
- **Small aggregates keep today's emit,** so release performance is unchanged.

Also in this round:

- Build x86_64 debug with `-fllvm`, which matches aarch64's frames form for form.
- File a Zig issue for inline stack probes on aarch64. LLVM supports them; Zig refuses `-fstack-check` on every non-x86 target.

## Gates

- The frame count equals the real frame, within a stated tolerance, over the grid and the corpus, on aarch64 and x86_64.
- equiv shows emitted-Zig changes only for aggregates over K.
- The JSON benchmark guard shows no release slowdown.
- The full matrix.
- An adversarial review.
