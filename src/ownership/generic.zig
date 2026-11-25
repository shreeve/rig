//! Generic bodies: what a body over type parameters requires of its
//! instances (`plain_reqs`, callables, associated types), checked at
//! each instance.

const std = @import("std");
const parser = @import("../parser.zig");
const sema = @import("../sema.zig");
const storage = @import("../storage.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const TypeId = sema.TypeId;
const SymbolId = sema.SymbolId;
const SymbolRef = sema.SymbolRef;
const Error = std.mem.Allocator.Error;
const state = @import("state.zig");
const transfer = @import("transfer.zig");
const origins = @import("origins.zig");
const types = @import("types.zig");
const notes = @import("notes.zig");
const Checker = state.Checker;
const Loan = state.Loan;
const PlainRequirement = state.PlainRequirement;
const Value = state.Value;
const VarId = state.VarId;
const containsLoan = state.containsLoan;
const unsigiled = state.unsigiled;

// -----------------------------------------------------------------------------
// Generic bodies: what an instance may do
// -----------------------------------------------------------------------------

/// A type parameter with bounds is checked against its bounds alone:
/// a body copies a `T` only when its bounds name `Copy`, and stores
/// one where no loan is tracked only when they name `Owned`.
pub fn checkBoundedCopies(self: *Checker) Error!void {
    const ctx = self.sema;
    const a = self.arena();
    for (self.plain_reqs.items[0..self.own_plain_reqs]) |r| {
        // A function value's requirement is no bound's: each instance,
        // or each call of the method, answers it (`checkCallables`).
        if (r.item.len > 0 or r.callable != null) continue;
        const sym = ctx.symbols.items[r.param];
        if (!sema.checkedByBounds(sym)) continue;
        // Where `$plain(T)` has held, a `T` copies and holds no loan.
        if (sema.narrowedAt(ctx, 0, r.pos, r.param)) continue;
        const api: sema.Api = if (r.view) .Owned else .Copy;
        if (sema.boundApis(ctx, sym).contains(api)) continue;
        // A `pub` declaration's parameter: at the parameter, with the
        // bounds to write, and a note where the body does it.
        if (try sema.statedMessage(ctx, a, r.param, .{ .api = api }, try sema.boundUse(a, api, sym.name, ""))) |msg| {
            try notes.err(self, sym.decl_pos, "{s}", .{msg});
            try notes.note(self, r.pos, "here", .{});
            continue;
        }
        const what = if (r.view) try std.fmt.allocPrint(a, "a value that holds no view, which {s} keeps", .{r.home.keeper()}) else if (r.element) "taking an element its collection still owns" else "a copy";
        try notes.err(self, r.pos, "{s}", .{try sema.unboundedMessage(ctx, a, sym, api, what)});
    }
}

/// Generic bodies are checked once, for a `T` that may own a resource.
/// Each instantiation the module makes must fit that: an argument
/// with drop glue only where the bodies never copy a `T`, no write
/// view in an argument (a write view is never stored in a value),
/// and a view only where the body stores no `T` where no loan is
/// tracked. A method's instance checks its own parameters; its
/// type's are checked with self's instance. An instance an earlier
/// module made is checked there (`sema.checkedBefore`).
pub fn checkInstantiations(self: *Checker) Error!void {
    const ctx = self.sema;
    var key: sema.InstanceKey = .{};
    defer key.deinit(ctx.allocator);
    for (ctx.fn_instances.items) |f| {
        if (try sema.checkedBefore(ctx, try key.ofFn(ctx, f.inst)) != null) continue;
        const shown = try sema.formatFnInstanceIn(ctx, self.arena(), f.inst);
        for (f.inst.ownParams(), f.inst.ownArgs()) |param, arg| {
            if (types.carriesWriteView(self, arg)) {
                // The call's instance of the API's method reports it.
                if (f.through_api) continue;
                const pname = sema.symbolAt(ctx, param).name;
                try notes.err(self, f.site, "`{s}` cannot use `{s} = {s}`: a write view is never stored inside a value; take `!{s}` in its signature instead", .{ shown, pname, try sema.formatTypeIn(ctx, self.arena(), arg), pname });
                continue;
            }
            try checkCopies(self, f.site, shown, param, arg, f.inst.subst());
            try checkViews(self, f.site, shown, param, arg, f.inst.subst());
            try checkCallables(self, f.site, shown, param, arg, f.inst.subst(), false);
            if (try checkItems(self, f.site, shown, param, arg, f.inst.subst())) if (f.via) |via| {
                const by = switch (via) {
                    .type => |t| try sema.formatTypeIn(ctx, self.arena(), t),
                    .func => |g| try sema.formatFnInstanceIn(ctx, self.arena(), g),
                };
                try notes.note(self, f.site, "`{s}` is made by `{s}`", .{ shown, by });
            };
        }
    }
    var it = ctx.instantiation_sites.iterator();
    while (it.next()) |entry| {
        const pn = switch (ctx.types.get(entry.key_ptr.*)) {
            .parameterized_nominal => |pn| pn,
            else => continue,
        };
        const base = sema.symbolAt(ctx, pn.sym).*;
        if (base.decl_pos == sema.builtin_decl_pos) continue;
        if (base.type_params == null) continue;
        if (try sema.checkedBefore(ctx, try key.ofType(ctx, entry.key_ptr.*)) != null) continue;
        const site = entry.value_ptr.*;
        const shown = try sema.formatTypeIn(ctx, self.arena(), entry.key_ptr.*);
        for (sema.paramRefs(ctx, pn.sym), 0..) |param, i| {
            if (i >= pn.args.len) break;
            const arg = pn.args[i];
            const pname = sema.symbolAt(ctx, param).name;
            const aname = try sema.formatTypeIn(ctx, self.arena(), arg);
            if (types.carriesWriteView(self, arg)) {
                try notes.err(self, site, "`{s}` cannot use `{s} = {s}`: a write view is never stored inside a value", .{ shown, pname, aname });
                continue;
            }
            const subst: sema.TypeSubst = .{ .params = sema.paramRefs(ctx, pn.sym), .args = pn.args };
            try checkCopies(self, site, shown, param, arg, subst);
            try checkViews(self, site, shown, param, arg, subst);
            try checkCallables(self, site, shown, param, arg, subst, true);
            _ = try checkItems(self, site, shown, param, arg, subst);
        }
    }
}

/// An instance whose argument for `param` gives one of its associated
/// types what may view memory the argument owns
/// (`SemContext.item_views`), where a generic body holds a value of
/// that associated type past a change of the `param` it came from
/// (`PlainRequirement.item`). Whether it was reported.
pub fn checkItems(self: *Checker, site: u32, shown: []const u8, param: SymbolRef, arg: TypeId, subst: sema.TypeSubst) Error!bool {
    const ctx = self.sema;
    const on = reqsOf(self, param);
    for (on.list) |r0| {
        const r = on.on(ctx, r0, param) orelse continue;
        if (r.item.len == 0) continue;
        if (!try sema.liveAt(ctx, r.module_id, r.pos, subst.params, subst.args)) continue;
        const assoc = for (on.home.symbols.items[param.sym].assoc) |a| {
            const of = on.home.symbols.items[a].assoc_of orelse continue;
            if (std.mem.eql(u8, of.name, r.item)) break a;
        } else continue;
        const item = ctx.item_views.get(.{ .assoc = on.home.ref(assoc), .base = arg }) orelse continue;
        const aname = on.home.symbols.items[assoc].name;
        const pname = on.home.symbols.items[param.sym].name;
        const iname = try sema.formatTypeIn(ctx, self.arena(), item);
        const bname = try sema.formatTypeIn(ctx, self.arena(), arg);
        try notes.err(self, site, "`{s}` cannot use `{s} = {s}`: a `{s}` may view memory `{s}` owns, and the generic body holds an `{s}` past a change of the `{s}` it came from; use `{s}` itself, or give items that own what they hold", .{ shown, aname, iname, iname, bname, aname, pname, bname });
        try notes.noteIn(self, r.module_id, r.pos, "the `{s}` changes here while an `{s}` it gave is held", .{ pname, aname });
        return true;
    }
    return false;
}

/// An instance whose argument for `param` holds a view, or a `?String`,
/// which may view a String, where a generic body stores a `param`
/// where no loan is tracked.
pub fn checkViews(self: *Checker, site: u32, shown: []const u8, param: SymbolRef, arg: TypeId, subst: sema.TypeSubst) Error!void {
    const ctx = self.sema;
    if (!types.mayCarryLoan(self, arg)) return;
    const pname = sema.symbolAt(ctx, param).name;
    const on = reqsOf(self, param);
    for (on.list) |r0| {
        const r = on.on(ctx, r0, param) orelse continue;
        if (!r.view) continue;
        if (!try sema.liveAt(ctx, r.module_id, r.pos, subst.params, subst.args)) continue;
        const why = (try sema.objectLoanReason(ctx, self.arena(), arg)) orelse if (sema.holdsMarkedView(ctx, arg)) "a view keeps what it views read-only" else "a `?String` may view a String (a `Static` holds no view)";
        try notes.err(self, site, "`{s}` cannot use `{s} = {s}`: the generic body {s}, which holds no view, and {s}", .{ shown, pname, try sema.formatTypeIn(ctx, self.arena(), arg), try r.home.doing(self.arena(), pname), why });
        try notes.noteIn(self, r.module_id, r.pos, "`{s}` {s}", .{ pname, r.home.site() });
        return;
    }
}

/// An instance whose argument for `param` can hold a view, where a
/// generic body gives a function value a view of memory the body
/// owns and may put it in a `param` the body holds by value
/// (`PlainRequirement.callable`): refused where the function value's
/// type, at the instance, may keep the view there. At a type's
/// instance (`at_type`), a requirement a method's body makes is left
/// to each call of the method (`checkMethodCalls`).
pub fn checkCallables(self: *Checker, site: u32, shown: []const u8, param: SymbolRef, arg: TypeId, subst: sema.TypeSubst, at_type: bool) Error!void {
    if (!types.mayCarryLoan(self, arg)) return;
    const on = reqsOf(self, param);
    for (on.list) |r0| {
        const r = on.on(self.sema, r0, param) orelse continue;
        if (r.callable == null) continue;
        if (at_type and r.method != null) continue;
        if (try callableRefuses(self, r, subst)) |inst| {
            try reportCallable(self, on.home, site, shown, r, arg, inst);
            return;
        }
    }
}

/// The type of requirement `r`'s function value at `subst`, when that
/// instance refuses it: one that, at its arguments, may keep a view
/// argument's view in what it writes (its default origins, Core
/// sentence 7), or, for a result the body holds, gives a result that
/// can hold a view, its own or an argument's. Null where it does not,
/// or where the type still names a parameter another instance binds.
pub fn callableRefuses(self: *Checker, r: PlainRequirement, subst: sema.TypeSubst) Error!?TypeId {
    const ctx = self.sema;
    const interner = self.interner;
    if (!try sema.liveAt(ctx, r.module_id, r.pos, subst.params, subst.args)) return null;
    const inst = try sema.substituteType(interner, r.callable.?, subst);
    if (ctx.typeInfo(inst).has_type_var or sema.containsPoison(ctx, inst)) return null;
    const f = sema.calledFn(ctx, inst) orelse return null;
    if (r.in_result) return if (sema.mayHoldView(ctx, f.returns)) inst else null;
    // The views it is passed, not the function values: what one of
    // those holds is its own (Core sentence 7).
    var viewed: sema.ParamMask = 0;
    for (f.params, 0..) |pt, i| if (sema.viewParam(ctx, pt) and sema.calledFn(ctx, pt) == null) {
        viewed |= sema.paramBit(i);
    };
    var scratch = std.heap.ArenaAllocator.init(self.gpa);
    defer scratch.deinit();
    const o = try sema.defaultOrigins(ctx, scratch.allocator(), f);
    return if (o.stores & viewed != 0) inst else null;
}

/// `shown` cannot use `param = arg` (requirement `r`): at `site`, with
/// a note at the body's call. `inst` is the function value's type
/// there.
pub fn reportCallable(self: *Checker, home: *const sema.SemContext, site: u32, shown: []const u8, r: PlainRequirement, arg: TypeId, inst: TypeId) Error!void {
    const ctx = self.sema;
    const a = self.arena();
    const pname = home.symbols.items[r.param].name;
    const aname = try sema.formatTypeIn(ctx, a, arg);
    const fname = try sema.formatTypeIn(ctx, a, inst);
    if (r.in_result) {
        try notes.err(self, site, "`{s}` cannot use `{s} = {s}`: the generic body holds as a `{s}` what a `{s}` gives when passed a view, and tracks no view in it, but a `{s}` can hold a view; use a `{s}` that owns what it holds", .{ shown, pname, aname, pname, fname, aname, pname });
        try notes.noteIn(self, r.module_id, r.pos, "the body holds the result as a `{s}` here", .{pname});
    } else {
        try notes.err(self, site, "`{s}` cannot use `{s} = {s}`: the generic body passes a `{s}` a view beside a write view of a `{s}` it holds, whose views it does not track, and a `{s}` can hold the view; use a `{s}` that owns what it holds", .{ shown, pname, aname, fname, pname, aname, pname });
        try notes.noteIn(self, r.module_id, r.pos, "the body passes the views here", .{});
    }
}

/// The function value's type `callable` must keep no view of memory
/// the body owns in a value of a type parameter's type, at each
/// instance (`PlainRequirement.callable`): through what it writes, or,
/// `in_result`, through its result, which the body holds as one.
/// Recorded on the type parameters that hold the view: those of its
/// write parameters' types, or of its result's.
pub fn requireCallable(self: *Checker, pos: u32, callable: TypeId, in_result: bool) Error!void {
    const ctx = self.sema;
    if (!ctx.typeInfo(callable).has_type_var) return;
    const f = sema.calledFn(ctx, callable) orelse return;
    var held: std.ArrayList(SymbolId) = .empty;
    if (in_result) {
        try sema.reachedTypeVars(ctx, f.returns, &held, self.arena());
    } else for (f.params) |pt| {
        if (types.carriesWriteView(self, pt)) try sema.reachedTypeVars(ctx, pt, &held, self.arena());
    }
    for (held.items) |param| {
        const req: PlainRequirement = .{ .param = param, .pos = pos, .callable = callable, .in_result = in_result, .method = self.method_pos };
        if (hasRequirement(self, req)) continue;
        try self.plain_reqs.append(self.gpa, req);
    }
}

pub fn hasRequirement(self: *const Checker, req: PlainRequirement) bool {
    for (self.plain_reqs.items) |r| {
        if (r.param == req.param and r.pos == req.pos and r.callable == req.callable and r.in_result == req.in_result and r.method == req.method and r.module_id == 0) return true;
    }
    return false;
}

/// Each call of a method of a generic type (`method_calls`) meets what
/// the method's body requires of a function value's type
/// (`PlainRequirement.callable`, with `method`), at the arguments the
/// self's type gives: refused there, or, where those arguments
/// are a generic body's own parameters, required of that body in
/// turn. Repeated until no call adds a requirement, as one method
/// calls another; a round adds only requirements not yet held, so
/// this settles. The bound is a backstop, as a loop's is: a chain
/// it cannot settle is rejected, never accepted.
pub fn checkMethodCalls(self: *Checker) Error!void {
    const ctx = self.sema;
    var reported: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer reported.deinit(self.gpa);
    var changed = true;
    var changed_at: u32 = 0;
    var rounds: u32 = 0;
    while (changed and rounds < 1000) : (rounds += 1) {
        changed = false;
        var ci: usize = 0;
        while (ci < self.method_calls.items.len) : (ci += 1) {
            const mc = self.method_calls.items[ci];
            const subst: sema.TypeSubst = .{ .params = mc.params, .args = mc.args };
            // Another module's method's requirements are its module's.
            const home: *const sema.SemContext = if (mc.target.module == ctx.module_id) ctx else ctx.foreign_semas.get(mc.target.module) orelse continue;
            var ri: usize = 0;
            while (ri < (if (home == ctx) self.plain_reqs.items.len else home.plain_reqs.items.len)) : (ri += 1) {
                var r = if (home == ctx) self.plain_reqs.items[ri] else home.plain_reqs.items[ri];
                if (home != ctx and r.module_id == 0) r.module_id = home.module_id;
                const m = r.method orelse continue;
                const callable = r.callable orelse continue;
                const module = if (r.module_id == 0) ctx.module_id else r.module_id;
                if (m != mc.target.pos or module != mc.target.module) continue;
                const arg = subst.lookup(home.ref(r.param)) orelse continue;
                if (!try sema.liveAt(ctx, r.module_id, r.pos, subst.params, subst.args)) continue;
                const interner = self.interner;
                const inst = try sema.substituteType(interner, callable, subst);
                if (sema.containsPoison(ctx, inst)) continue;
                if (ctx.typeInfo(inst).has_type_var) {
                    // The caller's own parameters: its instances answer.
                    const saved = self.method_pos;
                    defer self.method_pos = saved;
                    self.method_pos = mc.scope;
                    const before = self.plain_reqs.items.len;
                    try requireCallable(self, mc.pos, inst, r.in_result);
                    if (self.plain_reqs.items.len > before) {
                        changed = true;
                        changed_at = mc.pos;
                    }
                    continue;
                }
                if (!types.mayCarryLoan(self, arg)) continue;
                if (reported.contains(mc.pos)) continue;
                if (try callableRefuses(self, r, subst)) |at| {
                    try reported.put(self.gpa, mc.pos, {});
                    try reportCallable(self, home, mc.pos, try sema.formatTypeIn(ctx, self.arena(), mc.recv), r, arg, at);
                }
            }
        }
    }
    if (changed) try notes.tooComplex(self, changed_at, "call");
}

/// The requirements generic bodies make of a parameter, in the module
/// that declares it: this one's as the checker holds them, another's as
/// its check recorded them (`SemContext.plain_reqs`).
const Reqs = struct {
    list: []const PlainRequirement,
    home: *const sema.SemContext,

    /// `r` when it is on `param`, with its module named as `ctx` names it.
    fn on(self: Reqs, ctx: *const sema.SemContext, r: PlainRequirement, param: SymbolRef) ?PlainRequirement {
        if (self.home.ref(r.param) != param) return null;
        var out = r;
        if (self.home != ctx and out.module_id == 0) out.module_id = self.home.module_id;
        return out;
    }
};

fn reqsOf(self: *const Checker, param: SymbolRef) Reqs {
    const ctx = self.sema;
    if (ctx.owns(param)) return .{ .list = self.plain_reqs.items, .home = ctx };
    const home = sema.homeOf(ctx, param);
    return .{ .list = home.plain_reqs.items, .home = home };
}

/// An instance whose argument for `param` owns a resource, where a
/// generic body copies a `param`.
pub fn checkCopies(self: *Checker, site: u32, shown: []const u8, param: SymbolRef, arg: TypeId, subst: sema.TypeSubst) Error!void {
    const ctx = self.sema;
    if (sema.moves(ctx, arg) != .yes) return;
    const pname = sema.symbolAt(ctx, param).name;
    const on = reqsOf(self, param);
    for (on.list) |r0| {
        const r = on.on(ctx, r0, param) orelse continue;
        if (r.view or r.item.len > 0 or r.callable != null) continue;
        if (!try sema.liveAt(ctx, r.module_id, r.pos, subst.params, subst.args)) continue;
        if (sema.typeHasDropGlue(ctx, arg)) {
            try notes.err(self, site, "`{s}` cannot use `{s} = {s}`: the generic body copies a `{s}`, which would duplicate the resource `{s}` owns", .{ shown, pname, try sema.formatTypeIn(ctx, self.arena(), arg), pname, try sema.formatTypeIn(ctx, self.arena(), arg) });
        } else try notes.err(self, site, "`{s}` cannot use `{s} = {s}`: the generic body copies a `{s}`, and `{s}` is unique", .{ shown, pname, try sema.formatTypeIn(ctx, self.arena(), arg), pname, try sema.formatTypeIn(ctx, self.arena(), arg) });
        if (r.element) {
            try notes.noteIn(self, r.module_id, r.pos, "a `{s}` element is taken here while its collection still owns it; take the elements with `for x in <v`", .{pname});
        } else if (r.as_view) {
            try notes.noteIn(self, r.module_id, r.pos, "a `{s}` is taken here from inside an optional that still owns it, where `as` binds it", .{pname});
        } else try notes.noteIn(self, r.module_id, r.pos, "`{s}` copied here; move it with `<` instead", .{pname});
        return;
    }
}

/// What to write for a parameter that only ever gets literal text and
/// is stored where no loan is tracked: the loan `l` is the parameter's
/// own (`ext`), and a `Static` has none.
pub fn staticParamHint(l: Loan) []const u8 {
    return if (l.ext) "; if it is only passed literal text, declare the parameter `Static`, which holds no view" else "";
}

/// Every type parameter `ty` holds must be plain data in each
/// instance, because the value is copied (or taken as an `element`).
pub fn requirePlain(self: *Checker, pos: u32, ty: TypeId, element: bool) Error!void {
    return addRequirement(self, pos, ty, .{ .param = 0, .pos = pos, .element = element });
}

/// Every type parameter `ty` holds must hold no `?String` in each
/// instance, because the value is stored where no loan is tracked:
/// in a Cell, a Signal, a channel, an actor's value, or an owned
/// closure.
pub fn requireNoView(self: *Checker, pos: u32, ty: ?TypeId, home: sema.NoLoanHome) Error!void {
    return addRequirement(self, pos, ty orelse return, .{ .param = 0, .pos = pos, .view = true, .home = home });
}

pub fn addRequirement(self: *Checker, pos: u32, ty: TypeId, req: PlainRequirement) Error!void {
    const ctx = self.sema;
    var held: std.ArrayList(SymbolId) = .empty;
    // A value stored where no loan is tracked carries the loans of
    // every `T` it reaches, however deep; a copy or cleanup
    // requirement is about what it holds by value.
    if (req.view) try sema.reachedTypeVars(ctx, ty, &held, self.arena()) else try sema.heldTypeVars(ctx, ty, &held, self.arena());
    for (held.items) |param| {
        for (self.plain_reqs.items) |r| {
            if (r.param == param and r.pos == pos and r.view == req.view and r.item.len == 0) break;
        } else {
            var r = req;
            r.param = param;
            try self.plain_reqs.append(self.gpa, r);
        }
    }
}

/// Whether the members being walked are a generic type's.
pub fn genericOwner(self: *const Checker) bool {
    const ctx = self.sema;
    const owner = self.decl_owner orelse return false;
    return ctx.symbols.items[owner].type_params != null;
}

/// A generic body is checked once, a value of a type parameter's type
/// carrying no loan (SPEC "Generic bodies"). A value of an associated
/// type (`S.Item`) that a call gives is checked again as at an
/// instance whose associated type may view memory its base owns: the
/// body is walked once more with such a value a view that only reads
/// whatever the call was passed (`item`). An error that walk finds and
/// the first did not is a change of the base while such a value lives,
/// recorded as a requirement on the base (`PlainRequirement.item`):
/// each instance meets it unless its associated type may view memory
/// its base owns (`checkItems`). The walk reports nothing itself.
pub fn walkItemInstances(self: *Checker, root: Sexp, name: Sexp, tparams: Sexp, params: Sexp, returns: Sexp, body: Sexp) Error!void {
    const ctx = self.sema;
    const seen = try self.gpa.dupe(SymbolId, self.items_seen.items);
    defer self.gpa.free(seen);
    for (seen) |assoc| {
        const of = ctx.symbols.items[assoc].assoc_of orelse continue;
        const reqs = self.plain_reqs.items.len;
        const diags = self.diagnostics.items.len;
        const found = self.errors_found;
        self.item = assoc;
        const walked = transfer.walkFunOnce(self, root, name, tparams, params, returns, body);
        self.item = null;
        try walked;
        const at: ?u32 = for (self.diagnostics.items[diags..]) |d| {
            if (d.severity == .@"error") break d.pos;
        } else null;
        for (self.diagnostics.items[diags..]) |d| self.gpa.free(d.message);
        self.diagnostics.shrinkRetainingCapacity(diags);
        self.plain_reqs.shrinkRetainingCapacity(reqs);
        self.errors_found = found;
        if (at) |pos| try self.plain_reqs.append(self.gpa, .{ .param = of.base, .pos = pos, .item = of.name });
    }
}

// -----------------------------------------------------------------------------
// Generic types: what a type parameter may hold
// -----------------------------------------------------------------------------

/// Whether a value of `ty` reaches the associated type a walk as an
/// instance judges (`item`, `walkItemInstances`).
pub fn holdsItem(self: *const Checker, ty: ?TypeId) bool {
    const it = self.item orelse return false;
    const ctx = self.sema;
    return sema.reachesTypeVar(ctx, ty orelse return false, it);
}

/// Note the associated types a value of `ty`, a call's result,
/// reaches (`items_seen`).
pub fn noteItems(self: *Checker, ty: ?TypeId) Error!void {
    if (self.item != null) return;
    const ctx = self.sema;
    const t = ty orelse return;
    if (!ctx.typeInfo(t).has_type_var) return;
    var held: std.ArrayList(SymbolId) = .empty;
    try sema.reachedTypeVars(ctx, t, &held, self.arena());
    for (held.items) |sym| {
        if (ctx.symbols.items[sym].assoc_of == null) continue;
        if (std.mem.findScalar(SymbolId, self.items_seen.items, sym) == null) try self.items_seen.append(self.gpa, sym);
    }
}

/// Whether a value of `ty` may hold a view, here or in an instance.
pub fn mayHoldInInstance(self: *const Checker, ty: ?TypeId) bool {
    return types.mayCarryLoan(self, ty) or genericType(self, ty);
}

/// A store of `stored` in what var `id` leads to, a type that holds a
/// type parameter (`genericType`), whose loans a generic body does not
/// track: a parameter the caller viewed is noted as holding them
/// (`noteGenericStore`, `recordStore`), through the write views a
/// local holds.
pub fn genericStoreIn(self: *Checker, id: VarId, stored: Value, pos: u32, depth: u32) Error!void {
    if (!holdsGeneric(self, types.pointee(self, self.vars.items[id].ty))) return;
    if (depth > 16) return notes.tooComplex(self, pos, "store");
    const c = self.vars.items[id];
    if (c.kind == .param and c.ref != .none) {
        // The caller's value outlives this function's own values, as
        // for any type (`absorbLoans`): a call through a bound that
        // keeps what it is passed stores it there. (A function value
        // keeps nothing; its default origins only say it may.)
        if (self.api_call) for (stored.loans) |l| if (l.root != id and origins.isLocalLoan(self, l)) {
            try notes.err(self, pos, "cannot let this call store a view of `{s}` in `{s}`: `{s}` outlives it", .{ self.vars.items[l.root].name, c.name, c.name });
            return;
        };
        try heldStore(self, id, stored, true);
        var out: std.ArrayList(Loan) = .empty;
        for (stored.loans) |l| if (l.root != id and !origins.isLocalLoan(self, l)) try out.append(self.arena(), l);
        origins.recordStore(self, id, out.items, pos);
        return;
    }
    // A value of a type parameter's type this body owns: it tracks no
    // view in one (SPEC "Generic bodies"), so a call that keeps what
    // it is passed may not store a view there.
    if (self.api_call and c.ref == .none and depth == 0) for (stored.loans) |l| if (l.root != id) {
        const shown = try sema.formatTypeIn(self.sema, self.arena(), (types.pointee(self, c.ty) orelse c.ty) orelse sema.type_invalid);
        try notes.err(self, pos, "cannot let this call store a view of `{s}` in `{s}`, a `{s}`: a generic body tracks no view a value of a type parameter holds", .{ self.vars.items[l.root].name, c.name, shown });
        return;
    };
    if (c.ref == .none) try heldStore(self, id, stored, false);
    for (self.flows.items[id].loans) |l| {
        if (l.kind == .write and l.root != id) try genericStoreIn(self, l.root, stored, pos, depth + 1);
    }
}

/// A call of a function value (`held_store`) may store the loans in
/// `stored` in what var `id` leads to, a value of a type parameter's
/// type whose loans the body does not track. Where one is not the
/// write argument's own and is on memory the body owns (for a view
/// parameter `id`, the parameter itself or a value of the body's),
/// each instance's type of the function value must keep none there
/// (`requireCallable`), as for any other loan not on a parameter. A
/// loan on another view parameter stays tracked, as any view is: a
/// view parameter `id` records it
/// (`recordStore`), and a value of the body's carries it as a value
/// of a type parameter's type does (`taintGeneric`), returned or
/// stored wherever the body returns or stores one.
pub fn heldStore(self: *Checker, id: VarId, stored: Value, viewed: bool) Error!void {
    const hs = self.held_store orelse return;
    var required = false;
    for (stored.loans) |l| {
        if (containsLoan(hs.own, l)) continue;
        if (viewed) {
            if (l.root != id and !origins.isLocalLoan(self, l)) continue;
        } else if (!types.ownsLoan(self, l, 0)) if (origins.paramOf(self, l)) |i| {
            self.func.generic |= sema.paramBit(i);
            continue;
        };
        if (!required) try requireCallable(self, hs.pos, hs.callable, false);
        required = true;
    }
}

/// Record call `node` of a Rig method on a value of a generic type's
/// instance (`method_calls`), whose body's requirements of function
/// values its type's arguments answer (`checkMethodCalls`).
pub fn noteMethodCall(self: *Checker, node: Sexp, callee: Sexp) Error!void {
    const ctx = self.sema;
    const target = switch (ctx.callTargetOf(node) orelse return) {
        .function => |f| f,
        .none => return,
    };
    const recv = types.pointee(self, types.exprType(self, unsigiled(ir.Member.object(callee)))) orelse return;
    const pn = switch (ctx.types.get(recv)) {
        .parameterized_nominal => |pn| pn,
        else => return,
    };
    if (sema.symbolAt(ctx, pn.sym).type_params == null) return;
    const params = sema.paramRefs(ctx, pn.sym);
    try self.method_calls.append(self.gpa, .{ .pos = notes.startOf(self, node), .target = target, .recv = recv, .params = params, .args = pn.args, .scope = self.method_pos });
}

/// Whether `ty` holds a type parameter by value and so may hold a view
/// in an instance, though a generic body tracks no loan in a value of
/// it (SPEC "Generic bodies"): what reaches one is recorded for the
/// body check instead (`taintGeneric`, `noteGenericStore`). A type
/// parameter whose bounds give `Owned` holds none in any instance
/// (`sema.holdsUnownedParam`).
pub fn genericType(self: *const Checker, ty: ?TypeId) bool {
    const ctx = self.sema;
    const t = ty orelse return false;
    return !types.mayCarryLoan(self, t) and sema.holdsUnownedParam(ctx, t);
}

/// Whether a value of `ty` may hold a value of a type parameter's
/// type that may hold a view in an instance
/// (`sema.holdsUnownedParam`), which a generic body tracks no loan
/// in.
pub fn holdsGeneric(self: *const Checker, ty: ?TypeId) bool {
    const ctx = self.sema;
    return sema.holdsUnownedParam(ctx, ty orelse return false);
}

/// `v`'s loans reach a value of type `ty`, which a generic body keeps
/// no loan in (`genericType`): the parameters they are on may be
/// returned or stored wherever such a value is (`checkOrigins`).
pub fn taintGeneric(self: *Checker, ty: ?TypeId, v: Value) void {
    if (v.loans.len == 0 or !genericType(self, ty)) return;
    for (v.loans) |l| if (origins.paramOf(self, l)) |i| {
        self.func.generic |= sema.paramBit(i);
        if (self.func.generic_self_path == null and origins.isSelfVar(self, l.root) and !origins.withinSelfPaths(self, l.path)) self.func.generic_self_path = .{ .path = l.path, .at = l.pos };
    };
}

/// No loans, for a value of `ty` that carries none, after `v`'s reach
/// it (`taintGeneric`).
pub fn taintedNone(self: *Checker, ty: ?TypeId, v: Value) []const Loan {
    taintGeneric(self, ty, v);
    return &.{};
}

/// The body stores, at `pos`, a value whose type mentions a type
/// parameter in what parameter var `into` leads to: whatever reached
/// such a value may be stored there (`checkOrigins`).
pub fn noteGenericStore(self: *Checker, into: VarId, pos: u32) void {
    const i = self.vars.items[into].param_index orelse return;
    for (self.func.generic_stores[0..self.func.generic_store_count]) |s| if (s.param == i) return;
    if (self.func.generic_store_count == self.func.generic_stores.len) return;
    self.func.generic_stores[self.func.generic_store_count] = .{ .param = i, .pos = pos, .name = self.vars.items[into].name };
    self.func.generic_store_count += 1;
}

/// A bracket list of compile-time arguments (`List[Int]`, `max[Int]`),
/// which names a type or a function and holds no value.
pub fn isInstance(self: *const Checker, e: Sexp) bool {
    const s = self.sema;
    return s.instanceOf(e) != null;
}

/// The type of the function call `node` calls, when it names a type
/// parameter of the body: a function value's (a parameter, local,
/// capture, or field holding one, or a closure called where it is
/// written), or a generic function's signature at the call's type
/// arguments; null for a method.
pub fn calledValueType(self: *Checker, node: Sexp, callee: Sexp, field_call: bool) Error!?TypeId {
    const ctx = self.sema;
    if (callee.isKind(.member) and !field_call) return null;
    if (callee == .src) if (ctx.symbolOf(callee)) |id| if (ctx.symbols.items[id].kind == .function) {
        // A named function: generic, at the body's own parameters.
        const gc = ctx.genericCallOf(node) orelse return null;
        const interner = self.interner;
        const ty = try sema.substituteType(interner, ctx.symbols.items[id].ty, .{ .params = gc.params, .args = gc.type_args });
        if (!ctx.typeInfo(ty).has_type_var or sema.calledFn(ctx, ty) == null) return null;
        return ty;
    };
    if (ctx.callTargetOf(node)) |t| if (t == .function) return null;
    const ty = types.exprType(self, callee) orelse return null;
    if (!ctx.typeInfo(ty).has_type_var) return null;
    _ = sema.calledFn(ctx, ty) orelse return null;
    return ty;
}

/// `p.f(...)` where `f` is a data field holding a plain function or
/// an owned closure (not a method): the call has no self
/// (`storage.hasSelf`), and neither can keep a view of an
/// argument in `p`.
pub fn callsFunctionField(self: *const Checker, call: Sexp, callee: Sexp) bool {
    const ctx = self.sema;
    return !storage.isTypeCallee(ctx, ir.Member.object(callee)) and !storage.hasSelf(ctx, call);
}

/// Whether method call `callee` reaches a built-in table's method
/// that gives views of its entries to a function value
/// (`Field.views_entries`).
pub fn viewsEntries(self: *const Checker, callee: Sexp) bool {
    const ctx = self.sema;
    const recv = types.pointee(self, types.exprType(self, unsigiled(ir.Member.object(callee)))) orelse return false;
    const pn = switch (ctx.types.get(recv)) {
        .parameterized_nominal => |pn| pn,
        else => return false,
    };
    if (!sema.isHashTable(ctx, pn.sym)) return false;
    const name = types.text(self, ir.Member.name(callee));
    for (sema.symbolAt(ctx, pn.sym).fields orelse &.{}) |f| {
        if (f.is_method and std.mem.eql(u8, f.name, name)) return f.views_entries;
    }
    return false;
}
