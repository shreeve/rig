# The consolidation

> **History.** This records the restructuring of the compiler so the Core's
> rules come from its structure. All ten steps are done. The ownership
> model is in [CORE](../CORE.md) and the compiler in
> [INTERNALS](../internals/INTERNALS.md). It is kept as written.

About 90% of earlier soundness bugs traced to three structural weak
spots, which these steps removed:

1. **Type facts.** One fact per question (copies, unique, needs
   cleanup, may hold a loan, cloneable, how a read view is represented)
   replaced the disagreeing proxies; `obj T unique` exists,
   `std.random.Rng` became the unique `Random`, and a type holding a
   `Cell` is unique.
2. **One classifier and one exit.** `sema.handsOver` decides what every
   expression hands over by a positive list, and one exit primitive ends
   every path, running defers and reporting the loans it drops.
3. **Reads and lends.** A bare name reads in place where a view is
   expected, one lend table serves every owner (List, String, `^T`, `*T`,
   optionals), and a header's subject is viewed or taken by its
   classification.
4. **Containers hold anything.** `List[String]`, nested Lists, and records
   that own text work; `?v[i]`, `!v[i]`, and `<v[i]` lend or take an
   element; assigning a view place re-points it or writes through.
5. **The remaining planned rules.** An error value meets `T!` only as
   `return`'s operand, `(!s).insert(k)`, `x =! e`, an owner moves
   as a function's or block's last value, and `+x` deep-copies List, `^T`,
   and owning objects.
6. **Result origins.** A call's result carries the loans of the
   arguments whose types could hold what it views, `from a` narrows
   that, and each body is checked against its signature.
7. **Vocabulary.** Diagnostics, docs, and internal names say lend, view,
   and loan.
8. **SPEC follows the Core,** derived from it in the new vocabulary.
9. **Speed.** Generic uses are indexed by parameter, which removed the
   quadratic generic checks.
10. **Lowering, decided as storage facts.** Every hidden storage
    location emit makes is a fact (`src/storage.zig`), emit takes no
    address of a Zig temporary such a fact names, the sanitizer poisons
    hidden storage, and the ownership checker walks what a call holds.

Alongside them, a reference ownership checker built from the Core alone
(`bin/rig-oracle`, `test/oracle/`) checks the compiler: its jobs in `swarm
test/rig.rip` fail when the compiler accepts a function the Core rejects,
and when the oracle decides fewer functions than the floors in
`test/oracle/coverage`.

The final review found no unsound program. Its fixes are in: a write
method on a temporary needs `!`, which lends the temporary to write in
its statement's slot (`!mk().pop()`, CORE sentence 4), a binding with no
type holds a call's write view, and the payload-view and loop
diagnostics name only forms that compile.

What the steps left for later is in
[weak-spots](../internals/weak-spots.md).
