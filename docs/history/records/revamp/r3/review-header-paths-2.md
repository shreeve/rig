# Review: header-paths (PR #96), round 2

- **Reviewed:** `git diff 6931bc9b cf5fe5e5` without the merge of main: d3005f3c (the narrow oracle rule), dbf883b4 (the rejections gate), c7e4294e (`lendsBranch`), c9bc0ad5 (the `hdr.` sigil dimension), d275754e (corpus), cf5fe5e5 (listing).
- **Builds:** cf5fe5e5 and a7ac9080 (main), each in a fresh detached worktree, with `zig build -j4` and `zig build oracle -j4`. Everything ran on the Mac; pup was not needed.
- **Probes:** `.git/revamp/r3/review-header-paths-2-probes/`.
  - `n*`: the oracle's narrow rule.
  - `gate/`: the rejections gate.
  - `b/`: `lendsBranch` leaf kinds, bare arguments, and the newly accepted forms.
  - `h/`: header sigil stripping.
  - `na/`: around the 3 newly accepted programs.
  - `grid/`: 120 generated programs from `tools/gen3.py`. Results are in `grid-check.tsv`, `grid-run.tsv` and `grid-oracle.tsv`.
  - `hdrkeep/`: the `hdr.` family as generated, 156 programs.
  - `oracle-*-{main,head}.log`: the oracle over tests, corpus, and matrix, with each build.
  - `tools/run1.sh`: the sanitizer runner.

## Verdict

**There is no oracle weakening.** The narrow rule is correct, and it loses no rejection anywhere I looked. The rejections gate works, but it is not airtight (M1).

**The PR adds no unsound acceptance.**
- The 3 newly accepted programs are sound.
- Every review-1 shape is rejected.
- Every `lendsBranch` leaf kind I probed holds.

**But the class the PR says it closes is still open in two places (C1, C2).** Both are on main too. Both are use-after-frees under `RIG_SANITIZE=1`, and they print garbage or panic in `--release`.

- **C1:** `for x in ?B.path` over owned or element leaves never asks `lendsBranch`. The PR says `for` does.
- **C2:** a branch of write-view places is read in place, with no sigil, where a read view is expected. That is an argument to a `?T` parameter, or a `?T` field. This lend also routes around `lendsBranch`.

**Recommendation:**
- Fix C1 before landing. It is the PR's own claim, and it is a small change in `checkFor`.
- Fix C2 here, or record it as an open Critical with its probes added as tests.
- Correct the PR text, which says "no lend routes around it".
- This is the third round of soundness findings in the branch-lend class. AGENTS.md says "A second soundness round stops the feature". Consider the redesign: every place where a branching value is *read in place* (a sigil, a header mode, or a narrowing coercion) is a lend, and asks the one decider.

---

## Findings

### C1 (Critical, on main too, in the PR's stated class). `for x in ?B.path` with owned or element leaves skips `lendsBranch`

**The cause:** `checkFor` (`src/typecheck.zig` around line 1950) takes `for`'s `?`/`!` as its *mode*, and keeps the source bare.
- It asks `lendsBranch` only through `lendSlice`, so only for a range index (`?B.v[..]`).
- Any other source is `synthExpr`'d bare.
- The header decider (`headerCopiesWriteView(…, lent=true)`) flags only leaves of a type that holds a write view. Owned leaves pass.
- `match`, `if … as` and `while … as` are different. Their `?S`/`!S` is a real `.read`/`.write` node, `synthLend` runs, and `lendsBranch` rejects (probes `e_match_*`, `e_as_*`, `e_while_*`).
- **So the sigil-stripping paths are not identical.** `hdrkeep/` shows it: every `for.read` and `for.write` cell is rejected by the header decider, never by `lendsBranch`.

**Probes.** All are accepted by a7ac9080 and by cf5fe5e5, and all are use-after-frees under the sanitizer:

| Probe | Form | `--release` |
|---|---|---|
| `h/h03_for_read_owned_branch_path` | `a`, `b` owned `W` locals: `for x in ?(a if c else b).v`, with `!a.v.push(1)` in the body | `1 2 -6148914691236517206` |
| `h/h03c_…_reassign` | the same, with `a = mkw(1)` in the body | `1 -6148914691236517206 -6148914691236517206` |
| `h/h03e_for_read_owned_branch_elem` | `for x in ?(a if c else b)[0].v` over `Vec[W]` locals, with `!a[0].v.push(1)` in the body | `1 2 -6148…` |
| `grid/m_for_rv.{if,nested}.{owned,elem}` | 4 cells | `m_for_rv.if.elem` panics with an integer overflow |

- **The control** `h/h03k`, `for x in ?a.v` with the same body, is rejected: "cannot lend `a` to write while a read loan is live".
- **The emitted Zig** walks `(if (c) &a else &b).v.items()`, so the loan on `a` is simply lost.
- **The oracle** reports a `DIFF` on all of these (C4: "cannot write `a` while a read loan of it is live, carried by the `for` source"). The matrix has no cell for them: `HDR_LEAVES` is only `wparam`, `wlocal` and `holder`, all of which hold write views.
- **The fix:** in `checkFor`, when `mode` is `.read` or `.write` and the source is not a range index, ask `lendsBranch(source, .nil, mode)`, as `synthLend` does. Then add an owned leaf and an element leaf to the `hdr.` family.

### C2 (Critical, on main too; the sigil-less sibling of review 1's C2). A branch of write-view places read in place where a read view is expected

**The class:** an expression `B` whose base is a branching value (`a if c else b`, `x ?? a`, `e catch a`, `o?`, or a nested branch), with a leaf that is a place holding a write view, used without a sigil where a `?T` is expected.
- `recordAdapted` narrows it (`.narrow`, `src/typecheck.zig` around line 9091), as it would a bare name.
- For a bare name, ownership records a read lend of the name. For a branch, the leaf's write view is *copied*. The copy carries the loans the leaf holds (on `x`), but makes no loan on the leaf place itself.
- So writing through the leaf (`!a.push`, `a = …`, `if !o as w`) while the result lives is accepted.
- No `lendsBranch` call covers this path. `lendTemp` is not reached: the operand is not a temporary.

**Probes.** All are accepted by both compilers, and all are use-after-frees:

| Probe | Form |
|---|---|
| `b/a02b_bare_arg_branch_wviews_slice` | `sl(a if c else b)`, with `sl(v: ?Vec[Int]) -> []Int` and `a`, `b: !Vec[Int]` parameters, then `!a.push` ×100, then `s[0]` |
| `b/a02c` | the same, then `a = mkv(7)` |
| `b/a01b` | `sl((a if c else b).v)`, a path through a branch of `!W` parameters |
| `b/k03b` | local write views `a = !x`, `b = !y`; `sl(a if c else b)`, then `!a.push`. The same program pushing through `x` (`k03`) *is* rejected: the held loan travels, the loan on the leaf does not |
| `b/k04`, `b/k12` | `sl(pv(!b, k) ?? a)` and `sl(fv(!b, k) catch a)` |
| `b/k13` | `sw(a if c else b)`, with `sw(w: ?W) -> []Int` |
| `b/k14` | `sl(h1.w if c else h2.w)`, holder fields |
| `b/k15` | `sl((a if c else b) if c else b)`, a nested branch |
| `b/k10` | `RV(r: a if c else b)`, a `?Vec[Int]` field |
| `b/u01` | `sw(o?)` with `o: (!W)? = !a`, then `if !o as w` and `!w.v.push` |

**The grid** (`grid/`, contexts `arg_w`, `arg_v`, `field_w`, over forms `if`, `nested`, `coal`, `catch` and leaves `wparam`, `wlocal`, `holder`):
- 36 programs, all accepted by both compilers, all use-after-frees (`grid-run.tsv`).
- `--release` prints `0` where `1` is right (`m_arg_w.if.wparam`, `m_field_w.coal.holder`, `m_arg_v.nested.wlocal`).
- Owned and element leaves are rejected in these contexts (a type mismatch), and `field_v` is rejected throughout.

**The oracle:**
- 24 of the 36 would be a `DIFF`: `arg_v` is C4, and `field_w` is C2, "a bare write view would be copied".
- It abstains on the 12 `arg_w` programs, and on `a02b`, `k04` and `k12`–`k15`: "a bare write view passed as a view".
- No tree program or matrix cell has these shapes, so no gate sees them.

**The fix:** a held write view narrowed to a read view is an implicit read lend. Where its operand is a branching value, or a path from one, it must ask `lendsBranch(operand, .nil, .read)`. This is the same decider, at the one sibling site it does not reach yet. A matrix family "branch × narrowing context × write-view leaf" (`tools/gen3.py`) would keep it closed.

### M1 (Medium). The rejections gate is not airtight: a listed rejection can disappear without `LOST`

`checkProgram` (`test/oracle/main.zig`) checks a listed function only when it decides that function in this run. There are two gaps, both demonstrated in `gate/`:

1. **A module with any sema error is skipped whole.**
   - `prod == .sema` makes the loop `continue` before the rejects check. `own_ran` is false for the entire module as soon as sema reports any error.
   - `gate/q.rig` is the CLI test's `p.rig` plus one function with a type error. With `q.rig good` listed as a rejection the oracle *accepts*, `--rejects lostq q.rig` exits **0**. The same listing on `p.rig` exits 1 (`LOST`).
   - So a change that adds a sema error to a file, or that moves a rejection into sema, as this PR does, stops checking every listed oracle rejection in that module. It does so silently.
   - **An instance in this PR:** corpus `review-payload-loan-3-j02` and `j03` were `prod=reject ref=reject` on main. Since round 1 they are sema-rejected, so the oracle no longer decides them, and they are not in `rejections`. That is harmless here, but it is exactly the path by which a real rejection would vanish.
2. **There is no stale-entry check.** The allowlist has `FIXED` for unused entries; the rejections file has nothing like it.
   - A listed program that is not in the run, or a listed function not found in a seen program, passes: `gate/stale` lists `gone.rig bad` and `p.rig nosuch` and exits 0.
   - So renaming a test file, renaming a function, or deleting either silently drops its rejection.
   - **For doc examples, this is the checksum question.** Any edit to an example's text, even whitespace, gives it a new key. The old key goes stale (not reported). The new key is `UNLISTED` only if the oracle still rejects it. If the same change weakens the oracle so that it now accepts the example, nothing fails.

**The fix:**
- For gap 1, decide listed functions even when `prod == .sema`, as `--sema` already does. A listed function the oracle abstains on there could be reported separately.
- For gap 2, report a listed entry whose program was seen but whose function was not decided, as `STALE`. Have `test/run` check that every listed program prefix (`test/`, `doc/`, and the matrix ids) belongs to a set that ran, and was seen by it.
- The `# oracle:` stated verdicts are already robust: `checkStated` runs before the `prod` split. So `o01`–`o06` in `receiver_view_stored_in_argument.rig` are protected either way.

**Otherwise the logic is right:**
- `UNLISTED` fires on any decided `reject`.
- `LOST` fires on `accept` *and* `unknown`, so an abstention counts as lost.
- All four sets pass `--rejects` (`tests`, `corpus`, `docs`, and `matrix` through `matrix.py --oracle`), and each lists its whole set, with no sampling.
- `test/cli/oracle_rejections.sh` checks both directions.

### L1 (Low). The `hdr.` sigil dimension cannot see C1

- Every `for.*` cell (bare, `?`, `!`) is rejected by the header decider, and `for.write` cells partly by "`for x in !xs` … must be a binding". `lendsBranch` never fires there (`hdrkeep/` reasons).
- A cell checks only that the program is rejected, not which rule rejected it.
- With no owned or element leaf, the family is blind to `for x in ?(a if c else b).v` over owners.
- Add the leaves `owned` (`a = mkw(3)`) and `elem` (`a[0]` of a `Vec[W]`) for the `read` sigil.

### L2 (Low). PR text

"So does a slice lent (`lendSlice`, also the `for` header's), so no lend routes around it", and "`for` headers all ask it". Both overstate what is built: C1 and C2 are lends that route around it.

---

## The questions asked

### 1. The oracle

**Is the narrow rule correct?** Yes.
- **Store-into-argument shapes:** the oracle still rejects every `!self` method that stores a view of itself into another `!` argument: `o01`–`o06`, plus `n02` (receiver through a `!A` parameter) and `n03` (receiver through a local write view). `n05` (receiver `w = !g.a`, argument `!g.d`) is rejected at the call as a second lend of `g`.
- **Disjoint fields:** the only way another argument could share the receiver's root is `!g.a.put(!g.d)` (`n01`). Both checkers reject that as two live write lends of `g`, so the root-equality test (`recv_root == g`) never exempts a store into a sibling argument.
- **Cells:** a `Cell[?T]` is a type error (`n06`).
- **Closures:** an owned closure cannot capture a view (Core s9).
- **Into `self`:** a callee that stores `?self.v` through its own write-view field is rejected in the callee by both checkers (`n07`, `A.put`: C4). That is the invariant the exemption relies on.
- **Survey, main's oracle against cf5fe5e5's** (`oracle-*-{main,head}.log`):
  - Tests: 4,690 functions.
  - Corpus: about 28,000.
  - Matrix: the same 7,657 generated programs, run by both oracle binaries.
  - On every function both decide, **no `ref` verdict changes**.
  - With `--sema`, the only change is `j02` and `j03`, from `ref=reject` to `unknown`, because sema now poisons them (see M1).

**Does the rejections gate fail on any lost rejection?** On a lost rejection the oracle still decides, yes. On a module now rejected in sema, or a renamed, removed or edited program or function, no (M1). For doc examples, an edit to the text renames the entry, and the old entry is never reported.

### 2. `lendsBranch`: is any leaf kind accepted that is really a place?

Within `lendsBranch` itself, no. Every leaf kind I probed holds:

| Leaf kind | Probes | Result |
|---|---|---|
| Constants | `c01`, `c01b` | `!(K1 if k else K2)` is rejected ("cannot lend constant … to write"). A module constant cannot be a struct, so it holds no owner or view |
| Jumps with values | `c03`, `c03b`, `c04` | `?(pk(!a, k) ?? return none).v[..]` bound past its statement is rejected ("outlives its statement"). `(?(pk(!x, n > 1) ?? break n).v[..])[0]` runs clean, printing `1 2` in debug and `--release` |
| A lend leaf that reaches a place through another branch | `l01`, `l02`, `l07`, `l10` | `?(!(a if c else b) if k else !dd)` and the rest are rejected: the inner lend is checked by its own `synthLend` |
| A nested branch inside a path | `l03`, `l04`, `l05`, `grid nested` | `?((a if c else b).v if k else mkv(2))[..]` is rejected. The leaf `(a if c else b).v` hands `.place`, which is conservative: `l05`, over a branch of lends, is rejected too |
| Method receivers on a branch | `a03`, `l06`–`l10` | All rejected (`lendsBranch`, or the read loan) |
| `e?` / `e!` on place optionals | `c05b`, `c05c` | `?(o?)` and `!(o?)` are rejected. `c05c` (`!(o?)` with `o: (!W)? = !a`) was accepted on main and is rejected now |
| Moves | `c11` | `!(<a if k else <b)` runs clean (`4 4 3`) |

The holes are at sites that never call `lendsBranch` (C1, C2), not in its leaf list.

### 3. The 3 newly accepted programs

They are sound.
- **The corpus programs:** `review-lend-base-2-gen-{bw,ca,co}__slice__stmt` print `2 1110 2220`, sanitizer-clean.
- **Statement-scoped variants run clean:** `b/s07` prints `3 4 2` in debug and `--release`, and `na/n6` prints `2 2 2`. `na/n3` copies an `Int` out, then grows the Vec.
- **Every form where the view outlives the statement is rejected** ("a view reached through `!c if k else !d` outlives its statement"). That covers `s01`–`s04` and `s06` (grow, reassign, `??`, `catch`, locals), `na/n2` (bound slice), and `na/n5` (a slice retained through a call).
- **Write-slice forms** (`s05`, `na/n4`) are rejected ("only a named … can be sliced").
- **A non-slice path through a branch of lends that outlives the statement** (`s08`, `s09`) is rejected by ownership ("use of `c` while a write loan is live").

### 4. Sigil stripping in `match`, `as` and `for`

They are not identical:
- **`match`, `if … as` and `while … as`:** the sigil is a lend node, so `synthLend` runs and `lendsBranch` decides first. `headerSubject` then strips it for the header decider, with `lent=true`.
- **`for`:** the sigil is the loop's mode, and the source is bare. `lendsBranch` runs only for a range-index source. The decider is called with `lent = mode == .read or mode == .write`, which covers write-view-holding leaves only. That is C1.
- **The mode guards also differ** (`match`: `mode != .consume`; `for`: `mode != .move`; `as`: none). For `<S` subjects this is harmless: `headerSubject` does not strip `<`, so the decider sees a `.move` node and returns null, and `rejectMadeParts`/`moveLeaves` check the move.

## Cleanup

The worktrees were removed and nothing was pushed. Everything ran on the Mac, with no pup branch.
