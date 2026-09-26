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
            .generic_struct, .generic_enum => try self.walkGenericType(sexp),
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
            if (self.ctx.symbols.items[prev].kind == .generic_param) return self.checkShadowsDeclaration(name_node, what);
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
    /// function, type, constant, extern, or module, or of a generic
    /// parameter of the enclosing generic type or function: Zig rejects
    /// the shadowing, and a name means one thing in a body.
    fn checkShadowsDeclaration(self: *SymbolResolver, name_node: Sexp, what: []const u8) Error!void {
        const name = identAt(self.ctx.source, name_node) orelse return;
        const fn_param = if (self.ctx.lookup(self.scope, name)) |id| self.ctx.symbols.items[id].kind == .generic_param else false;
        const type_param = for (self.type_params) |tp| {
            if (std.mem.eql(u8, self.ctx.symbols.items[tp].name, name)) break true;
        } else false;
        if (fn_param or type_param) {
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

    /// A `generic_struct` or `generic_enum`.
    fn walkGenericType(self: *SymbolResolver, node: Sexp) Error!void {
        const name_node = ir.get(node, .name);
        const id = (try self.declare(name_node, .generic_type, .{})) orelse return;
        const name = self.ctx.symbols.items[id].name;
        const params = ir.get(node, .tparams);
        var ids: std.ArrayListUnmanaged(SymbolId) = .empty;
        defer ids.deinit(self.ctx.allocator);
        for (params.items(), 0..) |p, i| {
            const pnode = sema.paramNameNode(p) orelse continue;
            const pname = identAt(self.ctx.source, pnode) orelse continue;
            const dup = for (params.items()[0..i]) |e| {
                if (std.mem.eql(u8, sema.paramName(self.ctx.source, e) orelse "", pname)) break true;
            } else false;
            if (dup) {
                try self.ctx.errAt(pnode, "duplicate generic parameter `{s}` on `{s}`", .{ pname, name });
                continue;
            }
            // Detached: reached through the type's `type_params`. A bare
            // name is a type parameter; `n: Int` a compile-time value,
            // whose type `resolveNominal` resolves.
            const value = p.isKind(.@":");
            const pid = try self.ctx.addSymbol(.{
                .name = pname,
                .kind = if (value) .param else .generic_param,
                .ty = self.ctx.types.unknown_id,
                .decl_pos = srcPos(pnode, 0),
                .scope = if (value) sema.scope_invalid else self.scope,
                .flags = .{ .comptime_known = value },
            });
            try self.ctx.recordName(pnode, pid);
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
        // `for x in !xs` writes `xs` through `x`.
        if (ir.For.mode(node).tag == .write) try self.markWritten(ir.For.source(node));
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
    try foldModuleConsts(ctx, tree);
    var tr: TypeResolver = .{ .ctx = ctx, .scope = module_scope };
    for (ir.Module.decls(tree)) |decl| try tr.resolveDecl(decl);
}

/// Fold each integer module constant once, in declaration order, into
/// `const_ints`, so any type in the module can name it. A constant's
/// value names only earlier constants; one that does not fold, or does
/// not fit its type, is left for the checker to report.
fn foldModuleConsts(ctx: *SemContext, tree: Sexp) Error!void {
    for (ir.Module.decls(tree)) |decl| {
        if (!rig.isModuleConst(decl)) continue;
        const set = if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
        const target = ir.Set.target(set);
        if (target != .src or rig.bindingKindOf(ir.Set.op(set)) != .fixed) continue;
        const id = ctx.symbolOf(target) orelse continue;
        const ty = ir.Set.type(set);
        const declared: ?sema.IntInfo = if (ty == .nil) null else declaredIntType(ctx, ty) orelse continue;
        const names: ConstNames = .{ .ctx = ctx, .scope = sema.module_scope };
        const t = switch (sema.ctFoldBy(ctx, ir.Set.value(set), names)) {
            .value => |t| t,
            else => continue,
        };
        const int = declared orelse t.int orelse sema.IntInfo{};
        if (t.int) |i| if (!std.meta.eql(i, int)) continue;
        if (!sema.intInfoFits(int, t.v)) continue;
        try ctx.const_ints.put(ctx.allocator, id, .{ .value = t.v, .int = int });
    }
}

/// The integer type a constant's annotation names, through aliases;
/// null for any other type.
fn declaredIntType(ctx: *const SemContext, node: Sexp) ?sema.IntInfo {
    var ty = node;
    for (0..16) |_| {
        const name = identAt(ctx.source, ty) orelse return null;
        if (isIntTypeName(name)) {
            const bits = sizedTypeBits(name) orelse 0;
            return if (bits == 64 and name[0] == 'I') .{} else .{ .bits = bits, .signed = name[0] != 'U' };
        }
        const id = ctx.lookupInScopeOnly(sema.module_scope, name) orelse return null;
        if (ctx.symbols.items[id].kind != .type_alias) return null;
        ty = ctx.alias_targets.get(id) orelse return null;
    }
    return null;
}

/// The checks on declared types that need to know what every type holds
/// (`sema.computeContents`).
pub fn checkDeclarations(ctx: *SemContext) Error!void {
    for (ctx.deferred_checks.items) |c| try runCheck(ctx, c);
    ctx.deferred_checks.clearAndFree(ctx.allocator);
}

/// A rule on a spelled type that depends on what other types hold.
pub const DeferredCheck = union(enum) {
    /// `[N]T` spelled at `at`, with `T` spelled at `node`; `ty` is the
    /// array type, when its size is still to be checked.
    array: struct { node: Sexp, elem: TypeId, at: Sexp, ty: ?TypeId },
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
            if (c.ty) |ty| if (!try sema.checkArrayBytes(ctx, ctx.startOf(c.at), ty)) return;
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

/// The values of the constants a compile-time integer in a type names
/// (`sema.ctFoldBy`): a constant binding, a module constant, and
/// `module.NAME`, each with its type.
pub const ConstNames = struct {
    ctx: *const SemContext,
    scope: ScopeId,
    /// The generic type's parameters, which are not constants.
    type_params: []const SymbolId = &.{},
    /// In a module constant's declaration, its position: the module
    /// constants declared from there on are not visible yet.
    before: u32 = std.math.maxInt(u32),

    pub fn name(self: ConstNames, e: Sexp) ?sema.TypedInt {
        const text = identAt(self.ctx.source, e) orelse return null;
        for (self.type_params) |tp| if (std.mem.eql(u8, self.ctx.symbols.items[tp].name, text)) return null;
        const id = self.ctx.symbolOf(e) orelse self.ctx.lookupBefore(self.scope, text, e.src.pos) orelse return null;
        const sym = self.ctx.symbols.items[id];
        if (sym.kind != .local or !sym.flags.fixed or !self.visible(id)) return null;
        const c = self.ctx.const_ints.get(id) orelse return null;
        return .{ .v = c.value, .int = c.int };
    }

    pub fn member(self: ConstNames, e: Sexp) ?sema.TypedInt {
        const obj = ir.Member.object(e);
        const id = self.ctx.lookup(self.scope, identAt(self.ctx.source, obj) orelse return null) orelse return null;
        if (self.ctx.symbols.items[id].kind != .module) return null;
        const foreign = self.ctx.foreign_semas.get(self.ctx.module_refs.get(id) orelse return null) orelse return null;
        const fid = foreign.lookupInScopeOnly(sema.module_scope, identAt(self.ctx.source, ir.Member.name(e)) orelse return null) orelse return null;
        if (!foreign.symbols.items[fid].flags.is_public) return null;
        const c = foreign.const_ints.get(fid) orelse return null;
        return .{ .v = c.value, .int = c.int };
    }

    /// Whether symbol `id` is visible: a module constant declared at or
    /// after `before` is not.
    pub fn visible(self: ConstNames, id: SymbolId) bool {
        const sym = self.ctx.symbols.items[id];
        return !(sym.scope == sema.module_scope and sym.kind == .local and sym.decl_pos >= self.before);
    }
};

/// "type" when a generic type's parameters are all types, and
/// "compile-time" when some are values.
pub fn argsNoun(ctx: *const SemContext, tparams: []const SymbolId) []const u8 {
    for (tparams) |tp| if (ctx.symbols.items[tp].kind == .param) return "compile-time";
    return "type";
}

/// A compile-time argument written as a value: an integer, or arithmetic.
fn isValueSpelling(source: []const u8, node: Sexp) bool {
    return switch (node) {
        .src => sema.isIntLiteralText(identAt(source, node) orelse ""),
        .list => switch (node.kind() orelse return false) {
            .neg, .@"+", .@"-", .@"*", .@"/", .@"%" => true,
            else => false,
        },
        else => false,
    };
}

/// The type of a literal other than an integer: `Float`, `Bool`, or
/// `String`.
fn literalTypeName(text: []const u8) ?[]const u8 {
    if (sema.isFloatLiteralText(text)) return "Float";
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) return "Bool";
    if (text.len > 0 and (text[0] == '"' or text[0] == '\'')) return "String";
    return null;
}

/// The article for a type's name: "an `Int`", "a `Float`".
pub fn an(name: []const u8) []const u8 {
    return if (name.len > 0 and std.mem.indexOfScalar(u8, "AEIO", name[0]) != null) "an" else "a";
}

/// `Int` or a sized integer type's name.
fn isIntTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Int") or (sizedTypeBits(name) != null and name[0] != 'F');
}

pub const TypeResolver = struct {
    ctx: *SemContext,
    scope: ScopeId,
    nominal: NominalContext = NominalContext.none,
    /// In a module constant's declaration, its position (`ConstNames.before`).
    const_before: u32 = std.math.maxInt(u32),

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
            .@"struct", .@"enum", .errors, .generic_struct, .generic_enum => try self.resolveNominal(sexp),
            else => {},
        }
    }

    // ---- functions ----------------------------------------------------------

    /// Resolve a `fun` / `sub` (or method) signature, write parameter
    /// types into the parameter symbols, and return the function type.
    /// Top-level functions also get the type on their symbol. A type
    /// parameter (`fun max[T]`) is bound in the function's scope, where
    /// the signature is resolved.
    fn resolveFunction(self: *TypeResolver, node: Sexp, nominal_sym: SymbolId) Error!TypeId {
        const is_sub = node.isKind(.sub);
        const name = ir.get(node, .name);
        const params = ir.get(node, .params);
        const prev_scope = self.scope;
        defer self.scope = prev_scope;
        if (self.ctx.scopeOf(node)) |s| self.scope = s;

        // The compile-time parameters first: the other types may use
        // them (`fun zeros[n: Int] -> [n]Int`).
        var ct_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer ct_types.deinit(self.ctx.allocator);
        var ct_syms: std.ArrayListUnmanaged(SymbolId) = .empty;
        defer ct_syms.deinit(self.ctx.allocator);
        for (sema.tparamsOf(node).items()) |p| {
            const pty = try self.resolveCtParam(p);
            try ct_types.append(self.ctx.allocator, pty);
            const pid = self.ctx.symbolOf(sema.paramNameNode(p) orelse p) orelse sema.symbol_invalid;
            try ct_syms.append(self.ctx.allocator, pid);
            if (p != .src and pid != sema.symbol_invalid) self.ctx.symbols.items[pid].ty = pty;
        }
        const returns = rig.returnType(node);
        const return_ty = if (returns == .nil) self.ctx.types.void_id else try self.resolveReturnType(returns);
        var param_types: std.ArrayListUnmanaged(TypeId) = .empty;
        defer param_types.deinit(self.ctx.allocator);
        for (params.items()) |p| {
            const pty = try self.resolveParamType(p);
            try param_types.append(self.ctx.allocator, pty);
            if (sema.paramNameNode(p)) |pn| {
                if (self.ctx.symbolOf(pn)) |pid| self.ctx.symbols.items[pid].ty = pty;
            }
        }
        const fn_ty = try self.ctx.intern(.{ .function = .{
            .params = try self.ctx.dupeIds(param_types.items),
            .returns = return_ty,
            .is_sub = is_sub,
            .ct_params = try self.ctx.dupeIds(ct_types.items),
            .ct_syms = try self.ctx.arena.allocator().dupe(SymbolId, ct_syms.items),
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

    /// A compile-time parameter's slot in `FunctionType.ct_params`: a
    /// type parameter (a bare name, `T`) is itself, a `type_var`; a value
    /// parameter (`n: Int`) is its type, which may not depend on a type
    /// parameter.
    fn resolveCtParam(self: *TypeResolver, p: Sexp) Error!TypeId {
        if (p != .src) {
            const ty = try self.resolveParamType(p);
            const type_node = ir.get(p, .type);
            const name = sema.paramName(self.ctx.source, p) orelse "n";
            if (sema.containsTypeVar(self.ctx, ty)) {
                try self.ctx.errAt(type_node, "compile-time parameter `{s}` cannot have the type `{s}`, a type parameter; its type must be known where the function is declared", .{ name, try sema.formatType(self.ctx, ty) });
                return self.ctx.types.invalid_id;
            }
            if (!isCtValueType(self.ctx, ty)) {
                try self.ctx.errAt(type_node, "compile-time parameter `{s}` cannot have the type `{s}`; a compile-time value is a number, `Bool`, `String`, an enum whose variants carry nothing, or an optional of one", .{ name, try sema.formatType(self.ctx, ty) });
                return self.ctx.types.invalid_id;
            }
            return ty;
        }
        const id = self.ctx.symbolOf(p) orelse return self.ctx.types.invalid_id;
        const name = self.ctx.symbols.items[id].name;
        if (self.ctx.symbols.items[id].kind != .generic_param) return self.ctx.types.invalid_id;
        // Reusing the name of the type's own parameter was reported.
        for (self.nominal.type_params) |tp| if (std.mem.eql(u8, self.ctx.symbols.items[tp].name, name)) return self.ctx.types.invalid_id;
        const builtin_generic = if (self.ctx.lookupInScopeOnly(sema.module_scope, name)) |d| self.ctx.symbols.items[d].decl_pos == sema.builtin_decl_pos else false;
        if (primitiveTypeId(self.ctx, name) != null or isNumericTypeName(name) or std.mem.eql(u8, name, "Self") or builtin_generic) {
            try self.ctx.errAt(p, "generic parameter `{s}` has the name of a built-in type; use a different name, such as `T`", .{name});
            return self.ctx.types.invalid_id;
        }
        return self.ctx.intern(.{ .type_var = id });
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

    /// A `struct`, `enum`, `errors`, `generic_struct`, or `generic_enum`.
    fn resolveNominal(self: *TypeResolver, node: Sexp) Error!void {
        const sym_id = self.ctx.symbolOf(ir.get(node, .name)) orelse return;
        const head = node.kind().?;
        const generic = head == .generic_struct or head == .generic_enum;
        const is_enum = head == .@"enum" or head == .errors or head == .generic_enum;
        const members = ir.rest(node, .members);

        const prev = self.nominal;
        self.nominal = try sema.makeNominalContext(self.ctx, sym_id);
        defer self.nominal = prev;

        var fields: std.ArrayListUnmanaged(Field) = .empty;
        defer fields.deinit(self.ctx.allocator);
        const sym_name = self.ctx.symbols.items[sym_id].name;
        if (generic) try self.resolveValueParams(ir.get(node, .tparams));

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
                                    .generic_struct => "generic structs",
                                    else => "enums",
                                };
                                try self.ctx.errAt(m, "`drop` bodies are only for non-generic structs, not {s}", .{where});
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

    /// The types of a generic type's compile-time value parameters
    /// (`n: Int`), which are integers.
    fn resolveValueParams(self: *TypeResolver, tparams: Sexp) Error!void {
        for (tparams.items()) |p| {
            if (!p.isKind(.@":")) continue;
            const id = self.ctx.symbolOf(ir.get(p, .name)) orelse continue;
            const type_node = ir.get(p, .type);
            var ty = try self.resolveType(type_node);
            if (!self.isPoison(ty) and self.ctx.types.get(ty) != .int) {
                try self.ctx.errAt(type_node, "a compile-time value parameter of a type is an integer; `{s}` has the type `{s}`", .{ self.ctx.symbols.items[id].name, try sema.formatType(self.ctx, ty) });
                ty = self.ctx.types.invalid_id;
            }
            self.ctx.symbols.items[id].ty = ty;
        }
    }

    fn isPoison(self: *const TypeResolver, ty: TypeId) bool {
        return ty == self.ctx.types.invalid_id or ty == self.ctx.types.unknown_id;
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
            try self.ctx.err(pos, "`drop` takes exactly one parameter, its receiver: `drop(!self)`; got {d}", .{count});
            return;
        }
        const first = params.items()[0];
        if (!self.isSelfParam(first)) {
            try self.ctx.err(sema.paramPos(first, pos), "`drop` takes its receiver, named `self`: `drop(!self)`", .{});
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
            try self.ctx.err(sema.paramPos(first, pos), "`drop` takes its receiver write-borrowed: `drop(!self)`", .{});
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
                            if (self.ctx.symbols.items[tp].kind == .param) {
                                try self.ctx.err(s.pos, "`{s}` is a compile-time value, not a type", .{name});
                                return t.invalid_id;
                            }
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
                        // A function's own type parameter (`T` in `fun max[T]`).
                        .generic_param => {
                            try self.ctx.recordName(sexp, id);
                            return self.ctx.intern(.{ .type_var = id });
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
                        const len = try self.resolveCtInt(ir.ArrayType.size(sexp), .array_len);
                        const elem_node = ir.ArrayType.type(sexp);
                        const elem = try self.resolveType(elem_node);
                        if (self.isPoison(len)) return t.invalid_id;
                        const ty = try self.ctx.intern(.{ .array = .{ .elem = elem, .len = len } });
                        // Once every type's contents are known, a type too
                        // large is poison.
                        const ready = self.ctx.contents_ready;
                        if (ready and !try sema.checkArrayBytes(self.ctx, self.ctx.startOf(sexp), ty)) return t.invalid_id;
                        try self.checkWhenResolved(.{ .array = .{ .node = elem_node, .elem = elem, .at = sexp, .ty = if (ready) null else ty } });
                        return ty;
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

    /// Where a compile-time integer in a type goes: an array length, or
    /// a generic type's value parameter.
    pub const CtIntUse = union(enum) {
        array_len,
        arg: struct { param: SymbolId, owner: []const u8, index: usize },
    };

    /// A compile-time integer in a type: an array length (`[n]T`) or a
    /// generic type's value argument (`Ring[Int, 4]`). An integer, a
    /// constant, or arithmetic on them is folded to a `ct_value`; a
    /// compile-time integer parameter is its `ct_param`, and each value
    /// it takes is checked (`Requirement.array_len`). Poison after a
    /// diagnostic.
    pub fn resolveCtInt(self: *TypeResolver, node: Sexp, use: CtIntUse) Error!TypeId {
        const t = &self.ctx.types;
        const what: []const u8 = if (use == .array_len) "an array length" else "a compile-time argument";
        try self.recordCtNames(node);
        if (use == .arg and self.namesType(node)) {
            try self.ctx.errAt(node, "compile-time argument {d} of `{s}` is a value of type `{s}`, not a type", .{ use.arg.index + 1, use.arg.owner, try sema.formatType(self.ctx, self.ctx.symbols.items[use.arg.param].ty) });
            return t.invalid_id;
        }
        const folded = (try self.ctIntOf(node, what)) orelse return t.invalid_id;
        const ct = folded.ty;
        const param_ty = if (use == .arg) self.ctx.symbols.items[use.arg.param].ty else t.int_id;
        // A value argument has its parameter's type, as in an expression.
        if (use == .arg and folded.int != null and !self.isPoison(param_ty)) {
            const ty = try self.ctx.intern(.{ .int = folded.int.? });
            if (ty != param_ty) {
                const got = try sema.formatType(self.ctx, ty);
                const want = try sema.formatType(self.ctx, param_ty);
                try self.ctx.errAt(node, "compile-time argument {d} of `{s}` is `{s}`, {s} `{s}`; `{s}` takes {s} `{s}`", .{ use.arg.index + 1, use.arg.owner, try self.sourceText(node), an(got), got, self.ctx.symbols.items[use.arg.param].name, an(want), want });
                return t.invalid_id;
            }
        }
        switch (self.ctx.types.get(ct)) {
            .ct_value => |v| switch (use) {
                .array_len => if (v.int < 0 or v.int > sema.max_array_len) {
                    try self.ctx.errAt(node, "array length {d} is out of range: an array length runs from 0 to {d}", .{ v.int, sema.max_array_len });
                    return t.invalid_id;
                },
                .arg => |a| if (!self.isPoison(param_ty) and !sema.intFits(self.ctx, param_ty, v.int)) {
                    const ty = try sema.formatType(self.ctx, param_ty);
                    try self.ctx.errAt(node, "compile-time argument {d} of `{s}` is `{d}`, which `{s}`, {s} `{s}`, cannot hold", .{ a.index + 1, a.owner, v.int, self.ctx.symbols.items[a.param].name, an(ty), ty });
                    return t.invalid_id;
                },
            },
            .ct_param => |sym| {
                const ty = self.ctx.symbols.items[sym].ty;
                if (use == .arg and !self.isPoison(param_ty) and !self.isPoison(ty) and ty != param_ty) {
                    const got = try sema.formatType(self.ctx, ty);
                    const want = try sema.formatType(self.ctx, param_ty);
                    try self.ctx.errAt(node, "compile-time argument {d} of `{s}` is `{s}`, {s} `{s}`; `{s}` takes {s} `{s}`", .{ use.arg.index + 1, use.arg.owner, self.ctx.symbols.items[sym].name, an(got), got, self.ctx.symbols.items[use.arg.param].name, an(want), want });
                    return t.invalid_id;
                }
                if (use == .array_len) try self.ctx.generic_requirements.append(self.ctx.allocator, .{ .param = sym, .req = .array_len, .pos = self.ctx.startOf(node), .op = "an array length" });
            },
            else => {},
        }
        return ct;
    }

    /// A compile-time integer: its `ct_value` or `ct_param`, and for a
    /// value folded from typed constants, their type.
    const CtInt = struct { ty: TypeId, int: ?sema.IntInfo = null };

    /// The compile-time integer `node` is; null after a diagnostic about
    /// it as `what`.
    fn ctIntOf(self: *TypeResolver, node: Sexp, what: []const u8) Error!?CtInt {
        if (node == .src) if (try self.ctParamNamed(node)) |ct| return .{ .ty = ct };
        const names = self.constNames();
        switch (sema.ctFoldBy(self.ctx, node, names)) {
            .value => |v| return .{ .ty = try sema.ctInt(self.ctx, v.v), .int = v.int },
            .overflow => |o| {
                const at = try self.sourceText(o.node);
                if (o.int) |int| {
                    const ty = try sema.formatType(self.ctx, try self.ctx.intern(.{ .int = int }));
                    const b = sema.intRange(int);
                    if (std.meta.eql(self.ctx.span(o.node), self.ctx.span(node)))
                        try self.ctx.errAt(node, "{s} `{s}` overflows `{s}` ({d}..{d})", .{ what, at, ty, b.min, b.max })
                    else
                        try self.ctx.errAt(o.node, "{s} `{s}` overflows `{s}` ({d}..{d}) in `{s}`", .{ what, try self.sourceText(node), ty, b.min, b.max, at });
                } else try self.ctx.errAt(o.node, "{s} `{s}` is too large to compute", .{ what, try self.sourceText(node) });
                return null;
            },
            .mismatch => |m| {
                try self.ctx.errAt(m.node, "{s} `{s}` combines `{s}` and `{s}`; convert one to the other's type", .{
                    what, try self.sourceText(m.node),
                    try sema.formatType(self.ctx, try self.ctx.intern(.{ .int = m.a })),
                    try sema.formatType(self.ctx, try self.ctx.intern(.{ .int = m.b })),
                });
                return null;
            },
            .not_constant => {},
        }
        const text = try self.sourceText(node);
        if (node == .src and !sema.isIntLiteralText(text)) {
            if (literalTypeName(text)) |lit| {
                try self.ctx.errAt(node, "{s} is an integer; `{s}` is {s} `{s}`", .{ what, text, an(lit), lit });
                return null;
            }
            if (std.mem.eql(u8, text, "none")) {
                try self.ctx.errAt(node, "{s} is an integer; `none` is the absent optional", .{what});
                return null;
            }
            const id = self.lookupCt(node) orelse {
                if (isBuiltinTypeName(self.ctx, text)) return self.notAType(node, what);
                try self.ctx.errAt(node, "use of unbound name `{s}`", .{text});
                return null;
            };
            switch (self.ctx.symbols.items[id].kind) {
                .nominal_type, .generic_type, .type_alias, .generic_param => return self.notAType(node, what),
                else => {},
            }
            const sym = self.ctx.symbols.items[id];
            if (sym.flags.comptime_known and sym.kind == .param and !self.isPoison(sym.ty)) {
                try self.ctx.errAt(node, "{s} is an integer; `{s}` is a compile-time `{s}`", .{ what, text, try sema.formatType(self.ctx, sym.ty) });
                return null;
            }
            if (sym.kind == .local and sym.flags.fixed) {
                if (sym.ty == self.ctx.types.unknown_id and sym.scope == sema.module_scope) {
                    // A module constant a signature names, checked later.
                    try self.ctx.errAt(node, "{s} is an integer; `{s}` is not an integer constant", .{ what, text });
                    return null;
                } else if (!self.isPoison(sym.ty) and !sema.isInteger(self.ctx, sym.ty)) {
                    const ty = try sema.formatType(self.ctx, sym.ty);
                    try self.ctx.errAt(node, "{s} is an integer; `{s}` is {s} `{s}`", .{ what, text, an(ty), ty });
                    return null;
                }
            }
        } else if (node.isKind(.member)) {
            if (try self.memberNotCtInt(node, what)) return null;
        } else if (try self.mentionsCtParam(node)) {
            try self.ctx.errAt(node, "{s} `{s}` does arithmetic on a compile-time parameter, which Rig cannot check for overflow or division by zero; use a parameter or a constant", .{ what, text });
            return null;
        } else if (self.dividesByZero(node)) {
            try self.ctx.errAt(node, "{s} `{s}` divides by zero", .{ what, text });
            return null;
        } else if (node.isKind(.call)) {
            try self.ctx.errAt(node, "{s} cannot call a function: `{s}` runs only when the program does", .{ what, text });
            return null;
        }
        try self.ctx.errAt(node, "{s} must be known at compile time; `{s}` is not: use an integer, a constant (`N =! 4`), a compile-time parameter, or arithmetic on them", .{ what, text });
        return null;
    }

    /// Whether `node` is a name that names a type.
    fn namesType(self: *TypeResolver, node: Sexp) bool {
        if (node != .src) return false;
        const name = identAt(self.ctx.source, node) orelse return false;
        for (self.nominal.type_params) |tp| if (std.mem.eql(u8, self.ctx.symbols.items[tp].name, name)) return self.ctx.symbols.items[tp].kind == .generic_param;
        const id = self.ctx.lookupBefore(self.scope, name, node.src.pos) orelse return isBuiltinTypeName(self.ctx, name) or std.mem.eql(u8, name, "Self");
        return switch (self.ctx.symbols.items[id].kind) {
            .nominal_type, .generic_type, .type_alias, .generic_param => true,
            else => false,
        };
    }

    /// Report why `module.NAME` is not a compile-time integer, when that
    /// is something other than its value; false when nothing was reported.
    fn memberNotCtInt(self: *TypeResolver, node: Sexp, what: []const u8) Error!bool {
        const obj = ir.Member.object(node);
        const module_name = identAt(self.ctx.source, obj) orelse return false;
        const mod_id = self.ctx.lookup(self.scope, module_name) orelse {
            try self.ctx.errAt(obj, "use of unbound name `{s}`", .{module_name});
            return true;
        };
        if (self.ctx.symbols.items[mod_id].kind != .module) return false;
        const foreign = self.ctx.foreign_semas.get(self.ctx.module_refs.get(mod_id) orelse return false) orelse return false;
        const name = identAt(self.ctx.source, ir.Member.name(node)) orelse return false;
        const fid = foreign.lookupInScopeOnly(sema.module_scope, name) orelse {
            try self.ctx.errAt(node, "no member `{s}` in module `{s}`", .{ name, module_name });
            return true;
        };
        const fsym = foreign.symbols.items[fid];
        if (!fsym.flags.is_public) {
            try self.ctx.errAt(node, "`{s}.{s}` is not public; mark it `pub` in module `{s}` to expose it across module boundaries", .{ module_name, name, module_name });
            return true;
        }
        switch (fsym.kind) {
            .nominal_type, .generic_type, .type_alias => {
                _ = try self.notAType(node, what);
                return true;
            },
            .local => if (!sema.isInteger(foreign, fsym.ty) and !sema.containsPoison(foreign, fsym.ty)) {
                const ty = try sema.formatTypeIn(foreign, self.ctx.arena.allocator(), fsym.ty);
                try self.ctx.errAt(node, "{s} is an integer; `{s}.{s}` is {s} `{s}`", .{ what, module_name, name, an(ty), ty });
                return true;
            },
            else => {},
        }
        return false;
    }

    fn notAType(self: *TypeResolver, node: Sexp, what: []const u8) Error!?CtInt {
        try self.ctx.errAt(node, "`{s}` is a type; {s} is an integer, a constant, a compile-time parameter, or arithmetic on them", .{ try self.sourceText(node), what });
        return null;
    }

    /// The `ct_param` of the compile-time integer parameter (or `k =! n`
    /// alias of one) a name leaf denotes; null for any other name.
    fn ctParamNamed(self: *TypeResolver, leaf: Sexp) Error!?TypeId {
        const name = identAt(self.ctx.source, leaf) orelse return null;
        for (self.nominal.type_params) |tp| {
            if (!std.mem.eql(u8, self.ctx.symbols.items[tp].name, name)) continue;
            if (self.ctx.symbols.items[tp].kind != .param) return null;
            return try self.ctx.intern(.{ .ct_param = tp });
        }
        const id = self.ctx.lookupBefore(self.scope, name, leaf.src.pos) orelse return null;
        if (self.ctx.ct_locals.get(id)) |ct| return ct;
        const sym = self.ctx.symbols.items[id];
        if (sym.kind != .param or !sym.flags.comptime_known or self.ctx.types.get(sym.ty) != .int) return null;
        return try self.ctx.intern(.{ .ct_param = id });
    }

    /// Record the symbol each name in a compile-time integer names.
    fn recordCtNames(self: *TypeResolver, node: Sexp) Error!void {
        switch (node) {
            .src => {
                const name = identAt(self.ctx.source, node) orelse return;
                for (self.nominal.type_params) |tp| if (std.mem.eql(u8, self.ctx.symbols.items[tp].name, name)) return self.ctx.recordName(node, tp);
                try self.ctx.recordName(node, self.lookupCt(node) orelse return);
            },
            .list => if (node.isKind(.member)) {
                const obj = ir.Member.object(node);
                const id = self.ctx.lookup(self.scope, identAt(self.ctx.source, obj) orelse return) orelse return;
                if (self.ctx.symbols.items[id].kind == .module) try self.ctx.recordName(obj, id);
            } else for (node.items()) |c| try self.recordCtNames(c),
            else => {},
        }
    }

    /// Whether a name in `node` is a compile-time integer parameter.
    fn mentionsCtParam(self: *TypeResolver, node: Sexp) Error!bool {
        switch (node) {
            .src => return (try self.ctParamNamed(node)) != null,
            .list => {
                if (node.isKind(.member)) return false;
                for (node.items()) |c| if (try self.mentionsCtParam(c)) return true;
                return false;
            },
            else => return false,
        }
    }

    /// Whether `node` divides, or takes a remainder, by a constant zero.
    fn dividesByZero(self: *TypeResolver, node: Sexp) bool {
        const h = node.kind() orelse return false;
        if (h == .member) return false;
        if (h == .@"/" or h == .@"%") switch (sema.constIntBy(self.ctx, ir.get(node, .right), self.constNames())) {
            .value => |v| if (v == 0) return true,
            else => {},
        };
        for (node.items()) |c| if (self.dividesByZero(c)) return true;
        return false;
    }

    /// The constants names in a type denote.
    fn constNames(self: *const TypeResolver) ConstNames {
        return .{ .ctx = self.ctx, .scope = self.scope, .type_params = self.nominal.type_params, .before = self.const_before };
    }

    /// The symbol a name leaf in a compile-time integer denotes; a module
    /// constant a constant's declaration names must come before it.
    fn lookupCt(self: *const TypeResolver, leaf: Sexp) ?SymbolId {
        const id = self.ctx.lookupBefore(self.scope, identAt(self.ctx.source, leaf) orelse return null, leaf.src.pos) orelse return null;
        return if (self.constNames().visible(id)) id else null;
    }

    fn sourceText(self: *const TypeResolver, node: Sexp) Error![]const u8 {
        const sp = self.ctx.span(node);
        return self.ctx.source[sp.start..sp.end];
    }

    /// A declaration `module.Name` names in an imported module, or null
    /// after a diagnostic.
    const ForeignDecl = struct { foreign: *SemContext, origin: u32, id: SymbolId, sym: Symbol, module_name: []const u8, name: []const u8, pos: u32 };

    fn foreignDecl(self: *TypeResolver, module_node: Sexp, name_node: Sexp) Error!?ForeignDecl {
        const module_name = identAt(self.ctx.source, module_node) orelse return null;
        const name = identAt(self.ctx.source, name_node) orelse return null;
        const pos = srcPos(name_node, 0);
        const mod_id = self.ctx.lookup(self.scope, module_name) orelse {
            try self.ctx.errAt(module_node, "use of unbound module `{s}`; import it with `use {s}`", .{ module_name, module_name });
            return null;
        };
        if (self.ctx.symbols.items[mod_id].kind != .module) {
            try self.ctx.errAt(module_node, "`{s}` is not a module; a qualified type is written `module.Type`", .{module_name});
            return null;
        }
        try self.ctx.recordName(module_node, mod_id);
        const origin = self.ctx.module_refs.get(mod_id) orelse return null;
        const foreign = self.ctx.foreign_semas.get(origin) orelse return null;
        const fid = foreign.lookupInScopeOnly(sema.module_scope, name) orelse {
            try self.ctx.err(pos, "no type `{s}` in module `{s}`", .{ name, module_name });
            return null;
        };
        return .{ .foreign = foreign, .origin = origin, .id = fid, .sym = foreign.symbols.items[fid], .module_name = module_name, .name = name, .pos = pos };
    }

    /// Whether the declaration `d` names is public; reports it if not.
    fn checkPublic(self: *TypeResolver, d: ForeignDecl) Error!bool {
        if (d.sym.flags.is_public) return true;
        try self.ctx.err(d.pos, "`{s}.{s}` is not public; mark it `pub` in module `{s}` to expose it across module boundaries", .{ d.module_name, d.name, d.module_name });
        return false;
    }

    /// `module.Name`: a public type of an imported module.
    fn resolveQualified(self: *TypeResolver, module_node: Sexp, name_node: Sexp) Error!TypeId {
        const t = &self.ctx.types;
        const d = (try self.foreignDecl(module_node, name_node)) orelse return t.invalid_id;
        switch (d.sym.kind) {
            .nominal_type, .type_alias => {},
            .generic_type => {
                const arity = if (d.sym.type_params) |tps| tps.len else 0;
                try self.ctx.err(d.pos, "generic type `{s}.{s}` requires type arguments; write `{s}.{s}[{s}]`", .{ d.module_name, d.name, d.module_name, d.name, if (arity > 1) "T, ..." else "T" });
                return t.invalid_id;
            },
            else => {
                try self.ctx.err(d.pos, "`{s}.{s}` is not a type", .{ d.module_name, d.name });
                return t.invalid_id;
            },
        }
        if (!try self.checkPublic(d)) return t.invalid_id;
        if (d.sym.kind == .type_alias) return sema.importType(self.ctx, d.foreign, d.sym.ty, d.origin);
        return self.ctx.intern(.{ .imported_nominal = .{ .module_id = d.origin, .sym_id = d.id } });
    }

    /// `module.Box` in `module.Box[Int]`: the proxy of a public generic
    /// type of an imported module (`sema.proxyOf`).
    fn qualifiedGeneric(self: *TypeResolver, member: Sexp) Error!?SymbolId {
        const d = (try self.foreignDecl(ir.Member.object(member), ir.Member.name(member))) orelse return null;
        switch (d.sym.kind) {
            .generic_type => {},
            .nominal_type, .type_alias => {
                try self.ctx.err(d.pos, "`{s}.{s}` is not a generic type; it takes no type arguments", .{ d.module_name, d.name });
                return null;
            },
            else => {
                try self.ctx.err(d.pos, "`{s}.{s}` is not a type", .{ d.module_name, d.name });
                return null;
            },
        }
        if (!try self.checkPublic(d)) return null;
        return try sema.proxyOf(self.ctx, .{ .module_id = d.origin, .sym = d.id });
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
        var sym_id: SymbolId = undefined;
        var pos: u32 = undefined;
        if (name_node.isKind(.member)) {
            // `lib.Box[Int]`: another module's generic type.
            sym_id = (try self.qualifiedGeneric(name_node)) orelse return t.invalid_id;
            pos = srcPos(ir.Member.name(name_node), 0);
        } else {
            const name = identAt(self.ctx.source, name_node).?;
            pos = name_node.src.pos;
            sym_id = self.ctx.lookup(self.scope, name) orelse {
                try self.ctx.err(pos, "use of unbound type `{s}`", .{name});
                return t.invalid_id;
            };
            try self.ctx.recordName(name_node, sym_id);
            if (self.ctx.symbols.items[sym_id].kind != .generic_type) {
                try self.ctx.err(pos, "`{s}` is not a generic type", .{name});
                return t.invalid_id;
            }
        }
        const sym = self.ctx.symbols.items[sym_id];
        const name = sym.name;
        const tparams = sym.type_params orelse &.{};
        const supplied = ir.GenericInst.args(sexp);
        if (supplied.len != tparams.len) {
            try self.ctx.err(pos, "generic type `{s}` expects {d} {s} argument{s}, got {d}", .{ name, tparams.len, argsNoun(self.ctx, tparams), if (tparams.len == 1) @as([]const u8, "") else "s", supplied.len });
            return t.invalid_id;
        }
        var args: std.ArrayListUnmanaged(TypeId) = .empty;
        defer args.deinit(self.ctx.allocator);
        var any_bad = false;
        for (supplied, tparams, 0..) |a, tp, i| {
            const arg = if (self.ctx.symbols.items[tp].kind == .param)
                try self.resolveCtInt(a, .{ .arg = .{ .param = tp, .owner = name, .index = i } })
            else if (isValueSpelling(self.ctx.source, a)) blk: {
                try self.ctx.errAt(a, "`{s}` is a value; `{s}` takes a type", .{ try self.sourceText(a), self.ctx.symbols.items[tp].name });
                break :blk t.invalid_id;
            } else try self.resolveType(a);
            if (sema.containsPoison(self.ctx, arg)) any_bad = true;
            try args.append(self.ctx.allocator, arg);
        }
        // An instance with a rejected argument is poison: what follows
        // from it was already reported.
        if (any_bad) return t.invalid_id;
        const ty = try self.ctx.internCopy(.{ .parameterized_nominal = .{ .sym = sym_id, .args = args.items } });
        const inst = self.ctx.types.get(ty).parameterized_nominal;
        if (sym.decl_pos == sema.builtin_decl_pos) {
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

/// A type a compile-time argument can have: one written as a literal,
/// an enum value, or `none`.
fn isCtValueType(ctx: *const SemContext, ty: TypeId) bool {
    if (ty == ctx.types.invalid_id or ty == ctx.types.unknown_id) return true;
    return switch (ctx.types.get(ty)) {
        .optional => |inner| isCtValueType(ctx, inner),
        else => sema.isCopyPrimitive(ctx, ty) or sema.isPlainEnum(ctx, ty),
    };
}
