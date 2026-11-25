//! The walk: what each construct does to the abstract state, grouped by
//! the Core sentence it follows (docs/CORE.md section 2).

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const sema = @import("../sema.zig");
const storage = @import("../storage.zig");
const diag = @import("../diag.zig");
const self_check = @import("build_options").self_check;
const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const TypeId = sema.TypeId;
const SymbolId = sema.SymbolId;
const Error = std.mem.Allocator.Error;
const state = @import("state.zig");
const live = @import("live.zig");
const rules = @import("rules.zig");
const origins = @import("origins.zig");
const exits = @import("exits.zig");
const generic = @import("generic.zig");
const types = @import("types.zig");
const notes = @import("notes.zig");
const Checker = state.Checker;
const Loan = state.Loan;
const LoanKind = state.LoanKind;
const LoopCtx = state.LoopCtx;
const Part = state.Part;
const PathId = state.PathId;
const Paths = state.Paths;
const Reader = state.Reader;
const Ref = state.Ref;
const Sink = state.Sink;
const State = state.State;
const Tail = state.Tail;
const Value = state.Value;
const Var = state.Var;
const VarId = state.VarId;
const Via = state.Via;
const containsLoan = state.containsLoan;
const sameNode = state.sameNode;
const stateAt = Checker.stateAt;
const unsigiled = state.unsigiled;
const whole_path = state.whole_path;
const ExitTo = exits.ExitTo;
const staticParamHint = generic.staticParamHint;
const loop_view_rule = notes.loop_view_rule;
const module_level_rule = notes.module_level_rule;
const part_copies_rule = notes.part_copies_rule;

/// The call a destructure's value is: alone, or under `!`, `?`, or a
/// fallback that jumps.
pub fn resultsCall(value: Sexp) Sexp {
    return switch (value.kind() orelse return .nil) {
        .call => value,
        .propagate, .propagate_none => ir.get(value, .value),
        .@"??" => ir.@"??".left(value),
        .@"catch" => ir.Catch.value(value),
        else => .nil,
    };
}

pub fn isLambda(s: Sexp) bool {
    return s.isKind(.lambda);
}

pub fn hasLoanOn(loans: []const Loan, root: VarId) bool {
    for (loans) |l| if (l.root == root) return true;
    return false;
}

pub fn refOfTypeSexp(t: Sexp) Ref {
    if (t.isKind(.read_view)) return .read;
    if (t.isKind(.write_view)) return .write;
    return .none;
}

// -----------------------------------------------------------------------------
// Declarations, functions, statements, and blocks
// -----------------------------------------------------------------------------

pub fn walkDecl(self: *Checker, sexp: Sexp) Error!void {
    switch (sexp.kind() orelse return) {
        .module => {
            for (ir.Module.decls(sexp)) |c| if (rig.isModuleConst(c)) try walkDecl(self, c);
            for (ir.Module.decls(sexp)) |c| if (!rig.isModuleConst(c)) try walkDecl(self, c);
        },
        .fun, .sub => {
            // A method of a generic type: what its body requires of a
            // function value is checked at each call of it.
            const saved = self.method_pos;
            defer self.method_pos = saved;
            const name = ir.get(sexp, .name);
            if (self.fn_depth == 0) self.method_pos = if (generic.genericOwner(self) and name == .src) name.src.pos else null;
            try walkFun(self, name, sema.tparamsOf(sexp), ir.get(sexp, .params), rig.returnType(sexp), ir.get(sexp, .body));
        },
        .drop_decl => try walkFun(self, .nil, .nil, ir.DropDecl.params(sexp), .nil, ir.DropDecl.body(sexp)),
        .@"struct", .@"enum", .errors, .generic_struct => {
            const saved = self.decl_owner;
            defer self.decl_owner = saved;
            self.decl_owner = self.sema.symbolOf(ir.get(sexp, .name));
            for (ir.rest(sexp, .members)) |c| try walkDecl(self, c);
        },
        .@"pub" => try walkDecl(self, ir.Pub.decl(sexp)),
        .@"test" => try walkFun(self, .nil, .nil, .nil, .nil, ir.Test.body(sexp)),
        .use, .type, .@"extern", .extern_fun, .extern_sub, .zig_extern, .zig_const, .variant, .@":" => {},
        // An API's defaults, and an addition's methods (whose origins
        // its conformance holds, `declOrigins`).
        .api, .api_add => {
            const saved = self.decl_owner;
            defer self.decl_owner = saved;
            self.decl_owner = if (sexp.isKind(.api)) self.sema.symbolOf(ir.Api.name(sexp)) else null;
            for (ir.rest(sexp, .members)) |c| {
                if ((c.isKind(.fun) or c.isKind(.sub)) and ir.get(c, .body) != .nil) try walkDecl(self, c);
            }
        },
        else => try walkStmt(self, sexp),
    }
}

/// Walk a function, method, drop body or test body. `tparams`: its
/// compile-time parameters, whose values (`n: Int`) are Copy.
pub fn walkFun(self: *Checker, name: Sexp, tparams: Sexp, params: Sexp, returns: Sexp, body: Sexp) Error!void {
    const top = self.fn_depth == 0 and self.item == null;
    if (top) self.items_seen.clearRetainingCapacity();
    try walkFunOnce(self, name, tparams, params, returns, body);
    if (top and self.items_seen.items.len > 0) try generic.walkItemInstances(self, name, tparams, params, returns, body);
}

pub fn walkFunOnce(self: *Checker, name: Sexp, tparams: Sexp, params: Sexp, returns: Sexp, body: Sexp) Error!void {
    const saved_func = self.func;
    const saved_body = self.fn_body;
    const saved_loop = self.loop;
    const saved_reachable = self.reachable;
    defer {
        self.func = saved_func;
        self.fn_body = saved_body;
        self.loop = saved_loop;
        self.reachable = saved_reachable;
    }
    const ret_ty = types.fnReturnType(self, name);
    const returns_value = returns != .nil and !types.isVoid(self, ret_ty);
    self.func = .{ .ret_may_view = returns_value and types.returnMayView(self, ret_ty, returns), .ret_ty = if (returns_value) ret_ty else null, .origins = origins.declOrigins(self, name) };
    self.fn_body = body;
    self.loop = null;
    // The body runs when called, not here: its effects on anything
    // outside it are undone afterwards.
    const outer = try self.here();
    self.reachable = true;
    const top = self.fn_depth == 0;
    if (top) {
        self.last_use.clearRetainingCapacity();
        self.defer_used.clearRetainingCapacity();
        self.uses.clearRetainingCapacity();
        try live.indexUses(self, params, false, null);
        try live.indexUses(self, body, false, null);
        self.nll = true;
    }
    defer if (top) {
        self.nll = false;
    };
    self.fn_depth += 1;
    defer self.fn_depth -= 1;

    try self.pushScopeFor(.function, .nil);
    for (tparams.items()) |p| if (p != .src) try bindParam(self, p);
    try bindParams(self, params);
    try origins.bindSelfPaths(self);
    const result = try walkBody(self, body, returns_value);
    try self.popScopeWith(result.loans);
    if (name != .nil) try origins.checkOrigins(self, try std.fmt.allocPrint(self.arena(), "`{s}`", .{types.text(self, name)}), name, params);
    try self.rewind(outer);
    // Nothing allocated for a module-level function outlives it.
    if (self.fn_depth == 1) _ = self.fn_arena_state.reset(.{ .retain_with_limit = 1 << 20 });
}

/// Walk a function body in the current scope. When the function
/// returns a value, its last expression is the return value, whose
/// loans it gives.
pub fn walkBody(self: *Checker, body: Sexp, returns_value: bool) Error!Value {
    const stmts: []const Sexp = if (body.isKind(.block)) ir.Block.stmts(body) else (&body)[0..1];
    var result: Value = .{};
    for (stmts, 0..) |stmt, i| {
        try exits.checkAfterJump(self, stmts, i);
        if (!self.reachable) {
            try exits.checkRestAfterJump(self, stmts, i);
            break;
        }
        if (returns_value and i == stmts.len - 1 and isValue(self, stmt)) {
            const saved_stmt = self.cur_stmt;
            self.cur_stmt = stmt;
            defer self.cur_stmt = saved_stmt;
            result = try walkReturnValue(self, stmt, null);
        } else {
            try walkStmt(self, stmt);
        }
    }
    return result;
}

/// Bind the run-time parameters `params` of the function or closure
/// being checked, each with its index.
pub fn bindParams(self: *Checker, params: Sexp) Error!void {
    self.func.binding_params = true;
    defer self.func.binding_params = false;
    for (params.items()) |p| try bindParam(self, p);
}

pub fn bindParam(self: *Checker, p: Sexp) Error!void {
    var name_node: Sexp = .nil;
    var type_node: Sexp = .nil;
    var sugar: Ref = .none;
    switch (p) {
        .src => name_node = p,
        .list => switch (p.kind() orelse return) {
            .@":", .default => {
                name_node = ir.get(p, .name);
                type_node = ir.get(p, .type);
            },
            // `?@` / `!@` sugar.
            .read => {
                name_node = ir.Read.operand(p);
                sugar = .read;
            },
            .write => {
                name_node = ir.Write.operand(p);
                sugar = .write;
            },
            // `<@`: `Self`, owned.
            .move => name_node = ir.Move.operand(p),
            else => {},
        },
        else => return,
    }
    if (name_node != .src) return;
    const pos = name_node.src.pos;
    const ty = types.symType(self, pos);
    var ref = sugar;
    if (ref == .none) ref = types.refOfType(self, ty);
    if (ref == .none) ref = refOfTypeSexp(type_node);
    const index = self.func.params;
    if (self.func.binding_params) self.func.params += 1;
    const id = try self.addVar(.{
        .name = types.text(self, name_node),
        .decl = pos,
        .ty = ty,
        .kind = .param,
        .ref = ref,
        .param_index = if (self.func.binding_params and index < @bitSizeOf(sema.ParamMask)) @intCast(index) else null,
        // Written `f: once ?fun() -> T`, as the function's origins record.
        .once = self.func.binding_params and index < @bitSizeOf(sema.ParamMask) and self.func.origins.once & sema.paramBit(index) != 0,
    }, .{});
    // Views handed in by the caller: an external loan on the param
    // itself marks them as returnable and conflict-free. It is a
    // write loan when the param holds a write view, as `!T` or
    // inside an optional (`(!T)?`): whatever unwraps it writes
    // through that loan to what the caller owns (`callerOwns`).
    if (ref != .none or (ty != null and types.mayCarryLoan(self, ty))) {
        const writes = ref == .write or types.carriesWriteView(self, ty);
        self.replaceFlow(id, .{ .loans = try self.oneLoan(.{ .root = id, .kind = if (writes) .write else .read, .pos = pos, .ext = true }) });
    }
}

pub fn walkStmt(self: *Checker, stmt: Sexp) Error!void {
    _ = try walkStmtValue(self, stmt, null);
}

/// Walk one statement; its temporary views end with it. With
/// `sink`, its value is consumed there (a loop's `as` condition).
pub fn walkStmtValue(self: *Checker, stmt: Sexp, sink: ?Sink) Error!Value {
    const p = notes.span(self, stmt);
    if (!p.isEmpty()) self.anchor = p.start;
    if (!self.reachable) return .{};
    // The temporaries from before stay first: every state the
    // statement reaches keeps them, and a scope it leaves is younger.
    const temps_len = self.temps.items.len;
    const saved_stmt = self.cur_stmt;
    self.cur_stmt = stmt;
    defer self.cur_stmt = saved_stmt;
    const walked = self.walked.items.len;
    defer self.walked.shrinkRetainingCapacity(@min(walked, self.walked.items.len));
    const drops = self.stmt_drops.items.len;
    const v = if (sink) |k| try walkConsumed(self, stmt, k) else try walk(self, stmt);
    self.temps.shrinkRetainingCapacity(@min(temps_len, self.temps.items.len));
    try dropStmtTemps(self, drops);
    return v;
}

/// Walk a `(block ...)` in its own scope; its value is the value of
/// its last statement, which may not view the block's own locals.
pub fn walkBlock(self: *Checker, block: Sexp) Error!Value {
    const stmts = ir.Block.stmts(block);
    const t = takeTail(self, block);
    try self.pushScopeFor(.block, block);
    var v: Value = .{};
    for (stmts, 0..) |s, i| {
        try exits.checkAfterJump(self, stmts, i);
        if (!self.reachable) {
            try exits.checkRestAfterJump(self, stmts, i);
            break;
        }
        if (i < stmts.len - 1) {
            try walkStmt(self, s);
            continue;
        }
        v = try walkTailStmt(self, s, t);
    }
    v = try self.leaveScope(v);
    return if (self.reachable) v else .{};
}

/// Walk `stmt`, a block's last statement or a `match` arm's body, as
/// a statement whose value `t`, if any, consumes: its temporaries
/// end with it, and its tail name moves before the scope's defers
/// run, as emit takes it there.
pub fn walkTailStmt(self: *Checker, stmt: Sexp, t: ?Tail) Error!Value {
    if (t) |ctx| markTail(self, stmt, ctx);
    const v = try walkStmtValue(self, stmt, null);
    if (t) |ctx| {
        self.tail = null;
        if (stmt == .src and self.reachable) try consumeTailName(self, stmt, ctx);
    }
    return v;
}

// -----------------------------------------------------------------------------
// Expressions: what each form hands over
// -----------------------------------------------------------------------------

pub fn walk(self: *Checker, sexp: Sexp) Error!Value {
    // An API object of a read view of plain data, or of a type
    // parameter's value, views a copy, a local of the erasing block
    // (`sema.Erasure.copy`): its loan is on that copy, which keeps
    // what the view kept, never on what the view reached.
    const ctx = self.sema;
    if (ctx.facts.erasures.count() > 0) if (ctx.erasureOf(sexp)) |e| if (e.copy) {
        const v = try walkUnerased(self, sexp);
        const pos = notes.startOf(self, sexp);
        const viewed = if (sexp.isKind(.read)) ir.Read.operand(sexp) else sexp;
        const id = try self.addVar(.{ .name = try std.fmt.allocPrint(self.arena(), "the copy of {s}", .{notes.spanText(self, viewed)}), .decl = pos, .ty = e.from, .kind = .hidden, .erased_of = notes.spanText(self, viewed), .erased_view = e.view }, .{ .loans = v.loans });
        return .{ .loans = try self.oneLoan(.{ .root = id, .kind = .read, .pos = pos }) };
    };
    return walkUnerased(self, sexp);
}

pub fn walkUnerased(self: *Checker, sexp: Sexp) Error!Value {
    const ctx = self.sema;
    switch (sexp) {
        // Plain data read through a view is copied where it stands,
        // and keeps nothing viewed (Core §6).
        .src => {
            if (ctx.readsThrough(sexp)) if (ctx.typeOf(sexp)) |ty| {
                const reached = sema.unwrapViews(ctx, ty);
                if (!types.mayCarryLoan(self, reached) and !generic.genericType(self, reached)) {
                    const temps_start = self.temps.items.len;
                    _ = try walkName(self, sexp, false);
                    self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
                    return .{};
                }
            };
            return walkName(self, sexp, false);
        },
        .list => {},
        else => return .{},
    }
    const kind = sexp.kind() orelse return .{};
    // The value a header holds is read from its hidden var.
    if (self.held) |h| if (sexp.list.ptr == h.base.list.ptr) {
        try rules.checkReadable(self, h.id, takePlaceRead(self, sexp), notes.startOf(self, sexp));
        return live.varValue(self, h.id);
    };
    // A temporary is taken into its statement's slot: a block or
    // `match` value's tail leaves its scope as it would for a binding.
    if (ctx.dropsTemp(sexp)) {
        try rules.checkNoImplicitCopy(self, sexp, .binding, false);
        setTail(self, sexp, .binding);
        return holdTemp(self, sexp, try walkList(self, sexp, kind));
    }
    // A view its context reads through gives the value it reaches;
    // when that holds no view, the loans taken to reach it end here.
    if (ctx.readsThrough(sexp)) if (ctx.typeOf(sexp)) |ty| {
        const temps_start = self.temps.items.len;
        return copiedOut(self, sema.unwrapViews(ctx, ty), temps_start, try walkList(self, sexp, kind));
    };
    const temps_start = self.temps.items.len;
    const v = try walkList(self, sexp, kind);
    // A value that can hold no view carries no loan: the loans taken
    // to make it end here, but for those something else holds (a
    // store, a temporary's `drop` body), which are not temporaries
    // (Core §6, sentence 6).
    if (carriesNoLoan(self, sexp)) self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
    return v;
}

/// Whether the value of `e` can carry no loan: its type holds no
/// view, it is no callable, whose captures it carries, no value of a
/// type parameter's type, which an instance's may hold, and no arm
/// of `task.select`, which views until its select returns.
pub fn carriesNoLoan(self: *const Checker, e: Sexp) bool {
    if (isLambda(e)) return false;
    const ty = types.exprType(self, e) orelse return false;
    if (types.mayCarryLoan(self, ty) or generic.genericType(self, ty)) return false;
    const ctx = self.sema;
    return sema.calledFn(ctx, ty) == null and !sema.holdsCallable(ctx, ty) and !(e.isKind(.call) and ctx.selectArmOf(e) != null);
}

/// `v`, a view walked from `temps_start`, read through for the value
/// of type `reached` it reaches: a copy of that value. When the value
/// holds no view, the loans taken to reach it end here. A view read
/// through a view is a copy of the view: it keeps what the view
/// keeps, not the view that reached it, and a `?String`'s views end
/// here but for those it keeps.
pub fn copiedOut(self: *Checker, reached: TypeId, temps_start: usize, v: Value) Error!Value {
    const ctx = self.sema;
    if (!types.mayCarryLoan(self, reached)) {
        generic.taintGeneric(self, reached, v);
        self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
        return .{};
    }
    if (sema.holdsViewOnly(ctx, reached)) return keepViewTemps(self, temps_start, try origins.carry(self, reached, v));
    return origins.carry(self, reached, v);
}

/// The value `holder`, the operand of `a ?? b` or `a catch b` (`node`),
/// gives the fallback form: what its payload views, copied out where
/// `node` copies it (`SemContext.copiesPayload`), else the payload as
/// it is.
pub fn walkPayloadHolder(self: *Checker, node: Sexp, holder: Sexp) Error!Value {
    const ctx = self.sema;
    if (!ctx.copiesPayload(node)) return walk(self, holder);
    const temps_start = self.temps.items.len;
    const v = try walk(self, holder);
    const viewed = sema.payloadViewed(ctx, ctx.typeOf(holder) orelse return v) orelse return v;
    return copiedOut(self, viewed, temps_start, v);
}

pub fn walkList(self: *Checker, sexp: Sexp, kind: Tag) Error!Value {
    switch (kind) {
        .fun, .sub, .drop_decl, .@"struct", .@"enum", .errors => try walkDecl(self, sexp),
        .set => try walkSet(self, sexp),
        .destructure => try walkDestructure(self, sexp),
        .drop => try walkDrop(self, sexp),
        .@"return" => try walkReturn(self, sexp),
        .@"break" => try exits.walkJump(self, sexp, .brk),
        .@"continue" => try exits.walkJump(self, sexp, .cont),
        .panic => try walkPanic(self, sexp),
        .@"defer", .@"errdefer" => try exits.walkDefer(self, sexp),
        else => return switch (kind) {
            .block => walkBlock(self, sexp),
            .move => walkMove(self, ir.Move.operand(sexp)),
            // A view the type checker rejected makes no loan.
            .read, .write => if (types.rejected(self, sexp))
                walkRejectedView(self, ir.get(sexp, .operand))
            else if (viewsElements(self, sexp))
                // `?a` viewed as `?a[..]`, `!a` as `!a[..]`, `?t` of a
                // String as `?t[..]`.
                walkElems(self, sexp, ir.get(sexp, .operand), if (sexp.isKind(.read)) .read else .write)
            else
                walkView(self, ir.get(sexp, .operand), loanOf(self, sexp)),
            .clone, .weak => walkCloneWeak(self, sexp),
            .share => walkShare(self, sexp),
            .box => walkConsumed(self, ir.Box.operand(sexp), .box),
            .lambda => walkLambda(self, sexp, false),
            .@"if" => walkIf(self, sexp),
            .@"while" => walkWhile(self, sexp),
            .@"for" => walkFor(self, sexp),
            .labeled => walkLabeled(self, sexp),
            .match => walkMatch(self, sexp),
            .@"catch" => walkCatch(self, sexp),
            .@"??" => walkNullish(self, sexp),
            .propagate, .propagate_none => walkPropagate(self, sexp),
            .call => walkCall(self, sexp),
            // A destructure's target takes its result's loans.
            .result_part => self.part_value,
            .member, .index, .inst => if (generic.isInstance(self, sexp)) .{} else walkMember(self, sexp),
            .kwarg => walkConsumed(self, ir.Kwarg.value(sexp), .argument),
            .array => blk: {
                const late = self.late.items.len;
                try live.holdLateParts(self, sexp, ir.Array.elems(sexp));
                var v: Value = .{};
                for (ir.Array.elems(sexp)) |e| v = try self.valueUnion(v, try walkConsumed(self, e, .element));
                try live.endLate(self, late);
                break :blk v;
            },
            .array_fill => walkConsumed(self, ir.ArrayFill.value(sexp), .element),
            // A template's value is a String made of its slots, which
            // it only reads, as `String(...)` reads its arguments: the
            // String holds their text, not them.
            .template => blk: {
                const temps_start = self.temps.items.len;
                try walkTemplateSlots(self, sexp);
                self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
                break :blk .{};
            },
            .raw_block => walkTailPart(self, ir.RawBlock.body(sexp), takeTail(self, sexp)),
            .enum_lit, .symbol, .use, .type, .generic_struct, .generic_inst => .{},
            // Operators on values produce fresh Copy results. A binary
            // operator reads its left operand where it runs, and uses
            // it after the right one runs.
            // The right side of `and` and `or` runs only when the left
            // does not decide; the left is a `Bool`, which holds
            // nothing while it runs.
            .@"and", .@"or" => blk: {
                _ = try walk(self, ir.get(sexp, .left));
                _ = try walkMayRun(self, ir.get(sexp, .right), null, sexp);
                break :blk .{};
            },
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .neg, .not, .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&", .@"|", .@"^", .@"<<", .@"<<%", .@">>", .@".." => blk: {
                const operands = rig.children(sexp);
                if (operands.len == 2) {
                    _ = try walkThenHeld(self, operands[0], .operand, operands[1]);
                } else for (operands) |c| _ = try walk(self, c);
                break :blk .{};
            },
            else => blk: {
                var v: Value = .{};
                for (rig.children(sexp)) |c| v = try self.valueUnion(v, try walk(self, c));
                break :blk v;
            },
        },
    }
    return .{};
}

/// The operand of a view the type checker rejected: a closure
/// binding there was reported with it.
pub fn walkRejectedView(self: *Checker, operand: Sexp) Error!Value {
    if (operand == .src) if (self.find(operand)) |id| if (self.vars.items[id].closure) return .{};
    return walk(self, operand);
}

/// Walk an expression in a position that takes ownership of its value.
pub fn walkConsumed(self: *Checker, expr: Sexp, sink: Sink) Error!Value {
    // A bare value viewed to read where a view is expected is walked as
    // `?expr` (`View.implicit`).
    if (viewOf(self, expr)) |view| if (view.implicit) return walkImplicitView(self, expr, view);
    if (isLambda(expr)) {
        // A closure literal given to a call as a callable view
        // lives for the call; anywhere else it is reported by
        // walkLambda.
        if (sink == .argument and (types.viewsBy(self, expr, .callable) or self.in_rejected_call or types.rejected(self, expr))) self.lambda_ok = true;
        return walk(self, expr);
    }
    self.copy_reads = self.value_reads;
    self.value_reads = false;
    try rules.checkNoImplicitCopy(self, expr, sink, false);
    self.copy_reads = false;
    // Passing a held write view (`w`, `e.t`) passes it on: like `!w`,
    // it is a write view of its holder for as long as the result may
    // keep the view.
    // A `![]T` passed where a `[]T` is expected is viewed to read.
    if (sink == .argument and isWriteViewPlace(self, expr)) return walkView(self, expr, if (types.viewsBy(self, expr, .read_only)) .read else .write);
    setTail(self, expr, sink);
    return walk(self, expr);
}

/// Mark `expr`, if it yields through its parts, as consumed by `sink`.
pub fn setTail(self: *Checker, expr: Sexp, sink: Sink) void {
    markTail(self, expr, .{ .node = 0, .sink = sink, .vars = @intCast(self.vars.items.len) });
}

/// Mark `expr`, a part of the value `t` consumes, as consumed too.
/// A loop's `else` is consumed by the loop's own value (`walkLoop`).
pub fn markTail(self: *Checker, expr: Sexp, t: Tail) void {
    if (!sema.yieldsThroughParts(expr) or expr.isKind(.@"while") or expr.isKind(.@"for") or expr.isKind(.labeled)) return;
    self.tail = .{ .node = expr.list.id, .sink = t.sink, .vars = t.vars };
}

/// The consuming context of the branching `node`, if any.
pub fn takeTail(self: *Checker, node: Sexp) ?Tail {
    const t = self.tail orelse return null;
    if (t.node != node.list.id) return null;
    self.tail = null;
    return t;
}

/// Walk a part of a consumed value (a branch, an arm, a handler):
/// its tail leaves it. A block part moves its tail name before its
/// defers run (`walkBlock`); a bare name part moves here.
pub fn walkTailPart(self: *Checker, body: Sexp, t: ?Tail) Error!Value {
    const ctx = t orelse return walk(self, body);
    markTail(self, body, ctx);
    const v = try walk(self, body);
    self.tail = null;
    if (body == .src) try consumeTailName(self, body, ctx);
    return v;
}

/// `node`, a bare name at the tail of a value `t` consumes, leaves
/// its binding there, as emit takes it. A name the value itself
/// declares, which `t.sink` could not check, or one the function
/// returns, moves out, as `<x` would. A match payload named there
/// moves out of its scrutinee, which the check before the walk could
/// not see (the name is bound in the arm).
pub fn consumeTailName(self: *Checker, node: Sexp, t: Tail) Error!void {
    const sink = t.sink;
    const ctx = self.sema;
    const sym = ctx.symbolOf(node) orelse return;
    const id = self.find(node) orelse return;
    const v = self.vars.items[id];
    if (v.decl != ctx.symbols.items[sym].decl_pos) return;
    if (!self.flowLive(id)) return;
    if (!v.payload_view) {
        if ((sink == .ret or id >= t.vars) and !v.closure and !v.capture_resource) {
            if (leavesAsWriteView(self, v, node, if (sink == .ret) self.func.ret_ty else null)) {
                _ = try moveWriteView(self, id, node.src.pos);
            } else if (!v.loop_view and returnMoves(self, v)) {
                _ = try moveVar(self, id, node.src.pos, .move);
            }
        }
        return;
    }
    const k = types.owningKind(self, v.ty) orelse return;
    if (k == .generic and v.via != .owned) {
        // A copy for plain data; each instantiation is checked.
        return notes.reportAlias(self, node.src.pos, v.name, .name, k, .binding, v.ty, null);
    }
    _ = try movePayload(self, id, node.src.pos, "move");
}

/// A place whose value holds a write view (`w`, or a `(!T)?` name;
/// no field or element holds one): passing it on passes that view on.
pub fn isWriteViewPlace(self: *Checker, expr: Sexp) bool {
    if (!types.carriesWriteView(self, types.exprType(self, expr))) return false;
    return switch (types.hands(self, expr).kind) {
        .place, .part_of_made => true,
        .made, .view, .branches, .jump, .none => false,
    };
}

// -----------------------------------------------------------------------------
// Sentence 1: a bare name or place only reads
// -----------------------------------------------------------------------------

/// A bare use of a name.
pub fn walkName(self: *Checker, node: Sexp, as_callee: bool) Error!Value {
    const pos = node.src.pos;
    const name = types.text(self, node);
    const id = self.find(node) orelse return .{};
    const v = self.vars.items[id];
    if (v.closure and !as_callee) {
        try notes.errClosureValue(self, pos, name);
        return .{};
    }
    if (v.once and std.mem.findScalar(u32, self.once_uses.items, pos) == null) {
        try notes.errOnceUse(self, node);
        return .{};
    }
    const place = takePlaceRead(self, node);
    try rules.checkReadable(self, id, place, pos);
    try live.markWalked(self, pos);
    var value = live.varValue(self, id);
    if (origins.isSelfVar(self, id)) if (place) |e| if (resolvePlace(self, e)) |p| if (p.root == id) {
        value = try origins.tagSelf(self, value, id, p.path);
    };
    // What the binding carries is in use until its consumer is done
    // with the value read here (Core §6), whether or not the binding
    // is used again.
    try holdMoved(self, value);
    return value;
}

/// The place `walkMember` reads from `base`, once: a use touches the
/// path it names (Core §5). Null, the whole var, for any other read.
pub fn takePlaceRead(self: *Checker, base: Sexp) ?Sexp {
    const r = self.place_read orelse return null;
    if (!sameNode(r.base, base)) return null;
    self.place_read = null;
    return r.place;
}

/// The node a place's path starts from: its root's name, or a
/// header's held value.
pub fn placeBase(self: *const Checker, e: Sexp) Sexp {
    var base = e;
    while (base.isKind(.member) or base.isKind(.index)) {
        if (self.held) |h| if (base.list.ptr == h.base.list.ptr) break;
        base = ir.get(base, .object);
    }
    return base;
}

/// `?f` of closure binding `id`: a read loan on the closure, and the
/// loans its captures hold.
pub fn viewClosure(self: *Checker, id: VarId, pos: u32) Error!Value {
    const v = (try viewVar(self, id, whole_path, .read, pos)) orelse return .{};
    return .{ .loans = try self.unionLoans(v.loans, self.flows.items[id].loans) };
}

pub const Place = struct {
    root: VarId,
    whole: bool,
    /// The part of the root the place names: its fields up to the
    /// first step that ends a path (`extendsPath`).
    path: PathId = whole_path,
    /// A step has ended the path: no later field extends it.
    path_ended: bool = false,
    /// Some step goes through an element index.
    indexed: bool = false,
    /// Some step dereferences a shared handle.
    through_shared: bool = false,
    /// Some step goes through a view (a viewed root or a
    /// view-typed field).
    through_view: bool = false,
};

/// The var a place (`sema.Hands.Kind.place`) starts from, the path
/// it names below it, and how it gets there. Null for anything else,
/// and for a name the closure body did not capture (walking the
/// expression reports it). The path is decided here and nowhere else:
/// each loan, use, and store of the place carries it.
pub fn resolvePlace(self: *const Checker, e: Sexp) ?Place {
    // The value a header holds is its hidden var.
    if (self.held) |h| if (e == .list and e.list.ptr == h.base.list.ptr) return .{ .root = h.id, .whole = true };
    if (types.hands(self, e).kind != .place and !heldPath(self, e)) return null;
    switch (e) {
        .src => {
            const id = self.find(e) orelse return null;
            return .{ .root = id, .whole = true, .through_view = self.vars.items[id].ref != .none };
        },
        .list => switch (e.kind() orelse return null) {
            .member, .index => {
                const object = ir.get(e, .object);
                var p = resolvePlace(self, object) orelse return null;
                const at_root = p.whole;
                p.whole = false;
                if (e.isKind(.index)) p.indexed = true;
                if (!p.path_ended) {
                    if (self.paths.steps.get(e.list.id)) |step| {
                        p.path = step.path;
                        p.path_ended = step.ended;
                    } else {
                        if (self.paths.depth(p.path) < Paths.max_depth and extendsPath(self, e, at_root, origins.isSelfVar(self, p.root))) {
                            // Out of memory, the path is cut where it
                            // is, which only adds conflicts.
                            p.path = self.paths.child(self.gpa, p.path, types.text(self, ir.Member.name(e))) catch blk: {
                                p.path_ended = true;
                                break :blk p.path;
                            };
                        } else p.path_ended = true;
                        self.paths.steps.put(self.gpa, e.list.id, .{ .path = p.path, .ended = p.path_ended }) catch {};
                    }
                }
                if (types.exprType(self, object)) |t| {
                    const ty = types.typeData(self, t);
                    if (ty == .shared) p.through_shared = true;
                    if (ty == .read_view or ty == .write_view) p.through_view = true;
                }
                return p;
            },
            else => return null,
        },
        else => return null,
    }
}

/// Whether `e`, a step of a place, goes on the place's path (Core §5,
/// "A field is a place of its own"): a data field of a struct value,
/// of a box's value (a box has one owner), or of what the root's own
/// write view sees (`at_root`: `e`'s object is the root itself). Any
/// other step ends the path, and a loan is on the path so far: an
/// element or a slice (an index is a run-time value, and a push may
/// move the buffer), a handle (other handles reach its contents), a
/// read view (what it views is its own loans', not the holder's), an
/// optional's value (it exists only while present), or a member of
/// anything else.
pub fn extendsPath(self: *const Checker, e: Sexp, at_root: bool, self_root: bool) bool {
    const ctx = self.sema;
    if (!e.isKind(.member)) return false;
    var t = types.exprType(self, ir.Member.object(e)) orelse return false;
    // A self that `from` checks by path (`bindSelfPaths`) has paths
    // through a read view of self too, though no loan is on it.
    if (at_root) switch (ctx.types.get(t)) {
        .write_view => |inner| t = inner,
        .read_view => |inner| if (self_root) {
            t = inner;
        },
        else => {},
    };
    while (sema.boxedType(ctx, t)) |inner| t = inner;
    switch (ctx.types.get(t)) {
        .nominal, .imported_nominal => {},
        .parameterized_nominal => |pn| if (sema.isBuiltinGeneric(ctx, pn.sym)) return false,
        else => return false,
    }
    return sema.lookupDataFieldConst(ctx, t, types.text(self, ir.Member.name(e))) != null;
}

/// Walk the index expressions inside a place.
pub fn walkPlaceIndices(self: *Checker, e: Sexp) Error!void {
    switch (e.kind() orelse return) {
        .member => try walkPlaceIndices(self, ir.Member.object(e)),
        .index => {
            try walkPlaceIndices(self, ir.Index.object(e));
            _ = try walk(self, ir.Index.index(e));
        },
        else => {},
    }
}

/// The indices of place `e`, whose address is taken (a view, a
/// slice, a method's self): the place up to each index is found
/// before the index runs, so while the indices run, the place's path
/// `path` of `root` is held read, and an index cannot make a write
/// view of it or move it (`!ps[0].a[grow(!ps)]` would write into the
/// buffer `grow` freed). An assignment finds its target only after its
/// indices run (`walkFieldAssign`).
pub fn walkIndicesHeld(self: *Checker, e: Sexp, root: VarId, path: PathId) Error!void {
    const mark = self.temps.items.len;
    try live.addTemp(self, .{ .root = root, .path = path, .kind = .read, .pos = notes.startOf(self, e), .place_hold = true });
    try walkPlaceIndices(self, e);
    if (mark < self.temps.items.len and self.temps.items[mark].place_hold) _ = self.temps.orderedRemove(mark);
}

/// The indices of place `e`, read or taken, each walked as
/// `walkIndexOf` walks it.
pub fn walkFoundIndices(self: *Checker, e: Sexp) Error!void {
    switch (e.kind() orelse return) {
        .member => try walkFoundIndices(self, ir.Member.object(e)),
        .index => {
            const object = ir.Index.object(e);
            try walkFoundIndices(self, object);
            try walkIndexOf(self, object, ir.Index.index(e));
        },
        else => {},
    }
}

/// `index` of place `object`, read or taken: `object` is found before
/// the index runs (`v.constSlot(0).*.at(i)`). The index may make a
/// write view of the root or move it only where what it reads stays
/// put: the element is read from an array held inline in `object`, or from a
/// List's buffer that `at` reads after the index, and `object` lies
/// in its root's own storage (`staysInRoot`): `vs[grow(!vs)]` finds
/// `vs` where it was, and reads the element after. Anywhere else (a
/// List past another List's buffer or a box, a handle, a String) the
/// root is held read while the index runs: `v[0][grow(!v)]` would read
/// the buffer `grow` freed, and `h[reh(!h)]` the List a re-pointed
/// handle let go.
pub fn walkIndexOf(self: *Checker, object: Sexp, index: Sexp) Error!void {
    const place = resolvePlace(self, object) orelse {
        _ = try walk(self, index);
        return;
    };
    if (readsAfterIndex(self, object) and staysInRoot(self, object)) {
        _ = try walk(self, index);
        return;
    }
    const mark = self.temps.items.len;
    try live.addTemp(self, .{ .root = place.root, .path = place.path, .kind = .read, .pos = notes.startOf(self, object), .place_hold = true });
    _ = try walk(self, index);
    if (mark < self.temps.items.len and self.temps.items[mark].place_hold) _ = self.temps.orderedRemove(mark);
}

/// Whether an element of place `object` is read where `object` is
/// found: from an array held inline in it, from a List's buffer,
/// which `at` reads after the index runs, or, for a root that is a
/// slice (`xs: ![]T`), from the elements it views, which a view of
/// it may write but never move or free. A root is what a view it is
/// views.
pub fn readsAfterIndex(self: *const Checker, object: Sexp) bool {
    const ty = stepType(self, object) orelse return false;
    const root = !object.isKind(.member) and !object.isKind(.index);
    return switch (types.typeData(self, ty)) {
        .array => true,
        .slice => root,
        else => types.holdsElems(self, ty),
    };
}

/// The type of `e`, a place or a step of one, as a step into it sees
/// it: a root that is a view is what it views.
pub fn stepType(self: *const Checker, e: Sexp) ?TypeId {
    const ty = types.exprType(self, e) orelse return null;
    if (e.isKind(.member) or e.isKind(.index)) return ty;
    return types.pointee(self, ty);
}

/// Whether place `e` is stored where its root's value is, every step
/// to it a field of an object or an element of an array held there
/// (`holdsInline`): a write of the root changes what is there but
/// never moves it. A root is what a view it is views.
pub fn staysInRoot(self: *const Checker, e: Sexp) bool {
    if (!e.isKind(.member) and !e.isKind(.index)) return true;
    const object = ir.get(e, .object);
    const ty = stepType(self, object) orelse return false;
    return holdsInline(self, ty) and staysInRoot(self, object);
}

/// Whether values of `ty` hold their parts where the value is: an
/// array, or an object a module declares (`obj P`, `obj Wrap[T]`,
/// declared in this module's source).
pub fn holdsInline(self: *const Checker, ty: TypeId) bool {
    const ctx = self.sema;
    return switch (ctx.types.get(ty)) {
        .array, .nominal, .imported_nominal => true,
        .parameterized_nominal => |pn| blk: {
            const sym = ctx.symbols.items[pn.sym];
            break :blk sym.kind == .generic_type and sym.decl_pos < sema.imported_decl_pos;
        },
        else => false,
    };
}

/// A `member` or `index`. A place is read as far as its path: its
/// root's name is read there (`takePlaceRead`).
pub fn walkMember(self: *Checker, e: Sexp) Error!Value {
    const object = ir.get(e, .object);
    // The outermost step of the place sets it; its root's name, read
    // first, takes it.
    var sets_read = false;
    defer if (sets_read) {
        self.place_read = null;
    };
    if (self.place_read == null) {
        self.place_read = .{ .base = placeBase(self, e), .place = e };
        sets_read = true;
    }
    // A value that is no place is read where it runs, and indexed
    // after its index runs; a place is found up to its index before
    // the index runs (`walkIndexOf`).
    const obj = if (e.isKind(.index) and resolvePlace(self, object) == null)
        try walkThenHeld(self, object, .base, ir.Index.index(e))
    else blk: {
        const v = try walk(self, object);
        if (e.isKind(.index)) try walkIndexOf(self, object, ir.Index.index(e));
        break :blk v;
    };
    if (!types.mayCarryLoan(self, types.exprType(self, e))) {
        generic.taintGeneric(self, types.exprType(self, e), obj);
        return .{};
    }
    return origins.carry(self, types.exprType(self, e), obj);
}

/// The arguments of `print`, `panic`, `String(...)`, and `!t.add(...)`,
/// which are only read: a slice there is a read view, as `?a` would
/// be, and none is held past the call.
pub fn walkReadArgs(self: *Checker, args: []const Sexp) Error!void {
    for (args) |a| {
        // A template's slots are the call's arguments where it
        // stands, read at the call as the others are.
        if (a.isKind(.template)) {
            try walkTemplateSlots(self, a);
            continue;
        }
        try walkReadArg(self, a);
    }
}

/// The slots of template `t`, in order, each read as an argument of
/// `print` is (`walkReadArgs`).
pub fn walkTemplateSlots(self: *Checker, t: Sexp) Error!void {
    for (0..rig.Template.slotCount(t)) |i| try walkReadArg(self, rig.Template.value(t, i));
}

/// One argument `walkReadArgs` reads.
pub fn walkReadArg(self: *Checker, a: Sexp) Error!void {
    {
        if (viewOf(self, a)) |view| if (view.implicit) {
            _ = try walkImplicitView(self, a, view);
            return;
        };
        _ = try walk(self, a);
        try holdRead(self, a, .argument);
    }
}

// -----------------------------------------------------------------------------
// Sentence 2: `<x` moves, `+x` makes a new owner
// -----------------------------------------------------------------------------

pub const MoveVerb = enum {
    move,
    capture,

    pub fn text(m: MoveVerb) []const u8 {
        return switch (m) {
            .move => "move",
            .capture => "move-capture",
        };
    }
};

/// What `<e` does to its source (`sema.moveSource`).
pub fn moveSource(self: *const Checker, inner: Sexp) sema.MoveSource {
    return sema.moveSource(self.sema, inner);
}

/// `<e`: a binding is ended, an optional part emptied (`walkTake`,
/// where typecheck recorded the take), and any other source is
/// rejected: `<` would leave it as it was, or move what its owner
/// still drops. A value made here is taken, and a branching value
/// leaf by leaf.
pub fn walkMove(self: *Checker, inner: Sexp) Error!Value {
    switch (moveSource(self, inner)) {
        .binding => {
            const place = resolvePlace(self, inner) orelse return walk(self, inner);
            return moveVar(self, place.root, notes.startOf(self, inner), .move);
        },
        .capture => {
            const place = resolvePlace(self, inner) orelse return walk(self, inner);
            // A capture that owns a resource, or holds a view, is
            // reported as one (`rejectConsumedView`).
            if (self.vars.items[place.root].capture_resource) return moveVar(self, place.root, notes.startOf(self, inner), .move);
            _ = try walk(self, inner);
            try notes.errAt(self, inner, "cannot move `{s}`, a copy capture: the closure keeps it for every call; remove the `<` to copy it", .{types.text(self, inner)});
            return .{};
        },
        .optional_part => return walkTake(self, inner),
        .part => {
            if (resolvePlace(self, inner)) |place| return movePart(self, inner, place, null, false);
            // A path that starts from no var reaches its value through
            // a view or a handle when one of the values on it is one,
            // by its type: `(!s).items`, `(?s if c else ?t).items`,
            // `wrap(!s).items`.
            if (viewOnPath(self, inner)) |via| return movePart(self, inner, .{ .root = 0, .whole = false, .through_view = !via.shared, .through_shared = via.shared }, via.value, false);
            // A root no var holds here (an outer name a closure did not
            // capture): walking reports it.
            return walk(self, inner);
        },
        .branch_part => return movePart(self, inner, .{ .root = 0, .whole = false }, sema.pathRoot(inner), true),
        // The type checker reported it (`rejectMadeParts`), and a
        // module with type errors is not checked here.
        .made_part => return walk(self, inner),
        .declared => return moveDeclared(self, inner),
        .made => return walk(self, inner),
        .branches => {
            if (try notes.reportMoveLeaves(self, inner)) return .{};
            return walk(self, inner);
        },
    }
}

/// `<` of what lives for the whole program
/// (`sema.MoveSource.declared`): rejected, since nothing could end it.
pub fn moveDeclared(self: *Checker, inner: Sexp) Error!Value {
    _ = try walk(self, inner);
    const pos = notes.startOf(self, inner);
    const shown = notes.spanText(self, inner);
    const ty = types.exprType(self, inner);
    if (ty != null and types.typeData(self, ty.?) == .function) {
        try notes.err(self, pos, "cannot move function `{s}`: a function lives for the whole program; remove the `<` to use it", .{shown});
    } else if (inner == .src or (inner.isKind(.member) and ir.Member.object(inner) == .src and namesModule(self, ir.Member.object(inner)))) {
        try notes.err(self, pos, module_level_rule, .{ "move", shown });
    } else try notes.err(self, pos, part_copies_rule, .{try notes.placeText(self, inner)});
    return .{};
}

pub fn namesModule(self: *const Checker, e: Sexp) bool {
    const ctx = self.sema;
    const id = ctx.symbolOf(e) orelse return false;
    return ctx.symbols.items[id].kind == .module;
}

/// The value a field or element path reaches its place through that
/// is a view (`?T`, `!T`, a slice) or a shared handle, by the type
/// of each value on the path, as `resolvePlace` judges a place's:
/// `(!s)` in `(!s).items[0]`, `wrap(!s)` in `wrap(!s).items`.
pub fn viewOnPath(self: *const Checker, e: Sexp) ?struct { value: Sexp, shared: bool } {
    var p = e;
    while (p.isKind(.member) or p.isKind(.index)) {
        const obj = ir.get(p, .object);
        if (types.exprType(self, obj)) |t| switch (types.typeData(self, t)) {
            .read_view, .write_view, .slice, .string_view => return .{ .value = obj, .shared = false },
            .shared => return .{ .value = obj, .shared = true },
            else => {},
        };
        p = obj;
    }
    return null;
}

/// `<p.f` of an optional field or element: the value is taken out
/// and `none` left behind, so the place stays whole. The place is
/// written: no other view of it may be live. What the value
/// views, the place viewed.
pub fn walkTake(self: *Checker, inner: Sexp) Error!Value {
    const place = resolvePlace(self, inner) orelse return walkViewedPath(self, inner);
    try walkFoundIndices(self, inner);
    const id = place.root;
    const pos = notes.startOf(self, inner);
    if (!try rules.checkLivePath(self, id, place.path, pos)) return .{};
    if (try rules.conflicts(self, id, place.path, .write, pos)) return .{};
    try self.markNone(place);
    if (!types.mayCarryLoan(self, types.exprType(self, inner))) {
        generic.taintGeneric(self, types.exprType(self, inner), live.varValue(self, id));
        return .{};
    }
    return live.varValue(self, id);
}

pub fn moveVar(self: *Checker, id: VarId, pos: u32, verb: MoveVerb) Error!Value {
    const v = self.vars.items[id];
    const vt = verb.text();
    if (v.closure) {
        try notes.errClosureValue(self, pos, v.name);
        return .{};
    }
    if (try rules.rejectConsumedView(self, id, pos, vt)) return .{};
    if (verb == .capture and v.kind == .param and v.ref != .none) {
        const handle = if (types.pointee(self, v.ty)) |t| types.typeData(self, t) == .shared or types.typeData(self, t) == .weak else false;
        if (handle) {
            try notes.err(self, pos, "cannot move-capture view parameter `{s}`; the caller still owns what it views. Capture a clone with `|+{s}|`", .{ v.name, v.name });
        } else try notes.err(self, pos, "cannot move-capture view parameter `{s}`; the caller still owns what it views. Capture the view with `|{s}{s}|`", .{ v.name, if (v.ref == .write) "!" else "?", v.name });
        return .{};
    }
    if (!(if (verb == .capture) try rules.checkCapturable(self, id, pos) else try rules.checkLive(self, id, pos))) return .{};
    const value = live.varValue(self, id);
    if (try rules.rejectGlobal(self, id, pos, vt)) return .{};

    // A payload that views its scrutinee cannot leave it; a copied
    // payload is not a view (`bindPayload`).
    if (v.payload_view) return movePayload(self, id, pos, vt);

    if (try rules.conflicts(self, id, whole_path, .{ .consume = vt }, pos)) return .{};
    // Emit arms a drop flag only for a binding the var table flags
    // (`storage.Binding.flag`), so no other may move.
    const ctx = self.sema;
    if (ctx.symbolAt(v.decl)) |sym| if (!ctx.vars.binding(sym).flag) {
        try notes.err(self, pos, "internal error: `{s}` moves here, but the var table does not flag it", .{v.name});
        return .{};
    };
    // `<x` ends `x`, whatever its type: a Copy value or a view is
    // copied out, and the name is done.
    try self.markInvalid(id, .moved, pos);
    try holdMoved(self, value);
    return value;
}

/// The loans a moved value carries stay in force until the end of the
/// statement or call that consumes it, so a later argument of the
/// same call cannot view or move their roots.
pub fn holdMoved(self: *Checker, value: Value) Error!void {
    for (value.loans) |l| if (!l.ext) try live.addTemp(self, l);
}

/// Move (or drop, `op`) a match payload binding out of its
/// scrutinee: a view of a value the match does not consume, so it is
/// rejected, with the way to take it.
pub fn movePayload(self: *Checker, id: VarId, pos: u32, op: []const u8) Error!Value {
    const v = self.vars.items[id];
    const viewed = if (v.alias_of) |root| self.vars.items[root].name else v.matched;
    switch (v.via) {
        .viewed => {
            try notes.err(self, pos, "cannot move out of `{s}`: it is a view of `{s}`", .{ v.name, viewed });
            return .{};
        },
        .shared => {
            try notes.err(self, pos, "cannot move out of `{s}`: `{s}` is a shared handle and other handles may still use it", .{ v.name, viewed });
            return .{};
        },
        .owned => {},
    }
    // Only a binding of a var the function owns is `owned`.
    const root = v.alias_of orelse return .{};
    const r = self.vars.items[root];
    if (try rules.rejectConsumedView(self, root, pos, op)) return .{};
    if (v.alias_path.len > 0) {
        try notes.err(self, pos, "cannot {s} `{s}` out of `{s}`: `{s}` still owns it (partial moves are not supported)", .{ op, v.name, v.alias_path, r.name });
        return .{};
    }
    // A bare match reads what it matches; `match <x` hands its
    // fields to the arm.
    try notes.err(self, pos, "cannot {s} `{s}` out of `{s}`: `match {s}` reads `{s}`; write `match <{s}` to take its fields", .{ op, v.name, r.name, r.name, r.name, r.name });
    return .{};
}

/// `<p.f` or `<v[i]` of a part that can be neither ended nor emptied
/// (`MoveSource.part`): rejected. One that copies would stay as it
/// was; one that moves would stay owned by its parent, or by what
/// `via` reaches it through (`viewOnPath`, `branchesOnPath`),
/// whatever its syntax.
pub fn movePart(self: *Checker, inner: Sexp, place: Place, via: ?Sexp, branching: bool) Error!Value {
    _ = try walk(self, inner);
    const ty = types.exprType(self, inner);
    const path = try notes.placeText(self, inner);
    const pos = notes.startOf(self, inner);
    // An optional is taken only out of a place (`sema.moveSource`).
    if (branching and ty != null and types.typeData(self, ty.?) == .optional) {
        const base = via.?;
        if (base.isKind(.@"if")) {
            try notes.err(self, pos, "cannot take out of `{s}`: `{s}` reads a binding where it stands; take it inside each branch", .{ notes.spanText(self, inner), notes.spanText(self, base) });
        } else try notes.err(self, pos, "cannot take out of `{s}`: `{s}` reads a binding where it stands, and `<` takes only out of a place", .{ notes.spanText(self, inner), notes.spanText(self, base) });
        return .{};
    }
    if (ty != null and (types.copies(self, ty) or types.refOfType(self, ty) == .read)) {
        try notes.err(self, pos, part_copies_rule, .{if (via != null) notes.spanText(self, inner) else path});
        return .{};
    }
    // A write view has one holder, which keeps it.
    if (via == null and types.refOfType(self, ty) == .write) {
        try notes.err(self, pos, "cannot move out of `{s}`: a write view has one holder, and `{s}` keeps it; pass it on with `!{s}`", .{ path, self.vars.items[place.root].name, path });
        return .{};
    }
    if (via) |l| {
        const shown = notes.spanText(self, inner);
        const viewed_handle = (l.isKind(.read) or l.isKind(.write)) and types.isHandleType(self, types.exprType(self, ir.get(l, .operand)));
        if (place.through_shared or viewed_handle) {
            const handle = if (viewed_handle) ir.get(l, .operand) else l;
            try notes.err(self, pos, "cannot move out of `{s}`: it is reached through the shared handle `{s}`, and other handles may still use it; clone it with `+({s})`", .{ shown, notes.spanText(self, handle), shown });
        } else if (branching) {
            try notes.err(self, pos, "cannot move out of `{s}`: `{s}` reads a binding where it stands, which would still drop it; exchange the part where it is owned, with `swap`", .{ shown, notes.spanText(self, l) });
        } else if ((l.isKind(.read) or l.isKind(.write)) and resolvePlace(self, ir.get(l, .operand)) != null) {
            // A view of a place: the place's own path names the part.
            try notes.err(self, pos, "cannot move out of `{s}`: it is reached through `{s}`, a view; {s}", .{ shown, notes.spanText(self, l), try notes.exchangeHint(self, ty, path, "exchange it instead") });
        } else try notes.err(self, pos, "cannot move out of `{s}`: it is reached through `{s}`, a view, which gives up nothing of what it views; exchange the part where it is owned, with `swap`", .{ shown, notes.spanText(self, l) });
        return .{};
    }
    const root = self.vars.items[place.root].name;
    if (place.through_view) {
        try notes.err(self, pos, "cannot move out of `{s}`: `{s}` is a view; {s}", .{ path, root, try notes.exchangeHint(self, types.exprType(self, inner), path, "exchange it instead") });
    } else if (place.through_shared) {
        try notes.err(self, pos, "cannot move out of `{s}`: it is reached through a shared handle and other handles may still use it; clone it with `+{s}`", .{ path, path });
    } else if (place.indexed) {
        try notes.err(self, pos, "cannot move out of `{s}`: elements cannot be moved out of their container", .{path});
    } else return moveField(self, inner, place);
    return .{};
}

/// `<p.f` of a field of an object a local or parameter owns, which
/// copies not and that `<` does not take (`sema.moveSource`: it takes
/// an optional of a binding that can be assigned) (Core §5, "A field of an owned
/// object moves like a name"): `p.f` moves as a name does, and `p` is
/// partly moved (`Flow.parts`) until the field is assigned again.
/// Owning rules out views, handles, boxes, and elements, which
/// `movePart` reported; a type on the path with a `drop` body
/// expects every field; closures and deferred code move no field, as
/// they move no name. Emit gives the field a drop flag
/// (`SemContext.field_moves`).
pub fn moveField(self: *Checker, inner: Sexp, place: Place) Error!Value {
    const id = place.root;
    const v = self.vars.items[id];
    const path = try notes.placeText(self, inner);
    const root = v.name;
    const pos = notes.startOf(self, inner);
    if (v.payload_view) return movePayload(self, id, pos, "move");
    if (v.kind == .hidden or v.call_held) {
        try notes.err(self, pos, "cannot move out of `{s}`: it is part of a value its statement holds and drops; bind that value to a name first", .{path});
        return .{};
    }
    if (v.loop_view or v.elem_view or v.as_view or v.ref != .none) {
        try notes.err(self, pos, "cannot move out of `{s}`: `{s}` is a view; {s}", .{ path, root, try notes.exchangeHint(self, types.exprType(self, inner), path, "exchange it instead") });
        return .{};
    }
    if (try rules.rejectConsumedView(self, id, pos, "move a field out of")) return .{};
    if (try rules.rejectGlobal(self, id, pos, "move a field out of")) return .{};
    // Every step is a field of an object the step before holds by
    // value: no box, and no type with a `drop` body.
    var e = inner;
    while (e.isKind(.member)) {
        const object = ir.Member.object(e);
        const ty = types.exprType(self, object) orelse return .{};
        const ctx = self.sema;
        if (sema.boxedType(ctx, ty) != null) {
            try notes.err(self, pos, "cannot move out of `{s}`: a box frees what it holds as one; take the box's value with `<{s}.unbox()` first", .{ path, notes.spanText(self, object) });
            return .{};
        }
        if (types.dropBodyType(self, ty)) {
            try notes.err(self, pos, "cannot move out of `{s}`: `{s}` has a `drop` body, which expects every field; move `{s}` whole, or exchange the field: `old = swap(!{s}, v)`", .{ path, try sema.formatTypeIn(ctx, self.arena(), ty), notes.spanText(self, object), path });
            return .{};
        }
        e = object;
    }
    if (place.path_ended or place.path == whole_path) {
        try notes.err(self, pos, "cannot move out of `{s}`: only a field reached through fields `{s}` owns moves out; {s}", .{ path, root, try notes.exchangeHint(self, types.exprType(self, inner), path, "exchange it instead") });
        return .{};
    }
    if (!try rules.checkLivePath(self, id, place.path, pos)) return .{};
    if (try rules.conflicts(self, id, place.path, .{ .consume = "move" }, pos)) return .{};
    // Emit arms a drop flag only for a field the field-moves fact
    // records, so no other may move.
    const ctx = self.sema;
    if (ctx.symbolAt(v.decl)) |sym| {
        const fields = try fieldPath(self, inner);
        const recorded = for (ctx.fieldMoves(sym)) |f| {
            if (std.mem.eql(u8, f, fields)) break true;
        } else false;
        if (!recorded) {
            try notes.err(self, pos, "internal error: `{s}` moves here, but the field-moves fact does not record it", .{path});
            return .{};
        }
    }
    const value = live.varValue(self, id);
    var f = self.flows.items[id];
    var parts: std.ArrayList(Part) = .empty;
    try parts.appendSlice(self.arena(), f.parts);
    try parts.append(self.arena(), .{ .path = place.path, .at = pos });
    f.parts = parts.items;
    try self.setFlow(id, f);
    try holdMoved(self, value);
    if (!types.mayCarryLoan(self, types.exprType(self, inner))) {
        generic.taintGeneric(self, types.exprType(self, inner), value);
        return .{};
    }
    return origins.carry(self, types.exprType(self, inner), value);
}

/// The fields of a field path below its root, `a.b` for `p.a.b`, as
/// `SemContext.field_moves` records them.
pub fn fieldPath(self: *Checker, e: Sexp) Error![]const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    var p = e;
    while (p.isKind(.member)) : (p = ir.Member.object(p)) try fields.append(self.arena(), types.text(self, ir.Member.name(p)));
    std.mem.reverse([]const u8, fields.items);
    return std.mem.join(self.arena(), ".", fields.items);
}

/// `+x` / `~x`. A clone that holds no view is made where it stands
/// and keeps nothing viewed there (Core §6): what its operand read
/// through is released, so `!m.take(+v.key)` ends `v`'s view of `m`
/// before the call makes a write view of `m`.
pub fn walkCloneWeak(self: *Checker, e: Sexp) Error!Value {
    const inner = ir.get(e, .operand);
    const temps_start = self.temps.items.len;
    const v = try walk(self, inner);
    const p = resolvePlace(self, inner);
    const id: ?VarId = if (p != null and p.?.whole) p.?.root else null;
    const out = try newHandle(self, notes.startOf(self, inner), try notes.placeText(self, inner), types.exprType(self, e), id, v, e.isKind(.weak));
    if (!types.mayCarryLoan(self, types.exprType(self, e))) self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
    return out;
}

// -----------------------------------------------------------------------------
// Sentence 3: drop points
// -----------------------------------------------------------------------------

pub fn walkDrop(self: *Checker, node: Sexp) Error!void {
    const target = ir.Drop.target(node);
    // `<e` of anything but a name drops what it takes, as `_ = <e`
    // does (`walkSet`).
    if (target != .src) {
        const saved = self.binding;
        defer self.binding = saved;
        self.binding = .{ .name = "_", .value = target };
        _ = try walkConsumed(self, target, .binding);
        return;
    }
    const pos = target.src.pos;
    const name = types.text(self, target);
    const id = self.find(target) orelse return;
    const v = self.vars.items[id];
    // Why `<x` cannot drop `x` is decided once (`sema.undroppable`),
    // which the type checker's hint for a statement `-x` reads too.
    const why: ?sema.Undroppable = sema.undroppable(self.sema, target);
    if (why) |w| return switch (w) {
        .view_param => notes.err(self, pos, "cannot drop view parameter `{s}`; the caller owns what it views", .{name}),
        .capture => if (v.ref != .none)
            notes.err(self, pos, "cannot drop captured view `{s}`; the closure holds it for every call. Use it through the view, or pass it to a call", .{name})
        else if (v.capture_resource)
            notes.err(self, pos, "cannot drop captured `{s}`: the closure keeps what it captures for every call", .{name})
        else
            notes.err(self, pos, "cannot drop captured `{s}`; the closure keeps what it captures for every call", .{name}),
        .loop_slot => notes.err(self, pos, "cannot drop loop view `{s}`; " ++ loop_view_rule, .{name}),
    };
    if (try rules.rejectConsumedView(self, id, pos, "drop")) return;
    if (try rules.rejectGlobal(self, id, pos, "drop")) return;
    if (!self.flowLive(id)) {
        if (self.flows.items[id].status == .moved) {
            try notes.err(self, pos, "cannot drop `{s}` after it was moved", .{name});
        } else try notes.err(self, pos, "cannot drop `{s}` twice", .{name});
        try notes.noteInvalidated(self, id, pos);
        return;
    }
    if (!try rules.checkParts(self, id, whole_path, pos)) return;
    if (v.payload_view) {
        _ = try movePayload(self, id, pos, "drop");
        if (!self.flowLive(id)) try self.markInvalid(id, .dropped, pos);
        return;
    }
    if (self.findLoan(id, whole_path, .any, null)) |l| {
        try notes.err(self, pos, "cannot drop `{s}` while {s} is still in use", .{ name, try notes.viewOfText(self, l, whole_path) });
        try notes.noteLoan(self, l);
        try notes.noteStillUsed(self, l, pos);
        return;
    }
    try self.markInvalid(id, .dropped, pos);
}

// -----------------------------------------------------------------------------
// Sentence 4: `?x` and `!x` make views of a place
// -----------------------------------------------------------------------------

/// What view `e` (`?x` or `!x`) puts on `x` (`SemContext.loanOf`).
pub fn loanOf(self: *const Checker, e: Sexp) LoanKind {
    if (e.isKind(.read)) return .read;
    return switch (self.sema.loanOf(e)) {
        .read => .read,
        .write => .write,
    };
}

/// How `e` is viewed where a view of another type is expected
/// (`SemContext.viewOf`).
pub fn viewOf(self: *const Checker, e: Sexp) ?sema.View {
    const ctx = self.sema;
    return ctx.viewOf(e);
}

/// Whether `e`, a view written here, views the elements of its
/// operand (an array's or a List's, or a String's bytes) rather than a
/// view of the operand or of what it holds.
pub fn viewsElements(self: *const Checker, e: Sexp) bool {
    const view = viewOf(self, e) orelse return false;
    for (view.steps()) |step| switch (step) {
        .lift => {},
        .elems, .text => return true,
        else => return false,
    };
    return false;
}

/// `e`, a bare value viewed to read where a view is expected, walked as
/// the view `?e` would be: of its elements (`?a[..]`, `?t[..]`) when
/// the view's first row is theirs, of the value otherwise.
pub fn walkImplicitView(self: *Checker, e: Sexp, view: sema.View) Error!Value {
    for (view.steps()) |step| switch (step) {
        .lift => {},
        .elems, .text => return walkElems(self, e, e, .read),
        else => break,
    };
    return walkView(self, e, .read);
}

pub fn walkView(self: *Checker, inner: Sexp, kind: LoanKind) Error!Value {
    if (rig.isRangeIndex(inner)) return walkElems(self, inner, ir.Index.object(inner), kind);
    if (kind == .read and origins.throughReadView(self, inner)) return origins.walkThroughView(self, inner);
    const place = resolvePlace(self, inner) orelse {
        const start = self.vars.items.len;
        const v = try walkViewedPath(self, inner);
        return if (kind == .write) writeViewTemp(self, v, start) else v;
    };
    try walkIndicesHeld(self, inner, place.root, place.path);
    const id = place.root;
    const v = self.vars.items[id];
    const pos = notes.startOf(self, inner);
    if (v.closure) {
        if (kind == .read and place.whole) return viewClosure(self, id, pos);
        try notes.err(self, pos, "closure `{s}` cannot be given a write view; pass it as `?{s}`", .{ v.name, v.name });
        return .{};
    }
    return (try viewVar(self, id, place.path, kind, pos)) orelse .{};
}

/// `v`, the write view of a path that starts from no var: the
/// statement temporary it starts from (held since there were
/// `start` vars, `holdTemp`) is given a write view (`!mk().bump()`, Core
/// sentence 4).
pub fn writeViewTemp(self: *Checker, v: Value, start: usize) Error!Value {
    var loans: ?[]Loan = null;
    for (v.loans, 0..) |l, i| {
        if (l.root < start or !self.isStmtTemp(l.root) or l.kind == .write) continue;
        const out = loans orelse try self.arena().dupe(Loan, v.loans);
        out[i].kind = .write;
        loans = out;
    }
    var w = v;
    if (loans) |ls| w.loans = ls;
    return w;
}

/// A view of a path that starts from no var (`?f(?h).r`): it keeps
/// what the path's start views, whatever the type of each step.
pub fn walkViewedPath(self: *Checker, e: Sexp) Error!Value {
    if (!e.isKind(.member) and !e.isKind(.index)) return walk(self, e);
    const obj = try walkViewedPath(self, ir.get(e, .object));
    if (e.isKind(.index)) _ = try walk(self, ir.Index.index(e));
    return obj;
}

/// View place `path` of var `id` at `pos`: null when `id` is moved or
/// the view conflicts, both reported.
pub fn viewVar(self: *Checker, id: VarId, path: PathId, kind: LoanKind, pos: u32) Error!?Value {
    if (!try rules.checkLivePath(self, id, path, pos)) return null;
    if (try rules.conflicts(self, id, path, if (kind == .write) .write else .read, pos)) return null;
    const loan: Loan = .{ .root = id, .path = path, .kind = kind, .pos = pos };
    try live.addTemp(self, loan);
    return try viewOn(self, id, loan);
}

/// A view of the elements of `object`: `slice` is a slice of it
/// (`?xs[a..b]`, `!xs[a..b]`), or a view of the whole array viewed as
/// one (`?a`). A slice of a `?String` or a `[]T` views what that value
/// views. A slice of a List views the List, whose buffer it points
/// into, and one of a `![]T` views the `![]T`, as a view of a
/// view does. A slice of an array held in the storage of the var it
/// is reached from, which may be a copy (a by-value parameter, a loop
/// or pattern binding), also holds a frame loan on that var, so it
/// cannot outlive it.
pub fn walkElems(self: *Checker, slice: Sexp, object: Sexp, kind: LoanKind) Error!Value {
    // The place's own indexes, and a slice's bounds.
    const indices = if (rig.isRangeIndex(slice)) slice else object;
    // A slice the type checker rejected views nothing.
    if (types.rejected(self, slice)) {
        _ = try walk(self, object);
        try walkPlaceIndices(self, indices);
        return .{};
    }
    // What it views, as the type checker recorded it: the elements
    // or bytes the value holds, through handles and boxes, or a
    // `![]T` passed on. A view's elements are what the view views.
    const view = self.sema.sliceViewOf(slice) orelse self.sema.viewOf(slice) orelse return walkOperand(self, slice, object);
    if (!view.has(.elems) and !view.has(.text) and !view.has(.read_only)) return walkOperand(self, slice, object);
    const ty = types.exprType(self, object) orelse return walkOperand(self, slice, object);
    const peeled = types.pointee(self, ty) orelse ty;
    // An array reached through a read view (an element of a `[]T`)
    // is viewed as that view views it.
    if (origins.throughReadView(self, object)) {
        const v = try origins.walkThroughView(self, object);
        if (rig.isRangeIndex(slice)) _ = try walk(self, ir.Index.index(slice));
        return v;
    }
    // A path from no var (a temporary's part, `?mk().v[..]`) keeps
    // what its start views, as a view of one does; `!mk()[..]` is a
    // write view of that temporary.
    const place = resolvePlace(self, object) orelse {
        const start = self.vars.items.len;
        var v = try walkViewedPath(self, object);
        if (kind == .write) v = try writeViewTemp(self, v, start);
        if (rig.isRangeIndex(slice)) _ = try walk(self, ir.Index.index(slice));
        return v;
    };
    try walkIndicesHeld(self, indices, place.root, place.path);
    const id = place.root;
    const pos = notes.startOf(self, slice);
    const v = (try viewVar(self, id, place.path, kind, pos)) orelse return .{};
    if (types.typeData(self, peeled) != .array or !inVarStorage(self, object)) return v;
    return .{ .loans = try self.unionLoans(v.loans, try self.oneLoan(.{ .root = id, .path = place.path, .kind = kind, .pos = pos, .frame = true })) };
}

/// A slice walked as a plain value, or a whole-array view's operand.
pub fn walkOperand(self: *Checker, slice: Sexp, object: Sexp) Error!Value {
    return walk(self, if (rig.isRangeIndex(slice)) slice else object);
}

/// Whether the value of place `e` is stored in the var the place
/// starts from, rather than behind a pointer, a handle, or a List's
/// buffer, whose own loans cover it. A read view copies only
/// scalars and views, which hold no array, so an array reached
/// through one is behind a pointer.
pub fn inVarStorage(self: *const Checker, e: Sexp) bool {
    if (types.exprType(self, e)) |ty| switch (types.typeData(self, ty)) {
        .write_view, .read_view, .shared, .slice => return false,
        else => if (types.holdsElems(self, ty)) return false,
    };
    if (e.isKind(.member) or e.isKind(.index)) return inVarStorage(self, ir.get(e, .object));
    return true;
}

/// The loans of a view of (a path inside) var `id`, by what the var
/// is (`viewTarget`).
pub fn viewOn(self: *Checker, id: VarId, loan: Loan) Error!Value {
    const held = self.flows.items[id].loans;
    const v: Value = switch (viewTarget(self, self.vars.items[id])) {
        .write_view => .{ .loans = try self.unionLoans(try self.oneLoan(throughBinding(self, id, loan)), held) },
        .read_view => .{ .loans = held },
        .owner => .{ .loans = try self.oneLoan(loan) },
    };
    return if (origins.isSelfVar(self, id)) origins.tagSelf(self, v, id, loan.path) else v;
}

/// `loan`, on var `id`, marked a loan on the binding only
/// (`Loan.deref`) when it is viewed through the write view `id` holds:
/// a local's, a pattern's, or a loop element's, whose own loans are
/// what it views (a header's view, a `for` source, a payload's
/// subject). A parameter's or a capture's view is the caller's or
/// the closure's, and a hidden var (a value a call holds, a read
/// match's arm, an API object's copy) and a frame loan are storage
/// of this function, which no view of it may outlive. Self is a
/// parameter, so no such loan is on it (`checkSelfPaths`).
pub fn throughBinding(self: *const Checker, id: VarId, loan: Loan) Loan {
    const v = self.vars.items[id];
    var out = loan;
    out.deref = !loan.frame and viewTarget(self, v) == .write_view and switch (v.kind) {
        .local, .pattern, .loop_elem => true,
        .param, .capture, .hidden => false,
    };
    return out;
}

pub const ViewTarget = enum {
    /// A loan on the var.
    owner,
    /// A loan on the var, so nothing writes through it while the view
    /// lives, and the loans it holds.
    write_view,
    /// The loans it holds, as a copy of the view carries.
    read_view,
};

/// What a view of var `v` puts a loan on, from the binding's access
/// (`SemContext.bindingAccess`, docs/internals/INTERNALS.md "Binding access"):
/// a binding a write may go through is a write view, one no write goes
/// through a read view, and any other var (one that owns or copies its
/// value, or a value no binding names) an owner.
pub fn viewTarget(self: *const Checker, v: Var) ViewTarget {
    const ctx = self.sema;
    const sym = v.sym orelse return .owner;
    const access = ctx.bindingAccess(sym) orelse return .owner;
    return switch (access) {
        .write => .write_view,
        .read => .read_view,
    };
}

/// A call whose result `v` only reads what it views has returned: the
/// write views its arguments made since `temps_start` end, as a view
/// ends at its last use (Core sentence 6), but for those
/// the call may have stored (`stored`), which last as long as before.
/// What the result keeps stays viewed, to read, for the rest of the
/// statement, as any temporary view is (Core §3).
pub fn endWriteViews(self: *Checker, temps_start: usize, stored: Value, v: Value) Error!Value {
    var i = @min(temps_start, self.temps.items.len);
    while (i < self.temps.items.len) {
        const l = self.temps.items[i];
        if (l.kind == .write and !hasLoanOn(stored.loans, l.root)) _ = self.temps.orderedRemove(i) else i += 1;
    }
    for (v.loans) |l| if (!l.ext) try live.addTemp(self, l);
    return v;
}

/// The views taken since `temps_start` to compute view `v` end,
/// but for those `v` keeps: `!it.next()` twice in one statement.
pub fn keepViewTemps(self: *Checker, temps_start: usize, v: Value) Error!Value {
    self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
    for (v.loans) |l| if (!l.ext) try live.addTemp(self, l);
    return v;
}

// -----------------------------------------------------------------------------
// Temporaries (Core section 3): a statement's hidden values
// -----------------------------------------------------------------------------

/// An owning temporary only read where it stands lives in a hidden
/// var until its statement ends; what views it views that var. One a
/// `catch` handler makes is held in the var made for it before the
/// handler's scope opened (`holdPartTemps`).
pub fn holdTemp(self: *Checker, node: Sexp, v: Value) Error!Value {
    const pos = notes.startOf(self, node);
    const id = blk: {
        if (node == .list) if (self.part_temps.fetchRemove(node.list.id)) |kv| if (isStmtTempVar(self, kv.value, pos)) {
            try self.setFlow(kv.value, .{ .loans = v.loans });
            break :blk kv.value;
        };
        const id = try self.addVar(.{ .name = notes.spanText(self, node), .decl = pos, .ty = types.exprType(self, node), .kind = .hidden, .temp_value = true }, .{ .loans = v.loans });
        try self.stmt_drops.append(self.gpa, .{ .id = id, .pos = pos });
        break :blk id;
    };
    // The temporary is in use until its consumer is done with it.
    const loan: Loan = .{ .root = id, .kind = .read, .pos = pos };
    try live.addTemp(self, loan);
    return .{ .loans = try self.oneLoan(loan) };
}

/// Make the hidden vars for the statement temporaries `part`, a
/// `catch` handler, makes (`sema.stmtTemps`), before the caller opens
/// the scope it binds the handler's name in: they are the
/// statement's, as emit declares their slots for the statement, so
/// they outlive that scope and end with the statement
/// (`dropStmtTemps`). Each is made before the state a branch starts
/// from, so a path that makes it and one that does not join.
pub fn holdPartTemps(self: *Checker, part: Sexp) Error!void {
    const ctx = self.sema;
    var temps: std.ArrayList(Sexp) = .empty;
    try sema.stmtTemps(ctx, self.arena(), part, &temps);
    for (temps.items) |node| {
        const pos = notes.startOf(self, node);
        const id = try self.addVar(.{ .name = notes.spanText(self, node), .decl = pos, .ty = types.exprType(self, node), .kind = .hidden, .temp_value = true }, .{});
        try self.stmt_drops.append(self.gpa, .{ .id = id, .pos = pos });
        try self.part_temps.put(self.gpa, node.list.id, id);
    }
}

/// Whether var `id` is still the hidden var of the statement
/// temporary at `pos`: one whose scope ended is gone, and its id may
/// name a newer var.
pub fn isStmtTempVar(self: *const Checker, id: VarId, pos: u32) bool {
    if (id >= self.vars.items.len) return false;
    const v = self.vars.items[id];
    return v.kind == .hidden and v.decl == pos;
}

/// The hidden var of the live statement temporary at `pos`, if any.
pub fn stmtTempAt(self: *const Checker, pos: u32) ?VarId {
    var i = self.stmt_drops.items.len;
    while (i > 0) {
        i -= 1;
        const d = self.stmt_drops.items[i];
        if (d.pos == pos and isStmtTempVar(self, d.id, pos)) return d.id;
    }
    return null;
}

/// Drop the temporaries statement-held since `start`: a value that
/// still views one after the statement would outlive it. One whose
/// scope already ended (a branch's) was released there.
pub fn dropStmtTemps(self: *Checker, start: usize) Error!void {
    var i = self.stmt_drops.items.len;
    while (i > start) {
        i -= 1;
        const d = self.stmt_drops.items[i];
        if (!isStmtTempVar(self, d.id, d.pos)) continue;
        if (self.isViewed(d.id)) for (0..self.flows.items.len) |holder| {
            if (holder == d.id) continue;
            var f = self.flows.items[holder];
            var reported = false;
            var kept: std.ArrayList(Loan) = .empty;
            for (f.loans) |l| {
                if (l.root != d.id) {
                    try kept.append(self.arena(), l);
                } else if (!reported and live.holdsPastDrop(self, @intCast(holder))) {
                    try notes.reportTempOutlived(self, l, @intCast(holder));
                    reported = true;
                }
            }
            if (kept.items.len == f.loans.len) continue;
            f.loans = kept.items;
            try self.setFlow(@intCast(holder), f);
        };
        try self.setFlow(d.id, .{ .status = .dropped, .at = d.pos });
    }
    self.stmt_drops.shrinkRetainingCapacity(start);
}

/// A loan in `v` on a temporary held since `stmt_drops` held
/// `drops`: one a header made, which ends with the header.
pub fn headerTempLoan(self: *const Checker, drops: usize, v: Value) ?Loan {
    for (v.loans) |l| for (self.stmt_drops.items[@min(drops, self.stmt_drops.items.len)..]) |d| {
        if (d.id == l.root) return l;
    };
    return null;
}

// -----------------------------------------------------------------------------
// Bindings and assignment (Core sections 5 and 6)
// -----------------------------------------------------------------------------

pub fn walkSet(self: *Checker, node: Sexp) Error!void {
    const kind = rig.bindingKindOf(ir.Set.op(node));
    const target = ir.Set.target(node);
    const expr = ir.Set.value(node);
    if (target != .src) {
        // The steps in the order emit evaluates them
        // (`storage.eachSetStep`): the value, the base of the target's
        // path, and its indexes from the base outward.
        const Steps = struct {
            c: *Checker,
            set: Sexp,
            placed: bool,
            value: Value = .{},
            base: ?Value = null,
            base_node: Sexp = .nil,

            pub fn step(st: *@This(), s: storage.SetStep) Error!void {
                switch (s.role) {
                    .value => {
                        const mark = try useAfterValue(st.c, st.set);
                        defer st.c.after_value.shrinkRetainingCapacity(mark);
                        st.value = try walkConsumed(st.c, s.node, .field);
                    },
                    // The base of a target that is no place (a view,
                    // `(!h).r`, or a write view a call returns,
                    // `wrap(!h).r`) runs here; a place is found at
                    // the store.
                    .base => if (!st.placed) {
                        st.base = try walk(st.c, s.node);
                        st.base_node = s.node;
                    },
                    .index => _ = try walk(st.c, s.node),
                }
            }
        };
        var steps: Steps = .{ .c = self, .set = node, .placed = resolvePlace(self, target) != null };
        // A value read where it runs (`storage.isPureArg`) is read at
        // the store, after the target's base and indexes.
        const late = self.late.items.len;
        if (self.nll and storage.isPureArg(self.sema, expr)) try live.holdLate(self, expr);
        try storage.eachSetStep(node, &steps);
        try walkFieldAssign(self, node, target, steps.value, steps.base, steps.base_node);
        return live.endLate(self, late);
    }

    const pos = target.src.pos;
    const name = types.text(self, target);
    const is_lambda = isLambda(expr);
    // A write-view local re-pointed by a view its right side does not
    // read, and cannot leave early, never uses its old view again:
    // that view's loans end here (Core sentence 6), before the right
    // side makes a view anew.
    if (kind == .default and self.sema.repoints(node)) if (self.find(target)) |id| {
        if (!readsName(self, expr, name) and !leavesEarly(expr)) try self.setFlow(id, .{ .status = self.flows.items[id].status, .at = self.flows.items[id].at });
    };
    const mark = try useAfterValue(self, node);
    const value: Value = switch (kind) {
        .default, .fixed, .shadow => if (is_lambda) blk: {
            // A closure literal makes a new binding, or is reported
            // rebinding a closure; stored into any other existing
            // slot (a `fun` local, a write view) it would escape.
            self.lambda_ok = kind != .default or (if (self.find(target)) |id| self.vars.items[id].closure else true);
            break :blk try walk(self, expr);
        } else blk: {
            const saved = self.binding;
            defer self.binding = saved;
            self.binding = .{ .name = name, .value = expr };
            const v = try walkConsumed(self, expr, .binding);
            // A binding reported for taking a held write view holds
            // nothing, so its later uses report nothing more.
            break :blk if (self.binding.?.rejected) Value{} else v;
        },
        else => try walk(self, expr),
    };
    self.after_value.shrinkRetainingCapacity(mark);
    // The target takes the value: its old value is used no more, and
    // the new one from the next use on.
    try live.markWalked(self, pos);

    if (std.mem.eql(u8, name, "_")) return;

    switch (kind) {
        .shadow => try bindNew(self, target, false, is_lambda, value),
        .fixed => try bindNew(self, target, true, is_lambda, value),
        .default => {
            if (self.find(target)) |id| {
                const repoints = self.sema.repoints(node);
                try reassign(self, id, pos, value, repoints);
                return;
            } else {
                try bindNew(self, target, false, is_lambda, value);
            }
        },
        // Compound assignment (`+=`, ...).
        else => {
            const id = self.find(target) orelse return;
            try self.clearNones(id, whole_path);
            try rules.checkReadable(self, id, null, pos);
            try rules.checkAssignable(self, id, pos);
            return;
        },
    }
    if (is_lambda) self.vars.items[self.vars.items.len - 1].env_drop_reads = envDropReads(self, expr);
}

/// An assignment is `{ __v = value; place op= __v }`: what its target
/// reads is used after its value, so it is live while the value is
/// walked (`after_value`). A name target reads its binding when the
/// store combines with it (`x op= v`) or writes through it (a `!T`
/// local given a value); a field or element target reads every name
/// in it. Returns the mark to drop them back to once the value is
/// walked.
pub fn useAfterValue(self: *Checker, node: Sexp) Error!usize {
    const mark = self.after_value.items.len;
    const ctx = self.sema;
    const target = ir.Set.target(node);
    if (target != .src) {
        try useAfterValueIn(self, target);
        return mark;
    }
    const sym = ctx.symbolOf(target) orelse return mark;
    const s = ctx.symbols.items[sym];
    if (s.decl_pos == target.src.pos) return mark;
    const kind = rig.bindingKindOf(ir.Set.op(node));
    const writes_through = kind == .default and ctx.writesThrough(node);
    if (kind.operator() != null or writes_through) try self.after_value.append(self.gpa, .{ .sym = sym, .loop = self.loop });
    return mark;
}

pub fn useAfterValueIn(self: *Checker, e: Sexp) Error!void {
    switch (e) {
        .src => if (self.sema.symbolOf(e)) |sym| try self.after_value.append(self.gpa, .{ .sym = sym, .loop = self.loop }),
        .list => for (e.items()) |c| try useAfterValueIn(self, c),
        else => {},
    }
}

/// Whether `e` names `name` anywhere.
pub fn readsName(self: *const Checker, e: Sexp, name: []const u8) bool {
    switch (e) {
        .src => return std.mem.eql(u8, types.text(self, e), name),
        .list => {
            for (e.items()) |item| if (readsName(self, item, name)) return true;
            return false;
        },
        else => return false,
    }
}

/// Whether evaluating `e` may leave before it gives its value: a
/// propagation, a `return`, a `break`, a `continue`, or a `panic`
/// inside it.
pub fn leavesEarly(e: Sexp) bool {
    if (e != .list) return false;
    if (rig.leavesBody(e) or rig.leaves(e)) return true;
    for (e.items()) |item| if (leavesEarly(item)) return true;
    return false;
}

/// Whether dropping the environment of closure literal `lambda` may
/// run a `drop` body (`sema.dropRunsBody`).
pub fn envDropReads(self: *const Checker, lambda: Sexp) bool {
    const ctx = self.sema;
    for (sema.captureList(ir.Lambda.captures(lambda))) |cap| {
        const ty = types.symType(self, sema.captureNameNode(cap).?.src.pos) orelse return true;
        if (sema.dropRunsBody(ctx, ty) != .no) return true;
    }
    return false;
}

/// A new binding named by `node`, holding `value`.
pub fn bindNew(self: *Checker, node: Sexp, fixed: bool, closure: bool, value: Value) Error!void {
    const pos = node.src.pos;
    const ty = types.symType(self, pos);
    // A read binding whose type is no view, a type parameter's value
    // reached through a read view (`sema.decideBindingAccess`), is
    // its bytes where they stand: it keeps what it was bound from
    // viewed, and is taken only as a copy, as a `for` element is.
    const sym: ?SymbolId = self.sema.symbolAt(pos);
    const in_place = !closure and !types.isView(self, ty) and viewTarget(self, .{ .name = "", .decl = pos, .sym = sym }) == .read_view;
    _ = try self.addVar(.{
        .name = types.text(self, node),
        .decl = pos,
        .ty = ty,
        .ref = types.refOfType(self, ty),
        .fixed = fixed or closure,
        .closure = closure,
        .as_view = in_place,
    }, .{ .loans = if (closure or in_place) value.loans else if (types.mayCarryLoan(self, ty)) (try origins.carry(self, ty, value)).loans else generic.taintedNone(self, ty, value) });
}

/// `x = value`. A `!T` local given a view (`repoints`) points at
/// another place, as any binding takes a new value: the loans it held
/// end, and it holds the view's.
pub fn reassign(self: *Checker, id: VarId, pos: u32, value: Value, repoints: bool) Error!void {
    try self.clearNones(id, whole_path);
    const before = self.diagnostics.items.len;
    try rules.checkAssignable(self, id, pos);
    if (self.diagnostics.items.len != before and self.quiet == 0) return;
    const v = self.vars.items[id];
    if (v.kind == .capture and v.ref == .write) {
        // Assigning a captured write view writes into the value it
        // views.
        return storeThroughCapture(self, v, pos, value);
    }
    if (v.closure or v.fixed or v.loop_view or v.capture_resource) return;
    if (self.isGlobal(id) and !types.copies(self, v.ty)) return;
    if (self.findLoan(id, whole_path, .any, null) != null) return;
    if (v.ref == .write and !repoints) {
        // Assigning a write view writes into the value it views:
        // it still views it. Through a `!T` parameter (or a loop or
        // pattern binding) the new value may only carry views the
        // caller handed in; through a local, it lands in what the
        // local views, which then holds them.
        if (!try rules.checkLive(self, id, pos)) return;
        if (writesThroughLocal(self, id)) return storeThroughLocal(self, id, pos, value, 1);
        for (value.loans) |l| if (origins.isLocalLoan(self, l)) {
            const stored = self.vars.items[l.root].name;
            if (v.kind != .param) if (viewedRoot(self, id)) |root| {
                try notes.err(self, pos, "cannot store a view of `{s}` through `{s}`: `{s}` views `{s}`, which outlives it", .{ stored, v.name, v.name, self.vars.items[root].name });
                return;
            };
            try notes.err(self, pos, "cannot store a view of `{s}` through `{s}`: what `{s}` views outlives it", .{ stored, v.name, v.name });
            return;
        };
        return storeInViewed(self, id, pos, value, 1);
    }
    // The old value is dropped (if still owned) and the binding is
    // live again with the new value.
    try self.setFlow(id, .{ .loans = if (types.mayCarryLoan(self, v.ty)) (try origins.carry(self, v.ty, value)).loans else generic.taintedNone(self, v.ty, value) });
}

/// Whether storing `value` in a place of type `ty` may store a loan:
/// it carries one and the place may hold a view, or the place's type
/// mentions a type parameter (`noteGenericStore`).
pub fn storesLoans(self: *const Checker, ty: ?TypeId, value: Value) bool {
    if (generic.holdsGeneric(self, ty)) return true;
    return value.loans.len > 0 and types.mayCarryLoan(self, ty);
}

/// The var a view held by var `id` views, when it holds one of
/// a var of this function.
pub fn viewedRoot(self: *const Checker, id: VarId) ?VarId {
    if (self.vars.items[id].ref == .none) return null;
    for (self.flows.items[id].loans) |l| if (!l.ext and l.root != id) return l.root;
    return null;
}

/// Var `id` is a local write view of a var of this function (a
/// `match !x` binding views `x` as one does): a store through it
/// lands in what it views.
pub fn writesThroughLocal(self: *const Checker, id: VarId) bool {
    const v = self.vars.items[id];
    if (v.ref != .write or !(v.kind == .local or (v.kind == .pattern and v.alias_of != null))) return false;
    return viewedRoot(self, id) != null;
}

/// `w = e` through local write view `id`: `e` is stored in what
/// `w` views. A view parameter or module-level binding reached
/// that way outlives this function's values.
pub fn storeThroughLocal(self: *Checker, id: VarId, pos: u32, value: Value, depth: u32) Error!void {
    const held = live.varValue(self, id);
    for (held.loans) |w| {
        if (w.kind != .write) continue;
        const r = self.vars.items[w.root];
        if (!w.ext and !origins.callerOwns(self, w.root) and !self.isGlobal(w.root)) continue;
        for (value.loans) |l| if (origins.isLocalLoan(self, l)) {
            try notes.err(self, pos, "cannot store a view of `{s}` through `{s}`: `{s}` outlives it", .{ self.vars.items[l.root].name, self.vars.items[id].name, r.name });
            return;
        };
    }
    try origins.absorbThroughWrites(self, held, value, pos, self.vars.items[id].name, depth);
}

/// The store of `value` into `target`, once its steps have run
/// (`walkSet`); `base` is what a base that is no place, `base_node`,
/// gave.
pub fn walkFieldAssign(self: *Checker, set: Sexp, target: Sexp, value: Value, base: ?Value, base_node: Sexp) Error!void {
    const place = resolvePlace(self, target) orelse {
        // A target whose path starts from a value no var holds is
        // reached through that value's write loans: what is stored
        // there lands in what they reach.
        const through = base orelse Value{};
        // An element of a Cell's List, marked `(!c)[i] = v`, is stored
        // in the Cell as one a name reaches is.
        if (inCellList(self, target)) return storeInCellList(self, target, value);
        if (!storesLoans(self, types.exprType(self, target), value)) return;
        return storeThroughView(self, through, value, notes.startOf(self, target), if (base_node == .nil) null else notes.spanText(self, base_node));
    };
    const id = place.root;
    const pos = notes.startOf(self, target);
    try noteOldNone(self, set, place);
    if (!try fillParts(self, id, place, pos)) return;
    const v = self.vars.items[id];
    if (self.findLoan(id, place.path, .any, null)) |l| {
        const shown = try notes.placeText(self, target);
        const viewed = try notes.pathText(self, l.root, l.path);
        const of = if (std.mem.eql(u8, shown, viewed)) "it" else try self.arena().print("`{s}`", .{viewed});
        try notes.err(self, pos, "cannot assign to `{s}` while a {s} view of {s} is still in use", .{ shown, notes.viewWord(self, l), of });
        try notes.noteLoan(self, l);
        try notes.noteStillUsed(self, l, pos);
        return;
    }
    // An element of a Cell's List, or a field of one, is stored in
    // the Cell, which every handle to it reaches: it may hold no loan.
    if (inCellList(self, target)) return storeInCellList(self, target, value);
    if (!storesLoans(self, types.exprType(self, target), value)) return;
    // A value never holds a view of itself (Core §5): a part of `id`
    // may not take a loan on a part of `id`.
    if (try origins.selfViewIn(self, id, value.loans, &.{}, &.{})) |l| {
        try notes.err(self, pos, "cannot store in `{s}` a view of `{s}`: a value never holds a view of itself", .{ try notes.placeText(self, target), try notes.pathText(self, l.root, l.path) });
        return notes.noteLoan(self, l);
    }
    if (v.kind == .capture and !place.through_shared) return storeThroughCapture(self, v, pos, value);
    if (!place.through_shared and writesThroughLocal(self, id)) return storeThroughLocal(self, id, pos, value, origins.placeDepth(self, target, false));
    if (v.ref != .none or place.through_view or place.through_shared or self.isGlobal(id)) {
        // Stored into something the caller owns: only views the
        // caller handed in may go there.
        for (value.loans) |l| if (origins.isLocalLoan(self, l) or self.isGlobal(id)) {
            const stored = self.vars.items[l.root].name;
            const into = try notes.placeText(self, target);
            // A local view: what outlives it is what `v` views.
            if (v.kind != .param) if (viewedRoot(self, id)) |root| {
                try notes.err(self, pos, "cannot store a view of `{s}` in `{s}`: `{s}` views `{s}`, which outlives it", .{ stored, into, v.name, self.vars.items[root].name });
                return;
            };
            try notes.err(self, pos, "cannot store a view of `{s}` in `{s}`: `{s}` outlives it", .{ stored, into, v.name });
            return notes.noteStringViewOfString(self, l, types.exprType(self, target));
        };
        return storeInViewed(self, id, pos, value, origins.placeDepth(self, target, false));
    }
    var f = self.flows.items[id];
    f.loans = try self.unionLoans(f.loans, value.loans);
    try self.setFlow(id, f);
}

/// Assignment `set` stores into `place`: whether the field holds
/// `none` there is recorded, and false on any walk is final
/// (`old_nones`). After the store it holds a value.
pub fn noteOldNone(self: *Checker, set: Sexp, place: Place) Error!void {
    if (set == .list and set.list.id != 0 and self.reachable) {
        const none = place.path != whole_path and self.noneAt(place.root, place.path);
        const gop = try self.old_nones.getOrPut(self.gpa, set.list.id);
        if (!gop.found_existing) gop.value_ptr.* = .{ .set = set, .none = none } else gop.value_ptr.none = gop.value_ptr.none and none;
    }
    try self.clearNones(place.root, place.path);
}

/// `p.f = x` of a live `p` (Core §5): a field moved out at `p.f`, or
/// below it, is usable again, and drops nothing until then (emit
/// drops the old value behind its flag). A store below a field moved
/// out, or into a moved var, is reported. Returns whether the store
/// goes on.
pub fn fillParts(self: *Checker, id: VarId, place: Place, pos: u32) Error!bool {
    if (self.defer_floor) |floor| try rules.checkDeferredReach(self, id, floor, pos);
    if (!self.flowLive(id)) return rules.checkLive(self, id, pos);
    const f = self.flows.items[id];
    if (f.parts.len == 0) return true;
    var kept: std.ArrayList(Part) = .empty;
    for (f.parts) |part| {
        if (place.path != whole_path and !place.path_ended and self.paths.within(part.path, place.path)) continue;
        if (self.paths.overlap(part.path, place.path)) {
            const moved = try notes.pathText(self, id, part.path);
            try notes.err(self, pos, "cannot assign to `{s}`: `{s}` was moved out; assign `{s}` whole first", .{ try notes.pathText(self, id, place.path), moved, moved });
            try notes.note(self, part.at, "`{s}` was moved here", .{moved});
            return false;
        }
        try kept.append(self.arena(), part);
    }
    if (kept.items.len == f.parts.len) return true;
    if (self.in_defer) {
        try notes.err(self, pos, "a `defer` body cannot assign `{s}`, a field moved out of `{s}`; it runs when the scope exits", .{ try notes.pathText(self, id, place.path), self.vars.items[id].name });
        return false;
    }
    var nf = f;
    nf.parts = kept.items;
    try self.setFlow(id, nf);
    return true;
}

/// `stored` is stored through the write view `viewed`, whatever the
/// syntax that reaches it: a write self (`wrap(!h).keep(v)`,
/// `(!a if c else !b).keep(v)`), or an assignment's target that no
/// var holds (`(!h).r = v`, `wrap(!h).r = v`). Whatever its write
/// loans reach holds `stored`'s loans from here on. `via` names
/// the write view an assignment stores through; a call has none.
pub fn storeThroughView(self: *Checker, viewed: Value, stored: Value, pos: u32, via: ?[]const u8) Error!void {
    try origins.absorbThroughWrites(self, viewed, stored, pos, via, null);
}

/// `value`, which carries only loans the caller handed in, was stored
/// into what var `id` reaches through a view: a parameter's value,
/// or the value a loop or pattern binding writes through. Whatever
/// holds the stored value now holds its loans: a parameter, as any
/// var does (`absorbLoans`), and a binding's write loans lead to it
/// within `depth` steps (`absorbThroughWrites`).
pub fn storeInViewed(self: *Checker, id: VarId, pos: u32, value: Value, depth: u32) Error!void {
    const v = self.vars.items[id];
    if (v.kind == .param) return origins.absorbLoans(self, id, value, pos, &.{}, v.name, false, &.{});
    return origins.absorbThroughWrites(self, live.varValue(self, id), value, pos, v.name, depth);
}

/// Store `value` into `target`, reached through capture `v` of the
/// closure being checked. The captured value outlives every call of
/// the closure, while its parameters and its own values (its locals,
/// and what it moved or copied into its environment) live for one
/// call at most: a loan on any of them is rejected. A loan the
/// closure captured is on a value outside it, and the closure's
/// creation already let the captured value hold it (`walkLambda`).
pub fn storeThroughCapture(self: *Checker, v: Var, pos: u32, value: Value) Error!void {
    for (value.loans) |l| if (l.root >= self.func.closure_base) {
        try notes.err(self, pos, "cannot store a view of `{s}` through captured `{s}`: `{s}` outlives every call of the closure, and the closure's parameters and own values last one call at most", .{ self.vars.items[l.root].name, v.name, v.name });
        return;
    };
}

// -----------------------------------------------------------------------------
// Sentence 7: a call passes on only the views its signature shows
// -----------------------------------------------------------------------------

/// A call. What it holds in storage of its own lives only while it
/// runs (`holdForCall`), so a view of that ends with it.
pub fn walkCall(self: *Checker, node: Sexp) Error!Value {
    const mark = self.call_held.items.len;
    const once_mark = self.once_uses.items.len;
    const used = try rules.onceUses(self, node);
    const late = self.late.items.len;
    try live.holdLateParts(self, node, ir.Call.args(node));
    const v = try walkCallBody(self, node);
    try live.endLate(self, late);
    self.once_uses.shrinkRetainingCapacity(once_mark);
    // A `once` parameter called, or passed to another, is used up.
    for (used) |u| if (self.flowLive(u.id)) try self.markInvalid(u.id, .moved, u.pos);
    const out = try endCallHeld(self, node, mark, v);
    // Each result keeps only what the call's value still carries.
    if (self.results_of) |r| if (sameNode(r.node, node) and out.loans.len != v.loans.len) {
        const parts = try self.arena().alloc(Value, r.parts.len);
        for (r.parts, parts) |part, *kept| {
            var loans: std.ArrayList(Loan) = .empty;
            for (part.loans) |l| if (containsLoan(out.loans, l)) try loans.append(self.arena(), l);
            kept.* = .{ .loans = loans.items };
        }
        self.results_of = .{ .node = node, .parts = parts };
    };
    return out;
}

/// Hold `v`, the value of `node`, which the emitted call keeps in
/// storage of its own (`storage.Var` of life `call`: a self, or
/// a copied argument), in a hidden var the call views (`kind`), so
/// a view of it is a view of that storage.
pub fn holdForCall(self: *Checker, node: Sexp, v: Value, kind: LoanKind) Error!Value {
    const pos = notes.startOf(self, node);
    const id = try self.addVar(.{ .name = notes.spanText(self, node), .decl = pos, .ty = types.exprType(self, node), .kind = .hidden, .call_held = true }, .{ .loans = v.loans });
    try self.call_held.append(self.gpa, id);
    return .{ .loans = try self.oneLoan(.{ .root = id, .kind = kind, .pos = pos }) };
}

/// The node a call holds in storage of its own that lives only while
/// it runs, and that it views (a copy, or a value the storage owns),
/// when the storage facts record one of `kind` for it: a self
/// without its view sigils, an argument as written.
pub fn heldForCall(self: *const Checker, e: Sexp, kind: storage.StorageKind) ?Sexp {
    const ctx = self.sema;
    const node = if (kind == .self) storage.viewedPlace(e) else e;
    const s = ctx.varOf(node, kind) orelse return null;
    if (s.life != .call or s.by == .pointer) return null;
    // An owned argument is the callee's own value, not a view of it.
    if (kind == .argument and s.by != .copy) return null;
    return node;
}

/// The storage of the call `node` held since `mark` ends as it
/// returns `v`: the result, unless the statement discards it, and
/// every var the call stored a view of it in, may not keep one.
pub fn endCallHeld(self: *Checker, node: Sexp, mark: usize, v: Value) Error!Value {
    var out = v;
    var i = self.call_held.items.len;
    while (i > mark) {
        i -= 1;
        const id = self.call_held.items[i];
        if (self.reachable) {
            // Only a value nothing uses (an expression statement's,
            // `sema.discardsValue`) may keep no loan without a report.
            const discarded = self.sema.discardsValue(node);
            if (!discarded) for (out.loans) |l| if (l.root == id) {
                try notes.reportCallHeld(self, l, null);
                break;
            };
        }
        var kept: std.ArrayList(Loan) = .empty;
        for (out.loans) |l| if (l.root != id) try kept.append(self.arena(), l);
        out.loans = kept.items;
        if (self.isViewed(id)) for (0..self.flows.items.len) |holder| {
            if (holder == id) continue;
            var f = self.flows.items[holder];
            if (!hasLoanOn(f.loans, id)) continue;
            if (self.reachable and live.holderLive(self, @intCast(holder), null)) for (f.loans) |l| if (l.root == id) {
                try notes.reportCallHeld(self, l, @intCast(holder));
                break;
            };
            var left: std.ArrayList(Loan) = .empty;
            for (f.loans) |l| if (l.root != id) try left.append(self.arena(), l);
            f.loans = left.items;
            try self.setFlow(@intCast(holder), f);
        };
        var t: usize = 0;
        while (t < self.temps.items.len) {
            if (self.temps.items[t].root == id) _ = self.temps.orderedRemove(t) else t += 1;
        }
        try self.setFlow(id, .{ .status = .dropped, .at = notes.startOf(self, node) });
    }
    self.call_held.shrinkRetainingCapacity(mark);
    return out;
}

pub fn walkCallBody(self: *Checker, node: Sexp) Error!Value {
    const temps_start = self.temps.items.len;
    // Compile-time arguments (`f[3](x)`) are constants: no effect.
    const callee = self.sema.calleeOf(node);
    const args = ir.Call.args(node);
    if (self.sema.swapCallOf(node)) |swap| if (args.len == 2) return walkSwapCall(self, args, swap == .places);
    // The value the call calls (a closure's captures, what a callable
    // view views), which its result always carries, and its
    // self's value.
    var result: Value = .{};
    var recv_value: Value = .{};
    // What self holds, before the call views it: what a
    // result through a path of self carries (`selfPathsResult`).
    var recv_held: Value = .{};
    // A function a field holds is called, which reaches nothing of
    // the value holding it.
    var field_call = false;

    // Method call: self is viewed for the whole call. A
    // write self is reserved (read) while the arguments are
    // evaluated and must be otherwise unviewed when the call starts.
    var recv_root: ?VarId = null;
    // The place of `recv_root` self is (`resolvePlace`).
    var recv_path: PathId = whole_path;
    var recv_mode: sema.SelfMode = .read;
    var reservation: usize = 0;
    // What the call reads in place before its arguments run (the value
    // it calls, or a self that is no place) is copied there, so it
    // is held until the call runs (`holdRead`).
    const callee_found = self.errors_found;
    // An actor's call and a select's arm keep no loan in their result:
    // the actor holds a count of its own, and a select ends its arms.
    const actor_call = self.sema.isActorCall(node) or self.sema.selectArmOf(node) != null;
    // What the call puts on the place self is: a read loan, a write
    // loan where `!` makes a write view (`loanOf`).
    var recv_loan: LoanKind = .read;
    if (callee.isKind(.member) and !actor_call and generic.callsFunctionField(self, node, callee)) {
        // A function held in a field is called with the arguments
        // alone; it reaches nothing of the value holding it.
        result = try walk(self, ir.Member.object(callee));
        field_call = true;
        if (self.errors_found == callee_found) try holdRead(self, callee, .callee);
    } else if (callee.isKind(.member)) {
        var obj = ir.Member.object(callee);
        var explicit_write = false;
        if (obj.isKind(.write) or obj.isKind(.read)) {
            explicit_write = obj.isKind(.write);
            obj = ir.get(obj, .operand);
        }
        recv_mode = if (explicit_write) .write else types.selfMode(self, obj, callee);
        recv_loan = if (explicit_write) loanOf(self, ir.Member.object(callee)) else if (recv_mode == .write) .write else .read;
        const place = if (recv_mode == .value) null else resolvePlace(self, obj);
        if (place) |p| {
            const found = self.errors_found;
            // Self is passed by address: its indices are held
            // as a viewed place's are.
            const mark = self.temps.items.len;
            try live.addTemp(self, .{ .root = p.root, .path = p.path, .kind = .read, .pos = notes.startOf(self, obj), .place_hold = true });
            const recv_val = try walk(self, obj);
            if (mark < self.temps.items.len and self.temps.items[mark].place_hold) _ = self.temps.orderedRemove(mark);
            const id = p.root;
            // A self already reported (used while a write loan is live)
            // is not reported again as a conflicting write view.
            if (self.flowLive(id) and !types.isScalar(self, self.vars.items[id].ty) and self.errors_found == found) {
                const pos = notes.startOf(self, obj);
                reservation = self.temps.items.len;
                try live.addTemp(self, .{ .root = id, .path = p.path, .kind = .read, .pos = pos, .reserved = recv_loan == .write });
                recv_root = id;
                recv_path = p.path;
                // A built-in's methods hand out values, never views
                // of self.
                const kind = recv_loan;
                recv_held = recv_val;
                recv_value = if (actor_call or types.builtinName(self, types.exprType(self, obj)) != null) recv_val else try self.valueUnion(recv_val, try viewOn(self, id, .{ .root = id, .path = p.path, .kind = kind, .pos = pos }));
            }
        } else if (recv_mode == .value) {
            // A consuming self is taken like an argument: a name
            // it yields through a branch is moved with `<`.
            recv_value = try walkConsumed(self, ir.Member.object(callee), .argument);
        } else {
            recv_value = try walk(self, ir.Member.object(callee));
            recv_held = recv_value;
            if (self.errors_found == callee_found) try holdRead(self, ir.Member.object(callee), .self);
            // A built-in's methods hand out values, never views of
            // self.
            if ((recv_mode == .read or recv_mode == .write) and !actor_call and !rules.namesType(self, callee) and types.builtinName(self, types.exprType(self, obj)) == null) {
                const kind = recv_loan;
                // A self the call holds in storage of its own is
                // viewed from there; any other is viewed where its
                // leaves are.
                recv_value = if (heldForCall(self, obj, .self)) |held|
                    try holdForCall(self, held, recv_value, kind)
                else
                    try self.valueUnion(recv_value, try selfLeaves(self, obj, kind));
            }
        }
    } else if (callee == .src) {
        // A callable's result may view what the callable holds: a
        // closure its captures, a callable view what it views.
        result = try walkName(self, callee, true);
        if (self.errors_found == callee_found) try holdRead(self, callee, .callee);
    } else if (isLambda(callee)) {
        self.lambda_ok = true;
        result = try walk(self, callee);
    } else {
        result = try walk(self, callee);
        if (self.errors_found == callee_found) try holdRead(self, callee, .callee);
    }

    // A call of a function value whose type names a type parameter:
    // what the value may keep of a view of memory the body owns, put
    // in a value of a type parameter's type, each instance answers
    // (`requireCallable`).
    const value_ty = try generic.calledValueType(self, node, callee, field_call);
    if (callee.isKind(.member) and !field_call) try generic.noteMethodCall(self, node, callee);

    // `print`, `String(...)`, and `!t.add(...)` only read their
    // arguments, and hold none of them past the call: a String keeps
    // their text, not them.
    const text_op = self.sema.stringCallOf(node) orelse self.sema.stringCallOf(callee);
    if (storage.isPrintCall(self.sema, node) or text_op != null) {
        try walkReadArgs(self, args);
        if (recv_root) |id| if (recv_loan == .write) {
            const reserved = self.temps.orderedRemove(reservation);
            const at = notes.startOf(self, ir.Member.object(callee));
            if (try rules.conflictingLoan(self, id, recv_path, .write, at)) |l| try notes.noteWholeSelf(self, id, recv_path, l, callee, at);
            try self.temps.insert(self.gpa, reservation, reserved);
        };
        self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
        return .{};
    }
    // Every handle to a Cell, Signal, or channel reaches what it
    // holds, so what goes in (`Cell(v)`, `set`, `swap`, `subscribe`,
    // `send`) may not hold a view. Of an arm of `task.select`, a send
    // arm's value goes into its channel as `send`'s does, and its
    // function and a receive arm's go to the select, which calls them.
    const arm = self.sema.selectArmOf(node);
    const into = if (arm != null and arm.? != .send)
        null
    else if (callee.isKind(.member) and !rules.namesType(self, callee))
        types.builtinName(self, types.exprType(self, ir.Member.object(callee)))
    else if (rules.namesType(self, callee)) types.builtinName(self, types.exprType(self, node)) else null;
    const cell: ?[]const u8 = if (into != null and !std.mem.eql(u8, into.?, "List")) into else null;
    // `!xs.extend(?s)` copies `s`'s elements and keeps no loan of
    // them: in a generic body, each instance's hold no view.
    const extends = into != null and std.mem.eql(u8, into.?, "List") and callee.isKind(.member) and std.mem.eql(u8, types.text(self, ir.Member.name(callee)), "extend");
    // A channel's values and an actor's value hold no view (SPEC
    // "Channels", "Actors"): one made in a generic body asks each
    // instance for a type that holds none.
    if (self.sema.isChanMake(node)) try generic.requireNoView(self, notes.startOf(self, node), types.exprType(self, node), .channel_made);
    if (self.sema.isActorMake(node) or self.sema.isActorSupervised(node)) try generic.requireNoView(self, notes.startOf(self, node), types.exprType(self, node), .actor_made);
    // A consuming self is passed like an argument.
    const consumed_recv = if (recv_mode == .value and callee.isKind(.member)) recv_value else Value{};
    // Which arguments the call passes loans on from (Core sentence
    // 7): the callee's origins, by the parameter each argument fills.
    const params = self.sema.callParamsOf(node);
    // A value of the associated type a walk as an instance judges
    // carries what the call is passed, whatever the callee's origins
    // say of a type parameter (`walkItemInstances`).
    const carry_all = generic.holdsItem(self, types.exprType(self, node));
    try generic.noteItems(self, types.exprType(self, node));
    // What the result carries of self and arguments.
    var from_args: Value = .{};
    if (params == null or carry_all or params.?.resultCarriesSelf()) {
        // A `from` that names paths of self narrows what the result
        // carries of self (Core sentence 7).
        const paths = if (params) |p| p.origins.self_paths else &.{};
        const recv_part = if (paths.len > 0 and callee.isKind(.member) and recv_mode != .value and !actor_call and !field_call)
            try origins.selfPathsResult(self, paths, recv_root, recv_path, recv_loan, notes.startOf(self, ir.Member.object(callee)), recv_held, recv_value)
        else
            recv_value;
        result = try self.valueUnion(result, recv_part);
        from_args = recv_value;
    }
    const arg_values = try self.arena().alloc(Value, args.len);
    // What the call may store, and what its result carries. A method
    // may store a view of what its self holds, or is, in what it
    // was given a write view of (`h.r = ?@items[..]`).
    var stored: Value = if (params == null or params.?.storesSelf()) recv_value else .{};
    // Whether it may store a value of a type parameter's type, which
    // carries no loan in a generic body (`noteGenericStore`).
    var stores_generic = (params == null or params.?.storesSelf()) and callee.isKind(.member) and generic.holdsGeneric(self, types.pointee(self, types.exprType(self, unsigiled(ir.Member.object(callee)))));
    var carried: Value = .{};
    // A closure literal passed to a call the type checker rejected
    // was reported there.
    const saved_rejected = self.in_rejected_call;
    defer self.in_rejected_call = saved_rejected;
    const saved_call = self.arg_call;
    defer self.arg_call = saved_call;
    self.arg_call = node;
    for (args, arg_values, 0..) |a, *v, i| {
        self.in_rejected_call = types.rejected(self, node);
        const found = self.errors_found;
        v.* = try walkConsumed(self, a, .argument);
        if (self.errors_found == found) try holdRead(self, a, .argument);
        // An argument the call copies into storage of its own is viewed
        // from the copy.
        if (heldForCall(self, storage.argValue(a), .argument)) |held| v.* = try holdForCall(self, held, v.*, .read);
        // A value handed over that carries a write loan (a write view
        // a method's result keeps of its self) keeps its root under
        // a write view until the call returns, as a write view in the
        // argument does (Core sentence 5): a later argument may not
        // view, read, or move it.
        for (v.loans) |l| if (l.kind == .write and !l.ext and !containsLoan(self.temps.items[@min(temps_start, self.temps.items.len)..], l)) try live.addTemp(self, l);
        // A generic body's `T` holds no loan here, but an instance's
        // may be a `?String` viewing a String.
        // A send arm stores its value, its first argument, alone.
        if (extends and i == 0) try generic.requireNoView(self, notes.startOf(self, a), types.exprType(self, a), .list_extend);
        const stores_arg = cell != null and (arm == null or i == 0);
        if (stores_arg) try generic.requireNoView(self, notes.startOf(self, a), types.exprType(self, if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a), if (std.mem.eql(u8, cell.?, "Chan")) .channel else if (std.mem.eql(u8, cell.?, "Signal")) .signal else .cell);
        if (stores_arg and v.loans.len > 0 and !types.rejected(self, if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a)) {
            const held = v.*;
            v.* = .{};
            if (origins.readsPlainValue(self, a)) continue;
            // A view of a `?String` stores the `?String` it reaches: what
            // it views, not the view.
            const arg_ty = types.exprType(self, if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a);
            const loans = (try origins.carry(self, types.reachedType(self, arg_ty), held)).loans;
            if (loans.len == 0) continue;
            try notes.errAt(self, a, "cannot store a view of `{s}` in a `{s}`: every handle to it could reach the view; a value stored in a Cell or Signal may not hold one{s}", .{ self.vars.items[loans[0].root].name, cell.?, staticParamHint(loans[0]) });
            continue;
        }
        if (!origins.keepsCallable(self, node, a)) continue;
        // `!dst.copy(src)` stores copies of the elements `src` views,
        // which carry what those elements carry, not `src`'s loan
        // on what holds them (Core sentence 7).
        if (params == null or params.?.stores(i)) {
            stored = try self.valueUnion(stored, if (origins.copiedElem(self, callee)) |elem| try origins.carry(self, elem, v.*) else v.*);
            if (generic.holdsGeneric(self, types.exprType(self, if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a))) stores_generic = true;
        }
        if (params == null or carry_all or params.?.resultCarries(i)) carried = try self.valueUnion(carried, v.*);
    }
    result = try self.valueUnion(result, carried);
    from_args = try self.valueUnion(from_args, carried);
    // A table's `update` and `retain` give views of their own entries
    // to the function value they are given (`Field.views_entries`).
    if (callee.isKind(.member) and !field_call and generic.viewsEntries(self, callee)) for (args) |a| {
        const t = types.exprType(self, if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a) orelse continue;
        const ctx = self.sema;
        if (sema.calledFn(ctx, t) != null) try generic.requireCallable(self, notes.startOf(self, node), t, false);
    };
    // What the call keeps by its callee's `keeps`, for a conflict's note.
    if (params) |p| if (p.origins.stores & p.origins.viewed != 0) {
        const write_recv = if (recv_loan == .write) recv_root else null;
        if (p.keepsViewedSelf()) try notes.noteKept(self, callee, recv_value, "@", write_recv, arg_values);
        for (arg_values, 0..) |v, i| if (p.keepsViewed(i)) try notes.noteKept(self, callee, v, p.paramName(i) orelse "?", write_recv, arg_values);
    };

    // A write self is viewed when the call starts, before the
    // callee stores anything.
    if (recv_root) |id| if (recv_loan == .write) {
        // The reservation itself is no conflict.
        const reserved = self.temps.orderedRemove(reservation);
        const at = notes.startOf(self, ir.Member.object(callee));
        if (try rules.conflictingLoan(self, id, recv_path, .write, at)) |l| try notes.noteWholeSelf(self, id, recv_path, l, callee, at);
        try self.temps.insert(self.gpa, reservation, reserved);
    };

    // The callee may store what its arguments view into anything it
    // can mutate: self, and whatever the write views passed
    // to it lead to (`!x`, a write view passed on or moved in, a
    // value holding one). A built-in element method (`!dst.fill(v)`,
    // `!dst.copy(src)`) stores elements, which hold a view only where
    // the element type does (`storesNothing`).
    const saved_api = self.api_call;
    defer self.api_call = saved_api;
    self.api_call = if (self.sema.dispatchOf(node)) |d| d.viaApi() else false;
    if ((stored.loans.len > 0 or stores_generic) and !origins.storesNothing(self, callee)) {
        // A read view of self is never written through (Core sentence 9:
        // what changes through one is a Cell, which holds no loan). A
        // write view of self holds what the call stores, whatever
        // its form: what its write view reaches, a place's var, or the
        // write loans its value carries (a write view a call returns,
        // each branch of a branching self, a value the call holds).
        if (recv_mode == .write and callee.isKind(.member)) {
            const obj = ir.Member.object(callee);
            // What self is, not the view of it.
            if (generic.mayHoldInInstance(self, types.pointee(self, types.exprType(self, obj)))) {
                const pos = notes.startOf(self, obj);
                const viewed: Value = if (recv_root) |id| .{ .loans = try self.oneLoan(.{ .root = id, .path = recv_path, .kind = .write, .pos = pos }) } else recv_value;
                try storeThroughView(self, viewed, stored, pos, null);
            }
        }
        // Only a value that can write leads a store: a write view, or a
        // value holding a write view. A read view that carries the
        // write loans of what reached it (a parameter's own, a write
        // view's) writes nothing.
        if (callee.isKind(.member) and types.mayWrite(self, types.exprType(self, ir.Member.object(callee)))) try origins.absorbThroughWrites(self, consumed_recv, stored, notes.startOf(self, callee), null, null);
        // The loans of the function values the call is passed are
        // theirs, not views it is given (`heldStore`).
        var passed_fns: Value = .{};
        if (value_ty != null) for (args, arg_values) |a, v| {
            const t = types.exprType(self, if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a) orelse continue;
            const ctx = self.sema;
            if (sema.calledFn(ctx, t) != null) {
                passed_fns = try self.valueUnion(passed_fns, v);
            }
        };
        for (args, arg_values) |a, v| {
            if (!types.mayWrite(self, types.exprType(self, if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a))) continue;
            const saved_held = self.held_store;
            defer self.held_store = saved_held;
            self.held_store = if (value_ty) |t| .{ .callable = t, .pos = notes.startOf(self, node), .own = (try self.valueUnion(v, passed_fns)).loans } else null;
            try origins.absorbThroughWrites(self, v, stored, notes.startOf(self, a), null, null);
        }
    }

    // The views passed to the call end when it returns, unless its
    // result can carry them.
    if (!types.mayCarryLoan(self, types.exprType(self, node))) {
        // A function value's result, held as a value of a type
        // parameter's type, given a view of memory the body owns: each
        // instance's must hold no view, the value's own or the
        // argument's, so what the value holds is not kept here.
        if (value_ty) |t| if (generic.genericType(self, types.exprType(self, node)) and types.viewsOwned(self, carried)) {
            try generic.requireCallable(self, notes.startOf(self, node), t, true);
            generic.taintGeneric(self, types.exprType(self, node), carried);
            self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
            return .{};
        };
        generic.taintGeneric(self, types.exprType(self, node), if (field_call) from_args else result);
        // An arm of `task.select` views until the select returns,
        // which runs the arm it commits after making every arm (the
        // arm's storage lives for the select): the select ends them.
        if (self.sema.selectArmOf(node) == null) self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
        return .{};
    }
    // The result views only what could hold it (Core sentence 7). A
    // `?String`'s views end here but for those it keeps.
    const ty = types.exprType(self, node) orelse return result;
    const ctx = self.sema;
    if (sema.resultsOf(ctx, ty)) |tys| return callResults(self, node, temps_start, stored, result, tys);
    if (sema.holdsViewOnly(ctx, ty)) return keepViewTemps(self, temps_start, try origins.carryResult(self, ty, result));
    // A task, `f(x)&`, is its call, still running (`carryAs`).
    const kept = if (ir.Call.task(node) != .nil) try origins.carry(self, ty, result) else try origins.carryResult(self, ty, result);
    if (origins.viewsOnlyRead(self, ty)) return endWriteViews(self, temps_start, stored, kept);
    return kept;
}

/// A call that gives several results, `-> (A, B)`: each carries the
/// loans its own type can hold of what the call passes on, as one
/// result does (`carryResult` of each), recorded for the targets that
/// take them (`results_of`). An argument's write view ends at the
/// return only when no result keeps it to write; while one may, every
/// view lasts to the statement's end, as for a `!T` result. The
/// results are views of one call, so no two may break sentence 5: a
/// write loan one carries and a loan another carries on the same place
/// are reported (the declaration rejects them first, `sema`'s
/// `checkResultViews`, but a function value's type may say less).
pub fn callResults(self: *Checker, node: Sexp, temps_start: usize, stored: Value, result: Value, tys: []const TypeId) Error!Value {
    const ctx = self.sema;
    const parts = try self.arena().alloc(Value, tys.len);
    var whole: Value = .{};
    var view_only = true;
    var read_only = true;
    for (tys, parts) |t, *part| {
        part.* = if (types.mayCarryLoan(self, t)) try origins.carryResult(self, t, result) else .{};
        whole = try self.valueUnion(whole, part.*);
        if (!types.mayCarryLoan(self, t) or sema.holdsViewOnly(ctx, t)) continue;
        view_only = false;
        if (!origins.viewsOnlyRead(self, t)) read_only = false;
    }
    for (parts, 0..) |a, i| for (a.loans) |l| {
        if (l.kind != .write) continue;
        for (parts, 0..) |b, k| if (k != i) for (b.loans) |m| if (m.root == l.root and self.paths.overlap(m.path, l.path)) {
            try notes.err(self, notes.startOf(self, node), "the results of this call would view `{s}` twice while one of them writes it: a write view is the only view of what it views while it lives", .{self.vars.items[l.root].name});
            self.results_of = .{ .node = node, .parts = parts };
            return whole;
        };
    };
    self.results_of = .{ .node = node, .parts = parts };
    if (view_only) return keepViewTemps(self, temps_start, whole);
    if (read_only) return endWriteViews(self, temps_start, stored, whole);
    return whole;
}

/// `q, r = f()`: the call's several results go into the statement's
/// hidden results var, which holds the loans of every result no
/// target has taken yet; each target then takes its own, left to
/// right, as the binding `x = e` it is (`walkSet` of `(set op x _
/// (result_part))`), so a target is bound only while no result still
/// pending views it. A result no target takes (`_`) stays in the var,
/// which the statement's end drops (`dropStmtTemps`), when its drop
/// runs a `drop` body; any other reads none of its views. This walks
/// the desugaring: the results statement temporaries, each taken by
/// its binding (docs/internals/INTERNALS.md, "Several results").
pub fn walkDestructure(self: *Checker, node: Sexp) Error!void {
    const value = ir.Destructure.value(node);
    const targets = ir.Destructure.targets(node).items();
    // What a target's store reads is used after the value, as an
    // assignment's target is.
    const mark = self.after_value.items.len;
    for (targets) |t| if (t.isKind(.set)) {
        _ = try useAfterValue(self, t);
    };
    // A write-view local a target re-points never uses its old view
    // again, when the value does not read it and cannot leave early:
    // its loans end before the call makes a view anew, as for `w = e`.
    const ctx = self.sema;
    if (!leavesEarly(value)) for (targets) |t| {
        if (!t.isKind(.set) or !ctx.repoints(t)) continue;
        const name = types.text(self, ir.Set.target(t));
        if (readsName(self, value, name)) continue;
        if (self.find(ir.Set.target(t))) |id| try self.setFlow(id, .{ .status = self.flows.items[id].status, .at = self.flows.items[id].at });
    };
    const saved_results = self.results_of;
    defer self.results_of = saved_results;
    self.results_of = null;
    const temps_start = self.temps.items.len;
    const whole = try walkConsumed(self, value, .binding);
    self.after_value.shrinkRetainingCapacity(mark);
    if (!self.reachable) return;
    const call = resultsCall(value);
    const parts: []const Value = blk: {
        if (self.results_of) |r| if (sameNode(r.node, call) and r.parts.len == targets.len) break :blk r.parts;
        const all = try self.arena().alloc(Value, targets.len);
        @memset(all, whole);
        break :blk all;
    };
    // Which results the statement holds to its end: each a target
    // takes, until it takes it, and each `_` discards whose drop runs
    // a `drop` body, which could read what it views. Any other
    // discarded result uses none of its views (Core sentence 6), so
    // its loans end here, but for those another result keeps.
    const held = try self.arena().alloc(bool, targets.len);
    const tys: []const TypeId = if (types.exprType(self, value)) |t| sema.resultsOf(self.sema, t) orelse &.{} else &.{};
    var kept: Value = .{};
    for (targets, held, parts, 0..) |t, *h, part, k| {
        h.* = t.isKind(.set) or k >= tys.len or sema.dropRunsBody(self.sema, tys[k]) != .no;
        if (h.*) kept = try self.valueUnion(kept, part);
    }
    const pos = notes.startOf(self, node);
    const id = try self.addVar(.{ .name = "the call's results", .decl = pos, .ty = types.exprType(self, value), .kind = .hidden }, .{ .loans = kept.loans });
    // That var holds what the results carry from here, and each
    // target what it takes (Core sentence 6). What else the call
    // keeps viewed (`callResults`) stays.
    for (parts) |part| for (part.loans) |l| {
        var i = @min(temps_start, self.temps.items.len);
        while (i < self.temps.items.len) {
            if (self.temps.items[i].sameAs(l)) _ = self.temps.orderedRemove(i) else i += 1;
        }
    };
    try self.stmt_drops.append(self.gpa, .{ .id = id, .pos = pos });
    const saved_part = self.part_value;
    defer self.part_value = saved_part;
    for (targets, 0..) |t, j| {
        if (!t.isKind(.set)) continue;
        // The result leaves the temporary for its binding, which keeps
        // the loans of those still pending and of those held to the
        // statement's end.
        var left: Value = .{};
        for (targets, parts, held, 0..) |o, part, h, k| {
            if (k == j or (k < j and o.isKind(.set)) or !h) continue;
            left = try self.valueUnion(left, part);
        }
        try self.setFlow(id, .{ .loans = left.loans });
        if (try pendingView(self, t, targets, parts, held, j)) continue;
        self.part_value = parts[j];
        try walkSet(self, t);
    }
}

/// The target of `set` (the `j`th of `targets`) names a binding that
/// a result still pending views: binding it would change or drop what
/// that result views (`s, rest = split(?s)`). Reported, true.
pub fn pendingView(self: *Checker, set: Sexp, targets: []const Sexp, parts: []const Value, held: []const bool, j: usize) Error!bool {
    const target = ir.Set.target(set);
    if (target != .src) return false;
    const ctx = self.sema;
    const sym = ctx.symbolOf(target) orelse return false;
    if (ctx.symbols.items[sym].decl_pos == target.src.pos) return false;
    const id = self.find(target) orelse return false;
    for (targets, parts, held, 0..) |o, part, h, k| {
        if (k == j or (k < j and o.isKind(.set)) or !h) continue;
        for (part.loans) |l| if (l.root == id and !l.ext) {
            if (o.isKind(.set)) {
                try notes.err(self, target.src.pos, "cannot bind `{s}` while `{s}` views it", .{ types.text(self, target), types.text(self, ir.Set.target(o)) });
            } else try notes.err(self, target.src.pos, "cannot bind `{s}` while the result `_` discards views it: that result's `drop` body runs at the statement's end", .{types.text(self, target)});
            return true;
        };
    }
    return false;
}

/// A value read in place, by value, before the operands after it run
/// (`reader`: a call argument, a method's self, the value a call
/// calls, a binary operator's left operand, an indexed value that is
/// no place), when the value shares storage the place it reads owns
/// (a List's buffer, a box, a shared handle, a struct holding one;
/// through a write view, what it reaches). Its consumer uses that
/// value only after the later operands run, so until then the place's
/// root holds a read loan, and a later operand cannot make a write view
/// of it or move it. Plain data is copied whole when it is read, and what a
/// read view reaches is covered by its own loans.
pub fn holdRead(self: *Checker, operand: Sexp, reader: Reader) Error!void {
    const ctx = self.sema;
    const e = if (operand.isKind(.kwarg)) ir.Kwarg.value(operand) else operand;
    const place = resolvePlace(self, e) orelse return holdBranchReads(self, e, reader);
    const v = self.vars.items[place.root];
    if (v.ref == .read or v.closure or !self.flowLive(place.root)) return;
    var ty = types.exprType(self, e) orelse return;
    while (ctx.types.get(ty) == .write_view) ty = ctx.types.get(ty).write_view;
    if (!sema.readByAddress(ctx, ty)) return;
    try live.addTemp(self, .{ .root = place.root, .path = place.path, .kind = .read, .pos = notes.startOf(self, e), .held_read = reader });
}

/// The places a value that is no place reads in place: what a read
/// branching value (`a if c else b`, `o ?? d`, `e catch d`, `o?`) may
/// be (`sema.valueLeaves`), and a field or element of one, held as
/// `holdRead` holds a place. The value is copied where it runs, so a
/// place holding a Cell is held against any later view: one that
/// changes the Cell would leave the copy stale.
pub fn holdBranchReads(self: *Checker, e: Sexp, reader: Reader) Error!void {
    // A field or element that owns storage is read where the value
    // holding it is.
    if (isPartOfNoPlace(self, e)) {
        const ctx = self.sema;
        const ty = types.exprType(self, e) orelse return;
        if (!sema.readByAddress(ctx, ty)) return;
        return holdBranchReads(self, ir.get(e, .object), reader);
    }
    var leaves: std.ArrayList(Sexp) = .empty;
    try sema.valueLeaves(self.arena(), e, &leaves);
    for (leaves.items) |leaf| {
        if (isPartOfNoPlace(self, leaf)) try holdBranchReads(self, leaf, reader) else try holdBranchLeaf(self, leaf, reader);
    }
}

/// What a method called on `obj`, a self that is no place, is
/// given a view of: the method runs on self where it is, so a view it
/// returns may view whatever self may be (Core sentence 7).
/// For each leaf of the value its fields and elements are read from
/// (`sema.valueLeaves`: each branch of `a if c else b`, `o ?? d`,
/// `e catch d`), a loan on the place a name holds, or on the
/// statement's temporary a made value is, which ends with the
/// statement (Core §3).
pub fn selfLeaves(self: *Checker, obj: Sexp, kind: LoanKind) Error!Value {
    var base = obj;
    while (isPartOfNoPlace(self, base)) base = ir.get(base, .object);
    // A value its statement keeps in a slot (`dropsTemp`), a copy of a
    // branching value's leaf included, is viewed there.
    const ctx = self.sema;
    if (ctx.dropsTemp(base)) {
        const pos = notes.startOf(self, base);
        if (stmtTempAt(self, pos)) |id| return .{ .loans = try self.oneLoan(.{ .root = id, .kind = .read, .pos = pos }) };
    }
    var leaves: std.ArrayList(Sexp) = .empty;
    try sema.valueLeaves(self.arena(), base, &leaves);
    var out: Value = .{};
    for (leaves.items) |leaf| {
        const pos = notes.startOf(self, leaf);
        if (resolvePlace(self, leaf)) |p| {
            if (!self.flowLive(p.root)) continue;
            out = try self.valueUnion(out, try viewOn(self, p.root, .{ .root = p.root, .path = p.path, .kind = kind, .pos = pos }));
            continue;
        }
        if (isPartOfNoPlace(self, leaf)) {
            out = try self.valueUnion(out, try selfLeaves(self, leaf, kind));
            continue;
        }
        // A name that is no var (a module's, a constant's) names no
        // storage of this function.
        if (leaf == .src) continue;
        // A made value: the temporary its statement holds, made here
        // if the value needs no drop.
        const held = stmtTempAt(self, pos);
        const loan: Loan = .{ .root = held orelse (try holdTemp(self, leaf, .{})).loans[0].root, .kind = .read, .pos = pos };
        out = try self.valueUnion(out, .{ .loans = try self.oneLoan(loan) });
    }
    return out;
}

/// Whether `e` is a field or element of a value that is no place.
pub fn isPartOfNoPlace(self: *Checker, e: Sexp) bool {
    if (!e.isKind(.member) and !e.isKind(.index)) return false;
    return resolvePlace(self, e) == null and !rig.isRangeIndex(e);
}

pub fn holdBranchLeaf(self: *Checker, leaf: Sexp, reader: Reader) Error!void {
    const ctx = self.sema;
    const place = resolvePlace(self, leaf) orelse return;
    const v = self.vars.items[place.root];
    if (v.ref == .read or v.closure or !self.flowLive(place.root)) return;
    const ty = types.exprType(self, leaf) orelse return;
    if (!sema.readByAddress(ctx, ty)) return;
    try live.addTemp(self, .{ .root = place.root, .path = place.path, .kind = .read, .pos = notes.startOf(self, leaf), .held_read = reader });
}

/// Walk `earlier`, then `later` while what `earlier` reads in place is
/// held (`holdRead`): the consumer of both, a binary operator or an
/// index of a value that is no place, uses `earlier` after `later`
/// runs. The hold ends there.
pub fn walkThenHeld(self: *Checker, earlier: Sexp, reader: Reader, later: Sexp) Error!Value {
    const found = self.errors_found;
    const first = try walk(self, earlier);
    const mark = self.temps.items.len;
    if (self.errors_found == found) try holdRead(self, earlier, reader);
    var held = self.temps.items.len - mark;
    _ = try walk(self, later);
    while (held > 0 and mark < self.temps.items.len and self.temps.items[mark].held_read == reader) : (held -= 1) {
        _ = self.temps.orderedRemove(mark);
    }
    return first;
}

/// `swap(!a, !b)` (`swap` true) / `old = swap(!place, v)`: the places
/// are given as write views for the call, and `v` moves in. The two places
/// may be different fields of one value (`swap(!t.left, !t.right)`),
/// two places, neither of which holds the other (Core sentence 5). A
/// swap with a value is `t = <place; place = v` (`takenValue`): its
/// result is no view of the place.
pub fn walkSwapCall(self: *Checker, args: []const Sexp, swap: bool) Error!Value {
    const start = self.temps.items.len;
    const first = try walkConsumed(self, args[0], .argument);
    const viewed = self.temps.items.len;
    var saved: std.ArrayList(Loan) = .empty;
    defer saved.deinit(self.gpa);
    if (if (swap) notes.sameCollection(self, args[0], args[1]) else null) |e| {
        // Two elements of one collection: its own `swap` exchanges
        // them. Said once, here.
        try notes.err(self, notes.startOf(self, ir.Write.operand(args[1])), "cannot change `{s}` while a write view of it is still in use: to swap two elements of `{s}`, write `!{s}.swap({s}, {s})`", .{ e.base, e.base, e.base, e.i, e.j });
        try saved.appendSlice(self.gpa, self.temps.items[start..viewed]);
        self.temps.shrinkRetainingCapacity(start);
    }
    const second = try walkConsumed(self, args[1], .argument);
    try self.temps.appendSlice(self.gpa, saved.items);
    // What a swap with a value hands back views what the place's value viewed,
    // and each place now views what went in. A `swap`'s two views are
    // the ways in, not views stored.
    var result: Value = .{};
    const ty = types.exprType(self, args[1]);
    if (!swap and types.mayCarryLoan(self, ty)) result = try takenValue(self, args[0], ty, first) else if (!swap) generic.taintGeneric(self, ty, first);
    // A `swap` stores in each place the value the other held, which
    // carries what that held (`takenValue`).
    const views = if (swap) try self.unionLoans(first.loans, second.loans) else first.loans;
    const into_first = if (swap) try self.valueUnion(second, try takenValue(self, args[1], types.pointee(self, types.exprType(self, args[1])), second)) else second;
    try origins.absorbThroughViews(self, first, into_first, views, notes.startOf(self, args[1]), null, null);
    if (swap) try origins.absorbThroughViews(self, second, try self.valueUnion(first, try takenValue(self, args[0], types.pointee(self, types.exprType(self, args[0])), first)), views, notes.startOf(self, args[0]), null, null);
    self.temps.shrinkRetainingCapacity(start);
    return result;
}

/// What `swap(!p, v)` hands back, as `t = <p; p = v` takes it: the
/// value that was in `p`, which carries what `p`'s value held and no
/// loan on `p`, as `walkTake` gives `<p.f`. A place no var holds
/// (`!f().x`) is known only by the loans of its view.
pub fn takenValue(self: *Checker, view: Sexp, ty: ?TypeId, first: Value) Error!Value {
    const inner = if (view.isKind(.write)) ir.Write.operand(view) else view;
    const place = resolvePlace(self, inner) orelse return origins.carry(self, ty, first);
    return origins.carry(self, ty, live.varValue(self, place.root));
}

// -----------------------------------------------------------------------------
// Sentence 8: counted handles; closures (Core section 7)
// -----------------------------------------------------------------------------

/// The value of type `ty` that a clone or weak handle (`+x`, `~x`,
/// `|+x|`, `|~x|`) makes from var `id` or another value carrying `v`.
/// A new handle is independent of the view it was reached through
/// (a loop element, a `?*T` parameter), but reaches whatever the
/// shared value holds; a write view held there cannot be duplicated,
/// whoever made it.
pub fn newHandle(self: *Checker, pos: u32, what: []const u8, ty: ?TypeId, id: ?VarId, v: Value, weak: bool) Error!Value {
    if (!types.mayCarryLoan(self, ty)) {
        generic.taintGeneric(self, ty, v);
        return .{};
    }
    const out = heldThroughHandle(self, ty, id) orelse v;
    if (types.carriesWriteView(self, ty)) {
        try notes.err(self, pos, "cannot {s} `{s}`: it holds a write view, which cannot be duplicated", .{ if (weak) "take a weak handle to" else "clone", what });
        for (out.loans) |l| if (l.kind == .write) {
            try notes.noteLoan(self, l);
            break;
        };
        return .{};
    }
    return out;
}

/// What a shared value of handle type `ty` holds: nothing when its
/// type holds no view, the loans of the collection a loop element
/// `id` walks, or null to use the handle's own loans.
pub fn heldThroughHandle(self: *const Checker, ty: ?TypeId, id: ?VarId) ?Value {
    const t = types.pointee(self, ty) orelse return null;
    const boxed: TypeId = switch (types.typeData(self, t)) {
        .shared, .weak => |b| b,
        .optional => |o| switch (types.typeData(self, o)) {
            .shared, .weak => |b| b,
            else => return null,
        },
        else => return null,
    };
    if (!types.mayCarryLoan(self, boxed)) return .{};
    if (id) |i| if (self.vars.items[i].elem_of) |c| return .{ .loans = self.flows.items[c].loans };
    return null;
}

pub fn walkShare(self: *Checker, node: Sexp) Error!Value {
    const inner = ir.Share.operand(node);
    // `*|...| body`: an owned closure.
    if (isLambda(inner)) {
        self.lambda_ok = true;
        return walkLambda(self, inner, true);
    }
    // `*w` upgrading a weak handle it reads reads it, as a `?@`
    // method reads its self; one it takes is moved, as `*<x` moves
    // `x`. The new handle reaches what `w` reaches.
    const ctx = self.sema;
    if (ctx.upgradeOf(node)) |how| {
        const v = if (how == .reads) try walk(self, inner) else try walkConsumed(self, inner, .allocation);
        return if (types.mayCarryLoan(self, types.exprType(self, node))) v else .{};
    }
    return walkConsumed(self, inner, .allocation);
}

/// A closure literal; `owned` for `*|...| body`.
pub fn walkLambda(self: *Checker, node: Sexp, owned: bool) Error!Value {
    const params = ir.Lambda.params(node);
    const body = ir.Lambda.body(node);
    if (!self.lambda_ok) {
        try notes.errAt(self, node, "closures cannot escape their defining scope; bind the closure to a local (`f = |...| ...`) and call `f()`, or make it owned (`*|...| body`) to pass, store, or return it", .{});
    }
    self.lambda_ok = false;

    // Captures take effect on the enclosing scope, at construction.
    var value: Value = .{};
    var cap_values: std.ArrayList(Value) = .empty;
    const caps = sema.captureList(ir.Lambda.captures(node));
    for (caps) |cap| {
        const cv = try applyCapture(self, cap);
        try cap_values.append(self.arena(), cv);
        if (owned) try generic.requireNoView(self, sema.captureNameNode(cap).?.src.pos, types.symType(self, sema.captureNameNode(cap).?.src.pos), .closure);
        // An API object may hold a loan its type does not show: an
        // owned closure keeps one only where its braces name `Owned`.
        const ctx = self.sema;
        if (owned) if (types.symType(self, sema.captureNameNode(cap).?.src.pos)) |ct| if (try sema.objectLoanReason(ctx, self.arena(), ct)) |why| {
            try notes.err(self, sema.captureNameNode(cap).?.src.pos, "an owned closure holds no view, and {s}", .{why});
            value = try self.valueUnion(value, cv);
            continue;
        };
        // An owned closure is a shared handle that may be stored
        // anywhere, including in a Cell or Signal: it holds no view.
        if (owned and cv.loans.len > 0) {
            const name = types.text(self, sema.captureNameNode(cap).?);
            const l = cv.loans[0];
            const mode = sema.captureModeOf(cap).?;
            if (mode == .cap_read or mode == .cap_write) {
                try notes.err(self, sema.captureNameNode(cap).?.src.pos, "an owned closure cannot capture a view of `{s}`: it can be stored anywhere, so it could outlive `{s}`; capture an owned value, or use a stack closure (`|...|`)", .{ name, name });
                value = try self.valueUnion(value, cv);
                continue;
            }
            try notes.err(self, sema.captureNameNode(cap).?.src.pos, "an owned closure cannot capture `{s}`, which holds a view{s}{s}{s}; capture an owned value, or use a stack closure (`|...|`){s}", .{
                name,
                if (l.ext) "" else " of `",
                if (l.ext) "" else self.vars.items[l.root].name,
                if (l.ext) "" else "`",
                staticParamHint(l),
            });
            try notes.noteLoan(self, l);
        }
        value = try self.valueUnion(value, cv);
    }
    // The body may store what one capture views into what a
    // captured write view leads to, as a call may with its
    // arguments: that value now holds those loans. Only a capture
    // that can write leads a store (as for a call's arguments).
    const self_views = self.closure_self_views.items.len;
    defer self.closure_self_views.shrinkRetainingCapacity(self_views);
    self.capturing = true;
    if (!owned and caps.len > 1) for (caps, cap_values.items) |cap, cv| {
        const pos = sema.captureNameNode(cap).?.src.pos;
        if (sema.captureModeOf(cap).? != .cap_write and !types.mayWrite(self, types.symType(self, pos))) continue;
        try origins.absorbThroughWrites(self, cv, value, pos, null, null);
    };
    self.capturing = false;

    // The body is checked as its own function; it cannot affect the
    // enclosing state.
    const snap = try self.here();
    const saved_func = self.func;
    const saved_loop = self.loop;
    const fn_ty = types.exprType(self, node);
    const ret_ty: ?TypeId = if (fn_ty) |t| switch (types.typeData(self, t)) {
        .function => |f| f.returns,
        else => null,
    } else null;
    const returns_value = ret_ty != null and !types.isVoid(self, ret_ty);
    self.func = .{
        .in_closure = true,
        .ret_may_view = returns_value and types.mayCarryLoan(self, ret_ty),
        .ret_ty = if (returns_value) ret_ty else null,
        .closure_base = @intCast(self.vars.items.len),
        .origins = try origins.typeOrigins(self, fn_ty),
    };
    self.loop = null;
    self.reachable = true;
    try self.pushScopeFor(.closure, body);
    for (caps, cap_values.items) |cap, cv| {
        const name = sema.captureNameNode(cap).?;
        const ty = types.symType(self, name.src.pos);
        // A capture the type checker rejected holds nothing.
        const resource = !types.isPoisonType(self, ty) and switch (sema.captureModeOf(cap).?) {
            .cap_clone => !types.copies(self, ty),
            .cap_weak, .cap_move, .cap_read, .cap_write => true,
        };
        // A closure its callee calls at most once (`f: once ?fun()`)
        // takes what it owns of its captures, as a function takes a
        // parameter given by value.
        const once = if (self.sema.symbolOf(name)) |sym| self.sema.isOnceCapture(sym) else false;
        _ = try self.addVar(.{
            .name = types.text(self, name),
            .decl = name.src.pos,
            .ty = ty,
            .kind = if (once) .local else .capture,
            .ref = types.refOfType(self, ty),
            .capture_resource = resource and !once,
        }, .{ .loans = cv.loans });
    }
    try bindParams(self, params);
    const result = try walkBody(self, body, returns_value);
    try self.popScopeWith(result.loans);
    try origins.checkOrigins(self, "this closure", .nil, params);
    self.func = saved_func;
    self.loop = saved_loop;
    try self.rewind(snap);
    return if (owned) .{} else value;
}

pub fn applyCapture(self: *Checker, cap: Sexp) Error!Value {
    // A field path is viewed, copied, taken, or held weakly as its
    // sigil does it in an expression.
    if (sema.captureValue(cap) != .nil) return walk(self, sema.captureValue(cap));
    const mode = sema.captureModeOf(cap).?;
    const node = sema.captureNameNode(cap).?;
    const pos = node.src.pos;
    const name = types.text(self, node);
    // The name declares the capture; the binding it captures is the
    // capture's origin. Unresolved or nested captures are diagnosed by
    // ctx.
    const cap_sym = self.sema.symbolOf(node) orelse return .{};
    const id = self.varOf(self.sema.symbols.items[cap_sym].origin) orelse return .{};
    const v = self.vars.items[id];
    if (v.closure) {
        if (mode == .cap_read) return viewClosure(self, id, pos);
        // Reported by the type checker.
        if (types.isPoisonType(self, types.symType(self, pos))) return .{};
        try notes.err(self, pos, "cannot capture closure `{s}`; closures cannot be copied. Capture a read view of it with `|?{s}|`", .{ name, name });
        return .{};
    }
    if (mode == .cap_move) return moveVar(self, id, pos, .capture);
    // `|?x|` / `|!x|` view `x` for as long as the closure lives.
    if (mode == .cap_read or mode == .cap_write) return (try viewVar(self, id, whole_path, if (mode == .cap_read) .read else .write, pos)) orelse .{};
    if (!try rules.checkCapturable(self, id, pos)) return .{};
    if (self.findLoan(id, whole_path, .write, null)) |l| {
        try notes.err(self, pos, "cannot capture `{s}` while {s} is still in use", .{ name, try notes.viewOfText(self, l, whole_path) });
        try notes.noteLoan(self, l);
        try notes.noteStillUsed(self, l, pos);
        return .{};
    }
    // `|+x|` through a view captures a copy or a clone of what the
    // view sees, which keeps what that holds, not the view's loan
    // on it (Core §7, sentence 7).
    const ty = types.symType(self, pos);
    const through = types.refOfType(self, v.ty) != .none and types.refOfType(self, ty) == .none;
    const held = if (through) try origins.carry(self, ty, live.varValue(self, id)) else live.varValue(self, id);
    return newHandle(self, pos, name, ty, id, held, mode == .cap_weak);
}

// -----------------------------------------------------------------------------
// Sentence 9: shared storage and cells
// -----------------------------------------------------------------------------

/// `value` stored into `target`, an element of the List a Cell holds
/// (`inCellList`): every handle to the Cell reaches it, so it holds no
/// view.
pub fn storeInCellList(self: *Checker, target: Sexp, value: Value) Error!void {
    const pos = notes.startOf(self, target);
    try generic.requireNoView(self, pos, types.exprType(self, target), .cell);
    const loans = (try origins.carry(self, types.exprType(self, target), value)).loans;
    if (loans.len > 0) try notes.err(self, pos, "cannot store a view of `{s}` in a `Cell`: every handle to it could reach the view; a value stored in a Cell or Signal may not hold one{s}", .{ self.vars.items[loans[0].root].name, staticParamHint(loans[0]) });
}

/// Whether place `target` is, or is a field of, an element of the List
/// a Cell holds (`c[i] = v`, `c[i].f = v`).
pub fn inCellList(self: *const Checker, target: Sexp) bool {
    const ctx = self.sema;
    var e = target;
    while (e.isKind(.member) or e.isKind(.index)) : (e = ir.get(e, .object)) {
        if (!e.isKind(.index)) continue;
        const ty = types.exprType(self, ir.Index.object(e)) orelse continue;
        switch (ctx.types.get(sema.unwrapReadAccess(ctx, ty))) {
            .parameterized_nominal => |pn| if (pn.sym == ctx.cell_sym_id) return true,
            else => {},
        }
    }
    return false;
}

// -----------------------------------------------------------------------------
// Sentence 10: `e!` and `e?` propagate
// -----------------------------------------------------------------------------

/// `e!` / `e?`: on failure or `none`, control leaves for the caller.
pub fn walkPropagate(self: *Checker, node: Sexp) Error!Value {
    const v = try walk(self, ir.get(node, .value));
    if (self.reachable) _ = try exits.exitTo(self, .{ .exit = .{ .propagate = node.isKind(.propagate) } });
    return v;
}

/// Whether returning `e` may make the function fail, which runs its
/// `errdefer`s: `e` is an error, or may be one.
pub fn mayFail(self: *const Checker, e: Sexp) bool {
    const ctx = self.sema;
    const ty = types.exprType(self, e) orelse return true;
    return switch (ctx.types.get(ty)) {
        .fallible, .any_error, .invalid, .unknown => true,
        else => sema.isErrorSet(ctx, ty),
    };
}

/// `(catch expr name? handler)`: the handler runs when `expr` fails.
pub fn walkCatch(self: *Checker, node: Sexp) Error!Value {
    const t = takeTail(self, node);
    const v1 = try walkPayloadHolder(self, node, ir.Catch.value(node));
    const handler = ir.Catch.handler(node);
    try holdPartTemps(self, handler);
    const base = try self.here();
    try self.pushScopeFor(.block, handler);
    const name = ir.Catch.name(node);
    if (name != .nil) {
        _ = try self.addVar(.{ .name = types.text(self, name), .decl = name.src.pos, .ty = types.symType(self, name.src.pos) }, .{});
    }
    var v2 = try walkTailPart(self, handler, t);
    v2 = try self.leaveScope(v2);
    const s = try self.leave(base, notes.resumeAt(self, .nil, node));
    try self.apply(try self.join(stateAt(base), s));
    return self.valueUnion(v1, v2);
}

/// `a ?? b`: `b` runs only when `a` is `none`. It may be a jump, which
/// leaves the rest of the code reachable through the other path.
pub fn walkNullish(self: *Checker, node: Sexp) Error!Value {
    const t = takeTail(self, node);
    const v1 = try walkPayloadHolder(self, node, ir.@"??".left(node));
    return self.valueUnion(v1, try walkMayRun(self, ir.@"??".right(node), t, node));
}

// -----------------------------------------------------------------------------
// Return
// -----------------------------------------------------------------------------

pub fn walkReturn(self: *Checker, node: Sexp) Error!void {
    const value = ir.Return.value(node);
    var result: Value = .{};
    // `return a, b`: each part leaves the function as `return x`
    // does, left to right.
    if (value.isKind(.results)) {
        const tys: []const TypeId = if (self.func.ret_ty) |r| sema.resultsOf(self.sema, r) orelse &.{} else &.{};
        for (ir.Results.values(value), 0..) |part, i| {
            const ty: ?TypeId = if (i < tys.len) tys[i] else null;
            result = try self.valueUnion(result, try walkReturnValue(self, part, ty));
        }
    } else if (value != .nil) result = try walkReturnValue(self, value, null);
    _ = try exits.exitTo(self, .{ .exit = .{ .@"return" = value != .nil and mayFail(self, value) }, .result = result.loans });
    self.reachable = false;
}

/// A value leaving the function: a bare local moves out; anything
/// else must not copy an owning value; views must come from
/// view parameters.
/// `part`, for a part of `return a, b`, is the type of the result it
/// gives, by which its loans are judged (Core sentence 7, per result).
/// Gives the loans the result keeps.
pub fn walkReturnValue(self: *Checker, expr: Sexp, part: ?TypeId) Error!Value {
    var value: Value = .{};
    if (expr == .src and types.erasesCopy(self, expr)) {
        // A read view erased to an API object of a copy, a local of
        // this block (`walk`).
        value = try walk(self, expr);
    } else if (expr == .src) {
        try rules.checkNoImplicitCopy(self, expr, .ret, true);
        if (self.find(expr)) |id| {
            const v = self.vars.items[id];
            if (v.closure) {
                value = try walkName(self, expr, false);
            } else if (!v.capture_resource and leavesAsWriteView(self, v, expr, part orelse self.func.ret_ty)) {
                value = try moveWriteView(self, id, expr.src.pos);
            } else if (!v.loop_view and !v.capture_resource) {
                if (returnMoves(self, v)) {
                    value = try moveVar(self, id, expr.src.pos, .move);
                } else if (try rules.checkLive(self, id, expr.src.pos)) {
                    value = live.varValue(self, id);
                }
            }
        }
    } else if (isValue(self, expr)) {
        try rules.checkNoImplicitCopy(self, expr, .ret, true);
        setTail(self, expr, .ret);
        value = try walk(self, expr);
    } else {
        _ = try walk(self, expr);
        return .{};
    }
    const ret = part orelse self.func.ret_ty;
    const may_view = if (part) |t| types.mayCarryLoan(self, t) else self.func.ret_may_view;
    var kept: Value = .{};
    if (may_view and self.reachable) {
        // A result keeps only the loans its own type could hold.
        kept = if (part) |t| try origins.carry(self, t, value) else value;
        try rules.checkEscape(self, kept);
        origins.recordResult(self, kept, expr);
    } else if (self.reachable and generic.genericType(self, ret)) {
        kept = value;
        origins.recordResult(self, value, expr);
    }
    // A result that holds a value of a type parameter's type may carry,
    // in an instance, whatever reached one (`taintGeneric`).
    if (self.reachable and generic.holdsGeneric(self, ret) and self.func.generic_returned_at == null) self.func.generic_returned_at = notes.startOf(self, expr);
    return kept;
}

/// A bare name that leaves the function moves out: a match payload
/// out of its scrutinee, and an owning value out of its binding, so
/// deferred code at that exit sees it moved. A payload that is a read
/// view copies (Core sentence 1), as it does as the tail value.
pub fn returnMoves(self: *const Checker, v: Var) bool {
    if (v.payload_view) return v.ref != .read or types.owningKind(self, v.ty) != null;
    return types.owningKind(self, v.ty) != null;
}

/// Whether `v`, named at `node` where its value leaves for good (a
/// result of type `sink`, or the value of the block that declares
/// it), hands out the write view it holds: then the view leaves, as
/// `<v` would (Core sentence 1). A result that copies the value the
/// view sees (`w: !Int` returned as an `Int`) only reads it. A match
/// payload leaves as `returnMoves` says.
pub fn leavesAsWriteView(self: *const Checker, v: Var, node: Sexp, sink: ?TypeId) bool {
    if (v.closure or v.payload_view) return false;
    if (v.ref != .write and !types.carriesWriteView(self, v.ty)) return false;
    if (sink) |t| if (!types.carriesWriteView(self, t)) return false;
    const ctx = self.sema;
    return !ctx.readsThrough(node);
}

/// Move out the write view var `id` holds, where it leaves
/// (`leavesAsWriteView`): no loan on it may be in force (a closure or
/// a task it was given to), and nothing that runs after, a `defer`, a
/// task waited for at the scope's end, or a `drop` body, may use it.
/// What it views stays viewed while the value it leaves in is formed
/// (`holdMoved`).
pub fn moveWriteView(self: *Checker, id: VarId, pos: u32) Error!Value {
    if (!try rules.checkLive(self, id, pos)) return .{};
    const value = live.varValue(self, id);
    if (try rules.conflicts(self, id, whole_path, .{ .consume = "move" }, pos)) return .{};
    try self.markInvalid(id, .moved, pos);
    try holdMoved(self, value);
    return value;
}

// -----------------------------------------------------------------------------
// Branches
// -----------------------------------------------------------------------------

pub fn walkIf(self: *Checker, node: Sexp) Error!Value {
    const t = takeTail(self, node);
    const cond = ir.If.cond(node);
    if (rig.isAsPart(cond) or rig.isConditionJoin(cond)) return walkIfBinding(self, node, t);
    const then_b = ir.If.then(node);
    const else_b = ir.If.@"else"(node);
    // The condition is a header, its own statement.
    const mark = try useBranchesAfter(self, node, cond);
    try walkStmt(self, cond);
    self.after_value.shrinkRetainingCapacity(@min(mark, self.after_value.items.len));
    const base = try self.here();
    const past = notes.resumeAt(self, .nil, node);
    const v1 = try walkTailPart(self, then_b, t);
    const s1 = try self.leave(base, past);
    const v2 = if (else_b != .nil) try walkTailPart(self, else_b, t) else Value{};
    const s2 = try self.leave(base, past);
    try self.apply(try self.join(s1, s2));
    return self.valueUnion(v1, v2);
}

/// A branch before its condition in the source (`stmt if cond`, `a if
/// cond else b`) runs after it: what the branch reads is used after
/// the condition, so it is live while the condition is walked, as an
/// assignment's target is while its value is (`after_value`). A name
/// the branch binds counts as `useAfterValue` counts a target.
/// Returns the mark to drop them back to once the condition is walked.
pub fn useBranchesAfter(self: *Checker, node: Sexp, cond: Sexp) Error!usize {
    const mark = self.after_value.items.len;
    const at = notes.extent(self, cond).lo;
    for ([_]Sexp{ ir.If.then(node), ir.If.@"else"(node) }) |b| {
        if (b == .nil or notes.extent(self, b).lo >= at) continue;
        if (b.isKind(.set)) {
            _ = try useAfterValue(self, b);
            try useAfterValueIn(self, ir.Set.value(b));
        } else try useAfterValueIn(self, b);
    }
    return mark;
}

/// `if a as x` and `if a as x and ...`: the parts run in order, each
/// binding in a scope over the rest and the then-branch. The `else`
/// runs when a part fails, so it starts from the join of the states
/// after each part, with their bindings gone.
pub fn walkIfBinding(self: *Checker, node: Sexp, t: ?Tail) Error!Value {
    const then_b = ir.If.then(node);
    const else_b = ir.If.@"else"(node);
    const base = try self.here();
    const depth = self.scopes.items.len;
    // A failing part goes on to the `else`, or past the `if`.
    const fails = try walkConditionParts(self, ir.If.cond(node), then_b, .{ .to = base, .resume_at = notes.resumeAt(self, else_b, node) }, self.loop);
    var v1 = try walkTailPart(self, then_b, t);
    while (self.scopes.items.len > depth) v1 = try self.leaveScope(v1);
    const past = notes.resumeAt(self, .nil, node);
    const s1 = try self.leave(base, past);
    try self.apply(try joinAll(self, fails));
    const v2 = if (else_b != .nil) try walkTailPart(self, else_b, t) else Value{};
    const s2 = try self.leave(base, past);
    try self.apply(try self.join(s1, s2));
    return self.valueUnion(v1, v2);
}

/// The parts of a binding condition, in order. Each `as` moves the
/// value inside its optional into a binding, in a new scope over
/// `body`, which the caller pops. The binding holds what the value
/// views; the loans taken to compute it end there, so the path
/// where there is no value is free to use them. A part that fails
/// takes the exit `fail`, inside `loop`, with the effects of the
/// parts before it and its own, and none of the later ones': the
/// states it leaves with, one per part, which the caller joins
/// (`joinAll`) once back at `fail.to`.
pub fn walkConditionParts(self: *Checker, cond: Sexp, body: Sexp, fail: ExitTo, loop: ?*LoopCtx) Error![]const State {
    const Parts = struct {
        c: *Checker,
        body: Sexp,
        fail: ExitTo,
        loop: ?*LoopCtx,
        fails: *std.ArrayList(State),
        pub fn part(v: @This(), p: Sexp) Error!void {
            try walkConditionPart(v.c, p, v.body);
            const saved = v.c.loop;
            defer v.c.loop = saved;
            v.c.loop = v.loop;
            try v.fails.append(v.c.arena(), try exits.exitTo(v.c, v.fail));
        }
    };
    var fails: std.ArrayList(State) = .empty;
    try rig.eachGuardPart(cond, Parts{ .c = self, .body = body, .fail = fail, .loop = loop, .fails = &fails });
    return fails.items;
}

/// The join of `states`, all relative to the current point.
pub fn joinAll(self: *Checker, states: []const State) Error!State {
    var out: State = .{ .reachable = false };
    for (states) |s| out = try self.join(out, s);
    return out;
}

/// One part of a condition (`rig.eachGuardPart`).
pub fn walkConditionPart(self: *Checker, cond: Sexp, body: Sexp) Error!void {
    // Each part is a header, its own statement: its temporaries end
    // with it, after the binding takes what it binds.
    if (cond.isKind(.as_results)) return walkResultsBinding(self, cond, body);
    if (cond.isKind(.as_match)) return walkAsMatch(self, cond, body);
    if (!cond.isKind(.as)) return walkStmt(self, cond);
    // A bare place is bound as `if ?p as x` binds it, and a part of a
    // made value in a hidden var the `if` holds, in a scope the
    // caller ends with the body's (docs/internals/INTERNALS.md, "Header
    // subjects").
    const header = headerOf(self, cond);
    const saved_held = self.held;
    defer self.held = saved_held;
    if (header == .held) try holdBase(self, cond);
    const temps_start = self.temps.items.len;
    const drops = self.stmt_drops.items.len;
    const bound = if (header != null) try walkView(self, ir.As.value(cond), .read) else try walkConsumed(self, ir.As.value(cond), .binding);
    self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
    try self.pushScopeFor(.block, body);
    try bindNew(self, ir.As.name(cond), false, false, bound);
    try dropStmtTemps(self, drops);
}

/// Walk `part` of `node`, which runs on some paths through `node`
/// only: the right side of `and`, `or`, and `??`. What follows starts
/// from the join of the state before it with the state after it.
pub fn walkMayRun(self: *Checker, part: Sexp, t: ?Tail, node: Sexp) Error!Value {
    const base = try self.here();
    const v = try walkTailPart(self, part, t);
    const s = try self.leave(base, notes.resumeAt(self, .nil, node));
    try self.apply(try self.join(stateAt(base), s));
    return v;
}

/// How the header `node` has its bare subject (`SemContext.headerOf`).
pub fn headerOf(self: *const Checker, node: Sexp) ?sema.Header {
    const ctx = self.sema;
    return ctx.headerOf(node);
}

/// Hold the value the header `node` makes of which its subject is a
/// part (`SemContext.heldBaseOf`) in a hidden var of a scope opened
/// for the construct: `var _h = <base`, whose part the construct
/// views. The caller pops the scope where the construct ends.
pub fn holdBase(self: *Checker, node: Sexp) Error!void {
    const ctx = self.sema;
    const base = ctx.heldBaseOf(node) orelse return;
    const v = try walkConsumed(self, base, .binding);
    try self.pushScopeFor(.block, node);
    const id = try self.addVar(.{ .name = notes.spanText(self, base), .decl = notes.startOf(self, base), .ty = types.exprType(self, base), .kind = .hidden }, .{ .loans = v.loans });
    self.held = .{ .base = base, .id = id };
}

/// Whether place `e` is a path from the value a header holds.
pub fn heldPath(self: *const Checker, e: Sexp) bool {
    const h = self.held orelse return false;
    const base = sema.pathRoot(e);
    return base == .list and base.list.ptr == h.base.list.ptr;
}

/// Whether `match` takes its subject, and its bindings own what they
/// bind: `match <x`, or a value made there (`storage.matchMode`).
pub fn takesSubject(self: *const Checker, match: Sexp) bool {
    const ctx = self.sema;
    return storage.matchMode(ctx, match) == .consume;
}

pub const Scrutinee = struct {
    root: ?VarId = null,
    via: Via = .owned,
    /// The matched field (`h.s`) when it is not a whole binding.
    path: []const u8 = "",
    /// The place of `root` the subject is (`resolvePlace`), which its
    /// bindings view.
    place: PathId = whole_path,
    /// The subject as written, when no var holds the value it reads
    /// (`Var.matched`); empty when the match takes it.
    shown: []const u8 = "",
    /// The place a match that reads it names, as written: `<` on it
    /// would give the bindings their fields (`Var.read_subject`).
    read_place: []const u8 = "",
};

/// Whether a `match` reads the value its subject `e` gives where
/// another value holds it (`Hands`): storage, a view, a branching
/// value that may be a name's, or a view a call returns. A value
/// made there is the match's own.
pub fn readsInPlace(self: *const Checker, e: Sexp) bool {
    return switch (types.hands(self, e).kind) {
        .place, .part_of_made, .view, .branches => true,
        .made => if (types.exprType(self, e)) |t| types.typeData(self, t) == .read_view or types.typeData(self, t) == .write_view else false,
        .jump, .none => false,
    };
}

pub fn walkMatch(self: *Checker, match: Sexp) Error!Value {
    const tail_ctx = takeTail(self, match);
    const scrut = ir.Match.subject(match);
    const saved_arm = .{ self.arm_var, self.arm_subject, self.arm_take };
    defer {
        self.arm_var = saved_arm[0];
        self.arm_subject = saved_arm[1];
        self.arm_take = saved_arm[2];
    }
    // A bare place is matched as `match ?p`; a part of a made value
    // in a hidden var the match holds (docs/internals/INTERNALS.md, "Header
    // subjects").
    const header = headerOf(self, match);
    const saved_held = self.held;
    defer self.held = saved_held;
    if (header == .held) try holdBase(self, match);
    var info: Scrutinee = .{};
    var node = scrut;
    const written = scrut.isKind(.read) or scrut.isKind(.write);
    const viewed = written or header == .viewed or header == .held;
    if (viewed) {
        if (written) node = ir.get(scrut, .operand);
        info.via = .viewed;
    }
    if (resolvePlace(self, node)) |p| {
        info.root = p.root;
        info.place = p.path;
        const v = self.vars.items[p.root];
        if (p.through_view or v.payload_view) info.via = .viewed;
        if (p.through_shared) info.via = .shared;
        if (types.exprType(self, node)) |t| if (types.typeData(self, t) == .shared) {
            info.via = .shared;
        };
        if (!p.whole) info.path = try notes.placeText(self, node);
        if (!takesSubject(self, match) and !scrut.isKind(.write)) info.read_place = notes.spanText(self, node);
    } else if (!takesSubject(self, match) and readsInPlace(self, scrut)) {
        // A value no var holds, which the match reads where it is:
        // its bindings view it, as they view a place.
        info.via = .viewed;
        if (types.exprType(self, node)) |t| if (types.typeData(self, t) == .shared) {
            info.via = .shared;
        };
        info.shown = notes.spanText(self, node);
    }
    const scrut_temps = self.temps.items.len;
    // The subject is a header: its temporaries end with it.
    const drops = self.stmt_drops.items.len;
    const scrut_value = if (header == .viewed) try walkView(self, scrut, .read) else try walk(self, scrut);
    const header_temps = try self.arena().alloc(VarId, self.stmt_drops.items.len - @min(drops, self.stmt_drops.items.len));
    for (header_temps, self.stmt_drops.items[self.stmt_drops.items.len - header_temps.len ..]) |*t, d| t.* = d.id;
    // A view the subject yields, which the match reads where it points
    // (its tag, its payloads) after the header: one that carries a
    // loan on a temporary the header made reads it after its drop.
    const ctx = self.sema;
    if (storage.holdsView(ctx, match)) {
        for (scrut_value.loans) |l| if (std.mem.findScalar(VarId, header_temps, l.root) != null) {
            const temp = self.vars.items[l.root].name;
            try notes.err(self, l.pos, "this `match` reads the view its subject returns after its header drops the temporary `{s}` it points into; bind `{s}` to a name first", .{ temp, temp });
            break;
        };
    }
    try dropStmtTemps(self, drops);
    var outlived = false;
    // The subject's loans end with its header: the match holds what
    // its value carries until an arm is chosen (`hold`), and each
    // payload binding its own loans on what it views.
    self.temps.shrinkRetainingCapacity(@min(scrut_temps, self.temps.items.len));
    // The match reads its subject again after a guard runs, to test
    // the next arm's pattern: what the subject views stays viewed while
    // the arm is chosen, through every guard. (An arm's bindings hold
    // their own loans on it.)
    var held: std.ArrayList(Loan) = .empty;
    for (scrut_value.loans) |l| if (std.mem.findScalar(VarId, header_temps, l.root) == null) try held.append(self.arena(), l);
    const hold = try self.addVar(.{ .name = "", .decl = notes.startOf(self, scrut), .kind = .hidden }, .{ .loans = held.items });

    const base = try self.here();
    // The state an arm starts from: the entry state joined with what
    // each failed guard before it left.
    var start = stateAt(base);
    var acc: ?State = null;
    var value: Value = .{};
    var catch_all = false;
    const arms = ir.Match.arms(match);
    const past = notes.resumeAt(self, .nil, match);
    for (arms, 0..) |arm, i| {
        const pattern = ir.Arm.pattern(arm);
        const guard = ir.Arm.guard(arm);
        const body = ir.Arm.body(arm);
        try self.apply(start);
        try self.pushScopeFor(.block, arm);
        self.arm_var = null;
        self.arm_subject = notes.spanText(self, scrut);
        self.arm_take = notes.takeableSubject(self, scrut);
        // A guarded arm may not run for the values its pattern
        // matches. The views the guard takes end with it.
        const bound = self.vars.items.len;
        if (try bindPattern(self, pattern, info, scrut_value) and guard == .nil) catch_all = true;
        // A binding that views a temporary the subject made would
        // outlive it.
        if (!outlived) for (bound..self.vars.items.len) |id| {
            for (self.flows.items[id].loans) |l| if (std.mem.findScalar(VarId, header_temps, l.root) != null and live.holderLive(self, @intCast(id), null)) {
                try notes.reportTempOutlived(self, l, @intCast(id));
                outlived = true;
                break;
            };
            if (outlived) break;
        };
        var failed: ?State = null;
        if (guard != .nil) {
            // A header, its own statement.
            try walkStmt(self, guard);
            // A failing guard goes on to the next arm, or past the match.
            failed = try exits.exitTo(self, .{ .to = base, .resume_at = notes.resumeBefore(self, if (i + 1 < arms.len) arms[i + 1] else .nil, past) });
        }
        // The arm is chosen: the subject is read no more.
        if (self.flows.items[hold].loans.len > 0) try self.setFlow(hold, .{});
        // The body is a statement of its own (`sema.isArmBody`): its
        // temporaries end with it, in the arm's scope.
        var v = try walkTailStmt(self, body, tail_ctx);
        v = try self.leaveScope(v);
        value = try self.valueUnion(value, v);
        const s = try self.leave(base, past);
        acc = if (acc) |a| try self.join(a, s) else s;
        if (failed) |f| start = try self.join(start, f);
    }
    // Without a catch-all arm, no arm may run.
    if (!catch_all) acc = if (acc) |a| try self.join(a, start) else start;
    try self.apply(acc orelse start);
    if (self.flows.items[hold].loans.len > 0) try self.setFlow(hold, .{});
    // The value the match held ends with it.
    if (header == .held) {
        value = try self.leaveScope(value);
    }
    return value;
}

/// `s matches .circle(r)`, a part of a condition: the one-arm `match` it is
/// (`rig.asMatchOf`), its subject reached as `walkMatch` reaches a
/// match's and its pattern bound as an arm's, in a new scope over
/// `body`, which the caller pops. The values the pattern does not
/// match go on to the `else`.
pub fn walkAsMatch(self: *Checker, part: Sexp, body: Sexp) Error!void {
    const match = rig.asMatchOf(part);
    const scrut = ir.Match.subject(match);
    const pattern = ir.Arm.pattern(rig.asMatchArm(part));
    const saved_arm = .{ self.arm_var, self.arm_subject, self.arm_take };
    defer {
        self.arm_var = saved_arm[0];
        self.arm_subject = saved_arm[1];
        self.arm_take = saved_arm[2];
    }
    // A part of a made value in a hidden var the condition holds, in
    // a scope the caller ends with the body's.
    const header = headerOf(self, match);
    const saved_held = self.held;
    defer self.held = saved_held;
    if (header == .held) try holdBase(self, match);
    var info: Scrutinee = .{};
    var node = scrut;
    const written = scrut.isKind(.read) or scrut.isKind(.write);
    const viewed = written or header == .viewed or header == .held;
    if (viewed) {
        if (written) node = ir.get(scrut, .operand);
        info.via = .viewed;
    }
    if (resolvePlace(self, node)) |p| {
        info.root = p.root;
        info.place = p.path;
        const v = self.vars.items[p.root];
        if (p.through_view or v.payload_view) info.via = .viewed;
        if (p.through_shared) info.via = .shared;
        if (types.exprType(self, node)) |t| if (types.typeData(self, t) == .shared) {
            info.via = .shared;
        };
        if (!p.whole) info.path = try notes.placeText(self, node);
        if (!takesSubject(self, match) and !scrut.isKind(.write)) info.read_place = notes.spanText(self, node);
    } else if (!takesSubject(self, match) and readsInPlace(self, scrut)) {
        info.via = .viewed;
        if (types.exprType(self, node)) |t| if (types.typeData(self, t) == .shared) {
            info.via = .shared;
        };
        info.shown = notes.spanText(self, node);
    }
    const scrut_temps = self.temps.items.len;
    // The subject is a header: its temporaries end with it.
    const drops = self.stmt_drops.items.len;
    const scrut_value = if (header == .viewed) try walkView(self, scrut, .read) else try walk(self, scrut);
    const header_temps = try self.arena().alloc(VarId, self.stmt_drops.items.len - @min(drops, self.stmt_drops.items.len));
    for (header_temps, self.stmt_drops.items[self.stmt_drops.items.len - header_temps.len ..]) |*t, d| t.* = d.id;
    const ctx = self.sema;
    if (storage.holdsView(ctx, match)) {
        for (scrut_value.loans) |l| if (std.mem.findScalar(VarId, header_temps, l.root) != null) {
            const temp = self.vars.items[l.root].name;
            try notes.err(self, l.pos, "this `as` reads the view its subject returns after its header drops the temporary `{s}` it points into; bind `{s}` to a name first", .{ temp, temp });
            break;
        };
    }
    try dropStmtTemps(self, drops);
    // The subject's loans end with its header: each payload binding
    // holds its own loans on what it views.
    self.temps.shrinkRetainingCapacity(@min(scrut_temps, self.temps.items.len));
    try self.pushScopeFor(.block, body);
    self.arm_var = null;
    self.arm_subject = notes.spanText(self, scrut);
    self.arm_take = notes.takeableSubject(self, scrut);
    const bound = self.vars.items.len;
    _ = try bindPattern(self, pattern, info, scrut_value);
    // A binding that views a temporary the subject made would outlive
    // it.
    for (bound..self.vars.items.len) |id| {
        for (self.flows.items[id].loans) |l| if (std.mem.findScalar(VarId, header_temps, l.root) != null and live.holderLive(self, @intCast(id), null)) {
            return notes.reportTempOutlived(self, l, @intCast(id));
        };
    }
}

/// Bind a pattern's names. Returns true for a catch-all pattern.
pub fn bindPattern(self: *Checker, pattern: Sexp, info: Scrutinee, scrut_value: Value) Error!bool {
    switch (pattern) {
        .src => {
            const name = types.text(self, pattern);
            if (std.mem.eql(u8, name, "_")) return true;
            // Literal patterns match one value; an identifier binds the
            // whole scrutinee and matches everything.
            if (!rig.isIdentStart(name[0]) or std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) return false;
            // A module constant's name compares with its value.
            const ctx = self.sema;
            if (sema.patternConst(ctx, pattern) != null) return false;
            _ = try bindPayload(self, pattern, info, scrut_value);
            return true;
        },
        .list => {
            if (pattern.isKind(.variant_pattern)) {
                const ctx = self.sema;
                for (ctx.payloadBindings(pattern) orelse &.{}) |b| {
                    if (b == .src and !std.mem.eql(u8, types.text(self, b), "_")) _ = try bindPayload(self, b, info, scrut_value);
                }
            }
            // Alternatives that bind bind one symbol per name, at the
            // first alternative that binds it; every alternative binds
            // the same names with the same types, so they are bound
            // as that one binds them.
            if (pattern.isKind(.alt_pattern)) for (ir.AltPattern.alts(pattern)) |alt| {
                if (!alt.isKind(.variant_pattern) or !rig.matchesBinds(self.sema.source, alt)) continue;
                _ = try bindPattern(self, alt, info, scrut_value);
                break;
            };
            // `g: E =>` binds the whole error, narrowed to a set, as a
            // payload is bound: a view of the matched value under
            // `match e`, the value itself under `match <e`.
            if (pattern.isKind(.set_pattern)) {
                const b = ir.SetPattern.name(pattern);
                if (b == .src and !std.mem.eql(u8, types.text(self, b), "_")) _ = try bindPayload(self, b, info, scrut_value);
            }
            return false;
        },
        else => return false,
    }
}

pub fn bindPayload(self: *Checker, node: Sexp, info: Scrutinee, scrut_value: Value) Error!VarId {
    const pos = node.src.pos;
    const ty = types.symType(self, pos);
    // The bytes of a String field are a view of it, as any read view of
    // a field is, though a `?String` copies.
    const text_view = if (self.sema.payloadFieldOf(node)) |field| sema.viewsStringBytes(self.sema, field, ty orelse sema.type_invalid) else false;
    var v: Var = .{ .name = types.text(self, node), .decl = pos, .ty = ty, .kind = .pattern, .ref = if (text_view) .read else types.refOfType(self, ty), .read_subject = info.read_place };
    var loans: []const Loan = &.{};
    // A payload that copies (`sema.copies`) is copied out of the
    // matched value, which stays whole. A view the match makes of a
    // field (`match ?e`) views the matched value instead.
    const copied = types.copies(self, ty) and v.ref == .none;
    // A copy views what the matched value views.
    if (copied and !types.mayCarryLoan(self, ty)) generic.taintGeneric(self, ty, scrut_value);
    if (copied and types.mayCarryLoan(self, ty)) {
        const r_loans: []const Loan = if (info.root) |r| self.flows.items[r].loans else &.{};
        loans = (try origins.carry(self, ty, .{ .loans = try self.unionLoans(scrut_value.loans, r_loans) })).loans;
    } else if (!copied) {
        // The binding views the matched value unless the match takes
        // it: a place's (`alias_of`), or one no var holds, which a
        // binding of a view type views by its type, and any other
        // (a `T` of a generic body) by this fact.
        v.payload_view = info.root != null or (info.shown.len > 0 and v.ref == .none);
        if (info.root == null and v.payload_view) {
            v.via = info.via;
            v.matched = info.shown;
        }
        if (info.root) |r| {
            v.alias_of = r;
            v.alias_path = info.path;
            v.via = info.via;
            // The binding views the matched value: its root stays
            // viewed (under a write view when the view holds a write
            // view, which must not be reached twice), and a viewed
            // root passes on a view of what it holds.
            const on: Loan = .{ .root = r, .path = info.place, .kind = if (types.carriesWriteView(self, ty)) .write else .read, .pos = pos };
            loans = try self.oneLoan(if (info.via == .viewed) throughBinding(self, r, on) else on);
            if (info.via == .viewed) loans = try self.unionLoans(loans, self.flows.items[r].loans);
        } else {
            loans = scrut_value.loans;
        }
    }
    // A read match's binding that is no plain data of a subject emit
    // matches as a copy (not `storage.matchesInPlace`) is usable
    // within its arm only, so a view of it never outlives the copy
    // (docs/internals/INTERNALS.md, "Header subjects").
    const ctx = self.sema;
    if (ctx.symbolAt(pos)) |sym| if (ctx.symbols.items[sym].flags.arm_view) {
        const arm = self.arm_var orelse blk: {
            const id = try self.addVar(.{ .name = "", .decl = pos, .kind = .hidden, .arm_of = self.arm_subject, .arm_take = self.arm_take }, .{});
            self.arm_var = id;
            break :blk id;
        };
        loans = try self.unionLoans(loans, try self.oneLoan(.{ .root = arm, .kind = .read, .pos = pos }));
    };
    return self.addVar(v, .{ .loans = loans });
}

// -----------------------------------------------------------------------------
// Loops
// -----------------------------------------------------------------------------

pub const LoopSpec = struct {
    /// The `while` or `for` node.
    node: Sexp,
    cond: ?Sexp = null,
    cond_always_true: bool = false,
    /// `while a as x` or `while a as x and ...`: a condition of parts
    /// (`walkConditionParts`).
    cond_binds: bool = false,
    cont: ?Sexp = null,
    body: Sexp,
    /// `for` loops: element bindings and the source loan.
    elem1: Sexp = .nil,
    elem2: Sexp = .nil,
    source_root: ?VarId = null,
    /// The place of `source_root` the source is (`resolvePlace`).
    source_path: PathId = whole_path,
    /// `for x in <v`, or a collection the source makes: the loans it
    /// held, which its elements carry.
    moved: []const Loan = &.{},
    /// A source made in the header and walked in place (a call's
    /// view): the loans its value carries, which the loop holds for
    /// its whole run, as it holds a place's loan, while the header's
    /// own loans end with it (Core §3).
    held: []const Loan = &.{},
    source_loan: LoanKind = .read,
    source_pos: u32 = 0,
    resource_list: bool = false,
    /// The loop walks a collection it does not consume.
    elem_view: bool = false,
};

/// `if f() as a, b`: each name is a new binding that takes its result,
/// as a destructure's target does (`walkDestructure`), in a scope over
/// `body`, which the caller pops. The loans taken to make the results
/// end with the header, as `as`'s do, and so do those of a result no
/// name takes.
pub fn walkResultsBinding(self: *Checker, cond: Sexp, body: Sexp) Error!void {
    const value = ir.AsResults.value(cond);
    const names = ir.AsResults.names(cond).items();
    const temps_start = self.temps.items.len;
    const drops = self.stmt_drops.items.len;
    const saved_results = self.results_of;
    defer self.results_of = saved_results;
    self.results_of = null;
    const whole = try walkConsumed(self, value, .binding);
    const parts: []const Value = blk: {
        if (self.results_of) |r| if (sameNode(r.node, value) and r.parts.len == names.len) break :blk r.parts;
        const all = try self.arena().alloc(Value, names.len);
        @memset(all, whole);
        break :blk all;
    };
    self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
    try self.pushScopeFor(.block, body);
    const saved_part = self.part_value;
    defer self.part_value = saved_part;
    for (names, parts) |n, part| {
        if (!n.isKind(.set)) continue;
        self.part_value = part;
        try walkSet(self, n);
    }
    try dropStmtTemps(self, drops);
}

/// A statement that gives a value (`sema.yieldsValue`).
pub fn isValue(self: *const Checker, e: Sexp) bool {
    return sema.yieldsValue(self.source, e);
}

pub fn walkWhile(self: *Checker, node: Sexp) Error!Value {
    const cond = ir.While.cond(node);
    const step = ir.While.step(node);
    return walkLoop(self, .{
        .node = node,
        .cond = cond,
        .cond_binds = rig.isAsPart(cond) or rig.isConditionJoin(cond),
        .cond_always_true = cond == .src and std.mem.eql(u8, types.text(self, cond), "true"),
        .cont = if (step == .nil) null else step,
        .body = ir.While.body(node),
    });
}

pub fn walkFor(self: *Checker, node: Sexp) Error!Value {
    const mode = ir.For.mode(node).tag;
    const source = ir.For.source(node);
    var spec: LoopSpec = .{
        .node = node,
        .body = ir.For.body(node),
        .elem1 = ir.For.@"var"(node),
        .elem2 = ir.For.index(node),
    };
    // A bare place is walked as `for x in ?p`, an array made here as
    // `for x in <e`, and a part of a made value in a hidden var the
    // loop holds (docs/internals/INTERNALS.md, "Header subjects").
    const header = headerOf(self, node);
    const saved_held = self.held;
    defer self.held = saved_held;
    if (header == .held) try holdBase(self, node);
    // The source is a header: its temporaries end with it, before
    // the loop walks what it gives.
    const drops = self.stmt_drops.items.len;
    // A source the loop consumes (`storage.forConsumes`) is taken,
    // as emit hands its elements over.
    const consumes = storage.forConsumes(self.sema, node);
    if (mode == .move) {
        spec.moved = (try walkMove(self, source)).loans;
    } else if (header == .taken or consumes) {
        spec.moved = (try walkConsumed(self, source, .binding)).loans;
    } else {
        spec.elem_view = true;
        const found = self.errors_found;
        const temps_start = self.temps.items.len;
        const value = try walk(self, source);
        // The type checker let the loop read a source a call gives in
        // place where the recorded fact says its loans name only places
        // (`storage.livesIn`, CORE §9); the loans walked here agree, or
        // the fact is wrong.
        if (self_check) if (storage.decided(self.sema, source, .lives_in)) |roots| if (roots.onlyPlaces()) if (headerTempLoan(self, drops, value) != null) {
            const lc = diag.lineCol(self.source, notes.startOf(self, source));
            std.debug.panic("{d}:{d}: internal error: the loop's source was decided to live only in places (`lives_in`), but its loans name a value made in its header", .{ lc.line, lc.col });
        };
        if (headerTempLoan(self, drops, value)) |l| try notes.reportTempOutlived(self, l, null);
        // The elements of a collection the source makes (an array of
        // views, a call's result) carry the views it holds.
        if (resolvePlace(self, source) == null) {
            spec.moved = value.loans;
            spec.held = value.loans;
            spec.source_pos = notes.startOf(self, source);
            self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
        }
        // A source already reported (used while a write loan is live) is
        // not reported again as a conflicting view.
        // A read view held in a binding or a part of a value (`all`,
        // `s.names`, a `?List[T]`) is read as any view is, and its
        // elements view what it views, not the place holding it: the
        // loop walks the view it read, as `?all[0]` does.
        const held_view = if (resolvePlace(self, source) != null) mode != .write and types.refOfType(self, types.exprType(self, source)) == .read else false;
        if (held_view) {
            spec.moved = value.loans;
            // Its elements are slot views, as `for x in ?p`'s are.
            spec.resource_list = sema.forViewsSlot(self.sema, node);
        }
        if (self.errors_found == found and !held_view) if (resolvePlace(self, source)) |p| {
            const id = p.root;
            const kind: LoanKind = if (mode == .write) .write else .read;
            spec.source_root = id;
            spec.source_path = p.path;
            spec.source_loan = kind;
            spec.source_pos = notes.startOf(self, source);
            spec.resource_list = sema.forViewsSlot(self.sema, node);
            if (!self.flowLive(id) or try rules.conflicts(self, id, p.path, if (kind == .write) .write else .read, spec.source_pos)) {
                spec.source_root = null;
            }
        };
    }
    try dropStmtTemps(self, drops);
    var v = try walkLoop(self, spec);
    // The value the loop held ends with it.
    if (header == .held) v = try self.leaveScope(v);
    return v;
}

/// `(labeled name stmt)`: a labeled loop, or a labeled `match`, `raw`
/// block, or block, which `break $name` leaves.
pub fn walkLabeled(self: *Checker, node: Sexp) Error!Value {
    const stmt = ir.Labeled.stmt(node);
    if (stmt.isKind(.@"while") or stmt.isKind(.@"for")) {
        self.pending_reads = rules.readsValue(self, node);
        const v = try walk(self, stmt);
        self.pending_reads = false;
        return v;
    }
    var ctx: LoopCtx = .{ .node = stmt, .point = try self.here(), .scope_depth = self.scopes.items.len, .parent = self.loop, .is_loop = false };
    self.loop = &ctx;
    defer self.loop = ctx.parent;
    try walkStmt(self, stmt);
    try self.joinAt(ctx.point, ctx.breaks.items, notes.resumeAt(self, .nil, node));
    return .{};
}

pub fn walkLoop(self: *Checker, spec: LoopSpec) Error!Value {
    var ctx: LoopCtx = .{ .node = spec.node, .point = try self.here(), .scope_depth = self.scopes.items.len, .parent = self.loop, .start = notes.extent(self, spec.node).lo, .reads = self.pending_reads or rules.readsValue(self, spec.node) };
    self.pending_reads = false;
    self.loop = &ctx;
    defer self.loop = ctx.parent;
    const entry = ctx.point;

    // The loop head: relative to the entry, the join of the entry, the
    // end of the body, and every `continue`.
    var head = stateAt(entry);
    // Inside another loop's fixpoint nothing is reported, so the last
    // round, which walked the body from the settled head, is the
    // final walk.
    const outer_quiet = self.quiet > 0;
    self.quiet += 1;
    // The join only grows the state, over finitely many variables and
    // loans, so this reaches a fixpoint. The bound is a backstop: a
    // loop the analysis cannot settle is rejected, never accepted.
    var rounds: usize = 0;
    var it: Iteration = undefined;
    const converged = while (rounds < 100_000) : (rounds += 1) {
        try self.apply(head);
        it = try loopIteration(self, spec, &ctx);
        try self.rewind(entry);
        const next = try self.join(head, it.back);
        if (self.statesEql(next, head)) break true;
        head = next;
    } else false;
    self.quiet -= 1;
    if (!converged) try notes.errAt(self, spec.body, "this loop is too complex for the ownership checker; split it into smaller functions", .{});

    if (!outer_quiet or !converged) {
        try self.apply(head);
        it = try loopIteration(self, spec, &ctx);
        try self.rewind(entry);
    }
    try self.apply(try joinAll(self, it.exit));
    // A `loop` used as a value yields a `break` value.
    self.loop = ctx.parent;
    try self.joinAt(ctx.point, ctx.breaks.items, notes.resumeAt(self, .nil, spec.node));
    return ctx.value;
}

/// One walk of a loop: the states at the back edge and where the
/// condition fails, relative to the loop entry.
pub const Iteration = struct { back: State, exit: []const State };

pub fn loopIteration(self: *Checker, spec: LoopSpec, ctx: *LoopCtx) Error!Iteration {
    ctx.breaks.clearRetainingCapacity();
    ctx.conts.clearRetainingCapacity();
    ctx.step_conts.clearRetainingCapacity();
    ctx.step_point = null;
    ctx.value = .{};
    const depth = self.scopes.items.len;
    // The loop ends when its condition fails: for a binding
    // condition, when a part fails, with the bindings before it gone.
    // A failing part leaves the loop.
    const fail: ExitTo = .{ .to = ctx.point, .resume_at = notes.resumeAt(self, .nil, spec.node) };
    var exit: []const State = &.{};
    if (spec.cond_binds) {
        exit = try walkConditionParts(self, spec.cond.?, spec.body, fail, ctx.parent);
    } else {
        if (spec.cond) |c| try walkStmt(self, c);
        if (!spec.cond_always_true) exit = try self.arena().dupe(State, &.{try exits.exitTo(self, fail)});
    }
    // The loop is `loop { x = a or break; body: { body }; step }`
    // (docs/internals/INTERNALS.md, "Loops"): a `continue` in the body leaves
    // the body's block for the step. A step that runs after the body
    // (`storage.StepPoint`) runs in the bindings' scope, after the
    // body's own scope ends; any other runs after the bindings' scope
    // ends.
    const step_inside = spec.node.isKind(.@"while") and storage.stepPoint(self.sema, spec.node) == .after_body;
    if (step_inside) {
        ctx.step_point = try self.here();
        ctx.step_depth = self.scopes.items.len;
    }
    try self.pushScopeFor(.block, spec.body);
    try bindLoopElems(self, spec);
    try walkStmt(self, spec.body);
    if (step_inside) {
        while (self.scopes.items.len > ctx.step_depth) try self.popScope();
        if (ctx.step_conts.items.len > 0) try self.joinAt(ctx.step_point.?, ctx.step_conts.items, notes.stepAt(self, spec.node));
        ctx.step_point = null;
        try walkStep(self, spec.cont.?, spec.node);
    }
    while (self.scopes.items.len > depth) try self.popScope();

    // A `continue` and the end of the body go back to the loop's
    // head through any other step, as does a `continue` in the
    // condition (which the type checker rejects when the step runs
    // after the body, since it would skip binding what the step
    // reads); a `continue` in the step ends it.
    if (ctx.conts.items.len > 0) try self.joinAt(ctx.point, ctx.conts.items, ctx.start);
    if (!step_inside) if (spec.cont) |c| {
        ctx.conts.clearRetainingCapacity();
        try walkStep(self, c, spec.node);
        if (ctx.conts.items.len > 0) try self.joinAt(ctx.point, ctx.conts.items, ctx.start);
    };
    return .{ .back = try exits.exitTo(self, .{ .to = ctx.point, .resume_at = ctx.start }), .exit = exit };
}

/// Walk the step of `while` loop `node`, which runs after its body
/// (`stepAt`).
pub fn walkStep(self: *Checker, step: Sexp, node: Sexp) Error!void {
    const saved = self.step_at;
    defer self.step_at = saved;
    if (saved == null) self.step_at = notes.stepAt(self, node);
    try walkStmt(self, step);
}

pub fn bindLoopElems(self: *Checker, spec: LoopSpec) Error!void {
    var elem_loans: []const Loan = &.{};
    if (spec.source_root) |root| if (self.flowLive(root)) {
        // The source stays viewed for the whole loop; a write view a
        // binding holds passes on what it views (`throughBinding`).
        const on: Loan = .{ .root = root, .path = spec.source_path, .kind = spec.source_loan, .pos = spec.source_pos };
        elem_loans = if (throughBinding(self, root, on).deref) (try viewOn(self, root, on)).loans else try self.oneLoan(on);
        _ = try self.addVar(.{ .name = "", .decl = spec.source_pos, .kind = .hidden }, .{ .loans = elem_loans });
    };
    if (spec.held.len > 0) _ = try self.addVar(.{ .name = "", .decl = spec.source_pos, .kind = .hidden }, .{ .loans = spec.held });
    if (spec.elem1 == .src) {
        const pos = spec.elem1.src.pos;
        const ty = types.symType(self, pos);
        _ = try self.addVar(.{
            .name = types.text(self, spec.elem1),
            .decl = pos,
            .ty = ty,
            .kind = .loop_elem,
            .ref = types.refOfType(self, ty),
            .loop_view = spec.resource_list,
            .elem_view = spec.elem_view,
            .elem_of = if (elem_loans.len > 0) spec.source_root else null,
        }, .{ .loans = if (types.mayCarryLoan(self, ty)) try self.unionLoans(elem_loans, spec.moved) else generic.taintedNone(self, ty, .{ .loans = try self.unionLoans(elem_loans, spec.moved) }) });
    }
    if (spec.elem2 == .src) {
        const pos = spec.elem2.src.pos;
        _ = try self.addVar(.{ .name = types.text(self, spec.elem2), .decl = pos, .ty = types.symType(self, pos), .kind = .loop_elem }, .{});
    }
}

/// `panic(a, b)`: its values are read as `print` reads them, and the
/// program ends there. No scope is left: no drop or `defer` runs, so
/// nothing after it is reached.
pub fn walkPanic(self: *Checker, node: Sexp) Error!void {
    const temps_start = self.temps.items.len;
    try walkReadArgs(self, ir.Panic.args(node));
    self.temps.shrinkRetainingCapacity(@min(temps_start, self.temps.items.len));
    self.reachable = false;
}

/// The binding `break value` moves out: a bare name declared since
/// the loop's entry (`vars`), so its scope ends at this `break`,
/// whose value owns, as `return x` moves one (`returnMoves`).
pub fn breakMovesName(self: *Checker, value: Sexp, vars: u32) Error!?VarId {
    if (value != .src) return null;
    const id = self.find(value) orelse return null;
    if (id < vars) return null;
    const v = self.vars.items[id];
    if (v.closure or v.loop_view or v.capture_resource or v.alias_of != null or !returnMoves(self, v)) return null;
    try rules.checkNoImplicitCopy(self, value, .brk, true);
    return id;
}
