# Review 1: generic sets (R2.5, PR #569)

An adversarial review of the change (top model, 2026-10-22), probing
about 45 programs under `RIG_SANITIZE=1`: programs `rig check` accepts
that fail in Zig, crash, leak, or misbehave. Two HIGH, one MEDIUM, three
LOW. Each is resolved below, and each HIGH and the MEDIUM is a case in
test/rig/errors-generic.rig.test.

## Findings and resolution

1. **HIGH: a re-raise wrote a read-only slot.** A frame of a set without
   fields (`fun outer() -> Int!Bad`) called a function generic over its
   set whose body re-raised (`catch |e| return e`), in a program where
   another set has fields. The frame lent a shared slot meant never to be
   written, and `failValue` copies the slot for every member: a bus
   error. The same through a closure, and in a task. **Fixed:** a frame
   with no slot of its own lends a fresh one, as a `catch` does; the
   shared slot is gone. Case: "a re-raise in a frame of a set without
   fields, in a program with fields".
2. **HIGH: a fallible arm of `task.select` failed in Zig.** Every view of
   a fallible function takes the slot now, and `select` called the arm's
   function without one, even in a program with no fields. The same
   class held on main for an arm of any error in a program with fields.
   **Fixed:** `select` passes a slot to an arm that takes one, and a `!`
   or `catch` lends it its own (`selectInto`), so an arm's fields reach
   the handler. Case: "a fallible arm of `task.select`".
3. **MEDIUM: a closure's set conflicted with the expected result.**
   `first(n, |x| w(x)!)!` in a function declaring `Int!Wide` reported a
   conflict between `Wide` and `error`, suggesting `first[error]`,
   which is rejected. **Fixed:** a closure literal binds no set; it is
   checked against the set another argument, the expected result, or
   brackets give, and is `error` only when none does. Case: "a
   closure's set from the expected result".
4. **LOW: a union over a set parameter suggested.** Fixed: the message
   offers only `catch` when either set is a parameter. Case: "the
   parameter's set into a declared set".
5. **LOW: a non-fallible callback's mismatch names the inner types**
   ("expected `Int!E`, got `Int`"). Left as it is: the message is
   `bindArg`'s for every generic, and names the part that differs.
6. **LOW, on main before this change:** a bracketed generic call is
   named `` `expression` `` in a diagnostic (`id[Int](n)!`), and a
   conflict with the expected result says "argument 0". Left for the
   consolidation round.

## Covered without findings

Local and optional views, Lists and arrays of function values, owned
closures lent, `time.within`, `reduce` and `par.map` with set callbacks,
`List[E]`, `+e`, `<e`, `?e`, `E?` locals, `defer` and `errdefer`,
recursion, `E = error` with `String` fields, methods with their own set
parameter (also on a generic object), actors, tasks, two set parameters
and mixed type and set parameters, closures typed `!E` in a body,
`sub main()!` and tests, and modules (`pub` generics, a library without
fields used by a program with them, one imported set bound from two
modules).
