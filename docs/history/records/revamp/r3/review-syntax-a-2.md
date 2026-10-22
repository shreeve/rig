# Review: PR #92 `syntax-a`, round 2 (c755b7c0..689d9ddc)

Independent review of the fix commits 5059854a and 689d9ddc only. I built
689d9ddc and main (c7085d43) in fresh detached worktrees (`zig build`,
`zig build oracle`). Every accepted probe ran under `RIG_SANITIZE=1` in
debug and in `--release`, and through `bin/rig-oracle -v`. The probes are
in `.git/revamp/r3/review-syntax-a-2-probes/`: `e*`, `f*`, `i*`, `j*`, `k*`
cover the discarded take, `g*` the spacing hint, and `h*` the `-x` hints
and the `<?a` / `<!a` rejection. The full suite (`./test/run -j 2`) ran on
689d9ddc; see the end of this file.

## Verdict

**Safe to land.** No Critical, High, or Medium finding. H1 from round 1 is
fixed for every form I tried, and I found no double drop, lost drop, leak,
use-after-free, or wrong output. Every accepted probe runs
sanitizer-clean in debug and release, prints the same in both, and the
oracle reports no difference. Three Lows remain: two are wrong hint text,
one is a docs wording point.

## Is `facts.takes` the right fact?

Yes. `facts.takes` is recorded by `synthMove` exactly when
`sema.moveSource(operand) == .optional_part`. The bound form
(`x = <p.f`) already emits `rig.takeOut` from the same fact. So
`emitDiscard` now asks the checker's one classifier instead of
re-deriving it from syntax, and a discarded take and a bound take now
emit the same take.

What the fix changes:

- **Plain or view optionals** (no drop kind): before, these went to
  `_ = &p.f`. Now they go to `_ = rig.takeOut(&p.f)`.
- **Owning optionals:** these still go to `rig.discard(...)`, whose
  `emitBare` already emitted `takeOut`. They are unchanged.
- **Elements:** `<v[i]` was already excluded from the by-address path.
  It is unchanged.

**Takes now made, all correct and sanitizer-clean:**

- **Plain field types:** `Int?`, `Float?`, `Bool?`, an enum `C?`,
  `([2]Int)?`, `([]Int)?`, `String?`, and a plain struct `P?` (`i01`, `e11`).
- **Reached through a view or binding:**
  - a local `w = !s` (`e12`);
  - a `!S` parameter, `!self`, a nested `self.i.n`, and `self.w[0].n` (`j05`);
  - a struct holding a `!T` field (`j06`);
  - a `match !e` binding (`e04`);
  - a `for x in !v` binding (`f06`).
- **Containers:** `Box[S]` auto-deref (`e07`, `i07`), a `Vec[S]` element's
  field (`e07`), and array elements (`i04`).
- **Control flow:**
  - `defer` in a loop with `continue` and `break` (`f09`);
  - a closure with a `!s` capture, with `defer` (`f12`, `j02`);
  - a `while` step `_ = <s.n` (`j03`);
  - match arms (`j04`);
  - a `drop(!self)` body (`i08`);
  - a take repeated twice (`f14`).
- **Side-effecting index:** `<v[at(1)].n` evaluates `at` once (`k01`).
- **Generics:** `f: T?` and `Vec[T?]` with T = `Int`, `String`,
  `Vec[Int]`, and `*Int`, through a method and a generic `sub`
  (`e02`, `e03`, `i06`). A generic `T` has a drop kind, so emit uses
  `rig.discard(rig.takeOut(&...))` for every instance. That is correct
  for plain instances as well.
- **Owning optionals:** `*N?` and `~N?` (`i05`), `Vec[Int]?` (`e12`), and
  `Box[Int]?` (`i07`) go through the unchanged `rig.discard` path, with no
  double drop.

**Takes rejected, as they should be:**

- **Temporaries:** `<mk().n` and `_ = <mk().n`: "cannot take out of a
  temporary" (`e08`).
- **Shared handle:** `<h.n` through `*S` (`e09`).
- **Read views:** `<s.n` through `?S` (`f08`).
- **Copies:**
  - a `for x in v` copy (`f05`);
  - a `match e` copy (`f07`);
  - `<self.n` in a `<self` method, since the parameter is immutable (`f13`).
- **While a loan is live:** a take under a live `?s`, `?s.n`, or `!s` loan
  is rejected (`f01`–`f03`). The take is now a real write, and the checker
  already treats it as one ("cannot lend `s` to write").
- **Move rules:** a take after a whole move (`i09`); a non-optional plain
  field, "it copies"; a non-optional owning field, "partial moves"
  (`j01`).
- **Optional views:** a `V?` holding a view keeps the loan on the struct
  after `<s.v`. This is conservative and unchanged (`e13`).
- **Generic `f: T` with T = `Int?`:** rejected as a move out of a view,
  since the generic body sees `T`, not an optional (`e01`). This is
  conservative and unchanged.

**Still missing a take:** none found. Every place that `moveSource` calls
`optional_part` now takes, whether bound, discarded, or a statement.

## Statement `<?a` / `<!a` rejection

The rejection covers the forms `<?a`, `<!a`, `<?a.n`, `<!v`, `<?mk()`,
`<(?a)`, and `defer <?a` (`h03`, `h09`). All of these did nothing before,
so nothing valid is rejected:

- A `<?a` that is a value is untouched. This covers a `fun` tail
  `<?a`, a closure body `|?a| <?a`, `_ = <?a`, and `_ = <!a` (`h04`).
  These are move nodes, not `.drop` statements.
- A `<?a` that is a statement made no loan and ended none.

## Critical / High / Medium

None.

## Low

### L1. The spacing hint across a line break can quote a comment

`operandBefore` now skips line breaks, but not a comment that ends the
previous line. In that case it quotes a word from the comment
(`g01_hint_comment.rig`, `g09_hint_comment_call.rig`):

```rig
sub main()
  n = 3
  print(n # the count
    -1)
```

- **Observed:** "`count -1`: ... write `count - 1` to subtract, or
  `count, -1` ..."
- **Expected:** `n -1` ... `n - 1`, or the placeholder `a` that
  c755b7c0 printed.

The rejection itself is right; only the quoted text is wrong.

**Fix:** when the scan crosses a newline, step back over a trailing `#`
comment on that line, or return null, which falls back to the
placeholder.

The other line-break cases print the right operand: a blank line, CRLF,
`a[0]`, `"abc".len`, `<m`, and `[1 \n -1]` (`g03`–`g08`, `g10`).

### L2. The `-x` view hint fixes only parameters; captured and loop views still get "write `<x`", which is then rejected

The new `view_param` branch tests for `.param` plus a view type. Two
sibling bindings that hold views still get the hint
"to drop `v` now, write `<v`". When the user follows it, `<v` is then
rejected (`h01_minus_views.rig`, `h02`, `h10`, `h11`):

```rig
sub each(f: ?sub(Int))
  f(1)

sub main()
  v = Vec[Int]()
  each(|?v, i|
    -v          # hint: write `<v`
    print(i)
  )
  for x in ?v
    -x          # hint: write `<x`
```

- **Then `<v`:** "cannot drop captured view `v`; the closure holds it for
  every call".
- **Then `<x`:** "cannot drop loop view `x`".

**Which bindings get it right:**

- **Hinted correctly:**
  - local views `r = ?v` and `w = !v`, where `<r` and `<w` are accepted
    (`h07`);
  - slice and String parameters, where `<xs` and `<s` are accepted (`h06`);
  - `?self`;
  - `<self`.
- **Missed:** a `|?v|` capture and a `for x in ?v` binding.

This is a sibling of round 1's L4, so it falls under "fix the class, not
the instance". The hint should come from the same check that later
rejects `<x` ("cannot drop ... view"), not from a second test on the
symbol kind.

### L3. SPEC says a statement `<?x` "does nothing" but not that it is rejected

The new SPEC sentence says "A statement `<?x` or `<!x` moves a view
nowhere, and does nothing." The very next sentence says of `-e` that it
"does nothing, and is rejected". The new reject test,
`drop_statement_lend.rig`, checks that `<?x` is rejected too, so SPEC
should say so: "... does nothing, and is rejected".

## Suite

Both runs were on 689d9ddc, through `heavy.sh`:

- **`./test/run -j 2`:** 2917 passed, 0 failed, 3 pending, in 275s. The
  parser freshness check was skipped, because the worktree has no
  `nexus/` beside it. This diff does not touch the grammar.
- **`test/matrix.py -j 2 -k discard`:** 132 programs. 76 ran clean,
  56 were rejected, and 0 failed.
