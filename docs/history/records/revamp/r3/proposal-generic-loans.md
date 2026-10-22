# Proposal: loans ride on `T`

Status: design for the owner. A throwaway prototype on a scratch branch,
built on #215 (`gtloans`, a12b6c594), produced the census below. It is
not a PR.

## 1. The problem

A generic body is checked once, and today the checker keeps no loan in a
value whose type holds a type parameter. In an instance, though, a `T`
may be a view, so a loan the body cannot see is still real. Three holes
come from this. #215 fixes two of them, `from` through a `T` and a `T`
result beside a view, with a coarse record of which parameters reached a
`T`. The third is still open on main and on #215:

```rig
fun map[T, U](xs: []T, f: ?fun(?T) -> U) -> List[U]
  out: List[U] = List()
  for x in xs
    !out.push(f(?x))     # U may view x, a per-pass copy; out outlives it
  out
```

With `T = P` and `|p| p`, debug prints `0 1 2` and `--release` prints
`3 3 3`. The concrete `[]P` version is rejected today. B's `keeps` does
not catch it, because `out` is a local.

## 2. The rule, as a desugaring

**A generic body is checked as if each type parameter `T` were `?Z`, a
read view of a value of a fresh opaque type `Z` that may own a
resource. `T` is never a write view.** Nothing new is added: every loan
rule already written for read views applies to values of `T`, and the
existing per-instance requirements (plain copies, no view in a Cell)
stay as they are. So:

- **Calls, by origins.** A call's result whose type holds `T` carries the
  loans of the arguments whose types could hold what it views. Any
  argument reaches a `T` result, a `?String` included (oracle rule 2),
  because an instance may view anything. The call stores by its
  `stores`, which is `keeps` for lent parameters (B).
- **Stores, `from`, `keeps`, escapes and scope ends** use the ordinary
  rules, because the loans are now real (oracle rule 1). #215's record
  (`taintGeneric`) and B's generic-store note (`noteGenericStore`,
  `genericStoreIn`) are deleted.
- **Copies.** A copy of a `T` carries what the value holds, never a loan
  on the place it was read from: a value never views itself (oracle
  rule 3). An element of a lent `xs: []T` carries `xs`'s own loans,
  which stand for the caller's.
- **Fresh values.** An operator's result (`a + b`, `-a`, `<`) and a
  built-in read (`b.read[T]`) are new plain values that carry no loan,
  since every instance they allow is a number.
- **Loop elements.** `for x in xs` binds a copy for each pass, and a view
  of it ends with the pass (oracle rule 6).
- **Closures.** A closure call's result carries its captures' loans and
  its arguments', never a loan on the closure itself (oracle rule 5). A
  closure stores only through what it captured to write; a read capture
  of a write view does not count. This matches the oracle, and it also
  lifts today's over-strict `h = |?w, ?f| f(w)` rejection, which exists
  without generics too.
- **Cell, Signal, owned closure.** A loan that rides only on a `T` does
  not block a store there. The instance is checked instead, as SPEC
  already says (oracle rule 4).

**Instances.** For `T = Int`, an owner (`String`), or a handle of plain
data, every loan the body counted for a `T` is extra but harmless. For
`T = ?String`, or an object holding one, it is exactly what the instance
carries. `T` is never `!X` (Core §5).

**One choice for the owner: body or instance.** The model above rejects
some bodies only because some instance could hold a view: `map`, Trig's
5 `for_each_ancestor_directory[R]`, and `do_in_context[T]`. There are
two options:

- **(a) Reject the body.** This matches the oracle's rules 1-6 as they
  stand. It is the simplest, and it breaks the census rows marked (a)
  below.
- **(b) Record a requirement.** Where a violation's loan rides only on a
  value of type `T`, the body records "`T` holds no view here" and each
  instance is checked against it. This is the same machinery as the
  plain-copy and Cell requirements: the error is at the instantiating
  call, with a note at the body line. Trig's real callers return owned
  values or plain data, so they pass, and only an unsound instance
  (`R = ?String` viewing the ancestor path) is rejected. The oracle
  would then have to check instances, which it does not do today.

**Recommendation: (b).** It rejects the unsound instance and keeps the
reusable bodies (`map`, `for_each_ancestor…`, `do_in_context`) as they
are.

## 3. CORE text (owner approval)

Under sentence 6 (loans travel with views), as a new paragraph:

> A generic body is checked once, as if each type parameter `T` were a
> read view of a value of a type of its own, which may own: a value of
> `T` carries the loans of what made it, and a copy of one carries what
> it holds. Where only an instance whose `T` holds a view would break a
> rule, the body requires that the instance's `T` hold none there, and
> each instance is checked against that. *(planned)*

Sentence 7 is unchanged. Its "could hold" already covers a `T` result.
SPEC "Generic bodies" gains the details from §2.

## 4. Rejection census (prototype, option (a); option (b) shown after the arrow)

Option (a) rejects 8 functions in 7 programs (exactly the oracle's 8),
plus Trig's 6 functions. Std has none.

| Program | Why | Rewrite |
|---|---|---|
| examples/sort.rig `map`; examples/generics.rig `Stack.map`; test/behavior/types/generic_closure_args.rig `map`; modules/closure_args_across_modules `lib.map`; corpus R16-inf2, cav-c, syntax-review-ux-rs2 `map`/`fold` | `f(?x)` of a per-pass copy, kept in `out` | `for x in ?xs` + `f(x)` (or `-> List[U] from xs, f`) → (b): accepted; R16-inf2's `\|w\| w` and sort.rig's `\|p\| p.name` instances are rejected at the call |
| Trig tspath `for_each_ancestor_directory[R]` ×5 (path.rig:1063, 1073, rooted_path.rig:756, 771, pathkey.rig:169) | `callback(current)` result `Visit[R]` may view `current`, which is reassigned and returned | (a): the callback takes an owned path, or R gets an owned copy → (b): accepted; `R = ?String` instances rejected |
| Trig parser `do_in_context[T]` (parser.rig:6088) | `f(!self)`'s `T` may view `self` while `self.context_flags` is assigned | (a): pass `context_flags` separately → (b): accepted (T = node id, Bool) |

The prototype also showed false rejections that the rules above already
exclude. The real implementation must not produce them, and its tests
pin each one:

- copy rule 3: an element of a lent `[]T` returned (bytes_generic,
  string_ordering, R15/R16/sb probes, stdlib-g14b);
- fresh values: operators and `read[T]` (generic_fn_viewed_operands);
- the hold of a place read as a `T` argument (R16-m1
  `self.items[i] = f(self.items[i])`);
- `match`/`as` copies of a `T` (hotfix7 p12/p14,
  generic_payload_copy_*);
- the closure rule (generic_closure_* emit tests, never-data k04/k05/
  k09/k10).

Trig: slices' `sort_func[E]` and its 13 helpers (swaps in `![]E`),
`go_compare[V]` and `some[T]` are unaffected.

## 5. What it unlocks

- #215's strictness on f02, f03 and f04 goes away: loans are per value,
  not a record per function.
- B's generic-store approximation is deleted, and `keeps` in generic
  bodies becomes exact.
- The `map` hole closes.

## 6. Compiler and oracle

The oracle (#216) already has rules 1-6. Under (a) they agree as
written. Under (b), the oracle adds the requirement check per instance
(today it abstains on "a generic instance at a view"), or it accepts a
body whose only violations ride on `T` and checks the instances. Grids:
`gen.` gains `map` and `ancestor` (a `Visit[R]` callback) cells, each
with a plain, an owned and a view instance; the oracle and the compiler
must agree on every cell.

## 7. Size and stop rules

The size is one classifier: `ownership.mayCarryLoan` counts a type that
holds `T`. Around it come the copy rule in `carry`, fresh values, the
closure-store rule, and (b)'s requirement kind. It removes #215's and
B's generic records. Estimate: 3-4 days, plus the oracle's half of (b).
It is a classifier round: the full matrix, the corpus, Trig's gate
(18,568 parser inputs and `rig check --tests` on every module), and one
adversarial review. Stop rules: a second soundness round stops it, and
any rejection of a program outside §4 is reported before the rule
changes.

## 3b. CORE text after four reviews (2026-10-14; owner chose (b))

Reviews: soundness, plain English, generics practitioner, Trig porter.
Changes: the model is a join (owner for lend/move/drop, holder of read
views for loans), since "a read view" literally collapses `?x` (CORE §4)
and forbids `!x`; the trigger is mechanical (loans carried by values of
type parameters); the requirement is the broken rule itself, rechecked at
the instance's types (so `map(ids, |i| ?names[i])` passes); it propagates
through nested generic bodies; errors at the instance, note at body line.

> A generic body is checked once, as if each type parameter were a struct
> type of its own that owns a resource and holds read views. So `?x` and
> `!x` lend `x` itself, a value of a type parameter moves and drops as an
> owner does, and it carries loans by sentences 6 and 7. A copy of one
> carries the loans of the views it holds, never a loan on what it was
> copied from. Where a rule breaks only because of loans that values of
> type parameters carry, the body is accepted and records that rule at
> that line. Each instance, including one made inside another generic
> body, is checked against it at its own types; a failure is reported
> where the instance is made, with a note at the body line. *(planned)*

Plus: a `rig pending` block (`map` with `|p| String(p.name)` runs,
`|i| ?names[i]` runs, `|p| p.name` rejected); the Scope note narrowed to
"generics' per-instance checks of operations".
Round follow-ups (not CORE): help text naming both fixes (owned result;
`for x in ?xs` in the body); one "required by" note per wrapper level;
rewrite shipped `map`s to `for x in ?xs`; a nested-generic reject test;
later, `rig check` listing each pub generic's requirements.

## 3c. Final pass (foreman), after owner approval of §3b

> **A generic body is checked once, for every type it may be given.** It
> treats each type parameter as an object of its own that holds an owner
> and read views: `?x` and `!x` lend `x` itself, a value of a type
> parameter moves and drops as an owner does, and it carries loans by
> sentences 6 and 7. A copy of one carries the loans of the views it
> holds, never a loan on what it was copied from. Where a rule breaks
> only because of loans that values of type parameters carry, the body is
> still accepted, and records that rule at that line. Each instance is
> checked against the rule at its own types, and one made inside another
> generic body hands the rule on to that body; a failure is reported
> where the instance is made, with a note at the body line. *(planned)*

Scope note: "generics' per-instance checks" -> "generics' per-instance
checks of operations".
