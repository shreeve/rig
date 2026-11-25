//! Ownership checker: moves, drops, views, and aliasing of owning values.
//!
//! Runs on the normalized semantic IR after ctx, one function body at a
//! time, as a flow-sensitive abstract interpretation.
//!
//! Abstract state
//! --------------
//! * Every binding in scope is a `Var` (static facts: name, type, kind)
//!   paired with a `Flow` (status `live` / `moved` / `dropped`, plus the
//!   loans its value holds). Vars form a stack; leaving a scope truncates
//!   it, so a var index is valid exactly while the var is in scope.
//! * Every write to a flow goes on a trail with the value it replaced.
//!   Going back to a `Point` undoes the writes since; a branch or jump
//!   captures its `State` as the flows changed since its construct's
//!   point, so snapshots and joins cost what changed, not the scope.
//! * A `Loan` is a read or write view of a place: a root var and the
//!   path of fields below it (`resolvePlace`, `Paths`), so `p.a` and
//!   `p.b` are viewed apart, and two places conflict when one path is a
//!   prefix of the other. Loans travel with values: `r = ?a` stores a
//!   read loan on `a` in `r`; `View(box: ?a)` carries it into the
//!   struct. A call passes on only the loans its signature shows (Core
//!   sentence 7): its result carries the loans of
//!   its callee (what a callable holds) and of the arguments whose
//!   parameters' types could hold what it views, and it may store, in
//!   its write self and in what its `!x` arguments and other write
//!   views lead to, the loans of the arguments (its self among
//!   them) whose types could be held there (`sema.CallParams`). A body
//!   is checked against its signature (`checkOrigins`). A loan that is
//!   not stored anywhere is a temporary and ends with its statement.
//! * Hidden storage emit makes is read from the storage facts
//!   (the module's LIR, `lir.Var`): a self or copied argument a call holds while
//!   it runs is a hidden var the call views, which ends when the call
//!   returns (`holdForCall`).
//! * Cells, Signals and owned closures hold no views: every handle to
//!   one reaches what it holds, so tracking loans per handle var would
//!   miss the other handles.
//! * A `?String` is a view: one taken from a String (`?t[a..b]`) views it,
//!   and any value whose type holds a `?String` carries loans as a view
//!   does.
//! * A view carries the loans of only what could hold what it views
//!   (`carry`): a loan on a var whose type reaches that memory only
//!   through a read view it holds stands for that var's own loans, and
//!   a view through a read view keeps what the view keeps
//!   (`walkThroughView`).
//! * View parameters hold an *external* loan on themselves: it marks
//!   a view that came from the caller, which may be returned or stored
//!   into other view parameters, and it never conflicts. A loan
//!   stored into what a view parameter reaches goes in that
//!   parameter's flow, and the parameter is live at every exit (the
//!   caller uses its value after the return), so the loan stays in
//!   force for the rest of the body.
//! * Types come from ctx's facts table (`typeOf`, `symbolAt`); an
//!   unknown type is assumed to be able to hold a view.
//! * A loan is in force only while the var holding it is live: while
//!   it may be used again (see `holderLive`). Views end at their last
//!   use, not at the end of their block.
//!
//! Control flow
//! ------------
//! * `if`, `match`, ternaries, `catch`, `??`, and the right side of `and`
//!   and `or` walk every branch from the same entry state and `join` the
//!   results: a value moved or dropped on any path is moved or dropped
//!   afterwards, and loans are unioned. Each part of a binding condition
//!   that fails leaves for the `else` with the effects of the parts that
//!   ran, and the `else` starts from their join. A guard
//!   that fails runs on the way to the later arms, which start from the
//!   join of the entry state with what each failed guard left. A match
//!   without a catch-all arm also joins the state where no arm ran.
//! * Loops iterate to a fixpoint over the back edge: the loop-head state
//!   is the join of the entry state, the end of the body and every
//!   `continue`. The state after the loop joins the condition-false state
//!   with every `break`. Diagnostics are only reported on the final walk.
//! * `return`, `break` and `continue` make the rest of their block
//!   unreachable.
//!
//! Rules
//! -----
//! * A moved or dropped value cannot be used, viewed, moved or dropped.
//!   Reassigning a binding makes it live again.
//! * Read views exclude writes, moves, drops and reassignment of their
//!   place; write views exclude every other use. A value never holds a
//!   view of itself: a store of a loan on a part of a var into that var
//!   is rejected. A method call views
//!   its self for the whole call (`rc.show(<rc)` is rejected), and
//!   an argument that reads a value sharing storage its place owns
//!   holds that place read until the call ends (`print(v, grow(!v))`
//!   is rejected). The indexes of a viewed place (a view, a slice,
//!   a self) cannot make a write view of its root or move it, whose address is
//!   found before they run (`!ps[0].a[grow(!ps)]` is rejected); an
//!   assignment evaluates its value, then its target's indexes, then
//!   stores, so there they may.
//! * A view may not outlive its root: when a scope ends (normally or by
//!   `break`, `continue` or `!`), no surviving value may hold a loan on a
//!   var declared in it. A returned value, or one stored into something
//!   the caller owns, may only carry views the caller handed in.
//! * Values that own resources (`*T`, `~T`, `List[T]`, anything with drop
//!   glue) cannot be copied implicitly. In a consuming position (binding,
//!   argument, field, return, the branches of an `if`/`match` in such a
//!   position) a place expression of such a type must be written `<x` or
//!   `+x`; only a bare name returned directly moves implicitly. A value
//!   holding a write view cannot be copied either, except as a call
//!   argument (which passes it on for the call).
//! * `<` always leaves its source done (`MoveSource`): `<x` ends a
//!   binding, and `<p.f` or `<v[i]` of an optional empties it to `none`
//!   where its binding can be assigned. `<p.a` of any other field of an
//!   object a local or parameter owns, an optional one among them where
//!   its fields cannot be assigned (a parameter, a capture, a `=!`
//!   local), moves it as a name (Core §5): the var stays live, partly moved
//!   (`Flow.parts`), and a use overlapping a moved path is rejected until
//!   the path is assigned again; `p = x` assigns them all. Any other
//!   field or element is rejected: one that copies would stay as it was,
//!   and of one that moves a viewed or shared parent, a box, a container,
//!   or a type with a `drop` body still owns it. A module's constant
//!   lives for the whole program.
//! * View parameters cannot be dropped or move-captured. Functions may
//!   read module-level constants but not move them.
//! * A match payload binding of `match x` or `match ?x` views the
//!   scrutinee, and one of `match !x` is a write view of it: none can be moved
//!   out. `match <x` moves `x`, and its bindings own what they bind.
//! * A closure literal may only be bound (`f = |...|`), called in place,
//!   given to a call as a callable view (its value carries its
//!   captures' loans), or made owned with `*|...|`; closure bindings
//!   cannot be copied, and `?f` makes a view of one. A
//!   closure body may only use outer locals it captures. Resources
//!   captured into a closure are owned by its environment: the body may
//!   use and clone them but not move, drop or reassign them.
//! * A `defer` body cannot move or drop outer bindings, and is re-checked
//!   against the state at every exit of its scope; an `errdefer` body at
//!   every exit that fails (`!`, or returning an error). At an exit the
//!   path goes on past (`e!`, `e?`, a result that may be an error), its
//!   effects are undone after the check. A `defer` runs after the value
//!   the exit leaves with is formed (a result, a `break` value, a
//!   block's value), so that value's loans are in force while it is
//!   checked (`ExitTo.result`); a returned write view has moved. An exit
//!   that leaves a statement before a call in it starts ends the holds
//!   that wait for that call (`dropPendingHolds`): `!v.push(f()!)` under
//!   `errdefer !v.clear()` is accepted, as `x = f()!` then `!v.push(x)`.

const std = @import("std");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const diag = @import("diag.zig");
const state = @import("ownership/state.zig");

pub const Diagnostic = diag.Diagnostic;
pub const Error = std.mem.Allocator.Error;
pub const Checker = state.Checker;

test {
    _ = @import("ownership/state.zig");
    _ = @import("ownership/live.zig");
    _ = @import("ownership/transfer.zig");
    _ = @import("ownership/rules.zig");
    _ = @import("ownership/origins.zig");
    _ = @import("ownership/exits.zig");
    _ = @import("ownership/generic.zig");
    _ = @import("ownership/types.zig");
    _ = @import("ownership/notes.zig");
}

// =============================================================================
// Tests: each source is checked as the compiler checks it, by sema first,
// whose facts the ownership checker reads
// =============================================================================

const TestRig = struct {
    parser_obj: parser.Parser,
    checker: Checker,
    /// The program's facts (`checkWithSema`).
    ctx: *sema.SemContext,

    fn deinit(self: *TestRig) void {
        self.checker.deinit();
        self.ctx.deinit();
        std.testing.allocator.destroy(self.ctx);
        self.parser_obj.deinit();
    }

    fn hasError(self: *const TestRig, needle: []const u8) bool {
        for (self.checker.diagnostics.items) |d| {
            if (d.severity == .@"error" and std.mem.find(u8, d.message, needle) != null) return true;
        }
        return false;
    }
};

/// Check `source` as the compiler does: sema first, whose facts the
/// ownership checker reads (the jumps' destinations among them).
fn checkWithSema(source: []const u8) !TestRig {
    const a = std.testing.allocator;
    var p = parser.Parser.init(a, source);
    errdefer p.deinit();
    const tree = try p.parseProgram();
    const ctx = try a.create(sema.SemContext);
    errdefer a.destroy(ctx);
    ctx.* = try sema.check(a, source, tree, .{});
    errdefer ctx.deinit();
    if (ctx.hasErrors()) {
        for (ctx.diagnostics.items) |d| std.debug.print("sema: {s}\n", .{d.message});
        return error.TestUnexpectedResult;
    }
    var c = try Checker.init(a, source, ctx);
    errdefer c.deinit();
    try c.check(tree);
    return .{ .parser_obj = p, .checker = c, .ctx = ctx };
}

/// The declarations the loop tests below call.
const loop_prelude =
    \\obj R unique
    \\  n: Int
    \\
    \\fun make() -> R
    \\  R(n: 1)
    \\
    \\sub eat(r: R)
    \\  print(r.n)
    \\
    \\sub look(r: ?R)
    \\  print(r.n)
    \\
    \\fun go() -> Bool
    \\  true
    \\
    \\fun done() -> Bool
    \\  false
    \\
;

/// The declarations the other tests below call, beside `loop_prelude`'s.
const unit_prelude = loop_prelude ++
    \\fun c() -> Bool
    \\  true
    \\
    \\fun pick() -> Bool
    \\  false
    \\
    \\sub poke(r: !R)
    \\  r.n += 1
    \\
    \\sub R.show(?@, other: R)
    \\  print(@n, other.n)
    \\
    \\obj Pair
    \\  a: R
    \\
    \\obj View
    \\  box: ?R
    \\
    \\sub fill(v: !View, b: ?R) keeps b
    \\  v.box = b
    \\
;

fn expectCleanWithSema(source: []const u8) !void {
    var t = try checkWithSema(source);
    defer t.deinit();
    if (t.checker.hasErrors()) {
        for (t.checker.diagnostics.items) |d| std.debug.print("unexpected: {s}\n", .{d.message});
        return error.TestUnexpectedResult;
    }
}

fn expectErrorWithSema(source: []const u8, needle: []const u8) !void {
    var t = try checkWithSema(source);
    defer t.deinit();
    if (!t.hasError(needle)) {
        std.debug.print("expected error containing \"{s}\"; got:\n", .{needle});
        for (t.checker.diagnostics.items) |d| std.debug.print("  {s}\n", .{d.message});
        return error.TestUnexpectedResult;
    }
}

test "use after move" {
    try expectErrorWithSema(unit_prelude ++
        \\sub main()
        \\  packet = make()
        \\  eat(<packet)
        \\  look(?packet)
        \\
    , "use of `packet` after move");
}

test "hello passes" {
    try expectCleanWithSema(unit_prelude ++
        \\sub main()
        \\  print("hello")
        \\
    );
}

test "fixed binding cannot be reassigned" {
    try expectErrorWithSema(unit_prelude ++
        \\sub main()
        \\  user =! make()
        \\  user = make()
        \\
    , "cannot reassign fixed binding `user`");
}

test "explicit shadow allowed" {
    try expectCleanWithSema(unit_prelude ++
        \\sub main()
        \\  x = 1
        \\  print(x)
        \\  new x = 2
        \\  print(x)
        \\
    );
}

test "a temporary read view's loan ends at statement end" {
    try expectCleanWithSema(unit_prelude ++
        \\sub main()
        \\  user = make()
        \\  look(?user)
        \\  poke(!user)
        \\
    );
}

test "a bound view blocks a write" {
    try expectErrorWithSema(unit_prelude ++
        \\sub main()
        \\  user = make()
        \\  r = ?user
        \\  poke(!user)
        \\  look(r)
        \\
    , "cannot change `user` while a read view of it is still in use");
}

test "move in loop body is seen by the next iteration" {
    try expectErrorWithSema(unit_prelude ++
        \\sub main()
        \\  rc = make()
        \\  while go()
        \\    eat(<rc)
        \\
    , "use of `rc` after move");
}

test "move in loop then reassign is fine" {
    try expectCleanWithSema(unit_prelude ++
        \\sub main()
        \\  rc = make()
        \\  while go()
        \\    eat(<rc)
        \\    rc = make()
        \\
    );
}

test "move then break leaves the loop" {
    try expectCleanWithSema(unit_prelude ++
        \\sub main()
        \\  rc = make()
        \\  while go()
        \\    if done()
        \\      eat(<rc)
        \\      break
        \\    look(?rc)
        \\
    );
}

test "move after loop exit via break is still a move" {
    try expectErrorWithSema(unit_prelude ++
        \\sub main()
        \\  rc = make()
        \\  while go()
        \\    eat(<rc)
        \\    break
        \\  look(?rc)
        \\
    , "use of `rc` after move");
}

test "move then continue is seen at the loop head" {
    try expectErrorWithSema(unit_prelude ++
        \\sub main()
        \\  rc = make()
        \\  while go()
        \\    if done()
        \\      eat(<rc)
        \\      continue
        \\    look(?rc)
        \\
    , "use of `rc` after move");
}

test "move then return in a branch keeps the value live after the if" {
    try expectCleanWithSema(unit_prelude ++
        \\sub run(b: Bool)
        \\  rc = make()
        \\  if b
        \\    eat(<rc)
        \\    return
        \\  look(?rc)
        \\
    );
}

test "moves in two match arms are independent" {
    try expectCleanWithSema(unit_prelude ++
        \\sub run(n: Int)
        \\  rc = make()
        \\  match n
        \\    1 => eat(<rc)
        \\    _ => eat(<rc)
        \\
    );
}

test "move in one match arm is a move after the match" {
    try expectErrorWithSema(unit_prelude ++
        \\sub run(n: Int)
        \\  rc = make()
        \\  match n
        \\    1 => eat(<rc)
        \\    _ => look(?rc)
        \\  look(?rc)
        \\
    , "use of `rc` after move");
}

test "a view may not outlive an inner scope" {
    try expectErrorWithSema(unit_prelude ++
        \\sub main()
        \\  a = make()
        \\  r = ?a
        \\  if c()
        \\    b = make()
        \\    r = ?b
        \\  look(r)
        \\
    , "`b` is dropped here, at the end of its scope, while a read view of it is still in use");
}

test "a view chosen by if keeps both roots viewed" {
    try expectErrorWithSema(unit_prelude ++
        \\sub main()
        \\  a = make()
        \\  b = make()
        \\  r = if c()
        \\    ?a
        \\  else
        \\    ?b
        \\  <b
        \\  look(r)
        \\
    , "cannot drop `b` while a read view of it is still in use");
}

test "a view returned from a call views the argument" {
    try expectErrorWithSema(unit_prelude ++
        \\fun view(h: ?R) -> ?R
        \\  h
        \\
        \\sub main()
        \\  h = make()
        \\  r = view(?h)
        \\  <h
        \\  look(r)
        \\
    , "cannot drop `h` while a read view of it is still in use");
}

test "a returned view of a local is rejected" {
    try expectErrorWithSema(unit_prelude ++
        \\fun bad() -> ?R
        \\  user = make()
        \\  ?user
        \\
    , "cannot return a view of `user`, which belongs to this function");
}

test "a returned view of a view parameter is fine" {
    try expectCleanWithSema(unit_prelude ++
        \\fun first(a: ?R, b: ?R) -> ?R
        \\  if pick()
        \\    a
        \\  else
        \\    b
        \\
    );
}

test "a method's self is viewed for the whole call" {
    try expectErrorWithSema(unit_prelude ++
        \\sub main()
        \\  rc = make()
        \\  rc.show(<rc)
        \\
    , "cannot move `rc` while a read view of it is still in use");
}

test "dropping a view parameter is rejected" {
    try expectErrorWithSema(unit_prelude ++
        \\sub kill(rc: ?R)
        \\  <rc
        \\
    , "cannot drop view parameter `rc`");
}

test "move-capturing a view parameter is rejected" {
    try expectErrorWithSema(unit_prelude ++
        \\sub f(rc: ?R)
        \\  g = |<rc|
        \\    look(rc)
        \\  g()
        \\
    , "cannot move-capture view parameter `rc`");
}

test "moving out of a field is rejected" {
    try expectErrorWithSema(unit_prelude ++
        \\sub steal(p: ?Pair)
        \\  eat(<p.a)
        \\
    , "cannot move out of `p.a`");
}

test "a deferred body is checked against the state at scope exit" {
    try expectErrorWithSema(unit_prelude ++
        \\sub main()
        \\  rc = make()
        \\  defer look(?rc)
        \\  if c()
        \\    eat(<rc)
        \\    return
        \\  look(?rc)
        \\
    , "use of `rc` after move");
}

test "a view parameter may store views the caller passed in" {
    try expectCleanWithSema(unit_prelude ++
        \\sub put(v: !View, b: ?R) keeps b
        \\  v.box = b
        \\  fill(!v, b)
        \\
    );
    try expectErrorWithSema(unit_prelude ++
        \\sub put(v: !View)
        \\  b = make()
        \\  fill(!v, ?b)
        \\
    , "cannot let this call store a view of `b` in `v`");
}

test "module-level bindings are visible in functions but cannot be consumed" {
    try expectCleanWithSema(unit_prelude ++
        \\limit = "abc"
        \\
        \\sub main()
        \\  print(limit)
        \\
    );
    try expectErrorWithSema(unit_prelude ++
        \\limit = "abc"
        \\
        \\sub main()
        \\  x = <limit
        \\  print(x)
        \\
    , "cannot move module-level `limit` inside a function");
}
