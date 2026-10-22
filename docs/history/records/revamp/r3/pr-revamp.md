## Summary

This merges REVAMP-3, the consolidation in HANDOFF's ten-step plan, into `main`. It makes soundness a property of the compiler's structure instead of a result of review rounds. Each fact about ownership is now decided once and recorded. The ownership checker and the emitter read the same recorded facts. A reference checker, independent of the compiler, cross-checks every program in the test sets. Everything that landed follows the ten CORE sentences; an independent final review confirmed this sentence by sentence (see Core conformance).

Along the way, the reviews found memory-safety holes that were live in released Rig. Each was fixed on `main` first, in patch releases v0.1.1 through v0.1.6, and `main` has been merged back into this branch.

## What each step delivered

1. **One set of type facts.** `copyable`, `moves`, `cloneable`, `isUnique`, `lendByValue` and `readByAddress` are each decided in one place in sema, and every pass asks those functions.
2. **One classifier for what an expression hands over, and one for exits.** `handsOver`, `valueParts`, the `Use` fact and `exitTo` mean every path out of a scope reports the loans it discards.
3. **One lend table** (`lendsAs`, CORE §4). Implicit read lends where a signature asks for a view. Header subjects. Payload views of a read `match` are usable within their arm for now; see Breaking changes.
4. **Containers hold anything.** Vec, arrays and slices hold owners and views, and every element is a place: `?v[i]`, `!v[i]`, `<v[i]`, and `v[i] = x` drops the old value once. A write view can be re-pointed (`w = !n`).
5. **The rest of the Core's operations.** `+x` deep-clones Vecs, boxes and structs of owners. Dead failing-tail exits are gone. A `const` declaration form and the Bool long form are added.
6. **Result origins.** By default, which arguments a result may view is decided from the types. `-> T from a | self | static` is checked against the body. std's `strip_prefix`, `strip_suffix` and `cut` declare `from s`, and `os.env` declares `from static`.
7. **Vocabulary.** Diagnostics, identifiers and docs say lend (the act), view (the value) and loan (the record). A lint keeps the old word out. A note teaches that a `String` views text it doesn't own.
8. **SPEC.md follows the Core.** The ownership sections are in Core order, with the kinds and lend tables. It links CORE instead of duplicating its examples.
9. Already landed before this round.
10. **Storage facts** (design B of `step10` in HANDOFF):
    - Every hidden storage location emit creates is a recorded fact, minted at one chokepoint.
    - Emit takes no address of a Zig temporary.
    - The checker walks what a call holds while it runs.
    - Under the sanitizer, hidden stack storage is poisoned when it dies.
    - Headers whose subject makes a statement temporary are rejected until emit points instead of copying (B4).

**The reference checker** ("the oracle", `bin/rig-oracle`, `test/oracle/`) is a second, independent ownership checker. It models defer, handles, closures, generics, Cells, containers, re-pointing, clone and origins. `./test/run` fails if the compiler accepts a program the oracle rejects, and that failure can't be allowlisted. It decides 15,781 corpus functions, 3,297 test functions, 422 doc functions and 15,911 matrix functions.

**Tooling.**
- `test/equiv.py` compares two compilers over every program: parse, normalize, check, facts, sema, storage and emit.
- `rig check --facts=sema` and `--facts=storage` print the recorded facts.
- The form × context × type matrix (`test/matrix.py`) has grown to about 3,000 programs.

## Breaking changes since v0.1.6

Each item lists, in parentheses, how many of v0.1.6's own test and corpus programs it affects (from a survey of them).

1. **`x =! e` is gone.** Write `const x = e` (46 programs).
2. **An error value meets `T!` only as `return`'s operand.** Write `return E.bad` (16).
3. **`std.random.Rng` is renamed `Random`,** and it is `unique` (15).
4. **A write call whose `Bool` result is used** must be written `(!s).insert(k)` (8).
5. **A type holding a `Cell` is `unique`,** so a bare copy needs `<c` (6). `print` now shows a Cell's current value.
6. **Read-`match` payload views are usable within their arm only, for now.** For example, `.a(t) => return ?t` with `match ?e` ran on v0.1.6 and is now rejected. Emit may match a copy of the subject; B4 lifts this.
7. **A `match`, `if … as`, `while … as` or `for` header whose subject makes a statement temporary is rejected.** The hint is "bind the index (the argument) to a name first". v0.1.6 already rejects most of these forms.
8. **An unused `match` payload binding is an error** (5).
9. **Writing through a write view held in a read-`match` payload is rejected** (1).
10. **A `!self` method called on a temporary is rejected** (`mk().bump()`). Every change is marked by `!`, and a temporary can't be lent to write.
11. **Behaviour change (not a rejection):** `w = f(!n)` with no type now holds the write view, so `w = 5` writes `n`, as CORE §6 says. Before, it silently wrote a copy.

**Rejected by v0.1.6, sound and accepted now:**
- containers of owners (`Vec[Text]`, `Vec[Vec[Int]]`);
- element places;
- `+x` of Vecs, boxes and owning structs;
- re-pointing write views;
- `from`;
- branching receivers: `(a if c else b).inner()` keeps both loans, and a Cell change lands in the branch taken.

In all, 185 of v0.1.6's programs go from rejected to accepted.

## Verification

| Check (on the final tree, under `RIG_SANITIZE=1`) | Result |
|---|---|
| `./test/run` | 2,608 passed, 0 failed, 7 pending (CORE's planned rules) |
| `./test/run corpus` (reviewer probes) | 6,021 of 6,021 |
| `test/matrix.py` (form × context × type) | 3,070 programs, 0 failed |
| `zig build test`, fresh cache | 124 passed, 1 skipped |
| `./test/run oracle doc vocab` | 315 passed; the oracle's hard gate never fired |
| Intra-repo links | 392, 0 broken |

**Oracle floors (functions decided):** tests 3,297, corpus 15,781, docs 422, matrix 15,911.

- **Equivalence.** Every step was compared with the previous build by `test/equiv.py`, and every difference was explained by commit. Those logs are kept with the consolidation's ledger.
- **Reviews.** Each step had an independent adversarial review. Under AGENTS' rule that a second soundness round stops a feature, features stopped or were narrowed in four places:
  - escaping payload views (arm-local for now);
  - statement temporaries in headers (rejected until B4);
  - the step 1.5 carve-out;
  - B3's call-held rule, which held after one round.
- **Reviewer probes.** Every reviewer probe is kept in `test/corpus/`.
- **Final review findings.** The final review's medium and low findings that are fixed here: M1, M2, M3, M5, L2 and L3. The rest (M4, M6, M7 and the "is a view" fact) are recorded as weak spots in HANDOFF.

## Core conformance

An independent final review checked every CORE sentence and §1–§10 against this branch, with about 210 adversarial programs under the sanitizer and the oracle. It found no Critical or High finding.

| CORE | Verdict |
|---|---|
| The three words (lend, view, loan) | built |
| §1 Kinds | built |
| 1. A bare name only reads | built; moving as a block's last value is built for names the block declares; `break x` is planned |
| 2. `<x` moves, `+x` makes a new owner, `-x` drops now | built; deep clone of another module's type is planned |
| 3. Drop points | built |
| 4. `?x` / `!x` lend | built |
| 5. One writer or many readers | built |
| 6. A loan lasts until the last use of its views | built |
| 7. A call passes on only the loans its signature shows | built |
| 8. Handles | built |
| 9. Shared storage | built |
| 10. Failure and absence | built |
| §3 Temporaries | built; a `for` over a made Vec of owners is planned |
| §4 Lend table | all ten rows built; copying a plain struct out of a view is planned |
| §5 Containers and fields | built; `copy`/`fill`/`[n of x]` are built for elements that hold no view |
| §6 Order and bindings | built |
| §7 Closures and defer | built; `\|+x\|` of an owner is planned |
| §8–§10 | followed |

The second-to-last commit, "Correct CORE status words and precision (needs design-owner approval)", corrects CORE's *built* and *planned* words, and its precision, where the review found them off. It changes no rule, and adds `rig pending` examples for the rules it marks planned. It can be dropped without affecting anything else. The suite then shows 0 pending instead of 7.

## Open questions for the design owner

None of these blocks a safety fix. They are summarised in HANDOFF ("Open questions"):
- where CORE and the compiler differ in scope;
- two SPEC wordings;
- the rules CORE doesn't yet decide;
- when to lift the conservative limits (payload views, header temporaries);
- the held items (bare `break x`, field-precise re-pointing, std search taking `?T`).

## Nexus mirror

`rig.grammar` and `src/rig.zig` changed in two places:
- the `from` clause and contextual `from`/`static` keywords (step 6);
- `borrow_read`/`borrow_write` renamed to `read_view`/`write_view` (step 7).

`src/diag.zig` is unchanged. The exact diffs go to the Nexus session with the merge commit.
