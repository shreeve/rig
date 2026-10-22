# Queued round: `rig build --cpu` (owner-approved 2026-10-15, after inline2)

## Why
`rig build` passes no `-mcpu` to Zig (src/main.zig, around line 526), so every build targets the host CPU. A binary built on pup uses AVX2 and may crash with an illegal instruction on an older x86 machine. Fine for our benchmarks, wrong for anything handed to other people. Also, Zig's `x86_64_v3` lacks `pclmul` (r3/study-prefix-xor.md), so a level name alone isn't the whole story.

## Design (to settle in the round, spellings to the owner)
- `rig build --cpu <name>`: `native` (today's behavior), `baseline` (portable), the x86 levels `x86_64`, `x86_64_v2`, `x86_64_v3`, `x86_64_v4`, Zig's named CPUs (e.g. `haswell`, `apple_m1`), and Zig's `+feature` form if cheap. Rejected with a Rig diagnostic listing valid names when unknown.
- Decide the DEFAULT for `rig build --release` (native, as today, versus baseline). Recommend keeping native for `rig run`/`rig test`, and ask the owner for `rig build`.
- `target.arch` stays as is. Whether to add a compile-time feature query (`target.has(.avx2)`) is a separate question; note it, don't build it.
- `--target` (cross-compiling) is out of scope unless trivial.

## Gates
CLI tests: each level builds and runs on pup (x86) and the Mac; an unknown name is rejected; a `baseline` x86 binary contains no AVX instructions (objdump check). The JSON guard is unchanged at `native`. Docs: SPEC/README's build section and docs/STD.md's std.target. No CORE change.
