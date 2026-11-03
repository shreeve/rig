# Language design review of the concurrency surface

Probes are in the panel's `language/` scratch folder, run with `bin/rig` at 0b9fc6b.

## Findings

1. **Implicit local tasks are a silent 5.6x cliff.** Eight CPU tasks in a `Tasks[Int]`, each passed `c.k`, took 0.95 s real on 10 cores. Passed `?c` (a `?*Cfg`), they took 5.33 s real, on one core (`cliff_*.rig`, `--release=fast`). Nothing said so: Rig has no warning severity (`src/diag.zig`) and the LSP has no hover. A mark would tax the GUI case the feature exists for. A report is better.

2. **One task cannot get a deadline.** `time.within(d, |<t| >t!)` is rejected: "cannot move captured `t`: the closure keeps what it captures for every call". A second error then contradicts it: "wait for it, `>t!`" (`q1`; the same for a set, `p3`). Sets dodge this with `within:`, so deadlines have two spellings. `wait_all` now exists only to carry `within:`.

3. **Messages that mislead.**
   - `>j.t` and `>xs[0]` on values that are not tasks: "`>j` waits for a task ... write `(>j).t`" (`q4`, `p2`). It should say: bind it, `t = <j.t`, then `>t`.
   - `ch.recv()`: "changing a shared Cell is marked with `!`" (`p7`). This is a channel, not a Cell.
   - `on_recv` outside `select`: "no method `on_recv` on type `Chan`" (`p4`).
   - `ts.wait_first()`: "consumes the receiver" (`p8`). About 45 message strings in `src` say "receiver" instead of "self".
   - Waiting twice says only "use of `t` after move".

4. **`<t.wait()` no longer appears in anything that teaches the language.** SPEC, WELCOME, SYNTAX, STD, CONCURRENCY.md, the examples and the benchmarks are clean. It remains in 1 negative test (on purpose), the comment at `rig.grammar:460`, and 17 places in the historical `docs/concurrency/[1-4]-*.md`, which read as current.

5. **Redundant:** `task.both(a, b)` is `task.all(a, b)`.

6. **Sound.** Sigils are the mechanics (`&`, `>`); `<t.cancel()` and `<ts.wait_first()` are words with the move sigil. The spacing errors for `>` are exemplary.

## Decisions for the owner

1. Keep local tasks implicit, and add `rig check --tasks` to list each local task and what pins it. Default: yes.
2. Have `time.within` call its closure exactly once, so the closure may move captures. Then drop `within:` and `wait_all`. Default: yes.
3. Fix the messages in finding 3, saying "self" everywhere. Default: yes.
4. Mark the historical reports as superseded with a banner. Default: yes.
5. Drop `task.both` and keep `task.all`. Default: yes.
