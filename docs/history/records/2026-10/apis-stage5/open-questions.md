# APIs Stage 5: open questions (2026-10-23)

What the record ([docs/design/apis.md](../../../../design/apis.md), Stage
4's records, the `*Frozen` record, and the Sends/Syncs naming) does not
settle, each with a default and its reason. The refreshed Stage 5
section, [build-plan.md](build-plan.md), and
[core-draft.md](core-draft.md) are written to these defaults; "approve
the defaults" settles all of them. Two (13 and 14) close holes found in
Stage 4's phase 3 (#614) while writing this, and 13 narrows Stage 4's
approved default 14, so it needs the owner's word whatever else is
decided.

1. **When Stage 5 starts:** after Stage 4's phase 3 (#614) lands and
   the Core text below is approved; one language feature at a time.
   *Reason:* it extends #614's tables and boxes, and the owner's rule
   is one feature in flight.
2. **The Core first** (phase 0): a panel of four revises
   [core-draft.md](core-draft.md), and the owner approves it, before any
   code. *Reason:* a new handle, a new weak handle, and crossing rules
   change ownership (North Star 5).
3. **A crossing bound in the braces is a fact of the hidden value,**
   checked at the erasure by `sema.crossingBlocker`, and each form then
   crosses by its own row of SPEC §18's table. *Reason:* the braces'
   `Owned`, `Print`, and `Clone` are already facts of the value checked
   at erasure; one classifier, and §18's rows unchanged.
4. **One spelling per meaning:** a bound a form cannot use, written in
   its braces, is rejected toward the one it can: `?{A + Sends}` toward
   `Syncs`, `!{A + Syncs}` toward `Sends`, `*{A + Sends}` toward
   `Syncs`, and any in `~{...}`. *Reason:* otherwise two spellings name
   one type, or a bound promises what the form never does.
5. **An API's crossing bounds count as written in the braces:** `^{Job}`
   of `api Job: Sends` sends. *Reason:* Stage 3 checks the bound at
   every type that provides the API, so every hidden value has it;
   Stage 4 counts an API's `Owned`, `Print`, and `Clone` the same way;
   Stage 4's question 20 left this to Stage 5.
6. **`*{A + Syncs}`, written or by its API, takes only a handle counted
   atomically** whose value syncs: today a `*Frozen[T]`; a `*T` is
   rejected toward freezing it. *Reason:* a handle crosses by its count,
   and `Syncs` over a count that is not atomic would promise nothing.
7. **A `*{A}` without a crossing bound takes a `*T` or a `*Frozen[T]`,**
   its counts the hidden allocation's (atomic for a frozen value's),
   chosen at the erasure. *Reason:* the record's "whether its counts are
   atomic depends on the hidden type"; a frozen value is a counted value
   that also crosses.
8. **What becomes a `*{A}`:** `<h` and `+h` of a `*T` (its allocation
   kept), `*S(...)` and `*<x` written where it goes, and a frozen
   value's handle; never an actor's, a channel's, or a Cell's handle,
   and never `*<b` of a `^{A}`. *Reason:* actors' and channels'
   methods are messages, not the value's; a move into a new allocation
   needs the erased value's size; one allocation per shared value.
9. **A `*{A}` reaches `?@` methods only,** and `Clone` in its braces is
   rejected. *Reason:* handles only read (CORE sentence 8), and `+s`
   counts; a type holding a `Cell` changes through its `?@` methods, as
   behind any `*`.
10. **`~{A}` is `~s` of a `*{A}` whose braces name no crossing bound;**
    `*w` gives `*{A}?`; it never crosses; a weak handle of a hidden
    frozen allocation counts atomically. *Reason:* it mirrors `~T`; a
    `*Frozen[T]` has no weak handle, which `*{A + Syncs}` keeps, while a
    `*{A}` that merely hides a frozen value need not know.
11. **`ptr` is the value's address, and the counts go through the
    table** (each entry reaches them by the allocation's layout).
    *Reason:* `?s` is then the same two words, and each method entry is
    the one views and boxes call; `+s` and drops are rarer than calls.
12. **One table per API, type, and holding** (a box, a `*T`'s
    allocation, a frozen value's): `__rig_table_Shape_of(T, W,
    holding)`. *Reason:* only the drop and count entries differ; Zig
    makes each once where a conversion names it, and a program without
    objects emits the same Zig.
13. **An object without the crossing bound a task needs goes to no
    task, a local one included** (narrows Stage 4's approved default
    14; the owner decides). *Reason:* an object may hide an owned
    closure, which SPEC keeps from every task, a local one too, because
    its type does not show its captures. #614 lets a `^{Shape}` hiding
    one reach two local tasks at once (probe: `area_of(?b)&` and
    `?b.area()&` both accepted, `rig check --tasks` calls them local),
    where the same value of a known type is rejected. No crash was seen
    under the sanitizer; it bypasses a stated rule. *Alternative:*
    reject, at every erasure, a type holding an owned closure, keeping
    local tasks over objects but losing objects with callbacks.
14. **An object never hides a task or a set of tasks:** rejected at the
    erasure, naming the field. *Reason:* `task.isolate(|| mk())` gives
    a `^{Shape}` hiding a task started inside it under #614, which
    isolate rejects for any value whose type shows one; a task is bound
    to the scope that waits for it, and an erased drop hides that wait.
    No crash was seen under the sanitizer. *Alternative:* every walk
    that looks for a task treats an object as holding one, so isolate
    could give no object at all.
15. **`Sends` never implies `Owned`:** a channel's element and an
    actor's state need both, `^{Job + Sends + Owned}`, or an
    `api Job: Sends + Owned`. *Reason:*
    a task keeps the loans of what it is given, so `Sends` alone is
    right for a task's argument; homes that keep no loan already say
    `Owned`.
16. **A frozen value still never holds an object,** even one that
    syncs; the erased value many tasks read is a frozen value erased,
    `*{A + Syncs}`. *Reason:* a value that syncs may hold a one-word
    `*Cell`, which changes, and frozen means nothing changes.
17. **A Cell of an object stays rejected, by the Cell's own rule**
    (`Copy + Owned`), and Stage 4's "Stage 5" message for it goes.
    *Reason:* no object both copies and holds no loan; changing a shared
    object in place is an actor's or a Cell field's job.
18. **Owned closures become objects of one method in phase 4, kept only
    if measured faster.** *Reason:* the record's "once `*{...}` exists";
    on the Mac a closure made, called, and dropped costs 11.1 ns against
    4.6 ns for one allocation, so about 45% faster to make is expected,
    calls unchanged, the handle 8 bytes larger; Trig makes its 10 once,
    so it gains nothing and is only checked not to slow.
19. **No upcast, downcast, or conversion between forms** (`^{A}` to
    `*{A}`, `*{A}` to `^{A}`), as in Stage 4. *Reason:* each needs its
    own table or a size; no program asks.
20. **The oracle decides crossing only for objects,** from their braces
    and API, and abstains on other crossing as today. *Reason:* the
    checker table asks for "crossing facts of objects"; a full crossing
    checker in the oracle is its own project.
21. **The Lean obligation gates nothing** and lands beside phase 2 when
    ready. *Reason:* `Tasks.lean` already proves `confined`; the
    obligation is that an erasure keeps `holds`, which no compiler phase
    waits on.
22. **Associated types ride on Stage 4's phase 5:** `*{Source[Item:
    Int]}`, and a crossing bound after the named type. *Reason:* no
    program asks yet; nothing in Stage 5 changes how an item's type is
    named.
