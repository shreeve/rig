# Torture Corpus

Bad inputs that previously crashed (or could plausibly crash) the compiler.

**Contract enforced by `test/run`:**

For every `*.rig` file in this directory, `bin/rig run <file>` MUST:

1. Exit with a non-zero code (the input is bad — we want a clean rejection).
2. Print at least one byte to stderr (some kind of diagnostic).
3. **NEVER** print:
   - `Segmentation fault`
   - `panic:` / `panic at` / `general protection fault`
   - `reached unreachable code`
   - `index out of bounds`

If any of those phrases appear in stderr, the compiler panicked instead of producing a diagnostic — that's a robustness regression and the test fails.

Each file should be a minimal reduction of a real failure mode (or a class of
failures). New entries belong here whenever a panic/segfault is discovered.

The original M16 trigger was [`match_with_keyword_variant.rig`](match_with_keyword_variant.rig):
combining a `match` body with an enum whose variant happened to be a Rig
keyword (`sub`) caused parse failure to leave `Module.sema = undefined`, which
the diagnostic writer then dereferenced → SIGSEGV.
