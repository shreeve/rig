Errors that carry data, round 1 (R1, `errtype`, from `.git/revamp/r3/proposal-errors.md`, approved 2026-10-12): `error`, an error of any set, becomes a type, and it is owning.

## What round 1 does

- **`error` is a type.** It goes wherever a type goes: a parameter, a field, a result, `error?`, `[2]error`, `List[error]`, and a type argument in an expression (`List[error]()`, `@name(error)`). The grammar's `tatom` and `atom` take the keyword, and Nexus reports no new conflict. The lexer counts `error` as the end of an operand, so `error?` is its optional. A member of any set meets `error`. `error!` is rejected, as `E!` is, and `x = error` says "`error` is a type, not a value".
- **`error` is owning in every program.** One new type fact, `TypeInfo.any_error` (with `Contents`/`Holds.any_error`, reaching as `vector` does), is a positive input to `sema.moves` and `sema.readByAddress`, read through `sema.holdsAnyError`. `+e` clones it. It has no drop glue, since no set has fields yet. A `catch |e|` capture's storage is recorded `owned`; the emitted Zig is the same. The oracle (`test/oracle/kinds.zig`) reads the same kind, and the matrix gains an `error` row (96 new oracle rejections listed).
- **Three fixes the owning kind exposed**, each with a test. A `match <e` arm naming one member emitted `const __rig_whole = ;`. An unused parameter of an error type emitted `_ = e`, which Zig rejects; it is discarded by address now (this was broken on main for error sets too). And a branching error as an `==` operand reached emit with no recorded use.
- **Docs.** CORE §1 lists `error` as owning; CORE §2 has the "A failure moves its error" paragraph, a `rig reject` example and P1 as `rig pending`. SPEC §13 gains "Any error" and the planned "Declared sets and fields" (`rig pending`). INTERNALS, SYNTAX, README, IDEAS, HANDOFF are updated.
- **Effect on existing programs:** one corpus probe that copies an error (`review-errors-b3`) is now rejected and listed. Three corpus probes, rejected only by the unread-binding lint on `catch |e|`, are now accepted and run clean, since that lint exempts a value that moves.

## Merging main (230 commits)

Three conflicts:

- `src/typecheck.zig`, the `==` operand reads (two sites). This branch read operands with `moves == .yes`. Main independently made the same change more broadly (`moves != .no`, covering a type parameter's value too). I took main's side. Since `moves` answers `.yes` for an `error`, the branch's fix is kept.
- `test/oracle/rejections`: main's closure entries and this branch's `error.*` entries are both kept.
- `HANDOFF.md`, "Later": this branch's errors item is kept, with main's "Constant tables" and its updated SIMD item (dropping the branch's stale "SIMD round 2" wording).

I checked the auto-merged files for drift. `TypeInfo`, `holdsIn`, `moves`, `readByAddress` and `copies` merged intact. Main added no new site that classifies by drop glue or uniqueness (closures, check speed, nameorder, testscope, lane checks). The catch storage in `emit.zig` and `storage.zig`, the unused-parameter discard and the member-pattern arm all survived. The matrix's `fallible` guard still covers every `catch` context. A second merge took #180 (docs only).

## Gates

- **Fast (Mac, `cpuq --cores 2`):** build clean; `./test/run --delta`: 3685 passed, 0 failed, 14 pending.
- **Full (pup, `PUP_CORES=8 GATES_DELTA=1 pup-gates.sh`, 629603012):**
  - suite: 3684 passed, 1 failed, 14 pending. The failure is `cli/inline_grid`, which timed out at 900s under `INLINE_GRID_FULL=1` while the other gates loaded the machine (several earlier branches' full gates show the same timeout). Rerun alone in full mode (Mac, `cpuq --cores 2`, a6c9edaad): passed in 252s.
  - corpus: 10053 passed, 0 failed.
  - matrix: 11335 programs, 6802 ran clean, 4533 rejected, 0 failed.
  - unit: 172/175 passed (3 skipped).
  - oracle, doc and vocab: 448 passed, 0 failed, 14 pending.

## The CORE check

The CORE §2 paragraph uses the approved text's words (proposal-errors.md §5). It is not word for word, though:

- The approved text is one paragraph that ends with a single *(planned)*. The commit splits it at its two semicolons into sentences ("…every field clones. An error is…", "…`<err`). A `catch` that names…"). Each part gets its own mark: fields *(planned)*; `error` owning *(built)*; return / `e!` / the handler's own binding *(built)*; the drop at an unbound `catch` *(planned)*; reading, matching, printing, storing, cloning *(built)*. Otherwise the words are identical.
- The proposal's plan (§7) marks the paragraph *(built)* in R3. R1 marks some parts *(built)* now.
- CORE §1 also changes in ways the approved text does not cover: `error` in the owning row of the kinds table, and a third bullet ("Three kinds the parts can't show"), saying `error` is owning whatever the program's sets hold.

None of this is changed here. The owner decides whether the split and the §1 lines stand.

## Coordination

`replacefix` changes `walkSwapCall` in `src/ownership.zig`, a different fact from this one (`moves` / `readByAddress` inputs). Whichever merges second merges main and reruns the full gates with `GATES_DELTA=1` on the combined tree.

Auto-merge is off; the independent review comes next.
