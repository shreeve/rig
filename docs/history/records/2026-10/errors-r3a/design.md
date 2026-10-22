# R3a: the runtime's error-data plumbing (design)

Round R3a of errors with data (the approved spec,
[errors-spec.md](../../revamp/r3/errors-panel/errors-spec.md), §7.6, §7.7,
§7.10, §14; the owner: "Yes, start R3a (the runtime slot plumbing, no
behavior change)"). R3a adds to the runtime every place that keeps or
discards a Rig failure the data a member with fields carries, switched
on only by glue R3's emit declares. Until R3, no program declares it, so
every program's Zig, the runtime's code paths, and their speed are what
they are on main.

## The gate and the glue

R3's emit declares, in the root of a program in which a member with
fields reaches `error` (spec §7.1), one type:

```zig
pub const __rig_error_glue = struct {
    pub const size: usize = N;      // the program's largest member's fields
    pub const alignment: usize = A; // their alignment, program-wide
    pub fn drop(code: anyerror, data: *anyopaque) void;  // drops a member's fields; nothing for one without
    pub fn print(code: anyerror, data: *const anyopaque, w: *std.Io.Writer) !void;
};
```

The runtime reads it once:

```zig
pub const error_glue: ?type = if (builtin.is_test) TestErrorGlue else if (@hasDecl(root, "__rig_error_glue")) root.__rig_error_glue else null;
pub const ErrData = if (error_glue) |g| [g.size]u8 align(g.alignment) else [0]u8;
pub const ErrSlot = *ErrData;
```

`ErrData` is the bytes of a failure's fields; a failure is its Zig error
code and an `ErrData`, the code saying which member, and so whether the
bytes hold anything. `ErrSlot` is the hidden `__out` parameter R3's emit
gives a function that may fail with fields. With no glue, `ErrData` is
zero bytes and every branch below is compile-time dead.

The runtime's unit tests switch the gate on with `TestErrorGlue` (16
bytes, a count of drops), so they exercise the data paths; every
program in the suite exercises the paths with the gate off.

## Each site

| Site | Keeps | Discards (drops the data) |
|---|---|---|
| A task (`Task.start`) | `Control.err` holds the task's failure data; `run` passes `&control.err` to `f` when `f`'s last parameter is `ErrSlot` | |
| `>t` into a slot (`Task.waitInto`) | copies `control.err` to the waiter's slot before `release` | a result dropped because the waiter was canceled or timed out |
| `<t.cancel()`, dropping a task | | a failed result |
| `>ts`, `wait_first`, dropping a set | `wait_first`'s last failure; `>ts`'s first | every other failure, and those of tasks canceled after |
| `task.all` | the first failure | the others |
| `par.map`, `par.each` (`ParState`) | the first chunk's failure (after the `cmpxchg`) | a later chunk's |
| `select` (`dropAll`) | the arm's failure | the others |
| `supervise` | the last failure, when the restarts are spent | each failure it restarts after |
| `isolate` | `f`'s own slot, moved on for a normal failure | none after a panic (the leak is reported as left by the panic) |
| an actor's reply | the call's record holds the slot | a withdrawn call's |
| `main`, a `test` (`failMainData`, the runner) | | printed through `glue.print`, then dropped, before the leak check |

Each entry point R3's emit calls with a slot is a new function beside
today's (`waitInto` beside `wait`), which stays as it is, so no emitted
call changes in R3a.

## What shows it is unchanged

- R3a changes no emitted program: `emit.zig` is untouched.
- With the gate off, the runtime's new branches are compile-time dead:
  the full suite, `zig build test` on pup in three modes, and the four
  concurrency benchmarks on both machines, within noise.
- With the gate on (unit tests), each site keeps or drops as the table
  says: a test per row, counting drops, under the leak checker.
- Trig builds the commit, byte-identical.
