# The consolidation round: plan (2026-10-22)

The brief for a fresh Rig session, written by the Rig session that
ran the rounds of 2026-10-21 and 22. Start here, then read HANDOFF.md,
AGENTS.md, and ledger.md's newest entry.

## Why

Over two days Rig gained a lot: function values crossing tasks,
compile-time functions, `Table`/`Slot`, `*Frozen`, closure field paths,
Ctrl-C, and errors with data. Trig began checking in tasks too. Each
change was reviewed and gated, but the pace strained the seams.

- The worst bug of the period (D1, fixed in #549) came from two
  classifiers of one fact changed apart.
- Records briefly overstated numbers.
- pup ran out of memory twice under parallel agents.

The owner agreed: one language feature at a time, then a round with
no new features. This is that round. It starts when errors with data
is done (R4, R2.5).

## Rules for the round

- **No new language features.** Fixes, docs, tooling, and measurement
  only.
- **Each change is a small PR:** a failing case first; Rig's full
  suite; Trig's light gate (`tools/light`) for compiler, runtime, and
  std changes. Batch PRs into one gate where they touch apart.
- **At most three agents at a time.** A top model for tracks 1 and 2.
- **pup:** builds through `/zfs/trig-pup/trial/slot.sh` (slot 0,5), with
  at least 12 GB free and at most one other release build. Rig uses no
  timing cores 3 and 4.
- **Mac snapshots under ~/Data:** run tools with
  `GIT_DIR=~/Data/Code/rig/.git` and `RIG_BUILD_STORE` in your own
  folder, since `~/Data` is itself a git repo. Better: fix it in track 4.
- **Records:** every review and measurement goes in
  `docs/history/records/2026-10/consolidation/` with an INDEX.md line.

## Track 1: one classifier per fact (soundness; first)

Sweep the passes for any fact decided in more than one place.
Candidates:

- what crosses to a task or an actor (`crossCheck`,
  `crossingTypeOf`, `sema.atomicHandle`, `blockerIn`, `localBlocker`,
  par.map's capture checks);
- place, made value, lend, or view (`storage`, `hands`, `isTemporary`,
  ownership's walks);
- what copies, moves, or clones (`sema.copies`, `moves`, `cloneable`,
  Pending's `moves` and `copies`);
- what is fallible and with which set (`sema.Fallible`, typecheck's
  `!`/`catch`, emit);
- what a compile-time call is (`ct_call`);
- the zero rule of tables (`tableFill`, `__rig_zeros`).

Also: `src/facts.zig`'s `Pending` still lets emit decide three things
(`assignWritesThrough`, `moves`, `copies`). Make each a recorded fact,
so emit decides nothing (North Star 4).

**Done when** each fact has one function, every caller goes through
it, and each merge has a case that two paths would have split on.

## Track 2: no bug open

Bring HANDOFF's "No case is marked `known: true`: no bug is open" back
to true, and clear what reviews left open:

- #542's bends:
  - `task.all`, `task.isolate`, and `par.map` give any error even where
    the callee declares a set;
  - the hint "lend it to read: `?B.y`" leads to another error;
  - a generic body passing a method's failure on with `!` is rejected,
    with `Int!!` in the message.
- `Table`: `n` is not inferred from a `Slot[n]` argument (review 2, N3).
- `test/cli/match_scale.sh` failed once under a load of about 20; make
  its timing robust (a ratio of fastest runs, or instruction counts).
- The rest of `docs/internals/backlog.md`'s "problems the docs found".
  Among them:
  - a discarded result passes silently;
  - a capture error inside `http.serve` is reported twice;
  - `RIG_LEAK_TRACE=1 rig test` prints no trace;
  - a list of objects is refused with an unhelpful message;
  - a backgrounded server's first `print`;
  - the idle worker that once missed a run-next fiber.

  Fix each, or decide it, and record which.

**Done when** no case is `known: true`, and each backlog item is fixed
or moved to the ROADMAP with a reason.

## Track 3: docs say what is true

- **README** ("Not built yet" still lists declared error sets),
  **WELCOME**, **QUICK**, and **SPEC §19** (reserved forms) for the new
  features: error sets and fields, `*Frozen`, `Table`/`Slot`, closure
  field paths, compile-time functions, Ctrl-C.
- **Learn Rig:** which journeys should teach the new features. Error
  sets and fields belong in the errors journey, `*Frozen` and
  function values in tasks, compile-time functions in 07 (done). See
  `docs/internals/journeys.md`.
- **STD.md:** `Table`/`Slot`, `*Frozen`, and std.json's `JsonError`
  after R4.
- **ROADMAP:** remove what is built, and keep each planned item's
  reason.
- **INTERNALS:** one pass for passes and facts added this period.

**Done when** the doc tests are green, and a reader of README, WELCOME,
and QUICK meets every feature that is built.

## Track 4: tooling from this period's slips

- `tools/heavy` and `test/rig.rip` find Rig's own repository from a
  plain folder (a marker such as `rig.grammar` beside them, or an
  explicit error), never an enclosing repo such as `~/Data/.git`.
- Trig's two tiers (`tools/light`, `tools/full-main`): Rig's AGENTS.md
  and HANDOFF name them as the gates.
- pup's memory rule in the tool: the slot lock waits for free memory,
  not only for a slot.

**Done when** each slip of the period has a tool that prevents it.

## Track 6: speed baseline and census

The owner's rule: nothing late may slow earlier work.

- **The baseline.** Record it once, on the Mac and pup, from a fixed
  reference (main before 2026-10-21, ace79d579):
  - std.json (safe and fast, full corpus);
  - bench tasks, actors, net, and http;
  - `rig check --time` on Trig;
  - Trig's ts-pattern and zod3.
- **The census.** After each batch of merges, and on demand, time main
  against the baseline, interleaved. Bisect anything slower beyond 2%
  before more lands.
- **std.json's hot functions** (`document`, `escaped`,
  `skip_plain_ascii`) get aligned, so a code shift elsewhere cannot move
  them. A 32-byte shift made #565 2.3% slower on twitter and 7% faster
  on citm on pup, with identical code
  (records/2026-10/errors-r4/accepted.md).
- **guard.txt** for json is older than main: refresh it with `--update`
  on main, so the instruction guard measures against today.

The first census row is the 2026-10-22 run: main against ace79d579, on
the Mac. Nothing was slower beyond noise, and std.json was 1–4% faster.

## Track 5 (owner's choice): release v0.3.0

HANDOFF names it as next: "the docs pass, a full run, and the tag with
its migration guide." This round is the docs pass and the full run. If
the owner wants the tag:

- one migration guide from the rename scripts
  (`tools/migrate-*.py`, `tools/rename-interner.py`,
  `tools/migrate-json-error.py`);
- the release notes listing every form a release rejects that 0.2.9
  accepted (CHANGELOG has them);
- Trig's note and scripts first.

## Inventory (taken 2026-10-22, while R2.5 was being built)

- **Tests:** no case is marked `known: true`. Several known issues exist
  but have no case, so the round first writes each as a failing case:
  - #542's three bends (any error from `task.all`, `task.isolate`, and
    `par.map` despite a declared set; the hint "lend it to read:
    `?B.y`"; `Int!!` in a generic's message);
  - Table's `n` not inferred from a `Slot[n]` argument;
  - `match_scale`'s ratio under load.
- **Backlog:** 16 items in docs/internals/backlog.md, to be fixed, or
  moved to the ROADMAP with a reason.
- **Pending examples:** SPEC has 4 `rig pending` blocks and CORE has 3,
  all still pending. Check that each still describes a planned rule.
- **The guides miss this period's features.** README, WELCOME, and QUICK
  name none of `*Frozen`, `Table`/`Slot`, `JsonError`/`load`, Ctrl-C,
  closure field paths, or declared error sets, beyond one line on
  `*Frozen` in QUICK. README's "Not built yet" still lists errors that
  carry data. Learn Rig:
  - 03-errors needs declared sets and fields;
  - 04-concurrency needs function values crossing tasks, `*Frozen`, and
    Ctrl-C;
  - 07-generics covers compile-time functions already.
- **The speed baseline:** the reference is ace79d579 (main before
  2026-10-21). The Mac's std.json row is recorded (1–4% faster on main,
  nothing slower). Still to do: pup's std.json row, the bench
  tasks/actors/net/http rows, and Trig's timing rows.
- **Run beside the round, docs only:** the Stage 3 design refresh of
  docs/design/apis.md, so Stage 3 can start when the round ends.

## Order, and what comes after

1. Track 1, while tracks 3 and 4 run beside it (agents, small PRs).
2. Track 2, once track 1's merges settle.
3. Track 5 last, if wanted.

Expected: about two to three days. Then, per the owner's plan:

- the design refresh of APIs Stage 3 (`docs/design/apis.md`,
  `traits-panel/`, `naming-panel/`), for this period's changes
  (declared error sets on API methods, `*Frozen` beside `*{Shape}`,
  `Table`), then Stage 3;
- Stage 4 together with the I/O layer, its first real use.

Beside all of this, Rig supports Trig's speed and memory:

- the `Table`/`Slot` migration;
- "doing less": Trig allocates about 6.4x what tsrs does, and its
  memory is live data, not List slack.
