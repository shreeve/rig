# Committee brief: the final no-panic strategy for Rig's datetime library

You are one of three on a committee that settles the strategy. The owner's
direction: **"We cannot panic. We must have effects stay visible. ... It needs
to be excellent, not sloppy and awkward. ... Spiritually inherit from Jiff and
jump to the right answer immediately. Our DateTime library should be one of the
best in all software."**

Read, in this folder
(`/private/tmp/claude-501/-Users-shreeve-Data-Code-undat/6fff74ce-077f-4bc9-afce-9c419f622ac3/scratchpad/unix/`):
1. `PROPOSAL.md`, the coordinator's synthesis: the principle, the inventory of
   every panic and its proposed fix, the strict-vs-lenient question, and ideas.
2. `rust.md`, `zig-go.md`, `design.md`: the first panel's reports it draws on.

Then, as you need them: Rig's repo `~/Data/Code/rig` (main e38454865):
`AGENTS.md`, `SPEC.md` (search "Both modes keep every check", "### panic",
"catch"), `docs/design/datetime.md` (the whole design; §5, §6, §7.2, §9, §11
matter most), `std/time.rig`, `std/datetime/*.rig`. Jiff 1.0.0's source is at
`~/Data/Code/rig/misc/jiff/`. `~/Data/Code/rig/bin/rig run FILE` runs a program.
Read only: don't edit, commit or push.

Phases 1 to 3 are merged (std.time; Date, Time, DateTime, Weekday; Instant).
Phases 4 to 6 (TimeZone, ZonedDateTime, format) are not built, so their design
can still change freely; changes to merged parts are a migration.

## Decide

1. **The principle.** Lenient (a panic only where `Int` arithmetic would panic,
   never on input or a valid value, never hidden in an argument, a `checked_`
   twin for each) or strict (no datetime call panics at all; every
   range-leaving operation returns `!`), or something better. Judge by Rig's
   North Star, by what reads well in real programs (write a few short ones), and
   by what the best libraries learned.
2. **Each row of the inventory**: accept, change, or replace the proposed fix,
   with the exact signature.
3. **Open points**: a `Float` Unix maker or none; non-constant `Float` duration
   forms; constant-only `round` increments; the proof-elided `!` idea (language
   change; recommend whether to pursue it, not its details).
4. **What else**: anything in the whole datetime design, built or not, that
   would keep it from being among the best (a sharp edge, a missed Jiff idea, a
   mistake another library made that this design repeats). Be specific and
   brief; rank by importance.

Write your full report to your file in this folder (name given in your prompt).
Return at most 400 words: your decision on 1, the rows you'd change and how,
your answers on 3, and your top three items from 4.
