# Review of PR #923 (rv-select): named select arms, select value, tested-halves coverage

Reviewed at the branch head (8dd19a4ab) against main's rig
(`tools/baseline origin/main`). Probes are in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/45a7b8df-588d-46f9-ab76-f1ed2a2c6a62/scratchpad/rv923-probes/`.
`swarm test/rig.rip concurrency-chan`: green (31 jobs).

**Verdict:** the select itself is sound in everything I tried. Its runtime,
ownership, and deadline arms held under `RIG_SANITIZE=1` with seeds 1 to 20.
There are two real defects to fix before merge. The first is the new
coverage rule on error sets (findings 1 and 2), which breaks "accept means
correct". The second is a meaning change in `migrate-select.py` (finding 3).
The remaining findings are about messages and docs.

## 1. Medium: the coverage rule uses the wrong key on an error union, so a match that misses a member is accepted

`src/typecheck.zig:3902` (`coverTested`) puts the plain name `"bad"` into
`cov.variants`. On an error union, `recordCovered` keys each member as
`"A.bad"` (`errorArmKey`), and `coversAll` compares `cov.variants.count()`
with `variant_total` (`typecheck.zig:4335`). The extra key therefore counts
as one more covered member.

Probe `e14.rig`: `error L = A | B` with members `A.bad(line: Int?)`,
`A.other`, and `B.zed`. The match has the arms `.bad(l?)`, `.bad(none)`,
`.bad(_)`, and `.other`, and no arm for `.zed`.

- Branch: `rig check` exits 0.
- Main: rejects it, "`match` on `L` is not exhaustive".

**Fix:** key the entry as `recordCovered` does, with `errorArmKey(subject,
typeOf(alt), name)`. The simpler alternative is to return early when the
subject is an error union or any error. Add `e14` as a `fail` case.

## 2. Medium: the rule now admits error-set matches whose payload tests emit cannot lower

SPEC and the PR say the rule applies "to any enum", and error sets are
included. Payload tests (`v?` and `none`) on error members never lowered,
even on main. Main hid most of this because such a match also needed `_`.
The branch now accepts these matches without `_`:

- `e12.rig` has one set: `A.bad(line: Int?)` matched with `.bad(l?)`,
  `.bad(none)`, and `.other`. `rig check` passes, then Zig fails with
  `type 'anyerror' does not support field access` (`e.code.bad.line`). Main
  rejected this program as not exhaustive.
- `e10.rig` is a union matched in full. `rig check` passes, then emit fails
  with `internal error: cannot emit this payload pattern`.

The emit gap itself is older. On main, `e13.rig` (the same match with `_`)
reaches the same Zig error. It should go in backlog.md.

**Fix:** either fix how emit lowers payload tests on error members, or keep
`coverTested` to enum declarations until it does. Add a `fail` or `known:`
case either way.

## 3. Medium: `tools/migrate-select.py` changes what a program does when a `+` capture's source is written by a later arm

The script drops captures, so the body reads the live variable after the
select returns instead of the clone made when the arm was made.

Probe `mig/m4.orig.rig`:

```
k = 10
x = task.select((!a).on_recv(|+k, v| k), (!b).on_send(<bump(!k), || -1))!
```

The original prints `10 11`. After the rewrite (`.a => k`), it prints
`11 11`, with no MANUAL line.

**Fix:** around `tools/migrate-select.py:125`, print MANUAL whenever the
name of a `+x` capture appears in any other arm's text (its sent value, or
its function). A send arm's own value is made before its closure, so that
case is safe.

Shapes I checked that keep their meaning or are rejected outright:

- kept: function names (`twice` becomes `twice(v)`), `?g` views, `return`,
  `|!n, v|`, and `|+k, v|` with no later write;
- rejected outright: `|~c|` (`*c` on a strong handle), and a `+` capture
  mutated in the body (which the old form also rejects).

## 4. Low: a new rejection is not listed, and its message is misleading

`.got(v?)`, then `.got(none)`, then `.got(_)` (probe `e6.rig`):

- Main: accepts it.
- Branch: rejects it with "duplicate arm for variant `got`". The note
  points at `.got(none)` as "first arm here".

A trailing `_ =>` in the same position is now "this arm never runs". The
PR body says "New rejections of programs main accepts: none". The CHANGELOG
mentions only `_`. AGENTS requires both to be listed.

**Fix:** say "this arm never runs: `.got(v?)` and `.got(none)` cover
`.got`", list both in the CHANGELOG and the PR, and add a `fail` case.

## 5. Low: docs

- **`task.poll` dropped:** `docs/ROADMAP.md:30` replaces the select entry
  but drops `task.poll(...)`. That is the approved "don't wait" word
  (panel-select-designer.md:12). Keep it as a ROADMAP line, or record that
  the owner dropped it.
- **Deadline spelling:** `time.after(ns)` replaces the approved
  `time.after(ms: 50)`. The PR gives a reason (durations are `Int` ns), but
  it is a naming change, so it needs the owner's explicit yes.
- **Payload field name:** a receive arm's payload field is named `value`.
  `print(r)` shows `.got(value: "x")` and `.got(value: v?)` is accepted, but
  SPEC §18 never names the field.
- **Deadline tie:** when `time.within` and `time.after` fall at the same
  time, the task deadline wins (`tasks.zig:1725` is checked first, so
  `Stop.timeout`). That is reasonable but undocumented, and could be one
  sentence in SPEC.

## Checked and clean

All of these ran under `RIG_SANITIZE=1` with seeds 1 to 20 where it applies.

**Arms and ownership** (`o1` to `o7`, `s1`, `t2`, `p1` to `p5`, `v1` to `v4`, `c4`, `c5`):
- Moves between arms are rejected, in either order and through `chs[0]`: a
  send arm moving `a` beside `!a.on_recv()`, and `<s` sent by two arms.
- Two arms on one channel, plus a send arm on that same channel, run clean.
- A losing send drops its value, and a send arm whose value fails drops the
  earlier arm's value.
- A bound value is clean whether it is never matched, matched after its
  channel is dropped, or moved out with `match <r`. `r2 = r` is rejected.
- Views out of the match temporary are rejected when they escape.
- Dropping the channel inside an arm body works.
- A select across tasks runs clean.
- The value works in a generic `id[T]`, with `==`, and with `catch .late`,
  `catch .got(5)`, and `use std.time as clock`.

**Deadline arms** (`d1`):
- Several deadlines: the earliest wins.
- `after(0)` and `after(-5)` work, and so does `after(0)` beside a ready
  channel.
- `after(maxInt)` inside `within`, and a deadline before, at, or after
  `within`.
- Canceling a task waiting with a deadline arm.
- 20 selects with `after(0)` in a loop.

**Coverage rule on enums** (`e1` to `e5`, `e15`):
- Correct on several fields, `(Int?)?`, `_?`, guards, kwargs, generic
  `E[T]`, and `match <e`.
- The messages that name the missing half are good.
