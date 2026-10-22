# aarch64: vector `uadd.with.overflow` reports overflow where there is none when the sum is also used (32+ byte lanes)

Not filed. Draft for upstream (LLVM AArch64 backend; first seen through Zig).

## Versions

- Zig 0.17.0 (bundled LLVM/clang 22.1.8), host aarch64-macos (Apple M5).
- Reproduces with `-mcpu=baseline`, `apple_m1`, `apple_m4`, `apple_m5`.
- x86_64 (Linux, same Zig): correct.

## Zig reproducer

```zig
const std = @import("std");
const V = @Vector(32, u8);
noinline fn add(a: V, b: V) V { return a + b; }
pub fn main() void {
    var a: V = @splat(1);
    var b: V = @splat(1);
    std.mem.doNotOptimizeAway(&a);
    std.mem.doNotOptimizeAway(&b);
    std.debug.print("{}\n", .{add(a, b)[0]});
}
```

`zig build-exe -OReleaseSafe` then run: `panic: integer overflow`. Expected
`2`. Debug prints `2`. `@Vector(16, u8)` prints `2`.

## LLVM IR reproducer (no Zig involved)

```llvm
target triple = "aarch64-apple-macosx"
declare void @fail()

define <32 x i8> @add(<32 x i8> %a, <32 x i8> %b) {
entry:
  %r = call { <32 x i8>, <32 x i1> } @llvm.uadd.with.overflow.v32i8(<32 x i8> %a, <32 x i8> %b)
  %o = extractvalue { <32 x i8>, <32 x i1> } %r, 1
  %m = bitcast <32 x i1> %o to i32
  %ok = icmp eq i32 %m, 0
  br i1 %ok, label %good, label %bad
bad:
  call void @fail()
  unreachable
good:
  %s = extractvalue { <32 x i8>, <32 x i1> } %r, 0
  ret <32 x i8> %s
}
```

`clang -target aarch64-macos -O2 -S` (here `zig cc`, clang 22.1.8) gives:

```asm
_add:
	add.16b	v1, v1, v3
	adrp	x8, lCPI0_0@PAGE
	ldr	q3, [x8, lCPI0_0@PAGEOFF]     ; {1,2,4,...,128, 1,2,4,...,128}
	and.16b	v4, v1, v3                    ; <-- bit weights applied to the SUM
	ext.16b	v5, v4, v4, #8
	zip1.16b	v4, v4, v5
	addv.8h	h4, v4
	fmov	w8, s4
	add.16b	v0, v0, v2
	and.16b	v2, v0, v3                    ; <-- same, low half
	...
	orr	w8, w9, w8
	tst	w8, #0xffff
	b.ne	LBB0_2                        ; -> @fail
	ret
```

The overflow compare (`cmhi` of the sum against an addend) is gone: the
bitmask is built from the sum's own lanes as though they were already
0/-1 booleans, so a nonzero sum "overflows" where its lane's bit is set, and a
real overflow whose wrapped result has that bit clear is missed.
Note also that only 16 bits of the 32-bit mask are tested (`tst w8,
#0xffff` after OR-ing the two halves).

When only the overflow bits are used (drop `%s`, return `%ok`), the
output is correct (`add`, `cmhi`, `orr`, `umaxv`). So the fault appears
when both results of the split `uaddo` are live and the `<32 x i1>`
overflow vector is bitcast to an integer: the vector-to-bitmask lowering
for a type wider than a 128-bit register seems to take result 0 (the sum)
of the legalized node in place of result 1 (the overflow setcc).

## Scope seen from Zig (`a op b` on vectors in ReleaseSafe, aarch64)

Zig lowers checked vector `+`, `-`, `*`, and unary `-` to
`llvm.{u,s}{add,sub,mul}.with.overflow` and a branch on the bitcast
flags. Measured with Rig's lane grid (`test/lanes/lane_grid.py --impl
plain,intrinsic`):

Each of `+`, `-`, `*`, unary `-` (as `@subWithOverflow(0, a)`), and the
explicit `@addWithOverflow`/`@subWithOverflow`/`@mulWithOverflow` plus a
branch on `@reduce(.Or, flags)`, on lane types u8, i8, u16, i32 and lane
counts 16, 32, 64, 128 (aarch64 macOS, ReleaseSafe, 2 seeds; 168 cells):

| lanes | u8 | i8 | u16 | i32 |
|---|---|---|---|---|
| 16 | ok | ok | ok | ok |
| 32 | false overflow: add, sub, mul | false overflow: add, sub, mul, neg | ok | ok |
| 64 | false overflow: add, sub, mul | false overflow: add, sub, mul, neg | ok | ok |
| 128 | ok | ok | ok | ok |

28 bad cells, all on 32 and 64 byte lanes (both `plain` and `intrinsic`).
Debug and ReleaseFast were 0 bad in PR #147's run of the same grid. x86_64 Linux:
0 bad of 588 cells (every lane type, 2 to 64 lanes, all three ways).

As Rig programs (`--release`), the same byte lanes also MISS real
overflows: `x * x` on `@Vector(32, u8)`, `@Vector(64, u8)`,
`@Vector(32, i8)`, `@Vector(64, i8)` with one lane of 255 (127 for i8)
and the rest small returns the wrapped product, no panic.

## Workaround

Compute the wrapped result (`+%`, `-%`, `*%`) and find an overflowing lane
with ordinary lane comparisons (unsigned `r < a`; signed sign tests;
multiply against the product in lanes twice as wide), then
`@reduce(.Or, ...)`. This never asks for the `with.overflow` intrinsics
on vectors.

Files: .git/revamp/r3/simd64/ (f1.zig, uaddo2.ll; z4.zig is the loop form; bug.rig the original Rig program).
