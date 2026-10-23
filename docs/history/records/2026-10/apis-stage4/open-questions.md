# APIs Stage 4: open questions (2026-10-23)

What the record ([docs/design/apis.md](../../../../design/apis.md), its
panels, Stage 3's records, and this refresh) does not settle, each with
a default and its reason. The refreshed Stage 4 section and
[build-plan.md](build-plan.md) are written to these defaults; "approve
the defaults" settles all of them.

1. **When Stage 4 starts:** after Stage 3's last phase lands, on the
   owner's word, one language feature at a time. *Reason:* each stage
   waits for a program that needs it, and none needs it yet: Trig's 10
   owned closures each stand for one method, and it holds no object of
   several.
2. **The Core first** (phase 0): one lend-table row, the object kinds,
   and one paragraph, through the Core change process before any code.
   *Reason:* the erasure is a new lend and the box a new owner (North
   Star 5).
3. **`{A}` is one unsized type under the existing holding sigils**
   (`read_view`, `write_view`, `Box`), as `?fun` is a read view of a
   callable. *Reason:* every rule keyed on the holding kind applies
   unchanged; no second set of view rules.
4. **One API of a program's own per braces,** with `Owned`, `Print`,
   and `Clone` beside it; `Copy`, `Eq`, `Hash`, `Ord`, and the number
   APIs rejected; `Moves` and `Shares` Stage 5's. *Reason:* one table
   per API and type; a named combination (`api Both: Shape + Named`)
   is one line.
5. **What an object reaches is decided per method:** none with
   compile-time parameters of its own (types, values, sets) or with
   `Self` outside self; the rest of the API still forms objects.
   *Reason:* the panel's B7; leaving one method out need not cost the
   whole API.
6. **An entry for a fallible method takes the slot,** as a callable view
   of a fallible function does, and gives it to the method where the
   method takes one. *Reason:* one table type per API, whatever set
   fields the caller's frame lends; R2.5's rule for `?fun`.
7. **Associated types:** an object of an API with `type Item` names it,
   `^{Source[Item: Int]}`, the spelling "The words" keeps; built in
   phase 5, when a program needs it, and rejected with that spelling
   until then. *Reason:* each entry needs one type; `Iter` objects are
   the likely first use, and no program asks yet.
8. **An object of a copy stays in its frame:** a read view the program
   holds as a copy (`rig.ReadView`'s rule: small plain data), and a
   `?T`, erase to an object of a frame-local copy that is never
   returned or stored beyond the frame. *Reason:* an erasure needs an
   address; boxing the copy would allocate where no `^` is written, and
   pointing at the parameter would dangle (Stage 3's first phase-2
   attempt failed this way).
9. **An object meets no bound by an API:** `T = ^{Shape}` does not meet
   `[T: Shape]`, and a call on an unbounded `T` at an object instance
   is rejected as at a built-in type. *Reason:* a box is not its value
   (Stage 3's rule for handles); a forwarding witness is a second
   mechanism for what a `?{Shape}` parameter says; revisit when a
   program needs Rust's `dyn Tr: Tr`.
10. **No conversion between object types,** neither `?{Named}` to
    `?{Shape}` (an upcast) nor between markers. *Reason:* the panel's A4
    forbids widening; an upcast needs a table per pair of APIs, and no
    program asks.
11. **No downcast** (`if s as Circle c`) in Stage 4, though
    docs/design/formal-plan.md's round R3 lists it for GPUI's element
    tree and tsc's `Any`; the table reserves no type id. *Reason:* enums
    cover closed sets; a downcast needs a type identity across modules,
    which is its own design.
12. **`Print` and `Clone` come from the braces or the API's
    supertraits,** each a table entry; without them `print(b)` and `+b`
    are rejected, never `<Shape>`. *Reason:* the design's "when the API
    requires `Clone`", and A4's "set where the type is erased", are both
    true of the hidden type; a placeholder print would hide a missing
    `Print`.
13. **`Shape.area(s)` by name on an object is a dynamic call.**
    *Reason:* an API that builds on two declaring `area` needs it, as
    through a bound.
14. **A task over a call through an object is local,** built with boxes
    (phase 3); a channel send, an actor's argument, and `par.each`
    reject an object. *Reason:* Stage 3's rule for a bounded `T` without
    `Moves`; crossing is Stage 5's bound in the braces.
15. **An object is never frozen;** a `*Frozen[T]` lends a `?{Shape}`
    through `?f`. *Reason:* freezing is a fact of the hidden type's
    parts; an erased value many tasks read is Stage 5's.
16. **The table's home and name:** `__rig_table_Shape` and
    `__rig_table_Shape_of(T, W)` in the API's module, beside
    `__rig_defaults_Shape`, written for every API, and made by Zig only
    where a conversion names it. *Reason:* one table per API and type
    falls out of Zig's memoized compile-time calls; nothing to record
    per type, and a program without objects emits the same Zig.
17. **The oracle decides objects in the phase that builds them,** not in
    a later phase of its own. *Reason:* Stage 3 did the same in its
    phase 2; the second opinion should land with the feature, and the
    table's "abstains until then" lasts only until each phase.
18. **The Lean lemma gates nothing** and lands when λRig can state it.
    *Reason:* λRig has no functions yet; the packing half needs only
    boxes and views, and Stage 3's subsumption lemma comes first.
19. **Owned closures keep today's lowering** (`rig.Closure` behind a
    handle) through Stage 4. *Reason:* the design moves them to the
    table's shape only once `*{...}` exists (Stage 5).
20. **`^{Job}` of an `api Job: Moves`** does not cross in Stage 4, even
    though every provider moves; whether it does without `+ Moves` is
    Stage 5's. *Reason:* A5: each object form takes its facts from its
    own kind until the crossing rules are designed.
21. **`Moves` may become `Sends`** before Stage 5; Stage 4 names
    neither in braces, and the docs keep `Moves` until the owner
    decides. *Reason:* no Stage 4 form depends on the word.
