# A narrower set fitting a generic body: tried, held for Stage 3 (2026-10-23)

Consolidation track 2, #542's third bend: a generic body that takes a
call on a `T` as `Int!` rejected an instance whose method gives
`Int!Bad`, and `b.get() catch |e| 0` in a `-> Int!` body was typed
`Int!!`.

**Landed:** the `Int!!` inference (`Checker.wrapResult` takes a fallible
expected result's value), and the message for a body declaring a set
of its own that passes a `T`'s failure on with `!` ("`b.get` is a call
on a `T`, whose method the body takes to fail with any error").

**Tried and held:** letting a method's `T!E` fit a body taking `T!`.

- Round 1: Zig failed for a set without fields. The body passes the
  hidden slot for a failure's fields, and such a method takes none.
- Round 2 added `rig.methodCall(recv, "name", .{args}, slot)`, which
  passes the slot only where the method takes one, and self by pointer,
  by value, or as a copy's address. The independent review found:
  - **C1:** a `!@` method on a `T` had its receiver emitted as a value
    (`c.*`, `self.item`), so `methodCall` took its copy path, whose
    const-pointer assert failed at compile time; the write would have
    landed on a copy. Programs main ran correctly were broken.
  - **M1:** a view a `?@` method returned pointed into `methodCall`'s
    local copy of an owned `c: T` (undefined behavior in Zig, though it
    printed correctly).
- **The proposal for later:** emit the receiver by its address,
  `rig.methodCall(&place, ...)`, as `spawnMethod` does, so the runtime
  passes the pointer on or reads it for a by-value self, with no copy.
  Stage 3's bounds state the set a `T`'s method fails with, and so the
  slot convention statically; the fit belongs there (the supervisor's
  call, 2026-10-23).
