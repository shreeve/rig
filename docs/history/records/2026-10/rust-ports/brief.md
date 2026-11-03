# Rig reference library: four Rust projects ported to Rig (brief for Rig - Rust, 2026-10-29)

## The owner's words
> "I want you to review all of the Rig sigils and forms so that we get the most idiomatic and optimal Rig code we can. I'd like you to "pull out all the stops" and produce beautiful, expressive, Rig code that is PERFORMANT and CLEAN and BEAUTIFUL."
>
> "The assumption is that sigils help us to express Rig code ideally, in a compact and efficient way. If we find that we never use certain sigils or forms, that why support them? If you see how to best use them, that would be great. These FOUR projects could become a sort of reference library for Rig."
>
> On Zig: "Zig should be able to always match Rust performance and if we were having problems with a Rig version, we could compare against the Zig version to see where we could improve." He agreed to port Rust → Rig directly.

## What exists
`~/Data/Code/rig/compare/rust/`, cloned 2026-10-29. `/compare/` is in the checkout's `.git/info/exclude`, so it's untracked.

| Folder | Source | Genre | Rust forms it exercises |
|---|---|---|---|
| `too-many-lists/` | rust-unofficial/too-many-lists (MIT) | data structures | `Option<Box<Node>>`, `Rc`, `Rc<RefCell>`, `Weak` (the deque), `Arc` (persistent list), iterators with lifetimes, `unsafe` |
| `benchmarksgame/` | salsa.debian.org benchmarksgame (BSD-3); programs unpacked in `sources/` (10 benchmarks, several Rust versions each; no Zig) | speed kernels | `Box` churn (binarytrees), SIMD and floats (nbody, mandelbrot, spectralnorm), hash maps (knucleotide), bytes (fasta, revcomp), regex, bigints (pidigits) |
| `ray-tracing/` | fralken/ray-tracing-in-one-weekend (**no license**: write the Rig port from Peter Shirley's book, not from this code) | graphics and numeric | `Box<dyn Hittable>`, `Arc<dyn Material>`, rayon, `Copy` vectors |
| `mini-redis/` | tokio-rs/mini-redis (MIT) | async network server | `Arc<Mutex<State>>`, `tokio::spawn`, broadcast channels, `Bytes`, shutdown |

## Layout
- `compare/rig/{name}` holds the Rig ports, written from the Rust: its design and its ownership choices, never a Zig translation.
- `compare/zig/{name}` is made **only** when a Rig port is slower than Rust and `rig emit` doesn't show why. It then holds a hand-tuned Zig ceiling for that hot part (the Zig-ceiling method); then make Rig emit it.

## Suggested plan
1. **Expert panel first:** 3 experts, top model, at most 400 words each in their reply, full reports saved as files here.
   - **Idiom:** map every Rust construct in the four projects to the best Rig form, from `docs/QUICK.md`, `docs/learn/01-sigils.md`, `docs/CORE.md`, SPEC and SYNTAX.
   - **Speed:** the Rust hot paths, and what Rig emits for them (`rig emit`, proofs, `Simd`, the allocator).
   - **Reader:** what makes the code beautiful, how lines are counted, and how each project's side-by-side write-up looks.

   The result is one **Rig idiom map** plus a port plan for each project. Bring the owner the consensus as numbered decisions with defaults.
2. **Port one project at a time:** too-many-lists, then the Benchmarks Game (the fastest Rust version plus the plainest), then the ray tracer, then mini-redis.
3. **Measure each port** against the Rust:
   - code lines, with no comments or blanks;
   - speed, interleaved, fastest of N: arm64 on the Mac, x86 on pup, never burst; same output;
   - a short write-up with the hardest part side by side.
4. **Keep a sigil ledger:** where each sigil and form was used naturally across the four. Any that found no natural use is evidence for the owner. The 10-28 panel froze `*{A}`, `~{A}`, `once ?fun` and user `api`/`add`; a cut is the owner's decision, through CORE review.

## Rules
- `AGENTS.md` and `HANDOFF.md` in the repo, especially:
  - the vocabulary: lend, view, loan, never "borrow"; "object", never "struct"; `@` is self;
  - say "N% faster", never "+N%";
  - no AI attribution anywhere.
- Ports live in the untracked `compare/`. A compiler or std bug or gap a port finds is its own `wt new` worktree PR, starting from a failing case, through the full gates. One language feature in flight at a time.
- Merges are the owner's. Before `gh pr merge`, send Rig - Swiss and Rig - Merges (fork) the line "merging #N".
- At most 3 agents at a time, with reports of 300 words or less.
- In flight elsewhere: Rig - Merges (fork) is landing the errors-only PR. It rejects look-alike `eq`/`order`/`hash_into`/`print` methods, `?^T` parameters, and `f(+x)` into a read view, and fixes the `Twice.twice(4)` and `async fun` messages. Write ports to that rule set.
- Background records: [feature-cut/verdict.md](../feature-cut/verdict.md) (the keep-or-cut panel) and [rust-style/recommendations.md](../rust-style/recommendations.md) (the Rust style-guide review).
