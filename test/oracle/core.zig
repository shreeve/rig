//! The core the oracle checks: a function body lowered to vars and
//! straight-line ops in basic blocks, with every statement temporary a
//! hidden var and the evaluation order written out (lower.zig). The
//! dataflow (flow.zig) reads nothing else.

const std = @import("std");
const lib = @import("rig_lib");
const kinds = @import("kinds.zig");

pub const TypeId = lib.sema.TypeId;
pub const VarId = u32;
pub const LoanId = u32;
pub const BlockId = u32;

/// The checks, each named for the Core sentence it enforces (flow.zig).
pub const Rule = enum {
    /// s1, s2: a name is used only while it holds a value.
    C1,
    /// s1: a bare name of an owner, handle, or write view never copies.
    C2,
    /// s2, §5: only a whole binding moves; `<p.f` takes an optional.
    C3,
    /// s5, s6: no access conflicts with a live loan.
    C4,
    /// s3, s6, §3: nothing is dropped while a loan of it is live.
    C5,
    /// s7: a result views only what the function was lent.
    C6,
    /// §5: nothing moves out through a view.
    C7,
    /// §6: parameters and fixed bindings are never reassigned.
    B1,
};

pub const Finding = struct {
    rule: Rule,
    pos: u32,
    reason: []const u8,
};

pub const Var = struct {
    name: []const u8,
    ty: TypeId,
    kind: kinds.Kind,
    /// Values of the type may carry a loan (a view, or something holding one).
    holds_views: bool,
    /// Values may hold a `?T`, `!T`, or slice: a loan that points at a
    /// place, which a value copied out through it does not carry.
    holds_pointers: bool,
    /// Dropping it runs a user `drop` body, which reads what it views.
    drop_reads: bool,
    hidden: bool = false,
    param: bool = false,
    /// A binding that sees an owner's payload through a view (`match s`,
    /// `if ?o as x`): it reads and lends what it sees, never moves it.
    alias: bool = false,
    pos: u32,
};

pub const Mode = enum { read, write, reserved };

/// One step of a place's path: a field by name, or any element.
pub const Step = union(enum) { field: []const u8, elem };

/// The record of one lend. A loan on a write view's referent (`!w` or
/// `?w` with `w: !T`, a reborrow) is `deref`: it limits `w`'s uses, but
/// `w` going out of scope does not end what it views.
pub const Loan = struct {
    root: VarId,
    path: []const Step,
    mode: Mode,
    deref: bool = false,
    /// The caller's loan a parameter carries: on nothing here.
    external: bool = false,
    /// Lends of one `swap` or `replace` call: their places may be
    /// different fields of one value.
    group: u32 = 0,
    /// What the lent place holds can hold a view: a store through a
    /// write loan may leave one there.
    stores_views: bool = false,
    /// The lend made a `?T` or `!T` pointing at the place (not a slice
    /// or a String, which view its bytes).
    pointer: bool = true,
    /// The place reaches a Text, whose bytes a String made through the
    /// pointer may view.
    reaches_text: bool = false,
    pos: u32,

    /// Whether a value of a type that holds views but no pointer or
    /// slice (a String, a struct of Strings) can carry this loan: a
    /// String views only a Text's bytes, so it carries a loan on a
    /// place that reaches a Text, never one on a String it was copied
    /// out of or on an array (Core s7).
    pub fn reachesStrings(l: Loan) bool {
        return l.external or l.reaches_text;
    }
};

pub const AccessKind = enum {
    /// Copy or read in place: conflicts with a live write or reserved
    /// write loan that is active.
    read,
    /// A reserved write lend (a write receiver, two-phase): conflicts
    /// with a live write or reserved loan.
    reserve,
    /// Write, write lend, take, or assign: conflicts with any live loan.
    write,
    /// Move or drop of the whole var: conflicts with any live loan.
    whole,
};

pub const Access = struct {
    root: VarId,
    path: []const Step = &.{},
    deref: bool = false,
    kind: AccessKind,
    /// The loan an activation of a reserved lend ignores: its own.
    except: ?LoanId = null,
    group: u32 = 0,
};

/// One op. Its effect, in order: every var in `reads`, `moves`, and
/// `uses` must hold a value (C1); `access` is checked against the loans
/// live here (C4); the loans of `reads` and `moves` and the new `loan`
/// flow into `def` (replacing what it held) or `weak` (added to it),
/// filtered by whether its type can hold a view; `moves` are left
/// empty; after a call, each var in `gains` takes the flowing loans (the
/// call may have stored a view in it); `kill` drops a var (C5); `ret`
/// checks what leaves the function (C6).
pub const Op = struct {
    pos: u32,
    what: What,
    reads: []const VarId = &.{},
    moves: []const VarId = &.{},
    uses: []const VarId = &.{},
    /// Vars a return hands back to the caller when they hold a value: the
    /// write-view parameters (live to the end, never required to hold one).
    keep: []const VarId = &.{},
    def: ?VarId = null,
    weak: ?VarId = null,
    loan: ?LoanId = null,
    access: ?Access = null,
    gains: []const VarId = &.{},
    /// Write views the op stores through, or hands to a call: the vars
    /// their write loans are on take the flowing loans too.
    through: []const VarId = &.{},
    kill: ?VarId = null,
    /// For a kill: the end of a statement or scope ("does not live long
    /// enough"), rather than `-x`.
    scope_end: bool = false,
    /// A view reached through a slice or String view stored in `reads`:
    /// it carries that view's loans, not the loans that point at their
    /// holder (Core s7). The flow leaves out pointer loans.
    carry: bool = false,

    pub const What = enum { copy, move, take, lend, make, call, assign, use, kill, ret };
};

pub const Block = struct {
    ops: std.ArrayList(Op) = .empty,
    succs: std.ArrayList(BlockId) = .empty,
};

pub const Func = struct {
    vars: std.ArrayList(Var) = .empty,
    loans: std.ArrayList(Loan) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    /// Vars that hold a value on entry: the parameters.
    params: std.ArrayList(VarId) = .empty,
    /// The first finding the lowering made (C2, C3, C7).
    early: ?Finding = null,
};

fn vn(func: *const Func, v: VarId, buf: []u8) []const u8 {
    return std.mem.print(buf, "{s}#{d}", .{ func.vars.items[v].name, v }) catch "?";
}

pub fn dump(func: *const Func, w: *std.Io.Writer) !void {
    var nb: [128]u8 = undefined;
    try w.print("vars:", .{});
    for (func.vars.items, 0..) |v, i| try w.print(" {d}={s}:{s}", .{ i, v.name, @tagName(v.kind) });
    try w.print("\nloans:", .{});
    for (func.loans.items, 0..) |l, i| {
        try w.print(" L{d}={s}{s}", .{ i, @tagName(l.mode), if (l.deref) "*" else "" });
        if (l.external) try w.writeAll("(caller)") else try w.print("({s})", .{vn(func, l.root, &nb)});
    }
    try w.writeAll("\n");
    if (func.early) |f| try w.print("early: {s} @{d} {s}\n", .{ @tagName(f.rule), f.pos, f.reason });
    for (func.blocks.items, 0..) |b, bi| {
        try w.print("b{d}:\n", .{bi});
        for (b.ops.items) |op| {
            try w.print("  @{d} {s}", .{ op.pos, @tagName(op.what) });
            if (op.def) |d| try w.print(" def={s}", .{vn(func, d, &nb)});
            if (op.weak) |d| try w.print(" weak={s}", .{vn(func, d, &nb)});
            if (op.kill) |d| try w.print(" kill={s}", .{vn(func, d, &nb)});
            if (op.loan) |l| try w.print(" new=L{d}", .{l});
            for (op.reads) |v| try w.print(" r:{s}", .{vn(func, v, &nb)});
            for (op.moves) |v| try w.print(" m:{s}", .{vn(func, v, &nb)});
            for (op.uses) |v| try w.print(" u:{s}", .{vn(func, v, &nb)});
            for (op.gains) |v| try w.print(" g:{s}", .{vn(func, v, &nb)});
            for (op.keep) |v| try w.print(" k:{s}", .{vn(func, v, &nb)});
            if (op.access) |acc| try w.print(" {s}({s}{s})", .{ @tagName(acc.kind), vn(func, acc.root, &nb), if (acc.deref) "*" else "" });
            try w.writeAll("\n");
        }
        try w.writeAll("  ->");
        for (b.succs.items) |s| try w.print(" b{d}", .{s});
        try w.writeAll("\n");
    }
}
