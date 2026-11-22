# Groups, spreads, object update and the shorthand (2026-11-22)

Step 2 of the owner's named options ([docs/design/options.md](../../../../design/options.md),
sections 2, 3, 4, 9 and 11; the decisions are in
[named-options/](../named-options/README.md)): `..net: Net` makes an
object's fields a function's name-only options, `..v` passes a stored
value's fields to the group of its type, `T(x: 3, ..p)` updates an
object, and `name:` before `,` or `)` on its line is `name: name`.
Branch `named-groups`, from main f2529bd91. Plain data only: lifting
that limit is step 3.

## What landed

| Part | Where |
|---|---|
| Grammar: `..name: T` in a parameter list (`group_param`), `..e` among a call's arguments (`spread`), `KWARG_NAME ":"` alone (`(kwarg n n)`), and the rewrite's `field_of` type node; no new LALR conflict | `rig.grammar` |
| Named leaves: a leaf id range (0xC000 to 0xFDFE) whose text is in a process-wide table, so a rewrite writes any field name, declared in any module, at a hidden position homed in the source; `Parser.copyTree`; a name copied from the source is looked up at its home (`SemContext.fileModule`, `useName`) | `src/rig.zig`, `src/sema.zig`, `src/typecheck.zig` |
| The first check: `checkGroups` (an object of plain data, no name twice among the parameters, the groups and their fields, `pub` fields for a `pub` function, 64 parameters at most) records each valid group with its fields and, for a type of the same module, each field's written type; every use of a group's name in its body is recorded, a field read by its node | `src/typecheck.zig` |
| `optionsCall`: a call with a spread, or of a function whose group is as written, is checked only for its spreads (a name or field path, nominal, one per group); a call's spreads are recorded together or not at all, so the second check sees what the first saw. `objectUpdate` for a constructor | `src/typecheck.zig` |
| `Parser.desugarOptions`: a group becomes one parameter per field, `(: f (field_of T f g ftype))`; a field read becomes a leaf that names its parameter (`group_targets`, read by `useName` before any scope); a body that uses the group whole binds it, `net =! Net(timeout: timeout, ...)`; a spread becomes the keyword arguments `f: v.f` where it stands, or `f: f` for a group's own name | `src/rig.zig`, `src/modules.zig` |
| Resolve: `field_of` typed from the written field type or the foreign field's; `GroupParam` on each parameter (symbol and method), `SymbolFlags.group` and `group_field`; field defaults filled once types are resolved (`fillGroupDefaults`); a group counts as an option for the order rule; a unit's keyword never fills a field | `src/resolve.zig`, `src/sema.zig` |
| The second check's messages: a field by position, a field left out, `ms:` for a group's `Duration`, a closure written last, a field named in the body, an assignment to `net.timeout`; a function with a group is not a value (also through its type, and in a generic body), and an API's method takes none | `src/typecheck.zig` |
| Emit: a group field's default from another module, `T()` as `.{}` and `[n of x]` as `@splat(x)` | `src/emit.zig` |
| A group anywhere but a `fun`'s or a `sub`'s parameters is refused by the Parser wrapper; the shorthand at a line's end is refused there too | `src/rig.zig` |
| std.datetime: `Period`, `DateFields`, `ClockFields`, the groups `period` of `Date.add` and `DateTime.add`, and `date` and `clock` of `with`; `DateTime.with`'s body forwards them with spreads | `std/datetime/` |

About 1,200 compiler lines with their comments (rig.zig 346, typecheck
618, resolve 138, sema 83, the rest 34), against the plan's 1.4k to 1.8k.

## How the red team's constraints are met

- **Names no source holds.** The spread's keyword and member names, and
  the flattened parameters' names, are named leaves; each has its own
  hidden position (`hiddenPos`), so facts keyed by position stay apart,
  and its home is the spread or the group, so a diagnostic points there.
  A copied operand leaf is looked up at its home, so a later local of the
  same name never captures it; a field read's leaf names its parameter
  directly.
- **The signature is rewritten in the tree,** one `(:)` node per field
  and a real binding, so ownership's `paramBit(i)`, storage's
  `planHeldHeaders` and emit's parameter walks see the parameters they
  emit. Nothing in ownership, storage or emit changed but `emitDefault`.
- **The first check is quiet and the second carries the span.** A call
  with a spread is not matched in the first check; the second check sees
  keyword arguments whose nodes span the spread. A spread the first check
  refused is not rewritten (none of its call's are), and a group name in
  it is a use of the group whole, so the second check reports the same
  error at the same place.
- **The trailing closure.** A field holds plain data, never a function,
  so the three copies of the rule need nothing; a closure written last
  where only a field is open says so.
- **Field defaults** are filled from the field (`fillGroupDefaults`), in
  the source of the type's module (`DefaultValue.source`).
- **`ParamMask`.** More than 64 parameters with the groups' fields is
  refused at the declaration.
- **The language server** has no signature help and no rename, so there
  is nothing to teach it yet.

## Tests

`test/rig/options-groups.rig.test`, 40 cases: groups by name, required
fields, `code` cases showing a call with defaults filled and a spread as
field reads (`fetch("b", cfg.net.timeout, 9)`), inline options beside
several groups, whole use, a closure capturing the group, a body local
named as a field, every declaration message of section 2 (collisions,
not an object, a view, an owner, `pub`, order, placement, 64), every
call message (unit, position, missing, closure, function value), spreads
(named fields both sides, evaluation order with a write view, forwarding
with a pinned field, a field path through a group, every refusal of
section 3), object update and its refusals, the shorthand (call,
constructor, parameter, refusals, the line rule), methods, a generic
function and a generic type's method, field defaults of each kind, a
group whose type and function are another module's (methods, spreads,
object update, constants, `T()` and `[n of x]` defaults), and datetime's
groups and spreads, with no spread into `round` or a maker; a body's
local, closure parameter, and loop binding taking a field's name. A parse
error after `(` lists no expected tokens now, since `..` makes four
(`syntax-misc`, "habit ampersand view"). The first
check's messages for std.datetime's position errors now name the group
(`std-datetime-checks`). The oracle rejects the shorthand that would move
`buf` (listed in `test/oracle/rejections`); it accepts every other case.

Every `rig pending` block of options.md is an ordinary example. The
error example of the shorthand needed one change to compile at all: a
parameter may not share a module constant's name, so the module constant
`size` is met by a constructor, `Page(size:)`, instead of a call.

## Gates

- **Core suite** (`tools/heavy --class correctness swarm test/rig.rip -w
  4`), on the last compiler commit: 12,575 jobs, none failed, the oracle
  among them.
- **emit-diff** against origin/main f2529bd91 (after a plain `zig build`):
  identical on 37 of 38 programs, 635 files, std's datetime modules
  included; Trig was not compared, since its emit fails with both
  compilers on this Mac (`buildinfo.rig` not generated).
- **Check guard** (`bench/check/guard.py`, interleaved, branch first, four
  rounds each, at a load of 3.5 to 4.0): the branch's fewest instructions
  2,191,993,515, 1.6% above `guard.txt`; origin/main's fewest under the
  same load 2,180,464,958, 1.1% above it. The branch costs about 0.5%
  more instructions than main on the workload, which has no group or
  spread; three of the branch's four runs read 2.0 to 2.1%, so a recount
  on a quiet machine is worth doing before merge. Pass times moved with
  the load, within the gate.
- Trig's and loco's light gates were not run (the catch-up runs them).

After merging origin/main (bbdb95a51, datetime phase 4) and the review's
fixes (9fa05d704): every datetime area green after the merge; the core
suite 12,618 jobs, `cli.exit_teardown` failing under load and passing
alone, and the untracked review's own examples (which the fixes now
refuse) the only other failures; emit-diff identical on 37 of 38 programs
(Trig not compared, as before). The check guard, recounted under
`tools/mac-claim`, three rounds each, branch first, though the machine
stayed at a load of 3.8 to 4.0: the branch's fewest 2,194,685,110, 1.7%
above `guard.txt`; main's fewest 2,167,435,179, 0.5% above it, so the
branch costs about 1.3% more instructions on a workload with no group or
spread. Inside the 2% gate against the committed baseline, but more than
the first reading's 0.5% over main; the likeliest cause is the 16 bytes
`param_groups` adds to every `Symbol` and `Field`, which a side table
would take back. A quiet machine has not been found to confirm it.

## The independent review's fixes

An adversarial review of 8d2ff873d (kept beside the branch, not
committed) found six things; each fix began with a failing case in
`options-groups`, which now holds 47:

1. **High: a group's or an update's type that is not plain itself.** The
   check asked whether each field is plain data, never the type: an
   object with a `drop` body ran its drop twice after `D(..a)`, and a
   `unique` object was copied by `Seed(k: 9, ..a)` and by a group. Both
   now ask `sema.isPlain` of the type, the one meaning of plain, and say
   why ("has a `drop` body", "is `unique`", or the field). These are
   typecheck's refusals, so the oracle, which decides only modules that
   typecheck, compares nothing and `test/oracle/differences` needs no
   entry.
2. **Ownership's messages after a spread** carried the named leaves'
   hidden positions, past the end of the file, once per field. The module
   check now maps each to its home and says it once, so the oracle
   attributes it to its function; the case is in `test/oracle/rejections`.
3. **A field's name and a module-level name.** A group's field no longer
   meets the rule that a parameter shadows no module-level name, and a
   name the body writes looks past the fields to the scopes around
   (`count()` calls the module's `count`); emit names the parameter
   apart.
4. **Messages.** A spread of self, `..@` and `..@net`, is accepted:
   self is a place, and a field of it a field path (options.md says so
   now). A generic object is updated (`Box(n: 2, ..b)`, the instance its
   value is). A group of a generic instance, an assignment to a group
   (which then stays as written, so every check says it), a field by
   position or a keyword that names no parameter beside a spread, and a
   field whose type was invalid are each said as they are.
5. **Another module's private field through a group** is refused at the
   declaration, whatever the function's visibility.
6. **The expected-token list after `(`** is back: `callarg: "an argument"`
   in rig.grammar's `@errors` makes it "expected an argument or `)`".

Left as is: a spread reads through a `*T` or `^T` handle, as any field
read does (the review's note 7).

## Open questions

1. **A body's name that a field has.** The field names do not enter the
   body's scope: a read of `timeout` alone is refused ("read it as
   `net.timeout`"), and a local, a closure's parameter, or a binding may
   take the name, `timeout = 1` binding a local of its own. Default: as
   built.
2. **Messages beyond the doc's.** The doc gives one message for each of
   its examples; the others are worded here (two groups sharing a field,
   a group named as a field, a group of a type that is not an object, an
   owner in a group, a `pub` function's private field, a field left out,
   a closure written last, an optional or a type parameter's spread, a
   callee with no group or several, an update's second spread or a
   positional argument beside it, the shorthand at a line's end).
   Default: as built, the owner's to rename.
3. **std's group names.** `Date.add`'s group is `period`, and `with`'s are
   `date` and `clock`; the names show in messages ("`years` is a field of
   group `period` of `add`"). Default: as built.
