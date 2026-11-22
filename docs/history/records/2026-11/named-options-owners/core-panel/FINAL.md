# Final text (coordinator's synthesis of purist, veteran, writer, engineer)

Replaces the branch's paragraph and example in docs/CORE.md §5.

**A spread gives an object's fields one by one.** `..v`, where `v` is a name
or a field path, in a call or a constructor
([design/options.md](design/options.md)) is one keyword argument `f: v.f` for
each field the call does not name, in the order declared, evaluated where the
spread is written. A field that copies, plain data or a read view, is copied;
a field that moves, an owner or a handle, takes the spread's sigil: `<v.f`
from `..<v` and `+v.f` from `..+v`, so `..<v` leaves `v` partly moved, as
`<v.f` does. A bare `..v` that would give a field that moves is rejected, as
`f: v.f` is (sentence 1); a `..<v` that would move nothing is rejected; and a
spread makes no view, so `..?v` and `..!v` are rejected. A group, `..net: Net`
among a function's parameters, is one parameter per field, and the body reads
`net` as it reads an object parameter `net: Net`, so its fields move as an
owned object's do. `from net` and `keeps net` name the group and stand for
those of its fields that could hold what the result views or the call stores
(sentence 7); a field's own name is not in scope there and is rejected. A type
with a `drop` body, which expects every field (above), or a `unique` type,
which must not be copied (§1), is never taken apart so: it is no group's type
and is never updated, by any sigil, since `..<v` would take its fields apart
and `..v` or `..+v` would make a second value of it, which sentence 2 denies.
*(built)*

```rig
obj Doc
  name: String
  pages: Int = 1

sub show(..doc: Doc)
  print(doc.name, doc.pages)

sub main()
  d = Doc(name: String("a"))
  e = Doc(pages: d.name.len + 1, ..<d)
  show(pages: 9, ..+e)
  show(name: String("b"), ..e)
  show(..<e)
  print(d.pages)
```

```output
a 9
b 2
a 2
1
```

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
(the compiler's exact message for updating a type with a drop body)
```

Decisions in the synthesis:
- Purist's reasons in CORE's own words (drop body expects every field; unique must not be copied; sentence 2 for a second value), with the engineer's correction that `..+v` makes a second value of the type, which is what sentence 2 denies.
- Writer and veteran: refusals stated as refusals, `..?v`/`..!v` added; veteran's "partly moved"; engineer's "each field the call does not name, in the order declared" and "an owner or a handle".
- Purist's example (a group and an update, `..+e`, a bare `..e` accepted because its owner is named beside it, `..<e`, `d` read after its partial move), plus the engineer's reject block for a drop type.
- Writer's "update" definition dropped: the constructor form is in the first sentence, and "updated" is plain.
