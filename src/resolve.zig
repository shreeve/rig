//! Declarations: the built-in generic types, symbol resolution, and
//! declared types.
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
//!
//! Some rules on declared types depend on what other types hold (an
//! array cannot hold a resource), which is known only once every
//! declaration is resolved (`sema.computeContents`). Types spelled in
//! declarations queue those checks, and `checkDeclarations` runs them.

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
    /// The generic parameters of the generic type whose members are
    /// being walked.
    type_params: []const SymbolId = &.{},

    fn walk(self: *SymbolResolver, sexp: Sexp) Error!void {
        switch (sexp.kind() orelse return) {
            .module => {
                for (ir.Module.decls(sexp)) |c| if (rig.isModuleConst(c)) try self.walk(c);
                for (ir.Module.decls(sexp)) |c| if (!rig.isModuleConst(c)) try self.walk(c);
            },
            .@"pub" => {
                const before = self.ctx.symbols.items.len;
                try self.walk(ir.Pub.decl(sexp));
                if (self.ctx.symbols.items.len > before) self.ctx.symbols.items[before].flags.is_public = true;
            },
            .fun, .sub => {
                _ = try self.declare(ir.get(sexp, .name), .function, .{});
                try self.walkFun(sexp);
            },
            .lambda => try self.walkLambda(sexp),
            .use => try self.walkUse(sexp),
            .type => try self.walkTypeAlias(sexp),
            .generic_type, .generic_enum => try self.walkGenericType(sexp),
            .@"struct", .@"enum" => try self.walkNominalType(sexp, .{}),
            .errors => try self.walkNominalType(sexp, .{ .error_set = true }),
            .@"extern", .extern_fun, .extern_sub => _ = try self.declare(ir.get(sexp, .name), .@"extern", .{}),
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

    /// Declare a named symbol in the current scope and record the name
    /// fact. Module-level declarations must have unique names.
    fn declare(self: *SymbolResolver, name_node: Sexp, kind: sema.SymbolKind, flags: sema.SymbolFlags) Error!?SymbolId {
        const name = identAt(self.ctx.source, name_node) orelse return null;
        const pos = srcPos(name_node, 0);
        if (std.mem.eql(u8, name, "none")) {
            try self.ctx.err(pos, "`none` is the absent optional and cannot be used as a name", .{});
            return null;
        }
        // The lexer lets a keyword through only where it may name a
        // member, which includes a parameter list's `name:`.
        if (rig.keyword(name)) |kw| if (kw != .new) {
            try self.ctx.err(pos, "`{s}` is a keyword and cannot name a {s}", .{ name, if (kind == .param) "parameter" else "binding" });
            return null;
        };
        const sym: Symbol = .{
            .name = name,
            .kind = kind,
            .ty = self.ctx.types.unknown_id,
            .decl_pos = pos,
            .scope = self.scope,
            .flags = flags,
        };
        const dup = if (self.scope == self.module_scope) self.ctx.lookupInScopeOnly(self.scope, name) else null;
        if (dup) |prev| {
            const p = self.ctx.symbols.items[prev];
            if (p.decl_pos == sema.builtin_decl_pos) {
                try self.ctx.err(pos, "`{s}` is a reserved built-in nominal name and cannot be redefined", .{name});
            } else {
                try self.ctx.err(pos, "duplicate declaration of `{s}`", .{name});
                try self.ctx.note(p.decl_pos, "`{s}` first declared here", .{name});
            }
        }
        const id = try self.ctx.addSymbol(sym);
        // A duplicate is still resolved and checked, under a symbol no
        // name reaches, so errors inside it are reported too.
        if (dup == null) try self.ctx.addToScope(self.scope, id);
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
        if (self.visibleLocal(self.scope, name)) |prev| {
            try self.ctx.err(pos, "{s} `{s}` shadows the local `{s}`; use a different name", .{ what, name, name });
            try self.ctx.note(self.ctx.symbols.items[prev].decl_pos, "`{s}` declared here", .{name});
            return;
        }
        if (self.scope != self.module_scope) try self.checkShadowsDeclaration(name_node, what);
    }

    /// A local of the function `from` is in (through blocks and lambdas),
    /// excluding module-level names.
    fn visibleLocal(self: *SymbolResolver, from: ScopeId, name: []const u8) ?SymbolId {
        var sid: ?ScopeId = from;
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
    /// function, type, constant, extern, or module, or of a generic parameter of the
    /// enclosing generic type: Zig rejects the shadowing.
    fn checkShadowsDeclaration(self: *SymbolResolver, name_node: Sexp, what: []const u8) Error!void {
        const name = identAt(self.ctx.source, name_node) orelse return;
        for (self.type_params) |tp| {
            if (!std.mem.eql(u8, self.ctx.symbols.items[tp].name, name)) continue;
            try self.ctx.errAt(name_node, "{s} `{s}` has the name of the generic parameter `{s}`; use a different name", .{ what, name, name });
            return;
        }
        const decl = self.ctx.lookupInScopeOnly(self.module_scope, name) orelse return;
        const sym = self.ctx.symbols.items[decl];
        if (sym.decl_pos == sema.builtin_decl_pos) return;
        try self.ctx.errAt(name_node, "{s} `{s}` has the same name as the module-level declaration `{s}`; use a different name", .{ what, name, name });
        try self.ctx.note(sym.decl_pos, "`{s}` declared here", .{name});
    }

    /// The parameters and body of a `fun`, `sub`, or `drop`.
    fn walkFun(self: *SymbolResolver, node: Sexp) Error!void {
        const prev = try self.enter(node, .function);
        defer self.scope = prev;
        const tparams = sema.tparamsOf(node);
        try self.bindParams(tparams, .compile_time, .nil, &.{});
        try self.bindParams(ir.get(node, .params), .run_time, tparams, &.{});
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
        try self.bindParams(ir.Lambda.params(node), .run_time, .nil, captures);
        try self.walk(ir.Lambda.body(node));
    }

    /// `params`: a parameter group, or `_`. `earlier`: the group bound
    /// before it (a function's compile-time parameters, before its
    /// run-time ones), whose names it may not reuse, or `_`.
    fn bindParams(self: *SymbolResolver, params: Sexp, when: enum { compile_time, run_time }, earlier: Sexp, captures: []const Sexp) Error!void {
        const ct = when == .compile_time;
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
            for ([_][]const Sexp{ earlier.items(), params.items()[0..i] }) |before| for (before) |e| {
                if (std.mem.eql(u8, name, "_")) break;
                if (std.mem.eql(u8, sema.paramName(self.ctx.source, e) orelse "", name)) {
                    try self.ctx.err(pos, "duplicate parameter `{s}`", .{name});
                    collides = true;
                    break;
                }
            };
            if (collides) continue;
            if (self.ctx.scopes.items[self.scope].kind == .lambda) {
                try self.checkShadowingThroughLambda(name_node);
            } else {
                try self.checkShadowsDeclaration(name_node, "parameter");
            }
            // A bare name among compile-time parameters is a type
            // parameter.
            if (ct and p == .src) {
                _ = try self.declare(name_node, .generic_param, .{});
                continue;
            }
            const h = p.kind();
            const borrowed = h == .read or h == .write or
                ((h == .@":" or h == .default) and
                    (ir.get(p, .type).isKind(.borrow_read) or ir.get(p, .type).isKind(.borrow_write)));
            _ = try self.declare(name_node, .param, .{
                .borrowed_param = borrowed,
                .comptime_known = ct,
            });
        }
    }

    /// A lambda's parameters live in the closure's own function, which
    /// Zig nests inside the enclosing one: they may not reuse its locals.
    fn checkShadowingThroughLambda(self: *SymbolResolver, name_node: Sexp) Error!void {
        const name = identAt(self.ctx.source, name_node) orelse return;
        const parent = self.ctx.scopes.items[self.scope].parent orelse return;
        if (self.visibleLocal(parent, name)) |prev| {
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

    /// A `generic_type` or `generic_enum`.
    fn walkGenericType(self: *SymbolResolver, node: Sexp) Error!void {
        const name_node = ir.get(node, .name);
        const id = (try self.declare(name_node, .generic_type, .{})) orelse return;
        const name = self.ctx.symbols.items[id].name;
        const params = ir.get(node, .tparams);
        if (params.items().len == 0) {
            try self.ctx.errAt(name_node, "generic type `{s}` must declare at least one type parameter (`type {s}[T]`); a type without them is a `struct`", .{ name, name });
        }
        var ids: std.ArrayListUnmanaged(SymbolId) = .empty;
        defer ids.deinit(self.ctx.allocator);
        for (params.items(), 0..) |p, i| {
            if (p.isKind(.@":")) {
                try self.ctx.errAt(p, "a generic type's parameters are types; a compile-time value parameter (`{s}: T`) is not supported on a type", .{sema.paramName(self.ctx.source, p) orelse "n"});
                continue;
            }
            const pname = identAt(self.ctx.source, p) orelse continue;
            const dup = for (params.items()[0..i]) |e| {
                if (std.mem.eql(u8, identAt(self.ctx.source, e) orelse "", pname)) break true;
            } else false;
            if (dup) {
                try self.ctx.errAt(p, "duplicate generic parameter `{s}` on `{s}`", .{ pname, name });
                continue;
            }
            // Detached: reached through the type's `type_params`.
            const pid = try self.ctx.addSymbol(.{
                .name = pname,
                .kind = .generic_param,
                .ty = self.ctx.types.unknown_id,
                .decl_pos = srcPos(p, 0),
                .scope = self.scope,
            });
            try self.ctx.recordName(p, pid);
            try ids.append(self.ctx.allocator, pid);
        }
        self.ctx.symbols.items[id].type_params = try self.ctx.arena.allocator().dupe(SymbolId, ids.items);
        self.type_params = self.ctx.symbols.items[id].type_params.?;
        defer self.type_params = &.{};
        try self.walkMembers(ir.rest(node, .members));
    }

    /// A `struct`, `enum`, or `errors`.
    fn walkNominalType(self: *SymbolResolver, node: Sexp, flags: sema.SymbolFlags) Error!void {
        _ = try self.declare(ir.get(node, .name), .nominal_type, flags);
        try self.walkMembers(ir.rest(node, .members));
    }

    fn walkMembers(self: *SymbolResolver, members: []const Sexp) Error!void {
        for (members) |m| {
            if (m.isKind(.fun) or m.isKind(.sub) or m.isKind(.drop_decl)) try self.walkFun(m);
        }
    }

    fn walkSet(self: *SymbolResolver, node: Sexp) Error!void {
        const kind = rig.bindingKindOf(ir.Set.op(node));
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
                    if (self.visibleLocal(self.scope, identAt(self.ctx.source, target).?)) |prev| {
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
    /// the current body, or a module-level constant (which typecheck then
    /// rejects as a reassignment).
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
        if (self.visibleLocal(parent, name)) |prev| {
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
            .src => if (patternBinds(self.ctx.source, pattern)) {
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
}

/// The checks on declared types that need to know what every type holds
/// (`sema.computeContents`), then the module's public surface.
pub fn checkDeclarations(ctx: *SemContext) Error!void {
    for (ctx.deferred_checks.items) |c| try runCheck(ctx, c);
    ctx.deferred_checks.clearAndFree(ctx.allocator);
    try checkPublicSurface(ctx);
}

/// A rule on a spelled type that depends on what other types hold.
pub const DeferredCheck = union(enum) {
    /// `[N]T`, with `T` spelled at `node`.
    array: struct { node: Sexp, elem: TypeId },
    /// `Vec[T]`, `Cell[T]`, or `Signal[T]` spelled at `pos`.
    builtin: struct { pos: u32, sym: SymbolId, args: []const TypeId },
    /// `*fun(...) -> R`, with the function type spelled at `node`.
    owned_closure: struct { node: Sexp, ty: TypeId },
};

fn runCheck(ctx: *SemContext, check: DeferredCheck) Error!void {
    switch (check) {
        .array => |c| {
            if (sema.typeHasDropGlue(ctx, c.elem)) {
                try ctx.errAt(c.node, "arrays cannot hold values that own resources (`{s}`); use a `Vec`", .{try sema.formatType(ctx, c.elem)});
                return;
            }
            // `[N]T` in a generic type: every instance must supply plain
            // data for the parameters the element holds.
            var held: std.ArrayListUnmanaged(SymbolId) = .empty;
            defer held.deinit(ctx.allocator);
            try sema.heldTypeVars(ctx, c.elem, &held, ctx.allocator);
            for (held.items) |param| {
                try ctx.generic_requirements.append(ctx.allocator, .{ .param = param, .req = .plain, .pos = ctx.startOf(c.node), .op = "keeps in an array a value" });
            }
        },
        .builtin => |c| if (try builtinElementError(ctx, c.sym, c.args)) |msg| try ctx.err(c.pos, "{s}", .{msg}),
        .owned_closure => |c| try checkOwnedClosureType(ctx, c.node, c.ty),
    }
}

pub const TypeResolver = struct {
    ctx: *SemContext,
    scope: ScopeId,
    nominal: NominalContext = NominalContext.none,

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
                const text = identAt(self.ctx.source, name) orelse "extern";
                if (self.ctx.types.get(ty) == .function) {
                    try self.ctx.errAt(name, "a C function is declared with `extern fun {s}(...)` or `extern sub {s}(...)`; `extern name: T` is for C data", .{ text, text });
                    self.ctx.symbols.items[id].ty = self.ctx.types.invalid_id;
                    return;
                }
                self.ctx.symbols.items[id].ty = ty;
                if (!self.isCAbiType(ty)) {
                    try self.ctx.errAt(name, "`extern` variable `{s}` cannot have type `{s}`; only integers, floats, and Bool cross the C boundary", .{ text, try sema.formatType(self.ctx, ty) });
                }
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
        // Its parameter and return types are poison, so nothing else about
        // it is reported.
        const generic = try self.rejectGenericFunction(node);
        const returns = rig.returnType(node);
        const return_ty = if (generic)
            self.ctx.types.invalid_id
        else if (returns == .nil)
            self.ctx.types.void_id
        else
            try self.resolveReturnType(returns);

        var param_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer param_types.deinit(self.ctx.allocator);
        var ct_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer ct_types.deinit(self.ctx.allocator);
        for ([_]Sexp{ sema.tparamsOf(node), params }, 0..) |group, g| for (group.items()) |p| {
            // A type parameter makes the function generic, which
            // `rejectGenericFunction` reported: every type is poison.
            const pty = if (generic) self.ctx.types.invalid_id else try self.resolveParamType(p);
            try (if (g == 0) &ct_types else &param_types).append(self.ctx.allocator, pty);
            if (sema.paramNameNode(p)) |pn| {
                if (self.ctx.symbolOf(pn)) |pid| self.ctx.symbols.items[pid].ty = pty;
            }
        };
        const fn_ty = try self.ctx.intern(.{ .function = .{
            .params = try self.ctx.dupeIds(param_types.items),
            .returns = return_ty,
            .is_sub = is_sub,
            .ct_params = try self.ctx.dupeIds(ct_types.items),
        } });
        try self.ctx.recordType(name, fn_ty);
        if (nominal_sym == sema.symbol_invalid) {
            if (self.ctx.symbolOf(name)) |fid| {
                self.ctx.symbols.items[fid].ty = fn_ty;
                self.ctx.symbols.items[fid].param_names = try self.paramNames(params);
                self.ctx.symbols.items[fid].param_defaults = try self.paramDefaults(params);
            }
        }
        return fn_ty;
    }

    /// A type parameter (`fun max[T](a: T, b: T) -> T`) would make a
    /// function generic, which Rig does not support yet.
    fn rejectGenericFunction(self: *TypeResolver, node: Sexp) Error!bool {
        const at = for (sema.tparamsOf(node).items()) |p| {
            if (p == .src) break p;
        } else return false;
        try self.ctx.errAt(at, "generic functions are not supported yet: the type parameter `{s}` would make `{s}` generic; use a generic type, or write the function for each type", .{ identAt(self.ctx.source, at) orelse "T", identAt(self.ctx.source, ir.get(node, .name)) orelse "it" });
        return true;
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
            if (sema.isErrorSet(self.ctx, inner)) {
                const e = try sema.formatType(self.ctx, inner);
                try self.ctx.errAt(node, "`{s}!` would make a failure and a success both `{s}` values; return `{s}` or `{s}?`, or a struct that holds one", .{ e, e, e, e });
                return self.ctx.types.invalid_id;
            }
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
                    .@":", .default => return self.resolveType(ir.get(param, .type)),
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
                    const vname = identAt(self.ctx.source, m).?;
                    if (!is_enum) {
                        try self.ctx.err(s.pos, "field `{s}` needs a type (`{s}: T`)", .{ vname, vname });
                        continue;
                    }
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
                            if (is_enum) {
                                try self.ctx.err(fpos, "an enum declares variants, not typed fields; write `{s}` or `{s}(field: T)`", .{ fname, fname });
                                continue;
                            }
                            if (try self.checkDuplicateMember(fields.items, fname, fpos, sym_name)) continue;
                            const fty = try self.resolveType(ir.get(m, .type));
                            try fields.append(self.ctx.allocator, .{ .name = fname, .ty = fty, .decl_pos = fpos, .default = if (h == .default) ir.Default.value(m) else null });
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
                                try self.ctx.errAt(m, "`drop` bodies are only for structs, not {s}", .{where});
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

        if (generic) try self.checkTypeParamNames(sym_id, members);
        if (head == .@"enum" or head == .generic_enum) try self.checkEnumValues(members, generic);
        if (head == .@"struct") {
            for (members) |m| {
                if (m.isKind(.drop_decl)) try self.enforceDropBody(ir.DropDecl.body(m));
            }
        }
    }

    /// A generic parameter may not take a name that means something else
    /// where it is used: a built-in or primitive type, `Self`, a
    /// module-level declaration (the generic type itself included), or a
    /// method of the type.
    fn checkTypeParamNames(self: *TypeResolver, sym_id: SymbolId, members: []const Sexp) Error!void {
        for (self.ctx.symbols.items[sym_id].type_params orelse &.{}) |tp| {
            const p = self.ctx.symbols.items[tp];
            if (primitiveTypeId(self.ctx, p.name) != null or isNumericTypeName(p.name) or std.mem.eql(u8, p.name, "Self")) {
                try self.ctx.err(p.decl_pos, "generic parameter `{s}` has the name of a built-in type; use a different name, such as `T`", .{p.name});
            } else if (self.ctx.lookupInScopeOnly(sema.module_scope, p.name)) |decl| {
                try self.ctx.err(p.decl_pos, "generic parameter `{s}` has the same name as the module-level declaration `{s}`; use a different name", .{ p.name, p.name });
                const d = self.ctx.symbols.items[decl];
                if (d.decl_pos != sema.builtin_decl_pos) try self.ctx.note(d.decl_pos, "`{s}` declared here", .{p.name});
            } else for (members) |m| {
                if (!m.isKind(.fun) and !m.isKind(.sub)) continue;
                if (!std.mem.eql(u8, identAt(self.ctx.source, ir.get(m, .name)) orelse "", p.name)) continue;
                try self.ctx.err(p.decl_pos, "generic parameter `{s}` has the same name as a method of the type; use a different name", .{p.name});
                break;
            }
        }
    }

    /// Explicit enum values are constant integers that fit the emitted
    /// `enum(u32)` tag, and no two variants share a value (a variant
    /// without one takes the value after the previous variant's). Only a
    /// plain enum, without payloads or generic parameters, has values.
    fn checkEnumValues(self: *TypeResolver, members: []const Sexp, generic: bool) Error!void {
        var valued = false;
        var payloads = false;
        for (members) |m| {
            if (m.isKind(.valued)) valued = true;
            if (m.isKind(.variant)) payloads = true;
        }
        if (!valued) return;
        if (generic or payloads) {
            for (members) |m| {
                if (!m.isKind(.valued)) continue;
                try self.ctx.errAt(ir.Valued.value(m), "{s} cannot give its variants values; only a plain enum can", .{if (generic) "a generic enum" else "an enum with payload variants"});
            }
            return;
        }
        var seen: std.AutoHashMapUnmanaged(i128, Sexp) = .empty;
        defer seen.deinit(self.ctx.allocator);
        var next: i128 = 0;
        for (members) |m| {
            const explicit = m.isKind(.valued);
            const name_node = if (explicit) ir.Valued.name(m) else if (m == .src) m else continue;
            const name = identAt(self.ctx.source, name_node).?;
            const value = if (explicit) sema.constIntOf(self.ctx, ir.Valued.value(m)) orelse {
                try self.ctx.errAt(ir.Valued.value(m), "the value of `{s}` must be a constant integer", .{name});
                return;
            } else next;
            if (value < 0 or value > std.math.maxInt(u32)) {
                try self.ctx.errAt(if (explicit) ir.Valued.value(m) else name_node, "`{s}` has the value {d}, out of range: enum values run from 0 to {d}", .{ name, value, std.math.maxInt(u32) });
                return;
            }
            const gop = try seen.getOrPut(self.ctx.allocator, value);
            if (gop.found_existing) {
                const prev = gop.value_ptr.*;
                try self.ctx.errAt(name_node, "`{s}` has the value {d}, which `{s}` already has{s}", .{ name, value, identAt(self.ctx.source, prev).?, if (explicit) "" else " (a variant without `= value` takes the value after the previous variant's)" });
                try self.ctx.noteAt(prev, "`{s}` declared here", .{identAt(self.ctx.source, prev).?});
            } else gop.value_ptr.* = name_node;
            next = value + 1;
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
                    if (p.isKind(.default)) {
                        try self.ctx.errAt(ir.Default.name(p), "variant payload fields cannot have defaults", .{});
                        continue;
                    }
                    try self.ctx.errAt(p, "variant payload fields need types (`name: T`)", .{});
                    continue;
                }
                const field_name = ir.get(p, .name);
                const fname = identAt(self.ctx.source, field_name) orelse continue;
                if (try self.checkDuplicateMember(payload.items, fname, srcPos(field_name, 0), vname)) continue;
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
        for (params.items(), 0..) |p, i| {
            if (i == 0) continue;
            if (self.isSelfParam(p)) {
                try self.ctx.err(sema.paramPos(p, mpos), "`self` must be the first parameter of a method", .{});
            }
            if (p.isKind(.read) or p.isKind(.write)) {
                try self.ctx.err(sema.paramPos(p, mpos), "sigil-prefixed parameter sugar (`?self` / `!self`) is only allowed at the first parameter position", .{});
            }
        }
        const receiver: MethodReceiver = if (params.items().len > 0 and self.isSelfParam(params.items()[0]))
            try self.classifyReceiver(fn_ty, nominal_sym, mpos)
        else
            .none;
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

    fn classifyReceiver(self: *TypeResolver, fn_ty_id: TypeId, nominal_sym: SymbolId, mpos: u32) Error!MethodReceiver {
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
            .unknown, .invalid => {},
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
        if (!self.isSelfParam(first)) {
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
    /// it must not consume or replace `self`.
    fn enforceDropBody(self: *TypeResolver, body: Sexp) Error!void {
        const head = body.kind() orelse return;
        switch (head) {
            .drop => if (self.isSelf(ir.Drop.name(body))) {
                try self.ctx.errAt(ir.Drop.name(body), "cannot drop `self` inside its own drop body; the binding is being destroyed by the runtime", .{});
            },
            .move => if (self.isSelf(ir.Move.operand(body))) {
                try self.ctx.errAt(ir.Move.operand(body), "cannot move `self` out of its own drop body; the binding is being destroyed by the runtime", .{});
            },
            .@"return" => if (self.isSelf(ir.Return.value(body))) {
                try self.ctx.errAt(ir.Return.value(body), "cannot return `self` from its own drop body", .{});
            },
            .set => if (self.isSelf(ir.Set.target(body))) {
                try self.ctx.errAt(ir.Set.target(body), "cannot reassign `self` inside its own drop body; dropping the old value would run this body again", .{});
            },
            else => {},
        }
        for (rig.children(body)) |c| try self.enforceDropBody(c);
    }

    fn isSelf(self: *TypeResolver, node: Sexp) bool {
        return std.mem.eql(u8, identAt(self.ctx.source, node) orelse "", "self");
    }

    fn isSelfParam(self: *TypeResolver, param: Sexp) bool {
        return std.mem.eql(u8, sema.paramName(self.ctx.source, param) orelse "", "self");
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
                            try self.ctx.err(s.pos, "generic type `{s}` requires type arguments; write `{s}[{s}]`", .{ name, name, if (arity > 1) "T, ..." else "T" });
                            return t.invalid_id;
                        },
                        else => {
                            // A function's type parameter was reported with the function.
                            if (sym.kind != .generic_param) try self.ctx.err(s.pos, "`{s}` is not a type", .{name});
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
                    .error_union => {
                        const inner = try self.resolveType(ir.ErrorUnion.type(sexp));
                        const ty = try self.ctx.intern(.{ .fallible = inner });
                        try self.ctx.errAt(sexp, "a fallible type `{s}` is only allowed as a function's return type (a fallible handle is `(*T)!`)", .{try sema.formatType(self.ctx, ty)});
                        return t.invalid_id;
                    },
                    .optional, .borrow_read, .borrow_write, .weak, .slice => {
                        const inner = try self.resolveType(if (head == .weak) ir.Weak.operand(sexp) else ir.get(sexp, .type));
                        if (inner == t.invalid_id) return t.invalid_id;
                        return self.ctx.intern(switch (head) {
                            .optional => .{ .optional = inner },
                            .borrow_read => .{ .borrow_read = inner },
                            .borrow_write => .{ .borrow_write = inner },
                            .weak => .{ .weak = inner },
                            else => .{ .slice = .{ .elem = inner } },
                        });
                    },
                    .shared => {
                        const inner_node = ir.Shared.type(sexp);
                        const inner = try self.resolveType(inner_node);
                        if (inner == t.invalid_id) return t.invalid_id;
                        if (self.ctx.types.get(inner) == .shared) {
                            try self.ctx.errAt(inner_node, "nested shared type `**T` is not meaningful; use a single `*T`", .{});
                            return t.invalid_id;
                        }
                        if (self.ctx.types.get(inner) == .function) try self.checkWhenResolved(.{ .owned_closure = .{ .node = inner_node, .ty = inner } });
                        return self.ctx.intern(.{ .shared = inner });
                    },
                    .array_type => {
                        const size = ir.ArrayType.size(sexp);
                        const len = std.fmt.parseInt(u64, identAt(self.ctx.source, size) orelse "", 0) catch {
                            try self.ctx.errAt(size, "array length must be an integer literal", .{});
                            return t.invalid_id;
                        };
                        const elem_node = ir.ArrayType.type(sexp);
                        const elem = try self.resolveType(elem_node);
                        try self.checkWhenResolved(.{ .array = .{ .node = elem_node, .elem = elem } });
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
        const fid = foreign.lookupInScopeOnly(sema.module_scope, name) orelse {
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

    /// Run `check` now if every declared type's contents are known,
    /// otherwise once they are (`checkDeclarations`).
    fn checkWhenResolved(self: *TypeResolver, check: DeferredCheck) Error!void {
        if (self.ctx.contents_ready) return runCheck(self.ctx, check);
        try self.ctx.deferred_checks.append(self.ctx.allocator, check);
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
        var args: std.ArrayListUnmanaged(TypeId) = .empty;
        defer args.deinit(self.ctx.allocator);
        var any_bad = false;
        for (supplied) |a| {
            const arg = try self.resolveType(a);
            if (arg == t.invalid_id or arg == t.unknown_id) any_bad = true;
            try args.append(self.ctx.allocator, arg);
        }
        const ty = try self.ctx.internCopy(.{ .parameterized_nominal = .{ .sym = sym_id, .args = args.items } });
        const inst = self.ctx.types.get(ty).parameterized_nominal;
        if (!any_bad and sym.decl_pos == sema.builtin_decl_pos) {
            try self.checkWhenResolved(.{ .builtin = .{ .pos = pos, .sym = sym_id, .args = inst.args } });
        }
        if (!sema.containsTypeVar(self.ctx, ty)) {
            const gop = try self.ctx.instantiation_sites.getOrPut(self.ctx.allocator, ty);
            if (!gop.found_existing) gop.value_ptr.* = pos;
        } else {
            // Spelled inside a generic declaration: each instantiation of
            // that generic instantiates this too.
            for (self.ctx.generic_uses.items) |u| {
                if (u == ty) break;
            } else try self.ctx.generic_uses.append(self.ctx.allocator, ty);
        }
        return ty;
    }
};

/// Element-type rules of the built-in generics. An instance over generic
/// parameters (`Vec[T]` in `Stack[T]`) is checked for each instantiation
/// instead (`sema.expandInstantiations`).
pub fn builtinElementError(ctx: *SemContext, sym_id: SymbolId, args: []const TypeId) Error!?[]const u8 {
    if (args.len != 1 or sema.containsTypeVar(ctx, args[0])) return null;
    const a = ctx.arena.allocator();
    const arg = try sema.formatType(ctx, args[0]);
    if (sym_id == ctx.cell_sym_id) {
        if (sema.isCopyPrimitive(ctx, args[0]) or sema.typeHasDropGlue(ctx, args[0])) return null;
        return try std.fmt.allocPrint(a, "`Cell[T]` requires `T` to be a Copy primitive (Int, Bool, Float, String) or a type with drop glue (`*T`, `~T`, `Vec[T]`, `*sub()`, a struct with resource fields or a user `drop`); got `{s}`", .{arg});
    }
    if (sym_id == ctx.vec_sym_id) {
        const ok = sema.isCopyPrimitive(ctx, args[0]) or switch (ctx.types.get(args[0])) {
            .shared, .weak => true,
            // Plain data: a struct, enum, or optional that owns nothing
            // and holds no borrow is copied like a number.
            .nominal, .imported_nominal, .parameterized_nominal, .optional => sema.isPlainData(ctx, args[0]),
            else => false,
        };
        if (ok) return null;
        return try std.fmt.allocPrint(a, "`Vec[T]` requires `T` to be a Copy type (Int, Bool, Float, String), plain data (a struct, enum, or optional that owns nothing), a shared handle (`*T`), or a weak handle (`~T`); got `{s}`", .{arg});
    }
    if (sym_id == ctx.signal_sym_id) {
        if (sema.isCopyPrimitive(ctx, args[0])) return null;
        return try std.fmt.allocPrint(a, "`Signal[T]` requires `T` to be a Copy type (Int, Bool, Float, String); got `{s}`", .{arg});
    }
    return null;
}

/// `*fun(...) -> R` / `*sub(...)`: an owned closure passes plain Copy
/// values through its type-erased form.
fn checkOwnedClosureType(ctx: *SemContext, fun_type: Sexp, ty: TypeId) Error!void {
    const f = ctx.types.get(ty).function;
    const is_fun_type = fun_type.isKind(.fun_type);
    const nodes: []const Sexp = if (is_fun_type) ir.FunType.params(fun_type).items() else &.{};
    for (f.params, 0..) |p, i| {
        if (sema.isClosureValue(ctx, p)) continue;
        const pos = if (i < nodes.len) ctx.startOf(nodes[i]) else ctx.startOf(fun_type);
        try ctx.err(pos, "an owned closure takes plain Copy values (Int, Float, Bool, String, sized numbers, plain enums, or optionals of these); `{s}` is not one", .{try sema.formatType(ctx, p)});
    }
    if (!f.is_sub and !sema.isClosureValue(ctx, f.returns)) {
        const pos = if (is_fun_type and ir.FunType.returns(fun_type) != .nil) ctx.startOf(ir.FunType.returns(fun_type)) else ctx.startOf(fun_type);
        try ctx.err(pos, "an owned closure returns plain Copy values (Int, Float, Bool, String, sized numbers, plain enums, or optionals of these); `{s}` is not one", .{try sema.formatType(ctx, f.returns)});
    }
}

/// An importer reaches every type in the module's public surface: the
/// signatures of `pub` functions and aliases, the members of `pub` types,
/// and, through those, the members of the private types they hold. None
/// may be an instance of a generic type declared here, which the
/// importer could not name or resolve: generic types cannot cross module
/// boundaries yet.
fn checkPublicSurface(ctx: *SemContext) Error!void {
    var exposed: std.AutoHashMapUnmanaged(SymbolId, ?TypeId) = .empty;
    defer exposed.deinit(ctx.allocator);
    for (ctx.symbols.items) |sym| {
        if (!sym.flags.is_public) continue;
        switch (sym.kind) {
            .function, .type_alias => if (try exposedInstance(ctx, sym.ty, &exposed)) |inst| {
                const what = if (sym.kind == .type_alias) "type" else if (ctx.types.get(sym.ty) == .function and ctx.types.get(sym.ty).function.is_sub) "sub" else "function";
                try reportExposed(ctx, sym.decl_pos, what, sym.name, inst);
            },
            .nominal_type => for (sym.fields orelse &.{}) |*f| {
                const inst = try exposedInMember(ctx, f, &exposed) orelse continue;
                try reportExposed(ctx, f.decl_pos, if (f.is_method) "method" else if (f.is_variant) "variant" else "field", f.name, inst);
            },
            else => {},
        }
    }
}

/// `exposedInstance` for a method's signature or the types a data field
/// or variant holds.
fn exposedInMember(ctx: *SemContext, f: *const Field, exposed: *std.AutoHashMapUnmanaged(SymbolId, ?TypeId)) Error!?TypeId {
    if (f.is_method) return exposedInstance(ctx, f.ty, exposed);
    for (sema.dataFields(f)) |d| {
        if (try exposedInstance(ctx, d.ty, exposed)) |x| return x;
    }
    return null;
}

fn reportExposed(ctx: *SemContext, pos: u32, what: []const u8, name: []const u8, inst: TypeId) Error!void {
    try ctx.err(pos, "public {s} `{s}` exposes `{s}`, an instance of a generic type; generic types cannot cross module boundaries yet", .{ what, name, try sema.formatType(ctx, inst) });
}

/// The first instance of a generic type declared here that `ty` exposes:
/// in its structure, or in the members of a private type it names (each
/// searched once; `exposed` holds the answers).
fn exposedInstance(ctx: *SemContext, ty: TypeId, exposed: *std.AutoHashMapUnmanaged(SymbolId, ?TypeId)) Error!?TypeId {
    switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| if (ctx.symbols.items[pn.sym].decl_pos != sema.builtin_decl_pos) return ty,
        .type_var => return ty,
        .nominal => |s| {
            const sym = ctx.symbols.items[s];
            // A public type's members are checked on their own.
            if (sym.flags.is_public) return null;
            const gop = try exposed.getOrPut(ctx.allocator, s);
            if (gop.found_existing) return gop.value_ptr.*;
            gop.value_ptr.* = null;
            const found = fields: for (sym.fields orelse &.{}) |*f| {
                if (try exposedInMember(ctx, f, exposed)) |x| break :fields x;
            } else null;
            try exposed.put(ctx.allocator, s, found);
            return found;
        },
        else => {},
    }
    var it = sema.typeChildren(ctx, ty);
    while (it.next()) |c| if (try exposedInstance(ctx, c, exposed)) |x| return x;
    return null;
}

/// A leaf match pattern that binds its name: not the wildcard `_`, and
/// not a literal (`1`, `true`).
pub fn patternBinds(source: []const u8, pattern: Sexp) bool {
    const text = identAt(source, pattern) orelse return false;
    for ([_][]const u8{ "_", "true", "false" }) |word| if (std.mem.eql(u8, text, word)) return false;
    return !sema.isIntLiteralText(text) and !sema.isFloatLiteralText(text);
}

fn primitiveTypeId(ctx: *const SemContext, name: []const u8) ?TypeId {
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

/// The bit width a sized type name spells: `I8`..`I64`, `U8`..`U64`,
/// `F32`, `F64`.
fn sizedTypeBits(name: []const u8) ?u8 {
    // No leading zero: `I08` is not `I8`.
    if (name.len < 2 or name.len > 3 or name[1] == '0') return null;
    const bits = std.fmt.parseInt(u8, name[1..], 10) catch return null;
    const ok = switch (name[0]) {
        'I', 'U' => bits == 8 or bits == 16 or bits == 32 or bits == 64,
        'F' => bits == 32 or bits == 64,
        else => false,
    };
    return if (ok) bits else null;
}

/// A sized type. `I64` is `Int` and `F64` is `Float`: the same types
/// under their sized names.
fn sizedTypeId(ctx: *SemContext, name: []const u8) ?Error!TypeId {
    const bits = sizedTypeBits(name) orelse return null;
    return switch (name[0]) {
        'I' => if (bits == 64) ctx.types.int_id else ctx.intern(.{ .int = .{ .bits = bits } }),
        'U' => ctx.intern(.{ .int = .{ .bits = bits, .signed = false } }),
        else => if (bits == 64) ctx.types.float_id else ctx.intern(.{ .float = .{ .bits = bits } }),
    };
}

/// Whether `name` spells a built-in type: `Int`, `String`, `U8`, ...
pub fn isBuiltinTypeName(ctx: *const SemContext, name: []const u8) bool {
    return primitiveTypeId(ctx, name) != null or sizedTypeBits(name) != null;
}

/// Whether `name` spells a numeric type: `Int`, `Float`, or a sized one.
/// Called like a function, such a name converts a number to that type.
pub fn isNumericTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Int") or std.mem.eql(u8, name, "Float") or sizedTypeBits(name) != null;
}

// =============================================================================
// Built-in generic types
//
// `Cell[T]`, `Vec[T]`, and `Signal[T]`, registered in every module scope
// before user declarations. Their methods are ordinary method Fields on
// generic symbols, so calls go through the same lookup and substitution as
// user generics; the runtime (`runtime.zig`) implements them.
// =============================================================================

const builtin_pos = sema.builtin_decl_pos;

pub fn registerBuiltins(ctx: *SemContext, module_scope: ScopeId) Error!void {
    // Cell[T]: interior-mutable slot. Methods take `?self`; the runtime
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

    // Vec[T]: growable buffer that owns its elements.
    {
        const g = try addGeneric(ctx, module_scope, "Vec", &.{"T"});
        ctx.vec_sym_id = g.sym;
        const t = g.params[0];
        const read_self = try ctx.intern(.{ .borrow_read = g.self_ty });
        const write_self = try ctx.intern(.{ .borrow_write = g.self_ty });
        const opt_t = try ctx.intern(.{ .optional = t });
        try setFields(ctx, g.sym, &.{
            try method(ctx, "push", .write, &.{ write_self, t }, ctx.types.void_id),
            try method(ctx, "clear", .write, &.{write_self}, ctx.types.void_id),
            try method(ctx, "get", .read, &.{ read_self, ctx.types.int_id }, opt_t),
            try method(ctx, "pop", .write, &.{write_self}, opt_t),
        });
    }

    // Signal[T]: a Copy value plus subscriber closures notified on `set`.
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
    /// The type applied to its own parameters: `Vec[T]`.
    self_ty: TypeId,
};

fn addGeneric(ctx: *SemContext, module_scope: ScopeId, name: []const u8, param_names: []const []const u8) Error!Generic {
    const sym = try ctx.addSymbol(.{
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
        param_syms[i] = try ctx.addSymbol(.{
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
    try std.testing.expectEqual(@as(usize, 4), ctx.symbols.items[vec].fields.?.len);
    try std.testing.expect(ctx.lookup(scope, "T") == null);
}
