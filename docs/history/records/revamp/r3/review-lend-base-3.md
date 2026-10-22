# Review 3: PR #90 `lend-base`, the redesign (f395daef vs main faceba15)

**Setup.** I built fresh detached worktrees of f395daef and faceba15, each with `zig build` and `zig build oracle`. Every accepted probe ran under `RIG_SANITIZE=1` in debug and `--release`, and through `bin/rig-oracle`. The probes are in `.git/revamp/r3/review-lend-base-3-probes/`:
- `probe.sh` checks a file on both commits, and runs it if head accepts it;
- `hint.py` applies each lend-base hint alone, then reports every error the rewritten program draws, on any line, and runs it when it is clean;
- the probes are grouped by area: `a` wrappers, `b` contexts, `c` hint contexts, `e`/`k`/`t` moved compound bases and branches, `f` function fields, `g` Cells, handles, and Text, `h`/`r` slice and view contexts, `i` error pairs, `j` slice-lend writes, `l` builtin receivers, `m1`-`m4`/`o1` modules, `n` generics, `q` temporaries, `s` a sample of review 2's accepted grid, and `u` odd source shapes.

## Verdict

**The redesign closes the class.** I found:
- no Critical or High finding;
- no accept-means-correct or soundness finding;
- no program that f395daef accepts and faceba15 rejects.

What remains is hint quality and diagnostic wording (two Medium, four Low). None of it lets a wrong program through. It is safe to land. M1 contradicts a sentence in INTERNALS ("Where no rewrite compiles, it gives none"), so fix that sentence or the hints before the tag.

### Why the class is closed

- **The walk sees every path.** `checkModule` runs `checkLendBases(decl, decl)` over every declaration of every module, after typing. It is a plain tree walk over `n.items()`, and it does not depend on which typing routine handled a node.
- **What a base is, is decided by its kind.** `lendOf` → `lendUnder` → `handsOver` is `.lend` only for `read`/`write` nodes (by `shapeOf`), and recurses only through `.move`. Nothing typing-dependent can hide a lend.
- **Only two exits skip the error:**
  - `methods.contains(member)`, a fact `noteMethod` records only when `synthMemberCall` resolves a method;
  - `isCallee and isReceiverSigil`, where the call always reports the moved sigil (`fieldCallSigil`, `misreachedWrite`). I checked `?`, `!` and `<` on field calls, on `ops[i]` calls, and on module and type functions (`f/`, `o1/`). Each is rejected, on both commits.
- **Every other path through `lendBase` ends in `errAt`.** The one exception is a slice lend with no recorded type, which is a kept form anyway.
- **Node ids are unique.** The IR rewrites in `rig.zig` keep each node's id (`List.withId`), and the receiver sigil gets a fresh one. A `methods` key cannot alias a path.

### Contexts confirmed rejected (focus 1)

Each of these is rejected on f395daef. Most are accepted on faceba15.
- module constants and default field values (`b01`, `b02`);
- `defer` and `errdefer` (`b03`, `b14`);
- `test` blocks (`b04`) and `drop` bodies (`b06`);
- `raw` blocks (`b07`);
- match guards (`b08`), `while` headers (`b09`), and `for` ranges and sources (`b15`);
- `break` values, plain and labeled (`b10`, `b13`);
- generic functions, generic struct methods, and generic bodies (`b12`, `n02`, `n05`);
- closures: expression bodies, assignment bodies, and captures (`c25`, `c26`, `q09`);
- imported modules (`m1`-`m4`);
- Cells, shared handles, and Text (`g/`).

### Kept forms run correctly (focus 3)

These kept forms all run correctly in debug and `--release`, sanitizer-clean, with the oracle silent. Each behaves the same on faceba15.
- **Builtin receivers** (`l/`): Vec `push`, `pop`, `insert`, `remove`, `clear`, `get`, `swap`; Text `add`; Cell `set`, `get`, `replace`; weak `upgrade`.
- **Generic receivers** (`n01`, `n06`).
- **Branches as bases** (`k/`). A branch of a lend with:
  - `<w`, or a call that returns `!P`;
  - `<o ?? !p`;
  - a nested branch, or a moved branch;
  - `inc(!…)`, `if !… as`, `<` take, `= none`, a write method, `replace`, a function-field call, and a read slice.
- **Moved compound bases in every emit site** (`e/`, `k2x`, `t01`):
  - `emitMemberBase`, `emitIndexBase`, and the Vec and Text slice bases;
  - function and closure tails, `ptr_tail` views included;
  - closures with captured lends.
- **Slice lends with their writes** (`j/`): `+=`, `inc(!…)`, write receivers, field assignment, `replace`, postfix `if`, `defer`, a closure, `for !`, and a held view of an element. Reads are rejected with a hint that runs.
- **Review 2's grid** (`s/`): every 12th program it accepts, 26 in all. 23 run clean. The other 3 are function-field calls, now rejected as H1 intended.

### Over-rejection (focus 2)

I found no over-rejection. These are all rejected, and correctly so:
- lend of a lend: `(!(!p))`, `(?(?p))`, `((!p))`, and `(<(<(!p)))`;
- a lend of a held view: `(!w).x`;
- a lend of a temporary.

These are kept:
- `+(?p)`;
- `<w` of a held view (`a17`);
- `<(?a[..])`.

---

## Medium

### M1. A hint can still draw a new error, in contexts the reject tests do not cover

`test/hints.py` passes on every reject test, but each program below fails it. Each draws only the lend-base error on f395daef, and its hint, applied, draws a new error. `hint.py` and `test/hints.py` both flag them.

| Probe | Written | Hint | The hint draws |
|---|---|---|---|
| `c02`, `c06` | `own((?p).items)`, `gid((?p).items)`: an owned `Vec` argument, or a generic one | `own(p.items)` | "bare use of `Vec` value `p.items` … a field cannot be moved out" |
| `c03` | `y: Vec[Int] = (?p).items` | `y: Vec[Int] = p.items` | the same |
| `r14` | `ys = [(?p).items, (?p).items]` | `ys = [p.items, p.items]` | the same |
| `c15` | `y = <(!p).items`, a field that is not optional | `y = <p.items` | "cannot move out of `p.items` … partial moves" |
| `r05` | `w: (?Vec[Int])? = (?p).items` | `… = p.items` | "expected `(?Vec[Int])?`, got `Vec[Int]`" (`valueSigil` gives `!` for an optional only when it holds a write view, and otherwise nothing) |
| `h07`, `g16` | `print((?s)[1..3])`, `y = (?s)[1..3]` (Text) | `print(s[1..3])` | "a slice of a Text views it; write `?s[1..3]`" |
| `h11` | `y: ?[]Int = (?arr)[0..2]` | `… = ?arr[0..2]` | "expected `?[]Int`, got `[]Int`" |
| `r01` | `sum((?p).arr)`, with `sum(xs: []Int)` | `sum(p.arr)` | "expected `[]Int`, got `[3]Int`; write `?p.arr`" (`implicitArg` treats a slice parameter as lent implicitly, but an array is not) |
| `c12`, `q09` | `f = \|\| (!mk()).x = 5` | `t = mk()`, then `f = \|\| t.x = 5` | "`t` is a local of the enclosing function; capture it" |
| `q01` | a match arm `1 => (!mk()).x = 5` | `t = mk()` before the arm | "unexpected `=`" (no statement can go there) |

- **faceba15:** the c, r, h and g rows were accepted, or rejected for another reason. For example, base reports the move-out error in `c02` and `c03` directly. The temporary rows were accepted.
- **Expected:**
  - for a non-copy value expected: `+p.items`, or no hint;
  - for an optional view: `?p.items`;
  - for a slice of an array or Text read as a value, or passed: `?path`;
  - for a temporary inside a closure or an arm body: no bind-first hint.
- **Why the suite misses these:** the reject tests do not have these contexts. `test/hints.py` also excuses any error the original drew at that line with the same text. That hides `r05`, and the slice rows below (`h01`-`h05`, `h10`, `h12`, `a14`, `a15`, `a19`, `r10`, `r11`): there the original's slice error already reads "write `?arr[0..2]`", and the hint `y = arr[0..2]` draws it again.
- **Doc claim:** INTERNALS says "Where no rewrite compiles … it gives none." That is not true of these contexts (AGENTS rule 1).

### M2. A sibling error suggests the lend-base form as its fix

These errors were hidden before. Now they are printed beside the lend-base error, and several quote `sourceText` of an expression with a lend base, so their suggested fix is a form this PR rejects. faceba15 printed the same text, but there those forms were accepted. `plainText` exists to avoid this, but only a few messages use it.

| Probe | Written | The other error says |
|---|---|---|
| `a12` | `y = (?p).v.len()` | "`len` is a field: write `(?p).v.len`". The lend-base hint keeps the bad `()`: `y = p.v.len()`. |
| `c24`, `i18` | `y = (?p).o?` | "handle the missing value with `(?p).o ?? fallback`, or `if (?p).o as value`" |
| `r01`, `r02`, `r07`, `r08` | `sum((?p).arr)` | "write `?(?p).arr` or `?(?p).arr[..]`" |
| `r04` | `s: String = (?p).name` | "lend it as a String with `?(?p).name`" |
| `h01`-`h05`, `h10`, `h12` | `y = (?arr)[0..2]` | "write `?arr[0..2]`". The lend-base hint says `y = arr[0..2]`. The two disagree, and only the first is right. |
| `i01`, `i02`, `i03` | `(?p).x = 5` | "take a write view (`!T`) to mutate". Following it gives `(!p).x = 5`, which is rejected. |
| `i16` | `-(?p).items` | "only a binding is dropped with `-x`". The hint `-p.items` draws that same error. |
| `a02` | `(?(!p)).x` | "`!p` here is read … Write `?p`". That gives `(?(?p)).x`, which is still rejected. |

**Expected:** each message names the place with `plainText`, and the lend-base hint is dropped where a sibling error at the same path already gives the fix.

---

## Low

- **L1. An unknown method on a lend is reported as a path's base** (`g14`, `l11`). `(!s).push_str("d")` and `(!arr).sort()` draw two errors:
  - "type has no method …";
  - "`(!arr).sort`: write a lend on the whole path, not its base: `arr.sort()`". Its hint keeps the unknown method.

  The member was never resolved as a method, so it counts as a path. This is harmless, since the program is rejected anyway, but the second error is noise.
- **L2. No hint and no reason** (`i04`, `g05`):
  - `y = <(?p).items`, and `(?k).log[0] = 1` through a `Cell[Vec]`, each draw only "write a lend on the whole path, not its base", with no rewrite;
  - in `i04` the explaining error (a move through a view) belongs to the ownership pass, which does not run after a type error;
  - in `g05` no check objects at all, since `k.log[0] = 1` is valid.

  INTERNALS says that where no rewrite is given, "the path's own check explains". Here none does.
- **L3. Hint text quality:**
  - A path spread over lines is quoted with its newlines (`u05`, `(\n    ?p\n  ).x`).
  - A line over 100 characters gets just the path as its "rewrite" (`u04`). A tool that replaces the line with it, as `test/hints.py` does, produces a statement that does nothing.
  - `((!p)).x` hints `(p).x` (`a04`). It compiles, but the parentheses are left over.
- **L4. The Core.** The rule is not in `docs/CORE.md`. It sits in SYNTAX, which Core §8 counts as syntax, and it has three listed non-cases. AGENTS says "A feature that touches ownership fits it in one paragraph, with no exception list, or changes the Core first". So either list it in Core §8 as a syntax rule, or state why it is not ownership. The rule's motivation includes the written `!` that is only read, which is ownership.

---

## Not this PR's (seen in passing, same on faceba15)

- A diagnostic that prints a branch without parentheses: "bare use of `Vec` value `?p if c else ?q.items`" (`k09`), and "`mk(5) if c else mk(6).s`" (`e13`).
- `?t.ops[1](5)` suggests `?(t.ops(...))`, which drops the `[1]` (`f02`, `f06`).

## Not covered

- I did not rerun the full gates, the 240-cell grid, or the equivalence run. The PR reports those.
- Of review 2's accepted grid I reran a 1-in-12 sample, not all of it.
