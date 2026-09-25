# Torture Corpus

Bad inputs that could plausibly crash the compiler.

**Contract enforced by `test/run`**: for every `*.rig` file in this
directory, `bin/rig run <file>` must exit non-zero with at least one
`file:line:col` diagnostic, and must not crash (no signal, and none of
`Segmentation fault`, `panic:`, `reached unreachable code`, `index out of
bounds` in its output). A crash here means the compiler panicked instead
of producing a diagnostic.

An ordinary rejection with a message worth pinning belongs in
`test/reject/` instead.

Each file should be a minimal reduction of a real failure mode (or a class of
failures). New entries belong here whenever a panic/segfault is discovered.

Example: [`01_match_with_keyword_variant.rig`](01_match_with_keyword_variant.rig)
combines a `match` with an enum whose variant is a Rig keyword (`sub`); the
parse error must still reach the diagnostic writer.
