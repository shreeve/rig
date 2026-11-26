//! Typecheck's generic requirements: what a generic body asks of its
//! type parameters, checked at each instance, and the frames of
//! functions.

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const sema = @import("../sema.zig");
const storage = @import("../storage.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const SymbolRef = sema.SymbolRef;
const TypeId = sema.TypeId;
const Field = sema.Field;
const TypeSubst = sema.TypeSubst;
const Requirement = sema.Requirement;
const Error = std.mem.Allocator.Error;
const identAt = sema.identAt;
const tc = @import("../typecheck.zig");
const Checker = tc.Checker;
const ApiCheck = @import("apis.zig");
const CompatCheck = @import("compat.zig");

/// Every instantiation of a generic type, and every instance of a
/// generic function, must support the operations its bodies apply to
/// the type parameters (`@value + 1` requires a numeric `T`). Checked
/// after all bodies, against every instance the module's code makes
/// that no earlier module made (`sema.checkedBefore`).
/// An instance's type arguments, each standing as one (`sema.misplaced`):
/// a value holding a Cell by value, a write view, a bare API object, a
/// frozen value, or an actor's value is no type argument.
/// True when one stands misplaced, reported at the instance's site when
/// `report` gives one.
pub fn misplacedArgs(ctx: *SemContext, args: []const TypeId, report: ?u32) Error!bool {
    for (args) |arg| {
        if (sema.containsPoison(ctx, arg)) continue;
        const why = sema.misplaced(ctx, arg, .type_arg) orelse continue;
        const site = report orelse return true;
        const shown = try sema.formatType(ctx, arg);
        switch (why) {
            .cell => try ctx.err(site, sema.cell_misplaced, .{ shown, shown }),
            .write_view => try ctx.err(site, sema.write_view_misplaced, .{shown}),
            .unsized => try ctx.err(site, sema.object_unsized_arg, .{shown}),
            .frozen => try ctx.err(site, sema.frozen_misplaced_arg, .{ shown, shown }),
            .actor => try ctx.err(site, sema.actor_misplaced, .{shown}),
        }
        return true;
    }
    return false;
}

/// What the module's generic bodies, headers, APIs, and conformances
/// declare, checked before the instances are expanded, which read what
/// each conformance's witness names (`sema.Conformance.members`).
pub fn checkDeclaredApis(ctx: *SemContext) Error!void {
    try checkStatedForwards(ctx);
    try checkBoundedBodies(ctx);
    try checkHeaders(ctx);
    try ApiCheck.checkApis(ctx);
}

pub fn checkGenericInstantiations(ctx: *SemContext) Error!void {
    var reqs: Requirements = .empty;
    defer {
        var lists = reqs.valueIterator();
        while (lists.next()) |l| l.deinit(ctx.allocator);
        reqs.deinit(ctx.allocator);
    }
    for (ctx.generic_requirements.items, 0..) |req, i| {
        // A method's own, where the method is reached (`checkReaches`).
        if (req.body != sema.no_body) continue;
        const gop = try reqs.getOrPut(ctx.allocator, ctx.ref(req.param));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(ctx.allocator, @intCast(i));
    }
    // An instance an earlier module made is checked there
    // (`sema.checkedBefore`).
    var key: sema.InstanceKey = .{};
    defer key.deinit(ctx.allocator);
    var it = ctx.instantiation_sites.iterator();
    while (it.next()) |entry| {
        const pn = switch (ctx.types.get(entry.key_ptr.*)) {
            .parameterized_nominal => |pn| pn,
            else => continue,
        };
        if (sema.symbolAt(ctx, pn.sym).type_params == null) continue;
        const params = sema.paramRefs(ctx, pn.sym);
        const k = try key.ofType(ctx, entry.key_ptr.*);
        if (try checkedBefore(ctx, k) != null) continue;
        const mark = ctx.diagnostics.items.len;
        try checkTypeInstance(ctx, &reqs, entry.key_ptr.*, params, entry.value_ptr.*);
        sema.noteInstanceChecked(ctx, k, mark);
    }
    // A method's instance checks only its own parameters; its type's
    // are checked with self's instance.
    // An instance made by one whose bounds failed is not checked: the
    // failure written at the call is the error, and the generics that
    // instance calls would only repeat it (`sort.sort[F32]` and each of
    // the bounded helpers it reaches). In a later module, so is one made
    // by an instance whose check failed in an earlier one.
    var failed: std.HashMapUnmanaged(sema.FnInstance, void, sema.FnInstance.Context, 80) = .empty;
    defer failed.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < ctx.fn_instances.items.len) : (i += 1) {
        const f = ctx.fn_instances.items[i];
        if (f.via) |via| if (via == .func and failed.contains(via.func)) continue;
        const k = try key.ofFn(ctx, f.inst);
        if (try checkedBefore(ctx, k)) |before| {
            if (before.failed) try failed.put(ctx.allocator, f.inst, {});
            continue;
        }
        const mark = ctx.diagnostics.items.len;
        if (!try checkFnInstance(ctx, &reqs, f)) try failed.put(ctx.allocator, f.inst, {});
        sema.noteInstanceChecked(ctx, k, mark);
    }
    try checkReaches(ctx);
}

/// What an earlier module found checking the instance `key` names
/// (`sema.checkedBefore`), noting an error it reported
/// (`SemContext.failed_elsewhere`).
fn checkedBefore(ctx: *SemContext, key: []const u8) Error!?sema.Checked {
    const before = try sema.checkedBefore(ctx, key) orelse return null;
    if (before.failed) ctx.failed_elsewhere = true;
    return before;
}

/// Check the generic type's instance `ty`, over `params`, first made at
/// `site`.
fn checkTypeInstance(ctx: *SemContext, reqs: *Requirements, ty: TypeId, params: []const SymbolRef, site: u32) Error!void {
    const pn = ctx.types.get(ty).parameterized_nominal;
    // A box holds an API object through its allocation, `^{Shape}`.
    if (pn.sym == ctx.builtins.box and pn.args.len == 1 and sema.apiObject(ctx, pn.args[0]) != null) return;
    if (try misplacedArgs(ctx, pn.args, site)) return;
    const of: sema.InstanceRoot = .{ .type = ty };
    if (!try sema.checkBounds(ctx, params, pn.args, site, of)) return;
    if (!try checkRequirements(ctx, reqs, params, pn.args, site, of)) return;
    if (!try checkMethodCalls(ctx, .{ .params = params, .args = pn.args }, params, site, of)) return;
    try checkInstanceSizes(ctx, params, pn.args, site, of);
}

/// An entry of `SemContext.fn_instances`: an instance and where it is made.
const FnInstanceSite = @typeInfo(@FieldType(@FieldType(SemContext, "fn_instances"), "items")).pointer.child;

/// Check the generic function's instance `f`. False when its bounds
/// fail.
fn checkFnInstance(ctx: *SemContext, reqs: *Requirements, f: FnInstanceSite) Error!bool {
    // An implementation's method reached through an API has the
    // arguments the call's instance of the API's method checks and
    // reports.
    if (try misplacedArgs(ctx, f.inst.ownArgs(), if (f.through_api) null else f.site)) return true;
    const of: sema.InstanceRoot = .{ .func = f.inst };
    // So are its bounds, which are the API's method's.
    const bounded = if (f.through_api) try sema.boundsMet(ctx, f.inst.ownParams(), f.inst.ownArgs()) else try sema.checkBounds(ctx, f.inst.ownParams(), f.inst.ownArgs(), f.site, of);
    if (!bounded) {
        if (!f.through_api) if (f.via) |via| try ctx.note(f.site, "`{s}` is made by `{s}`", .{ try sema.rootName(ctx, of), try sema.rootName(ctx, via) });
        return false;
    }
    if (try checkRequirements(ctx, reqs, f.inst.ownParams(), f.inst.ownArgs(), f.site, of) and
        try checkMethodCalls(ctx, f.inst.subst(), f.inst.ownParams(), f.site, of))
    {
        try checkInstanceSizes(ctx, f.inst.params, f.inst.args, f.site, of);
    } else if (f.via) |via| try ctx.note(f.site, "`{s}` is made by `{s}`", .{ try sema.rootName(ctx, of), try sema.rootName(ctx, via) });
    return true;
}

/// Record the frame owners of `tree` (`sema.FrameOwner`), each with the
/// owner around it, and every call with the innermost owner around it
/// and the copies of it Zig writes (`sema.FrameCall`): one walk, which
/// knows the owners by a positive list of their kinds. Nothing else
/// finds an owner or attributes a call; `accounts.count`, `inlining.decide`,
/// and `rig check --facts=frames` read these.
pub fn recordFrameOwners(ctx: *SemContext, tree: Sexp) Error!void {
    var w: OwnerWalker = .{ .ctx = ctx };
    try w.walk(tree, null, 1, .{});
    const a = ctx.arena.allocator();
    const owners = ctx.frame_owners.items;
    const counts = try a.alloc(u32, owners.len);
    @memset(counts, 0);
    for (ctx.frame_calls.items) |c| if (c.owner) |o| {
        counts[o] += 1;
    };
    const lists = try a.alloc([]u32, owners.len);
    for (lists, counts) |*l, n| l.* = try a.alloc(u32, n);
    @memset(counts, 0);
    for (ctx.frame_calls.items, 0..) |c, i| if (c.owner) |o| {
        lists[o][counts[o]] = @intCast(i);
        counts[o] += 1;
    };
    for (owners, lists) |*o, l| o.calls = l;
}

pub const OwnerWalker = struct {
    ctx: *SemContext,

    /// What the declarations around a function make it: a member of a
    /// type, and of a generic one, and the type's name.
    const Decl = struct { member: bool = false, generic_type: bool = false, type_name: []const u8 = "" };

    /// `copies`: how many times Zig writes the code `node` is in, which a
    /// `defer` or `errdefer` body multiplies by its exits
    /// (`accounts.Walker.deferBody` counts its values the same way).
    fn walk(self: *OwnerWalker, node: Sexp, owner: ?u32, copies: u32, decl: Decl) Error!void {
        const ctx = self.ctx;
        if (node != .list) return;
        const kind = node.kind() orelse {
            for (node.items()) |c| try self.walk(c, owner, copies, decl);
            return;
        };
        const a = ctx.arena.allocator();
        switch (kind) {
            .use => {},
            .fun, .sub => {
                // A compile-time function has no frame: it never runs when
                // the program does.
                if (rig.isCtFun(node)) return;
                const name = ir.get(node, .name);
                const label = try a.print("`{s}`", .{sema.identAt(ctx.source, name) orelse "?"});
                const o = try self.add(.{ .kind = .function, .root = node, .parent = owner, .pos = ctx.startOf(name), .label = label, .member = decl.member, .of_generic_type = decl.generic_type, .type_name = decl.type_name });
                for ([_]Sexp{ ir.get(node, .params), ir.get(node, .body) }) |part| try self.walk(part, o, 1, .{});
            },
            .@"test" => {
                const label = try a.print("test {s}", .{sema.identAt(ctx.source, ir.get(node, .name)) orelse "?"});
                const o = try self.add(.{ .kind = .test_block, .root = node, .parent = owner, .pos = ctx.startOf(node), .label = label });
                try self.walk(ir.get(node, .body), o, 1, .{});
            },
            .drop_decl => {
                const o = try self.add(.{ .kind = .drop, .root = node, .parent = owner, .pos = ctx.startOf(node), .label = "`drop`" });
                for ([_]Sexp{ ir.get(node, .params), ir.get(node, .body) }) |part| try self.walk(part, o, 1, .{});
            },
            .lambda => {
                // The captures are made where the closure is.
                try self.walk(ir.Lambda.captures(node), owner, copies, decl);
                const o = try self.add(.{ .kind = .closure, .root = node, .parent = owner, .pos = ctx.startOf(node), .label = "a closure" });
                for ([_]Sexp{ ir.Lambda.params(node), ir.Lambda.body(node) }) |part| try self.walk(part, o, 1, .{});
            },
            .@"struct", .@"enum", .errors, .generic_struct, .generic_enum => {
                const of: Decl = .{ .member = true, .generic_type = decl.generic_type or kind == .generic_struct or kind == .generic_enum, .type_name = sema.identAt(ctx.source, ir.get(node, .name)) orelse "" };
                for (rig.children(node)) |c| try self.walk(c, owner, copies, of);
            },
            .call => {
                // The callee first, as its object's calls run first.
                try self.walk(ir.Call.callee(node), owner, copies, decl);
                const i: u32 = @intCast(ctx.frame_calls.items.len);
                try ctx.frame_calls.append(ctx.allocator, .{ .node = node, .owner = owner, .copies = copies });
                if (sema.decisionKeyOf(node)) |k| try ctx.call_index.put(ctx.allocator, k, i);
                for (ir.Call.args(node)) |arg| try self.walk(arg, owner, copies, decl);
            },
            else => {
                const kids = rig.children(node);
                for (kids, 0..) |c, i| {
                    if (owner != null and (c.isKind(.@"defer") or c.isKind(.@"errdefer"))) {
                        var exits: u32 = 1;
                        for (kids[i + 1 ..]) |r| exits += @intCast(countExits(r));
                        // Saturating: a count that large fails every limit.
                        try self.walk(ir.get(c, .body), owner, copies *| exits, decl);
                        continue;
                    }
                    try self.walk(c, owner, copies, decl);
                }
            },
        }
    }

    fn add(self: *OwnerWalker, o: sema.FrameOwner) Error!u32 {
        const i: u32 = @intCast(self.ctx.frame_owners.items.len);
        try self.ctx.frame_owners.append(self.ctx.allocator, o);
        return i;
    }
};

/// The exits in `e` (`storage.leave_kinds`), not counting those in its
/// closures.
pub fn countExits(e: Sexp) usize {
    if (e != .list) return 0;
    const kind = e.kind() orelse {
        var n: usize = 0;
        for (e.items()) |c| n += countExits(c);
        return n;
    };
    if (kind == .lambda) return 0;
    var n: usize = @intFromBool(std.mem.findScalar(Tag, &storage.leave_kinds, kind) != null);
    for (rig.children(e)) |c| n += countExits(c);
    return n;
}

/// How a frame's types (`sema.Frame.tys`) are laid out: the values, then
/// `copies`, which are copies its code may make, then `params`, a
/// function's parameters as the code copies them where it is inlined;
/// of the values the last `marked`, and of the copies the last
/// `marked_copies`, are what calls of marked `inline` functions land in
/// it.
pub const FrameParts = struct { copies: u32 = 0, marked: u32 = 0, marked_copies: u32 = 0, params: u32 = 0 };

/// A frame's count: its own values, what marked calls land in it
/// (`sema.Account`), and the reach of its parameters' copies where it is
/// inlined (`sema.FrameOwner.params`).
pub const FrameCounted = struct { own: sema.FrameCount, marked: sema.FrameCount, params: u128 = 0 };

/// Check the frame of `label` whose types are `tys`, laid out as `parts`
/// says: its count, its own values and what marked calls land in it
/// together, against `sema.max_frame_bytes` and its reach against
/// `sema.max_frame_reach`. A large one marks its declaration, at `decl`
/// in `module` (0 for this one), `noinline` (`sema.SemContext.large_frames`).
/// A marked `inline` function's frame is counted, for what the rule
/// inlines through it (`inlining.decide`), and not checked: Zig never
/// writes it, and its values land in each caller's, which is.
pub fn checkFrame(ctx: *SemContext, pos: u32, label: []const u8, of: ?sema.InstanceRoot, tys: []const TypeId, names: []const []const u8, parts: FrameParts, decl: u32) Error!?FrameCounted {
    return checkFrameIn(ctx, pos, label, of, tys, names, parts, 0, decl);
}

/// The count of the frame, null when a value in it follows an error. It
/// is recorded (`SemContext.frame_sizes`) as the frame of the owner
/// declared at `decl` in module `module` (0 for this one).
pub fn checkFrameIn(ctx: *SemContext, pos: u32, label: []const u8, of: ?sema.InstanceRoot, tys: []const TypeId, names: []const []const u8, parts: FrameParts, module: u32, decl: u32) Error!?FrameCounted {
    const body = tys[0 .. tys.len - parts.params];
    const values = body[0 .. body.len - parts.copies];
    const copied = body[values.len..];
    const bytes = (try frameBytes(ctx, values)) orelse return null;
    const reach = bytes + ((try reachBytes(ctx, copied)) orelse return null);
    const marked_bytes = (try frameBytes(ctx, values[values.len - parts.marked ..])) orelse return null;
    const marked: sema.FrameCount = .{ .bytes = marked_bytes, .reach = marked_bytes + ((try reachBytes(ctx, copied[copied.len - parts.marked_copies ..])) orelse return null) };
    const params = (try reachBytes(ctx, tys[body.len..])) orelse return null;
    const counted: FrameCounted = .{ .own = .{ .bytes = bytes - marked.bytes, .reach = reach - marked.reach }, .marked = marked, .params = params };
    const shown = if (of) |root| try ctx.arena.allocator().print("{s} in `{s}`", .{ label, try sema.rootName(ctx, root) }) else label;
    const declared = if (module == 0) ctx.module_id else module;
    try ctx.frame_sizes.append(ctx.allocator, .{ .label = shown, .pos = pos, .bytes = counted.own.bytes, .reach = counted.own.reach, .marked = marked, .params = params, .module = declared, .decl = decl });
    // A marked `inline` function's frame is never written: its values
    // land in each caller's, which is checked in turn.
    const decl_ctx = ctx.declaringContext(.{ .module = declared, .pos = decl }) orelse return counted;
    if (decl_ctx.inline_decls.contains(decl)) return counted;
    if (bytes > sema.max_frame_bytes) {
        try reportFrame(ctx, pos, label, bytes, of, values, names[0..values.len]);
        return counted;
    }
    if (reach * sema.reach_factor > sema.max_frame_reach) {
        const in = if (of) |root| try ctx.arena.allocator().print(" in `{s}`", .{try sema.rootName(ctx, root)}) else "";
        try ctx.err(pos, "{s} makes or copies {d} bytes of values{s}, and a build may hold each in a temporary of its own on the stack, {d} times over at most; a function's code may take at most {d} bytes (512 MiB) of stack. Keep large data on the heap, in a box (`^T`) or a `List`, or split the function", .{ label, reach, in, sema.reach_factor, sema.max_frame_reach });
        return counted;
    }
    if (reach * sema.reach_factor < sema.noinline_reach) return counted;
    // Within `max_frame_reach`, checked above.
    const takes: u64 = @intCast(reach * sema.reach_factor);
    if (declared == ctx.module_id) try sema.markLarge(&ctx.large_frames, ctx.allocator, decl, takes) else try ctx.large_foreign_frames.append(ctx.allocator, .{ .module = module, .pos = decl, .bytes = takes });
    return counted;
}

/// The bytes of the copies `tys`, each that does not fit in registers;
/// null when one follows an error.
pub fn reachBytes(ctx: *SemContext, tys: []const TypeId) Error!?u128 {
    var total: u128 = 0;
    for (tys) |ty| {
        if (sema.containsPoison(ctx, ty)) return null;
        const b = (try sema.minBytes(ctx, ty)) orelse return null;
        if (b > sema.register_bytes) total += b;
    }
    return total;
}

/// The bytes the values `tys` take together; null when one follows an
/// error or is too large by itself, which is reported on its own.
pub fn frameBytes(ctx: *SemContext, tys: []const TypeId) Error!?u128 {
    var total: u128 = 0;
    for (tys) |ty| {
        if (sema.containsPoison(ctx, ty)) return null;
        const b = (try sema.minBytes(ctx, ty)) orelse return null;
        if (b > sema.max_value_bytes) return null;
        total += b;
    }
    return total;
}

pub fn reportFrame(ctx: *SemContext, pos: u32, label: []const u8, bytes: u128, of: ?sema.InstanceRoot, tys: []const TypeId, names: []const []const u8) Error!void {
    const in = if (of) |root| try ctx.arena.allocator().print(" in `{s}`", .{try sema.rootName(ctx, root)}) else "";
    // The three largest, by name where a local has one.
    var top: [3]usize = undefined;
    var n: usize = 0;
    for (tys, 0..) |ty, i| {
        const b = (try sema.minBytes(ctx, ty)) orelse 0;
        var at = n;
        while (at > 0 and (try sema.minBytes(ctx, tys[top[at - 1]])).? < b) : (at -= 1) {}
        if (at >= top.len) continue;
        if (n < top.len) n += 1;
        var j = n - 1;
        while (j > at) : (j -= 1) top[j] = top[j - 1];
        top[at] = i;
    }
    var largest: std.ArrayList(u8) = .empty;
    for (top[0..n], 0..) |i, k| {
        const b = (try sema.minBytes(ctx, tys[i])) orelse 0;
        const what = if (names[i].len > 0) try ctx.arena.allocator().print("`{s}`", .{names[i]}) else "a temporary";
        try largest.appendSlice(ctx.arena.allocator(), try ctx.arena.allocator().print("{s}{s} ({d} bytes)", .{ if (k == 0) "" else ", ", what, b }));
    }
    try ctx.err(pos, "{s} keeps {d} bytes of values on its stack{s}; a function keeps at most {d} (13 MiB). Its largest: {s}. Keep large data on the heap, in a box (`^T`) or a `List`", .{ label, bytes, in, sema.max_frame_bytes, largest.items });
}

/// The arrays a generic declaration makes, in one instance, and a generic
/// type's instance itself, must fit `sema.max_value_bytes`; the instance
/// must also nest at most `sema.max_value_depth` deep.
pub fn checkInstanceSizes(ctx: *SemContext, params: []const SymbolRef, args: []const TypeId, at: u32, of: sema.InstanceRoot) Error!void {
    for (args) |a| if (sema.containsPoison(ctx, a)) return;
    const subst: sema.TypeSubst = .{ .params = params, .args = args };
    var entries: std.ArrayList(sema.HomeEntry) = .empty;
    defer entries.deinit(ctx.allocator);
    try ctx.genericEntries(.arrays, params, &entries);
    for (entries.items) |e| {
        const g = e.home.generic_arrays.items[e.index];
        const ty = try sema.substituteType(ctx, g.ty, subst);
        if (sema.containsTypeVar(ctx, ty) or sema.containsPoison(ctx, ty)) continue;
        const bytes = (try sema.arrayOversized(ctx, ty)) orelse continue;
        try ctx.oversized.put(ctx.allocator, ty, {});
        if (of == .type) try ctx.oversized.put(ctx.allocator, of.type, {});
        try ctx.err(at, "`{s}` makes `{s}`, which takes {d} bytes; a value takes at most {d} (8 MiB), since it may live on the stack. Keep larger data in a `List`", .{ try sema.rootName(ctx, of), try sema.formatType(ctx, ty), bytes, sema.max_value_bytes });
        try ctx.noteIn(e.module(ctx, g.module_id), g.pos, "the array is made here", .{});
        return;
    }
    if (of == .type) {
        const sym = ctx.types.get(of.type).parameterized_nominal.sym;
        if (try sema.oversizedByItself(ctx, of.type, sym, subst)) |bytes| {
            try sema.reportOversized(ctx, at, of.type, bytes);
            return;
        }
        if (try sema.tooDeepByItself(ctx, of.type, sym, subst)) |depth| {
            try sema.reportTooDeep(ctx, at, of.type, depth);
            return;
        }
    }
    // Its frames are counted from the module's LIR, after lowering
    // (`accounts.count`).
    const a = ctx.arena.allocator();
    try ctx.instance_frames.append(ctx.allocator, .{ .params = try a.dupe(SymbolRef, params), .args = try a.dupe(TypeId, args), .at = at, .of = of });
}

/// The frames of the generic instance over `params` and `args`, made at
/// `at`: a function instance checks the frames that use its own
/// parameters; those that use only its type's are checked with the type's
/// instance.
pub fn checkInstanceFrames(ctx: *SemContext, params: []const SymbolRef, args: []const TypeId, at: u32, of: sema.InstanceRoot) Error!void {
    const subst: sema.TypeSubst = .{ .params = params, .args = args };
    var entries: std.ArrayList(sema.HomeEntry) = .empty;
    defer entries.deinit(ctx.allocator);
    const own = switch (of) {
        .func => |f| f.ownParams(),
        .type => params,
    };
    var buf: std.ArrayList(TypeId) = .empty;
    defer buf.deinit(ctx.allocator);
    try ctx.genericEntries(.frames, own, &entries);
    frames: for (entries.items) |e| {
        const fr = e.home.generic_frames.items[e.index];
        const fr_module = e.module(ctx, fr.module_id);
        buf.clearRetainingCapacity();
        for (fr.tys) |ty| {
            const t = try sema.substituteType(ctx, ty, subst);
            if (sema.containsTypeVar(ctx, t)) continue :frames;
            try buf.append(ctx.allocator, t);
        }
        const before = ctx.diagnostics.items.len;
        _ = try checkFrameIn(ctx, at, fr.label, of, buf.items, fr.names, .{ .copies = fr.copies, .marked = fr.marked, .marked_copies = fr.marked_copies, .params = fr.params }, fr_module, fr.pos);
        if (ctx.diagnostics.items.len == before) continue;
        try ctx.noteIn(fr_module, fr.pos, "{s} is declared here", .{fr.label});
        return;
    }
}

/// Why a value holding `blocker` cannot go to another task
/// (`Checker.crossCheck`), and to be read there when `shared`; `verb`
/// says how it relates to `blocker` when it is that type or views it.
pub fn crossingReason(ctx: *SemContext, blocker: TypeId, shared: bool, verb: ?[]const u8) Error![]const u8 {
    const a = ctx.arena.allocator();
    const what = verb orelse try std.fmt.allocPrint(a, "holds `{s}`,", .{try sema.formatType(ctx, blocker)});
    const blocker_is_weak = ctx.types.get(blocker) == .weak;
    const why: []const u8 = switch (ctx.types.get(blocker)) {
        .shared, .weak => |inner| if (ctx.types.get(inner) == .function)
            "an owned closure, whose captures its type does not show"
        else if (blocker_is_weak and (sema.isWordCell(ctx, inner) or sema.cellObject(ctx, inner)))
            "a `~` handle, which stays with one task; a `*` handle to the same value goes to other tasks"
        else if (blocker_is_weak)
            "a `~` handle whose count is not atomic, so two cores could change it at once"
        else if (sema.isCell(ctx, inner))
            "a `*` handle to a Cell of more than one word, which stays with one task; a Cell of an `Int`, `Bool`, `Float`, or plain enum goes to other tasks"
        else if (try sema.cellRefusalReason(ctx, inner)) |reason|
            reason
        else
            "a `*` handle whose count is not atomic, so two cores could change it at once",
        .callable => "a closure or function passed to a call as a view, whose captures its type does not show",
        .write_view => "a write view, which no two tasks may hold at once",
        // The bound it lacks for the form that reached it: one named
        // alone says which the other is.
        .api_object => |o| blk: {
            const named = sema.objectBounds(ctx, o);
            if (named.contains(.Sends)) break :blk "an API object whose braces and API name no `Syncs`, so no two tasks may read what it hides";
            if (named.contains(.Syncs)) break :blk "an API object whose braces and API name no `Sends`, so what it hides may not go to another task";
            break :blk "an API object whose braces and API name no `Sends` or `Syncs` for this, so what it hides may go to no task";
        },
        .parameterized_nominal => |pn| if (pn.sym == ctx.builtins.task and shared)
            "a task, which only the one that holds it may wait for"
        else if (pn.sym == ctx.builtins.tasks)
            "a set of tasks, which stays with the task that made it"
        else
            "a value that changes through handles that stay on this core",
        else => "a value that cannot go to another core",
    };
    return std.fmt.allocPrint(a, "{s} {s}", .{ what, why });
}

/// `inst`, made at `at`, gives its parameter `pname` the type `arg`, which
/// fails `req`, a `Requirement.task` or `.no_task`: the error, and a note
/// at the body's line.
pub fn reportTaskReq(ctx: *SemContext, req: sema.GenericRequirement, at: u32, inst: []const u8, pname: []const u8, arg: TypeId) Error!void {
    const aname = try sema.formatType(ctx, arg);
    switch (req.req) {
        .no_task => {
            try ctx.err(at, "`{s}` cannot use `{s} = {s}`: {s}, and {s}", .{ inst, pname, aname, req.op, try ApiCheck.taskWhy(ctx, arg) });
            try ctx.noteIn(req.module_id, req.pos, "`{s}` hidden here", .{pname});
        },
        .task => |reach| {
            const blocker = (try sema.taskBlocker(ctx, arg, reach)).?;
            // A value a local task takes: the task the body makes crosses.
            // (An erasure hides the value in an object, which crosses by
            // its bound wherever it goes.)
            const crosses = !reach.local and (try sema.localBlocker(ctx, arg, reach.how)) == null and !std.mem.startsWith(u8, req.op, "is erased");
            const whose = if (std.mem.find(u8, req.op, "actor") != null) "the actor's task" else "the body's task";
            try ctx.err(at, "`{s}` cannot use `{s} = {s}`: a value that holds a `{s}` {s} in the generic body, and `{s}` {s}{s}{s}{s}", .{ inst, pname, aname, pname, req.op, aname, try crossingReason(ctx, blocker, reach.how == .shares, if (blocker == arg) "is" else null), if (crosses) "; " else "", if (crosses) whose else "", if (crosses) " may run on another core in every instance, so it takes nothing that stays on one thread" else "" });
            try ctx.noteIn(req.module_id, req.pos, "a `{s}` {s} here", .{ pname, req.op });
        },
        else => unreachable,
    }
}

/// The methods the program reaches (`sema.BodyReach`), each checked
/// against what its body requires of its type's parameters
/// (`GenericRequirement.body`): at the call that reaches it, or that
/// makes the instance of the body whose call does.
pub fn checkReaches(ctx: *SemContext) Error!void {
    var key: sema.InstanceKey = .{};
    defer key.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < ctx.body_reaches.items.len) : (i += 1) {
        const r = ctx.body_reaches.items[i];
        const k = try key.ofReach(ctx, r);
        if (try checkedBefore(ctx, k) != null) continue;
        const mark = ctx.diagnostics.items.len;
        defer sema.noteInstanceChecked(ctx, k, mark);
        // The body's requirements are recorded by the module it is in.
        const home: *const SemContext = if (r.fun.module == ctx.module_id) ctx else ctx.foreign_semas.get(r.fun.module) orelse continue;
        for (home.generic_requirements.items) |req0| {
            var req = req0;
            if (home != @as(*const SemContext, ctx) and req.module_id == 0) req.module_id = home.module_id;
            if (req.body == sema.no_body or req.body != r.fun.pos) continue;
            if ((if (req.module_id == 0) ctx.module_id else req.module_id) != r.fun.module) continue;
            if (req.index >= r.args.len) continue;
            const arg = r.args[req.index];
            if (sema.containsPoison(ctx, arg) or sema.containsTypeVar(ctx, arg)) continue;
            if (!try sema.liveAt(ctx, req.module_id, req.pos, r.params, r.args)) continue;
            if (try ApiCheck.satisfies(ctx, arg, req.req)) continue;
            const inst = try sema.rootName(ctx, .{ .func = try sema.reachInstance(ctx, r) });
            try reportTaskReq(ctx, req, r.site, inst, home.symbols.items[req.param].name, arg);
            if (r.via) |via| try ctx.note(r.site, "`{s}` is reached from `{s}`", .{ inst, try sema.rootName(ctx, via) });
            break;
        }
    }
}

/// The positions of `generic_requirements` on each parameter of this
/// module, in order. Another module's parameter's are read in its list
/// (`requirementsOn`).
pub const Requirements = std.AutoHashMapUnmanaged(SymbolRef, std.ArrayList(u32));

/// The requirements on `param`, by position in its home module's
/// `generic_requirements`: this module's from `reqs`, another's found
/// there and kept in `reqs`.
fn requirementsOn(ctx: *SemContext, reqs: *Requirements, param: SymbolRef) Error!?[]const u32 {
    if (ctx.owns(param)) return if (reqs.getPtr(param)) |l| l.items else null;
    const gop = try reqs.getOrPut(ctx.allocator, param);
    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
        const home = sema.homeOf(ctx, param);
        for (home.generic_requirements.items, 0..) |req, i| {
            if (req.body != sema.no_body or req.param != param.sym) continue;
            try gop.value_ptr.append(ctx.allocator, @intCast(i));
        }
    }
    return gop.value_ptr.items;
}

/// False after a diagnostic.
pub fn checkRequirements(ctx: *SemContext, reqs: *Requirements, given_params: []const SymbolRef, given_args: []const TypeId, at: u32, of: sema.InstanceRoot) Error!bool {
    var ok = true;
    // The associated types of the parameters too (`I.Item`), at what each
    // argument gives them.
    const all = try sema.withAssoc(ctx, given_params, given_args);
    const params = all.params;
    const args = all.args;
    for (params, 0..) |param_ref, i| {
        if (i >= args.len) break;
        const home = sema.homeOf(ctx, param_ref);
        const arg = args[i];
        // A diagnostic was reported about the argument.
        if (sema.containsPoison(ctx, arg)) continue;
        const on = (try requirementsOn(ctx, reqs, param_ref)) orelse continue;
        for (on) |r| {
            var req = home.generic_requirements.items[r];
            if (home != @as(*const SemContext, ctx) and req.module_id == 0) req.module_id = home.module_id;
            // What code this instance does not compile needs (`sema.liveAt`).
            if (!try sema.liveAt(ctx, req.module_id, req.pos, params, args)) continue;
            if (try ApiCheck.satisfies(ctx, arg, req.req)) continue;
            const inst = try sema.rootName(ctx, of);
            const pname = home.symbols.items[param_ref.sym].name;
            const aname = try sema.formatType(ctx, arg);
            const cannot = "`{s}` cannot use `{s} = {s}`: the generic body ";
            switch (req.req) {
                .copies, .no_cleanup => if (sema.typeHasDropGlue(ctx, arg))
                    try ctx.err(at, cannot ++ "{s} that holds a `{s}`, which would leak or duplicate the resource `{s}` owns", .{ inst, pname, aname, req.op, pname, aname })
                else
                    try ctx.err(at, cannot ++ "{s} that holds a `{s}`, and `{s}` is unique", .{ inst, pname, aname, req.op, pname, aname }),
                .clones => try ctx.err(at, cannot ++ "{s} that holds a `{s}`, and `{s}` is not `Clone`", .{ inst, pname, aname, req.op, pname, aname }),
                .array_len => try ctx.err(at, cannot ++ "uses `{s}` as an array length, which runs from 0 to {d}", .{ inst, pname, aname, pname, sema.max_array_len }),
                .lane_count => try ctx.err(at, cannot ++ "uses `{s}` as a lane count, a power of two from 2 to 64", .{ inst, pname, aname, pname }),
                .slot_count => try ctx.err(at, cannot ++ "names `Slot[{s}]`, and a slot names one of `n` slots, `n` at least 1", .{ inst, pname, aname, pname }),
                .sized => try ctx.err(at, cannot ++ "takes `${s}` of a type that holds a `{s}`, and `{s}` holds a vector, whose size and alignment differ from target to target", .{ inst, pname, aname, req.op, pname, aname }),
                .bytes => try ctx.err(at, cannot ++ "applies `{s}` to a `{s}` in bytes, which takes an integer or float type", .{ inst, pname, aname, req.op, pname }),
                .records => try ctx.err(at, cannot ++ "makes a `{s}` from bytes with `extend_from_bytes`, and not every bit pattern is {s} `{s}`: give `{s}` an integer, a float, or an object or array of them with no padding", .{ inst, pname, aname, pname, CompatCheck.article(aname), aname, pname }),
                .fits => |v| try ctx.err(at, cannot ++ "applies `{s}` to a `{s}` and the literal `{d}`, which `{s}` cannot hold", .{ inst, pname, aname, req.op, pname, v, aname }),
                .float => try ctx.err(at, cannot ++ "applies `{s}` to a `{s}` and a float literal, which `{s}` cannot hold", .{ inst, pname, aname, req.op, pname, aname }),
                .shift => |v| try ctx.err(at, cannot ++ "shifts a `{s}` by {d} bits, which `{s}` is too narrow for", .{ inst, pname, aname, pname, v, aname }),
                .printable => if (try sema.objectUnprinted(ctx, arg)) |held|
                    try ctx.err(at, cannot ++ "{s}s a value that holds a `{s}`, and `{s}` cannot be {s}: its type is erased, and its braces and API name no `Print`", .{ inst, pname, aname, req.op, pname, try sema.formatType(ctx, held), if (std.mem.eql(u8, req.op, "write")) "written" else "printed" })
                else
                    try ctx.err(at, cannot ++ "{s}s a value that holds a `{s}`, and {s} would {s} as text, like a `?String`", .{ inst, pname, aname, req.op, pname, if (std.mem.eql(u8, aname, "[]U8")) "a `[]U8`" else try ctx.arena.allocator().print("the `[]U8` a `{s}` holds", .{aname}), req.op }),
                .whole_division => try ctx.err(at, cannot ++ "gives a `{s}` the division of whole numbers `{s}`, which divides integers, not a `{s}`", .{ inst, pname, aname, pname, req.op, aname }),
                .not_error => try ctx.err(at, "`{s}` cannot use `{s} = {s}`: a return type `{s}!` would make a failure and a success both `{s}` values", .{ inst, pname, aname, pname, aname }),
                .error_set => try ctx.err(at, "`{s}` cannot use `{s} = {s}`: `{s}` names an error set, and `{s}` is not one", .{ inst, pname, aname, pname, aname }),
                .not_function => try ctx.err(at, cannot ++ "makes a handle `{s}{s}` of a `{s}`, and `{s}` is a function type: `*{s}` is an owned closure, not a handle of a function. Hold the owned closure itself in a `{s}`: `{s} = *{s}`", .{ inst, pname, aname, req.op[1..2], pname, pname, aname, aname, pname, pname, aname }),
                .named => {
                    const held = sema.unnameable(ctx, arg).?;
                    const what = if (held == arg) "is one" else try ctx.arena.allocator().print("holds `{s}`", .{try sema.formatType(ctx, held)});
                    try ctx.err(at, cannot ++ "names a type that holds a `{s}` with `$name`, which spells no view or slice in a type parameter's instance but a `?String`, and `{s}` {s}", .{ inst, pname, aname, pname, aname, what });
                },
                .frozen => try ctx.err(at, cannot ++ "freezes a value that holds a `{s}`, and {s}", .{ inst, pname, aname, pname, try sema.frozenReason(ctx, arg, (try sema.frozenBlocker(ctx, arg)).?) }),
                .no_task, .task => try reportTaskReq(ctx, req, at, inst, pname, arg),
                .meets => |api| try ctx.err(at, cannot ++ "{s}, and `{s}` is not `{s}`", .{ inst, pname, aname, req.op, aname, @tagName(api) }),
                .order => {
                    const lack: sema.Lack = (try sema.lacks(ctx, arg, .Ord)) orelse .{ .ty = arg };
                    try ctx.err(at, cannot ++ "orders a `{s}` with `order`, and `{s}` cannot be ordered{s}", .{ inst, pname, aname, pname, aname, try sema.lackDetail(ctx, ctx.arena.allocator(), arg, .Ord, lack) });
                },
                .equatable => try ctx.err(at, cannot ++ "applies `{s}` to `{s}`, which `{s}` does not support: {s}", .{ inst, pname, aname, req.op, pname, aname, try ApiCheck.notEquatableReason(ctx, (try sema.notEquatable(ctx, arg, null)).?) }),
                .hashable => try ctx.err(at, cannot ++ "hashes a `{s}` with `.hash()`, which `{s}` does not support: {s}", .{ inst, pname, aname, pname, aname, try ApiCheck.notEquatableReason(ctx, (try sema.notHashable(ctx, arg, null)).?) }),
                else => try ctx.err(at, cannot ++ "applies `{s}` to `{s}`, which `{s}` does not support", .{ inst, pname, aname, req.op, pname, aname }),
            }
            switch (req.req) {
                .copies, .no_cleanup, .clones => try ctx.noteIn(req.module_id, req.pos, "here", .{}),
                .array_len => try ctx.noteIn(req.module_id, req.pos, "`{s}` used as an array length here", .{pname}),
                .lane_count => try ctx.noteIn(req.module_id, req.pos, "`{s}` used as a lane count here", .{pname}),
                .slot_count => try ctx.noteIn(req.module_id, req.pos, "`{s}` used as a slot count here", .{pname}),
                .bytes, .fits, .float, .shift, .whole_division => try ctx.noteIn(req.module_id, req.pos, "`{s}` used here", .{req.op}),
                .not_error => try ctx.noteIn(req.module_id, req.pos, "`{s}!` returned here", .{pname}),
                .error_set => try ctx.noteIn(req.module_id, req.pos, "`!{s}` here", .{pname}),
                .not_function => try ctx.noteIn(req.module_id, req.pos, "`{s}{s}` here", .{ req.op[1..2], pname }),
                .named => try ctx.noteIn(req.module_id, req.pos, "`$name` here", .{}),
                .printable => try ctx.noteIn(req.module_id, req.pos, "written here", .{}),
                .frozen => try ctx.noteIn(req.module_id, req.pos, "frozen here", .{}),
                .no_task, .task => {},
                .meets => try ctx.noteIn(req.module_id, req.pos, "erased here", .{}),
                else => try ctx.noteIn(req.module_id, req.pos, "`{s}` used on `{s}` here ({s})", .{ req.op, pname, req.req.describe() }),
            }
            ok = false;
            break;
        }
    }
    return ok;
}

/// Whether `ty` is an `obj` or an `enum` a module declares, whose
/// methods a call on a type parameter reaches as Zig resolves it in each
/// instance; a built-in type's methods are lowered by emit at a call of
/// a known type, so none is reached through a type parameter.
pub fn declaredType(ctx: *const SemContext, ty: TypeId) bool {
    switch (ctx.types.get(ty)) {
        .nominal, .parameterized_nominal => {},
        else => return false,
    }
    const decl = sema.nominalDecl(ctx, ty) orelse return false;
    return decl.symbol().decl_pos != sema.builtin_decl_pos and !(decl.module_id == null and sema.isBuiltinGeneric(ctx, ctx.ref(decl.sym)));
}

/// The method calls generic bodies make on the parameters `own`
/// (`sema.GenericMethodCall`), checked at the instance `subst` made at
/// `at`: a call whose types this instance leaves open is checked where
/// they are bound. A type's instance leaves open what its methods' own
/// parameters bind; a method's instance checks only the calls on its own
/// parameters or whose types name one. False after a diagnostic.
pub fn checkMethodCalls(ctx: *SemContext, subst: TypeSubst, own: []const SymbolRef, at: u32, of: sema.InstanceRoot) Error!bool {
    const outer: TypeSubst = .{ .params = subst.params[0 .. subst.params.len - own.len], .args = subst.args[0 .. subst.args.len - own.len] };
    // The calls are recorded by the module that declares the parameters.
    for (subst.params, 0..) |p, n| {
        if (p.sym == sema.symbol_invalid) continue;
        const home = sema.homeOf(ctx, p);
        const seen = for (subst.params[0..n]) |q| {
            if (q.sym != sema.symbol_invalid and sema.homeOf(ctx, q) == home) break true;
        } else false;
        if (seen) continue;
        var i: usize = 0;
        while (i < home.generic_methods.items.len) : (i += 1) {
            var c = home.generic_methods.items[i];
            if (home != @as(*const SemContext, ctx) and c.module_id == 0) c.module_id = home.module_id;
            const param = home.ref(c.param);
            if (subst.lookup(param) == null) continue;
            if (std.mem.findScalar(SymbolRef, own, param) == null) {
                // On a type's parameter: checked with a method's instance only
                // where it names one of the method's own.
                if (of == .func and !try namesOwn(ctx, c, outer)) continue;
            }
            const arg = subst.lookup(param).?;
            if (sema.containsPoison(ctx, arg)) continue;
            // A call in code this instance does not compile (`sema.liveAt`).
            if (!try sema.liveAt(ctx, c.module_id, c.pos, subst.params, subst.args)) continue;
            if (!try checkMethodCall(ctx, home, c, subst, arg, at, of)) return false;
        }
    }
    return true;
}

/// Whether the types of call `c` name a parameter `outer` leaves open.
pub fn namesOwn(ctx: *SemContext, c: sema.GenericMethodCall, outer: TypeSubst) Error!bool {
    for (c.args) |t| if (sema.containsTypeVar(ctx, try sema.substituteType(ctx, t, outer))) return true;
    return switch (c.result) {
        .ty => |t| sema.containsTypeVar(ctx, try sema.substituteType(ctx, t, outer)),
        .nothing, .dropped => false,
    };
}

/// Call `c` at an instance whose type for its parameter is `arg`. True
/// when the instance meets it, or when the instance leaves a type of it
/// open.
pub fn checkMethodCall(ctx: *SemContext, home: *const SemContext, c: sema.GenericMethodCall, subst: TypeSubst, arg: TypeId, at: u32, of: sema.InstanceRoot) Error!bool {
    const a = ctx.arena.allocator();
    const args = try a.alloc(TypeId, c.args.len);
    for (c.args, args) |t, *out| out.* = try sema.substituteType(ctx, t, subst);
    const result: ?TypeId = switch (c.result) {
        .ty => |t| try sema.substituteType(ctx, t, subst),
        .nothing, .dropped => null,
    };
    if (sema.containsTypeVar(ctx, arg)) return true;
    for (args) |t| if (sema.containsTypeVar(ctx, t)) return true;
    if (result) |t| if (sema.containsTypeVar(ctx, t)) return true;
    for (args) |t| if (sema.containsPoison(ctx, t)) return true;
    if (result) |t| if (sema.containsPoison(ctx, t)) return true;

    const inst = try sema.rootName(ctx, of);
    const pname = home.symbols.items[c.param].name;
    const aname = try sema.formatType(ctx, arg);
    const cannot = "`{s}` cannot use `{s} = {s}`: the generic body ";
    const viewed = ctx.types.get(arg) == .read_view;
    const base = if (viewed) ctx.types.get(arg).read_view else arg;
    const bname = try sema.formatType(ctx, base);
    const verb: []const u8 = switch (c.self_mode) {
        .write => "writes",
        .value => "consumes",
        .read, .none => "reads",
    };
    if (try reportApiUnbound(ctx, c, base, at, of)) return false;
    // An API object's methods are reached through its table, which only
    // a call on a value whose type is written as the object makes.
    if (sema.mentionsObject(ctx, base)) {
        try ctx.err(at, cannot ++ "calls `{s}` on a `{s}`, and an API object's methods are called only where its type is written", .{ inst, pname, aname, c.method, pname });
        try ctx.noteIn(c.module_id, c.pos, "`{s}` called here", .{c.call});
        return false;
    }
    if (!declaredType(ctx, base)) {
        try ctx.err(at, cannot ++ "calls `{s}` on a `{s}`, and a call on a `{s}` reaches only the methods of an `obj` or an `enum` a module declares, not those of `{s}`", .{ inst, pname, aname, c.method, pname, pname, bname });
        try ctx.noteIn(c.module_id, c.pos, "`{s}` called here", .{c.call});
        return false;
    }
    if (viewed and c.self_mode != .read) {
        try ctx.err(at, cannot ++ "calls `{s}`, which {s} `{s}`, and `{s}` is a read view, through which nothing is written or consumed", .{ inst, pname, aname, c.call, verb, c.recv, aname });
        try ctx.noteIn(c.module_id, c.pos, "`{s}` called here", .{c.call});
        return false;
    }
    const m = (try sema.typeMethod(ctx, base, c.method)) orelse {
        try ctx.err(at, cannot ++ "calls `{s}` on a `{s}`, and `{s}` has no method `{s}`", .{ inst, pname, aname, c.method, pname, bname, c.method });
        try ctx.noteIn(c.module_id, c.pos, "`{s}` called here", .{c.call});
        return false;
    };
    const owner = try a.print("{s}.{s}", .{ bname, c.method });
    const why: ?[]const u8 = blk: {
        const declared = m.module orelse ctx.module_id;
        const body = if (c.module_id == 0) ctx.module_id else c.module_id;
        if (!m.field.is_pub and declared != body) {
            const mname = if (declared == ctx.module_id) ctx.name else if (ctx.foreign_semas.get(declared)) |f| f.name else "?";
            break :blk try a.print("and `{s}` is private to module `{s}`; declare it `pub` there", .{ owner, mname });
        }
        if (m.field.self_mode == .none) break :blk try a.print("and `{s}` takes no `self`", .{owner});
        // A method with options takes them by name, which a generic
        // body's call, by position only, never gives: refused as a
        // function value is (`optionsValue`).
        if (m.field.has_groups) break :blk try a.print("and `{s}` has options, given by name, which a call in a generic body cannot give; call it where its type is written, or pass a closure that does", .{owner});
        if (m.field.param_defaults) |d| for (d) |x| {
            if (x != null) break :blk try a.print("and `{s}` has options, given by name, which a call in a generic body cannot give; call it where its type is written, or pass a closure that does", .{owner});
        };
        if (m.field.self_mode != c.self_mode) break :blk try a.print("which {s} `{s}`, but `{s}` takes `self` as `{s}`", .{ verb, c.recv, owner, switch (m.field.self_mode) {
            .read => "?@",
            .write => "!@",
            .value => "<@",
            .none => "",
        } });
        if (m.field.inline_marked) break :blk try a.print("and `{s}` is marked `inline`, and a call on a `{s}` is not inlined", .{ owner, pname });
        // A view kept in a `T` the body holds by value is a loan the body
        // does not track, which a move of the value could carry out of
        // the function; through a write view, the function's own `keeps`
        // says what may be stored.
        if (c.owned_recv and m.field.origins.stores & m.field.origins.viewed != 0) break :blk try a.print("and `{s}` keeps a view of an argument in `{s}`, a `{s}` the body holds, whose views it does not track", .{ owner, c.recv, pname });
        // Its result may view `x` itself, a `T` the body holds, or an
        // argument: held as a value of a type parameter's type, which can
        // hold a view at this instance, the view is one no loan tracks.
        if (c.owned_recv and c.result == .ty and sema.containsTypeVar(ctx, c.result.ty) and m.field.origins.result & m.field.origins.viewed != 0 and sema.mayHoldView(ctx, result.?))
            break :blk try a.print("and `{s}` gives a view of `{s}` or an argument, which the body holds as a `{s}`, whose views it does not track", .{ owner, c.recv, try sema.formatType(ctx, c.result.ty) });
        if (m.field.owner_bounds.len > 0) break :blk try a.print("and `{s}` is declared under a bound on its type's parameters, which a call on a `{s}` with no bound does not state", .{ owner, pname });
        if (sema.isGenericFn(ctx, m.fn_ty)) break :blk try a.print("and `{s}` takes compile-time parameters of its own, which a call on a `{s}` does not give", .{ owner, pname });
        const params = m.fn_ty.params[1..];
        if (params.len != args.len) break :blk try a.print("with {d} argument{s}, and `{s}` takes {d}", .{ args.len, if (args.len == 1) "" else "s", owner, params.len });
        for (args, params, 1..) |got, want, n| if (got != want)
            break :blk try a.print("passing argument {d} as `{s}`, and `{s}` takes `{s}` there", .{ n, try sema.formatType(ctx, got), owner, try sema.formatType(ctx, want) });
        const gives = m.fn_ty.returns;
        switch (c.result) {
            .ty => if (result.? != gives) break :blk try a.print("taking its result as `{s}`, and `{s}` gives `{s}`", .{ try sema.formatType(ctx, result.?), owner, try sema.formatType(ctx, gives) }),
            .nothing => if (ctx.types.get(gives) != .void) break :blk try a.print("as a statement, and `{s}` gives `{s}`; discard it with `_ = {s}`", .{ owner, try sema.formatType(ctx, gives), c.call }),
            .dropped => if (ctx.types.get(gives) == .fallible) break :blk try a.print("under `_ =`, and `{s}` gives `{s}`, whose failure `_ =` would not handle", .{ owner, try sema.formatType(ctx, gives) }),
        }
        break :blk null;
    };
    const reason = why orelse return true;
    try ctx.err(at, cannot ++ "calls `{s}`, {s}", .{ inst, pname, aname, c.call, reason });
    try ctx.noteIn(c.module_id, c.pos, "`{s}` called here", .{c.call});
    return false;
}

/// A call `x.area()` on a `T` with no bound, where the instance's type
/// has no method `area` of its own but provides an API the module sees
/// that declares it (a default, or an addition's method): only a bound
/// reaches it, so the error says to write one. False when that is not so.
pub fn reportApiUnbound(ctx: *SemContext, c: sema.GenericMethodCall, base: TypeId, at: u32, of: sema.InstanceRoot) Error!bool {
    if (try sema.typeMethod(ctx, base, c.method) != null) return false;
    const a = ctx.arena.allocator();
    var refs: std.ArrayList(sema.ApiRef) = .empty;
    for (ctx.symbols.items, 0..) |sym, i| {
        if (sym.kind == .api) try refs.append(a, .{ .module_id = ctx.module_id, .sym = @intCast(i) });
    }
    for (ctx.imports) |imp| for (imp.sema.symbols.items, 0..) |sym, i| {
        if (sym.kind == .api and sym.flags.is_public) try refs.append(a, .{ .module_id = imp.module_id, .sym = @intCast(i) });
    };
    const api: sema.ApiRef = for (refs.items) |r| {
        const sym = sema.apiSymbol(ctx, r) orelse continue;
        const declares = for (sym.fields orelse &.{}) |f| {
            if (f.is_method and std.mem.eql(u8, f.name, c.method)) break true;
        } else false;
        if (declares and try sema.provides(ctx, base, r) != null) break r;
    } else return false;
    const pname = ctx.symbols.items[c.param].name;
    const generic: []const u8 = switch (of) {
        .func => |f| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.print(a, "{s}[", .{f.name});
            for (f.ownParams(), 0..) |p, i| try out.print(a, "{s}{s}", .{ if (i > 0) ", " else "", sema.symbolAt(ctx, p).name });
            try out.append(a, ']');
            break :blk out.items;
        },
        .type => |t| try sema.formatType(ctx, if (ctx.types.get(t) == .parameterized_nominal) (try sema.makeNominalContext(ctx, ctx.localSym(ctx.types.get(t).parameterized_nominal.sym))).self_type else t),
    };
    try ctx.err(at, "`{s}` has no method `{s}`: `{s}` gives `{s}` no bound; write `[{s}: {s}]`, which declares `{s}`", .{ pname, c.method, generic, pname, pname, try sema.apiName(ctx, api), c.method });
    try ctx.noteIn(c.module_id, c.pos, "`{s}` called here", .{c.call});
    return true;
}

/// The value a box, a counted handle, or a frozen value's handle of type
/// `ty` reaches, through each in turn; `ty` itself for any other type.
pub fn reachedValue(ctx: *const SemContext, ty: TypeId) TypeId {
    var a = ty;
    while (true) {
        if (sema.boxedType(ctx, a)) |inner| {
            a = inner;
        } else switch (ctx.types.get(a)) {
            .shared => |inner| a = sema.frozenValue(ctx, inner) orelse inner,
            else => return a,
        }
    }
}

/// Whether the bounds of `sym` give what `req` needs, `api`: the API
/// itself, or for the comparison operators `Num`, since every number
/// orders by `<`, a float as IEEE 754 says (a NaN beside anything false).
pub fn boundsGive(ctx: *SemContext, sym: sema.Symbol, req: Requirement, api: sema.Api) bool {
    const apis = sema.boundApis(ctx, sym);
    return apis.contains(api) or (req == .ordered and apis.contains(.Num));
}

/// Whether `api` says how a value is copied, kept, or crosses to
/// another task: a fact of a type's parts that every method of a generic
/// type shares, never one a method's own bounds add.
pub fn ownershipApi(api: sema.Api) bool {
    return switch (api) {
        .Copy, .Clone, .Owned, .Sends, .Syncs => true,
        else => false,
    };
}

/// The API that gives a body requirement `req` on a type parameter
/// (docs/design/apis.md, "What a bound changes in a body"), or null for
/// one each instance still decides with any bounds: a literal's fit, a
/// shift's width, a size, a name.
pub fn apiOf(req: Requirement) ?sema.Api {
    return switch (req) {
        .numeric, .bytes => .Num,
        .integer, .whole_division => .Integer,
        .records => null,
        .signed => .Signed,
        .ordered, .order => .Ord,
        .equatable => .Eq,
        .hashable => .Hash,
        .copies, .no_cleanup => .Copy,
        .clones => .Clone,
        .printable => .Print,
        .meets => |api| api,
        .float, .fits, .shift, .array_len, .lane_count, .slot_count, .sized, .not_error, .error_set, .not_function, .named, .frozen, .no_task, .task => null,
    };
}

/// A type parameter checked by its bounds (`sema.checkedByBounds`) that a
/// generic function's body gives, through the generic functions it calls
/// at it (`SemContext.param_calls`), to a task that may run on another
/// core must state `Sends`, or `Syncs` given as a read view, and one it
/// gives to a body that prints it must state `Print`, as a body doing so
/// itself must: each instance is not checked for it, and an error at a
/// callee's instance would name what the public generic does not show. What
/// a callee's parameter needs, the caller's parameters its argument holds
/// need, where the callee's own walk looks: `sema.taskParams` for a task,
/// `sema.printedTypeVars` for printing. A generic type's printing passes
/// the same way to the parameters of each instance a body names
/// (`SemContext.generic_uses`), as every instance is checked for it.
pub fn checkStatedForwards(ctx: *SemContext) Error!void {
    const a = ctx.arena.allocator();
    const Need = union(enum) { task: sema.TaskReach, print };
    const Gone = struct { param: SymbolId, need: Need, pos: u32 };
    var gone: std.ArrayList(Gone) = .empty;
    for (ctx.generic_requirements.items) |r| {
        if (r.body != sema.no_body) continue;
        switch (r.req) {
            .task => |reach| try gone.append(a, .{ .param = r.param, .need = .{ .task = reach }, .pos = r.pos }),
            // A parameter checked by its bounds answers for its own
            // printing (`checkBoundedBodies`), and its callers through
            // them at each call.
            .printable => if (!sema.checkedByBounds(ctx.symbols.items[r.param])) try gone.append(a, .{ .param = r.param, .need = .print, .pos = r.pos }),
            else => {},
        }
    }
    if (gone.items.len == 0) return;
    // What each callee's parameter needs, its caller's parameters need
    // through the arguments, until nothing new.
    var tasks: std.ArrayList(sema.TaskParam) = .empty;
    defer tasks.deinit(ctx.allocator);
    var printed: std.ArrayList(SymbolId) = .empty;
    defer printed.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < gone.items.len) : (i += 1) {
        const g = gone.items[i];
        for (ctx.param_calls.items) |c| for (c.params, c.args) |p, arg| {
            if (p != ctx.ref(g.param)) continue;
            switch (g.need) {
                // A task in a method of a generic type is checked where
                // the program reaches the method (`sema.BodyReach`).
                .task => |reach| if (c.body == sema.no_body) {
                    tasks.clearRetainingCapacity();
                    try sema.taskParams(ctx, arg, reach, &tasks);
                    for (tasks.items) |f| try addNeed(Gone, a, &gone, .{ .param = f.param, .need = .{ .task = f.reach }, .pos = c.pos });
                },
                .print => try printedNeeds(Gone, ctx, a, &gone, arg, c.pos, &printed),
            }
        };
        // A type's printing is its every instance's (`checkGenericInstantiations`):
        // the parameters of what a body names it at, `Box(v: x)` in `f[T]`.
        if (g.need == .print) for (ctx.generic_uses.items, ctx.generic_uses_at.items) |use, at| {
            const pn = switch (ctx.types.get(use)) {
                .parameterized_nominal => |pn| pn,
                else => continue,
            };
            // Another module's generic's parameters are never this one's.
            if (!ctx.owns(pn.sym)) continue;
            const params = sema.symbolAt(ctx, pn.sym).type_params orelse continue;
            for (params, pn.args) |p, arg| if (p == g.param) try printedNeeds(Gone, ctx, a, &gone, arg, at, &printed);
        };
    }
    var reported: std.AutoHashMapUnmanaged(struct { SymbolId, sema.Api }, void) = .empty;
    defer reported.deinit(ctx.allocator);
    for (gone.items) |g| {
        const sym = ctx.symbols.items[g.param];
        if (!sema.checkedByBounds(sym)) continue;
        const api: sema.Api, const what: []const u8 = switch (g.need) {
            .task => |reach| if (reach.local) continue else if (reach.how == .moves)
                .{ .Sends, "a value given to a task that may run on another core" }
            else
                .{ .Syncs, "a value passed as a view to a task that may run on another core" },
            .print => .{ .Print, "printing" },
        };
        if (sema.boundApis(ctx, sym).contains(api)) continue;
        if ((try reported.getOrPut(ctx.allocator, .{ g.param, api })).found_existing) continue;
        try reportUnbounded(ctx, g.pos, g.param, api, what);
    }
}

/// Adds to `gone` (`checkStatedForwards`) the need to print each type
/// parameter a printed `arg` holds, given at `pos`.
pub fn printedNeeds(comptime Gone: type, ctx: *SemContext, a: std.mem.Allocator, gone: *std.ArrayList(Gone), arg: TypeId, pos: u32, printed: *std.ArrayList(SymbolId)) Error!void {
    printed.clearRetainingCapacity();
    try sema.printedTypeVars(ctx, arg, printed, ctx.allocator);
    for (printed.items) |param| try addNeed(Gone, a, gone, .{ .param = param, .need = .print, .pos = pos });
}

/// Adds `need` to `gone` (`checkStatedForwards`) unless it is there.
pub fn addNeed(comptime Gone: type, a: std.mem.Allocator, gone: *std.ArrayList(Gone), need: Gone) Error!void {
    for (gone.items) |o| if (o.param == need.param and std.meta.eql(o.need, need.need)) return;
    try gone.append(a, need);
}

/// A type parameter with bounds is checked against its bounds alone: what
/// this module's bodies do with one must be what its bounds name. A
/// parameter with no bound keeps per-instance checking.
pub fn checkBoundedBodies(ctx: *SemContext) Error!void {
    const a = ctx.arena.allocator();
    for (ctx.generic_requirements.items) |r| {
        if (r.module_id != 0) continue;
        const sym = ctx.symbols.items[r.param];
        if (!sema.checkedByBounds(sym)) continue;
        const api = apiOf(r.req) orelse continue;
        if (boundsGive(ctx, sym, r.req, api)) continue;
        // Where `$plain(T)` has held, a `T` copies and holds no loan.
        if (sema.plainApis().contains(api) and sema.narrowedAt(ctx, 0, r.pos, r.param)) continue;
        if (try sema.reportStated(ctx, r.pos, r.param, api, r.op)) continue;
        try reportUnbounded(ctx, r.pos, r.param, api, try a.print("{s}", .{r.req.describe()}));
    }
}

/// A body at `pos` does with a `T` (`param`, which has bounds or is one
/// of a `pub` declaration's) what `api` gives (`what`), and its bounds do
/// not name it.
pub fn reportUnbounded(ctx: *SemContext, pos: u32, param: SymbolId, api: sema.Api, what: []const u8) Error!void {
    if (try sema.reportStated(ctx, pos, param, api, "")) return;
    const a = ctx.arena.allocator();
    const sym = ctx.symbols.items[param];
    try ctx.err(pos, "{s}", .{try sema.unboundedMessage(ctx, a, sym, api, what)});
}

/// The APIs this module's types name on their headers. A type that
/// declares the method of an API it names (`sema.apiMethodName`) gives
/// that API its own meaning, by that method, whose signature the API
/// fixes (`checkApiMethod`). A type that names `Ord` with no `order` of its
/// own is ordered by its fields in declared order, and an enum by its
/// variant, then its payload's fields: each must provide `Ord`. A field of
/// a type parameter's type is decided by each instance (`sema.lacks`).
pub fn checkHeaders(ctx: *SemContext) Error!void {
    for (ctx.symbols.items) |sym| {
        if (sym.kind != .nominal_type and sym.kind != .generic_type) continue;
        if (sema.isAlias(sym) or sym.decl_pos == sema.builtin_decl_pos) continue;
        try checkLookAlikes(ctx, sym);
        if (sym.apis.count() == 0) continue;
        var it = sym.apis.iterator();
        while (it.next()) |api| if (sema.ownApiMethod(sym, api)) |m| try checkApiMethod(ctx, sym, api, m);
        if (!sym.apis.contains(.Ord) or sema.ownApiMethod(sym, .Ord) != null) continue;
        for (sym.fields orelse &.{}) |f| {
            if (f.is_method) continue;
            const parts: []const Field = if (f.is_variant) f.payload orelse &.{} else &.{f};
            for (parts) |part| {
                const lack = (try sema.lacks(ctx, part.ty, .Ord)) orelse continue;
                const shown = if (f.is_variant) try ctx.arena.allocator().print("{s}.{s}", .{ f.name, part.name }) else part.name;
                try ctx.err(sym.decl_pos, "`{s}` names `Ord`, so it is ordered by its fields, but its field `{s}` is a `{s}`, which {s}{s}", .{ sym.name, shown, try sema.formatType(ctx, part.ty), sema.cannotDo(.Ord), try sema.lackDetail(ctx, ctx.arena.allocator(), part.ty, .Ord, lack) });
                break;
            }
        }
    }
}

/// Where field `f`, declared `pub ?name`, may be written, as an error
/// says it: in its module, or, for a built-in type written in Rig, in the
/// type's own methods. `declares` adds what declares it so.
pub fn readOnlyWhere(ctx: *SemContext, f: sema.ReadOnlyField, declares: bool) Error![]const u8 {
    const a = ctx.arena.allocator();
    if (std.mem.eql(u8, f.module, "std." ++ rig.builtin_module_name)) return a.print("outside the methods of `{s}`", .{f.owner});
    if (declares) return a.print("outside module `{s}`, which declares it `pub ?{s}`", .{ f.module, f.field });
    return a.print("outside module `{s}`", .{f.module});
}

/// The signature `api` fixes for the method by which a type gives it its
/// own meaning, as an error shows it.
pub fn fixedSignature(api: sema.Api) []const u8 {
    return switch (api) {
        .Eq => "fun eq(?@, other: ?Self) -> Bool",
        .Hash => "sub hash_into(?@, h: !Hasher)",
        .Ord => "fun order(?@, other: ?Self) -> Order",
        .Print => "sub print(?@, out: !Printer)",
        else => "",
    };
}

/// Whether `ty` is a write view of the built-in `Hasher`.
pub fn isHasherView(ctx: *SemContext, ty: TypeId) Error!bool {
    return ty == try ctx.intern(.{ .write_view = try ctx.intern(.{ .nominal = ctx.builtins.hasher }) });
}

/// The method `m` of `sym`, by which it gives `api` its own meaning, has
/// the signature `api` fixes: another signature is an error, not a quiet
/// opt-out (docs/design/apis.md, Stage 2).
pub fn checkApiMethod(ctx: *SemContext, sym: sema.Symbol, api: sema.Api, m: Field) Error!void {
    const why = (try apiMethodMismatch(ctx, api, m)) orelse return;
    if (why.len == 0) return;
    const owner = try ctx.arena.allocator().print("{s}.{s}", .{ sym.name, m.name });
    try ctx.err(m.decl_pos, "`{s}` {s}, but `{s}` fixes `{s}`", .{ owner, why, @tagName(api), fixedSignature(api) });
}

/// A method of `sym` with the very signature a built-in API fixes,
/// `fun eq(?@, other: ?Self) -> Bool` and the others, on a type whose
/// header does not name that API: `==`, hashing, ordering, or printing
/// would quietly pass it by. A method under the name with another
/// signature is an ordinary method.
pub fn checkLookAlikes(ctx: *SemContext, sym: sema.Symbol) Error!void {
    if (sym.flags.error_set) return;
    for ([_]sema.Api{ .Eq, .Hash, .Ord, .Print }) |api| {
        if (sym.apis.contains(api)) continue;
        const name = sema.apiMethodName(api).?;
        for (sym.fields orelse &.{}) |m| {
            if (!m.is_method or m.is_drop_method or !std.mem.eql(u8, m.name, name)) continue;
            if ((try apiMethodMismatch(ctx, api, m)) != null) continue;
            const a = ctx.arena.allocator();
            const is_enum = for (sym.fields orelse &.{}) |f| {
                if (f.is_variant) break true;
            } else false;
            const params: []const u8 = if (sym.kind == .generic_type) try a.print("[{s}]", .{ApiCheck.tparamNames(ctx, sym)}) else "";
            const uses: []const u8 = switch (api) {
                .Eq => "`==`",
                .Hash => "hashing",
                .Ord => "`<`",
                .Print => "`print`",
                else => unreachable,
            };
            try ctx.err(m.decl_pos, "`{s}.{s}` has the signature `{s}` fixes, but `{s}` does not name `{s}`, so {s} does not use it: name it on the header, `{s} {s}{s}: {s}`, or rename the method", .{ sym.name, m.name, @tagName(api), sym.name, @tagName(api), uses, if (is_enum) "enum" else "obj", sym.name, params, try sema.formatBounds(ctx, a, sym, api) });
        }
    }
}

/// How method `m` differs from the signature `api` fixes for it, as an
/// error says it; empty for no function, null for the very signature.
pub fn apiMethodMismatch(ctx: *SemContext, api: sema.Api, m: Field) Error!?[]const u8 {
    const a = ctx.arena.allocator();
    const f = switch (ctx.types.get(m.ty)) {
        .function => |f| f,
        else => return "",
    };
    if (f.params.len == 0) return "";
    const self_view = f.params[0];
    const names = m.param_names orelse &.{};
    const what: ?[]const u8 = blk: {
        if (m.self_mode != .read) break :blk try a.print("takes `self` as `{s}`", .{switch (m.self_mode) {
            .write => "!@",
            .value => "<@",
            .none => "nothing",
            .read => "?@",
        }});
        if (f.ct_params.len > 0) break :blk "takes compile-time parameters";
        if (m.owner_bounds.len > 0) break :blk "is declared under a bound on its type's parameters, which the header does not state";
        if (f.params.len != 2) break :blk try a.print("takes {d} parameter{s}", .{ f.params.len - 1, if (f.params.len == 2) "" else "s" });
        const p = f.params[1];
        const ok = switch (api) {
            .Eq, .Ord => p == self_view,
            .Hash => try isHasherView(ctx, p),
            .Print => p == try ctx.intern(.{ .write_view = try ctx.intern(.{ .nominal = ctx.builtins.printer }) }),
            else => true,
        };
        if (!ok) break :blk try a.print("takes `{s}` as `{s}`", .{ if (names.len > 1) names[1] else "?", try sema.formatType(ctx, p) });
        const want: TypeId = switch (api) {
            .Eq => ctx.types.bool_id,
            .Ord => try ctx.intern(.{ .nominal = ctx.builtins.order }),
            else => ctx.types.void_id,
        };
        if (f.returns != want) break :blk if (f.returns == ctx.types.void_id) "gives nothing" else try a.print("gives `{s}`", .{try sema.formatType(ctx, f.returns)});
        break :blk null;
    };
    return what;
}
