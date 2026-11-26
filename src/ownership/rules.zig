//! The rules: each check that rejects a program, grouped by the Core
//! sentence it enforces (docs/CORE.md section 2).

const std = @import("std");
const parser = @import("../parser.zig");
const sema = @import("../sema.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const TypeId = sema.TypeId;
const Error = std.mem.Allocator.Error;
const state = @import("state.zig");
const live = @import("live.zig");
const transfer = @import("transfer.zig");
const origins = @import("origins.zig");
const generic = @import("generic.zig");
const types = @import("types.zig");
const notes = @import("notes.zig");
const Access = state.Access;
const Checker = state.Checker;
const Loan = state.Loan;
const PathId = state.PathId;
const Sink = state.Sink;
const Value = state.Value;
const VarId = state.VarId;
const whole_path = state.whole_path;
const loop_view_rule = notes.loop_view_rule;
const module_level_rule = notes.module_level_rule;

// -----------------------------------------------------------------------------
// Sentences 1 and 2: a moved or dropped value cannot be used
// -----------------------------------------------------------------------------

/// Reading `id`, or the place `place` of it: it must be live and not
/// under a write view. The place's path is decided only where some write
/// loan on `id` is live.
pub fn checkReadable(self: *Checker, id: VarId, place: ?Sexp, pos: u32) Error!void {
    const path = if (place) |e| (if (transfer.resolvePlace(self, e)) |p| (if (p.root == id) p.path else whole_path) else whole_path) else whole_path;
    if (!try checkLivePath(self, id, path, pos)) return;
    if (self.findLoan(id, whole_path, .write, null) == null) return;
    if (self.findLoan(id, path, .write, null)) |l| {
        try notes.err(self, pos, "cannot use `{s}` while {s} is still in use", .{ try notes.pathText(self, id, path), try notes.viewOfText(self, l, path) });
        try notes.noteLoan(self, l);
        try notes.noteStillUsed(self, l, pos);
    }
}

/// Report a capture of a moved or dropped var. Returns whether it is
/// live.
pub fn checkCapturable(self: *Checker, id: VarId, pos: u32) Error!bool {
    if (self.flowLive(id)) return checkParts(self, id, whole_path, pos);
    const what = if (self.flows.items[id].status == .dropped) "drop" else "move";
    try notes.err(self, pos, "cannot capture `{s}` after {s}", .{ self.vars.items[id].name, what });
    try notes.noteInvalidated(self, id, pos);
    return false;
}

/// Report a use of a moved or dropped var. Returns whether it is live.
/// A use of all of it, which a field moved out leaves unusable.
pub fn checkLive(self: *Checker, id: VarId, pos: u32) Error!bool {
    return checkLivePath(self, id, whole_path, pos);
}

/// Report a use of place `path` of var `id` that is moved or dropped,
/// or that overlaps a field moved out of it (`Flow.parts`): a use
/// touches the path it names (Core §5). Returns whether it is usable.
pub fn checkLivePath(self: *Checker, id: VarId, path: PathId, pos: u32) Error!bool {
    if (self.defer_floor) |floor| try checkDeferredReach(self, id, floor, pos);
    if (self.flowLive(id)) return checkParts(self, id, path, pos);
    const v = self.vars.items[id];
    if (v.once) {
        try notes.err(self, pos, "`{s}` is called at most once (`once`), and it is used up already", .{v.name});
        const f = self.flows.items[id];
        if (self.loop != null and f.at >= (self.step_at orelse pos) and !self.in_defer) {
            try notes.note(self, f.at, "`{s}` was used here, in a previous iteration of the loop", .{v.name});
        } else try notes.note(self, f.at, "`{s}` was used here", .{v.name});
        return false;
    }
    const what = if (self.flows.items[id].status == .dropped) "drop" else "move";
    try notes.err(self, pos, "use of `{s}` after {s}", .{ try notes.varText(self, v), what });
    try notes.noteInvalidated(self, id, pos);
    return false;
}

/// Report a use of place `path` of `id` that overlaps a field moved
/// out of it: the field itself, or anything below it, is used after
/// its move; anything that holds it, `id` itself among them, waits
/// until the field is assigned again (Core §5: "no use touches all
/// of `p` except `p = x`"). Returns whether the use is fine.
pub fn checkParts(self: *Checker, id: VarId, path: PathId, pos: u32) Error!bool {
    for (self.flows.items[id].parts) |part| {
        if (!self.paths.overlap(part.path, path)) continue;
        const moved = try notes.pathText(self, id, part.path);
        if (self.paths.within(path, part.path)) {
            try notes.err(self, pos, "use of `{s}` after move", .{try notes.pathText(self, id, path)});
        } else try notes.err(self, pos, "`{s}` is partly moved: `{s}` was moved out; assign it first", .{ try notes.pathText(self, id, path), moved });
        try notes.note(self, part.at, "`{s}` was moved here", .{moved});
        return false;
    }
    return true;
}

/// Deferred code reading `id` reads what it views, directly or
/// through what that views, which must not be a var declared after
/// the `defer` (from `floor` on): that is dropped before it runs.
pub fn checkDeferredReach(self: *Checker, id: VarId, floor: u32, pos: u32) Error!void {
    var reach: std.ArrayList(VarId) = .empty;
    try reach.append(self.arena(), id);
    var k: usize = 0;
    while (k < reach.items.len) : (k += 1) {
        for (self.flows.items[reach.items[k]].loans) |l| {
            if (l.ext or std.mem.findScalar(VarId, reach.items, l.root) != null) continue;
            if (l.root >= floor) {
                try notes.err(self, pos, "deferred code reads `{s}` through `{s}`, but `{s}` is declared after the `defer` and dropped before it runs", .{ self.vars.items[l.root].name, self.vars.items[id].name, self.vars.items[l.root].name });
                try notes.noteLoan(self, l);
                return;
            }
            try reach.append(self.arena(), l.root);
        }
    }
}

/// Loop elements and captured resources are views of a slot owned
/// elsewhere: they cannot be consumed. Returns true if rejected.
pub fn rejectConsumedView(self: *Checker, id: VarId, pos: u32, op: []const u8) Error!bool {
    const v = self.vars.items[id];
    // An element of generic type is taken as a copy: each instance
    // must be plain data.
    if (v.elem_view and v.ref == .none) if (types.owningKind(self, v.ty)) |k| if (k == .generic) {
        try generic.requirePlain(self, pos, v.ty.?, true);
    };
    if (v.as_view) if (types.owningKind(self, v.ty)) |k| if (k == .generic) {
        try generic.addRequirement(self, pos, v.ty.?, .{ .param = 0, .pos = pos, .as_view = true });
    };
    if (v.loop_view) {
        try notes.err(self, pos, "cannot {s} loop view `{s}`; " ++ loop_view_rule, .{ op, v.name });
        return true;
    }
    if (v.capture_resource) {
        if (v.ref != .none) {
            try notes.err(self, pos, "cannot {s} captured view `{s}`; the closure holds it for every call. Use it through the view, or pass it to a call", .{ op, v.name });
            return true;
        }
        try notes.err(self, pos, "cannot {s} captured `{s}`: the closure keeps what it captures for every call{s}", .{ op, v.name, try notes.captureFix(self, v.name, v.ty) });
        return true;
    }
    return false;
}

/// A module-level binding outlives every call of the function using
/// it: a function cannot consume or replace it.
pub fn rejectGlobal(self: *Checker, id: VarId, pos: u32, op: []const u8) Error!bool {
    if (!self.isGlobal(id)) return false;
    const name = self.vars.items[id].name;
    try notes.err(self, pos, module_level_rule, .{ op, name });
    return true;
}

// -----------------------------------------------------------------------------
// Sentence 2: an owning value is not copied implicitly
// -----------------------------------------------------------------------------

/// Reject an implicit copy of an owning value in a consuming position.
/// `top_return`: a bare name directly in return position is a move.
pub fn checkNoImplicitCopy(self: *Checker, expr: Sexp, sink: Sink, top_return: bool) Error!void {
    // Reported by the type checker.
    if (types.rejected(self, expr)) return;
    // The value a view reaches is copied where its context reads
    // it, in the branches of what is read too.
    const saved_reads = self.copy_reads;
    defer self.copy_reads = saved_reads;
    if (readsValue(self, expr)) self.copy_reads = true;
    switch (expr) {
        .src => {
            const v = self.vars.items[self.find(expr) orelse return];
            const pos = expr.src.pos;
            const name = v.name;
            if (v.closure) return; // reported by walkName
            // A loop view passed to a call is passed on for the call, as
            // `?x` passes it; anywhere else it would be copied out.
            if (v.loop_view and !(sink == .argument and types.isView(self, v.ty))) {
                try notes.err(self, pos, "bare use of loop view `{s}` in {s} would carry the viewed handle past the loop; " ++ loop_view_rule, .{ name, sink.text() });
                return;
            }
            // A captured read view or Copy value is copied out, so is
            // a captured write view whose value its context reads (a
            // closure's `Int` result), and a captured view passed to a
            // call is viewed for the call.
            const copied = v.ref == .read or types.copies(self, v.ty) or readsThroughWriteView(self, v.ty) or (sink == .argument and v.ref != .none) or try types.copiesNarrowed(self, v.ty, pos);
            if (v.capture_resource and !copied and v.ref == .write) {
                try notes.err(self, pos, "`{s}` is a write view the closure captures, and a {s} would hand it out of the closure at each call, though a write view has one holder; use it inside the closure instead", .{ name, sink.text() });
                return;
            }
            if (v.capture_resource and !copied) {
                try notes.err(self, pos, "`{s}` is captured by the closure, which keeps it for every call, so a {s} can't take it{s}", .{ name, sink.text(), try notes.captureFix(self, name, v.ty) });
                return;
            }
            // A read of a group's field is a field's read, which no
            // result moves out (docs/design/options.md, section 2).
            const field = try origins.groupFieldRead(self, expr);
            if (top_return and field == null) return;
            if (types.owningKind(self, v.ty)) |k| return notes.reportAlias(self, pos, field orelse name, if (field != null) .field else .name, k, sink, v.ty, null);
            if (sink == .argument) return;
            // A write view of a Copy value is copied where the
            // value is read; where a `!T` goes, the view would be.
            if (v.ref == .write and !readsThroughWriteView(self, v.ty)) {
                try notes.err(self, pos, "bare use of write view `{s}` in {s} would copy it, and a write view never copies; use `<{s}` to move it", .{ name, sink.text(), name });
            } else if (v.ref != .write and types.carriesWriteView(self, v.ty)) {
                try notes.err(self, pos, "bare use of `{s}` in {s} would copy the write view it holds; use `<{s}` to move it", .{ name, sink.text(), name });
            }
        },
        .list => switch (types.hands(self, expr).kind) {
            .place, .part_of_made => {
                // `Enum.variant` is a new value, not a field.
                if (namesType(self, ir.get(expr, .object))) return;
                const ty = types.exprType(self, expr);
                if (types.owningKind(self, ty)) |k| {
                    return notes.reportAlias(self, notes.startOf(self, expr), try notes.placeText(self, expr), if (expr.isKind(.index)) .element else .field, k, sink, ty, expr);
                }
            },
            // A value that is one of its parts (`sema.valueParts`):
            // a tail it returns moves out, like a bare return; an
            // operand it passes through does not. `m?` copies out
            // the value inside `m`, which only matters when that
            // value owns or holds a write view.
            .made, .branches => {
                const ty = types.exprType(self, expr);
                var parts = sema.valueParts(expr);
                while (parts.next()) |p| switch (p.via) {
                    .tail => try checkNoImplicitCopy(self, p.node, sink, top_return),
                    .operand => try checkNoImplicitCopy(self, p.node, sink, false),
                    .unwrapped => if (types.owningKind(self, ty) != null or types.carriesWriteView(self, ty)) try checkNoImplicitCopy(self, p.node, sink, false),
                };
            },
            .view, .jump, .none => {},
        },
        else => {},
    }
}

/// Whether a bare name, field, or element of type `ty` hands over the
/// value a write view reaches rather than the view: `ty` is a write
/// view of a value that copies (`sema.copiedThrough`), and the
/// context reads it (`copy_reads`, `SemContext.readsThrough`). A bare
/// name or place only reads (Core sentence 1): `x = h.w`, with
/// `w: !Int` or `w: !Point`, copies the value.
pub fn readsThroughWriteView(self: *const Checker, ty: ?TypeId) bool {
    return self.copy_reads and types.refOfType(self, ty) == .write and types.copiedThrough(self, ty);
}

/// Whether the context of `e` reads the value the view it yields
/// reaches (`SemContext.readsThrough`).
pub fn readsValue(self: *const Checker, e: Sexp) bool {
    const ctx = self.sema;
    return ctx.readsThrough(e);
}

/// Whether `e` names a type (`Shape`, `lib.Shape`, `Opt[Int]`) rather
/// than a value.
pub fn namesType(self: *const Checker, e: Sexp) bool {
    const ctx = self.sema;
    if (ctx.instanceOf(e)) |inst| return inst == .type;
    const leaf = if (e.isKind(.member)) ir.Member.name(e) else e;
    if (leaf != .src) return false;
    if (e.isKind(.member)) {
        // `module.Type`: the module has no value.
        const m = ir.Member.object(e);
        if (m != .src) return false;
        const id = ctx.symbolOf(m) orelse return false;
        return ctx.symbols.items[id].kind == .module;
    }
    const id = ctx.symbolOf(e) orelse return false;
    return switch (ctx.symbols.items[id].kind) {
        .nominal_type, .generic_type, .type_alias => true,
        else => false,
    };
}

// -----------------------------------------------------------------------------
// Sentences 5 and 6: a view leaves its place read-only or unusable
// -----------------------------------------------------------------------------

/// Report a live loan on place `path` of var `id` that `access` at
/// `pos` conflicts with: a read view conflicts with a write loan,
/// anything else with every loan. Returns whether there was one.
pub fn conflicts(self: *Checker, id: VarId, path: PathId, access: Access, pos: u32) Error!bool {
    return try conflictingLoan(self, id, path, access, pos) != null;
}

/// `conflicts`, giving the loan it reported.
pub fn conflictingLoan(self: *Checker, id: VarId, path: PathId, access: Access, pos: u32) Error!?Loan {
    if (access != .read) try self.clearNones(id, path);
    const l = self.findLoan(id, path, if (access == .read) .write else .any, null) orelse return null;
    // Diagnostics name both places: the one used, and the one viewed
    // where it is not the same.
    const name = try notes.pathText(self, id, path);
    const view = try notes.viewOfText(self, l, path);
    const viewed = try notes.viewedText(self, l, path);
    const verb = switch (access) {
        .read => "use",
        // A cell changes through its own calls (`!c.set(5)`), so a
        // write of the handle that holds one is named as such.
        .write => if (path == whole_path and notes.holdsCellHandle(self, id)) "make a write view of the handle" else "change",
        .consume => |v| v,
    };
    // Every arm of `task.select` is made before it runs one, so the
    // views two arms make live at once: the fix moves the use out of
    // one.
    if (access == .write and l.kind == .write and !l.place_hold and l.held_read == .none and notes.selectWith(self, self.cur_stmt, pos, l.pos) != null) {
        try notes.err(self, pos, "cannot change `{s}` while {s} is still in use: `task.select` makes every arm before it runs one, so two arms cannot each hold a write view of `{s}`; let one arm write it, or have each arm give a value and write `{s}` after the select", .{ name, view, name, name });
        try notes.noteLoan(self, l);
        try notes.noteStillUsed(self, l, pos);
        return l;
    }
    if (access != .read and l.place_hold)
        try notes.err(self, pos, "cannot {s} `{s}` in an index of a view being made of {s}", .{ verb, name, viewed })
    else if (access != .read and l.held_read != .none)
        try notes.err(self, pos, "cannot {s} `{s}` {s}", .{ verb, name, try notes.heldReadClause(self, l.held_read, viewed) })
    else
        try notes.err(self, pos, "cannot {s} `{s}` while {s} is still in use", .{ verb, name, view });
    try notes.noteLoan(self, l);
    try notes.noteStillUsed(self, l, pos);
    if (access != .read and l.held_read == .callee) try notes.noteCloneCallee(self, l.pos);
    return l;
}

/// Checks shared by reassignment and compound assignment.
pub fn checkAssignable(self: *Checker, id: VarId, pos: u32) Error!void {
    const v = self.vars.items[id];
    if (v.closure) {
        try notes.err(self, pos, "cannot reassign closure binding `{s}`; closure bindings are fixed", .{v.name});
        try notes.note(self, v.decl, "`{s}` was bound here as a closure", .{v.name});
        return;
    }
    if (v.fixed and self.isGlobal(id)) {
        try notes.err(self, pos, "cannot reassign constant `{s}`", .{v.name});
        try notes.note(self, v.decl, "`{s}` is declared here", .{v.name});
        return;
    }
    if (v.fixed) {
        try notes.err(self, pos, "cannot reassign fixed binding `{s}`", .{v.name});
        try notes.note(self, v.decl, "`{s}` was bound here with `=!`", .{v.name});
        return;
    }
    // Assigning a captured write view writes through it.
    // (A capture the type checker rejected is reported there.)
    const writes_capture = v.kind == .capture and (v.ref == .write or types.isPoisonType(self, v.ty));
    if (!writes_capture and try rejectConsumedView(self, id, pos, "reassign")) return;
    if (!types.copies(self, v.ty) and try rejectGlobal(self, id, pos, "reassign")) return;
    if (v.payload_view and v.ref != .write and !types.isPoisonType(self, v.ty)) {
        try notes.err(self, pos, "cannot reassign match binding `{s}`; it views the matched value", .{v.name});
        return;
    }
    if (self.findLoan(id, whole_path, .any, null)) |l| {
        try notes.err(self, pos, "cannot reassign `{s}` while {s} is still in use", .{ v.name, try notes.viewOfText(self, l, whole_path) });
        try notes.noteLoan(self, l);
        try notes.noteStillUsed(self, l, pos);
    }
}

// -----------------------------------------------------------------------------
// A view may not outlive its root
// -----------------------------------------------------------------------------

/// Value `v` leaving the scopes of the vars `>= start`: report its
/// loans on them and drop those.
pub fn escapeVarsFrom(self: *Checker, v: Value, start: u32) Error!Value {
    for (v.loans) |l| if (l.root >= start and !l.deref) try notes.reportShortLived(self, l, null, null);
    return .{ .loans = try self.filterLoansBelow(v.loans, start) };
}

pub fn checkEscape(self: *Checker, v: Value) Error!void {
    for (v.loans, 0..) |l, i| {
        if (l.deref or !origins.isLocalLoan(self, l)) continue;
        if (self.func.in_closure and l.root < self.func.closure_base) continue;
        const r = self.vars.items[l.root];
        if (r.arm_of.len > 0) {
            try notes.reportArmView(self, l);
            continue;
        }
        if (r.erased_of.len > 0) {
            try notes.reportErasedCopy(self, l, r);
            continue;
        }
        const seen = for (v.loans[0..i]) |p| {
            if (p.root == l.root and !p.ext) break true;
        } else false;
        if (seen) continue;
        if (r.kind == .param) {
            const shown = if (r.ty) |t| try sema.formatTypeIn(self.sema, self.arena(), t) else "T";
            try notes.err(self, l.pos, "cannot return a view of `{s}`: a parameter taken by value belongs to this function and ends with it; take `{s}: ?{s}` to return a view of the caller's value", .{ try notes.varText(self, r), r.name, shown });
            try notes.noteStringResultOfString(self, l, self.func.ret_ty);
            continue;
        }
        try notes.err(self, l.pos, "cannot return a view of `{s}`, which belongs to this function", .{r.name});
        try notes.note(self, r.decl, "`{s}` is local to this {s}", .{ r.name, if (self.func.in_closure) "closure" else "function" });
        try notes.noteStringResultOfString(self, l, self.func.ret_ty);
    }
}

// -----------------------------------------------------------------------------
// Sentence 7: a `once` parameter is called at most once
// -----------------------------------------------------------------------------

pub const OnceUse = struct { id: VarId, pos: u32 };

/// The `once` parameters call `node` uses up: its callee, and each
/// argument that fills a parameter its own callee calls at most once.
/// Any other argument that is one is reported: the callee could call
/// it again.
pub fn onceUses(self: *Checker, node: Sexp) Error![]const OnceUse {
    var out: std.ArrayList(OnceUse) = .empty;
    const callee = ir.Call.callee(node);
    if (callee == .src) if (onceVar(self, callee)) |id| {
        try out.append(self.arena(), .{ .id = id, .pos = callee.src.pos });
        try self.once_uses.append(self.gpa, callee.src.pos);
    };
    const params = self.sema.callParamsOf(node);
    for (ir.Call.args(node), 0..) |a, ai| {
        const value = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
        if (value != .src) continue;
        const id = onceVar(self, value) orelse continue;
        if (params) |p| if (p.fillsOnce(ai)) {
            try out.append(self.arena(), .{ .id = id, .pos = value.src.pos });
            try self.once_uses.append(self.gpa, value.src.pos);
            continue;
        };
        try notes.errOnceUse(self, value);
        try self.once_uses.append(self.gpa, value.src.pos);
    }
    return out.items;
}

/// The `once` parameter `e` names, if it is one.
pub fn onceVar(self: *const Checker, e: Sexp) ?VarId {
    const id = self.find(e) orelse return null;
    return if (self.vars.items[id].once) id else null;
}
