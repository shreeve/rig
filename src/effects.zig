//! Effects: fallibility and the `raw` boundary.
//!
//! Runs after sema and reads its facts table: the type sema recorded
//! for each expression and the symbol it resolved for each name.
//!
//! Fallibility. A call whose type is `T!` must be the operand of `!`
//! (propagate) or `catch` (handle); the failure path is never implicit.
//! `!` needs a fallible operand and an enclosing function that can fail:
//! a `fun ... -> T!`, or `sub main` (lowered to `!void`). Closure bodies
//! and `defer` / `errdefer` expressions cannot propagate.
//!
//! The raw boundary. Builtins outside the safe list and calls to
//! `extern` functions must be inside a `raw` block.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const types = @import("types.zig");
const diag = @import("diag.zig");

const Sexp = parser.Sexp;
const SemContext = types.SemContext;
const headOf = types.headOf;
const isHead = types.isHead;
const firstSrcPos = diag.firstSrcPos;

pub const Diagnostic = diag.Diagnostic;
pub const Error = std.mem.Allocator.Error;

pub const Checker = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    sema: *const SemContext,
    arena: std.heap.ArenaAllocator,
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,

    /// Current body: may `!` propagate, and how to name it in messages.
    can_propagate: bool = false,
    fn_name: []const u8 = "",
    fn_pos: u32 = 0,
    in_lambda: bool = false,
    in_defer: bool = false,
    raw_depth: usize = 0,

    pub fn initWithSema(allocator: std.mem.Allocator, source: []const u8, sema: *const SemContext) Error!Checker {
        return .{
            .allocator = allocator,
            .source = source,
            .sema = sema,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Checker) void {
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const Checker) bool {
        return diag.hasErrorsIn(self.diagnostics.items);
    }

    pub fn check(self: *Checker, ir: Sexp) Error!void {
        try self.walk(ir, false);
    }

    fn err(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        const msg = try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
        try self.diagnostics.append(self.allocator, .{ .severity = .@"error", .pos = pos, .message = msg });
    }

    fn note(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        const msg = try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
        try self.diagnostics.append(self.allocator, .{ .severity = .note, .pos = pos, .message = msg });
    }

    fn text(self: *Checker, node: Sexp) []const u8 {
        return types.identAt(self.source, node) orelse "";
    }

    /// `handled`: `sexp` is the direct operand of `!` or `catch`.
    fn walk(self: *Checker, sexp: Sexp, handled: bool) Error!void {
        const head = headOf(sexp) orelse return;
        const items = sexp.list;
        switch (head) {
            .@"fun", .@"sub" => try self.walkFunction(sexp),
            .@"drop_decl" => {
                const saved = self.save();
                defer self.restore(saved);
                self.can_propagate = false;
                self.fn_name = "drop";
                self.fn_pos = firstSrcPos(sexp);
                for (items[1..]) |c| try self.walk(c, false);
            },
            .@"lambda" => {
                const saved = self.save();
                defer self.restore(saved);
                self.can_propagate = false;
                self.in_lambda = true;
                self.in_defer = false;
                for (items[1..]) |c| try self.walk(c, false);
            },
            .@"defer", .@"errdefer" => {
                const prev = self.in_defer;
                self.in_defer = true;
                defer self.in_defer = prev;
                for (items[1..]) |c| try self.walk(c, false);
            },
            .@"propagate" => {
                try self.checkPropagate(items[1]);
                try self.walk(items[1], true);
            },
            .@"catch" => {
                try self.walk(items[1], true);
                for (items[2..]) |c| try self.walk(c, false);
            },
            .@"call" => try self.walkCall(sexp, handled),
            .@"raw_block" => {
                self.raw_depth += 1;
                defer self.raw_depth -= 1;
                for (items[1..]) |c| try self.walk(c, false);
            },
            .@"builtin" => {
                if (items[1] == .src) {
                    const name = self.text(items[1]);
                    if (!isSafeBuiltin(name) and self.raw_depth == 0) {
                        try self.err(items[1].src.pos, "builtin `@{s}` is not in the safe whitelist; wrap in a `raw` block. Safe builtins: `@sizeOf`, `@alignOf`, `@TypeOf`, `@typeName`.", .{name});
                    }
                }
                for (items[2..]) |c| try self.walk(c, false);
            },
            else => for (items[1..]) |c| try self.walk(c, false),
        }
    }

    const Saved = struct { can_propagate: bool, fn_name: []const u8, fn_pos: u32, in_lambda: bool, in_defer: bool };

    fn save(self: *Checker) Saved {
        return .{ .can_propagate = self.can_propagate, .fn_name = self.fn_name, .fn_pos = self.fn_pos, .in_lambda = self.in_lambda, .in_defer = self.in_defer };
    }

    fn restore(self: *Checker, s: Saved) void {
        self.can_propagate = s.can_propagate;
        self.fn_name = s.fn_name;
        self.fn_pos = s.fn_pos;
        self.in_lambda = s.in_lambda;
        self.in_defer = s.in_defer;
    }

    fn walkFunction(self: *Checker, node: Sexp) Error!void {
        const items = node.list;
        const saved = self.save();
        defer self.restore(saved);
        const is_sub = items[0].tag == .@"sub";
        self.fn_name = self.text(items[1]);
        self.fn_pos = types.srcPos(items[1], 0);
        self.in_lambda = false;
        self.in_defer = false;
        self.can_propagate = if (is_sub)
            std.mem.eql(u8, self.fn_name, "main")
        else
            isHead(items[3], .@"error_union");
        try self.walk(items[items.len - 1], false);
    }

    fn checkPropagate(self: *Checker, operand: Sexp) Error!void {
        const pos = firstSrcPos(operand);
        if (self.in_defer) {
            try self.err(pos, "cannot use `!` inside `defer`; a deferred expression cannot propagate failure, so handle it with `catch`", .{});
        } else if (!self.can_propagate) {
            if (self.in_lambda) {
                try self.err(pos, "use of `!` propagation requires a fallible enclosing function; a closure body cannot propagate failure, so handle it with `catch`", .{});
            } else {
                try self.err(pos, "use of `!` propagation requires the enclosing function `{s}` to declare a fallible return type (`-> T!`)", .{self.fn_name});
                if (self.fn_pos != 0) try self.note(self.fn_pos, "`{s}` declared here", .{self.fn_name});
            }
        }
        const ty = self.sema.typeOf(operand) orelse return;
        switch (self.sema.types.get(ty)) {
            .fallible, .unknown, .invalid => {},
            else => try self.err(pos, "`!` needs a fallible operand; this expression has type `{s}` and cannot fail", .{try types.formatTypeIn(self.sema, self.arena.allocator(), ty)}),
        }
    }

    fn walkCall(self: *Checker, node: Sexp, handled: bool) Error!void {
        const items = node.list;
        const callee = items[1];

        if (!handled) {
            if (self.sema.typeOf(node)) |ty| {
                if (self.sema.types.get(ty) == .fallible) {
                    const name = try self.calleeName(callee);
                    try self.err(firstSrcPos(callee), "fallible call to `{s}` must be wrapped with `!` (propagate) or `catch` (handle)", .{name});
                    if (self.sema.symbolOf(callee)) |id| {
                        const sym = self.sema.symbols.items[id];
                        if (sym.decl_pos != types.builtin_decl_pos) try self.note(sym.decl_pos, "`{s}` declared as fallible here", .{name});
                    }
                }
            }
        }

        if (self.raw_depth == 0) {
            if (self.externCallee(callee)) |name| {
                try self.err(firstSrcPos(callee), "call to extern function `{s}` requires `raw` block; wrap the call in `raw INDENT body OUTDENT`. Extern declarations are the FFI boundary and bypass Rig's ownership and effect contracts.", .{name});
            }
        }

        for (items[1..]) |c| try self.walk(c, false);
    }

    /// How the callee is spelled, for messages: `f`, `a.f`, or `.m`.
    fn calleeName(self: *Checker, callee: Sexp) Error![]const u8 {
        if (callee == .src) return self.text(callee);
        if (isHead(callee, .@"member")) {
            const obj = callee.list[1];
            const name = self.text(callee.list[2]);
            if (obj == .src) return std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ self.text(obj), name });
            return name;
        }
        return "expression";
    }

    /// The spelled name if `callee` resolves to an extern function,
    /// here or in an imported module.
    fn externCallee(self: *Checker, callee: Sexp) ?[]const u8 {
        if (callee == .src) {
            const id = self.sema.symbolOf(callee) orelse return null;
            return if (self.sema.symbols.items[id].kind == .@"extern") self.text(callee) else null;
        }
        if (!isHead(callee, .@"member")) return null;
        const obj = callee.list[1];
        const id = self.sema.symbolOf(obj) orelse return null;
        if (self.sema.symbols.items[id].kind != .module) return null;
        const origin = self.sema.module_refs.get(id) orelse return null;
        const foreign = self.sema.foreign_semas.get(origin) orelse return null;
        if (foreign.scopes.items.len < 2) return null;
        const name = self.text(callee.list[2]);
        const fid = foreign.lookupInScopeOnly(1, name) orelse return null;
        const fsym = foreign.symbols.items[fid];
        if (fsym.kind != .@"extern" or !fsym.flags.is_public) return null;
        return std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ self.text(obj), name }) catch name;
    }
};

/// Builtins allowed outside `raw`: compile-time type queries only.
fn isSafeBuiltin(name: []const u8) bool {
    const safe = [_][]const u8{ "sizeOf", "alignOf", "TypeOf", "typeName" };
    for (safe) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

const Run = struct {
    p: parser.Parser,
    sema: SemContext,
    eff: Checker,

    fn deinit(self: *Run) void {
        self.eff.deinit();
        self.sema.deinit();
        self.p.deinit();
    }

    fn has(self: *const Run, needle: []const u8) bool {
        for (self.eff.diagnostics.items) |d| {
            if (std.mem.indexOf(u8, d.message, needle) != null) return true;
        }
        return false;
    }
};

fn run(source: []const u8) !Run {
    const allocator = std.testing.allocator;
    var r: Run = undefined;
    r.p = parser.Parser.init(allocator, source);
    errdefer r.p.deinit();
    const ir = try r.p.parseProgram();
    r.sema = try types.check(allocator, source, ir);
    errdefer r.sema.deinit();
    r.eff = try Checker.initWithSema(allocator, source, &r.sema);
    try r.eff.check(ir);
    return r;
}

test "effects: unwrapped fallible call is an error" {
    var r = try run(
        \\fun load(id: Int) -> Int!
        \\  id
        \\
        \\sub main()
        \\  x = load(1)
        \\  print(x)
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.has("fallible call to `load` must be wrapped"));
}

test "effects: fallible method call without `!`" {
    var r = try run(
        \\struct U
        \\  n: Int
        \\
        \\  fun check(?self) -> Int!
        \\    self.n
        \\
        \\sub main()
        \\  u = U(n: 1)
        \\  print(u.check())
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.has("fallible call to `u.check` must be wrapped"));
}

test "effects: `!` inside a fallible function and main is fine" {
    var r = try run(
        \\fun load(id: Int) -> Int!
        \\  id
        \\
        \\fun twice(id: Int) -> Int!
        \\  load(id)! + load(id)!
        \\
        \\sub main()
        \\  print(twice(2)!)
        \\
    );
    defer r.deinit();
    try std.testing.expect(!r.eff.hasErrors());
}

test "effects: `!` on a value that cannot fail" {
    var r = try run(
        \\fun one() -> Int
        \\  1
        \\
        \\sub main()
        \\  print(one()!)
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.has("needs a fallible operand"));
}

test "effects: closures and defer cannot propagate" {
    var r = try run(
        \\fun g() -> Int!
        \\  3
        \\
        \\sub main()
        \\  defer print(g()!)
        \\  n = 1
        \\  c = |+n|
        \\    print(g()! + n)
        \\  c()
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.has("inside `defer`"));
    try std.testing.expect(r.has("a closure body cannot propagate"));
}
