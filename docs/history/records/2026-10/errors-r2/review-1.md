# Review: declared error sets (branch `errsets`, PR #542)

Binary: `~/Data/Code/worktrees/rig/errsets/bin/rig` (Oct 22 00:27). Probes are in this
directory (`pN.rig`); each named below was run with `RIG_OUT_DIR=out/...`.
`rig check` accepts every program in findings 1-5 and 7; each then fails in Zig or
runs wrong.

## Blockers (accept means correct)

### 1. `.name` against a union is resolved as a member of the union itself (wrong result or Zig error)

`checkEnumLit` and the `==` enum-literal path look the name up on `L` itself. A union
has no members of its own (its `fields` is null), and nothing reports the miss. Emit
then writes `error.@"L.x"`, an error that is in no set.

In a comparison, Zig peer-resolves the two sets, so the test compiles and **is always
false** (p9, p10, p23):

```rig
error A
  x
  w
error B
  y
error L = A | B

fun f(n: Int) -> Int!L
  return A.x if n == 0
  return A.w if n == 1
  return B.y if n == 2
  n

sub main()
  for n in [0, 1, 2]
    v = f(n) catch |e|
      if e == .x
        -11
      else
        -12
    print(v)          # prints -12 -12 -12; want -11 -12 -12
```

`e != .y` is always true. `e == .zzz`, a name in no part, is accepted (p11). On a
plain set, `no variant zzz` is reported (p12). Where `.x` is a value of type `L`,
Zig fails with "expected type 'error{A.x,B.y}', found 'error{L.x}'". Examples:
`x: L = .x` (p11), `ls: List[L]` then `!ls.push(.x)` (p13), and the same in an
argument, a field, or a return.

Patterns on a union (`match e` with `.x =>`) are fine: they go through
`unionMemberSet`.

**Fix:** in `checkEnumLit` and in `checkEquality`'s enum-literal branch, when the
expected type is a union, resolve the name with `unionMemberSet` (which reports a
missing or ambiguous name). Record the leaf set's type on the literal, as the pattern
path does. Add cases for `==`, `!=`, a binding, a push, and a missing name.

### 2. Overlapping arms in a match: Zig "duplicate switch value"

`checkSetPattern` covers members without reporting any already covered, and emit lists
every member of `E` in the prong. Handling one member first and then the rest of its
set fails in Zig (p34b):

```rig
fun f(n: Int) -> Int!
  return A.x if n == 0
  return B.y if n == 1
  n
...
      match e
        A.x => 4
        _: L => 5        # Zig: duplicate switch value 'error.A.x'
        _ => 6
```

Two set arms that overlap (`_: L =>` then `_: A =>`) fail the same way (p34). For the
second, an arm whose members are all covered already should get the usual "this arm
never runs".

**Fix:** in `writePatternHead`, list only the members that no earlier arm covered
(the coverage map knows which). Report an arm that adds no member as one that never
runs. The capture's Zig type then narrows, so bind
`g = @as(E, cap)`, not the capture itself.

### 3. A guard on a `g: E =>` arm cannot see `g`

Emit binds `g` only in the arm's body. In the select form a guard reads `g` before
the body runs (p8):

```rig
      match e
        A.x, B.y => -1
        g: A if n > 0 and g == .w => -2
        _ => -3
```

Zig fails with "use of undeclared identifier 'g'".

**Fix:** in the select form's guard, alias `g` to `@as(E, @errorCast(subj))`, as
variant-pattern guards do with their payload.

### 4. `Tasks[T!E].wait_first()`: Zig error inside the runtime

`taskSetWait` gives `wait_first` the task's own type, `T!E`. But
`src/tasks.zig` `wait_first` declares `var last: anyerror` and returns it as `T`
(p38):

```rig
fun firstof() -> Int!JS
  ts: Tasks[Int!JS] = Tasks()
  !ts.add(work(3)&)
  <ts.wait_first()!
```

Zig fails with "expected type 'error{Job.bad,...}!i64', found 'anyerror'". The
runtime is also called from `rig run` with a plain catch.

**Fix:** type `last` as `@typeInfo(T).error_union.error_set`. Also check the other
`anyerror` returns in `tasks.zig` against what sema gives each one.

## Major

### 5. Using `K.name` on a temporary in a member test leaks

The new `x == K.name` branch returns before the temporary-drop bookkeeping that the
`.name` branch does. A temporary from `catch`, `??`, or an `if` expression is never
dropped (p17, p42, p44):

```rig
enum K
  a(xs: List[Int])
  b
sub main()
  c = true
  print((K.a(List([1])) if c else K.b) == K.a)   # leak: 1 allocation
```

`(mkf(0) catch K.b) == K.a` and `(mko(0) ?? K.b) == K.a` leak too. The same
expressions with `.a` do not.

**Fix:** send the `K.name` member test through the same `readThrough` /
`recordTempDrop` path as `.name`. One classifier serves both.

### 6. `(A, B)!E` silently drops the set

In `resolveReturnType`, the results-type branch interns `.fallible = .{ .ok = inner }`
and ignores `ErrorUnion.set` (p28):

```rig
fun f(n: Int) -> (Int, Int)!A
  return B.y if n < 0          # accepted; emitted `anyerror!@Tuple(...)`
  return n, n
```

Callers see "`f` may fail with any error". The declaration is silently dropped, which
North Star 1 forbids.

**Fix:** resolve the set there too, and in the `fun_type` returns path.

### 7. A union declared after its use in `Task[T!L]` is falsely rejected

`setHoldsStop` runs at type resolution for a `Task`/`Tasks` argument, before a
later-declared union's `error_parts` are filled. The union is then read as a set with
no parts (p30):

```rig
fun keep(t: Task[Int!JS]) -> Int!JS
  >t!
...
error JS = Job | task.Stop     # declared below
```

The error reads: "`JS` does not hold it: join it into the set
(`error L = JS | task.Stop`)". The program is correct.

**Fix:** resolve every `error_join`'s parts before function signatures and field types
(a pre-pass), or defer this check to typecheck.

### 8. Waiting on `Tasks` with a declared set loses the set

In `taskSetWait`, `>ts` builds `.fallible = .{ .ok = all }` (any error). So
`>ts!` in a function that declares `!JS` is rejected with "`wait` may fail with any
error". This holds even though `Tasks[Int!JS]` is legal (§3.8 allows it). Also,
`Tasks[Int!JS]()` does not parse in an expression ("unexpected name"), so a typed
binding is the only spelling.

**Fix:** keep `each`'s set for `>ts`. A typed arg parse for `T!E` in expression
generics may wait.

## Minor

- **Diagnostics inside a closure name an empty function.** For example, "`loose` may
  fail with any error, and `` declares `Int!A`" (p3), and "`B.y` is not in `A`, the
  error set `` declares" (p3b). Use "the closure" when `body.name` is nil.
- **The wait diagnostic says `wait` for `>ts`.** It should show `>ts`. When the set is
  already a union named `L`, the suggestion reads `error L = L | task.Stop`; suggest a
  fresh name.
- **SPEC §5 Comparing is ahead of the code for optionals.** It now says `Shape.dot`
  compares "with any enum, or optional of one". But `o: K? = ...; o == K.b` is
  rejected ("`==` is not defined for `K?`"), while `o == .b` works (p16).
- **A `*fun` value is not covariant in its set.** `*fun(Int) -> Int!A` where
  `*fun(Int) -> Int!L` is wanted is a type mismatch (p2). Lending `?h` works.
  errors-spec §3.2 says function values are covariant.
- **`if e as g: A` does not parse.** Only `match` narrows. This is acceptable if
  intended.
- **`expectShim` does not check a declared set.** It still checks only "an error of the
  module", not membership in the declared `E`, and its comment still speaks of
  `anyerror!T`. errors-spec §3.2 asks for a checked cast at the call. Only std can hit
  this today.

## Checked and fine

- Cross-module sets and unions, including a union of an imported union, a private part
  behind a `pub` union, and three-module chains (p1, p23, p31).
- `g: E =>` with `E` a union, with `_`, nested, and under `match <e` (p14).
- Alternatives with set arms; `.x` arms with guards (p32, p33); arms used in the
  select form (p45).
- Typed `catch` on subs, actor calls, and `>t` (p19, p24, p40).
- Lending a function covariantly through `?fun`, `?sub`, closures, `reduce`,
  `par.map`, and `par.each` (p2, p20, p22, p39).
- Generics with `T!A` (p4).
- `time.within` with sets (p21).
- `main` with a declared set (p25, p26).
- Widening into `L`, `error`, `L?`, and `List[error]` (p7).
- A forward-declared union outside a task type (p46).
- Unions of unions; a duplicate part.
