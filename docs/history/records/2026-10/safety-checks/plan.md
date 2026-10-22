# Next Rig round (after fun-and-comptime lands): what safety checks cost Trig

Agreed with Rig (fork), 2026-10-21.
- Measuring-only emit knob, never shipped: drop one check kind at a time (index, overflow, cast, unwrap), and ALL FOUR together.
  The gap between the sum of the single-kind gains and the all-dropped gain shows overlap that needs a joint fix.
- Build Trig per variant on pup core 3, fastest of 10, ts-pattern + zod3; time + instructions.
- perf annotate the panic branches, ranked by retired branches per SITE: concentrated (flatten store accessors
  `[id / 256][id % 256]`) or spread thin (a general rule, e.g. counters proven not to wrap).
- Then choose among: non-wrapping counters, flatter accessors, more proofs.
Questions for Trig (from me, as foreman):
  (b) how many functions pay a large prologue before a kind test (split + `rarely` fixes it today);
  (c) a case where the Core refuses a view Trig wants (returning a stored list as a view works today);
  (d) the share of `[192 of 0]` fills (emitted as a memset).
