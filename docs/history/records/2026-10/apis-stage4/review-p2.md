# APIs Stage 4, phase 2: adversarial review (2026-10-23)

A review of PR #612 ([phase2-notes.md](phase2-notes.md)) against the
approved CORE text (§4, "An API object hides its value's type, never
its loans"), the panel's holes H1 to H13 ([core-panel/](core-panel/)),
and phase 2's contract: `?{A}` and `!{A}` lend, call through a table,
and every misuse is a Rig error. About 210 probe programs (two of
several modules), each run with `rig check`, then `RIG_SANITIZE=1 rig
run`, and the oracle (`rig-oracle -v`). Each fix has its case; the full
suite is green (10,170 jobs).

## Findings, by severity

### High: accepted, then failed in Zig

1. **A table's names met the module's own.** Every API's table is
   written into its module, and `__rig_table_Shape_of(comptime T,
   comptime W)` declared `T`, `W`, `p`, and a function per method named
   as the method. A module with an API and a `fun area`, a `type T`, a
   `type W`, or a constant `p` failed in Zig ("ambiguous reference",
   "function parameter shadows declaration"), with no object in the
   program: a Stage 3 program that compiled on `main` stopped compiling.
   *Fixed:* `emitApiTable` declares only hidden names (`__rig_T`,
   `__rig_W`, `__rig_p`, `__rig_out`, `__rig_entry_area`). Case "apis
   object a table beside names of the module's own"; the `code` case of
   an entry follows the names.
2. **A `!{A}` lent to read where `?w` is written.** The lend table's
   `read_only` row was recorded only for a bare `w`, so `?w` (an
   argument, a result, inside an optional result, a binding) wrote the
   write view where a `rig.ApiView(..., .read)` goes: "expected type
   ApiView(.read), found ApiView(.write)". Its sibling: a closure's
   `|?w|` capture. *Fixed:* `synthLend` records the `read_only` row for
   `?w` of an object, which emit already lowers as `(w).read()`, and a
   captured read view of a write object is `w.read()`
   (`writeCapturedView`). The oracle modelled a bare `w` handed to a
   `?{A}` field as a copy of a write view (compiler accept, oracle
   reject); it now lends the read view, as a write slice lends its
   elements. Cases "apis object a write view lent to read where it is
   written", "... by a capture and a field".
3. **A copy erased in a branch of one line.** `x = if c` then
   `area_of(p)` (`p: ?Int`), and an `if` as a function's last
   statement, reached emit's internal error "an API object's copy
   without its slot": a one-expression branch is written inline, with no
   block to declare the copy's slot. *Fixed:* `emitYieldBlock` inlines
   no branch that erases a copy (`hasErasedCopies`). Case "apis object
   of a copy in a branch of one line".

### Medium

4. **An object in a field printed without `Print`.** `objectUnprinted`
   walked wrappers and type arguments but no `obj`'s fields, so
   `print(Pair(s: ?sq, n: 1))` with `s: ?{Shape}` printed the hidden
   value through the table's print entry, against H13. *Fixed:* the walk
   goes through fields and payloads, in any module, skipping a type that
   prints itself (`sub print(?@, out: !Printer)`). Case "apis object
   printed through a field".

## The builder's decisions

1. **Two Zig types for the views:** sound (no const cast away), but each
   place a `!{A}` becomes a `?{A}` must say so; findings 2 and its
   sibling were two such places. Every lend site now goes through the
   `read_only` row, and the capture is the one place that does not;
   probed after the fix: arguments, results, bindings, optional results,
   `if` and `match` values, receivers, generic arguments, List pushes,
   fields, captures.
2. **A print entry in every table:** right, with finding 4 closing the
   check that guards it.
3. **A fallible entry always takes the slot:** sound; sets with fields
   (a `String` among them) through `!`, `catch |e|`, by name, in a loop,
   under `defer`, and `T!`, each clean under the sanitizer; a `match`
   missing an arm is rejected.
4. **`<@` entries wait for boxes:** right; a `<@` call through a view is
   rejected as for any view.
5. **The alignment check is kept:** right, for the Mac's measured cost.
6. **Brace closure parameters:** the lexer change is confined to
   `skipType`, whose `{` and `}` were error tokens before phase 1; no
   test, example, or Trig source has a brace in a bar list (Trig's
   braces are all in strings and comments), and the lexer's unit tests
   pass.

## The call cost

The 2.5% on pup is the dependent load of the entry from the table. A
cheap, sound recovery: hold a table of one word in the view by value,
`vt: Entries` when `@sizeOf(Entries)` is a word, else `*const Entries`;
the call `s.vt.area(s.ptr)` is written the same, and the object stays
two words, as a `?fun` is. It needs one-method tables to be one word,
so the print entry would move to a second table that only an object
whose braces or API name `Print` holds (`__rig_table_Shape` and a
printing one): about 40 lines in emit and the runtime, and a `code`
case. Not built here; worth it if a program calls through one-method
objects in a hot loop.

## Parked

- Low: `?{Shape}!E` reads as `?({Shape}!E)` (written `(?{Shape})!E`),
  as phase 1 parked `?{Shape}?`.
- Low: a `?String` view of a `String` with `add String: Shape` is no
  `?{Shape}` ("a view provides no API"); `area_of(t)` of the `String`
  itself erases.
- Low: a task over a function taking an object, `area_of(s)&` with `s:
  ?{Shape}`, is rejected even as a local task, where `area_of(?h)&`
  checks `h`'s own type; conservative.
- Low: the self of a `?@` method erased in its body, `fun me(?@) ->
  ?{Shape} from @`, is a copy by kind and cannot leave, as H12 decides.
- Outside this PR: `for i in 0..f.len` of a `*Frozen[List[T]]` fails in
  Zig (`usize` into `i64`), with no object in the program.

## Probed without findings

H1 to H13 as views reach them: a read loan through `?v[0]` against
`!v.push`; a write view's writes seen by the owner (fields, elements,
`^T`, `!^T`, optionals, additions to `Int`, `String`, enums, a generic
type); erasure through boxes, handles, frozen handles, fields of
handles and boxes, and optionals, each with the owner reassigned,
moved, or dropped while the object lives (rejected); the copy in
loops, nested loops, `while`, `break`, `continue`, early `return`,
`defer`, closures, `match` arms, `catch` handlers, `??`, ternaries, and
headers, each rejected where kept past its block; `from @` results
used after a write (rejected), and `from @first` implementations held
to the API's whole self; `keeps` through a write view; two objects of
two APIs on one value, read and write (rejected); supertraits, a
diamond, defaults, additions, by-name calls with sigils; generic bodies
erasing `?T` and `!T`, `T` inferred as `?{Shape}` (sized), as
`{Shape}` (rejected); `Owned`, `Clone`, `Print` in braces checked at
erasure; `==`, `hash`, `Cell`, error fields, owned closures, and tasks
over objects; recursion through the table; another module's API and
its additions; `$size`, `$align`, `$name`. Every accepted program ran
clean under the sanitizer, and the oracle agreed on each, abstaining
only in its existing classes (generic instances at views, methods
through handles).
