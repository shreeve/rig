//! Declarations: symbol resolution and signature types.
//!
//! `resolveSymbols` walks the whole IR once, creating a Symbol for every
//! declaration and binding and a Scope for every node that opens one.
//! Each scope is recorded in the facts table under its node, so later
//! walks enter scopes by node identity rather than by visiting order.
//!
//! `resolveDeclarations` then turns every declared type expression into
//! a TypeId: function signatures, parameter types, struct fields, enum
//! variants, methods, `drop` bodies, externs, and type aliases.
//! `TypeResolver.resolveType` is also used by the expression checker for
//! annotations inside bodies.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const types = @import("types.zig");
const builtins = @import("sema_builtins.zig");

const Sexp = parser.Sexp;
const Tag = rig.Tag;
const SemContext = types.SemContext;
const SymbolId = types.SymbolId;
const ScopeId = types.ScopeId;
const TypeId = types.TypeId;
const Type = types.Type;
const Symbol = types.Symbol;
const Field = types.Field;
const MethodReceiver = types.MethodReceiver;
const NominalContext = types.NominalContext;
const Error = std.mem.Allocator.Error;

const identAt = types.identAt;
const srcPos = types.srcPos;
const headOf = types.headOf;
const isHead = types.isHead;
const firstSrcPos = types.diag.firstSrcPos;

// =============================================================================
// Symbol resolution
// =============================================================================

pub fn resolveSymbols(ctx: *SemContext, ir: Sexp, module_scope: ScopeId) Error!void {
    var r: SymbolResolver = .{ .ctx = ctx, .scope = module_scope, .module_scope = module_scope };
    try r.walk(ir);
}

const SymbolResolver = struct {
    ctx: *SemContext,
    scope: ScopeId,
    module_scope: ScopeId,

    fn walk(self: *SymbolResolver, sexp: Sexp) Error!void {
        const head = headOf(sexp) orelse return;
        const items = sexp.list;
        switch (head) {
            .@"module" => for (items[1..]) |c| try self.walk(c),
            .@"pub" => {
                const before = self.ctx.symbols.items.len;
                try self.walk(items[1]);
                if (self.ctx.symbols.items.len > before) self.ctx.symbols.items[before].flags.is_public = true;
            },
            .@"fun", .@"sub" => try self.walkFun(sexp, true),
            .@"lambda" => try self.walkLambda(sexp),
            .@"use" => try self.walkUse(items),
            .@"type" => try self.walkTypeAlias(items),
            .@"generic_type", .@"generic_enum" => try self.walkGenericType(items),
            .@"struct", .@"enum", .@"errors" => try self.walkNominalType(items),
            .@"extern" => try self.walkExtern(items),
            .@"extern_fun", .@"extern_sub" => {
                _ = try self.declare(items[1], .@"extern", .{});
            },
            .@"test" => try self.walkTest(sexp),
            .@"set" => try self.walkSet(items),
            .@"block" => {
                const prev = try self.enter(sexp, .block);
                defer self.scope = prev;
                for (items[1..]) |c| try self.walk(c);
            },
            .@"for" => try self.walkFor(sexp),
            .@"if" => try self.walkConditional(items[1], items[2..3], items[3..]),
            .@"write" => {
                try self.markWritten(items[1]);
                try self.walk(items[1]);
            },
            .@"while" => try self.walkConditional(items[1], items[2..4], items[4..]),
            .@"arm" => try self.walkArm(sexp),
            .@"catch_block" => try self.walkCatchBlock(sexp),
            .@"catch" => try self.walkCatch(sexp),
            else => for (items[1..]) |c| try self.walk(c),
        }
    }

    /// Open a scope for `node` and make it current; returns the previous scope.
    fn enter(self: *SymbolResolver, node: Sexp, kind: types.ScopeKind) Error!ScopeId {
        const s = try self.ctx.pushScopeKind(self.scope, kind);
        try self.ctx.recordScope(node, s);
        const prev = self.scope;
        self.scope = s;
        return prev;
    }

    fn addSymbol(self: *SymbolResolver, sym: Symbol) Error!SymbolId {
        const id: SymbolId = @intCast(self.ctx.symbols.items.len);
        try self.ctx.symbols.append(self.ctx.allocator, sym);
        try self.ctx.addToScope(sym.scope, id);
        return id;
    }

    fn addDetached(self: *SymbolResolver, sym: Symbol) Error!SymbolId {
        const id: SymbolId = @intCast(self.ctx.symbols.items.len);
        try self.ctx.symbols.append(self.ctx.allocator, sym);
        return id;
    }

    /// Declare a named symbol in the current scope and record the name
    /// fact. Module-level declarations must have unique names.
    fn declare(self: *SymbolResolver, name_node: Sexp, kind: types.SymbolKind, flags: types.SymbolFlags) Error!?SymbolId {
        const name = identAt(self.ctx.source, name_node) orelse return null;
        const pos = srcPos(name_node, 0);
        if (std.mem.eql(u8, name, "none")) {
            try self.ctx.err(pos, "`none` is the absent optional and cannot be used as a name", .{});
            return null;
        }
        if (self.scope == self.module_scope) {
            if (self.ctx.lookupInScopeOnly(self.scope, name)) |prev| {
                const p = self.ctx.symbols.items[prev];
                if (p.decl_pos == types.builtin_decl_pos) {
                    try self.ctx.err(pos, "`{s}` is a reserved built-in nominal name and cannot be redefined", .{name});
                } else {
                    try self.ctx.err(pos, "duplicate declaration of `{s}`", .{name});
                    try self.ctx.note(p.decl_pos, "`{s}` first declared here", .{name});
                }
                return null;
            }
        }
        const id = try self.addSymbol(.{
            .name = name,
            .kind = kind,
            .ty = self.ctx.types.unknown_id,
            .decl_pos = pos,
            .scope = self.scope,
            .flags = flags,
        });
        try self.ctx.recordName(name_node, id);
        return id;
    }

    /// Bind a new local that must not shadow a visible local (SPEC:
    /// implicit shadowing is illegal; `new x = ...` is the explicit form).
    fn bindFresh(self: *SymbolResolver, name_node: Sexp, what: []const u8) Error!?SymbolId {
        const name = identAt(self.ctx.source, name_node) orelse return null;
        if (std.mem.eql(u8, name, "_")) return null;
        try self.checkShadowing(name_node, what);
        return self.declare(name_node, .local, .{ .pattern_bound = true });
    }

    fn checkShadowing(self: *SymbolResolver, name_node: Sexp, what: []const u8) Error!void {
        const name = identAt(self.ctx.source, name_node) orelse return;
        const pos = srcPos(name_node, 0);
        if (self.visibleLocal(name)) |prev| {
            try self.ctx.err(pos, "{s} `{s}` shadows the local `{s}`; use a different name", .{ what, name, name });
            try self.ctx.note(self.ctx.symbols.items[prev].decl_pos, "`{s}` declared here", .{name});
            return;
        }
        if (self.scope != self.module_scope) try self.checkShadowsDeclaration(name_node, what);
    }

    /// A local in the current function (through blocks and lambdas),
    /// excluding module-level names.
    fn visibleLocal(self: *SymbolResolver, name: []const u8) ?SymbolId {
        var sid: ?ScopeId = self.scope;
        while (sid) |s| {
            if (s == self.module_scope or s == types.scope_invalid) return null;
            if (self.ctx.lookupInScopeOnly(s, name)) |id| return id;
            const scope = self.ctx.scopes.items[s];
            if (scope.kind == .function) return null;
            sid = scope.parent;
        }
        return null;
    }

    /// A local or parameter may not reuse the name of a module-level
    /// function, type, extern, or module: Zig rejects the shadowing.
    fn checkShadowsDeclaration(self: *SymbolResolver, name_node: Sexp, what: []const u8) Error!void {
        const name = identAt(self.ctx.source, name_node) orelse return;
        const decl = self.ctx.lookupInScopeOnly(self.module_scope, name) orelse return;
        const sym = self.ctx.symbols.items[decl];
        if (sym.kind == .local or sym.decl_pos == types.builtin_decl_pos) return;
        try self.ctx.err(srcPos(name_node, 0), "{s} `{s}` has the same name as the module-level declaration `{s}`; use a different name", .{ what, name, name });
        try self.ctx.note(sym.decl_pos, "`{s}` declared here", .{name});
    }

    fn walkFun(self: *SymbolResolver, node: Sexp, add_symbol: bool) Error!void {
        const items = node.list;
        if (add_symbol) _ = try self.declare(items[1], .function, .{});
        const prev = try self.enter(node, .function);
        defer self.scope = prev;
        try self.bindParams(items[2], &.{});
        try self.walk(items[items.len - 1]);
    }

    fn walkTest(self: *SymbolResolver, node: Sexp) Error!void {
        const items = node.list;
        const prev = try self.enter(node, .function);
        defer self.scope = prev;
        for (items[1..]) |c| try self.walk(c);
    }

    fn walkLambda(self: *SymbolResolver, node: Sexp) Error!void {
        const items = node.list;
        const prev = try self.enter(node, .lambda);
        defer self.scope = prev;
        // Captures first, so a parameter that reuses a capture's name is caught.
        for (types.captureList(items[1])) |cap| {
            const name_node = types.captureNameNode(cap) orelse continue;
            const name = identAt(self.ctx.source, name_node) orelse continue;
            if (self.ctx.lookupInScopeOnly(self.scope, name)) |first| {
                try self.ctx.err(srcPos(name_node, 0), "duplicate capture name `{s}`", .{name});
                try self.ctx.note(self.ctx.symbols.items[first].decl_pos, "first captured here", .{});
                continue;
            }
            _ = try self.declare(name_node, .capture, .{});
        }
        try self.bindParams(items[2], types.captureList(items[1]));
        try self.walk(items[4]);
    }

    fn bindParams(self: *SymbolResolver, params: Sexp, captures: []const Sexp) Error!void {
        if (params != .list) return;
        for (params.list, 0..) |p, i| {
            const name_node = types.paramNameNode(p) orelse continue;
            const name = identAt(self.ctx.source, name_node) orelse continue;
            const pos = srcPos(name_node, 0);
            var collides = false;
            for (captures) |cap| {
                const cn = types.captureNameNode(cap) orelse continue;
                if (std.mem.eql(u8, identAt(self.ctx.source, cn) orelse "", name)) {
                    try self.ctx.err(pos, "closure parameter `{s}` has the name of the capture `{s}`", .{ name, name });
                    try self.ctx.note(srcPos(cn, 0), "captured here", .{});
                    collides = true;
                }
            }
            if (collides) continue;
            // Any number of parameters may be ignored as `_`.
            for (params.list[0..i]) |earlier| {
                if (std.mem.eql(u8, name, "_")) break;
                if (std.mem.eql(u8, types.paramName(self.ctx.source, earlier) orelse "", name)) {
                    try self.ctx.err(pos, "duplicate parameter `{s}`", .{name});
                    collides = true;
                    break;
                }
            }
            if (collides) continue;
            if (self.ctx.scopes.items[self.scope].kind == .lambda) {
                try self.checkShadowingThroughLambda(name_node);
            } else {
                try self.checkShadowsDeclaration(name_node, "parameter");
            }
            const h = headOf(p);
            const borrowed = h == .@"read" or h == .@"write" or
                (p == .list and p.list.len >= 3 and types.isBorrowedTypeNode(p.list[2]));
            const is_pre = h == .@"pre_param";
            _ = try self.declare(name_node, .param, .{
                .borrowed_param = borrowed,
                .is_pre = is_pre,
                .comptime_known = is_pre,
            });
        }
    }

    /// A lambda's parameters live in the closure's own function, which
    /// Zig nests inside the enclosing one: they may not reuse its locals.
    fn checkShadowingThroughLambda(self: *SymbolResolver, name_node: Sexp) Error!void {
        const name = identAt(self.ctx.source, name_node) orelse return;
        const parent = self.ctx.scopes.items[self.scope].parent orelse return;
        const saved = self.scope;
        self.scope = parent;
        defer self.scope = saved;
        if (self.visibleLocal(name)) |prev| {
            try self.ctx.err(srcPos(name_node, 0), "closure parameter `{s}` has the name of the local `{s}`; to capture the local, give it a sigil (`|+{s}|` copies or clones it, `|<{s}|` moves it, `|~{s}|` holds it weakly), or name the parameter differently", .{ name, name, name, name, name });
            try self.ctx.note(self.ctx.symbols.items[prev].decl_pos, "`{s}` declared here", .{name});
            return;
        }
        try self.checkShadowsDeclaration(name_node, "parameter");
    }

    fn walkUse(self: *SymbolResolver, items: []const Sexp) Error!void {
        const id = (try self.declare(items[1], .module, .{})) orelse return;
        const name = identAt(self.ctx.source, items[1]).?;
        for (self.ctx.imports) |imp| {
            if (std.mem.eql(u8, imp.local_name, name)) {
                try self.ctx.module_refs.put(self.ctx.allocator, id, imp.module_id);
                break;
            }
        }
    }

    fn walkTypeAlias(self: *SymbolResolver, items: []const Sexp) Error!void {
        const id = (try self.declare(items[1], .type_alias, .{})) orelse return;
        try self.ctx.alias_targets.put(self.ctx.allocator, id, items[2]);
    }

    fn checkReserved(self: *SymbolResolver, name_node: Sexp) Error!bool {
        const name = identAt(self.ctx.source, name_node) orelse return true;
        if (!builtins.isReservedName(name)) return false;
        try self.ctx.err(srcPos(name_node, 0), "`{s}` is a reserved built-in nominal name and cannot be redefined", .{name});
        return true;
    }

    fn walkGenericType(self: *SymbolResolver, items: []const Sexp) Error!void {
        if (try self.checkReserved(items[1])) return;
        const id = (try self.declare(items[1], .generic_type, .{})) orelse return;
        const name = self.ctx.symbols.items[id].name;
        const params = items[2];
        if (params != .list or params.list.len == 0) {
            const kind = if (items[0].tag == .@"generic_enum") "enum" else "type";
            try self.ctx.err(srcPos(items[1], 0), "generic {s} `{s}` must declare at least one type parameter; for a non-generic {s}, drop the `()`", .{ kind, name, kind });
        }
        var ids: std.ArrayListUnmanaged(SymbolId) = .empty;
        defer ids.deinit(self.ctx.allocator);
        if (params == .list) {
            for (params.list, 0..) |p, i| {
                const pname = identAt(self.ctx.source, p) orelse continue;
                var dup = false;
                for (params.list[0..i]) |e| {
                    if (std.mem.eql(u8, identAt(self.ctx.source, e) orelse "", pname)) dup = true;
                }
                if (dup) {
                    try self.ctx.err(srcPos(p, 0), "duplicate generic parameter `{s}` on `{s}`", .{ pname, name });
                    continue;
                }
                const pid = try self.addDetached(.{
                    .name = pname,
                    .kind = .generic_param,
                    .ty = self.ctx.types.unknown_id,
                    .decl_pos = srcPos(p, 0),
                    .scope = self.scope,
                });
                try self.ctx.recordName(p, pid);
                try ids.append(self.ctx.allocator, pid);
            }
        }
        self.ctx.symbols.items[id].type_params = try self.ctx.arena.allocator().dupe(SymbolId, ids.items);
        try self.walkMembers(items[3..]);
    }

    fn walkNominalType(self: *SymbolResolver, items: []const Sexp) Error!void {
        if (try self.checkReserved(items[1])) return;
        _ = try self.declare(items[1], .nominal_type, .{});
        if (items.len > 2) try self.walkMembers(items[2..]);
    }

    fn walkMembers(self: *SymbolResolver, members: []const Sexp) Error!void {
        for (members) |m| {
            const h = headOf(m) orelse continue;
            switch (h) {
                .@"fun", .@"sub" => try self.walkFun(m, false),
                .@"drop_decl" => {
                    const prev = try self.enter(m, .function);
                    defer self.scope = prev;
                    try self.bindParams(m.list[1], &.{});
                    try self.walk(m.list[2]);
                },
                else => {},
            }
        }
    }

    /// `(extern _ name type)`: an extern variable.
    fn walkExtern(self: *SymbolResolver, items: []const Sexp) Error!void {
        _ = try self.declare(items[2], .@"extern", .{});
    }

    fn walkSet(self: *SymbolResolver, items: []const Sexp) Error!void {
        const kind = rig.bindingKindOf(items[1]) catch return;
        const target = items[2];
        try self.walk(items[4]);
        if (target != .src) {
            try self.markWritten(target);
            try self.walk(target);
            return;
        }
        // `_ = expr` discards the value; it binds nothing.
        if (std.mem.eql(u8, identAt(self.ctx.source, target).?, "_")) return;
        switch (kind) {
            .default, .@"move" => {
                if (self.assignable(identAt(self.ctx.source, target).?)) |existing| {
                    try self.ctx.recordName(target, existing);
                    self.ctx.symbols.items[existing].flags.reassigned = true;
                    return;
                }
                try self.checkNewLocal(target);
                _ = try self.declare(target, .local, .{});
            },
            .fixed => {
                if (self.scope != self.module_scope) {
                    if (self.visibleLocal(identAt(self.ctx.source, target).?)) |prev| {
                        const name = self.ctx.symbols.items[prev].name;
                        try self.ctx.err(srcPos(target, 0), "`{s}` is already bound; `=!` declares a new binding. Assign with `{s} = ...` or shadow with `new {s} = ...`", .{ name, name, name });
                        try self.ctx.note(self.ctx.symbols.items[prev].decl_pos, "`{s}` declared here", .{name});
                        try self.ctx.recordName(target, prev);
                        return;
                    }
                }
                try self.checkNewLocal(target);
                _ = try self.declare(target, .local, .{ .fixed = true });
            },
            .shadow => _ = try self.declare(target, .local, .{}),
            .@"+=", .@"-=", .@"*=", .@"/=" => {
                if (self.assignable(identAt(self.ctx.source, target).?)) |existing| {
                    self.ctx.symbols.items[existing].flags.reassigned = true;
                }
            },
        }
    }

    /// `!x`, `!x.f`, and assignments to `x.f` / `x[i]` write the binding
    /// `x` is: it cannot be a constant.
    fn markWritten(self: *SymbolResolver, place: Sexp) Error!void {
        var p = place;
        while (headOf(p)) |h| {
            if (h != .@"member" and h != .@"index") return;
            p = p.list[1];
        }
        const name = identAt(self.ctx.source, p) orelse return;
        const id = self.ctx.lookup(self.scope, name) orelse return;
        self.ctx.symbols.items[id].flags.written = true;
    }

    /// The existing binding `x = ...` assigns to: a local or parameter of
    /// the current body, or a module-level variable.
    fn assignable(self: *SymbolResolver, name: []const u8) ?SymbolId {
        if (self.ctx.lookupLocal(self.scope, name)) |id| {
            const k = self.ctx.symbols.items[id].kind;
            if (k == .local or k == .param or k == .capture) return id;
            return null;
        }
        const id = self.ctx.lookupInScopeOnly(self.module_scope, name) orelse return null;
        return if (self.ctx.symbols.items[id].kind == .local) id else null;
    }

    fn checkNewLocal(self: *SymbolResolver, name_node: Sexp) Error!void {
        if (self.scope == self.module_scope) return;
        try self.checkLambdaShadow(name_node);
        try self.checkShadowsDeclaration(name_node, "local");
    }

    /// Inside a lambda, a new local may not reuse a name of the
    /// enclosing function's locals (Zig would reject the shadowing).
    fn checkLambdaShadow(self: *SymbolResolver, name_node: Sexp) Error!void {
        const name = identAt(self.ctx.source, name_node) orelse return;
        const root = self.ctx.bodyRoot(self.scope) orelse return;
        if (self.ctx.scopes.items[root].kind != .lambda) return;
        const parent = self.ctx.scopes.items[root].parent orelse return;
        const saved = self.scope;
        self.scope = parent;
        defer self.scope = saved;
        if (self.visibleLocal(name)) |prev| {
            try self.ctx.err(srcPos(name_node, 0), "`{s}` inside the closure shadows the local `{s}` of the enclosing function; closures reach outer values only through captures", .{ name, name });
            try self.ctx.note(self.ctx.symbols.items[prev].decl_pos, "`{s}` declared here", .{name});
        }
    }

    fn walkFor(self: *SymbolResolver, node: Sexp) Error!void {
        const items = node.list;
        try self.walk(items[4]);
        {
            const prev = try self.enter(node, .block);
            defer self.scope = prev;
            _ = try self.bindFresh(items[2], "`for` binding");
            _ = try self.bindFresh(items[3], "`for` binding");
            try self.walk(items[5]);
        }
        try self.walk(items[6]);
    }

    /// An `if` / `while`. A condition `(as expr name)` opens a scope
    /// binding `name` over `bodies` (the branch or loop body the value
    /// is present in); `rest` (the `else`) is outside it.
    fn walkConditional(self: *SymbolResolver, cond: Sexp, bodies: []const Sexp, rest: []const Sexp) Error!void {
        if (isHead(cond, .@"as")) {
            try self.walk(cond.list[1]);
            const prev = try self.enter(cond, .block);
            defer self.scope = prev;
            _ = try self.bindFresh(cond.list[2], "optional binding");
            for (bodies) |b| try self.walk(b);
        } else {
            try self.walk(cond);
            for (bodies) |b| try self.walk(b);
        }
        for (rest) |r| try self.walk(r);
    }

    fn walkCatchBlock(self: *SymbolResolver, node: Sexp) Error!void {
        const items = node.list;
        const prev = try self.enter(node, .block);
        defer self.scope = prev;
        _ = try self.bindFresh(items[1], "`catch` binding");
        try self.walk(items[2]);
    }

    /// `(catch expr name-or-_ handler)`.
    fn walkCatch(self: *SymbolResolver, node: Sexp) Error!void {
        const items = node.list;
        try self.walk(items[1]);
        if (items[2] != .nil) {
            const prev = try self.enter(node, .block);
            defer self.scope = prev;
            _ = try self.bindFresh(items[2], "`catch` binding");
            try self.walk(items[3]);
        } else {
            try self.walk(items[items.len - 1]);
        }
    }

    fn walkArm(self: *SymbolResolver, node: Sexp) Error!void {
        const items = node.list;
        const prev = try self.enter(node, .block);
        defer self.scope = prev;
        const pattern = items[1];
        switch (pattern) {
            .src => if (!isWildcardPattern(self.ctx.source, pattern)) {
                _ = try self.bindFresh(pattern, "pattern binding");
            },
            .list => if (isHead(pattern, .@"variant_pattern")) {
                for (pattern.list[2..]) |b| _ = try self.bindFresh(b, "pattern binding");
            },
            else => {},
        }
        try self.walk(items[items.len - 1]);
    }

};

// =============================================================================
// Declaration types
// =============================================================================

pub fn resolveDeclarations(ctx: *SemContext, ir: Sexp, module_scope: ScopeId) Error!void {
    if (!isHead(ir, .@"module")) return;
    var tr: TypeResolver = .{ .ctx = ctx, .scope = module_scope };
    for (ir.list[1..]) |decl| try tr.resolveDecl(decl);
    try tr.checkPublicNominals();
}

pub const TypeResolver = struct {
    ctx: *SemContext,
    scope: ScopeId,
    nominal: NominalContext = NominalContext.none,
    /// The first generic instance `collectLeaks` saw since the last report.
    generic_leak: ?TypeId = null,

    fn resolveDecl(self: *TypeResolver, sexp: Sexp) Error!void {
        const head = headOf(sexp) orelse return;
        const items = sexp.list;
        switch (head) {
            .@"pub" => try self.resolveDecl(items[1]),
            .@"fun", .@"sub" => _ = try self.resolveFunction(sexp, types.symbol_invalid),
            .@"type" => {
                const id = self.ctx.symbolOf(items[1]) orelse return;
                _ = try self.resolveAlias(id);
            },
            .@"extern" => {
                const ty = try self.resolveType(items[3]);
                const id = self.ctx.symbolOf(items[2]) orelse return;
                self.ctx.symbols.items[id].ty = ty;
                if (self.ctx.types.get(ty) == .function) try self.checkExternSignature(items[2], ty);
            },
            .@"extern_fun", .@"extern_sub" => try self.resolveExternFun(items),
            .@"struct", .@"enum", .@"errors", .@"generic_type", .@"generic_enum" => try self.resolveNominal(items),
            else => {},
        }
    }

    // ---- functions ----------------------------------------------------------

    /// Resolve a `fun` / `sub` (or method) signature, write parameter
    /// types into the parameter symbols, and return the function type.
    /// Top-level functions also get the type on their symbol.
    fn resolveFunction(self: *TypeResolver, node: Sexp, nominal_sym: SymbolId) Error!TypeId {
        const items = node.list;
        const is_sub = items[0].tag == .@"sub";
        const params = items[2];
        const return_ty = if (is_sub or items[3] == .nil)
            self.ctx.types.void_id
        else
            try self.resolveReturnType(items[3]);

        var param_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer param_types.deinit(self.ctx.allocator);
        var pre_mask: u32 = 0;
        if (params == .list) {
            for (params.list, 0..) |p, i| {
                const pty = try self.resolveParamType(p);
                try param_types.append(self.ctx.allocator, pty);
                if (isHead(p, .@"pre_param") and i < 32) pre_mask |= @as(u32, 1) << @intCast(i);
                if (types.paramNameNode(p)) |pn| {
                    if (self.ctx.symbolOf(pn)) |pid| self.ctx.symbols.items[pid].ty = pty;
                }
            }
        }
        const fn_ty = try self.ctx.intern(.{ .function = .{
            .params = try self.ctx.dupeIds(param_types.items),
            .returns = return_ty,
            .is_sub = is_sub,
            .pre_mask = pre_mask,
        } });
        try self.ctx.recordType(items[1], fn_ty);
        if (nominal_sym == types.symbol_invalid) {
            if (self.ctx.symbolOf(items[1])) |fid| {
                self.ctx.symbols.items[fid].ty = fn_ty;
                self.ctx.symbols.items[fid].param_names = try self.paramNames(params);
                self.ctx.symbols.items[fid].param_defaults = try self.paramDefaults(params);
                if (self.ctx.symbols.items[fid].flags.is_public) {
                    try self.checkPublicSignature(fid, srcPos(items[1], 0), return_ty, param_types.items);
                }
            }
        }
        return fn_ty;
    }

    /// The default value of each parameter, or null when none has one.
    fn paramDefaults(self: *TypeResolver, params: Sexp) Error!?[]const ?Sexp {
        if (params != .list) return null;
        var any = false;
        const out = try self.ctx.arena.allocator().alloc(?Sexp, params.list.len);
        for (params.list, 0..) |p, i| {
            out[i] = if (isHead(p, .@"default")) p.list[3] else null;
            if (out[i] != null) any = true;
        }
        return if (any) out else null;
    }

    fn paramNames(self: *TypeResolver, params: Sexp) Error!?[]const []const u8 {
        if (params != .list) return &.{};
        const names = try self.ctx.arena.allocator().alloc([]const u8, params.list.len);
        for (params.list, 0..) |p, i| names[i] = types.paramName(self.ctx.source, p) orelse return null;
        return names;
    }

    /// Only a function's return type may be fallible (`T!`); Zig error
    /// unions with inferred error sets exist only there.
    fn resolveReturnType(self: *TypeResolver, node: Sexp) Error!TypeId {
        if (isHead(node, .@"error_union")) {
            const inner = try self.resolveType(node.list[1]);
            return self.ctx.intern(.{ .fallible = inner });
        }
        return self.resolveType(node);
    }

    pub fn resolveParamType(self: *TypeResolver, param: Sexp) Error!TypeId {
        switch (param) {
            .src => |s| {
                const name = identAt(self.ctx.source, param).?;
                if (std.mem.eql(u8, name, "self") and !self.nominal.isEmpty()) {
                    try self.ctx.err(s.pos, "`self` parameter requires an explicit receiver type; use `?self`, `!self`, or `self: Self`", .{});
                } else {
                    try self.ctx.err(s.pos, "parameter `{s}` needs a type annotation (`{s}: T`)", .{ name, name });
                }
                return self.ctx.types.invalid_id;
            },
            .list => |items| {
                const h = headOf(param) orelse return self.ctx.types.invalid_id;
                switch (h) {
                    .@":", .@"pre_param", .@"default" => return self.resolveType(items[2]),
                    .@"read", .@"write" => {
                        const name = identAt(self.ctx.source, items[1]) orelse return self.ctx.types.invalid_id;
                        const pos = srcPos(items[1], 0);
                        if (!std.mem.eql(u8, name, "self")) {
                            try self.ctx.err(pos, "sigil-prefixed parameter is only allowed for `self`; for other parameters use `{s}: ?Type` / `{s}: !Type`", .{ name, name });
                            return self.ctx.types.invalid_id;
                        }
                        if (self.nominal.isEmpty()) {
                            try self.ctx.err(pos, "`{s}self` is only allowed in a method body (inside a struct, enum, or errors declaration)", .{if (h == .@"read") "?" else "!"});
                            return self.ctx.types.invalid_id;
                        }
                        return self.ctx.intern(if (h == .@"read")
                            Type{ .borrow_read = self.nominal.self_type }
                        else
                            Type{ .borrow_write = self.nominal.self_type });
                    },
                    else => {},
                }
                try self.ctx.err(firstSrcPos(param), "unsupported parameter form", .{});
                return self.ctx.types.invalid_id;
            },
            else => return self.ctx.types.invalid_id,
        }
    }

    fn resolveExternFun(self: *TypeResolver, items: []const Sexp) Error!void {
        const is_sub = items[0].tag == .@"extern_sub";
        const params = items[2];
        const returns: Sexp = if (is_sub) .nil else items[3];
        const return_ty = if (returns == .nil) self.ctx.types.void_id else try self.resolveReturnType(returns);
        var ps: std.ArrayListUnmanaged(TypeId) = .empty;
        defer ps.deinit(self.ctx.allocator);
        if (params == .list) {
            for (params.list) |p| {
                if (isHead(p, .@"default")) try self.ctx.err(types.paramPos(p, firstSrcPos(p)), "an `extern` parameter cannot have a default value", .{});
                try ps.append(self.ctx.allocator, try self.resolveParamType(p));
            }
        }
        const fn_ty = try self.ctx.intern(.{ .function = .{
            .params = try self.ctx.dupeIds(ps.items),
            .returns = return_ty,
            .is_sub = is_sub,
        } });
        const id = self.ctx.symbolOf(items[1]) orelse return;
        self.ctx.symbols.items[id].ty = fn_ty;
        self.ctx.symbols.items[id].param_names = try self.paramNames(params);
        try self.checkExternSignature(items[1], fn_ty);
    }

    /// C functions take and return only integers, floats, and Bool.
    fn checkExternSignature(self: *TypeResolver, name_node: Sexp, fn_ty_id: TypeId) Error!void {
        const f = self.ctx.types.get(fn_ty_id).function;
        const name = identAt(self.ctx.source, name_node) orelse "extern";
        const pos = srcPos(name_node, 0);
        if (self.ctx.types.get(f.returns) == .fallible) {
            try self.ctx.err(pos, "an `extern` function cannot return a fallible type `{s}`; C functions report failure through their return value", .{try types.formatType(self.ctx, f.returns)});
        } else if (f.returns != self.ctx.types.void_id and !self.isCAbiType(f.returns)) {
            try self.ctx.err(pos, "`extern` function `{s}` cannot return `{s}`; only integers, floats, and Bool cross the C boundary", .{ name, try types.formatType(self.ctx, f.returns) });
        }
        for (f.params) |p| {
            if (!self.isCAbiType(p)) {
                try self.ctx.err(pos, "`extern` function `{s}` cannot take `{s}`; only integers, floats, and Bool cross the C boundary", .{ name, try types.formatType(self.ctx, p) });
            }
        }
    }

    fn isCAbiType(self: *TypeResolver, ty: TypeId) bool {
        if (ty == self.ctx.types.invalid_id) return true;
        return switch (self.ctx.types.get(ty)) {
            .int, .float, .bool => true,
            else => false,
        };
    }

    // ---- aliases ------------------------------------------------------------

    /// Resolve (once) and return an alias's target type.
    pub fn resolveAlias(self: *TypeResolver, id: SymbolId) Error!TypeId {
        const sym = &self.ctx.symbols.items[id];
        if (sym.ty != self.ctx.types.unknown_id) return sym.ty;
        const target = self.ctx.alias_targets.get(id) orelse return self.ctx.types.invalid_id;
        if (self.ctx.alias_in_progress.contains(id)) {
            try self.ctx.err(sym.decl_pos, "type alias `{s}` refers to itself", .{sym.name});
            sym.ty = self.ctx.types.invalid_id;
            return sym.ty;
        }
        try self.ctx.alias_in_progress.put(self.ctx.allocator, id, {});
        defer _ = self.ctx.alias_in_progress.remove(id);
        var module_resolver: TypeResolver = .{ .ctx = self.ctx, .scope = sym.scope };
        const ty = try module_resolver.resolveType(target);
        self.ctx.symbols.items[id].ty = ty;
        return ty;
    }

    // ---- nominal types ------------------------------------------------------

    fn resolveNominal(self: *TypeResolver, items: []const Sexp) Error!void {
        const sym_id = self.ctx.symbolOf(items[1]) orelse return;
        const head = items[0].tag;
        const generic = head == .@"generic_type" or head == .@"generic_enum";
        const is_enum = head == .@"enum" or head == .@"errors" or head == .@"generic_enum";
        const members = items[if (generic) 3 else 2..];

        const prev = self.nominal;
        self.nominal = try types.makeNominalContext(self.ctx, sym_id);
        defer self.nominal = prev;

        var fields: std.ArrayListUnmanaged(Field) = .empty;
        defer fields.deinit(self.ctx.allocator);
        const sym_name = self.ctx.symbols.items[sym_id].name;

        for (members) |m| {
            switch (m) {
                .src => |s| {
                    if (!is_enum) {
                        try self.ctx.err(s.pos, "field `{s}` needs a type (`{s}: T`)", .{ identAt(self.ctx.source, m).?, identAt(self.ctx.source, m).? });
                        continue;
                    }
                    const vname = identAt(self.ctx.source, m).?;
                    if (try self.checkDuplicateMember(fields.items, vname, s.pos, sym_name)) continue;
                    try fields.append(self.ctx.allocator, .{ .name = vname, .ty = self.ctx.types.void_id, .decl_pos = s.pos, .is_variant = true });
                },
                .list => |mi| {
                    const h = headOf(m) orelse continue;
                    switch (h) {
                        .@":", .@"default" => {
                            if (mi.len < 3) continue;
                            const fname = identAt(self.ctx.source, mi[1]) orelse continue;
                            const fpos = srcPos(mi[1], 0);
                            if (h == .@"default") {
                                try self.ctx.err(fpos, "field default values are not supported yet; pass `{s}` in every constructor", .{fname});
                            }
                            if (is_enum) {
                                try self.ctx.err(fpos, "an enum declares variants, not typed fields; write `{s}` or `{s}(field: T)`", .{ fname, fname });
                                continue;
                            }
                            if (try self.checkDuplicateMember(fields.items, fname, fpos, sym_name)) continue;
                            const fty = try self.resolveType(mi[2]);
                            try fields.append(self.ctx.allocator, .{ .name = fname, .ty = fty, .decl_pos = fpos });
                        },
                        .@"valued" => {
                            const vname = identAt(self.ctx.source, mi[1]) orelse continue;
                            if (!is_enum) {
                                try self.ctx.err(srcPos(mi[1], 0), "field `{s}` needs a type (`{s}: T = value`)", .{ vname, vname });
                                continue;
                            }
                            if (head == .@"errors") {
                                try self.ctx.err(srcPos(mi[1], 0), "error set members have no values; write `{s}`", .{vname});
                            }
                            if (try self.checkDuplicateMember(fields.items, vname, srcPos(mi[1], 0), sym_name)) continue;
                            try fields.append(self.ctx.allocator, .{ .name = vname, .ty = self.ctx.types.void_id, .decl_pos = srcPos(mi[1], 0), .is_variant = true });
                        },
.@"variant" => {
                            if (!is_enum or head == .@"errors") {
                                try self.ctx.err(firstSrcPos(m), "only enums declare payload variants", .{});
                                continue;
                            }
                            try self.resolveVariant(mi, &fields, sym_name);
                        },
                        .@"fun", .@"sub" => {
                            if (head == .@"errors") {
                                try self.ctx.err(srcPos(mi[1], 0), "an error set cannot declare methods; write a function that takes the error", .{});
                                continue;
                            }
                            try self.resolveMethod(m, sym_id, &fields);
                        },
                        .@"read", .@"write" => {
                            const n = identAt(self.ctx.source, mi[1]) orelse "name";
                            try self.ctx.err(types.paramPos(m, 0), "sigil-prefixed member (`?{s}` / `!{s}`) is not allowed in a nominal body; sigil-prefix sugar is only valid for the `self` parameter of a method", .{ n, n });
                        },
                        .@"drop_decl" => {
                            if (head == .@"struct") {
                                try self.resolveDropDecl(m, sym_id, &fields);
                            } else {
                                const where: []const u8 = switch (head) {
                                    .@"errors" => "error sets",
                                    .@"generic_type", .@"generic_enum" => "generic types",
                                    else => "enums",
                                };
                                try self.ctx.err(dropPos(m), "`drop` declarations on {s} are deferred (only plain structs can declare `drop`); {s}", .{
                                    where,
                                    if (generic) "generic Drop requires bounds / monomorphized resource analysis" else "enum Drop requires per-variant payload drop",
                                });
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        const owned = try self.ctx.arena.allocator().dupe(Field, fields.items);
        self.ctx.symbols.items[sym_id].fields = owned;

        if (head == .@"struct") {
            // `types.propagateDropGlue` finishes this once every type is resolved.
            self.ctx.symbols.items[sym_id].flags.has_drop_glue = types.fieldsHaveDropGlue(self.ctx, owned);
            for (members) |m| {
                if (isHead(m, .@"drop_decl")) {
                    try self.enforceDropBody(m.list[2], owned);
                }
            }
        }
    }

    fn checkDuplicateMember(self: *TypeResolver, fields: []const Field, name: []const u8, pos: u32, owner: []const u8) Error!bool {
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, name)) {
                try self.ctx.err(pos, "duplicate member `{s}` in `{s}`", .{ name, owner });
                try self.ctx.note(f.decl_pos, "first declared here", .{});
                return true;
            }
        }
        return false;
    }

    fn resolveVariant(self: *TypeResolver, mi: []const Sexp, fields: *std.ArrayListUnmanaged(Field), owner: []const u8) Error!void {
        if (mi.len < 3) return;
        const vname = identAt(self.ctx.source, mi[1]) orelse return;
        const vpos = srcPos(mi[1], 0);
        if (try self.checkDuplicateMember(fields.items, vname, vpos, owner)) return;
        var payload: std.ArrayListUnmanaged(Field) = .empty;
        defer payload.deinit(self.ctx.allocator);
        if (mi[2] == .list) {
            for (mi[2].list) |p| {
                if (!isHead(p, .@":") or p.list.len < 3) {
                    try self.ctx.err(firstSrcPos(p), "variant payload fields need types (`name: T`)", .{});
                    continue;
                }
                const fname = identAt(self.ctx.source, p.list[1]) orelse continue;
                try payload.append(self.ctx.allocator, .{
                    .name = fname,
                    .ty = try self.resolveType(p.list[2]),
                    .decl_pos = srcPos(p.list[1], 0),
                });
            }
        }
        try fields.append(self.ctx.allocator, .{
            .name = vname,
            .ty = self.ctx.types.void_id,
            .decl_pos = vpos,
            .payload = try self.ctx.arena.allocator().dupe(Field, payload.items),
            .is_variant = true,
        });
    }

    fn resolveMethod(self: *TypeResolver, node: Sexp, nominal_sym: SymbolId, fields: *std.ArrayListUnmanaged(Field)) Error!void {
        const items = node.list;
        const mname = identAt(self.ctx.source, items[1]) orelse return;
        const mpos = srcPos(items[1], 0);
        const owner = self.ctx.symbols.items[nominal_sym].name;
        if (try self.checkDuplicateMember(fields.items, mname, mpos, owner)) return;
        const fn_ty = try self.resolveFunction(node, nominal_sym);
        const params = items[2];
        var receiver: MethodReceiver = .none;
        if (params == .list and params.list.len > 0) {
            for (params.list, 0..) |p, i| {
                if (i == 0) continue;
                const is_self = std.mem.eql(u8, types.paramName(self.ctx.source, p) orelse "", "self");
                const h = headOf(p);
                if (is_self) {
                    try self.ctx.err(types.paramPos(p, mpos), "`self` must be the first parameter of a method", .{});
                }
                if (h == .@"read" or h == .@"write") {
                    try self.ctx.err(types.paramPos(p, mpos), "sigil-prefixed parameter sugar (`?self` / `!self`) is only allowed at the first parameter position", .{});
                }
            }
            const first = params.list[0];
            if (std.mem.eql(u8, types.paramName(self.ctx.source, first) orelse "", "self")) {
                receiver = try self.classifyReceiver(first, fn_ty, nominal_sym, mpos);
            }
        }
        try fields.append(self.ctx.allocator, .{
            .name = mname,
            .ty = fn_ty,
            .decl_pos = mpos,
            .is_method = true,
            .receiver = receiver,
            .param_names = try self.paramNames(params),
            .param_defaults = try self.paramDefaults(params),
        });
    }

    fn classifyReceiver(self: *TypeResolver, first: Sexp, fn_ty_id: TypeId, nominal_sym: SymbolId, mpos: u32) Error!MethodReceiver {
        const fn_ty = self.ctx.types.get(fn_ty_id);
        if (fn_ty != .function or fn_ty.function.params.len == 0) return .none;
        const pty_id = fn_ty.function.params[0];
        const nom = self.ctx.symbols.items[nominal_sym].name;
        const self_ty = self.nominal.self_type;
        switch (self.ctx.types.get(pty_id)) {
            .borrow_read => |inner| {
                if (inner == self_ty) return .read;
                try self.ctx.err(mpos, "`self` receiver type must be `?Self` or `?{s}`", .{nom});
            },
            .borrow_write => |inner| {
                if (inner == self_ty) return .write;
                try self.ctx.err(mpos, "`self` receiver type must be `!Self` or `!{s}`", .{nom});
            },
            .nominal, .parameterized_nominal => {
                if (pty_id == self_ty) return .value;
                try self.ctx.err(mpos, "`self` receiver type must be `Self` or `{s}`", .{nom});
            },
            .unknown, .invalid => _ = first,
            else => try self.ctx.err(mpos, "`self` receiver type must be `?Self`, `!Self`, `Self`, or an explicit `{s}` form", .{nom}),
        }
        return .none;
    }

    fn resolveDropDecl(self: *TypeResolver, node: Sexp, nominal_sym: SymbolId, fields: *std.ArrayListUnmanaged(Field)) Error!void {
        const items = node.list;
        const pos = dropPos(node);
        for (fields.items) |f| {
            if (f.is_drop_method) {
                try self.ctx.err(pos, "duplicate `drop` declaration on this struct; a struct has at most one `drop`", .{});
                return;
            }
        }
        const params = items[1];
        const count: usize = if (params == .list) params.list.len else 0;
        var ptys: [1]TypeId = undefined;
        if (params == .list) {
            for (params.list, 0..) |p, i| {
                const pty = try self.resolveParamType(p);
                if (i == 0) ptys[0] = pty;
                if (types.paramNameNode(p)) |pn| {
                    if (self.ctx.symbolOf(pn)) |pid| self.ctx.symbols.items[pid].ty = pty;
                }
            }
        }
        if (count != 1) {
            try self.ctx.err(pos, "`drop` declaration must take exactly one parameter `self: !Self`; got {d} parameter(s)", .{count});
            return;
        }
        const first = params.list[0];
        if (!std.mem.eql(u8, types.paramName(self.ctx.source, first) orelse "", "self")) {
            try self.ctx.err(types.paramPos(first, pos), "`drop` declaration's parameter must be named `self`", .{});
            return;
        }
        const pty = self.ctx.types.get(ptys[0]);
        const ok = pty == .borrow_write and blk: {
            break :blk switch (self.ctx.types.get(pty.borrow_write)) {
                .nominal => |s| s == nominal_sym,
                else => false,
            };
        };
        if (!ok) {
            try self.ctx.err(types.paramPos(first, pos), "`drop` declaration must use `self: !Self` (write-borrow); other receiver shapes are rejected", .{});
            return;
        }
        const fn_ty = try self.ctx.intern(.{ .function = .{
            .params = try self.ctx.dupeIds(&ptys),
            .returns = self.ctx.types.void_id,
            .is_sub = true,
        } });
        try fields.append(self.ctx.allocator, .{
            .name = "drop",
            .ty = fn_ty,
            .decl_pos = pos,
            .is_method = true,
            .receiver = .write,
            .is_drop_method = true,
        });
    }

    /// Inside `drop`, the body runs before the generated field drops, so
    /// it must not consume `self` or move/replace a field with drop glue.
    fn enforceDropBody(self: *TypeResolver, body: Sexp, fields: []const Field) Error!void {
        const head = headOf(body) orelse return;
        const items = body.list;
        switch (head) {
            .@"drop" => if (self.isSelf(items[1])) {
                try self.ctx.err(items[1].src.pos, "cannot drop `self` inside its own drop body; the binding is being destroyed by the runtime", .{});
            },
            .@"move" => {
                if (self.isSelf(items[1])) {
                    try self.ctx.err(items[1].src.pos, "cannot move `self` out of its own drop body; the binding is being destroyed by the runtime", .{});
                } else try self.checkDropBodyField(items[1], fields, "move");
            },
            .@"return" => if (self.isSelf(items[1])) {
                try self.ctx.err(items[1].src.pos, "cannot return `self` from its own drop body", .{});
            },
            .@"set" => if (self.isSelf(items[2])) {
                try self.ctx.err(items[2].src.pos, "cannot reassign `self` inside its own drop body; dropping the old value would run this body again", .{});
            } else try self.checkDropBodyField(items[2], fields, "reassign"),
            else => {},
        }
        for (items[1..]) |c| try self.enforceDropBody(c, fields);
    }

    fn isSelf(self: *TypeResolver, node: Sexp) bool {
        return std.mem.eql(u8, identAt(self.ctx.source, node) orelse "", "self");
    }

    fn checkDropBodyField(self: *TypeResolver, member: Sexp, fields: []const Field, op: []const u8) Error!void {
        if (!isHead(member, .@"member")) return;
        if (!self.isSelf(member.list[1])) return;
        const fname = identAt(self.ctx.source, member.list[2]) orelse return;
        for (fields) |f| {
            if (f.is_method or f.is_variant or !std.mem.eql(u8, f.name, fname)) continue;
            if (types.typeHasDropGlue(self.ctx, f.ty)) {
                try self.ctx.err(srcPos(member.list[2], 0), "cannot {s} resource field `self.{s}` inside drop body; fields are dropped automatically after the user drop body returns, so a manual {s} would race the auto-generated drop and double-free", .{ op, fname, op });
            }
            return;
        }
    }

    // ---- type expressions ---------------------------------------------------

    pub fn resolveType(self: *TypeResolver, sexp: Sexp) Error!TypeId {
        const t = &self.ctx.types;
        switch (sexp) {
            .nil => return t.void_id,
            .src => |s| {
                const name = identAt(self.ctx.source, sexp).?;
                if (primitiveTypeId(self.ctx, name)) |id| return id;
                if (sizedTypeId(self.ctx, name)) |id| return try id;
                if (!self.nominal.isEmpty()) {
                    if (std.mem.eql(u8, name, "Self")) return self.nominal.self_type;
                    for (self.nominal.type_params) |tp| {
                        if (std.mem.eql(u8, self.ctx.symbols.items[tp].name, name)) {
                            try self.ctx.recordName(sexp, tp);
                            return self.ctx.intern(.{ .type_var = tp });
                        }
                    }
                }
                if (self.ctx.lookup(self.scope, name)) |id| {
                    const sym = self.ctx.symbols.items[id];
                    switch (sym.kind) {
                        .nominal_type => {
                            try self.ctx.recordName(sexp, id);
                            return self.ctx.intern(.{ .nominal = id });
                        },
                        .type_alias => {
                            try self.ctx.recordName(sexp, id);
                            return self.resolveAlias(id);
                        },
                        .generic_type => {
                            const arity = if (sym.type_params) |tps| tps.len else 0;
                            if (arity > 0) {
                                try self.ctx.err(s.pos, "generic type `{s}` requires type arguments; write `{s}(T)`", .{ name, name });
                            } else {
                                try self.ctx.err(s.pos, "generic type `{s}` must be written with empty parentheses; write `{s}()`", .{ name, name });
                            }
                            return t.invalid_id;
                        },
                        else => {
                            try self.ctx.err(s.pos, "`{s}` is not a type", .{name});
                            return t.invalid_id;
                        },
                    }
                }
                try self.ctx.err(s.pos, "use of unbound type `{s}`", .{name});
                return t.invalid_id;
            },
            .list => |items| {
                const head = headOf(sexp) orelse return t.invalid_id;
                switch (head) {
                    .@"optional" => {
                        const inner = try self.resolveType(items[1]);
                        if (inner == t.invalid_id) return t.invalid_id;
                        return self.ctx.intern(.{ .optional = inner });
                    },
                    .@"error_union" => {
                        const inner = try self.resolveType(items[1]);
                        const ty = try self.ctx.intern(.{ .fallible = inner });
                        try self.ctx.err(firstSrcPos(sexp), "a fallible type `{s}` is only allowed as a function's return type (a fallible handle is `(*T)!`)", .{try types.formatType(self.ctx, ty)});
                        return t.invalid_id;
                    },
                    .@"borrow_read", .@"borrow_write", .@"weak", .@"slice" => {
                        const inner = try self.resolveType(items[1]);
                        if (inner == t.invalid_id) return t.invalid_id;
                        return switch (head) {
                            .@"borrow_read" => self.ctx.intern(.{ .borrow_read = inner }),
                            .@"borrow_write" => self.ctx.intern(.{ .borrow_write = inner }),
                            .@"weak" => self.ctx.intern(.{ .weak = inner }),
                            else => self.ctx.intern(.{ .slice = .{ .elem = inner } }),
                        };
                    },
                    .@"shared" => {
                        const inner = try self.resolveType(items[1]);
                        if (inner == t.invalid_id) return t.invalid_id;
                        if (self.ctx.types.get(inner) == .shared) {
                            try self.ctx.err(firstSrcPos(items[1]), "nested shared type `**T` is not meaningful; use a single `*T`", .{});
                            return t.invalid_id;
                        }
                        if (self.ctx.types.get(inner) == .function) try self.checkOwnedClosureType(items[1], inner);
                        return self.ctx.intern(.{ .shared = inner });
                    },
                    .@"array_type" => {
                        const len = types.parseIntegerLiteral(self.ctx.source, items[1]) orelse {
                            try self.ctx.err(firstSrcPos(items[1]), "array length must be an integer literal", .{});
                            return t.invalid_id;
                        };
                        const elem = try self.resolveType(items[2]);
                        if (types.typeHasDropGlue(self.ctx, elem)) {
                            try self.ctx.err(firstSrcPos(items[2]), "arrays cannot hold values that own resources (`{s}`); use a `Vec`", .{try types.formatType(self.ctx, elem)});
                            return t.invalid_id;
                        }
                        return self.ctx.intern(.{ .array = .{ .elem = elem, .len = len } });
                    },
                    .@"fun_type" => {
                        var ps: std.ArrayListUnmanaged(TypeId) = .empty;
                        defer ps.deinit(self.ctx.allocator);
                        if (items[1] == .list) {
                            for (items[1].list) |p| try ps.append(self.ctx.allocator, try self.resolveType(p));
                        }
                        const ret = try self.resolveReturnType(items[2]);
                        return self.ctx.intern(.{ .function = .{
                            .params = try self.ctx.dupeIds(ps.items),
                            .returns = ret,
                            .is_sub = ret == t.void_id,
                        } });
                    },
                    .@"generic_inst" => return self.resolveGenericInst(sexp),
                    .@"member" => return self.resolveQualified(items[1], items[2]),
                    else => {
                        try self.ctx.err(firstSrcPos(sexp), "unsupported type expression", .{});
                        return t.invalid_id;
                    },
                }
            },
            else => return t.invalid_id,
        }
    }

    /// `module.Name`: a public type of an imported module.
    fn resolveQualified(self: *TypeResolver, module_node: Sexp, name_node: Sexp) Error!TypeId {
        const t = &self.ctx.types;
        const module_name = identAt(self.ctx.source, module_node) orelse return t.invalid_id;
        const name = identAt(self.ctx.source, name_node) orelse return t.invalid_id;
        const pos = srcPos(name_node, 0);
        const mod_id = self.ctx.lookup(self.scope, module_name) orelse {
            try self.ctx.err(srcPos(module_node, 0), "use of unbound module `{s}`; import it with `use {s}`", .{ module_name, module_name });
            return t.invalid_id;
        };
        if (self.ctx.symbols.items[mod_id].kind != .module) {
            try self.ctx.err(srcPos(module_node, 0), "`{s}` is not a module; a qualified type is written `module.Type`", .{module_name});
            return t.invalid_id;
        }
        try self.ctx.recordName(module_node, mod_id);
        const origin = self.ctx.module_refs.get(mod_id) orelse return t.invalid_id;
        const foreign = self.ctx.foreign_semas.get(origin) orelse return t.invalid_id;
        const fid = foreign.lookupInScopeOnly(1, name) orelse {
            try self.ctx.err(pos, "no type `{s}` in module `{s}`", .{ name, module_name });
            return t.invalid_id;
        };
        const fsym = foreign.symbols.items[fid];
        switch (fsym.kind) {
            .nominal_type, .type_alias => {},
            .generic_type => {
                try self.ctx.err(pos, "generic type `{s}.{s}` needs type arguments, which qualified types do not take yet", .{ module_name, name });
                return t.invalid_id;
            },
            else => {
                try self.ctx.err(pos, "`{s}.{s}` is not a type", .{ module_name, name });
                return t.invalid_id;
            },
        }
        if (!fsym.flags.is_public) {
            try self.ctx.err(pos, "`{s}.{s}` is not public; mark it `pub` in module `{s}` to expose it across module boundaries", .{ module_name, name, module_name });
            return t.invalid_id;
        }
        if (fsym.kind == .type_alias) return types.importType(self.ctx, foreign, fsym.ty, origin);
        return self.ctx.intern(.{ .imported_nominal = .{ .module_id = origin, .sym_id = fid } });
    }

    /// `*fun(...) R` / `*sub(...)`: an owned closure passes plain Copy
    /// values through its type-erased form.
    fn checkOwnedClosureType(self: *TypeResolver, fun_type: Sexp, ty: TypeId) Error!void {
        const f = self.ctx.types.get(ty).function;
        const nodes: []const Sexp = if (isHead(fun_type, .@"fun_type") and fun_type.list[1] == .list) fun_type.list[1].list else &.{};
        for (f.params, 0..) |p, i| {
            if (types.isClosureValue(self.ctx, p)) continue;
            const pos = if (i < nodes.len) firstSrcPos(nodes[i]) else firstSrcPos(fun_type);
            try self.ctx.err(pos, "an owned closure takes plain Copy values (Int, Float, Bool, String, sized numbers, plain enums, or optionals of these); `{s}` is not one", .{try types.formatType(self.ctx, p)});
        }
        if (!f.is_sub and !types.isClosureValue(self.ctx, f.returns)) {
            const pos = if (isHead(fun_type, .@"fun_type") and fun_type.list[2] != .nil) firstSrcPos(fun_type.list[2]) else firstSrcPos(fun_type);
            try self.ctx.err(pos, "an owned closure returns plain Copy values (Int, Float, Bool, String, sized numbers, plain enums, or optionals of these); `{s}` is not one", .{try types.formatType(self.ctx, f.returns)});
        }
    }

    fn resolveGenericInst(self: *TypeResolver, sexp: Sexp) Error!TypeId {
        const items = sexp.list;
        const t = &self.ctx.types;
        const name = identAt(self.ctx.source, items[1]) orelse return t.invalid_id;
        const pos = srcPos(items[1], 0);
        const sym_id = self.ctx.lookup(self.scope, name) orelse {
            try self.ctx.err(pos, "use of unbound type `{s}`", .{name});
            return t.invalid_id;
        };
        try self.ctx.recordName(items[1], sym_id);
        const sym = self.ctx.symbols.items[sym_id];
        if (sym.kind != .generic_type) {
            try self.ctx.err(pos, "`{s}` is not a generic type", .{name});
            return t.invalid_id;
        }
        const expected = if (sym.type_params) |tps| tps.len else 0;
        const supplied = items[2..];
        if (supplied.len != expected) {
            try self.ctx.err(pos, "generic type `{s}` expects {d} type argument{s}, got {d}", .{ name, expected, if (expected == 1) @as([]const u8, "") else "s", supplied.len });
            return t.invalid_id;
        }
        const args = try self.ctx.arena.allocator().alloc(TypeId, supplied.len);
        var any_bad = false;
        for (supplied, 0..) |a, i| {
            args[i] = try self.resolveType(a);
            if (args[i] == t.invalid_id or args[i] == t.unknown_id) any_bad = true;
        }
        if (!any_bad) {
            if (try self.builtinArgError(sym_id, args)) |msg| {
                try self.ctx.err(pos, "{s}", .{msg});
                return t.invalid_id;
            }
        }
        const ty = try self.ctx.intern(.{ .parameterized_nominal = .{ .sym = sym_id, .args = args } });
        if (!types.containsTypeVar(self.ctx, ty)) {
            const gop = try self.ctx.instantiation_sites.getOrPut(self.ctx.allocator, ty);
            if (!gop.found_existing) gop.value_ptr.* = pos;
        } else if (sym.decl_pos != types.builtin_decl_pos) {
            // Spelled inside a generic declaration: each instantiation of
            // that generic instantiates this too.
            for (self.ctx.generic_uses.items) |u| {
                if (u == ty) break;
            } else try self.ctx.generic_uses.append(self.ctx.allocator, ty);
        }
        return ty;
    }

    /// Element-type rules of the built-in generics.
    fn builtinArgError(self: *TypeResolver, sym_id: SymbolId, args: []const TypeId) Error!?[]const u8 {
        const a = self.ctx.arena.allocator();
        if (sym_id == self.ctx.cell_sym_id) {
            if (types.isCopyPrimitive(self.ctx, args[0]) or types.typeHasDropGlue(self.ctx, args[0])) return null;
            return try std.fmt.allocPrint(a, "`Cell(T)` requires `T` to be a Copy primitive (Int, Bool, Float, String) OR a type with drop glue (`*T`, `~T`, `Vec(T)`, `*sub()`, struct with resource fields or user `drop`); got `{s}`", .{try types.formatType(self.ctx, args[0])});
        }
        if (sym_id == self.ctx.vec_sym_id) {
            const ok = types.isCopyPrimitive(self.ctx, args[0]) or switch (self.ctx.types.get(args[0])) {
                .shared, .weak => true,
                // Plain data: a struct, enum, or optional that owns nothing
                // and holds no borrow is copied like a number.
                .nominal, .imported_nominal, .parameterized_nominal, .optional => types.isPlainData(self.ctx, args[0]),
                else => false,
            };
            if (ok) return null;
            return try std.fmt.allocPrint(a, "`Vec(T)` requires `T` to be a Copy type (Int, Bool, Float, String), a shared handle (`*T`), or a weak handle (`~T`); got `{s}`", .{try types.formatType(self.ctx, args[0])});
        }
        if (sym_id == self.ctx.signal_sym_id) {
            if (types.isCopyPrimitive(self.ctx, args[0])) return null;
            return try std.fmt.allocPrint(a, "`Signal(T)` requires `T` to be a Copy type (Int, Bool, Float, String); got `{s}`", .{try types.formatType(self.ctx, args[0])});
        }
        return null;
    }

    // ---- public API leaks ---------------------------------------------------

    /// A `pub` function may not mention a private nominal of this module:
    /// importers could hold such a value but never construct or inspect it.
    fn checkPublicSignature(self: *TypeResolver, fn_id: SymbolId, pos: u32, ret: TypeId, params: []const TypeId) Error!void {
        var leaks: std.ArrayListUnmanaged(SymbolId) = .empty;
        defer leaks.deinit(self.ctx.allocator);
        try self.collectLeaks(ret, &leaks);
        for (params) |p| try self.collectLeaks(p, &leaks);
        const f = self.ctx.symbols.items[fn_id];
        const is_sub = self.ctx.types.get(f.ty) == .function and self.ctx.types.get(f.ty).function.is_sub;
        try self.reportGenericLeak(pos, if (is_sub) "sub" else "function", f.name);
        for (leaks.items) |leak| {
            const ln = self.ctx.symbols.items[leak].name;
            try self.ctx.err(pos, "public {s} `{s}` leaks private type `{s}`; either mark `{s}` `pub` so importers can construct/destructure it, or remove `{s}` from the public API", .{
                if (is_sub) "sub" else "function", f.name, ln, ln, f.name,
            });
        }
    }

    fn collectLeaks(self: *TypeResolver, ty: TypeId, leaks: *std.ArrayListUnmanaged(SymbolId)) Error!void {
        if (self.ctx.types.get(ty) == .parameterized_nominal) {
            const pn = self.ctx.types.get(ty).parameterized_nominal;
            if (self.ctx.symbols.items[pn.sym].decl_pos != types.builtin_decl_pos and self.generic_leak == null) self.generic_leak = ty;
        }
        switch (self.ctx.types.get(ty)) {
            .optional, .fallible, .borrow_read, .borrow_write, .shared, .weak, .range => |inner| try self.collectLeaks(inner, leaks),
            .slice => |s| try self.collectLeaks(s.elem, leaks),
            .array => |a| try self.collectLeaks(a.elem, leaks),
            .function => |f| {
                for (f.params) |p| try self.collectLeaks(p, leaks);
                try self.collectLeaks(f.returns, leaks);
            },
            .nominal => |s| try self.addLeak(s, leaks),
            .parameterized_nominal => |pn| {
                try self.addLeak(pn.sym, leaks);
                for (pn.args) |a| try self.collectLeaks(a, leaks);
            },
            else => {},
        }
    }

    /// An instance of a generic type declared here cannot be named by an
    /// importer, so it may not appear in the public surface.
    fn reportGenericLeak(self: *TypeResolver, pos: u32, what: []const u8, name: []const u8) Error!void {
        const ty = self.generic_leak orelse return;
        self.generic_leak = null;
        try self.ctx.err(pos, "public {s} `{s}` exposes `{s}`, an instance of a generic type; generic types cannot cross module boundaries yet", .{ what, name, try types.formatType(self.ctx, ty) });
    }

    /// The fields, methods, and variant payloads of a public struct or
    /// enum are reachable from importers: none may name an instance of a
    /// generic type declared here.
    pub fn checkPublicNominals(self: *TypeResolver) Error!void {
        var leaks: std.ArrayListUnmanaged(SymbolId) = .empty;
        defer leaks.deinit(self.ctx.allocator);
        for (self.ctx.symbols.items) |sym| {
            if (!sym.flags.is_public) continue;
            switch (sym.kind) {
                .nominal_type => for (sym.fields orelse &.{}) |f| {
                    if (f.is_variant) {
                        for (f.payload orelse &.{}) |pf| try self.collectLeaks(pf.ty, &leaks);
                    } else try self.collectLeaks(f.ty, &leaks);
                    try self.reportGenericLeak(f.decl_pos, if (f.is_method) "method" else if (f.is_variant) "variant" else "field", f.name);
                },
                .type_alias, .@"extern" => {
                    try self.collectLeaks(sym.ty, &leaks);
                    try self.reportGenericLeak(sym.decl_pos, if (sym.kind == .type_alias) "type" else "extern", sym.name);
                },
                else => {},
            }
        }
    }

    fn addLeak(self: *TypeResolver, sym_id: SymbolId, leaks: *std.ArrayListUnmanaged(SymbolId)) Error!void {
        const sym = self.ctx.symbols.items[sym_id];
        if (sym.decl_pos == types.builtin_decl_pos or sym.flags.is_public) return;
        for (leaks.items) |l| if (l == sym_id) return;
        try leaks.append(self.ctx.allocator, sym_id);
    }
};

fn dropPos(node: Sexp) u32 {
    if (node.list.len >= 2 and node.list[1] == .list) {
        for (node.list[1].list) |p| {
            const pp = types.paramPos(p, 0);
            if (pp != 0) return pp;
        }
    }
    return firstSrcPos(node);
}

/// A match pattern that matches anything without binding: `else`, `_`.
pub fn isWildcardPattern(source: []const u8, pattern: Sexp) bool {
    const text = identAt(source, pattern) orelse return false;
    return std.mem.eql(u8, text, "else") or std.mem.eql(u8, text, "_");
}

pub fn primitiveTypeId(ctx: *const SemContext, name: []const u8) ?TypeId {
    const t = &ctx.types;
    const table = [_]struct { []const u8, TypeId }{
        .{ "Int", t.int_id },
        .{ "Float", t.float_id },
        .{ "Bool", t.bool_id },
        .{ "String", t.string_id },
        .{ "Void", t.void_id },
    };
    for (table) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return null;
}

/// `I8`..`I64`, `U8`..`U64`, `F32`, `F64`.
pub fn sizedTypeId(ctx: *SemContext, name: []const u8) ?Error!TypeId {
    if (name.len < 2 or name.len > 3) return null;
    const bits = std.fmt.parseInt(u8, name[1..], 10) catch return null;
    switch (name[0]) {
        'I', 'U' => {
            if (bits != 8 and bits != 16 and bits != 32 and bits != 64) return null;
            return ctx.intern(.{ .int = .{ .bits = bits, .signed = name[0] == 'I' } });
        },
        'F' => {
            if (bits != 32 and bits != 64) return null;
            return ctx.intern(.{ .float = .{ .bits = bits } });
        },
        else => return null,
    }
}
