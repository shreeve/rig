Adds `std.target` with `target.arch`, the target's processor architecture as a compile-time fact, for std.json's per-target tier:

```rig
use std.target

TIER = 0 if target.arch == .x86_64 else 16
```

## Semantics

- `target.arch` is a value of the built-in enum `Arch`. `Arch` is Zig's `std.Target.Cpu.Arch`, all 61 variants, and lowers to that type. The full list was chosen over a subset with `.other` so that every target has a name, each name means what it means to Zig, no mapping code is needed, and no `.other` changes meaning when the list grows. The variants are read from the Zig that builds the compiler, which is the Zig that builds programs. `Arch` is reserved like `Endian`.
- `std/target.rig` declares `pub arch: Arch` in its `extern zig` block. That is a new grammar form, a Zig-backed constant (`zig_const`), allowed only in the standard library and only of type `Bool`, an integer, or a built-in enum. It emits `pub const arch: rig.Arch = shim.arch;`, and `std/target.zig` gives `builtin.cpu.arch`.
- Sema never knows the value. A Zig-backed constant carries the new `per_target` flag, and so does a module constant or `const` local whose value names one. No fold gives such a constant a value, so `rig check` gives the same verdict on every machine. Both branches of a ternary on it are type-checked, and Zig picks one when it compiles.
- `target.os` is not built.

## Sites that need a constant's value (the class)

| Site | Before | Now |
|---|---|---|
| array length `[N]T`, `[N of x]` | rejected, misleading message | rejected, names the per-target constant |
| `Simd` lane count, compile-time int argument | rejected | same, clear message |
| `lag[k]`, range-pattern bounds, enum value | rejected | same, clear message |
| compile-time `Arch`/`Endian` argument | Zig instantiates | unchanged (correct) |
| proofs, constant index or offset checks | no value, so checked at run time | unchanged (correct) |
| arithmetic in a function | `rig.rt`, checked at run time | unchanged (correct) |
| **module-constant arithmetic** (`100 / TIER`, `HUGE * 2`, `1 << (TIER + 64)`) | **Zig compile error** (already a bug with enum-branching constants) | rejected: every operand must fold |
| **compound shift** `x >>= K` | **Zig compile error** (`@intCast` of a comptime constant) | value read through `rig.rt`, checked at run time |

## Tests

- `behavior/std/target_arch`: TIER, match, `Arch` parameter, compile-time `Arch` argument, per-target `Endian`, const local. The output holds on both CI machines.
- `behavior/std/target_arch_shift_panics`
- `reject/std/target_arch_values`, `reject/std/target_arch_const_arithmetic`, `reject/types/const_arithmetic_unknown`, `reject/types/arch_reserved`, `reject/types/arch_variants`
- `cli/std_target.sh`: compares `target.arch` with `uname -m`, and checks that the emitted Zig keeps `if (….arch == .x86_64) 0 else 16` as a comptime choice. It also runs a `Bool` and a `U16` Zig-backed constant through `RIG_STD`: one used in a branch, one rejected as an array length, and a `String` constant rejected.
- `Int(Arch.x86_64)` and `Int(Endian.big)` now say that a built-in enum has no integer value; before, they said it had variants with payloads.
- SPEC "The target" (a run example and a reject example), and a STD.md example.

## Docs

SPEC (types table, Constants, The target, Zig-backed declarations), docs/STD.md (`std.target`), SYNTAX, INTERNALS, ROADMAP, and RIG-NOTES 12, which is now marked built for arch, with os and CPU features still open.

## Gates

- pup (x86_64), full gates on this branch merged with main at 8ce492b, run with `--delta`: suite 3711 passed with 0 failed, corpus 10061 passed with 0 failed, matrix 11357 programs with 0 failed, unit tests passed, and oracle/doc/vocab 452 passed with 0 failed.
- An earlier full run before the merge had two failures, both fixed or cleared. The test `arch_reserved` was split in two. `cli/inline_grid` timed out under load and passed when rerun alone.
- Mac (aarch64): an earlier full `./test/run` had one failure, the same `arch_reserved` test, since split. On the merged tree, the new tests, `doc/SPEC`, `doc/STD`, `doc/SYNTAX`, style, vocab, and the unit tests all passed.

## Follow-up

Module-level arithmetic over a per-target constant is rejected even where it cannot fail (`K & 1`, `K +% 1`). That is over-strict but sound, and is left as is.

After review: delta suite on pup at f59059f, merged with main at 40e2dbf: 3711 passed, 0 failed.
