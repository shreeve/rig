# Engineer: "A spread gives an object's fields one by one"

Read on branch `group-owners`, worktree 5f418402d: src/rig.zig
(`expandSpreads`, `flattenGroups`, `readParam`), src/typecheck.zig
(`spreadOperand`, `spreadGiven`, `optionsCall`, `objectUpdate`,
`checkGroups`, `notGroupType`), src/sema.zig (`declaredOrigins`,
`declKeeps`), test/oracle/lower.zig (`namedParams`), and the two test
files. Every probe ran with the worktree's bin/rig in a temp dir.

## Revised paragraph

**A spread gives an object's fields one by one.** `..v`, of a name or a
field path, in a call or a constructor
([design/options.md](design/options.md)), is one keyword argument
`f: v.f` for each field of `v` that no keyword of the call names, in the
order declared, evaluated where the spread is written. A field that
moves, an owner or a handle, takes the spread's sigil, `<v.f` from
`..<v` or `+v.f` from `..+v`; one that copies, plain data or a read
view, is copied. So a bare `..v` that would give an owner is rejected,
as `f: v.f` would be (sentence 1); `..<v` that moves nothing is
rejected; and a spread makes no view, so `..?v` and `..!v` are
rejected. A group, `..net: Net` among a function's parameters, is one
parameter per field; the body reads `net` as it reads an object
parameter `net: Net`, and `from net` and `keeps net` name the group,
standing for those of its fields that could hold the view (a field's
own name is no parameter). A type whose `drop` body or `unique` mark
makes it more than its fields is never taken apart this way: it is no
group's type, and no update makes one, by any sigil, since `..<v` would
take its fields apart, and `..v` or `..+v` would duplicate it, and
sentence 2 gives such a type no `+`. Its fields may be of any type.
*(built)*

Example: the branch's example runs and prints `a 2 a 9 1` (checked).
I would replace it with one that also shows a group, since a group is
half the paragraph and the only place `..+`/`..<` into parameters is
taught (checked, prints exactly this):

```rig
obj Doc
  name: String
  pages: Int

sub show(tag: ?String, ..doc: Doc)
  print(tag, doc.name, doc.pages)

sub main()
  d = Doc(name: String("a"), pages: 1)
  e = Doc(pages: d.name.len + 1, ..<d)
  show("e", ..+e)
  show("f", pages: 9, ..<e)
  print(d.pages)
```

```output
e a 2
f a 9
1
```

and add a rejection (checked, exact text):

```rig reject
obj File
  name: String
  fd: Int

  drop(!@)
    print("close", @name)

sub main()
  f = File(name: String("a.txt"), fd: 3)
  g = File(fd: 4, ..<f)
  print(g.fd)
```

```error
`File` has a `drop` body, so no update makes one
```

(`..<f`, not `..+f`, so the example does not cement the `..+p` point
that waits on the owner.)

## Sentence by sentence against the code

1. **"one keyword argument per field it gives"** - underclaims.
   `spreadGiven` gives only the fields *no keyword of the call names*,
   in declared order (`namesKeyword`). The branch's own example depends
   on it (`pages:` wins over `d.pages`), but the paragraph never says
   which fields "it gives". Tested: options-groups "a spread gives a
   stored value's fields, and named fields win"; options-owners "object
   update moves the owners and copies the rest".
   Operand: `isSpreadPlace` takes a name, `@`, or a field path only (no
   index, no call); "a name or a field path" is exact, "v" alone is not.
   Tested: "a spread passes a value of a group's own type, once, from a
   place" (`bind defaults() to a name first`).
2. **"evaluated where it is written"** - exact. Tested four ways ("a
   spread is read where it is written", "arguments and a spread are
   evaluated in the order written", "a moving spread is read where it
   is written", "a moving spread takes its place before a later write
   view").
3. **"a field that moves takes the spread's sigil ... one that copies
   is copied"** - exact; "moves" is `sema.copies(ty) != .yes`, so it
   covers handles too (`..a` of a `*Box` field: "a `*Box`, a handle";
   `..+a` bumps the count). Naming "an owner or a handle" and "plain
   data or a read view" ties it to §1 and says why read views ride bare.
   (A write view can't be a field at all - probed - so no third case.)
   **Gap:** no test of a handle field in a spread; the "a handle"
   message and `..+` on a `*T` field are untested.
4. **"so a bare `..v` gives only fields that copy and `..<v` gives at
   least one that moves"** - the "so" overclaims: the first follows
   from desugaring (`f: v.f` of an owner is rejected by sentence 1),
   the second does not; it is its own refusal in `spreadGiven`. State
   them as rejections, the first with its reason. Note `..+v` that
   clones nothing is accepted (`.clone => {}`) - consistent with `+x`
   of plain data being a copy; the paragraph rightly says nothing.
5. **`..?v` and `..!v` refused** - the code has it (`spreadOperand`) and
   the paragraph omits it. It belongs in CORE: it is the visible-effects
   rule for the spread sigil (a spread never makes a view). **Gap:**
   `..?n` is tested ("the sigils of a spread"), `..!n` is not; add
   `plain(..!n)` beside it.
6. **"the body reads `net` as an object parameter whose fields those
   are"** - exact, and better said "as it reads an object parameter
   `net: Net`": field reads become the field parameters; a body that
   uses `net` whole binds `net =! Net(f: <f, ...)` at its start and its
   reads then read that binding; immutable; partly moved by `<net.f`;
   `j.name` returned bare is rejected as for an owned parameter. All
   tested ("a group's owner is read in place, as an object parameter's
   field is", "a group used whole is partly moved...", "a body that
   uses an owning group whole binds it", "a group's field is not
   assigned").
7. **"`from net` and `keeps net` name those of them that could hold the
   view"** - ambiguous: reads as if the clauses name fields, the one
   thing the compiler refuses. Code: the group's name stands for its
   field parameters that could hold the result's view (`from`) or that
   are views the function stores (`keeps`); naming a group where none
   qualifies is refused; a field's bare name is refused. Tested: `from`
   none refused, both bare names refused, `from`/`keeps` accepted.
   **Gap:** "`keeps l`: no field of group `l` ... is a view that `put`
   could keep" (probed, works) has no test.
   **Oracle:** `namedParams` treats a group's name as *all* its field
   parameters and also matches a field's bare name. Both are harmless
   (a field that can't hold a view carries no loan; the compiler
   refuses bare names first), but its comment cites this paragraph -
   worth a line saying the oracle over-approximates by design.
8. **drop / unique sentence** - the facts are exact and tested (group:
   both; update: drop with `..+f`, `..<f`, `..f`; unique with `..s`).
   `..<s`/`..+s` of a unique type refused by the same branch (probed),
   untested - cheap to add. **The reason overclaims/misdirects:**
   "an update would move its fields apart or copy them, and sentence 2
   gives such a type no `+`" - but `..+p` does not `+` the type, it
   clones *fields*, which may well have `+`. The real argument (and the
   error's "duplicate it") is that `..+p` or a bare `..p` builds a
   second value of the type, a clone by another road, which sentence 2
   denies; `..<p` takes it apart. My wording says that. This is also
   exactly the pending-owner point (options.md §11 step 3), so the
   sentence should be precise about which sigil gets which reason.
9. **Missing, worth one clause:** the rule binds the *type*, not its
   fields: a group or update whose field is a drop or unique type
   works, the field moving (probed: `Job(f: File)` group and update;
   `Gen(s: Seed)` group). Untested in options-owners; add one.

## Left to options.md (deliberately)

Exactly-the-type matching (a group of `v`'s type, an update of `v`'s
type), one spread per group or update, every other update argument
named, optional and type-variable operands refused, pub/private field
rules, the 64-parameter cap, generic group types refused, closures never
filling a group's field.

## Tests to add (none of these exist)

- `..!n` refused (options-owners "the sigils of a spread").
- A handle field: `..a` refused "a handle", `..+a` shares, `..<a` moves.
- `keeps l` with no view field refused.
- `..<s` and `..+s` of a `unique` type refused.
- A group and an update whose field has a drop body run, dropping once.
