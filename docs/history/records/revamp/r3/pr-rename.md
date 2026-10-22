# v0.3.0 renames: `^T`, `List`, `String` / `?String`

Branch `rename` (worktree `../rig-rename`), from main 52de2a57 (after the fold, #107), pushed to
origin, no PR. Head: see the end of this file.

Three decided renames, in one branch, as separate commits: each is a hand commit (the compiler),
then a script commit (`.git/revamp/r3/rename/rewrite.py MODE apply`, re-runnable), then a hand
commit (what the script cannot decide: tests that nested holdings, docs prose, oracle lists).
The commit order is box, list, string, docs.

## What the plan decided (and where)

`rig-questions.md`: "Box -> `^T`", "^T design study", "Heap-sigil stacking (DECIDED)", "Text plan"
step 3, "Names (DECIDED 2026-10-06)": `Vec` -> `List`; `Text` -> `String`, `String` -> `?String`.

## Migration table (v0.3.0)

Rewritten by the script in every `.rig` file, doc example, test script program, and Zig test
program; by hand where it says so.

### Box

| Before | After | Note |
|---|---|---|
| `Box[T]` | `^T` | an owning kind: one owner, `+b` copies the value into a new box |
| `Box(Node(...))` | `^Node(...)` | |
| `Box(x)` of an owner | `^<x` | |
| `Box(x)` of plain data | `^x` | copies the data into a box |
| `Box[T]?` | `^T?` | the sigil binds tighter than a suffix |
| `Box[T?]` | `^(T?)` | |
| `Box[?T]`, `Box[?T]?` | `^?T`, `(^?T)?` | a box that holds a read view |
| `Vec[Box[T]]`, `[N]Box[T]`, `?Box[T]`, `!Box[T]` | `List[^T]`, `[N]^T`, `?^T`, `!^T` | |
| `Box[Box[T]]`, `Box[*T]`, `*Box[T]`, `Box[~T]`, `**T` | rejected | `^^T`, `^*T`, `*^T`, `^~T`, `**T`: a value is held one way on the heap; checked in type resolution (written types, aliases, generic instances' fields, generic calls' signatures) |
| `Box[fun ...]` | rejected | `^fun` is reserved for a future uniquely owned closure |
| `Box(none)` | rejected | `^none` boxes nothing |
| `type B = Box[Int]`, `B(5)` | `type B = ^Int`, `^5` | an alias of a box is not a constructor |
| `<b.unbox()` | `<b.unbox()` | unchanged |
| the name `Box` | unbound, with a hint | a program may declare its own `Box` |

### List

| Before | After |
|---|---|
| `Vec[T]`, `Vec()`, `Vec[Int]()` | `List[T]`, `List()`, `List[Int]()` |
| `Cell[Vec[T]]` and its members | `Cell[List[T]]` |
| `@name(Vec[Int])` | `"List[Int]"` |
| a program's own type named `List` | collides with the built-in; the tests' became `Chain` |
| the name `Vec` | unbound, with a hint |

### String

| Before | After | Note |
|---|---|---|
| `Text` (the owned text) | `String` | |
| `Text(a, b)`, `Text()` | `String(a, b)`, `String()` | |
| `Text?`, `*Text`, `^Text`, `List[Text]` | `String?`, `*String`, `^String`, `List[String]` | |
| `!Text` | `!String` | the write view of an owner |
| `String` (the read view) | `?String` | `fun f(s: String)` is `fun f(s: ?String)` |
| `String?`, `String!` | `(?String)?`, `(?String)!` | a view takes parentheses before a suffix |
| `[]String`, `List[String]`, `Cell[String]` | `[]?String`, `List[?String]`, `Cell[?String]` | |
| `?Text`, `?String` | `?String` | one type |
| `!String` (was rejected) | `!?String` is rejected | `!String` now writes an owner |
| `Static` | `Static` | unchanged: the static subset of `?String` |
| `@name(String)` (the view) | `"?String"` | `@name(Text)` is `"String"` |
| the name `Text` | unbound, with a hint | |
| the old `String` annotation | no hint can say it | an owner is expected; the mismatch says "a `String` owns its text: write `String(...)` to copy it, or declare the place `?String` to only read it" |
| `std.text` functions | `?String` parameters and results | the module keeps its name |

### Constructors: how to build text, lists, and boxes

| To make | 0.2 | 0.3.0 |
|---|---|---|
| an empty text | `Text()` | `String()` |
| text from values (as `print` writes them) | `Text("n=", 42)` | `String("n=", 42)` |
| a copy of a read view | `Text(s)`, `+s` | `String(s)`, `+s` (a `?String` makes a new `String`) |
| append | `!t.add(a, b)`, `!t.push(b)`, `!t.clear()` | unchanged, on a `String` |
| a read view of text | `?t`, `?t[a..b]`, a literal | unchanged; the type is `?String` (a literal is a `Static`, which reads as a `?String`) |
| an empty list | `Vec()`, `Vec[Int]()` | `List()`, `List[Int]()` |
| list members | `push`, `pop`, `get`, `insert`, `remove`, `clear`, `len`, `[i]` | unchanged |
| a box of a new value | `Box(Node(...))` | `^Node(...)` |
| a box of an owner | `Box(<x)` | `^<x` |
| a box of plain data | `Box(5)` | `^5` |
| a box holding a view | `Box(?v)` | `^?v` |
| an optional box | `Box[T]?`, `none` | `^T?`, `none` |
| a box of an optional | `Box(none)` with `Box[T?]` | `x: ^(T?) = ^none` |
| the value back out | `<b.unbox()` | `<b.unbox()` |

### Standard library

`std.text` keeps its module name and function names; every `String` parameter or result is now
`?String`, and an optional one is `(?String)?`: `contains`, `starts_with`, `ends_with`, `find`,
`find_last`, `count`, `compare`, `parse_int`, `parse_float`, `parse_bool` (parameters);
`trim`, `trim_start`, `trim_end` (`?String` results); `strip_prefix`, `strip_suffix`
(`(?String)?` results); `cut` (a `Cut` with `?String` fields `before` and `after`); `split`,
`lines`, `words` (iterators whose `next` gives `(?String)?`). `std.os.args()` is `[]Static` and
`std.os.env(name: ?String)` is `Static?`. `std.sort` and `std.slices` take `List` where they took
`Vec`. No function was renamed.

### `@name`, facts, and diagnostics

| Before | After |
|---|---|
| `@name(Vec[Int])` | `"List[Int]"` |
| `@name(Box[Int])`, `Box[Int]?` | `"^Int"`, `"^Int?"` (a box of a view is `^?Int`, an optional one `(^?Int)?`) |
| `@name(Text)` | `"String"` |
| `@name(String)` (the view) | `"?String"` (also for a type parameter bound to a `Static`) |
| `--facts` types and diagnostics that print a type | the same names: `List[Int]`, `^Node`, `String`, `?String`, `(?String)?` |
| "bare use of `Box` value" | the type is printed: `` `b` owns a `^S` `` |
| "into a shared box" | "into a counted handle" (`box` means `^T` only) |
| "`String` cannot be written" | "`!?String` cannot be written" |
| emitted Zig | `rig.List`, `rig.String`; the box stays `rig.Box` |

## The migration tool

`tools/migrate-0.3.py` migrates a directory of 0.2 programs:

```
tools/migrate-0.3.py scan  DIR     what would change
tools/migrate-0.3.py apply DIR     rewrite every .rig file under DIR
```

It applies the three renames to each file (box, then list, then string), prints a line for each
thing it cannot decide (`MANUAL path:line: why`) and a summary, and is idempotent: it records what
it wrote, with a hash, in `DIR/.rig-migrated-0.3` and skips a file that still has that hash.
It cannot decide a `!String` (a 0.2 write view of text, which 0.3.0 cannot write), a
`Box[T](...)` that names its type argument, or a `Box(name: ...)` of a type of your own; a type of
yours named `List` becomes `Chain`. It rewrites no prose and no strings. A program it leaves
as written is checked by the compiler: the retired names `Box`, `Vec`, and `Text` are unbound
with a hint, and an old `String` annotation that expected a read view draws "a `String` owns its
text: write `String(...)` to copy it, or declare the place `?String` to only read it".
`test/cli/migrate_tool.sh` runs it on a 0.2 program and runs the result.

## Decisions made

- **`^T`.** An owning kind, held like a handle (CORE §1). `^Node(...)`, `^<x`, `^x`. The grammar adds
  the prefix `^` (expression and type) and `^?T`, a box of a read view (seam 3 needs one; `^!T`
  stays unwritable). `^ x` detached is a lexer error, as `* x` is.
- **Stacking** (`^^T`, `^*T`, `*^T`, `^~T`, `**T`) is rejected in type resolution (`sema.heapStacked`):
  written types, aliases, type arguments in expressions, `^x`/`*x` of a held value, the fields and
  methods of an instance of a generic type (at the written instance and at instances reached
  through generic bodies), and a generic call's signature. A type local to a generic body is not
  checked, and a generic body cannot reach through a `T` anyway. `*~T` is left allowed.
- **`^fun`** is rejected and reserved; `^|..|` is "a box, not a closure"; `^none` boxes nothing;
  an alias of a box is not a constructor.
- **`Box`** is no longer a name: unbound with a hint, and not reserved (a program may declare its
  own `Box`). `Vec` and `Text` are unbound with hints. The design proposed keeping `Box` reserved
  for a release; with the name unregistered there is nothing to reserve, so a program of the
  old form fails at its first use with the hint.
- **`Static`** keeps its name and is the static subset of `?String` (SPEC, CORE, INTERNALS reworded);
  it reads as a `?String` exactly where it did.
- **`List`** collided with programs' own types named `List` (16 test files): the script renames
  those `Chain`.
- **`String`** as a user type name is reserved as `Text` was (probe `p-s` was accepted before).
- **The `*` allocation sink** says "counted handle", not "shared box", so `box` means `^T`.
- **A teaching rule** in WELCOME and SPEC: names say what a value is, sigils say how you hold it.
- **Hints**: a `String` expected where a `?String` or `Static` is given says how to copy or read.
  The `(?T?)?` hint prints `(?String)?`. `string` and `str` (lower case) get the text hint.

## Tests that nested holdings

Removed or cut to one holding, because the form is rejected now (each keeps its reject test in
`reject/types/heap_stacked_*`): `box_of_handle_write` (deleted), `box_of_handle_access`,
`box_members_compose`, `box_edge_cases`, `box_holds_read_view`, `box_of_values`,
`generic_holds_owned_closure`, `weak_in_box_upgrade(_hint)`, `alias_constructs_any_type`,
`guarded_view_subject_cell`, `text_handle_slice`, `lend_table_rows`,
`print_reads_cell_places_after_later_args`, `box_member_loans`, `lend_table_loans`,
`text_handle_slice_keeps_handle`, and the 22 `boxbox` matrix cells. Corpus probes that nest boxes
are rejected now (24).

## Gates (macOS, `cpuq run`, `-j "$CPUQ_CORES"`; no waiters, so no pup)

| Gate | Result at the head |
|---|---|
| `./test/run` | 3200 passed, 0 failed, 3 pending (the planned Core rules) |
| `./test/run corpus` | 10032 passed, 0 failed |
| `test/matrix.py` | 7152 programs: 3638 ran clean, 3514 rejected, 0 failed (22 `boxbox` cells fewer than main) |
| `zig build test --cache-dir "$(mktemp -d)"` | pass |
| `./test/run oracle` | five sets pass (lists remapped by `remap_oracle.py`; `R16-rs5` listed; `box.recv_view_then_write.ctor` no longer rejected by the oracle) |
| new tests | `behavior/types/box_caret_forms`, `box_of_view_signature`, `string_owned_and_view`, `syntax/caret_xor_and_box`; `reject/types/heap_stacked_{types,alias,generic,values}`, `box_function`, `box_none`, `{box,list,string}_retired_name`, `string_owner_expected`, `syntax/detached_prefix_box(_value)`; `cli/migrate_tool`; unit tests of the printer and `heapStacked` |

Not run: Linux, the `--release` grids beyond the `# release` tests, the deep gate.

## Equivalence (`.git/revamp/r3/rename/compare_rewrite.py all`)

Main's compiler runs each original, the new compiler its rewrite (12582 programs and doc blocks:
every tracked `.rig` entry program and every doc block). Emitted root module and package must be
identical, with `rig/runtime.zig` read as a diff (below), `rig.List`, `rig.String`, `.listPush` ...
mapped back, and the comments of `std/*.zig` ignored. A pair both reject must give the old messages
rewritten.

| Result | Programs | Why |
|---|---|---|
| identical Zig, package, or messages | 12444 | |
| emit differs, test edited by hand | 14 | the nested-holding tests above |
| emit differs, `@name` table | 1 | the table lists `?String`, not `Box`; strings read `List[Int]` |
| emit differs, names | 12 | a type the script called `List` is `Chain`; a local called `Vec` or `Text` is `List` or `String` |
| emit differs, `const` | 2 | `Option[?String].none`: the type argument is a read sigil, which `isZigComptimeIn` treats as run-time, so the binding is `const` and not `var` with `_ = &x` |
| both reject, order | 2 | the same messages in another order (hash order of the renamed generic names) |
| both reject, messages differ | 79 | 26 stacking; 17 programs that wrote the 0.2 `!String`; 9 that declared their own `Box`; 6 "shared box" wording; the rest hints (`string`, `vec`, `Box` through a module), one fewer duplicate cell-holder message when a box is written `^`, and a box of a write view now rejected |
| accepts -> rejects | 28 | 24 stacking or `^fun`, 1 box of a write view (`Box(f() catch ..)` of a `!Int`, which a written type never allowed), 1 `struct String` of a program (reserved now) ... |
| rejects -> accepts | 2 | the `Box` reserved-name probes |

The matrix agrees too: its 7152 programs give the same accept or reject as main's, by cell
(`vec` cells are `list`), and the stacked `boxbox` cells are gone.

`rig/runtime.zig` differs only by the renames (`Vec`/`List`, `Text`/`String`, `isString` is
`isStringView`, `isText` is `isString`, the `vec*` members are `list*`) and the type-name rules:
a box is named by its shape as a handle is, and a view takes parentheses before a suffix.

The three scripts were improved after their commits; run from the commit before each, the final
scripts differ from the committed output in: box, 5 files (a `Box[?T]` followed by a suffix is
`(^?T)?`) and `test/README.md`; list, 4 files (`lib.List`, `List.cons` of a program's own type) and
`test/README.md`; string, `test/matrix.py`. The hand commits after each script carry those edits.

## Decisions to confirm

CORE text (edited in `docs/CORE.md`, marked *(built)*):

1. §1, after the kinds table: "A `^T` is held like a handle and behaves like an owner: one owner,
   moved by `<b`, with `+b` copying its value into a new box."
2. The view row reads "`?T`, `!T`, `[]T`, `![]T`" (the read view of text is `?String`).
3. Sentence 2 gains "`+s` of a `?String` is a new `String`".
4. Sentence 8: "`*<x` moves `x` into a counted handle, and `*S(...)` makes a new value there; `^<x` and
   `^S(...)` put a value alone in a box. A box has one owner and no count: it moves, and `+b` copies
   its value into a new box. A value is held one way on the heap, as `^T`, `*T`, or `~T`, so a
   holding sigil over a held value (`^*T`, `**T`) is rejected."
5. §4, after the lend table: "A `String` lends a `?String`, its bytes, and that is its only read
   view ... A `?String` is a view, so nothing lends a `?String` place to write: assign to it to
   point it at other text, or hold a `String`."
6. The teaching rule (WELCOME, SPEC §2): "Names say what a value is; sigils say how you hold it."
   Every named type is an owner; a view is never a name.

Also: (a) `Box` unbound and not reserved (above); (b) `*~T` and `~*T`-like forms are not stacking;
(c) `^T` forwarding gaps (index, slice, `for`, `==`, arithmetic through a box; `unbox` hiding a
method) are not in this branch (HANDOFF lists them); (d) Nexus mirror: `nexus-sync-rename.diff`
(`rig.grammar` 86968e87ed08a089, `src/rig.zig` 98250f9b148c4378); (e) old `String` annotations get no
name hint, only the type mismatch; (f) a `Static` is not a `String`, and says so with the copy hint.
