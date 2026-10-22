# Proposal: a signature that reads an argument without keeping it

Status: design only. Probes ran `bin/rig check` on main's binary, built
before #150 and #152, which change neither origins nor the call rule.
The oracle binary (Oct 10) parses no 0.3 program: no oracle verdict is
claimed.

## 1. The problem

Trig NEEDS 11, reduced:

```rig
obj Parser
  src: ?String
  errors: Int

  sub note(!self, msg: ?String)
    if msg.len > self.src.len
      self.errors += 1

  sub check(!self)
    suggestion = String("did you mean x?")
    !self.note(?suggestion)       # rejected
```

```error
cannot let this call store a view of `suggestion` in `self`: `self` outlives it
```

With a local `p`, `note(!p, ?m)` is accepted but keeps `m` lent while
`p` lives (`<m`: "cannot drop `m` while it is lent"). Without the `src`
field it checks. Trig's lexer (docs/lexer/repros/view-field-store.rig)
hits both directions: `!self.add_to(!out)` and `!c.run(!self)`, with `c`
a local helper and `run(!self, s: !Scanner)` storing nothing.

Cost in Trig: owned `Text` arguments; a builder passed in and back out
(`sb = (!self).scan_escape_sequence_into(flags, <sb)`); Go's separate
`regExpParser` made a field of the scanner (`s.rx`), its methods
functions of the scanner; and helpers (`scan_number_fragment`,
`scan_hex_digits`, `scan_identifier_parts`, the regexp operands)
returning owned Strings where Go returns slices (with Appendix A).

## 2. Today's rule, exactly

- `sema.Origins` (src/sema.zig:1272) holds two parameter masks,
  `result` and `stores`, set per declaration by `computeOrigins` (:5356)
  through `declOrigins` (:5323). `stores` is `defaultOrigins`' (:5307):
  each parameter whose type reaches, past a view, the targets of
  `storeTargets` (:5195), what any write parameter's memory may hold.
  `from` narrows only `result` (:5348); nothing narrows `stores`.
- For `note`: `!self` leads to a `Parser`, which holds a `?String`
  (targets: text bytes), and `msg: ?String` reaches bytes, so `msg` is
  in `stores` whatever the body does.
- The call rule (src/ownership.zig `walkCallBody`): `stored` is the
  receiver (:3950) and each argument in `stores` (:3992), put in what
  the write receiver and arguments lead to (:4025,
  `absorbThroughWrites`); a local's loan stored into a parameter is the
  error above (`absorbLoans`, :4414). A write lend the call may store
  lasts to the statement's end (`endWriteLends`).
- The body check: `recordStore` (:4697) notes each parameter a body
  stores; `checkOrigins` (:4711) rejects one outside `stores` (:4736),
  which with type-derived `stores` fires only on a classifier bug.
- A function value is called with its type's origins.
- Observed: `!p.set_src(text)` where `set_src(!self, s: ?String)` does
  `self.src = s` is accepted with no written `?`: the call keeps the view
  in `p` though CORE sentence 4 says a lend kept in a field is written.

## 3. The options

| | Default for a lent argument | Marker | Sentence 7 | Modular | Migration |
|---|---|---|---|---|---|
| (a) | may be stored, by type (today) | a clause narrows: `keeps none`, `keeps a` | holds | yes | none |
| (b) | not stored | the keeping parameter is named | holds, and tighter | yes | each body that stores a lent parameter |
| (c) | inferred from the body | none | broken | no | none |
| (d) | Rust: a fresh elided lifetime, so not stored | a named lifetime shared with the target | holds | yes | (b)'s |

**(a)** is `from`'s shape, and compatible, but the common case (a
method that reads an argument) needs the annotation, on most `!self`
methods of every struct holding a view, and a newcomer meets the
rejection first. **(b)** leaves the common case unwritten and makes the
rare one visible (a setter says `keeps s`); the existing body check
reports a missing `keeps` in the callee, at the store, with the fix.

**(c)** Rig compiles whole programs, so it could infer, but a caller's
acceptance would then depend on a callee's body, against sentence 7: a
library body edit breaks or admits callers with no signature change. A
call through `?f` would still use the type and disagree with the direct
call; it needs a call-graph fixpoint (today "recursion needs no
fixpoint"); a generic body, walked once with `T` opaque, cannot be
inferred; the oracle must repeat it; and an error points at a call whose
cause is invisible there. It hides an effect (AGENTS rule 4).

**(d)** Rust elides `msg` in `fn note(&mut self, msg: &str)` to a fresh
lifetime unrelated to the struct's `'a`, so the callee cannot store it;
storing needs `msg: &'a str`. That is (b), with a marker naming the
target too. Rust also does it for owned values with lifetimes
(`Token<'_>`); Rig types carry no lifetimes, and a value's loans travel
with it (sentence 6).

**Recommendation: (b)**, for lent parameters only; a value passed by
value is the callee's and keeps today's type rule (pushing a `Token`
holding a `?String` into `self` needs nothing written).

**The case against (b).** It breaks code: each function storing a lent
parameter is rejected until it says `keeps`, a count unknown until the
round's first build. It adds a clause beside `from`. It has two
defaults: a lent parameter is not kept but a by-value one is, and a
declaration keeps what `keeps` names while a function type keeps all its
types allow. `keeps s` names no target, coarser than Rust. It is
post-freeze churn for one consumer. (a) has none of these costs, only
the annotation on the common case, and the surprise.

## 4. The Core change (owner approval needed)

Add to sentence 7, after "of `a` alone.":

> A call keeps only what its signature shows. A value passed to it by
> value is the callee's, which may keep it, and its loans, wherever its
> type fits. A view lent to it (a `?T`, `!T`, `[]T`, `![]T`, `?String`,
> an optional of one, or a `?self` or `!self` receiver) it keeps only
> when the signature names that parameter in `keeps` (`sub watch(!self,
> s: ?String) keeps s`): it may store what the view sees in what its
> write receiver and write arguments lead to, and the loan lasts while
> that holder is used. Any other lend ends when the call returns. A
> function called as a value keeps what its type could hold, since a
> type names no `keeps`. The compiler checks each body against its
> `keeps`. *(planned)*

And, if question 5 is approved, to sentence 4's list of written lends:
"and a lend to a parameter the callee keeps (`!p.watch(?t)`)".

## 5. Desugaring

As for `from`, none new: `f(e1, ..., en)` stays `t1 = e1; ...; tn = en;
f(t1, ..., tn)` (INTERNALS "Call origins"); the write arguments' owners
hold the loans of the `ti` in `stores`, and every other `ti`'s loans end
with the statement. Only the set changes; the checker rule is the call
rule with that set, plus the body check.

## 6. The fact and its classifier

- `Origins.stores` stays one fact, decided once in `declOrigins`, by a
  positive list: (1) a parameter taken by value whose type could hold
  what the write parameters lead to (today's rule, restricted to
  by-value parameters); (2) a parameter `keeps` names.
- "Lent parameter" is one classifier in sema, `sema.lentParam(ty)`: a
  view type or an optional of one. #159 adds a private `isViewType` to
  `src/ownership.zig`; the round moves it to sema and uses it in both
  places rather than adding a third.
- `keeps` names are checked where `from`'s are (:5332-5346): a name that
  is no parameter, a by-value one, one no write parameter could hold, or
  a `keeps` with no write parameter or receiver, is reported.
- `defaultOrigins` is unchanged and serves function types. Resolve
  records the clause (`declared_keeps`, beside `declared_origins`).
- `checkOrigins` (:4736) gains the note "say so: `keeps s`", as `from`
  has "say so: `-> T from a`". An `extern zig` `keeps` is trusted.

## 7. The oracle

`lower.zig` reads `keeps` from the IR as `declaredFrom` (:162) reads
`from`, and `kinds.Reach.stores` (test/oracle/kinds.zig:483) keeps a
lent parameter only when it is named. `flow.zig` gains the body check
beside C6: a store of a lent parameter's loans where the caller reaches
them, when `keeps` does not name it. Function values keep the type rule.

## 8. What stays conservative, and why

Function values keep by type (function-type clauses wait with
function-type `from`, rig-questions E.4; closures already keep no lent
parameter, `storeThroughCapture`). By-value parameters keep by type.
The target is not named (spelling 3 would). Built-in generics' methods
(`all_params`) keep every argument.

## 9. Spellings (the owner decides)

1. A clause, like `from`: `sub watch(!self, s: ?String) keeps s`,
   `fun bind(!self, s: ?String) -> Int keeps s, self`.
2. A word on the parameter: `sub watch(!self, keep s: ?String)`.
3. Naming the target too: `sub watch(!self, s: ?String into self)`.

Recommend 1: one mechanism with `from`, a contextual word as `from` is
(rig.grammar:463-469), naming the receiver `self` as `from self` does.

## 10. Sibling sites and test plan

Sites: `declOrigins`, `checkOrigins`, resolve's clause record, the
`fun`, `sub`, `extern`, and #158's `method` forms (each carries
`origins:origins`), the oracle's `declaredFrom` and `Reach.stores`, and
each std module and example the body check rejects (the migration).

Reject tests: a body storing a lent parameter without `keeps` (with the
note); `keeps` naming no parameter, a by-value one, or one no write
parameter could hold; `keeps` with no write parameter; `<t` after
`!p.watch(?t)` while `p` is used; a call through `?watch` (by type); a
generic `?T` parameter stored without `keeps`. Run tests,
sanitizer-clean: §1's program, view-field-store.rig, a `keeps s` setter,
`keeps self` into a `!` argument, a method from another module. CORE
gets a `rig` and a `rig reject` example. Matrix: the `store.` grid gains
{kept, not kept} per lent parameter kind, into the receiver and into a
`!` argument. Corpus: view-field-store.rig and §1's program.

## 11. Size and order

A small checker round (grammar, resolve, `declOrigins`, `checkOrigins`,
oracle), docs (CORE sentence 7, SPEC "Second-class views", SYNTAX,
INTERNALS "Call origins"), and an unmeasured migration. `stores` is a
fact the ownership checker consumes: the round runs the full matrix.
It waits for #158 (modules), which rewrites the `fun` and `sub` schema
lines and adds the `method` forms the clause rides on; #159, whose
`isViewType` it moves; and #151 (sema, `test/oracle/lower.zig`). It
changes another fact than field loans and may run beside that round;
the second to land passes the full gates on the combined tree.

## Appendix A. `replace` keeps its place lent

```rig
obj Scanner
  text: ?String
  value: String

sub main()
  src = "abc"
  s = Scanner(text: ?src, value: String())
  taken = replace(!s, Scanner(text: "", value: String()))
  _ = replace(!s, <taken)         # cannot lend `s` to write while a read loan is live
  print(s.text)
```

Note: "lent to write here, and kept lent to read by a view that only
reads it". Without `value: String` it checks; so does `<o.s` through a
write view of an optional field.

**Cause.** `walkSwapCall` (src/ownership.zig:4246) gives the result
`carry(ty, first)`, `first` being `!s`'s value, a write loan on `s`.
`carry` keeps a loan on a var whose type owns memory the result could
view (`sema.viewReach` `owned`): `Scanner` owns a String, so by type a
`Scanner`'s `?String` could view `s`'s bytes. As `Scanner` holds only
`?String` views (`holdsViewOnly`), the loan kept is a read loan. So the
result-carry rule (a result holding no write view carries read loans)
explains why it is a read loan, and `carry`'s type-reach, applied as if
the result were a view of the `!` argument, why there is one at all.
Field-precise loans neither explain nor fix it (the place is all of
`s`); `keeps` does not apply (a builtin, and a result is no store).

**Fix.** SPEC already says `replace` "hands back the value that was
there, owned". So `replace(!p, v)` is a take then a store, `t = <p;
p = v`, and its result carries what `p`'s value held, as `walkTake`
(:2738-2747) gives `<p.f`: `varValue(p)`, carried, and no loan on `p`.
Sound because a value never views itself, nor what is moved in. Class:
"a value moved out of a place treated as a view of it"; siblings:
`walkTake` (right), a built-in method's result (`builtinName`: no
receiver lend), `<b.unbox()`, `match <x`. Tests: the program above,
Trig's replace-view.rig (through a `Holder`), a place through a
write-view local, and a reject that the place is write-lent during the
call. A hotfix, independent of both proposals.

The same type-reach also makes a `!self` method returning
`self.text[a..b]` keep all of `self` lent when the scanner owns any
String (checked: a `Scanner` with `value: String` is rejected at
`s.pos += 1` while the slice lives; without it, accepted). That is what
the signature says, so it needs a path in the signature (`from
self.text`), the deferred "path tokens" item, not this fix.

## 12. Questions for the owner

1. Option (b), a lent parameter is kept only when named? Recommend yes.
2. Spelling: `keeps s` clause, `keep s:` on the parameter, or `into`?
   Recommend the `keeps s` clause.
3. By-value parameters keep today's type rule? Recommend yes.
4. Function values keep by type until function types get clauses?
   Recommend yes.
5. Require a written `?` for an argument the callee keeps (sentence 4)?
   Recommend yes, in the same round.
6. Land Appendix A's `replace` fix now, as its own hotfix? Recommend yes.
7. Approve the sentence 7 text of §4? Recommend yes.
