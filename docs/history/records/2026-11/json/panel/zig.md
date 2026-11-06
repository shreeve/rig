# std.json: instructions that come from Rig's lowering (arm64, Zig 0.17, ReleaseSafe)

Panel member: Zig/LLVM codegen. Instruction counts only (no timing), Mac, every run through `tools/low`.

## Method

- Copied `pc/` to `panel/zig/base` and built it exactly as rig does (`zig build-exe -OReleaseSafe -fomit-frame-pointer -fno-stack-protector`).
- `count.sh PROG` takes `/usr/bin/time -l` "instructions retired" at N=20 and N=0, median of 5 each. It reports (I20 - I0)/20, so the 25 M instructions of startup drop out. Run-to-run noise is about 0.3%.
- Every variant prints the same check (`1700700` for citm, `591460` for twitter), so each parse fills the same tape.
- Each edit is built three times: citm_catalog, a minified citm_catalog (same values, whitespace outside strings removed, 500 KB), and twitter. Per-byte figures for the minified build divide by the full citm size (1,727,204 bytes), so they compare directly with the full one.
- Scripts and variants: `panel/zig/{count.sh,var.sh,build.sh,minify.py,setsrc.py,stats.py,e2.py}`, and the folders `base`, `e1`, `e2`, `e3`, `e3b`, `e4`, `e4a` (each with `.min` and `.tw` twins).

## Where the instructions go (citm_catalog, baseline)

| build | instructions per parse | per citm byte |
|---|---:|---:|
| citm_catalog | 13.87 M | 8.03 |
| citm minified | 8.11 M | 4.70 |
| so whitespace | 5.76 M | 3.33 (42%) |

- citm's tape has 85,035 entries: 10,937 objects and 10,451 arrays (each an open and a close entry), 25,869 keys (8 bytes on average), 14,392 ints (8.8 digits on average), 1,263 nulls, and 735 strings.
- Token work is about **95 instructions per tape entry**. yyjson retires 5.61 per byte for the whole file, whitespace included (9.7 M). So the gap is in per-token work, as the skip-space record concluded. All the edits below are in token work. None touches the whitespace algorithm.
- `Doc.document` is a single 3,686-instruction function. `scalar`, `number`, `key`, `scan_string`, `open`, `close`, and every `skip_space` are inlined into it. Only `skip_plain_ascii`, `utf8_text`, `escaped`, and, at some sites, `ListOf(i64,0).push` are calls.

## Measured overheads, ranked

The edits are cumulative: E1, then E3 on E1, then E4/E4a on E3. Savings are in instructions per byte. Each is measured against the variant it was applied to.

| # | overhead | citm | citm min | twitter | owner |
|---|---|---:|---:|---:|---|
| 1 | Zig overflow and `@intCast` checks in json.zig's arithmetic (E4: all of them) | **0.39** (5.0%) | 0.31 | **0.25** (3.4%) | compiler (ranges) + std.json source |
| 1a | ... of which the tape-entry encodings and `depth` (E4a); the remaining 0.23 / 0.22 are position arithmetic (`i + 8`, `i - first`, `i + 1`) and `@intCast` | 0.16 | 0.14 | 0.03 | std.json source (wrapping ops), or a List-length fact |
| 2 | `List.push`: out of line at some sites, and `len` re-read after the element store (E1) | **0.21** (2.6%) | 0.25 | **0.47** (5.9%) | compiler runtime (`rig/runtime.zig`) |
| 3 | `skip_plain_ascii` as a call, with its constants and range guard redone per string (E3) | **0.16** (2.0%) | 0.09 | **0.13** (1.8%) | std.json source (or the inliner) |
| 3b | ... with only its first 16 bytes inlined and the vector loop kept out of line (E3b) | 0.11 | 0.07 | 0.04 | std.json source |
| - | Tape kept in a local, so ptr/len/cap could live in registers (E2, on E1) | **-0.04 (worse)** | -0.08 | -0.32 | not worth it in this shape |
| 4 | (estimated) the SWAR digit loop rematerializes 11 constants per 8 digits, and a 9-digit int runs `eight_digits` twice | ~0.09 | | | std.json source |
| 5 | (estimated) the `-1` error protocol: `tbz/tbnz i,#63` after every step, and double branches | ~0.05 | | | std.json source (`Int?` or `!`) |

All together, E1 + E3 + E4 take citm from 8.03 to 7.30 per byte (9.1% fewer) and twitter from 8.03 to 7.18 (10.7% fewer). That is about a third of the distance to yyjson's 5.6 on both files.

### 1. Arithmetic checks (E4: `@setRuntimeSafety(false)` in every json.zig function)

These are only the checks Zig adds for `+ - *`, `@intCast`, and `@shlExact`. Rig's own index checks (`rig.at` → `index`, `indexPanic`) live in runtime.zig and stay. The earlier "4-9%" figure measured index and arithmetic checks together, so this edit is a different cut. The checks seen in the disassembly:

- `open`: `len * 2` (`cmn x22,#0x4000…; b.mi`) and `top * 16 + tag` (`add; lsr #60; cmp; b.ls`). That is 6 instructions per open.
- `close`: `len * 16` (4), `start * 16 + tag + 1` (`lsr #59; cbnz`), and `depth - 1` (`subs; b.vs`). About 8 per close.
- `add_int`: `v * 16`. `add_float`: `len(floats) * 16`. In `number`: `int_digits = i - first` (`subs; b.vs`), `digits`, `exp*10`.
- Loop conditions `i + 8 <= len` and `i + 16 <= len` in `take_digits` and `skip_plain_ascii` (`adds; b.vc` each iteration), and `i + k` on return.
- `skip_space(src, i + 1)` in `key`, and `at + len(word)` in `literal`.

What Rig would need:

- **A range fact for positions:** `document` already fails when `n > MAX_INPUT` (2^32). Every position is in `0..n`, so `i + 8`, `i + 16`, `i - first`, and `i + 1` cannot overflow. This is the "`+` under a bound" proof the compiler already makes in loop conditions, extended to `+` and `-` of two values that are each bounded by `n`. It is a proofs.zig change, not a std.json one.
- **The tape encodings** (`x * 16 + tag`) cannot be proven without value-range tracking through stored tape entries (`top` comes back out of the tape). The simple fix belongs to std.json: write the encodings with Rig's wrapping operators. The overflow cannot happen, because the input is capped at 2^32, so the tape holds fewer than 2^33 entries. A cheaper compiler-side half is to give LLVM `len <= max_len` as an assume, which `heldLen` asserts only in debug builds. With max_len = 2^62-1 that proves `len * 2` and nothing more, so it is not enough alone.

### 2. `List.push` (E1, a runtime.zig change)

Before:

```zig
pub fn push(self: *Self, value: T) void {
    if (self.len == self.mem().len) self.growTo(self.len +% 1);
    const m = self.mem();
    m.ptr[self.len] = value;
    self.len +%= 1;
}
```

- `self.len` is read again after `m.ptr[self.len] = value`. The store is an `i64` through a pointer that LLVM cannot separate from the `Doc` (Zig emits no TBAA), so each push runs `str; ldr len; add; str`.
- The function is a plain `fn`. LLVM left it out of line at several of `document`'s hot sites, notably the key path: `bl ListOf(i64,0).push`, a 17-instruction body with a frame, plus about 4 in the caller.
- `mov x27, #0x2020…` and `mov w16, #10` are rematerialized after every push's merge with the `growBy` path.

After:

```zig
pub inline fn push(self: *Self, value: T) void {
    const l = self.len;
    if (l == self.mem().len) self.growTo(l +% 1);
    const m = self.mem();
    m.ptr[l] = value;
    self.len = l +% 1;
}
```

- A push is now 7 instructions (`ldp cap,len; ldr ptr; add; cmp; b.ne; str v; str len`), against 8-9 inline and about 21 out of line before.
- The same edit applies to `String.push`, `pushInt`, and `pushKeep`, and to every List of every program, so it belongs to the runtime. It is the cheapest item here.
- An `inline fn` grows code size at each push site. `growBy` is already out of line and cold, so the inlined part is 6 instructions.

### E2: the tape in registers, a negative result

- `document` copied `self.tape` to a local and passed `*List` to the inline helpers, so SROA could keep ptr, len, and cap in registers. It was written back around `escaped`.
- **It retired more instructions:** 7.88 against E1's 7.84 per byte on citm, and 7.88 against 7.56 on twitter. Stack traffic in `document` went from 20 to 49 `[sp]` accesses.
- `document` already keeps self, src.ptr, n, i, top, depth, the constant 10, the constant 0x2020…, two float bounds (d8, d9), and the inlined number's temporaries live. Three more live values spill.
- So the open item "a List write window" pays only together with lower register pressure:
  - a single write cursor (an end pointer against a cap pointer: 2 registers, not 3);
  - `depth` folded into `top`;
  - `number`'s cold float tail (`decimal_to_float`, `slow_float`, the ±max bounds held in d8/d9) moved out of line.
- What remains after E1 is about 3 instructions per push (≈0.15 per byte on citm). I would not chase it before the items above.

### 3. `skip_plain_ascii` as a call (E3)

Rig emits it as `pub fn` with `@setEvalBranchQuota`, and LLVM does not inline it. Each key and each string pays:

- argument moves and `bl`/`ret`, with an `stp/ldp` frame;
- the guard `(at < 0) or (at > len)`, which the caller's `at = quote + 1` with `quote < n` already proves;
- six `mov/movk` constant builds for `special64`;
- `adds; b.vs` overflow checks on `i + 16`.

Results:

- **Fully inlined:** 0.16 per byte on citm and 0.13 on twitter.
- **Only the two 8-byte SWAR words inlined** (the common case for keys of 8-16 bytes), with the 16-byte vector loop kept out of line as `skip_plain_rest`: 0.11 and 0.04.

The skip-space record found that a call shape can lose time where an inlined one gains, and the reverse. Time E3 against E3b before choosing. In Rig, the fix is a std.json source split: `skip_plain_ascii` as an inline `fun` for the head, and a `called fun` for the vector loop.

### 4. The number path (estimated from the disassembly)

The SWAR digit loop inlined into `document` takes 32 instructions per 8 digits. 11 of them are `mov/movk` constant builds (`0x3030…`, `0x4646…`, `2561`, `6553601`, `42949672960001`, `100000000`), rematerialized every iteration because `document` has no registers left for them.

- citm's ints average 8.8 digits, so most take a full 8-digit pass, then a second pass that finds 1 digit and still runs `eight_digits` on the shifted word. A Zig ceiling runs one 8-digit SWAR step, then finishes the remaining 1-7 digits with a scalar loop or a 4-digit SWAR step.
- Est. 10-20 instructions per int, so 0.08-0.17 per byte on citm. Ints are rare in twitter.
- This is std.json source; there is no compiler fact here. Moving `number` out of line (`called fun`) would give it its own registers, so the constants stay hoisted, but it adds call overhead per number. That trade needs a measurement.

### 5. The `-1` error protocol (estimated)

- After every `scalar`/`key`/`scan_string`, `if (i < 0) return -1` is a `tbnz x22,#63`. LLVM often duplicates it as `tbz …; b …` at each merge into the separator loop.
- About 2 instructions per value, or 0.05 per byte on citm.
- `T?` was measured as neutral (json.md, open item 7), so this is not a lead. Recorded for completeness.

### Ruled out by measurement or inspection

- **Tuple returns** (`take_digits` → `@Tuple(i64, u64)`): fully inlined, both values in registers. There is no memory traffic and the cost is zero.
- **`rig.rt(...)` wrappers:** identity functions, and they vanish. The `fault` error value is written only on failure paths.
- **`self.` reloads after calls:** besides the List fields (item 2), `document` keeps `src`, `n`, and `top` in registers across `skip_plain_ascii` and `utf8_text` calls. The only reloads are of `self.tape`'s fields after stores into the tape, which item 2 removes. `close` re-reads `tape.len` and `tape.ptr` after its `slot(start).*` store for the same aliasing reason. Read the length once in `close` (std.json source), or let E1's single read cover it.
- **i64 positions:** the sign tests (`tbnz x,#63`) are the explicit guards in the Rig source (`at < 0`), or the index check's lower half. Positions held as `u32`/`usize` would remove them, but Rig's `Int` is signed, and the proofs already drop most of them. They are small besides items 1 and 5.

## What Rig would need, by owner

**Compiler and runtime:**

1. `List.push`, `String.push`, `pushInt`, and `pushKeep`: read `len` once and mark the function `inline` (runtime.zig). Measured at 0.21 per byte on citm and 0.47 on twitter.
2. proofs.zig: treat `i ± k` and `i - j` as proven when both values are positions bounded by a length the function has already tested against a cap (`n <= MAX_INPUT`). The rest of item 1: 0.23 per byte on citm, 0.22 on twitter.
3. Optionally, emit `heldLen`'s invariant as an LLVM assume (`if (n > max_len) unreachable`) in release builds. This is cheap, but it only proves `len * 2`-sized products.

**std.json source:**

1. Write the tape encodings and `depth` with wrapping operators (E4a: 0.16 per byte on citm, 0.03 on twitter), noting the 2^32 input cap as the reason.
2. Split `skip_plain_ascii` into an inline head and a called vector loop (0.11 / 0.04). Inline it whole for 0.16 / 0.13, if timing allows.
3. Finish the last 1-7 digits of `take_digits` with a scalar loop rather than a second `eight_digits` (est. 0.1 on citm).
4. Lower `document`'s register pressure (fold `depth` into `top`, move the float tail out of line) before trying the tape write window again.
