# Veteran (Rust and Swift ownership): the spread paragraph

## Revised paragraph

**A spread gives an object's fields one by one.** `..v` in a call or a
constructor ([design/options.md](design/options.md)) is one keyword
argument, `f: v.f`, for each field of `v` not named beside it, evaluated
where the spread is written. A field that copies is copied; one that
moves takes the spread's sigil, `<v.f` from `..<v` or `+v.f` from
`..+v`, so `..<v` leaves `v` partly moved, as `<v.f` does, and `..+v`
leaves it whole. A bare `..v` that would give a field that moves is
refused, as `f: v.f` of an owner is, and so is a `..<v` that moves
nothing. A group, `..net: Net` among a function's parameters, is one
parameter per field; the body reads `net` as an object parameter made of
them, and `from net` or `keeps net` stands for those of its fields that
could hold the view. A type whose `drop` body or `unique` mark makes it
more than its fields is never taken apart this way: it is no group, and
no update makes one, not even `..+v`, since an update would move its
fields apart or copy them, and sentence 2 gives such a type no `+`.
*(built)*

```rig
obj Doc
  name: String
  tag: ?String
  pages: Int

sub show(..d: Doc)
  print(d.name, d.tag, d.pages)

sub main()
  d = Doc(name: String("a"), tag: "draft", pages: 1)
  e = Doc(pages: d.name.len + 1, ..<d)
  f = Doc(pages: 9, ..+e)
  g = Doc(name: String("b"), ..f)
  print(e.name, e.pages, f.name, d.tag, d.pages)
  show(pages: 3, ..<g)
```

```output
a 2 a draft 1
b draft 3
```

Optional reject block (both errors come from one run, checked on the
worktree's `bin/rig`):

```rig reject
obj Doc
  name: String
  pages: Int

obj File
  fd: Int

  drop(!@)
    print("close", @fd)

sub main()
  d = Doc(name: String("a"), pages: 1)
  e = Doc(pages: 2, ..d)
  f = File(fd: 1)
  g = File(fd: 2, ..f)
  print(e.pages, g.fd)
```

```error
`..d` gives `name`, a `String`, which owns: write `..<d` to move it, or `..+d` to clone it
`File` has a `drop` body, so no update makes one: an update would take its fields apart or duplicate it, and a `drop` type has no clone (Core sentence 2); move `f` whole and set the field
```

The example ran clean under `RIG_SANITIZE=1` (output as shown); the reject
block gave exactly those two errors.

## Reasons, from where a Rust or Swift programmer stands

1. **"A bare `..v` gives only fields that copy" reads as a filter.** A
   Rust reader, used to `..base` taking whatever is left, reads it as
   "a bare spread quietly gives the plain fields and leaves out the
   owners" (defaulted? dropped?). The fact is a refusal. Saying "is
   refused, as `f: v.f` of an owner is" ties it to a rule the reader
   already holds: a bare place only reads (sentence 1). I checked that
   `Doc(name: d.name, ...)` is refused. "`..<v` gives at least one that
   moves" has the same problem; "so is a `..<v` that moves nothing"
   states the refusal.

2. **Say "partly moved."** Rust's `S { a, ..base }` partially moves
   `base`, and its Copy fields stay usable. Rig does the same, but the
   draft leaves the reader to work it out from the desugaring. One
   clause, "so `..<v` leaves `v` partly moved, as `<v.f` does, and `..+v`
   leaves it whole", uses the term from the paragraph just above and
   answers the first question a Rust reader asks.

3. **"Not named beside it."** In Rust, a named field is never taken from
   the base, and that is why `S { name: new, ..base }` moves nothing when
   only Copy fields are left. "Per field it gives" says this only if you
   already know what "gives" means. "For each field of `v` not named
   beside it" says it outright. Rust also forces `..base` to come last and
   evaluates it last; Rig puts it anywhere and evaluates it in place, so
   "evaluated where the spread is written" stays.

4. **The drop rule is stricter than Rust's, so say how strict.** Rust
   refuses only a move out of a Drop type (E0509): an update that copies
   Copy fields out of one is accepted, and a `Clone` Drop type can be
   cloned. Rig refuses every update, `..+v` included (built, pending the
   owner). "Not even `..+v`" heads off the Rust reader's natural
   workaround. Swift readers need nothing new: a noncopyable type with a
   `deinit` can't be partly consumed either.

5. **The example now shows the cases worth teaching:**
   - a read-view field (`tag`) copied through `..<d` and still usable after;
   - a bare `..f` that is accepted because the owning field is named beside
     it (Rust's override case);
   - a group taking `..<g`.

   The draft's example skipped the group, though the paragraph spends a
   sentence on it. The reject block shows the two refusals a Rust reader
   would not expect. It is optional if the panel wants the paragraph short.

Smaller points: "whose fields those are" becomes "made of them", and "name
those of them" becomes "stands for those of its fields". No fact changes.
