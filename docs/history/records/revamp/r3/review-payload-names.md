# Review: payload-names at bf652b0e

Independent fast-gate review (soundness, accept-means-correct).
Diff: `git diff 8f7cf2c6...bf652b0e`. Worktree built with `zig build` and
`zig build oracle`. Probes are in `.git/revamp/r3/probes/review-payload-names/`.
`run.sh` checks each probe, runs it under `RIG_SANITIZE=1` (with `timeout 20`) in
debug and with `--release` and compares the two outputs, then runs `bin/rig-oracle`.
`ident.sh` diffs `rig emit` of a by-name probe against its positional `_` twin.
`topos.py` rewrites by-name arm patterns into the positional form.

## Verdict

**No soundness hole found in this branch.** No Critical, High or Medium finding.
Every owned value in every probe is dropped exactly once, sanitizer-clean in debug
and `--release`. Every by-name pattern I compared emits Zig byte-identical to its
positional `_` twin. Rejections are clean, and I found no over-rejection against
main. The only findings are Low: two cosmetic diagnostic points, and two oracle
differences that exist on main too and come from positional patterns as well.

## Code read

- `fieldBindings` (typecheck) is the only classifier. It builds the field-order array
  once, with `.nil` for a field left out, and `recordPayloadBindings` stores it. Every
  pass that pairs bindings with fields now reads `payloadBindings`: typecheck
  (`copied_from`, `owned_bindings`, `viewsMatched`, `patternBinds`/`guardWrite`,
  `rejectWriteViewBindings`), storage, ownership, emit (captures, guard copies,
  consumed parts, aliases) and the oracle.
- The remaining raw `ir.VariantPattern.bindings` readers are resolve (`bindFresh` of
  `bindingName`), `rejectAltBindings`, sema `Coverage.expectName`, and the oracle's
  alternatives abstain. All of them deal only with names and never pair a binding
  with a field, so they are correct.
- A left-out field is skipped everywhere a `_` is skipped: ownership's
  `b == .src and != "_"`, storage `isUsed(.nil)`, `symbolOf(.nil) == null`, and the
  oracle's `bindHeld(.nil)` is treated as a use, the same as `_`. A read match calls
  `readBinding(f.ty, name)` for a left-out field, which matches what it does for a `_`.
- `#85`'s `recordPayloadField` sits in the same loop, keyed on the binding leaf, so
  `payloadFieldOf` is correct for by-name bindings.
- The storage change dropped `variantPayload(ty orelse continue)` from the non-consume
  path. That path is now guarded by `payloadBindings orelse continue`, which is only
  set when typecheck resolved the variant, so it is equivalent.
- `--facts=sema` prints `payload_binds ... - b k`. `[]const Sexp` is the only Facts
  value type of that shape, so the new `writeFactValue` arm changes no other fact.

## Hunt results

### 1. Owning fields (all run sanitizer-clean in debug and `--release`, 0 oracle differences)

| Probe | What it covers | Result |
|---|---|---|
| p01_consume_owning | `match <e` on D-with-drop, `*D`, Text, `Vec[D]`, struct holding D+Text, left out or by name, with guards | each D dropped once, at arm end |
| p02_read_views | read match `?E` returning a by-name view past the arm (B4b), `G[?Text]` with by-name view field, write match on `G[?Text]`, consuming `G[D]` | correct |
| p05_write_box_cell | `match !e` on `Box[D]`, `*D`, `*Cell[Int]`, `Vec[D]`, Cell holder, by name, guards | correct; replaced values dropped once |
| p06_modules | imported generic `Pair[A,B]` and plain `Bag`, read/consume/held-temporary subjects | correct |
| p10_early_exit | `return`, error return, `break`, `continue`, `?` out of consuming arms with left-out D fields | every D dropped once on every path |
| p11_alts | alternatives binding `_` by name, in read, write and consuming matches | correct |
| p16_generic_consume | generic functions consuming `Opt[T]` with T=D and T=Text, leaving T fields out | correct |
| p17_shared_subject | matching through `*E` by name | correct |
| p18_swap | binding names that are other fields' names (`.two(w: h, h: w)`) in read, write, guard and consume | each binding takes the field it names |
| p23_nested_catchall | nested consuming matches by name, catch-alls, match values | correct |
| p24_cell_leftout | Cell holder left out of a copying read match of a temporary | correct; same as `_` |
| p09_field_name_shadow | moved or dropped locals that share a field's name; closure | the field name is not a use |

Escape attempts are rejected the same way as their positional twins. Each probe has a
`_pos` twin, and both give the same diagnostics:
- p03: a view outliving reassign, drop or move of the subject.
- p12: a view of a header temporary, including C5.
- p13: a view-typed field outliving what it views.
- p15: a write-view field reached through a read view.
- p21: moving or dropping out of a read binding.
- p22: moving out of a write binding.

**Widened grids.** `grid_gen.py` takes test/matrix.py's `payload` and `viewpay`
grids (821 cells) and gives each variant a second, owning field `z: Text`. It writes
each cell twice: binding `r` by name with `z` left out, and positionally with `_`.
`grid_run.sh` then checks every cell:
- **Verdict parity:** 0 differences (591 accepted, 230 rejected by both forms).
- **Emit identity:** 0 differences on all 591 accepted cells.
- **Debug runs:** all 591 accepted by-name cells print their expected output under
  `RIG_SANITIZE=1`.
- **Release runs:** a 1-in-8 sample of 73 cells (`release_sample.sh`) passes.
- **Oracle:** 13 differences, all pre-existing (see L3 below).

### 2. Identity

Byte-identical emit (only the `note: the package ...` path differs) for:
- p01, p02, p05, p06 (cross-module), p09, p10, p11, p16, p17, p18, p23, p24;
- the branch's own `test/behavior/ownership/match_payload_by_name.rig` and
  `test/behavior/types/payload_by_name.rig`, converted by `topos.py` (id_*.rig);
- all 591 accepted widened grid cells.

`--facts=storage` differs only in spans. The agent's claim holds.

### 3. Rejections (p08, p19, p04, p25, plus the branch's reject tests)

Each of these is rejected at the right line and column:
- mixing styles, which points at the variant name;
- an unknown field, with a "did you mean" hint;
- a duplicate field;
- a by-name pattern on a no-payload variant;
- alternatives binding names;
- a guard that writes or moves a by-name binding, in write and consuming matches;
- a by-name pattern on an error, or on a non-enum;
- `.rect()` on a payload variant;
- use after a consuming match (the branch's `payload_by_name_flow`).

No crash in any later pass.

### 4. Arity crash

- **Confirmed fixed.** `/Users/shreeve/Data/Code/rig/bin/rig check p07_arity.rig` on
  main panics with "for loop over objects with non-equal lengths" at
  storage.zig:1034. The branch reports both arity errors cleanly.
- **Sibling hunt** (p08, p19, p25): typecheck-rejected patterns going through
  storage, ownership and emit. The cases tried were mixed styles, duplicate field,
  unknown field or variant, payload on a no-payload variant, by-name patterns in
  alternatives, a write match with a rejected pattern, a variant pattern on Int, a
  payload on an error, and `.two(a, b: b)` in each mode. All of them return null from
  `payloadBindings`, and every reader handles `orelse`. No other crash.
- No other zip of bindings with fields remains. Emit's
  `variantPayload(...) orelse unsupported` only runs on accepted programs.

### 5. Over-rejection

`overreject.sh` ran `rig check` with main's binary and the branch's binary over all
9809 `.rig` files in main's test/, examples/ and std/ (output in `overreject.out`).
Only 4 verdicts differ, and every one is main rejecting and the branch accepting a
by-name pattern:
- `test/corpus/docs-probes-k1.rig`
- `test/corpus/review-sc3-k1.rig`
- `test/corpus/syntax-review-symmetry-p_pattern_kw.rig`
- `test/reject/syntax/match_field_name_pattern.rig`, which the branch deletes

The three corpus probes now run, print the right output in debug and `--release`
under the sanitizer, and are oracle-clean. Nothing that main accepts is rejected by
the branch.

### 6. Oracle

The oracle was run on every probe (`all_probes.out`). It reports 0 differences except
the two below, and both reproduce with positional patterns and with main's oracle.

## Findings

None Critical, High or Medium.

**L1 (cosmetic). The duplicate-field note points at the binding, not the field.**
- Probe: p19_messages.rig line 20.
- Observed: `.rect(h: _, h: q)` reports "first bound here" at the first binding's
  value (`_`, col 14), not its field name (`h`, col 11).
- Cause: `self.startOf(binds[i])`, where `binds[i]` is the kwarg value.
- Fix: keep the kwarg node, or its name, for the note.

**L2 (cosmetic, pre-existing). A duplicate binding name gets an odd message.**
- Probe: p14_dup_name.rig and its positional twin.
- Observed: `.two(a: x, b: x)` reports "pattern binding `x` shadows the local `x`",
  plus "bound but never read". Main gives the same for `.two(x, x)`.
- Effect: the program is rejected, so this is only wording.

**L3 (pre-existing on main, oracle stricter than prod). A generic view payload beside an owning field.**
- Probe: p26_oracle_generic_viewpay.rig; 13 `viewpay.*.generic.{ret,guard,store}`
  widened cells in the same way.
- Observed: `match gwrap(x)` on a `G[?T]` that also holds `z: Text` gets
  `DIFF inner prod=accept ref=reject C5 a loan of a temporary outlives its statement`.
- Production is right: the program runs sanitizer-clean in debug and release and
  prints the right value, because `r` is the `?T` the field holds, not a view of the
  temporary.
- Cause: the oracle's `bindHeld` C5 rule sees `holds_views` on the binding, and
  `payloadOf` returns the declared `T` rather than the instance's `?T`. It does not
  use #85's `payloadFieldOf`.
- Scope: positional patterns give the same difference with main's oracle. It is not
  this branch's, but it is a follow-up for #85, and the gate will see it once a grid
  holds an owning field beside a generic view field.

**L4 (pre-existing on main, prod stricter than oracle). Moving out of a write-match binding.**
- Probe: p22_move_from_write.rig.
- Observed: moving out of a write-match binding (`z = <a` in `match !e`) is rejected
  by prod ("cannot move out of `a`: it is a view of `e`") but accepted by the oracle
  (`stricter ... prod=reject ref=accept`).
- Scope: the positional form does the same on main. This is a gap in the reference
  checker, not a prod hole.

Also pre-existing and unchanged, noted for completeness: p13_view_field.rig rejects
reassigning `g` after copying out its `?Text` payload, which views `s` and not `g`.
This is conservative and the positional form behaves the same.

## Commands

```
P=.git/revamp/r3/probes/review-payload-names
$P/run.sh $P/p*.rig                         # all_probes.out
$P/ident.sh A.rig A_pos.rig                 # emit identity
python3 $P/grid_gen.py <worktree>/test/matrix.py $P/grid
.git/revamp/r3/heavy.sh $P/grid_run.sh      # grid_run.out
.git/revamp/r3/heavy.sh $P/release_sample.sh
.git/revamp/r3/heavy.sh $P/overreject.sh    # overreject.out
```
