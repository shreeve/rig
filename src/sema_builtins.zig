//! Built-in generic types, registered in every module scope before
//! user declarations: `Cell(T)`, `Vec(T)`, and `Signal(T)`. Their methods are
//! ordinary method Fields on generic symbols, so calls go through the
//! same lookup and substitution as user generics; the runtime
//! (`runtime.zig`) implements them.

const std = @import("std");
const types = @import("types.zig");

const SemContext = types.SemContext;
const SymbolId = types.SymbolId;
const ScopeId = types.ScopeId;
const TypeId = types.TypeId;
const Field = types.Field;
const MethodReceiver = types.MethodReceiver;
const Error = std.mem.Allocator.Error;

const pos = types.builtin_decl_pos;

/// Names users cannot redeclare: emit recognizes these by name.
pub fn isReservedName(name: []const u8) bool {
    const reserved = [_][]const u8{ "Cell", "Vec", "Signal" };
    for (reserved) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    return false;
}

pub fn register(ctx: *SemContext, module_scope: ScopeId) Error!void {
    // Cell(T): interior-mutable slot. Methods take `?self`; the runtime
    // mutates through its own pointer.
    {
        const g = try addGeneric(ctx, module_scope, "Cell", &.{"T"});
        ctx.cell_sym_id = g.sym;
        const t = g.params[0];
        const self_ty = try ctx.intern(.{ .borrow_read = g.self_ty });
        try setFields(ctx, g.sym, &.{
            .{ .name = "value", .ty = t, .decl_pos = pos },
            try method(ctx, "get", .read, &.{self_ty}, t),
            try method(ctx, "set", .read, &.{ self_ty, t }, ctx.types.void_id),
            // Swap in a new value and return the old one as owned.
            try method(ctx, "replace", .read, &.{ self_ty, t }, t),
        });
    }

    // Vec(T): growable buffer that owns its elements.
    {
        const g = try addGeneric(ctx, module_scope, "Vec", &.{"T"});
        ctx.vec_sym_id = g.sym;
        const t = g.params[0];
        const read_self = try ctx.intern(.{ .borrow_read = g.self_ty });
        const write_self = try ctx.intern(.{ .borrow_write = g.self_ty });
        const opt_t = try ctx.intern(.{ .optional = t });
        try setFields(ctx, g.sym, &.{
            try method(ctx, "push", .write, &.{ write_self, t }, ctx.types.void_id),
            try method(ctx, "length", .read, &.{read_self}, ctx.types.int_id),
            try method(ctx, "clear", .write, &.{write_self}, ctx.types.void_id),
            try method(ctx, "get", .read, &.{ read_self, ctx.types.int_id }, opt_t),
            try method(ctx, "pop", .write, &.{write_self}, opt_t),
        });
    }

    // Signal(T): a Copy value plus subscriber closures notified on `set`.
    {
        const g = try addGeneric(ctx, module_scope, "Signal", &.{"T"});
        ctx.signal_sym_id = g.sym;
        const t = g.params[0];
        const self_ty = try ctx.intern(.{ .borrow_read = g.self_ty });
        // Subscribers are owned closures `*sub()`.
        const callback = try ctx.intern(.{ .function = .{ .params = &.{}, .returns = ctx.types.void_id, .is_sub = true } });
        const closure_handle = try ctx.intern(.{ .shared = callback });
        try setFields(ctx, g.sym, &.{
            .{ .name = "value", .ty = t, .decl_pos = pos },
            try method(ctx, "get", .read, &.{self_ty}, t),
            try method(ctx, "set", .read, &.{ self_ty, t }, ctx.types.void_id),
            try method(ctx, "subscribe", .read, &.{ self_ty, closure_handle }, ctx.types.void_id),
        });
    }
}

const Generic = struct {
    sym: SymbolId,
    /// `type_var` TypeIds of the parameters, in order.
    params: []const TypeId,
    /// The type applied to its own parameters: `Vec(T)`.
    self_ty: TypeId,
};

fn addGeneric(ctx: *SemContext, module_scope: ScopeId, name: []const u8, param_names: []const []const u8) Error!Generic {
    const sym: SymbolId = @intCast(ctx.symbols.items.len);
    try ctx.symbols.append(ctx.allocator, .{
        .name = name,
        .kind = .generic_type,
        .ty = ctx.types.unknown_id,
        .decl_pos = pos,
        .scope = module_scope,
    });
    try ctx.scopes.items[module_scope].symbols.append(ctx.allocator, sym);

    const arena = ctx.arena.allocator();
    const param_syms = try arena.alloc(SymbolId, param_names.len);
    const param_tys = try arena.alloc(TypeId, param_names.len);
    for (param_names, 0..) |pname, i| {
        // Generic parameters are detached: in the symbol table, not in a scope.
        param_syms[i] = @intCast(ctx.symbols.items.len);
        try ctx.symbols.append(ctx.allocator, .{
            .name = pname,
            .kind = .generic_param,
            .ty = ctx.types.unknown_id,
            .decl_pos = pos,
            .scope = module_scope,
        });
        param_tys[i] = try ctx.intern(.{ .type_var = param_syms[i] });
    }
    ctx.symbols.items[sym].type_params = param_syms;
    const self_ty = try ctx.intern(.{ .parameterized_nominal = .{ .sym = sym, .args = param_tys } });
    return .{ .sym = sym, .params = param_tys, .self_ty = self_ty };
}

fn method(ctx: *SemContext, name: []const u8, receiver: MethodReceiver, params: []const TypeId, returns: TypeId) Error!Field {
    const ty = try ctx.intern(.{ .function = .{
        .params = try ctx.dupeIds(params),
        .returns = returns,
        .is_sub = returns == ctx.types.void_id,
    } });
    return .{ .name = name, .ty = ty, .decl_pos = pos, .is_method = true, .receiver = receiver };
}

fn setFields(ctx: *SemContext, sym: SymbolId, fields: []const Field) Error!void {
    ctx.symbols.items[sym].fields = try ctx.arena.allocator().dupe(Field, fields);
}

test "builtins: registered with methods" {
    var ctx = try SemContext.init(std.testing.allocator, "");
    defer ctx.deinit();
    const scope = try ctx.pushScopeKind(types.scope_invalid, .module);
    try register(&ctx, scope);
    const vec = ctx.lookup(scope, "Vec").?;
    try std.testing.expectEqual(ctx.vec_sym_id, vec);
    try std.testing.expectEqual(@as(usize, 5), ctx.symbols.items[vec].fields.?.len);
    try std.testing.expect(ctx.lookup(scope, "T") == null);
}
