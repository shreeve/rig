# Static (text plan, step 1)

Branch `static` (from main a80cc3d2, after seam 3), pushed to origin, no PR. Head a204f003.

## What it is

`Static` is a built-in type: a `String` known to view only bytes that live for
the whole program. Its meaning is a desugaring: **a `String` whose loans are
always empty.** So it is plain data (copies, no drop glue, no `Views` bit), it
has the representation of a `String` (`[]const u8`), and every operation of a
`String` that reads has the same checker arm and the same emitted Zig (`len`,
index, slice, `for`, `==`, `<`, `print`). The loan walk sees a plain value,
which is why a `Cell`, a `Signal`, an owned closure, and a generic body that
stores a `T` there accept it with no new rule.

### The one decider for "where a Static comes from"

Nothing else has the type. The positive list (docs/INTERNALS.md, "Static"):

1. a string literal (`synthLeaf`, `.str`), so a constant made of literals too;
2. a name, field, element or call whose declared type is `Static` or holds one
   (std: `os.env -> Static?`, `os.args -> []Static`);
3. a slice of a `Static` (`synthSlice`: views the same bytes);
4. the join of values that are all `Static` (`unify`: branch, `??`, `catch`,
   `match`/loop value, list literal).

A String that may view a Text (a parameter, `?t[..]`, `text.trim("  a  ")`) is
not one, and **nothing converts a String to a Static.**

### The one conversion

`typecheck.readsAsString` (applied in `meets`): `Static` where a `String` is
read, and `?Static` as `?String`, `Static?` as `String?`, `[]Static` as
`[]String`. It compares types by id, so it is read-only by construction: a
`!Static` is not a `!String`, a place of type `Static` takes only a `Static`.
Joins (`unify`, `??`/`catch` via `joinFallback`) of a Static and a String give
the String; a generic `T` bound by both is the String unless a place that holds
it exactly (`Cell[T]`, `!T`, an array, a handle, a function type) gives the
type (`Bound.held_ty`), in which case that type holds and the other argument is
reported where it is checked. Ordering and `==` read both sides.

### Diagnostics (hints point to a `String` parameter)

- mismatch `Static` <- `String`: "a `Static` is a literal, or text derived only
  from literals, and a `String` may view a `Text`. A parameter or field that
  only reads its text is declared `String`, which takes a `Static` too";
- re-assigning a literal-bound name: "`s` is a `Static`, bound to a literal's
  text ...: declare it `s: String = ...` to hold other text";
- a String parameter stored in a Cell / owned closure: "if it is only passed
  literal text, declare the parameter `Static`, which carries no loan";
- the generic-body instance check says a `Static` carries no loan;
- `(?T?)?` hint fixed: `none` for `?Vec[Int]?` now says "`?Vec[Int]?` is a view
  of an optional, not an optional view (write `(?Vec[Int])?`)" (was the wrong
  `(?Vec[Int]?)?`).

`Static` is a reserved name like `Text`.

## Tests

- `test/behavior/types/static_in_holders.rig` (`# release`): a Static in a
  `*Cell`, a `*Signal`, an owned closure, a struct field, a generic container,
  a generic body storing `T`; prints and compares.
- `test/behavior/types/static_reads_as_string.rig` (`# release`): the
  conversion in every read position.
- `examples/static_status.rig`.
- reject: `ownership/static_needs_literal_text`, `types/static_never_where_written`,
  `types/static_join_is_string`, `types/static_name_reserved`,
  `types/none_for_view_of_optional`; hints added to
  `ownership/text_string_param_in_cell`.
- corpus: 13 probes `test/corpus/static-*.rig` (11 rejected, 2 run clean).
- matrix: a `static` type in every family (7156 programs); the `nest.` family
  (generic body putting `T` inside a Cell/closure) expects Static to run.
- unit: Static is distinct and plain in the type-fact table.
- oracle: a slice of a Static is a copy (`slicesStatic`); 8 new entries in
  `test/oracle/rejections` (6 matrix cells like their `string.` twins, 1 doc, 1
  corpus probe).

## Migration cost (the semantic change you should know about)

A literal is now a `Static`, so an unannotated binding to a literal is a
`Static`: `s = "a"` then `s = other_string` is rejected (hint: `s: String = "a"`);
`c = *Cell("x")` is a `Cell[Static]` (annotate `*Cell[String]` to hold other
text); `<lit` of a literal-bound name is "drops nothing: plain data"; a
`!String` parameter cannot take `!lit`. In the tree: about 40 reject tests'
expected messages say `Static` where a literal's type was `String`; about 25
reject/behavior tests and 6 corpus probes got a `: String` annotation on a
literal-bound name (the corpus probes keep their oracle differences). The
`Cell[String]` + literal route (value-tracked loans) still works; it is not
removed in this step.

Review: one independent adversarial review (about 60 probes, sanitizer on):
no unsound program. It found one spec/code mismatch (`q ?? s` with `q: Static?`
and `s: String` was rejected though the spec says the join is a `String`); fixed
(`joinFallback`) and tested. Conservative rejections it listed, left as is:
`*fun(Static)` for `*fun(String)` (and the result form), and a `*Cell[Static]`
passed where `*Cell[String]` goes.

## Decisions to confirm

1. **Literal bindings infer `Static`** (the semantics report's option A, cost
   #4). The alternative (literal defaults to `String`, `Static` only by
   annotation) would leave the origin dependence. Confirm.
2. **`os.args()` is `[]Static`** as well as `os.env`: it is as static as env,
   though the brief's list named only env.
3. **`@name(T)` stays `String`** (not on the list).
4. **CORE (not edited).** Proposed text:
   - sentence 9, the last clause: "`Cell`, `Signal`, and owned closures hold
     nothing that carries a loan: no view, directly or behind a handle. Text
     they keep is a `Static`, or a `String` the checker can show views no
     `Text`. A `*T` carries the loans of what it holds."
   - §1 kinds table, plain row: "`Int`, `Bool`, `Static`, enums, structs whose
     parts are all plain".
   - sentence 7, the parenthesis: "or of something that lives for the whole
     program (a `Static`, such as a literal; a module constant)".
   - §4: "A `Static` is read as a `String` where the text is only read; it never
     converts where the text can be written, and nothing converts a `String`
     to a `Static`."
5. **Hint text** above (wording is mine).
6. **`@name(T)` with `T` bound to `Static` says `String`**: the names table is
   keyed by the Zig type, and both are `[]const u8` (`@name(Static)` written
   directly says `Static`). Documented in SPEC and tested.
7. **Emit equivalence is not byte-identical for two programs**, both accepted
   by both compilers (see Gates): a `Static` result no longer needs a hidden
   temporary slot (a `Static` cannot view the temporary it was made beside),
   so `rig.keep(...)` is not emitted there.

## Gates (head a204f003, macOS, `cpuq run --cores 2-6 --label rig:static`)

| Gate | Result |
|---|---|
| `./test/run` (includes the `# release` runs and the oracle sets) | 3177 passed, 0 failed, 3 pending (the planned Core rules) |
| `./test/run corpus` | 9950 passed, 0 failed |
| `test/matrix.py` (7156 programs, with the new `static` type) | 3695 ran clean, 3461 rejected, 0 failed |
| `zig build test` (fresh cache) | 137/138, 1 skipped |
| `test/equiv.py` vs a80cc3d2 (parse, normalize, check, facts, sema, storage, emit, pkg over every tracked program and doc block) | emit and pkg identical for every program both accept except 2: `test/corpus/audit-fuzz-c-f-f00049.rig` and the SPEC generics block (`Wrap(v: 1).with("s")`): a `Static`-typed result drops the hidden temporary slot (class in decision 7). `sema` differs in ~2300 programs (a new built-in type in the type table); `check`/`facts` differ in 186 programs, the ones that name `Static` in a message or type. |

Logs: `.git/revamp/r3/logs/static-mac.*`. Not run: the Linux/pup gates and the
`--release` grid beyond the two new `# release` behavior tests (a release
needs the deep gate); one machine-wide mishap: a `pkill -f test/run` I ran to
stop my own gate may have killed another project's (`em:test`) `./test/run`
process, whose wrapper carried on to its next stage.
