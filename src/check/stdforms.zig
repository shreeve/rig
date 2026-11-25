//! Typecheck's standard-library forms, typed by hand where the compiler
//! knows std by name: tasks, `par`, `select`, actors, chains, durations,
//! `String`, bit and SIMD calls. Moving one into std's own declarations
//! empties this file.

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const sema = @import("../sema.zig");
const storage = @import("../storage.zig");
const Wide = sema.Wide;
const resolve = @import("../resolve.zig");
const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const TypeId = sema.TypeId;
const Type = sema.Type;
const Field = sema.Field;
const FunctionType = sema.FunctionType;
const SelfMode = sema.SelfMode;
const TypeSubst = sema.TypeSubst;
const Requirement = sema.Requirement;
const Error = std.mem.Allocator.Error;
const identAt = sema.identAt;
const tc = @import("../typecheck.zig");
const Checker = tc.Checker;
const ApiCheck = @import("apis.zig");
const CompatCheck = @import("compat.zig");
const GenericCheck = @import("generics.zig");
const BuiltinCheck = @import("builtins.zig");
const CallCheck = @import("calls.zig");
const ClosureCheck = @import("closures.zig");
const ExprCheck = @import("expr.zig");
const FlowCheck = @import("flow.zig");
const PatternCheck = @import("patterns.zig");
const StmtCheck = @import("stmt.zig");
const ViewCheck = @import("views.zig");

/// Whether `part`, of type `part_ty`, an argument of the task `call`
/// or its method's self (taken as `as_self` says), may go to the task
/// as it is passed: given (moved or copied) when its type moves, a read
/// view when it shares, and a write view when what it views moves
/// (`sema.Crossing`), so the task may run on another core. A part that
/// stays on one thread (`sema.localBlocker`) makes the task local:
/// it and the task making it run on this thread from then on. Reports
/// the part that cannot go even to a local task; adds each part that
/// goes to `gone`.
pub fn crossCheck(self: *Checker, call: Sexp, part: Sexp, part_ty_in: TypeId, as_self: ?sema.SelfMode, gone: *std.ArrayList(Checker.Gone), parts: []const Sexp) Error!bool {
    const viewed_closure = part.isKind(.lambda);
    const part_ty = try crossingTypeOf(self, part, part_ty_in);
    const k = self.ctx.types.get(part_ty);
    // A closure binding is typed as a function value but holds its
    // captures; only its callable view `?g` reaches a call.
    if (ViewCheck.fnArg(self, part, part_ty_in) == .binding) {
        try self.errAt(part, "closure `{s}` stays in its binding, so it goes to no task; a task takes a named function by value", .{CallCheck.sourceText(self, part)});
        return false;
    }
    const Mode = enum { given, read, write };
    const mode: Mode = if (as_self) |r| switch (r) {
        .read => .read,
        .write => .write,
        .value, .none => if (k == .read_view) .read else if (k == .write_view) .write else .given,
    } else if (k == .read_view) .read else if (k == .write_view) .write else .given;
    const how: sema.Crossing = if (mode == .read) .shares else .moves;
    const inner = if (k == .read_view or k == .write_view) sema.unwrapViews(self.ctx, part_ty) else part_ty;
    const passed = switch (mode) {
        .given => "is given to a task",
        .read => "is passed to a task as a read view",
        .write => "is passed to a task as a write view",
    };
    const pin = (try sema.crossingBlocker(self.ctx, inner, how)) orelse {
        try gone.append(self.ctx.arena.allocator(), .{ .ty = inner, .how = how, .pos = self.startOf(part), .passed = passed });
        return true;
    };
    const blocker = (try sema.localBlocker(self.ctx, inner, how)) orelse {
        try gone.append(self.ctx.arena.allocator(), .{ .ty = inner, .how = how, .pos = self.startOf(part), .passed = passed });
        const why = try std.fmt.allocPrint(self.ctx.arena.allocator(), "`{s}`: `{s}` {s}", .{ CallCheck.sourceText(self, part), try self.tyName(part_ty), try blockerReason(self, pin, mode == .read, if (pin == part_ty) "is" else if (pin == inner) "views" else null) });
        try self.ctx.recordLocalTask(call, .{ .pos = self.startOf(call), .call = CallCheck.sourceText(self, call), .why = why });
        return true;
    };
    const what = if (viewed_closure) "this closure" else try std.fmt.allocPrint(self.ctx.arena.allocator(), "`{s}`", .{CallCheck.sourceText(self, part)});
    // An API object without the bound the task needs, which even a
    // task another part pins to this thread does not take.
    if (try objectLack(self, part_ty, how)) |lack| {
        const pinned = for (parts) |other| {
            if (CompatCheck.sameNode(other, part)) continue;
            const oty = try crossingTypeOf(self, other, self.ctx.typeOf(other) orelse continue);
            if (self.isPoison(oty)) continue;
            const ok = self.ctx.types.get(oty);
            const ohow: sema.Crossing = if (ok == .read_view) .shares else .moves;
            const oinner = if (ok == .read_view or ok == .write_view) sema.unwrapViews(self.ctx, oty) else oty;
            if ((try sema.crossingBlocker(self.ctx, oinner, ohow)) != null and (try sema.localBlocker(self.ctx, oinner, ohow)) == null) break true;
        } else false;
        try self.errAt(part, "{s} {s}, and {s}{s}", .{ what, passed, lack, if (pinned) " (a local task too: what it hides may go to no task)" else "" });
        return false;
    }
    try self.errAt(part, "{s} {s}: `{s}` {s}", .{ what, passed, try self.tyName(part_ty), try blockerReason(self, blocker, mode == .read, if (blocker == part_ty) "is" else if (blocker == inner) "views" else null) });
    return false;
}

/// The API object a value of `ty` holds directly, `^{A}`, a view of
/// one, `?{A}`, or a view of a box, `?^{A}`, or an optional of these,
/// going to a task as `how` says, when its braces and API do not name
/// the crossing bound its form's row needs (`sema.blockerIn`): why,
/// with the fix. Null for any other type, and for a write view passed
/// to be read by several, which no bound allows.
pub fn objectLack(self: *Checker, ty: TypeId, how_in: sema.Crossing) Error!?[]const u8 {
    const types = &self.ctx.types;
    var held_ty = ty;
    var how = how_in;
    if (types.get(held_ty) == .optional) held_ty = types.get(held_ty).optional;
    if (sema.objectHeld(self.ctx, held_ty) == null) switch (types.get(held_ty)) {
        .read_view => |inner| {
            held_ty = inner;
            how = .shares;
        },
        .write_view => |inner| held_ty = inner,
        else => return null,
    };
    if (types.get(held_ty) == .optional) held_ty = types.get(held_ty).optional;
    const held = sema.objectHeld(self.ctx, held_ty) orelse return null;
    const a = self.ctx.arena.allocator();
    switch (held.form) {
        .read => how = .shares,
        .write => if (how == .shares) return null,
        .box => {},
        // A counted handle crosses by its count, which only a frozen
        // value's is atomically; a weak handle never.
        .shared => {
            if (sema.frozenObject(self.ctx, self.ctx.types.get(held_ty).shared)) return null;
            return try a.print("`{s}` stays with its task, as a `*T` does: its braces name no `Syncs`", .{try self.tyName(held_ty)});
        },
        .weak => return try a.print("`{s}`, a weak handle, goes to no task", .{try self.tyName(held_ty)}),
    }
    const need = sema.crossingBound(how);
    if (sema.objectBounds(self.ctx, held.object).contains(need)) return null;
    var fixed = held.object;
    fixed.builtins.insert(need);
    const sigil: []const u8 = switch (held.form) {
        .read => "?",
        .write => "!",
        .box => "^",
        .shared, .weak => unreachable,
    };
    return try a.print("`{s}` hides its value's type without naming `{s}`: write `{s}{s}`", .{ try self.tyName(held_ty), @tagName(need), sigil, try sema.objectSpelling(self.ctx, a, fixed) });
}

/// A value of `ty` goes to a task as `how` says, at `pos`, where it
/// `passed` (`is given to a task`): to a `local` one, or to one that
/// may run on another core. Each instance's type for a type parameter
/// it holds must go so too (`sema.taskParams`): one Zig function
/// serves every instance of a generic body, so a task the body makes
/// to cross takes in no instance what stays on one thread.
pub fn requireTask(self: *Checker, ty: TypeId, how: sema.Crossing, pos: u32, passed: []const u8, local: bool) Error!void {
    if (!self.ctx.typeInfo(ty).has_type_var) return;
    var found: std.ArrayList(sema.TaskParam) = .empty;
    defer found.deinit(self.ctx.allocator);
    try sema.taskParams(self.ctx, ty, .{ .how = how, .local = local }, &found);
    for (found.items) |p| try ExprCheck.require(self, p.param, .{ .task = p.reach }, pos, passed);
}

/// The one check that a value of `ty`, hidden at `at` from the rules
/// that wait for a task, holds none (Core §4): erased to the API
/// object `where`; given out of `where`, `task.isolate` or
/// `task.supervise`, which ends every task started in it; or captured
/// by an owned closure, whose type does not show its captures. Its
/// known type holds no task (`sema.holdsTask`), and each instance's
/// type for a type parameter it holds none (`Requirement.no_task`).
/// False when its known type holds one, reported at `at`.
pub fn hidesNoTask(self: *Checker, at: Sexp, ty: TypeId, how: Checker.Hidden, where: []const u8) Error!bool {
    if (sema.holdsTask(self.ctx, ty)) {
        const shown = try self.tyName(ty);
        switch (how) {
            .erased => try self.errAt(at, "`{s}` is erased to `{s}`, which would hide a task from the rules that wait for one, and {s}: wait for the task before erasing", .{ shown, where, try ApiCheck.taskWhy(self.ctx, ty) }),
            .isolated => try self.errAt(at, "a task started in `{s}` ends in it, and `{s}` gives a `{s}`, which holds one: wait for it inside", .{ where, CallCheck.sourceText(self, at), shown }),
            .captured => try self.errAt(at, "an owned closure holds no task: `{s}` is a `{s}`{s}, which only the scope that waits for it may hold; wait for it first and capture its value", .{ CallCheck.sourceText(self, at), shown, if (sema.isTask(self.ctx, ty) or sema.isTaskSet(self.ctx, ty)) "" else " holding one" }),
        }
        return false;
    }
    if (!self.ctx.typeInfo(ty).has_type_var) return true;
    var held: std.ArrayList(SymbolId) = .empty;
    defer held.deinit(self.ctx.allocator);
    try sema.reachedTypeVars(self.ctx, ty, &held, self.ctx.allocator);
    const a = self.ctx.arena.allocator();
    for (held.items) |param| {
        const pname = self.ctx.symbols.items[param].name;
        const op = switch (how) {
            .erased => try a.print("the generic body erases a value that holds a `{s}` to `{s}`, which would hide a task from the rules that wait for one", .{ pname, where }),
            .isolated => try a.print("a task started in `{s}` ends in it, so the generic body gives out of it no value that holds a `{s}`", .{ where, pname }),
            .captured => try a.print("the generic body captures a value that holds a `{s}` in an owned closure, which would hide a task from the rules that wait for one", .{pname}),
        };
        try ExprCheck.require(self, param, .no_task, self.startOf(at), op);
    }
    return true;
}

/// The type `part`, an argument of `ty` going to another task (a
/// task's call or an actor's), crosses as: a value erased there as
/// the API object it becomes; a closure literal written there is passed
/// as a callable view, as `?f` of a closure is, since it views what it
/// captures; a bare value viewed where a view goes, as that view. The
/// one classifier for both
/// (`crossCheck`, `actorCall`).
pub fn crossingTypeOf(self: *Checker, part: Sexp, ty: TypeId) Error!TypeId {
    // A value erased where it is passed crosses as the API object it
    // becomes, by that object's braces, never by its known type (Core
    // §4: an object without the bound a task needs goes to no task).
    if (self.ctx.erasureOf(part)) |er| return er.view;
    // A bare value viewed where a view goes crosses as the view, shared
    // (Core sentence 1; SPEC §18: a `?T` crosses when `T` syncs).
    if (self.ctx.viewOf(part)) |view| if (view.implicit) return view.ty;
    if (ViewCheck.fnArg(self, part, ty) != .literal) return ty;
    const fn_ty = sema.unwrapViews(self.ctx, ty);
    return switch (self.ctx.types.get(fn_ty)) {
        .callable => try self.ctx.intern(.{ .read_view = fn_ty }),
        else => try sema.callableOfFn(self.ctx, fn_ty),
    };
}

/// A crossing at `at` that a `pub` declaration's type parameter
/// `blocker` does not state, reported at the parameter
/// (`sema.reportStated`): false for any other blocker.
pub fn statedCrossing(self: *Checker, blocker: TypeId, how: sema.Crossing, at: u32) Error!bool {
    const p = switch (self.ctx.types.get(blocker)) {
        .type_var => |p| p,
        else => return false,
    };
    return sema.reportStated(self.ctx, at, self.ctx.localSym(p), if (how == .moves) .Sends else .Syncs, "");
}

/// `crossingReason`.
pub fn blockerReason(self: *Checker, blocker: TypeId, shared: bool, verb: ?[]const u8) Error![]const u8 {
    return GenericCheck.crossingReason(self.ctx, blocker, shared, verb);
}

/// How a callee is spelled, for messages: `f`, `a.f`, or `.m`.
pub fn calleeName(self: *Checker, callee: Sexp) Error![]const u8 {
    if (callee == .src) return self.text(callee);
    if (callee.isKind(.member)) {
        const obj = ir.Member.object(callee);
        const name = self.text(ir.Member.name(callee));
        if (obj == .src) return sema.memberText(self.ctx.arena.allocator(), self.text(obj), name);
        return name;
    }
    // Any other callee (`id[Int]`): as written.
    return CallCheck.sourceText(self, callee);
}

pub fn synthCallInner(self: *Checker, node: Sexp) Error!TypeId {
    var callee = ir.Call.callee(node);
    const args = ir.Call.args(node);

    // `f[...](args)`, `Wrap[Int](args)`: compile-time arguments.
    var ct: ?Sexp = null;
    if (rig.isBracketList(callee)) if (try CallCheck.instTarget(self, ir.get(callee, .object))) |target| switch (target) {
        .generic => |nt| return if (self.ctx.ref(nt.id) == self.ctx.builtins.simd)
            simdConvert(self, try CallCheck.typeInstance(self, callee, nt), args, self.startOf(callee))
        else if (self.ctx.ref(nt.id) == self.ctx.builtins.slot)
            slotMade(self, callee, try CallCheck.typeInstance(self, callee, nt), args)
        else
            CallCheck.constructInstance(self, node, callee, nt, args),
        .function => {
            ct = callee;
            callee = ir.get(callee, .object);
        },
        .value_member => return CallCheck.synthMemberCall(self, ir.get(callee, .object), args, callee),
        .not_generic, .reported => {
            try CallCheck.notGeneric(self, callee, target);
            return CallCheck.skipCall(self, args);
        },
    };
    if (callee.isKind(.ct_call)) {
        try self.errAt(node, "`{s}` is a compile-time function: its value is `{s}`, with no parentheses", .{ CallCheck.sourceText(self, sema.cteval.calleeOf(callee)), CallCheck.sourceText(self, callee) });
        return CallCheck.skipCall(self, args);
    }

    if (callee == .src) {
        const name = self.text(callee);
        if (CallCheck.lookupQuiet(self, callee) == null) {
            if (std.mem.eql(u8, name, "print")) return checkPrint(self, args);
            if (std.mem.eql(u8, name, "warn")) return checkWarn(self, args);
            if (std.mem.eql(u8, name, "String")) return checkStringNew(self, node, args);
            if (std.mem.eql(u8, name, "swap")) return CallCheck.checkSwap(self, node, callee, args);
            if (resolve.isNumericTypeName(name)) {
                var r = self.resolver();
                return CallCheck.checkConversion(self, try r.resolveType(callee), name, args, callee.src.pos);
            }
        }
        const sym_id = (try ExprCheck.useName(self, callee)) orelse return CallCheck.skipCall(self, args);
        const sym = self.ctx.symbols.items[sym_id];
        if (sym.kind != .nominal_type and sym.kind != .generic_type and sym.kind != .type_alias and sym.kind != .module) {
            try self.ctx.recordType(callee, sym.ty);
        }
        switch (sym.kind) {
            .function, .@"extern" => {
                // `cap(8)`: a compile-time function takes its
                // arguments in brackets.
                if (ct == null and sema.cteval.isCtFunction(self.ctx, sym_id)) return CallCheck.badCall(self, args, callee, "`{s}` runs at compile time: call it with brackets, `{s}[...]`", .{ name, name });
                return functionCall(self, callee, sym, ct, args);
            },
            .nominal_type => return CallCheck.construct(self, sym_id, args, callee.src.pos, TypeSubst.empty, null),
            .type_alias => return aliasCall(self, node, callee, name, sym.ty, args, callee.src.pos),
            .generic_type => {
                if (self.ctx.ref(sym_id) == self.ctx.builtins.list) {
                    // `List(a)` takes its element type from `a`'s.
                    if (args.len == 1 and !args[0].isKind(.kwarg)) return BuiltinCheck.listFromElems(self, args[0], null);
                    return CallCheck.badCall(self, args, callee, "`List()` needs its element type: name it (`List[T]()`), give it where the value goes (`v: List[T] = List()`), or make the List from an array, `List([1, 2, 3])`", .{});
                }
                if (self.ctx.ref(sym_id) == self.ctx.builtins.simd) return CallCheck.badCall(self, args, callee, "a vector names its lane type and count: `Simd[U8, 16](array)`, or `Simd[U8, 16].splat(x)`", .{});
                if (self.ctx.ref(sym_id) == self.ctx.builtins.slot) return CallCheck.badCall(self, args, callee, "a `Slot[n]` is made by `push`, by `Slot[n].of(i)`, or by a literal below `n`", .{});
                if (self.ctx.ref(sym_id) == self.ctx.builtins.table) return CallCheck.badCall(self, args, callee, "`Table()` needs its type: give it where the value goes (`t: Table[T, n] = Table()`), or name it, `Table[T, n]()`", .{});
                if (self.ctx.ref(sym_id) == self.ctx.builtins.signal and !CompatCheck.sameNode(node, self.expect.shared_operand)) return CallCheck.badCall(self, args, callee, Checker.stack_signal, .{});
                if (self.ctx.ref(sym_id) == self.ctx.builtins.actor) return actorMake(self, node, callee, args);
                if (self.ctx.ref(sym_id) == self.ctx.builtins.frozen) return frozenMake(self, node, callee, args);
                return constructGeneric(self, callee, sym_id, args, name, callee.src.pos);
            },
            .module => return CallCheck.badCall(self, args, callee, "module `{s}` cannot be called", .{name}),
            .generic_param => return CallCheck.badCall(self, args, callee, "`{s}` is a type parameter; it cannot be called or constructed", .{name}),
            else => return CallCheck.callValue(self, callee, sym.ty, args, name),
        }
    }

    if (callee.isKind(.member)) return CallCheck.synthMemberCall(self, callee, args, ct);

    if (callee.isKind(.enum_lit)) return CallCheck.badCall(self, args, callee, "variant `.{s}(...)` needs a known enum type; annotate the binding", .{self.text(ir.EnumLit.name(callee))});

    const callee_ty = try ViewCheck.synthOperand(self, callee);
    return CallCheck.callValue(self, callee, callee_ty, args, CallCheck.sourceText(self, callee));
}

/// A call through an alias of type `ty` (in this module's terms),
/// named `name`: it constructs the object the alias names, or
/// converts to the number type it names.
pub fn aliasCall(self: *Checker, call: Sexp, callee: Sexp, name: []const u8, ty: TypeId, args: []const Sexp, pos: u32) Error!TypeId {
    if (self.isPoison(ty)) return CallCheck.skipCall(self, args);
    if (self.ctx.types.get(ty) == .slot) return slotMade(self, callee, ty, args);
    if (sema.isNumeric(self.ctx, ty)) return CallCheck.checkConversion(self, ty, name, args, pos);
    if (self.ctx.types.get(ty) == .simd) {
        if (callee == .src) if (CallCheck.lookupQuiet(self, callee)) |id| try self.ctx.recordName(callee, id);
        return simdConvert(self, ty, args, pos);
    }
    if (ty == self.t().string_id) return checkStringNew(self, call, args);
    if (sema.boxedType(self.ctx, ty) != null) return CallCheck.badCall(self, args, callee, "`{s}` is a type alias for `{s}`; a box is made with `^`: write `^value`", .{ name, try self.tyName(ty) });
    const nt = CallCheck.aliasNamedType(self, ty) orelse return CallCheck.badCall(self, args, callee, "`{s}` is a type alias for `{s}`, which has no constructor", .{ name, try self.tyName(ty) });
    if (nt.foreign) |fo| return CallCheck.construct(self, nt.id, args, pos, TypeSubst.empty, fo);
    if (nt.args) |targs| {
        if (self.ctx.ref(nt.id) == self.ctx.builtins.list) {
            try BuiltinCheck.checkListConstruction(self, call, ty);
            return ty;
        }
        if (self.ctx.ref(nt.id) == self.ctx.builtins.table) {
            try checkTableConstruction(self, call);
            return ty;
        }
        if (self.ctx.ref(nt.id) == self.ctx.builtins.signal and !CompatCheck.sameNode(call, self.expect.shared_operand)) return CallCheck.badCall(self, args, callee, Checker.stack_signal, .{});
        return CallCheck.construct(self, nt.id, args, pos, .{ .params = nt.sym.type_params orelse &.{}, .args = targs }, null);
    }
    if (callee == .src) try self.ctx.recordName(callee, nt.id);
    return CallCheck.construct(self, nt.id, args, pos, TypeSubst.empty, null);
}

/// `Wrap(v: 3)`, `lib.Wrap(v: 3)`: generic type `sym_id`, named `name`
/// by `callee`, constructed at the type arguments its fields' values
/// and the type expected of it give.
pub fn constructGeneric(self: *Checker, callee: Sexp, sym_id: SymbolId, args: []const Sexp, name: []const u8, pos: u32) Error!TypeId {
    if (args.len > 0 and isTypeName(self, args[0])) {
        try self.errAt(callee, "type arguments go in brackets: `{s}[{s}](...)`", .{ name, self.text(args[0]) });
        return self.t().invalid_id;
    }
    const fields = self.ctx.symbols.items[sym_id].fields orelse &.{};
    // An update makes the instance its spread's value is
    // (`objectUpdate`).
    for (args) |a| if (a.isKind(.spread)) {
        const ty = sema.unwrapAccess(self.ctx, try FlowCheck.synthQuiet(self, rig.Parser.spreadPlace(ir.Spread.value(a))));
        const result = switch (self.ctx.types.get(ty)) {
            .parameterized_nominal => |pn| if (pn.sym == self.ctx.ref(sym_id)) ty else null,
            else => null,
        } orelse {
            try self.errAt(a, "`..{s}` is a `{s}`, but this makes a `{s}`: a spread passes a value of the type it updates", .{ try ViewCheck.plainText(self, ir.Spread.value(a)), try self.tyName(ty), name });
            return CallCheck.skipCall(self, args);
        };
        try self.objectUpdate(args, fields, result, name);
        return result;
    };
    // Fields are set by name, but for one field given positionally.
    if (!(args.len == 1 and CallCheck.soleField(fields) != null)) for (args) |a| if (!a.isKind(.kwarg)) {
        try CallCheck.positionalFieldsError(self, fields, name, pos);
        return CallCheck.skipCall(self, args);
    };
    const subst = (try inferTypeArgs(self, sym_id, args, .{ .fields = fields }, pos, CallCheck.expectedResult(self, (try sema.makeNominalContext(self.ctx, sym_id)).self_type), null)) orelse return CallCheck.skipCall(self, args);
    _ = try ViewCheck.instantiate(self, sym_id, subst.args, pos);
    return CallCheck.construct(self, sym_id, args, pos, subst, null);
}

/// Call function `sym`, named by `callee`, with the compile-time
/// arguments in bracket list `ct` (null for none).
pub fn functionCall(self: *Checker, callee: Sexp, sym: sema.Symbol, ct: ?Sexp, args: []const Sexp) Error!TypeId {
    const name = self.text(callee);
    if (ExprCheck.isEntryPoint(self, sym)) return CallCheck.badCall(self, args, callee, Checker.entry_point_use, .{});
    if (self.isPoison(sym.ty)) return CallCheck.skipCall(self, args);
    const fty = self.ctx.types.get(sym.ty);
    if (fty != .function) return CallCheck.badCall(self, args, callee, "`{s}` has type `{s}` and cannot be called", .{ name, try self.tyName(sym.ty) });
    if (sym.kind == .@"extern" and self.raw_depth == 0) {
        try self.errAt(callee, "call to extern function `{s}` requires `raw` block; extern functions are the FFI boundary and bypass Rig's ownership and effect checks", .{name});
    }
    const info = CallCheck.paramsOf(sym, self.ctx.source);
    const f = (try CallCheck.instantiateCall(self, fty.function, ct, args, info, 0, name, callee.src.pos, false, .empty)) orelse return CallCheck.skipCall(self, args);
    if (sym.kind == .function) try noteTarget(self, self.ctx.module_id, sym.decl_pos, sym.flags.inline_marked, .empty);
    // A generic function's callee has the instance's signature.
    if (fty.function.ct_params.len > 0) try self.ctx.recordType(callee, try self.ctx.internCopy(.{ .function = f }));
    self.expect.view_call = true;
    try CallCheck.checkArgs(self, args, f, info, name, callee.src.pos, .{ .origins = sym.origins, .declared = fty.function.params });
    return f.returns;
}

/// A swap that gives back the old value, thrown away as a statement:
/// what was meant is a store (`x = v`, `!c.set(v)`), or an exchange of
/// two places (`swap(!a, !b)`); `_ = swap(!x, v)` drops the old value
/// on purpose. Reports it.
pub fn discardedSwap(self: *Checker, stmt: Sexp) Error!bool {
    const call = if (stmt.isKind(.write)) ir.Write.operand(stmt) else stmt;
    if (!call.isKind(.call) or ir.Call.task(call) != .nil) return false;
    const callee = ir.Call.callee(call);
    const args = ir.Call.args(call);
    if (args.len == 0) return false;
    const v = CallCheck.sourceText(self, args[args.len - 1]);
    if (self.ctx.swapCallOf(call)) |swap| {
        if (args.len != 2 or swap == .places) return false;
        const place = CallCheck.sourceText(self, if (args[0].isKind(.write)) ir.Write.operand(args[0]) else args[0]);
        try self.errAt(stmt, "this `swap` gives back the old value of `{s}`, which a statement throws away: to store `{s}`, write `{s} = {s}`; to exchange two places, pass write views of both, `swap(!{s}, !b)`", .{ place, v, place, v, place });
        return true;
    }
    if (callee.isKind(.member) and std.mem.eql(u8, self.text(ir.Member.name(callee)), "swap") and args.len == 1) {
        const obj = ir.Member.object(callee);
        const obj_ty = self.ctx.typeOf(obj) orelse return false;
        if (CompatCheck.cellElementType(self.ctx, obj_ty) == null) return false;
        const c = CallCheck.sourceText(self, if (obj.isKind(.write)) ir.Write.operand(obj) else obj);
        try self.errAt(stmt, "this `swap` gives back the Cell's old value, which a statement throws away: to store `{s}`, write `!{s}.set({s})`", .{ v, c, v });
        return true;
    }
    return false;
}

/// `compare_swap` compares, so it is a Cell of one word's
/// (`sema.isWordValue`); `add` and `sub` count, so they are a
/// `Cell[Int]`'s. Any other method fits every Cell. Reports a call
/// that does not fit.
pub fn cellMethod(self: *Checker, obj_ty: TypeId, method: []const u8, pos: u32) Error!bool {
    const counts = std.mem.eql(u8, method, "add") or std.mem.eql(u8, method, "sub");
    if (!counts and !std.mem.eql(u8, method, "compare_swap")) return true;
    const elem = CompatCheck.cellElementType(self.ctx, obj_ty) orelse return true;
    if (sema.containsTypeVar(self.ctx, elem)) return true;
    if (counts and elem != self.t().int_id) {
        try self.err(pos, "`{s}` counts, so it is a `Cell[Int]`'s; this is a `Cell[{s}]`: change it with `set`, `swap`, or `compare_swap`", .{ method, try self.tyName(elem) });
        return false;
    }
    if (!sema.isWordValue(self.ctx, elem)) {
        try self.err(pos, "`compare_swap` compares and stores at once, so it is a Cell of one word's (`Int`, `Bool`, `Float`, or a plain enum); this is a `Cell[{s}]`: change it with `set` or `swap`", .{try self.tyName(elem)});
        return false;
    }
    return true;
}

/// The type a bare name holds, when it holds a view: what tells a held
/// `!T` from a value before the name is checked (`checkSwap`).
pub fn heldViewType(self: *Checker, arg: Sexp) ?TypeId {
    if (arg != .src) return null;
    const id = CallCheck.lookupQuiet(self, arg) orelse return null;
    return self.ctx.symbols.items[id].ty;
}

/// The type of the place a `swap` argument makes a write view of
/// (`!x`, or a held `!T`), which holds no view; null after a
/// diagnostic.
pub fn swapPlace(self: *Checker, arg: Sexp, what: []const u8) Error!?TypeId {
    const ty = try PatternCheck.synthExpr(self, arg);
    if (self.isPoison(ty)) return null;
    const place = switch (self.ctx.types.get(ty)) {
        .write_view => |inner| if (sema.writeSliceElem(self.ctx, ty) == null) inner else null,
        else => null,
    } orelse {
        try self.errAt(arg, "`{s}` takes a write view of a place: `!x`; got `{s}`", .{ what, try self.tyName(ty) });
        return null;
    };
    if (sema.isErasedView(self.ctx, ty)) {
        try self.errAt(arg, "`{s}` cannot exchange through `{s}`, a `{s}`: the value it views may be of another type; call its methods, or hold a `^{s}` and replace the box", .{ what, try ViewCheck.plainText(self, CompatCheck.stripSigil(arg)), try self.tyName(ty), try self.tyName(place) });
        return null;
    }
    if (sema.holdsMarkedView(self.ctx, place)) {
        try self.errAt(arg, "`{s}` moves values that hold no `?T`, `!T`, or slice; `{s}` may hold one", .{ what, try self.tyName(place) });
        return null;
    }
    // A value that changes by a marked call is never replaced whole
    // (Core §4): a Cell's change is one indivisible step every handle
    // sees, which a plain exchange would race; a value that holds one
    // keeps plain data its handles only read; a Signal's set may be
    // running its subscribers. A handle is exchanged as itself.
    if (sema.holdsMarkedValue(self.ctx, place)) {
        const sym: ?sema.SymbolRef = switch (self.ctx.types.get(place)) {
            .parameterized_nominal => |pn| pn.sym,
            else => null,
        };
        if (sym == self.ctx.builtins.cell) {
            try self.errAt(arg, "`{s}` moves values whole, and a `{s}` changes only by its marked calls, which every handle shares: exchange its value with the Cell's own `old = (!c).swap(v)`", .{ what, try self.tyName(place) });
        } else if (sym == self.ctx.builtins.signal) {
            try self.errAt(arg, "`{s}` moves values whole, and a `{s}` changes only by its marked calls (`!s.set(v)`), which may be running its subscribers", .{ what, try self.tyName(place) });
        } else if (sym == self.ctx.builtins.chan) {
            try self.errAt(arg, "`{s}` moves values whole, and a `{s}` changes only by its sends and receives, marked calls every handle shares", .{ what, try self.tyName(place) });
        } else try self.errAt(arg, "`{s}` moves values whole, and `{s}` holds a Cell, so it lives only behind a shared handle, whose other fields only read", .{ what, try self.tyName(place) });
        return null;
    }
    if (!arg.isKind(.write)) try checkViewsVisibly(self, arg, ty, "the call writes through");
    return place;
}

/// `print(a, b, ...)`: any number of values, printed on one line.
pub fn checkPrint(self: *Checker, args: []const Sexp) Error!TypeId {
    try checkFormatArgs(self, args, "`print`", "print");
    return self.t().void_id;
}

/// `warn(a, b, ...)`: written as `print` writes them, to stderr.
pub fn checkWarn(self: *Checker, args: []const Sexp) Error!TypeId {
    try checkFormatArgs(self, args, "`warn`", "warn");
    return self.t().void_id;
}

/// `panic(a, b, ...)`: a message, written as `print` writes it, and
/// the end of the program, so it gives no value. It stands where
/// `placePanics` allows it.
pub fn checkPanic(self: *Checker, e: Sexp) Error!TypeId {
    const args = ir.Panic.args(e);
    const place = self.panic_places.get(CompatCheck.nodeId(e)) orelse .value;
    switch (place) {
        .statement => {},
        .value => try self.errAt(e, "`panic` ends the program and gives no value, so it stands as a statement or as a branch's value", .{}),
        .deferred => try self.errAt(e, "`panic` cannot stand in deferred code, which runs as its scope ends; check before the scope ends instead", .{}),
    }
    if (args.len == 0) try self.errAt(e, "`panic` needs a message: say what went wrong", .{});
    try checkFormatArgs(self, args, "`panic`", "print");
    // A misplaced `panic` is poison, so what uses it reports nothing more.
    return if (place == .statement) self.t().noreturn_id else self.t().invalid_id;
}

/// Record where each `panic` under `e` stands, `e` standing at
/// `place`, by a positive list: a block's statement, the value of an
/// `if` or `match` branch, the right side of `??`, and the tail of a
/// `catch` handler stand as statements, and a body is a block.
/// Everything else needs a value. Deferred code keeps `deferred`.
pub fn placePanics(self: *Checker, e: Sexp, place: Checker.PanicPlace) Error!void {
    const kind = e.kind() orelse return;
    const stmt: Checker.PanicPlace = if (place == .deferred) .deferred else .statement;
    const value: Checker.PanicPlace = if (place == .deferred) .deferred else .value;
    switch (kind) {
        .panic => {
            try self.panic_places.put(self.ctx.allocator, CompatCheck.nodeId(e), place);
            for (ir.Panic.args(e)) |a| try placePanics(self, a, value);
        },
        .block => for (ir.Block.stmts(e)) |s| try placePanics(self, s, stmt),
        .@"if" => {
            try placePanics(self, ir.If.cond(e), value);
            try placePanics(self, ir.If.then(e), stmt);
            try placePanics(self, ir.If.@"else"(e), stmt);
        },
        .match => {
            try placePanics(self, ir.Match.subject(e), value);
            for (ir.Match.arms(e)) |arm| {
                try placePanics(self, ir.Arm.pattern(arm), value);
                try placePanics(self, ir.Arm.guard(arm), value);
                try placePanics(self, ir.Arm.body(arm), stmt);
            }
        },
        .@"??" => {
            try placePanics(self, ir.@"??".left(e), value);
            try placePanics(self, ir.@"??".right(e), stmt);
        },
        .@"catch" => {
            try placePanics(self, ir.Catch.value(e), value);
            try placePanics(self, ir.Catch.handler(e), stmt);
        },
        .labeled => try placePanics(self, ir.Labeled.stmt(e), place),
        .@"defer", .@"errdefer" => try placePanics(self, ir.get(e, .body), .deferred),
        .fun, .sub, .drop_decl, .@"test", .lambda => {
            const body = ir.get(e, .body);
            for (rig.children(e)) |c| try placePanics(self, c, if (CompatCheck.sameNode(c, body)) .statement else .value);
        },
        else => for (rig.children(e)) |c| try placePanics(self, c, value),
    }
}

/// The values `print`, `String(...)`, and `!t.add(...)` (`who`) write
/// as text, each as `print` writes it: any value but a `Void`, a
/// bare `none`, or one holding a `[]U8`, positionally. They are only
/// read, and kept by nothing, so a viewed temporary lives long
/// enough.
pub fn checkFormatArgs(self: *Checker, args: []const Sexp, who: []const u8, verb: []const u8) Error!void {
    for (args) |a| {
        // A template's slots are the call's arguments where it stands
        // (SPEC "Templates").
        if (a.isKind(.template)) {
            try checkTemplateSlots(self, a, who, verb);
            continue;
        }
        try checkFormatArg(self, a, who, verb);
    }
}

/// One value `checkFormatArgs` writes.
pub fn checkFormatArg(self: *Checker, a: Sexp, who: []const u8, verb: []const u8) Error!void {
    if (a.isKind(.kwarg)) {
        try self.errAt(a, "{s} takes no keyword arguments", .{who});
        _ = try FlowCheck.synthQuiet(self, ir.Kwarg.value(a));
        return;
    }
    // The values are only read, so a slice is viewed the way a read
    // parameter's argument is: `print(w[1..3])`.
    const saved_view = self.expect.view_arg;
    defer self.expect.view_arg = saved_view;
    self.expect.view_arg = a;
    const ty = try ViewCheck.synthReadTemp(self, a);
    if (!self.isPoison(ty) and CallCheck.slicedArg(self, a)) if (CompatCheck.sliceArgView(self.ctx, ty, ty)) |view| {
        var implicit = view;
        implicit.implicit = true;
        try self.ctx.recordImplicitView(a);
        try self.ctx.recordView(a, implicit);
    };
    if (try ViewCheck.writeViewRead(self, a, ty, .{ .value = sema.unwrapViews(self.ctx, ty) })) return;
    // A task shows nothing of what it gives: what is meant is its
    // result, and `<t` and `>t` are one key apart.
    if (!self.isPoison(ty) and (sema.isTask(self.ctx, sema.unwrapViews(self.ctx, ty)) or sema.isTaskSet(self.ctx, sema.unwrapViews(self.ctx, ty)))) {
        const shown = try ViewCheck.plainText(self, CompatCheck.stripSigil(a));
        try self.errAt(a, "`{s}` is a task, which {s} cannot show: wait for what it gives, `>{s}`", .{ shown, who, shown });
        return;
    }
    // An integer literal is written as an `Int`, which must hold it.
    if (ty == self.t().int_literal_id) try ViewCheck.defaultIntLiteral(self, a);
    // `?none` views a bare `none`.
    const shown_ty = if (sema.unwrapViews(self.ctx, ty) == self.t().none_id) self.t().none_id else ty;
    switch (self.ctx.types.get(shown_ty)) {
        .void => try self.errAt(a, "{s} needs a value; this expression produces no value (`Void`)", .{who}),
        .none_literal => try self.errAt(a, "cannot {s} a bare `none`", .{verb}),
        .noreturn => try self.errAt(a, "{s} needs a value; this expression never produces one", .{who}),
        else => {
            if (!try sema.printable(self.ctx, ty)) {
                const name = try self.tyName(ty);
                const direct = std.mem.eql(u8, name, "[]U8");
                try self.errAt(a, "cannot {s} a `{s}`: {s}would {s} as text, like a `?String`; {s} the bytes one by one", .{ verb, name, if (direct) "it " else "the `[]U8` it holds ", verb, verb });
            } else if (try sema.objectUnprinted(self.ctx, ty)) |held| {
                // An API object prints by the `Print` its braces or
                // API name, through its table.
                const printed = if (std.mem.eql(u8, verb, "write")) "written" else "printed";
                const h = sema.objectHeld(self.ctx, held) orelse {
                    try self.errAt(a, "`{s}` cannot be {s}: it holds an API object whose type is erased, and whose braces and API name no `Print`", .{ try self.tyName(ty), printed });
                    return;
                };
                const api = try sema.apiName(self.ctx, h.object.api);
                var with = h.object;
                with.builtins.insert(.Print);
                const sigil: []const u8 = switch (h.form) {
                    .read => "?",
                    .write => "!",
                    .box => "^",
                    .shared => "*",
                    .weak => "~",
                };
                try self.errAt(a, "`{s}` cannot be {s}: its type is erased; write `{s}{s}`, or build `{s}` on `Print`", .{ try self.tyName(held), printed, sigil, try sema.objectSpelling(self.ctx, self.ctx.arena.allocator(), with), api });
            }
            // Each instance answers for a type parameter the value
            // prints: held, viewed, an element, or a type
            // argument (`[]T`, `List[T]`).
            var printed: std.ArrayList(SymbolId) = .empty;
            defer printed.deinit(self.ctx.allocator);
            try sema.printedTypeVars(self.ctx, ty, &printed, self.ctx.allocator);
            for (printed.items) |param| try ExprCheck.require(self, param, .printable, self.startOf(a), verb);
        },
    }
}

/// The slots of template `t` where `who` writes it (`print`, `warn`,
/// `panic`, `String(...)`, `!t.add(...)`): each value checked as one
/// of `who`'s arguments (`checkFormatArg`), left to right, and its
/// text's escapes as a string literal's.
pub fn checkTemplateSlots(self: *Checker, tpl: Sexp, who: []const u8, verb: []const u8) Error!void {
    const n = rig.Template.slotCount(tpl);
    for (0..n + 1) |i| {
        const piece = rig.Template.piece(tpl, i);
        try ExprCheck.checkEscapes(self, piece);
        try self.ctx.recordType(piece, self.t().static_id);
    }
    for (0..n) |i| {
        const v = rig.Template.value(tpl, i);
        if (try literalSlot(self, v)) continue;
        try checkFormatArg(self, v, who, verb);
    }
    try self.ctx.recordType(tpl, self.t().string_id);
}

/// A slot holding only a literal (`{0}`, `{"a"}`, `{true}`, `{-1}`),
/// which is rejected: its text belongs in the template's text, and a
/// ported `{0}` meant a value it does not name.
pub fn literalSlot(self: *Checker, v: Sexp) Error!bool {
    const lit = if (v.isKind(.neg)) ir.Neg.operand(v) else v;
    const only = switch (lit) {
        .src => blk: {
            const lit_text = self.text(lit);
            break :blk sema.isStringLiteralText(lit_text) or sema.isIntLiteralText(lit_text) or sema.isFloatLiteralText(lit_text) or std.mem.eql(u8, lit_text, "true") or std.mem.eql(u8, lit_text, "false") or std.mem.eql(u8, lit_text, "none");
        },
        .list => lit.isKind(.symbol),
        else => false,
    };
    if (!only) return false;
    try self.errAt(v, "a slot holds only a literal; write its text in the template, or a brace as `\\{{` and `\\}}`", .{});
    try self.ctx.recordType(v, self.t().invalid_id);
    return true;
}

/// A template whose value its context takes (`template_ok`): a
/// String made from its pieces. Anywhere else a template is rejected
/// (SPEC "Templates").
pub fn synthTemplate(self: *Checker, tpl: Sexp) Error!TypeId {
    try checkTemplateSlots(self, tpl, "a slot", "write");
    // Fixed text, which the program holds as a literal's.
    if (CompatCheck.sameNode(tpl, self.expect.template_fixed) and templateFolds(self, tpl)) {
        try self.ctx.recordType(tpl, self.t().static_id);
        return self.t().static_id;
    }
    if (CompatCheck.sameNode(tpl, self.expect.template_ok)) return self.t().string_id;
    if (CompatCheck.sameNode(tpl, self.expect.template_fixed)) {
        try self.errAt(tpl, "a module's constant is fixed text, so a template there takes only constant slots: an Int, a Bool, or a `Static` known when the program is compiled", .{});
        try self.ctx.recordType(tpl, self.t().invalid_id);
        return self.t().invalid_id;
    }
    try self.errAt(tpl, "a template stands where text is written (`print`, `warn`, `panic`, `String(...)`, `!t.add(...)`) or where a `String` or `?String` goes; bind it to a name first", .{});
    try self.ctx.recordType(tpl, self.t().invalid_id);
    return self.t().invalid_id;
}

/// A template where a value of type `expected` goes: a String where a
/// `String` (or a `String?`) goes, and a String a `?String` reads as a
/// temporary of its statement, which `checkActual` views. A `Static`
/// is text fixed when the program is compiled, which a template is
/// not.
pub fn checkTemplateAgainst(self: *Checker, tpl: Sexp, expected: TypeId) Error!void {
    const want = switch (self.ctx.types.get(expected)) {
        .optional => |inner| inner,
        else => expected,
    };
    const saved_fixed = self.expect.template_fixed;
    defer self.expect.template_fixed = saved_fixed;
    if (want == self.t().static_id or want == self.t().string_view_id) self.expect.template_fixed = tpl;
    if (want == self.t().static_id) {
        try checkTemplateSlots(self, tpl, "a slot", "write");
        if (templateFolds(self, tpl)) {
            try self.ctx.recordType(tpl, self.t().static_id);
            return ViewCheck.checkActual(self, tpl, self.t().static_id, expected);
        }
        try self.ctx.recordType(tpl, self.t().invalid_id);
        return self.errAt(tpl, "type mismatch: expected `Static`, got a template built as the program runs; a `Static` is text fixed when the program is compiled, which a template is when each slot is an Int, a Bool, or a `Static` known then", .{});
    }
    const saved = self.expect.template_ok;
    defer self.expect.template_ok = saved;
    if (want == self.t().string_id or want == self.t().string_view_id) self.expect.template_ok = tpl;
    const ty = try synthTemplate(self, tpl);
    if (self.isPoison(ty)) return;
    return ViewCheck.checkActual(self, tpl, ty, expected);
}

/// Whether template `tpl` is fixed text: every slot an Int, a Bool, or
/// a `Static` Zig knows when it compiles (`isComptimeKnown`), which
/// it writes as text there; a show slot, a Float, and any other value
/// is written as the program runs.
pub fn templateFolds(self: *Checker, tpl: Sexp) bool {
    for (0..rig.Template.slotCount(tpl)) |i| {
        const v = rig.Template.slot(tpl, i);
        if (v.isKind(.show) or !CallCheck.isComptimeKnown(self, v)) return false;
        const ty = ExprCheck.canonical(self, self.ctx.typeOf(v) orelse return false);
        if (!(sema.isInteger(self.ctx, ty) or ty == self.t().bool_id or ty == self.t().static_id)) return false;
    }
    return true;
}

/// `s = `{s}…``: a template that reads the binding it assigns copies
/// all of it to add to it, on every step of a loop; `!s.add(...)`
/// appends in place.
pub fn checkTemplateGrows(self: *Checker, rhs: Sexp, target: Sexp) Error!void {
    if (!rhs.isKind(.template) or target.isKind(.paren)) return;
    const assigned = CallCheck.sourceText(self, target);
    for (0..rig.Template.slotCount(rhs)) |i| {
        const v = rig.Template.value(rhs, i);
        const read = if (v.isKind(.read)) ir.Read.operand(v) else v;
        if (!std.mem.eql(u8, CallCheck.sourceText(self, read), assigned)) continue;
        return self.errAt(v, "this template reads `{s}`, the binding it assigns, so it copies all of `{s}` each time; append in place with `!{s}.add(...)`", .{ assigned, assigned, assigned });
    }
}

/// `String(a, b, ...)`: a new String holding each value as `print` writes
/// it, with no separators; `String()` is empty.
pub fn checkStringNew(self: *Checker, call: Sexp, args: []const Sexp) Error!TypeId {
    try checkFormatArgs(self, args, "`String(...)`", "write");
    try self.ctx.recordStringCall(call, .new);
    return self.t().string_id;
}

/// `!t.add(a, b, ...)`, which appends each value as `print` writes
/// it, and `!t.clear()`, on a String self written `!t`, recorded
/// on the callee. Null when self is no String or the method
/// none of these.
pub fn stringCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!?TypeId {
    // A box gives a view of the String it holds.
    var held = sema.unwrapViews(self.ctx, obj_ty);
    while (sema.boxedType(self.ctx, held)) |inner| held = sema.unwrapViews(self.ctx, inner);
    if (held != self.t().string_id) return null;
    const op = std.meta.stringToEnum(sema.StringCall, method) orelse return null;
    if (op == .new or op == .push_int or op == .push_keep or op == .printer_value or op == .hasher_add) return null;
    // Only `push` takes compile-time arguments: `push[T, e](v)`.
    if (ct != null and op != .push) return try CallCheck.badCall(self, args, ct.?, "`{s}` takes no compile-time arguments", .{method});
    const recv = try self.ctx.intern(.{ .write_view = self.t().string_id });
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{recv}), .returns = self.t().void_id, .is_sub = true });
    if (!try ViewCheck.checkSelfSigil(self, obj, .write, self.t().void_id, method)) {
        const kind: CompatCheck.SelfTypeKind = switch (self.ctx.types.get(obj_ty)) {
            .read_view => .read_view,
            .write_view => .write_view,
            else => .owned_nominal,
        };
        // (A String made here with no `!` is reported as such.)
        const saved_of = self.expect.self_of;
        defer self.expect.self_of = saved_of;
        self.expect.self_of = callee;
        try ViewCheck.checkSelfMode(self, obj, .write, kind, method, pos, self.t().void_id);
        if (ViewCheck.hands(self, obj).kind != .made) try ViewCheck.rejectResourceTemporary(self, obj, obj_ty);
    }
    switch (op) {
        .add => try checkFormatArgs(self, args, "`add`", "write"),
        // One byte, as a List's `push` takes one element.
        .push_int, .push_keep, .printer_value, .hasher_add => unreachable,
        // `push[T, e](v)`: the bytes of an integer; `push(v, keep:
        // k)` the first `k` bytes of a vector.
        .push => if (ct) |b| {
            const wide = try pushWide(self, callee, b, pos, args);
            if (wide) return try finishStringCall(self, callee, if (pushKeepOf(self, args) != null) .push_keep else .push_int);
        } else if (pushKeepOf(self, args) != null) {
            if (try pushVector(self, callee, pos, args)) return try finishStringCall(self, callee, .push_keep);
        } else if (args.len == 1 and args[0].isKind(.kwarg)) {
            try self.errAt(args[0], "`push` takes its byte by position, not by name: `!t.push({s})`", .{CallCheck.sourceText(self, ir.Kwarg.value(args[0]))});
            try CallCheck.synthArgs(self, args);
        } else if (args.len != 1) {
            try self.err(pos, "`push` takes one byte, a `U8`; got {d} arguments", .{args.len});
            try CallCheck.synthArgs(self, args);
        } else try ViewCheck.checkExpr(self, args[0], try ViewCheck.byteType(self)),
        // Room for `n` more bytes.
        .reserve => if (args.len == 1 and args[0].isKind(.kwarg)) {
            try self.errAt(args[0], "`reserve` takes its count by position, not by name: `!t.reserve({s})`", .{CallCheck.sourceText(self, ir.Kwarg.value(args[0]))});
            try CallCheck.synthArgs(self, args);
        } else if (args.len != 1) {
            try self.err(pos, "`reserve` takes one argument, the number of bytes to make room for; got {d} arguments", .{args.len});
            try CallCheck.synthArgs(self, args);
        } else try ViewCheck.checkExpr(self, args[0], self.t().int_id),
        else => if (args.len > 0) {
            try self.err(pos, "`clear` takes no arguments; got {d}", .{args.len});
            try CallCheck.synthArgs(self, args);
        },
    }
    return try finishStringCall(self, callee, op);
}

pub fn finishStringCall(self: *Checker, callee: Sexp, op: sema.StringCall) Error!TypeId {
    try self.ctx.recordStringCall(callee, op);
    return self.t().void_id;
}

/// `!t.push[T, e](v)`: the integer `v`, a `T`, appended as `$size(T)`
/// bytes in byte order `e`, a compile-time `Endian`; a one-byte `T`
/// takes no byte order. True when it checked, with the call's `T`
/// recorded; after a diagnostic, false.
pub fn pushWide(self: *Checker, callee: Sexp, b: Sexp, pos: u32, args: []const Sexp) Error!bool {
    const example = "push[U32, .little](value)";
    try self.ctx.recordInstance(b, .function);
    const given = sema.bracketArgs(b);
    if (given.len < 1 or given.len > 2) {
        _ = try CallCheck.badCall(self, args, b, "`push` takes the integer type and, for more than one byte, the byte order in brackets: `{s}`", .{example});
        return false;
    }
    const num = try CallCheck.typeArg(self, given[0]);
    if (self.isPoison(num)) {
        _ = try CallCheck.skipCall(self, args);
        return false;
    }
    var one_byte = false;
    switch (self.ctx.types.get(num)) {
        .int => |info| one_byte = CompatCheck.intBounds(info).bits == 8,
        // A type parameter: each instance must be an integer.
        .type_var => |param| try ExprCheck.require(self, self.ctx.localSym(param), .integer, self.startOf(given[0]), "push"),
        else => {
            _ = try CallCheck.badCall(self, args, given[0], "`push` appends an integer type; got `{s}`", .{try self.tyName(num)});
            return false;
        },
    }
    if (given.len == 2) {
        if (one_byte) {
            _ = try CallCheck.badCall(self, args, given[1], "`push` of a one-byte `{s}` takes no byte order: `push[{s}](byte)`", .{ try self.tyName(num), try self.tyName(num) });
            return false;
        }
        const endian = try self.ctx.intern(.{ .nominal = self.ctx.builtins.endian });
        try self.checkCtValue(given[1], endian, 1, "push");
    } else if (!one_byte) {
        _ = try CallCheck.badCall(self, args, b, "`push` of a `{s}` takes a byte order too: `{s}`", .{ try self.tyName(num), example });
        return false;
    }
    const keep = pushKeepOf(self, args);
    for (args, 0..) |a, i| if (a.isKind(.kwarg) and !(keep != null and i == args.len - 1)) {
        _ = try CallCheck.badCall(self, args, a, "`push` takes no keyword argument but `keep:`, last: `push[U64, .little](word, keep: k)`", .{});
        return false;
    };
    const given_args = args.len - @intFromBool(keep != null);
    if (given_args != 1) {
        _ = try CallCheck.badCall(self, args, pos, "`push` takes one argument, the integer to append; got {d} arguments", .{given_args});
        return false;
    }
    try ViewCheck.checkExpr(self, args[0], num);
    if (keep) |k| try checkKeep(self, ir.Kwarg.value(k), switch (self.ctx.types.get(num)) {
        .int => |info| CompatCheck.intBounds(info).bits / 8,
        else => null,
    });
    try self.ctx.recordStringNum(callee, num);
    return true;
}

/// The `keep: k` argument of a `push`: the last argument, a keyword
/// argument named `keep`; else null.
pub fn pushKeepOf(self: *Checker, args: []const Sexp) ?Sexp {
    if (args.len == 0) return null;
    const last = args[args.len - 1];
    if (!last.isKind(.kwarg)) return null;
    const name = ir.Kwarg.name(last);
    if (!std.mem.eql(u8, self.text(name), "keep")) return null;
    return last;
}

/// `keep: k`: an `Int`, which must be `0..=size` where `size`, the
/// bytes of the value pushed, is known and `k` is a constant;
/// otherwise the push panics.
pub fn checkKeep(self: *Checker, k: Sexp, size: ?u64) Error!void {
    try ViewCheck.checkExpr(self, k, self.t().int_id);
    const v = ExprCheck.constInt(self, k) orelse return;
    if (v < 0) {
        try self.errAt(k, "`keep: {d}` is negative; `push` keeps 0 up to the size of the value", .{v});
    } else if (size) |n| if (v > n) {
        try self.errAt(k, "`keep: {d}` is more than the {d} bytes pushed", .{ v, n });
    };
}

/// `!t.push(v, keep: k)`: the first `k` bytes of the vector `v`, a
/// `Simd[U8, n]`. True when it checked, with the vector's type
/// recorded; after a diagnostic, false.
pub fn pushVector(self: *Checker, callee: Sexp, pos: u32, args: []const Sexp) Error!bool {
    const keep = pushKeepOf(self, args).?;
    for (args, 0..) |a, i| if (a.isKind(.kwarg) and i != args.len - 1) {
        _ = try CallCheck.badCall(self, args, a, "`push` takes no keyword argument but `keep:`, last: `push(block, keep: k)`", .{});
        return false;
    };
    if (args.len != 2) {
        _ = try CallCheck.badCall(self, args, pos, "`push(v, keep: k)` takes one value and `keep:`; got {d} arguments", .{args.len - 1});
        return false;
    }
    const ty = try PatternCheck.synthExpr(self, args[0]);
    if (self.isPoison(ty)) {
        try CallCheck.synthArgs(self, args[1..]);
        return false;
    }
    const vec = sema.unwrapViews(self.ctx, ty);
    const simd = sema.simdOf(self.ctx, vec);
    const bytes = if (simd) |v| switch (self.ctx.types.get(v.elem)) {
        .int => |info| if (CompatCheck.intBounds(info).bits == 8 and !info.signed) sema.simdLen(self.ctx, v) else null,
        else => null,
    } else null;
    if (bytes == null) {
        _ = try CallCheck.badCall(self, args, args[0], "`push` with `keep:` takes a vector of bytes, a `Simd[U8, n]`, or an integer with its byte order, `push[U64, .little](word, keep: k)`; got `{s}`", .{try self.tyName(ty)});
        return false;
    }
    // The vector is read as a value: a write view written here is
    // reported, and a held write view read through.
    if (self.ctx.types.get(ty) == .write_view) {
        try ViewCheck.readOf(self, args[0], ty, .{ .value = vec });
        if (self.isPoison(self.ctx.typeOf(args[0]) orelse ty)) return false;
    }
    try checkKeep(self, ir.Kwarg.value(keep), bytes.?);
    try self.ctx.recordStringNum(callee, vec);
    return true;
}

/// The methods of an integer's bits, all on its bit pattern, so a
/// negative value counts as its two's complement: `x.not()`, the
/// complement (every bit flipped), also of a `Bool`; `x.swap_bytes()`,
/// the bytes reversed; both in self's own type. And
/// `x.leading_zeros()`, `x.trailing_zeros()`, and `x.count_ones()`,
/// an `Int` (a zero has as many of each zero count as it has bits).
/// Null when `method` is none of them or self is not an
/// integer.
pub fn bitCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp) Error!?TypeId {
    const op = std.meta.stringToEnum(sema.ElemOp, method) orelse return null;
    if (!op.isBits()) return null;
    const value = sema.unwrapViews(self.ctx, obj_ty);
    if (op == .to_bits) return toBitsCall(self, callee, obj, obj_ty, value, method, pos, args);
    if (op == .fraction or op == .exponent) return frexpCall(self, callee, obj, obj_ty, value, op, method, pos, args);
    // `v.not()` of a vector: lane by lane, of integer or `Bool` lanes.
    // A mask's bits are counted as `bits()`'s.
    const lane = if (sema.simdOf(self.ctx, value)) |v| (if (op == .not) v.elem else {
        if (v.elem != self.t().bool_id or op == .swap_bytes) return null;
        const recv = try selfText(self, obj);
        return try CallCheck.badCall(self, args, pos, "`{s}` counts an integer's bits, and `{s}` is a mask, `{s}`: count the bits `bits()` gives, `{s}.bits().{s}()`", .{ method, try ViewCheck.plainText(self, obj), try self.tyName(value), recv, method });
    }) else value;
    const is_bool = lane == self.t().bool_id;
    if (!(is_bool and op == .not) and !sema.isInteger(self.ctx, lane)) return null;
    if (ViewCheck.isSelfSigil(self, obj)) try ViewCheck.misplacedSigil(self, obj, method, "does not consume `self`");
    _ = try ViewCheck.readThrough(self, obj, obj_ty, value);
    if (value == self.t().int_literal_id) try ViewCheck.defaultIntLiteral(self, obj);
    const ty = if (value == self.t().int_literal_id) self.t().int_id else value;
    const result = switch (op) {
        .leading_zeros, .trailing_zeros, .count_ones => self.t().int_id,
        else => ty,
    };
    if (args.len > 0) {
        try self.err(pos, "`{s}` takes no arguments; got {d}", .{ method, args.len });
        try CallCheck.synthArgs(self, args);
    }
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{ty}), .returns = result, .is_sub = false });
    try self.ctx.recordElemCall(callee, .{ .op = op, .elem = result, .num = ty });
    return result;
}

/// `f.to_bits()`: the IEEE bits of a float as the unsigned integer of
/// its width. Null when self is not a float.
pub fn toBitsCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, value: TypeId, method: []const u8, pos: u32, args: []const Sexp) Error!?TypeId {
    const info = switch (self.ctx.types.get(value)) {
        .float => |f| f,
        else => return null,
    };
    if (ViewCheck.isSelfSigil(self, obj)) try ViewCheck.misplacedSigil(self, obj, method, "does not consume `self`");
    _ = try ViewCheck.readThrough(self, obj, obj_ty, value);
    const result = try bitsType(self, info);
    if (args.len > 0) {
        try self.err(pos, "`{s}` takes no arguments; got {d}", .{ method, args.len });
        try CallCheck.synthArgs(self, args);
    }
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{value}), .returns = result, .is_sub = false });
    try self.ctx.recordElemCall(callee, .{ .op = .to_bits, .elem = result, .num = value });
    return result;
}

/// `x.hash()`: a `U64` of the value `x` reaches, on exactly the
/// types `==` compares, less a float and what holds one
/// (`sema.notHashable`). Values `==` calls equal hash equal: text by
/// its bytes whatever its type, an optional holding a value as that
/// value. It reads `x` where it is, as `==` reads an operand; in a
/// generic body, each parameter the value holds records `hashable`,
/// checked at every instance.
pub fn hashCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, pos: u32, args: []const Sexp) Error!TypeId {
    const u64_ty = try self.ctx.intern(.{ .int = .{ .bits = 64, .signed = false } });
    if (ViewCheck.isSelfSigil(self, obj) and !obj.isKind(.read)) try ViewCheck.misplacedSigil(self, obj, "hash", "only reads `self`");
    var value = sema.unwrapViews(self.ctx, obj_ty);
    if (value == self.t().int_literal_id) {
        try ViewCheck.defaultIntLiteral(self, obj);
        value = self.t().int_id;
    }
    if (args.len > 0) {
        try self.err(pos, "`hash` takes no arguments; got {d}", .{args.len});
        try CallCheck.synthArgs(self, args);
    }
    if (!CompatCheck.isText(self.ctx, value)) {
        var params: std.ArrayList(SymbolId) = .empty;
        defer params.deinit(self.ctx.allocator);
        if (try sema.notHashable(self.ctx, value, &params)) |n| {
            try self.errAt(obj, "`.hash()` does not take a `{s}`: {s}", .{ try self.tyName(value), try ApiCheck.notEquatableReason(self.ctx, n) });
            return u64_ty;
        }
        for (params.items) |tv| try ExprCheck.require(self, tv, .hashable, self.startOf(obj), ".hash()");
    }
    if (!ViewCheck.hands(self, obj).hasStorage()) try ViewCheck.readLeaf(self, obj) else try ViewCheck.rejectResourceTemporary(self, obj, obj_ty);
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{try self.ctx.intern(.{ .read_view = value })}), .returns = u64_ty, .is_sub = false });
    try self.ctx.recordElemCall(callee, .{ .op = .hash, .elem = u64_ty, .num = value });
    return noteMethod(self, callee, .read, u64_ty);
}

/// `a.order(?b)`: how two values of a type that provides `Ord` order,
/// an `Order`, where the type declares no `order` of its own (a number,
/// text, an enum, or a type whose header names `Ord` and is ordered by
/// its fields). On a type parameter, the bounds or each instance
/// provide `Ord`. Null when the type provides no `Ord`.
pub fn orderCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, pos: u32, args: []const Sexp) Error!?TypeId {
    var value = sema.unwrapViews(self.ctx, obj_ty);
    if (value == self.t().int_literal_id) {
        try ViewCheck.defaultIntLiteral(self, obj);
        value = self.t().int_id;
    }
    if (value == self.t().float_literal_id) value = self.t().float_id;
    switch (self.ctx.types.get(value)) {
        .type_var => |tv| {
            const sym = self.ctx.symbols.items[self.ctx.localSym(tv)];
            if (sema.hasBounds(sym) and !sema.boundApis(self.ctx, sym).contains(.Ord)) {
                if (!try sema.reportStated(self.ctx, self.startOf(obj), self.ctx.localSym(tv), .Ord, "order")) return null;
            }
            if (!sema.hasBounds(sym)) try ExprCheck.require(self, self.ctx.localSym(tv), .order, self.startOf(obj), "order");
        },
        .float => {
            try self.errAt(obj, "`{s}` has no `order`{s}", .{ try self.tyName(value), sema.floatUnordered });
            return try CallCheck.skipCall(self, args);
        },
        else => if ((try sema.lacks(self.ctx, value, .Ord)) != null) return null,
    }
    const order_ty = try self.ctx.intern(.{ .nominal = self.ctx.builtins.order });
    if (ViewCheck.isSelfSigil(self, obj) and !obj.isKind(.read)) try ViewCheck.misplacedSigil(self, obj, "order", "only reads `self`");
    if (!ViewCheck.hands(self, obj).hasStorage()) try ViewCheck.readLeaf(self, obj) else try ViewCheck.rejectResourceTemporary(self, obj, obj_ty);
    const view = try self.ctx.intern(.{ .read_view = value });
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{ view, view }), .returns = order_ty, .is_sub = false });
    try CallCheck.checkArgs(self, args, .{ .params = try self.ctx.dupeIds(&.{view}), .returns = order_ty, .is_sub = false }, .{ .names = &.{"other"} }, "order", pos, .{ .has_self = true, .origins = .{ .result = 0, .stores = 0 }, .declared = &.{view} });
    try self.ctx.recordElemCall(callee, .{ .op = .order, .elem = order_ty, .num = value });
    return try noteMethod(self, callee, .read, order_ty);
}

/// `!h.add(x)`: the hash of `x`, any value that provides `Hash`, mixed
/// into the hash a Hasher makes. `x` is only read.
pub fn hasherAdd(self: *Checker, callee: Sexp, obj: Sexp, pos: u32, args: []const Sexp) Error!TypeId {
    if (!obj.isKind(.write)) try self.errAt(obj, "`add` writes the Hasher: `!{s}.add(...)`", .{try ViewCheck.plainText(self, CompatCheck.stripSigil(obj))});
    if (args.len != 1 or args[0].isKind(.kwarg)) return CallCheck.badCall(self, args, pos, "`add` takes the one value whose hash it mixes in: `!h.add(x)`", .{});
    try ViewCheck.recordUse(self, CompatCheck.stripSigil(obj), .view);
    const arg = args[0];
    const saved_view = self.expect.view_arg;
    defer self.expect.view_arg = saved_view;
    self.expect.view_arg = arg;
    const ty = try ViewCheck.synthReadTemp(self, arg);
    if (ty == self.t().int_literal_id) try ViewCheck.defaultIntLiteral(self, arg);
    if (!self.isPoison(ty)) {
        const value = sema.unwrapViews(self.ctx, if (ty == self.t().int_literal_id) self.t().int_id else ty);
        switch (self.ctx.types.get(value)) {
            .type_var => |tv| if (!sema.hasBounds(self.ctx.symbols.items[self.ctx.localSym(tv)])) try ExprCheck.require(self, self.ctx.localSym(tv), .hashable, self.startOf(arg), "!h.add(x)"),
            else => {},
        }
        if (try sema.lacks(self.ctx, value, .Hash)) |lack| {
            if (try sema.reportStatedLack(self.ctx, self.startOf(arg), .Hash, lack, null)) {
                // Reported at the parameter.
            } else if (lack.own_eq) {
                try self.errAt(arg, "{s}", .{try sema.ownEqUnhashed(self.ctx, lack.ty)});
            } else try self.errAt(arg, "`!h.add(x)` takes a value that provides `Hash`, and `{s}` cannot be hashed{s}", .{ try self.tyName(value), try sema.lackDetail(self.ctx, self.ctx.arena.allocator(), value, .Hash, lack) });
        }
    }
    const hasher = try self.ctx.intern(.{ .write_view = try self.ctx.intern(.{ .nominal = self.ctx.builtins.hasher }) });
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{ hasher, ty }), .returns = self.t().void_id, .is_sub = true });
    try self.ctx.recordStringCall(callee, .hasher_add);
    return try noteMethod(self, callee, .write, self.t().void_id);
}

/// `!out.value(x)`: `x` written to a Printer as `print` shows a part of
/// another value, text in quotes. `x` is any value `print` takes, and
/// only read.
pub fn printerValue(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, pos: u32, args: []const Sexp) Error!TypeId {
    _ = obj_ty;
    if (!obj.isKind(.write)) try self.errAt(obj, "`value` writes the Printer: `!{s}.value(...)`", .{try ViewCheck.plainText(self, CompatCheck.stripSigil(obj))});
    if (args.len != 1 or args[0].isKind(.kwarg)) return CallCheck.badCall(self, args, pos, "`value` takes the one value it writes: `!out.value(x)`", .{});
    try ViewCheck.recordUse(self, CompatCheck.stripSigil(obj), .view);
    try checkFormatArgs(self, args, "`value`", "print");
    const arg_ty = self.ctx.typeOf(args[0]) orelse self.t().invalid_id;
    const printer = try self.ctx.intern(.{ .write_view = try self.ctx.intern(.{ .nominal = self.ctx.builtins.printer }) });
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{ printer, arg_ty }), .returns = self.t().void_id, .is_sub = true });
    try self.ctx.recordStringCall(callee, .printer_value);
    return try noteMethod(self, callee, .write, self.t().void_id);
}

/// Whether `obj_ty` has a data field `name`, here or in the module
/// that declares it.
pub fn hasDataField(self: *Checker, obj_ty: TypeId, name: []const u8) Error!bool {
    if (try sema.lookupDataField(self.ctx, obj_ty, name)) |_| return true;
    const decl = sema.nominalDecl(self.ctx, sema.unwrapAccess(self.ctx, obj_ty)) orelse return false;
    return (try CompatCheck.findDataField(self.ctx, decl.symbol().fields orelse &.{}, name)) != null;
}

/// `f.fraction()` and `f.exponent()`, the two halves of what C,
/// Python, and Go call `frexp`: the fraction, a float of the
/// self's type, and the exponent, an `Int`. Null when the
/// self is not a float.
pub fn frexpCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, value: TypeId, op: sema.ElemOp, method: []const u8, pos: u32, args: []const Sexp) Error!?TypeId {
    if (self.ctx.types.get(value) != .float) return null;
    if (ViewCheck.isSelfSigil(self, obj)) try ViewCheck.misplacedSigil(self, obj, method, "does not consume `self`");
    _ = try ViewCheck.readThrough(self, obj, obj_ty, value);
    const result = if (op == .fraction) value else self.t().int_id;
    if (args.len > 0) {
        try self.err(pos, "`{s}` takes no arguments; got {d}", .{ method, args.len });
        try CallCheck.synthArgs(self, args);
    }
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{value}), .returns = result, .is_sub = false });
    try self.ctx.recordElemCall(callee, .{ .op = op, .elem = result, .num = value });
    return result;
}

/// The methods of a float that compare it, `F32`'s as `Float`'s:
/// `x.min(y)` and `x.max(y)`, the smaller and the larger, where a NaN
/// loses to a number (IEEE 754 minimumNumber and maximumNumber, as
/// Zig's `@min` and `@max`); `x.clamp(lo, hi)`, `x` limited to
/// `lo..hi`; and `x.total_order(?y)`, the `Order` of IEEE 754
/// totalOrder, which orders every float, NaN too. Null when `method`
/// is none of them or self is not a float.
pub fn floatCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp) Error!?TypeId {
    const op = std.meta.stringToEnum(sema.ElemOp, method) orelse return null;
    if (!op.isFloat()) return null;
    var value = sema.unwrapViews(self.ctx, obj_ty);
    if (value == self.t().float_literal_id) value = self.t().float_id;
    if (self.ctx.types.get(value) != .float) return null;
    if (ViewCheck.isSelfSigil(self, obj)) try ViewCheck.misplacedSigil(self, obj, method, "does not consume `self`");
    _ = try ViewCheck.readThrough(self, obj, obj_ty, value);
    if (op == .total_order) {
        const order_ty = try self.ctx.intern(.{ .nominal = self.ctx.builtins.order });
        const view = try self.ctx.intern(.{ .read_view = value });
        try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{ view, view }), .returns = order_ty, .is_sub = false });
        try CallCheck.checkArgs(self, args, .{ .params = try self.ctx.dupeIds(&.{view}), .returns = order_ty, .is_sub = false }, .{ .names = &.{"other"} }, method, pos, .{ .has_self = true, .origins = .{ .result = 0, .stores = 0 }, .declared = &.{view} });
        try self.ctx.recordElemCall(callee, .{ .op = op, .elem = order_ty, .num = value });
        return order_ty;
    }
    const params: []const TypeId = if (op == .clamp) &.{ value, value } else &.{value};
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(if (op == .clamp) &.{ value, value, value } else &.{ value, value }), .returns = value, .is_sub = false });
    try CallCheck.checkArgs(self, args, .{ .params = try self.ctx.dupeIds(params), .returns = value, .is_sub = false }, .{}, method, pos, .{ .has_self = true, .origins = .{ .result = 0, .stores = 0 }, .declared = params });
    try self.ctx.recordElemCall(callee, .{ .op = op, .elem = value, .num = value });
    return value;
}

/// The unsigned integer type as wide as a float of `info`.
pub fn bitsType(self: *Checker, info: sema.FloatInfo) Error!TypeId {
    return self.ctx.intern(.{ .int = .{ .bits = if (info.bits == 32) 32 else 64, .signed = false } });
}

/// The functions of a number type: `Float.from_bits(u)`, the float
/// whose IEEE bits are the unsigned integer `u`, and `I32.wrap(x)`, an
/// integer converted to an integer type by keeping its low bits.
pub fn numberTypeCall(self: *Checker, callee: Sexp, obj: Sexp, target: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    if (self.isPoison(target)) return CallCheck.skipCall(self, args);
    const shown = CallCheck.sourceText(self, obj);
    const tt = self.ctx.types.get(target);
    const is_wrap = std.mem.eql(u8, method, "wrap");
    const is_bits = std.mem.eql(u8, method, "from_bits");
    const special: ?sema.ElemOp = if (tt == .float and std.mem.eql(u8, method, "nan")) .nan else if (tt == .float and std.mem.eql(u8, method, "inf")) .inf else null;
    if (special) |op| {
        if (ct) |b| return CallCheck.badCall(self, args, b, "`{s}` takes no compile-time arguments", .{method});
        if (args.len != 0) return CallCheck.badCall(self, args, pos, "`{s}.{s}()` takes no arguments; got {d}", .{ shown, method, args.len });
        try noteCallee(self, .{ .params = &.{}, .returns = target, .is_sub = false });
        try self.ctx.recordElemCall(callee, .{ .op = op, .elem = target, .num = target });
        return target;
    }
    if ((is_wrap and tt != .int) or (is_bits and tt != .float) or !(is_wrap or is_bits)) {
        const fns: []const u8 = if (tt == .int) "`wrap`" else "`from_bits`, `nan`, and `inf`";
        return CallCheck.badCall(self, args, pos, "`{s}` has no function `{s}`; its function is {s}, and its limits are `{s}.min` and `{s}.max`", .{ shown, method, fns, shown, shown });
    }
    if (ct) |b| return CallCheck.badCall(self, args, b, "`{s}` takes no compile-time arguments", .{method});
    if (args.len != 1 or args[0].isKind(.kwarg)) return CallCheck.badCall(self, args, pos, "`{s}.{s}(x)` takes one argument; got {d}", .{ shown, method, args.len });
    const arg = args[0];
    if (is_bits) {
        const u = try bitsType(self, tt.float);
        try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{u}), .returns = target, .is_sub = false });
        try self.ctx.recordElemCall(callee, .{ .op = .from_bits, .elem = u, .num = target });
        try ViewCheck.checkExpr(self, arg, u);
        return target;
    }
    var from = try ViewCheck.synthValue(self, arg);
    if (self.isPoison(from)) return target;
    if (!sema.isInteger(self.ctx, from)) {
        try self.errAt(arg, "`{s}.wrap(x)` takes an integer; convert a Float with `Int(x)` first", .{shown});
        return target;
    }
    if (from == self.t().int_literal_id) {
        try ViewCheck.defaultIntLiteral(self, arg);
        from = self.t().int_id;
    }
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{from}), .returns = target, .is_sub = false });
    try self.ctx.recordElemCall(callee, .{ .op = .wrap, .elem = from, .num = target });
    return target;
}

/// `Status.from_int(n)`: the variant of plain enum `enum_ty` whose
/// value is the integer `n`, or `none`.
pub fn enumFromIntCall(self: *Checker, callee: Sexp, enum_ty: TypeId, shown: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    const result = try self.ctx.intern(.{ .optional = enum_ty });
    if (ct) |b| return CallCheck.badCall(self, args, b, "`from_int` takes no compile-time arguments", .{});
    if (args.len != 1 or args[0].isKind(.kwarg)) return CallCheck.badCall(self, args, pos, "`{s}.from_int(n)` takes one argument, an integer; got {d}", .{ shown, args.len });
    const arg = args[0];
    var from = try ViewCheck.synthValue(self, arg);
    if (self.isPoison(from)) return result;
    if (!sema.isInteger(self.ctx, from)) {
        try self.errAt(arg, "`{s}.from_int(n)` takes an integer; `n` has type `{s}`", .{ shown, try self.tyName(from) });
        return result;
    }
    if (from == self.t().int_literal_id) {
        try ViewCheck.defaultIntLiteral(self, arg);
        from = self.t().int_id;
    }
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{from}), .returns = result, .is_sub = false });
    try self.ctx.recordElemCall(callee, .{ .op = .from_int, .elem = from, .num = enum_ty });
    return result;
}

/// Whether `obj` names the builtin type `Symbol`.
pub fn symbolNamed(self: *Checker, obj: Sexp) bool {
    return obj == .src and std.mem.eql(u8, self.text(obj), "Symbol") and CallCheck.lookupQuiet(self, obj) == null;
}

/// `Symbol.from_text(word)`: the symbol the program writes as
/// `:word`, or none. It is `Symbol`'s one function.
pub fn symbolTypeCall(self: *Checker, callee: Sexp, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    if (!std.mem.eql(u8, method, "from_text")) {
        return CallCheck.badCall(self, args, pos, "`Symbol` has no function `{s}`; its one function is `Symbol.from_text(word)`", .{method});
    }
    return fromTextCall(self, callee, self.t().symbol_id, "Symbol", pos, args, ct);
}

/// `Color.from_text(word)`: the variant of plain enum `enum_ty` named
/// `word`, or `none`, and `Symbol.from_text(word)` of `enum_ty`
/// `Symbol`. `word` is passed as to a parameter `?String`.
pub fn fromTextCall(self: *Checker, callee: Sexp, enum_ty: TypeId, shown: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    const result = try self.ctx.intern(.{ .optional = enum_ty });
    if (ct) |b| return CallCheck.badCall(self, args, b, "`from_text` takes no compile-time arguments", .{});
    if (args.len != 1) return CallCheck.badCall(self, args, pos, "`{s}.from_text(word)` takes one argument, a `?String`; got {d}", .{ shown, args.len });
    if (args[0].isKind(.kwarg)) return CallCheck.badCall(self, args, pos, "`{s}.from_text(word)` takes its argument by position", .{shown});
    const f: FunctionType = .{ .params = try self.ctx.dupeIds(&.{self.t().string_view_id}), .returns = result, .is_sub = false };
    try noteCallee(self, f);
    var scratch = std.heap.ArenaAllocator.init(self.ctx.allocator);
    defer scratch.deinit();
    try CallCheck.checkArgs(self, args, f, .{}, "from_text", pos, .{ .origins = try sema.defaultOrigins(self.ctx, scratch.allocator(), f) });
    try self.ctx.recordElemCall(callee, .{ .op = .from_text, .elem = self.t().string_view_id, .num = enum_ty });
    if (enum_ty != self.t().symbol_id) try self.ctx.recordTextTable(sema.nominalDecl(self.ctx, enum_ty).?);
    return result;
}

/// `v[i]` assigned, viewed, or taken: a lane of a vector is a part of
/// its value, not a place (docs/CORE.md §1, `sema.isLane`), as an
/// `Int`'s bits are. True when reported.
pub fn rejectLane(self: *Checker, e: Sexp, use: Checker.LaneUse) Error!bool {
    if (!sema.isLane(self.ctx, e)) return false;
    const v = try ViewCheck.plainText(self, ir.Index.object(e));
    const i = try ViewCheck.plainText(self, ir.Index.index(e));
    switch (use) {
        .assign => try self.errAt(e, "a lane of `{s}` is a value, not a place, so it is not assigned: write `{s} = {s}.with({s}, x)`", .{ v, v, v, i }),
        .read_viewed => try self.errAt(e, "a lane of `{s}` is a value, not a place, so it has no view: read it as `{s}[{s}]`", .{ v, v, i }),
        .write_viewed => try self.errAt(e, "a lane of `{s}` is a value, not a place, so it has no write view: change it with `{s} = {s}.with({s}, x)`", .{ v, v, v, i }),
        .take => try self.errAt(e, "a lane of `{s}` is a value, not a place, so it is not taken: read it as `{s}[{s}]`", .{ v, v, i }),
    }
    return true;
}

/// `e` as the self of a method, in parentheses unless it is a
/// name, a field, an element, or a call: `(v == 1).any()`.
pub fn selfText(self: *Checker, e: Sexp) Error![]const u8 {
    const shown = try ViewCheck.plainText(self, e);
    const bare = e == .src or e.isKind(.member) or e.isKind(.index) or e.isKind(.call);
    return if (bare) shown else self.ctx.arena.allocator().print("({s})", .{shown});
}

/// The mask a comparison of two `v`s gives: `Simd[Bool, n]`.
pub fn maskOf(self: *Checker, v: sema.SimdType) Error!TypeId {
    return self.ctx.intern(.{ .simd = .{ .elem = self.t().bool_id, .len = v.len } });
}

/// The built-in type of kind `tag` (`.simd`, `.slot`), declared as
/// `sym`, that `obj` names where a value could stand: `Simd[T, n]` or
/// `Slot[n]` (recorded as its instance), or an alias of one, also
/// another module's (`lib.Block`); null when it names none. Poison
/// after a diagnostic.
pub fn builtinTypeNamed(self: *Checker, obj: Sexp, sym_id: SymbolId, comptime tag: std.meta.Tag(Type)) Error!?TypeId {
    if (rig.isBracketList(obj)) {
        const target = (try CallCheck.instTarget(self, ir.get(obj, .object))) orelse return null;
        if (target != .generic or target.generic.id != sym_id) return null;
        return try CallCheck.typeInstance(self, obj, target.generic);
    }
    if (obj.isKind(.member)) {
        const id = (try CallCheck.moduleNamed(self, ir.Member.object(obj))) orelse return null;
        const found = CallCheck.foreignLookup(self, id, self.text(ir.Member.name(obj))) orelse return null;
        if (found.sym.kind != .type_alias or found.ctx.types.get(found.sym.ty) != tag) return null;
        return try sema.importType(self.ctx, found.ctx, found.sym.ty, found.module_id);
    }
    if (obj != .src) return null;
    const id = CallCheck.lookupQuiet(self, obj) orelse return null;
    const sym = self.ctx.symbols.items[id];
    if (sym.kind != .type_alias or self.ctx.types.get(sym.ty) != tag) return null;
    try self.ctx.recordName(obj, id);
    return sym.ty;
}

/// `Slot[n](x)`: no slot is made from other bits; reported.
pub fn slotMade(self: *Checker, callee: Sexp, st: TypeId, args: []const Sexp) Error!TypeId {
    if (self.isPoison(st)) return CallCheck.skipCall(self, args);
    const shown = try self.tyName(st);
    const n = if (self.ctx.types.get(st) == .slot) (if (sema.slotCount(self.ctx, self.ctx.types.get(st).slot)) |c| try self.ctx.arena.allocator().print("{d}", .{c}) else "`n`") else "`n`";
    return CallCheck.badCall(self, args, callee, "a `{s}` is made by `push`, by `{s}.of(i)`, or by a literal below {s}", .{ shown, shown, n });
}

/// `Slot[n].of(i)`: the slot `i` names, `Slot[n]?`, `none` unless
/// `0 <= i < n`. A slot type has no other function.
pub fn slotTypeCall(self: *Checker, callee: Sexp, st: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    if (self.isPoison(st)) return CallCheck.skipCall(self, args);
    const shown = try self.tyName(st);
    if (!std.mem.eql(u8, method, "of")) return CallCheck.badCall(self, args, pos, "`{s}` has no function `{s}`; its one function is `{s}.of(i)`, the slot an integer names", .{ shown, method, shown });
    if (ct) |b| return CallCheck.badCall(self, args, b, "`of` takes no compile-time arguments", .{});
    if (args.len != 1 or args[0].isKind(.kwarg)) return CallCheck.badCall(self, args, pos, "`{s}.of(i)` takes one argument, an integer; got {d}", .{ shown, args.len });
    const result = try self.ctx.intern(.{ .optional = st });
    var from = try ViewCheck.synthValue(self, args[0]);
    if (self.isPoison(from)) return result;
    if (!sema.isInteger(self.ctx, from)) {
        try self.errAt(args[0], "`{s}.of(i)` takes an integer; `i` has type `{s}`", .{ shown, try self.tyName(from) });
        return result;
    }
    if (from == self.t().int_literal_id) {
        try ViewCheck.defaultIntLiteral(self, args[0]);
        from = self.t().int_id;
    }
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{from}), .returns = result, .is_sub = false });
    try self.ctx.recordElemCall(callee, .{ .op = .from_int, .elem = from, .num = st });
    return result;
}

/// `Table()`: its slots, each `T()`; it takes no arguments.
pub fn checkTableConstruction(self: *Checker, call: Sexp) Error!void {
    const args = ir.Call.args(call);
    if (args.len == 0) return;
    try self.errAt(args[0], "`Table()` takes no arguments: a table holds its `n` slots, each `T()`, from the moment it is made", .{});
    try CallCheck.synthArgs(self, args);
}

/// `Simd[T, n].splat(x)`: a vector of type `vt` whose every lane is
/// `x`, a `T` or a literal that fits it. A vector type has no other
/// function.
pub fn simdTypeCall(self: *Checker, callee: Sexp, vt: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    if (self.isPoison(vt)) return CallCheck.skipCall(self, args);
    const v = self.ctx.types.get(vt).simd;
    if (!std.mem.eql(u8, method, "splat")) return CallCheck.badCall(self, args, pos, "`{s}` has no function `{s}`; a vector is made with `{s}.splat(x)`, every lane `x`, or from an array of its lanes, `{s}([...])`", .{ try self.tyName(vt), method, try self.tyName(vt), try self.tyName(vt) });
    if (ct) |b| return CallCheck.badCall(self, args, b, "`splat` takes no compile-time arguments", .{});
    if (args.len != 1 or args[0].isKind(.kwarg)) return CallCheck.badCall(self, args, pos, "`splat` takes one argument, the value of every lane; got {d}", .{args.len});
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{v.elem}), .returns = vt, .is_sub = false });
    try self.ctx.recordElemCall(callee, .{ .op = .splat, .elem = v.elem, .num = vt });
    try ViewCheck.checkExpr(self, args[0], v.elem);
    return vt;
}

/// `Simd[T, n](a)`: the vector of type `vt` whose lanes are the
/// elements of `a`, a `[n]T`.
pub fn simdConvert(self: *Checker, vt: TypeId, args: []const Sexp, pos: u32) Error!TypeId {
    if (self.isPoison(vt)) return CallCheck.skipCall(self, args);
    const v = self.ctx.types.get(vt).simd;
    const arr = try self.ctx.intern(.{ .array = .{ .elem = v.elem, .len = v.len } });
    if (args.len != 1 or args[0].isKind(.kwarg)) {
        _ = try CallCheck.badCall(self, args, pos, "`{s}(a)` makes a vector of the lanes of an array `{s}`; it takes one argument", .{ try self.tyName(vt), try self.tyName(arr) });
        return vt;
    }
    try ViewCheck.checkExpr(self, args[0], arr);
    return vt;
}

/// The methods of a vector (docs/SPEC.md, "Vectors"), which read the
/// self as a value and make a new one: `m.bits()`, a `U64` whose
/// bit `i` is lane `i` of mask `m`; `m.first()`, the index of its first
/// true lane, or `none`; `m.lanes()`, an iterator of its true lanes;
/// `m.any()` and `m.all()`;
/// `m.select(a, b)`, lane `i` of `a` where `m`'s is true and of `b`
/// where it is false; `v.array()`, the lanes as a `[n]T`; and
/// `v.with(i, x)`, a copy of `v` whose lane `i` is `x`; `t.lookup(idx)`,
/// lane `i` of table `t` at each index of `idx` (`lookupCall`); and
/// `v.lag[k](prev)` (`lagCall`). Null when self is no vector or
/// `method` none of them.
pub fn simdCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!?TypeId {
    const v = sema.simdOf(self.ctx, obj_ty) orelse return null;
    const op = std.meta.stringToEnum(sema.ElemOp, method) orelse return null;
    if (!op.isSimd() or op == .splat) return null;
    const vt = sema.unwrapViews(self.ctx, obj_ty);
    const mask_op = op == .bits or op == .first or op == .lanes or op == .any or op == .all or op == .select;
    if (mask_op and v.elem != self.t().bool_id) return try CallCheck.badCall(self, args, pos, "`{s}` is a method of a mask, `Simd[Bool, n]`, which a comparison gives; got `{s}`", .{ method, try self.tyName(vt) });
    if (ViewCheck.isSelfSigil(self, obj)) try ViewCheck.misplacedSigil(self, obj, method, "reads `self` as a value");
    _ = try ViewCheck.readThrough(self, obj, obj_ty, vt);
    if (op == .lag) {
        const b = ct orelse return try CallCheck.badCall(self, args, pos, "`lag` takes how many lanes back in brackets: `v.lag[1](prev)`", .{});
        return try lagCall(self, callee, vt, b, pos, args);
    }
    if (ct) |b| return try CallCheck.badCall(self, args, b, "`{s}` takes no compile-time arguments", .{method});
    const want: usize = switch (op) {
        .select, .with => 2,
        .lookup => 1,
        else => 0,
    };
    for (args) |a| if (a.isKind(.kwarg)) return try CallCheck.badCall(self, args, a, "`{s}` takes no keyword arguments", .{method});
    if (args.len != want) return try CallCheck.badCall(self, args, pos, "`{s}` takes {s}; got {d} argument{s}", .{ method, switch (op) {
        .select => "two arguments, the lanes where the mask is true and where it is false",
        .with => "two arguments, the lane's index and its new value",
        .lookup => "one argument, a `Simd[U8, n]` of indexes into the table",
        else => "no arguments",
    }, args.len, CompatCheck.plural(args.len) });
    if (op == .lookup) return try lookupCall(self, callee, obj, vt, args[0]);
    var elem = v.elem;
    const result: TypeId = switch (op) {
        .bits => try self.ctx.intern(.{ .int = .{ .bits = 64, .signed = false } }),
        .first => try self.ctx.intern(.{ .optional = self.t().int_id }),
        .lanes => blk: {
            const lanes = (try lanesType(self, pos)) orelse return self.t().invalid_id;
            elem = lanes;
            break :blk lanes;
        },
        .any, .all => self.t().bool_id,
        .array => try self.ctx.intern(.{ .array = .{ .elem = v.elem, .len = v.len } }),
        .with => vt,
        .select => blk: {
            const picked = (try selectOperands(self, args, v)) orelse return self.t().invalid_id;
            elem = self.ctx.types.get(picked).simd.elem;
            break :blk picked;
        },
        else => unreachable,
    };
    const params: []const TypeId = switch (op) {
        .with => &.{ vt, self.t().int_id, v.elem },
        .select => &.{ vt, result, result },
        else => &.{vt},
    };
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(params), .returns = result, .is_sub = false });
    try self.ctx.recordElemCall(callee, .{ .op = op, .elem = elem, .num = vt });
    if (op == .with) {
        try checkIndexArg(self, args[0], null);
        try checkLaneIndex(self, args[0], vt);
        try ViewCheck.checkExpr(self, args[1], v.elem);
    }
    return result;
}

/// The prelude's `Lanes`, the iterator `m.lanes()` gives: imported
/// under the hidden name every file that calls a `lanes` method uses
/// (`Parser.preludeUse`), or the prelude's own.
pub fn lanesType(self: *Checker, pos: u32) Error!?TypeId {
    for (self.ctx.imports) |imp| {
        if (!std.mem.eql(u8, imp.local_name, rig.builtin_binding_name)) continue;
        const id = imp.sema.moduleMember("Lanes") orelse break;
        return try self.ctx.intern(.{ .nominal = .{ .module_id = imp.module_id, .sym = id } });
    }
    if (std.mem.eql(u8, self.ctx.name, "std." ++ rig.builtin_module_name)) if (self.ctx.moduleMember("Lanes")) |id| return try self.ctx.intern(.{ .nominal = self.ctx.ref(id) });
    try self.err(pos, "`lanes` gives the built-in `Lanes`, which this module cannot reach", .{});
    return null;
}

/// `t.lookup(idx)`: a table `t` of 16, 32, or 64 `U8` lanes, and indexes
/// `idx`, a `Simd[U8, n]`; lane `i` of the result is `t[idx[i]]`, or 0
/// where `idx[i]` is past the table. The result's type is `idx`'s.
pub fn lookupCall(self: *Checker, callee: Sexp, obj: Sexp, vt: TypeId, arg: Sexp) Error!?TypeId {
    const byte = try ViewCheck.byteType(self);
    const v = self.ctx.types.get(vt).simd;
    const m = sema.simdLen(self.ctx, v);
    if (v.elem != byte or m == null or m.? < 16) {
        try self.errAt(obj, "`lookup` looks up bytes in a table of 16, 32, or 64 of them: a `Simd[U8, 16]`, `Simd[U8, 32]`, or `Simd[U8, 64]`; got `{s}`", .{try self.tyName(vt)});
        _ = try PatternCheck.synthExpr(self, arg);
        return self.t().invalid_id;
    }
    const at = try ViewCheck.synthOperandValue(self, arg);
    if (self.isPoison(at)) return self.t().invalid_id;
    const idx = sema.unwrapViews(self.ctx, at);
    const iv = sema.simdOf(self.ctx, idx);
    if (iv == null or iv.?.elem != byte) {
        try self.errAt(arg, "`lookup` takes its indexes as a `Simd[U8, n]`; got `{s}`", .{try self.tyName(at)});
        return self.t().invalid_id;
    }
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{ vt, idx }), .returns = idx, .is_sub = false });
    try self.ctx.recordElemCall(callee, .{ .op = .lookup, .elem = byte, .num = idx });
    return idx;
}

/// `cur.lag[k](prev)`: lane `i` is `cur[i - k]` for `i >= k`, and
/// `prev[n - k + i]` below, for vectors `cur` and `prev` of one type.
/// `k` is a constant integer from 1 to `n - 1`, checked now, so the
/// lane count must be known too.
pub fn lagCall(self: *Checker, callee: Sexp, vt: TypeId, b: Sexp, pos: u32, args: []const Sexp) Error!?TypeId {
    try self.ctx.recordInstance(b, .function);
    const given = sema.bracketArgs(b);
    if (given.len != 1) return try CallCheck.badCall(self, args, b, "`lag` takes one compile-time argument, how many lanes back: `v.lag[1](prev)`", .{});
    for (args) |a| if (a.isKind(.kwarg)) return try CallCheck.badCall(self, args, a, "`lag` takes no keyword arguments", .{});
    if (args.len != 1) return try CallCheck.badCall(self, args, pos, "`lag` takes one argument, the vector before this one; got {d} argument{s}", .{ args.len, CompatCheck.plural(args.len) });
    const n = sema.simdLen(self.ctx, self.ctx.types.get(vt).simd);
    const mark = self.ctx.diagnostics.items.len;
    try self.checkCtValue(given[0], self.t().int_id, 0, "lag");
    if (self.ctx.diagnostics.items.len == mark) {
        const names: resolve.ConstNames = .{ .ctx = self.ctx, .scope = self.scope, .type_params = self.nominal.type_params };
        const k: ?Wide = switch (sema.constIntBy(self.ctx, given[0], names)) {
            .value => |c| c,
            else => null,
        };
        if (k == null and try self.perTarget(given[0], "the number of lanes `lag` takes")) {
            // Reported.
        } else if (k == null or n == null) {
            try self.errAt(given[0], "`lag` takes a constant number of lanes, on a vector whose lane count is known where it is checked; got `{s}` on a `{s}`", .{ CallCheck.sourceText(self, given[0]), try self.tyName(vt) });
        } else if (k.? < 1 or k.? >= n.?) {
            try self.errAt(given[0], "`lag` of a `{s}` takes 1 to {d} lanes; got `{d}`", .{ try self.tyName(vt), n.? - 1, k.? });
        }
    }
    try ViewCheck.checkExpr(self, args[0], vt);
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{ vt, vt }), .returns = vt, .is_sub = false });
    try self.ctx.recordElemCall(callee, .{ .op = .lag, .elem = self.ctx.types.get(vt).simd.elem, .num = vt });
    return vt;
}

/// A constant lane index of a vector of type `vt` is checked against
/// its lane count now; any other when the program runs.
pub fn checkLaneIndex(self: *Checker, index: Sexp, vt: TypeId) Error!void {
    const n = sema.simdLen(self.ctx, self.ctx.types.get(vt).simd) orelse return;
    const i = ExprCheck.constInt(self, index) orelse return;
    if (i >= 0 and i < n) return;
    try self.errAt(index, "lane `{d}` is out of range for `{s}`, whose lanes are 0 to {d}", .{ i, try self.tyName(vt), n - 1 });
}

/// The operands of `m.select(a, b)` for a mask of `mask`'s lanes:
/// two vectors of one type with as many lanes, or a vector and a
/// scalar of its lane type or a literal that fits it, or two scalars
/// of one lane type; each scalar stands for every lane (a splat). The
/// vector type they give, or null after a diagnostic.
pub fn selectOperands(self: *Checker, args: []const Sexp, mask: sema.SimdType) Error!?TypeId {
    const a = try ViewCheck.synthOperandValue(self, args[0]);
    const b = try ViewCheck.synthOperandValue(self, args[1]);
    if (self.isPoison(a) or self.isPoison(b)) return null;
    const lit = [2]bool{ isLiteralType(self, a), isLiteralType(self, b) };
    if (sema.simdOf(self.ctx, a) != null and sema.simdOf(self.ctx, b) != null and a != b) {
        try self.errAt(args[0], "`select` picks lanes from two vectors of one type; got `{s}` and `{s}`", .{ try self.tyName(a), try self.tyName(b) });
        return null;
    }
    const vt: TypeId = if (sema.simdOf(self.ctx, a) != null) a else if (sema.simdOf(self.ctx, b) != null) b else blk: {
        // Two scalars: the lane type is theirs, an `Int` or a `Float`
        // for two literals.
        const lane = if (!lit[0]) a else if (!lit[1]) b else if (a == self.t().float_literal_id or b == self.t().float_literal_id) self.t().float_id else self.t().int_id;
        if (!sema.isLaneType(self.ctx, lane)) {
            try self.errAt(args[if (lit[0]) 1 else 0], "`select` picks lanes of a number or `Bool`; got `{s}`", .{try self.tyName(lane)});
            return null;
        }
        break :blk try self.ctx.intern(.{ .simd = .{ .elem = lane, .len = mask.len } });
    };
    const v = self.ctx.types.get(vt).simd;
    if (v.len != mask.len) {
        try self.errAt(args[0], "`select` on a mask of {s} lanes picks from vectors of as many lanes; got `{s}`", .{ try self.tyName(mask.len), try self.tyName(vt) });
        return null;
    }
    for (args, [2]TypeId{ a, b }) |arg, ty| {
        if (ty == vt) continue;
        if (!try splatOperand(self, arg, ty, vt, "select")) return null;
    }
    return vt;
}

/// Whether `ty` is an untyped literal's.
pub fn isLiteralType(self: *Checker, ty: TypeId) bool {
    return ty == self.t().int_literal_id or ty == self.t().float_literal_id;
}

/// `operand`, of type `ty`, where a vector of type `vt` goes: a scalar
/// of its lane type, or a literal that fits it, stands for every lane
/// (recorded as a splat). False after a diagnostic.
pub fn splatOperand(self: *Checker, operand: Sexp, ty: TypeId, vt: TypeId, op: []const u8) Error!bool {
    const v = self.ctx.types.get(vt).simd;
    if (isLiteralType(self, ty)) {
        const mark = self.ctx.diagnostics.items.len;
        try ViewCheck.checkExpr(self, operand, v.elem);
        if (self.ctx.diagnostics.items.len != mark) return false;
    } else if (ty != v.elem) {
        const hint = if (sema.isLaneType(self.ctx, ty)) try self.ctx.arena.allocator().print("; a scalar beside a vector is of its lane type, `{s}`", .{try self.tyName(v.elem)}) else "";
        try self.errAt(operand, "operator `{s}` operands have different types `{s}` and `{s}`{s}", .{ op, try self.tyName(vt), try self.tyName(ty), hint });
        return false;
    }
    try self.ctx.recordSplat(operand, vt);
    return true;
}

/// A lane-wise operator `(op left right)` with a vector operand: both
/// of one `Simd[T, n]`, or one a scalar of its lane type `T`, or a
/// literal that fits it, which stands for every lane (`splatOperand`).
/// `req` applies to `T` as it would to two scalars; `&`, `|`, and `^`
/// combine masks too. `a` and `b` are the operands' value types. The
/// vector's type, or poison after a diagnostic.
pub fn simdOperands(self: *Checker, e: Sexp, op: []const u8, req: Requirement, a: TypeId, b: TypeId) Error!TypeId {
    const operands = [2]Sexp{ ir.get(e, .left), ir.get(e, .right) };
    const vt = if (sema.simdOf(self.ctx, a) != null) a else b;
    const v = self.ctx.types.get(vt).simd;
    const head = e.kind().?;
    switch (head) {
        .@"/", .@"%" => {
            try self.errAt(operands[0], "operator `{s}` does not take a `Simd`: a vector has `+`, `-`, `*`, their wrapping and saturating forms, `&`, `|`, `^`, the shifts, and the comparisons", .{op});
            return self.t().invalid_id;
        },
        else => {},
    }
    const bitwise = head == .@"&" or head == .@"|" or head == .@"^";
    const lane_ok = switch (req) {
        .integer => sema.isInteger(self.ctx, v.elem) or (bitwise and v.elem == self.t().bool_id),
        .equatable => true,
        else => sema.isNumeric(self.ctx, v.elem),
    };
    if (!lane_ok) {
        if (req == .ordered) {
            try self.errAt(operands[0], "operator `{s}` orders numbers; the lanes of `{s}` are not", .{ op, try self.tyName(vt) });
        } else try self.errAt(operands[0], "operator `{s}` requires {s} operands; got `{s}`", .{ op, if (req == .integer) "integer" else "numeric", try self.tyName(vt) });
        return self.t().invalid_id;
    }
    for (operands, [2]TypeId{ a, b }) |operand, ty| {
        if (ty == vt) continue;
        if (sema.simdOf(self.ctx, ty) != null) {
            try self.errAt(operands[0], "operator `{s}` operands have different types `{s}` and `{s}`", .{ op, try self.tyName(a), try self.tyName(b) });
            return self.t().invalid_id;
        }
        if (!try splatOperand(self, operand, ty, vt, op)) return self.t().invalid_id;
    }
    return vt;
}

/// `v op= x` of a vector `v` of type `vt`: the lane-wise operator, as
/// `v = v op x` (`simdOperands`).
pub fn simdCompound(self: *Checker, op: Tag, spelled: []const u8, vt: TypeId, rhs: Sexp, pos: u32) Error!void {
    const v = self.ctx.types.get(vt).simd;
    const req: Requirement = switch (op) {
        .@"+", .@"-", .@"*" => .numeric,
        .@"&", .@"|", .@"^", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>" => .integer,
        else => {
            try self.err(pos, "`{s}` does not take a `Simd`: a vector has `+=`, `-=`, `*=`, their wrapping and saturating forms, `&=`, `|=`, `^=`, and the shifts", .{spelled});
            _ = try PatternCheck.synthExpr(self, rhs);
            return;
        },
    };
    const bitwise = op == .@"&" or op == .@"|" or op == .@"^";
    const lane_ok = if (req == .integer) sema.isInteger(self.ctx, v.elem) or (bitwise and v.elem == self.t().bool_id) else sema.isNumeric(self.ctx, v.elem);
    if (!lane_ok) {
        try self.err(pos, "`{s}` requires {s} lanes; got `{s}`", .{ spelled, if (req == .integer) "integer" else "numeric", try self.tyName(vt) });
        _ = try PatternCheck.synthExpr(self, rhs);
        return;
    }
    if (op == .@"<<" or op == .@"<<%" or op == .@">>") {
        _ = try ExprCheck.checkShiftAmount(self, rhs, v.elem, spelled);
        return;
    }
    const ty = try ViewCheck.synthOperandValue(self, rhs);
    if (self.isPoison(ty) or ty == vt) return;
    if (sema.simdOf(self.ctx, ty) != null) return ViewCheck.mismatch(self, rhs, vt, ty);
    _ = try splatOperand(self, rhs, ty, vt, spelled);
}

/// A mask where a `Bool` is expected: it is no `Bool`, so a condition,
/// `and`, `or`, and `not` reject it, each with the form that reduces
/// or combines it.
pub fn maskAsBool(self: *Checker, e: Sexp, actual: TypeId) Error!void {
    const shown = try ViewCheck.plainText(self, e);
    const recv = try selfText(self, e);
    const ty = try self.tyName(actual);
    if (CompatCheck.sameSite(e, self.expect.not_operand)) return self.errAt(e, "`not` takes a Bool, and `{s}` is a mask, `{s}`: write `{s}.not()` for its lanes flipped, or reduce it with `.any()` or `.all()`", .{ shown, ty, recv });
    if (self.expect.logic_op.len > 0 and (CompatCheck.sameSite(e, self.expect.logic_operands[0]) or CompatCheck.sameSite(e, self.expect.logic_operands[1]))) {
        const sym: []const u8 = if (std.mem.eql(u8, self.expect.logic_op, "and")) "&" else "|";
        return self.errAt(e, "`{s}` takes Bools, and `{s}` is a mask, `{s}`: combine masks lane by lane with `{s}`, each in parentheses, or reduce each with `.any()` or `.all()`", .{ self.expect.logic_op, shown, ty, sym });
    }
    if (CompatCheck.sameSite(e, self.expect.ternary_cond)) return self.errAt(e, "`{s}` is a mask, `{s}`, not a `Bool`: a ternary runs one side, so pick lanes with `{s}.select(a, b)`, or reduce the mask with `.any()` or `.all()`", .{ shown, ty, recv });
    try self.errAt(e, "`{s}` is a mask, `{s}`, not a `Bool`: write `{s}.any()` or `{s}.all()`", .{ shown, ty, recv, recv });
}

/// `arg`, filling a duration parameter of type `param` (`sema.duration`):
/// a number of units of `unit` nanoseconds when a unit's keyword gives
/// one, else of seconds, or, with no keyword, a `Duration` value. A
/// number is recorded for emit, which makes the `Duration` it is, or
/// the `Int` of nanoseconds an `Int` parameter takes (`time.after`,
/// `per:`). A constant is checked to be a finite number a `Duration`
/// holds, and, where the callee waits it, not to be negative.
///
/// A `part` of a duration given by several units' keywords
/// (`sema.DurationParts`) is recorded as the `Int` of nanoseconds it
/// counts, which emit adds up; its sign is the sum's to check
/// (`checkDurationSum`), so the nanoseconds of a constant part are
/// returned, null for any other.
pub fn checkDurationArg(self: *Checker, arg: Sexp, param: TypeId, unit: ?i64, info: Checker.ParamInfo, part: bool) Error!?i128 {
    try ViewCheck.recordUse(self, arg, .take);
    const ty = try PatternCheck.synthExpr(self, arg);
    if (self.isPoison(ty)) return null;
    const shown = try ViewCheck.plainText(self, arg);
    const value = ExprCheck.canonical(self, ty);
    // A fallible value, `time.duration(seconds: n)` with no `!`, is
    // said once, by the call's own error.
    if (self.ctx.types.get(value) == .fallible) return null;
    const float = value == self.t().float_id;
    const target = sema.durationParam(self.ctx, param);
    if (!float and value != self.t().int_id) {
        if (sema.isDurationType(self.ctx, sema.unwrapOptionals(self.ctx, value)) or self.ctx.types.get(value) == .none_literal) {
            if (unit) |u| {
                try self.errAt(arg, "a unit's keyword takes a number, and `{s}` is a `{s}` already: write it with no keyword, not `{s}: {s}`", .{ shown, try self.tyName(ty), sema.duration.unitName(u), shown });
                return null;
            }
            if (target != null) {
                try ViewCheck.checkActual(self, arg, ty, param);
                try ViewCheck.recordLift(self, arg, ty, param);
                return null;
            }
            if (sema.isDurationType(self.ctx, value)) {
                try self.ctx.recordDuration(arg, .{ .unit_ns = 0 });
                return null;
            }
        }
        try self.errAt(arg, "a duration is a number of seconds, a unit's keyword and a number, `ms: 40`, or a `time.Duration`, and `{s}` is a `{s}`{s}", .{ shown, try self.tyName(ty), if (sema.isNumeric(self.ctx, ty)) try std.fmt.allocPrint(self.ctx.arena.allocator(), ": write `Int({s})`", .{shown}) else "" });
        return null;
    }
    const unit_ns = unit orelse sema.duration.second_ns;
    const unit_name = if (unit != null) sema.duration.unitName(unit_ns) else "seconds";
    var known: ?i128 = null;
    if (!float) {
        if (ExprCheck.constInt(self, arg)) |v| {
            const wide = v * unit_ns;
            if (!durationHolds(wide)) {
                try self.errAt(arg, "`{s}` {s} is beyond a `Duration`'s range, about 292 billion years either way", .{ shown, unit_name });
                return null;
            }
            if (v < 0 and info.waits and !part) {
                try negativeWait(self, arg, shown, try std.fmt.allocPrint(self.ctx.arena.allocator(), "{d}", .{v}));
                return null;
            }
            known = @intCast(wide);
        }
    } else switch (floatConst(self, arg)) {
        .value => |v| {
            const ns = sema.floatToNs(v, unit_ns).?;
            if (!durationHolds(ns)) {
                try self.errAt(arg, "`{s}` {s} is beyond a `Duration`'s range, about 292 billion years either way", .{ shown, unit_name });
                return null;
            }
            if (v < 0 and info.waits and !part) {
                try negativeWait(self, arg, shown, try std.fmt.allocPrint(self.ctx.arena.allocator(), "{d}", .{v}));
                return null;
            }
            known = ns;
        },
        .not_finite => {
            try self.errAt(arg, "a duration is a finite number, and `{s}` is not", .{shown});
            return null;
        },
        .unknown => {},
    }
    // How the number becomes a `Duration` (docs/design/datetime.md
    // §5.2): a constant, checked above, and an `Int` of a unit below
    // a second always fit; any other number known only as the program
    // runs can leave the range, so a wait clamps an `Int` and refuses
    // a `Float`, a call that can fail joins the failure to its own,
    // and anywhere else the conversion is to be written.
    const how: sema.DurationHow = if (known != null or (!float and sema.duration.totalInt(unit_ns))) .total else if (info.waits) blk: {
        if (float) {
            const form = if (unit != null) try std.fmt.allocPrint(self.ctx.arena.allocator(), "{s}: {s}", .{ unit_name, shown }) else shown;
            try self.errAt(arg, "a wait takes no `Float` known only as the program runs, which may not be finite: make the duration first, {s}, and pass that", .{try durationFix(self, form)});
            return null;
        }
        break :blk .clamped;
    } else if (part) .total else if (info.fold) |into| .{ .folded = into } else {
        const form = if (unit != null) try std.fmt.allocPrint(self.ctx.arena.allocator(), "{s}: {s}", .{ unit_name, shown }) else shown;
        const why = if (float) "is a `Float`, which may not be finite or may be" else "can be";
        try self.errAt(arg, "`{s}` {s} beyond a `Duration`'s range as the program runs, and {s}: make the duration first, {s}, and pass that", .{ form, why, noFold(self), try durationFix(self, form) });
        return null;
    };
    if (part) {
        // A part is an `I128` of nanoseconds; a `Float` known only as
        // the program runs fails, as the sum does, where the sum may
        // (`checkArgs`).
        const part_how: sema.DurationHow = if (known == null and float) (if (info.fold) |into| .{ .folded = into } else .total) else .total;
        try self.ctx.recordDuration(arg, .{ .unit_ns = unit_ns, .float = float, .part = true, .how = part_how });
        return known;
    }
    const opt = if (target != null and !sema.isDurationType(self.ctx, param)) param else sema.type_invalid;
    try self.ctx.recordDuration(arg, .{ .unit_ns = unit_ns, .float = float, .ty = target orelse sema.type_invalid, .opt = opt, .how = how });
    return known;
}

/// The fix that makes a duration form's conversion visible: passing
/// its failure on, `time.duration(minutes: n)!`, where the function
/// being checked can, else handling it.
pub fn durationFix(self: *Checker, form: []const u8) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    if (self.body.fail_to == .caller) return std.fmt.allocPrint(a, "`time.duration({s})!`", .{form});
    return std.fmt.allocPrint(a, "`time.duration({s}) catch ...`, handling its failure", .{form});
}

/// Why a duration form that can fail joins no failure in the call
/// being checked: it cannot fail, or it is a task's, whose arguments
/// are made as it starts.
pub fn noFold(self: *Checker) []const u8 {
    if (self.expect.current_call) |call| if (ir.Call.task(call) != .nil) return "this call cannot fail, a task's arguments being made as it starts";
    return "this call cannot fail";
}

/// Whether a duration form among `args` of `call` joins the call's
/// failure (`sema.DurationHow.folded`).
pub fn formFolds(self: *Checker, call: Sexp, args: []const Sexp) bool {
    for (args) |a| {
        const v = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
        if (self.ctx.durationOf(v)) |d| if (d.how == .folded) return true;
    }
    if (self.ctx.callSlotsOf(call)) |slots| for (slots) |sl| switch (sl) {
        .parts => |p| if (p.how == .folded) return true,
        else => {},
    };
    return false;
}

/// Whether `ns` nanoseconds is within a `Duration`'s range: whole
/// seconds within ±(2^63 - 1), symmetric (docs/design/datetime.md
/// §5.1).
pub fn durationHolds(ns: Wide) bool {
    const limit: Wide = @as(Wide, std.math.maxInt(i64)) * 1_000_000_000 + 999_999_999;
    return ns >= -limit and ns <= limit;
}

/// The error set a duration form that can fail joins in a call of a
/// function returning `returns` (docs/design/datetime.md §5.2): the
/// callee's own set when it has members `range` and `invalid`; for
/// a callee that may fail with any error, std.datetime's
/// `DateTimeError` for its own functions (`datetime`) and std.time's
/// `TimeError` for every other; none for a callee that cannot fail
/// or whose set has no such members.
pub fn durationFold(self: *Checker, returns: TypeId, datetime: bool) ?sema.FoldInto {
    const fl = switch (self.ctx.types.get(returns)) {
        .fallible => |x| x,
        else => return null,
    };
    if (fl.set == self.t().any_error_id) return if (datetime) .{ .module = "std.datetime", .set = "DateTimeError" } else .{ .module = "std.time", .set = "TimeError" };
    if (sema.isSetParam(self.ctx, fl.set)) return null;
    var leaves: std.ArrayList(sema.SetKey) = .empty;
    sema.errorSetLeaves(self.ctx, fl.set, &leaves, self.ctx.arena.allocator()) catch return null;
    for (leaves.items) |key| {
        var range = false;
        var invalid = false;
        for (sema.setMembers(key)) |m| {
            if (!m.is_variant) continue;
            range = range or std.mem.eql(u8, m.name, "range");
            invalid = invalid or std.mem.eql(u8, m.name, "invalid");
        }
        if (range and invalid) return .{ .module = if (key.ctx.is_root) "" else key.ctx.name, .set = key.ctx.symbols.items[key.sym].name };
    }
    return null;
}

/// The sum of a duration's parts (`sema.DurationParts`), `ns`, when
/// every part is a constant: one a `Duration` holds and, where the
/// callee waits it, not negative. Said at `at`, the first part, of
/// every unit the call's `keyword` arguments give.
pub fn checkDurationSum(self: *Checker, at: Sexp, keyword: []const Sexp, ns: i128, info: Checker.ParamInfo) Error!void {
    if (!durationHolds(ns))
        return self.errAt(at, "`{s}` is beyond a `Duration`'s range, about 292 billion years either way", .{try unitsText(self, keyword)});
    if (ns < 0 and info.waits) try negativeWait(self, at, try unitsText(self, keyword), try friendlyNs(self.ctx.arena.allocator(), @intCast(ns)));
}

/// The units' keywords among `keyword`, as written: `hours: 1,
/// minutes: 30`.
pub fn unitsText(self: *Checker, keyword: []const Sexp) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = self.ctx.arena.allocator();
    for (keyword) |kw| {
        if (!kw.isKind(.kwarg) or sema.duration.unitNs(self.text(ir.Kwarg.name(kw))) == null) continue;
        if (out.items.len > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, try ViewCheck.plainText(self, kw));
    }
    return out.items;
}

/// `ns` nanoseconds as `print` shows a `Duration`: `-30m`, `1h 30m`,
/// `1s 500ms`.
pub fn friendlyNs(a: std.mem.Allocator, ns: i64) Error![]const u8 {
    if (ns == 0) return "0s";
    var out: std.ArrayList(u8) = .empty;
    if (ns < 0) try out.append(a, '-');
    var rest: u64 = @abs(ns);
    const labels = [_][]const u8{ "h", "m", "s", "ms", "us", "ns" };
    for (sema.duration.units, labels) |u, label| {
        const per: u64 = @intCast(u[1]);
        const n = rest / per;
        rest %= per;
        if (n == 0) continue;
        if (out.items.len > 1 or (out.items.len == 1 and out.items[0] != '-')) try out.append(a, ' ');
        try out.print(a, "{d}{s}", .{ n, label });
    }
    return out.items;
}

/// A negative constant, `value` as Rig computes it, given to a wait
/// (`ParamInfo.waits`).
pub fn negativeWait(self: *Checker, arg: Sexp, shown: []const u8, value: []const u8) Error!void {
    if (std.mem.eql(u8, std.mem.trim(u8, shown, "() "), value) or CompatCheck.constFloatOf(self.ctx.source, arg) != null)
        return self.errAt(arg, "a wait of `{s}` is negative: a constant wait is zero or more", .{shown});
    try self.errAt(arg, "a wait of `{s}` is negative, {s}: a constant wait is zero or more", .{ shown, value });
}

/// A constant `Float` as Rig computes it (`FloatConst`): number
/// literals, a float type's limit, `Float.inf()` and `Float.nan()`,
/// a binding whose value is constant (`const_floats`, `const_ints`),
/// and the arithmetic of these, each operation in `F64`; as the one
/// classifier of an integer constant (`sema.constIntOf`) does for an
/// `Int`.
pub fn floatConst(self: *Checker, e: Sexp) CompatCheck.FloatConst {
    if (CompatCheck.isNotFinite(self.ctx.source, e)) return .not_finite;
    switch (e) {
        .src => {
            const lit = identAt(self.ctx.source, e) orelse return .unknown;
            if (sema.isFloatLiteralText(lit)) {
                const v = CompatCheck.floatLiteralValue(lit);
                return if (std.math.isFinite(v)) .{ .value = v } else .not_finite;
            }
            if (sema.isIntLiteralText(lit)) return .{ .value = CompatCheck.wideToFloat(f64, std.fmt.parseInt(Wide, lit, 0) catch return .unknown) };
            const id = self.ctx.symbolOf(e) orelse return .unknown;
            if (self.ctx.const_floats.get(id)) |v| return .{ .value = v };
            if (self.ctx.const_ints.get(id)) |c| return .{ .value = CompatCheck.wideToFloat(f64, c.value) };
            return .unknown;
        },
        .list => {
            const h = e.kind() orelse return .unknown;
            if (h == .member) return if (CompatCheck.floatLimit(f64, self.ctx.source, e)) |v| .{ .value = v } else .unknown;
            if (h == .neg) return switch (floatConst(self, ir.Neg.operand(e))) {
                .value => |v| .{ .value = -v },
                else => |o| o,
            };
            switch (h) {
                .@"+", .@"-", .@"*", .@"/", .@"%" => {},
                else => return .unknown,
            }
            const a = floatConst(self, ir.get(e, .left));
            const b = floatConst(self, ir.get(e, .right));
            if (a == .unknown or b == .unknown) return .unknown;
            if (a == .not_finite or b == .not_finite) return .not_finite;
            const v = CompatCheck.floatOp(f64, h, a.value, b.value);
            return if (std.math.isFinite(v)) .{ .value = v } else .not_finite;
        },
        else => return .unknown,
    }
}

/// A keyword no parameter of `callee`, which takes a duration, is
/// named, and no unit nor length of the calendar (`calendarKeyword`):
/// a spelling of `seconds:`, or neither.
pub fn badDurationKeyword(self: *Checker, at: Sexp, kname: []const u8, value: Sexp, callee: []const u8, option: ?[]const u8) Error!void {
    if (CompatCheck.isSecondsName(kname)) return self.errAt(at, "`{s}` has no parameter `{s}`; did you mean `seconds: {s}`?", .{ callee, kname, try ViewCheck.plainText(self, value) });
    // A duration with a default is an option, given by its name.
    if (option) |name| return self.errAt(at, "`{s}` has no parameter `{s}`; its duration is an option, given by name, `{s}: {s}`, or by units' keywords, `ms: 40` or `minutes: 1, seconds: 30`, from `ns:` to `hours:`", .{ callee, kname, name, try ViewCheck.plainText(self, value) });
    try self.errAt(at, "`{s}` has no parameter `{s}`; a duration is written bare in seconds, `{s}(2)`, or with units' keywords, `ms: 40` or `minutes: 1, seconds: 30`, from `ns:` to `hours:`", .{ callee, kname, callee });
}

/// The hours of `value` days or weeks, `per` hours each, as a
/// duration's `hours:` writes them: the number when it is a constant
/// that comes out whole, else the product, `24 * n`.
pub fn calendarHours(self: *Checker, value: Sexp, per: i64) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    if (ExprCheck.constInt(self, value)) |n| if (std.math.cast(i64, n)) |k| if (std.math.mul(i64, k, per) catch null) |h| return std.fmt.allocPrint(a, "{d}", .{h});
    if (CompatCheck.constFloatOf(self.ctx.source, value)) |v| {
        const h = v * @as(f64, @floatFromInt(per));
        if (h == @trunc(h) and @abs(h) < 0x1p53) return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(h))});
    }
    const shown = try ViewCheck.plainText(self, value);
    const simple = for (shown) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '@' or c == '(' or c == ')')) break false;
    } else true;
    return if (simple) std.fmt.allocPrint(a, "{d} * {s}", .{ per, shown }) else std.fmt.allocPrint(a, "{d} * ({s})", .{ per, shown });
}

/// `days:` or `weeks:` where a duration is taken, said once for the
/// call with the fix for every unit its `keyword` arguments give: the
/// days, the weeks and any `hours:` become one `hours:` where the first
/// of them stood (`calendarHours`), the other units as written. On an
/// `Instant`'s `add` or `checked_add` (`zoneless`, its name) a day on
/// the clock is a zone's, which the message says before the exact
/// hours.
pub fn calendarKeyword(self: *Checker, at: Sexp, kname: []const u8, keyword: []const Sexp, zoneless: ?[]const u8) Error!void {
    const days = std.mem.eql(u8, kname, "days");
    if (zoneless) |method| {
        try self.errAt(at, "an `Instant` has no calendar, so `{s}` takes no `{s}:`: a {s} on the clock is a zone's; write `{s}`, exactly {d} hours {s}", .{ method, kname, if (days) "day" else "week", try calendarFix(self, keyword), @as(i64, if (days) 24 else 168), if (days) "a day" else "a week" });
        return;
    }
    try self.errAt(at, "a duration takes no `{s}:`, since a day is not always 24 hours: write `{s}`, exactly {d} hours {s}", .{ kname, try calendarFix(self, keyword), @as(i64, if (days) 24 else 168), if (days) "a day" else "a week" });
}

/// The units of `keyword` with its `days:`, `weeks:` and `hours:` as one
/// `hours:` (`calendarKeyword`): `hours: 26, minutes: 30`.
pub fn calendarFix(self: *Checker, keyword: []const Sexp) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    // The hours of each, and their sum while each is a whole constant.
    var terms: std.ArrayList([]const u8) = .empty;
    var total: ?i64 = 0;
    for (keyword) |kw| {
        const name = self.text(ir.Kwarg.name(kw));
        const per: i64 = if (std.mem.eql(u8, name, "days")) 24 else if (std.mem.eql(u8, name, "weeks")) 168 else if (std.mem.eql(u8, name, "hours")) 1 else continue;
        const term = if (per == 1) try ViewCheck.plainText(self, ir.Kwarg.value(kw)) else try calendarHours(self, ir.Kwarg.value(kw), per);
        try terms.append(a, term);
        const n = std.fmt.parseInt(i64, term, 10) catch null;
        total = if (total != null and n != null) std.math.add(i64, total.?, n.?) catch null else null;
    }
    const hours = if (total) |sum| try std.fmt.allocPrint(a, "{d}", .{sum}) else try std.mem.join(a, " + ", terms.items);
    var fix: std.ArrayList(u8) = .empty;
    var placed = false;
    for (keyword) |kw| {
        const name = self.text(ir.Kwarg.name(kw));
        const hourly = sema.duration.isCalendar(name) or std.mem.eql(u8, name, "hours");
        if (!hourly and sema.duration.unitNs(name) == null) continue;
        if (hourly and placed) continue;
        if (fix.items.len > 0) try fix.appendSlice(a, ", ");
        if (hourly) {
            try fix.print(a, "hours: {s}", .{hours});
            placed = true;
        } else try fix.appendSlice(a, try ViewCheck.plainText(self, kw));
    }
    return fix.items;
}

pub fn checkArg(self: *Checker, arg: Sexp, f: FunctionType, i: usize, views: bool) Error!void {
    const saved = self.expect.viewed_temp;
    const saved_callable = self.expect.viewed_callable;
    const saved_kept = self.expect.callable_kept;
    const saved_view = self.expect.view_arg;
    defer {
        self.expect.view_arg = saved_view;
        self.expect.viewed_temp = saved;
        self.expect.viewed_callable = saved_callable;
        self.expect.callable_kept = saved_kept;
    }
    self.expect.viewed_temp = if (views) arg else .nil;
    self.expect.view_arg = arg;
    self.expect.slot.value = arg;
    self.expect.slot.declared = if (i < self.expect.slot.params.len) self.expect.slot.params[i] else f.params[i];
    // A closure literal lives for the call, so the call's result may
    // not hold it.
    const kept = sema.holdsCallable(self.ctx, f.returns);
    self.expect.viewed_callable = if (kept) .nil else arg;
    self.expect.callable_kept = if (kept) arg else .nil;
    try ViewCheck.checkExpr(self, arg, f.params[i]);
    try checkViewsVisibly(self, arg, f.params[i], "the call writes through");
}

/// A write view a binding holds is passed on to a `!T` visibly, `!w`,
/// as an owned value is: the self of the view passed on writes through
/// it. (A read view is passed on bare.)
pub fn checkViewsVisibly(self: *Checker, arg: Sexp, expected: TypeId, what: []const u8) Error!void {
    if (self.ctx.types.get(expected) != .write_view or arg != .src) return;
    const ty = self.ctx.typeOf(arg) orelse return;
    if (self.ctx.types.get(ty) != .write_view) return;
    const src = CallCheck.sourceText(self, arg);
    try self.errAt(arg, "write `!{s}`: {s} `{s}`", .{ src, what, src });
}

/// Whether a call of `f` (with self parameter `recv`) may keep a
/// view of an argument past the call: in its result, or through a
/// write view into something that can hold one.
pub fn callRetains(self: *Checker, f: FunctionType, recv: ?TypeId) bool {
    if (sema.mayHoldMarkedView(self.ctx, f.returns)) return true;
    for (f.params) |p| if (storesView(self, p)) return true;
    return if (recv) |r| storesView(self, r) else false;
}

/// A write view into something that can hold a view.
pub fn storesView(self: *Checker, param: TypeId) bool {
    const inner = switch (self.ctx.types.get(param)) {
        .write_view => |inner| inner,
        else => return false,
    };
    const held = if (sema.writeSliceElem(self.ctx, param)) |elem| elem else inner;
    return sema.mayHoldMarkedView(self.ctx, held);
}

/// Whether `e` is a name that names a type.
pub fn isTypeName(self: *Checker, e: Sexp) bool {
    if (e != .src) return false;
    const id = CallCheck.lookupQuiet(self, e) orelse return resolve.isBuiltinTypeName(self.ctx, self.text(e));
    return switch (self.ctx.symbols.items[id].kind) {
        .nominal_type, .generic_type, .type_alias, .generic_param => true,
        else => false,
    };
}

/// The `ct_param` of the compile-time integer parameter (or `k =! n`
/// binding of one) that `e` names; null for anything else.
pub fn ctParamOf(self: *Checker, e: Sexp) Error!?TypeId {
    if (e != .src) return null;
    const id = self.ctx.symbolOf(e) orelse return null;
    if (self.ctx.ct_locals.get(id)) |ct| return ct;
    const sym = self.ctx.symbols.items[id];
    if (sym.kind != .param or !sym.flags.comptime_known or self.ctx.types.get(sym.ty) != .int) return null;
    return try self.ctx.intern(.{ .ct_param = self.ctx.ref(id) });
}

/// Compile-time argument `i` of `callee` for integer value parameter
/// `param`: its value folded to a `ct_value`, or the `ct_param` of a
/// compile-time parameter passed on. Null after a diagnostic.
pub fn ctIntArg(self: *Checker, a: Sexp, param: SymbolId, i: usize, callee: []const u8) Error!?TypeId {
    const ty = self.ctx.symbols.items[param].ty;
    const mark = self.ctx.diagnostics.items.len;
    try self.checkCtValue(a, ty, i, callee);
    if (self.ctx.diagnostics.items.len != mark) return null;
    if (try ctParamOf(self, a)) |ct| return ct;
    const names: resolve.ConstNames = .{ .ctx = self.ctx, .scope = self.scope, .type_params = self.nominal.type_params };
    switch (sema.constIntBy(self.ctx, a, names)) {
        .value => |v| {
            if (!sema.intFits(self.ctx, ty, v)) {
                const name = try self.tyName(ty);
                try self.errAt(a, "compile-time argument {d} of `{s}` is `{d}`, which `{s}`, {s} `{s}`, cannot hold", .{ i + 1, callee, v, self.ctx.symbols.items[param].name, resolve.an(name), name });
                return null;
            }
            return try sema.ctInt(self.ctx, v);
        },
        .overflow => try self.errAt(a, "compile-time argument {d} of `{s}` is too large to compute", .{ i + 1, callee }),
        .not_constant => if (sema.perTargetLeaf(self.ctx, a)) |leaf| {
            try self.errAt(a, "compile-time argument {d} of `{s}` must be known when Rig checks the program; " ++ sema.per_target_why, .{ i + 1, callee, CallCheck.sourceText(self, leaf) });
        } else try self.errAt(a, "compile-time argument {d} of `{s}` must be an integer known at compile time: an integer, a constant, a compile-time parameter, or arithmetic on constants", .{ i + 1, callee }),
    }
    return null;
}

/// The fix for a call of `method` on type parameter `pname`, which
/// has no bound: the bound by the one API this module sees that
/// declares it, or how to make one.
pub fn boundForMethod(self: *Checker, pname: []const u8, method: []const u8) Error![]const u8 {
    const a = self.ctx.arena.allocator();
    var refs: std.ArrayList(sema.ApiRef) = .empty;
    for (self.ctx.symbols.items, 0..) |sym, i| {
        if (sym.kind == .api and !sema.isProxy(sym)) try refs.append(a, .{ .module_id = self.ctx.module_id, .sym = @intCast(i) });
    }
    for (self.ctx.imports) |imp| for (imp.sema.symbols.items, 0..) |sym, i| {
        if (sym.kind == .api and sym.flags.is_public and !sema.isProxy(sym)) try refs.append(a, .{ .module_id = imp.module_id, .sym = @intCast(i) });
    };
    var found: ?sema.ApiRef = null;
    for (refs.items) |r| {
        const sym = sema.apiSymbol(self.ctx, r) orelse continue;
        const declares = for (sym.fields orelse &.{}) |f| {
            if (f.is_method and std.mem.eql(u8, f.name, method)) break true;
        } else false;
        if (!declares) continue;
        if (found != null) return a.print("bound `{s}` by an API that declares `{s}`", .{ pname, method });
        found = r;
    }
    if (found) |r| return a.print("write `[{s}: {s}]`", .{ pname, try sema.apiName(self.ctx, r) });
    return a.print("declare an API with `{s}`, and bound `{s}` by it", .{ method, pname });
}

/// The method `method` of the APIs `refs` name and those they build
/// on: each API that declares it, once, in the order written. More than
/// one makes a call ambiguous (`reportAmbiguous`).
pub fn apiMethodsIn(self: *Checker, refs: []const sema.ApiRef, method: []const u8) Error![]const ApiCheck.ApiMethod {
    const a = self.ctx.arena.allocator();
    var out: std.ArrayList(ApiCheck.ApiMethod) = .empty;
    for (refs) |b| for (try sema.apiClosure(self.ctx, a, b)) |c| {
        const seen = for (out.items) |o| {
            if (o.api.eql(c)) break true;
        } else false;
        if (seen) continue;
        const home = sema.apiContext(self.ctx, c) orelse continue;
        const csym = sema.apiSymbol(self.ctx, c) orelse continue;
        for (csym.fields orelse &.{}) |f| if (f.is_method and std.mem.eql(u8, f.name, method)) {
            try out.append(a, .{ .api = c, .home = home, .field = f });
            break;
        };
    };
    return out.items;
}

/// The type of the API method `m` in this module's types, `Self` being
/// `self_ty`: the type a call through a bound, or through the API by
/// name, is checked against. Null for a method whose type was rejected.
pub fn apiMethodAt(self: *Checker, m: ApiCheck.ApiMethod, self_ty: TypeId) Error!?TypeId {
    const local_ty = if (m.home == @as(*const SemContext, self.ctx)) m.field.ty else try sema.importType(self.ctx, m.home, m.field.ty, m.api.module_id);
    if (self.ctx.types.get(local_ty) != .function or sema.containsPoison(self.ctx, local_ty)) return null;
    const api_sym = sema.apiSymbol(self.ctx, m.api) orelse return null;
    const home_self = (api_sym.type_params orelse return null)[0];
    const self_param = if (m.home == @as(*const SemContext, self.ctx)) home_self else try sema.proxyOf(self.ctx, .{ .module_id = m.api.module_id, .sym = home_self });
    return try sema.substituteType(self.ctx, local_ty, .{ .params = &.{self_param}, .args = &.{self_ty} });
}

/// `x.area()` where two APIs that apply to `x`'s type declare `area`:
/// the call names one, `Shape.area(x)`.
pub fn reportAmbiguous(self: *Checker, obj: Sexp, method: []const u8, found: []const ApiCheck.ApiMethod, ty: TypeId, pos: u32, args: []const Sexp) Error!TypeId {
    const a = self.ctx.arena.allocator();
    const call = if (self.expect.current_call) |c| CallCheck.sourceText(self, c) else method;
    const first = try sema.apiName(self.ctx, found[0].api);
    const sigil: []const u8 = switch (found[0].field.self_mode) {
        .write => "!",
        .value => "<",
        .read, .none => "",
    };
    var named: std.ArrayList(u8) = .empty;
    try named.print(a, "{s}.{s}({s}{s}", .{ first, method, sigil, try ViewCheck.plainText(self, CompatCheck.stripSigil(obj)) });
    for (args) |arg| try named.print(a, ", {s}", .{CallCheck.sourceText(self, arg)});
    try named.append(a, ')');
    return CallCheck.badCall(self, args, pos, "`{s}` could call `{s}.{s}` or `{s}.{s}`, which both apply to `{s}`; name the API: `{s}`", .{ call, first, method, try sema.apiName(self.ctx, found[1].api), method, try self.tyName(ty), named.items });
}

/// `x.m(args)` on a value of a type parameter `T` (`tv`), or a view
/// of one. With no bound, it is checked here as the call of a function
/// value with no `from` or `keeps`, and at each instance against the
/// method its type declares (`sema.GenericMethodCall`): the call's
/// sigil says how it takes self; its arguments are what the body
/// passes; and its result is what the body takes (`typeParamResult`).
/// A bounded `T` is checked against its bounds alone: a method of an
/// API they name is called through the bound (`apiMethodCall`), and
/// the built-in APIs give a body no method to call.
pub fn typeParamCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, tv: TypeId, param: SymbolId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    const tname = try self.tyName(tv);
    const psym = self.ctx.symbols.items[param];
    if (!sema.hasBounds(psym) and psym.flags.states_bounds) if (self.ctx.stated.get(param)) |decl| {
        // A `pub` declaration calls a method on a `T` through a bound.
        try self.ctx.err(psym.decl_pos, "`{s}` calls `{s}` on a `{s}`, which a `pub` generic does through a bound: {s}", .{ decl, method, tname, try boundForMethod(self, psym.name, method) });
        try self.ctx.note(pos, "here", .{});
        return CallCheck.skipCall(self, args);
    };
    if (sema.hasBounds(psym)) {
        const found = try apiMethodsIn(self, psym.user_apis, method);
        if (found.len > 1) return reportAmbiguous(self, obj, method, found, tv, pos, args);
        // `Iter`'s `next`, which each instance's type declares.
        if (found.len == 0 and std.mem.eql(u8, method, "next") and sema.boundApis(self.ctx, psym).contains(.Iter)) return iterNextCall(self, callee, obj, obj_ty, tv, param, pos, args, ct);
        if (found.len == 0) {
            const bounds = try sema.formatBounds(self.ctx, self.ctx.arena.allocator(), psym, null);
            return CallCheck.badCall(self, args, pos, "`{s}` is bounded by `{s}`, which gives no method `{s}`; a call on a `{s}` is checked at each instance only where `{s}` has no bound", .{ tname, bounds, method, tname, tname });
        }
        // The witness is the value's own, so the value is the `T` or a
        // view of one, not a box or a handle of it.
        if (sema.unwrapViews(self.ctx, obj_ty) != tv) return CallCheck.badCall(self, args, pos, "a method on a `{s}` is called on a `{s}` or a view of one, and `{s}` is a `{s}`", .{ tname, tname, CallCheck.sourceText(self, CompatCheck.stripSigil(obj)), try self.tyName(obj_ty) });
        const witness = (try sema.witnessFor(self.ctx, tv, found[0].api)) orelse return CallCheck.skipCall(self, args);
        return apiMethodCall(self, callee, obj, obj_ty, tv, found[0], .{ .witness = witness }, method, pos, args, ct);
    }
    if (ct) |b| return CallCheck.badCall(self, args, b, "a method called on a `{s}` takes no compile-time arguments", .{tname});
    // Emit writes the call as Zig resolves it on the value, so the
    // value is the `T` or a view of one, not a box or a handle of it.
    if (sema.unwrapViews(self.ctx, obj_ty) != tv) return CallCheck.badCall(self, args, pos, "a method on a `{s}` is called on a `{s}` or a view of one, and `{s}` is a `{s}`", .{ tname, tname, CallCheck.sourceText(self, CompatCheck.stripSigil(obj)), try self.tyName(obj_ty) });
    const call = self.expect.current_call orelse return CallCheck.skipCall(self, args);
    const mode: SelfMode = if (obj.isKind(.write)) .write else if (obj.isKind(.move)) .value else .read;
    const result = (try typeParamResult(self, call, tv)) orelse return CallCheck.skipCall(self, args);
    const returns = switch (result) {
        .ty => |ty| ty,
        .nothing, .dropped => self.t().void_id,
    };
    if (self.isPoison(returns)) return CallCheck.skipCall(self, args);
    const mark = self.ctx.diagnostics.items.len;
    _ = try noteMethod(self, callee, mode, returns);
    const misplaced_sigil = try ViewCheck.checkSelfSigil(self, obj, mode, returns, method);
    switch (mode) {
        .value => try ViewCheck.recordUse(self, obj, .take),
        .write => try ViewCheck.recordUse(self, CompatCheck.stripSigil(obj), .view),
        .read, .none => {},
    }
    if (mode == .read and !misplaced_sigil and !ViewCheck.hands(self, obj).hasStorage()) {
        try ViewCheck.readLeaf(self, obj);
    } else if (mode != .value and !misplaced_sigil and !(mode == .write and ViewCheck.hands(self, obj).kind == .made)) try ViewCheck.rejectResourceTemporary(self, obj, obj_ty);
    if (!misplaced_sigil) {
        const saved_of = self.expect.self_of;
        defer self.expect.self_of = saved_of;
        self.expect.self_of = callee;
        const kind: CompatCheck.SelfTypeKind = switch (self.ctx.types.get(obj_ty)) {
            .read_view => .read_view,
            .write_view => .write_view,
            else => .owned_nominal,
        };
        try ViewCheck.checkSelfMode(self, obj, mode, kind, method, pos, returns);
    }
    // The arguments as the body passes them: a literal as the type
    // a binding of it would have.
    const a = self.ctx.arena.allocator();
    const params = try a.alloc(TypeId, args.len + 1);
    params[0] = switch (mode) {
        .read => try self.ctx.intern(.{ .read_view = tv }),
        .write => try self.ctx.intern(.{ .write_view = tv }),
        .value, .none => tv,
    };
    for (args, params[1..]) |arg, *p| {
        const e = if (arg.isKind(.kwarg)) ir.Kwarg.value(arg) else arg;
        const ty = try CallCheck.argType(self, e);
        p.* = if (ty == self.t().int_literal_id) self.t().int_id else if (ty == self.t().float_literal_id) self.t().float_id else ty;
    }
    const f: FunctionType = .{ .params = params, .returns = returns, .is_sub = result != .ty };
    try noteCallee(self, f);
    const rest: FunctionType = .{ .params = f.params[1..], .returns = f.returns, .is_sub = f.is_sub };
    // A temporary self the result or an argument may keep a view of
    // is kept in its statement's slot, as for any method.
    if ((mode == .read or mode == .write) and !misplaced_sigil and !obj.isKind(.read)) {
        const viewed = CompatCheck.stripSigil(obj);
        const base = if (ViewCheck.hands(self, viewed).kind == .part_of_made) StmtCheck.placeOf(self, viewed).base else viewed;
        const copied = switch (ViewCheck.hands(self, base).kind) {
            .made => true,
            .branches => if (self.ctx.typeOf(base)) |ty| !sema.readByAddress(self.ctx, ty) else false,
            else => false,
        };
        if (copied and ViewCheck.isTemporary(self, viewed) and (sema.mayHoldView(self.ctx, f.returns) or callRetains(self, rest, f.params[0]))) try ViewCheck.viewTemp(self, viewed);
    }
    var scratch = std.heap.ArenaAllocator.init(self.ctx.allocator);
    defer scratch.deinit();
    const origins = try sema.defaultOrigins(self.ctx, scratch.allocator(), f);
    self.expect.view_call = true;
    self.expect.view_recv = f.params[0];
    try CallCheck.checkArgs(self, args, rest, .{}, method, pos, .{ .has_self = true, .origins = origins, .declared = rest.params });
    if (self.ctx.diagnostics.items.len != mark or self.ctx.quiet != 0) return returns;
    try self.ctx.recordTypeParamCall(call);
    for (self.ctx.generic_methods.items) |c| if (c.pos == self.startOf(call) and c.module_id == 0) return returns;
    try self.ctx.generic_methods.append(self.ctx.allocator, .{
        .param = param,
        .method = method,
        .self_mode = mode,
        .args = try self.ctx.dupeIds(f.params[1..]),
        .result = result,
        .pos = self.startOf(call),
        .recv = try a.dupe(u8, CallCheck.sourceText(self, CompatCheck.stripSigil(obj))),
        .call = try a.dupe(u8, CallCheck.sourceText(self, call)),
        .owned_recv = if (self.ctx.typeOf(CompatCheck.stripSigil(obj))) |recv_ty| self.ctx.types.get(recv_ty) == .type_var else false,
    });
    return returns;
}

/// `s.area()` through an API object, `s` a `?{Shape}`, `!{Shape}`, or
/// `^{Shape}`, and `Shape.area(s)` (`self_arg`, `args` from self on)
/// (docs/design/apis.md, Stage 4): the method is one the object
/// reaches (`sema.objectMethods`), and one left out is reported with
/// why, to be called through a bound. It is checked as a call of the
/// API's declaration, `Self` the object, whose type only self names,
/// with the API's `from` and `keeps`, and reaches the hidden type's
/// method through the object's table (`Dispatch.dynamic`).
pub fn objectCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, o: sema.ApiObject, named: ?sema.ApiRef, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp, self_arg: bool) Error!TypeId {
    const a = self.ctx.arena.allocator();
    const form = try self.tyName(obj_ty);
    const api = try sema.apiName(self.ctx, o.api);
    const rest = if (self_arg) args[1..] else args;
    var found: std.ArrayList(sema.ObjectMethod) = .empty;
    for (try sema.objectMethods(self.ctx, a, o.api)) |m| {
        if (named) |r| if (!r.eql(m.api)) continue;
        if (std.mem.eql(u8, m.field.name, method)) try found.append(a, m);
    }
    if (found.items.len == 0) return CallCheck.badCall(self, args, pos, "`{s}` has no method `{s}`: a call through it reaches the methods of `{s}` and the APIs it builds on", .{ form, method, api });
    if (found.items.len > 1) {
        const one = try sema.apiName(self.ctx, found.items[0].api);
        const two = try sema.apiName(self.ctx, found.items[1].api);
        return CallCheck.badCall(self, args, pos, "`{s}` could call `{s}.{s}` or `{s}.{s}`, which both apply to `{s}`; name the API: `{s}.{s}({s})`", .{ CallCheck.sourceText(self, self.expect.current_call orelse obj), one, method, two, method, form, one, method, CallCheck.sourceText(self, obj) });
    }
    const m = found.items[0];
    const declarer = try sema.apiName(self.ctx, m.api);
    if (m.left_out) |why| return switch (why) {
        .ct_params => CallCheck.badCall(self, args, pos, "`{s}.{s}` takes compile-time parameters, which a call through `{s}` cannot pass: call it through a bound, `[T: {s}]`", .{ declarer, method, form, api }),
        .set_param => |e| CallCheck.badCall(self, args, pos, "`{s}.{s}` takes a set parameter, `{s}`, which a call through `{s}` cannot pass: call it through a bound, `[T: {s}]`", .{ declarer, method, e, form, api }),
        .self_type => CallCheck.badCall(self, args, pos, "`{s}.{s}` names `Self` outside self, which a call through `{s}` cannot know: call it through a bound, `[T: {s}]`", .{ declarer, method, form, api }),
    };
    if (m.field.self_mode == .none) return CallCheck.badCall(self, args, pos, "`{s}.{s}` takes no self, so a call through `{s}` cannot reach it: call it through a bound, `[T: {s}]`", .{ declarer, method, form, api });
    // A handle only reads (Core sentence 8): a call through a `*{A}`
    // reaches `?@` methods alone, as through a `*T`.
    if (m.field.self_mode == .write or m.field.self_mode == .value) if (sema.objectHeld(self.ctx, sema.unwrapViews(self.ctx, obj_ty))) |h| if (h.form == .shared) {
        const shown = try self.tyName(sema.unwrapViews(self.ctx, obj_ty));
        return CallCheck.badCall(self, args, pos, "`{s}` only reads, as any handle: `{s}` takes `{s}`; hold a `^{s}`, or change the value through a `Cell` it holds", .{ shown, method, if (m.field.self_mode == .write) "!@" else "<@", try sema.objectSpelling(self.ctx, a, h.object) });
    };
    const home = sema.apiContext(self.ctx, m.api) orelse return CallCheck.skipCall(self, args);
    const am: ApiCheck.ApiMethod = .{ .api = m.api, .home = home, .field = m.field };
    const object = try self.ctx.intern(.{ .api_object = o });
    if (!self_arg) return apiMethodCall(self, callee, obj, obj_ty, object, am, .{ .table = .{ .api = o.api, .slot = m.slot.? } }, method, pos, rest, ct);
    // `Shape.area(s)`: self the first argument, with its sigil; a
    // method that consumes self takes the box, `Shape.close(<b)`.
    const self_ty = if (m.field.self_mode == .value) try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.builtins.box, .args = try self.ctx.dupeIds(&.{object}) } }) else object;
    const fn_ty_id = (try apiMethodAt(self, am, self_ty)) orelse return CallCheck.skipCall(self, args);
    const fn_ty = self.ctx.types.get(fn_ty_id).function;
    const info = CallCheck.methodParams(m.field, false, home.source);
    const shown = try a.print("{s}.{s}", .{ declarer, method });
    const f = (try CallCheck.instantiateCall(self, fn_ty, ct, args, info, 0, shown, pos, true, .empty)) orelse return CallCheck.skipCall(self, args);
    try noteCallee(self, f);
    self.expect.view_call = true;
    try CallCheck.checkArgs(self, args, f, info, shown, pos, .{ .origins = m.field.origins, .declared = fn_ty.params });
    if (self.expect.current_call) |call| try self.ctx.recordDispatch(call, .{ .dynamic = .{ .api = m.api, .method = m.field.name, .table = o.api, .slot = m.slot.?, .self_mode = m.field.self_mode, .self_arg = true } });
    return f.returns;
}

/// `(!it).next()` on an `I` bounded by `Iter`: `fun next(!@) ->
/// I.Item?`, the shape `sema.iterItem` asks of each instance's type,
/// whose `next` Zig finds on the value (`Dispatch.direct`).
pub fn iterNextCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, tv: TypeId, param: SymbolId, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    const tname = try self.tyName(tv);
    if (ct) |b| return CallCheck.badCall(self, args, b, "`Iter`'s `next` takes no compile-time arguments", .{});
    if (args.len > 0) return CallCheck.badCall(self, args, pos, "`Iter`'s `next` takes no arguments: `next(!@) -> {s}.Item?`", .{tname});
    if (sema.unwrapViews(self.ctx, obj_ty) != tv) return CallCheck.badCall(self, args, pos, "a method on a `{s}` is called on a `{s}` or a view of one, and `{s}` is a `{s}`", .{ tname, tname, CallCheck.sourceText(self, CompatCheck.stripSigil(obj)), try self.tyName(obj_ty) });
    const item = try self.ctx.intern(.{ .type_var = self.ctx.ref(try sema.assocParam(self.ctx, param, .iter, "Item")) });
    const returns = try self.ctx.intern(.{ .optional = item });
    _ = try noteMethod(self, callee, .write, returns);
    const misplaced_sigil = try ViewCheck.checkSelfSigil(self, obj, .write, returns, "next");
    if (!misplaced_sigil) {
        const kind: CompatCheck.SelfTypeKind = switch (self.ctx.types.get(obj_ty)) {
            .read_view => .read_view,
            .write_view => .write_view,
            else => .owned_nominal,
        };
        try ViewCheck.checkSelfMode(self, obj, .write, kind, "next", pos, returns);
    }
    try ViewCheck.recordUse(self, CompatCheck.stripSigil(obj), .view);
    const f: FunctionType = .{ .params = try self.ctx.dupeIds(&.{try self.ctx.intern(.{ .write_view = tv })}), .returns = returns, .is_sub = false };
    try noteCallee(self, f);
    var scratch = std.heap.ArenaAllocator.init(self.ctx.allocator);
    defer scratch.deinit();
    const origins = try sema.defaultOrigins(self.ctx, scratch.allocator(), f);
    self.expect.view_call = true;
    self.expect.view_recv = f.params[0];
    try CallCheck.checkArgs(self, args, .{ .params = &.{}, .returns = returns, .is_sub = false }, .{}, "next", pos, .{ .has_self = true, .origins = origins, .declared = &.{} });
    return returns;
}

/// `x.area()` reaching a method of an API of a program's own: through
/// a bound on `x`'s type parameter, or on a type that provides the
/// API (`apiShorthand`). It is checked as a call of the API's
/// declaration, `Self` being `self_ty`: its self, parameters,
/// compile-time parameters, and result with its failure, which every
/// implementation has exactly, and its `from` and `keeps`, which every
/// implementation is within (docs/design/apis.md, Stage 3). The call
/// reaches the method through `witness` (`Dispatch.static`).
pub fn apiMethodCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, self_ty: TypeId, m: ApiCheck.ApiMethod, via: Checker.ApiVia, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    const fn_ty_id = (try apiMethodAt(self, m, self_ty)) orelse return CallCheck.skipCall(self, args);
    const fn_ty = self.ctx.types.get(fn_ty_id).function;
    const self_mode = m.field.self_mode;
    _ = try noteMethod(self, callee, self_mode, fn_ty.returns);
    try noteCallee(self, fn_ty);
    const misplaced_sigil = try ViewCheck.checkSelfSigil(self, obj, self_mode, fn_ty.returns, method);
    switch (self_mode) {
        .value => try ViewCheck.recordUse(self, obj, .take),
        .write => try ViewCheck.recordUse(self, CompatCheck.stripSigil(obj), .view),
        .read, .none => {},
    }
    if (self_mode == .read and !misplaced_sigil and !ViewCheck.hands(self, obj).hasStorage()) {
        try ViewCheck.readLeaf(self, obj);
    } else if (self_mode != .value and !misplaced_sigil and !(self_mode == .write and ViewCheck.hands(self, obj).kind == .made)) try ViewCheck.rejectResourceTemporary(self, obj, obj_ty);
    if (!misplaced_sigil) {
        const saved_of = self.expect.self_of;
        defer self.expect.self_of = saved_of;
        self.expect.self_of = callee;
        const kind: CompatCheck.SelfTypeKind = switch (self.ctx.types.get(obj_ty)) {
            .read_view => .read_view,
            .write_view => .write_view,
            else => .owned_nominal,
        };
        try ViewCheck.checkSelfMode(self, obj, self_mode, kind, method, pos, fn_ty.returns);
    }
    const info = CallCheck.methodParams(m.field, true, m.home.source);
    const f = (try CallCheck.instantiateCall(self, fn_ty, ct, args, info, 1, method, pos, false, .empty)) orelse return CallCheck.skipCall(self, args);
    const own: Checker.OwnArgs = .{ .args = self.inst_own.args, .slots = self.inst_slots };
    if (sema.isGenericFn(self.ctx, fn_ty)) try noteCallee(self, f);
    const rest: FunctionType = .{ .params = f.params[1..], .returns = f.returns, .is_sub = f.is_sub };
    // A temporary self the result or an argument may keep a view of
    // is kept in its statement's slot, as for any method.
    if ((self_mode == .read or self_mode == .write) and !misplaced_sigil and !obj.isKind(.read)) {
        const viewed = CompatCheck.stripSigil(obj);
        const base = if (ViewCheck.hands(self, viewed).kind == .part_of_made) StmtCheck.placeOf(self, viewed).base else viewed;
        const copied = switch (ViewCheck.hands(self, base).kind) {
            .made => true,
            .branches => if (self.ctx.typeOf(base)) |ty| !sema.readByAddress(self.ctx, ty) else false,
            else => false,
        };
        if (copied and ViewCheck.isTemporary(self, viewed) and (sema.mayHoldView(self.ctx, f.returns) or callRetains(self, rest, f.params[0]))) try ViewCheck.viewTemp(self, viewed);
    }
    self.expect.view_call = true;
    self.expect.view_recv = f.params[0];
    const mark = self.ctx.diagnostics.items.len;
    try CallCheck.checkArgs(self, args, rest, info, method, pos, .{ .has_self = true, .origins = m.field.origins, .declared = fn_ty.params[1..] });
    // A self the method keeps is viewed with `?` written (Core
    // sentence 4).
    const o = m.field.origins;
    if (self_mode == .read and !misplaced_sigil and self.ctx.diagnostics.items.len == mark and o.stores & o.viewed & sema.paramBit(0) != 0 and ViewCheck.implicitSelf(self, obj)) {
        if (self.expect.current_call) |call| try ViewCheck.reportKept(self, call, obj, .{ .stored = method });
    }
    switch (via) {
        .witness => |witness| {
            if (self.expect.current_call) |call| try self.ctx.recordDispatch(call, .{ .static = .{ .witness = witness, .api = m.api, .method = m.field.name, .self_mode = self_mode } });
            try recordApiCall(self, self_ty, m, own, pos);
        },
        .table => |entry| if (self.expect.current_call) |call| try self.ctx.recordDispatch(call, .{ .dynamic = .{ .api = m.api, .method = m.field.name, .table = entry.api, .slot = entry.slot, .self_mode = self_mode } }),
    }
    return f.returns;
}

/// Record a call through API method `m` on `self_ty`, at the method's
/// own compile-time arguments `own` (`instantiateCall`), whose
/// instance of the implementation is checked (`sema.ApiCall`).
pub fn recordApiCall(self: *Checker, self_ty: TypeId, m: ApiCheck.ApiMethod, own: Checker.OwnArgs, pos: u32) Error!void {
    if (self.tentative != 0 or self.isPoison(self_ty)) return;
    try self.ctx.recordApiCall(.{ .recv = self_ty, .api = m.api, .method = m.field.name, .args = own.args, .slots = own.slots, .pos = pos });
}

/// `c.area()` on a value of a type that has no method `area` of its
/// own, where one API the module declares or imports, which the type
/// provides, declares `area`: a call through that API, a default or
/// an addition's method included. Null when none does; two make the
/// call name the API (`Shape.area(c)`).
pub fn apiShorthand(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!?TypeId {
    const value = ExprCheck.canonical(self, sema.unwrapViews(self.ctx, obj_ty));
    switch (self.ctx.types.get(value)) {
        .type_var, .shared, .weak, .optional, .function => return null,
        else => {},
    }
    const visible = try visibleApis(self);
    if (visible.len == 0) return null;
    const a = self.ctx.arena.allocator();
    var found: std.ArrayList(ApiCheck.ApiMethod) = .empty;
    for (visible) |ref| {
        for (try apiMethodsIn(self, &.{ref}, method)) |m| {
            const seen = for (found.items) |o| {
                if (o.api.eql(m.api)) break true;
            } else false;
            if (seen) continue;
            if (try sema.provides(self.ctx, value, m.api) == null) continue;
            try found.append(a, m);
        }
    }
    if (found.items.len == 0) return null;
    if (found.items.len > 1) return try reportAmbiguous(self, obj, method, found.items, value, pos, args);
    const witness = (try sema.witnessFor(self.ctx, value, found.items[0].api)) orelse return null;
    // `5.twice()`: a literal self is a value of the type it defaults to.
    if (obj_ty == self.t().int_literal_id) try ViewCheck.defaultIntLiteral(self, CompatCheck.stripSigil(obj));
    return try apiMethodCall(self, callee, obj, obj_ty, value, found.items[0], .{ .witness = witness }, method, pos, args, ct);
}

/// The APIs this module declares and those the modules it imports
/// declare `pub`: those whose methods `c.area()` reaches.
pub fn visibleApis(self: *Checker) Error![]const sema.ApiRef {
    if (self.visible_apis) |v| return v;
    const a = self.ctx.arena.allocator();
    var out: std.ArrayList(sema.ApiRef) = .empty;
    for (self.ctx.symbols.items, 0..) |sym, i| {
        if (sym.kind == .api and !sema.isProxy(sym)) try out.append(a, .{ .module_id = self.ctx.module_id, .sym = @intCast(i) });
    }
    for (self.ctx.imports) |imp| {
        for (imp.sema.symbols.items, 0..) |sym, i| {
            if (sym.kind != .api or !sym.flags.is_public or sema.isProxy(sym)) continue;
            const ref: sema.ApiRef = .{ .module_id = imp.module_id, .sym = @intCast(i) };
            const seen = for (out.items) |o| {
                if (o.eql(ref)) break true;
            } else false;
            if (!seen) try out.append(a, ref);
        }
    }
    self.visible_apis = out.items;
    return out.items;
}

/// `Shape.area(c)`: the method of an API called through it by name,
/// self given as the first argument with its sigil as at any call. The
/// first argument's type provides the API, or is a type parameter
/// whose bounds name it; the call is checked against the API's
/// declaration and reaches the method through the witness.
pub fn apiNameCall(self: *Checker, ref: sema.ApiRef, api_text: []const u8, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    const found = try apiMethodsIn(self, &.{ref}, method);
    if (found.len == 0) return CallCheck.badCall(self, args, pos, "`{s}` declares no method `{s}`", .{ api_text, method });
    const m = found[0];
    if (args.len == 0 or args[0].isKind(.kwarg)) return CallCheck.badCall(self, args, pos, "`{s}.{s}` takes self first: `{s}.{s}(x)`", .{ api_text, method, api_text, method });
    const recv_ty = try CallCheck.argType(self, CompatCheck.stripSigil(args[0]));
    if (self.isPoison(recv_ty)) return CallCheck.skipCall(self, args);
    // `Shape.area(s)` of an API object `s` whose API is or builds on
    // `Shape`: a call through the object.
    if (sema.objectHeld(self.ctx, recv_ty)) |h| {
        for (try sema.apiClosure(self.ctx, self.ctx.arena.allocator(), h.object.api)) |c| {
            if (c.eql(m.api)) return objectCall(self, .nil, args[0], recv_ty, h.object, m.api, method, pos, args, ct, true);
        }
    }
    // `Shape.area(4)`: a literal self is a value of the type it
    // defaults to.
    const value = ExprCheck.canonical(self, sema.unwrapViews(self.ctx, recv_ty));
    const witness = (try sema.witnessFor(self.ctx, value, m.api)) orelse {
        const name = try sema.apiName(self.ctx, m.api);
        return CallCheck.badCall(self, args, pos, "`{s}.{s}` takes self as a value of a type that provides `{s}`, and `{s}` does not", .{ api_text, method, name, try self.tyName(value) });
    };
    const fn_ty_id = (try apiMethodAt(self, m, value)) orelse return CallCheck.skipCall(self, args);
    const fn_ty = self.ctx.types.get(fn_ty_id).function;
    const info = CallCheck.methodParams(m.field, false, m.home.source);
    const shown = try self.ctx.arena.allocator().print("{s}.{s}", .{ api_text, method });
    const f = (try CallCheck.instantiateCall(self, fn_ty, ct, args, info, 0, shown, pos, true, .empty)) orelse return CallCheck.skipCall(self, args);
    const own: Checker.OwnArgs = .{ .args = self.inst_own.args, .slots = self.inst_slots };
    try noteCallee(self, f);
    self.expect.view_call = true;
    try CallCheck.checkArgs(self, args, f, info, shown, pos, .{ .origins = m.field.origins, .declared = fn_ty.params });
    if (self.expect.current_call) |call| try self.ctx.recordDispatch(call, .{ .static = .{ .witness = witness, .api = m.api, .method = m.field.name, .self_arg = true, .self_mode = m.field.self_mode } });
    try recordApiCall(self, value, m, own, pos);
    return f.returns;
}

/// The API `obj` names, as the object of `Shape.area(c)`; null when it
/// names none.
pub fn apiNamedCallee(self: *Checker, obj: Sexp) Error!?sema.ApiRef {
    if (obj == .src) {
        const id = CallCheck.lookupQuiet(self, obj) orelse return null;
        if (self.ctx.symbols.items[id].kind != .api) return null;
    } else if (!obj.isKind(.member)) return null;
    return switch (try resolve.apiNamed(self.ctx, self.scope, obj)) {
        .user => |ref| ref,
        else => null,
    };
}

/// The result a call `x.m(...)` on a value of type parameter `tv`
/// takes in the body, from where it stands: nothing as a statement,
/// any result `_ =` drops, the type its context expects (through
/// `!`, `?`, `catch`, and `??`, which wrap it), or the type of the
/// other operand of an arithmetic or comparison operator, a literal
/// as a binding of it would be. Null after a diagnostic: with none
/// of these, the body cannot know the result's type.
pub fn typeParamResult(self: *Checker, call: Sexp, tv: TypeId) Error!?sema.GenericMethodCall.Result {
    if (CompatCheck.sameNode(self.expect.discarded, call)) return if (self.expect.discard_named) .dropped else .nothing;
    // A statement `x.m()!` gives nothing, or fails.
    if (!self.expect.discard_named and self.expect.discarded != .nil and !CompatCheck.sameNode(self.expect.discarded, call)) if (CompatCheck.resultCall(self.expect.discarded)) |c| if (CompatCheck.sameNode(c, call)) {
        if (try wrapResult(self, self.expect.discarded, call, self.t().void_id)) |ty| return .{ .ty = ty };
    };
    if (CompatCheck.sameNode(self.expect.result_expected.call, call)) {
        const ty = self.expect.result_expected.ty;
        if (self.isPoison(ty)) return .{ .ty = ty };
        if (try wrapResult(self, self.expect.result_expected.value, call, ty)) |wrapped| return .{ .ty = wrapped };
    }
    if (CompatCheck.resultCall(self.expect.beside.node)) |c| if (CompatCheck.sameNode(c, call)) {
        const other = self.expect.beside.ty orelse try FlowCheck.synthQuiet(self, self.expect.beside.other);
        const ty = if (other == self.t().int_literal_id) self.t().int_id else if (other == self.t().float_literal_id) self.t().float_id else other;
        if (!self.isPoison(ty) and self.ctx.types.get(ty) != .void) if (try wrapResult(self, self.expect.beside.node, call, ty)) |wrapped| return .{ .ty = wrapped };
    };
    const shown = CallCheck.sourceText(self, call);
    try self.errAt(call, "`{s}` calls a method on a `{s}`, whose result type the body cannot know; give it one: `a: Float = {s}`, then `print(a)`", .{ shown, try self.tyName(tv), shown });
    return null;
}

/// `ty`, what `value` gives, as the type of the call `call` that
/// `value` is or wraps: through `!` and `catch` a fallible `ty!`,
/// through `?` and `??` an optional `ty?`. Null for any other form.
/// A `ty` that is itself fallible, a `-> T!` function's result that
/// `value` stands for, is its value `T` there: `x.m() catch |e| 0`
/// gives a `T`, and the tail wraps it.
pub fn wrapResult(self: *Checker, value: Sexp, call: Sexp, ty: TypeId) Error!?TypeId {
    if (CompatCheck.sameNode(value, call)) return ty;
    const kind = value.kind() orelse return null;
    const ok = if (self.ctx.types.get(ty) == .fallible) self.ctx.types.get(ty).fallible.ok else ty;
    return switch (kind) {
        .propagate => try wrapResult(self, ir.Propagate.value(value), call, try self.ctx.intern(.{ .fallible = .{ .ok = ok } })),
        .@"catch" => try wrapResult(self, ir.Catch.value(value), call, try self.ctx.intern(.{ .fallible = .{ .ok = ok } })),
        .propagate_none => try wrapResult(self, ir.PropagateNone.value(value), call, try self.ctx.intern(.{ .optional = ty })),
        .@"??" => try wrapResult(self, ir.@"??".left(value), call, try self.ctx.intern(.{ .optional = ty })),
        else => null,
    };
}

/// The parameters of a hand-typed call that takes a value and then
/// integer options by name (`*Actor(x, mailbox: n)`): `first`, named
/// `name`, then an `Int` for each option named, once, in the order
/// written; `checkArgs` reports a name given twice.
/// The options of `optionParams` that take a duration: `per:`, in
/// seconds (`sema.duration`).
pub fn optionDurations(names: []const []const u8) sema.ParamMask {
    var mask: sema.ParamMask = 0;
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, "per")) {
        mask |= sema.paramBit(i);
    };
    return mask;
}

pub fn optionParams(self: *Checker, args: []const Sexp, first: TypeId, name: []const u8) Error!struct { []const TypeId, []const []const u8 } {
    const a = self.ctx.arena.allocator();
    var params: std.ArrayList(TypeId) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    try params.append(a, first);
    try names.append(a, name);
    for (args[1..]) |arg| {
        const n = self.text(ir.Kwarg.name(arg));
        for (names.items) |had| {
            if (std.mem.eql(u8, had, n)) break;
        } else {
            try params.append(a, self.t().int_id);
            try names.append(a, n);
        }
    }
    return .{ params.items, names.items };
}

/// `*Actor(x)` and `*Actor(x, mailbox: n)`: an actor of `x`, which
/// it takes, behind its first handle. Its value goes to a task of its
/// own: an object or enum whose fields move and hold no loan.
/// `mailbox` is how many calls made with `&` may be in flight at
/// once (64 by default).
pub fn actorMake(self: *Checker, node: Sexp, callee: Sexp, args: []const Sexp) Error!TypeId {
    if (!CompatCheck.sameNode(node, self.expect.shared_operand)) return CallCheck.badCall(self, args, callee, "an actor lives only behind a shared handle: write `*Actor(x)`", .{});
    var positional: usize = 0;
    for (args) |a| {
        if (!a.isKind(.kwarg)) {
            positional += 1;
            continue;
        }
        if (!std.mem.eql(u8, self.text(ir.Kwarg.name(a)), "mailbox")) return CallCheck.badCall(self, args, a, "`Actor` takes the value it runs, and `mailbox:`, how many calls made with `&` it holds at once: `*Actor(x, mailbox: 16)`", .{});
    }
    if (positional != 1 or args[0].isKind(.kwarg)) return CallCheck.badCall(self, args, callee, "`Actor` takes the value it runs: `*Actor(Counter(hits: 0))`", .{});
    const value = args[0];
    const ty = ExprCheck.canonical(self, try CallCheck.argType(self, value));
    if (self.isPoison(ty)) return CallCheck.skipCall(self, args);
    const shown = CallCheck.sourceText(self, value);
    const declared = switch (self.ctx.types.get(ty)) {
        .nominal => true,
        .parameterized_nominal => |pn| !sema.isBuiltinGeneric(self.ctx, self.ctx.localSym(pn.sym)),
        else => false,
    };
    if (!declared) {
        return CallCheck.badCall(self, args, value, "an actor runs an object or an enum, whose methods its handles call; `{s}` has type `{s}`", .{ shown, try self.tyName(ty) });
    }
    if (try sema.crossingBlocker(self.ctx, ty, .moves)) |blocker| {
        if (try statedCrossing(self, blocker, .moves, self.startOf(value))) return CallCheck.skipCall(self, args);
        return CallCheck.badCall(self, args, value, "an actor's value goes to a task of its own, and `{s}` {s}", .{ try self.tyName(ty), try blockerReason(self, blocker, false, if (blocker == ty) "is" else null) });
    }
    try requireTask(self, ty, .moves, self.startOf(value), "is given to an actor's task", false);
    if (sema.mayHoldView(self.ctx, ty)) return CallCheck.badCall(self, args, value, "an actor's value holds no view, and a `{s}` may hold a view", .{try self.tyName(ty)});
    const actor = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.builtins.actor, .args = try self.ctx.dupeIds(&.{ty}) } });
    const params, const names = try optionParams(self, args, ty, "value");
    const call: FunctionType = .{ .params = params, .returns = actor, .is_sub = false };
    try noteCallee(self, call);
    try CallCheck.checkArgs(self, args, call, .{ .names = names }, "Actor", self.startOf(callee), .{ .declared = call.params });
    if (self.expect.current_call) |c| try self.ctx.recordActorMake(c);
    self.ctx.makes_tasks = true;
    self.ctx.makes_actors = true;
    return actor;
}

/// `*Frozen(x)`: a frozen value of `x`, which it takes, behind its
/// first handle; `x` holds only data that never changes
/// (`sema.frozenBlocker`). A frozen value is shared, `+f`, never
/// frozen again.
pub fn frozenMake(self: *Checker, node: Sexp, callee: Sexp, args: []const Sexp) Error!TypeId {
    if (!CompatCheck.sameNode(node, self.expect.shared_operand)) return CallCheck.badCall(self, args, callee, "a frozen value lives only behind a shared handle: write `*Frozen(x)`", .{});
    if (args.len != 1 or args[0].isKind(.kwarg)) return CallCheck.badCall(self, args, callee, "`Frozen` takes the value it freezes: `*Frozen(String(\"home\"))`", .{});
    const value = args[0];
    const ty = ExprCheck.canonical(self, try CallCheck.argType(self, value));
    if (self.isPoison(ty)) return CallCheck.skipCall(self, args);
    if (sema.frozenOfHandle(self.ctx, ty) != null) {
        const taken = if (value.isKind(.move)) ir.Move.operand(value) else value;
        const shown = CallCheck.sourceText(self, taken);
        return CallCheck.badCall(self, args, value, "`{s}` is frozen already: `+{s}` shares it", .{ shown, shown });
    }
    if (try sema.frozenBlocker(self.ctx, ty)) |blocker| return CallCheck.badCall(self, args, value, "{s}", .{try sema.frozenMessage(self.ctx, ty, blocker)});
    if (sema.heapStacked(self.ctx, ty)) return CallCheck.badCall(self, args, value, "this value is already `{s}`; `*Frozen` would hold it twice; " ++ sema.heap_stacked_rule, .{try self.tyName(ty)});
    try sema.requireFrozen(self.ctx, ty, self.startOf(value));
    const frozen = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.builtins.frozen, .args = try self.ctx.dupeIds(&.{ty}) } });
    const call: FunctionType = .{ .params = try self.ctx.dupeIds(&.{ty}), .returns = frozen, .is_sub = false };
    try noteCallee(self, call);
    try CallCheck.checkArgs(self, args, call, .{ .names = &.{"value"} }, "Frozen", self.startOf(callee), .{ .declared = call.params });
    if (self.expect.current_call) |c| try self.ctx.recordFrozenMake(c);
    return frozen;
}

/// `*Actor.supervised(*|| Rooms(...))`: an actor whose value `make`
/// makes, first here and again each time a panic ends it, with
/// `restarts: n, per: ns`, at most `n` times within `ns`
/// nanoseconds, and `mailbox:` as `*Actor(x)` takes it. The actor
/// keeps `make`, so it is an owned closure written in the call, which
/// no one else holds, and the tasks that run the actor call it: what
/// it captures moves to them. It takes nothing and gives the value,
/// which follows `*Actor(x)`'s rules.
pub fn actorSupervised(self: *Checker, callee: Sexp, method: []const u8, pos: u32, args: []const Sexp) Error!TypeId {
    if (!std.mem.eql(u8, method, "supervised")) return CallCheck.badCall(self, args, pos, "`Actor` has one function of its own, `supervised`, an actor that starts again when a panic ends it: `*Actor.supervised(*|| Rooms(...))`", .{});
    const node = self.expect.current_call orelse return CallCheck.skipCall(self, args);
    if (!CompatCheck.sameNode(node, self.expect.shared_operand)) return CallCheck.badCall(self, args, callee, "an actor lives only behind a shared handle: write `*Actor.supervised(...)`", .{});
    var positional: usize = 0;
    for (args) |a| {
        if (!a.isKind(.kwarg)) {
            positional += 1;
            continue;
        }
        const name = self.text(ir.Kwarg.name(a));
        if (!std.mem.eql(u8, name, "mailbox") and !std.mem.eql(u8, name, "restarts") and !std.mem.eql(u8, name, "per")) return CallCheck.badCall(self, args, a, "`Actor.supervised` takes the function that makes its value, then `restarts:` and `per:`, at most how many restarts within how many seconds, and `mailbox:`", .{});
    }
    if (positional != 1 or args[0].isKind(.kwarg)) return CallCheck.badCall(self, args, callee, "`Actor.supervised` takes the function that makes its value: `*Actor.supervised(*|| Rooms(...))`", .{});
    const f = args[0];
    if (f.isKind(.lambda)) return CallCheck.badCall(self, args, f, "the actor keeps the function that makes its value, so it is an owned closure: `*{s}`", .{CallCheck.sourceText(self, f)});
    if (!f.isKind(.share) or !ir.Share.operand(f).isKind(.lambda)) return CallCheck.badCall(self, args, f, "the actor keeps the function that makes its value, which no one else may hold: write an owned closure in the call, `*Actor.supervised(*|| Rooms(...))`", .{});
    const f_ty = try CallCheck.argType(self, f);
    if (self.isPoison(f_ty)) return CallCheck.skipCall(self, args);
    const make = sema.ownedClosureFn(self.ctx, f_ty) orelse return CallCheck.skipCall(self, args);
    if (make.params.len != 0) return CallCheck.badCall(self, args, f, "the function that makes an actor's value takes nothing", .{});
    const ty = ExprCheck.canonical(self, make.returns);
    if (self.ctx.types.get(ty) == .fallible) return CallCheck.badCall(self, args, f, "the function that makes an actor's value cannot fail; a panic in it ends the actor", .{});
    const declared = switch (self.ctx.types.get(ty)) {
        .nominal => true,
        .parameterized_nominal => |pn| !sema.isBuiltinGeneric(self.ctx, self.ctx.localSym(pn.sym)),
        else => false,
    };
    if (!declared) return CallCheck.badCall(self, args, f, "an actor runs an object or an enum, whose methods its handles call; the function gives a value of type `{s}`", .{try self.tyName(ty)});
    if (try sema.crossingBlocker(self.ctx, ty, .moves)) |blocker| {
        if (try statedCrossing(self, blocker, .moves, self.startOf(f))) return CallCheck.skipCall(self, args);
        return CallCheck.badCall(self, args, f, "an actor's value goes to a task of its own, and `{s}` {s}", .{ try self.tyName(ty), try blockerReason(self, blocker, false, if (blocker == ty) "is" else null) });
    }
    try requireTask(self, ty, .moves, self.startOf(f), "is given to an actor's task", false);
    if (sema.mayHoldView(self.ctx, ty)) return CallCheck.badCall(self, args, f, "an actor's value holds no view, and a `{s}` may hold a view", .{try self.tyName(ty)});
    // The tasks that run the actor call the function, each in turn.
    for (sema.captureList(ir.Lambda.captures(ir.Share.operand(f)))) |cap| {
        const name_node = sema.captureNameNode(cap) orelse continue;
        const id = self.ctx.symbolOf(name_node) orelse continue;
        const cty = self.ctx.symbols.items[id].ty;
        if (self.isPoison(cty)) continue;
        const blocker = (try sema.crossingBlocker(self.ctx, cty, .moves)) orelse {
            try requireTask(self, cty, .moves, self.startOf(name_node), "is given to an actor's tasks", false);
            continue;
        };
        if (try statedCrossing(self, blocker, .moves, self.startOf(name_node))) return CallCheck.skipCall(self, args);
        return CallCheck.badCall(self, args, name_node, "the tasks that run the actor call the function that makes its value, and `{s}` {s}", .{ self.text(name_node), try blockerReason(self, blocker, false, if (blocker == cty) "is" else null) });
    }
    const actor = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.builtins.actor, .args = try self.ctx.dupeIds(&.{ty}) } });
    const params, const names = try optionParams(self, args, f_ty, "make");
    const call: FunctionType = .{ .params = params, .returns = actor, .is_sub = false };
    try noteCallee(self, call);
    try CallCheck.checkArgs(self, args, call, .{ .names = names, .durations = optionDurations(names), .waits = true }, "Actor.supervised", self.startOf(callee), .{ .declared = call.params });
    try self.ctx.recordActorSupervised(node);
    self.ctx.makes_tasks = true;
    self.ctx.makes_actors = true;
    return actor;
}

/// `c.m(args)` through a handle `c` of an actor of `value`: a message,
/// which waits for the method to run on the actor's task and gives
/// its result. A `?@` method is called bare, through a handle or a
/// read view of one; a `!@` method is marked, `!c.m(...)`, through a
/// handle the caller holds. A method that takes its value, or whose
/// signature has `keeps` or `from`, is not called through a handle:
/// the actor holds no loan, and nothing it gives views its state. Its
/// arguments go to the actor's task (given ones move, viewed ones
/// share), and so does its result, which moves.
pub fn actorCall(self: *Checker, callee: Sexp, obj: Sexp, value: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    if (ct) |b| return CallCheck.badCall(self, args, b, "a method called through an actor's handle takes no compile-time arguments", .{});
    const shown = try ViewCheck.plainText(self, CompatCheck.stripSigil(obj));
    const m = (try sema.lookupMethod(self.ctx, value, method)) orelse {
        if (try hasDataField(self, value, method)) return CallCheck.badCall(self, args, pos, "an actor's fields are its own: reach `{s}` through a method of `{s}`", .{ method, try self.tyName(value) });
        return CallCheck.badCall(self, args, pos, "no method `{s}` on `{s}`, the value of actor `{s}`", .{ method, try self.tyName(value), shown });
    };
    const self_mode = m.field.self_mode;
    if (m.field.owner_bounds.len > 0) return CallCheck.badCall(self, args, pos, "`{s}` is declared under a bound on its type's parameters, and an actor's handle calls no such method: call it in a method of `{s}`", .{ method, try self.tyName(value) });
    switch (self_mode) {
        .none => return CallCheck.badCall(self, args, pos, "`{s}` takes no self: call it through its type, `{s}.{s}(...)`", .{ method, try self.tyName(value), method }),
        .value => return CallCheck.badCall(self, args, pos, "`{s}` takes its value, which the actor keeps: a handle calls a `?@` or `!@` method", .{method}),
        .read => if (obj.isKind(.write)) return CallCheck.badCall(self, args, obj, "`{s}` only reads the actor: call it bare, `{s}.{s}(...)`", .{ method, shown, method }),
        .write => {
            if (!obj.isKind(.write)) return CallCheck.badCall(self, args, obj, "`{s}` changes the actor: mark the call, `!{s}.{s}(...)`", .{ method, shown, method });
            if (self.ctx.typeOf(CompatCheck.stripSigil(obj))) |held| if (self.ctx.types.get(held) == .read_view) {
                return CallCheck.badCall(self, args, obj, "`{s}` changes the actor, and `{s}` is a read view of its handle, which only reads: call it through a handle you hold", .{ method, shown });
            };
        },
    }
    // A handle made here that the call only reads is a temporary its
    // statement drops, as a method's self is (one given a write view
    // is kept by its view).
    if (self_mode == .read and !ViewCheck.hands(self, obj).hasStorage()) try ViewCheck.readLeaf(self, obj);
    const o = m.field.origins;
    if (o.declared or o.stores & o.viewed != 0) return CallCheck.badCall(self, args, pos, "`{s}` has `keeps` or `from`, and an actor holds no view, nor gives a view of its state: a handle cannot call it", .{method});
    const f = m.fn_ty;
    const rest: FunctionType = .{ .params = f.params[1..], .returns = f.returns, .is_sub = f.is_sub };
    _ = try noteMethod(self, callee, self_mode, f.returns);
    try noteCallee(self, rest);
    const info = CallCheck.methodParams(m.field, true, CallCheck.declSource(self, m.nominal_sym));
    const mark = self.ctx.diagnostics.items.len;
    // The handle stands for self, which the actor's task holds: what the
    // call passes on is the method's own, past its self.
    const passed: sema.Origins = .{ .result = o.result >> 1, .stores = o.stores >> 1, .viewed = o.viewed >> 1, .once = o.once >> 1 };
    try CallCheck.checkArgs(self, args, rest, info, method, pos, .{ .origins = passed, .declared = rest.params });
    if (self.ctx.diagnostics.items.len != mark) return f.returns;
    // What crosses to the actor's task.
    for (args) |a| {
        const arg = if (a.isKind(.kwarg)) ir.Kwarg.value(a) else a;
        const arg_ty = self.ctx.typeOf(arg) orelse continue;
        if (self.isPoison(arg_ty)) continue;
        if (ViewCheck.fnArg(self, arg, arg_ty) == .binding) {
            try self.errAt(arg, "closure `{s}` stays in its binding, so it goes to no actor; an actor's method takes a named function by value", .{CallCheck.sourceText(self, arg)});
            return self.t().invalid_id;
        }
        const ty = try crossingTypeOf(self, arg, arg_ty);
        const k = self.ctx.types.get(ty);
        if (k == .write_view) {
            try self.errAt(arg, "a method an actor runs takes no write view: `{s}` makes a write view of `{s}`", .{ CallCheck.sourceText(self, arg), try ViewCheck.plainText(self, CompatCheck.stripSigil(arg)) });
            return self.t().invalid_id;
        }
        const how: sema.Crossing = if (k == .read_view or k == .slice) .shares else .moves;
        const inner = if (k == .read_view) sema.unwrapViews(self.ctx, ty) else ty;
        if (try sema.crossingBlocker(self.ctx, inner, how)) |blocker| {
            if (try statedCrossing(self, blocker, how, self.startOf(arg))) return self.t().invalid_id;
            if (try objectLack(self, ty, how)) |lack| {
                try self.errAt(arg, "an actor runs its methods on a task of its own, and `{s}` {s}: {s}", .{ CallCheck.sourceText(self, arg), if (how == .shares) "is passed to it as a read view" else "is given to it", lack });
                return self.t().invalid_id;
            }
            try self.errAt(arg, "an actor runs its methods on a task of its own, and `{s}` {s}: `{s}` {s}", .{ CallCheck.sourceText(self, arg), if (how == .shares) "is passed to it as a read view" else "is given to it", try self.tyName(ty), try blockerReason(self, blocker, how == .shares, if (blocker == ty) "is" else if (blocker == inner) "views" else null) });
            return self.t().invalid_id;
        }
        try requireTask(self, inner, how, self.startOf(arg), if (how == .shares) "is passed to an actor's task as a read view" else "is given to an actor's task", false);
    }
    if (!try ExprCheck.waitHoldsStop(self, pos, f.returns, method)) return self.t().invalid_id;
    const result = if (self.ctx.types.get(f.returns) == .fallible) self.ctx.types.get(f.returns).fallible.ok else f.returns;
    if (sema.mayHoldView(self.ctx, result)) {
        try self.err(pos, "`{s}` gives a `{s}`, which may view the actor's state; a method called through a handle gives a value", .{ method, try self.tyName(result) });
        return self.t().invalid_id;
    }
    if (try sema.crossingBlocker(self.ctx, result, .moves)) |blocker| {
        if (try statedCrossing(self, blocker, .moves, pos)) return self.t().invalid_id;
        try self.err(pos, "`{s}` gives a value made on the actor's task, and `{s}` {s}", .{ method, try self.tyName(result), try blockerReason(self, blocker, false, if (blocker == result) "is" else null) });
        return self.t().invalid_id;
    }
    try requireTask(self, result, .moves, pos, "is given back by an actor's task", false);
    if (self.expect.current_call) |c| try self.ctx.recordActorCall(c);
    // The method the call reaches, as any method call records it: its
    // proven depth is the room a run inline needs (`Actor.claim`). A
    // generic type's method keeps none, and runs inline only with a
    // whole task's stack left.
    if (m.subst.params.len == 0) if (sema.nominalDecl(self.ctx, value)) |nom| {
        try noteTarget(self, nom.ctx.module_id, m.field.decl_pos, m.field.inline_marked, .empty);
    };
    return f.returns;
}

/// Record the call being checked (`current_call`) as a call of the
/// Rig function or method declared at `pos` in module `module`
/// (`sema.CallTarget`): the one fact of what a call reaches, which
/// `inlining.decide` reads. A built-in declares none. A call of a
/// function marked `inline` also records the instance it makes
/// (`sema.InlineCall`): its type's parameters bound by `recv`, then
/// its own (`inst_own`, so this runs after `instantiateCall`), which
/// the frame check lands its values at (`FrameWalker.addInlined`).
pub fn noteTarget(self: *Checker, module: u32, pos: u32, marked: bool, recv: TypeSubst) Error!void {
    const call = self.expect.current_call orelse return;
    if (pos >= sema.imported_decl_pos) return;
    const fun: sema.FnRef = .{ .module = module, .pos = pos };
    try self.ctx.recordCallTarget(call, .{ .function = fun });
    if (!marked) return;
    const a = self.ctx.arena.allocator();
    try self.ctx.recordInlineCall(call, .{ .fun = fun, .subst = .{
        .params = try std.mem.concat(a, SymbolId, &.{ recv.params, self.inst_own.params }),
        .args = try std.mem.concat(a, TypeId, &.{ recv.args, self.inst_own.args }),
    } });
}

/// `noteTarget` for the method `field` of the type `owner`, declared
/// in module `module` (null for this one), or, for a proxy of
/// another module's generic type, in the module the proxy stands for.
/// The program reaches the method at self's arguments, on
/// `recv_ty` (`sema.BodyReach`), at `pos`.
pub fn noteMethodTarget(self: *Checker, field: Field, owner: sema.Symbol, module: ?u32, recv: TypeSubst, recv_ty: TypeId, pos: u32) Error!void {
    if (owner.decl_pos == sema.builtin_decl_pos) return;
    const declared = module orelse if (sema.isProxy(owner)) owner.from.module_id else self.ctx.module_id;
    try noteTarget(self, declared, field.decl_pos, field.inline_marked, recv);
    if (recv.params.len == 0 or self.tentative != 0 or field.decl_pos >= sema.imported_decl_pos or self.isPoison(recv_ty)) return;
    _ = try self.ctx.recordBodyReach(.{ .fun = .{ .module = declared, .pos = field.decl_pos }, .in = bodyRef(self), .params = recv.params, .args = recv.args, .recv = recv_ty, .method = field.name, .site = pos });
}

/// The method whose body is being checked, when it is one a call
/// reaches (`body_pos`).
pub fn bodyRef(self: *Checker) ?sema.FnRef {
    if (self.body_pos == sema.no_body) return null;
    return .{ .module = self.ctx.module_id, .pos = self.body_pos };
}

/// Records `callee` as the member a call resolved as a method, which
/// takes its self as `self` and returns `returns`: its object
/// is self, no path's base (`checkViewBases`). Returns
/// `returns`.
pub fn noteMethod(self: *Checker, callee: Sexp, self_mode: sema.SelfMode, returns: TypeId) Error!TypeId {
    if (callee == .list) try self.methods.put(self.ctx.allocator, CompatCheck.nodeId(callee), .{ .self_mode = self_mode, .returns = returns });
    // A self the method views is viewed where it is: each element on
    // its path is reached in place, not copied (`sema.copiesElem`).
    if ((self_mode == .read or self_mode == .write) and callee.isKind(.member)) {
        var p = ViewCheck.selfPlace(ir.Member.object(callee));
        while (true) switch (p.kind() orelse break) {
            .index => {
                try self.ctx.recordElemViewed(p);
                p = ir.get(p, .object);
            },
            .member => p = ir.get(p, .object),
            else => break,
        };
    }
    // How the call dispatches: `direct`, until a call through an API
    // records `static` (`apiMethodCall`).
    if (self.expect.current_call) |call| if (self.ctx.dispatchOf(call) == null) try self.ctx.recordDispatch(call, .direct);
    return returns;
}

/// `sigil`, a `!` self-sigil rule moved onto `place`, a module
/// or type through which a function is called, so it reaches no
/// value: reported, with the form that views the value the call
/// makes (of type `ty`), or, before a `Bool`, the habit of `!` as
/// negation (as `fieldCallSigil` does). `ty` when there is none.
pub fn misreachedWrite(self: *Checker, sigil: ?Sexp, place: Sexp, method: []const u8, ty: TypeId) Error!TypeId {
    const s = sigil orelse return ty;
    const what = if ((try CallCheck.moduleNamed(self, place)) != null) "a module" else "a type";
    const shown = try ViewCheck.plainText(self, place);
    const value = if (self.ctx.types.get(ty) == .fallible) self.ctx.types.get(ty).fallible.ok else ty;
    const call = try FlowCheck.callWith(self, s, shown, method);
    if (value == self.t().bool_id) {
        try self.errAt(s, "`!` here reaches `{s}`, {s}, and `{s}` makes a `Bool`; for negation use `not`", .{ shown, what, call });
    } else try self.errAt(s, "`!` here reaches `{s}`, {s}, not the value `{s}` makes: write `!({s})` to make a write view of that value, or remove the `!`", .{ shown, what, call, call });
    return self.t().invalid_id;
}

/// `copy`, `fill`, and `swap`: built-in methods on the elements of a
/// slice, an array, or a List, which write them in place; `sum`,
/// which reads them (`sumCall`); `prefetch`, which asks for one
/// (`prefetchCall`); and `read` and `write` on bytes
/// (`bytesCall`). Null when `method` is none of them or self
/// has no elements.
pub fn elemsCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!?TypeId {
    const op = std.meta.stringToEnum(sema.ElemOp, method) orelse return null;
    if (op.isBits() or op.isSimd() or op.isTypeFn() or op.isFloat() or op == .hash or op == .order) return null;
    const peeled = sema.unwrapViews(self.ctx, obj_ty);
    var len: ?u64 = null;
    const elem: TypeId = switch (self.ctx.types.get(peeled)) {
        .slice => |sl| sl.elem,
        .array => |a| blk: {
            len = sema.arrayLen(self.ctx, a);
            break :blk a.elem;
        },
        .string_view, .static => try ViewCheck.byteType(self),
        else => CompatCheck.listElementType(self.ctx, peeled) orelse return null,
    };
    if (obj.isKind(.move) and ViewCheck.isSelfSigil(self, obj)) {
        try ViewCheck.misplacedSigil(self, obj, method, "does not consume `self`");
        return try CallCheck.skipCall(self, args);
    }
    if (op == .sum) return try sumCall(self, callee, obj, obj_ty, peeled, elem, pos, args, ct);
    if (op == .prefetch) return try prefetchCall(self, callee, obj, obj_ty, peeled, elem, pos, args, ct);
    if (op == .read or op == .write) return try bytesCall(self, callee, obj, obj_ty, elem, len, op, pos, args, ct);
    if (ct) |b| return try CallCheck.badCall(self, args, b, "`{s}` takes no compile-time arguments", .{method});
    if (!try writesElements(self, obj, obj_ty, peeled, method)) return try CallCheck.skipCall(self, args);
    if (op != .swap and try ViewCheck.cannotCopy(self, elem, pos, "copies into the elements a value")) {
        if (op == .fill) {
            try ViewCheck.notDuplicated(self, pos, "`fill` copies its value into every element", elem, "`for i in 0..xs.len` with `xs[i] = +x`", "");
        } else try ViewCheck.notDuplicated(self, pos, "`copy` copies every element of its source", elem, "`for i in 0..src.len` with `xs[i] = +src[i]`", "");
        return try CallCheck.skipCall(self, args);
    }
    for (args) |a| if (a.isKind(.kwarg)) return try CallCheck.badCall(self, args, a, "`{s}` takes no keyword arguments", .{method});
    const want: usize = if (op == .swap) 2 else 1;
    if (args.len != want) return try CallCheck.badCall(self, args, pos, "`{s}` takes {s}; got {d} argument{s}", .{ method, switch (op) {
        .copy => "one argument, the `[]T` to copy from",
        .fill => "one argument, the value for every element",
        .swap => "two arguments, the indexes of the elements to swap",
        .read, .write, .not, .leading_zeros, .trailing_zeros, .count_ones, .swap_bytes, .to_bits, .from_bits, .wrap, .from_int, .from_text, .nan, .inf, .fraction, .exponent, .splat, .bits, .first, .lanes, .any, .all, .array, .with, .select, .lookup, .lag, .hash, .order, .min, .max, .clamp, .total_order, .sum, .prefetch => unreachable,
    }, args.len, if (args.len == 1) "" else "s" });
    const recv = try self.ctx.intern(.{ .write_view = peeled });
    const params: []const TypeId = switch (op) {
        .copy => &.{ recv, try self.ctx.intern(.{ .slice = .{ .elem = elem } }) },
        .fill => &.{ recv, elem },
        .swap => &.{ recv, self.t().int_id, self.t().int_id },
        .read, .write, .not, .leading_zeros, .trailing_zeros, .count_ones, .swap_bytes, .to_bits, .from_bits, .wrap, .from_int, .from_text, .nan, .inf, .fraction, .exponent, .splat, .bits, .first, .lanes, .any, .all, .array, .with, .select, .lookup, .lag, .hash, .order, .min, .max, .clamp, .total_order, .sum, .prefetch => unreachable,
    };
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(params), .returns = self.t().void_id, .is_sub = true });
    try self.ctx.recordElemCall(callee, .{ .op = op, .elem = elem });
    switch (op) {
        // `copy` keeps nothing of its source: a temporary array may
        // be viewed as it.
        .copy => {
            const saved = self.expect.viewed_temp;
            defer self.expect.viewed_temp = saved;
            self.expect.viewed_temp = args[0];
            try ViewCheck.checkExpr(self, args[0], params[1]);
        },
        .fill => try ViewCheck.checkExpr(self, args[0], params[1]),
        .swap => for (args) |a| try checkIndexArg(self, a, len),
        .read, .write, .not, .leading_zeros, .trailing_zeros, .count_ones, .swap_bytes, .to_bits, .from_bits, .wrap, .from_int, .from_text, .nan, .inf, .fraction, .exponent, .splat, .bits, .first, .lanes, .any, .all, .array, .with, .select, .lookup, .lag, .hash, .order, .min, .max, .clamp, .total_order, .sum, .prefetch => unreachable,
    }
    return self.t().void_id;
}

/// `xs.reduce(start, f)` on a slice, an array, or a List: the running
/// value, `start` first, passed with each element in order, viewed as a
/// `?T`, to `f`, which gives the next; the last. The running value
/// moves through, so it may own what it holds; a `start` of type `A`
/// takes an `f` of type `?fun(A, ?T) -> A`, and one whose `f` can
/// fail can fail, with the first failure. It only reads its
/// self. Null when self has no elements.
pub fn reduceCall(self: *Checker, obj: Sexp, obj_ty: TypeId, pos: u32, args: []const Sexp, ct: ?Sexp) Error!?TypeId {
    const peeled = sema.unwrapViews(self.ctx, obj_ty);
    const elem: TypeId = switch (self.ctx.types.get(peeled)) {
        .slice => |sl| sl.elem,
        .array => |a| a.elem,
        else => CompatCheck.listElementType(self.ctx, peeled) orelse return null,
    };
    const example = "`xs.reduce(0, |sum, x| sum + x)`";
    if (ct) |b| return try CallCheck.badCall(self, args, b, "`reduce` takes no compile-time arguments", .{});
    if (obj.isKind(.move) and ViewCheck.isSelfSigil(self, obj)) {
        try ViewCheck.misplacedSigil(self, obj, "reduce", "does not consume `self`");
        return try CallCheck.skipCall(self, args);
    }
    if (ViewCheck.isSelfSigil(self, obj) and !obj.isKind(.read)) try ViewCheck.misplacedSigil(self, obj, "reduce", "only reads its elements");
    if (args.len != 2 or args[0].isKind(.kwarg) or args[1].isKind(.kwarg)) return try CallCheck.badCall(self, args, pos, "`reduce` takes the starting value and the function that gives the next value from the running one and each element: {s}", .{example});
    const start = try CallCheck.argType(self, args[0]);
    if (self.isPoison(start)) return try CallCheck.skipCall(self, args);
    // A literal start runs as an `Int` or a `Float`.
    const value = CompatCheck.readValue(self.ctx, start);
    const acc = if (value == self.t().int_literal_id) self.t().int_id else if (value == self.t().float_literal_id) self.t().float_id else value;
    const each = try self.ctx.intern(.{ .read_view = elem });
    const fn_ty = (try reduceFunction(self, args[1], acc, each)) orelse return try CallCheck.skipCall(self, args);
    const fails = self.ctx.types.get(self.ctx.types.get(fn_ty).function.returns) == .fallible;
    const result = if (fails) try self.ctx.intern(.{ .fallible = .{ .ok = acc } }) else acc;
    const recv = try self.ctx.intern(.{ .read_view = peeled });
    const f: FunctionType = .{ .params = try self.ctx.dupeIds(&.{ recv, acc, try sema.callableOfFn(self.ctx, fn_ty) }), .returns = result, .is_sub = false };
    try noteCallee(self, f);
    // `mk().reduce(...)` reads a temporary, dropped when its statement ends.
    if (ViewCheck.isTemporary(self, obj)) try ViewCheck.viewTemp(self, obj);
    try CallCheck.checkArgs(self, args, .{ .params = f.params[1..], .returns = f.returns, .is_sub = false }, .{ .names = &.{ "start", "f" } }, "reduce", pos, .{ .has_self = true, .origins = .{ .stores = 0 } });
    if (self.expect.current_call) |c| try self.ctx.recordReduceCall(c);
    return closureResult(self, args[1], result);
}

/// The type of `reduce`'s function `f`, taking the running value as
/// `acc` and each element as `each`: a closure literal's, checked
/// quietly first as one that cannot fail and then, when its body
/// needs to, as one that can, and when neither checks clean, as the
/// one with fewer errors (`closureType`'s rule); or the type of a
/// function or a function value. Null, reported, when it is neither.
pub fn reduceFunction(self: *Checker, f: Sexp, acc: TypeId, each: TypeId) Error!?TypeId {
    const plain = try self.ctx.intern(.{ .function = .{ .params = try self.ctx.dupeIds(&.{ acc, each }), .returns = acc, .is_sub = false } });
    if (f.isKind(.lambda)) {
        const failing = try self.ctx.intern(.{ .function = .{ .params = try self.ctx.dupeIds(&.{ acc, each }), .returns = try self.ctx.intern(.{ .fallible = .{ .ok = acc } }), .is_sub = false } });
        const plain_errors = try lambdaErrorsQuietly(self, f, plain);
        if (plain_errors == 0) return plain;
        const failing_errors = try lambdaErrorsQuietly(self, f, failing);
        if (failing_errors == 0) return failing;
        try self.closures_in_error.put(self.ctx.allocator, CompatCheck.nodeId(f), {});
        return if (failing_errors < plain_errors) failing else plain;
    }
    const ty = try CallCheck.argType(self, f);
    if (self.isPoison(ty)) return null;
    const owned: ?TypeId = if (sema.ownedClosureFn(self.ctx, ty)) |o| try self.ctx.intern(.{ .function = o }) else null;
    const fn_ty = if (self.ctx.types.get(ty) == .function) ty else sema.callableFnTy(self.ctx, ty) orelse owned orelse {
        try self.errAt(f, "`reduce` calls a function with the running value and each element, a closure or a function's name; `{s}` is a `{s}`", .{ CallCheck.sourceText(self, f), try self.tyName(ty) });
        return null;
    };
    const returns = self.ctx.types.get(fn_ty).function.returns;
    return if (self.ctx.types.get(returns) == .fallible) try self.ctx.intern(.{ .function = .{ .params = try self.ctx.dupeIds(&.{ acc, each }), .returns = try self.ctx.intern(.{ .fallible = .{ .ok = acc } }), .is_sub = false } }) else plain;
}

/// A chain, `xs.filter(f).count()`: stages on a `for` source whose type
/// declares no method of the name, ended by a consumer, or the source
/// of a `for`. It is found (`chains`) for its statement to be checked
/// again with the chain rewritten into the loop it means
/// (`checkRewritten`); this check gives it no type. Null when the call
/// is no chain: self's own method, or a self no `for` walks.
pub fn chainCall(self: *Checker, callee: Sexp, method: []const u8, args: []const Sexp) Error!?TypeId {
    const call = self.expect.current_call orelse return null;
    var root = ir.Member.object(callee);
    var stages: usize = 0;
    var first = method;
    while (root.isKind(.call) and ir.Call.callee(root).isKind(.member) and rig.isChainStage(self.text(ir.Member.name(ir.Call.callee(root))))) {
        stages += 1;
        first = self.text(ir.Member.name(ir.Call.callee(root)));
        root = ir.Member.object(ir.Call.callee(root));
    }
    const found = (try chainSource(self, root, method, stages)) orelse return null;
    const kind = found.kind;
    const consumer = rig.isChainConsumer(method);
    const for_source = self.expect.chain_for != .nil and CompatCheck.sameNode(call, ir.For.source(self.expect.chain_for));
    if (!consumer and !for_source) {
        try self.errAt(call, "a chain is not a value: end it with a consumer (`.count()`, `.collect()`), or make it a `for` loop's source", .{});
        return self.t().invalid_id;
    }
    if (!try chainShape(self, callee, method, args)) return self.t().invalid_id;
    // Each stage binds hidden names of its own (`Parser.stageName`).
    const count = if (consumer) stages else stages + 1;
    if (count > rig.max_chain_stages) {
        try self.errAt(call, "this chain has {d} stages, and a chain has at most {d}: end it with `.collect()` part way and chain on the List that gives, or write the loop", .{ count, rig.max_chain_stages });
        return self.t().invalid_id;
    }
    // A `for` header's sigil before a chain views the chain's source,
    // as before any method call (`for x in !xs.filter(f)` walks
    // `(!xs).filter(f)`): one that reaches no place views nothing, and
    // a `<` is written on the source it takes.
    if (for_source) {
        const mode = ir.For.mode(self.expect.chain_for).tag;
        if (mode == .read or mode == .move) {
            const mark: []const u8 = if (mode == .read) "?" else "<";
            try self.errAt(root, "the `{s}` before this chain reaches no place and does nothing: remove it; the chain walks `{s}` as a `for` over it would", .{ mark, try ViewCheck.plainText(self, root) });
            return self.t().invalid_id;
        }
        if (root.isKind(.move) and ViewCheck.isSelfSigil(self, root)) {
            const shown = try ViewCheck.plainText(self, ir.get(root, .operand));
            try self.errAt(root, "a `<` before a chain is written on the source it takes: `(<{s}).{s}(...)` takes `{s}`, and `{s}.{s}(...)` walks it where it stands", .{ shown, first, shown, shown, first });
            return self.t().invalid_id;
        }
    }
    // An iterator in a place advances: the chain makes a write view of
    // it, and says so, as a `for` over it does. A read view of one
    // cannot.
    if (kind == .iterator and (root.isKind(.read) or (!for_source and !madeHere(root) and !root.isKind(.write)))) {
        const shown = try ViewCheck.plainText(self, if (root.isKind(.read)) ir.get(root, .operand) else root);
        try self.errAt(root, "a chain advances the iterator `{s}`: make a write view of it, `(!{s}).{s}(...)`", .{ shown, shown, first });
        return self.t().invalid_id;
    }
    // A `zip`'s second source: one a chain, walked as the first is.
    var zip: rig.ChainSource = .elements;
    var zip_copies = true;
    var zips: usize = 0;
    var at = call;
    while (at.isKind(.call) and ir.Call.callee(at).isKind(.member)) : (at = ir.Member.object(ir.Call.callee(at))) {
        const c = ir.Call.callee(at);
        if (!std.mem.eql(u8, self.text(ir.Member.name(c)), "zip")) continue;
        zips += 1;
        if (zips > 1) {
            try self.errAt(ir.Member.name(c), "a chain takes one `zip`", .{});
            return self.t().invalid_id;
        }
        const ys = ir.Call.args(at)[0];
        const second = (try chainSource(self, ys, "zip", 1)) orelse {
            try self.errAt(ys, "`zip` walks a List, an array, a slice, or an iterator, and `{s}` is a `{s}`", .{ try ViewCheck.plainText(self, ys), try self.tyName(try FlowCheck.synthQuiet(self, ys)) });
            return self.t().invalid_id;
        };
        if (second.kind == .range) {
            try self.errAt(ys, "`zip` with a range: write its numbers with `enumerate`, or hold the range's bounds", .{});
            return self.t().invalid_id;
        }
        if (second.kind == .iterator and !madeHere(ys) and !ys.isKind(.write)) {
            const shown = try ViewCheck.plainText(self, ys);
            try self.errAt(ys, "`zip` advances the iterator `{s}`: make a write view of it, `zip(!{s})`", .{ shown, shown });
            return self.t().invalid_id;
        }
        zip = second.kind;
        zip_copies = second.copies;
    }
    var views = false;
    if (!try chainTypes(self, call, root, kind, zip, &views)) return self.t().invalid_id;
    if (views and !for_source) try self.chain_views.put(self.ctx.allocator, CompatCheck.nodeId(call), root);
    const node = if (for_source) self.expect.chain_for else call;
    const id = node.list.id;
    if (self.ctx.parser == null) {
        try self.errAt(call, "a chain needs the module graph, which rewrites it", .{});
        return self.t().invalid_id;
    }
    // Every statement and declaration that holds a call that may be a
    // chain is checked under a mark (`checkRewritten`).
    if (self.rewrites_open == 0) {
        try self.errAt(call, "internal error: this chain is outside any statement checked again", .{});
        return self.t().invalid_id;
    }
    for (self.chains.items) |c| if (c.node == id) return self.t().unknown_id;
    try self.chains.append(self.ctx.allocator, .{ .node = id, .source = kind, .copies = found.copies, .zip = zip, .zip_copies = zip_copies, .scope = self.scope });
    return self.t().unknown_id;
}

/// A value made where it stands: a call, or a literal.
pub fn madeHere(e: Sexp) bool {
    return e.isKind(.call) or e.isKind(.array) or e.isKind(.read);
}

/// What a chain whose stages end at `root` walks, or null when `root`
/// is no `for` source, or its type declares `method` itself, or, with
/// no stage, a List's own `sum` or `reduce` takes the call.
pub fn chainSource(self: *Checker, root: Sexp, method: []const u8, stages: usize) Error!?struct { kind: rig.ChainSource, copies: bool = true } {
    if (root.isKind(.@"..")) return .{ .kind = .range };
    // A module's or a type's function (`par.map`, `task.all`) is no chain.
    if ((try CallCheck.moduleNamed(self, root)) != null or (try CallCheck.namedType(self, root)) != null) return null;
    const ty = try FlowCheck.synthQuiet(self, root);
    if (self.isPoison(ty)) return null;
    const peeled = sema.unwrapViews(self.ctx, ty);
    const elem: ?TypeId = switch (self.ctx.types.get(peeled)) {
        .slice => |sl| sl.elem,
        .array => |arr| arr.elem,
        else => sema.listElem(self.ctx, peeled),
    };
    if (elem) |e| {
        if (stages == 0 and (std.mem.eql(u8, method, "sum") or std.mem.eql(u8, method, "reduce"))) return null;
        return .{ .kind = .elements, .copies = sema.copies(self.ctx, e) == .yes };
    }
    switch (try sema.iterItem(self.ctx, peeled)) {
        .item => {},
        else => return null,
    }
    if ((try sema.methodOfType(self.ctx, peeled, method)) != null) return null;
    return .{ .kind = .iterator };
}

/// Each stage and the consumer of a chain take the arguments they
/// name, reported where they do not.
pub fn chainShape(self: *Checker, callee: Sexp, method: []const u8, args: []const Sexp) Error!bool {
    var ok = try chainArgs(self, callee, method, args);
    var obj = ir.Member.object(callee);
    while (obj.isKind(.call) and ir.Call.callee(obj).isKind(.member)) {
        const c = ir.Call.callee(obj);
        const name = self.text(ir.Member.name(c));
        if (!rig.isChainStage(name)) break;
        if (!try chainArgs(self, c, name, ir.Call.args(obj))) ok = false;
        obj = ir.Member.object(c);
    }
    return ok;
}

pub fn chainArgs(self: *Checker, callee: Sexp, name: []const u8, args: []const Sexp) Error!bool {
    const Want = struct { n: usize, what: []const u8 };
    const want: Want = if (std.mem.eql(u8, name, "map") or std.mem.eql(u8, name, "filter") or std.mem.eql(u8, name, "any") or std.mem.eql(u8, name, "all") or std.mem.eql(u8, name, "find"))
        .{ .n = 1, .what = "a function of each item, `|x| ...`" }
    else if (std.mem.eql(u8, name, "min_by") or std.mem.eql(u8, name, "max_by"))
        .{ .n = 1, .what = "a function giving each item's key, `|x| x.key`" }
    else if (std.mem.eql(u8, name, "take") or std.mem.eql(u8, name, "skip"))
        .{ .n = 1, .what = "a count" }
    else if (std.mem.eql(u8, name, "zip"))
        .{ .n = 1, .what = "a second source" }
    else if (std.mem.eql(u8, name, "reduce"))
        .{ .n = 2, .what = "the starting value and a function of the running value and each item, `|acc, x| ...`" }
    else
        .{ .n = 0, .what = "nothing" };
    for (args) |a| if (a.isKind(.kwarg)) {
        try self.errAt(a, "`{s}` takes no keyword arguments", .{name});
        return false;
    };
    if (args.len != want.n) {
        try self.errAt(ir.Member.name(callee), "`{s}` in a chain takes {s}", .{ name, want.what });
        return false;
    }
    for (args) |a| if (a.isKind(.lambda)) if (failsIn(ir.get(a, .body))) |at| {
        try self.errAt(at, "a chain's function cannot fail: handle the failure inside it with `catch`, or write the loop", .{});
        return false;
    };
    return true;
}

/// The first `e!` in a closure's body, outside closures inside it.
pub fn failsIn(e: Sexp) ?Sexp {
    if (e != .list) return null;
    if (e.isKind(.propagate)) return e;
    if (e.isKind(.lambda)) return null;
    for (e.items()) |c| if (failsIn(c)) |at| return at;
    return null;
}

/// A chain's items, typed stage by stage from its source as its
/// rewrite types them (`TypeResolver.chainItemType`), each stage and
/// the consumer checked against what reaches it and reported in the
/// chain's terms, so no error names the loop it becomes. False when
/// one is reported. An item whose type is not known (a function whose
/// own errors its loop reports) is checked no further. `views`: the
/// consumer gives items that may hold views (`collect`, `find`, `min`,
/// `max`, `min_by`, `max_by`), which keep the source viewed.
pub fn chainTypes(self: *Checker, call: Sexp, root: Sexp, kind: rig.ChainSource, zip: rig.ChainSource, views: *bool) Error!bool {
    const a = self.ctx.arena.allocator();
    var calls: std.ArrayList(Sexp) = .empty;
    var at = call;
    while (true) {
        try calls.append(a, at);
        const obj = ir.Member.object(ir.Call.callee(at));
        if (!(obj.isKind(.call) and ir.Call.callee(obj).isKind(.member) and rig.isChainStage(self.text(ir.Member.name(ir.Call.callee(obj)))))) break;
        at = obj;
    }
    std.mem.reverse(Sexp, calls.items);
    var item = try chainSourceItem(self, root, kind);
    // The second value `enumerate` or `zip` passes with each item.
    var second: ?TypeId = null;
    var pairs: enum { none, index, zip } = .none;
    // Whether a `map` made one value of each pair since it began.
    var mapped = false;
    for (calls.items) |c| {
        const callee = ir.Call.callee(c);
        const name_node = ir.Member.name(callee);
        const name = self.text(name_node);
        const args = ir.Call.args(c);
        const what: []const u8 = switch (pairs) {
            .none => "each item",
            .index => "each item and its index",
            .zip => "each item and the item `zip` pairs with it",
        };
        // `min_by` and `max_by`, as `min` and `max`, take each item
        // alone.
        const by = std.mem.eql(u8, name, "min_by") or std.mem.eql(u8, name, "max_by");
        const passes_pair = pairs != .none and !by;
        const known = item != null and (!passes_pair or second != null);
        const params: []const TypeId = if (!known) &.{} else if (!passes_pair) try a.dupe(TypeId, &.{item.?}) else try a.dupe(TypeId, &.{ item.?, second.? });
        // A consumer of the items alone takes one value per item.
        const one_value = by or std.mem.eql(u8, name, "sum") or std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max") or std.mem.eql(u8, name, "collect");
        if (one_value and pairs != .none and !mapped) {
            const stage, const params_shown = if (pairs == .index) .{ "enumerate", "x, i" } else .{ "zip", "x, y" };
            try self.errAt(name_node, "`{s}` takes one value per item, and after `{s}` each item is two: map them to one first, `.map(|{s}| ...).{s}({s})`", .{ name, stage, params_shown, name, if (by) "..." else "" });
            return false;
        }
        const takes_fn = by or std.mem.eql(u8, name, "map") or std.mem.eql(u8, name, "filter") or std.mem.eql(u8, name, "any") or std.mem.eql(u8, name, "all") or std.mem.eql(u8, name, "find");
        if (takes_fn and !try chainArity(self, args[0], name, if (passes_pair) what else "each item", if (passes_pair) 2 else 1)) return false;
        if (std.mem.eql(u8, name, "reduce") and !try chainArity(self, args[1], name, "the running value and each item", 2)) return false;
        const result: ?TypeId = if (takes_fn and known) try chainFnResult(self, args[0], params) else null;
        if (std.mem.eql(u8, name, "map")) {
            if (result) |r| if (r == self.t().void_id) {
                try self.errAt(args[0], "`map`'s function gives each item's new value; this one gives nothing", .{});
                return false;
            };
            item = result;
            mapped = true;
        } else if (std.mem.eql(u8, name, "filter") or std.mem.eql(u8, name, "any") or std.mem.eql(u8, name, "all") or std.mem.eql(u8, name, "find")) {
            if (result) |r| if (sema.unwrapViews(self.ctx, r) != self.t().bool_id) {
                try self.errAt(args[0], "`{s}`'s function gives a `Bool`; this one gives `{s}`", .{ name, try self.tyName(r) });
                return false;
            };
        } else if (std.mem.eql(u8, name, "take") or std.mem.eql(u8, name, "skip")) {
            const n = try FlowCheck.synthQuiet(self, args[0]);
            if (!self.isPoison(n) and !sema.isInteger(self.ctx, CompatCheck.readValue(self.ctx, n))) {
                try self.errAt(args[0], "`{s}` takes a count, an `Int`; `{s}` is a `{s}`", .{ name, try ViewCheck.plainText(self, args[0]), try self.tyName(n) });
                return false;
            }
        } else if (std.mem.eql(u8, name, "enumerate")) {
            pairs = .index;
            mapped = false;
            second = self.t().int_id;
        } else if (std.mem.eql(u8, name, "zip")) {
            pairs = .zip;
            mapped = false;
            second = try chainSourceItem(self, args[0], zip);
        } else if (std.mem.eql(u8, name, "sum")) {
            if (item) |it| if (!sema.isNumeric(self.ctx, CompatCheck.readValue(self.ctx, it))) {
                try self.errAt(name_node, "`sum` adds numbers, and these items are `{s}`s", .{try self.tyName(sema.unwrapViews(self.ctx, it))});
                return false;
            };
        } else if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
            if (item) |it| if (try noOrder(self, it)) |lack| {
                const shown = sema.unwrapViews(self.ctx, it);
                try self.errAt(name_node, "`{s}` compares items with `<`; `{s}` has no order{s}", .{ name, try self.tyName(shown), try sema.lackDetail(self.ctx, a, shown, .Ord, lack) });
                return false;
            };
        } else if (std.mem.eql(u8, name, "min_by") or std.mem.eql(u8, name, "max_by")) {
            if (result) |r| if (try noOrder(self, r)) |lack| {
                const shown = sema.unwrapViews(self.ctx, r);
                try self.errAt(args[0], "`{s}`'s key is compared with `<`; `{s}` has no order{s}", .{ name, try self.tyName(shown), try sema.lackDetail(self.ctx, a, shown, .Ord, lack) });
                return false;
            };
        }
    }
    const last = self.text(ir.Member.name(ir.Call.callee(call)));
    const gives_items = for ([_][]const u8{ "collect", "find", "min", "max", "min_by", "max_by" }) |c| {
        if (std.mem.eql(u8, last, c)) break true;
    } else false;
    if (gives_items) if (item) |it| {
        views.* = sema.mayHoldView(self.ctx, it);
    };
    return true;
}

/// What a chain's source `src`, of kind `kind`, gives each step, as
/// `TypeResolver.chainItemType` gives it: an element read as a `for`
/// reads it, an iterator's `next` item, a range's integer. Null when
/// not known.
pub fn chainSourceItem(self: *Checker, src: Sexp, kind: rig.ChainSource) Error!?TypeId {
    if (kind == .range) {
        // The rewrite holds the bounds; the item takes the first's type.
        const ty = CompatCheck.readValue(self.ctx, try FlowCheck.synthQuiet(self, ir.get(src, .left)));
        if (self.isPoison(ty)) return null;
        return if (ty == self.t().int_literal_id) self.t().int_id else ty;
    }
    const ty = try FlowCheck.synthQuiet(self, src);
    if (self.isPoison(ty)) return null;
    const peeled = sema.unwrapViews(self.ctx, ty);
    if (kind == .iterator) return switch (try sema.iterItem(self.ctx, peeled)) {
        .item => |item| item,
        else => null,
    };
    const elem = switch (self.ctx.types.get(peeled)) {
        .slice => |sl| sl.elem,
        .array => |arr| arr.elem,
        else => sema.listElem(self.ctx, peeled) orelse return null,
    };
    if (sema.copies(self.ctx, elem) == .yes) return elem;
    return try self.ctx.intern(.{ .read_view = elem });
}

/// Whether a chain's function `f` takes no more than the `n` values
/// its stage `name` passes it, `what`: reported when it takes more. A
/// closure may take fewer.
pub fn chainArity(self: *Checker, f: Sexp, name: []const u8, what: []const u8, n: usize) Error!bool {
    if (!f.isKind(.lambda)) return true;
    const takes = ir.Lambda.params(f).items().len;
    if (takes <= n) return true;
    try self.errAt(f, "`{s}` passes its function {s}; this one takes {d} parameters", .{ name, what, takes });
    return false;
}

/// What a chain's function `f` gives, passed `params`: a closure
/// written there, checked quietly; a function's or a closure value's
/// result. Null when not known: a closure's own errors are reported
/// where its loop is checked.
pub fn chainFnResult(self: *Checker, f: Sexp, params: []const TypeId) Error!?TypeId {
    var ty: TypeId = undefined;
    if (f.isKind(.lambda)) {
        const mark = self.ctx.diagnostics.items.len;
        self.ctx.quiet += 1;
        self.tentative += 1;
        defer {
            self.ctx.quiet -= 1;
            self.tentative -= 1;
            self.ctx.diagnostics.shrinkRetainingCapacity(mark);
        }
        const fn_ty = try ClosureCheck.checkLambdaGiven(self, f, null, params, false);
        if (self.ctx.diagnostics.items.len != mark or self.isPoison(fn_ty) or self.ctx.types.get(fn_ty) != .function) return null;
        ty = self.ctx.types.get(fn_ty).function.returns;
    } else {
        const fty = try FlowCheck.synthQuiet(self, f);
        if (self.isPoison(fty)) return null;
        const peeled = sema.unwrapViews(self.ctx, fty);
        if (self.ctx.types.get(peeled) == .function) {
            ty = self.ctx.types.get(peeled).function.returns;
        } else if (sema.callableFnTy(self.ctx, fty)) |c| {
            ty = self.ctx.types.get(c).function.returns;
        } else if (sema.ownedClosureFn(self.ctx, fty)) |o| {
            ty = o.returns;
        } else return null;
    }
    switch (self.ctx.types.get(ty)) {
        .fallible => |fl| ty = fl.ok,
        else => {},
    }
    if (self.isPoison(ty)) return null;
    if (ty == self.t().int_literal_id) return self.t().int_id;
    if (ty == self.t().float_literal_id) return self.t().float_id;
    return ty;
}

/// What `ty`, compared with `<`, lacks to be ordered (`orderedBeside`'s
/// rule), or null when it is.
pub fn noOrder(self: *Checker, ty: TypeId) Error!?sema.Lack {
    const r = sema.unwrapViews(self.ctx, ty);
    if (sema.isNumeric(self.ctx, r) or ExprCheck.isBytes(self, r) or sema.containsTypeVar(self.ctx, r) or sema.isOrderedEnum(self.ctx, r)) return null;
    switch (self.ctx.types.get(r)) {
        .string_view, .static => return null,
        else => {},
    }
    return try sema.lacks(self.ctx, r, .Ord);
}

/// How many errors closure literal `f` has against function type
/// `want`, checked quietly.
pub fn lambdaErrorsQuietly(self: *Checker, f: Sexp, want: TypeId) Error!usize {
    const mark = self.ctx.diagnostics.items.len;
    self.ctx.quiet += 1;
    self.tentative += 1;
    defer {
        self.ctx.quiet -= 1;
        self.tentative -= 1;
        self.ctx.diagnostics.shrinkRetainingCapacity(mark);
    }
    _ = try ClosureCheck.checkLambda(self, f, want);
    return self.ctx.diagnostics.items.len - mark;
}

/// `xs.sum()` and `xs.sum(start: n)`: the elements of a slice, an
/// array, or a List of numbers, added in order to `start`, `0` by
/// default, each as `+` adds; a value of the elements' type. It only
/// reads its self.
pub fn sumCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, peeled: TypeId, elem: TypeId, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    switch (self.ctx.types.get(peeled)) {
        .string_view, .static => return CallCheck.badCall(self, args, obj, "`sum` adds numbers, and `{s}` is text", .{try self.tyName(obj_ty)}),
        else => {},
    }
    if (ct) |b| return CallCheck.badCall(self, args, b, "`sum` takes no compile-time arguments", .{});
    if (ViewCheck.isSelfSigil(self, obj) and !obj.isKind(.read)) try ViewCheck.misplacedSigil(self, obj, "sum", "only reads its elements");
    const numeric = switch (self.ctx.types.get(elem)) {
        .int, .float => true,
        // Each instance's `+` (`Num`), as an operator's on a `T`.
        .type_var => |param| blk: {
            try ExprCheck.require(self, self.ctx.localSym(param), .numeric, pos, "sum");
            break :blk true;
        },
        else => false,
    };
    if (!numeric) return CallCheck.badCall(self, args, obj, "`sum` adds numbers: an `Int`, a `Float`, or a sized integer or float; the elements of `{s}` are `{s}`", .{ try self.tyName(obj_ty), try self.tyName(elem) });
    if (args.len > 1 or (args.len == 1 and !(args[0].isKind(.kwarg) and std.mem.eql(u8, self.text(ir.Kwarg.name(args[0])), "start")))) {
        return CallCheck.badCall(self, args, pos, "`sum` takes only a starting value, by name: `xs.sum(start: 10)`", .{});
    }
    const recv = try self.ctx.intern(.{ .read_view = peeled });
    const params: []const TypeId = if (args.len == 1) &.{ recv, elem } else &.{recv};
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(params), .returns = elem, .is_sub = false });
    try self.ctx.recordElemCall(callee, .{ .op = .sum, .elem = elem });
    // `mk().sum()` reads a temporary, dropped when its statement ends.
    if (ViewCheck.isTemporary(self, obj)) try ViewCheck.viewTemp(self, obj);
    if (args.len == 1) try ViewCheck.checkExpr(self, ir.get(args[0], .value), elem);
    return elem;
}

/// `xs.prefetch(i)`: a hint that element `i` of a slice, an array, or a
/// List will be read soon, which does nothing a program can see, so
/// its index is any integer, never checked against the length. It
/// reads its self for the call and gives nothing.
pub fn prefetchCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, peeled: TypeId, elem: TypeId, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    switch (self.ctx.types.get(peeled)) {
        .string_view, .static => return CallCheck.badCall(self, args, obj, "`prefetch` asks for an element of a List, an array, or a slice, and `{s}` is text", .{try self.tyName(obj_ty)}),
        else => {},
    }
    if (ct) |b| return CallCheck.badCall(self, args, b, "`prefetch` takes no compile-time arguments", .{});
    if (ViewCheck.isSelfSigil(self, obj) and !obj.isKind(.read)) try ViewCheck.misplacedSigil(self, obj, "prefetch", "only reads its elements");
    if (args.len != 1 or args[0].isKind(.kwarg)) {
        return CallCheck.badCall(self, args, pos, "`prefetch` takes one argument, the index of the element to fetch; got {d} argument{s}", .{ args.len, if (args.len == 1) "" else "s" });
    }
    const recv = try self.ctx.intern(.{ .read_view = peeled });
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(&.{ recv, self.t().int_id }), .returns = self.t().void_id, .is_sub = true });
    try self.ctx.recordElemCall(callee, .{ .op = .prefetch, .elem = elem });
    // `mk().prefetch(i)` reads a temporary, dropped when its statement ends.
    if (ViewCheck.isTemporary(self, obj)) try ViewCheck.viewTemp(self, obj);
    try checkIndexArg(self, args[0], null);
    return self.t().void_id;
}

/// `bytes.read[T, e](at)` and `!bytes.write[T, e](at, v)`: the integer
/// or float `T` held in the `$size(T)` bytes from `at`, in byte
/// order `e`, a compile-time `Endian`. The bytes are a `[]U8`, an
/// `![]U8`, a `[N]U8`, a `List[U8]`, or (for `read`) a `?String`; `at` is
/// checked now against an array's length when it is constant, and
/// when the program runs otherwise.
pub fn bytesCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, elem: TypeId, len: ?u64, op: sema.ElemOp, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    const method = @tagName(op);
    const peeled = sema.unwrapViews(self.ctx, obj_ty);
    const byte = try ViewCheck.byteType(self);
    if (elem != byte) return CallCheck.badCall(self, args, obj, "`{s}` works on bytes: a `[]U8`, an `![]U8`, a `[N]U8`, a `List[U8]`, or a `?String`; got `{s}`", .{ method, try self.tyName(obj_ty) });
    if (op == .write) {
        if (!try writesElements(self, obj, obj_ty, peeled, method)) return CallCheck.skipCall(self, args);
    } else if (ViewCheck.isSelfSigil(self, obj) and !obj.isKind(.read)) try ViewCheck.misplacedSigil(self, obj, method, "only reads `self`");
    const example = if (op == .read) "read[U32, .little](at)" else "write[U32, .little](at, value)";
    const b = ct orelse return CallCheck.badCall(self, args, pos, "`{s}` takes the type and the byte order in brackets: `{s}`", .{ method, example });
    try self.ctx.recordInstance(b, .function);
    const given = sema.bracketArgs(b);
    if (given.len < 1 or given.len > 2) return CallCheck.badCall(self, args, b, "`{s}` takes the type and the byte order, in brackets: `{s}`", .{ method, example });
    const num = try CallCheck.typeArg(self, given[0]);
    if (self.isPoison(num)) return CallCheck.skipCall(self, args);
    // A vector of numbers is read lane by lane, each lane in the byte
    // order; a value of one byte, or a vector of one-byte lanes, has
    // none.
    const lanes = if (sema.simdOf(self.ctx, num)) |v| v.elem else null;
    var one_byte = false;
    switch (self.ctx.types.get(lanes orelse num)) {
        .int => |info| one_byte = CompatCheck.intBounds(info).bits == 8,
        .float => {},
        // A type parameter: each instance must be a number.
        .type_var => |param| try ExprCheck.require(self, self.ctx.localSym(param), .bytes, self.startOf(given[0]), method),
        else => return CallCheck.badCall(self, args, given[0], "`{s}` {s} an integer or float type, or a `Simd` of them; got `{s}`", .{ method, if (op == .read) "reads" else "writes", try self.tyName(num) }),
    }
    if (one_byte) {
        if (given.len == 2) return CallCheck.badCall(self, args, given[1], "`{s}` of {s}`{s}`{s} takes no byte order: `{s}[{s}]{s}`", .{ method, if (lanes == null) "a one-byte " else "", try self.tyName(num), if (lanes == null) "" else ", whose lanes are one byte,", method, try self.tyName(num), if (op == .read) "(at)" else "(at, value)" });
    } else if (given.len != 2) {
        return CallCheck.badCall(self, args, b, "`{s}` of a `{s}` takes a byte order too: `{s}`", .{ method, try self.tyName(num), example });
    } else {
        const endian = try self.ctx.intern(.{ .nominal = self.ctx.builtins.endian });
        try self.checkCtValue(given[1], endian, 1, method);
    }
    for (args) |a| if (a.isKind(.kwarg)) return CallCheck.badCall(self, args, a, "`{s}` takes no keyword arguments", .{method});
    const want: usize = if (op == .read) 1 else 2;
    if (args.len != want) return CallCheck.badCall(self, args, pos, "`{s}` takes {s}; got {d} argument{s}", .{ method, if (op == .read) "one argument, the offset of the first byte" else "two arguments, the offset of the first byte and the value", args.len, if (args.len == 1) "" else "s" });
    const recv = try self.ctx.intern(if (op == .read) Type{ .read_view = peeled } else Type{ .write_view = peeled });
    const params: []const TypeId = if (op == .read) &.{ recv, self.t().int_id } else &.{ recv, self.t().int_id, num };
    const returns = if (op == .read) num else self.t().void_id;
    try noteCallee(self, .{ .params = try self.ctx.dupeIds(params), .returns = returns, .is_sub = op == .write });
    try self.ctx.recordElemCall(callee, .{ .op = op, .elem = elem, .num = num });
    try checkOffsetArg(self, args[0], num, len, method);
    if (op == .write) try ViewCheck.checkExpr(self, args[1], num);
    return returns;
}

/// The offset of a `read` or `write` of a `num`: an integer, checked
/// now against a known length when it is constant.
pub fn checkOffsetArg(self: *Checker, a: Sexp, num: TypeId, len: ?u64, method: []const u8) Error!void {
    const ty = try ViewCheck.synthValue(self, a);
    if (self.isPoison(ty)) return;
    if (!sema.isInteger(self.ctx, ty)) return self.errAt(a, "an offset must be an integer; got `{s}`", .{try self.tyName(ty)});
    if (ty == self.t().int_literal_id) try ViewCheck.defaultIntLiteral(self, a);
    const at = ExprCheck.constInt(self, a) orelse return;
    const size: Wide = switch (self.ctx.types.get(num)) {
        .int => |i| if (i.bits == 0) 8 else i.bits / 8,
        .float => |f| if (f.bits == 0) 8 else f.bits / 8,
        .simd => |v| @intCast(((try sema.minBytes(self.ctx, v.elem)) orelse return) * (sema.simdLen(self.ctx, v) orelse return)),
        else => return,
    };
    if (at < 0) return self.errAt(a, "an offset cannot be negative; got `{d}`", .{at});
    if (len) |n| if (at + size > n) {
        try self.errAt(a, "`{s}` of a `{s}` at `{d}` runs past the end of an array of length {d}: it needs {d} bytes", .{ method, try self.tyName(num), at, n, size });
    };
}

/// An index argument: an integer (`Int` when that is all a literal
/// says), checked now against a known length when it is constant.
pub fn checkIndexArg(self: *Checker, a: Sexp, len: ?u64) Error!void {
    const ty = try ViewCheck.synthValue(self, a);
    if (self.isPoison(ty)) return;
    if (!sema.isInteger(self.ctx, ty)) return self.errAt(a, "an index must be an integer; got `{s}`{s}", .{ try self.tyName(ty), try FlowCheck.loopOrderHint(self, a, self.t().int_id) });
    if (ty == self.t().int_literal_id) try ViewCheck.defaultIntLiteral(self, a);
    if (len) |n| if (ExprCheck.constInt(self, a)) |i| if (i < 0 or i >= n) {
        try self.errAt(a, "index `{d}` is out of bounds for an array of length {d}", .{ i, n });
    };
}

/// The self of a method that writes the elements of `peeled` (a
/// slice, an array, or a List): a `![]T`, or a place written `!xs`.
/// False after a diagnostic.
pub fn writesElements(self: *Checker, obj: Sexp, obj_ty: TypeId, peeled: TypeId, method: []const u8) Error!bool {
    switch (self.ctx.types.get(peeled)) {
        .string_view, .static => {
            try self.errAt(obj, "cannot `{s}` a `?String`; a `?String` is read-only", .{method});
            return false;
        },
        .slice => if (sema.writeSliceElem(self.ctx, obj_ty) == null) {
            try self.errAt(obj, "cannot `{s}` a `{s}`; its elements are read-only (a writable slice is a `![]T`)", .{ method, try self.tyName(obj_ty) });
            return false;
        },
        else => {},
    }
    // `!xs.fill(v)`: the write view took the checks.
    if (obj.isKind(.write)) return true;
    const place = if (obj.isKind(.read) or obj.isKind(.move)) ir.get(obj, .operand) else obj;
    // A self `!` could not write (through a `*T` or `?T`, or of
    // a parameter) is reported as such, not with a `!` to add.
    if (!try StmtCheck.requireAccess(self, StmtCheck.placeOf(self, place), .write_viewed, obj)) return false;
    const shown = try ViewCheck.plainText(self, place);
    const viewed = if (ViewCheck.sigilReaches(place)) try self.ctx.arena.allocator().print("!{s}", .{shown}) else try self.ctx.arena.allocator().print("!({s})", .{shown});
    try self.errAt(obj, "`{s}` writes the elements; make a write view of `self` with `!`: `{s}`", .{ method, try FlowCheck.callWith(self, obj, viewed, method) });
    return false;
}

/// The error set a wait for work failing with `sets` fails with: the
/// one of them that holds every other and `task.Stop`, which every
/// wait may also fail with (`sema.setHoldsStop`); `error` when none
/// does, or one is `error` or a set parameter. The one rule for
/// `task.all`, `par.map` and `par.each`, and `task.isolate` and
/// `task.supervise`, whose runtime fails with the sets joined and
/// `task.Stop` (`rig.WaitErr`).
pub fn waitSet(self: *Checker, sets: []const TypeId) Error!TypeId {
    const any = self.t().any_error_id;
    for (sets) |set| if (set == any or self.isPoison(set) or sema.isSetParam(self.ctx, set)) return any;
    for (sets) |held| {
        if (!try sema.setHoldsStop(self.ctx, held, self.ctx.arena.allocator())) continue;
        const holds_all = for (sets) |other| {
            if (!sema.errorSubset(self.ctx, other, held)) break false;
        } else true;
        if (holds_all) return held;
    }
    return any;
}

/// A call of a std function the checker types itself, since Rig cannot
/// declare it (`task.all`, `isolate`, `supervise`, `select`,
/// `par.map`, `each`, `workers`, `http.serve`, `io.copy`): its type.
/// Null for any other call of module `module_sym`. One lookup of the
/// module for every call through one.
pub fn stdForm(self: *Checker, module_sym: SymbolId, name: []const u8, pos: u32, args: []const Sexp) Error!?TypeId {
    const module = stdModule(self, module_sym) orelse return null;
    const eql = std.mem.eql;
    if (eql(u8, module, "std.task")) {
        if (eql(u8, name, "all")) return try taskJoin(self, pos, args);
        if (eql(u8, name, "select")) return try taskSelect(self, pos, args);
        if (eql(u8, name, "isolate") or eql(u8, name, "supervise")) return try isolateCall(self, eql(u8, name, "supervise"), pos, args);
    } else if (eql(u8, module, "std.par")) {
        if (eql(u8, name, "workers")) return try parWorkers(self, pos, args);
        if (eql(u8, name, "map")) return try parCall(self, .map, pos, args);
        if (eql(u8, name, "each")) return try parCall(self, .each, pos, args);
        if (eql(u8, name, "push")) return try parPush(self, pos, args);
    } else if (eql(u8, module, "std.http")) {
        if (eql(u8, name, "serve")) return try httpServe(self, module_sym, pos, args);
    } else if (eql(u8, module, "std.io")) {
        if (eql(u8, name, "copy")) return try ioCopy(self, pos, args);
    } else if (eql(u8, module, "std.time")) {
        if (eql(u8, name, "after")) return try CallCheck.badCall(self, args, pos, "`after` makes a deadline arm of `task.select`, and stands only as one of its arguments: `task.select(late: time.after(ms: 50), ...)`", .{});
    }
    return null;
}

/// `task.all(a, b, ...)` of `std.task`: wait for tasks of any types,
/// which the call takes, and give each one's value as several
/// results, or nothing when no task gives a value, as a `sub` does;
/// either way failing when any task can. A task of a type parameter's
/// type gives a value, `T`, whatever an instance binds it to, so a
/// generic body is typed, and emitted, once for every instance.
/// Tasks that give values and tasks that give none do not mix:
/// several results with holes would be a shape of its own. Which the
/// call gives is recorded (`recordTaskJoin`) for emit and the runtime.
/// Rig declares no function of any number of arguments, so the call
/// is typed here, its parameters the tasks' own types (`argType`).
pub fn taskJoin(self: *Checker, pos: u32, args: []const Sexp) Error!TypeId {
    const name = "all";
    if (args.len < 2) return try CallCheck.badCall(self, args, pos, "`task.all` waits for two tasks or more, `task.all(f(x)&, g(y)&, h(z)&)`; for one, `>t`", .{});
    const a = self.ctx.arena.allocator();
    const params = try a.alloc(TypeId, args.len);
    const parts = try a.alloc(TypeId, args.len);
    var sets: std.ArrayList(TypeId) = .empty;
    var fails = false;
    // The first task that gives a value, and the first that gives none.
    var valued: ?Sexp = null;
    var valueless: ?Sexp = null;
    for (args, params, parts) |arg, *p, *part| {
        if (arg.isKind(.kwarg)) return try CallCheck.badCall(self, args, arg, "`task.{s}` takes its tasks in order, with no names", .{name});
        const ty = try CallCheck.argType(self, arg);
        if (self.isPoison(ty)) return try CallCheck.skipCall(self, args);
        if (!sema.isTask(self.ctx, ty)) return try CallCheck.badCall(self, args, arg, "`task.{s}` waits for tasks, and `{s}` is a `{s}`: make the call a task, `f(x)&`", .{ name, CallCheck.sourceText(self, arg), try self.tyName(ty) });
        const gives = sema.taskResult(self.ctx, ty).?;
        const can_fail = self.ctx.types.get(gives) == .fallible;
        const value = if (can_fail) self.ctx.types.get(gives).fallible.ok else gives;
        if (value == self.t().void_id) {
            if (valueless == null) valueless = arg;
        } else if (valued == null) valued = arg;
        if (valued != null and valueless != null) return try CallCheck.badCall(self, args, arg, "`task.{s}` gives each task's value, or nothing when none gives one, and `{s}` gives none while `{s}` gives one: wait for the tasks that give none in a `task.{s}` of their own, or each on its own, `>t`", .{ name, CallCheck.sourceText(self, valueless.?), CallCheck.sourceText(self, valued.?), name });
        fails = fails or can_fail;
        if (can_fail) try sets.append(a, self.ctx.types.get(gives).fallible.set);
        p.* = ty;
        part.* = value;
    }
    const gives = if (valued == null) self.t().void_id else try self.ctx.intern(.{ .results = try self.ctx.dupeIds(parts) });
    const result = if (fails) try self.ctx.intern(.{ .fallible = .{ .ok = gives, .set = try waitSet(self, sets.items) } }) else gives;
    const f: FunctionType = .{ .params = try self.ctx.dupeIds(params), .returns = result, .is_sub = valued == null };
    try noteCallee(self, f);
    try CallCheck.checkArgs(self, args, f, .{}, try a.print("task.{s}", .{name}), pos, .{ .declared = f.params });
    if (self.expect.current_call) |call| try self.ctx.recordTaskJoin(call, valued != null);
    return result;
}

/// `par.map(?xs, f, limit: n)` and `par.each(!xs, f, limit: n)` of
/// `std.par`: call `f` on each element of `xs`, on up to `n` tasks at
/// once. `map` gives each call's value, in the order of `xs`; `each`
/// writes each element. When `f` can fail, so can the call. The call
/// is typed here, as `taskJoin` types its own: `f` is a closure written
/// in the call, whose result decides whether it fails, or a function's
/// name. Every task reads what `f` captures, and `map`'s elements, so
/// these must sync; `each`'s elements and `map`'s values go to other
/// tasks, so these must be sendable.
pub fn parCall(self: *Checker, kind: sema.ParCall, pos: u32, args: []const Sexp) Error!TypeId {
    const shown = if (kind == .map) "par.map" else "par.each";
    const example = if (kind == .map) "par.map(?xs, |x| x * 2)" else "par.each(!xs, |x| x *= 2)";
    var positional: usize = 0;
    for (args) |a| {
        if (!a.isKind(.kwarg)) {
            positional += 1;
            continue;
        }
        if (!std.mem.eql(u8, self.text(ir.Kwarg.name(a)), "limit")) return try CallCheck.badCall(self, args, a, "`{s}` takes the elements, a function, and at most `limit:`, how many tasks run at once: `{s}`", .{ shown, example });
    }
    if (positional != 2 or args.len > 3) return try CallCheck.badCall(self, args, pos, "`{s}` takes the elements and a function, `{s}`, and `limit:`, how many tasks run at once", .{ shown, example });
    // The function comes second, or last, after `limit:`, when it is a
    // closure written there (`trailingParam`).
    const xs = args[0];
    const f = if (CallCheck.hasTrailingClosure(args)) args[args.len - 1] else args[1];
    if (xs.isKind(.kwarg) or f.isKind(.kwarg)) return try CallCheck.badCall(self, args, if (xs.isKind(.kwarg)) xs else f, "positional arguments must come before keyword arguments: `{s}` takes the elements, then the function, `{s}(?xs, f, limit: n)`, or `limit:` before a closure written last, `{s}(?xs, limit: n, |x| ...)`", .{ shown, shown, shown });
    const xs_ty = try CallCheck.argType(self, xs);
    if (self.isPoison(xs_ty)) return try CallCheck.skipCall(self, args);
    const elem = (if (kind == .each) sema.writeSliceElem(self.ctx, xs_ty) else null) orelse sema.viewedElem(self.ctx, xs_ty) orelse switch (self.ctx.types.get(xs_ty)) {
        .slice => |sl| sl.elem,
        else => return try CallCheck.badCall(self, args, xs, "`{s}` runs over the elements of a List, an array, or a slice; `{s}` is a `{s}`", .{ shown, CallCheck.sourceText(self, xs), try self.tyName(xs_ty) }),
    };
    if (kind == .each and !xs.isKind(.write) and self.ctx.types.get(xs_ty) != .write_view) {
        const place = try ViewCheck.plainText(self, CompatCheck.stripSigil(xs));
        return try CallCheck.badCall(self, args, xs, "`par.each` passes each element as a write view: make write views of the elements, `par.each(!{s}, ...)`", .{place});
    }
    const slice = try self.ctx.intern(.{ .slice = .{ .elem = elem } });
    const xs_param = if (kind == .map) slice else try self.ctx.intern(.{ .write_view = slice });
    const each_param = try self.ctx.intern(if (kind == .map) Type{ .read_view = elem } else Type{ .write_view = elem });
    var fn_ty = (try parFunction(self, kind, f, &.{each_param}, shown)) orelse return try CallCheck.skipCall(self, args);
    const returns = self.ctx.types.get(fn_ty).function.returns;
    const fails = self.ctx.types.get(returns) == .fallible;
    // A closure that gives a view of a value that copies gives the
    // value, as a generic call's result binds it (`readValue`).
    const value = CompatCheck.readValue(self.ctx, if (fails) self.ctx.types.get(returns).fallible.ok else returns);
    if (self.isPoison(value)) return try CallCheck.skipClosureCall(self, args, f, &.{each_param}, kind == .each);
    if (kind == .map and sema.holdsWriteView(self.ctx, value)) return try givesWriteView(self, args, f, &.{each_param}, shown, value, "x");
    if (kind == .map and f.isKind(.lambda)) {
        const gives = if (fails) try self.ctx.intern(.{ .fallible = .{ .ok = value } }) else value;
        fn_ty = try self.ctx.intern(.{ .function = .{ .params = try self.ctx.dupeIds(&.{each_param}), .returns = gives, .is_sub = false } });
    }
    const result = switch (kind) {
        .map => blk: {
            if (value == self.t().void_id) {
                try self.errAt(f, "`par.map` gives each call's value, and `{s}` gives none: to call it on each element, `par.each(!xs, ...)`", .{CallCheck.sourceText(self, f)});
                return try CallCheck.skipClosureCall(self, args, f, &.{each_param}, false);
            }
            const list = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.builtins.list, .args = try self.ctx.dupeIds(&.{value}) } });
            break :blk if (fails) try self.ctx.intern(.{ .fallible = .{ .ok = list, .set = try waitSet(self, &.{self.ctx.types.get(returns).fallible.set}) } }) else list;
        },
        .each => if (fails) try self.ctx.intern(.{ .fallible = .{ .ok = self.t().void_id, .set = try waitSet(self, &.{self.ctx.types.get(returns).fallible.set}) } }) else self.t().void_id,
        .workers, .push => unreachable,
    };
    const params: []const TypeId = &.{ xs_param, try sema.callableOfFn(self.ctx, fn_ty), self.t().int_id };
    const call: FunctionType = .{ .params = try self.ctx.dupeIds(params[0..args.len]), .returns = result, .is_sub = kind == .each };
    try noteCallee(self, call);
    try CallCheck.checkArgs(self, args, call, .{ .names = &.{ "xs", "f", "limit" } }, shown, pos, .{ .declared = call.params });
    // Each task reads what `f` captures, and `map`'s elements; `each`'s
    // elements and `map`'s values go to the tasks that make them.
    if (f.isKind(.lambda)) for (sema.captureList(ir.Lambda.captures(f))) |cap| {
        if (!try parCapture(self, cap, shown)) return self.t().invalid_id;
    };
    const how: sema.Crossing = if (kind == .map) .shares else .moves;
    if (try sema.crossingBlocker(self.ctx, elem, how)) |blocker| {
        if (try statedCrossing(self, blocker, how, self.startOf(xs))) return self.t().invalid_id;
        try self.errAt(xs, "`{s}` hands the elements of `{s}` to tasks that may run on other cores, {s} each, and `{s}` {s}", .{ shown, CallCheck.sourceText(self, xs), if (kind == .map) "to read" else "to write", try self.tyName(elem), try blockerReason(self, blocker, kind == .map, if (blocker == elem) "is" else null) });
        return self.t().invalid_id;
    }
    try requireTask(self, elem, how, self.startOf(xs), if (kind == .map) "is passed to tasks as a read view" else "is passed to tasks as a write view", false);
    if (kind == .map) {
        if (try sema.crossingBlocker(self.ctx, value, .moves)) |blocker| {
            if (try statedCrossing(self, blocker, .moves, self.startOf(f))) return self.t().invalid_id;
            try self.errAt(f, "`par.map` gathers the values that tasks on other cores make, and `{s}` {s}", .{ try self.tyName(value), try blockerReason(self, blocker, false, if (blocker == value) "is" else null) });
            return self.t().invalid_id;
        }
        try requireTask(self, value, .moves, self.startOf(f), "is given back by a task", false);
    }
    if (self.expect.current_call) |c| try self.ctx.recordParCall(c, kind);
    self.ctx.makes_tasks = true;
    return closureResult(self, f, result);
}

/// Reports `f`, the function `par.map` or `par.workers` (`shown`)
/// calls, whose value `value` holds a write view, which nothing the
/// call gives back may hold: it would reach what a task was given a
/// write view of after the task, beside the owner's own view. `copied`
/// is how the closure's parameter is spelled in the hint, and `params`
/// what `f` takes (`skipClosureCall`).
pub fn givesWriteView(self: *Checker, args: []const Sexp, f: Sexp, params: []const TypeId, shown: []const u8, value: TypeId, copied: []const u8) Error!TypeId {
    const how = if (self.ctx.types.get(value) == .write_view) "is" else "holds";
    try self.errAt(f, "`{s}` gives back each call's value, and `{s}` {s} a write view, which no value it gives back may hold: give a copy, `+{s}`, or a value made from it", .{ shown, try self.tyName(value), how, copied });
    return try CallCheck.skipClosureCall(self, args, f, params, false);
}

/// `par.workers(!states, ?items, f)` of `std.par`: one task for each
/// state, each calling `f(!s, x)` with its own state on the next item
/// it takes, in the order of `items`, until none is left. It gives each
/// call's value in the order of the items, or nothing when `f` gives
/// nothing; when `f` can fail, so can the call. Typed here, as
/// `parCall` types `map` and `each`: each state goes to one task to
/// write, so it must be sendable, as `each`'s elements; every task
/// reads the items and what `f` captures, so these must sync, as
/// `map`'s; and the values come from other tasks, so they must be
/// sendable.
pub fn parWorkers(self: *Checker, pos: u32, args: []const Sexp) Error!TypeId {
    const shown = "par.workers";
    const example = "par.workers(!states, ?items, |s, x| ...)";
    for (args) |a| if (a.isKind(.kwarg)) return try CallCheck.badCall(self, args, a, "`par.workers` runs one task for each state, and takes the states, the items, and a function: `{s}`", .{example});
    if (args.len != 3) return try CallCheck.badCall(self, args, pos, "`par.workers` takes the states, the items, and a function, `{s}`", .{example});
    const states = args[0];
    const items = args[1];
    const f = args[2];
    const states_ty = try CallCheck.argType(self, states);
    if (self.isPoison(states_ty)) return try CallCheck.skipCall(self, args);
    const state = sema.writeSliceElem(self.ctx, states_ty) orelse sema.viewedElem(self.ctx, states_ty) orelse switch (self.ctx.types.get(states_ty)) {
        .slice => |sl| sl.elem,
        else => return try CallCheck.badCall(self, args, states, "`par.workers` gives each task one of the states, the elements of a List, an array, or a slice; `{s}` is a `{s}`", .{ CallCheck.sourceText(self, states), try self.tyName(states_ty) }),
    };
    if (!states.isKind(.write) and self.ctx.types.get(states_ty) != .write_view) {
        const place = try ViewCheck.plainText(self, CompatCheck.stripSigil(states));
        return try CallCheck.badCall(self, args, states, "`par.workers` gives each task a write view of one state: make write views of the states, `par.workers(!{s}, ...)`", .{place});
    }
    const items_ty = try CallCheck.argType(self, items);
    if (self.isPoison(items_ty)) return try CallCheck.skipCall(self, args);
    const item = sema.viewedElem(self.ctx, items_ty) orelse switch (self.ctx.types.get(items_ty)) {
        .slice => |sl| sl.elem,
        else => return try CallCheck.badCall(self, args, items, "`par.workers` takes the items from a List, an array, or a slice; `{s}` is a `{s}`", .{ CallCheck.sourceText(self, items), try self.tyName(items_ty) }),
    };
    const states_param = try self.ctx.intern(.{ .write_view = try self.ctx.intern(.{ .slice = .{ .elem = state } }) });
    const items_param = try self.ctx.intern(.{ .slice = .{ .elem = item } });
    const state_param = try self.ctx.intern(.{ .write_view = state });
    const item_param = try self.ctx.intern(.{ .read_view = item });
    var fn_ty = (try parFunction(self, .workers, f, &.{ state_param, item_param }, shown)) orelse return try CallCheck.skipCall(self, args);
    const returns = self.ctx.types.get(fn_ty).function.returns;
    const fails = self.ctx.types.get(returns) == .fallible;
    // A closure that gives a view of a value that copies gives the
    // value, as a generic call's result binds it (`readValue`).
    const value = CompatCheck.readValue(self.ctx, if (fails) self.ctx.types.get(returns).fallible.ok else returns);
    if (self.isPoison(value)) return try CallCheck.skipClosureCall(self, args, f, &.{ state_param, item_param }, false);
    const none = value == self.t().void_id;
    // A write view given back would reach a task's state, or what it
    // holds, after the task, beside the state's own.
    if (sema.holdsWriteView(self.ctx, value)) return try givesWriteView(self, args, f, &.{ state_param, item_param }, shown, value, "s");
    if (f.isKind(.lambda)) {
        const gives = if (fails) try self.ctx.intern(.{ .fallible = .{ .ok = value } }) else value;
        fn_ty = try self.ctx.intern(.{ .function = .{ .params = try self.ctx.dupeIds(&.{ state_param, item_param }), .returns = gives, .is_sub = none } });
    }
    const ok = if (none) value else try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.builtins.list, .args = try self.ctx.dupeIds(&.{value}) } });
    const result = if (fails) try self.ctx.intern(.{ .fallible = .{ .ok = ok, .set = try waitSet(self, &.{self.ctx.types.get(returns).fallible.set}) } }) else ok;
    const call: FunctionType = .{ .params = try self.ctx.dupeIds(&.{ states_param, items_param, try sema.callableOfFn(self.ctx, fn_ty) }), .returns = result, .is_sub = none };
    try noteCallee(self, call);
    // The call stores nothing in the states but what the closure
    // stores there, a view of what it captures: never an item, which
    // no state may keep past its call.
    try CallCheck.checkArgs(self, args, call, .{ .names = &.{ "states", "items", "f" } }, shown, pos, .{ .declared = call.params, .origins = .{ .stores = sema.paramBit(2) } });
    // Every task reads what `f` captures and the items; each state
    // goes to one task, and each value comes from one.
    if (f.isKind(.lambda)) for (sema.captureList(ir.Lambda.captures(f))) |cap| {
        if (!try parCapture(self, cap, shown)) return self.t().invalid_id;
    };
    if (try sema.crossingBlocker(self.ctx, state, .moves)) |blocker| {
        if (try statedCrossing(self, blocker, .moves, self.startOf(states))) return self.t().invalid_id;
        try self.errAt(states, "`par.workers` hands each of `{s}` to a task that may run on another core, to write, and `{s}` {s}", .{ CallCheck.sourceText(self, states), try self.tyName(state), try blockerReason(self, blocker, false, if (blocker == state) "is" else null) });
        return self.t().invalid_id;
    }
    try requireTask(self, state, .moves, self.startOf(states), "is passed to a task as a write view", false);
    if (try sema.crossingBlocker(self.ctx, item, .shares)) |blocker| {
        if (try statedCrossing(self, blocker, .shares, self.startOf(items))) return self.t().invalid_id;
        try self.errAt(items, "`par.workers` hands the items of `{s}` to tasks that may run on other cores, to read, and `{s}` {s}", .{ CallCheck.sourceText(self, items), try self.tyName(item), try blockerReason(self, blocker, true, if (blocker == item) "is" else null) });
        return self.t().invalid_id;
    }
    try requireTask(self, item, .shares, self.startOf(items), "is passed to tasks as a read view", false);
    if (!none) {
        if (try sema.crossingBlocker(self.ctx, value, .moves)) |blocker| {
            if (try statedCrossing(self, blocker, .moves, self.startOf(f))) return self.t().invalid_id;
            try self.errAt(f, "`par.workers` gathers the values that tasks on other cores make, and `{s}` {s}", .{ try self.tyName(value), try blockerReason(self, blocker, false, if (blocker == value) "is" else null) });
            return self.t().invalid_id;
        }
        try requireTask(self, value, .moves, self.startOf(f), "is given back by a task", false);
    }
    if (self.expect.current_call) |c| try self.ctx.recordParCall(c, .workers);
    self.ctx.makes_tasks = true;
    return closureResult(self, f, result);
}

/// `par.push(!t, ?sizes, f, limit: n)` of `std.par`: push
/// `sizes.sum()` slots onto the table `t` at once, then call
/// `f(!run, k)` for each run `k`, the next `sizes[k]` of those slots
/// in order, on up to `n` tasks at once. It is `par.each` over the
/// runs, typed as `parCall` types it: the runs are disjoint slices of
/// the slots `t` owns, each a write view for one task, so `T` must be
/// sendable, as `each`'s elements; every task reads what `f` captures,
/// so these must sync. `f` gives nothing; when it can fail, so can the
/// call. `t` is an ordinary `!` argument, a write view for the call.
pub fn parPush(self: *Checker, pos: u32, args: []const Sexp) Error!TypeId {
    const shown = "par.push";
    const example = "par.push(!t, ?sizes, |run, k| ...)";
    var positional: usize = 0;
    for (args) |a| {
        if (!a.isKind(.kwarg)) {
            positional += 1;
            continue;
        }
        if (!std.mem.eql(u8, self.text(ir.Kwarg.name(a)), "limit")) return try CallCheck.badCall(self, args, a, "`par.push` takes the table, the sizes of the runs, a function, and at most `limit:`, how many tasks run at once: `{s}`", .{example});
    }
    if (positional != 3 or args.len > 4) return try CallCheck.badCall(self, args, pos, "`par.push` takes the table, the sizes of the runs, and a function, `{s}`, and `limit:`, how many tasks run at once", .{example});
    const table_arg = args[0];
    const sizes = args[1];
    // The function comes third, or last, after `limit:`, when it is a
    // closure written there (`trailingParam`).
    const f = if (CallCheck.hasTrailingClosure(args)) args[args.len - 1] else args[2];
    for ([_]Sexp{ table_arg, sizes, f }) |a| if (a.isKind(.kwarg)) return try CallCheck.badCall(self, args, a, "positional arguments must come before keyword arguments: `par.push` takes the table, the sizes, then the function, `par.push(!t, ?sizes, f, limit: n)`, or `limit:` before a closure written last, `par.push(!t, ?sizes, limit: n, |run, k| ...)`", .{});
    const t_ty = try CallCheck.argType(self, table_arg);
    if (self.isPoison(t_ty)) return try CallCheck.skipCall(self, args);
    const table = sema.unwrapViews(self.ctx, t_ty);
    const elem = sema.tableElem(self.ctx, table) orelse return try CallCheck.badCall(self, args, table_arg, "`par.push` pushes the next slots of a Table; `{s}` is a `{s}`", .{ CallCheck.sourceText(self, table_arg), try self.tyName(t_ty) });
    if (!table_arg.isKind(.write) and self.ctx.types.get(t_ty) != .write_view) {
        const place = try ViewCheck.plainText(self, CompatCheck.stripSigil(table_arg));
        return try CallCheck.badCall(self, args, table_arg, "`par.push` pushes slots onto the table and writes them: pass a write view of it, `par.push(!{s}, ...)`", .{place});
    }
    const sizes_ty = try CallCheck.argType(self, sizes);
    if (self.isPoison(sizes_ty)) return try CallCheck.skipCall(self, args);
    const size = sema.viewedElem(self.ctx, sizes_ty) orelse switch (self.ctx.types.get(sema.unwrapViews(self.ctx, sizes_ty))) {
        .slice => |sl| sl.elem,
        else => null,
    };
    if (size != self.t().int_id) return try CallCheck.badCall(self, args, sizes, "`par.push` takes the size of each run as an `Int`, from a List, an array, or a slice; `{s}` is a `{s}`", .{ CallCheck.sourceText(self, sizes), try self.tyName(sizes_ty) });
    const t_param = try self.ctx.intern(.{ .write_view = table });
    const sizes_param = try self.ctx.intern(.{ .slice = .{ .elem = self.t().int_id } });
    const run_param = try self.ctx.intern(.{ .write_view = try self.ctx.intern(.{ .slice = .{ .elem = elem } }) });
    const fn_ty = (try parFunction(self, .push, f, &.{ run_param, self.t().int_id }, shown)) orelse return try CallCheck.skipCall(self, args);
    const returns = self.ctx.types.get(fn_ty).function.returns;
    const fails = self.ctx.types.get(returns) == .fallible;
    const result = if (fails) try self.ctx.intern(.{ .fallible = .{ .ok = self.t().void_id, .set = try waitSet(self, &.{self.ctx.types.get(returns).fallible.set}) } }) else self.t().void_id;
    const params: []const TypeId = &.{ t_param, sizes_param, try sema.callableOfFn(self.ctx, fn_ty), self.t().int_id };
    const call: FunctionType = .{ .params = try self.ctx.dupeIds(params[0..args.len]), .returns = result, .is_sub = true };
    try noteCallee(self, call);
    try CallCheck.checkArgs(self, args, call, .{ .names = &.{ "t", "sizes", "f", "limit" } }, shown, pos, .{ .declared = call.params });
    // Every task reads what `f` captures; each run goes to the one
    // task that writes it.
    if (f.isKind(.lambda)) for (sema.captureList(ir.Lambda.captures(f))) |cap| {
        if (!try parCapture(self, cap, shown)) return self.t().invalid_id;
    };
    if (try sema.crossingBlocker(self.ctx, elem, .moves)) |blocker| {
        if (try statedCrossing(self, blocker, .moves, self.startOf(table_arg))) return self.t().invalid_id;
        try self.errAt(table_arg, "`par.push` hands the runs of `{s}` to tasks that may run on other cores, to write each, and `{s}` {s}", .{ CallCheck.sourceText(self, table_arg), try self.tyName(elem), try blockerReason(self, blocker, false, if (blocker == elem) "is" else null) });
        return self.t().invalid_id;
    }
    try requireTask(self, elem, .moves, self.startOf(table_arg), "is passed to tasks as a write view", false);
    if (self.expect.current_call) |c| try self.ctx.recordParCall(c, .push);
    self.ctx.makes_tasks = true;
    return closureResult(self, f, result);
}

/// `task.isolate(f)` of `std.task`: run `f`, which takes nothing, and
/// give what it gives, failing as it fails and with
/// `task.Stop.panicked` when a panic in it, or in a task it started,
/// reached this boundary. The call is typed here, as `taskJoin` types
/// its own: `f` is a closure written in the call, which fails when its
/// body propagates, or a function's name. Its frames are dropped at a
/// panic with whatever they half-changed, so `f` has no write view of
/// anything outside it: no capture is `|!x|`. A task started in `f`
/// ends in it, so `f` gives no value that holds one. `task.supervise`
/// when `supervise`.
pub fn isolateCall(self: *Checker, supervise: bool, pos: u32, args: []const Sexp) Error!TypeId {
    const shown = if (supervise) "task.supervise" else "task.isolate";
    if (supervise) {
        for (args[@min(args.len, 1)..]) |a| {
            const k = if (a.isKind(.kwarg)) self.text(ir.Kwarg.name(a)) else "";
            if (!std.mem.eql(u8, k, "restarts") and !std.mem.eql(u8, k, "per")) return try CallCheck.badCall(self, args, a, "`task.supervise` takes the function to run, then `restarts:` and `per:`, at most how many restarts within how many seconds: `task.supervise(|| work()!, restarts: 3, per: 60)`", .{});
        }
        if (args.len == 0 or args[0].isKind(.kwarg)) return try CallCheck.badCall(self, args, pos, "`task.supervise` takes the function to run, `task.supervise(|| work()!)`", .{});
    } else if (args.len != 1 or args[0].isKind(.kwarg)) return try CallCheck.badCall(self, args, pos, "`task.isolate` takes the function to run, `task.isolate(|| work()!)`", .{});
    const f = args[0];
    var fn_ty: TypeId = undefined;
    if (f.isKind(.lambda)) {
        fn_ty = try closureType(self, f, &.{}, false);
    } else {
        const ty = try CallCheck.argType(self, f);
        if (self.isPoison(ty)) return try CallCheck.skipCall(self, args);
        const kind = ViewCheck.fnArg(self, f, ty);
        if (kind == .view or kind == .binding) {
            return try CallCheck.badCall(self, args, f, "`{s}` drops what a panic in `{s}` half-changed, so it may take no write view of anything outside it, which a closure's type does not show: write the closure in the call, `{s}(|| ...)`", .{ shown, CallCheck.sourceText(self, f), shown });
        }
        if (kind != .named or self.ctx.types.get(ty).function.params.len != 0) {
            return try CallCheck.badCall(self, args, f, "`{s}` runs a function that takes nothing, a closure written in the call or a function's name; `{s}` is a `{s}`", .{ shown, CallCheck.sourceText(self, f), try self.tyName(ty) });
        }
        fn_ty = ty;
    }
    const returns = self.ctx.types.get(fn_ty).function.returns;
    const fails = self.ctx.types.get(returns) == .fallible;
    const value = CompatCheck.readValue(self.ctx, if (fails) self.ctx.types.get(returns).fallible.ok else returns);
    if (f.isKind(.lambda)) {
        const gives = if (fails) try self.ctx.intern(.{ .fallible = .{ .ok = value } }) else value;
        fn_ty = try self.ctx.intern(.{ .function = .{ .params = &.{}, .returns = gives, .is_sub = sema.returnsNothing(self.ctx, gives) } });
    }
    if (!try hidesNoTask(self, f, value, .isolated, shown)) return try CallCheck.skipCall(self, args);
    const result = try self.ctx.intern(.{ .fallible = .{ .ok = value, .set = try waitSet(self, if (fails) &.{self.ctx.types.get(returns).fallible.set} else &.{}) } });
    const params, const names = try optionParams(self, args, try sema.callableOfFn(self.ctx, fn_ty), "f");
    const call: FunctionType = .{ .params = params, .returns = result, .is_sub = value == self.t().void_id };
    try noteCallee(self, call);
    try CallCheck.checkArgs(self, args, call, .{ .names = names, .durations = optionDurations(names), .waits = true }, shown, pos, .{ .declared = call.params });
    if (f.isKind(.lambda)) for (sema.captureList(ir.Lambda.captures(f))) |cap| {
        const name_node = sema.captureNameNode(cap) orelse continue;
        const n = self.text(name_node);
        if (sema.captureModeOf(cap) == .cap_write) {
            try self.errAt(name_node, "`{s}` drops what a panic in it half-changed, so it may take no write view of anything outside it, and `|!{s}|` makes a write view of `{s}`: give the change back as its value, or keep it in a `*Cell`, captured `|+{s}|`", .{ shown, n, n, n });
            return self.t().invalid_id;
        }
        // What a capture holds may write for it: a write view, or a
        // closure, whose type does not show what it writes.
        const id = self.ctx.symbolOf(name_node) orelse continue;
        const sym = self.ctx.symbols.items[id];
        if (self.isPoison(sym.ty)) continue;
        const inner = sema.unwrapViews(self.ctx, sym.ty);
        const why: []const u8 = if (sema.holdsWriteView(self.ctx, sym.ty))
            "holds a write view: give the change back as its value, or keep the state in a `*Cell`"
        else if (self.ctx.types.get(inner) == .callable or (self.ctx.types.get(inner) == .function and sym.flags.closure))
            "is a closure, whose type does not show what it writes: keep the state it changes in a `*Cell`, or capture an owned closure, `*|...| body`"
        else
            continue;
        try self.errAt(name_node, "`{s}` drops what a panic in it half-changed, so it may take no write view of anything outside it, and `{s}` {s}", .{ shown, n, why });
        return self.t().invalid_id;
    };
    if (self.expect.current_call) |c| try if (supervise) self.ctx.recordSuperviseCall(c) else self.ctx.recordIsolateCall(c);
    self.ctx.makes_tasks = true;
    return closureResult(self, f, result);
}

/// `*Chan[T](n)`: a channel of `n` slots, behind its first handle. It
/// stands only as the operand of `*`, and what it carries holds no
/// view, as a Cell's value holds none.
pub fn chanMake(self: *Checker, call: Sexp, e: Sexp, ty: TypeId, args: []const Sexp) Error!TypeId {
    if (!CompatCheck.sameNode(call, self.expect.shared_operand)) return CallCheck.badCall(self, args, e, "a channel lives only behind a shared handle: write `*Chan[T](n)`", .{});
    if (args.len != 1 or args[0].isKind(.kwarg)) return CallCheck.badCall(self, args, e, "`Chan[T](n)` takes how many values it holds: `*Chan[Job](64)`", .{});
    const elem = self.ctx.types.get(ty).parameterized_nominal.args[0];
    if (sema.mayHoldView(self.ctx, elem)) {
        if (try sema.objectLoanReason(self.ctx, self.ctx.arena.allocator(), elem)) |why| return CallCheck.badCall(self, args, e, "a channel's values hold no view, and {s}", .{why});
        return CallCheck.badCall(self, args, e, "a channel's values hold no view, and a `{s}` may hold a view", .{try self.tyName(elem)});
    }
    const f: FunctionType = .{ .params = try self.ctx.dupeIds(&.{self.t().int_id}), .returns = ty, .is_sub = false };
    try noteCallee(self, f);
    try CallCheck.checkArgs(self, args, f, .{ .names = &.{"capacity"} }, "Chan", self.startOf(e), .{ .declared = f.params });
    try self.ctx.recordChanMake(call);
    self.ctx.makes_tasks = true;
    return ty;
}

/// `task.select(arm, ...)` of `std.task`: wait until one arm's channel
/// operation can complete, commit that one alone, and give what its
/// function gives. An arm is `(!ch).on_recv(f)`, whose `f` takes the
/// value received as `T?`, none once the channel is closed and empty,
/// or `(!ch).on_send(<v, f)`, whose `f` takes nothing; every `f` gives
/// the same type, and is a closure written in the arm, a closure's
/// view, or a function's name. A fallible waiting point.
pub fn taskSelect(self: *Checker, pos: u32, args: []const Sexp) Error!TypeId {
    if (args.len == 0) return try CallCheck.badCall(self, args, pos, "`task.select` takes the arms to wait on, each named: `task.select(got: !ch.on_recv(), late: time.after(ms: 50))`", .{});
    for (args) |a| if (a.isKind(.kwarg)) return taskSelectNamed(self, pos, args);
    // An arm of the named form written without its name.
    for (args) |arm| if (try namedArmShape(self, arm))
        return try badArms(self, args, arm, "each arm of `task.select` has a name, the variant its value matches in a `match`: `{s}: {s}`", .{ try armName(self, arm), try armText(self, arm) });
    const shape = "each arm of `task.select` is `(!ch).on_recv(|v| ...)` or `(!ch).on_send(<v, || ...)`";
    // Every arm's function first, each typed alone (`armResult`):
    // their join is what each must give, so no arm's order decides it.
    const Arm = struct { recv: bool, elem: TypeId, given: []const TypeId, gives: TypeId, panics: bool };
    const arms = try self.ctx.arena.allocator().alloc(Arm, args.len);
    for (args, arms) |arm, *out| {
        if (!arm.isKind(.call) or !ir.Call.callee(arm).isKind(.member)) return try CallCheck.badCall(self, args, arm, "{s}", .{shape});
        const callee = ir.Call.callee(arm);
        const method = self.text(ir.Member.name(callee));
        const recv = std.mem.eql(u8, method, "on_recv");
        if (!recv and !std.mem.eql(u8, method, "on_send")) return try CallCheck.badCall(self, args, arm, "{s}", .{shape});
        const obj = ir.Member.object(callee);
        if (!obj.isKind(.write)) return try CallCheck.badCall(self, args, obj, "an arm receives or sends, which changes the channel: mark it, `(!{s}).{s}(...)`", .{ CallCheck.sourceText(self, obj), method });
        const handle = ir.get(obj, .operand);
        const handle_ty = try armHandle(self, obj);
        if (self.isPoison(handle_ty)) return try CallCheck.skipCall(self, args);
        const elem = sema.chanOfHandle(self.ctx, handle_ty) orelse return try badArms(self, args, handle, "`{s}` is a `{s}`, not a channel; {s}", .{ CallCheck.sourceText(self, handle), try self.tyName(handle_ty), shape });
        const arm_args = ir.Call.args(arm);
        if (arm_args.len != @as(usize, if (recv) 1 else 2)) return try CallCheck.badCall(self, args, arm, "{s}", .{shape});
        const given: []const TypeId = if (recv) try self.ctx.dupeIds(&.{try self.ctx.intern(.{ .optional = elem })}) else &.{};
        const f = arm_args[arm_args.len - 1];
        const gives = (try armResult(self, f, given)) orelse return try CallCheck.skipCall(self, args);
        const panics = gives == self.t().noreturn_id or (f.isKind(.lambda) and sema.tailOf(ir.Lambda.body(f)).isKind(.panic));
        out.* = .{ .recv = recv, .elem = elem, .given = given, .gives = gives, .panics = panics };
    }
    // The join: the first returning arm's value, failing when any arm can, with
    // the set of them that holds every other, else any error.
    var sets: std.ArrayList(TypeId) = .empty;
    for (arms) |arm| if (self.ctx.types.get(arm.gives) == .fallible) try sets.append(self.ctx.arena.allocator(), self.ctx.types.get(arm.gives).fallible.set);
    // An arm that never returns (`panic`) gives no value to join.
    const first = for (arms) |arm| {
        if (!arm.panics) break arm.gives;
    } else arms[0].gives;
    const value = if (self.ctx.types.get(first) == .fallible) self.ctx.types.get(first).fallible.ok else first;
    const returns = if (sets.items.len == 0) value else try self.ctx.intern(.{ .fallible = .{ .ok = value, .set = for (sets.items) |held| {
        for (sets.items) |other| {
            if (!sema.errorSubset(self.ctx, other, held)) break;
        } else break held;
    } else self.t().any_error_id } });
    const saved_call = self.expect.current_call;
    const saved_callee = self.expect.callee_node;
    defer {
        self.expect.current_call = saved_call;
        self.expect.callee_node = saved_callee;
    }
    for (args, arms) |arm, info| {
        const callee = ir.Call.callee(arm);
        const method = self.text(ir.Member.name(callee));
        const arm_args = ir.Call.args(arm);
        const fn_ty = try self.ctx.intern(.{ .function = .{ .params = info.given, .returns = returns, .is_sub = sema.returnsNothing(self.ctx, returns) } });
        const viewed = try sema.callableOfFn(self.ctx, fn_ty);
        const call: FunctionType = .{ .params = if (info.recv) try self.ctx.dupeIds(&.{viewed}) else try self.ctx.dupeIds(&.{ info.elem, viewed }), .returns = returns, .is_sub = sema.returnsNothing(self.ctx, returns) };
        self.expect.current_call = arm;
        self.expect.callee_node = callee;
        try noteCallee(self, call);
        try CallCheck.checkArgs(self, arm_args, call, .{ .names = if (info.recv) &.{"f"} else &.{ "value", "f" } }, method, self.startOf(callee), .{ .declared = call.params });
        try self.ctx.recordType(arm, returns);
        try self.ctx.recordSelectArm(arm, if (info.recv) .recv else .send);
    }
    if (saved_call) |c| try self.ctx.recordSelect(c);
    self.ctx.makes_tasks = true;
    return try self.ctx.intern(.{ .fallible = .{ .ok = value } });
}

/// `task.select(name: arm, ...)`: wait until one arm can complete,
/// commit it alone, and give a value of the select's own type
/// (`sema.selectType`), whose variants are the arms' names: a
/// receive, `!ch.on_recv()`, carries the value as `T?`, none once the
/// channel is closed and empty; a send, `!ch.on_send(<v)`, and a
/// deadline, `time.after(ns)`, carry nothing. No arm holds a
/// function, so the `match` on the value runs the winner's body in
/// the enclosing scope. A fallible waiting point.
pub fn taskSelectNamed(self: *Checker, pos: u32, args: []const Sexp) Error!TypeId {
    const shape = "each arm of `task.select` is `name: !ch.on_recv()`, `name: !ch.on_send(<v)`, `name: ?t.on_end()`, or `name: time.after(ms: 50)`";
    const a = self.ctx.arena.allocator();
    const names = try a.alloc([]const u8, args.len);
    const payloads = try a.alloc(?TypeId, args.len);
    const saved_call = self.expect.current_call;
    const saved_callee = self.expect.callee_node;
    defer {
        self.expect.current_call = saved_call;
        self.expect.callee_node = saved_callee;
    }
    for (args, names, payloads, 0..) |arg, *name, *payload, i| {
        if (!arg.isKind(.kwarg)) return try badArms(self, args, arg, "each arm of `task.select` has a name, the variant its value matches in a `match`: `{s}: {s}`", .{ try armName(self, arg), try armText(self, arg) });
        name.* = self.text(ir.Kwarg.name(arg));
        for (names[0..i]) |earlier| if (std.mem.eql(u8, earlier, name.*))
            return try badArms(self, args, ir.Kwarg.name(arg), "two arms of `task.select` are named `{s}`; each name is a variant of the value it gives, so each is its own", .{name.*});
        const arm = ir.Kwarg.value(arg);
        if (!arm.isKind(.call) or !ir.Call.callee(arm).isKind(.member)) return try badArms(self, args, arm, "{s}", .{shape});
        const callee = ir.Call.callee(arm);
        const method = self.text(ir.Member.name(callee));
        const arm_args = ir.Call.args(arm);
        self.expect.current_call = arm;
        self.expect.callee_node = callee;
        if (try isAfterArm(self, arm)) {
            const f: FunctionType = .{ .params = try self.ctx.dupeIds(&.{self.t().int_id}), .returns = self.t().void_id, .is_sub = true };
            try noteCallee(self, f);
            try CallCheck.checkArgs(self, arm_args, f, .{ .names = &.{"d"}, .durations = sema.paramBit(0), .waits = true }, "time.after", self.startOf(callee), .{ .declared = f.params });
            try self.ctx.recordType(arm, self.t().void_id);
            try self.ctx.recordSelectArm(arm, .after);
            payload.* = null;
            continue;
        }
        const obj = ir.Member.object(callee);
        if (std.mem.eql(u8, method, "on_end")) {
            // A task's end: the arm makes a read view of the task, so
            // the select neither waits it nor takes its value, which
            // the winner's body takes with `>t`.
            if (!obj.isKind(.read)) return try badArms(self, args, obj, "an arm on a task's end makes a read view of the task, and leaves it to its holder: `{s}: ?{s}.on_end()`", .{ name.*, CallCheck.sourceText(self, CompatCheck.stripSigil(obj)) });
            const task_node = ir.get(obj, .operand);
            const task_ty = try PatternCheck.synthExpr(self, task_node);
            if (self.isPoison(task_ty)) return try skipArms(self, args);
            if (!sema.isTask(self.ctx, sema.unwrapViews(self.ctx, task_ty))) return try badArms(self, args, task_node, "`{s}` is a `{s}`, not a task; {s}", .{ CallCheck.sourceText(self, task_node), try self.tyName(task_ty), shape });
            if (arm_args.len != 0) return try badArms(self, args, arm, "a task arm takes nothing: `{s}: ?{s}.on_end()`", .{ name.*, CallCheck.sourceText(self, task_node) });
            const f: FunctionType = .{ .params = &.{}, .returns = self.t().void_id, .is_sub = true };
            try noteCallee(self, f);
            try self.ctx.recordType(arm, self.t().void_id);
            try self.ctx.recordSelectArm(arm, .end);
            payload.* = null;
            continue;
        }
        const recv = std.mem.eql(u8, method, "on_recv");
        if (!recv and !std.mem.eql(u8, method, "on_send")) return try badArms(self, args, arm, "{s}", .{shape});
        if (!obj.isKind(.write)) return try badArms(self, args, obj, "an arm receives or sends, which changes the channel: mark it, `!{s}.{s}(...)`", .{ CallCheck.sourceText(self, obj), method });
        const handle = ir.get(obj, .operand);
        const handle_ty = try armHandle(self, obj);
        if (self.isPoison(handle_ty)) return try skipArms(self, args);
        const elem = sema.chanOfHandle(self.ctx, handle_ty) orelse return try badArms(self, args, handle, "`{s}` is a `{s}`, not a channel; {s}", .{ CallCheck.sourceText(self, handle), try self.tyName(handle_ty), shape });
        if (arm_args.len != @as(usize, if (recv) 0 else 1)) {
            if (recv) return try badArms(self, args, arm, "a named arm gives what it receives to the `match` on the select's value, and takes no function: `{s}: !{s}.on_recv()`", .{ name.*, CallCheck.sourceText(self, handle) });
            return try badArms(self, args, arm, "a named arm sends one value and takes no function: `{s}: !{s}.on_send(<v)`", .{ name.*, CallCheck.sourceText(self, handle) });
        }
        const f: FunctionType = .{ .params = if (recv) &.{} else try self.ctx.dupeIds(&.{elem}), .returns = self.t().void_id, .is_sub = true };
        try noteCallee(self, f);
        try CallCheck.checkArgs(self, arm_args, f, .{ .names = if (recv) &.{} else &.{"value"} }, method, self.startOf(callee), .{ .declared = f.params });
        try self.ctx.recordType(arm, self.t().void_id);
        try self.ctx.recordSelectArm(arm, if (recv) .recv else .send);
        payload.* = if (recv) try self.ctx.intern(.{ .optional = elem }) else null;
    }
    if (saved_call) |c| try self.ctx.recordSelect(c);
    self.ctx.makes_tasks = true;
    return try self.ctx.intern(.{ .fallible = .{ .ok = try sema.selectType(self.ctx, names, payloads, pos) } });
}

/// The handle of a receive or send arm, `ch` of `!ch.on_recv()`, whose
/// `!` is checked as a marked method's self is (`synthView`): the arm
/// changes its channel, so it needs a handle the task holds or a
/// write view (`!*Chan[T]`, or `!Chan[T]` of the channel itself), and
/// a read view, however it is reached, is rejected there. The
/// handle's type, or poison once that is reported. What is no
/// channel gives its type alone, with no view's diagnostic, so the
/// caller says it is no channel.
pub fn armHandle(self: *Checker, obj: Sexp) Error!TypeId {
    const saved = self.expect.self_obj;
    defer self.expect.self_obj = saved;
    self.expect.self_obj = obj;
    const mark = self.ctx.diagnostics.items.len;
    const viewed = try PatternCheck.synthExpr(self, obj);
    const handle_ty = self.ctx.typeOf(ir.get(obj, .operand)) orelse return self.t().invalid_id;
    if (self.isPoison(handle_ty)) return handle_ty;
    if (sema.chanOfHandle(self.ctx, handle_ty) == null) {
        self.ctx.diagnostics.shrinkRetainingCapacity(mark);
        return handle_ty;
    }
    return if (self.isPoison(viewed)) self.t().invalid_id else handle_ty;
}

/// `badCall` of `task.select`: the arms' channels and values are
/// checked, not the arms, which stand only in a select.
pub fn badArms(self: *Checker, args: []const Sexp, at: anytype, comptime fmt: []const u8, fmt_args: anytype) Error!TypeId {
    if (@TypeOf(at) == Sexp) try self.errAt(at, fmt, fmt_args) else try self.err(at, fmt, fmt_args);
    return skipArms(self, args);
}

pub fn skipArms(self: *Checker, args: []const Sexp) Error!TypeId {
    for (args) |a| {
        const arm = storage.argValue(a);
        if (arm.isKind(.call) and ir.Call.callee(arm).isKind(.member)) {
            const obj = ir.Member.object(ir.Call.callee(arm));
            if ((try CallCheck.moduleNamed(self, obj)) == null) _ = try PatternCheck.synthExpr(self, if (obj.isKind(.write) or obj.isKind(.read)) ir.get(obj, .operand) else obj);
            try CallCheck.synthArgs(self, ir.Call.args(arm));
        } else try CallCheck.synthArgs(self, &.{arm});
    }
    return self.t().invalid_id;
}

/// Whether `arm` is a deadline arm, `time.after(ns)` of `std.time`.
pub fn isAfterArm(self: *Checker, arm: Sexp) Error!bool {
    if (!arm.isKind(.call) or !ir.Call.callee(arm).isKind(.member)) return false;
    const callee = ir.Call.callee(arm);
    if (!std.mem.eql(u8, self.text(ir.Member.name(callee)), "after")) return false;
    const module = (try CallCheck.moduleNamed(self, ir.Member.object(callee))) orelse return false;
    return std.mem.eql(u8, stdModule(self, module) orelse return false, "std.time");
}

/// Whether `arm`, unnamed, is written as an arm of the named form
/// (`taskSelectNamed`): `!ch.on_recv()`, `!ch.on_send(<v)`, or
/// `time.after(ns)`.
pub fn namedArmShape(self: *Checker, arm: Sexp) Error!bool {
    if (try isAfterArm(self, arm)) return true;
    if (!arm.isKind(.call) or !ir.Call.callee(arm).isKind(.member)) return false;
    const method = self.text(ir.Member.name(ir.Call.callee(arm)));
    const n = ir.Call.args(arm).len;
    return (std.mem.eql(u8, method, "on_recv") and n == 0) or (std.mem.eql(u8, method, "on_send") and n == 1) or std.mem.eql(u8, method, "on_end");
}

/// A name for an unnamed arm, which its diagnostic suggests: its
/// channel's, when that is a name, `late` for a deadline, else `arm`.
pub fn armName(self: *Checker, arm: Sexp) Error![]const u8 {
    if (try isAfterArm(self, arm)) return "late";
    if (!arm.isKind(.call) or !ir.Call.callee(arm).isKind(.member)) return "arm";
    const obj = ir.Member.object(ir.Call.callee(arm));
    const handle = if (obj.isKind(.write) or obj.isKind(.read)) ir.get(obj, .operand) else obj;
    return if (handle == .src) self.text(handle) else "arm";
}

/// An arm as written, its channel's `!` or its task's `?` included.
pub fn armText(self: *Checker, arm: Sexp) Error![]const u8 {
    const shown = try ViewCheck.plainText(self, arm);
    if (!arm.isKind(.call) or !ir.Call.callee(arm).isKind(.member)) return shown;
    const obj = ir.Member.object(ir.Call.callee(arm));
    const mark: []const u8 = if (obj.isKind(.write)) "!" else if (obj.isKind(.read)) "?" else return shown;
    return std.fmt.allocPrint(self.ctx.arena.allocator(), "{s}{s}", .{ mark, shown });
}

/// The name of std module `module_sym` names (`std.time`), or null for
/// a module of the program's own.
pub fn stdModule(self: *Checker, module_sym: SymbolId) ?[]const u8 {
    const origin = self.ctx.module_refs.get(module_sym) orelse return null;
    return (self.ctx.foreign_semas.get(origin) orelse return null).name;
}

/// What an arm's function `f`, given `params`, gives: a closure
/// written there (`closureType`), a closure's view, or a function's
/// name.
pub fn armResult(self: *Checker, f: Sexp, params: []const TypeId) Error!?TypeId {
    if (f.isKind(.lambda)) {
        const ty = try closureType(self, f, params, false);
        if (self.isPoison(ty) or self.ctx.types.get(ty) != .function) return null;
        return self.ctx.types.get(ty).function.returns;
    }
    const ty = try CallCheck.argType(self, f);
    if (self.isPoison(ty)) return null;
    // The arm runs on the task that selects, so a closure's view
    // goes to it as to any call; `checkArgs` refuses a binding.
    switch (ViewCheck.fnArg(self, f, ty)) {
        .named, .binding => return self.ctx.types.get(ty).function.returns,
        .view => if (sema.callableFnTy(self.ctx, ty)) |c| return self.ctx.types.get(c).function.returns else if (sema.ownedClosureFn(self.ctx, ty)) |c| return c.returns,
        .literal, .other => {},
    }
    try self.errAt(f, "an arm of `task.select` calls a closure written in it, a closure's view, or a function's name; `{s}` is a `{s}`", .{ CallCheck.sourceText(self, f), try self.tyName(ty) });
    return null;
}

/// `http.serve(<listener, f)` of `std.http`: take connections on a
/// `net.Listener`, which it takes, and answer each request with what
/// `f` gives for it, a `fun(?http.Request) -> http.Response`: a
/// closure written in the call, or a function's name. Every
/// connection's task calls `f`, so each capture must sync and none
/// is a write view, as `par.map`'s. It fails as the listener fails, or
/// when its task is canceled. Null when `module_sym`, `std.http`,
/// declares no `Request` or `Response`.
pub fn httpServe(self: *Checker, module_sym: SymbolId, pos: u32, args: []const Sexp) Error!?TypeId {
    const example = "`http.serve(<listener, |req| http.text(\"hi\"))`";
    if (args.len != 2 or args[0].isKind(.kwarg) or args[1].isKind(.kwarg)) return try CallCheck.badCall(self, args, pos, "`http.serve` takes a `net.Listener` and the function that answers each request: {s}", .{example});
    const req_sym = CallCheck.foreignLookup(self, module_sym, "Request") orelse return null;
    const resp_sym = CallCheck.foreignLookup(self, module_sym, "Response") orelse return null;
    const req = try self.ctx.intern(.{ .nominal = .{ .module_id = req_sym.module_id, .sym = req_sym.id } });
    const resp = try self.ctx.intern(.{ .nominal = .{ .module_id = resp_sym.module_id, .sym = resp_sym.id } });
    const listener = try CallCheck.argType(self, args[0]);
    if (self.isPoison(listener)) return try CallCheck.skipCall(self, args);
    if (!namesForeignType(self, listener, "std.net", "Listener")) return try CallCheck.badCall(self, args, args[0], "`http.serve` takes connections on a `net.Listener`, which it takes: `http.serve(<l, ...)`; `{s}` is a `{s}`", .{ CallCheck.sourceText(self, args[0]), try self.tyName(listener) });
    const f = args[1];
    if (!f.isKind(.lambda)) {
        const f_ty = try CallCheck.argType(self, f);
        if (self.isPoison(f_ty)) return try CallCheck.skipCall(self, args);
        switch (ViewCheck.fnArg(self, f, f_ty)) {
            .binding, .view => {
                try manyTasksClosure(self, f, "http.serve", "http.serve(<l, |req| ...)");
                return try CallCheck.skipCall(self, args);
            },
            .literal, .named, .other => {},
        }
    }
    const fn_ty = try self.ctx.intern(.{ .function = .{ .params = try self.ctx.dupeIds(&.{try self.ctx.intern(.{ .read_view = req })}), .returns = resp, .is_sub = false } });
    const result = try self.ctx.intern(.{ .fallible = .{ .ok = self.t().void_id } });
    const call: FunctionType = .{ .params = try self.ctx.dupeIds(&.{ listener, try sema.callableOfFn(self.ctx, fn_ty) }), .returns = result, .is_sub = true };
    try noteCallee(self, call);
    try CallCheck.checkArgs(self, args, call, .{ .names = &.{ "listener", "f" } }, "http.serve", pos, .{ .declared = call.params });
    if (f.isKind(.lambda)) for (sema.captureList(ir.Lambda.captures(f))) |cap| {
        if (!try parCapture(self, cap, "http.serve")) return self.t().invalid_id;
    };
    if (self.expect.current_call) |c| try self.ctx.recordHttpServe(c);
    self.ctx.makes_tasks = true;
    return result;
}

/// `io.copy(!from, !to)` of `std.io`: copy what `from` reads to `to`
/// until `from` ends, and give how many bytes. Each is a `file.File`
/// or a `net.Stream`, as a write view. Rig has no interfaces, so the
/// checker types it, as it does `http.serve`.
pub fn ioCopy(self: *Checker, pos: u32, args: []const Sexp) Error!TypeId {
    if (args.len != 2 or args[0].isKind(.kwarg) or args[1].isKind(.kwarg)) return try CallCheck.badCall(self, args, pos, "`io.copy` takes what to read and what to write, each a `file.File` or a `net.Stream`: `io.copy(!src, !dst)`", .{});
    var params: [2]TypeId = undefined;
    for (args, 0..) |a, i| {
        const ty = try CallCheck.argType(self, a);
        if (self.isPoison(ty)) return try CallCheck.skipCall(self, args);
        const base = switch (self.ctx.types.get(ty)) {
            .write_view => |inner| inner,
            else => ty,
        };
        if (!namesForeignType(self, base, "std.file", "File") and !namesForeignType(self, base, "std.net", "Stream")) return try CallCheck.badCall(self, args, a, "`io.copy` reads from and writes to a `file.File` or a `net.Stream`; `{s}` is a `{s}`", .{ try ViewCheck.plainText(self, CompatCheck.stripSigil(a)), try self.tyName(base) });
        if (!a.isKind(.write) and self.ctx.types.get(ty) != .write_view) return try CallCheck.badCall(self, args, a, "`io.copy` reads and writes through `{s}`: make a write view of it, `!{s}`", .{ try ViewCheck.plainText(self, CompatCheck.stripSigil(a)), try ViewCheck.plainText(self, CompatCheck.stripSigil(a)) });
        params[i] = try self.ctx.intern(.{ .write_view = base });
    }
    const result = try self.ctx.intern(.{ .fallible = .{ .ok = self.t().int_id } });
    const call: FunctionType = .{ .params = try self.ctx.dupeIds(&params), .returns = result, .is_sub = false };
    try noteCallee(self, call);
    try CallCheck.checkArgs(self, args, call, .{ .names = &.{ "from", "to" } }, "io.copy", pos, .{ .declared = call.params });
    if (self.expect.current_call) |c| try self.ctx.recordIoCopy(c);
    return result;
}

/// Whether `ty` is type `name` of the standard library's module
/// `module`.
pub fn namesForeignType(self: *Checker, ty: TypeId, module: []const u8, name: []const u8) bool {
    const n = switch (self.ctx.types.get(ty)) {
        .nominal => |n| if (self.ctx.owns(n)) return false else n,
        else => return false,
    };
    const foreign = self.ctx.foreign_semas.get(n.module_id) orelse return false;
    return std.mem.eql(u8, foreign.name, module) and std.mem.eql(u8, foreign.symbols.items[n.sym].name, name);
}

/// The function type of `f`, the function `par.map`, `par.each`,
/// `par.workers`, or `par.push` calls on each element, which takes
/// `params` (the element, a task's state and the item, or a run and
/// its index): a closure written in the
/// call, which fails when its body propagates a failure, or a
/// function's name. Null after a diagnostic.
pub fn parFunction(self: *Checker, kind: sema.ParCall, f: Sexp, params: []const TypeId, shown: []const u8) Error!?TypeId {
    if (f.isKind(.lambda)) {
        const sub = kind == .each or kind == .push;
        // A closure that gives a value has no type to check its
        // parameters against until its body is typed: its count is
        // checked first. (One that gives nothing is checked against
        // the `sub` type the call gives it, which says so.)
        const takes = ir.Lambda.params(f).items().len;
        if (!sub and takes > params.len) {
            try self.errAt(f, "this closure takes {d} parameters, but `{s}` passes {d}; a closure may take fewer, never more", .{ takes, shown, params.len });
            try self.closures_reported.put(self.ctx.allocator, CompatCheck.nodeId(f), {});
            return null;
        }
        return try closureType(self, f, params, sub);
    }
    const ty = try CallCheck.argType(self, f);
    if (self.isPoison(ty)) return null;
    switch (ViewCheck.fnArg(self, f, ty)) {
        .named => {
            const got = self.ctx.types.get(ty).function;
            if (got.params.len == params.len) {
                // Each parameter takes what the runtime passes: the
                // view itself, or the value of a scalar's read view;
                // a write view is passed as itself.
                const fits = for (got.params, params) |have, given| {
                    if (have == given) continue;
                    if (self.ctx.types.get(given) != .read_view or have != CompatCheck.readValue(self.ctx, given)) break false;
                } else true;
                if (fits) {
                    // `each` and `push` keep nothing `f` gives.
                    if (kind == .each or kind == .push) {
                        const gives = got.returns;
                        const value = if (self.ctx.types.get(gives) == .fallible) self.ctx.types.get(gives).fallible.ok else gives;
                        if (value != self.t().void_id) {
                            try self.errAt(f, "`{s}` keeps nothing its function gives, and `{s}` gives a `{s}`: call it in a closure that discards the value, `_ = ...`, or give nothing", .{ shown, CallCheck.sourceText(self, f), try self.tyName(value) });
                            return null;
                        }
                    }
                    return ty;
                }
                if (kind == .workers) {
                    try self.errAt(f, "`par.workers` calls `{s}` with a task's state as `{s}` and each item as `{s}`, and `{s}` takes `{s}` and `{s}`", .{ CallCheck.sourceText(self, f), try self.tyName(params[0]), try self.tyName(params[1]), CallCheck.sourceText(self, f), try self.tyName(got.params[0]), try self.tyName(got.params[1]) });
                } else if (kind == .push) {
                    try self.errAt(f, "`par.push` calls `{s}` with each run as `{s}` and its index as `{s}`, and `{s}` takes `{s}` and `{s}`", .{ CallCheck.sourceText(self, f), try self.tyName(params[0]), try self.tyName(params[1]), CallCheck.sourceText(self, f), try self.tyName(got.params[0]), try self.tyName(got.params[1]) });
                } else try self.errAt(f, "`{s}` calls `{s}` with each element as `{s}`, and `{s}` takes `{s}`", .{ shown, CallCheck.sourceText(self, f), try self.tyName(params[0]), CallCheck.sourceText(self, f), try self.tyName(got.params[0]) });
                return null;
            }
            if (kind == .workers) {
                try self.errAt(f, "`{s}` calls `{s}` with a task's state and one item at a time, and it takes {d} parameters", .{ shown, CallCheck.sourceText(self, f), got.params.len });
            } else if (kind == .push) {
                try self.errAt(f, "`{s}` calls `{s}` with one run and its index at a time, and it takes {d} parameters", .{ shown, CallCheck.sourceText(self, f), got.params.len });
            } else try self.errAt(f, "`{s}` calls `{s}` with one element at a time, and it takes {d} parameters", .{ shown, CallCheck.sourceText(self, f), got.params.len });
        },
        .binding, .view => try manyTasksClosure(self, f, shown, switch (kind) {
            .map => "par.map(?xs, |x| ...)",
            .each => "par.each(!xs, |x| ...)",
            .workers => "par.workers(!states, ?items, |s, x| ...)",
            .push => "par.push(!t, ?sizes, |run, k| ...)",
        }),
        .literal, .other => try self.errAt(f, "`{s}` calls a function on each element, a closure written in the call or a function's name; `{s}` is a `{s}`", .{ shown, CallCheck.sourceText(self, f), try self.tyName(ty) }),
    }
    return null;
}

/// Reports `f`, a closure that is not written in the call `shown`,
/// which runs it on several tasks at once (`FnArg.binding`,
/// `FnArg.view`): every task would read what it captures, which its
/// type does not show, so the closure is written in the call, as
/// `example`.
pub fn manyTasksClosure(self: *Checker, f: Sexp, shown: []const u8, example: []const u8) Error!void {
    try self.errAt(f, "`{s}` calls `{s}` on several tasks at once, and every task reads what a closure captures, which its type does not show: write the closure in the call, `{s}`", .{ shown, CallCheck.sourceText(self, f), example });
}

/// The type of closure literal `f` written where the function a std
/// form calls goes (`task.isolate`, `par.map`, `task.select`'s arms),
/// given `params`, which fails when its body propagates a failure:
/// checked quietly as one that cannot fail, then as one that can, and,
/// when neither checks clean, as the one with fewer errors (one that
/// cannot fail on a tie), whose errors the call's own check of `f`
/// reports, or `closureErrors` where the call cannot build on what it
/// gives: a closure in error that propagates is not also reported for
/// propagating. A `sub` gives nothing, as `par.each`'s closure.
pub fn closureType(self: *Checker, f: Sexp, params: []const TypeId, sub: bool) Error!TypeId {
    const plain, const plain_errors = try closureQuietly(self, f, params, sub, false);
    if (plain_errors == 0) return plain;
    const failing, const failing_errors = try closureQuietly(self, f, params, sub, true);
    if (failing_errors > 0) try self.closures_in_error.put(self.ctx.allocator, CompatCheck.nodeId(f), {});
    if (failing_errors >= plain_errors) return plain;
    // A body whose value is poison gives no failure to its type:
    // the closure still fails, as the call's own check of it must.
    if (self.isPoison(failing) or self.ctx.types.get(failing) != .function) return failing;
    const got = self.ctx.types.get(failing).function;
    if (self.ctx.types.get(got.returns) == .fallible) return failing;
    return try self.ctx.intern(.{ .function = .{ .params = got.params, .returns = try self.ctx.intern(.{ .fallible = .{ .ok = got.returns } }), .is_sub = got.is_sub } });
}

/// What a std form that calls `f` gives, `result`, or poison when `f`
/// is a closure literal in error (`closures_in_error`), whose errors
/// the call reported.
pub fn closureResult(self: *Checker, f: Sexp, result: TypeId) TypeId {
    if (f.isKind(.lambda) and self.closures_in_error.contains(CompatCheck.nodeId(f))) return self.t().invalid_id;
    return result;
}

/// Reports the errors of closure literal `f`, which `closureType`
/// typed and which checks clean neither way, where the call that
/// passes it cannot build on what it gives and stops (`skipCall`
/// checks it again with no parameter types, which hides them): it is
/// checked aloud, given `params`, as the one of the two with fewer
/// errors.
pub fn closureErrors(self: *Checker, f: Sexp, params: []const TypeId, sub: bool) Error!void {
    _, const plain = try closureQuietly(self, f, params, sub, false);
    _, const failing = try closureQuietly(self, f, params, sub, true);
    _ = try closureAs(self, f, params, sub, failing < plain);
    try self.closures_reported.put(self.ctx.allocator, CompatCheck.nodeId(f), {});
}

/// Closure literal `f` checked quietly as `closureType` checks it, as
/// one that can fail when `fails`: its type, and how many errors it has.
pub fn closureQuietly(self: *Checker, f: Sexp, params: []const TypeId, sub: bool, fails: bool) Error!struct { TypeId, usize } {
    const mark = self.ctx.diagnostics.items.len;
    self.ctx.quiet += 1;
    self.tentative += 1;
    defer {
        self.ctx.quiet -= 1;
        self.tentative -= 1;
        self.ctx.diagnostics.shrinkRetainingCapacity(mark);
    }
    const ty = try closureAs(self, f, params, sub, fails);
    return .{ ty, self.ctx.diagnostics.items.len - mark };
}

/// Closure literal `f` checked as `closureType` checks it, as one that
/// can fail when `fails`.
pub fn closureAs(self: *Checker, f: Sexp, params: []const TypeId, sub: bool, fails: bool) Error!TypeId {
    if (!sub) return try ClosureCheck.checkLambdaGiven(self, f, null, params, fails);
    const returns = if (fails) try self.ctx.intern(.{ .fallible = .{ .ok = self.t().void_id } }) else self.t().void_id;
    return try ClosureCheck.checkLambda(self, f, try self.ctx.intern(.{ .function = .{ .params = try self.ctx.dupeIds(params), .returns = returns, .is_sub = true } }));
}

/// Whether capture `cap` of the closure `par.map`, `par.each`,
/// `par.workers`, or `par.push` calls (`shown`) may be read by several tasks at
/// once: not a write view, and of a type that shares. Reports why not.
pub fn parCapture(self: *Checker, cap: Sexp, shown: []const u8) Error!bool {
    const mode = sema.captureModeOf(cap) orelse return true;
    const name_node = sema.captureNameNode(cap) orelse return true;
    const name = self.text(name_node);
    if (mode == .cap_write) {
        if (std.mem.eql(u8, shown, "par.workers")) {
            try self.errAt(name_node, "`par.workers` calls the closure on several tasks at once, and `|!{s}|` makes a write view of `{s}`, which no two tasks may hold at once: keep what each task writes in its state, or gather what each call gives", .{ name, name });
        } else try self.errAt(name_node, "`{s}` calls the closure on several tasks at once, and `|!{s}|` makes a write view of `{s}`, which no two tasks may hold at once: gather what each call gives with `par.map`, or count with a `*Cell[Int]`, captured `|+{s}|`", .{ shown, name, name, name });
        return false;
    }
    const id = self.ctx.symbolOf(name_node) orelse return true;
    const ty = self.ctx.symbols.items[id].ty;
    if (self.isPoison(ty)) return true;
    const inner = sema.unwrapViews(self.ctx, ty);
    const blocker = (try sema.crossingBlocker(self.ctx, inner, .shares)) orelse {
        try requireTask(self, inner, .shares, self.startOf(name_node), "is passed to tasks as a read view", false);
        return true;
    };
    if (try statedCrossing(self, blocker, .shares, self.startOf(name_node))) return false;
    try self.errAt(name_node, "`{s}` calls the closure on several tasks at once, which all read what it captures, and `{s}` {s}", .{ shown, name, try blockerReason(self, blocker, true, if (blocker == ty) "is" else if (blocker == inner) "views" else null) });
    return false;
}

/// `>ts` (all of them) and `<ts.wait_first()`: the waits of a set of
/// tasks, whose results depend on whether its tasks can fail. A
/// deadline for either is `time.within`'s. Null when the set is not
/// one, or `method` neither wait.
pub fn taskSetWait(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp) Error!?TypeId {
    const set = sema.unwrapViews(self.ctx, obj_ty);
    if (!sema.isTaskSet(self.ctx, set)) return null;
    const first = std.mem.eql(u8, method, "wait_first");
    if (!first and !rig.isWaitMember(callee)) return null;
    if (first) try self.ctx.recordBuiltinCall(callee, .wait_first);
    const each = sema.taskResult(self.ctx, set).?;
    const fails = self.ctx.types.get(each) == .fallible;
    const value = if (fails) self.ctx.types.get(each).fallible.ok else each;
    const result = if (first) each else blk: {
        const all = if (value == self.t().void_id) value else try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.builtins.list, .args = try self.ctx.dupeIds(&.{value}) } });
        break :blk if (fails) try self.ctx.intern(.{ .fallible = .{ .ok = all, .set = self.ctx.types.get(each).fallible.set } }) else all;
    };
    const f: FunctionType = .{ .params = try self.ctx.dupeIds(&.{set}), .returns = result, .is_sub = result == self.t().void_id };
    try noteCallee(self, f);
    _ = try noteMethod(self, callee, .value, result);
    const misplaced_sigil = try ViewCheck.checkSelfSigil(self, obj, .value, result, method);
    try ViewCheck.recordUse(self, obj, .take);
    if (!misplaced_sigil) {
        const saved_of = self.expect.self_of;
        defer self.expect.self_of = saved_of;
        self.expect.self_of = callee;
        try ViewCheck.checkSelfMode(self, obj, .value, CompatCheck.classifySelfType(self.ctx, obj_ty, self.ctx.localSym(self.ctx.builtins.tasks)), method, pos, result);
    }
    const shown = try ViewCheck.plainText(self, CompatCheck.stripSigil(obj));
    // Only tasks that can fail can be stopped: neither the first to
    // finish nor a deadline can leave the others behind.
    if (first and !fails) {
        try self.err(pos, "`wait_first` takes the first task to succeed and cancels the rest, and the tasks of `{s}` cannot fail, so they cannot be canceled: wait for all of them, `>{s}`", .{ try self.tyName(set), shown });
        try CallCheck.synthArgs(self, args);
        return self.t().invalid_id;
    }
    if (args.len > 0) {
        try self.err(pos, "`wait_first` takes nothing; to give it a deadline, call it in `time.within`: `time.within(2, |<{s}| <{s}.wait_first()!)`", .{ shown, shown });
        try CallCheck.synthArgs(self, args);
        return self.t().invalid_id;
    }
    return result;
}

/// `>x`: what a wait takes is a task, or a set of tasks, held, not a
/// view of one; the error when it is not, and null when it is, for the
/// task's `wait` or the set's (`taskSetWait`) to type.
pub fn waitOperand(self: *Checker, obj: Sexp, obj_ty: TypeId, pos: u32, args: []const Sexp) Error!?TypeId {
    const shown = try ViewCheck.plainText(self, CompatCheck.stripSigil(obj));
    const held = sema.unwrapViews(self.ctx, obj_ty);
    const task = sema.isTask(self.ctx, held) or sema.isTaskSet(self.ctx, held);
    if (task and held == obj_ty) return null;
    if (task) return try CallCheck.badCall(self, args, pos, "`>{s}` takes the task, and `{s}` is a view of it, `{s}`: only the one that holds a task waits for it", .{ shown, shown, try self.tyName(obj_ty) });
    if (self.ctx.types.get(held) == .function) return try CallCheck.badCall(self, args, pos, "`>` waits for a task, and `{s}` is a function: make its call a task, `t = {s}(...)&`, then wait for it, `>t`", .{ shown, shown });
    return try CallCheck.badCall(self, args, pos, "`>` waits for a task, and `{s}` has type `{s}`; a task is a call made with `&`, `t = f(x)&`", .{ shown, try self.tyName(obj_ty) });
}

/// `t.wait()` written out: a task is waited for with `>t`; a
/// deadline is `time.within`'s.
pub fn spelledWait(self: *Checker, obj: Sexp, obj_ty: TypeId, method: []const u8, pos: u32, args: []const Sexp) Error!?TypeId {
    const held = sema.unwrapViews(self.ctx, obj_ty);
    if (!sema.isTask(self.ctx, held) or !std.mem.eql(u8, method, "wait")) return null;
    const task = CompatCheck.stripSigil(obj);
    const shown = try ViewCheck.plainText(self, task);
    // `>` takes a name alone: a task made where it is waited for is
    // the call itself, and any other is bound to a name first.
    if (task != .src) {
        if (task.isKind(.call) and ir.Call.task(task) != .nil) {
            const call = std.mem.trimEnd(u8, shown, "&");
            return try CallCheck.badCall(self, args, pos, "a task waited for as soon as it starts is the call itself: write `{s}`", .{call});
        }
        return try CallCheck.badCall(self, args, pos, "a task is waited for with `>` on a name: take it out to one first, `t = <{s}`, then wait for that, `>t`", .{shown});
    }
    if (args.len > 0) return try CallCheck.badCall(self, args, pos, "a task is waited for with `>`, which takes nothing; to give the wait a deadline, write it in `time.within`: `time.within(2, |<{s}| >{s}!)`", .{ shown, shown });
    return try CallCheck.badCall(self, args, pos, "a task is waited for with `>`: write `>{s}`", .{shown});
}

/// A `Cell[List[E]]` answers its List's `push`, `pop`, `keep`,
/// `clear`, and, for a plain-data `E`, `get(i)`, through any path to
/// the cell, as `set` does. Null for the Cell's own members.
pub fn cellListCall(self: *Checker, callee: Sexp, obj: Sexp, obj_ty: TypeId, elem: TypeId, pos: u32, args: []const Sexp) Error!?TypeId {
    const method = self.text(ir.Member.name(callee));
    const Member = enum { push, pop, keep, clear, get };
    const member = std.meta.stringToEnum(Member, method) orelse return null;
    if (member == .get and args.len == 0) return null;
    try self.ctx.recordBuiltinCall(callee, switch (member) {
        .push => .list_push,
        .pop => .list_pop,
        .keep => .list_keep,
        .clear => .list_clear,
        .get => .list_get,
    });
    const cell = sema.unwrapReadAccess(self.ctx, obj_ty);
    const recv = try self.ctx.intern(if (member == .get) .{ .read_view = cell } else .{ .write_view = cell });
    const opt_elem = try self.ctx.intern(.{ .optional = elem });
    const params: []const TypeId = switch (member) {
        .push => &.{ recv, elem },
        .pop, .clear => &.{recv},
        .keep, .get => &.{ recv, self.t().int_id },
    };
    const f: FunctionType = .{
        .params = try self.ctx.dupeIds(params),
        .returns = switch (member) {
            .push, .keep, .clear => self.t().void_id,
            .pop, .get => opt_elem,
        },
        .is_sub = member == .push or member == .keep or member == .clear,
    };
    try noteCallee(self, f);
    if (member == .get) {
        // Self is read where it stands, as any `?@`
        // method's is (`readLeaf`).
        if (!ViewCheck.hands(self, obj).hasStorage()) try ViewCheck.readLeaf(self, obj);
        if (try ViewCheck.cannotCopy(self, elem, pos, "copies an element out of a Cell's List")) {
            _ = try CallCheck.badCall(self, args, pos, CompatCheck.cell_list_handle, .{try self.tyName(cell)});
            return f.returns;
        }
    } else {
        // A write method of the Cell's List, marked as any is
        // (`checkSelfMode`); the Cell is the handle's own, so
        // the handle is viewed, not the Cell exclusively.
        const misplaced_sigil = try ViewCheck.checkSelfSigil(self, obj, .write, f.returns, method);
        try ViewCheck.recordUse(self, CompatCheck.stripSigil(obj), .view);
        if (!misplaced_sigil and ViewCheck.hands(self, obj).kind != .made) try ViewCheck.rejectResourceTemporary(self, obj, obj_ty);
        if (!misplaced_sigil) {
            const saved_of = self.expect.self_of;
            defer self.expect.self_of = saved_of;
            self.expect.self_of = callee;
            try ViewCheck.checkSelfMode(self, obj, .write, CompatCheck.classifySelfType(self.ctx, obj_ty, self.ctx.localSym(self.ctx.builtins.cell)), method, pos, f.returns);
        }
    }
    try CallCheck.checkArgs(self, args, .{ .params = f.params[1..], .returns = f.returns, .is_sub = f.is_sub }, .{}, method, pos, .{ .has_self = true });
    return f.returns;
}

/// `xs.get(i)` on an array, a slice, or a `?String`: the element as
/// `T?` (a `?String`'s byte as `U8?`), `none` when `i` is out of range.
/// Null when `obj_ty` is none of these.
pub fn sequenceGet(self: *Checker, obj_ty: TypeId, pos: u32, args: []const Sexp) Error!?TypeId {
    const seq = sema.unwrapViews(self.ctx, obj_ty);
    const elem: TypeId = switch (self.ctx.types.get(seq)) {
        .array => |a| a.elem,
        .slice => |sl| sl.elem,
        .string_view, .static => try ViewCheck.byteType(self),
        else => return null,
    };
    const recv = try self.ctx.intern(.{ .read_view = seq });
    const f: FunctionType = .{
        .params = try self.ctx.dupeIds(&.{ recv, self.t().int_id }),
        .returns = try self.ctx.intern(.{ .optional = elem }),
        .is_sub = false,
    };
    try noteCallee(self, f);
    if (try ViewCheck.cannotCopy(self, elem, pos, "copies an element out of a sequence")) {
        return try CallCheck.badCall(self, args, pos, "`get` would copy an element out of a `{s}`, whose elements a copy cannot share; index it (`xs[i]`) or iterate over it instead", .{try self.tyName(seq)});
    }
    try CallCheck.checkArgs(self, args, .{ .params = f.params[1..], .returns = f.returns, .is_sub = false }, .{}, "get", pos, .{ .has_self = true });
    return f.returns;
}

/// Whether `.len` (and so `is_empty()`) is built in on `ty`, a type
/// with its views peeled: an array, a slice, a `?String`, a `Static`,
/// a List, or a Cell holding a List.
pub fn hasBuiltinLen(self: *Checker, ty: TypeId) bool {
    return switch (self.ctx.types.get(ty)) {
        .array, .slice, .string_view, .static, .string => true,
        .parameterized_nominal => CompatCheck.listElementType(self.ctx, ty) != null or CompatCheck.cellListElement(self.ctx, ty) != null,
        else => false,
    };
}

pub fn noteCallee(self: *Checker, f: FunctionType) Error!void {
    try noteCalleeType(self, try self.ctx.intern(.{ .function = f }));
}

pub fn noteCalleeType(self: *Checker, ty: TypeId) Error!void {
    if (self.expect.callee_node) |n| try self.ctx.recordType(n, ty);
}

/// `Type.function(args)` or `Type.variant(payload)`, for a type of
/// this module or an imported one.
pub fn associatedCall(self: *Checker, obj: Sexp, nt: Checker.NamedType, name: []const u8, pos: u32, args: []const Sexp, ct: ?Sexp) Error!TypeId {
    const tname = try CallCheck.namedTypeName(self, nt);
    const members = nt.sym.fields orelse return CallCheck.badCall(self, args, pos, "opaque type `{s}` has no members", .{tname});
    const generic = nt.sym.kind == .generic_type;
    if (!generic and std.mem.eql(u8, name, "from_int")) {
        const enum_ty = try CallCheck.namedTypeValue(self, nt);
        if (CallCheck.enumValues(self, enum_ty)) |plain| {
            if (CallCheck.isBuiltinEnumTy(self, enum_ty)) return CallCheck.badCall(self, args, pos, "`{s}.from_int(n)` takes a declared enum; the built-in enum `{s}` has no integer value", .{ tname, tname });
            if (plain) return enumFromIntCall(self, self.expect.callee_node orelse return CallCheck.skipCall(self, args), enum_ty, tname, pos, args, ct);
            const declared = (try sema.findMember(self.ctx, members, name, .any)) != null;
            if (!declared) return CallCheck.badCall(self, args, pos, "`{s}` has variants with payloads, which have no integer value", .{tname});
        }
    }
    // `from_text`, unless a payload enum declares its own.
    if (std.mem.eql(u8, name, "from_text") and !nt.sym.flags.error_set and (try sema.findMember(self.ctx, members, name, .any)) == null) {
        const is_enum = for (members) |m| {
            if (m.is_variant) break true;
        } else false;
        if (is_enum) {
            if (!generic) {
                const enum_ty = try CallCheck.namedTypeValue(self, nt);
                if (CallCheck.hasVariantNames(self, enum_ty)) return fromTextCall(self, self.expect.callee_node orelse return CallCheck.skipCall(self, args), enum_ty, tname, pos, args, ct);
            }
            return CallCheck.badCall(self, args, pos, "`from_text` gives a plain enum's variant by its name; `{s}` {s}", .{ tname, if (generic) "is generic" else "has variants with payloads, which a name cannot build" });
        }
    }
    // The first member of that name decides.
    found: {
        const m = members[(try sema.findMember(self.ctx, members, name, .any)) orelse break :found];
        if (m.is_method and !m.is_drop_method) {
            try CallCheck.checkVisible(self, m, nt.sym, if (nt.foreign) |fo| fo.module_id else null, pos);
            const fty = self.ctx.types.get(try CallCheck.memberType(self, nt.foreign, m.ty));
            if (fty != .function) break :found;
            var f = fty.function;
            var recv: TypeSubst = .empty;
            if (generic) {
                // The type's arguments are given (`Pair[Int, ?String].make`)
                // or come from the call's arguments.
                const subst = if (nt.args) |given| TypeSubst{ .params = nt.sym.type_params orelse &.{}, .args = given } else (try inferTypeArgs(self, nt.id, args, .{ .params = .{ .params = f.params, .names = m.param_names, .defaults = m.param_defaults } }, pos, CallCheck.expectedResult(self, f.returns), name)) orelse return CallCheck.skipCall(self, args);
                if (nt.args == null) try self.ctx.recordType(obj, try ViewCheck.instantiate(self, nt.id, subst.args, pos));
                f = self.ctx.types.get(try sema.substituteType(self.ctx, m.ty, subst)).function;
                recv = subst;
            }
            const after_self = if (m.self_mode != .none and args.len > 0 and !args[0].isKind(.kwarg)) args[1..] else args;
            const mark = self.ctx.diagnostics.items.len;
            if (!try CallCheck.stdArgChecks(self, if (nt.foreign) |fo| fo.module_id else null, nt.sym.name, name, after_self, pos)) return CallCheck.skipCall(self, args);
            const source = if (nt.foreign) |fo| fo.ctx.source else CallCheck.declSource(self, nt.id);
            var info = CallCheck.methodParams(m, false, source);
            const home_ctx = if (nt.foreign) |fo| fo.ctx else self.ctx;
            info.zoneless = sema.duration.zoneless(home_ctx, nt.sym.name, name);
            info.datetime = home_ctx.is_std and std.mem.eql(u8, home_ctx.name, "std.datetime");
            f = (try CallCheck.instantiateCall(self, f, ct, args, info, 0, name, pos, m.self_mode != .none, recv)) orelse return CallCheck.skipCall(self, args);
            try noteMethodTarget(self, m, nt.sym, if (nt.foreign) |fo| fo.module_id else null, recv, if (recv.args.len > 0) try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.ref(nt.id), .args = try self.ctx.dupeIds(recv.args) } }) else sema.type_invalid, pos);
            if (!try ViewCheck.meetsNeeds(self, m, nt.id, recv.args, pos, if (m.self_mode != .none and args.len > 0) args[1..] else args)) return CallCheck.skipCall(self, args);
            if (!try ViewCheck.meetsOwnerBounds(self, m, nt.sym, if (nt.foreign) |fo| fo.module_id else null, recv.args, pos, m.self_mode != .none)) return CallCheck.skipCall(self, args);
            try noteCallee(self, f);
            self.expect.view_call = true;
            try CallCheck.checkArgs(self, args, f, info, name, pos, .{ .origins = m.origins, .declared = fty.function.params });
            try CallCheck.stdArgTypes(self, if (nt.foreign) |fo| fo.module_id else null, nt.sym.name, name, after_self);
            const home = if (nt.foreign) |fo| fo.ctx else self.ctx;
            // An argument with an error of its own leaves the call
            // unchecked, and asks for no `!` besides.
            if (sema.constMaker(home, nt.sym.name, name)) |maker|
                return if (self.ctx.diagnostics.items.len == mark) CallCheck.constMakerCall(self, home, maker, args, f.returns) else self.t().invalid_id;
            if (sema.formatOwner(home, nt.sym.name, name)) |ft|
                return if (self.ctx.diagnostics.items.len == mark) CallCheck.formatCall(self, ft, after_self, f.returns) else self.t().invalid_id;
            return f.returns;
        }
        if (ct) |b| return CallCheck.badCall(self, args, b, "`{s}.{s}` is not a function; it takes no compile-time arguments", .{ tname, name });
        if (!m.is_variant) break :found;
        const payload = m.payload orelse &.{};
        if (payload.len == 0) return CallCheck.badCall(self, args, pos, "variant `{s}.{s}` takes no payload", .{ tname, name });
        var subst = TypeSubst.empty;
        var ty = try CallCheck.namedTypeValue(self, nt);
        if (nt.args) |given| {
            subst = .{ .params = nt.sym.type_params orelse &.{}, .args = given };
            ty = try ViewCheck.instantiate(self, nt.id, given, pos);
        } else if (generic) {
            // Arguments that fill no field bind nothing to infer from:
            // say what the variant takes instead.
            const positional = for (args) |a| {
                if (!a.isKind(.kwarg)) break true;
            } else false;
            if (args.len == 0 or (positional and !(args.len == 1 and CallCheck.soleField(payload) != null))) {
                try CallCheck.checkFieldArgs(self, args, payload, .{ .owner = name, .decl_pos = m.decl_pos, .module_id = nt.sym.from.module_id, .pos = pos, .foreign = nt.foreign, .kind = .variant });
                return self.t().invalid_id;
            }
            const self_type = (try sema.makeNominalContext(self.ctx, nt.id)).self_type;
            subst = (try inferTypeArgs(self, nt.id, args, .{ .payload = payload }, pos, CallCheck.expectedResult(self, self_type), name)) orelse return CallCheck.skipCall(self, args);
            ty = try ViewCheck.instantiate(self, nt.id, subst.args, pos);
        }
        try CallCheck.checkFieldArgs(self, args, payload, .{ .owner = name, .decl_pos = m.decl_pos, .module_id = nt.sym.from.module_id, .pos = pos, .subst = subst, .foreign = nt.foreign, .kind = .variant, .instance = ty });
        return ty;
    }
    const hint = (if (nt.foreign) |fo| sema.stdRenamed(fo.ctx, nt.sym.name, name) else null) orelse try ExprCheck.memberHint(self, nt.sym.fields orelse &.{}, name, .associated);
    try self.err(pos, "no method `{s}` on type `{s}`{s}", .{ name, tname, hint });
    try PatternCheck.noteDeclared(self, nt.sym, nt.foreign == null);
    return CallCheck.skipCall(self, args);
}

/// The type arguments of generic type `sym_id` that make `args` fit:
/// each argument's type is matched against the field or parameter it
/// fills (`inferBindings`). Null, after a diagnostic, when some
/// parameter is left unbound or the arguments disagree on one.
pub fn inferTypeArgs(self: *Checker, sym_id: SymbolId, args: []const Sexp, from: Checker.InferFrom, pos: u32, result: ?Checker.ResultType, member: ?[]const u8) Error!?TypeSubst {
    const sym = self.ctx.symbols.items[sym_id];
    const params = sym.type_params orelse &.{};
    const inf = try CallCheck.inferBindings(self, params, args, from, result);
    if (member) |name| try noteTypeArgsHint(self, sym_id, name, inf);
    for (params, inf.bound) |p, b| {
        const pname = self.ctx.symbols.items[p].name;
        if (b.ty == sema.type_invalid) {
            if (inf.poisoned) return null;
            try self.err(pos, "cannot infer `{s}` for `{s}` from the arguments; name it (`{s}[...]`), or give the type where the value goes (`x: {s}[...] = ...`)", .{ pname, sym.name, sym.name, sym.name });
            return null;
        }
        if (b.conflict == sema.type_invalid) {
            if (try CallCheck.viewedClosureBound(self, b.ty, pname, sym.name, pos)) return null;
            if (!try CallCheck.valueBindingFits(self, p, b, sym.name, pos) or !try CallCheck.inferredTypeFits(self, b, args)) return null;
            continue;
        }
        const c = try CallCheck.conflictText(self, b);
        try self.err(pos, "conflicting {s} for `{s}` in `{s}`: `{s}` ({s}) and `{s}` ({s}); name it (`{s}[...]`)", .{ if (self.ctx.symbols.items[p].kind == .param) "values" else "types", pname, sym.name, c.first, c.first_from, c.second, c.second_from, sym.name });
        return null;
    }
    const bound = try self.ctx.arena.allocator().alloc(TypeId, params.len);
    for (inf.bound, bound) |b, *out| out.* = b.ty;
    return .{ .params = params, .args = bound };
}

/// Where an argument of `Type.member(...)` gives a type parameter
/// another type than the one the expected type gives it, what to
/// write for the mismatch that follows (`result_hints`): the type
/// named, which passes the expected type on to the arguments.
pub fn noteTypeArgsHint(self: *Checker, sym_id: SymbolId, member: []const u8, inf: Checker.Inference) Error!void {
    const call = self.expect.current_call orelse return;
    if (call.list.id == 0) return;
    _ = self.result_hints.remove(call.list.id);
    const a = self.ctx.arena.allocator();
    const types = try a.alloc(TypeId, inf.bound.len);
    var first: ?usize = null;
    for (inf.bound, types, 0..) |b, *ty, i| {
        ty.* = if (b.wanted != sema.type_invalid) b.wanted else b.ty;
        if (b.wanted != sema.type_invalid and first == null) first = i;
    }
    const i = first orelse return;
    for (types) |ty| if (ty == sema.type_invalid) return;
    const sym = self.ctx.symbols.items[sym_id];
    const b = inf.bound[i];
    const took = try a.print("`{s}.{s}` takes `{s} = {s}` from argument {d}", .{ sym.name, member, self.ctx.symbols.items[sym.type_params.?[i]].name, try self.tyName(b.ty), b.arg });
    const named = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = self.ctx.ref(sym_id), .args = try self.ctx.dupeIds(types) } });
    const hint = if (CompatCheck.spelledInBrackets(self.ctx, named)) try a.print("{s}; to pass `{s}` on to it, name the type: `{s}.{s}(...)`", .{ took, try self.tyName(types[i]), try self.tyName(named), member }) else took;
    try self.result_hints.put(self.ctx.allocator, call.list.id, hint);
}
