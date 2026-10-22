# Review 4: ignored-bang fix commits (d4cd3085..309a3e5c)

Scope: 90bbc714, db64483a, 7792d89e, cfdf670e, 24fca219, fb906d05, and
309a3e5c. This excludes what merge 3af64e45 brought in from main.

I built `bin/rig` and `bin/rig-oracle` at 309a3e5c, and `bin/rig` at
d4cd3085 and at main 39d0e4b2. The probes are in
`scratchpad/r4p/` (session scratchpad): s*/h*/f*/v* cover labels,
a* cover `as` headers, and d* cover diagnostics.

## Verdict

**Safe to land. There are no soundness findings.** I found no Critical,
High, or Medium issue in the fix commits. There are three Low findings,
and one pre-existing issue is carried over.

## Gates run

- **Round tests.** `./test/run` on write_lend_as_header,
  ignored_write_lend*, loop_label_shadow*, labels_nested*, and
  cli/diagnostics: 17 passed.
- **Over-rejection scan.** I ran `rig check` on every .rig file in
  test/, examples/, and std/, at 309a3e5c and at d4cd3085. Only the two
  new tests differ:
  - loop_label_shadow_value.rig was rejected at d4cd3085 and is now
    accepted.
  - ignored_write_lend_as.rig is now rejected.

  No corpus probe, example, or std module changed outcome.
- **Accepted probes.** Each one ran under `RIG_SANITIZE=1` in debug and
  as a `--release` build. All were clean, with the same output in both.
- **Oracle.** `bin/rig-oracle` over all 47 probes: 0 differences.
- **SPEC claims.** The new claim (`Opt[!Int].some(v: !n)` keeps the
  write view; `Opt.some(v: !n)` is rejected) is covered by
  write_lend_kept.rig and ignored_write_lend.rig.
- **`zig fmt`.** The remaining sema.zig diffs are already on main.

## 1. `as` headers: dropping `markWritten(expr)` (90bbc714)

`markWritten` walks down through `.member` and `.index` nodes only. For
`!(!p).o` the header is a `.write` node, and for `<(!p).o` it is a
`.move` node, so the removed call did nothing for either. Those forms
are still marked written, by `requireAccess` and `synthMove`.

So the change only affects a bare path header (`(!p).o as v`). A bare
path header never writes. Its binding is one of these:

- a copy of the value;
- a read view of the value;
- a read of an optional write view held in the field;
- an error that says to write `!`.

The new rejection is therefore exact. The valid forms all stay accepted
and run correctly in debug and `--release`:

- `if/while !(!p).o as v` with `v += 1`
- `<(!p).o as v`
- `!(!p).q.o as v`, `!(!(!p).q).o as v`, and `<(!p).q.o as v` (a05)
- a `!P` parameter: `!(!h).o`, `!h.o`, and `!(!h).vs` with
  `!v.push` (a07)
- Vec payloads through `!(!p).vs`, in `if` and `while` (a10)
- a field holding `(!Int)?`, written through `!(!v).w as x` or
  `<(!v).w as x` (a03, a04)

Bare forms are now rejected as only read, the same way `(!p).o ?? 0`
is:

- `(!p).q.o as v`
- `(!h).o as v`
- `(!v).w as x` over `(!Int)?`
- `(!p).t as s` over `Text?`

In a09, assigning to `v` after `(!p).o as v` still also gives the
"copy of the value inside" diagnostic, which names `!(!p).o as v`.

## 2. Label shadowing in `breaksOut` / `breakValues` (db64483a)

`breaksOut` has three users besides `breakValues` and `yieldedLeaves`:

- `hasValueBreaks`, which typecheck's `isValueLoop`, emit, ownership's
  `else` walk, and storage all use;
- `loopsForever`;
- `yieldsWriteView` and `writeLendRead`.

Missing a leaf in `yieldedLeaves` would be unsound, because
`yieldsWriteView` could then bind a held write view where a leaf is a
bare read. So I checked that every jump the walk now skips really
targets the inner construct, and that every jump that leaves the outer
loop is still found.

**Still found, and rejected or held correctly:**

- s02: `break :a w` in an inner `:a` loop's `else`.
- s03: an unlabeled `break w` inside `:a match`.
- s05: an unlabeled `break w` inside `:a raw`.
- s07: a deeper loop's inner `:a` `else`.
- s13: `break :a w` from a `:b` loop placed after an `:a` shadow.
- s14: a triple shadow whose innermost `else` breaks to the outer loop.
- f01, f04: `loopsForever` still sees an unlabeled `break` in `:a raw`
  and in `:a match`, and a `:b` loop's `else`.

**Correctly skipped:**

- `break :a` in an inner `:a` body (s01, s15).
- `continue :a` in an inner `:a` loop (s12).
- f02, f03: `loopsForever` with `break :a` inside an inner `:a` loop,
  including from a nested unlabeled loop's `else`.

**Agreement with typecheck and emit:**

- Typecheck already treats a jump in an inner `:a` loop's header, or
  in an `:a match` subject, as the inner construct's (h01, h04). The
  walk also skips those headers, so the two agree.
- A value `break` cannot be written in a `while` condition or a range
  header at all (h03, h06, h07).
- Programs that use both meanings print what the innermost rule gives:
  s01 prints `2` then `11 2`, s02b prints `1 12`, f05 prints `2 100`.
- `loopsForever` and `isValueLoop` agree with emit. The probes that
  run, including v02 with owned `Text` values crossing an inner `:a`
  value loop inside an outer `:a` loop with an `else`, are
  sanitizer-clean in both builds.

A shadowing `:a match` or `:a raw` is walked with the label cleared, so
only unlabeled breaks count. This is right: s04 shows that typecheck
rejects `break :a v` out of a labeled block.

## 3. Follow-on-error suppression (7792d89e, 309a3e5c)

A path error is skipped only when an existing non-lint error in this
module lies within the statement's own span. Any such error already
fails `rig check`. So the suppression cannot turn a rejected program
into an accepted one.

I checked how diagnostics are removed. The only shrinks are
`synthQuiet` and the tentative lambda check, which are nested sections
closed before `checkReachedLends` runs at module end. Lints are emitted
by sema after this point, and 309a3e5c also excludes them. Ownership
errors come later still.

## 4. `placeInOrder` (7792d89e)

The merge is consistent:

- Each late error carries its notes with it.
- Notes that belong to early errors stay after their errors, because
  insertion happens only before an early module-0 error.
- Every error's index in `reported` is updated afterwards.

The dedupe check in `report` also compares position and message before
it skips, so a stale index could only fail to dedupe. It could never
hide a new error. Path errors now print in source order (d03).

## Findings

### Low 1: suppression hides an independent path error in the same statement

The own span of a simple statement is the whole statement. That
includes a value `match`'s arms and a closure's body. So an unrelated
error anywhere in it hides the path error until the first error is
fixed.

```rig
struct P
  x: Int

sub main()
  p = P(x: 1)
  a = (!p).x + nope1
  print(a)
  d = match (!p).x
    1 => nope6
    _ => 0
  print(d)
```

Observed: only the two "use of unbound name" errors are reported.

Expected: the `(!p).x` errors are reported too, or the comment says
that any error in the statement hides them. The commit comment says
"the write was rejected there", which is narrower than what the code
does.

This is noise only. Every such program is still rejected (d02, d03,
d05).

### Low 2: the suggested rewrite for a nested lend is itself rejected (pre-existing)

```rig
if (!(!p).q).o as v
  print(v)
```

Observed: "`!(!p).q` here is read, not held: `(!(!p).q).o` only reads
the place it reaches. Write `(!p).q.o`".

`(!p).q.o` is then rejected in turn ("`!p` ... Write `p.q`"). The same
happens at d4cd3085 with `x = (!(!p).q).o` (a14).

Expected: the hint strips every write lend from the path, giving
`p.q.o`.

### Low 3: a value loop that only an inner same-label loop breaks is now rejected (intended)

v01 is accepted on main and prints `5`, `6`, `7`. It is now rejected
with "this expression does nothing as a statement" and "incompatible
types `Void` and `Int`". v01 has the shape `k = if c` over an `:a for`
loop whose only `break :a i + 5` belongs to an inner `:a while true`,
with an `else` of `7`.

This matches the rule in SPEC §Loops as values. It also matches the
unlabeled case without any break (v03), which main rejects the same
way. Main accepted v01 only because of the label bug.

The diagnostic does not say why the loop is not a value. A message
such as "this loop has no `break` with a value" would help. Cosmetic.

### Carried over, not this round: `(!arr)[i]` miscompile family (Rule 2)

These forms are still accepted by `rig check`, and `zig` then fails on
the emitted code:

- m01: `if !(!arr)[0] as v`
- m03: `if <(!arr)[0] as v`
- m02: `(!arr)[0] = 7`

There is still no known-bug test in test/known for them. They are
unchanged by these commits. fb906d05 only pins the bare `(!arr)[0] as v`
form as rejected. They should be fixed or given known-bug tests before
the release tag.

## Commits checked with no finding

- **cfdf670e:** the doc comments on `ReachedLend`, `LoopValue`,
  `hasValueBreaks`, and `written_paths` are now on the right
  declarations, and the stray blank line is gone.
- **24fca219:** the SPEC wording now says the program is rejected, and
  names both rewrites. Both are tested.
- **fb906d05:** the reject test now pins `(!arr)[0] as v`.
