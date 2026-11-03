# Committee brief: Google's Rust style guide, applied to Rig

The owner asked: how do the guidelines in Google's Rust style guide (`rustguide.md` beside this file, from https://google.github.io/styleguide/rustguide.html) apply to Rig? A committee reviews them in detail and makes **recommendations only**. **Change no file in any repository.** Write only your report, in this directory.

## Rig in brief
Rig is an indentation-sensitive systems language that compiles to Zig. It aims for the readability of Python and Ruby, the cost model of Zig and C, and the memory safety of Rust: no GC, no hidden allocation, copy or reference count, and ownership shown by one-character sigils. Repo: `~/Data/Code/rig` (read `origin/main`; `git -C ~/Data/Code/rig show origin/main:PATH`).

Read before you start:
- `AGENTS.md`: the North Star, "One vocabulary", "Taste", and "Naming" (the owner's taste in names).
- `docs/QUICK.md`: the sigils on one page.
- `docs/design/mantras.md`.

Then whatever your sections need:
- `SPEC.md`, `SYNTAX.md`, `docs/CORE.md` (ownership);
- `docs/design/apis.md` (`api Shape`, Rig's traits);
- `docs/STD.md`, `docs/learn/*.md`;
- `docs/internals/INTERNALS.md`, `docs/internals/tests.md`.

Rig's own words: you *lend a view*, and the owner keeps a *loan*; never write "borrow". An `obj` is an "object", never a "struct". `@` is "self". Write "N% faster/slower", never bare signed percentages.

To test a claim, run Rig. `GIT_DIR=$(git -C ~/Data/Code/rig rev-parse --git-common-dir) ~/Data/Code/rig/tools/baseline origin/main` prints the path of a `rig` built at main. Run probes in your own scratch directory with `RIG_OUT_DIR` set to it (`rig run f.rig`, `rig check f.rig`). Verify before claiming what Rig does or doesn't do.

## For each guideline in your sections
Give one of:
- **Applies as is.**
- **Applies in Rig's form**, with the Rig spelling.
- **Dissolved by Rig's design**, and why, e.g. Rig has one text view, `?String`, so `&str` versus `&String` can't arise.
- **Not applicable**, with the reason, e.g. Chrome or Fuchsia only.

For each that applies, recommend one or more:
- **(L)** the language or compiler enforces it: a rejection;
- **(W)** a warning or lint;
- **(S)** a style rule in a Rig style guide;
- **(D)** a std or docs convention.

Rank by value: how often Rig code meets it, and what it prevents. Note where Rig already does it, and point to the doc or test. Flag where the Rust advice would be wrong for Rig, or where Rig should do better than Rust: "dissolve a problem rather than patch it" (AGENTS, Taste).

## Report
Write `member-<letter>.md` in this directory:
- a table, one row per guideline: guideline | verdict | Rig form | recommendation (L/W/S/D) | priority (high/medium/low);
- then up to 600 words on the top recommendations and any disagreement with the guide;
- the probes you ran, with results.

Reply in ≤150 words: your top 5 recommendations.
