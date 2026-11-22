# Purist: "A spread gives an object's fields one by one"

## Revised paragraph

**A spread gives an object's fields one by one.** `..v` in a call or a
constructor ([design/options.md](design/options.md)) is one keyword
argument per field it gives, `f: v.f`, evaluated where it is written.
The spread's sigil goes on each field that moves, `<v.f` from `..<v` and
`+v.f` from `..+v`, and a field that copies is copied. So a bare `..v`
that would give a field that moves is rejected, as `f: v.f` is (sentence
1); `..<v` that would move nothing is rejected, as a field that copies
takes no `<` (above); and a spread takes no `?` or `!`. A group, `..net:
Net` among a function's parameters, is one parameter per field, and the
body sees `net` as a parameter of type `Net` whose fields those
parameters are, so its fields move as an owned object's do (above).
`from net` and `keeps net` name each of those parameters whose type
could hold what the result views or the call stores (sentence 7); a
field's own name is not in scope there and names nothing. A type with a
`drop` body, which expects every field, or a `unique` type, which must
not be copied (§1), is never taken apart so: it is no group's type, and
no update makes one, `..+v` included, since an update leaves its fields
moved apart or copied, and sentence 2 gives neither a `+`. *(built)*

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

(Run with the branch's `bin/rig` in a temp dir: prints exactly this. The
five refusals were also checked: bare `..d` of an owner, `..<d` moving
nothing, `..?d`, `Lock(id: 2, ..+a)` of a `drop` type, `Seed(n: 2, ..s)`
of a `unique` type; each is rejected with the message the record gives.)

## Reasons

1. **Citation of sentence 2: correct.** Sentence 2 reads "a `unique` type
   or one with a `drop` body has none", which covers both types for
   `..+v`. But it is only half the reason. The other half is in CORE
   already, in its own words: a `drop` body "expects every field" (§5, the
   `File` example right above), and a `unique` type "must not be copied"
   (§1). The draft coined "more than its fields" in place of both. That is
   new vocabulary for facts CORE already names, and close to §1's "three
   kinds the parts can't show", which also lists Cell types, so a reader
   could take it to cover them too. The revision uses CORE's two phrases as
   appositives, so each type comes with its own reason, and then cites
   sentence 2 for `..+v`. "`unique` mark" becomes "`unique` type", as in
   sentence 2.

2. **Rejections stated as rejections, with their source.** "So a bare
   `..v` gives only fields that copy" can be read as "it skips the
   others", which is not the fact (the fact is that it is refused). Each
   rule is now said as a rejection and tied to the sentence it follows
   from: the bare spread to sentence 1 (a bare place moves only where the
   value leaves for good, as `buf: buf` is refused), and the empty `..<v`
   to §5's "a field that copies takes no `<`". The second is the one
   genuinely new rule: it is an analogy, not something CORE implies,
   because a vacuous per-field `<` would be harmless. The analogy is the
   honest justification. The draft never closed the set of sigils
   ("takes the spread's sigil" invites `..?v`), so the revision adds "a
   spread takes no `?` or `!`".

3. **`from`/`keeps` in sentence 7's terms.** "Could hold the view" leaves
   "the view" undefined. Sentence 7 says "whose type could hold what it
   views" for `from`, and talks of what a call stores for `keeps`; the
   revision uses those words and cites sentence 7. It also states the
   built refusal of a field's bare name (`from text`), which follows from
   scope: options.md §2 says the field names do not enter the body.

## Smaller points

- "The body reads `net`" becomes "sees", since "reads" is sentence 1's
  technical verb for a bare use. "Object parameter" is not a CORE term,
  and a group may be plain; "a parameter of type `Net`" is exact. The
  added "so its fields move as an owned object's do (above)" links to the
  §5 paragraph that justifies `<net.f` and the refusal of copying an owner
  out.
- Placement after "A field of an owned object moves like a name" is
  right: the paragraph relies on `<p.f`, partly moved names, and the
  `drop`-body example just before it.
- **The example now teaches the whole paragraph:** the type is used both
  as a group and in an update. It shows `..+` (e keeps its name), a bare
  spread accepted when the moving field is named, `..<` forwarding,
  evaluation where written (`d.name.len` before `..<d`), and a partly
  moved `d` whose copied field is still read (sentence 3). The draft's
  example had no group at all.

## On the pending item

CORE line 7: "A rule anywhere else that does not follow from a sentence
here is a mistake in one of them." Options.md §11 step 3's "updated only
by `..+p`" contradicts sentence 2, so as CORE stands the built behavior
(no update of a `drop` type at all) is the one that follows. If the owner
wants `..+p` for `drop` types, sentence 2 has to change first, as its own
reviewed Core change (North Star 5). This paragraph should not do it
implicitly. Recommendation: keep the paragraph as built, and fix
options.md §11 to match, unless he rules otherwise.
