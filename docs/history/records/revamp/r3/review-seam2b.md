# Review: seam2b (`!` lends any value to write), round 1

Branch `seam2b` at f305ab64 (10 commits on main d3504c38, v0.2.2),
built in /Users/shreeve/Data/Code/rig-seam2b (`zig build`, `zig build
oracle`). Probes are in `.git/revamp/r3/probes/review-seam2b/`.
`run.sh` runs each one on the branch under `RIG_SANITIZE=1`, checks it
with rig-v022, and prints the oracle's non-agreeing verdicts. The
differential fuzzers are in `fuzz/`:

- `gen.py` makes 272 programs, 16 temporary heads × 17 write operations.
  Each op runs once on `!HEAD` and once on `tt = HEAD`, and the two
  outputs are compared as multisets. Results: `run3.log`.
- `genctx.py` makes 918 programs, 9 heads × 6 expressions × 17 contexts.
  Results: `runc.log`.

Both fuzzers ran through `bulk.sh`.

## Verdict

**No soundness hole in seam 2's own rule.** I found no accepted program
that corrupts memory, leaks, uses freed memory, or prints a wrong result
because a temporary is lent to write. More than 300 hand probes and
about 1,190 fuzz programs back this up.

The escape check held on every route I tried:

- holders, Cells and closures;
- generic bodies and the generic `idw[T](x: !T)`;
- iterators and `for`;
- `defer` and `errdefer`;
- `!`, `?`, `??` and `catch` propagation;
- returns and loop `break` values;
- `if … as`, `while … as` and `match` headers;
- re-pointing, `swap` and `replace` of view fields;
- parameters;
- stores through a temporary's held write view into a named holder.

v0.2.2's `storeThroughLend` and `viewOnPath` covered every store and
move shape I built. The drop order was right in every form I tried:
assignments (value before index before target), hoisted kwargs,
receivers made before or after their arguments, branching temporaries,
and while steps.

**One new Medium finding: accepted programs whose Zig does not compile.**
These are a `swap` or `replace` of a field of a branching temporary, a
write slice of an array field of one, and a hoisted receiver that is a
part of one. "Accept means correct" is broken, but no memory is touched:
Zig refuses the program. The cause is the emitter's `write_place` flag,
which is set at only some of the sites that emit a write lend.

## Findings

### Medium 1 (new): a field of a branching temporary, lent to write through `swap`, `replace`, a write slice, or a hoisted receiver, emits Zig that does not compile

Probes:

- `zh01_swap_branch_temp.rig`, `zh02_replace_branch_temp.rig`;
- `zh05_swap_forms.rig` (`??`), `zh10_swap_catch.rig` (`catch`);
- `zh09_swap_owning.rig` (a Text field);
- `iso/zh11_4,15,16,18,19.rig` (write slices of an array field);
- `iso/zh11_6.rig` and `zi02_cell_branch_hoist.rig` (hoisted receivers);
- 18 programs in `fuzz/run3.log`, every `{branch,branch2,coal,coal0,catch,catch0}__{swap,replace,replo}`.

```rig
struct S
  n: Int

sub main
  c = f(1) == 1
  k = 3
  swap(!(S(n: 1) if c else S(n: 2)).n, !k)          # zh01
  print(replace(!(S(n: 1) if c else S(n: 2)).n, 7)) # zh02
  sort.sort(!(mk(1) if c else mk(2)).arr[..])       # zh11_4, arr: [3]Int
  !(mk(11) if c else mk(12)).kk.put2(b: f(2), a: f(3))  # zh11_6, hoisted receiver
```

Output on seam2b: a Zig compile error in every form.

- swap: `runtime.zig:177:32: error: expected type '*i64', found '*const i64'`
- replace: `runtime.zig:171:10: error: cannot assign to constant`
- write slice: `runtime.zig:1180:17: error: expected type '[]i64', found '[]const i64'`
- hoisted receiver: `__rig_main.zig: expected type '*K2', found '*const K2'`

rig-v022 rejects every one ("cannot lend a temporary to write"), so
all of them are new. The oracle abstains or agrees: it does not model
emit.

The same writes work in other forms:

- as a plain argument, `inc(!(S(n: 1) if c else S(n: 2)).n)` (zh04);
- on the whole value, `swap(!(…), !s)` and `replace(!(…), v)` (zh06, zh07);
- on an element, `swap(!(arr(1) if c else arr(2))[0], !k)` (zh08);
- on a Vec field's slice (zh11_2, zh11_3);
- with a receiver that is not hoisted (zh11_11, zh11_22);
- when nothing branches, `swap(!mk(1).n, !k)` and `sort.sort(!mk(1).arr[..])`.

**Root cause:** `src/emit.zig`. `emitMemberBase` copies a branching
value into `@as(T, …)`, so that Zig reads it with its Rig type. It skips
that copy only when `self.write_place` is set. That flag is set in only
two places: the `.write` arm when it emits an address, and
`emitMemberBase` when its object is a `.write` node. Three sibling sites
emit a write lend without setting it:

- `emitSwapCall` emits `emitAddressOf(lentPlace(a))`, which strips the
  `!`;
- the `.write` arm's `![]T` path, `emitExpr(ir.Write.operand(sexp))`,
  does not set it;
- `hoistReceiver` emits `lentPlace(receiver)`.

In each case the slot is written through the address of a constant
copy, which Zig rejects. All the failures are compile errors; I found
no form where a mutable copy loses the write silently.

**The class:** "this place is written" is decided at each emit site,
from the syntax that is there, rather than recorded once. That goes
against "one classifier per fact" and "the checker checks exactly what
is emitted". Record it once, for example as a fact on the lent place
that `dropsTemp` already keys, and have `emitMemberBase` read that fact
instead of the flag. Then add zh01, zh02, zh05, zh09, zh10, zh11_4 and
zh11_6 as tests.

### Low 1 (new, precision): a temporary holder with no `drop` body is rejected, while a named one is accepted

`y01_holder_nodrop.rig`, compared with `y02_holder_nodrop_named.rig`:

```rig
struct PR
  r: String
  sub set(!self, r: String)
    self.r = r

!mkpr().set(?mk(1).t)        # y01: rejected
p.set(?s.t)                  # y02: s in an inner block; accepted, runs clean
```

y01 is rejected with "a view of the temporary `mk(1)` is held by
`mkpr()`, a temporary its statement drops after it". The note adds
"`mkpr()` is made before `mk(1)`, so dropped after it". Dropping a `PR`
runs no `drop` body, so the drop never reads the view (Core sentence 6),
and the named form is accepted.

`dropStmtTemps` counts every hidden var as live (`holderLive`), whatever
`sema.dropRunsBody` says. Core §10 says "rules follow the value's type,
never where the value came from". The rejection is sound, but stricter
than the Core, and the note gives a reason that does not apply.

The same over-strictness shows in e14, t05 and n01, where the oracle
accepts ("stricter").

### Low 2 (new, diagnostics): a function called through a module or type is not a head `!` reaches

`mq/main.rig`, `kmod/k02.rig`:

```rig
print(!lib.mk().bump())       # (!lib).mk().bump()
print(!U.make().bump())       # (!U).make().bump()
sete(!E.a(s: "x"))            # (!E).a(...)
```

`!` reaches `lib` or `U`, because `lib.mk` parses as a method callee.
Each line gives two errors that contradict each other: "`mk` is called
through its type or module and has no receiver; drop the `!`", and then
"`bump` changes its receiver …; add `!`: `!(lib.mk()).bump()`".

SYNTAX says `!` reaches "the value a call that is no method call makes".
A module function or an associated constructor is the most natural such
call. The second hint is right; the first should be dropped, or the
parse rule should treat a callee whose object is a module or type as no
method call.

### Low 3 (new, diagnostics): a hint that leads to another rejection

`k03_ifas_through_temp_view.rig`, then `k05_ifas_suggested.rig`. For
`if (!O(o: !b)).o as x`, the error suggests writing
`!(!O(o: !b)).o`. That form is then rejected with "this header binds a
copy of its subject … bind `O(o: !b)` to a name first", which is the
advice that should have come first.

### Low 4 (pre-existing, precision): a call-held receiver inside a branch keeps its loan past the statement

`zq03_meb_cond_named2.rig`, and its temporary forms
`zq01_meb_cond.rig` and `fuzz/runc.log` (`*__meb__cond*`):

```rig
x = !a.me().bump() if c else 0
!a.items.push(1)      # error: use of `a` while a write loan is live (lent at the line above)
```

rig-v022 behaves the same. `x = !a.me().bump()` without the branch is
accepted. Inside a branch, the hidden var that the call holds for the
receiver `a.me()` is not ended (`endCallHeld`), so its write loan
outlives the statement. With a temporary, `x = !mk(1).me().bump() if c
else 0` is rejected with "a view of the temporary `mk(1)` … `mk(1).me()`
still holds it after the statement".

This is sound, but it breaks "leaving a scope never silently forgets a
borrow" in the opposite direction: the scope keeps a loan it should
release.

### Low 5 (pre-existing, precision): `!a.me().me().bump()` is rejected

`zd04_me_me_named.rig` and `zd03_me_me_temp.rig` give "a view of
`a.me()` outlives the call, which holds `a.me()` only while it runs".
rig-v022 gives the same error for the named form; the oracle accepts. A
single `.me()` works.

### Low 6 (oracle gaps): the oracle accepts unsound programs

- **`swap` of view-holding fields.**
  - `zn01_swap_named_oracle.rig` (pre-existing): `swap(!h.w, !g.w)`
    with `g` in an inner block.
  - New temporary instances: `e01`, `t01`, `t04`, `t05` and `t06`, for
    example `swap(!h.w, !P(w: !mk(1).n).w)`.

  The compiler rejects all of them. The oracle accepts ("stricter"), so
  no oracle set would catch a compiler regression in this shape.
- **A made write view as a loop's value.** In `e05_loop_break.rig`,
  `r = while true` / `break !mk(1).at()` / `r += 1` is accepted by the
  oracle and rejected by the compiler. The oracle rejects the same thing
  bound directly (`c02`, `x = !mk(1).at()`), so it treats a loop's
  `break` value as a copy and a binding as a view.

## Claims verified

- **Accepted and correct.** Each of these runs sanitizer-clean, with
  the same output on the temporary as on a named copy (`fuzz/run3.log`:
  254 of 272 OK; the other 18 are Medium 1):
  - the documented forms `!mk().bump()`, `!mk().pop()`,
    `x = !mk().take()`, `!mk().items.push(1)`, `grow(!mk())`,
    `!mk()[..]` and `(!mk()).r = v`;
  - heads that are a call, a constructor, `if`, `??`, `catch` (taken or
    not), an array literal element, a Vec element, a field or array
    field of a temporary, `<s`, a Box, `?` and `!` (in fallible
    functions);
  - ops: `reset` (assigns the whole value), `=`, `+=`, a Text field
    assignment, `.at()`, `swap` and `replace` (on non-branching heads),
    `.me().bump()`, `.t.add`, `take`, `<(!e).o`, `fill`.
- **Contexts** (`runc.log`: 891 of 918 run sanitizer-clean, no Zig
  error). They cover `if`, `else if`, `while` conditions and steps,
  `defer`, closures called several times, conditional values,
  `and`/`or`, `for` bodies and ranges, `match` arms, guards,
  `return … if`, loop `break` values, nested calls, and two temporaries
  in one `print`. The 27 rejections are of two kinds:
  - 9 `break !h.at()`, a write view kept past its statement, which the
    compiler rightly rejects (the oracle accepts; see Low 6);
  - 18 `x = !h.me().bump() if c else 0`, which is Low 4.
- **Drop order:**
  - an assignment's value temporaries are dropped after its target's,
    and the index's between them (a01, a03, `zf01` while steps);
  - kwargs in either order (b01/b02 reject or run as the source order
    implies);
  - hoisted receivers and arguments (i01–i06, v01: no re-evaluation, no
    leak on the `?` path);
  - a receiver made before a holder argument (x04 line 1, x05).
- **Escapes rejected:**
  - c01–c07, c14 (bindings, returns, field stores, re-pointing, Optional
    wrap, `if … as`);
  - e03–e09, e11–e14, n01–n06, t01–t06 (swap and replace of view fields
    and wholes, closures, `Hold[!Int]`, loop break, `match`, `?`,
    `catch`);
  - g01–g07 and k01–k05 (headers: `as`, `while as`, `match`, `for` over
    parts and method views);
  - h01–h08 (stores into a named holder through a temporary's held
    write view, by method, field assignment, push and replace);
  - zc01–zc09 (stores into receivers made by `<h`, an array literal,
    Box, `??`, `catch`, a constructor, a Vec element, `+v`);
  - q01–q03 (write slices kept);
  - x01–x04 (a receiver storing into an argument and the reverse);
  - zg01–zg06 (`match`, `for` and `as` over views a temporary's method
    returns);
  - zm01 (generic `idw`);
  - zo01 (stores into parameters);
  - s01–s02.
- **Through views:**
  - lends of read-view results are rejected (d01–d06);
  - `*T` and `~T` temporaries lent to write and re-assigned run clean
    (d07, k001);
  - `!(!mk())`, `?(!mk())` and `!(?mk())` behave as written (zp01, d05);
  - `!P(w: !a).go(!a)` and `.rd(?a)` / `.rd(a.n)` are rejected
    (d10, d11, za01), so the delayed receiver rule does not reach a
    write view a temporary holds.
- **Constants:** `!none`, `!(5 if c else 6)`, `!Int.max`,
  `!lib.Color.red`, `!lib.LIMIT`, `!(-Int.max)` and `!(Int.max + 0)`
  are rejected. `![3, 1, 2][..]` in a sort, `!(E.a(s: "x"))` and
  `!(f(1) if c else 6)` run (kmod/).
- **Parse:** 50 chain forms, compared with rig-v022 (`parse/forms.txt`).
  - The sigil now reaches the made head in: `!f()[i].m()`,
    `!f().x.m()`, `!f().g()!.h()`, `!f().g()?.h()`, `!(e).m()`,
    `!(a.f(x)).g().h()`, `!Type(n: 1).m()`, `![1, 2][..].m()`,
    `!(f() catch g()).m()`, `!(f() ?? g()).m()`, `!f[T]().m()`,
    `!f(x).g[2](y)`, and inside `+`, `if`, `catch` and `??`.
  - Unchanged: `!a.b().c()`, `!(x)?.m()`, `!f()?.m()`, `!f()!.m()`,
    `!f()(y).m()`, `!a.b(x)(y).g()`, `!x?.f()`, `!-f().m()`, `!+f().m()`,
    `!<f().m()`.
  - The implementer's equivalence run (`logs/seam2b/g.classified`) lists
    no accepted program whose result changed: 56 rej→acc, 101 rej→rej,
    and 5 doc blocks that are new.
  - Newly accepted corpus probes (k001, k002, k007, q003, q004, x032,
    x040, p-lend_temp) print the right values.

## Rounds

This is round 1 of seam2b. Medium 1 is an emit fix in the feature's own
code, not an ownership fix, so it does not count as a soundness round.
Fix its class (one fact for "this place is lent to write" that every
emit site reads) before merging.
