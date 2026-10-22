# Review: header-paths (PR #96), round 1

- **Reviewed:** `git diff 308585bf 6931bc9b` (head 6931bc9b, base main 308585bf).
- **Builds:** both commits, in fresh detached worktrees, with `zig build` and `zig build oracle`.
- **Probes:** `.git/revamp/r3/review-header-paths-1-probes/`.
  - Hand-written: `o*` (oracle), `p*`, `q*`, `r*`, `t*`, `u*`.
  - `grid1/`: 136 programs, header × subject shape × leaf.
  - `grid2/`: 84 programs, header × sigil (`?`, `!`, bare) × form (bare branch, path, parenthesised path) × leaf.
  - Each grid directory has a `results.log`.
  - `tools/`: the runner and generators, plus `oracle-narrow-receiver-own-lend.diff`, the narrower oracle rule tested in section H1.
- **Runs:** each program was checked by both compilers and both oracles. Every program the PR accepts was run with `RIG_SANITIZE=1` in debug, and the key ones also in `--release`.

## Verdict

**Not safe to land as is.** There is one High finding against the PR itself, and one Critical class that is still open in the class the PR says it closes.

- **H1 (High, introduced by this PR):** the oracle change disarms the reference checker. It no longer rejects a method that stores a view of its `!self` receiver in another `!` argument. An existing reject test is affected: the oracle now accepts `write_receiver` in `test/reject/ownership/receiver_stored_in_argument_siblings.rig`. A narrower rule fixes L1's false positive without losing any of these rejections.
- **C1 (Critical, on main too, inside the PR's stated class):** a header subject that reaches the write view through a branch under a lend sigil is accepted, and it is a use-after-free. The forms are `match ?(a if c else b)`, `match !(a if c else b).e`, and `if ?(a if c else b).o as x`. The decider never sees through the `?` or `!` for `match`, `if … as` and `while … as`. `for` does peel `?` and moves `!` to its mode, so `for` is covered.
  - 48 of grid2's 84 programs are accepted, and every one is a sanitizer use-after-free.
  - In `--release` they print `0` where `3` is right.
  - The root cause is wider than headers. A lend `?B` or `!B` of a branch `B` whose leaves are write-view places, or a path through one (`?(a if c else b).e`), is accepted anywhere, in a statement or a call argument (Critical, C2).
  - The oracle abstains on the bare forms ("a lend of a branching value (Core §3, planned)"), so no gate sees them.
- **What the PR adds is sound as far as it goes.** Every bare path-through-a-branch shape in grid1 is rejected, in all four headers and over every leaf kind; on main, the same programs run. The walk-to-base works through parentheses, `?.`, `??`, `catch`, and depth-2 paths. The "plain-data part is copied" exemption held under every probe (section 2).

---

## Findings

### H1 (High). The oracle no longer stores a call's receiver lend in another `!` argument, which disarms the reference checker

**The change:** in `test/oracle/flow.zig`, `transfer` now does this before anything is stored:

```zig
if (op.what == .call) if (op.loan) |own| stored.unset(own);
```

`op.loan` is the activation (write) loan on the receiver. The line removes it from what a call stores into every var: every `gains` var (each `!` argument's root, not only the receiver's), and every `through` target. The comment narrows it to "in what that receiver views", but the code does not. SPEC "Second-class views" says the opposite for other arguments. A call may store in "what its `!` arguments and other write views lead to: a view of each argument, the receiver among them". A write lend ends as the call returns "unless the call may store it".

**Probes:** the compiler rejects every one. On main the oracle rejects them too. At 6931bc9b it accepts them.

| Probe | Shape | old oracle | new oracle |
|---|---|---|---|
| `o01_store_readview_of_self_into_arg` | `sub put(!self, dst: !Vec[?Vec[Int]])` pushes `?self.v`; then `h` is reassigned while `d` holds the view | reject C4 "cannot move `h` while a read loan … carried by `d`" | **accept** |
| `o02_store_writeview_of_self_into_arg` | pushes `!self.v` into `!Vec[!Vec[Int]]` | reject C4 | **accept** |
| `o04_store_readview_bang_receiver` | `!h.put(!d)`, then `!h.v.push(5)` | reject C4 | **accept** |
| `o05_store_slice_of_self` | stores `?self.v[..]`, then grows `h.v` 100 times and reads the slice | reject C4 | **accept** |
| `o06_store_into_struct_arg` | `dst.s = ?self.v[..]` into a `!Slot` | reject C4 | **accept** |
| **in the tree:** `test/reject/ownership/receiver_stored_in_argument_siblings.rig`, `write_receiver` | `!s.putw(!h)`, then `<s` | reject C4 "cannot move `s` … carried by `h`" | **accept** (reported as `stricter`) |

- **Survey:** I ran the oracle over the 948 tree programs that declare a `!self` method taking further parameters, with the main, PR, and narrow-rule oracles.
  - Main to PR: one verdict changed, `write_receiver` above, from reject to accept.
  - Main to the narrow rule: none changed. The narrow rule also silences `a05c`, `a05e` and `a07d`.
- **Why the gates did not notice:** a compiler-rejects / oracle-accepts difference is reported as `stricter`, which does not fail the run. So the oracle sets stay green while the oracle has stopped checking this class.
- **What this means:**
  - The oracle is the hard gate for "prod accepts something unsafe". For a write-receiver call that stores a view of its receiver in another argument, it has gone blind.
  - Any future compiler regression in that class would pass the oracle.
  - The PR's survey reports "No DIFF". That is true, but it missed this lost rejection, which shows up as `stricter`.

**A narrower rule exists** (`tools/oracle-narrow-receiver-own-lend.diff`, built and run in a scratch worktree):
- The rule: leave the call's own receiver loan out only of what is stored in the receiver itself. That is the receiver root's `gain`, and the `through` of the receiver's own view (`recv_view`) and root (`recv_root`).
- Results:
  - `a05c`, `a05e`, `a07d` and `header_branch_read_alternatives.rig`: oracle silent (L1's false positive is fixed).
  - `o01`, `o02`, `o04`, `o05`, `o06`, and all 7 functions of `receiver_stored_in_argument_siblings.rig`: still rejected, as on main.
- **Why the receiver itself is safe to exclude:** a callee cannot store a view of `self` through `self`'s own write views. The compiler rejects `!self.w.push(?self.n)` in the method itself ("cannot lend `self` to write while a read loan is live", `o07`).
- **A better long-term fix:** a precise store signature for built-ins such as `Vec.push`. Today they have no `sig`, so `store_loan` defaults to true. `push` stores its argument in the receiver, never the receiver's own lend, and that is where the false positive comes from.

**Fix before landing:** replace the blanket `unset` with the receiver-only rule, or revert 09b06222 and list `a05c`, `a05e`, `a07d` some other way. Then add `o01`–`o06` to the corpus, so that a future weakening shows as a DIFF on a program the compiler rejects. Better still, add `# oracle: main reject C4` lines, so a lost rejection fails the run.

### C1 (Critical, on main too). A header subject that lends a branch, or a path through one, is not checked by the decider

**The class:** the PR's own class, "a header subject … reaches a place holding a write view through a branch". Here the reach goes through a lend sigil.
- `checkMatch` calls `headerCopiesWriteView(subject)` only for `mode == .read`, and passes the subject with its `?` still on. `pathRoot(?…)` is the `.read` node, which is not branching, so the decider returns null. A `!` subject is `.write` mode and is never asked.
- `checkOptionalBinding` passes `expr` (`?…` or `!…`) unpeeled, too.
- `checkFor` peels `?` (`peeled_source`), and its `!` is a mode with a bare source, so `for` is covered (grid2: all 18 `l_for.*` rejected).

**Results (grid2):** every one of the following is accepted by both 308585bf and 6931bc9b, and is a sanitizer use-after-free.

| Header | Subjects | Leaves |
|---|---|---|
| `match` | `?(a if c else b)`, `!(a if c else b)` | `!E` parameter, local `a = !x` |
| `match` | `?(a if c else b).e`, `!(a if c else b).e`, `?((a if c else b)).e`, `!((…)).e` | `!W` parameter, local, holder field `h1.w` |
| `if … as` | the same forms, with `.o` | the same |
| `while … as` | the same forms, with `.o` | the same |

- **Counts:** 48 programs, all accepted, all use-after-frees.
- **In `--release`:** for example, `l_match.r.path.wparam`, `l_as.w.bare.wparam` and `l_while_as.r.bare.local` print `0` where the right value is `3`.
- **The oracle:**
  - For the `?…path` forms it reports `DIFF prod=accept ref=reject C2 … a bare write view would be copied`, so it would catch them if they were in the tree.
  - For the bare-branch and `!…` forms it abstains: "a lend of a branching value (Core §3, planned)", or "a write lend of a made value". No gate covers them.

**Representative probes:**
- `r06_match_readlend_bare_branch`: `match ?(a if c else b)` with `a`, `b: !E`, then `a = mk(99)`, then reads a slice taken from the arm.
- `r07_match_writelend_bare_branch`: the same with `!`.
- `p08_as_write_plain_part_in_vec`: `if !(a if c else b)[0].o as x` over `!Vec[A3]`. The body grows `a`, then `x = 7` writes freed memory. Release silently loses the write.
- `p09_match_write_branchpart`: `match !(a if c else b)[0].e`, then `r.n = 5` after `a` reallocates.
- `grid1/g_for.meth_gvw.*`: `for x in (!(a if c else b)).gvw()`, a write lend of a branch as a method receiver, in `for`. It is a use-after-free in debug and crashes in `--release`. The same call in a statement (`q02`) or a `match` (`q11`) is rejected by ownership. Only the `for` header loses the loan.

**The fix:**
- The class is "a lend whose operand reaches a write-view place through a branch". The decider's walk should go through `.read` and `.write` (and through a method receiver lent with `!`).
- Better, the lend itself should be rejected. That is C2, and it closes C1 at its root.

### C2 (Critical, on main too, a sibling of C1). `?B` and `!B` of a branch of write-view places, or of a path through one, are accepted anywhere

These are accepted, and are use-after-frees:

| Probe | Form |
|---|---|
| `q08_stmt_readlend_bare_branch` | `t = ?(a if c else b)` |
| `q09_stmt_writelend_bare_branch` | `t = !(a if c else b)` |
| `q10_call_arg_readlend_bare_branch` | `first(?(a if c else b))` |
| `p10_lend_write_branchpart_stmt` | `w = !(a if c else b)[0].o` |
| `p11_lend_read_branchpart_stmt` | `r = ?(a if c else b)[0].v` |

`q03`, `q06` and `q07` (`w = !(a if c else b).v` over `!W` parameters, holder fields, and locals) are two live writers of one place. The oracle reports C4 on them.

- **What CORE says:** `docs/CORE.md` §3 says "A lend of a branching value that may be a name's, `?(a if c else b)`, is *planned*".
- **What prod does:**
  - For owned leaves it rejects ("cannot lend `x if c else y`: it may be `x`, a value a name holds …"; `p12`, `p13`).
  - For leaves that are write-view places it accepts: `lendTemp` and `lendsToWrite` do not fire.
  - For a path through such a branch, `pathHands` calls the path a `.place` ("A path through a view reaches what the view views"), so `isTemporary` is false and neither lend check runs.
- **Why it is Critical:** this violates Rule 2 (accepting a planned form) and Rule 3 (a use-after-free in safe code).
- **The class:** a lend whose operand is a branch, or a path through one, any of whose leaves (`valueLeaves`) is a place holding a write view.
- **Sibling sites to check together:**
  - `lendTemp` / `lendTempIn` (read lends and slices);
  - `lendsToWrite`;
  - a method receiver lent with `!` (`(!(a if c else b)).m()`);
  - header subjects (C1);
  - `pathHands`'s `.place` for a path through a branch of views. Any consumer that trusts `.place` there inherits the hole.

### M1 (Medium). The `hdr.` matrix family has no sigil dimension

`HDR_SHAPES` covers bare subjects only. A sigil dimension (`?S`, `!S`) over the same headers, shapes and leaves would have found C1. grid2's generator (`tools/gen2.py`) is a ready template.

### L1 (Low). Survey wording

The PR says "Oracle: No DIFF … 5 of 5 sets". That is true, but the change also turned a `ref=reject` into `ref=accept` on a tree program (H1) without saying so. A rule that weakens the oracle should come with a survey of the oracle's `prod=reject ref=reject` verdicts before and after, not only its DIFFs.

---

## The questions asked

### 1. Is the walk to the base complete?

| Shape | Result |
|---|---|
| `(a if c else b).e`, `.o`, `.v`; `((…)).e` (nested parentheses); `(h1 if c else h2).w.F`; `o?.F`; `(o ?? !B).F`; `catch` part | rejected in all four headers (the PR's tests and `hdr.`, confirmed by grid1) |
| **`?` or `!` in front of any of these, or of a bare branch** | **accepted, a use-after-free, in `match`, `as` and `while as` (C1)**; rejected in `for` |
| Method-call steps: `(a if c else b).ge()`, `.gv()`, `.go()` (read receiver) | rejected by ownership (the loan is tracked) |
| Method-call steps: `(!(a if c else b)).gew()` in `match` | rejected by ownership |
| **Method-call steps: `(!(a if c else b)).gvw()` in `for`** | **accepted, a use-after-free (C1)** |
| Slices: `?(a if c else b)[0..2]`, `?(a if c else b).v[0..2]` | rejected ("cannot lend `a if c else b`") |
| Slices: `?(a if c else b).v[..]` in a statement (`q04`) | rejected |
| `e?` mid-path: `(a if c else b).o?`, `.q?.e`, `.q?.o?`, `(… .o ?? mk(5))` | rejected ("bind this `E` to a name first", or a header-temporary copy). These run on a different rule, not on the decider |
| `v[(i if c else j)]`, a branch inside an index (`r08`) | accepted, and correct (`1 2 3 4`) |
| Labeled-break, `match`-value and block-`if` bases (`r01`–`r03`) | rejected at the binding: "bare use of write view `a` … would copy" |
| Closures returning a branch, or a lend of a branch part, of captures (`r04`, `r05`) | rejected by ownership |
| Generic `T` (`id(a if c else b).e`) | rejected: "`id[!W]` cannot use `T = !W`" |

### 2. Is "a plain-data part is just copied" a positive list, and correct?

- **Is it a positive list?** Effectively yes. `copies(ty) == .yes` is the positive fact. It is `.no` for anything holding a write view, any owner, any unique value (Cell-holding included) and any handle (`*T` and `~T` move). It is `.depends` for type parameters, which stay checked.
- **What passes the exemption:** plain data, read views, slices and String.
- **Probes:**
  - Read-view parts: `t01` (`for e in (a if c else b).rv`), `t03` (`if (…).ov as v`). Prod rejects the later `!z.push` with "cannot lend `z` to write while a read loan is live". The loan travels through the leaf's held loans.
  - Slice parts: `t02`, rejected the same way.
  - Plain parts: `t06` (`if (…).o as x` of `Int?`), `t08` (`for x in ?(…)[0].arr`), `u02`. They are copied, and print the right values under the sanitizer.
- **One caveat:** the exemption is only sound because the subject is bare. Under `!`, a "plain" part is viewed in place, not copied (`p08`, `p09`). Today that reaches the decider only through C1's gap. If C1 is fixed by peeling `?` and `!` into the decider, the `copies` exemption must not apply to the peeled `!` case (nor to `?` in `match` and `as`, which view in place).

### 3. The oracle change

High: see H1. The rule "a call's own write lend of its receiver ends when the call returns" is false for calls that may store a view of the receiver in another `!` argument. SPEC says such a lend lasts "while what holds it lives".
- **Methods that return a view of `self`:** not affected. The change touches only `stored`, not the result flow; `a05c`'s result is still carried.
- **Closures capturing `self`, and Cell or Signal subscriptions:** not reachable through this path. `op.loan` is set only for write receivers, and an owned closure cannot capture a view (Core s9).

### 4. Over-rejection

- **Programs now rejected** beyond the PR's list: none found.
- **Each rejection has a working alternative** (`u01` runs, sanitizer-clean, in debug and `--release`):
  - `for x in (?a if c else ?b).v`;
  - `if (?a if c else ?b).o as y`;
  - `while (?a if c else ?b).o as y`;
  - `match (?a if c else ?b).e`;
  - `t = (!a if c else !b)`, then `for x in !t.v` and `if !t.o as y`.
- **Plain parts through a branch of write views stay accepted** (`u02`).
- **One non-alternative to note:** `for x in !(!a if c else !b).v` is rejected ("`for x in !xs` writes each element in place; `xs` must be a binding, or a field or element of one"). The named form above is the only way, and it is on main too.
- **Already on main, not this PR:** `t05` and `t07` (`for x in (a if c else b).arr` with `a = !xs[0]`, then `!xs.push`) are rejected by prod and accepted by the oracle (`stricter`).

## Summary for the gate

- **Blockers:**
  - **H1.** Narrow the oracle rule to the receiver itself, or revert it, and add `o01`–`o06` as oracle-checked probes.
  - **C1/C2.** They are on main too, but they are the PR's own class with a lend sigil in front, so the claim that the class is closed is not yet true. Either:
    - extend the fix (reject a lend of a branch, or of a path through one, with a write-view-place leaf, at the lend sites and in the decider), or
    - land #96 with C1/C2 recorded as an open Critical for the next round, with the grid2 programs added as `pending` or `reject` tests once fixed.
- **The PR's own additions:** no other regressions found. In these grids, every program that main accepted and the PR now rejects is in the PR's class. Every probe of the documented alternatives runs clean.
