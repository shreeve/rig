# Owners and read views in groups and object update (2026-11-22)

Step 3 of the owner's named options ([docs/design/options.md](../../../../design/options.md),
section 3, "Owners and views", and section 11, step 3; the decisions are
in [named-options/](../named-options/README.md)): a group's fields, and an
updated object's, may own and view. Branch `group-owners`, from
`origin/named-groups` at 92202f854 (step 2, PR #1220).

## The Core paragraph

The lift is a desugaring into forms the Core already has (parameters,
keyword arguments, `<p.f`, `+p.f`, constructors), with one choice per
field made by a per-type fact (whether it copies). It fits in one
paragraph, added to CORE §5 after "A field of an owned object moves like
a name", with an example:

> **A spread gives an object's fields one by one.** `..v` in a call or a
> constructor is one keyword argument per field it gives, `f: v.f`,
> evaluated where it is written; a field that moves takes the spread's
> sigil, `<v.f` from `..<v` or `+v.f` from `..+v`, and one that copies is
> copied, so a bare `..v` gives only fields that copy and `..<v` gives at
> least one that moves. A group, `..net: Net` among a function's
> parameters, is one parameter per field; the body reads `net` as an
> object parameter whose fields those are, and `from net` and `keeps net`
> name those of them that could hold the view. A type whose fields are
> not all of it is not taken apart: one with a `drop` body is no group and
> is updated only by `..+v`, and a `unique` one is neither. *(built)*

No other sentence of CORE changes. The last sentence follows two facts
CORE already states: a `drop` body expects every field (§5, so no
partial move and no group, whose fields would drop one by one without the
body), and a `unique` type must not be copied (§1, and a spread that
leaves its source whole copies the fields that copy). `..+v` of a `drop`
type is the owner's decision (section 11): it builds a new value by its
constructor from a clone of each field that moves, which writing the
constructor out does too; it is not `+v`, which such a type has none of.

## What is built

| Part | Where |
|---|---|
| The sigil of a spread, `..<v` and `..+v` (parsed already as `(spread (move v))` and `(spread (clone v))`), and which fields it gives move (`sema.copies` is not `.yes`), recorded on `rig.SpreadSite`; a group's moving fields on `rig.GroupSite` | `src/rig.zig`, `src/typecheck.zig` |
| `spreadGiven`: the fields a spread gives, checked against its sigil, in a call and in an update; `..?v` and `..!v` refused; an update of a `drop` type only by `..+v`, of a `unique` type never; a generic instance's update types its fields at the instance (`updateType`) | `src/typecheck.zig` |
| `notGroupType`: a group's type has no `drop` body and is not `unique`; owners and views pass | `src/typecheck.zig` |
| The rewrite: `<v.f` or `+v.f` for a field that moves, `v.f` for one that copies; a body that uses a group whole binds it with `<` on each moving field, and then its field reads and spreads read the binding (`FlatGroup.bound`) | `src/rig.zig` |
| `from net` and `keeps net`: a group's name stands for those of its fields' parameters that could hold the result's view, or that are views the function may store (`groupFieldsNamed`); a name of no such field is refused | `src/sema.zig` |
| Ownership: a field read the rewrite wrote as its parameter is a field read, not a bare name, so a result does not move it out (`groupFieldRead`); messages name a group's field `net.name` and the fix `from net` or `keeps net` (`paramShown`, `paramList`); a call's recorded parameter names give a group's field by its group (`clauseNames`), for the note on a kept view | `src/ownership.zig`, `src/typecheck.zig` |
| A closure written last skips a group's field: a field may hold a function value, `fun(Int) -> Int`, though never a callable view | `src/typecheck.zig` |

The red team's "parameter bits per written position" was already true
after step 2, which rewrites the signature in the tree: ownership's
`paramBit(i)`, storage's `planHeldHeaders` and emit's parameter walks
see one parameter per field. Nothing in storage or emit changed.

## Decisions taken from the design and the Core

1. **The spelling of a spread that moves or clones** is the one the
   design gives for object update, `..<p` and `..+p`, used for a call's
   spread too: options.md section 3 makes a call's spread and an update
   one rule. `<` and `+` go only on the fields that move; a field that
   copies is copied, plain data and read views alike (`+` of a `?String`
   would make a `String`).
2. **A bare `..v` that would give a moving field is refused**, naming
   the field and both fixes, as `buf: buf` is refused with "write `<buf`".
   A field named beside the spread is never read from it, so a bare spread
   that leaves out every moving field is accepted.
3. **`..<v` that gives no moving field is refused**, as `<p.n` of a field
   that copies is ("it copies, so `<` would leave it as it was"). `..+v`
   that clones nothing is accepted, as `+n` of an `Int` is.
4. **In the body, a group is an object parameter** (options.md section 2,
   "the body sees one value"): `return net.name` of an owner is refused
   ("write `+net.name`"), `<net.name` moves it. Without this, the same
   text would move or be refused depending on whether the body also used
   `net` whole elsewhere.
5. **A `drop` type's update by "a whole move"** is read as moving the
   value whole and setting the field (`e = <d`, `e.name = x`), which the
   refusal of `..<d` says; no new form desugars it.

## Tests

`test/rig/options-owners.rig.test`, the area of this step: owners and
views in a group's fields and defaults (`String()`, `List()`); spreads
with each sigil, from a field path, with named fields both sides; the
emitted call of a moving spread; forwarding with a pinned field (`..<h`
and `..+h`); a field moved out in the body, and refused as a result; a
group used whole beside a field's move (partly moved); spreading a group
the body binds whole; `from` (direct and through the group used whole),
a view outliving its source refused, `from` of a group that holds no
view, the message naming `l.text` and `from l`; `keeps` on a method,
refused without it, and the kept view keeping its place read-only;
object update moving some fields and copying others, `..+p`, and a spread
read where it is written (accepted keyword-first, refused spread-first);
a `drop` type updated by `..+f`; every sigil refusal; group types with a
`drop` body or `unique`; a closure written last beside a group with a
function-valued field, and refused where only that field is open;
evaluation order with a write view and a cloning spread, and a moving
spread before a write view refused; a generic function with an owning
group; another module's owning group (spread, forward, update); and a
call with an owning group spawned as a task, under `seeds: 20`.
`options-groups` keeps its 47 cases, five with their messages now the
step's.

## The oracle

The oracle read `from` and `keeps` names only as parameters, so `from l`
named nothing to it and it refused a function that returns a view of a
group's field. It now reads a group's name as its fields' parameters
(`namedParams` in test/oracle/lower.zig), the Core paragraph's rule; that
widens nothing it accepted before. It then agrees with every rejection
of the new cases, seven listed in `test/oracle/rejections`. One
difference is recorded, a ref-gap in `test/oracle/differences`: the
compiler refuses `j.name` of an owning field as a result, as it refuses
an object parameter's field, where the oracle sees the parameter the
rewrite made of it, a bare name, which a result moves.

## Gates

- **Core suite** (`tools/heavy --class correctness swarm test/rig.rip -w
  4 -q`) on 520a44866: 12,651 jobs, one failure, the oracle's set of
  tests asking for one more rejection to be listed; with it and the three
  more the oracle then named (it reports one at a time), the options
  areas and the oracle pass (319be3c79).
- **emit-diff** against origin/main 47b6e27c9 (#1220 merged), after a
  plain `zig build`: identical on 37 of 38 programs, 635 files; Trig not
  compared, since its emit fails with both compilers on this Mac
  (`buildinfo.rig` not generated), as in step 2.
- **Check guard** (`bench/check/guard.py`, under `tools/mac-claim`,
  interleaved, branch first, four rounds each, at a load of 2.9 to 3.2):
  the branch's fewest 2,173,102,507 instructions, origin/main's
  2,171,566,560, a gap of 0.07%; against `guard.txt` the branch is 0.7%
  above, as main is. The workload has no group or spread, so the cost is
  the new checks' reach on every call and parameter (`groupFieldRead` is
  a test of a leaf's id range, `clauseNames` copies names only for a
  callee with a group).
- Trig's and loco's light gates were not run (the brief keeps this
  build on the Mac).

## Open questions

1. **`from net.name`.** `from net` names every field of the group that
   could hold the view; a path names nothing yet ("`from` names a
   parameter, or a path of self"). Default: as built, `from net` only.
2. **`..+v` of a `unique` type** builds a copy of a type that has no
   `+`; it is refused with every other update of a `unique` type.
   Default: as built.
