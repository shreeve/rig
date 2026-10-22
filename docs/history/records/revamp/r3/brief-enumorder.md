# Queued round: enums order (Trig NEEDS 44; owner-approved 2026-10-16)

Start after `enumnone` merges (both touch enum handling in typecheck).
Rule: `<`, `<=`, `>`, `>=` work on a plain enum (no payload variants), comparing the variants' values: the explicit `= n` values where given, else declaration order (whatever `Int(x)` gives today). An enum with any payload variant stays unordered, rejected with a Rig diagnostic as today. Both sides must be the same enum type. `.variant` shorthand on either side takes its type from the other side.
Tests: ordered plain enums with explicit values out of declaration order, implicit values, mixed sides (`x >= .es2015`), generic `T` with an ordered requirement (`Requirement.ordered`: a plain enum now satisfies it; check every generic that uses `<`, e.g. std.math min/max and sort), payload enums rejected, two different enums rejected. SPEC's enum section updated; RUST-TRIAGE/IDEAS notes reconciled. If CORE mentions enum ordering, stop: expert process.
Gates: build, suite --delta, corpus, full matrix (typecheck classification), equivalence, one adversarial review.
