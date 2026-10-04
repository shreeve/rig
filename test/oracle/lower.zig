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

    const Via = enum { own, read, write };
};

/// A scope (a block's bindings) or a statement's temporaries; leaving
/// either drops its vars, last first.
const Region = struct {
    vars: std.ArrayList(VarId) = .empty,
};

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

/// `planned` applies the Core's planned rule the oracle models: a type
/// holding a `Cell` is unique (Core §1). A bare place a `for` walks or
/// an `if … as` or `while … as` binds is read where it stands, as `?p`
/// (Core s1, built).
pub fn lowerUnit(a: std.mem.Allocator, m: *const lib.modules.Module, unit: Unit, planned: bool) !core.Func {
    var l: Lowerer = .{
        .a = a,
        .ctx = m.sema,
        .parser = m.parser,
        .src = m.source,
        .kinds = kinds.Kinds.init(a, m.sema, planned),
        .planned = true,
    };
    l.run(unit) catch |err| switch (err) {
        error.Found => {},
        else => |e| return e,
    };
    return l.f;
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
    /// While lowering a value block's last value, through the branches
    /// of `if`s in tail position: the block's region. A bare binding of
    /// that block or a deeper one leaves with the value.
    tail_floor: ?usize = null,
    /// While a header finds the place its subject names in a value it
    /// made: that value's node, and the var holding it.
    made_root: ?struct { start: u32, end: u32, v: VarId } = null,

    // ---- the function ---------------------------------------------------

    fn run(self: *Lowerer, unit: Unit) Error!void {
        if (unit.generic_owner) return abstain("a generic body");
        const decl = unit.decl;
        const kind = decl.kind().?;
        if ((kind == .fun or kind == .sub) and ir.get(decl, .tparams) != .nil) return abstain("a generic body");
        const entry = try self.newBlock();
        self.cur = entry;
        try self.regions.append(self.a, .{});
        if (kind != .@"test") {
            for (ir.get(decl, .params).items()) |p| try self.param(p);
        }
        const body = ir.get(decl, .body);
        const returns = kind == .fun;
        const stmts = ir.Block.stmts(body);
        try self.regions.append(self.a, .{});
        for (stmts, 0..) |s, i| {
            if (returns and i + 1 == stmts.len and isValue(s)) {
                try self.reachable();
                try self.retValue(s);
            } else try self.stmt(s);
        }
        if (self.cur != null) try self.ret(null, self.posOf(body));
    }

    fn param(self: *Lowerer, p: Sexp) Error!void {
        const name = switch (p.kind() orelse return abstain("an unusual parameter")) {
            .@":", .default => ir.get(p, .name),
            .read, .write, .move => ir.get(p, .operand),
            else => return abstain("an unusual parameter"),
        };
        const sym_id = self.ctx.symbolOf(name) orelse return abstain("a parameter without a symbol");
        const sym = self.ctx.symbols.items[sym_id];
        const v = try self.newVar(sym.name, sym.ty, false, name.src.pos);
        self.f.vars.items[v].param = true;
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

    /// Drop a region's vars, last first, at `pos`.
    fn killRegion(self: *Lowerer, r: Region, pos: u32) Error!void {
        var i = r.vars.items.len;
        while (i > 0) {
            i -= 1;
            try self.emit(.{ .pos = pos, .what = .kill, .kill = r.vars.items[i], .scope_end = true });
        }
    }

    fn popRegion(self: *Lowerer, pos: u32) Error!void {
        const r = self.regions.pop().?;
        if (self.cur != null) try self.killRegion(r, pos);
    }

    /// Leave every region above `depth`, innermost first (a jump).
    fn unwind(self: *Lowerer, depth: usize, pos: u32) Error!void {
        var i = self.regions.items.len;
        while (i > depth) {
            i -= 1;
            try self.killRegion(self.regions.items[i], pos);
        }
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
                if (v == .nil) try self.ret(null, self.posOf(s)) else try self.retValue(v);
            },
            .@"break", .@"continue" => try self.jump(s),
            .labeled => {
                const inner = ir.Labeled.stmt(s);
                if (!inner.isKind(.@"while") and !inner.isKind(.@"for") and !inner.isKind(.match)) return abstain("a labeled `raw` block");
                self.label = ir.Labeled.label(s).getText(self.src);
                try self.stmtIn(inner);
            },
            .@"defer", .@"errdefer" => return abstain("`defer`"),
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
                const v = try self.eval(rhs, .take, sym.ty);
                const x = try self.bind(target, 1);
                try self.store(x, v, pos);
                return;
            }
            const x = self.vars.get(sym_id).?;
            const xv = self.f.vars.items[x];
            if (xv.kind != .write_view) try self.reassignable(sym, pos);
            if (xv.kind == .write_view) {
                const vt = try self.typeOf(rhs);
                if (self.ctx.types.get(vt) == .borrow_write) return abstain("assigning a write view to a write view (Core §6, planned)");
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
        // the store (Core §6).
        const v = try self.eval(rhs, .take, try self.typeOf(target));
        const p = try self.place(target) orelse return abstain("an assignment to something not a place");
        if (p.via == .read) return abstain("a write through a read view");
        if (self.f.vars.items[p.root].kind != .write_view and self.ctx.types.get(p.ty) == .borrow_write) return abstain("a write view stored in a place");
        // A store through a write view lands in what the view sees (s6).
        const through: []const VarId = if (p.via == .write) try self.one(p.root) else &.{};
        try self.emit(.{ .pos = pos, .what = .assign, .moves = try self.list(v), .uses = try self.one(p.root), .weak = p.root, .through = through, .access = .{ .root = p.root, .path = p.path, .deref = p.via == .write, .kind = .write } });
    }

    fn compound(self: *Lowerer, target: Sexp, rhs: Sexp, pos: u32) Error!void {
        var v = try self.eval(rhs, .read, null);
        if (v) |rv| v = try self.readThrough(rv, pos);
        const p = try self.place(target) orelse return abstain("a compound assignment to something not a place");
        if (target == .src and self.f.vars.items[p.root].kind != .write_view) {
            try self.reassignable(self.ctx.symbols.items[self.ctx.symbolOf(target).?], pos);
        }
        var deref = p.via == .write;
        if (p.via == .own and p.path.len == 0 and self.f.vars.items[p.root].kind == .write_view) deref = true;
        try self.emit(.{ .pos = pos, .what = .assign, .reads = try self.list(v), .uses = try self.one(p.root), .access = .{ .root = p.root, .path = p.path, .deref = deref, .kind = .write } });
    }

    /// Core §6: a local binding may be reassigned; parameters and fixed
    /// bindings may not.
    fn reassignable(self: *Lowerer, sym: sema.Symbol, pos: u32) Error!void {
        if (sym.kind == .param) return self.found(.B1, pos, "a parameter `{s}` is not reassigned", .{sym.name});
        if (sym.flags.fixed) return self.found(.B1, pos, "a fixed binding `{s}` is not reassigned", .{sym.name});
    }

    /// Bind a fresh var to a lowered value.
    fn store(self: *Lowerer, x: VarId, v: ?VarId, pos: u32) Error!void {
        try self.emit(.{ .pos = pos, .what = .move, .moves = try self.list(v), .def = x });
    }

    /// `-x` drops `x` now (Core s2).
    fn dropStmt(self: *Lowerer, s: Sexp) Error!void {
        const name = ir.Drop.name(s);
        const x = self.varOf(name) orelse return abstain("a drop of something not a local");
        const xv = self.f.vars.items[x];
        // What a parameter views, the caller owns (SPEC §7 "Drop").
        if (xv.param and self.ctx.types.get(xv.ty) != .string and xv.kind != .owning and xv.kind != .plain) {
            return self.found(.C5, self.posOf(s), "a parameter's view is the caller's; it is not dropped here", .{});
        }
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
        try self.pushRegion();
        if (held) |h| try self.bindHeld(ir.As.name(cond), h, self.optionalInner(h.ty));
        if (j) |jv| try self.armValue(ir.If.then(e), how, jv) else try self.blockStmts(ir.If.then(e));
        try self.popRegion(self.posOf(e));
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
        const bare: How = if (how == .take and self.planned and is_place) .read else how;
        try self.pushRegion();
        var v = try self.subject(value, bare, "the `as` value");
        // A read view of a made value of plain data is read as its value,
        // which carries no loan (Core §4).
        if (value.isKind(.read) and !self.isPlaceSyntax(ir.Read.operand(value))) v = try self.readThrough(v, pos);
        const h = try self.hold(v, "the `as` value", pos);
        try self.popRegion(pos);
        var carry_from: ?VarId = null;
        // A bare place read where it stands is `?p`.
        const lent_place: ?Sexp = if (value.isKind(.read)) ir.Read.operand(value) else if (is_place and bare == .read) value else null;
        if (lent_place) |lp| if (self.rootVar(lp)) |r| {
            const rv = self.f.vars.items[r];
            if (rv.kind != .write_view and !rv.alias) carry_from = r;
        };
        const lent_temp = (value.isKind(.read) or value.isKind(.write)) and self.madeSubject(ir.get(value, .operand));
        return .{ .v = h, .pos = pos, .ty = ty, .carry_from = carry_from, .lent_temp = lent_temp };
    }

    /// What a header's subject hands over (Core §3), lowered inside the
    /// header's region; `bare` says what a bare place does.
    /// - A place is read, lent, moved, or taken as written.
    /// - A value made in the header (a call's result, a constructor, a
    ///   literal) is taken. So is the made value the subject is a part
    ///   of (`mk().e`, `[a, b][0]`): a hidden var of the statement holds
    ///   it through the body, and the subject is its part.
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
        if (self.madeSubject(named)) {
            if (lent and isBranching(named)) return abstain("a lend of a branching value (Core §3, planned)");
            if (lent and value.isKind(.write)) return abstain("a write lend of a made value");
            const part = named.kind().? == .member or named.kind().? == .index;
            if (part or lent) {
                const hp = try self.heldPart(named, name);
                if (lent) return try self.lend(hp.place, .read, value, try self.typeOf(value));
                // The payloads a header binds of a value it holds are the
                // body's own (or views of the holder: `bindHeld`).
                return hp.held;
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

    /// Whether a header subject names a value the header makes, or a
    /// part of one: neither a place, nor a constant, nor a sigil.
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
            .borrow_read, .borrow_write => if (stored == null or stored.? != xv.ty) {
                const mode: core.Mode = if (self.ctx.types.get(xv.ty) == .borrow_write) .write else .read;
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
    /// enum of this module that is not generic.
    fn payloadOf(self: *Lowerer, ty: TypeId, pattern: Sexp, i: usize) ?TypeId {
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
                try self.killRegion(self.regions.items[self.regions.items.len - 1], self.posOf(guard));
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
                .variant_pattern => for (ir.VariantPattern.bindings(pattern), 0..) |b, i| {
                    if (b != .src) return abstain("a payload bound by field name");
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
        const src_ty = sema.unwrapBorrows(self.ctx, try self.typeOf(source));
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
                } else try self.eval(source, .take, null),
                .iter => if (source.isKind(.@"..")) try self.eval(source, .read, null) else if (self.madeSubject(source)) blk: {
                    // A value the header makes is taken, and so is the made
                    // value the source is a part of; a branching value is
                    // taken leaf by leaf (Core §3).
                    if (source.isKind(.member) or source.isKind(.index)) break :blk (try self.heldPart(source, "the `for` source")).held;
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
        while (i > 0) {
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
            try self.unwind(lp.cont_depth orelse lp.depth, pos);
            try self.goto(lp.cont orelse return abstain("`continue` out of a `match`"));
            return;
        }
        const lp = try self.findLoop(ir.Break.label(s));
        const v = ir.Break.value(s);
        if (v != .nil) {
            const lv = lp.value orelse return abstain("a `break` value of a loop that is not a value");
            // A `break` value is consumed like a result (SPEC §6); where
            // the loop's value is read, a write view is read through.
            try self.storeTaken(v, lv);
        }
        try self.unwind(lp.depth, pos);
        try self.goto(lp.brk);
    }

    /// `return e` or a `fun`'s last value: the value, then every region
    /// left, then the return (Core s3, s7).
    fn retValue(self: *Lowerer, e: Sexp) Error!void {
        const r = try self.newVar("the result", try self.typeOf(e), true, self.posOf(e));
        try self.pushRegion();
        try self.valueInto(e, .ret, r);
        try self.popRegion(self.posOf(e));
        if (self.cur == null) return;
        try self.ret(r, self.posOf(e));
    }

    fn ret(self: *Lowerer, r: ?VarId, pos: u32) Error!void {
        try self.unwind(0, pos);
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

    fn innerOf(self: *Lowerer, ty: TypeId) Error!TypeId {
        return switch (self.ctx.types.get(ty)) {
            .borrow_write, .borrow_read => |t| t,
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
        try self.store(j, v, pos);
        try self.goto(x);
        self.cur = other;
        try self.pushRegion();
        if (e.isKind(.@"catch")) {
            const name = ir.Catch.name(e);
            if (name != .nil and !std.mem.eql(u8, name.getText(self.src), "_")) {
                const err = try self.bind(name, 0);
                try self.emit(.{ .pos = pos, .what = .make, .def = err });
            }
        }
        const handler = if (e.isKind(.@"??")) ir.get(e, .right) else ir.Catch.handler(e);
        try self.valueInto(handler, if (how == .ret) .take else how, j);
        try self.popRegion(pos);
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
        try self.store(j, v, self.posOf(e));
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
                const p = try self.place(operand) orelse blk: {
                    if (k == .write) return abstain("a write lend of a made value");
                    if (isBranching(operand)) return abstain("a lend of a branching value (Core §3, planned)");
                    const t = try self.eval(operand, .take, null) orelse return null;
                    break :blk Place{ .root = t, .path = &.{}, .ty = self.f.vars.items[t].ty };
                };
                return try self.lend(p, if (k == .read) .read else .write, e, try self.typeOf(e));
            },
            .move => return self.move(e, how),
            .clone => {
                const operand = ir.Clone.operand(e);
                const p = try self.place(operand) orelse return abstain("a clone of a made value");
                const t = try self.temp(try self.typeOf(e), pos);
                // `+x` reads `x` and makes a new owner carrying its loans (Core s2).
                try self.emit(.{ .pos = pos, .what = .make, .reads = try self.one(p.root), .def = t, .access = .{ .root = p.root, .path = p.path, .deref = p.via == .write, .kind = .read } });
                return t;
            },
            .@"if", .block, .match, .@"??", .@"catch" => {
                const t = try self.temp(try self.typeOf(e), pos);
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
                try self.ret(null, pos);
                self.cur = on;
                return v;
            },
            .array => {
                var parts: std.ArrayList(VarId) = .empty;
                for (ir.rest(e, .elems)) |el| if (try self.eval(el, .take, null)) |v| try parts.append(self.a, v);
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
            .lambda, .share, .weak => return abstain("a closure or handle"),
            .builtin, .raw_block => return abstain("`raw`"),
            .inst => return abstain("compile-time arguments"),
            .kwarg => return abstain("a keyword argument out of place"),
            .@"while", .@"for" => {
                // A loop that `break` leaves with a value (SPEC §6); a
                // write view's value is read through there.
                var ty = try self.typeOf(e);
                if (self.ctx.types.get(ty) == .borrow_write) ty = try self.innerOf(ty);
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
            .local, .param => {},
            .function => return abstain("a function value"),
            .capture => return abstain("a closure capture"),
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
            if (obj.isKind(.read) or obj.isKind(.write) or obj.isKind(.move)) return abstain("a sigil on an accessed object");
            // The object of a field or element read is only read (Core §3).
            const t = try self.eval(obj, .read, null) orelse return abstain("an access to a constant");
            break :blk Place{ .root = t, .path = &.{}, .ty = self.f.vars.items[t].ty };
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
        switch (self.ctx.types.get(base.ty)) {
            // A view reached through a slice or String carries that
            // view's loans, through a write view too (Core s7).
            .slice, .string => if (via != .read or !carry) {
                if (via == .write) under_write = true;
                via = .read;
                carry = true;
            },
            .borrow_read => if (via == .own) {
                via = .read;
            },
            .borrow_write => if (via == .own) {
                via = .write;
            },
            else => {},
        }
        return .{ .root = base.root, .path = path, .ty = try self.typeOf(e), .via = via, .slice = slice, .slice_of = if (slice) base.ty else 0, .carry = carry, .under_write = under_write };
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
        // A bare slice of a place lends it (Core §4).
        if (p.slice and p.via == .own) return try self.lend(p, .read, e, p.ty);
        switch (info.kind) {
            .plain, .read_view => return try self.copy(p, p.ty, pos),
            .write_view => {
                // A write view read as its value copies what it reaches
                // (SPEC §7); a write slice read as a slice views the same
                // elements, a reborrow. A write view itself never copies.
                const wants_view = if (want) |w| self.ctx.types.get(w) == .borrow_write else false;
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
                switch (how) {
                    .read, .view => return try self.lend(p, .read, e, p.ty),
                    .ret => if (p.path.len == 0 and p.via == .own and !self.f.vars.items[p.root].hidden) return try self.moveWhole(p.root, pos),
                    .take => {},
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
        if (self.f.vars.items[root].alias) return self.found(.C7, pos, "a payload seen through a view does not move out; take the subject with `<`", .{});
        if (self.isFinding(root)) return abstain("an index that moves its place's root");
        const t = try self.temp(self.f.vars.items[root].ty, pos);
        try self.emit(.{ .pos = pos, .what = .move, .moves = try self.one(root), .def = t, .access = .{ .root = root, .kind = .whole } });
        return t;
    }

    fn isFinding(self: *Lowerer, root: VarId) bool {
        return std.mem.findScalar(VarId, self.finding.items, root) != null;
    }

    /// `?p` or `!p` (Core s4, §4): a new loan on the place, carrying what
    /// the root views; through a read view, a copy of that view.
    fn lend(self: *Lowerer, p: Place, mode: core.Mode, e: Sexp, ty: TypeId) Error!VarId {
        const pos = self.posOf(e);
        const kind: kinds.Kind = if (mode == .read) .read_view else .write_view;
        if (mode != .read and self.isFinding(p.root)) return abstain("an index that lends its place's root to write");
        const pk = (try self.kinds.of(p.ty)).kind;
        // Lending a view the place holds hands over a copy of it; lending
        // the place itself (`?p.s` as a `?String`, a slice) makes a loan.
        const pointer = switch (self.ctx.types.get(ty)) {
            .borrow_read, .borrow_write => ty != p.ty,
            else => false,
        };
        if (p.via == .read or (p.via == .own and pk == .read_view and !p.slice and !pointer)) {
            if (mode != .read) return abstain("a write lend through a read view");
            const t = try self.viewTemp(ty, kind, pos);
            try self.emit(.{ .pos = pos, .what = .copy, .reads = try self.one(p.root), .def = t, .access = readAccess(p), .carry = p.carry });
            return t;
        }
        const deref = p.via == .write or (p.path.len == 0 and pk == .write_view);
        const loan = try self.newLoan(p, mode, deref, 0, pos);
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

    fn newLoan(self: *Lowerer, p: Place, mode: core.Mode, deref: bool, group: u32, pos: u32) Error!core.LoanId {
        // What the loan is on: for a slice, what is sliced.
        var reached = if (p.slice) p.slice_of else p.ty;
        if (self.ctx.types.get(reached) == .borrow_write) reached = try self.innerOf(reached);
        try self.f.loans.append(self.a, .{
            .root = p.root,
            .path = p.path,
            .mode = mode,
            .deref = deref,
            .group = group,
            .pos = pos,
            .stores_views = try self.storesViews(p),
            .reaches_text = (try self.kinds.of(reached)).reaches_text,
        });
        return @intCast(self.f.loans.items.len - 1);
    }

    /// `<x` moves a whole binding; `<p.f` takes an optional field, or
    /// copies a plain one (Core s2, §5).
    fn move(self: *Lowerer, e: Sexp, how: How) Error!?VarId {
        const operand = ir.Move.operand(e);
        const pos = self.posOf(e);
        if (operand == .src) {
            const v = self.varOf(operand) orelse return abstain("a move of something not a local");
            return try self.moveWhole(v, pos);
        }
        const p = try self.place(operand) orelse return try self.eval(operand, how, null);
        const info = try self.kinds.of(p.ty);
        if (self.ctx.types.get(p.ty) == .optional) {
            if (p.via == .read) return self.found(.C7, pos, "nothing is taken out through a read view", .{});
            const t = try self.temp(p.ty, pos);
            try self.emit(.{ .pos = pos, .what = .take, .reads = try self.one(p.root), .def = t, .access = .{ .root = p.root, .path = p.path, .deref = p.via == .write, .kind = .write } });
            return t;
        }
        if (info.kind.copies()) return try self.copy(p, p.ty, pos);
        return self.found(.C3, pos, "only a whole binding moves; a field that is not optional cannot be taken", .{});
    }

    // ---- calls ----------------------------------------------------------

    const Shape = enum { view, take };

    fn shapeOf(ctx: *const sema.SemContext, ty: TypeId) Shape {
        return switch (ctx.types.get(ty)) {
            .borrow_read, .borrow_write, .slice, .string => .view,
            .optional => |o| switch (ctx.types.get(o)) {
                .borrow_read, .borrow_write, .slice, .string => .view,
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

        // Whether an instance suits a generic body is not ownership's
        // question here (SPEC "Generic bodies").
        if (self.ctx.genericCallOf(e) != null) return abstain("a call of a generic function");

        // What each argument goes to.
        var shapes: []const Shape = &.{};
        var all_read = false;
        var group: u32 = 0;
        var is_ctor = false;

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
                },
                .nominal_type, .generic_type, .type_alias => {
                    const built_in = sym_id.? == self.ctx.vec_sym_id or sym_id.? == self.ctx.box_sym_id or sym_id.? == self.ctx.cell_sym_id or sym_id.? == self.ctx.signal_sym_id;
                    if (s.kind == .generic_type and !built_in) return abstain("a generic constructor");
                    is_ctor = true;
                },
                .local, .param, .capture => return abstain("a call of a closure"),
                else => return abstain("an unusual callee"),
            };
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
                if (ft != null and ft.? == .function) shapes = try self.shapesOf(self.ctx, ft.?.function.params) else is_ctor = true;
            } else {
                // A method: the receiver first, then the arguments.
                const recv_mode, const fn_params = try self.method(callee);
                if (fn_params) |fp| {
                    shapes = try self.shapesOf(fp.ctx, fp.params);
                } else all_read = true;
                switch (recv_mode) {
                    .none => return abstain("a function of a type called on a value"),
                    .write => {
                        if (!obj.isKind(.write)) return abstain("a write receiver without `!`");
                        const p = try self.place(ir.Write.operand(obj)) orelse return abstain("a write receiver of a made value");
                        // A write receiver is lent when the call runs; its
                        // arguments may still read it (SPEC §7).
                        if (p.via == .read) return abstain("a write receiver through a read view");
                        const deref = p.via == .write or (p.path.len == 0 and self.f.vars.items[p.root].kind == .write_view);
                        const reserved = try self.newLoan(p, .reserved, deref, 0, pos);
                        const r = try self.viewTemp(try self.typeOf(obj), .write_view, pos);
                        try self.emit(.{ .pos = pos, .what = .lend, .reads = try self.one(p.root), .def = r, .loan = reserved, .access = .{ .root = p.root, .path = p.path, .deref = deref, .kind = .reserve } });
                        try uses.append(self.a, r);
                        try reads.append(self.a, p.root);
                        if (try self.storesViews(p)) try gains.append(self.a, p.root);
                        activation = try self.newLoan(p, .write, deref, 0, pos);
                        access = .{ .root = p.root, .path = p.path, .deref = deref, .kind = .write, .except = reserved };
                    },
                    .read => {
                        // A method lends its receiver for the whole call
                        // (SPEC §7), plain data included.
                        const r = if (try self.place(obj)) |p|
                            try self.lend(p, .read, obj, p.ty)
                        else
                            try self.eval(obj, .read, null);
                        if (r) |rv| try reads.append(self.a, rv);
                    },
                    .value => {
                        const r = try self.eval(obj, .take, null);
                        if (r) |rv| try moves.append(self.a, rv);
                    },
                }
            }
        } else if (callee.isKind(.enum_lit)) {
            is_ctor = true;
        } else return abstain("an unusual callee");

        // The arguments, left to right.
        const slots = self.ctx.callSlotsOf(e);
        for (args, 0..) |arg, i| {
            const val = if (arg.isKind(.kwarg)) ir.Kwarg.value(arg) else arg;
            var shape: Shape = .take;
            if (!all_read and !is_ctor) {
                const pi = if (slots) |sl| slotIndex(sl, i) orelse return abstain("an argument without a parameter") else i;
                if (pi >= shapes.len) return abstain("an argument without a parameter");
                shape = shapes[pi];
            }
            if (group != 0 and val.isKind(.write)) {
                // `swap` and `replace` lend their places for the call.
                const p = try self.place(ir.Write.operand(val)) orelse return abstain("an unusual `swap`");
                const deref = p.via == .write or (p.path.len == 0 and self.f.vars.items[p.root].kind == .write_view);
                const loan = try self.newLoan(p, .write, deref, group, pos);
                const t = try self.viewTemp(try self.typeOf(val), .write_view, pos);
                try self.emit(.{ .pos = self.posOf(val), .what = .lend, .reads = try self.one(p.root), .def = t, .loan = loan, .access = .{ .root = p.root, .path = p.path, .deref = deref, .kind = .write, .group = group } });
                try uses.append(self.a, t);
                try reads.append(self.a, p.root);
                continue;
            }
            if (val.isKind(.write)) {
                const p = try self.place(ir.Write.operand(val)) orelse return abstain("a write lend of a made value");
                try reads.append(self.a, try self.lend(p, .write, val, try self.typeOf(val)));
                // The call may store a view in what it was lent to write (s6).
                if (try self.storesViews(p)) try gains.append(self.a, p.root);
                continue;
            }
            const arg_how: How = if (all_read) .read else if (shape == .view) .view else .take;
            // Where a write view goes, a bare one would be copied (SPEC §7).
            const wants_view = is_ctor and arg.isKind(.kwarg) and self.fieldIsWriteView(e, ir.Kwarg.name(arg).getText(self.src));
            var v = try self.eval(val, arg_how, if (wants_view) self.ctx.typeOf(val) else null) orelse continue;
            if ((arg_how == .take and !is_ctor) or all_read) v = try self.readThrough(v, self.posOf(val));
            if (arg_how == .take) try moves.append(self.a, v) else try reads.append(self.a, v);
        }

        const rt = try self.typeOf(e);
        const rinfo = self.ctx.types.get(rt);
        const result: ?VarId = switch (rinfo) {
            .void, .noreturn => null,
            else => try self.temp(rt, pos),
        };
        // A write view handed on lets the call store into what it sees.
        var through: std.ArrayList(VarId) = .empty;
        for ([_][]const VarId{ reads.items, moves.items }) |g| for (g) |v| {
            if (self.f.vars.items[v].kind == .write_view) try through.append(self.a, v);
        };
        try self.emit(.{
            .pos = pos,
            .what = .call,
            .reads = reads.items,
            .moves = moves.items,
            .uses = uses.items,
            .def = result,
            .loan = activation,
            .access = access,
            .gains = gains.items,
            .through = through.items,
        });
        return result;
    }

    /// Whether a call lent `p` to write may store a view there: what
    /// the lend reaches can hold one.
    fn storesViews(self: *Lowerer, p: Place) Error!bool {
        var ty = p.ty;
        if (self.ctx.types.get(ty) == .borrow_write) ty = try self.innerOf(ty);
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
    /// "Second-class borrows").
    fn readThrough(self: *Lowerer, v: VarId, pos: u32) Error!VarId {
        const vv = self.f.vars.items[v];
        if (!vv.hidden) return v;
        const inner_ty = switch (self.ctx.types.get(vv.ty)) {
            .borrow_read, .borrow_write => |t| t,
            else => return v,
        };
        if (!(try self.kinds.of(inner_ty)).kind.copies()) return v;
        const t = try self.temp(inner_ty, pos);
        try self.emit(.{ .pos = pos, .what = .copy, .reads = try self.one(v), .def = t });
        return t;
    }

    fn fieldIsWriteView(self: *Lowerer, ctor: Sexp, name: []const u8) bool {
        const ty = self.ctx.typeOf(ctor) orelse return false;
        const decl = sema.nominalDecl(self.ctx, ty) orelse return false;
        for (decl.symbol().fields orelse &.{}) |*f| {
            for (sema.dataFields(f)) |d| {
                if (std.mem.eql(u8, d.name, name) and decl.ctx.types.get(d.ty) == .borrow_write) return true;
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

    fn shapesOf(self: *Lowerer, ctx: *const sema.SemContext, params: []const TypeId) Error![]const Shape {
        const out = try self.a.alloc(Shape, params.len);
        for (params, out) |p, *s| s.* = shapeOf(ctx, p);
        return out;
    }

    const MethodParams = struct { ctx: *const sema.SemContext, params: []const TypeId };

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
        const recv_ty = try self.typeOf(inner_obj);
        const decl = sema.nominalDecl(self.ctx, recv_ty) orelse {
            // A built-in method of an array, slice, or String: it writes
            // its receiver only where `!` says so.
            return switch (self.ctx.types.get(sema.unwrapBorrows(self.ctx, recv_ty))) {
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
                .read, .write, .value => .{ f.receiver, .{ .ctx = decl.ctx, .params = if (params.len > 0) params[1..] else params } },
            };
        }
        return null;
    }
};
