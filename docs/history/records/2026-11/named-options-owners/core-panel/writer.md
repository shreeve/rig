# Writer: "A spread gives an object's fields one by one"

Angle: clarity, sentence length, ambiguity, and whether the order teaches
the rule. No fact changed; every fact in the brief kept, and checked on the
worktree's `bin/rig` (the example prints `a 2 a 9 1`; bare `..d` with an
owner, `..?d`, and `from agent` of a group's field are each refused).

## Revised paragraph

**A spread or a group is an object's fields, one by one.** `..v` in a
call or a constructor ([design/options.md](design/options.md)) is one
keyword argument per field it gives, `f: v.f`, evaluated where it is
written. A field that copies is copied; a field that moves takes the
spread's sigil, so `..<v` gives `<v.f` and `..+v` gives `+v.f`. A bare
`..v` that would give a field that moves is refused, as is a `..<v` that
moves none, and a spread takes no `?` or `!`. A constructor with a
spread, `T(f: x, ..v)`, is an update. A group, `..net: Net` among a
function's parameters, is one parameter per field of `Net`; the body
reads `net` as one object parameter. `from net` and `keeps net` name its
fields as `from` and `keeps` name parameters, and a field's own name
there is refused. A type with a `drop` body or a `unique` mark is never a
group and is never updated, not even by `..+v`: its `drop` body expects
every field, a `unique` value must not be copied (§1), and sentence 2
gives neither a `+`. *(built)*

Example: unchanged. It shows the three things a reader must see — a
moving spread read after a field it moves (`d.name.len` before `..<d`),
a cloning spread, and the source left partly moved but its copied field
still usable (`d.pages`).

## Reasons

1. **Split the 70-word first sentence into three.** The draft's opening
   sentence carried the desugaring, evaluation order, both sigils, the
   copy rule, and two refusals behind a semicolon and a "so". Each now has
   its own sentence, in the order a reader needs: what a spread is, what
   happens to each field, what is refused.

2. **State refusals as refusals.** "a bare `..v` gives only fields that
   copy and `..<v` gives at least one that moves" reads as a description;
   a reader cannot tell it is a compile error. "is refused" says so. The
   brief's fact that `..?v` and `..!v` are refused was missing; it costs
   seven words.

3. **Replace the vague phrases.**
   - "more than its fields" said nothing checkable; it is replaced by the
     three rules it stood for, each already in CORE: a `drop` body expects
     every field (the case just above), a `unique` value must not be
     copied (§1), and sentence 2 gives neither a `+`.
   - "no update makes one" read two ways (makes a group? makes a value of
     the type?); now "is never updated, not even by `..+v`", which also
     states the `..+` fact the draft left implicit.
   - "an update would move its fields apart" is dropped: "apart" was a
     metaphor, and the `drop` rule already covers it.
   - "those of them that could hold the view": "those of them" made the
     reader count antecedents, and "the view" had none (a result's view
     for `from`, a stored view for `keeps`). Now `net` names its fields
     "as `from` and `keeps` name parameters", which inherits §4's exact
     rule instead of restating it, and adds the brief's fact that a
     field's bare name is refused.
   - "whose fields those are" is gone; "one parameter per field of
     `Net`" and "one object parameter" say it.

4. **Define "update" before using it.** CORE uses the word nowhere else;
   the draft's last sentence relied on it. One short sentence,
   "A constructor with a spread, `T(f: x, ..v)`, is an update", fixes
   that and costs nothing else.

5. **Lead names both halves.** The draft's lead covered spreads, but half
   the paragraph is groups and the last sentence is about both. "A spread
   or a group is an object's fields, one by one" is the rule the whole
   paragraph unfolds, and the exception ("never a group, never updated")
   reads as its natural limit. If the panel prefers the draft's lead, the
   rest stands without change.

6. **Small word choices.** "evaluated where it is written" kept over
   "read", since "read" means something narrower in sentence 1. "a field
   that moves" kept as the pair of "a field that copies" (CORE's per-type
   fact) rather than "owns", which would leave handles unclear. "sentence
   2 gives such a type no `+`" became "gives neither a `+`", since the
   subject is now two types.

## Open for the coordinator

- The `drop`-type update stays "never, not even `..+v`", pending the
  owner (options.md §11 step 3 says otherwise). A ruling for `..+p`
  would touch sentence 2 itself, which gives a `drop` type no `+`, so it
  is a Core change of its own, not an edit to this paragraph.
- Optional: a second example with a group that owns a field and a
  `from net` result would show the group half, which the example does
  not. options.md §3 already has one; CORE's habit is one example per
  paragraph, so I would not add it.
