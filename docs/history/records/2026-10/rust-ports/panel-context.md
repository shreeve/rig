# Panel context: the Rig reference library (2026-10-29)

The owner wants four Rust projects ported to Rig as a reference library:
idiomatic, fast, beautiful Rig that uses the sigils fully. His words:

> "review all of the Rig sigils and forms so that we get the most idiomatic and optimal Rig code we can. ... produce beautiful, expressive, Rig code that is PERFORMANT and CLEAN and BEAUTIFUL."
>
> "If we find that we never use certain sigils or forms, that why support them? ... These FOUR projects could become a sort of reference library for Rig."

The full brief: [brief.md](brief.md).

## Where things are
- Rig checkout (current `main`, read-only for you): `/Users/shreeve/Data/Claude/Worktrees/rig/rig-production-agent-6dff9f`.
  Its `bin/rig` is freshly built from main. Run it as `RIG=/Users/shreeve/Data/Claude/Worktrees/rig/rig-production-agent-6dff9f/bin/rig`.
- The docs, in that checkout: `docs/QUICK.md` (one page), `docs/learn/01-sigils.md` to `11-performance.md`,
  `docs/CORE.md` (ownership), `SPEC.md`, `SYNTAX.md`, `docs/STD.md`, `docs/design/mantras.md`,
  `docs/design/iterators.md`, `docs/design/concurrency.md`, `examples/`, `bench/`.
- The Rust sources: `~/Data/Code/rig/compare/rust/`
  - `too-many-lists/lists/src/*.rs` (first..fifth, silly1/2; the book in `src/*.md`)
  - `benchmarksgame/sources/{binarytrees,fannkuchredux,fasta,knucleotide,mandelbrot,nbody,pidigits,regexredux,revcomp,spectralnorm}/*.rust` (several Rust versions each, plus expected output `*_out`)
  - `ray-tracing/src/` (NO LICENSE: study its shape only; the port is written from Peter Shirley's book, never from this code; quote none of it)
  - `mini-redis/src/` (tokio server)
- Ports will go to `~/Data/Code/rig/compare/rig/{name}`.
- Scratch probes: write `.rig` files only under your own temp dir
  (`mktemp -d`), and run with `RIG_OUT_DIR=$tmp`. Never edit the checkout.

## Rules
- Vocabulary: lend, view, loan; never "borrow". A Rig `obj` is an "object", never a "struct". `@` is "self".
- Say "N% faster", never "+N%".
- In flight (write to these rules): the errors-only PR rejects `?^T` parameters, `f(+x)` into a read view,
  and look-alike `eq`/`order`/`hash_into`/`print` methods on a type whose header does not name the API.
  Float is losing `Ord` (owner approved).
- Frozen (no new stages): `*{A}`, `~{A}`, `once ?fun`, user `api`/`add`.
- Verify by probing: run `$RIG check`, `$RIG run`, `$RIG emit` on small files. A claim about what Rig accepts
  or emits is backed by a probe, or marked unverified.
- If the Mac is busy, run heavy things through `tools/heavy CMD` from the checkout. Probes are light; no need.
- Your reply to me is at most 400 words. Your full report goes to the file named in your task.
