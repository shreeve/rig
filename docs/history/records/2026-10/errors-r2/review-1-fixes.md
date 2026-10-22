# How review 1's findings were fixed (declared error sets, #542)

Each finding of [review-1.md](review-1.md) is fixed in commit 4c4f7724f,
with a case in `test/rig/errors-sets.rig.test` that fails without it.

| Finding | Fix |
|---|---|
| 1. `.name` against a union named the union's own member | `checkExpr` resolves `.name` where a union is expected through `unionMemberSet`: the member of the one set it joins that has it, a missing or shared name reported |
| 2. Overlapping arms gave Zig a duplicate prong value | the checker records the members each `g: E =>` arm newly covers (`set_pattern_members`, by set type), and emit lists those; an arm that adds none "never runs"; `g` is bound as `@as(E, capture)` |
| 3. A guard could not read `g` | `guardBindings` binds `g` as `@as(E, @errorCast(subject))` |
| 4. `Tasks[T!E].wait_first` failed in the runtime | `Tasks` keeps its tasks' set (`Err`) for `wait_first`'s last error and `>ts` |
| 5. `x == K.name` on a made value leaked | it reads its operand as `x == .name` does, so the test drops a value made for it |
| 6. `(A, B)!E` dropped `E` | `resolveReturnType` resolves the set for several results too |
| 7. A union declared after `Task[T!L]` was not yet resolved | unions are resolved before every other declaration |
| 8. `>ts` lost its set | `taskSetWait` keeps the tasks' set |
| minor: messages in a closure named an empty function | they use `bodyName` ("this closure") |
| minor: SPEC claimed `K.name` beside an optional | SPEC now says `.name` compares with an optional, `K.name` with a value of `K` |

Fixing finding 2's first version crashed the compiler: a recorded fact
held a pointer to a module's `SemContext`, which moves before emit. The
fact holds the set's type instead.

Left for later, and listed in #542: `*fun` values are not covariant in
their set (a lent `?fun` is); `expectShim` does not yet check a Zig-backed
function against the set it declares; the `task.Stop` rule's message
names the wait's method rather than `>ts`.
