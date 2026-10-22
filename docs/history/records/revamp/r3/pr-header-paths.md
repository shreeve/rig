## Summary
This is the follow-up to #94, and fixes the findings of its final review (review-payload-loan-5). Main has every one of them.

A header reads a write view, or a value holding one, out of a place through a branch, and keeps no loan on the place. That copy is a second writer. #94's decider, `sema.headerCopiesWriteView`, missed two shapes:
- **C1, a path through a branch.** The decider fired only when the whole subject was a branch. A field, element or `?.` step reached through one got past it: `(a if c else b).e`, `(a if c else b)[0].e`, `(h1 if c else h2).w`, `o?.w`, `h.o?.w`, `(o ?? g).w`, and a `catch` part. This held in every header: `match`, `if … as`, `while … as` and `for`.
- **C2, `for` never asked the decider.** So review 4's shapes still passed as `for` sources: `for x in (a if c else b)`, `o?`, `o ?? !d` and `(h1.v if c else h2.v)`.

On main, 17 of the review's probes are use-after-frees under the sanitizer. In `--release` they read freed memory: they print `0`, panic on an integer overflow, or crash. Each is now rejected.

| Written (accepted on main, now rejected) | Write instead |
|---|---|
| `match (a if c else b).e`, with `a`, `b` holding write views | lend each leaf: `match (?a if c else ?b).e`, or `t = (!a if c else !b)`, then `match !t.e` |
| `match o?.w` or `(o ?? g).w`, with `o` holding a write view | bind the value inside where it stands: `if o as x` (or `if !o as x`), then match `x.w` |
| `for x in (a if c else b)`, `o?`, `o ?? !d`, or `(h1.v if c else h2.v)` over write views | lend each leaf: `for x in (?a if c else ?b)`, or bind the value inside with `if o as x` |
| a read-only match of a branch of owned holders of write views (`f08`) | `match (?a.w if c else ?b.w)` |

## Round 2: review-header-paths-1
**H1, the oracle (introduced by round 1).** Round 1 dropped a call's own receiver lend from *everything* the call stores, which weakened the reference checker: it stopped rejecting a callee that stores a view of `self` into another `!` argument (`o01`–`o06`). That rule is replaced with the reviewer's narrow one (`tools/oracle-narrow-receiver-own-lend.diff`): the own lend is left out only of what the call stores into the receiver itself. `o01`–`o06` are oracle-checked tests now (`reject/ownership/receiver_view_stored_in_argument.rig`, `# oracle: … reject C4`), and `a05c`, `a05e`, `a07d` stay silent.

**The gate that would have caught H1.** Every function the oracle rejects is listed in `test/oracle/rejections` (3,900-odd lines). `bin/rig-oracle --rejects` fails a set on a rejection not listed (`UNLISTED`) and on a listed function the oracle decides and no longer rejects (`LOST`), whatever the compiler decides. `test/run` and `test/matrix.py --oracle` pass it, and `test/cli/oracle_rejections.sh` checks that both fire. A doc example is listed by the checksum of its text, as its output directory is named, so an edit that only moves it keeps its entry.

**C1 + C2, fixed at the root.** A lend of a branch now lends each branch, by one positive-list rule decided once (`Checker.lendsBranch`, recorded per branch in `branch_lends`). A `?` or `!` whose operand is a branch (`a if c else b`, `??`, `catch`, `e?`, `e!`), or a path of fields, elements, and method receivers from one, is accepted only when every leaf is made there (a call's result, a literal, a constructor), is a constant, is a lend itself, or jumps. Otherwise it is rejected, with the rewrite:

```
cannot lend `a if c else b`: it may be `a`, a value a name holds, which lending the branching value would copy; lend each branch: `?a if c else ?b`
```

A path keeps its lend (`!(!a if c else !b)[0].o`), a slice lends each branch's elements (`(?a if c else ?b)[1..]`), and an unwrap is lent in a header (`if ?o as x`).
- **One rule, not three.** Main had two partial versions: `lendsToWrite` (write lends) and `lendTemp` (read lends of types that move or are write views, by a "named leaf"). Both now ask `lendsBranch`. So does a slice lent (`lendSlice`, also the `for` header's), so no lend routes around it.
- **What it closes.** A plain-data branch under `?` (`?(a if c else b)` of `Int`), a path through a branch (`?(a if c else b)[0].v`, `!(a if c else b).o`), a receiver (`(!(a if c else b)).gvw()`), and a `??` with a place leaf (`?(o ?? !d)`). Every review shape is rejected in every header: `q02`, `q03`, `q08`–`q10`, `p08`–`p13`, `r06`, `r07`. `u01`, `u02`, `r08`, and `t08` stay accepted.
- **Headers strip the sigil the same way.** `checkMatch`, `checkOptionalBinding`, and `checkFor` all pass `headerSubject(subject)` to `sema.headerCopiesWriteView`: the node without its `?`/`!`, and whether it was lent. A lent subject is viewed in place, so its plain parts are no exemption, under `!` above all (the reviewer's caveat).
- **Newly accepted (3), by design:** a lend through a branch of lends, `?(!c if k else !d).a[..]` and its `catch` and `??` forms (corpus `review-lend-base-2-gen-{bw,ca,co}__slice__stmt`). Main rejected them by the "named leaf" test, which counted a lend as a place. They print the right value, sanitizer-clean in debug and `--release`.

**Tests.**
- `reject/ownership/lend_branch_of_places.rig`: 13 errors, each with its rewrite. Main rejects one of them.
- `behavior/ownership/lend_each_branch.rig` (`# release`): the rewrites run.
- The `hdr.` matrix family gains a sigil dimension, bare, `?S`, and `!S`: 156 programs, all rejected.
- Corpus: all 52 probes and both grids (272 files, `review-header-paths-1-*`).
- Two probes the compiler rejects and the oracle accepts are classified `prod-strict` in `test/oracle/differences`: `o07`, which reassigns while the old value holds the view, and `t05`, a loop over a copied plain part.

## Round 1: the class and its fix
- **The class:** a header subject, or the base its path is reached from, is a branching value whose leaf is a place holding a write view.
- **The fix, walk to the base.** `sema.headerCopiesWriteView(ctx, subject)` walks fields, elements and `?.` steps back to the base (`pathRoot`). If that base is a branching form (`a if c else b`, `a ?? b`, `e catch h`, `e!`, `e?`), it applies the same positive leaf test as before: a leaf that is a place, or a part of one, of a type that holds a write view.
  - A path through the branch only matters when the header *views* the part it reaches (`copies` is `.no` or `.depends`). A part of plain data is copied out in the header.
  - Read-only branches over `?W` stay accepted (`d08`), because a read view's type holds no write view.
- **The fix, a third caller.** `checkFor` calls the decider on its source (and on the operand of `?source`), as `checkMatch` and `checkOptionalBinding` already do.
- **The structural unit test** now pins the decider's callers by name: exactly `checkOptionalBinding`, `checkFor` and `checkMatch`. So no header kind can skip it.

Nothing beyond walking to the base and adding the third caller was needed.

## The Lows
- **The Medium.** `match (tg(!a, false) catch |_| b).e` compiled to Zig that failed. It is a `catch` part with a bare write-view leaf, and C1's fix rejects it (`c11`).
- **L1, an oracle false positive.** The oracle rejected `match (!h).gw()`, where `gw(!self) -> !E` returns `!self.w` (`a05c`; on main also `a05e` and `a07d`). Its call model stored the call's *own* write lend of its receiver into what the receiver views: "cannot write `r` while a write loan of it is live, carried by `h`". A call's lend of its receiver ends as it returns (Core s7), so the oracle now leaves that loan out of what a call stores (`test/oracle/flow.zig`, `transfer`). Prod accepts these programs, so they could not be listed in `differences` (a prod-accepts difference always fails the run). All three are now silent, and the oracle sets pass.
- **L2, the branch-of-lends hint.** "bind `(!a if c else !b).e` to a name first" led to a rejected program. It now reads "bind the branch to a name first, `t = (!a if c else !b)`, then match its part with `match !t.e`", which runs (`d02c`).
- **L3, the read-only alternative.** The rejection now names it, by leaf: "lend each leaf, to read with `?h1.w` or to write with `!h1.w`". For a leaf reached through a read view or handle, it says "lend each leaf to read, `?h1.w` (it is reached through a read view, so nothing writes through it)". For an optional leaf, it names `if o as x` and `if !o as x`. The alternative `match (?h1.w if c else ?h2.w)` runs (`f03`).
- **L4, the `.copied` default.** `checkOptionalBinding`'s reach is now a positive list:
  - **`.taken`**, a value made in the header or moved with `<o`, which the binding owns, a write view included. It takes the access its type gives.
  - **`.copied`**, a copy, which only reads: a view is `.read`, plain data is none.
  - **`.written`**, which also covers `!o` with a view inside (`if !o as w` of a `(!P)?`), by `sema.makesWriteView`.

  A copy can no longer fall to `.write`.

  As a result, corpus `review-payload-loan-3-j04` (`if o as x` of a `!((!P)?)` parameter, then `x.t = v`) is rejected in sema as a write through a read binding. Main rejected it in ownership. The same goes for `j05`. Their `test/oracle/differences` entries are gone (FIXED).

## Commits
Round 1:
- d8dc7a6e Reject a header path through a branch that copies a write view, for every header
- 09b06222 Keep a call's own receiver lend out of what it stores, in the oracle (narrowed in round 2)
- aff02b88 Add a matrix family of header subjects that reach a write view through a branch
- 6931bc9b Keep review 5's payload-loan probes in the corpus

Round 2:
- d3005f3c Drop a call's own receiver lend only where it stores into the receiver, in the oracle
- dbf883b4 Fail the oracle sets when a listed oracle rejection is lost
- c7e4294e Lend a branch only where every leaf is made there or a lend, decided once
- c9bc0ad5 Add a bare, read, and write sigil dimension to the hdr matrix family
- d275754e Keep review-header-paths-1's probes and grids in the corpus
- 329fd4f7 Merge main (a7ac9080, with #95)
- cf5fe5e5 List the oracle rejections of the programs main added

## Round 1 tests
- **`reject/ownership/header_path_through_branch.rig`:** 15 errors, every review-5 shape, each with its hint. They are:
  - `match` of `(a if c else b).e`, `(a if c else b)[0].e`, `(h1 if c else h2).w` of owned holders, `o?.w`, `h.o?.w`, `(o ?? g).w`, and a `catch` part;
  - `if … as` and `while … as` of `(a if c else b).o`;
  - `for` over `(a if c else b).v`, `(a if c else b)`, `o?`, `o ?? !d`, and `(h1.v if c else h2.v)`;
  - the branch-of-lends hint.
- **`behavior/ownership/header_branch_read_alternatives.rig`** (`# release`): what stays accepted, sanitizer-clean in debug and `--release`. That is a path through a branch of read views (`d08`), `?h1.w if c else ?h2.w` (`f03`), `if o as x` then `if !o as x` (`f07`), `t = (!a if c else !b)` then `match !t.e` (`d02c`), and `match (!h).gw()` (`a05c`).
- **Updated:** `match_branch_copies_write_view.rig` expects the new hints.
- **Matrix, `hdr.<header>.<shape>.<leaf>`:**
  - **The cells:**
    - headers: `match`, `as`, `while_as`, `for`;
    - subject shapes: a path through a branch at depth 1 (`(A if c else B).F`) and depth 2 (`(h1 if c else h2).w.F`), `o?.F`, `(o ?? !B).F`, and `(tg(!B, false) catch |_| A).F`;
    - leaves: a `!W` parameter, a local `a = !x`, and the field of an owned holder.
  - **The program:** each takes a view of what the header binds, writes through the place the branch read, then reads the view.
  - **The results:** 52 programs, all rejected. Main's compiler fails 24 of them: 12 uses of freed memory, and 12 that fail in Zig.
- **Corpus:** all 99 review-5 probes (`review-payload-loan-5-*`). Three had their layout fixed for the style check (a blank line between declarations, trailing spaces).

## Round 1 survey (against 308585bf)
`test/equiv.py` against 308585bf: 71 of 11,726 programs differ, all in `check` and `facts` only.
- **Emit:** every program both compilers accept emits identical Zig and an identical package.
- **Newly rejected (25):** all are review-5 probes; no program in the tree before them changes verdict.
  - **17 are use-after-frees on main:** `b01`, `b02`, `b03`, `b09`, `b11`, `c03`, `c04`, `c05`, `d03`, `d04`, `d06`, `d07b`, `d10`, `d11`, `h01`, `h02`, `h03`.
  - **One fails in Zig on main:** `c11`.
  - **Seven run on main.** Each holds an unloaned copy of a write view, the class's shape:
    - `b08`, `b09b`, `c09` and `d07` run only because nothing freed what the copy views before it was read;
    - `c08` has a live read view that sees a write (Core sentence 5);
    - `d09` and `f08` are read-only. The table's last row gives `f08`'s alternative; `d09` is its sibling, rejected by the same rule.
- **Rejected on both (46):** the message changed, to the new header or hint text.
- **Oracle:**
  - **No DIFF.**
  - **FIXED:** `j04` and `j05` are now rejected in sema, so their entries were removed.
  - **Gap left as found:** the oracle was silent on `h01`, `h03`, `d06`, `b02`, `b03`, `d03` and `d04`, whose leaf is an optional, or an owned value holding a write view. The compiler now rejects these in sema, where the oracle abstains, so they cannot be listed as differences.

## Verification
Round 2, on pup through `pup-gates.sh` with `GATES_DELTA=1`, at the merge 329fd4f7 (main a7ac9080 included):
- **Suite:** 3,091 passed, 3 pending. The 2 failures were `UNLISTED` oracle rejections of programs main added (`capture_fix_by_type`, `copy_into_generic_param`, `take_hint_where_take_allowed`, and six doc examples). They are listed in cf5fe5e5, and `oracle doc vocab` then passed at cf5fe5e5 (364 passed, 3 pending).
- **Corpus:** 9,502 passed, 0 failed.
- **Matrix:** 7,657 programs, 3,992 rejected, 3,665 ran clean, 0 failed. The `hdr.` family alone has 156 programs, all rejected.
- **Unit:** 135 of 137 passed, 2 skipped.
- **Oracle:** 5 of 5 sets, with the rejections gate.
- **Before the merge,** the same gates passed at d275754e: suite 3,083, corpus 9,502, matrix 7,657 with 0 failed, unit, and `oracle doc vocab` 362.

**equiv against main (a7ac9080):** 300 of 12,010 programs differ, all in `check` and `facts` only. No program both compilers accept emits different Zig or a different package.
- **Newly rejected, 152:** 127 `review-header-paths-1` probes and 25 `review-payload-loan-5` probes, all added on this branch. **Not one program that was in the tree before this branch is newly rejected by the branch-lend rule** (nor by round 1).
- **Newly accepted, 3:** the branch-of-lends slices described above.
- **Rejected on both, 144:** the message changed, to the unified branch-lend message or round 1's header text. That includes CORE's `rig pending` example for `?(a if c else b)`, which is still pending.

## Follow-ups
- **#94's open design decision:** may a view of a write-view binding outlive the binding? This is unchanged.
- **Review 4's M1 and M2:** a `for` over a `Vec[?P]` with a field read, and a generic `|?x|` capture of a `match !g` binding. Both fail in Zig, and both are on main, outside this class.
