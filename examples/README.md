# Rig Examples

Each `.rig` file's leading comment block describes its intent. The
suite is intentionally flat — one `.rig` per scenario, paired with
goldens in `test/golden/{raw_sexp,semantic_sexp,errors,emitted_zig}/`.

Implicit categories (read the header to tell which is which):

- **Working / clean** — should pass `rig check` cleanly. May or may not
  also lower to Zig (some only exercise the front-end). E.g.:
  - `hello.rig`, `shadow.rig`, `spacing.rig`
  - `borrow_release.rig`, `shadow_lookup.rig` (M4.5a positive checks)
  - `branch_independent.rig` (M4.5b positive check)

- **Negative** — must produce a specific diagnostic. The error text is
  the golden, not the emitted Zig. E.g.:
  - `move.rig`, `borrow.rig`, `drop.rig`, `escape.rig`, `fixed.rig`
    (SPEC §V1 test cases)
  - `plain_after_move.rig`, `plain_after_drop.rig`,
    `plain_during_write.rig`, `missing_bang.rig` (M4.5a)
  - `escape_nested.rig`, `branch_merged_move.rig` (M4.5b)

- **Surface preview** — exercises the broader Rig surface; not all
  features are fully lowered yet. Flagged in the file header.
  - `showcase.rig`

The `test/run` script doesn't care about category — it runs raw_sexp
+ semantic_sexp + determinism on every example, and runs the
ownership/effects checker on every example to capture the `errors/`
golden (which is empty for the clean ones). Emitted-Zig tests run
only for `EMIT_TARGETS` listed in `test/run`.
