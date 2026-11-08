//! The exporter of `rig-oracle --lambda`: a program λRig can express,
//! written as an S-expression of λRig's forms (formal/LambdaRig/Syntax.lean),
//! for `lrig` (formal/LRig.lean) to check and run beside bin/rig.
//!
//! λRig has Ints, boxes holding an Int (`^Int`), and views of either. A
//! program is in scope when it is one `sub main()` whose statements are
//! bindings, assignments, `<x`, and `print` calls, over integer literals,
//! names, `<x`, `+x`, `^e`, `?x`, `!x`, and `+`. Every value's kind then
//! follows from the syntax, so the exporter needs no types. It maps each
//! form to the λRig form CORE gives it, one to one, and leaves out
//! anything else, saying why: it is the trusted part of the agreement
//! test (test/cli/agree.sh), so it stays small and syntactic.
//!
//! The forms: `(lit n)`, `(name x)`, `(move x)`, `(clone x)`, `(box e)`,
//! `(lend read x)`, `(lend write x)`, `(assign x e)`, `(drop x)`,
//! `(add a b)`, `(out e)`, `(seq a b)`, `(let x e body)`.
//!
//! Left out, since λRig's meaning differs from Rig's there: a bare name
//! of a box (Rig reads it in place, or moves it; λRig's checker rejects
//! it), a view assigned to a view (Rig re-points it, CORE §6), a write
//! view of a box read bare, and `+` over a box.

const std = @import("std");
const lib = @import("rig_lib");
const lower = @import("lower.zig");

const parser = lib.parser;
const ir = parser.ir;
const Sexp = parser.Sexp;

/// What a name holds, as far as λRig goes.
const Kind = enum {
    int,
    box,
    /// A read view of an Int, or of a box.
    read_int,
    read_box,
    /// A write view of an Int, or of a box.
    write_int,
    write_box,

    fn owner(k: Kind) bool {
        return k == .int or k == .box;
    }
};

pub const Outside = error{ Outside, OutOfMemory };

pub const Exporter = struct {
    a: std.mem.Allocator,
    src: []const u8,
    out: std.ArrayList(u8) = .empty,
    names: std.StringHashMapUnmanaged(Kind) = .empty,
    /// Why the program is left out.
    why: []const u8 = "",

    fn outside(self: *Exporter, why: []const u8) Outside {
        self.why = why;
        return error.Outside;
    }

    fn w(self: *Exporter, s: []const u8) !void {
        try self.out.appendSlice(self.a, s);
    }

    fn name(self: *Exporter, s: Sexp) Outside![]const u8 {
        if (s != .src or s.src.id != 0) return self.outside("a name the rewrite made, or not a name");
        const t = lower.leafText(s, self.src);
        if (t.len == 0 or !(std.ascii.isAlphabetic(t[0]) or t[0] == '_')) return self.outside("not a name");
        for (t) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return self.outside("not a name");
        return t;
    }

    fn kindOf(self: *Exporter, s: Sexp) Outside!Kind {
        const n = try self.name(s);
        return self.names.get(n) orelse self.outside("a name main does not bind");
    }

    /// An expression; gives the kind of its value.
    fn expr(self: *Exporter, e: Sexp) Outside!Kind {
        switch (e) {
            .src => {
                const t = lower.leafText(e, self.src);
                if (t.len > 0 and std.ascii.isDigit(t[0])) {
                    for (t) |c| if (!std.ascii.isDigit(c)) return self.outside("a number that is not a plain integer");
                    if (t.len > 18) return self.outside("a large integer");
                    try self.w("(lit ");
                    try self.w(t);
                    try self.w(")");
                    return .int;
                }
                const k = try self.kindOf(e);
                const n = try self.name(e);
                switch (k) {
                    .box => return self.outside("a bare name of a box"),
                    .write_box => return self.outside("a bare name of a write view of a box"),
                    else => {},
                }
                try self.w("(name ");
                try self.w(n);
                try self.w(")");
                return switch (k) {
                    .write_int => .int,
                    else => k,
                };
            },
            .list => {},
            else => return self.outside("an unusual expression"),
        }
        const tag = e.kind() orelse return self.outside("an unusual expression");
        switch (tag) {
            .paren => return self.expr(ir.get(e, .value)),
            .move, .clone => {
                const operand = ir.get(e, .operand);
                const k = try self.kindOf(operand);
                try self.w(if (tag == .move) "(move " else "(clone ");
                try self.w(try self.name(operand));
                try self.w(")");
                if (tag == .move) return k;
                return switch (k) {
                    .int, .read_int, .write_int => .int,
                    .box, .read_box, .write_box => .box,
                };
            },
            .read, .write => {
                const operand = ir.get(e, .operand);
                const k = try self.kindOf(operand);
                if (!k.owner()) return self.outside("a lend of a view");
                try self.w(if (tag == .read) "(lend read " else "(lend write ");
                try self.w(try self.name(operand));
                try self.w(")");
                return switch (k) {
                    .int => if (tag == .read) .read_int else .write_int,
                    else => if (tag == .read) .read_box else .write_box,
                };
            },
            .box => {
                try self.w("(box ");
                const k = try self.expr(ir.get(e, .operand));
                if (k != .int) return self.outside("a box of something that is not an Int");
                try self.w(")");
                return .box;
            },
            .@"+" => {
                try self.w("(add ");
                const l = try self.expr(ir.get(e, .left));
                try self.w(" ");
                const r = try self.expr(ir.get(e, .right));
                try self.w(")");
                if (!(l == .int or l == .read_int) or !(r == .int or r == .read_int)) return self.outside("`+` of something that is not an Int");
                return .int;
            },
            else => return self.outside("a form λRig does not have"),
        }
    }

    /// The statements from `stmts[i]` on, then `(lit 0)`.
    fn stmts(self: *Exporter, list: []const Sexp, i: usize) Outside!void {
        if (i == list.len) return self.w("(lit 0)");
        const s = list[i];
        const tag = s.kind() orelse return self.outside("a statement that is a bare value");
        switch (tag) {
            .set => {
                if (ir.Set.type(s) != .nil) return self.outside("a binding with a type");
                const target = ir.Set.target(s);
                const n = try self.name(target);
                const op = lib.rig.bindingKindOf(ir.Set.op(s));
                const rhs = ir.Set.value(s);
                if (op == .default and !self.names.contains(n)) {
                    try self.w("(let ");
                    try self.w(n);
                    try self.w(" ");
                    const k = try self.expr(rhs);
                    try self.w(" ");
                    try self.names.put(self.a, n, k);
                    try self.stmts(list, i + 1);
                    try self.w(")");
                    return;
                }
                if (op == .fixed or op == .shadow) return self.outside("a fixed or shadowing binding (`=!`, `new`)");
                const k = self.names.get(n) orelse return self.outside("a compound assignment to an unbound name");
                try self.w("(seq (assign ");
                try self.w(n);
                try self.w(" ");
                const vk = switch (op) {
                    .default => try self.expr(rhs),
                    .@"+=" => blk: {
                        if (!(k == .int or k == .write_int)) return self.outside("`+=` of something that is not an Int");
                        try self.w("(add (name ");
                        try self.w(n);
                        try self.w(") ");
                        const r = try self.expr(rhs);
                        try self.w(")");
                        if (!(r == .int or r == .read_int)) return self.outside("`+=` of something that is not an Int");
                        break :blk Kind.int;
                    },
                    else => return self.outside("an assignment λRig does not have"),
                };
                const fits = switch (k) {
                    .int => vk == .int or vk == .read_int,
                    .box => vk == .box,
                    .write_int => vk == .int or vk == .read_int,
                    .write_box => vk == .box,
                    .read_int, .read_box => false,
                };
                if (!fits) return self.outside("an assignment that re-points a view, or changes a kind");
                try self.w(") ");
                try self.stmts(list, i + 1);
                try self.w(")");
            },
            .drop => {
                const target = ir.Drop.target(s);
                const n = try self.name(target);
                _ = try self.kindOf(target);
                try self.w("(seq (drop ");
                try self.w(n);
                try self.w(") ");
                try self.stmts(list, i + 1);
                try self.w(")");
            },
            .call => {
                const callee = ir.Call.callee(s);
                if (callee != .src or !std.mem.eql(u8, lower.leafText(callee, self.src), "print")) return self.outside("a call other than `print`");
                if (ir.Call.task(s) != .nil) return self.outside("a task");
                const args = ir.Call.args(s);
                if (args.len == 0) return self.outside("`print()` of nothing");
                for (args) |arg| {
                    try self.w("(seq (out ");
                    _ = try self.expr(arg);
                    try self.w(") ");
                }
                try self.stmts(list, i + 1);
                for (args) |_| try self.w(")");
            },
            else => return self.outside("a statement λRig does not have"),
        }
    }
};

/// Export a module's program: its S-expression, or why it is outside.
pub fn exportModule(a: std.mem.Allocator, m: *const lib.modules.Module) !union(enum) { program: []const u8, outside: []const u8 } {
    const decls = ir.Module.decls(m.ir);
    if (decls.len != 1) return .{ .outside = "more than one declaration" };
    const d = decls[0];
    if (!d.isKind(.sub)) return .{ .outside = "not a `sub main()`" };
    if (!std.mem.eql(u8, lower.leafText(ir.get(d, .name), m.source), "main")) return .{ .outside = "not a `sub main()`" };
    if (ir.get(d, .params) != .nil and ir.get(d, .params).items().len > 1) return .{ .outside = "a main with parameters" };
    if (ir.get(d, .fails) != .nil) return .{ .outside = "a main that can fail" };
    const body = ir.get(d, .body);
    if (body == .nil) return .{ .outside = "no body" };
    var ex: Exporter = .{ .a = a, .src = m.source };
    ex.stmts(ir.Block.stmts(body), 0) catch |err| switch (err) {
        error.Outside => return .{ .outside = ex.why },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .program = ex.out.items };
}
