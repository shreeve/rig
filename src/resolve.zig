//! Declarations: the built-in generic types, symbol resolution, and
//! signature sema.
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
const sema = @import("sema.zig");

const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const ScopeId = sema.ScopeId;
const TypeId = sema.TypeId;
const Type = sema.Type;
const Symbol = sema.Symbol;
const Field = sema.Field;
const MethodReceiver = sema.MethodReceiver;
const NominalContext = sema.NominalContext;
const Error = std.mem.Allocator.Error;

const identAt = sema.identAt;
const srcPos = sema.srcPos;

// =============================================================================
// Symbol resolution
// =============================================================================

pub fn resolveSymbols(ctx: *SemContext, tree: Sexp, module_scope: ScopeId) Error!void {
    var r: SymbolResolver = .{ .ctx = ctx, .scope = module_scope, .module_scope = module_scope };
    try r.walk(tree);
}

const SymbolResolver = struct {
    ctx: *SemContext,
    scope: ScopeId,
    module_scope: ScopeId,

    fn walk(self: *SymbolResolver, sexp: Sexp) Error!void {
        switch (sexp.kind() orelse return) {
            .module => for (ir.Module.decls(sexp)) |c| try self.walk(c),
            .@"pub" => {
                const before = self.ctx.symbols.items.len;
                try self.walk(ir.Pub.decl(sexp));
                if (self.ctx.symbols.items.len > before) self.ctx.symbols.items[before].flags.is_public = true;
            },
            .fun, .sub => try self.walkFun(sexp, true),
            .lambda => try self.walkLambda(sexp),
            .use => try self.walkUse(sexp),
            .type => try self.walkTypeAlias(sexp),
            .generic_type, .generic_enum => try self.walkGenericType(sexp),
            .@"struct", .@"enum" => try self.walkNominalType(sexp),
            .errors => {
                const before = self.ctx.symbols.items.len;
                try self.walkNominalType(sexp);
                if (self.ctx.symbols.items.len > before) self.ctx.symbols.items[before].flags.error_set = true;
            },
            .@"extern" => _ = try self.declare(ir.Extern.name(sexp), .@"extern", .{}),
            .extern_fun, .extern_sub => _ = try self.declare(ir.get(sexp, .name), .@"extern", .{}),
            .@"test" => try self.walkTest(sexp),
            .set => try self.walkSet(sexp),
            .block => {
                const prev = try self.enter(sexp, .block);
                defer self.scope = prev;
                for (ir.Block.stmts(sexp)) |c| try self.walk(c);
            },
            .@"for" => try self.walkFor(sexp),
            .@"if" => try self.walkConditional(ir.If.cond(sexp), &.{ir.If.then(sexp)}, ir.If.@"else"(sexp)),
            .write => {
                try self.markWritten(ir.Write.operand(sexp));
                try self.walk(ir.Write.operand(sexp));
            },
            .@"while" => try self.walkConditional(ir.While.cond(sexp), &.{ ir.While.step(sexp), ir.While.body(sexp) }, ir.While.@"else"(sexp)),
            .arm => try self.walkArm(sexp),
            .@"catch" => try self.walkCatch(sexp),
            else => for (rig.children(sexp)) |c| try self.walk(c),
        }
    }

    /// Open a scope for `node` and make it current; returns the previous scope.
    fn enter(self: *SymbolResolver, node: Sexp, kind: sema.ScopeKind) Error!ScopeId {
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
    fn declare(self: *SymbolResolver, name_node: Sexp, kind: sema.SymbolKind, flags: sema.SymbolFlags) Error!?SymbolId {
        const name = identAt(self.ctx.source, name_node) orelse return null;
        const pos = srcPos(name_node, 0);
        if (std.mem.eql(u8, name, "none")) {
            try self.ctx.err(pos, "`none` is the absent optional and cannot be used as a name", .{});
            return null;
        }
        if (self.scope == self.module_scope) {
            if (self.ctx.lookupInScopeOnly(self.scope, name)) |prev| {
                const p = self.ctx.symbols.items[prev];
                if (p.decl_pos == sema.builtin_decl_pos) {
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
            if (s == self.module_scope or s == sema.scope_invalid) return null;
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
        if (sym.kind == .local or sym.decl_pos == sema.builtin_decl_pos) return;
        try self.ctx.errAt(name_node, "{s} `{s}` has the same name as the module-level declaration `{s}`; use a different name", .{ what, name, name });
        try self.ctx.note(sym.decl_pos, "`{s}` declared here", .{name});
    }

    /// A `fun` or `sub`.
    fn walkFun(self: *SymbolResolver, node: Sexp, add_symbol: bool) Error!void {
        if (add_symbol) _ = try self.declare(ir.get(node, .name), .function, .{});
        const prev = try self.enter(node, .function);
        defer self.scope = prev;
        try self.bindParams(ir.get(node, .params), &.{});
        try self.walk(ir.get(node, .body));
    }

    fn walkTest(self: *SymbolResolver, node: Sexp) Error!void {
        const prev = try self.enter(node, .function);
        defer self.scope = prev;
        try self.walk(ir.Test.body(node));
    }

    fn walkLambda(self: *SymbolResolver, node: Sexp) Error!void {
        const prev = try self.enter(node, .lambda);
        defer self.scope = prev;
        const captures = sema.captureList(ir.Lambda.captures(node));
        // Captures first, so a parameter that reuses a capture's name is caught.
        for (captures) |cap| {
            const name_node = sema.captureNameNode(cap) orelse continue;
            const name = identAt(self.ctx.source, name_node) orelse continue;
            if (self.ctx.lookupInScopeOnly(self.scope, name)) |first| {
                try self.ctx.errAt(name_node, "duplicate capture name `{s}`", .{name});
                try self.ctx.note(self.ctx.symbols.items[first].decl_pos, "first captured here", .{});
                continue;
            }
            _ = try self.declare(name_node, .capture, .{});
        }
        try self.bindParams(ir.Lambda.params(node), captures);
        try self.walk(ir.Lambda.body(node));
    }

    /// `params`: a parameter group, or `_`.
    fn bindParams(self: *SymbolResolver, params: Sexp, captures: []const Sexp) Error!void {
        for (params.items(), 0..) |p, i| {
            const name_node = sema.paramNameNode(p) orelse continue;
            const name = identAt(self.ctx.source, name_node) orelse continue;
            const pos = srcPos(name_node, 0);
            var collides = false;
            for (captures) |cap| {
                const cn = sema.captureNameNode(cap) orelse continue;
                if (std.mem.eql(u8, identAt(self.ctx.source, cn) orelse "", name)) {
                    try self.ctx.err(pos, "closure parameter `{s}` has the name of the capture `{s}`", .{ name, name });
                    try self.ctx.noteAt(cn, "captured here", .{});
                    collides = true;
                }
            }
            if (collides) continue;
            // Any number of parameters may be ignored as `_`.
            for (params.items()[0..i]) |earlier| {
                if (std.mem.eql(u8, name, "_")) break;
                if (std.mem.eql(u8, sema.paramName(self.ctx.source, earlier) orelse "", name)) {
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
            const h = p.kind();
            const borrowed = h == .read or h == .write or
                ((h == .@":" or h == .pre_param or h == .default) and sema.isBorrowedTypeNode(ir.get(p, .type)));
            const is_pre = h == .pre_param;
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
            try self.ctx.errAt(name_node, "closure parameter `{s}` has the name of the local `{s}`; to capture the local, give it a sigil (`|+{s}|` copies or clones it, `|<{s}|` moves it, `|~{s}|` holds it weakly), or name the parameter differently", .{ name, name, name, name, name });
            try self.ctx.note(self.ctx.symbols.items[prev].decl_pos, "`{s}` declared here", .{name});
            return;
        }
        try self.checkShadowsDeclaration(name_node, "parameter");
    }

    fn walkUse(self: *SymbolResolver, node: Sexp) Error!void {
        const name_node = ir.Use.name(node);
        const id = (try self.declare(name_node, .module, .{})) orelse return;
        const name = identAt(self.ctx.source, name_node).?;
        for (self.ctx.imports) |imp| {
            if (std.mem.eql(u8, imp.local_name, name)) {
                try self.ctx.module_refs.put(self.ctx.allocator, id, imp.module_id);
                break;
            }
        }
    }

    fn walkTypeAlias(self: *SymbolResolver, node: Sexp) Error!void {
        const id = (try self.declare(ir.Type.name(node), .type_alias, .{})) orelse return;
        try self.ctx.alias_targets.put(self.ctx.allocator, id, ir.Type.type(node));
    }

    fn checkReserved(self: *SymbolResolver, name_node: Sexp) Error!bool {
        const name = identAt(self.ctx.source, name_node) orelse return true;
        if (!isReservedName(name)) return false;
        try self.ctx.errAt(name_node, "`{s}` is a reserved built-in nominal name and cannot be redefined", .{name});
        return true;
    }

    /// A `generic_type` or `generic_enum`.
    fn walkGenericType(self: *SymbolResolver, node: Sexp) Error!void {
        const name_node = ir.get(node, .name);
        if (try self.checkReserved(name_node)) return;
        const id = (try self.declare(name_node, .generic_type, .{})) orelse return;
        const name = self.ctx.symbols.items[id].name;
        const params = ir.get(node, .params);
        if (params.items().len == 0) {
            const kind = if (node.isKind(.generic_enum)) "enum" else "type";
            try self.ctx.errAt(name_node, "generic {s} `{s}` must declare at least one type parameter; for a non-generic {s}, drop the `()`", .{ kind, name, kind });
        }
        var ids: std.ArrayListUnmanaged(SymbolId) = .empty;
        defer ids.deinit(self.ctx.allocator);
        {
            for (params.items(), 0..) |p, i| {
                const pname = identAt(self.ctx.source, p) orelse continue;
                var dup = false;
                for (params.items()[0..i]) |e| {
                    if (std.mem.eql(u8, identAt(self.ctx.source, e) orelse "", pname)) dup = true;
                }
                if (dup) {
                    try self.ctx.errAt(p, "duplicate generic parameter `{s}` on `{s}`", .{ pname, name });
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
        try self.walkMembers(ir.rest(node, .members));
    }

    /// A `struct`, `enum`, or `errors`.
    fn walkNominalType(self: *SymbolResolver, node: Sexp) Error!void {
        const name_node = ir.get(node, .name);
        if (try self.checkReserved(name_node)) return;
        _ = try self.declare(name_node, .nominal_type, .{});
        try self.walkMembers(ir.rest(node, .members));
    }

    fn walkMembers(self: *SymbolResolver, members: []const Sexp) Error!void {
        for (members) |m| {
            const h = m.kind() orelse continue;
            switch (h) {
                .fun, .sub => try self.walkFun(m, false),
                .drop_decl => {
                    const prev = try self.enter(m, .function);
                    defer self.scope = prev;
                    try self.bindParams(ir.DropDecl.params(m), &.{});
                    try self.walk(ir.DropDecl.body(m));
                },
                else => {},
            }
        }
    }

    fn walkSet(self: *SymbolResolver, node: Sexp) Error!void {
        const kind = rig.bindingKindOf(ir.Set.op(node)) catch return;
        const target = ir.Set.target(node);
        try self.walk(ir.Set.value(node));
        if (target != .src) {
            try self.markWritten(target);
            try self.walk(target);
            return;
        }
        // `_ = expr` discards the value; it binds nothing.
        if (std.mem.eql(u8, identAt(self.ctx.source, target).?, "_")) return;
        switch (kind) {
            .default, .move => {
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
                        try self.ctx.errAt(target, "`{s}` is already bound; `=!` declares a new binding. Assign with `{s} = ...` or shadow with `new {s} = ...`", .{ name, name, name });
                        try self.ctx.note(self.ctx.symbols.items[prev].decl_pos, "`{s}` declared here", .{name});
                        try self.ctx.recordName(target, prev);
                        return;
                    }
                }
                try self.checkNewLocal(target);
                _ = try self.declare(target, .local, .{ .fixed = true });
            },
            .shadow => _ = try self.declare(target, .local, .{}),
            .@"+=", .@"-=", .@"*=", .@"/=", .@"%=", .@"&=", .@"|=", .@"^=", .@"<<=", .@">>=" => {
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
        while (p.kind()) |h| {
            if (h != .member and h != .index) return;
            p = ir.get(p, .object);
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
            try self.ctx.errAt(name_node, "`{s}` inside the closure shadows the local `{s}` of the enclosing function; closures reach outer values only through captures", .{ name, name });
            try self.ctx.note(self.ctx.symbols.items[prev].decl_pos, "`{s}` declared here", .{name});
        }
    }

    fn walkFor(self: *SymbolResolver, node: Sexp) Error!void {
        try self.walk(ir.For.source(node));
        {
            const prev = try self.enter(node, .block);
            defer self.scope = prev;
            _ = try self.bindFresh(ir.For.@"var"(node), "`for` binding");
            _ = try self.bindFresh(ir.For.index(node), "`for` binding");
            try self.walk(ir.For.body(node));
        }
        try self.walk(ir.For.@"else"(node));
    }

    /// An `if` / `while`. A condition `(as expr name)` opens a scope
    /// binding `name` over `bodies` (the branch or loop body the value
    /// is present in); `else_` is outside it.
    fn walkConditional(self: *SymbolResolver, cond: Sexp, bodies: []const Sexp, else_: Sexp) Error!void {
        if (cond.isKind(.as)) {
            try self.walk(ir.As.value(cond));
            const prev = try self.enter(cond, .block);
            defer self.scope = prev;
            _ = try self.bindFresh(ir.As.name(cond), "optional binding");
            for (bodies) |b| try self.walk(b);
        } else {
            try self.walk(cond);
            for (bodies) |b| try self.walk(b);
        }
        try self.walk(else_);
    }

    /// `(catch value name-or-_ handler)`.
    fn walkCatch(self: *SymbolResolver, node: Sexp) Error!void {
        try self.walk(ir.Catch.value(node));
        const name = ir.Catch.name(node);
        if (name != .nil) {
            const prev = try self.enter(node, .block);
            defer self.scope = prev;
            _ = try self.bindFresh(name, "`catch` binding");
            try self.walk(ir.Catch.handler(node));
        } else {
            try self.walk(ir.Catch.handler(node));
        }
    }

    fn walkArm(self: *SymbolResolver, node: Sexp) Error!void {
        const prev = try self.enter(node, .block);
        defer self.scope = prev;
        const pattern = ir.Arm.pattern(node);
        switch (pattern) {
            .src => if (!isWildcardPattern(self.ctx.source, pattern)) {
                _ = try self.bindFresh(pattern, "pattern binding");
            },
            .list => if (pattern.isKind(.variant_pattern)) {
                for (ir.VariantPattern.bindings(pattern)) |b| _ = try self.bindFresh(b, "pattern binding");
            },
            else => {},
        }
        try self.walk(ir.Arm.body(node));
    }
};

// =============================================================================
// Declaration types
// =============================================================================

pub fn resolveDeclarations(ctx: *SemContext, tree: Sexp, module_scope: ScopeId) Error!void {
    if (!tree.isKind(.module)) return;
    var tr: TypeResolver = .{ .ctx = ctx, .scope = module_scope };
    for (ir.Module.decls(tree)) |decl| try tr.resolveDecl(decl);
    try tr.checkPublicNominals();
}

pub const TypeResolver = struct {
    ctx: *SemContext,
    scope: ScopeId,
    nominal: NominalContext = NominalContext.none,
    /// The first generic instance `collectLeaks` saw since the last report.
    generic_leak: ?TypeId = null,

    fn resolveDecl(self: *TypeResolver, sexp: Sexp) Error!void {
        switch (sexp.kind() orelse return) {
            .@"pub" => try self.resolveDecl(ir.Pub.decl(sexp)),
            .fun, .sub => _ = try self.resolveFunction(sexp, sema.symbol_invalid),
            .type => {
                const id = self.ctx.symbolOf(ir.Type.name(sexp)) orelse return;
                _ = try self.resolveAlias(id);
            },
            .@"extern" => {
                const name = ir.Extern.name(sexp);
                const ty = try self.resolveType(ir.Extern.type(sexp));
                const id = self.ctx.symbolOf(name) orelse return;
                self.ctx.symbols.items[id].ty = ty;
                if (self.ctx.types.get(ty) == .function) try self.checkExternSignature(name, ty);
            },
            .extern_fun, .extern_sub => try self.resolveExternFun(sexp),
            .@"struct", .@"enum", .errors, .generic_type, .generic_enum => try self.resolveNominal(sexp),
            else => {},
        }
    }

    // ---- functions ----------------------------------------------------------

    /// Resolve a `fun` / `sub` (or method) signature, write parameter
    /// types into the parameter symbols, and return the function type.
    /// Top-level functions also get the type on their symbol.
    fn resolveFunction(self: *TypeResolver, node: Sexp, nominal_sym: SymbolId) Error!TypeId {
        const is_sub = node.isKind(.sub);
        const name = ir.get(node, .name);
        const params = ir.get(node, .params);
        const returns = rig.returnType(node);
        const return_ty = if (returns == .nil)
            self.ctx.types.void_id
        else
            try self.resolveReturnType(returns);

        var param_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer param_types.deinit(self.ctx.allocator);
        var pre_mask: u32 = 0;
        for (params.items(), 0..) |p, i| {
            const pty = try self.resolveParamType(p);
            try param_types.append(self.ctx.allocator, pty);
            if (p.isKind(.pre_param) and i < 32) pre_mask |= @as(u32, 1) << @intCast(i);
            if (sema.paramNameNode(p)) |pn| {
                if (self.ctx.symbolOf(pn)) |pid| self.ctx.symbols.items[pid].ty = pty;
            }
        }
        const fn_ty = try self.ctx.intern(.{ .function = .{
            .params = try self.ctx.dupeIds(param_types.items),
            .returns = return_ty,
            .is_sub = is_sub,
            .pre_mask = pre_mask,
        } });
        try self.ctx.recordType(name, fn_ty);
        if (nominal_sym == sema.symbol_invalid) {
            if (self.ctx.symbolOf(name)) |fid| {
                self.ctx.symbols.items[fid].ty = fn_ty;
                self.ctx.symbols.items[fid].param_names = try self.paramNames(params);
                self.ctx.symbols.items[fid].param_defaults = try self.paramDefaults(params);
                if (self.ctx.symbols.items[fid].flags.is_public) {
                    try self.checkPublicSignature(fid, name.src.pos, return_ty, param_types.items);
                }
            }
        }
        return fn_ty;
    }

    /// The default value of each parameter, or null when none has one.
    fn paramDefaults(self: *TypeResolver, params: Sexp) Error!?[]const ?Sexp {
        if (params == .nil) return null;
        var any = false;
        const out = try self.ctx.arena.allocator().alloc(?Sexp, params.items().len);
        for (params.items(), 0..) |p, i| {
            out[i] = if (p.isKind(.default)) ir.Default.value(p) else null;
            if (out[i] != null) any = true;
        }
        return if (any) out else null;
    }

    fn paramNames(self: *TypeResolver, params: Sexp) Error!?[]const []const u8 {
        if (params == .nil) return &.{};
        const names = try self.ctx.arena.allocator().alloc([]const u8, params.items().len);
        for (params.items(), 0..) |p, i| names[i] = sema.paramName(self.ctx.source, p) orelse return null;
        return names;
    }

    /// Only a function's return type may be fallible (`T!`); Zig error
    /// unions with inferred error sets exist only there.
    fn resolveReturnType(self: *TypeResolver, node: Sexp) Error!TypeId {
        if (node.isKind(.error_union)) {
            const inner = try self.resolveType(ir.ErrorUnion.type(node));
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
            .list => {
                const h = param.kind() orelse return self.ctx.types.invalid_id;
                switch (h) {
                    .@":", .pre_param, .default => return self.resolveType(ir.get(param, .type)),
                    .read, .write => {
                        const operand = ir.get(param, .operand);
                        const name = identAt(self.ctx.source, operand) orelse return self.ctx.types.invalid_id;
                        const pos = srcPos(operand, 0);
                        if (!std.mem.eql(u8, name, "self")) {
                            try self.ctx.err(pos, "sigil-prefixed parameter is only allowed for `self`; for other parameters use `{s}: ?Type` / `{s}: !Type`", .{ name, name });
                            return self.ctx.types.invalid_id;
                        }
                        if (self.nominal.isEmpty()) {
                            try self.ctx.err(pos, "`{s}self` is only allowed in a method body (inside a struct, enum, or errors declaration)", .{if (h == .read) "?" else "!"});
                            return self.ctx.types.invalid_id;
                        }
                        return self.ctx.intern(if (h == .read)
                            Type{ .borrow_read = self.nominal.self_type }
                        else
                            Type{ .borrow_write = self.nominal.self_type });
                    },
                    else => {},
                }
                try self.ctx.errAt(param, "unsupported parameter form", .{});
                return self.ctx.types.invalid_id;
            },
            else => return self.ctx.types.invalid_id,
        }
    }

    /// An `extern_fun` or `extern_sub`.
    fn resolveExternFun(self: *TypeResolver, node: Sexp) Error!void {
        const is_sub = node.isKind(.extern_sub);
        const name = ir.get(node, .name);
        const params = ir.get(node, .params);
        const returns: Sexp = if (is_sub) .nil else ir.ExternFun.returns(node);
        const return_ty = if (returns == .nil) self.ctx.types.void_id else try self.resolveReturnType(returns);
        var ps: std.ArrayListUnmanaged(TypeId) = .empty;
        defer ps.deinit(self.ctx.allocator);
        for (params.items()) |p| {
            if (p.isKind(.default)) try self.ctx.err(sema.paramPos(p, self.ctx.startOf(p)), "an `extern` parameter cannot have a default value", .{});
            try ps.append(self.ctx.allocator, try self.resolveParamType(p));
        }
        const fn_ty = try self.ctx.intern(.{ .function = .{
            .params = try self.ctx.dupeIds(ps.items),
            .returns = return_ty,
            .is_sub = is_sub,
        } });
        const id = self.ctx.symbolOf(name) orelse return;
        self.ctx.symbols.items[id].ty = fn_ty;
        self.ctx.symbols.items[id].param_names = try self.paramNames(params);
        try self.checkExternSignature(name, fn_ty);
    }

    /// C functions take and return only integers, floats, and Bool.
    fn checkExternSignature(self: *TypeResolver, name_node: Sexp, fn_ty_id: TypeId) Error!void {
        const f = self.ctx.types.get(fn_ty_id).function;
        const name = identAt(self.ctx.source, name_node) orelse "extern";
        const pos = srcPos(name_node, 0);
        if (self.ctx.types.get(f.returns) == .fallible) {
            try self.ctx.err(pos, "an `extern` function cannot return a fallible type `{s}`; C functions report failure through their return value", .{try sema.formatType(self.ctx, f.returns)});
        } else if (f.returns != self.ctx.types.void_id and !self.isCAbiType(f.returns)) {
            try self.ctx.err(pos, "`extern` function `{s}` cannot return `{s}`; only integers, floats, and Bool cross the C boundary", .{ name, try sema.formatType(self.ctx, f.returns) });
        }
        for (f.params) |p| {
            if (!self.isCAbiType(p)) {
                try self.ctx.err(pos, "`extern` function `{s}` cannot take `{s}`; only integers, floats, and Bool cross the C boundary", .{ name, try sema.formatType(self.ctx, p) });
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

    /// A `struct`, `enum`, `errors`, `generic_type`, or `generic_enum`.
    fn resolveNominal(self: *TypeResolver, node: Sexp) Error!void {
        const sym_id = self.ctx.symbolOf(ir.get(node, .name)) orelse return;
        const head = node.kind().?;
        const generic = head == .generic_type or head == .generic_enum;
        const is_enum = head == .@"enum" or head == .errors or head == .generic_enum;
        const members = ir.rest(node, .members);

        const prev = self.nominal;
        self.nominal = try sema.makeNominalContext(self.ctx, sym_id);
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
                .list => {
                    const h = m.kind() orelse continue;
                    switch (h) {
                        .@":", .default => {
                            const name_node = ir.get(m, .name);
                            const fname = identAt(self.ctx.source, name_node) orelse continue;
                            const fpos = srcPos(name_node, 0);
                            if (h == .default) {
                                try self.ctx.err(fpos, "field default values are not supported yet; pass `{s}` in every constructor", .{fname});
                            }
                            if (is_enum) {
                                try self.ctx.err(fpos, "an enum declares variants, not typed fields; write `{s}` or `{s}(field: T)`", .{ fname, fname });
                                continue;
                            }
                            if (try self.checkDuplicateMember(fields.items, fname, fpos, sym_name)) continue;
                            const fty = try self.resolveType(ir.get(m, .type));
                            try fields.append(self.ctx.allocator, .{ .name = fname, .ty = fty, .decl_pos = fpos });
                        },
                        .valued => {
                            const name_node = ir.Valued.name(m);
                            const vname = identAt(self.ctx.source, name_node).?;
                            const vpos = name_node.src.pos;
                            if (!is_enum) {
                                try self.ctx.err(vpos, "field `{s}` needs a type (`{s}: T = value`)", .{ vname, vname });
                                continue;
                            }
                            if (head == .errors) {
                                try self.ctx.err(vpos, "error set members have no values; write `{s}`", .{vname});
                            }
                            if (try self.checkDuplicateMember(fields.items, vname, vpos, sym_name)) continue;
                            try fields.append(self.ctx.allocator, .{ .name = vname, .ty = self.ctx.types.void_id, .decl_pos = vpos, .is_variant = true });
                        },
                        .variant => {
                            if (!is_enum or head == .errors) {
                                try self.ctx.errAt(m, "only enums declare payload variants", .{});
                                continue;
                            }
                            try self.resolveVariant(m, &fields, sym_name);
                        },
                        .fun, .sub => {
                            if (head == .errors) {
                                try self.ctx.errAt(ir.get(m, .name), "an error set cannot declare methods; write a function that takes the error", .{});
                                continue;
                            }
                            try self.resolveMethod(m, sym_id, &fields);
                        },
                        .read, .write => {
                            const n = identAt(self.ctx.source, ir.get(m, .operand)) orelse "name";
                            try self.ctx.err(sema.paramPos(m, 0), "sigil-prefixed member (`?{s}` / `!{s}`) is not allowed in a nominal body; sigil-prefix sugar is only valid for the `self` parameter of a method", .{ n, n });
                        },
                        .drop_decl => {
                            if (head == .@"struct") {
                                try self.resolveDropDecl(m, sym_id, &fields);
                            } else {
                                const where: []const u8 = switch (head) {
                                    .errors => "error sets",
                                    .generic_type, .generic_enum => "generic types",
                                    else => "enums",
                                };
                                try self.ctx.errAt(m, "`drop` declarations on {s} are deferred (only plain structs can declare `drop`); {s}", .{
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
            // `sema.propagateDropGlue` finishes this once every type is resolved.
            self.ctx.symbols.items[sym_id].flags.has_drop_glue = sema.fieldsHaveDropGlue(self.ctx, owned);
            for (members) |m| {
                if (m.isKind(.drop_decl)) {
                    try self.enforceDropBody(ir.DropDecl.body(m), owned);
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

    fn resolveVariant(self: *TypeResolver, variant: Sexp, fields: *std.ArrayListUnmanaged(Field), owner: []const u8) Error!void {
        const name_node = ir.Variant.name(variant);
        const vname = identAt(self.ctx.source, name_node).?;
        const vpos = name_node.src.pos;
        if (try self.checkDuplicateMember(fields.items, vname, vpos, owner)) return;
        var payload: std.ArrayListUnmanaged(Field) = .empty;
        defer payload.deinit(self.ctx.allocator);
        {
            for (ir.Variant.params(variant).items()) |p| {
                if (!p.isKind(.@":")) {
                    try self.ctx.errAt(p, "variant payload fields need types (`name: T`)", .{});
                    continue;
                }
                const field_name = ir.get(p, .name);
                const fname = identAt(self.ctx.source, field_name) orelse continue;
                try payload.append(self.ctx.allocator, .{
                    .name = fname,
                    .ty = try self.resolveType(ir.get(p, .type)),
                    .decl_pos = srcPos(field_name, 0),
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
        const name = ir.get(node, .name);
        const mname = identAt(self.ctx.source, name).?;
        const mpos = name.src.pos;
        const owner = self.ctx.symbols.items[nominal_sym].name;
        if (try self.checkDuplicateMember(fields.items, mname, mpos, owner)) return;
        const fn_ty = try self.resolveFunction(node, nominal_sym);
        const params = ir.get(node, .params);
        var receiver: MethodReceiver = .none;
        if (params.items().len > 0) {
            for (params.items(), 0..) |p, i| {
                if (i == 0) continue;
                const is_self = std.mem.eql(u8, sema.paramName(self.ctx.source, p) orelse "", "self");
                const h = p.kind();
                if (is_self) {
                    try self.ctx.err(sema.paramPos(p, mpos), "`self` must be the first parameter of a method", .{});
                }
                if (h == .read or h == .write) {
                    try self.ctx.err(sema.paramPos(p, mpos), "sigil-prefixed parameter sugar (`?self` / `!self`) is only allowed at the first parameter position", .{});
                }
            }
            const first = params.items()[0];
            if (std.mem.eql(u8, sema.paramName(self.ctx.source, first) orelse "", "self")) {
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
        const pos = self.ctx.startOf(node);
        for (fields.items) |f| {
            if (f.is_drop_method) {
                try self.ctx.err(pos, "duplicate `drop` declaration on this struct; a struct has at most one `drop`", .{});
                return;
            }
        }
        const params = ir.DropDecl.params(node);
        const count: usize = params.items().len;
        var ptys: [1]TypeId = undefined;
        for (params.items(), 0..) |p, i| {
            const pty = try self.resolveParamType(p);
            if (i == 0) ptys[0] = pty;
            if (sema.paramNameNode(p)) |pn| {
                if (self.ctx.symbolOf(pn)) |pid| self.ctx.symbols.items[pid].ty = pty;
            }
        }
        if (count != 1) {
            try self.ctx.err(pos, "`drop` declaration must take exactly one parameter `self: !Self`; got {d} parameter(s)", .{count});
            return;
        }
        const first = params.items()[0];
        if (!std.mem.eql(u8, sema.paramName(self.ctx.source, first) orelse "", "self")) {
            try self.ctx.err(sema.paramPos(first, pos), "`drop` declaration's parameter must be named `self`", .{});
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
            try self.ctx.err(sema.paramPos(first, pos), "`drop` declaration must use `self: !Self` (write-borrow); other receiver shapes are rejected", .{});
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
        const head = body.kind() orelse return;
        switch (head) {
            .drop => if (self.isSelf(ir.Drop.name(body))) {
                try self.ctx.errAt(ir.Drop.name(body), "cannot drop `self` inside its own drop body; the binding is being destroyed by the runtime", .{});
            },
            .move => {
                const operand = ir.Move.operand(body);
                if (self.isSelf(operand)) {
                    try self.ctx.errAt(operand, "cannot move `self` out of its own drop body; the binding is being destroyed by the runtime", .{});
                } else try self.checkDropBodyField(operand, fields, "move");
            },
            .@"return" => if (self.isSelf(ir.Return.value(body))) {
                try self.ctx.errAt(ir.Return.value(body), "cannot return `self` from its own drop body", .{});
            },
            .set => {
                const target = ir.Set.target(body);
                if (self.isSelf(target)) {
                    try self.ctx.errAt(target, "cannot reassign `self` inside its own drop body; dropping the old value would run this body again", .{});
                } else try self.checkDropBodyField(target, fields, "reassign");
            },
            else => {},
        }
        for (rig.children(body)) |c| try self.enforceDropBody(c, fields);
    }

    fn isSelf(self: *TypeResolver, node: Sexp) bool {
        return std.mem.eql(u8, identAt(self.ctx.source, node) orelse "", "self");
    }

    fn checkDropBodyField(self: *TypeResolver, member: Sexp, fields: []const Field, op: []const u8) Error!void {
        if (!member.isKind(.member)) return;
        if (!self.isSelf(ir.Member.object(member))) return;
        const name = ir.Member.name(member);
        const fname = identAt(self.ctx.source, name).?;
        for (fields) |f| {
            if (f.is_method or f.is_variant or !std.mem.eql(u8, f.name, fname)) continue;
            if (sema.typeHasDropGlue(self.ctx, f.ty)) {
                try self.ctx.errAt(name, "cannot {s} resource field `self.{s}` inside drop body; fields are dropped automatically after the user drop body returns, so a manual {s} would race the auto-generated drop and double-free", .{ op, fname, op });
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
            .list => {
                const head = sexp.kind() orelse return t.invalid_id;
                switch (head) {
                    .optional => {
                        const inner = try self.resolveType(ir.Optional.type(sexp));
                        if (inner == t.invalid_id) return t.invalid_id;
                        return self.ctx.intern(.{ .optional = inner });
                    },
                    .error_union => {
                        const inner = try self.resolveType(ir.ErrorUnion.type(sexp));
                        const ty = try self.ctx.intern(.{ .fallible = inner });
                        try self.ctx.errAt(sexp, "a fallible type `{s}` is only allowed as a function's return type (a fallible handle is `(*T)!`)", .{try sema.formatType(self.ctx, ty)});
                        return t.invalid_id;
                    },
                    .borrow_read, .borrow_write, .slice => {
                        const inner = try self.resolveType(ir.get(sexp, .type));
                        if (inner == t.invalid_id) return t.invalid_id;
                        return switch (head) {
                            .borrow_read => self.ctx.intern(.{ .borrow_read = inner }),
                            .borrow_write => self.ctx.intern(.{ .borrow_write = inner }),
                            else => self.ctx.intern(.{ .slice = .{ .elem = inner } }),
                        };
                    },
                    .weak => {
                        const inner = try self.resolveType(ir.Weak.operand(sexp));
                        if (inner == t.invalid_id) return t.invalid_id;
                        return self.ctx.intern(.{ .weak = inner });
                    },
                    .shared => {
                        const inner_node = ir.Shared.type(sexp);
                        const inner = try self.resolveType(inner_node);
                        if (inner == t.invalid_id) return t.invalid_id;
                        if (self.ctx.types.get(inner) == .shared) {
                            try self.ctx.errAt(inner_node, "nested shared type `**T` is not meaningful; use a single `*T`", .{});
                            return t.invalid_id;
                        }
                        if (self.ctx.types.get(inner) == .function) try self.checkOwnedClosureType(inner_node, inner);
                        return self.ctx.intern(.{ .shared = inner });
                    },
                    .array_type => {
                        const size = ir.ArrayType.size(sexp);
                        const len = sema.parseIntegerLiteral(self.ctx.source, size) orelse {
                            try self.ctx.errAt(size, "array length must be an integer literal", .{});
                            return t.invalid_id;
                        };
                        const elem_node = ir.ArrayType.type(sexp);
                        const elem = try self.resolveType(elem_node);
                        if (sema.typeHasDropGlue(self.ctx, elem)) {
                            try self.ctx.errAt(elem_node, "arrays cannot hold values that own resources (`{s}`); use a `Vec`", .{try sema.formatType(self.ctx, elem)});
                            return t.invalid_id;
                        }
                        return self.ctx.intern(.{ .array = .{ .elem = elem, .len = len } });
                    },
                    .fun_type => {
                        var ps: std.ArrayListUnmanaged(TypeId) = .empty;
                        defer ps.deinit(self.ctx.allocator);
                        for (ir.FunType.params(sexp).items()) |p| try ps.append(self.ctx.allocator, try self.resolveType(p));
                        const ret = try self.resolveReturnType(ir.FunType.returns(sexp));
                        return self.ctx.intern(.{ .function = .{
                            .params = try self.ctx.dupeIds(ps.items),
                            .returns = ret,
                            .is_sub = ret == t.void_id,
                        } });
                    },
                    .generic_inst => return self.resolveGenericInst(sexp),
                    .member => return self.resolveQualified(ir.Member.object(sexp), ir.Member.name(sexp)),
                    else => {
                        try self.ctx.errAt(sexp, "unsupported type expression", .{});
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
            try self.ctx.errAt(module_node, "use of unbound module `{s}`; import it with `use {s}`", .{ module_name, module_name });
            return t.invalid_id;
        };
        if (self.ctx.symbols.items[mod_id].kind != .module) {
            try self.ctx.errAt(module_node, "`{s}` is not a module; a qualified type is written `module.Type`", .{module_name});
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
        if (fsym.kind == .type_alias) return sema.importType(self.ctx, foreign, fsym.ty, origin);
        return self.ctx.intern(.{ .imported_nominal = .{ .module_id = origin, .sym_id = fid } });
    }

    /// `*fun(...) R` / `*sub(...)`: an owned closure passes plain Copy
    /// values through its type-erased form.
    fn checkOwnedClosureType(self: *TypeResolver, fun_type: Sexp, ty: TypeId) Error!void {
        const f = self.ctx.types.get(ty).function;
        const is_fun_type = fun_type.isKind(.fun_type);
        const nodes: []const Sexp = if (is_fun_type) ir.FunType.params(fun_type).items() else &.{};
        for (f.params, 0..) |p, i| {
            if (sema.isClosureValue(self.ctx, p)) continue;
            const pos = if (i < nodes.len) self.ctx.startOf(nodes[i]) else self.ctx.startOf(fun_type);
            try self.ctx.err(pos, "an owned closure takes plain Copy values (Int, Float, Bool, String, sized numbers, plain enums, or optionals of these); `{s}` is not one", .{try sema.formatType(self.ctx, p)});
        }
        if (!f.is_sub and !sema.isClosureValue(self.ctx, f.returns)) {
            const pos = if (is_fun_type and ir.FunType.returns(fun_type) != .nil) self.ctx.startOf(ir.FunType.returns(fun_type)) else self.ctx.startOf(fun_type);
            try self.ctx.err(pos, "an owned closure returns plain Copy values (Int, Float, Bool, String, sized numbers, plain enums, or optionals of these); `{s}` is not one", .{try sema.formatType(self.ctx, f.returns)});
        }
    }

    fn resolveGenericInst(self: *TypeResolver, sexp: Sexp) Error!TypeId {
        const t = &self.ctx.types;
        const name_node = ir.GenericInst.name(sexp);
        const name = identAt(self.ctx.source, name_node).?;
        const pos = name_node.src.pos;
        const sym_id = self.ctx.lookup(self.scope, name) orelse {
            try self.ctx.err(pos, "use of unbound type `{s}`", .{name});
            return t.invalid_id;
        };
        try self.ctx.recordName(name_node, sym_id);
        const sym = self.ctx.symbols.items[sym_id];
        if (sym.kind != .generic_type) {
            try self.ctx.err(pos, "`{s}` is not a generic type", .{name});
            return t.invalid_id;
        }
        const expected = if (sym.type_params) |tps| tps.len else 0;
        const supplied = ir.GenericInst.args(sexp);
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
        if (!sema.containsTypeVar(self.ctx, ty)) {
            const gop = try self.ctx.instantiation_sites.getOrPut(self.ctx.allocator, ty);
            if (!gop.found_existing) gop.value_ptr.* = pos;
        } else if (sym.decl_pos != sema.builtin_decl_pos) {
            // Spelled inside a generic declaration: each instantiation of
            // that generic instantiates this too.
            for (self.ctx.generic_uses.items) |u| {
                if (u == ty) break;
            } else try self.ctx.generic_uses.append(self.ctx.allocator, ty);
        }
        return ty;
    }

    /// Element-type rules of the built-in generics.
    pub fn builtinArgError(self: *TypeResolver, sym_id: SymbolId, args: []const TypeId) Error!?[]const u8 {
        const a = self.ctx.arena.allocator();
        if (sym_id == self.ctx.cell_sym_id) {
            if (sema.isCopyPrimitive(self.ctx, args[0]) or sema.typeHasDropGlue(self.ctx, args[0])) return null;
            return try std.fmt.allocPrint(a, "`Cell(T)` requires `T` to be a Copy primitive (Int, Bool, Float, String) OR a type with drop glue (`*T`, `~T`, `Vec(T)`, `*sub()`, struct with resource fields or user `drop`); got `{s}`", .{try sema.formatType(self.ctx, args[0])});
        }
        if (sym_id == self.ctx.vec_sym_id) {
            const ok = sema.isCopyPrimitive(self.ctx, args[0]) or switch (self.ctx.types.get(args[0])) {
                .shared, .weak => true,
                // Plain data: a struct, enum, or optional that owns nothing
                // and holds no borrow is copied like a number.
                .nominal, .imported_nominal, .parameterized_nominal, .optional => sema.isPlainData(self.ctx, args[0]),
                else => false,
            };
            if (ok) return null;
            return try std.fmt.allocPrint(a, "`Vec(T)` requires `T` to be a Copy type (Int, Bool, Float, String), a shared handle (`*T`), or a weak handle (`~T`); got `{s}`", .{try sema.formatType(self.ctx, args[0])});
        }
        if (sym_id == self.ctx.signal_sym_id) {
            if (sema.isCopyPrimitive(self.ctx, args[0])) return null;
            return try std.fmt.allocPrint(a, "`Signal(T)` requires `T` to be a Copy type (Int, Bool, Float, String); got `{s}`", .{try sema.formatType(self.ctx, args[0])});
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
            if (self.ctx.symbols.items[pn.sym].decl_pos != sema.builtin_decl_pos and self.generic_leak == null) self.generic_leak = ty;
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
        try self.ctx.err(pos, "public {s} `{s}` exposes `{s}`, an instance of a generic type; generic types cannot cross module boundaries yet", .{ what, name, try sema.formatType(self.ctx, ty) });
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
        if (sym.decl_pos == sema.builtin_decl_pos or sym.flags.is_public) return;
        for (leaks.items) |l| if (l == sym_id) return;
        try leaks.append(self.ctx.allocator, sym_id);
    }
};

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

/// `I8`..`I64`, `U8`..`U64`, `F32`, `F64`. `I64` is `Int` and `F64` is
/// `Float`: the same types under their sized names.
pub fn sizedTypeId(ctx: *SemContext, name: []const u8) ?Error!TypeId {
    if (name.len < 2 or name.len > 3) return null;
    const bits = std.fmt.parseInt(u8, name[1..], 10) catch return null;
    switch (name[0]) {
        'I', 'U' => {
            if (bits != 8 and bits != 16 and bits != 32 and bits != 64) return null;
            if (bits == 64 and name[0] == 'I') return ctx.types.int_id;
            return ctx.intern(.{ .int = .{ .bits = bits, .signed = name[0] == 'I' } });
        },
        'F' => {
            if (bits != 32 and bits != 64) return null;
            if (bits == 64) return ctx.types.float_id;
            return ctx.intern(.{ .float = .{ .bits = bits } });
        },
        else => return null,
    }
}

/// Whether `name` spells a numeric type: `Int`, `Float`, or a sized one.
/// Called like a function, such a name converts a number to that type.
pub fn isNumericTypeName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "Int") or std.mem.eql(u8, name, "Float")) return true;
    if (name.len < 2 or name.len > 3) return false;
    const bits = std.fmt.parseInt(u8, name[1..], 10) catch return false;
    return switch (name[0]) {
        'I', 'U' => bits == 8 or bits == 16 or bits == 32 or bits == 64,
        'F' => bits == 32 or bits == 64,
        else => false,
    };
}

// =============================================================================
// Built-in generic types
//
// `Cell(T)`, `Vec(T)`, and `Signal(T)`, registered in every module scope
// before user declarations. Their methods are ordinary method Fields on
// generic symbols, so calls go through the same lookup and substitution as
// user generics; the runtime (`runtime.zig`) implements them.
// =============================================================================

const builtin_pos = sema.builtin_decl_pos;

/// Names users cannot redeclare: emit recognizes these by name.
pub fn isReservedName(name: []const u8) bool {
    const reserved = [_][]const u8{ "Cell", "Vec", "Signal" };
    for (reserved) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    return false;
}

pub fn registerBuiltins(ctx: *SemContext, module_scope: ScopeId) Error!void {
    // Cell(T): interior-mutable slot. Methods take `?self`; the runtime
    // mutates through its own pointer.
    {
        const g = try addGeneric(ctx, module_scope, "Cell", &.{"T"});
        ctx.cell_sym_id = g.sym;
        const t = g.params[0];
        const self_ty = try ctx.intern(.{ .borrow_read = g.self_ty });
        try setFields(ctx, g.sym, &.{
            .{ .name = "value", .ty = t, .decl_pos = builtin_pos },
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
            .{ .name = "value", .ty = t, .decl_pos = builtin_pos },
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
        .decl_pos = builtin_pos,
        .scope = module_scope,
    });
    try ctx.addToScope(module_scope, sym);

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
            .decl_pos = builtin_pos,
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
    return .{ .name = name, .ty = ty, .decl_pos = builtin_pos, .is_method = true, .receiver = receiver };
}

fn setFields(ctx: *SemContext, sym: SymbolId, fields: []const Field) Error!void {
    ctx.symbols.items[sym].fields = try ctx.arena.allocator().dupe(Field, fields);
}

test "builtins: registered with methods" {
    var ctx = try SemContext.init(std.testing.allocator, "");
    defer ctx.deinit();
    const scope = try ctx.pushScopeKind(sema.scope_invalid, .module);
    try registerBuiltins(&ctx, scope);
    const vec = ctx.lookup(scope, "Vec").?;
    try std.testing.expectEqual(ctx.vec_sym_id, vec);
    try std.testing.expectEqual(@as(usize, 5), ctx.symbols.items[vec].fields.?.len);
    try std.testing.expect(ctx.lookup(scope, "T") == null);
}
