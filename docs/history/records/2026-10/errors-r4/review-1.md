# Review: R4 (PR #565), the reach fact and `load` (2026-10-22)

An adversarial review by probe programs, run under RIG_SANITIZE=1. It
looked for any path that carries an error with fields into `error`, or
into a `T!` failure, while `fields_reach_error` stays off. It tried
generics, closures, function values, tasks and `>t`, actors, `Tasks`,
`within`, `isolate`, `par`, `catch |e| e`, `List[error]`, `^error`,
`?error`, Map values, `match` and `if` arms, object fields, defaults,
and programs of several modules. It found none. Every module gets the
same `error_data`. `load` holds `keeps src`, leaves the tape empty
after a failure, and gives the kind and offset `doc.error` and
`doc.error_pos` hold.

## Findings, and their fixes

1. **High, North Star 1, from R3.** Where `error` carries fields, a value
   of a set without fields put where `error` goes was emitted as a bare
   code where a `rig.ErrorValue` goes, which Zig rejects. That covered a
   declaration, an assignment, `if` and `match` arms, an object's field,
   `^error`, `List[error]`, a `-> error` result, a Map's value, and a
   default. It also reached across modules: a module without fields
   broke once another module turned the flag on. **Fixed:** the checker
   records each such value (`code_widenings`, in `checkActual`), and
   emit makes it `rig.ErrorValue.of(code, .{})` where `error` carries
   fields. Case: "an error of a set without fields goes where `error`
   carries fields".
2. **Medium, North Star 2, from R3.** `print(mk())` with `mk() -> error`
   leaked 16 bytes, as did `print((!l).pop())` of a `List[error]`. A
   temporary `error` had no drop: `error` has no drop glue of its own.
   **Fixed:** a temporary that holds `error` is dropped
   (`Checker.readLeafAs`), as CORE's owning `error` says. Case: "a temporary
   `error` made by a call is dropped".
3. **Low, coverage.** Three errors-data cases ran with `error_data` off
   and no longer tested the slot path their names describe: "a Zig-backed
   `T!` call...", "a `T!` function passes on an error of a set without
   fields", and "a function without fields lent where one with them
   goes". **Fixed:** each gains a `T!` function that fails with a member
   with fields, which turns the slot on.
4. **Low.** A program that imports std.json has error glue, so a
   `rig batch build` builds it alone. That only slows the suite; kept.
   A doc comment had joined `noteErrorWidening`'s; fixed.
