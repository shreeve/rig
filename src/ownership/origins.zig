//! Origins: which loans a value carries (`carry`), what a call keeps
//! of its arguments (Core sentence 7), and a body checked against its
//! signature (`checkOrigins`).

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const sema = @import("../sema.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const TypeId = sema.TypeId;
const Error = std.mem.Allocator.Error;
const state = @import("state.zig");
const live = @import("live.zig");
const transfer = @import("transfer.zig");
const rules = @import("rules.zig");
const generic = @import("generic.zig");
const types = @import("types.zig");
const notes = @import("notes.zig");
const Checker = state.Checker;
const Loan = state.Loan;
const LoanKind = state.LoanKind;
const PathId = state.PathId;
const Paths = state.Paths;
const ReachKey = state.ReachKey;
const Value = state.Value;
const VarId = state.VarId;
const containsLoan = state.containsLoan;
const whole_path = state.whole_path;

/// Whether `l` is on the place of one of `views`, whatever its kind: a
/// view a store goes through, which a view that only reads it keeps as a
/// read loan (`carryLoan`).
pub fn isViewOf(views: []const Loan, l: Loan) bool {
    for (views) |x| if (x.root == l.root and x.path == l.path and !x.ext) return true;
    return false;
}

// -----------------------------------------------------------------------------
// Sentence 7: what a value carries, and what a call keeps
// -----------------------------------------------------------------------------

/// The loans a value of type `ty` needs, of those `v` carries (Core
/// sentence 7): a view carries the loans of only what could hold
/// what it views. A loan on a var whose type could hold that memory
/// only through a read view, or not at all (`sema.ViewReach`), stands
/// for the loans the var holds, judged the same way: `it.next()` of a
/// `!it` iterator holding Strings views what `it` views, not `it`. A
/// loan on a var that may own that memory, or hold a write view of
/// it, stays. A value that holds only Strings reads what it views, so
/// what it keeps are read loans; one holding a write view, a type
/// parameter, or a type not known keeps every loan.
pub fn carry(self: *Checker, ty: ?TypeId, v: Value) Error!Value {
    return carryAs(self, ty, v, false);
}

/// The loans a call's result keeps of `v` (Core sentence 7), as
/// `carry` keeps them. A result that holds no write view reads what
/// it views, so every loan it keeps is a read loan, also one of an
/// argument or self given as a write view: while the result lives, that
/// owner may be read but not written. What the call stores keeps its
/// loans where it stores them (`absorbThroughWrites`).
pub fn carryResult(self: *Checker, ty: ?TypeId, v: Value) Error!Value {
    return carryAs(self, ty, v, true);
}

pub fn carryAs(self: *Checker, ty: ?TypeId, v: Value, result: bool) Error!Value {
    const ctx = self.sema;
    const t = ty orelse return v;
    if (v.loans.len == 0) return v;
    // A task is its call, still running: it keeps every loan of its
    // arguments as made, a write loan to write, whatever its result's
    // type could view (docs/design/concurrency.md, "Where a task may
    // go"). A set of tasks keeps those of each. A call that gives a
    // task (`-> Task[T]`) gives a result like any other: no task given
    // a write view leaves where it is bound, so what it keeps are read
    // loans.
    if (!result and sema.holdsCallLoans(ctx, t)) return v;
    if (!viewsOnlyRead(self, t)) return v;
    const reads = result or sema.holdsViewOnly(ctx, t);
    var out: std.ArrayList(Loan) = .empty;
    for (v.loans) |l| try carryLoan(self, &out, t, reads, l, 0);
    return .{ .loans = out.items };
}

/// Whether values of `ty` hold views, and none that can write: no
/// write view, type parameter, or type not known. The loans such a
/// value keeps are narrowed by `carry`, and a call's result of the
/// type keeps them as read loans (`carryResult`).
pub fn viewsOnlyRead(self: *const Checker, ty: TypeId) bool {
    const ctx = self.sema;
    const info = ctx.typeInfo(ty);
    if (info.poison or info.views.write) return false;
    if (generic.holdsItem(self, ty)) return true;
    if (info.holds_type_var) return false;
    return info.views.marked or info.views.string_view;
}

pub fn carryLoan(self: *Checker, out: *std.ArrayList(Loan), ty: TypeId, reads: bool, l: Loan, depth: u8) Error!void {
    // A loan on a var whose scope ended was released with it
    // (`releaseVarsFrom`); one that survives is a lost track of the
    // walk, which no program is accepted with.
    if (l.root >= self.vars.items.len) return notes.err(self, l.pos, "internal error: a loan outlives the var it is on", .{});
    if (l.ext or depth >= 16 or try mayOwnView(self, l.root, ty)) {
        var kept = l;
        if (reads and !l.ext and l.kind == .write) {
            kept.kind = .read;
            kept.read_of_write = true;
        }
        if (!containsLoan(out.items, kept)) try out.append(self.arena(), kept);
        return;
    }
    for (self.flows.items[l.root].loans) |h| {
        // What self holds, standing for a loan on a path of self, is
        // on that path (`tagSelf`).
        var k = h;
        if (h.ext and h.root == l.root and isSelfVar(self, l.root) and l.path != whole_path and self.paths.within(l.path, h.path)) k.path = l.path;
        try carryLoan(self, out, ty, reads, k, depth + 1);
    }
}

/// Whether var `id`'s value may own memory a value of type `view`
/// views, or hold a write view of it (`sema.ViewReach.owned`). A
/// closure, and a var whose type is not known, may.
pub fn mayOwnView(self: *Checker, id: VarId, view: TypeId) Error!bool {
    const ctx = self.sema;
    // An associated type an instance gives may view anything.
    if (generic.holdsItem(self, view)) return true;
    const v = self.vars.items[id];
    if (v.closure) return true;
    const t = v.ty orelse return true;
    if (types.isPoisonType(self, t) or ctx.types.get(t) == .unknown) return true;
    const key: ReachKey = .{ .holder = t, .view = view };
    if (self.reaches.get(key)) |r| return r == .owned;
    var scratch = std.heap.ArenaAllocator.init(self.gpa);
    defer scratch.deinit();
    const r = try sema.viewReach(ctx, scratch.allocator(), t, view);
    try self.reaches.put(self.gpa, key, r);
    return r == .owned;
}

/// Whether place `e` reaches its value through a read view: a step
/// past a `?T`, a read-only `[]T`, or a `?String` (`c.items[0]` with
/// `items: ?List[Item]`). Its memory is the view's, which the place's
/// var does not own.
pub fn throughReadView(self: *const Checker, e: Sexp) bool {
    var p = e;
    while (p.isKind(.member) or p.isKind(.index)) {
        const obj = ir.get(p, .object);
        if (types.exprType(self, obj)) |t| switch (types.typeData(self, t)) {
            .read_view, .slice, .string_view => return true,
            else => {},
        };
        p = obj;
    }
    return false;
}

/// A view of place `e` through a read view (`throughReadView`),
/// which is the view through a copy of that view (`?c.items[0]` is
/// `t = c.items` then `?t[0]`): it keeps what the view keeps, which
/// the place's var holds, and no loan on the var (Core sentence 7).
/// The var is held while the place's indexes run, as for any view.
pub fn walkThroughView(self: *Checker, e: Sexp) Error!Value {
    const place = transfer.resolvePlace(self, e) orelse return transfer.walkViewedPath(self, e);
    try transfer.walkIndicesHeld(self, e, place.root, place.path);
    try rules.checkReadable(self, place.root, e, notes.startOf(self, e));
    return tagSelf(self, live.varValue(self, place.root), place.root, place.path);
}

/// Whether call `call` may keep what argument `arg` views. No value
/// holds a callable view, so a callable view given to a call is kept
/// only by a result that is one, or through what it returns when
/// that can hold a view.
pub fn keepsCallable(self: *const Checker, call: Sexp, arg: Sexp) bool {
    const ctx = self.sema;
    const value = if (arg.isKind(.kwarg)) ir.Kwarg.value(arg) else arg;
    const fn_ty = ctx.callableOf(value) orelse blk: {
        const ty = types.exprType(self, value) orelse return true;
        if (sema.callableFn(ctx, ty) == null) return true;
        break :blk sema.callableFnTy(ctx, ty).?;
    };
    if (sema.holdsCallable(ctx, types.exprType(self, call) orelse return true)) return true;
    return types.mayCarryLoan(self, ctx.types.get(fn_ty).function.returns);
}

/// The element type of a call of `copy`, a built-in element method
/// that stores copies of the elements its argument views.
pub fn copiedElem(self: *const Checker, callee: Sexp) ?TypeId {
    const ctx = self.sema;
    const ec = ctx.elemCallOf(callee) orelse return null;
    return if (ec.op == .copy) ec.elem else null;
}

/// A call of a built-in element method whose elements hold no
/// view: it stores none of its arguments' views.
pub fn storesNothing(self: *const Checker, callee: Sexp) bool {
    const ctx = self.sema;
    const ec = ctx.elemCallOf(callee) orelse return false;
    return !types.mayCarryLoan(self, ec.elem);
}

/// A view of a value that copies and carries no loan (`k` with
/// `k: ?Int`), passed where a value is expected, is read by value
/// (`sema.copiedThrough`): what it views is not stored.
pub fn readsPlainValue(self: *const Checker, e: Sexp) bool {
    const ctx = self.sema;
    const arg = if (e.isKind(.kwarg)) ir.Kwarg.value(e) else e;
    const value = sema.copiedThrough(ctx, types.exprType(self, arg) orelse return false) orelse return false;
    return !types.mayCarryLoan(self, value);
}

/// Record that the values the write loans in `v` lead to may now hold
/// the loans in `stored`. Those write loans are the path to them, not
/// something stored. `via` names the write view an assignment
/// stores through; without it, a call stores them.
///
/// Without a `depth` (a call, which may store anywhere its arguments
/// reach), every value the write loans lead to, however deep, may
/// hold them. An assignment goes through `depth` write views from
/// `v` (`placeDepth`): the values within that many write loans may
/// hold them, and the ones further on, which only what it wrote
/// views, do not. A write view var on the way (`w2 = !w`) is a
/// name for what it views, and takes no step of its own.
pub fn absorbThroughWrites(self: *Checker, v: Value, stored: Value, pos: u32, via: ?[]const u8, depth: ?u32) Error!void {
    return absorbThroughViews(self, v, stored, v.loans, pos, via, depth);
}

/// `absorbThroughWrites`, where `views` are the views the store goes
/// through (`absorbLoans`): `v`'s, and a `swap`'s other place's.
pub fn absorbThroughViews(self: *Checker, v: Value, stored: Value, views: []const Loan, pos: u32, via: ?[]const u8, depth: ?u32) Error!void {
    var level: std.ArrayList(VarId) = .empty;
    try appendWriteRoots(self, &level, v, &.{});
    const d = depth orelse {
        for (level.items) |r| {
            // Only a value that can hold a view can have one stored in it.
            if (!types.mayCarryLoan(self, types.pointee(self, self.vars.items[r].ty))) {
                try generic.genericStoreIn(self, r, stored, pos, 0);
                continue;
            }
            try absorbLoans(self, r, stored, pos, level.items, via, true, views);
        }
        return;
    };
    // The values reached, found before any of them takes the loans.
    var seen: std.ArrayList(VarId) = .empty;
    var remaining = d;
    while (level.items.len > 0 and seen.items.len <= 64) {
        var next: std.ArrayList(VarId) = .empty;
        var i: usize = 0;
        while (i < level.items.len) : (i += 1) {
            const r = level.items[i];
            if (std.mem.findScalar(VarId, seen.items, r) != null) continue;
            try seen.append(self.arena(), r);
            const c = self.vars.items[r];
            if (callerOwns(self, r) or self.isGlobal(r)) continue;
            if (c.ref == .write) {
                try appendWriteRoots(self, &level, live.varValue(self, r), seen.items);
            } else if (remaining > 1) try appendWriteRoots(self, &next, live.varValue(self, r), seen.items);
        }
        if (remaining <= 1) break;
        remaining -= 1;
        level = next;
    }
    if (seen.items.len > 64) return absorbThroughViews(self, v, stored, views, pos, via, null);
    // The write loans that lead from one value reached to the next are
    // views the store goes through too.
    var through_views: std.ArrayList(Loan) = .empty;
    try through_views.appendSlice(self.arena(), views);
    for (seen.items) |r| for (live.varValue(self, r).loans) |l| if (l.kind == .write) try through_views.append(self.arena(), l);
    for (seen.items) |r| {
        if (!types.mayCarryLoan(self, types.pointee(self, self.vars.items[r].ty))) {
            try generic.genericStoreIn(self, r, stored, pos, 0);
            continue;
        }
        try absorbLoans(self, r, stored, pos, seen.items, via, false, through_views.items);
    }
}

/// Append to `out` the roots of the write loans in `v` not in `out`
/// or `skip`.
pub fn appendWriteRoots(self: *Checker, out: *std.ArrayList(VarId), v: Value, skip: []const VarId) Error!void {
    for (v.loans) |l| {
        if (l.kind != .write or std.mem.findScalar(VarId, out.items, l.root) != null or std.mem.findScalar(VarId, skip, l.root) != null) continue;
        try out.append(self.arena(), l.root);
    }
}

/// The number of write views a store to `target` goes through from
/// its root var's value: each one the path reaches through, the root
/// included, and the `!T` the place itself holds when the store
/// writes through it.
pub fn placeDepth(self: *const Checker, target: Sexp, writes_through: bool) u32 {
    var n: u32 = @intFromBool(writes_through);
    var e = target;
    while (e.isKind(.member) or e.isKind(.index)) {
        e = ir.get(e, .object);
        // A root var holding a write view (a `match !x` binding
        // among them, whatever its type) is one.
        const root_is_write_view = e == .src and if (self.find(e)) |id| self.vars.items[id].ref == .write else false;
        const is_write_view = if (types.exprType(self, e)) |t| types.typeData(self, t) == .write_view else false;
        if (root_is_write_view or is_write_view) n += 1;
    }
    return n;
}

/// Record that var `id` may now hold the loans in `v`, and so may
/// every value it has a write view of: a store through a write view lands
/// there. `through` are the vars whose write views led to `id`;
/// their own loans are the path, not something stored. A viewed
/// parameter or a module-level binding outlives this function's
/// values: storing a view of one into it is rejected, and a
/// view parameter holds the loans the caller handed in, as any
/// var does. `via` is as for `absorbThroughWrites`.
///
/// A value never holds a view of itself (Core §5): a loan on a part
/// of `id` stored into `id` is rejected, but for `views`, the views
/// the store goes through (a write self's own, a write argument's,
/// the write loans held on the way), which are the way in, not views
/// stored.
pub fn absorbLoans(self: *Checker, id: VarId, v_in: Value, pos: u32, through: []const VarId, via: ?[]const u8, deeper: bool, views: []const Loan) Error!void {
    if (try selfViewIn(self, id, v_in.loans, views, through)) |l| return notes.reportSelfView(self, id, l, views, pos, via);
    // A value that holds only Strings keeps only what leads to a String.
    // What lands in a value that holds only Strings needs only what
    // could hold them (`carry`).
    const t = types.pointee(self, self.vars.items[id].ty);
    const strings = if (t) |inner| sema.holdsViewOnly(self.sema, inner) else false;
    const v = if (strings) try carry(self, t, v_in) else v_in;
    var out: std.ArrayList(Loan) = .empty;
    for (v.loans) |l| {
        if (l.root != id and std.mem.findScalar(VarId, through, l.root) == null) try out.append(self.arena(), l);
    }
    const c = self.vars.items[id];
    if (callerOwns(self, id) and generic.holdsGeneric(self, t)) generic.noteGenericStore(self, id, pos);
    if (callerOwns(self, id) or self.isGlobal(id)) {
        // The caller accounts for views it passed in; only views
        // of this function's own values cannot be stored. Nothing
        // viewed may be stored in a module-level binding.
        for (out.items) |l| if (isLocalLoan(self, l) or self.isGlobal(id)) {
            const name = self.vars.items[l.root].name;
            if (self.vars.items[l.root].erased_of.len > 0) {
                try notes.reportErasedCopy(self, l, self.vars.items[l.root]);
                return;
            }
            if (via) |w| {
                try notes.err(self, pos, "cannot store a view of `{s}` through `{s}`: `{s}` outlives it", .{ name, w, c.name });
            } else try notes.err(self, pos, "cannot let this call store a view of `{s}` in `{s}`: `{s}` outlives it", .{ name, c.name, c.name });
            return;
        };
        // The parameter holds what is stored in the value the caller
        // gave it a view of. It is live at every exit (`holderLive`),
        // since the caller reads that value after the return, so each
        // loan stays in force for the rest of the body.
        recordStore(self, id, out.items, pos);
        var pf = self.flows.items[id];
        pf.loans = try self.unionLoans(pf.loans, out.items);
        return self.setFlow(id, pf);
    }
    var f = self.flows.items[id];
    const held = f.loans;
    f.loans = try self.unionLoans(held, out.items);
    try self.setFlow(id, f);
    if (!deeper) return;
    // Only a var that holds a write view writes what its write loans
    // lead to. Any other keeps a write loan only as what it copied
    // out through one (`k.a = r.s`): what is stored in it stays there.
    if (c.ref != .write and !types.mayWrite(self, c.ty)) return;
    const next = try std.mem.concat(self.arena(), VarId, &.{ through, &.{id} });
    for (held) |l| {
        if (l.kind != .write or std.mem.findScalar(VarId, next, l.root) != null) continue;
        // Only a value that can hold a view can have one stored in it.
        if (!types.mayCarryLoan(self, types.pointee(self, self.vars.items[l.root].ty))) continue;
        if (through.len > 16) return notes.tooComplex(self, pos, "store");
        try absorbLoans(self, l.root, v, pos, next, via, true, try std.mem.concat(self.arena(), Loan, &.{ views, &.{l} }));
    }
}

/// Whether var `id` is a parameter whose value is what the caller
/// viewed: a view parameter (`?T`, `!T`), or one holding a write view
/// (`(!T)?`), which every unwrapping of it (`w?`, `w ?? e`,
/// `if <w as x`, a call's `!` or `catch`) writes through. A store
/// a write loan leads to on it lands in what the caller owns, which
/// outlives this function's own values.
pub fn callerOwns(self: *const Checker, id: VarId) bool {
    const v = self.vars.items[id];
    return v.kind == .param and (v.ref != .none or types.carriesWriteView(self, v.ty));
}

/// A loan on a value owned by the current function (as opposed to one
/// the caller handed in through a view parameter, or a
/// module-level constant, which outlives every function).
pub fn isLocalLoan(self: *const Checker, l: Loan) bool {
    if (l.ext or self.isGlobal(l.root)) return false;
    if (l.frame) return true;
    const r = self.vars.items[l.root];
    return !(r.kind == .param and r.ref != .none);
}

// -----------------------------------------------------------------------------
// Self's paths: what a method may keep of self
// -----------------------------------------------------------------------------

/// Whether var `id` is the self of a method whose `from` names
/// paths of self (`bindSelfPaths`).
pub fn isSelfVar(self: *const Checker, id: VarId) bool {
    const s = self.func.self_var orelse return false;
    return s == id;
}

/// `v`, a value viewed or read from path `path` of var `root`, with
/// each loan the caller handed in through self (an external loan on
/// it) on that path, when `root` is the self of a method whose
/// `from` names paths of self: what the body returns is checked
/// against them (`checkSelfPaths`). Any other value is `v`.
pub fn tagSelf(self: *Checker, v: Value, root: VarId, path: PathId) Error!Value {
    if (!isSelfVar(self, root) or path == whole_path) return v;
    const retag = struct {
        fn is(c: *const Checker, l: Loan, r: VarId, p: PathId) bool {
            return l.ext and l.root == r and l.path != p and c.paths.within(p, l.path);
        }
    };
    for (v.loans) |l| {
        if (!retag.is(self, l, root, path)) continue;
        var out: std.ArrayList(Loan) = .empty;
        for (v.loans) |k| {
            var t = k;
            if (retag.is(self, k, root, path)) t.path = path;
            if (!containsLoan(out.items, t)) try out.append(self.arena(), t);
        }
        return .{ .loans = out.items };
    }
    return v;
}

/// In a method whose `from` names paths of self (`sema.SelfPath`),
/// note its self and those paths, so the body's views of self are
/// tagged with the path they come from (`tagSelf`).
pub fn bindSelfPaths(self: *Checker) Error!void {
    const sps = self.func.origins.self_paths;
    if (sps.len == 0) return;
    const start = self.scopes.items[self.scopes.items.len - 1].start;
    const id: VarId = for (self.vars.items[start..], start..) |v, i| {
        if (std.mem.eql(u8, v.name, "@")) break @intCast(i);
    } else return;
    if (self.vars.items[id].kind != .param) return;
    const out = try self.arena().alloc(PathId, sps.len);
    for (sps, out) |sp, *p| p.* = try selfPathId(self, whole_path, sp);
    self.func.self_var = id;
    self.func.self_paths = out;
}

/// The path `sp` names below path `from` of a place, cut where paths
/// are cut (`Paths.max_depth`), which only adds conflicts.
pub fn selfPathId(self: *Checker, from: PathId, sp: sema.SelfPath) Error!PathId {
    var p = from;
    for (sp.fields) |f| {
        if (self.paths.depth(p) >= Paths.max_depth) break;
        p = try self.paths.child(self.gpa, p, f);
    }
    return p;
}

/// Whether path `p` of self is within a path the method's `from`
/// names.
pub fn withinSelfPaths(self: *const Checker, p: PathId) bool {
    for (self.func.self_paths) |sp| if (self.paths.within(p, sp)) return true;
    return false;
}

/// What a call's result carries of its self when its callee's
/// `from` names paths of self (Core sentence 7, `sema.SelfPath`): the
/// loans self holds, `held`, as the call runs, and for each path not
/// declared as a read view a loan on that path of self's
/// place (`root`, `path`), never a loan on all of it. A self that
/// is no place keeps its whole view, `viewed`, for such a path. When
/// self is itself a view, what it holds is what that view carries.
pub fn selfPathsResult(self: *Checker, paths: []const sema.SelfPath, root: ?VarId, path: PathId, kind: LoanKind, pos: u32, held: Value, viewed: Value) Error!Value {
    // A self that is no place is a value the statement holds (a
    // temporary), whose loans are what it holds.
    var holds = held;
    if (root == null) {
        var loans: std.ArrayList(Loan) = .empty;
        for (held.loans) |l| {
            const hidden = self.vars.items[l.root].kind == .hidden and !l.ext;
            for (if (hidden) self.flows.items[l.root].loans else &.{l}) |k| {
                if (!containsLoan(loans.items, k)) try loans.append(self.arena(), k);
            }
        }
        holds = .{ .loans = loans.items };
    }
    var out: Value = .{};
    for (paths) |sp| {
        var part = holds;
        if (root) |id| {
            const p = try selfPathId(self, path, sp);
            if (!sp.via_view) part = try self.valueUnion(part, try transfer.viewOn(self, id, .{ .root = id, .path = p, .kind = kind, .pos = pos }));
            part = try tagSelf(self, part, id, p);
        } else if (!sp.via_view) part = try self.valueUnion(part, viewed);
        out = try self.valueUnion(out, part);
    }
    return out;
}

/// A loan on a part of var `id` that a value carrying `loans` keeps,
/// directly or through what the vars they are on hold (a view of `r`
/// keeps what `r` views), but for `views` and the loans on `through`:
/// the ways the store goes in (`absorbLoans`). A value never holds a
/// view of itself (Core §5).
pub fn selfViewIn(self: *Checker, id: VarId, loans: []const Loan, views: []const Loan, through: []const VarId) Error!?Loan {
    // `loans`, then what the vars they are on hold, each var once,
    // which is copied only where there is some.
    var seen: ?std.DynamicBitSetUnmanaged = null;
    var work: std.ArrayList(Loan) = .empty;
    var i: usize = 0;
    while (true) : (i += 1) {
        const l = if (i < loans.len) loans[i] else if (i - loans.len < work.items.len) work.items[i - loans.len] else break;
        if (l.ext or l.root >= self.vars.items.len) continue;
        if (l.root == id) {
            if (!isViewOf(views, l)) return l;
            continue;
        }
        const held = self.flows.items[l.root].loans;
        if (held.len == 0 or std.mem.findScalar(VarId, through, l.root) != null) continue;
        if (seen == null) seen = try .initEmpty(self.arena(), self.vars.items.len);
        if (seen.?.isSet(l.root)) continue;
        seen.?.set(l.root);
        try work.appendSlice(self.arena(), held);
    }
    return null;
}

// -----------------------------------------------------------------------------
// A body against its signature
// -----------------------------------------------------------------------------

/// The origins of the function or method declared with name `name`:
/// which arguments its callers pass loans on from.
pub fn declOrigins(self: *const Checker, name: Sexp) sema.Origins {
    const ctx = self.sema;
    if (name != .src) return .{};
    // An addition's method, which no symbol's fields hold.
    for (ctx.conformances.items) |c| for (c.methods) |f| {
        if (f.decl_pos == name.src.pos) return f.origins;
    };
    if (self.decl_owner) |owner| {
        const fields = ctx.symbols.items[owner].fields orelse &.{};
        // The first method of its name, unless two share it.
        if (sema.memberIn(ctx, fields, types.text(self, name), .method)) |i| {
            if (fields[i].decl_pos == name.src.pos) return fields[i].origins;
        }
        for (fields) |f| {
            if (f.is_method and f.decl_pos == name.src.pos) return f.origins;
        }
        return .{};
    }
    const sym = ctx.symbolOf(name) orelse return .{};
    const s = ctx.symbols.items[sym];
    return if (s.kind == .function) s.origins else .{};
}

/// The origins a call of a value of function type `fn_ty` has: those
/// its type gives (`sema.defaultOrigins`).
pub fn typeOrigins(self: *Checker, fn_ty: ?TypeId) Error!sema.Origins {
    const ctx = self.sema;
    const f = switch (ctx.types.get(fn_ty orelse return .{})) {
        .function => |f| f,
        else => return .{},
    };
    var scratch = std.heap.ArenaAllocator.init(self.gpa);
    defer scratch.deinit();
    return sema.defaultOrigins(ctx, scratch.allocator(), f);
}

/// Where result `expr` gives the view of parameter `name`: through
/// an `if`'s branches, the branch whose value is `name` itself, or
/// else one whose value reads it; null when it is `expr` as a whole.
pub fn resultPos(self: *const Checker, expr: Sexp, name: []const u8) ?u32 {
    const tail = sema.tailOf(expr);
    if (tail == .nil) return null;
    if (!tail.isKind(.@"if")) return if (notes.startOf(self, tail) == notes.startOf(self, expr)) null else notes.startOf(self, tail);
    const branches = [_]Sexp{ ir.If.then(tail), ir.If.@"else"(tail) };
    for (branches) |b| {
        const bt = sema.tailOf(b);
        if (bt == .src and std.mem.eql(u8, types.text(self, bt), name)) return notes.startOf(self, bt);
    }
    for (branches) |b| {
        if (b == .nil) continue;
        if (transfer.readsName(self, sema.tailOf(b), name)) return resultPos(self, b, name) orelse notes.startOf(self, sema.tailOf(b));
    }
    return null;
}

/// The index of the current function's run-time parameter that
/// loan `l` is on, if any: a loan the caller handed in through it,
/// or one of it as a view (`?p` with `p: !T`).
pub fn paramOf(self: *const Checker, l: Loan) ?u8 {
    if (self.func.in_closure and l.root < self.func.closure_base) return null;
    const r = self.vars.items[l.root];
    if (r.kind != .param) return null;
    return r.param_index;
}

/// Record that the function returns `v`: the parameters whose loans
/// it carries are among those a call's result carries.
pub fn recordResult(self: *Checker, v: Value, expr: Sexp) void {
    // A loan on what is the function's own (a parameter taken by
    // value) cannot leave it, which `checkEscape` reports.
    for (v.loans) |l| if (!isLocalLoan(self, l)) if (paramOf(self, l)) |i| {
        if (self.func.self_escape == null and isSelfVar(self, l.root) and !withinSelfPaths(self, l.path)) self.func.self_escape = .{ .path = l.path, .at = resultPos(self, expr, "@") orelse notes.startOf(self, expr) };
        const bit = sema.paramBit(i);
        if (self.func.returned & bit == 0) {
            self.func.returned_at[i] = notes.startOf(self, expr);
            self.func.returned_by[i] = expr;
        }
        self.func.returned |= bit;
    };
}

/// Record that the function stores `loans` in what parameter `into`
/// leads to: the parameters they are on are among those a call may
/// store.
pub fn recordStore(self: *Checker, into: VarId, loans: []const Loan, pos: u32) void {
    // What cannot hold a view keeps no loan (`w = other` through
    // `w: !Int` copies a number), unless an instance's may.
    const held = types.pointee(self, self.vars.items[into].ty);
    if (generic.holdsGeneric(self, held)) generic.noteGenericStore(self, into, pos);
    if (!types.mayCarryLoan(self, held) and !generic.genericType(self, held)) return;
    for (loans) |l| if (l.root != into) if (paramOf(self, l)) |i| {
        const bit = sema.paramBit(i);
        if (self.func.stored & bit == 0) {
            self.func.stored_at[i] = pos;
            self.func.stored_in[i] = self.vars.items[into].name;
        }
        self.func.stored |= bit;
    };
}

/// `net.timeout`, when `leaf` is a read of a group's field that the
/// options rewrite wrote as the field's parameter
/// (`rig.Parser.group_targets`), else null.
pub fn groupFieldRead(self: *Checker, leaf: Sexp) Error!?[]const u8 {
    if (leaf != .src or !rig.isNamedLeaf(leaf)) return null;
    const p = self.sema.parser orelse return null;
    if (!p.group_targets.contains(leaf.src.pos)) return null;
    const id = self.sema.symbolOf(leaf) orelse return null;
    const group = self.sema.group_fields.get(id) orelse return null;
    return try sema.memberText(self.arena(), group, types.text(self, leaf));
}

/// How parameter `param` is named to a reader: its name, or, for a
/// group's field, `group.field`; and how `from` and `keeps` name it:
/// its name, or its group's.
pub fn paramShown(self: *Checker, param: Sexp) Error!struct { shown: []const u8, clause: []const u8 } {
    const pn = if (sema.paramNameNode(param)) |n| types.text(self, n) else "?";
    const of = sema.groupFieldOf(param) orelse return .{ .shown = pn, .clause = pn };
    const group = types.text(self, ir.FieldOf.group(of));
    return .{ .shown = try sema.memberText(self.arena(), group, pn), .clause = group };
}

/// A body passes on only the loans its signature shows (Core
/// sentence 7): what it returns and stores comes from the parameters
/// its origins name. `params` are its run-time parameters.
pub fn checkOrigins(self: *Checker, what: []const u8, name: Sexp, params: Sexp) Error!void {
    try checkSelfPaths(self, what, name);
    const o = self.func.origins;
    const items = params.items();
    // What reached a value of a type parameter's type is returned and
    // stored wherever such a value is (`taintGeneric`).
    for (0..@min(items.len, @bitSizeOf(sema.ParamMask))) |i| {
        const bit = sema.paramBit(i);
        if (self.func.generic & bit == 0) continue;
        if (self.func.generic_returned_at) |at| if (self.func.returned & bit == 0) {
            self.func.returned |= bit;
            self.func.returned_at[i] = at;
        };
        if (self.func.stored & bit != 0) continue;
        for (self.func.generic_stores[0..self.func.generic_store_count]) |s| if (s.param != i) {
            self.func.stored |= bit;
            self.func.stored_at[i] = s.pos;
            self.func.stored_in[i] = s.name;
            break;
        };
    }
    const n = @min(items.len, @bitSizeOf(sema.ParamMask));
    for (0..n) |i| {
        const bit = sema.paramBit(i);
        const named = try paramShown(self, items[i]);
        const pname = named.shown;
        if (self.func.returned & bit != 0 and o.result & bit == 0) {
            if (o.declared) {
                const only = try paramList(self, items, o.result, true, name);
                const at = resultPos(self, self.func.returned_by[i], if (sema.paramNameNode(items[i])) |pn| types.text(self, pn) else pname) orelse self.func.returned_at[i];
                if (only.len == 0) {
                    try notes.err(self, at, "{s} returns a view of `{s}`, but its signature says it views only what lives for the whole program", .{ what, pname });
                } else try notes.err(self, at, "{s} returns a view of `{s}`, but its signature says it views only {s}", .{ what, pname, only });
                if (declaredFrom(self, name)) |d| {
                    const all = try paramList(self, items, self.func.returned, false, name);
                    if (namesStatic(self, items, self.func.returned)) {
                        try notes.note(self, notes.startOf(self, d.returns), "`from static` means what lives for the whole program, not the parameter `static`; rename the parameter to name it in `from`", .{});
                    } else try notes.note(self, notes.startOf(self, d.returns), "say so: `-> {s} from {s}`, or return a view of what it names only", .{ notes.spanText(self, d.returns), all });
                }
                return;
            }
            try notes.err(self, self.func.returned_at[i], "{s} returns a view of `{s}`, but a call of it does not count as a view of `{s}`: its type cannot hold what the result views", .{ what, pname, pname });
        }
        if (self.func.stored & bit != 0 and o.stores & bit == 0) {
            if (o.viewed & bit != 0) {
                // A view parameter is kept only where `keeps` names it.
                const into = self.func.stored_in[i];
                const kept = try paramList(self, items, (o.stores & o.viewed) | (self.func.stored & o.viewed), false, .nil);
                try notes.err(self, self.func.stored_at[i], "{s} stores a view of `{s}` in `{s}`, which its caller reaches, but its signature does not keep `{s}`; say so: `keeps {s}`", .{ what, pname, into, named.clause, kept });
            } else try notes.err(self, self.func.stored_at[i], "{s} stores a view of `{s}` where its caller can reach it, but a call of it keeps no view of `{s}`: its type cannot hold what the write parameters hold", .{ what, pname, pname });
        }
    }
}

/// A method whose `from` names paths of self returns views of those
/// paths only (Core sentence 7): a view of another path of self, or
/// of all of it, that the body returns, directly or through a value
/// of a type parameter's type it returns (a call through a bound
/// views its self, `taintGeneric`), is reported.
pub fn checkSelfPaths(self: *Checker, what: []const u8, name: Sexp) Error!void {
    if (self.func.self_var == null) return;
    const e = self.func.self_escape orelse
        (if (self.func.generic_returned_at != null) self.func.generic_self_path else null) orelse return;
    const d = declaredFrom(self, name) orelse return;
    // Self's var has left scope: its path is spelled from `@`.
    var path: std.ArrayList(u8) = .empty;
    try path.append(self.arena(), '@');
    try self.paths.appendText(self.arena(), &path, e.path);
    if (path.items.len > 2) _ = path.orderedRemove(1);
    const got = path.items;
    // What the clause names, and the fix: the clause with the path
    // the body returns, all of self (`@`) holding every other path.
    var only: std.ArrayList(u8) = .empty;
    var fix: std.ArrayList(u8) = .empty;
    for (d.names.items()) |n| {
        if (only.items.len > 0) try only.appendSlice(self.arena(), ", ");
        try only.print(self.arena(), "`{s}`", .{notes.spanText(self, n)});
        if (e.path == whole_path and n.isKind(.member)) continue;
        try fix.print(self.arena(), "{s}, ", .{notes.spanText(self, n)});
    }
    try fix.appendSlice(self.arena(), got);
    try notes.err(self, e.at, "{s} returns a view of `{s}`, but its signature says it views only {s}", .{ what, got, only.items });
    try notes.note(self, notes.startOf(self, d.returns), "say so: `-> {s} from {s}`, or return a view of what it names only", .{ notes.spanText(self, d.returns), fix.items });
}

/// Whether a parameter of `mask` among `items` is named `static`,
/// which `from` cannot name.
pub fn namesStatic(self: *const Checker, items: []const Sexp, mask: sema.ParamMask) bool {
    for (items, 0..) |p, i| {
        if (mask & sema.paramBit(i) == 0) continue;
        const pn = sema.paramNameNode(p) orelse continue;
        if (std.mem.eql(u8, types.text(self, pn), "static")) return true;
    }
    return false;
}

/// The `from` clause of the function named `name`, if it writes one.
pub fn declaredFrom(self: *const Checker, name: Sexp) ?sema.DeclaredOrigins {
    const ctx = self.sema;
    if (name != .src) return null;
    return ctx.declared_origins.get(name.src.pos);
}

/// The parameters of `mask` among `items`, as a `from` list (`a, b`),
/// each in backquotes when `quoted`. Self is the paths of it that the
/// `from` of function `name` names (`from @text`), when it names any.
pub fn paramList(self: *Checker, items: []const Sexp, mask: sema.ParamMask, quoted: bool, name: Sexp) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const clause: []const Sexp = if (self.func.origins.self_paths.len == 0) &.{} else if (declaredFrom(self, name)) |d| d.names.items() else &.{};
    var groups: std.ArrayList([]const u8) = .empty;
    for (items, 0..) |p, i| {
        if (mask & sema.paramBit(i) == 0) continue;
        if (sema.paramNameNode(p) == null) continue;
        // A group's fields are named by the group's name, once.
        const pn = (try paramShown(self, p)).clause;
        if (sema.groupFieldOf(p) != null) {
            const seen = for (groups.items) |g| {
                if (std.mem.eql(u8, g, pn)) break true;
            } else false;
            if (seen) continue;
            try groups.append(self.arena(), pn);
        }
        var paths: usize = 0;
        if (std.mem.eql(u8, pn, "@")) for (clause) |c| if (c.isKind(.member)) {
            try appendListName(self, &out, notes.spanText(self, c), quoted);
            paths += 1;
        };
        if (paths == 0) try appendListName(self, &out, pn, quoted);
    }
    return out.items;
}

/// `item` appended to the list `out` (`paramList`).
pub fn appendListName(self: *Checker, out: *std.ArrayList(u8), item: []const u8, quoted: bool) Error!void {
    if (out.items.len > 0) try out.appendSlice(self.arena(), ", ");
    if (quoted) try out.append(self.arena(), '`');
    try out.appendSlice(self.arena(), item);
    if (quoted) try out.append(self.arena(), '`');
}
