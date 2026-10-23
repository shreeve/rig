# R4: std.json's `JsonError` (design)

Round R4 of errors with data, from the approved spec
(docs/history/records/revamp/r3/errors-panel/errors-spec.md, "std.json
(R4)" and §7.1), started 2026-10-22 on the owner's word, relayed by
Rig: "Let's work on this when you think we can."

## 1. A prerequisite R3 left: when `error` carries fields

Spec §7.1 gives `__out` to a `T!` function, and makes `error` a value
with fields, only when **a member with fields can reach `error`** in
the program: a `T!` function fails with one, `!` or `return` passes one
from a declared set into `T!`, or a value of such a set widens to
`error`. R3 (#555) used a coarser fact: any module declares a member
with fields. With R4, std.json declares one, so every program that
imports std.json would pay in all its `T!` frames, and every `error`
would be 16 bytes or more. R4 builds the spec's fact first.

- **The fact.** Each module records `fields_reach_error` while it is
  checked. The program's is the OR over its modules, which main.zig
  hands emit as `error_data`, as it hands `declaresErrorFields` today.
  The glue (`__rig_errors.zig`), and so a value of a set with fields,
  still depends on `declaresErrorFields`.
- **Where it is set:** a failing `return` of a set with fields in a
  function declaring `T!` (`checkReturnedError`); `!` passing such a
  set into a `T!` function's failure (`synthPropagate`); and any value
  whose type holds such a set meeting a type that holds `error` there
  (`meets`: an `error`, `?error`, `^error`, `List[error]`, a function
  or task type whose failure is `T!`). A conservative answer costs only
  speed, never soundness: a program in which fields might reach `error`
  pays for slots it may not use.
- **What stays as R3 built it:** a function declaring a set with fields
  takes `__out`. A `catch` of such a call holds a slot. A typed binding
  owns an `ErrorValue`.

## 2. `JsonError`

```rig pending
pub error JsonError
  bad(kind: Error, at: Int)

pub sub parse(!@, src: ?String)!JsonError keeps src
```

- `Doc.parse` fails with `JsonError.bad(kind:, at:)` instead of
  returning `false`. The public `error` and `error_pos` fields go. The
  parse's inner functions keep their `-1` protocol, which records the
  first failure in private fields, so the hot loop is the same. `parse`
  fails once, at its end, from those fields.
- `Error` loses `ok`, which only marked "no error yet". The private
  record starts at `.empty`, and nothing reads it unless the parse
  failed.
- `JsonError` is plain data, 16 bytes (an enum and an `Int`): no drop,
  and a clone that copies.
- **Speed.** The only change on the path that succeeds is `parse`'s
  slot parameter, one pointer per document. The rule is never slower:
  exclusive time, interleaved, fastest of N, on the Mac and on pup,
  against main, on every json bench (bench/json). Anything beyond 2%
  slower stops the round, and Rig gets the numbers. Trig's timing is
  checked too.

## 3. Trig, and the migration

Trig calls `if not (!doc).parse(x)` three times
(src/sourcemap/source_mapper.rig, src/packagejson/packagejson.rig,
src/packagejson/jsonvalue_test.rig). The migration writes
`(!doc).parse(x) catch |_| <the old false branch>`. A `catch` keeps
`JsonError` out of `error`, so none of Trig's `T!` frames takes a slot
(§1). A `!` into a `T!` function would turn the slots on for the whole
program. Trig gets the note and the script before the PR merges.

## 4. Tests

- **The fact.** A program that imports a set with fields and catches it
  emits `T!` functions with no `__out` (`code` cases). One that passes
  it into `T!` gives them `__out`. Widening through `^error` and
  `List[error]` turns it on.
- **std.json.** `parse` fails with each kind and its position; a caught
  failure reads `e.kind` and `e.at` through `match`; the tape is empty
  after a failure; `!` passes `JsonError` up.

## 5. Revised after timing (2026-10-22)

The first build's `parse` failing with `JsonError` missed the json
gate (timing-1.md). Its cost was code placement, not code (codegen.md).
On the owner's fallback, `parse` keeps answering a `Bool`, with
`doc.error` and `doc.error_pos`, and `load` beside it fails with
`JsonError.bad(kind:, at:)`. Callers of `parse`, Trig's among them,
change nothing, so §3's migration is not needed.

## 6. Rebuilt on Option U (2026-10-22)

The owner adopted Option U (errors-r3/design-check-u.md) before R4
landed: `error` is always an `ErrorValue`, and every `T!` function takes
a slot that has no bits where no set has fields. §1's fact, and
review-1's two fixes, are U's instead (its coercion fact, and `error`'s
drop glue). R4 is `JsonError` and `load` on top of U.
