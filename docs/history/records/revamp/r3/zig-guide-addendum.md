<!--
Addendum for ZIG-0.17.md (gist 57a74df35e17dacb30dcaa5d5164a27f), ready to paste.
Every repro below was compiled and run on Zig 0.17.0 (LLVM 22.1.8), aarch64-macos (Apple M-series),
2026-10-12, with the output quoted. Sources are in
/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad/zg/
(a1_ovf, a2_inline, a2_result, a3_const, a3b_field, a3b_payload, a4_quota*, a5_reduce, a6_any, a7b_load,
a8b_x86, a9_bool*), outputs in ../zgout, ../zgout2, ../zgout4.

Where it goes:
  - the four "traps that compile" -> new §4.3 (after §4.2), and add one line to §23.5 item 10 and §23.7 item 5
  - the five compiler/LLVM bugs   -> §24 "Bugs and regressions to work around"
  - the extras at the end         -> §24 (smp_allocator, handleSegfault), §2.4/§16.1 deprecated list, §19.2, §20.4
-->

### 4.3 Folding and wrapping traps for code that generates Zig (silent or surprising)

These come from a compiler that emits Zig and promises run-time panics where Zig folds at compile time.
They apply to hand-written code that relies on a run-time check being a run-time check.

1. **`inline fn` is analyzed at every call with its arguments comptime-known, and its result is comptime-known
   to the caller.** A literal argument makes the body's arithmetic a compile-time computation, so a
   call that never executes can still fail to compile, and a returned constant folds into the caller's
   expressions. `@call(.always_inline, f, args)` behaves the same.

   ```zig
   // a2_inline.zig
   inline fn inc(x: u8) u8 {
       return x + 1;
   }
   pub fn main() void {
       var never = false;
       _ = &never;
       if (never) _ = inc(255); // never executed, still a compile error
   }
   ```
   ```
   a2_inline.zig:3:14: error: overflow of integer type 'u8' with value '256'
       return x + 1;
   a2_inline.zig:8:23: note: called inline here
   ```
   ```zig
   // a2_result.zig
   inline fn limit() u8 {
       return 255;
   }
   pub fn main() void {
       var never = false;
       _ = &never;
       if (never) _ = limit() + 1; // the result of an inline call is a constant
   }
   ```
   ```
   a2_result.zig:8:28: error: overflow of integer type 'u8' with value '256'
   ```
   Workaround: pass the value through a non-inline identity, at the top of the body and around the call.
   Verified: both calls below compile and run.

   ```zig
   fn rt(v: anytype) @TypeOf(v) { return v; }          // not inline: a call, so the result is a run-time value
   inline fn inc(x0: u8) u8 { const x = rt(x0); return x + 1; }
   // ... if (never) _ = inc(255);  if (never) _ = rt(limit()) + 1;      -> prints ok
   ```
   The same fold turns a benchmark over constant input into 0 ns (§23.7 item 5).

2. **A part of a comptime-known aggregate is comptime-known.** An element of a `const` array, a field of a
   `const` struct, a payload or tag of a `const` union, and a `switch` subject built from constants all
   fold, so arithmetic on them is checked by the compiler, not at run time, even in a branch that never runs.

   ```zig
   // a3_const.zig                                   // a3b_field.zig                 // a3b_payload.zig
   const table = [_]u8{ 255, 1 };                    const p: P = .{ .n = 255 };      const u: U = .{ .a = 255 };
   if (never) { const x = table[0] + 1; _ = x; }     ... p.n + 1                      ... switch (u) { .a => |v| _ = v + 1, ... }
   ```
   ```
   a3_const.zig:6:28: error: overflow of integer type 'u8' with value '256'
   a3b_field.zig:7:23: error: overflow of integer type 'u8' with value '256'
   a3b_payload.zig:8:29: error: overflow of integer type 'u8' with value '256'
   ```
   Workaround: read the part through the same `rt` identity (`rt(table[0]) + 1`). Verified.

3. **Each inlined call is charged to the calling function's 1000-backwards-branch quota.** A function with
   more than 1000 calls of an `inline fn` fails to compile, though no comptime code is written:

   ```zig
   inline fn bump(x: u32) u32 { return x +% 1; }
   pub fn main() void {
       var a: u32 = 0;
       _ = &a;
       a = bump(a);   // repeated 1001 times (a4_q1001.zig); 999 times compiles (a4_q999.zig)
       @import("std").debug.print("{d}\n", .{a});
   }
   ```
   ```
   a4_q1001.zig:1005:13: error: evaluation exceeded 1000 backwards branches
       a = bump(a);
   a4_q1001.zig:1005:13: note: use @setEvalBranchQuota() to raise the branch limit from 1000
   ```
   Workarounds, verified: `@setEvalBranchQuota(100_000);` as the first statement of the function (1100 calls
   then compile and print `1100`), or cap the inlined calls per function and call the helper out of line.

4. **`@reduce(.Add)` and `@reduce(.Mul)` wrap in every optimize mode.** Lane arithmetic with `+`, `-`, `*` is
   checked; the reductions are not.

   ```zig
   var v: @Vector(4, u8) = .{ 200, 100, 0, 0 };  _ = &v;
   @reduce(.Add, v)                               // 44, no panic (Debug and ReleaseSafe)
   @reduce(.Add, @as(@Vector(4, u16), v))         // 300
   var m: @Vector(2, u8) = .{ 16, 16 };  _ = &m;
   @reduce(.Mul, m)                               // 0
   ```
   Workaround: widen the lanes first (`@as(@Vector(4, u16), v)`) and range-check the result, or reduce with
   `+` pairwise by hand where an overflow must panic.

(Add to §23.5 item 10: *"Zig folds parts of constants and every `inline fn` call; launder run-time checks through a
non-inline identity (§4.3.1–2)"*.)

### 24 additions (Bugs and regressions to work around)

- **aarch64, ReleaseSafe and ReleaseFast: `@addWithOverflow` on 32- and 64-lane byte vectors reports an overflow
  that is not there** when both the result and the flags are used (LLVM's AArch64 lowering of
  `llvm.{u,s}{add,sub,mul}.with.overflow` on split `<32 x i8>`/`<64 x i8>`). Plain checked `+`, `-`, `*` and
  unary `-` on those vectors use the same intrinsics, so a correct program panics with "integer overflow";
  Rig's grid of 168 cells per mode also found `i8` `*` at 32 lanes missing a real overflow (a one-lane
  input, 127 * 127, panicked correctly here). Debug, x86_64 and 16 lanes are fine.

  ```zig
  // a1_ovf.zig
  const std = @import("std");
  noinline fn load(comptime n: usize, b: []const u8) @Vector(n, u8) { return b[0..n].*; }
  noinline fn viaOv(comptime n: usize, a: @Vector(n, u8)) @Vector(n, u8) {
      const r = @addWithOverflow(a, a);
      if (@reduce(.Or, r[1] != @as(@Vector(n, u1), @splat(0)))) @panic("false overflow");
      return r[0];
  }
  pub fn main() void {
      var buf: [64]u8 = undefined;
      for (&buf, 0..) |*b, i| b.* = @intCast(i % 50); // every sum <= 98
      _ = viaOv(16, load(16, &buf));  std.debug.print("16 lanes ok\n", .{});
      _ = viaOv(32, load(32, &buf));  std.debug.print("32 lanes ok\n", .{});
  }
  ```
  ```
  zig run -O Debug        -> 16 lanes ok / 32 lanes ok
  zig run -O ReleaseSafe  -> 16 lanes ok / thread panic: false overflow
  zig run -O ReleaseFast  -> 16 lanes ok / thread panic: false overflow
  ```
  Workaround, verified in ReleaseSafe and ReleaseFast (32 and 64 lanes pass; a real `200 + 200` still panics):
  wrap, then compare: `const r = a +% b; if (@reduce(.Or, r < a)) @panic("overflow");` (unsigned; signed: compare
  the signs). For `*` widen the lanes (`u8` -> `u16`).

- **LLVM turns `@reduce(.Max, @select(...))` into a mask bitcast, which is slow on NEON inside a loop.** An any-lane-matches scan spelled as a reduction over a 0xFF/0x00 byte mask compiles, on aarch64
  ReleaseFast, to the full bitmask extraction (`cmeq`, `and` with lane weights, `ext`, `zip1`, `addv`, `fmov`
  per 16 bytes), not to `umaxv`. Per 32-byte block: 13 instructions against 5 when the pieces are OR-ed and
  `umaxv` is named directly.

  ```zig
  // a6_any.zig (aarch64-macos, -O ReleaseFast, zig build-obj -femit-asm)
  export fn anyq_reduce(p: [*]const u8, n: usize) bool {
      var i: usize = 0;
      while (i + 32 <= n) : (i += 32) {
          const v: @Vector(32, u8) = p[i..][0..32].*;
          const m = v == @as(@Vector(32, u8), @splat('"'));
          const s = @select(u8, m, @as(@Vector(32, u8), @splat(0xFF)), @as(@Vector(32, u8), @splat(0)));
          if (@reduce(.Max, s) != 0) return true;
      }
      return false;
  }
  ```
  ```
  loop body, anyq_reduce:  ldp q,q | cmeq and ext zip1 addv fmov | cmeq and ext zip1 addv fmov | orr | tst | b.eq
  loop body, anyq_umaxv:   ldp q,q | cmeq cmeq | orr | umaxv fmov | cbz
  ```
  Workaround: OR the 16-byte pieces and call the intrinsic, guarded so that no other target sees it:
  `extern fn @"llvm.aarch64.neon.umaxv.i32.v16i8"(@Vector(16, u8)) i32;` used only when
  `builtin.target.cpu.arch == .aarch64 and builtin.zig_backend == .stage2_llvm` and the `neon` feature is set
  (an `llvm.*` extern fails to link on the self-hosted x86_64 Debug backend; an intrinsic for a missing
  feature is an LLVM crash, not a Zig error).

- **aarch64: a `[n]u8` -> `@Vector(n, u8)` `@bitCast` of 4 or 8 bytes is lowered lane by lane.** Coercing the array
  (`const v: @Vector(4, u8) = p.*;`) or loading one integer and bitcasting it is a single load.

  ```zig
  // a7b_load.zig (aarch64-macos, -O ReleaseFast); each function sums the lanes as u32
  export fn s4_coerce(p: *const [4]u8) u32 { const v: @Vector(4, u8) = p.*; return @reduce(.Add, @as(@Vector(4, u32), v)); }
  export fn s4_bitcast_array(p: *const [4]u8) u32 { const raw: [4]u8 = p.*; const v: @Vector(4, u8) = @bitCast(raw); return @reduce(.Add, @as(@Vector(4, u32), v)); }
  export fn s8_bitcast_array(p: *const [8]u8) u32 { const raw: [8]u8 = p.*; const v: @Vector(8, u8) = @bitCast(raw); return @reduce(.Add, @as(@Vector(8, u32), v)); }
  export fn s8_int(p: *align(1) const u64) u32 { const v: @Vector(8, u8) = @bitCast(p.*); return @reduce(.Add, @as(@Vector(8, u32), v)); }
  ```
  ```
  s4_coerce:         ldr s0 | ushll.8h | uaddlv.4h | fmov                                   (4 instructions)
  s4_bitcast_array:  ld1r.4s | adrp | ldr q | ushl.4s | movi | and.16b | addv.4s | fmov      (8)
  s8_bitcast_array:  ld1r.2d | 4 x (adrp, ldr q, ushl.2d) | 2 x uzp1 | movi | 2 x and | add | addv | fmov   (21)
  s8_int:            ldr d0 | movi | movi | udot | addp | fmov                               (6)
  ```
  Same family as §5.3 ("array `@bitCast` is lowered element by element"), here for the vector direction.

- **x86_64 self-hosted backend (the Debug default there): a load through a pointer to a small vector reads the
  whole register.** `*align(1) const @Vector(4, u8)` loads 16 bytes, so reading the last four bytes of a page
  touches the next page. The array route reads exactly 4.

  ```zig
  // a8b_x86.zig: zig build-exe -O Debug -target x86_64-macos -fno-llvm a8b_x86.zig && objdump -d --no-show-raw-insn a8b
  noinline fn load4_vec(p: *align(1) const @Vector(4, u8)) u32 { const v = p.*; return @reduce(.Add, @as(@Vector(4, u32), v)); }
  noinline fn load4_arr(p: *const [4]u8) u32 { const raw: [4]u8 = p.*; const v: @Vector(4, u8) = @bitCast(raw); return @reduce(.Add, @as(@Vector(4, u32), v)); }
  ```
  ```
  load4_arr:  movl   (%rax), %edx          ; 4 bytes
  load4_vec:  movdqu (%rax), %xmm0         ; 16 bytes
  ```
  Workaround: load the bytes as an array or one integer, then `@bitCast`; use a vector pointer only for 16 bytes
  or more (a whole register). (Verified by disassembly; not run on x86 here.)

- **aarch64 without NEON, Debug: `@bitCast(@Vector(n, bool))` to an integer gives wrong bits.** The bit of the first set lane
  survives and the bits of later lanes are lost. The CPU has NEON; the compiler is told not to use it, so the program runs natively on an M-series Mac.

  ```zig
  // a9_bool32.zig (also 16 and 64): zig run -O Debug -target aarch64-macos -mcpu=apple_m1-neon a9_bool32.zig
  noinline fn bits(v: @Vector(32, u8), s: u8) u32 { return @bitCast(v == @as(@Vector(32, u8), @splat(s))); }
  // lanes 3 and 30 equal 's'
  ```
  ```
  default CPU,   Debug / ReleaseSafe / ReleaseFast:  got 0x40000008  want 0x40000008
  -mcpu=apple_m1-neon, ReleaseSafe / ReleaseFast:    got 0x40000008  want 0x40000008
  -mcpu=apple_m1-neon, Debug:  n=16 got 0x8 want 0x4008 | n=32 got 0x8 want 0x40000008 | n=64 got 0x8 want 0x4000000000000008
  ```
  Workaround, verified: build the integer lane by lane, `inline for (0..32) |i| r |= @as(u32, @intFromBool(m[i])) << i;`,
  or turn the mask into bytes with `@select` and gather them (a multiply by `0x0102040810204080`).

### Found while verifying (not part of the nine; paste where noted)

- **§24: `std.heap.smp_allocator` is a compile error when single-threaded.** `SmpAllocator.zig` has
  `comptime { assert(!builtin.single_threaded); }`, so any reference fails on `wasm32-wasi` (single-threaded by default)
  and under `-fsingle-threaded`. Select by `builtin.single_threaded` (`std.heap.wasm_allocator` on wasm,
  `std.heap.brk_allocator` for single-threaded Linux/wasm, else `smp_allocator`). Verified: a language runtime that
  names `smp_allocator` fails on `wasm32-wasi`; with the name swapped to `wasm_allocator` two programs build and run
  correctly under wasmtime in Debug and ReleaseSafe.
  ```
  b6_smp.zig:  pub fn main() void { const p = std.heap.smp_allocator.create(u32) catch return; std.heap.smp_allocator.destroy(p); }
  zig build-exe -fno-emit-bin -fsingle-threaded b6_smp.zig
  SmpAllocator.zig:115:11: note: called at comptime here
      assert(!builtin.single_threaded); // you're holding it wrong
  ```

- **§19.2: a crash handler for buffered output.** `pub const panic = std.debug.FullPanic(f)` covers panics only.
  A SIGSEGV/SIGBUS/SIGILL/SIGFPE (a stack overflow, say) goes to `std.debug.defaultHandleSegfault`, which does not
  call your panic handler, so output you buffer is lost. The root module can override it:
  ```zig
  pub const debug = struct {
      pub fn handleSegfault(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
          flushMyOutput();
          std.debug.defaultHandleSegfault(addr, name, ctx);
      }
  };
  ```
  Verified: a program that prints a line, then overflows its stack, with stdout a pipe, prints nothing without the
  hook and the line with it. The segfault handler is installed only when `std.options.enable_segfault_handler` is
  true, which defaults to `runtime_safety and have_segfault_handling_support`: not in ReleaseFast/ReleaseSmall.

- **§2.4 / §16.1 / §23.2: more deprecated spellings.** `std.mem.copyForwards` and `std.mem.copyBackwards` ("This
  function is deprecated; use @memmove instead", `mem.zig`), and `std.mem.lastIndexOfScalar` (alias of
  `findScalarLast`). They compile silently. On 1 GB of `u64` moved per round, `copyBackwards`/`copyForwards` and
  `@memmove` are within noise in ReleaseFast and ReleaseSafe (17-38 ms either way over three rounds on a
  loaded machine); the cost is only the deprecation. Add to the §23.2 sweep: `copyForwards|copyBackwards`.

- **§24: x86_64 self-hosted backend, `export fn` returning a vector.** `export fn load4(p: *align(1) const
  @Vector(4, u8)) @Vector(4, u8) { return p.*; }` with `-O Debug -fno-llvm -target x86_64-macos` fails with
  `error(x86_64_encoder): no encoding found for: none movq eax xmm0 none none` / `emit MIR failed: InvalidInstruction
  (Zig compiler bug)`. The same function without `export` compiles.

- **§20.4: a relative `-D` path resolved against the working directory is cached by its text.** The configuration
  is keyed by the option string, so `b.pathResolve(&.{ cwd, option })` is frozen at the first run's cwd:
  ```
  (cd a) zig build -Dtool=tool show   ->  configured with .../cc/a/tool
  (cd b) zig build -Dtool=tool show   ->  configured with .../cc/a/tool      (cache hit; wanted .../cc/b/tool)
  ```
  Resolve against `b.root`, require an absolute path, or call `b.graph.poisonCache()` when the option is relative.

- **§5.7 / §4.2 (pointers to rvalues): Zig 0.17.0 emits no `llvm.lifetime` markers.** `use(&S{ .a = x, .b = y })`
  twice in one function, `-O ReleaseFast -femit-llvm-ir`: 0 occurrences of `llvm.lifetime`. A temporary
  whose address is taken therefore keeps its stack slot to the end of the function today; the guide can state
  that this is an implementation fact, not a language guarantee.
