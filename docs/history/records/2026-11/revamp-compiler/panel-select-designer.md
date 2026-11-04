# task.select as a tagged result: designer's verdict

**Good idea; better than a shared parameter clause.** Go's `select`, tokio's `select!`, and the way Swift code switches over a task group's results all run the winning body in the enclosing scope. Doing the same here removes the capture problem instead of patching it. It reads like Ruby's `case/in`: "select one, then match which one". A beginner already knows `match`. Arms may now give different types, which the closure form cannot, and leaving out an arm is an exhaustiveness error with no `_`.

**Magic:** it is mild, because each name appears twice, close together. SPEC states it in one sentence: "select gives an enum whose variants are its argument names". Labels are required: an unnamed arm is an error.

**Pitfalls:**
- **Marks.** `a.recv()` is spelled like the blocking receive but must not run, and it drops the `!` that sending and receiving require. Write `add: (!a).on_recv()`, which reads as an arm, not a call, and keeps the write mark.
- **Closed channel.** The payload is `T?`, so match it with `.add(v?) =>` and `.add(none) =>`, two patterns the language already has.
- **Errors.** The select itself fails: `match task.select(...)!`, with `catch` as usual.
- **Deadline.** A timeout is one more named arm, `late: time.on_after(5.s)`, matched as `.late =>`.
- **Default.** "Don't wait" should be its own word, `task.poll(...)`, giving `none` when nothing is ready, so you match `none =>` rather than use a magic arm name.
- **Losing sends.** `(!c).on_send(<v)` drops `v` if it loses, as today.

**Better variant:** the same design, with `on_*` arm names and the write marks kept. Retire the closure form after one release, as proposed.
