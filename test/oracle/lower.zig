//! Lowering a function body to the core (core.zig).
//!
//! The lowering decides, once per expression, what it hands over (Core
//! §3): a place read where it stands, a place copied, moved, taken, or
//! lent, or a made value held in a hidden var. Every temporary is a var
//! of its statement, dropped at the statement's end, last made first;
//! a header (an `if` or `while` condition, a `for` source) is its own
//! statement. Evaluation order is written out: a call's callee and
//! receiver, then its arguments left to right; an assignment's value,
//! then the target's indexes, then the store (Core §6).
//!
//! What the oracle does not model yet makes the lowering abstain
//! (`error.Abstain`, with `abstain_reason`), so the dataflow never
//! guesses. A rule the lowering itself decides (C2, C3, C7) ends it with
//! `error.Found`, recorded in `Func.early`.

const std = @import("std");
const lib = @import("rig_lib");
const core = @import("core.zig");
const kinds = @import("kinds.zig");
const flow = @import("flow.zig");
const Unit = @import("main.zig").Unit;

const sema = lib.sema;
const parser = lib.parser;
const rig = lib.rig;
const ir = parser.ir;
const Sexp = parser.Sexp;
const TypeId = sema.TypeId;
const SymbolId = sema.SymbolId;
const VarId = core.VarId;
const BlockId = core.BlockId;
const Step = core.Step;

/// Why the last lowering abstained.
pub var abstain_reason: []const u8 = "";

pub const Error = error{ Abstain, Found, OutOfMemory };

fn abstain(why: []const u8) Error {
    abstain_reason = why;
    return error.Abstain;
}

/// What the context does with a value (Core §3).
const How = enum {
    /// Reads it: a `print` or `Text` argument, an operand, a condition,
    /// an object whose field or element is read. Never moves a name.
    read,
    /// Takes it: a binding, an owned parameter, a stored field or
    /// element, a `break` value.
    take,
    /// Takes it as the function's result: a bare local moves (Core s1).
    ret,
    /// A view parameter's argument: a lend, or a view copied.
    view,
};

/// A place: a var and the fields and elements on the way.
const Place = struct {
    root: VarId,
    path: []const Step,
    /// The place's own type.
    ty: TypeId,
    /// Whether the path passes through a view: then the place is not
    /// the root's own storage but what the view sees.
    via: Via = .own,
    /// A slice, `x[a..b]`: a view of part of the place, not a value
    /// stored there (Core §4).
    slice: bool = false,
    /// For a slice, the type of what is sliced.
    slice_of: TypeId = 0,
    /// The path passes through a `[]T` or String stored in a place or
    /// seen through a view: what it reaches carries that view's loans,
    /// not a loan on its holder (Core s7).
    carry: bool = false,
    /// The path passed through a write view before it carried: reaching
    /// the stored view still reads the write view's place.
    under_write: bool = false,
    /// The path passes through a counted handle: what it reaches is the
    /// box's, which a loan on the handle keeps alive (Core s8: handles
    /// only read).
    handle: bool = false,

    const Via = enum { own, read, write };
};

/// A scope (a block's bindings) or a statement's temporaries; leaving
/// either drops its vars, last first, and runs its scope's `defer`s.
const Region = struct {
    vars: std.ArrayList(VarId) = .empty,
    defers: std.ArrayList(Deferred) = .empty,
};

/// A `defer` or `errdefer` its scope has reached: its body runs at
/// every exit of the scope, after the vars declared after it are
/// dropped and before the ones declared before it (Core §7; SPEC
/// "defer and errdefer").
const Deferred = struct {
    body: Sexp,
    /// An `errdefer`: it runs only on the exits where the function fails.
    err: bool,
    /// How many of the region's vars were declared before it.
    at: usize,
};

/// Whether an exit fails the function, which runs its `errdefer`s.
const Fails = enum { no, yes, maybe };

const Loop = struct {
    label: ?[]const u8,
    brk: BlockId,
    /// Null for a `match`, which only `break :label` leaves.
    cont: ?BlockId,
    /// The region depth a `break` unwinds to.
    depth: usize,
    /// The region depth a `continue` unwinds to, when it differs.
    cont_depth: ?usize = null,
    value: ?VarId,
};

/// Lower one function to the core. Rules once planned and now built hold
/// in every run: a type holding a `Cell` is unique (Core §1), a bare
/// place a `for` walks or an `if … as` or `while … as` binds is read
/// where it stands, as `?p`, and a bare `break x` of an owner declared in
/// the loop moves it (Core s1).
pub fn lowerUnit(a: std.mem.Allocator, m: *const lib.modules.Module, unit: Unit) !core.Func {
    var l: Lowerer = .{
        .a = a,
        .ctx = m.sema,
        .parser = m.parser,
        .src = m.source,
        .kinds = kinds.Kinds.init(a, m.sema, true),
        .planned = true,
        .module = m,
    };
    l.run(unit) catch |err| switch (err) {
        error.Found => {},
        else => |e| return e,
    };
    try l.finish();
    return l.f;
}

/// A generic function's declaration, in its module.
const Callee = struct {
    module: *const lib.modules.Module,
    decl: Sexp,
    /// For a method of a generic type: the type's declaration.
    owner: Sexp = .nil,
};

/// The program's modules, for the generic bodies a call runs (set per
/// program by main.zig), and what is known of each body.
pub var program_modules: []const lib.modules.Module = &.{};
pub var copies_memo: std.AutoHashMapUnmanaged(struct { u32, u32 }, Copies) = .empty;
pub const Copies = enum { pending, none, some };

/// The parameters a function's `from` clause names (`-> T from a, b`),
/// a bit each, read from the declaration in its module's IR: the
/// function or method whose name is at `pos`. Null when it writes none.
fn declaredFrom(ctx: *const sema.SemContext, pos: u32) ?u64 {
    const m = for (program_modules) |*m| {
        if (m.sema == ctx) break m;
    } else return null;
    if (m.ir == .nil) return null;
    const d = findFun(m.ir, pos) orelse return null;
    const names = ir.get(d, .origins);
    if (names == .nil) return null;
    var mask: u64 = 0;
    for (names.items()) |n| {
        const text = n.getText(m.source);
        for (ir.get(d, .params).items(), 0..) |p, i| {
            const pn = sema.paramNameNode(p) orelse continue;
            if (std.mem.eql(u8, pn.getText(m.source), text) and i < 64) mask |= @as(u64, 1) << @intCast(i);
        }
    }
    return mask;
}

/// The `fun` (or `extern fun`) whose name is at `pos`, among `node`'s
/// declarations and members.
fn findFun(node: Sexp, pos: u32) ?Sexp {
    const kind = node.kind() orelse return null;
    switch (kind) {
        .fun, .extern_fun => {
            const n = ir.get(node, .name);
            return if (n == .src and n.src.pos == pos) node else null;
        },
        .module, .zig_extern, .@"pub", .@"struct", .@"enum", .generic_struct, .generic_enum => for (node.items()) |c| {
            if (findFun(c, pos)) |f| return f;
        },
        else => {},
    }
    return null;
}

fn moduleById(id: u32) ?*const lib.modules.Module {
    for (program_modules) |*m| if (m.id == id) return m;
    return null;
}

/// The `fun` or `sub` of a module named `name` (declared at `pos`,
/// when known), with a body.
fn findDecl(m: *const lib.modules.Module, name: []const u8, pos: ?u32) ?Callee {
    if (m.ir == .nil) return null;
    for (ir.Module.decls(m.ir)) |d0| {
        const d = if (d0.isKind(.@"pub")) ir.Pub.decl(d0) else d0;
        if (!d.isKind(.fun) and !d.isKind(.sub)) continue;
        const n = ir.get(d, .name);
        if (n != .src or !std.mem.eql(u8, n.getText(m.source), name)) continue;
        if (pos) |p| if (n.src.pos != p) continue;
        if (ir.get(d, .body) == .nil) return null;
        return .{ .module = m, .decl = d };
    }
    return null;
}

/// Whether a generic body, and every generic body it calls at its own
/// type parameters, never copies a value of a type parameter: the body
/// lowers and checks clean in generic mode (SPEC "Generic bodies"). A
/// body on the way (recursion) is assumed not to copy.
fn copiesNoT(a: std.mem.Allocator, c: Callee) Error!bool {
    const key = .{ @as(u32, @intCast(c.module.id)), c.module.parser.span(c.decl).start };
    if (copies_memo.get(key)) |known| return known != .some;
    try copies_memo.put(a, key, .pending);
    const saved_reason = abstain_reason;
    defer abstain_reason = saved_reason;
    var l: Lowerer = .{
        .a = a,
        .ctx = c.module.sema,
        .parser = c.module.parser,
        .src = c.module.source,
        .kinds = kinds.Kinds.init(a, c.module.sema, true),
        .planned = true,
        .module = c.module,
    };
    var ok = true;
    l.run(.{ .name = "", .decl = c.decl, .owner = c.owner, .generic_owner = c.owner != .nil }) catch |err| switch (err) {
        error.Found, error.Abstain => ok = false,
        else => |x| return x,
    };
    if (ok and l.f.early != null) ok = false;
    if (ok) try l.finish();
    if (ok and try flow.check(a, &l.f) != null) ok = false;
    if (ok and l.copies_t) ok = false;
    if (ok) for (l.t_calls.items) |dep| {
        if (!try copiesNoT(a, dep)) {
            ok = false;
            break;
        }
    };
    try copies_memo.put(a, key, if (ok) .none else .some);
    return ok;
}

const Lowerer = struct {
    a: std.mem.Allocator,
    ctx: *const sema.SemContext,
    parser: *const parser.Parser,
    src: []const u8,
    kinds: kinds.Kinds,
    planned: bool,
    f: core.Func = .{},
    cur: ?BlockId = null,
    vars: std.AutoHashMapUnmanaged(SymbolId, VarId) = .empty,
    regions: std.ArrayList(Region) = .empty,
    loops: std.ArrayList(Loop) = .empty,
    /// The label of the statement being lowered, from `(labeled ...)`.
    label: ?[]const u8 = null,
    write_params: std.ArrayList(VarId) = .empty,
    groups: u32 = 0,
    /// Roots whose places are being found while an index runs.
    finding: std.ArrayList(VarId) = .empty,
    /// The region of each binding.
    region_of: std.AutoHashMapUnmanaged(VarId, usize) = .empty,
    /// A branching value read where it stands, each leaf read in place:
    /// its var, and the region of the statement that reads it.
    read_leaves: std.AutoHashMapUnmanaged(VarId, usize) = .empty,
    /// While lowering a value block's last value, through the branches
    /// of `if`s in tail position: the block's region. A bare binding of
    /// that block or a deeper one leaves with the value.
    tail_floor: ?usize = null,
    /// While a header finds the place its subject names in a value it
    /// made: that value's node, and the var holding it.
    made_root: ?struct { start: u32, end: u32, v: VarId } = null,
    /// While a deferred body is lowered: the loops it may leave start here.
    loop_floor: usize = 0,
    in_defer: bool = false,
    /// While a deferred body is lowered: the first var it declares.
    defer_vars: VarId = 0,
    /// The payloads a pattern binds of a place the function owns.
    owned_payloads: std.AutoHashMapUnmanaged(VarId, void) = .empty,
    /// The elements a `for` binds.
    loop_elems: std.AutoHashMapUnmanaged(VarId, void) = .empty,
    /// The locals a stack closure literal is bound to.
    closure_bindings: std.AutoHashMapUnmanaged(VarId, void) = .empty,
    /// In a generic body: it copies a value whose type holds a type
    /// parameter somewhere, which an instance at an owner cannot allow.
    copies_t: bool = false,
    /// In a generic body: the generic functions it calls at its own type
    /// parameters, whose bodies its instances also run.
    t_calls: std.ArrayList(Callee) = .empty,
    /// The module the body is in.
    module: ?*const lib.modules.Module = null,
    /// The result type the function or closure declares.
    ret_ty: ?TypeId = null,

    // ---- the function ---------------------------------------------------

    fn run(self: *Lowerer, unit: Unit) Error!void {
        const decl = unit.decl;
        const kind = decl.kind().?;
        // A generic body is checked once, for every instance (SPEC
        // "Generic bodies").
        self.kinds.generic = unit.generic_owner or ((kind == .fun or kind == .sub) and ir.get(decl, .tparams) != .nil);
        const entry = try self.newBlock();
        self.cur = entry;
        try self.regions.append(self.a, .{});
        if (kind != .@"test") {
            for (ir.get(decl, .params).items()) |p| try self.param(p);
        }
        if (kind == .fun) if (ir.get(decl, .name) == .src) {
            self.f.from = declaredFrom(self.ctx, ir.get(decl, .name).src.pos);
            self.ret_ty = self.declaredReturn(ir.get(decl, .name));
        };
        try self.lowerBody(ir.get(decl, .body), kind == .fun);
    }

    /// A body's statements, its last one its value when it `returns`.
    fn lowerBody(self: *Lowerer, b: Sexp, returns: bool) Error!void {
        const stmts = ir.Block.stmts(b);
        try self.regions.append(self.a, .{});
        for (stmts, 0..) |s, i| {
            if (returns and i + 1 == stmts.len and isValue(s)) {
                try self.reachable();
                try self.retValue(s);
            } else try self.stmt(s);
        }
        if (self.cur != null) try self.ret(null, self.posOf(b), .no);
    }

    /// A closure's body, checked as a function of its own (Core §7):
    /// what it captured holds a value on entry and an external loan for
    /// the closure's life, which its environment owns and never drops
    /// here; its parameters are a function's, whose views last one call.
    fn runClosure(self: *Lowerer, e: Sexp) Error!void {
        const ft = switch (self.ctx.types.get(try self.typeOf(e))) {
            .function => |f| f,
            else => return abstain("a closure of an unusual type"),
        };
        self.cur = try self.newBlock();
        try self.regions.append(self.a, .{});
        for (sema.captureList(ir.Lambda.captures(e))) |cap| {
            const leaf = sema.captureNameNode(cap) orelse return abstain("an unusual capture");
            const sym_id = self.ctx.symbolOf(leaf) orelse return abstain("a capture without a symbol");
            const sym = self.ctx.symbols.items[sym_id];
            const v = try self.newVar(sym.name, sym.ty, false, leaf.src.pos);
            self.f.vars.items[v].param = true;
            self.f.vars.items[v].capture = true;
            try self.vars.put(self.a, sym_id, v);
            try self.f.params.append(self.a, v);
            if (self.f.vars.items[v].kind == .write_view) try self.write_params.append(self.a, v);
        }
        for (ir.Lambda.params(e).items()) |p| {
            try self.param(p);
            const v = self.f.params.items[self.f.params.items.len - 1];
            self.f.vars.items[v].call_only = true;
        }
        self.ret_ty = ft.returns;
        try self.lowerBody(ir.Lambda.body(e), self.ctx.types.get(ft.returns) != .void);
    }

    /// The result type of the function or method named at `name`.
    fn declaredReturn(self: *Lowerer, name: Sexp) ?TypeId {
        const pos = name.src.pos;
        const fn_ty = if (self.ctx.symbolOf(name)) |id| self.ctx.symbols.items[id].ty else method: {
            for (self.ctx.symbols.items) |sym| {
                for (sym.fields orelse &.{}) |f| if (f.is_method and f.decl_pos == pos) break :method f.ty;
            }
            return null;
        };
        return switch (self.ctx.types.get(fn_ty)) {
            .function => |f| f.returns,
            else => null,
        };
    }

    /// The type a function's result takes from a value `e` of type `ty`:
    /// a view of a value that copies, returned where that value is the
    /// result, is copied out (Core §4), as a typed binding copies it.
    fn resultType(self: *Lowerer, ty: TypeId) Error!TypeId {
        const result = self.ret_ty orelse return ty;
        const inner = switch (self.ctx.types.get(ty)) {
            .read_view, .write_view => |inner| inner,
            else => return ty,
        };
        if (self.ctx.types.get(inner) == .slice) return ty;
        var value = result;
        while (true) switch (self.ctx.types.get(value)) {
            .optional, .fallible => |i| value = i,
            else => break,
        };
        if (self.isRef(value) or self.ctx.types.get(value) == .slice) return ty;
        if (!(try self.kinds.of(inner)).kind.copies()) return ty;
        return result;
    }

    fn param(self: *Lowerer, p: Sexp) Error!void {
        if (p == .src) return self.paramNamed(p);
        const name = switch (p.kind() orelse return abstain("an unusual parameter")) {
            .@":", .default => ir.get(p, .name),
            .read, .write, .move => ir.get(p, .operand),
            else => return abstain("an unusual parameter"),
        };
        return self.paramNamed(name);
    }

    fn paramNamed(self: *Lowerer, name: Sexp) Error!void {
        const sym_id = self.ctx.symbolOf(name) orelse return abstain("a parameter without a symbol");
        const sym = self.ctx.symbols.items[sym_id];
        const v = try self.newVar(sym.name, sym.ty, false, name.src.pos);
        self.f.vars.items[v].param = true;
        // A function value passed by value is a function or a closure
        // that carries no loan: a stack closure is only lent (`?fun`).
        if (self.ctx.types.get(sym.ty) == .function) self.f.vars.items[v].holds_views = false;
        try self.vars.put(self.a, sym_id, v);
        try self.f.params.append(self.a, v);
        // The caller owns what a view parameter sees; an owned parameter
        // is dropped where the function ends (Core s3).
        if (self.f.vars.items[v].kind == .owning) try self.regions.items[0].vars.append(self.a, v);
        if (self.f.vars.items[v].kind == .write_view) try self.write_params.append(self.a, v);
    }

    /// The last statement of a `fun` is its value unless it is a
    /// statement form or a jump.
    fn isValue(s: Sexp) bool {
        const k = s.kind() orelse return true;
        return switch (k) {
            .set, .drop, .pass, .@"while", .@"for", .@"return", .@"break", .@"continue", .@"defer", .@"errdefer", .labeled => false,
            .@"if" => ir.If.@"else"(s) != .nil,
            else => true,
        };
    }

    // ---- blocks and vars ------------------------------------------------

    fn newBlock(self: *Lowerer) Error!BlockId {
        try self.f.blocks.append(self.a, .{});
        return @intCast(self.f.blocks.items.len - 1);
    }

    /// The block ops go to; after a jump, a fresh one nothing reaches.
    fn block(self: *Lowerer) Error!*core.Block {
        if (self.cur == null) self.cur = try self.newBlock();
        return &self.f.blocks.items[self.cur.?];
    }

    fn emit(self: *Lowerer, op: core.Op) Error!void {
        const b = try self.block();
        try b.ops.append(self.a, op);
    }

    fn goto(self: *Lowerer, target: BlockId) Error!void {
        const b = try self.block();
        try b.succs.append(self.a, target);
        self.cur = null;
    }

    fn branch(self: *Lowerer, t: BlockId, e: BlockId) Error!void {
        const b = try self.block();
        try b.succs.append(self.a, t);
        try b.succs.append(self.a, e);
        self.cur = null;
    }

    fn newVar(self: *Lowerer, name: []const u8, ty: TypeId, hidden: bool, pos: u32) Error!VarId {
        const info = try self.kinds.of(ty);
        if (info.unsupported) |why| return abstain(why);
        try self.f.vars.append(self.a, .{
            .name = name,
            .ty = ty,
            .kind = info.kind,
            .holds_views = info.holds_views,
            .holds_pointers = info.holds_pointers,
            .holds_writes = info.holds_writes,
            .drop_reads = info.drop_reads,
            .hidden = hidden,
            .pos = pos,
        });
        return @intCast(self.f.vars.items.len - 1);
    }

    /// A statement temporary, dropped where its statement ends.
    fn temp(self: *Lowerer, ty: TypeId, pos: u32) Error!VarId {
        const v = try self.newVar("temporary", ty, true, pos);
        try self.regions.items[self.regions.items.len - 1].vars.append(self.a, v);
        return v;
    }

    /// A temporary holding a view the lowering makes (an implicit read
    /// lend), whatever the node's type says.
    fn viewTemp(self: *Lowerer, ty: TypeId, kind: kinds.Kind, pos: u32) Error!VarId {
        const v = try self.temp(ty, pos);
        self.f.vars.items[v].kind = kind;
        self.f.vars.items[v].holds_views = true;
        self.f.vars.items[v].holds_pointers = true;
        self.f.vars.items[v].drop_reads = false;
        return v;
    }

    fn typeOf(self: *Lowerer, e: Sexp) Error!TypeId {
        return self.ctx.typeOf(e) orelse abstain(if (e.kind()) |k| switch (k) {
            inline else => |t| "an expression without a type: " ++ @tagName(t),
        } else "an expression without a type: a name");
    }

    fn posOf(self: *Lowerer, e: Sexp) u32 {
        return switch (e) {
            .src => |s| s.pos,
            .list => self.parser.span(e).start,
            else => 0,
        };
    }

    fn found(self: *Lowerer, rule: core.Rule, pos: u32, comptime fmt: []const u8, args: anytype) Error {
        if (self.f.early == null) self.f.early = .{ .rule = rule, .pos = pos, .reason = try self.a.print(fmt, args) };
        return error.Found;
    }

    fn pushRegion(self: *Lowerer) Error!void {
        try self.regions.append(self.a, .{});
    }

    /// Leave a region at `pos`: drop its vars, last first, running each
    /// `defer` it reached where it was written among them, and each
    /// `errdefer` too on an exit that fails (Core §7: they run where
    /// their scope ends; the code there is inlined at every exit, so the
    /// checks apply to it as written).
    fn killRegion(self: *Lowerer, r: Region, pos: u32, fails: bool) Error!void {
        var di = r.defers.items.len;
        var i = r.vars.items.len;
        while (true) {
            while (di > 0 and r.defers.items[di - 1].at >= i) {
                di -= 1;
                const d = r.defers.items[di];
                if (!d.err or fails) try self.runDeferred(d.body);
            }
            if (i == 0) break;
            i -= 1;
            try self.emit(.{ .pos = pos, .what = .kill, .kill = r.vars.items[i], .scope_end = true });
        }
    }

    /// A deferred body at one exit: its own statements, which may not
    /// leave it (a jump or a propagation out of deferred code is the
    /// compiler's to reject; the oracle leaves such a function alone).
    fn runDeferred(self: *Lowerer, body: Sexp) Error!void {
        if (self.cur == null) return;
        const saved_floor = self.tail_floor;
        const saved_label = self.label;
        const saved_made = self.made_root;
        const saved_loops = self.loop_floor;
        const saved_in = self.in_defer;
        const saved_vars = self.defer_vars;
        defer {
            self.defer_vars = saved_vars;
            self.tail_floor = saved_floor;
            self.label = saved_label;
            self.made_root = saved_made;
            self.loop_floor = saved_loops;
            self.in_defer = saved_in;
        }
        self.tail_floor = null;
        self.label = null;
        self.made_root = null;
        self.loop_floor = self.loops.items.len;
        self.in_defer = true;
        self.defer_vars = @intCast(self.f.vars.items.len);
        try self.pushRegion();
        if (body.isKind(.block)) {
            for (ir.Block.stmts(body)) |s| try self.stmt(s);
        } else try self.stmt(body);
        try self.popRegion(self.posOf(body));
    }

    fn popRegion(self: *Lowerer, pos: u32) Error!void {
        const r = self.regions.pop().?;
        if (self.cur != null) try self.killRegion(r, pos, false);
    }

    /// Leave every region above `depth`, innermost first (a jump, or a
    /// return that fails or not).
    fn unwind(self: *Lowerer, depth: usize, pos: u32, fails: bool) Error!void {
        var i = self.regions.items.len;
        while (i > depth) {
            i -= 1;
            try self.killRegion(self.regions.items[i], pos, fails);
        }
    }

    /// Whether a region on the stack has reached an `errdefer`.
    fn hasErrdefer(self: *Lowerer) bool {
        for (self.regions.items) |r| for (r.defers.items) |d| if (d.err) return true;
        return false;
    }

    fn varOf(self: *Lowerer, leaf: Sexp) ?VarId {
        const sym = self.ctx.symbolOf(leaf) orelse return null;
        return self.vars.get(sym);
    }

    /// Declare the binding a leaf names in a region: a statement's
    /// binding goes to the scope under the statement's own temporaries
    /// (`under` 1); a pattern's or loop's to the region on top.
    fn bind(self: *Lowerer, leaf: Sexp, under: usize) Error!VarId {
        const sym_id = self.ctx.symbolOf(leaf) orelse return abstain("a binding without a symbol");
        const sym = self.ctx.symbols.items[sym_id];
        const v = try self.newVar(sym.name, sym.ty, false, leaf.src.pos);
        try self.vars.put(self.a, sym_id, v);
        const r = self.regions.items.len - 1 - under;
        try self.regions.items[r].vars.append(self.a, v);
        try self.region_of.put(self.a, v, r);
        return v;
    }

    // ---- statements -----------------------------------------------------

    fn stmt(self: *Lowerer, s: Sexp) Error!void {
        try self.reachable();
        try self.pushRegion();
        try self.stmtIn(s);
        try self.popRegion(self.posOf(s));
    }

    /// A statement right after a jump is a syntax error the compiler
    /// reports; the oracle leaves such a function alone.
    fn reachable(self: *Lowerer) Error!void {
        if (self.cur == null) return abstain("a statement after a jump");
    }

    fn stmtIn(self: *Lowerer, s: Sexp) Error!void {
        const k = s.kind() orelse {
            _ = try self.eval(s, .read, null);
            return;
        };
        if (k != .labeled and k != .@"while" and k != .@"for" and k != .match) self.label = null;
        switch (k) {
            .set => try self.set(s),
            .drop => try self.dropStmt(s),
            .pass => {},
            .@"if" => try self.ifInto(s, .read, null),
            .match => try self.matchInto(s, .read, null),
            .@"while" => try self.whileStmt(s, null),
            .@"for" => try self.forStmt(s, null),
            .@"return" => {
                const v = ir.Return.value(s);
                if (v == .nil) try self.ret(null, self.posOf(s), .no) else try self.retValue(v);
            },
            .@"break", .@"continue" => try self.jump(s),
            .labeled => {
                const inner = ir.Labeled.stmt(s);
                if (!inner.isKind(.@"while") and !inner.isKind(.@"for") and !inner.isKind(.match)) return abstain("a labeled `raw` block");
                self.label = ir.Labeled.label(s).getText(self.src);
                try self.stmtIn(inner);
            },
            // Registered on the scope under the statement's temporaries;
            // its body runs at the scope's exits (`killRegion`).
            .@"defer", .@"errdefer" => {
                const scope = &self.regions.items[self.regions.items.len - 2];
                try scope.defers.append(self.a, .{ .body = ir.get(s, .body), .err = k == .@"errdefer", .at = scope.vars.items.len });
            },
            .raw_block => return abstain("`raw`"),
            else => _ = try self.eval(s, .read, null),
        }
    }

    /// `x = e`, `x op= e`, `new x = e`, `p.f = e`, `_ = e` (Core §6).
    fn set(self: *Lowerer, s: Sexp) Error!void {
        const op = rig.bindingKindOf(ir.Set.op(s));
        const target = ir.Set.target(s);
        const rhs = ir.Set.value(s);
        const pos = self.posOf(s);
        if (target == .src and std.mem.eql(u8, target.getText(self.src), "_")) {
            // `_ = e` binds the value to nothing: it is taken, then
            // dropped with the statement.
            _ = try self.eval(rhs, .take, null);
            return;
        }
        if (op.operator() != null) return self.compound(target, rhs, pos);
        if (target == .src) {
            const sym_id = self.ctx.symbolOf(target) orelse return abstain("a binding without a symbol");
            const sym = self.ctx.symbols.items[sym_id];
            const declares = op == .shadow or op == .fixed or sym.decl_pos == target.src.pos;
            if (!declares and !self.vars.contains(sym_id)) {
                if (sym.scope == sema.module_scope) try self.reassignable(sym, pos);
                return abstain("an assignment to a name the lowering did not bind");
            }
            if (declares) {
                // The value first, then the binding (Core §6).
                // A stack closure is bound to a local, which is fixed
                // (Core §7, SPEC "Stack closures").
                const lambda = rhs.isKind(.lambda);
                const v = if (lambda) try self.closure(rhs, false) else try self.eval(rhs, .take, sym.ty);
                const x = try self.bind(target, 1);
                if (lambda) try self.closure_bindings.put(self.a, x, {});
                try self.store(x, v, pos);
                return;
            }
            const x = self.vars.get(sym_id).?;
            const xv = self.f.vars.items[x];
            const ref = self.isWriteRef(xv.ty);
            // Assigning a view to a name that holds one re-points it
            // (Core §6 "View places"): a binding is reassigned, which a
            // parameter or a fixed binding never is.
            const repoint = ref and try self.pointsAnew(rhs);
            if (!ref or repoint) try self.reassignable(sym, pos);
            if (self.closure_bindings.contains(x)) return self.found(.B1, pos, "a closure binding `{s}` is fixed", .{sym.name});
            if (repoint) {
                // The new view first; the name then holds its loans, and
                // none of the old view's (Core §6). The old view owns
                // nothing, and a lend on of what it saw carries that
                // loan itself, so nothing here conflicts with it.
                const v = try self.eval(rhs, .take, xv.ty);
                try self.emit(.{ .pos = pos, .what = .assign, .moves = try self.list(v), .def = x });
                return;
            }
            if (ref) {
                // A write view's value is written through (SPEC §7).
                const v = try self.eval(rhs, .take, try self.innerOf(xv.ty));
                try self.emit(.{ .pos = pos, .what = .assign, .reads = try self.list(v), .uses = try self.one(x), .weak = x, .through = try self.one(x), .access = .{ .root = x, .deref = true, .kind = .write } });
                return;
            }
            const v = try self.eval(rhs, .take, xv.ty);
            // Reassigning a name drops its old value: no loan of it may
            // be live (Core s5, s6).
            try self.emit(.{ .pos = pos, .what = .assign, .moves = try self.list(v), .def = x, .access = .{ .root = x, .kind = .whole } });
            return;
        }
        // A field or element: the value first, then the indexes, then
        // the store (Core §6). A place holding a write view is re-pointed
        // by a view and written through by a value (Core §6 "View
        // places", for fields and elements alike).
        const target_ty = try self.typeOf(target);
        const write_in = self.isWriteRef(target_ty) and !try self.pointsAnew(rhs);
        const v = try self.eval(rhs, .take, if (write_in) try self.innerOf(target_ty) else target_ty);
        const p = try self.place(target) orelse return abstain("an assignment to something not a place");
        if (p.via == .read) return abstain("a write through a read view");
        if (p.handle) return abstain("a write through a handle");
        // A store through a write view lands in what the view sees (s6).
        const deref = p.via == .write or write_in;
        const through: []const VarId = if (deref) try self.one(p.root) else &.{};
        try self.emit(.{ .pos = pos, .what = .assign, .moves = try self.list(v), .uses = try self.one(p.root), .weak = p.root, .through = through, .access = .{ .root = p.root, .path = p.path, .deref = deref, .kind = .write } });
    }

    /// Whether assigning `rhs` to a place holding a write view re-points
    /// it: `rhs` is a new write view (a lend, `<w`, a call's), not a
    /// place, whose bare name is read as the value it sees (SPEC §7).
    fn pointsAnew(self: *Lowerer, rhs: Sexp) Error!bool {
        return self.isWriteRef(try self.typeOf(rhs)) and !self.isPlaceSyntax(rhs);
    }

    /// Whether a loop element is a generic body's copy of a `T` element
    /// it only reads (SPEC "Generic bodies").
    fn genericLoopCopy(self: *Lowerer, v: VarId) bool {
        if (!self.kinds.generic) return false;
        const info = self.kinds.of(self.f.vars.items[v].ty) catch return false;
        return info.generic_copy;
    }

    /// Whether a value of `ty` is a `?T` or `!T` itself, which `+`
    /// clones what it sees through.
    fn isRef(self: *Lowerer, ty: TypeId) bool {
        return switch (self.ctx.types.get(ty)) {
            .read_view, .write_view => true,
            else => false,
        };
    }

    /// Whether a value of `ty` is a write view, `!T`, itself (not a
    /// value holding one): assigning a value to its place writes
    /// through it, and lending it lends on what it sees.
    fn isWriteRef(self: *Lowerer, ty: TypeId) bool {
        return self.ctx.types.get(ty) == .write_view;
    }

    fn compound(self: *Lowerer, target: Sexp, rhs: Sexp, pos: u32) Error!void {
        var v = try self.eval(rhs, .read, null);
        if (v) |rv| v = try self.readThrough(rv, pos);
        const p = try self.place(target) orelse return abstain("a compound assignment to something not a place");
        if (p.handle) return abstain("a write through a handle");
        if (target == .src and !self.isWriteRef(p.ty)) {
            try self.reassignable(self.ctx.symbols.items[self.ctx.symbolOf(target).?], pos);
        }
        // Through a write view, or into what a place's write view sees.
        const deref = p.via == .write or (!p.slice and self.isWriteRef(p.ty));
        try self.emit(.{ .pos = pos, .what = .assign, .reads = try self.list(v), .uses = try self.one(p.root), .access = .{ .root = p.root, .path = p.path, .deref = deref, .kind = .write } });
    }

    /// Core §6: a local binding may be reassigned; parameters and fixed
    /// bindings may not.
    fn reassignable(self: *Lowerer, sym: sema.Symbol, pos: u32) Error!void {
        if (sym.kind == .param) return self.found(.B1, pos, "a parameter `{s}` is not reassigned", .{sym.name});
        if (sym.kind == .capture) return self.found(.B3, pos, "a closure does not reassign `{s}`, which it captured", .{sym.name});
        if (sym.flags.fixed) return self.found(.B1, pos, "a fixed binding `{s}` is not reassigned", .{sym.name});
    }

    /// Bind a fresh var to a lowered value.
    fn store(self: *Lowerer, x: VarId, v: ?VarId, pos: u32) Error!void {
        try self.emit(.{ .pos = pos, .what = .move, .moves = try self.list(v), .def = x });
    }

    /// A statement `<x` drops `x` now (Core s2); `<e` of anything but a
    /// name drops what it takes, as `_ = <e` does.
    fn dropStmt(self: *Lowerer, s: Sexp) Error!void {
        const name = ir.Drop.target(s);
        if (name != .src) {
            _ = try self.eval(name, .take, null);
            return;
        }
        const x = self.varOf(name) orelse return abstain("a drop of something not a local");
        const xv = self.f.vars.items[x];
        // What a parameter views, the caller owns (SPEC §7 "Drop").
        if (xv.param and self.ctx.types.get(xv.ty) != .string and xv.kind != .owning and xv.kind != .plain) {
            return self.found(.C5, self.posOf(s), "a parameter's view is the caller's; it is not dropped here", .{});
        }
        try self.keptByDefer(x, self.posOf(s));
        try self.keptByClosure(x, self.posOf(s));
        // Dropping a generic loop element ends a copy (SPEC "Generic
        // bodies").
        if (self.loop_elems.contains(x) and (try self.kinds.of(xv.ty)).generic_copy) {
            self.copies_t = true;
            try self.emit(.{ .pos = self.posOf(s), .what = .use, .uses = try self.one(x) });
            return;
        }
        // A payload seen through a view is the subject's (§5).
        if (xv.alias) return self.found(.C7, self.posOf(s), "a payload seen through a view is not dropped; take the subject with `<`", .{});
        try self.emit(.{ .pos = self.posOf(s), .what = .kill, .uses = try self.one(x), .kill = x, .access = .{ .root = x, .kind = .whole } });
    }

    /// An `if`, as a statement (`j` null) or a value stored in `j`.
    fn ifInto(self: *Lowerer, e: Sexp, how: How, j: ?VarId) Error!void {
        const cond = ir.If.cond(e);
        var held: ?Held = null;
        if (cond.isKind(.as)) {
            held = try self.asHeader(ir.As.value(cond), .take);
        } else if (rig.bindsInCondition(cond)) {
            return abstain("a joined `and` chain with `as` parts");
        } else try self.header(cond);
        const t = try self.newBlock();
        const x = try self.newBlock();
        const els = ir.If.@"else"(e);
        if (els == .nil and j != null) return abstain("an `if` value without `else`");
        const el = if (els == .nil) x else try self.newBlock();
        try self.branch(t, el);
        self.cur = t;
        // A branch is no statement of its own (Core §3): a value branch's
        // temporaries are its statement's, and only the bindings an `as`
        // makes leave with it.
        const region = held != null or j == null;
        if (region) try self.pushRegion();
        if (held) |h| try self.bindHeld(ir.As.name(cond), h, self.optionalInner(h.ty));
        if (j) |jv| try self.armValue(ir.If.then(e), how, jv) else try self.blockStmts(ir.If.then(e));
        if (region) try self.popRegion(self.posOf(e));
        try self.goto(x);
        if (els != .nil) {
            self.cur = el;
            if (j) |jv| try self.valueInto(els, how, jv) else if (els.isKind(.@"if")) try self.stmt(els) else try self.blockStmts(els);
            try self.goto(x);
        }
        self.cur = x;
    }

    /// A branch's value, where the branch's own bindings (a pattern's,
    /// an `as`'s) leave with it as a block's do.
    fn armValue(self: *Lowerer, e: Sexp, how: How, j: VarId) Error!void {
        const saved = self.tail_floor;
        self.tail_floor = self.tail_floor orelse self.regions.items.len - 1;
        defer self.tail_floor = saved;
        try self.valueInto(e, how, j);
    }

    /// What a header holds through the statement it heads.
    const Held = struct {
        v: VarId,
        pos: u32,
        /// The subject's type, whose elements or payloads the header binds.
        ty: TypeId,
        /// For a read lend of a place (`match ?h`): the place's root, whose
        /// loans a String payload carries instead of the loan on it.
        carry_from: ?VarId = null,
        /// For a lend of a value the header made (`match ?mk()`): the
        /// header's temporary, which the tests of the statement may read
        /// but no binding may view (Core §3).
        lent_temp: bool = false,
        /// For a lend of a place the function owns: its payloads are that
        /// place's.
        of_owner: bool = false,
    };

    /// The value of `if e as x`, `while e as x`, or a `match` subject: a
    /// header, whose temporaries end with it, and whose value a hidden
    /// var of the statement holds (Core §3). A bare place is taken as a
    /// binding takes it (`as`, `how` take) or read where it stands
    /// (`match`, `how` read); see `subject` for the rest.
    fn asHeader(self: *Lowerer, value: Sexp, how: How) Error!Held {
        const pos = self.posOf(value);
        const ty = try self.typeOf(value);
        // Under the planned rule a bare place an `as` binds is read where
        // it stands, as `?p` (Core s1, planned; INTERNALS "Header
        // subjects"); an optional of plain data still copies.
        const is_place = self.isPlaceSyntax(value);
        // An element or field of a lend (`(?v[i..2])[1]`) is a place the
        // header views through it; the oracle does not model that path.
        if (!is_place and (value.isKind(.member) or value.isKind(.index))) {
            const rk = chainRoot(value).kind();
            if (rk == .read or rk == .write) return abstain("a header subject reached through a lend");
        }
        const bare: How = if (how == .take and self.planned and is_place) .read else how;
        try self.pushRegion();
        var v = try self.subject(value, bare, "the `as` value");
        // A read view of plain data that is no place's, written `?mk()`
        // or a call's result, is read as its value in the header, which
        // carries no loan (Core §4).
        const named = if (value.isKind(.read)) ir.Read.operand(value) else value;
        // A bare `match` subject, or a lend of a view a call returns
        // (`lendsHeldView`), reads a `T` in that view where it is, as it
        // reads a place's: each binding sees its
        // payload through the view (Core s1), and a generic body's copy
        // of one is the instance's question where the binding is used.
        const in_place = how == .read and self.kinds.generic and (!value.isKind(.read) or self.lendsHeldView(value));
        if (!value.isKind(.write) and !self.isPlaceSyntax(named)) v = if (in_place) try self.readPlainThrough(v, pos) else try self.readThrough(v, pos);
        const h = try self.hold(v, "the `as` value", pos);
        try self.popRegion(pos);
        var carry_from: ?VarId = null;
        var of_owner = false;
        // A bare place read where it stands is `?p`.
        const lent_place: ?Sexp = if (value.isKind(.read)) ir.Read.operand(value) else if (is_place and bare == .read) value else null;
        if (lent_place) |lp| if (self.rootVar(lp)) |r| {
            const rv = self.f.vars.items[r];
            if (rv.kind != .write_view and !rv.alias) carry_from = r;
            of_owner = rv.kind == .owning and !rv.alias;
        };
        const lent_temp = (value.isKind(.read) or value.isKind(.write)) and self.madeSubject(ir.get(value, .operand)) and !self.lendsHeldView(value);
        return .{ .v = h, .pos = pos, .ty = ty, .carry_from = carry_from, .lent_temp = lent_temp, .of_owner = of_owner };
    }

    /// What a header's subject hands over (Core §3), lowered inside the
    /// header's region; `bare` says what a bare place does.
    /// - A place is read, lent, moved, or taken as written.
    /// - A value made in the header (a call's result, a constructor, a
    ///   literal) is taken. So is the made value the subject is a part
    ///   of (`mk().e`, `[a, b][0]`): a hidden var of the statement holds
    ///   it through the body, and the part is read where it stands, or
    ///   copied in the header when it is plain data (`heldView`).
    /// - A lend of a made value (`?mk()`) lends the header's temporary:
    ///   the statement's tests may read it, but no binding may view it
    ///   (`Held.lent_temp`).
    /// - A branching value (`if`, `??`, `catch`, `o?`, `match`, a block)
    ///   is taken leaf by leaf, as a binding takes it: a bare leaf whose
    ///   type moves is rejected (C2, Core s1), `<x` moves, a made leaf is
    ///   taken, a leaf of plain data or a read view copies.
    fn subject(self: *Lowerer, value: Sexp, bare: How, name: []const u8) Error!VarId {
        const pos = self.posOf(value);
        const lent = value.isKind(.read) or value.isKind(.write);
        const named = if (lent) ir.get(value, .operand) else value;
        const root = chainRoot(named);
        if (self.madeSubject(named) and !self.lendsHeldView(value)) {
            if (lent and isBranching(named)) return abstain("a lend of a branching value (Core §3, planned)");
            if (lent and value.isKind(.write)) return abstain("a write lend of a made value");
            const part = named.kind().? == .member or named.kind().? == .index;
            if (part and !lent) return self.heldView(named, name, bare);
            if (lent) {
                const hp = try self.heldPart(named, name);
                return try self.lend(hp.place, .read, value, try self.typeOf(value));
            }
            if (isBranching(root)) {
                const t = try self.temp(try self.typeOf(root), pos);
                try self.valueInto(root, .take, t);
                return t;
            }
        }
        return try self.eval(value, bare, null) orelse blk: {
            // A literal or constant subject holds no loan.
            const c = try self.temp(try self.typeOf(value), pos);
            try self.emit(.{ .pos = pos, .what = .make, .def = c });
            break :blk c;
        };
    }

    /// Take the value a header made, which `named` is or is a part of,
    /// into a hidden var of the statement; the place `named` is in it.
    fn heldPart(self: *Lowerer, named: Sexp, name: []const u8) Error!struct { held: VarId, place: Place } {
        const root = chainRoot(named);
        const made = try self.eval(root, .take, null) orelse return abstain("a part of a constant");
        const held = try self.hold(made, name, self.posOf(named));
        const span = self.parser.span(root);
        const saved = self.made_root;
        self.made_root = .{ .start = span.start, .end = span.end, .v = held };
        defer self.made_root = saved;
        const p = try self.place(named) orelse return abstain("an unusual header subject");
        return .{ .held = held, .place = p };
    }

    /// A part of a value a header makes (INTERNALS "Header subjects"):
    /// one of plain data is read in the header, its made value a
    /// temporary there; any other is read where it stands, `?_h.f`, in
    /// the made value the header takes into a hidden var of the whole
    /// construct (Core §3: the made value is taken; Core s1: the part is
    /// read in place).
    fn heldView(self: *Lowerer, named: Sexp, name: []const u8, bare: How) Error!VarId {
        const ty = try self.typeOf(named);
        if ((try self.kinds.of(ty)).kind == .plain) {
            return try self.eval(named, bare, null) orelse blk: {
                const c = try self.temp(ty, self.posOf(named));
                try self.emit(.{ .pos = self.posOf(named), .what = .make, .def = c });
                break :blk c;
            };
        }
        const hp = try self.heldPart(named, name);
        return try self.lend(hp.place, .read, named, hp.place.ty);
    }

    /// Whether a header subject names a value the header makes, or a
    /// part of one: neither a place, nor a constant, nor a sigil.
    /// Whether `value` lends to read a read view a call returns,
    /// `?get(e)`: that lends the view on, the view itself (Core §4, a
    /// held view lends `?T`), not a temporary the header made.
    fn lendsHeldView(self: *Lowerer, value: Sexp) bool {
        if (!value.isKind(.read)) return false;
        const operand = ir.Read.operand(value);
        if (!operand.isKind(.call)) return false;
        const ty = self.ctx.typeOf(operand) orelse return false;
        return self.ctx.types.get(ty) == .read_view;
    }

    fn madeSubject(self: *Lowerer, named: Sexp) bool {
        const rk = chainRoot(named).kind() orelse return false;
        if (rk == .read or rk == .write or rk == .move) return false;
        return !self.isPlaceSyntax(named) and !self.constRooted(named);
    }

    /// The object a chain of fields and elements starts from: `mk()` in
    /// `mk().e[0]`.
    fn chainRoot(e: Sexp) Sexp {
        var x = e;
        while (x.kind()) |k| {
            if (k != .member and k != .index) break;
            x = ir.get(x, .object);
        }
        return x;
    }

    /// Move a header's value into a hidden var of the statement around
    /// the header, which outlives the header's temporaries.
    fn hold(self: *Lowerer, v: VarId, name: []const u8, pos: u32) Error!VarId {
        const vv = self.f.vars.items[v];
        const h = try self.newVar(name, vv.ty, true, pos);
        const hv = &self.f.vars.items[h];
        hv.kind = vv.kind;
        hv.holds_views = vv.holds_views;
        hv.holds_pointers = vv.holds_pointers;
        hv.holds_writes = vv.holds_writes;
        hv.drop_reads = vv.drop_reads;
        try self.regions.items[self.regions.items.len - 2].vars.append(self.a, h);
        try self.store(h, v, pos);
        return h;
    }

    /// Bind an element or payload of a held value, whose stored type is
    /// `stored` when known. Through a held view, the binding sees the
    /// payload where it is and carries the view's loans. A held value is
    /// the body's own: a binding of the stored type is a copy of it, or
    /// owned, carrying what it holds; a binding that views a stored
    /// value (`?T` of a stored `T`) is a lend of the holder, whose loan
    /// ends with the statement (Core §3: a view of what a header made
    /// does not outlive it).
    fn bindHeld(self: *Lowerer, leaf: Sexp, h: Held, stored: ?TypeId) Error!void {
        if (leaf == .nil or std.mem.eql(u8, leaf.getText(self.src), "_")) {
            try self.emit(.{ .pos = h.pos, .what = .use, .uses = try self.one(h.v) });
            return;
        }
        const x = try self.bind(leaf, 0);
        const hv = self.f.vars.items[h.v];
        const xv = &self.f.vars.items[x];
        // A view of a value a header made ends with the header: a binding
        // that would carry it outlives its statement (Core §3).
        if (h.lent_temp and (xv.holds_views or (xv.kind != .plain and (hv.kind == .read_view or hv.kind == .write_view)))) {
            return self.found(.C5, leaf.src.pos, "a loan of a temporary the header made outlives its statement", .{});
        }
        // A String payload of a read lend carries the String's loans, not
        // the loan on what holds it (Core s7).
        if (h.carry_from) |r| if (self.ctx.types.get(xv.ty) == .string) {
            try self.emit(.{ .pos = h.pos, .what = .copy, .reads = try self.one(r), .uses = try self.one(h.v), .def = x, .carry = true });
            return;
        };
        const held_view = hv.kind == .read_view or hv.kind == .write_view;
        if (!held_view) switch (self.ctx.types.get(xv.ty)) {
            .read_view, .write_view => if (stored == null or stored.? != xv.ty) {
                const mode: core.Mode = if (self.ctx.types.get(xv.ty) == .write_view) .write else .read;
                const loan = try self.newLoan(self.rootPlace(h.v), mode, false, 0, h.pos);
                try self.emit(.{ .pos = h.pos, .what = .lend, .reads = try self.one(h.v), .def = x, .loan = loan, .access = .{ .root = h.v, .kind = if (mode == .read) .read else .write } });
                return;
            },
            else => {},
        };
        // The held value stays whole for the arms after a failed guard.
        if (held_view and xv.kind != .plain) {
            // An owner's payload seen through the view: an alias.
            xv.alias = xv.kind == .owning;
            if (xv.alias and h.of_owner) try self.owned_payloads.put(self.a, x, {});
            xv.kind = hv.kind;
            xv.holds_views = true;
            xv.holds_pointers = true;
            xv.drop_reads = false;
        }
        try self.emit(.{ .pos = h.pos, .what = .copy, .reads = try self.one(h.v), .def = x });
    }

    /// The type an `as` binds: what the optional subject holds.
    fn optionalInner(self: *Lowerer, ty: TypeId) ?TypeId {
        return switch (self.ctx.types.get(ty)) {
            .optional => |t| t,
            else => null,
        };
    }

    /// The type of each element a `for` over a value of `ty` binds.
    fn elementOf(self: *Lowerer, ty: TypeId) ?TypeId {
        return switch (self.ctx.types.get(ty)) {
            .array => |arr| arr.elem,
            .slice => |sl| sl.elem,
            .parameterized_nominal => |pn| if (pn.sym == self.ctx.vec_sym_id and pn.args.len == 1) pn.args[0] else null,
            else => null,
        };
    }

    /// The type of the `i`th payload a variant pattern binds, for an
    /// enum of this module that is not generic, matched or lent (`?E`).
    fn payloadOf(self: *Lowerer, of: TypeId, pattern: Sexp, i: usize) ?TypeId {
        const ty = sema.unwrapViews(self.ctx, of);
        if (self.ctx.types.get(ty) != .nominal) return null;
        const decl = sema.nominalDecl(self.ctx, ty) orelse return null;
        if (decl.ctx != self.ctx) return null;
        const name = ir.VariantPattern.name(pattern);
        if (name != .src) return null;
        const want = name.getText(self.src);
        for (decl.symbol().fields orelse &.{}) |*f| {
            if (!f.is_variant or !std.mem.eql(u8, f.name, want)) continue;
            const payload = sema.dataFields(f);
            return if (i < payload.len) payload[i].ty else null;
        }
        return null;
    }

    /// A `match`, as a statement (`j` null) or a value stored in `j`.
    /// The subject is a header held in a hidden var; each arm tests it,
    /// binds its payloads (owned when the subject is, views of it
    /// otherwise), and runs its guard, whose failure goes on to the next
    /// arm (Core §3).
    fn matchInto(self: *Lowerer, e: Sexp, how: How, j: ?VarId) Error!void {
        const label = self.label;
        self.label = null;
        const pos = self.posOf(e);
        try self.pushRegion();
        const h = try self.asHeader(ir.Match.subject(e), .read);
        const x = try self.newBlock();
        try self.loops.append(self.a, .{ .label = label, .brk = x, .cont = null, .depth = self.regions.items.len, .value = j });
        const arms = ir.Match.arms(e);
        for (arms, 0..) |arm, i| {
            const last = i + 1 == arms.len;
            const pattern = ir.Arm.pattern(arm);
            const guard = ir.Arm.guard(arm);
            // The test reads the subject.
            try self.emit(.{ .pos = self.posOf(arm), .what = .use, .uses = try self.one(h.v) });
            const body = try self.newBlock();
            const next = try self.newBlock();
            const sure = guard == .nil and self.irrefutable(pattern);
            const falls = !last or !self.ctx.isExhaustive(e);
            if (sure or !falls) try self.goto(body) else try self.branch(body, next);
            self.cur = body;
            try self.pushRegion();
            try self.bindPattern(pattern, h);
            if (guard != .nil) {
                try self.header(guard);
                const held_blk = try self.newBlock();
                const fail = try self.newBlock();
                try self.branch(held_blk, if (falls) fail else held_blk);
                // A failed guard leaves the arm's bindings.
                self.cur = fail;
                try self.killRegion(self.regions.items[self.regions.items.len - 1], self.posOf(guard), false);
                try self.goto(next);
                self.cur = held_blk;
            }
            if (j) |jv| try self.armValue(ir.Arm.body(arm), how, jv) else try self.blockStmts(ir.Arm.body(arm));
            try self.popRegion(self.posOf(arm));
            try self.goto(x);
            self.cur = next;
            if (last) {
                if (falls) try self.goto(x) else self.cur = null;
            }
        }
        _ = self.loops.pop();
        self.cur = x;
        try self.popRegion(pos);
    }

    /// The var a place expression starts from.
    fn rootVar(self: *Lowerer, e: Sexp) ?VarId {
        if (e == .src) return self.varOf(e);
        const k = e.kind() orelse return null;
        if (k != .member and k != .index) return null;
        return self.rootVar(ir.get(e, .object));
    }

    /// Whether `e` is written as a place: a local, or a field or element
    /// of one.
    fn isPlaceSyntax(self: *Lowerer, e: Sexp) bool {
        if (e == .src) return self.varOf(e) != null;
        const k = e.kind() orelse return false;
        if (k != .member and k != .index) return false;
        return self.isPlaceSyntax(ir.get(e, .object));
    }

    fn irrefutable(self: *Lowerer, pattern: Sexp) bool {
        if (pattern != .src) return false;
        if (std.mem.eql(u8, pattern.getText(self.src), "_")) return true;
        return self.bindsName(pattern);
    }

    /// Whether a pattern leaf binds a name (rather than naming a constant).
    fn bindsName(self: *Lowerer, leaf: Sexp) bool {
        const sym_id = self.ctx.symbolOf(leaf) orelse return false;
        const sym = self.ctx.symbols.items[sym_id];
        return sym.kind == .local and sym.decl_pos == leaf.src.pos;
    }

    fn bindPattern(self: *Lowerer, pattern: Sexp, h: Held) Error!void {
        switch (pattern) {
            .src => if (self.bindsName(pattern)) try self.bindHeld(pattern, h, h.ty),
            .list => switch (pattern.kind() orelse return abstain("an unusual pattern")) {
                .variant_pattern => for (self.ctx.payloadBindings(pattern) orelse &.{}, 0..) |b, i| {
                    try self.bindHeld(b, h, self.payloadOf(h.ty, pattern, i));
                },
                .alt_pattern => for (ir.AltPattern.alts(pattern)) |alt| {
                    if (alt.isKind(.variant_pattern) and ir.VariantPattern.bindings(alt).len > 0) return abstain("alternatives that bind");
                    if (alt == .src and self.bindsName(alt)) return abstain("alternatives that bind");
                },
                .enum_lit, .member, .range_pattern, .neg => {},
                else => return abstain("an unusual pattern"),
            },
            else => {},
        }
    }

    /// A condition: its own statement, whose temporaries end with it.
    fn header(self: *Lowerer, cond: Sexp) Error!void {
        try self.pushRegion();
        const c = try self.readOpt(cond);
        try self.emit(.{ .pos = self.posOf(cond), .what = .use, .uses = try self.list(c) });
        try self.popRegion(self.posOf(cond));
    }

    fn blockStmts(self: *Lowerer, b: Sexp) Error!void {
        if (!b.isKind(.block)) return self.stmt(b);
        try self.pushRegion();
        for (ir.Block.stmts(b)) |s| try self.stmt(s);
        try self.popRegion(self.posOf(b));
    }

    fn whileStmt(self: *Lowerer, s: Sexp, loop_value: ?VarId) Error!void {
        const label = self.label;
        self.label = null;
        const cond = ir.While.cond(s);
        if (!cond.isKind(.as) and rig.bindsInCondition(cond)) return abstain("a joined `and` chain with `as` parts");
        const h = try self.newBlock();
        try self.goto(h);
        self.cur = h;
        const forever = cond == .src and std.mem.eql(u8, cond.getText(self.src), "true");
        const b = try self.newBlock();
        const x = try self.newBlock();
        const st = try self.newBlock();
        // A jump in the condition (`?? break`) leaves the loop too.
        try self.loops.append(self.a, .{ .label = label, .brk = x, .cont = st, .depth = self.regions.items.len, .value = loop_value });
        var held: ?Held = null;
        if (cond.isKind(.as)) held = try self.asHeader(ir.As.value(cond), .take) else try self.header(cond);
        const els = ir.While.@"else"(s);
        const e = if (els == .nil) x else try self.newBlock();
        if (forever) try self.goto(b) else try self.branch(b, e);
        const step = ir.While.step(s);
        // One iteration's region holds the `as` binding through the body
        // and the step; `continue` goes to the step inside it.
        self.cur = b;
        try self.pushRegion();
        if (held) |hv| try self.bindHeld(ir.As.name(cond), hv, self.optionalInner(hv.ty));
        self.loops.items[self.loops.items.len - 1].cont_depth = self.regions.items.len;
        try self.blockStmts(ir.While.body(s));
        try self.goto(st);
        self.cur = st;
        if (step != .nil) try self.stmt(step);
        try self.popRegion(self.posOf(s));
        try self.goto(h);
        _ = self.loops.pop();
        if (els != .nil) {
            self.cur = e;
            if (loop_value) |lv| try self.valueInto(els, .take, lv) else try self.blockStmts(els);
            try self.goto(x);
        }
        self.cur = x;
    }

    fn forStmt(self: *Lowerer, s: Sexp, loop_value: ?VarId) Error!void {
        const label = self.label;
        self.label = null;
        const mode = ir.For.mode(s).tag;
        const source = ir.For.source(s);
        const pos = self.posOf(s);
        const src_ty = sema.unwrapViews(self.ctx, try self.typeOf(source));
        // The loop's own scope holds what the header binds: the source.
        try self.pushRegion();
        var src_var: VarId = undefined;
        {
            try self.pushRegion();
            const v: ?VarId = switch (mode) {
                .read, .write => blk: {
                    // A lend of a value the header makes is a lend of the
                    // header's temporary, which ends with the header, before
                    // the loop walks it; a lent value of plain data is read
                    // as its value, which carries no loan (Core §3, §4).
                    if (self.madeSubject(source)) {
                        if (mode == .write) return abstain("a write lend of a made value");
                        if (isBranching(source)) return abstain("a lend of a branching value (Core §3, planned)");
                        const p = try self.place(source) orelse blk2: {
                            const t = try self.eval(source, .take, null) orelse return abstain("a lend of a constant");
                            break :blk2 Place{ .root = t, .path = &.{}, .ty = self.f.vars.items[t].ty };
                        };
                        const view = try self.lend(p, .read, source, try self.typeOf(source));
                        const inner = try self.typeOf(source);
                        if ((try self.kinds.of(inner)).kind.copies()) {
                            const c = try self.temp(inner, pos);
                            try self.emit(.{ .pos = pos, .what = .copy, .reads = try self.one(view), .def = c });
                            break :blk c;
                        }
                        break :blk view;
                    }
                    const p = try self.place(source) orelse return abstain("a `for` over a lend of an unusual value");
                    break :blk try self.lend(p, if (mode == .read) .read else .write, source, try self.typeOf(source));
                },
                .move => if (source == .src) blk: {
                    const x = self.varOf(source) orelse return abstain("a `for` moving something not a local");
                    break :blk try self.moveWhole(x, pos);
                } else try self.moveOut(source, pos, .take),
                .iter => if (source.isKind(.@"..")) try self.eval(source, .read, null) else if (self.madeSubject(source)) blk: {
                    // A value the header makes is taken, and so is the made
                    // value the source is a part of; a branching value is
                    // taken leaf by leaf (Core §3).
                    if (source.isKind(.member) or source.isKind(.index)) break :blk try self.heldView(source, "the `for` source", .read);
                    break :blk try self.eval(source, .take, null);
                } else if (try self.place(source)) |p| blk: {
                    if ((try self.kinds.of(p.ty)).kind.copies()) break :blk try self.copy(p, p.ty, pos);
                    // A bare place is read where it stands (Core s1, planned).
                    if (!self.planned) return abstain("a `for` over a bare place (Core s1, planned)");
                    break :blk try self.lend(p, .read, source, p.ty);
                } else try self.eval(source, .take, null),
                else => return abstain("an unusual `for`"),
            };
            const src = v orelse blk: {
                // A literal or constant source holds no loan.
                const c = try self.temp(try self.typeOf(source), pos);
                try self.emit(.{ .pos = pos, .what = .make, .def = c });
                break :blk c;
            };
            src_var = try self.hold(src, "the `for` source", pos);
            try self.popRegion(pos);
        }
        const h = try self.newBlock();
        try self.goto(h);
        self.cur = h;
        try self.emit(.{ .pos = pos, .what = .use, .uses = try self.one(src_var) });
        const b = try self.newBlock();
        const x = try self.newBlock();
        const els = ir.For.@"else"(s);
        const e = if (els == .nil) x else try self.newBlock();
        try self.branch(b, e);
        try self.loops.append(self.a, .{ .label = label, .brk = x, .cont = h, .depth = self.regions.items.len, .value = loop_value });
        self.cur = b;
        try self.pushRegion();
        // Each element: a copy, or owned when the source is, or else a
        // view of the source, carrying its loans.
        const var_leaf = ir.For.@"var"(s);
        if (var_leaf != .nil and !std.mem.eql(u8, var_leaf.getText(self.src), "_")) {
            try self.bindHeld(var_leaf, .{ .v = src_var, .pos = pos, .ty = src_ty }, self.elementOf(src_ty));
            // An element of a source the loop moves is its own.
            if (mode != .move) try self.loop_elems.put(self.a, @intCast(self.f.vars.items.len - 1), {});
        }
        const idx_leaf = ir.For.index(s);
        if (idx_leaf != .nil and !std.mem.eql(u8, idx_leaf.getText(self.src), "_")) {
            const iv = try self.bind(idx_leaf, 0);
            try self.emit(.{ .pos = pos, .what = .make, .def = iv });
        }
        for (ir.Block.stmts(ir.For.body(s))) |st| try self.stmt(st);
        try self.popRegion(pos);
        try self.goto(h);
        _ = self.loops.pop();
        if (els != .nil) {
            self.cur = e;
            if (loop_value) |lv| try self.valueInto(els, .take, lv) else try self.blockStmts(els);
            try self.goto(x);
        }
        self.cur = x;
        try self.popRegion(pos);
    }

    fn findLoop(self: *Lowerer, label: Sexp) Error!Loop {
        var i = self.loops.items.len;
        const want = if (label == .nil) null else label.getText(self.src);
        while (i > self.loop_floor) {
            i -= 1;
            const lp = self.loops.items[i];
            // `break` inside a `match` leaves the loop (Core §8).
            if (want == null) {
                if (lp.cont != null) return lp;
                continue;
            }
            if (lp.label) |have| if (std.mem.eql(u8, have, want.?)) return lp;
        }
        return abstain("a jump to an unknown loop");
    }

    fn jump(self: *Lowerer, s: Sexp) Error!void {
        const pos = self.posOf(s);
        if (s.isKind(.@"continue")) {
            const lp = try self.findLoop(ir.Continue.label(s));
            try self.unwind(lp.cont_depth orelse lp.depth, pos, false);
            try self.goto(lp.cont orelse return abstain("`continue` out of a `match`"));
            return;
        }
        const lp = try self.findLoop(ir.Break.label(s));
        const v = ir.Break.value(s);
        if (v != .nil) {
            const lv = lp.value orelse return abstain("a `break` value of a loop that is not a value");
            // A `break` value is consumed like a result (SPEC §6); where
            // the loop's value is read, a write view is read through.
            // A bare name declared in the loop leaves for good, and
            // moves (Core s1); one from outside the loop takes `<x`.
            const local: ?VarId = if (v != .src) null else if (self.varOf(v)) |x| blk: {
                const in_loop = if (self.region_of.get(x)) |r| r >= lp.depth else false;
                const moves = !(try self.kinds.of(self.f.vars.items[x].ty)).kind.copies();
                break :blk if (in_loop and moves and !self.f.vars.items[x].alias) x else null;
            } else null;
            if (local) |x| try self.store(lv, try self.moveWhole(x, self.posOf(v)), self.posOf(v)) else try self.storeTaken(v, lv);
        }
        try self.unwind(lp.depth, pos, false);
        try self.goto(lp.brk);
    }

    /// `return e` or a `fun`'s last value: the value, then every region
    /// left, then the return (Core s3, s7).
    fn retValue(self: *Lowerer, e: Sexp) Error!void {
        const r = try self.newVar("the result", try self.resultType(try self.typeOf(e)), true, self.posOf(e));
        try self.pushRegion();
        try self.valueInto(e, .ret, r);
        try self.popRegion(self.posOf(e));
        if (self.cur == null) return;
        // The function fails when it returns an error value (SPEC
        // "Failing"): always for one, on some paths for a branching value
        // with an error leaf.
        const ty = self.f.vars.items[r].ty;
        const fails: Fails = if (sema.isErrorValue(self.ctx, ty)) .yes else if (self.ctx.types.get(ty) == .fallible) .maybe else .no;
        try self.ret(r, self.posOf(e), fails);
    }

    /// Leave the function: every scope's drops and `defer`s, then the
    /// return. Where it may fail, the `errdefer`s run on a path of their
    /// own (SPEC "defer and errdefer").
    fn ret(self: *Lowerer, r: ?VarId, pos: u32, fails: Fails) Error!void {
        if (self.in_defer) return abstain("a return from deferred code");
        if (fails == .maybe and self.hasErrdefer()) {
            const ok = try self.newBlock();
            const err = try self.newBlock();
            try self.branch(ok, err);
            self.cur = ok;
            try self.retPath(r, pos, false);
            self.cur = err;
            try self.retPath(r, pos, true);
            return;
        }
        try self.retPath(r, pos, fails == .yes);
    }

    fn retPath(self: *Lowerer, r: ?VarId, pos: u32, fails: bool) Error!void {
        try self.unwind(0, pos, fails);
        // A write parameter's caller sees what it holds (Core s7).
        try self.emit(.{ .pos = pos, .what = .ret, .reads = try self.list(r), .keep = self.write_params.items });
        self.cur = null;
    }

    // ---- values ---------------------------------------------------------

    fn list(self: *Lowerer, v: ?VarId) Error![]const VarId {
        const x = v orelse return &.{};
        return self.one(x);
    }

    fn one(self: *Lowerer, v: VarId) Error![]const VarId {
        const s = try self.a.alloc(VarId, 1);
        s[0] = v;
        return s;
    }

    /// `ty`, or `want` where `ty` is a view of a `want`: the value a
    /// context that wants it reads through the view.
    fn wantedValue(self: *Lowerer, ty: TypeId, want: ?TypeId) Error!TypeId {
        const w = want orelse return ty;
        return switch (self.ctx.types.get(ty)) {
            .write_view, .read_view => |inner| if (inner == w) w else ty,
            else => ty,
        };
    }

    /// Whether a slice of a value of type `ty` slices a String, itself
    /// or through a write view.
    fn slicesString(self: *Lowerer, ty: TypeId) bool {
        const t = switch (self.ctx.types.get(ty)) {
            .write_view => |inner| inner,
            else => ty,
        };
        return self.ctx.types.get(t) == .string;
    }

    fn innerOf(self: *Lowerer, ty: TypeId) Error!TypeId {
        return switch (self.ctx.types.get(ty)) {
            .write_view, .read_view => |t| t,
            else => abstain("an unexpected view type"),
        };
    }

    /// Lower `e` and store its value in `j` (a branch of a branching
    /// value, a block's last value, a result).
    fn valueInto(self: *Lowerer, e: Sexp, how: How, j: VarId) Error!void {
        const k = e.kind() orelse return self.storeValue(e, how, j);
        switch (k) {
            .@"if" => try self.ifInto(e, how, j),
            .match => try self.matchInto(e, how, j),
            .@"??", .@"catch" => try self.fallback(e, how, j),
            .block => {
                const stmts = ir.Block.stmts(e);
                if (stmts.len == 0) return abstain("an empty block value");
                try self.pushRegion();
                for (stmts[0 .. stmts.len - 1]) |s| try self.stmt(s);
                const last = stmts[stmts.len - 1];
                if (isValue(last)) {
                    try self.reachable();
                    const saved = self.tail_floor;
                    self.tail_floor = self.tail_floor orelse self.regions.items.len - 1;
                    try self.pushRegion();
                    try self.valueInto(last, how, j);
                    try self.popRegion(self.posOf(last));
                    self.tail_floor = saved;
                } else try self.stmt(last);
                try self.popRegion(self.posOf(e));
            },
            .@"return" => try self.stmtIn(e),
            .@"break", .@"continue" => try self.jump(e),
            else => try self.storeValue(e, how, j),
        }
    }

    /// `a ?? b` and `e catch h`: the left value when it is there, else
    /// the fallback or handler, which may jump (Core §3: each branch in
    /// the parent's context).
    fn fallback(self: *Lowerer, e: Sexp, how: How, j: VarId) Error!void {
        const pos = self.posOf(e);
        const left = if (e.isKind(.@"??")) ir.get(e, .left) else ir.Catch.value(e);
        // The left value is unwrapped, not the value itself: a bare name
        // there never moves (SPEC §7: `(<o)?`, not `<o?`).
        const v = try self.eval(left, if (how == .ret) .take else how, self.f.vars.items[j].ty);
        const ok = try self.newBlock();
        const other = try self.newBlock();
        const x = try self.newBlock();
        try self.branch(ok, other);
        self.cur = ok;
        try self.storeLeaf(j, v, left);
        try self.goto(x);
        self.cur = other;
        // The fallback is no statement of its own (Core §3), as an `if`
        // branch is not (`ifInto`): its temporaries are its statement's,
        // and only the error a `catch` binds leaves with it.
        const name: Sexp = if (e.isKind(.@"catch")) ir.Catch.name(e) else .nil;
        const binds = name != .nil and !std.mem.eql(u8, name.getText(self.src), "_");
        if (binds) {
            try self.pushRegion();
            const err = try self.bind(name, 0);
            try self.emit(.{ .pos = pos, .what = .make, .def = err });
        }
        const handler = if (e.isKind(.@"??")) ir.get(e, .right) else ir.Catch.handler(e);
        try self.valueInto(handler, if (how == .ret) .take else how, j);
        if (binds) try self.popRegion(pos);
        try self.goto(x);
        self.cur = x;
    }

    fn storeTaken(self: *Lowerer, e: Sexp, j: VarId) Error!void {
        if (e.kind() != null and isBranching(e)) return self.valueInto(e, .take, j);
        const v = try self.eval(e, .take, null);
        try self.store(j, v, self.posOf(e));
    }

    fn storeValue(self: *Lowerer, e: Sexp, how: How, j: VarId) Error!void {
        const floor = self.tail_floor;
        self.tail_floor = null;
        defer self.tail_floor = floor;
        if (how == .take and floor != null and e == .src) if (self.varOf(e)) |x| {
            // A block's own binding, as its last value, leaves with it
            // (Core s1: it leaves for good).
            if ((self.region_of.get(x) orelse 0) >= floor.?) {
                try self.store(j, try self.moveWhole(x, self.posOf(e)), self.posOf(e));
                return;
            }
        };
        const v = try self.eval(e, how, self.f.vars.items[j].ty);
        try self.storeLeaf(j, v, e);
    }

    /// Store a branch's value `v`, of leaf `e`, in `j`. Where `j` is a
    /// branching value read in place, a leaf that makes a value is read
    /// where it is too (Core §3): it is a temporary of the statement that
    /// reads the branching value, and `j` holds a loan on it.
    fn storeLeaf(self: *Lowerer, j: VarId, v: ?VarId, e: Sexp) Error!void {
        const pos = self.posOf(e);
        const r = self.read_leaves.get(j) orelse return self.store(j, v, pos);
        const made = v orelse return self.store(j, v, pos);
        const mv = self.f.vars.items[made];
        if (mv.kind != .owning) return self.store(j, v, pos);
        const h = try self.newVar("temporary", mv.ty, true, pos);
        try self.regions.items[r].vars.append(self.a, h);
        try self.store(h, made, pos);
        try self.store(j, try self.lend(.{ .root = h, .path = &.{}, .ty = mv.ty }, .read, e, mv.ty), pos);
    }

    /// Lower an expression in a context; the var holding its value, or
    /// null for a value that holds no loan and needs no drop (a literal,
    /// a constant, nothing).
    fn eval(self: *Lowerer, e: Sexp, how: How, want: ?TypeId) Error!?VarId {
        const pos = self.posOf(e);
        const k = e.kind() orelse return self.leafValue(e, how, want);
        switch (k) {
            .member, .index => {
                if (k == .member and try self.constant(e)) return null;
                if (self.constRooted(e)) return null;
                const p = try self.place(e) orelse return abstain("an unusual access");
                return try self.placeValue(p, how, want, e);
            },
            .call => return self.call(e, how),
            .read, .write => {
                const operand = ir.get(e, .operand);
                if (k == .write) return try self.lend(try self.writePlace(operand), .write, e, try self.typeOf(e));
                const p = try self.place(operand) orelse blk: {
                    if (isBranching(operand)) return abstain("a lend of a branching value (Core §3, planned)");
                    const t = try self.eval(operand, .take, null) orelse return null;
                    break :blk Place{ .root = t, .path = &.{}, .ty = self.f.vars.items[t].ty };
                };
                return try self.lend(p, .read, e, try self.typeOf(e));
            },
            .move => return self.move(e, how),
            .clone => {
                const operand = ir.Clone.operand(e);
                const t = try self.temp(try self.typeOf(e), pos);
                const p = try self.place(operand) orelse {
                    // `+mk()`: a new owner of what the temporary holds.
                    const m = try self.eval(operand, .read, null) orelse return abstain("a clone of a constant");
                    try self.emit(.{ .pos = pos, .what = .make, .reads = try self.one(m), .def = t, .unpoint = self.isRef(self.f.vars.items[m].ty) });
                    return t;
                };
                // `+x` reads `x` and makes a new owner of its value, part by
                // part (Core s2): it carries the loans of the views the value
                // holds; through a view, `+r` of a `?T` is a new `T`, which
                // carries no loan on what `r` sees.
                const through = p.via != .own or self.isRef(p.ty);
                try self.emit(.{ .pos = pos, .what = .make, .reads = try self.one(p.root), .def = t, .unpoint = through, .access = .{ .root = p.root, .path = p.path, .deref = p.via == .write, .kind = .read } });
                return t;
            },
            .@"if", .block, .match, .@"??", .@"catch" => {
                // A branching value read where it stands is copied there;
                // a Cell of an owner in the copy shares what a later read
                // lend of its place may change (Core s9), which the oracle
                // does not model.
                if (how == .read) {
                    const ti = self.ctx.typeInfo(try self.typeOf(e));
                    if (ti.cell) return abstain("a branching value holding a Cell, read");
                }
                // Read where it stands, a branching value of a type that
                // does not copy is each leaf read in place: a view, held
                // until what reads it is done (Core §3, §6: `print(a if c
                // else b, grow(!a))` reads `a` as `?a` would).
                // Where the context wants the value a view of its type
                // reaches (a binding of an `Int` from `w if c else v`, with
                // `w, v: !Int`), each branch is read as that value (Core §4).
                const ty = try self.wantedValue(try self.typeOf(e), want);
                const in_place = (how == .read or how == .view) and !(try self.kinds.of(ty)).kind.copies();
                // A branch whose every leaf is a write view (its type is
                // `!T`) is a write view of the leaf it took (Core §4).
                const view_kind: kinds.Kind = if (self.ctx.types.get(ty) == .write_view) .write_view else .read_view;
                const t = if (in_place) try self.viewTemp(ty, view_kind, pos) else try self.temp(ty, pos);
                if (in_place) try self.read_leaves.put(self.a, t, self.regions.items.len - 1);
                try self.valueInto(e, how, t);
                return t;
            },
            .propagate, .propagate_none => {
                // `e!` and `e?` leave the function on failure or absence,
                // dropping every temporary and binding so far (Core s10, §3).
                const v = try self.eval(ir.get(e, .value), if (how == .ret) .take else how, want);
                const exit = try self.newBlock();
                const on = try self.newBlock();
                try self.branch(on, exit);
                self.cur = exit;
                // `e!` fails the function; `e?` returns `none`.
                try self.ret(null, pos, if (k == .propagate) .yes else .no);
                self.cur = on;
                return v;
            },
            .array => {
                var parts: std.ArrayList(VarId) = .empty;
                // Each element is taken as the array's element type wants:
                // a bare write view would be copied (Core s1).
                const elem: ?TypeId = switch (self.ctx.types.get(try self.typeOf(e))) {
                    .array => |arr| arr.elem,
                    else => null,
                };
                for (ir.rest(e, .elems)) |el| if (try self.eval(el, .take, elem)) |v| try parts.append(self.a, v);
                const t = try self.temp(try self.typeOf(e), pos);
                try self.emit(.{ .pos = pos, .what = .make, .moves = parts.items, .def = t });
                return t;
            },
            .array_fill => {
                // `[n of x]` copies `x` (Core §5).
                const n = try self.eval(ir.ArrayFill.size(e), .read, null);
                const v = try self.eval(ir.ArrayFill.value(e), .read, null);
                const t = try self.temp(try self.typeOf(e), pos);
                try self.emit(.{ .pos = pos, .what = .make, .reads = try self.pair(n, v), .def = t });
                return t;
            },
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&", .@"|", .@"^", .@"<<", .@">>", .@".." => {
                // An operand is read as its value (SPEC §7).
                const l = try self.readOpt(ir.get(e, .left));
                const r = try self.readOpt(ir.get(e, .right));
                const t = try self.temp(try self.typeOf(e), pos);
                try self.emit(.{ .pos = pos, .what = .make, .uses = try self.pair(l, r), .def = t });
                return t;
            },
            .neg, .not => {
                const v = try self.readOpt(ir.get(e, .operand));
                const t = try self.temp(try self.typeOf(e), pos);
                try self.emit(.{ .pos = pos, .what = .make, .uses = try self.list(v), .def = t });
                return t;
            },
            .@"and", .@"or" => {
                // The right side runs only on some paths.
                const l = try self.eval(ir.get(e, .left), .read, null);
                const t = try self.temp(try self.typeOf(e), pos);
                try self.emit(.{ .pos = pos, .what = .make, .uses = try self.list(l), .def = t });
                const r_blk = try self.newBlock();
                const x = try self.newBlock();
                try self.branch(r_blk, x);
                self.cur = r_blk;
                const r = try self.eval(ir.get(e, .right), .read, null);
                try self.emit(.{ .pos = pos, .what = .make, .uses = try self.list(r), .def = t });
                try self.goto(x);
                self.cur = x;
                return t;
            },
            .enum_lit => return null,
            .@"return", .@"break", .@"continue" => {
                try self.valueInto(e, how, undefined);
                return null;
            },
            .pass => return null,
            // A stack closure is called where it is written, bound to a
            // local, or lent to a call; it never leaves its function
            // (Core §7: it may be lent, not stored).
            .lambda => switch (how) {
                .ret => return self.found(.B4, pos, "a stack closure does not leave the function that writes it; make it owned (`*|...|`)", .{}),
                .take => return abstain("a stack closure stored"),
                .read, .view => return try self.closure(e, false),
            },
            .share => {
                // `*<x` moves `x` into a counted box and `*S(...)` boxes a
                // new value: the box takes it, with its loans (Core s8, s9).
                // An owned closure's environment is the box (Core §7).
                const operand = ir.get(e, .operand);
                const v = if (operand.isKind(.lambda)) try self.closure(operand, true) else try self.eval(operand, .take, null);
                const t = try self.temp(try self.typeOf(e), pos);
                try self.emit(.{ .pos = pos, .what = .make, .moves = try self.list(v), .def = t });
                return t;
            },
            .weak => {
                // `~h` reads the handle and holds its box weakly, with the
                // contents' loans, as every handle does (Core s8, s9).
                const p = try self.place(ir.get(e, .operand)) orelse return abstain("a weak handle of a made value");
                const t = try self.temp(try self.typeOf(e), pos);
                try self.emit(.{ .pos = pos, .what = .make, .reads = try self.one(p.root), .def = t, .access = readAccess(p) });
                return t;
            },
            .builtin, .raw_block => return abstain("`raw`"),
            .inst => return abstain("compile-time arguments"),
            .kwarg => return abstain("a keyword argument out of place"),
            .@"while", .@"for" => {
                // A loop that `break` leaves with a value (SPEC §6); a
                // write view's value is read through there.
                var ty = try self.typeOf(e);
                if (self.ctx.types.get(ty) == .write_view) ty = try self.innerOf(ty);
                const t = try self.temp(ty, pos);
                if (k == .@"while") try self.whileStmt(e, t) else try self.forStmt(e, t);
                return t;
            },
            else => return abstain(switch (k) {
                inline else => |tag| "an unusual expression: " ++ @tagName(tag),
            }),
        }
    }

    /// A value read where it stands: a `?T` or `!T` made there is read
    /// through, ending the loan taken to reach it.
    fn readOpt(self: *Lowerer, e: Sexp) Error!?VarId {
        if (e == .nil) return null;
        const v = try self.eval(e, .read, null) orelse return null;
        return try self.readThrough(v, self.posOf(e));
    }

    fn valueOpt(self: *Lowerer, e: Sexp, how: How) Error!?VarId {
        if (e == .nil) return null;
        return try self.eval(e, how, null);
    }

    fn pair(self: *Lowerer, x: ?VarId, y: ?VarId) Error![]const VarId {
        var out: std.ArrayList(VarId) = .empty;
        if (x) |v| try out.append(self.a, v);
        if (y) |v| try out.append(self.a, v);
        return out.items;
    }

    fn isBranching(e: Sexp) bool {
        const k = e.kind() orelse return false;
        return switch (k) {
            .@"if", .@"??", .@"catch", .propagate, .propagate_none, .match, .block => true,
            else => false,
        };
    }

    /// A member that names no place: a module's constant, an enum
    /// variant, an error.
    fn constant(self: *Lowerer, e: Sexp) Error!bool {
        const obj = ir.Member.object(e);
        if (self.ctx.isErrorMember(e)) return true;
        if (obj != .src) return false;
        // `Int.min`: a member of a built-in type.
        const sym_id = self.ctx.symbolOf(obj) orelse return self.ctx.typeOf(obj) == null;
        const sym = self.ctx.symbols.items[sym_id];
        return switch (sym.kind) {
            .module, .nominal_type, .type_alias, .generic_type => true,
            else => false,
        };
    }

    fn constRooted(self: *Lowerer, e: Sexp) bool {
        switch (e) {
            .src => {
                const sym_id = self.ctx.symbolOf(e) orelse return false;
                const sym = self.ctx.symbols.items[sym_id];
                return sym.kind == .local and sym.scope == sema.module_scope and !self.vars.contains(sym_id);
            },
            .list => {
                const k = e.kind() orelse return false;
                if (k == .member) return self.constant(e) catch false or self.constRooted(ir.Member.object(e));
                if (k == .index) return self.constRooted(ir.Index.object(e));
                return false;
            },
            else => return false,
        }
    }

    fn leafValue(self: *Lowerer, e: Sexp, how: How, want: ?TypeId) Error!?VarId {
        if (e != .src) return null;
        const sym_id = self.ctx.symbolOf(e) orelse return null; // a literal
        const sym = self.ctx.symbols.items[sym_id];
        switch (sym.kind) {
            // A function lives for the whole program and carries no loan.
            .function => return null,
            .local, .param, .capture => {},
            else => return abstain("an unusual name"),
        }
        // A module's constant lives for the whole program (Core s7).
        const v = self.vars.get(sym_id) orelse {
            if (sym.scope == sema.module_scope) return null;
            return abstain("a name the lowering did not bind");
        };
        const p = self.rootPlace(v);
        return try self.placeValue(p, how, want, e);
    }

    /// A place expression: a local, or a field or element of a place or
    /// of a made value. Null when `e` is not one.
    fn place(self: *Lowerer, e: Sexp) Error!?Place {
        switch (e) {
            .src => {
                const sym_id = self.ctx.symbolOf(e) orelse return null;
                const v = self.vars.get(sym_id) orelse return null;
                return self.rootPlace(v);
            },
            .list => if (self.made_root) |mr| {
                const span = self.parser.span(e);
                if (span.start == mr.start and span.end == mr.end) return self.rootPlace(mr.v);
            },
            else => return null,
        }
        const k = e.kind() orelse return null;
        if (k != .member and k != .index) return null;
        if (k == .member and try self.constant(e)) return null;
        if (k == .index and self.ctx.instanceOf(e) != null) return abstain("compile-time arguments");
        const obj = ir.get(e, .object);
        // Part of a module's constant lives for the whole program.
        if (self.constRooted(obj)) return null;
        const base = try self.place(obj) orelse blk: {
            if (obj.isKind(.move)) return abstain("a sigil on an accessed object");
            // A lend (`(!h).f`, `(?mk()).f`) is a view: its part is
            // reached through it (Core §4), as through a `!T` or `?T`.
            if (obj.isKind(.read) or obj.isKind(.write)) {
                const t = try self.eval(obj, .read, null) orelse return abstain("a lend of a constant");
                const tv = self.f.vars.items[t];
                break :blk Place{ .root = t, .path = &.{}, .ty = tv.ty, .via = if (obj.isKind(.write)) .write else .read };
            }
            // The object of a field or element read is only read (Core §3).
            const t = try self.eval(obj, .read, null) orelse return abstain("an access to a constant");
            // A branching value read where it stands is each leaf read
            // where it is (Core §3): its part is what that view sees, and
            // carries the loans on the leaves, a made leaf's on the
            // statement's temporary (`storeLeaf`).
            const tv = self.f.vars.items[t];
            const via: Place.Via = if (tv.kind == .read_view) .read else .own;
            break :blk Place{ .root = t, .path = &.{}, .ty = tv.ty, .via = via };
        };
        var step: Step = undefined;
        var slice = false;
        if (k == .index) {
            // The indexes run before the place is used.
            try self.finding.append(self.a, base.root);
            const idx = ir.Index.index(e);
            if (idx.isKind(.@"..")) {
                slice = true;
                _ = try self.valueOpt(ir.get(idx, .left), .read);
                _ = try self.valueOpt(ir.get(idx, .right), .read);
            } else _ = try self.eval(idx, .read, null);
            _ = self.finding.pop();
            step = .elem;
        } else step = .{ .field = ir.Member.name(e).getText(self.src) };
        const path = try self.a.alloc(Step, base.path.len + 1);
        @memcpy(path[0..base.path.len], base.path);
        path[base.path.len] = step;
        // A step out of a view leaves the root's own storage.
        var via = base.via;
        var carry = base.carry;
        var under_write = base.under_write;
        var handle = base.handle;
        switch (self.ctx.types.get(base.ty)) {
            // What a handle holds is read through it, and stays while the
            // handle does: a loan on the handle (Core s8, §4's `*T` row).
            .shared => handle = true,
            .weak => return abstain("an access through a weak handle"),
            // A view reached through a slice or String carries that
            // view's loans, through a write view too (Core s7).
            .slice, .string => if (via != .read or !carry) {
                if (via == .write) under_write = true;
                via = .read;
                carry = true;
            },
            .read_view => if (via == .own) {
                via = .read;
            },
            .write_view => if (via == .own) {
                via = .write;
            },
            else => {},
        }
        return .{ .root = base.root, .path = path, .ty = try self.typeOf(e), .via = via, .slice = slice, .slice_of = if (slice) base.ty else 0, .carry = carry, .under_write = under_write, .handle = handle };
    }

    /// A var as a place; an alias is the payload it sees.
    fn rootPlace(self: *Lowerer, v: VarId) Place {
        const vv = self.f.vars.items[v];
        const via: Place.Via = if (!vv.alias) .own else if (vv.kind == .write_view) .write else .read;
        return .{ .root = v, .path = &.{}, .ty = vv.ty, .via = via };
    }

    /// A bare place where a value is wanted (Core s1, §3).
    fn placeValue(self: *Lowerer, p: Place, how: How, want: ?TypeId, e: Sexp) Error!?VarId {
        const pos = self.posOf(e);
        const info = try self.kinds.of(p.ty);
        if (info.unsupported) |why| return abstain(why);
        // A bare slice of a place lends it (Core §4), and so does one
        // through a write view, which may change or replace what the
        // slice views; a slice of a String copies the view it is.
        if (p.slice and (p.via == .own or (p.via == .write and !self.slicesString(p.slice_of)))) return try self.lend(p, .read, e, p.ty);
        // A value holding a write view moves as an owner does (Core §1);
        // the compiler lends one on where it is handed over bare, which
        // the oracle does not model.
        const holds_write = info.kind == .write_view and !self.isWriteRef(p.ty);
        if (holds_write and (how == .view or (how == .take and !(p.path.len == 0 and p.via == .own and self.f.vars.items[p.root].hidden)))) {
            return abstain("a bare value holding a write view handed on");
        }
        const kind: kinds.Kind = if (holds_write) .owning else info.kind;
        switch (kind) {
            .plain, .read_view => return try self.copy(p, p.ty, pos),
            .write_view => {
                // A write view read as its value copies what it reaches,
                // a name, field, or element alike (Core s1, SPEC §7); a
                // write slice read as a slice views the same
                // elements, a lend on. A write view itself never copies.
                const wants_view = if (want) |w| self.ctx.types.get(w) == .write_view else false;
                const t_ty = try self.innerOf(p.ty);
                const ti = try self.kinds.of(t_ty);
                const through: Place = .{ .root = p.root, .path = p.path, .ty = t_ty, .via = .write };
                const elems = self.ctx.types.get(t_ty) == .slice;
                switch (how) {
                    .read => {
                        if (ti.kind.copies() and !elems) return try self.copy(through, t_ty, pos);
                        return try self.lend(through, .read, e, t_ty);
                    },
                    .view => return abstain("a bare write view passed as a view"),
                    .take, .ret => {
                        if (!wants_view and ti.kind.copies()) {
                            if (elems) return try self.lend(through, .read, e, t_ty);
                            return try self.copy(through, t_ty, pos);
                        }
                        if (how == .ret and p.path.len == 0 and p.via == .own) return try self.moveWhole(p.root, pos);
                        return self.found(.C2, pos, "a bare write view would be copied; write `<` to move it", .{});
                    },
                }
            },
            .owning => {
                // Whether a function value copies depends on what it holds
                // (a function, or a closure that never moves).
                if (self.ctx.types.get(p.ty) == .function) return abstain("a bare function value");
                if (how == .take or how == .ret) if (self.fnTypeOf(p.ty) != null) return abstain("a function value handed on");
                switch (how) {
                    .read, .view => return try self.lend(p, .read, e, p.ty),
                    .ret => if (p.path.len == 0 and p.via == .own and !self.f.vars.items[p.root].hidden) return try self.moveWhole(p.root, pos),
                    .take => {},
                }
                // A generic body may copy a `T`, which each instance must
                // allow (SPEC "Generic bodies"); not a payload of a place
                // the function owns, as its result, which would move out
                // of that place.
                const payload = how == .ret and self.owned_payloads.contains(p.root);
                if (info.generic_copy and !payload) {
                    self.copies_t = true;
                    return try self.copy(p, p.ty, pos);
                }
                return self.found(.C2, pos, "a bare `{s}` owns a resource and would be copied; write `<` or `+`", .{self.textOf(e)});
            },
        }
    }

    fn textOf(self: *Lowerer, e: Sexp) []const u8 {
        const span = self.parser.span(e);
        return self.src[span.start..span.end];
    }

    fn copy(self: *Lowerer, p: Place, ty: TypeId, pos: u32) Error!VarId {
        const t = try self.temp(ty, pos);
        try self.emit(.{ .pos = pos, .what = .copy, .reads = try self.one(p.root), .def = t, .access = readAccess(p), .carry = p.carry });
        return t;
    }

    /// What reading a place accesses: nothing behind a read view; the
    /// write view's place, when the path passed through one.
    fn readAccess(p: Place) ?core.Access {
        if (p.under_write) return .{ .root = p.root, .deref = true, .kind = .read };
        if (p.via == .read) return null;
        return .{ .root = p.root, .path = p.path, .deref = p.via == .write, .kind = .read };
    }

    fn moveWhole(self: *Lowerer, root: VarId, pos: u32) Error!VarId {
        try self.keptByDefer(root, pos);
        try self.keptByClosure(root, pos);
        // A loop element of a generic type taken from a collection the
        // loop reads is a copy, which each instance must allow (SPEC
        // "Generic bodies").
        if (self.loop_elems.contains(root) and (try self.kinds.of(self.f.vars.items[root].ty)).generic_copy) {
            self.copies_t = true;
            return try self.copy(self.rootPlace(root), self.f.vars.items[root].ty, pos);
        }
        if (self.f.vars.items[root].alias) return self.found(.C7, pos, "a payload seen through a view does not move out; take the subject with `<`", .{});
        if (self.isFinding(root)) return abstain("an index that moves its place's root");
        const t = try self.temp(self.f.vars.items[root].ty, pos);
        try self.emit(.{ .pos = pos, .what = .move, .moves = try self.one(root), .def = t, .access = .{ .root = root, .kind = .whole } });
        return t;
    }

    /// Deferred code may read and write what is live where it runs
    /// (Core §7), so it moves or drops only what it declares itself: it
    /// runs at every exit of its scope (SPEC "defer and errdefer").
    fn keptByDefer(self: *Lowerer, v: VarId, pos: u32) Error!void {
        if (self.in_defer and v < self.defer_vars) return self.found(.B2, pos, "deferred code does not move or drop `{s}`, which it did not declare", .{self.f.vars.items[v].name});
    }

    /// A closure's environment holds what it captured for the closure's
    /// life: the body uses it, and never moves or drops it (Core §7).
    fn keptByClosure(self: *Lowerer, v: VarId, pos: u32) Error!void {
        const vv = self.f.vars.items[v];
        if (vv.capture) return self.found(.B3, pos, "a closure does not move or drop `{s}`, which it captured", .{vv.name});
    }

    /// Whether `v` is a closure or a view of one whose result holds no
    /// view: a call it is handed to, or a call of it, can keep none of
    /// what it captured (no value holds a stack closure or a `?fun`, and
    /// an owned closure carries no loan).
    fn callsOnly(self: *Lowerer, v: VarId, call_ty: TypeId) Error!bool {
        const ft = self.fnTypeOf(self.f.vars.items[v].ty) orelse return false;
        if (self.holdsCallable(call_ty)) return false;
        if (self.ctx.types.get(ft.returns) == .void) return true;
        return !(try self.kinds.of(ft.returns)).holds_views;
    }

    /// Whether a value of `ty` may be a closure or a view of one.
    fn holdsCallable(self: *Lowerer, ty: TypeId) bool {
        return switch (self.ctx.types.get(ty)) {
            .function, .callable => true,
            .optional, .fallible, .read_view, .write_view, .shared, .weak => |inner| self.holdsCallable(inner),
            else => false,
        };
    }

    /// The function type a callee value of type `ty` calls.
    fn fnTypeOf(self: *Lowerer, ty: TypeId) ?sema.FunctionType {
        var t = ty;
        while (true) switch (self.ctx.types.get(t)) {
            .function => |f| return f,
            .callable, .read_view, .shared => |inner| t = inner,
            else => return null,
        };
    }

    /// A closure literal (Core §7): each capture in order, as its sigil
    /// says (`?x` and `!x` lend, `<x` moves, `+x` copies or adds a count,
    /// `~x` holds weakly), into the closure's environment, which carries
    /// their loans; an owned closure's (`owned`) may carry none (Core
    /// s9, C8). Its body is checked as a function of its own, and what
    /// it finds is the enclosing function's.
    fn closure(self: *Lowerer, e: Sexp, owned: bool) Error!VarId {
        const pos = self.posOf(e);
        var parts: std.ArrayList(VarId) = .empty;
        for (sema.captureList(ir.Lambda.captures(e))) |cap| {
            const leaf = sema.captureNameNode(cap) orelse return abstain("an unusual capture");
            const sym_id = self.ctx.symbolOf(leaf) orelse return abstain("a capture without a symbol");
            const sym = self.ctx.symbols.items[sym_id];
            const outer = self.vars.get(sym.origin) orelse return abstain("a capture of a name the lowering did not bind");
            const p = self.rootPlace(outer);
            const v = switch (sema.captureModeOf(cap).?) {
                .cap_read => try self.lend(p, .read, leaf, sym.ty),
                .cap_write => try self.lend(p, .write, leaf, sym.ty),
                .cap_move => try self.moveWhole(outer, leaf.src.pos),
                .cap_clone, .cap_weak => blk: {
                    // `|+x|` makes what `+x` makes (Core §7): through a
                    // view, a value that carries no loan on what the view
                    // sees, but what that holds.
                    const through = self.isRef(self.f.vars.items[outer].ty) and !self.isRef(sym.ty);
                    const t = try self.temp(sym.ty, leaf.src.pos);
                    try self.emit(.{ .pos = leaf.src.pos, .what = .make, .reads = try self.one(outer), .def = t, .access = readAccess(p), .unpoint = through });
                    break :blk t;
                },
            };
            // Dropping the environment would run a `drop` body.
            if (self.f.vars.items[v].drop_reads) return abstain("a closure holding a value with a `drop` body");
            try parts.append(self.a, v);
        }
        var inner: Lowerer = .{
            .a = self.a,
            .ctx = self.ctx,
            .parser = self.parser,
            .src = self.src,
            .kinds = kinds.Kinds.init(self.a, self.ctx, self.planned),
            .planned = self.planned,
        };
        inner.kinds.generic = self.kinds.generic;
        inner.module = self.module;
        inner.runClosure(e) catch |err| switch (err) {
            error.Found => {},
            else => |x| return x,
        };
        if (inner.copies_t) self.copies_t = true;
        try self.t_calls.appendSlice(self.a, inner.t_calls.items);
        if (inner.f.early == null) try inner.finish();
        const finding = inner.f.early orelse try flow.check(self.a, &inner.f);
        if (finding) |f| {
            if (self.f.early == null) self.f.early = f;
            return error.Found;
        }
        const t = try self.temp(try self.typeOf(e), pos);
        try self.emit(.{ .pos = pos, .what = .make, .moves = parts.items, .def = t, .no_loans = owned });
        // Its calls may store what it captured through what it captured
        // to write, as a call's write arguments may (SPEC §11 "Captures";
        // what one call received it never stores there, as checked in
        // its body): those places hold the captures' loans from here on.
        try self.emit(.{ .pos = pos, .what = .call, .reads = try self.one(t), .through = try self.one(t) });
        return t;
    }

    fn isHandle(self: *Lowerer, ty: TypeId) bool {
        return switch (self.ctx.types.get(sema.unwrapViews(self.ctx, ty))) {
            .shared, .weak => true,
            else => false,
        };
    }

    fn isFinding(self: *Lowerer, root: VarId) bool {
        return std.mem.findScalar(VarId, self.finding.items, root) != null;
    }

    /// What `!e` lends to write (Core s4: any value, named or
    /// temporary): the place `e` is, or else the value `e` makes, a
    /// temporary of the statement (Core §3), which holds it until the
    /// statement ends. A literal lives for the whole program, as a
    /// constant does (Core s7), and a branching value may be a name's.
    fn writePlace(self: *Lowerer, e: Sexp) Error!Place {
        if (try self.place(e)) |p| return p;
        // A branching value every value of which is made there is one
        // temporary (Core §3), taken branch by branch.
        if (isBranching(e)) {
            if (!self.madeEverywhere(e)) return abstain("a write lend of a branching value that may be a name's");
            const t = try self.temp(try self.typeOf(e), self.posOf(e));
            try self.valueInto(e, .take, t);
            return .{ .root = t, .path = &.{}, .ty = self.f.vars.items[t].ty };
        }
        const t = try self.eval(e, .take, null) orelse return abstain("a write lend of a literal");
        if (!self.f.vars.items[t].hidden) return abstain("a write lend of an unusual value");
        return .{ .root = t, .path = &.{}, .ty = self.f.vars.items[t].ty };
    }

    /// Whether every value branching `e` may be is made there, or jumps:
    /// none is a name, a field or element, or a lend (Core §3).
    fn madeEverywhere(self: *Lowerer, e: Sexp) bool {
        const k = e.kind() orelse return self.ctx.symbolOf(e) == null;
        return switch (k) {
            .member, .index, .read, .write => false,
            .@"if" => blk: {
                const els = ir.If.@"else"(e);
                break :blk els != .nil and self.madeEverywhere(ir.If.then(e)) and self.madeEverywhere(els);
            },
            .match => for (ir.Match.arms(e)) |arm| {
                if (!self.madeEverywhere(ir.Arm.body(arm))) break false;
            } else true,
            .@"??" => self.madeEverywhere(ir.get(e, .left)) and self.madeEverywhere(ir.get(e, .right)),
            .@"catch" => self.madeEverywhere(ir.Catch.value(e)) and self.madeEverywhere(ir.Catch.handler(e)),
            .propagate, .propagate_none => self.madeEverywhere(ir.get(e, .value)),
            .block => blk: {
                const stmts = ir.Block.stmts(e);
                break :blk stmts.len > 0 and isValue(stmts[stmts.len - 1]) and self.madeEverywhere(stmts[stmts.len - 1]);
            },
            else => true,
        };
    }

    /// `?p` or `!p` (Core s4, §4): a new loan on the place, carrying what
    /// the root views; through a read view, a copy of that view.
    fn lend(self: *Lowerer, p: Place, mode: core.Mode, e: Sexp, ty: TypeId) Error!VarId {
        const pos = self.posOf(e);
        const kind: kinds.Kind = if (mode == .read) .read_view else .write_view;
        if (mode != .read and self.isFinding(p.root)) return abstain("an index that lends its place's root to write");
        if (mode != .read and p.handle) return abstain("a write lend through a handle");
        const pk = (try self.kinds.of(p.ty)).kind;
        // Lending a view the place holds hands over a copy of it; lending
        // the place itself (`?p.s` as a `?String`, a slice) makes a loan.
        const pointer = switch (self.ctx.types.get(ty)) {
            .read_view, .write_view => ty != p.ty,
            else => false,
        };
        // A generic loop's element of a `?Vec[T]` is a copy the iteration
        // holds (SPEC "Generic bodies"): `?x` lends that copy, whose loan
        // ends with the iteration.
        const loop_copy = p.path.len == 0 and mode == .read and self.loop_elems.contains(p.root) and self.genericLoopCopy(p.root);
        if (loop_copy) {
            const loan = try self.lentLoan(p, .read, false, 0, pos);
            const t = try self.viewTemp(ty, kind, pos);
            try self.emit(.{ .pos = pos, .what = .lend, .reads = try self.one(p.root), .def = t, .loan = loan, .access = .{ .root = p.root, .kind = .read } });
            return t;
        }
        if (p.via == .read or (p.via == .own and pk == .read_view and !p.slice and !pointer)) {
            if (mode != .read) return abstain("a write lend through a read view");
            const t = try self.viewTemp(ty, kind, pos);
            try self.emit(.{ .pos = pos, .what = .copy, .reads = try self.one(p.root), .def = t, .access = readAccess(p), .carry = p.carry });
            return t;
        }
        const deref = p.via == .write or (!p.slice and self.isWriteRef(p.ty));
        const loan = try self.lentLoan(p, mode, deref, 0, pos);
        // A slice or a String views the place's bytes, and copies of it
        // carry the loan; a `?T` or `!T` points at the place.
        self.f.loans.items[loan].pointer = switch (self.ctx.types.get(ty)) {
            .slice, .string => false,
            else => !p.slice,
        };
        const t = try self.viewTemp(ty, kind, pos);
        try self.emit(.{ .pos = pos, .what = .lend, .reads = try self.one(p.root), .def = t, .loan = loan, .access = .{
            .root = p.root,
            .path = p.path,
            .deref = deref,
            .kind = switch (mode) {
                .read => .read,
                .write => .write,
                .reserved => .reserve,
            },
        } });
        return t;
    }

    /// A loan on place `p`, which a view carries where the type of what
    /// is lent could hold what the view views (`lent`; `core.Loan.ty`).
    fn lentLoan(self: *Lowerer, p: Place, mode: core.Mode, deref: bool, group: u32, pos: u32) Error!core.LoanId {
        const loan = try self.newLoan(p, mode, deref, group, pos);
        // What the loan is on: for a slice, what is sliced; through a
        // write view, the view, which may write what it reaches.
        self.f.loans.items[loan].ty = if (p.slice) p.slice_of else p.ty;
        return loan;
    }

    fn newLoan(self: *Lowerer, p: Place, mode: core.Mode, deref: bool, group: u32, pos: u32) Error!core.LoanId {
        try self.f.loans.append(self.a, .{
            .root = p.root,
            .path = p.path,
            .mode = mode,
            .deref = deref,
            .group = group,
            .pos = pos,
            .stores_views = try self.storesViews(p),
        });
        return @intCast(self.f.loans.items.len - 1);
    }

    /// `<` always leaves its source done (Core s2, §5): `<x` moves a
    /// whole binding, and `<p.f` takes an optional field, leaving `none`.
    /// Any other place is rejected: a part that copies would stay as it
    /// was, and one that moves stays its owner's. A module's constant
    /// lives for the whole program; a part of a value made here is done
    /// with its statement.
    fn move(self: *Lowerer, e: Sexp, how: How) Error!?VarId {
        return self.moveOut(ir.Move.operand(e), self.posOf(e), how);
    }

    /// `move` of `operand`, also the source of a `for x in <e`.
    fn moveOut(self: *Lowerer, operand: Sexp, pos: u32, how: How) Error!?VarId {
        if (self.moduleValue(operand)) return self.found(.C3, pos, "a module's constant lives for the whole program; `<` can neither end nor empty it", .{});
        if (self.declaredFunction(operand)) return self.found(.C3, pos, "a function lives for the whole program; `<` cannot end it", .{});
        // A branching value gives up only its leaves made there; `<` would
        // leave any other leaf as it was (Core §3: `<a if c else <b`).
        if (isBranchingValue(operand)) {
            if (try self.keptLeaf(operand)) |leaf| return self.found(.C3, self.posOf(leaf), "`<` of a branching value leaves this leaf as it was; move it inside the branch", .{});
        }
        if (operand == .src) {
            const v = self.varOf(operand) orelse return abstain("a move of something not a local");
            return try self.moveWhole(v, pos);
        }
        const p = try self.place(operand) orelse return try self.eval(operand, how, null);
        const info = try self.kinds.of(p.ty);
        if (self.ctx.types.get(p.ty) == .optional) {
            if (p.via == .read) return self.found(.C7, pos, "nothing is taken out through a read view", .{});
            // A part of a value made in the statement: nothing would see
            // it emptied.
            if (p.via == .own and self.f.vars.items[p.root].hidden) return self.found(.C3, pos, "a part of a value made here is dropped with it; nothing would see it emptied", .{});
            if (p.handle) return abstain("a take through a handle");
            const t = try self.temp(p.ty, pos);
            try self.emit(.{ .pos = pos, .what = .take, .reads = try self.one(p.root), .def = t, .access = .{ .root = p.root, .path = p.path, .deref = p.via == .write, .kind = .write } });
            return t;
        }
        if (info.kind.copies()) return self.found(.C3, pos, "a part that copies is neither ended nor emptied; `<` would leave it as it was", .{});
        return self.found(.C3, pos, "only a whole binding moves; a field that is not optional cannot be taken", .{});
    }

    /// A function named as a value: `one`, `geo.mk`, `Point.origin`.
    fn declaredFunction(self: *Lowerer, e: Sexp) bool {
        const ty = self.ctx.typeOf(e) orelse return false;
        if (self.ctx.types.get(ty) != .function) return false;
        if (e == .src) {
            const sym_id = self.ctx.symbolOf(e) orelse return false;
            return self.ctx.symbols.items[sym_id].kind == .function;
        }
        if (!e.isKind(.member)) return false;
        const obj = ir.Member.object(e);
        if (obj != .src) return false;
        const sym_id = self.ctx.symbolOf(obj) orelse return false;
        return switch (self.ctx.symbols.items[sym_id].kind) {
            .module, .nominal_type, .type_alias, .generic_type => true,
            else => false,
        };
    }

    /// A value that is one of its operands: `a if c else b`, `a ?? b`,
    /// `e catch h`, `e!`, `e?`. (A `match` or a block makes its value.)
    fn isBranchingValue(e: Sexp) bool {
        const k = e.kind() orelse return false;
        return switch (k) {
            .@"if" => ir.If.@"else"(e) != .nil,
            .@"??", .@"catch", .propagate, .propagate_none => true,
            else => false,
        };
    }

    /// The first leaf of branching value `e` that is not a value made
    /// there: a name, a field or element, or a constant.
    fn keptLeaf(self: *Lowerer, e: Sexp) Error!?Sexp {
        const leaves: [2]Sexp = switch (e.kind().?) {
            .@"if" => .{ blockTail(ir.If.then(e)), blockTail(ir.If.@"else"(e)) },
            .@"??" => .{ ir.get(e, .left), ir.get(e, .right) },
            .@"catch" => .{ ir.Catch.value(e), blockTail(ir.Catch.handler(e)) },
            .propagate => .{ ir.Propagate.value(e), .nil },
            .propagate_none => .{ ir.PropagateNone.value(e), .nil },
            else => unreachable,
        };
        for (leaves) |leaf| {
            if (leaf == .nil) continue;
            if (isBranchingValue(leaf)) {
                if (try self.keptLeaf(leaf)) |l| return l;
                continue;
            }
            if (self.leftAsItWas(leaf)) return leaf;
        }
        return null;
    }

    /// Whether `<` would leave leaf `e` as it was: a name of a binding, a
    /// function or constant, or a field or element of anything but a
    /// type (`Color.red` is a value).
    fn leftAsItWas(self: *Lowerer, e: Sexp) bool {
        if (e == .src) {
            const sym_id = self.ctx.symbolOf(e) orelse return false;
            const sym = self.ctx.symbols.items[sym_id];
            return switch (sym.kind) {
                .local, .param, .capture => true,
                .function => true,
                else => false,
            };
        }
        const k = e.kind() orelse return false;
        if (k != .member and k != .index) return false;
        if (k == .member and self.ctx.isErrorMember(e)) return false;
        if (self.declaredFunction(e) or self.moduleValue(e)) return true;
        // A type's member (`Color.red`, `Int.min`) is a value.
        if (k == .member) {
            const obj = ir.Member.object(e);
            if (obj == .src) {
                if (self.ctx.symbolOf(obj)) |id| switch (self.ctx.symbols.items[id].kind) {
                    .nominal_type, .type_alias, .generic_type => return false,
                    else => {},
                } else if (self.ctx.typeOf(obj) == null) return false;
            }
        }
        return true;
    }

    fn blockTail(b: Sexp) Sexp {
        if (!b.isKind(.block)) return b;
        const stmts = ir.Block.stmts(b);
        if (stmts.len == 0) return .nil;
        return blockTail(stmts[stmts.len - 1]);
    }

    /// A module's constant, of this module or another (`K`, `geo.K`), or
    /// a part of one (`geo.KP[0]`); not a type's member or a function.
    fn moduleValue(self: *Lowerer, e: Sexp) bool {
        switch (e) {
            .src => {
                const sym_id = self.ctx.symbolOf(e) orelse return false;
                const sym = self.ctx.symbols.items[sym_id];
                return sym.kind == .local and sym.scope == sema.module_scope and !self.vars.contains(sym_id);
            },
            .list => {
                const k = e.kind() orelse return false;
                if (k == .index) return self.moduleValue(ir.Index.object(e));
                if (k != .member) return false;
                const obj = ir.Member.object(e);
                if (obj == .src) if (self.ctx.symbolOf(obj)) |id| if (self.ctx.symbols.items[id].kind == .module) {
                    const ty = self.ctx.typeOf(e) orelse return false;
                    return self.ctx.types.get(ty) != .function;
                };
                return self.moduleValue(obj);
            },
            else => return false,
        }
    }

    // ---- calls ----------------------------------------------------------

    const Shape = enum { view, take };

    fn shapeOf(ctx: *const sema.SemContext, ty: TypeId) Shape {
        return switch (ctx.types.get(ty)) {
            .read_view, .write_view, .slice, .string, .callable => .view,
            .optional => |o| switch (ctx.types.get(o)) {
                .read_view, .write_view, .slice, .string => .view,
                else => .take,
            },
            else => .take,
        };
    }

    fn call(self: *Lowerer, e: Sexp, how: How) Error!?VarId {
        _ = how;
        const pos = self.posOf(e);
        const callee = self.ctx.calleeOf(e);
        const args = ir.Call.args(e);
        var reads: std.ArrayList(VarId) = .empty;
        var moves: std.ArrayList(VarId) = .empty;
        var gains: std.ArrayList(VarId) = .empty;
        var uses: std.ArrayList(VarId) = .empty;
        var access: ?core.Access = null;
        var activation: ?core.LoanId = null;
        // The var whose elements the call hands back, for a Vec's `get`,
        // `pop`, and `remove`.
        var elem_from: ?VarId = null;
        // A write receiver reached through a write view.
        var recv_view: ?VarId = null;
        // The holders of the places a `swap` or `replace` lends, and the
        // value `replace` stores.
        var exchanged: std.ArrayList(VarId) = .empty;
        var stored_value: std.ArrayList(VarId) = .empty;

        // A generic function or type at type arguments of plain data is
        // checked by its signature here; at others, whether the body
        // suits the instance is the instance's question (SPEC "Generic
        // bodies"), which the oracle does not answer.
        if (self.ctx.genericCallOf(e)) |gc| try self.genericCall(e, gc.type_args);
        try self.plainInstance(try self.typeOf(e));

        // A Cell or Signal made, or one a method stores into (Core s9).
        var cell_store = false;

        // What each argument goes to.
        var shapes: []const Shape = &.{};
        // Per parameter: the call stores the argument (a built-in
        // generic's `T`), even where it is a view.
        var stored: []const bool = &.{};
        var all_read = false;
        // `copy`'s element type: what it stores is a copy of each element
        // its argument's slice views.
        var elem_copy: ?TypeId = null;
        var group: u32 = 0;
        var is_ctor = false;
        var reach: kinds.Reach = .{ .a = self.a };
        // The callee's signature, as declared, whose parameter types say
        // which arguments the result and the stores carry (Core s7); null
        // for a built-in, which carries every argument's.
        var sig: ?Sig = null;
        // The receiver's vars in `reads` and `moves`, and whether its
        // write lend's loan is the call's own.
        var recv_vars: std.ArrayList(VarId) = .empty;

        if (callee == .src) {
            const name = callee.getText(self.src);
            const sym_id = self.ctx.symbolOf(callee);
            const sym: ?sema.Symbol = if (sym_id) |id| self.ctx.symbols.items[id] else null;
            const builtin = sym == null or sym.?.decl_pos == sema.builtin_decl_pos;
            if (builtin and std.mem.eql(u8, name, "print")) {
                all_read = true;
            } else if (builtin and (std.mem.eql(u8, name, "swap") or std.mem.eql(u8, name, "replace"))) {
                self.groups += 1;
                group = self.groups;
                if (std.mem.eql(u8, name, "swap")) all_read = true else shapes = &.{ .view, .take };
            } else if (self.ctx.textCallOf(e) == .new) {
                // `Text(...)` formats its arguments as `print` does.
                all_read = true;
            } else if (sym == null) {
                // A conversion, `Int(x)`, reads its argument.
                all_read = true;
            } else if (sym) |s| switch (s.kind) {
                .function => {
                    const ft = self.ctx.types.get(s.ty);
                    if (ft != .function) return abstain("an unusual callee");
                    shapes = try self.shapesOf(self.ctx, ft.function.params);
                    sig = .{ .ctx = self.ctx, .f = ft.function, .from = declaredFrom(self.ctx, s.decl_pos) };
                },
                .nominal_type, .generic_type, .type_alias => {
                    is_ctor = true;
                    cell_store = sym_id.? == self.ctx.cell_sym_id or sym_id.? == self.ctx.signal_sym_id;
                },
                // A closure, a function value, or a view of one: the
                // callee value first; the result carries its loans, the
                // loans of what the closure captured (Core s7).
                .local, .param, .capture => {
                    const v = self.vars.get(sym_id.?) orelse return abstain("a call of a name the lowering did not bind");
                    if (self.f.vars.items[v].kind == .write_view) return abstain("a call through a write view of a closure");
                    const vf = self.fnTypeOf(s.ty) orelse return abstain("an unusual callee");
                    shapes = try self.shapesOf(self.ctx, vf.params);
                    sig = .{ .ctx = self.ctx, .f = vf };
                    // The value called is read first, and stays read until
                    // the call runs (Core §6): a later argument may not
                    // change it. A stack closure's binding never changes
                    // (Core §7: it is only lent to read).
                    const cv = if (self.ctx.types.get(self.f.vars.items[v].ty) == .function)
                        v
                    else
                        (try self.placeValue(self.rootPlace(v), .read, null, callee)).?;
                    if (try self.callsOnly(v, try self.typeOf(e))) try uses.append(self.a, cv) else try reads.append(self.a, cv);
                },
                else => return abstain("an unusual callee"),
            };
        } else if (callee.isKind(.lambda)) {
            // A closure called where it is written: a temporary.
            const v = try self.closure(callee, false);
            const vf = self.fnTypeOf(try self.typeOf(callee)) orelse return abstain("an unusual callee");
            shapes = try self.shapesOf(self.ctx, vf.params);
            sig = .{ .ctx = self.ctx, .f = vf };
            if (try self.callsOnly(v, try self.typeOf(e))) try uses.append(self.a, v) else try reads.append(self.a, v);
        } else if (callee.isKind(.member)) {
            const obj = ir.Member.object(callee);
            const obj_sym: ?sema.Symbol = if (obj == .src) if (self.ctx.symbolOf(obj)) |id| self.ctx.symbols.items[id] else null else null;
            const static = if (obj_sym) |os| switch (os.kind) {
                .module, .nominal_type, .type_alias, .generic_type => true,
                else => false,
            } else obj.isKind(.member) and self.ctx.typeOf(obj) == null;
            if (static) {
                // A variant's constructor, or a function of the type.
                const ft: ?sema.Type = if (self.ctx.typeOf(callee)) |t| self.ctx.types.get(t) else null;
                if (ft != null and ft.? == .function) {
                    shapes = try self.shapesOf(self.ctx, ft.?.function.params);
                    // A generic function's callee has its instance's
                    // signature; only a plain one says what it was declared.
                    if (ft.?.function.ct_params.len == 0) sig = .{ .ctx = self.ctx, .f = ft.?.function, .from = self.staticFrom(callee) };
                } else is_ctor = true;
            } else {
                // A method: the receiver first, then the arguments.
                const recv_mode, const fn_params = try self.method(callee);
                const recv_obj = if (obj.isKind(.read) or obj.isKind(.write) or obj.isKind(.move)) ir.get(obj, .operand) else obj;
                const recv_ty = try self.typeOf(recv_obj);
                cell_store = self.isCell(recv_ty);
                if (fn_params) |fp| {
                    shapes = try self.shapesOf(fp.ctx, if (fp.ctx == self.ctx) try self.instParams(recv_ty, fp.params) else fp.params);
                    if (!fp.builtin) sig = .{ .ctx = fp.ctx, .f = fp.full, .receiver = true, .from = declaredFrom(fp.ctx, fp.decl_pos) };
                    // A built-in generic's `T` parameter stores what it is
                    // given (`push`, `insert`, a Cell's `set`).
                    const st = try self.a.alloc(bool, fp.params.len);
                    for (fp.params, st) |pt, *x| x.* = fp.ctx.types.get(pt) == .type_var;
                    stored = st;
                } else if (self.ctx.elemCallOf(callee)) |ec| switch (ec.op) {
                    // `fill` stores a copy of its value in every element,
                    // and `copy` copies of the values its slice's elements
                    // hold (Core §5): a copy of a view carries its loan.
                    .fill => {
                        shapes = try self.shapesOf(self.ctx, &.{ec.elem});
                        stored = &.{true};
                    },
                    .copy => {
                        elem_copy = ec.elem;
                        shapes = &.{.view};
                        stored = &.{true};
                    },
                    .swap, .read, .write => all_read = true,
                } else all_read = true;
                // `get`, `pop`, and `remove` hand back an element of a Vec:
                // a value it held, which carries the loans the Vec's
                // elements carry, and no loan on the Vec (Core s7: a view
                // reached through another carries that view's loans).
                const elem_method = self.isVec(recv_ty) and for ([_][]const u8{ "get", "pop", "remove" }) |m| {
                    if (std.mem.eql(u8, m, ir.Member.name(callee).getText(self.src))) break true;
                } else false;
                switch (recv_mode) {
                    .none => return abstain("a function of a type called on a value"),
                    .write => {
                        // A write receiver with no `!` is a write view
                        // the receiver's value is (`wrap(!h).keep(x)`, a
                        // branch of write lends): lent on through it.
                        const p = if (obj.isKind(.write)) try self.writePlace(ir.Write.operand(obj)) else blk: {
                            const t = try self.eval(obj, .read, null) orelse return abstain("a write receiver without `!`");
                            if (self.f.vars.items[t].kind != .write_view) return abstain("a write receiver without `!`");
                            break :blk Place{ .root = t, .path = &.{}, .ty = self.f.vars.items[t].ty };
                        };
                        if (p.handle or self.isHandle(p.ty)) return abstain("a write receiver through a handle");
                        // A write receiver is lent when the call runs; its
                        // arguments may still read it (SPEC §7).
                        if (p.via == .read) return abstain("a write receiver through a read view");
                        const deref = p.via == .write or (!p.slice and self.isWriteRef(p.ty));
                        const reserved = try self.lentLoan(p, .reserved, deref, 0, pos);
                        const r = try self.viewTemp(try self.typeOf(obj), .write_view, pos);
                        try self.emit(.{ .pos = pos, .what = .lend, .reads = try self.one(p.root), .def = r, .loan = reserved, .access = .{ .root = p.root, .path = p.path, .deref = deref, .kind = .reserve } });
                        try uses.append(self.a, r);
                        try reads.append(self.a, p.root);
                        try recv_vars.append(self.a, p.root);
                        if (try self.storesViews(p)) try gains.append(self.a, p.root);
                        // Through a write view, the call may store into
                        // what that view sees (`!w[0].push(?t)`).
                        if (deref) recv_view = r;
                        if (elem_method) elem_from = p.root;
                        activation = try self.lentLoan(p, .write, deref, 0, pos);
                        access = .{ .root = p.root, .path = p.path, .deref = deref, .kind = .write, .except = reserved };
                    },
                    .read => {
                        // A method lends its receiver for the whole call
                        // (SPEC §7), plain data included.
                        var r: ?VarId = null;
                        if (try self.place(obj)) |p| {
                            r = try self.lend(p, .read, obj, p.ty);
                            if (elem_method) elem_from = p.root;
                        } else {
                            r = try self.eval(obj, .read, null);
                            // A value made there is a temporary of the
                            // statement, which the method sees where it is
                            // (Core §3): what it returns may view it.
                            if (r) |rv| if (self.f.vars.items[rv].hidden and !elem_method and (recv_obj.isKind(.call) or recv_obj.isKind(.clone) or recv_obj.isKind(.share))) {
                                const vv = self.f.vars.items[rv];
                                r = try self.lend(.{ .root = rv, .path = &.{}, .ty = vv.ty }, .read, recv_obj, vv.ty);
                            };
                            if (elem_method) elem_from = r;
                        }
                        if (r) |rv| {
                            try reads.append(self.a, rv);
                            try recv_vars.append(self.a, rv);
                        }
                    },
                    .value => {
                        if (self.isHandle(try self.typeOf(obj))) return abstain("a by-value receiver through a handle");
                        const r = try self.eval(obj, .take, null);
                        if (r) |rv| {
                            try moves.append(self.a, rv);
                            try recv_vars.append(self.a, rv);
                        }
                    },
                }
            }
        } else if (callee.isKind(.enum_lit)) {
            is_ctor = true;
        } else return abstain("an unusual callee");

        // Which vars the result, and what the call stores, carry (Core s7).
        var carried: std.ArrayList(VarId) = .empty;
        var kept: std.ArrayList(VarId) = .empty;
        var uncarried: std.ArrayList(VarId) = .empty;
        var result_loan = true;
        var store_loan = true;
        if (sig) |sg| if (sg.receiver and sg.f.params.len > 0) {
            const to_result = if (sg.from) |m| m & 1 != 0 else try reach.leads(sg.ctx, sg.f.params[0], sg.f.returns);
            const to_store = try reach.stores(sg.ctx, sg.f.params, 0);
            for (recv_vars.items) |rv| {
                try (if (to_result) &carried else &uncarried).append(self.a, rv);
                if (to_store) try kept.append(self.a, rv);
            }
            result_loan = to_result;
            store_loan = to_store;
        };
        // Where each argument's vars start in `reads` and `moves`.
        var spans: std.ArrayList(struct { reads: usize, moves: usize, to_result: bool, to_store: bool }) = .empty;
        // The arguments, left to right.
        const slots = self.ctx.callSlotsOf(e);
        for (args, 0..) |arg, i| {
            const val = if (arg.isKind(.kwarg)) ir.Kwarg.value(arg) else arg;
            var shape: Shape = .take;
            var keeps = false;
            // Whether the result, and a store, may carry this argument's
            // loans: by its parameter's type, as declared.
            var to_result = true;
            var to_store = true;
            if (!all_read and !is_ctor) {
                const pi = if (slots) |sl| slotIndex(sl, i) orelse return abstain("an argument without a parameter") else i;
                if (pi >= shapes.len) return abstain("an argument without a parameter");
                shape = shapes[pi];
                keeps = pi < stored.len and stored[pi];
                if (sig) |sg| {
                    const fi = pi + @intFromBool(sg.receiver);
                    if (fi < sg.f.params.len) {
                        to_result = if (sg.from) |m| fi < 64 and m & (@as(u64, 1) << @intCast(fi)) != 0 else try reach.leads(sg.ctx, sg.f.params[fi], sg.f.returns);
                        to_store = try reach.stores(sg.ctx, sg.f.params, fi);
                    }
                }
            }
            try spans.append(self.a, .{ .reads = reads.items.len, .moves = moves.items.len, .to_result = to_result, .to_store = to_store });
            if (group != 0 and val.isKind(.write)) {
                // `swap` and `replace` lend their places for the call.
                const p = try self.place(ir.Write.operand(val)) orelse return abstain("an unusual `swap`");
                const deref = p.via == .write or (!p.slice and self.isWriteRef(p.ty));
                const loan = try self.lentLoan(p, .write, deref, group, pos);
                const t = try self.viewTemp(try self.typeOf(val), .write_view, pos);
                try self.emit(.{ .pos = self.posOf(val), .what = .lend, .reads = try self.one(p.root), .def = t, .loan = loan, .access = .{ .root = p.root, .path = p.path, .deref = deref, .kind = .write, .group = group } });
                try uses.append(self.a, t);
                try reads.append(self.a, p.root);
                if (try self.storesViews(p)) try exchanged.append(self.a, p.root);
                continue;
            }
            if (val.isKind(.write)) {
                const p = try self.writePlace(ir.Write.operand(val));
                try reads.append(self.a, try self.lend(p, .write, val, try self.typeOf(val)));
                // The call may store a view in what it was lent to write (s6).
                if (try self.storesViews(p)) try gains.append(self.a, p.root);
                continue;
            }
            const arg_how: How = if (all_read) .read else if (shape == .view) .view else .take;
            // Where a write view goes, a bare one would be copied (SPEC §7).
            const wants_view = is_ctor and arg.isKind(.kwarg) and self.fieldIsWriteView(e, ir.Kwarg.name(arg).getText(self.src));
            var v = try self.eval(val, arg_how, if (wants_view) self.ctx.typeOf(val) else null) orelse continue;
            if ((arg_how == .take and (!is_ctor or cell_store)) or all_read) v = try self.readThrough(v, self.posOf(val));
            if (elem_copy) |et| {
                // The elements read through the slice carry their own
                // loans, not the slice's loan on what holds them (Core s7).
                const t = try self.temp(et, self.posOf(val));
                try self.emit(.{ .pos = self.posOf(val), .what = .copy, .reads = try self.one(v), .def = t, .carry = true });
                try uses.append(self.a, v);
                try moves.append(self.a, t);
                continue;
            }
            // A value made where a view is expected is a temporary of the
            // statement, lent to the call (Core s1, §3): the result's view
            // of it ends with the statement.
            const made_plain = self.f.vars.items[v].kind == .plain and !self.isPlaceSyntax(val) and val.kind() != null;
            if (arg_how == .view and self.f.vars.items[v].hidden and (self.f.vars.items[v].kind == .owning or made_plain)) {
                const vv = self.f.vars.items[v];
                v = try self.lend(.{ .root = v, .path = &.{}, .ty = vv.ty }, .read, val, vv.ty);
            }
            // A callable whose result holds no view hands the call none
            // of its captures' views: the call only calls it (Core s7).
            if (try self.callsOnly(v, try self.typeOf(e))) {
                try uses.append(self.a, v);
                continue;
            }
            if (group != 0 and arg_how == .take) try stored_value.append(self.a, v);
            if (arg_how == .take or keeps) try moves.append(self.a, v) else try reads.append(self.a, v);
        }

        for (spans.items, 0..) |sp, si| {
            const r_end = if (si + 1 < spans.items.len) spans.items[si + 1].reads else reads.items.len;
            const m_end = if (si + 1 < spans.items.len) spans.items[si + 1].moves else moves.items.len;
            for ([_][]const VarId{ reads.items[sp.reads..r_end], moves.items[sp.moves..m_end] }) |g| for (g) |v| {
                try (if (sp.to_result) &carried else &uncarried).append(self.a, v);
                if (sp.to_store) try kept.append(self.a, v);
            };
        }
        // A var the result or a store carries for one reason carries it.
        var no_result: std.ArrayList(VarId) = .empty;
        var no_store: std.ArrayList(VarId) = .empty;
        if (sig != null) for ([_][]const VarId{ reads.items, moves.items }) |g| for (g) |v| {
            const callee_value = std.mem.findScalar(VarId, uncarried.items, v) == null and std.mem.findScalar(VarId, carried.items, v) == null;
            if (callee_value) continue;
            if (std.mem.findScalar(VarId, carried.items, v) == null and std.mem.findScalar(VarId, no_result.items, v) == null) try no_result.append(self.a, v);
            if (std.mem.findScalar(VarId, kept.items, v) == null and std.mem.findScalar(VarId, no_store.items, v) == null) try no_store.append(self.a, v);
        };
        const rt = try self.typeOf(e);
        const rinfo = self.ctx.types.get(rt);
        const result: ?VarId = switch (rinfo) {
            .void, .noreturn => null,
            else => try self.temp(rt, pos),
        };
        if (stored_value.items.len > 0) for (exchanged.items) |root| {
            try self.emit(.{ .pos = pos, .what = .assign, .reads = stored_value.items, .weak = root });
        };
        // A write view handed on lets the call store into what it sees.
        var through: std.ArrayList(VarId) = .empty;
        if (recv_view) |r| try through.append(self.a, r);
        for ([_][]const VarId{ reads.items, moves.items }) |g| for (g) |v| {
            if (self.f.vars.items[v].kind == .write_view) try through.append(self.a, v);
        };
        try self.emit(.{
            .pos = pos,
            .what = .call,
            .reads = reads.items,
            .moves = moves.items,
            .uses = uses.items,
            .def = if (elem_from == null) result else null,
            .loan = activation,
            .access = access,
            .gains = gains.items,
            .through = through.items,
            .no_loans = cell_store,
            .no_result = no_result.items,
            .result_loan = result_loan or sig == null,
            .no_store = no_store.items,
            .store_loan = store_loan or sig == null,
        });
        if (elem_from) |from| if (result) |r| {
            try self.emit(.{ .pos = pos, .what = .copy, .reads = try self.one(from), .def = r });
        };
        // `swap` exchanges what its places hold (Core s6): each place's
        // holder then holds the views the other held, not the call's own
        // lends of them. `replace` stores its value in its place, above.
        for (exchanged.items) |root| {
            const others = try self.a.alloc(VarId, exchanged.items.len);
            var n: usize = 0;
            for (exchanged.items) |o| if (o != root) {
                others[n] = o;
                n += 1;
            };
            if (n > 0) try self.emit(.{ .pos = pos, .what = .assign, .reads = others[0..n], .weak = root });
        }
        return result;
    }

    /// Whether `ty` is a Vec, or a view of one.
    fn isVec(self: *Lowerer, ty: TypeId) bool {
        return switch (self.ctx.types.get(sema.unwrapViews(self.ctx, ty))) {
            .parameterized_nominal => |pn| pn.sym == self.ctx.vec_sym_id,
            else => false,
        };
    }

    /// A built-in generic's method parameters at the receiver's type
    /// arguments: `push(x: T)` of a `Vec[?Int]` takes a `?Int`, which it
    /// stores (Core §5).
    fn instParams(self: *Lowerer, recv_ty: TypeId, params: []const TypeId) Error![]const TypeId {
        const pn = switch (self.ctx.types.get(sema.unwrapViews(self.ctx, recv_ty))) {
            .parameterized_nominal => |pn| pn,
            else => return params,
        };
        if (!sema.isBuiltinGeneric(self.ctx, pn.sym)) return params;
        const tps = self.ctx.symbols.items[pn.sym].type_params orelse return params;
        const out = try self.a.dupe(TypeId, params);
        for (out) |*p| switch (self.ctx.types.get(p.*)) {
            .type_var => |sym| for (tps, 0..) |tp, i| {
                if (tp == sym and i < pn.args.len) p.* = pn.args[i];
            },
            else => {},
        };
        return out;
    }

    /// Whether a call lent `p` to write may store a view there: what
    /// the lend reaches can hold one.
    fn storesViews(self: *Lowerer, p: Place) Error!bool {
        var ty = p.ty;
        if (self.ctx.types.get(ty) == .write_view) ty = try self.innerOf(ty);
        // A slice's place is its elements; a slice of a Text, its bytes.
        switch (self.ctx.types.get(ty)) {
            .slice => |sl| ty = sl.elem,
            .string => if (p.slice) return false,
            else => {},
        }
        return (try self.kinds.of(ty)).holds_views;
    }

    /// A `?T` or `!T` made where a value is wanted is read there: the
    /// value is copied out and the loan taken to reach it ends (SPEC §7
    /// "Second-class views").
    /// `readThrough` of plain data only: a view of a value whose copy
    /// depends on the instance stays a view.
    fn readPlainThrough(self: *Lowerer, v: VarId, pos: u32) Error!VarId {
        const vv = self.f.vars.items[v];
        if (!vv.hidden) return v;
        const inner_ty = switch (self.ctx.types.get(vv.ty)) {
            .read_view, .write_view => |t| t,
            else => return v,
        };
        if (!(try self.kinds.of(inner_ty)).kind.copies()) return v;
        return self.readThrough(v, pos);
    }

    fn readThrough(self: *Lowerer, v: VarId, pos: u32) Error!VarId {
        const vv = self.f.vars.items[v];
        if (!vv.hidden) return v;
        const inner_ty = switch (self.ctx.types.get(vv.ty)) {
            .read_view, .write_view => |t| t,
            else => return v,
        };
        // A generic body reads a `T` by value where its instances do
        // (SPEC "Generic bodies": the copy is the instance's question).
        const inner = try self.kinds.of(inner_ty);
        if (!inner.kind.copies() and !inner.generic_copy) return v;
        if (!inner.kind.copies()) self.copies_t = true;
        const t = try self.temp(inner_ty, pos);
        try self.emit(.{ .pos = pos, .what = .copy, .reads = try self.one(v), .def = t });
        return t;
    }

    fn fieldIsWriteView(self: *Lowerer, ctor: Sexp, name: []const u8) bool {
        const ty = self.ctx.typeOf(ctor) orelse return false;
        const decl = sema.nominalDecl(self.ctx, ty) orelse return false;
        for (decl.symbol().fields orelse &.{}) |*f| {
            for (sema.dataFields(f)) |d| {
                if (std.mem.eql(u8, d.name, name) and decl.ctx.types.get(d.ty) == .write_view) return true;
            }
        }
        return false;
    }

    fn slotIndex(slots: []const sema.ArgSlot, arg: usize) ?usize {
        for (slots, 0..) |s, pi| switch (s) {
            .arg => |ai| if (ai == arg) return pi,
            .default => {},
        };
        return null;
    }

    /// Fill `f.keep` once the body is lowered (`core.Func.keeps`): a
    /// var whose type holds no write view or type parameter keeps a
    /// loan only on a place whose type may own what the var's views
    /// point into (Core s7).
    fn finish(self: *Lowerer) Error!void {
        const nv = self.f.vars.items.len;
        const nl = self.f.loans.items.len;
        if (nl == 0) return;
        const keep = try self.a.alloc(bool, nv * nl);
        @memset(keep, true);
        var reach: kinds.Reach = .{ .a = self.a };
        var memo: std.AutoHashMapUnmanaged(struct { TypeId, TypeId }, bool) = .empty;
        for (self.f.vars.items, 0..) |v, vi| {
            if (!v.holds_views or v.holds_writes or v.alias) continue;
            // A binding that sees an owner's payload is a view whatever its
            // type: it carries what it sees.
            const kind = try self.kinds.of(v.ty);
            if (!kind.holds_views or kind.holds_writes) continue;
            const info = self.ctx.typeInfo(v.ty);
            if (info.holds_type_var or info.has_type_var or info.poison) continue;
            for (self.f.loans.items, 0..) |l, li| {
                // A loan through a write view is on memory the view may
                // write: the var carries it as any view of it does.
                if (l.external or l.deref or l.ty == sema.type_invalid) continue;
                const gop = try memo.getOrPut(self.a, .{ l.ty, v.ty });
                if (!gop.found_existing) gop.value_ptr.* = try reach.owns(self.ctx, l.ty, v.ty);
                keep[vi * nl + li] = gop.value_ptr.*;
            }
        }
        self.f.keep = keep;
        self.f.keep_loans = nl;
    }

    fn shapesOf(self: *Lowerer, ctx: *const sema.SemContext, params: []const TypeId) Error![]const Shape {
        const out = try self.a.alloc(Shape, params.len);
        for (params, out) |p, *s| s.* = shapeOf(ctx, p);
        return out;
    }

    /// A value of a user generic type at type arguments of plain data;
    /// any other type passes.
    fn plainInstance(self: *Lowerer, ty: TypeId) Error!void {
        switch (self.ctx.types.get(ty)) {
            .read_view, .write_view, .shared, .weak, .optional, .fallible => |inner| return self.plainInstance(inner),
            .parameterized_nominal => |pn| {
                if (sema.isBuiltinGeneric(self.ctx, pn.sym)) {
                    for (pn.args) |a| try self.plainInstance(a);
                    return;
                }
                var owners = false;
                for (pn.args) |a| {
                    if (try self.ownerArg(a)) owners = true else try self.plainInstanceArg(a);
                }
                if (owners and !try self.typeCopiesNoT(pn.sym)) return abstain("a generic type at an owner whose methods copy a `T`");
            },
            else => {},
        }
    }

    /// A type argument that owns and holds no view: a generic body's
    /// instance at it is correct when the body never copies a `T`.
    fn ownerArg(self: *Lowerer, t: TypeId) Error!bool {
        if (t == sema.type_invalid or self.ctx.types.get(t) == .ct_value) return false;
        if (self.kinds.generic and self.ctx.typeInfo(t).has_type_var) return false;
        const info = try self.kinds.of(t);
        return info.kind == .owning and !info.holds_views and info.unsupported == null and !self.holdsCallable(t);
    }

    /// Whether no method or `drop` body of a user generic type copies a
    /// value of a type parameter (`copiesNoT`).
    fn typeCopiesNoT(self: *Lowerer, sym_id: SymbolId) Error!bool {
        var sym = self.ctx.symbols.items[sym_id];
        var m = self.module orelse return false;
        if (sema.isProxy(sym)) {
            m = moduleById(sym.from.module_id) orelse return false;
            sym = m.sema.symbols.items[sym.from.sym];
        }
        if (m.ir == .nil) return false;
        for (ir.Module.decls(m.ir)) |d0| {
            const d = if (d0.isKind(.@"pub")) ir.Pub.decl(d0) else d0;
            if (!d.isKind(.generic_struct) and !d.isKind(.generic_enum)) continue;
            const n = ir.get(d, .name);
            if (n != .src or n.src.pos != sym.decl_pos) continue;
            for (ir.rest(d, .members)) |mem0| {
                const mem = if (mem0.isKind(.@"pub")) ir.Pub.decl(mem0) else mem0;
                if (!mem.isKind(.fun) and !mem.isKind(.sub) and !mem.isKind(.drop_decl)) continue;
                if (ir.get(mem, .body) == .nil) continue;
                if (!try copiesNoT(self.a, .{ .module = m, .decl = mem, .owner = d })) return false;
            }
            return true;
        }
        return false;
    }

    /// A type argument of plain data. An instance at a String is checked
    /// against whether the body stores a `T` where no loan may go (Core
    /// s9), which the oracle does not answer either.
    fn plainInstanceArg(self: *Lowerer, t: TypeId) Error!void {
        if (t == sema.type_invalid) return;
        // A generic body's own parameters: each instance of it is checked
        // where it is made.
        if (self.kinds.generic and self.ctx.typeInfo(t).has_type_var) return;
        if (self.ctx.types.get(t) == .ct_value) return;
        if ((try self.kinds.of(t)).kind == .plain) return;
        return abstain("a generic instance at an owner or a view");
    }

    /// A call of a generic function, checked by its signature at its
    /// type arguments (SPEC "Generic bodies"): each of plain data; or an
    /// owner that holds no view, where the body, and every generic body
    /// it calls at its own type parameters, never copies a value of a
    /// type parameter (so `sort.sort_by(!v, less)` of a `Vec[Text]`). In
    /// a generic body, a call at its own type parameters is that body's
    /// to answer for its instances (`t_calls`).
    fn genericCall(self: *Lowerer, e: Sexp, type_args: []const TypeId) Error!void {
        var owners = false;
        var own_params = false;
        for (type_args) |t| {
            if (t == sema.type_invalid or self.ctx.types.get(t) == .ct_value) continue;
            if (self.kinds.generic and self.ctx.typeInfo(t).has_type_var) {
                own_params = true;
                continue;
            }
            const info = try self.kinds.of(t);
            if (info.kind == .plain) continue;
            if (info.kind != .owning or info.holds_views or info.unsupported != null or self.holdsCallable(t)) return abstain("a generic instance at a view");
            owners = true;
        }
        if (!owners and !own_params) return;
        const callee = self.calleeDecl(e) orelse return abstain("a generic instance at an owner of an unusual callee");
        if (own_params) try self.t_calls.append(self.a, callee);
        if (owners and !try copiesNoT(self.a, callee)) return abstain("a generic instance at an owner whose body copies a `T`");
    }

    /// The declaration a call's callee names: a function of this module,
    /// or of a module it uses.
    fn calleeDecl(self: *Lowerer, e: Sexp) ?Callee {
        const m = self.module orelse return null;
        const callee = self.ctx.calleeOf(e);
        if (callee == .src) {
            const sym_id = self.ctx.symbolOf(callee) orelse return null;
            const sym = self.ctx.symbols.items[sym_id];
            if (sym.kind != .function) return null;
            if (sema.isProxy(sym)) {
                const fm = moduleById(sym.from.module_id) orelse return null;
                const fsym = fm.sema.symbols.items[sym.from.sym];
                return findDecl(fm, fsym.name, fsym.decl_pos);
            }
            return findDecl(m, sym.name, sym.decl_pos);
        }
        if (!callee.isKind(.member)) return null;
        const obj = ir.Member.object(callee);
        if (obj != .src) return null;
        const obj_sym = self.ctx.symbolOf(obj) orelse return null;
        const mid = self.ctx.module_refs.get(obj_sym) orelse return null;
        const fm = moduleById(mid) orelse return null;
        return findDecl(fm, ir.Member.name(callee).getText(self.src), null);
    }

    /// The `from` clause of `module.f` named by callee `callee`.
    fn staticFrom(self: *Lowerer, callee: Sexp) ?u64 {
        const obj = ir.Member.object(callee);
        if (obj != .src) return null;
        const obj_sym = self.ctx.symbolOf(obj) orelse return null;
        const mid = self.ctx.module_refs.get(obj_sym) orelse return null;
        const fm = moduleById(mid) orelse return null;
        const name = ir.Member.name(callee).getText(self.src);
        const id = fm.sema.lookupInScopeOnly(sema.module_scope, name) orelse return null;
        return declaredFrom(fm.sema, fm.sema.symbols.items[id].decl_pos);
    }

    /// Whether a value of `ty` is a Cell or Signal, or a view or handle
    /// of one.
    fn isCell(self: *Lowerer, ty: TypeId) bool {
        return switch (self.ctx.types.get(ty)) {
            .read_view, .write_view, .shared => |inner| self.isCell(inner),
            .parameterized_nominal => |pn| pn.sym == self.ctx.cell_sym_id or pn.sym == self.ctx.signal_sym_id,
            else => false,
        };
    }

    const MethodParams = struct {
        ctx: *const sema.SemContext,
        params: []const TypeId,
        /// The method's signature, its receiver first.
        full: sema.FunctionType = undefined,
        /// A built-in generic's method, which keeps what it is handed.
        builtin: bool = true,
        /// Where its name is declared.
        decl_pos: u32 = 0,
    };

    /// A callee's declared signature (`receiver`: a method's, called on
    /// a value, whose receiver is its first parameter).
    const Sig = struct {
        ctx: *const sema.SemContext,
        f: sema.FunctionType,
        receiver: bool = false,
        /// What its `from` clause names (Core s7), when it writes one: a
        /// bit per parameter, a method's receiver first.
        from: ?u64 = null,
    };

    /// How a method takes its receiver, and its other parameters' types.
    fn method(self: *Lowerer, callee: Sexp) Error!struct { sema.MethodReceiver, ?MethodParams } {
        const obj = ir.Member.object(callee);
        const mname = ir.Member.name(callee).getText(self.src);
        if (self.ctx.elemCallOf(callee)) |ec| {
            return .{ if (ec.op == .read) .read else .write, null };
        }
        if (self.ctx.textCallOf(callee)) |tc| {
            _ = tc;
            return .{ .write, null };
        }
        const inner_obj = if (obj.isKind(.read) or obj.isKind(.write) or obj.isKind(.move)) ir.get(obj, .operand) else obj;
        var recv_ty = try self.typeOf(inner_obj);
        try self.plainInstance(recv_ty);
        // A method of what a handle holds reads it through the handle
        // (Core s8).
        switch (self.ctx.types.get(sema.unwrapViews(self.ctx, recv_ty))) {
            .shared => |inner| recv_ty = inner,
            // `w.upgrade()` reads the weak handle; its result is a new
            // count carrying the handle's loans (Core s8, s9).
            .weak => if (std.mem.eql(u8, mname, "upgrade")) return .{ .read, null } else return abstain("a method of a weak handle"),
            else => {},
        }
        const decl = sema.nominalDecl(self.ctx, recv_ty) orelse {
            // A built-in method of an array, slice, or String: it writes
            // its receiver only where `!` says so.
            return switch (self.ctx.types.get(sema.unwrapViews(self.ctx, recv_ty))) {
                .array, .slice, .string => .{ if (obj.isKind(.write)) .write else .read, null },
                else => abstain("a method of an unusual type"),
            };
        };
        if (try self.methodOf(decl, mname)) |found_method| return found_method;
        // A method of what a box holds, reached through the box.
        if (sema.boxedNominal(self.ctx, recv_ty)) |boxed| {
            if (sema.nominalDecl(self.ctx, boxed)) |inner_decl| {
                if (try self.methodOf(inner_decl, mname)) |found_method| return found_method;
            }
        }
        // A `Cell[Vec[T]]` answers its Vec's members through any path,
        // without `!` (SPEC "Cell").
        switch (self.ctx.types.get(sema.unwrapViews(self.ctx, recv_ty))) {
            .parameterized_nominal => |pn| if (pn.sym == self.ctx.cell_sym_id and pn.args.len == 1) {
                if (sema.nominalDecl(self.ctx, pn.args[0])) |held| if (held.sym == self.ctx.vec_sym_id) {
                    if (try self.methodOf(held, mname)) |found_method| return .{ .read, found_method[1] };
                };
            },
            else => {},
        }
        return abstain("a method reached through a handle");
    }

    fn methodOf(self: *Lowerer, decl: sema.NominalDecl, mname: []const u8) Error!?struct { sema.MethodReceiver, ?MethodParams } {
        _ = self;
        for (decl.symbol().fields orelse &.{}) |f| {
            if (!f.is_method or f.is_drop_method or !std.mem.eql(u8, f.name, mname)) continue;
            const ft = decl.ctx.types.get(f.ty);
            if (ft != .function) return abstain("an unusual method");
            const params = ft.function.params;
            return switch (f.receiver) {
                .none => abstain("a function of a type called on a value"),
                .read, .write, .value => .{ f.receiver, .{ .ctx = decl.ctx, .params = if (params.len > 0) params[1..] else params, .full = ft.function, .builtin = decl.symbol().decl_pos == sema.builtin_decl_pos, .decl_pos = f.decl_pos } },
            };
        }
        return null;
    }
};
