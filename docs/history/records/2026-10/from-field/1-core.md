# `from @field`: Core purist (1 of 4)

## Where it goes

Sentence 7, right after "…or, when the result says `from a`, of `a` alone.":

> A method's `from` may also name a path of self, as §5 defines one
> (`from @text`, `from @a.b`), whose type could hold what the result
> views: the result then carries the loan on that path alone, so a use
> that touches only self's other paths may go on while it lives; when
> the path holds a read view, the result carries that view's loans,
> and none on self. *(planned → built)*

Nothing new is invented here. The loan on a path comes from sentence 5 and §5, and "that view's loans, not a loan on the holder" is already in sentence 7. The body check is the one sentence 7 already states ("checks each body against its signature, `from` … included").

## Examples (after the Cursor example)

`seen` holds a view, so `next`'s items view the List and not the reader. `word` views `text` alone, so `at` may be written:

```rig
obj Reader
  text: String
  seen: ?List[Int]
  at: Int

  fun next(!@) -> ?Int from @seen
    @at += 1
    ?@seen[@at - 1]

  fun word(?@) -> ?String from @text
    ?@text[..2]

sub main()
  v: List[Int] = List()
  !v.push(7)
  !v.push(8)
  r = Reader(text: String("hi there"), seen: ?v, at: 0)
  a = (!r).next()
  b = (!r).next()
  w = ?r.word()
  r.at = 0
  print(w, a, b)
```

```output
hi 7 8
```

(Today this is rejected: `at: Int` could hold the `?Int`.)

```rig reject
obj Reader
  text: String
  name: String

  fun word(?@) -> ?String from @text
    ?@name[..2]
```

```error
`word` returns a view of `@name`, but its signature says it views only `@text`
```

## The loan in each case

- **Owned field** (`text: String`): a loan on the path `r.text`. Writing `r.at` is fine, but `(!r).m()`, `r = …` and `<r` touch all of `r` and conflict (§5).
- **View field** (`map: ?Map[K, V]`): the field's own loans, on the map's owner. Nothing is on the iterator, so `!it.next()` may go on while earlier items live.
- **Nested path `@a.b`**: allowed, since a §5 path is fields through a box. A path stops where §5 stops (an element, a handle, an optional's value), and `from @map.es` through a read view is rejected with "write `from @map`". One rule, no list.
- **With parameters**: `from @map, k` carries both. Each name appears once, and none may hold another, so `from @, @text` is rejected.
- **Through a bound**: `from @map` is within the API's `from @` (by position), so it narrows. The `[I: Iter]` instance check reads the implementation's `from`. An item `from` a read-view field views what the iterator only views, like `text.split`'s, so it is taken. std's `Items`, `Keys`, `Values` and `Members` add `from @map`/`from @set`.

## What it does NOT change

- Run time: the check is in the checker only.
- A call through a function value: still no `from`.
- `keeps`: still names only parameters.
- A `!@`/`?@` lend of self: still touches all of self.
- Several results.
- Loan kinds and conflict rules: no new ones.
