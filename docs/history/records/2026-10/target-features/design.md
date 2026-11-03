# Row 32: CPU features in std.target (design, 2026-10-31)

**Approved by the owner, 2026-10-31 ("Approve defaults", in Rig - Rust (fork)):** `target.has(.avx2)` with the built-in enum `Feature`; Zig's x86-64 and arm64 feature names, merged; `Feature` reserved globally, as `Arch` and `Os` are.

Assigned by the owner through Rig - Swiss: "conditional compilation, as
`std.target` CPU features, `target.has(.avx2)` and the like, beside
`target.os`. Values only, branched on like `target.arch`, no new syntax."
Builds on #813 (`target.os: Os`), from the same files.

## What exists

- `target.arch: Arch` and (#813) `target.os: Os`: built-in enums whose
  variants are all of Zig's (`std.Target.Cpu.Arch`, `std.Target.Os.Tag`),
  lowered to Zig's own types. Rig knows their type, never their value, so
  `rig check` gives the same verdict everywhere. Rig keeps both branches of a
  choice, and Zig drops the one the target does not take.
- `rig build` compiles for the native CPU (Zig's default), so a feature test
  answers for the machine it builds on: `avx2` is true on pup. A build for
  another CPU is a later `--target`, which is not part of this row.
- Today's users write around the gap: std.json's `TIER = 0 if target.arch ==
  .x86_64 else 16`, and std/crypto.zig's
  `std.Target.aarch64.featureSetHas(builtin.cpu.features, .dit)` in Zig.
  #814's x86 AEAD path is chosen by arch, though what it means is "one
  multiplier port, AVX2". The short-message rows layout needs `avx2`.

## Design

```rig pending
use std.target

# A constant per CPU: Zig keeps the branch the target's CPU takes.
LANES = 8 if target.has(.avx2) or target.arch == .aarch64 else 4

sub main()
  print(LANES == 8 or LANES == 4)
```

- `target.has(f: Feature) -> Bool`: whether the CPU the program is compiled
  for has feature `f`. It is false when the target's architecture has no
  feature by that name: `target.has(.avx2)` is false on arm64, and
  `target.has(.neon)` is false on x86-64.
- `Feature` is a built-in enum, as `Arch` and `Os` are. Its variants are the
  names of Zig's features for x86-64 and arm64 (`std.Target.x86.Feature`,
  `std.Target.aarch64.Feature`), merged: `.avx2`, `.bmi2`, `.adx`,
  `.sse4_2`, `.avx512f`, `.pclmul`, `.sha`, `.aes`, `.neon`, `.sha2`,
  `.sha3`, `.crc`, `.dotprod`, `.sve`, `.dit`, `.lse`, and the rest: 202 x86 and 277 arm64 names in Zig 0.17, each checked to exist. A name
  both architectures have, such as `.aes`, means each architecture's own
  feature, the same instructions. These are Zig's names, as `Arch` takes
  Zig's, so no table maps them.
- Only x86-64 and arm64 for now, the two machines Rig runs and is measured
  on. A later architecture adds its feature names to the same enum.
- Lowering: `rig.hasFeature(.avx2)`, a comptime function in the runtime that
  tests `builtin.cpu.arch` and `featureSetHas` on that architecture's set
  when it has the name. Zig folds it to a constant. No new IR node: it is a
  call to a std function whose result is a compile-time Bool, checked as a
  choice on `target.arch` is (both branches kept; rejected where Rig needs
  the value while checking, such as an array length).
- Conditional externs: an `extern fun` called only under a branch the
  target does not take is never referenced, so it is never linked. Zig
  analyzes lazily. This is what coreutils' Linux-only calls need (syncfs,
  and fdatasync on macOS). It needs a test, not code.

## Names (for the owner)

| | Default `target.has(.avx2)`, enum `Feature` | `target.cpu.has(.avx2)`, enum `Cpu` | `target.features.avx2` (Bool fields) |
|---|---|---|---|
| Declaration | `pub fun has(f: Feature) -> Bool` | `pub cpu: Cpu` with `has` | `pub features: Features` |
| Error | ``no variant `avx3` on enum `Feature` `` | ``no variant `avx3` on enum `Cpu` `` | ``no field `avx3` on `Features` `` |
| Prose | "`target.has(.avx2)` is whether the CPU the program is compiled for has AVX2." | "`target.cpu.has(.avx2)` ..." | "`target.features.avx2` ..." |
| Note | reads as Swiss quoted it; reserves `Feature` (no program in Rig, Trig, loco or the ports declares one) | `Cpu` reads as the CPU, not a feature | hundreds of fields; no `.name` value to pass around |

Reserving `Feature` rejects a program that declares its own type `Feature`.
None of ours does, but it is a common word, so the release notes list it.
The alternative that reserves nothing is `target.Feature`, a module-qualified
type. But `Arch` and `Os` are global, and one mechanism per idea favours
the same form here.

## Tests, written first

- test/rig/types-misc-1.rig.test, beside `Arch` and `Os`: `Feature`
  reserved; `no variant `avx3` on enum `Feature``; `Int(f)`,
  `Feature.from_int`, `$variants(Feature)` rejected as for `Arch`; and
  `print(target.has(.avx2) or not target.has(.avx2))` printing `true`.
- test/cli/std_target.sh:
  - on pup `target.has(.avx2)` is true and `.neon` false; on the Mac `.neon`
    is true and `.avx2` false (read `uname -m`);
  - emit keeps both branches of a constant;
  - an `extern fun` named only under `if target.os == .linux` builds and runs
    on macOS (the conditional-extern case).
- Cross-target compile: the emitted package of a program using `has`
  compiles with Zig's `-target` for x86_64-linux, aarch64-linux and
  aarch64-macos, as #814's std_crypto_targets.sh does.
- STD.md "std.target": `has` in the table, the `rig pending` example above
  made ordinary, and SPEC §3 "The target".

## First users, after it lands

1. coreutils: `sync -f` / `-d` on Linux and `unlink`'s error kind branch on
   `target.os` (#813 already gives that). Row 25c's `f.sync_fs()` and
   `os.sync()` use it inside std, and the conditional-extern test covers
   syncfs.
2. std.crypto: #814's long-path MAC choice becomes `target.has(.avx2)`
   rather than `target.arch == .x86_64`, if the x86 path is really about the
   CPU's units. That waits for #814 and its own timing. DIT in
   std/crypto.zig stays Zig, as it is not Rig's to test.
3. std.json's TIER, if its choice is really about a feature: left to
   std.json's owner, under its never-slower rule.

## Decisions for the owner (defaults)

1. Form: `target.has(.avx2)` with the built-in enum `Feature`. Default:
   yes.
2. Variants: Zig's feature names for x86-64 and arm64, merged; other
   architectures later. Default: yes.
3. Reserve `Feature` globally, like `Arch` and `Os`, rather than
   `target.Feature`. Default: yes, listed in the release notes.

## Release notes

CHANGELOG's Upgrading section lists `Feature` as a reserved built-in name, as #813 lists `Os`. It carries the one-line Trig note: "Rig makes `Feature` a reserved built-in type (std.target's `target.has(.avx2)`); Trig declares no type named `Feature`, so no migration is needed." Swiss checked that neither Trig nor loco declares one.
