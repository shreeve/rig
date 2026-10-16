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
const diag = @import("diag.zig");
const sema = @import("sema.zig");
const Wide = sema.Wide;

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
    defer r.pending_shadows.deinit(ctx.allocator);
    try r.walk(tree);
    // Module-level names are visible throughout the module, so the
    // clash with them is judged once all are declared.
    // Each lands where the walk met it, so diagnostics stay in the
    // order a one-pass check would give.
    var inserted: usize = 0;
    for (r.pending_shadows.items) |p| {
        const start = ctx.diagnostics.items.len;
        try r.reportShadowsDeclaration(p.name_node, p.what);
        const n = ctx.diagnostics.items.len - start;
        if (n == 0) continue;
        const group = try ctx.allocator.dupe(sema.Diagnostic, ctx.diagnostics.items[start..]);
        defer ctx.allocator.free(group);
        ctx.diagnostics.shrinkRetainingCapacity(start);
        try ctx.diagnostics.insertSlice(ctx.allocator, p.at + inserted, group);
        inserted += n;
    }
}

const SymbolResolver = struct {
    ctx: *SemContext,
    scope: ScopeId,
    module_scope: ScopeId,
    /// The generic parameters of the generic type whose members are
    /// being walked.
    type_params: []const SymbolId = &.{},
    /// Parameters and locals whose clash with a module-level
    /// declaration is checked after the whole module is walked.
    pending_shadows: std.ArrayList(PendingShadow) = .empty,

    const PendingShadow = struct { name_node: Sexp, what: []const u8, at: usize };

    fn walk(self: *SymbolResolver, sexp: Sexp) Error!void {
        switch (sexp.kind() orelse return) {
            .module => {
                // A file's `use`s name its modules everywhere in it.
                for (ir.Module.decls(sexp)) |c| if (c.isKind(.use)) try self.walk(c);
                for (ir.Module.decls(sexp)) |c| if (rig.isModuleConst(c)) try self.walk(c);
                for (ir.Module.decls(sexp)) |c| if (!rig.isModuleConst(c) and !c.isKind(.use)) try self.walk(c);
            },
            .@"pub" => {
                const decl = ir.Pub.decl(sexp);
                try self.walk(decl);
                // The symbol the declaration's name leaf names: a module
                // constant's value is walked before its name is declared.
                const kind = decl.kind() orelse return;
                const name = if (kind == .set) ir.Set.target(decl) else if (ir.has(kind, .name)) ir.get(decl, .name) else return;
                if (self.ctx.symbolOf(name)) |id| self.ctx.symbols.items[id].flags.is_public = true;
            },
            .fun, .sub => {
                const marked = rig.markerOf(sexp) == .@"inline";
                const id = try self.declare(ir.get(sexp, .name), .function, .{ .inline_marked = marked });
                if (id) |sym| {
                    try self.checkMarker(sexp, self.ctx.symbols.items[sym]);
                    if (marked and self.scope == sema.module_scope) try self.ctx.inline_decls.put(self.ctx.allocator, self.ctx.symbols.items[sym].decl_pos, sexp);
                }
                try self.walkFun(sexp);
            },
            .lambda => try self.walkLambda(sexp),
            .use => try self.walkUse(sexp),
            .type => try self.walkTypeAlias(sexp),
            .generic_struct, .generic_enum => try self.walkGenericType(sexp),
            .@"struct" => try self.walkNominalType(sexp, .{ .unique = ir.Struct.unique(sexp) != .nil }),
            .@"enum" => try self.walkNominalType(sexp, .{}),
            .errors => try self.walkNominalType(sexp, .{ .error_set = true }),
            .@"extern", .extern_fun, .extern_sub => {
                const name_node = ir.get(sexp, .name);
                _ = try self.declare(name_node, .@"extern", .{});
                try self.checkExternName(name_node);
            },
            // A Zig-backed constant: known at compile time, to Zig alone.
            .zig_const => _ = try self.declare(ir.ZigConst.name(sexp), .local, .{ .fixed = true, .comptime_known = true, .per_target = true }),
            .zig_extern => {
                if (!self.ctx.is_std) try self.ctx.errAt(sexp, "only the standard library binds declarations to Zig code with `extern zig`; write the function in Rig, or declare a C function with `extern fun` and call it in a `raw` block", .{});
                for (ir.ZigExtern.decls(sexp)) |d| {
                    const f = if (d.isKind(.@"pub")) ir.Pub.decl(d) else d;
                    // A Zig-backed constant takes no marker, and has no role for one.
                    const m: rig.Marker = if (f.isKind(.fun) or f.isKind(.sub)) rig.markerOf(f) else .none;
                    if (m != .none) try self.ctx.errAt(ir.get(f, .mark), "`{s}` is an `extern zig` function, whose body is Zig code: it takes no `{s}`", .{ identAt(self.ctx.source, ir.get(f, .name)) orelse "", @tagName(m) });
                    try self.walk(d);
                }
            },
            .@"test" => try self.walkTest(sexp),
            .set => try self.walkSet(sexp),
            // `q, r = f()`: the value first, then each target's binding,
            // left to right (`(set op q _ (result_part))`).
            .destructure => {
                try self.walk(ir.Destructure.value(sexp));
                for (ir.Destructure.targets(sexp).items()) |t| try self.walk(t);
            },
            .block => {
                const prev = try self.enter(sexp, .block);
                defer self.scope = prev;
                for (ir.Block.stmts(sexp)) |c| try self.walk(c);
            },
            .@"for" => try self.walkFor(sexp),
            .@"if" => try self.walkConditional(ir.If.cond(sexp), &.{ir.If.then(sexp)}, ir.If.@"else"(sexp)),
            .write => {
                try self.markWritten(sexp, ir.Write.operand(sexp), .lend_write);
                try self.walk(ir.Write.operand(sexp));
            },
            .@"while" => try self.walkConditional(ir.While.cond(sexp), &.{ ir.While.step(sexp), ir.While.body(sexp) }, ir.While.@"else"(sexp)),
            .arm => try self.walkArm(sexp),
            .@"catch" => try self.walkCatch(sexp),
            else => for (rig.children(sexp)) |c| try self.walk(c),
        }
    }

    /// A marker the declaration cannot take: the program's `main`, which
    /// only the program calls, once, takes none.
    fn checkMarker(self: *SymbolResolver, node: Sexp, sym: sema.Symbol) Error!void {
        const m = rig.markerOf(node);
        if (m == .none) return;
        if (self.ctx.is_root and sym.scope == sema.module_scope and std.mem.eql(u8, sym.name, "main")) {
            try self.ctx.errAt(ir.get(node, .mark), "`main` is the program's entry point, which the program calls once: it takes no `{s}`", .{@tagName(m)});
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
        // `String` and `Static` are built-in types, like `List`, though no
        // symbol holds them.
        const reserved = self.scope == self.module_scope and (std.mem.eql(u8, name, "String") or std.mem.eql(u8, name, "Static"));
        if (reserved) try self.ctx.err(pos, "`{s}` is a reserved built-in nominal name and cannot be redefined", .{name});
        if (dup) |prev| {
            const p = self.ctx.symbols.items[prev];
            if (p.decl_pos == sema.builtin_decl_pos) {
                try self.ctx.err(pos, "`{s}` is a reserved built-in nominal name and cannot be redefined", .{name});
            } else if (kind == .module and p.kind == .module) {
                try self.ctx.err(pos, "two imports bind the name `{s}`; name one of them with `as`: `use ... as other`", .{name});
                try self.ctx.note(p.decl_pos, "`{s}` first imported here", .{name});
            } else {
                try self.ctx.err(pos, "duplicate declaration of `{s}`", .{name});
                try self.ctx.note(p.decl_pos, "`{s}` first declared here", .{name});
            }
        }
        const id = try self.ctx.addSymbol(sym);
        // A duplicate is still resolved and checked, under a symbol no
        // name reaches, so errors inside it are reported too.
        if (dup == null and !reserved) try self.ctx.addToScope(self.scope, id);
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
        if (self.ctx.fileModule(name, srcPos(name_node, 0))) |module| return self.shadowsModule(name_node, what, module);
        try self.pending_shadows.append(self.ctx.allocator, .{ .name_node = name_node, .what = what, .at = self.ctx.diagnostics.items.len });
    }

    fn reportShadowsDeclaration(self: *SymbolResolver, name_node: Sexp, what: []const u8) Error!void {
        const name = identAt(self.ctx.source, name_node) orelse return;
        const decl = self.ctx.lookupInScopeOnly(self.module_scope, name) orelse return;
        const sym = self.ctx.symbols.items[decl];
        if (sym.decl_pos == sema.builtin_decl_pos) return;
        try self.ctx.errAt(name_node, "{s} `{s}` has the same name as the module-level declaration `{s}`; use a different name", .{ what, name, name });
        try self.ctx.note(sym.decl_pos, "`{s}` declared here", .{name});
    }

    /// A parameter or local named like a module its file uses. A
    /// parameter can take the name only if the module is imported under
    /// another; a local can also hide the module with `new`.
    fn shadowsModule(self: *SymbolResolver, name_node: Sexp, what: []const u8, module: SymbolId) Error!void {
        const name = identAt(self.ctx.source, name_node).?;
        const decl = for (self.ctx.file_uses.items) |u| {
            if (u.sym == module) break u.decl;
        } else unreachable;
        const path = if (self.ctx.parser) |p| diag.textOf(self.ctx.source, p.span(ir.Use.name(decl))) else name;
        const other: []const u8 = if (name.len > 1) name[0..1] else "m";
        if (std.mem.find(u8, what, "parameter") != null) {
            try self.ctx.errAt(name_node, "{s} `{s}` has the name of the module this file uses as `{s}`; import the module under another name, `use {s} as {s}`", .{ what, name, name, path, other });
        } else try self.ctx.errAt(name_node, "{s} `{s}` has the name of the module this file uses as `{s}`; import the module under another name, `use {s} as {s}`, or write `new {s} = ...`, which hides the module `{s}` for the rest of this scope", .{ what, name, name, path, other, name, name });
        try self.ctx.note(self.ctx.symbols.items[module].decl_pos, "`{s}` imported here", .{name});
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
            // `|!x|` writes the binding it captures, as `!x` does.
            if (cap.isKind(.cap_write)) try self.markWritten(cap, name_node, .capture);
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
            _ = try self.declare(name_node, .param, .{ .comptime_known = ct });
        }
    }

    /// A lambda's parameters live in the closure's own function, which
    /// Zig nests inside the enclosing one: they may not reuse its locals.
    fn checkShadowingThroughLambda(self: *SymbolResolver, name_node: Sexp) Error!void {
        const name = identAt(self.ctx.source, name_node) orelse return;
        const parent = self.ctx.scopes.items[self.scope].parent orelse return;
        if (self.visibleLocal(parent, name)) |prev| {
            try self.ctx.errAt(name_node, "closure parameter `{s}` has the name of the local `{s}`; to capture the local, give it a sigil (`|+{s}|` copies or clones it, `|<{s}|` moves it, `|?{s}|` or `|!{s}|` lends it, `|~{s}|` holds it weakly), or name the parameter differently", .{ name, name, name, name, name, name, name });
            try self.ctx.note(self.ctx.symbols.items[prev].decl_pos, "`{s}` declared here", .{name});
            return;
        }
        try self.checkShadowsDeclaration(name_node, "parameter");
    }

    /// Reports a C declaration whose name the emitted Zig cannot keep
    /// (`rig.zigRenames`: `std`, `rig`, `panic`, `debug`, `__rig*`):
    /// the linker finds a C name only as it is spelled.
    fn checkExternName(self: *SymbolResolver, name_node: Sexp) Error!void {
        const name = identAt(self.ctx.source, name_node) orelse return;
        if (!rig.zigRenames(name)) return;
        try self.ctx.err(srcPos(name_node, 0), "a C declaration cannot be named `{s}`: the Zig that Rig writes uses that name itself, and C links a name only as it is spelled", .{name});
    }

    /// `use NAME`, `use a.b.NAME`, or either `as ALIAS`: the module's
    /// symbol is named by the alias, else the path's last name. It binds
    /// that name in its own file only (`SemContext.fileModule`), so it is
    /// in no scope; two `use`s of one file may not bind one name.
    fn walkUse(self: *SymbolResolver, node: Sexp) Error!void {
        const path = ir.Use.name(node);
        const alias = ir.Use.alias(node);
        const name_node = if (alias != .nil) alias else if (path.isKind(.member)) ir.Member.name(path) else path;
        const name = identAt(self.ctx.source, name_node) orelse return;
        const pos = srcPos(name_node, 0);
        const file = sema.fileIndex(self.ctx.parts, pos);
        // As for any binding (`declare`): `none` is the absent optional.
        if (std.mem.eql(u8, name, "none")) try self.ctx.err(pos, "`none` is the absent optional and cannot name a module; name it with `as`: `use ... as other`", .{});
        if (self.ctx.fileModule(name, pos)) |prev| {
            try self.ctx.err(pos, "two imports bind the name `{s}`; name one of them with `as`: `use ... as other`", .{name});
            try self.ctx.note(self.ctx.symbols.items[prev].decl_pos, "`{s}` first imported here", .{name});
            return;
        }
        // The module this file's `use` names.
        const target = for (self.ctx.imports) |imp| {
            if (std.mem.eql(u8, imp.local_name, name) and imp.file == file) break imp.module_id;
        } else null;
        const id = try self.ctx.addSymbol(.{
            .name = name,
            .kind = .module,
            .ty = self.ctx.types.unknown_id,
            .decl_pos = pos,
            .scope = self.module_scope,
        });
        try self.ctx.recordName(name_node, id);
        if (target) |t| try self.ctx.module_refs.put(self.ctx.allocator, id, t);
        try self.ctx.file_uses.append(self.ctx.allocator, .{ .file = file, .sym = id, .decl = node });
    }

    fn walkTypeAlias(self: *SymbolResolver, node: Sexp) Error!void {
        const id = (try self.declare(ir.Type.name(node), .type_alias, .{})) orelse return;
        try self.ctx.alias_targets.put(self.ctx.allocator, id, ir.Type.type(node));
    }

    /// A `generic_struct` or `generic_enum`.
    fn walkGenericType(self: *SymbolResolver, node: Sexp) Error!void {
        const name_node = ir.get(node, .name);
        const unique = node.isKind(.generic_struct) and ir.GenericStruct.unique(node) != .nil;
        const id = (try self.declare(name_node, .generic_type, .{ .unique = unique })) orelse return;
        const name = self.ctx.symbols.items[id].name;
        const params = ir.get(node, .tparams);
        var ids: std.ArrayList(SymbolId) = .empty;
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
            try self.markWritten(node, target, .elem_store);
            try self.walk(target);
            return;
        }
        // `_ = expr` discards the value; it binds nothing.
        if (std.mem.eql(u8, identAt(self.ctx.source, target).?, "_")) return;
        switch (kind) {
            .default => {
                if (self.assignable(identAt(self.ctx.source, target).?)) |existing| {
                    try self.ctx.recordName(target, existing);
                    try self.ctx.recordWrite(node, existing, .assign);
                    return;
                }
                try self.checkNewLocal(target);
                _ = try self.declare(target, .local, .{ .closure = ir.Set.value(node).isKind(.lambda) });
            },
            .fixed => {
                if (self.scope != self.module_scope and !rig.shadows(ir.Set.op(node))) {
                    if (self.visibleLocal(self.scope, identAt(self.ctx.source, target).?)) |prev| {
                        const name = self.ctx.symbols.items[prev].name;
                        try self.ctx.errAt(target, "`{s}` is already bound; `=!` declares a new binding. Assign with `{s} = ...` or shadow with `new {s} =! ...`", .{ name, name, name });
                        try self.ctx.note(self.ctx.symbols.items[prev].decl_pos, "`{s}` declared here", .{name});
                        try self.ctx.recordName(target, prev);
                        return;
                    }
                }
                try self.checkNewLocal(target);
                _ = try self.declare(target, .local, .{ .fixed = true, .closure = ir.Set.value(node).isKind(.lambda) });
            },
            .shadow => _ = try self.declare(target, .local, .{ .closure = ir.Set.value(node).isKind(.lambda) }),
            .@"+=", .@"-=", .@"*=", .@"/=", .@"%=", .@"+%=", .@"-%=", .@"*%=", .@"+|=", .@"-|=", .@"&=", .@"|=", .@"^=", .@"<<=", .@"<<%=", .@">>=" => {
                if (self.assignable(identAt(self.ctx.source, target).?)) |existing| {
                    try self.ctx.recordWrite(node, existing, .compound);
                } else if (self.scope == self.module_scope) {
                    // A module-level `K += 1` declares nothing it could
                    // update; the checker rejects it, and `K` is bound so
                    // its uses report nothing more.
                    _ = try self.declare(target, .local, .{ .fixed = true });
                }
            },
        }
    }

    /// `!x`, `!x.f`, and assignments to `x.f` / `x[i]` write the binding
    /// `x` is: it cannot be a constant. `node` is the site that writes it
    /// (`SemContext.recordWrite`).
    fn markWritten(self: *SymbolResolver, node: Sexp, place: Sexp, kind: sema.WriteKind) Error!void {
        var p = place;
        while (p.kind()) |h| {
            if (h != .member and h != .index) return;
            p = ir.get(p, .object);
        }
        const name = identAt(self.ctx.source, p) orelse return;
        const id = self.ctx.lookup(self.scope, name) orelse return;
        try self.ctx.recordWrite(node, id, kind);
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
        if (ir.For.mode(node).tag == .write) try self.markWritten(node, ir.For.source(node), .lend_write);
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

    /// An `if` / `while`. Each `(as expr name)` in the condition opens a
    /// scope binding `name` over the parts of the condition after it and
    /// `bodies` (the branch or loop body the value is present in);
    /// `else_` is outside them.
    fn walkConditional(self: *SymbolResolver, cond: Sexp, bodies: []const Sexp, else_: Sexp) Error!void {
        if (rig.bindsInCondition(cond)) {
            const prev = self.scope;
            defer self.scope = prev;
            try self.walkConditionParts(cond);
            for (bodies) |b| try self.walk(b);
        } else {
            try self.walk(cond);
            for (bodies) |b| try self.walk(b);
        }
        try self.walk(else_);
    }

    /// The parts of a binding condition, in order; each `as` enters the
    /// scope of its binding, which the caller leaves.
    fn walkConditionParts(self: *SymbolResolver, cond: Sexp) Error!void {
        try rig.eachGuardPart(cond, self);
    }

    /// One part of a binding condition (`rig.eachGuardPart`).
    pub fn part(self: *SymbolResolver, p: Sexp) Error!void {
        if (p.isKind(.as_results)) {
            try self.walk(ir.AsResults.value(p));
            _ = try self.enter(p, .block);
            for (ir.AsResults.names(p).items()) |n| {
                try self.walk(n);
                if (!n.isKind(.set)) continue;
                if (self.ctx.symbolOf(ir.Set.target(n))) |id| self.ctx.symbols.items[id].flags.as_bound = true;
            }
            return;
        }
        if (!p.isKind(.as)) return self.walk(p);
        try self.walk(ir.As.value(p));
        _ = try self.enter(p, .block);
        if (try self.bindFresh(ir.As.name(p), "optional binding")) |id| self.ctx.symbols.items[id].flags.as_bound = true;
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
        // Alternatives bind no names (the checker rejects them); a name
        // is still bound once, for its uses.
        if (pattern.isKind(.alt_pattern)) {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(self.ctx.allocator);
            for (ir.AltPattern.alts(pattern)) |alt| {
                const binds: []const Sexp = if (alt.isKind(.variant_pattern)) ir.VariantPattern.bindings(alt) else if (patternBinds(self.ctx.source, alt)) (&alt)[0..1] else &.{};
                for (binds) |bound| {
                    const b = sema.bindingName(bound);
                    const name = identAt(self.ctx.source, b) orelse continue;
                    if ((try seen.getOrPut(self.ctx.allocator, name)).found_existing) continue;
                    _ = try self.bindFresh(b, "pattern binding");
                }
            }
        }
        switch (pattern) {
            .src => if (patternBinds(self.ctx.source, pattern)) {
                _ = try self.bindFresh(pattern, "pattern binding");
            },
            .list => if (pattern.isKind(.variant_pattern)) {
                for (ir.VariantPattern.bindings(pattern)) |b| _ = try self.bindFresh(sema.bindingName(b), "pattern binding");
            },
            else => {},
        }
        // A guard sees the pattern's bindings.
        try self.walk(ir.Arm.guard(node));
        try self.walk(ir.Arm.body(node));
    }
};

// =============================================================================
// Declaration types
// =============================================================================

pub fn resolveDeclarations(ctx: *SemContext, tree: Sexp, module_scope: ScopeId) Error!void {
    if (!tree.isKind(.module)) return;
    try checkDetachedMethods(ctx, tree);
    try checkUseNames(ctx);
    try orderModuleConsts(ctx, tree);
    try foldModuleConsts(ctx);
    var tr: TypeResolver = .{ .ctx = ctx, .scope = module_scope };
    for (ir.Module.decls(tree)) |decl| {
        if ((if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl).isKind(.errors)) tr.declares_errors = true;
    }
    for (ir.Module.decls(tree)) |decl| try tr.resolveDecl(decl);
}

/// A `use` may not bind the name of a declaration of its module, which
/// its file sees too.
fn checkUseNames(ctx: *SemContext) Error!void {
    for (ctx.file_uses.items) |u| {
        const sym = ctx.symbols.items[u.sym];
        const decl = ctx.lookupInScopeOnly(sema.module_scope, sym.name) orelse continue;
        const d = ctx.symbols.items[decl];
        if (d.decl_pos == sema.builtin_decl_pos) continue;
        try ctx.err(sym.decl_pos, "`{s}` is a declaration of this module; import the module under another name: `use ... as other`", .{sym.name});
        try ctx.note(d.decl_pos, "`{s}` declared here", .{sym.name});
    }
}

/// Why each method declared outside a body names no type it can join
/// (`Parser.attachMethods` attached every one that does): a method is a
/// member of an `obj` or `enum` of its own module, named with the
/// type's parameters as its declaration names them.
fn checkDetachedMethods(ctx: *SemContext, tree: Sexp) Error!void {
    const p = ctx.parser orelse return;
    const src = ctx.source;
    for (p.detached.items) |decl| {
        const def = if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
        const owner = ir.get(def, .owner);
        const name = identAt(src, ir.get(def, .name)) orelse "";
        const kw = if (def.isKind(.sub)) "sub" else "fun";
        if (owner.isKind(.member)) {
            const shown = diag.textOf(src, p.span(owner));
            const module = identAt(src, ir.Member.object(owner)) orelse shown;
            try ctx.errAt(owner, "methods of `{s}` are declared in module `{s}`, which declares the type", .{ shown, module });
            continue;
        }
        const tname = identAt(src, owner) orelse continue;
        const id = ctx.lookupInScopeOnly(sema.module_scope, tname);
        const sym = if (id) |i| ctx.symbols.items[i] else null;
        if (sym != null and sym.?.kind == .type_alias) {
            const target = ctx.alias_targets.get(id.?).?;
            const shown = diag.textOf(src, p.span(target));
            const plain = target == .src and declaredType(src, tree, shown) != null;
            if (plain) {
                try ctx.errAt(owner, "`{s}` is an alias of `{s}`; declare the method as `{s} {s}.{s}`", .{ tname, shown, kw, shown, name });
            } else try ctx.errAt(owner, "`{s}` is an alias of `{s}`; a method is declared on an `obj` or `enum` of this module", .{ tname, shown });
            continue;
        }
        if ((sym != null and sym.?.decl_pos == sema.builtin_decl_pos) or isBuiltinTypeName(ctx, tname) or std.mem.eql(u8, tname, "String") or std.mem.eql(u8, tname, "Static")) {
            try ctx.errAt(owner, "`{s}` is a built-in type; a method is declared on a type of this module", .{tname});
            continue;
        }
        const ty = declaredType(src, tree, tname) orelse {
            try ctx.errAt(owner, "`{s}` names no type declared in this module", .{tname});
            continue;
        };
        if (ty.isKind(.errors)) {
            try ctx.errAt(owner, "`{s}` is an error set; a method is declared on an `obj` or `enum`", .{tname});
            continue;
        }
        // The type is this module's: the parameters are named otherwise.
        const keyword = if (ty.isKind(.@"enum") or ty.isKind(.generic_enum)) "enum" else "obj";
        const tparams = rig.Parser.tparamsOf(ty);
        if (tparams == .nil) {
            try ctx.errAt(owner, "write `{s} {s}.{s}`: `{s} {s}` takes no compile-time parameters", .{ kw, tname, name, keyword, tname });
            continue;
        }
        var names: std.ArrayList(u8) = .empty;
        for (tparams.items(), 0..) |tp, i| {
            if (i > 0) try names.appendSlice(ctx.arena.allocator(), ", ");
            try names.appendSlice(ctx.arena.allocator(), sema.paramName(src, tp) orelse "_");
        }
        const params = names.items;
        try ctx.errAt(owner, "write `{s} {s}[{s}].{s}`: a method names its type's parameters as `{s} {s}[{s}]` declares them", .{ kw, tname, params, name, keyword, tname, params });
    }
}

/// The `obj`, `enum`, or error set this module declares as `name`.
fn declaredType(src: []const u8, tree: Sexp, name: []const u8) ?Sexp {
    for (ir.Module.decls(tree)) |decl| {
        const d = if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
        switch (d.kind() orelse continue) {
            .@"struct", .@"enum", .errors, .generic_struct, .generic_enum => {},
            else => continue,
        }
        if (std.mem.eql(u8, identAt(src, ir.get(d, .name)) orelse "", name)) return d;
    }
    return null;
}

/// Order the module constants so that each comes after the constants
/// its value and its type name (`SemContext.const_order`): a constant
/// may name any constant of its module, wherever it is declared, and
/// one that depends on itself is rejected and left out. A module-level
/// binding that is no constant (`k += 1`) comes last, for the checker
/// to reject.
fn orderModuleConsts(ctx: *SemContext, tree: Sexp) Error!void {
    const a = ctx.allocator;
    var consts: std.ArrayList(Sexp) = .empty;
    defer consts.deinit(a);
    var index: std.AutoHashMapUnmanaged(SymbolId, u32) = .empty;
    defer index.deinit(a);
    var rest: std.ArrayList(Sexp) = .empty;
    defer rest.deinit(a);
    for (ir.Module.decls(tree)) |decl| {
        if (!rig.isModuleConst(decl)) continue;
        const set = if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
        const target = ir.Set.target(set);
        const id = if (target == .src and rig.bindingKindOf(ir.Set.op(set)) == .fixed) ctx.symbolOf(target) else null;
        if (id == null or index.contains(id.?)) {
            try rest.append(a, decl);
            continue;
        }
        try index.put(a, id.?, @intCast(consts.items.len));
        try consts.append(a, decl);
    }
    // What each constant names: `deps[starts[i]..starts[i + 1]]`.
    var deps: std.ArrayList(u32) = .empty;
    defer deps.deinit(a);
    const starts = try a.alloc(u32, consts.items.len + 1);
    defer a.free(starts);
    for (consts.items, 0..) |decl, i| {
        starts[i] = @intCast(deps.items.len);
        const set = if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
        try constNamesIn(ctx, ir.Set.value(set), &index, &deps);
        try constNamesIn(ctx, ir.Set.type(set), &index, &deps);
    }
    starts[consts.items.len] = @intCast(deps.items.len);

    // Depth first, with an explicit stack, so a long chain fits.
    const State = enum(u2) { new, open, done };
    const state = try a.alloc(State, consts.items.len);
    defer a.free(state);
    @memset(state, .new);
    const cyclic = try a.alloc(bool, consts.items.len);
    defer a.free(cyclic);
    @memset(cyclic, false);
    const Frame = struct { i: u32, next: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(a);
    ctx.const_order.clearRetainingCapacity();
    for (0..consts.items.len) |root| {
        if (state[root] != .new) continue;
        state[root] = .open;
        try stack.append(a, .{ .i = @intCast(root), .next = starts[root] });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next < starts[top.i + 1]) {
                const j = deps.items[top.next];
                top.next += 1;
                switch (state[j]) {
                    .new => {
                        state[j] = .open;
                        try stack.append(a, .{ .i = j, .next = starts[j] });
                    },
                    .open => if (!cyclic[j]) try reportConstCycle(ctx, consts.items, stack.items, j, cyclic),
                    .done => {},
                }
                continue;
            }
            const done = stack.pop().?;
            state[done.i] = .done;
            if (!cyclic[done.i]) try ctx.const_order.append(a, consts.items[done.i]);
        }
    }
    try ctx.const_order.appendSlice(a, rest.items);
}

/// Each constant of `index` that a name leaf in `node` names, appended
/// to `out`: a member's name, a keyword argument's, and an enum literal's
/// name no constant of this module.
fn constNamesIn(ctx: *const SemContext, node: Sexp, index: *const std.AutoHashMapUnmanaged(SymbolId, u32), out: *std.ArrayList(u32)) Error!void {
    switch (node) {
        .src => {
            const text = identAt(ctx.source, node) orelse return;
            const id = ctx.lookupInScopeOnly(sema.module_scope, text) orelse return;
            if (index.get(id)) |i| try out.append(ctx.allocator, i);
        },
        .list => switch (node.kind() orelse return) {
            .member => try constNamesIn(ctx, ir.Member.object(node), index, out),
            .kwarg => try constNamesIn(ctx, ir.Kwarg.value(node), index, out),
            .enum_lit, .builtin => for (rig.children(node)[1..]) |c| try constNamesIn(ctx, c, index, out),
            else => for (rig.children(node)) |c| try constNamesIn(ctx, c, index, out),
        },
        else => {},
    }
}

/// The constants open on `stack` from `j` on name each other in a
/// cycle back to `j`: reported once, at `j`'s value, and each left out.
fn reportConstCycle(ctx: *SemContext, consts: []const Sexp, stack: anytype, j: u32, cyclic: []bool) Error!void {
    const a = ctx.arena.allocator();
    var from: usize = stack.len;
    while (from > 0 and stack[from - 1].i != j) from -= 1;
    from -|= 1;
    var path: std.ArrayList(u8) = .empty;
    for (stack[from..]) |f| {
        cyclic[f.i] = true;
        try path.print(a, "`{s}` → ", .{constName(ctx, consts[f.i])});
        const set = if (consts[f.i].isKind(.@"pub")) ir.Pub.decl(consts[f.i]) else consts[f.i];
        if (ctx.symbolOf(ir.Set.target(set))) |id| ctx.symbols.items[id].ty = ctx.types.invalid_id;
    }
    try path.print(a, "`{s}`", .{constName(ctx, consts[j])});
    const set = if (consts[j].isKind(.@"pub")) ir.Pub.decl(consts[j]) else consts[j];
    try ctx.errAt(ir.Set.value(set), "constant `{s}` depends on itself ({s})", .{ constName(ctx, consts[j]), path.items });
}

fn constName(ctx: *const SemContext, decl: Sexp) []const u8 {
    const set = if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
    return identAt(ctx.source, ir.Set.target(set)) orelse "_";
}

/// Fold each integer module constant once, in dependency order
/// (`orderModuleConsts`), into `const_ints`, so any type in the module
/// can name it. Its literals take its declared type (`Int` without
/// one), as a local constant's do; one that does not fold, or does not
/// fit its type, is left for the checker to report.
fn foldModuleConsts(ctx: *SemContext) Error!void {
    for (ctx.const_order.items) |decl| {
        const set = if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
        const target = ir.Set.target(set);
        if (target != .src or rig.bindingKindOf(ir.Set.op(set)) != .fixed) continue;
        const id = ctx.symbolOf(target) orelse continue;
        // A constant whose value names one the target sets is set by the
        // target too, and has no value Rig knows.
        if (sema.perTargetLeaf(ctx, ir.Set.value(set)) != null) {
            ctx.symbols.items[id].flags.per_target = true;
            continue;
        }
        const ty = ir.Set.type(set);
        const declared: ?sema.IntInfo = if (ty == .nil) null else declaredIntType(ctx, ty) orelse continue;
        const names: ConstNames = .{ .ctx = ctx, .scope = sema.module_scope, .literal = declared orelse .{} };
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
    const name = identAt(ctx.source, node) orelse return null;
    if (sema.intTypeNamed(name)) |i| return i;
    return sema.aliasIntType(ctx, ctx.lookupInScopeOnly(sema.module_scope, name) orelse return null);
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
    /// `List[T]`, `^T`, `Cell[T]`, or `Signal[T]` spelled at `pos`.
    builtin: struct { pos: u32, sym: SymbolId, args: []const TypeId },
    /// An instance of a generic type the program declares, spelled at
    /// `pos`: none of its fields or methods may stack two holdings.
    instance_stacking: struct { pos: u32, ty: TypeId },
    /// `*fun(...) -> R`, with the function type spelled at `node`.
    /// A type spelled at `node` that stands at `home`, where a value
    /// holding a Cell may not (`sema.misplaced`).
    cell_home: struct { node: Sexp, ty: TypeId, home: sema.Home },
};

fn runCheck(ctx: *SemContext, check: DeferredCheck) Error!void {
    switch (check) {
        .array => |c| {
            if (c.ty) |ty| if (!try sema.checkArrayBytes(ctx, ctx.startOf(c.at), ty)) return;
            // `[N]T` in a generic type: every instance must supply plain
            // data for the parameters the element holds.
            var held: std.ArrayList(SymbolId) = .empty;
            defer held.deinit(ctx.allocator);
            try sema.heldTypeVars(ctx, c.elem, &held, ctx.allocator);
            for (held.items) |param| {
                try ctx.generic_requirements.append(ctx.allocator, .{ .param = param, .req = .no_cleanup, .pos = ctx.startOf(c.node), .op = "keeps in an array a value" });
            }
        },
        .builtin => |c| if (try builtinElementError(ctx, c.sym, c.args)) |msg| try ctx.err(c.pos, "{s}", .{msg}),
        .instance_stacking => |c| try sema.checkInstanceStacked(ctx, c.ty, c.pos),
        .cell_home => |c| if (sema.misplaced(ctx, c.ty, c.home) == .cell) {
            const shown = try sema.formatType(ctx, c.ty);
            try ctx.errAt(c.node, sema.cell_misplaced, .{ shown, shown });
        },
    }
}

/// What `sema.ctFoldBy` knows where a compile-time integer is declared
/// (in a type, a module constant, an enum value): the names visible from
/// `scope`, a constant binding's and a module constant's value, and
/// `module.NAME`, each with its type.
pub const ConstNames = struct {
    ctx: *const SemContext,
    scope: ScopeId,
    /// The generic type's parameters, which are not constants.
    type_params: []const SymbolId = &.{},
    /// The integer type arithmetic on literals alone takes: a module
    /// constant's declared type.
    literal: ?sema.IntInfo = null,

    pub fn symbol(self: ConstNames, e: Sexp) ?SymbolId {
        const text = identAt(self.ctx.source, e) orelse return null;
        for (self.type_params) |tp| if (std.mem.eql(u8, self.ctx.symbols.items[tp].name, text)) return tp;
        return self.ctx.symbolOf(e) orelse self.ctx.lookupBefore(self.scope, text, e.src.pos);
    }

    pub fn name(self: ConstNames, e: Sexp) ?sema.TypedInt {
        const id = self.symbol(e) orelse return null;
        const sym = self.ctx.symbols.items[id];
        if (sym.kind != .local or !sym.flags.fixed) return null;
        const c = self.ctx.const_ints.get(id) orelse return null;
        return .{ .v = c.value, .int = c.int };
    }

    pub fn member(self: ConstNames, e: Sexp) ?sema.TypedInt {
        const obj = ir.Member.object(e);
        if (obj != .src) return null;
        const id = self.ctx.lookupAt(self.scope, identAt(self.ctx.source, obj) orelse return null, obj.src.pos) orelse return null;
        if (self.ctx.symbols.items[id].kind != .module) return null;
        const foreign = self.ctx.foreign_semas.get(self.ctx.module_refs.get(id) orelse return null) orelse return null;
        const fid = foreign.lookupInScopeOnly(sema.module_scope, identAt(self.ctx.source, ir.Member.name(e)) orelse return null) orelse return null;
        if (!foreign.symbols.items[fid].flags.is_public) return null;
        const c = foreign.const_ints.get(fid) orelse return null;
        return .{ .v = c.value, .int = c.int };
    }

    pub fn literalInt(self: ConstNames, _: Sexp) ?sema.IntInfo {
        return self.literal;
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
/// `?String`.
fn literalTypeName(text: []const u8) ?[]const u8 {
    if (sema.isFloatLiteralText(text)) return "Float";
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) return "Bool";
    if (text.len > 0 and (text[0] == '"' or text[0] == '\'')) return "?String";
    return null;
}

/// The article for a type's name: "an `Int`", "a `Float`".
pub fn an(name: []const u8) []const u8 {
    return if (name.len > 0 and std.mem.findScalar(u8, "AEIO", name[0]) != null) "an" else "a";
}

pub const TypeResolver = struct {
    ctx: *SemContext,
    scope: ScopeId,
    nominal: NominalContext = NominalContext.none,
    /// The module declares an error set, which its fallible Zig-backed
    /// functions fail with.
    declares_errors: bool = false,

    /// The type a type name not found here was likely meant as: a
    /// built-in one written in lower case (`i32`, `string`), or a type
    /// it is a typo of.
    fn typeHint(self: *TypeResolver, name: []const u8, pos: u32) Error![]const u8 {
        const a = self.ctx.arena.allocator();
        if (sema.retiredNameHint(name)) |hint| return hint;
        if (name.len > 0 and std.ascii.isLower(name[0])) {
            const upper = try a.dupe(u8, name);
            upper[0] = std.ascii.toUpper(upper[0]);
            if (std.mem.eql(u8, name, "str") or std.mem.eql(u8, name, "string")) return "; Rig's text is a `String` (owned), and `?String` is its read view";
            if (isBuiltinTypeName(self.ctx, upper)) return a.print("; Rig's types are capitalized: `{s}`", .{upper});
        }
        var s: sema.Suggest = .{ .name = name };
        self.ctx.offerVisible(&s, self.scope, pos, struct {
            fn keep(sym: sema.Symbol) bool {
                return switch (sym.kind) {
                    .nominal_type, .generic_type, .type_alias => true,
                    else => false,
                };
            }
        }.keep);
        for (self.nominal.type_params) |tp| s.offer(self.ctx.symbols.items[tp].name);
        for ([_][]const u8{ "Int", "Float", "Bool", "String", "Static", "Void" }) |p| s.offer(p);
        return s.hint(a);
    }

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
            .zig_extern => for (ir.ZigExtern.decls(sexp)) |d| {
                try self.resolveDecl(d);
                const decl = if (d.isKind(.@"pub")) ir.Pub.decl(d) else d;
                if (!decl.isKind(.zig_const)) try self.checkZigBacked(decl);
            },
            .zig_const => {
                const name = ir.ZigConst.name(sexp);
                const id = self.ctx.symbolOf(name) orelse return;
                const ty = try self.resolveType(ir.ZigConst.type(sexp));
                self.ctx.symbols.items[id].ty = ty;
                // Zig gives it a value of a type both sides spell alike.
                const plain = switch (self.ctx.types.get(ty)) {
                    .bool, .int => true,
                    .nominal => |sym| sema.isBuiltinEnum(self.ctx, sym),
                    else => false,
                };
                if (!plain and !self.isPoison(ty)) {
                    try self.ctx.errAt(ir.ZigConst.type(sexp), "a Zig-backed constant is a `Bool`, an integer, or a built-in enum, not `{s}`", .{try sema.formatType(self.ctx, ty)});
                    self.ctx.symbols.items[id].ty = self.ctx.types.invalid_id;
                }
            },
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
        var ct_types: std.ArrayList(TypeId) = .empty;
        defer ct_types.deinit(self.ctx.allocator);
        var ct_syms: std.ArrayList(SymbolId) = .empty;
        defer ct_syms.deinit(self.ctx.allocator);
        for (sema.tparamsOf(node).items()) |p| {
            const pty = try self.resolveCtParam(p);
            try ct_types.append(self.ctx.allocator, pty);
            const pid = self.ctx.symbolOf(sema.paramNameNode(p) orelse p) orelse sema.symbol_invalid;
            try ct_syms.append(self.ctx.allocator, pid);
            if (p != .src and pid != sema.symbol_invalid) self.ctx.symbols.items[pid].ty = pty;
        }
        const returns = rig.returnType(node);
        const return_ty = if (rig.subFails(node))
            try self.ctx.intern(.{ .fallible = self.ctx.types.void_id })
        else if (returns == .nil) self.ctx.types.void_id else try self.resolveReturnType(returns);
        var param_types: std.ArrayList(TypeId) = .empty;
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
        try self.recordFrom(node, params, returns);
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
                try self.ctx.errAt(type_node, "compile-time parameter `{s}` cannot have the type `{s}`; a compile-time value is a number, `Bool`, `?String`, an enum whose variants carry nothing, or an optional of one", .{ name, try sema.formatType(self.ctx, ty) });
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
        // Several results, `-> (A, B)`, also fallible or optional as a
        // whole: `-> (A, B)!`, `-> (A, B)?`.
        if (node.isKind(.results_type)) return self.resolveResults(node);
        const wrapped = if (node.isKind(.error_union) or node.isKind(.optional)) ir.get(node, .type) else Sexp.nil;
        if (wrapped.isKind(.results_type)) {
            const inner = try self.resolveResults(wrapped);
            if (self.isPoison(inner)) return inner;
            return self.ctx.intern(if (node.isKind(.optional)) .{ .optional = inner } else .{ .fallible = inner });
        }
        if (node.isKind(.error_union) and wrapped.isKind(.optional) and ir.Optional.type(wrapped).isKind(.results_type)) {
            try self.ctx.errAt(node, "several results are fallible, `(A, B)!`, or optional, `(A, B)?`, not both", .{});
            return self.ctx.types.invalid_id;
        }
        if (node.isKind(.error_union)) {
            const inner = try self.resolveType(ir.ErrorUnion.type(node));
            if (sema.isErrorValue(self.ctx, inner)) {
                const e = try sema.formatType(self.ctx, inner);
                try self.ctx.errAt(node, "`{s}!` would make a failure and a success both `{s}` values; return `{s}` or `{s}?`, or an object that holds one", .{ e, e, e, e });
                return self.ctx.types.invalid_id;
            }
            // Each instance must give `T` a type that is not an error.
            if (self.ctx.types.get(inner) == .type_var) {
                try self.ctx.generic_requirements.append(self.ctx.allocator, .{ .param = self.ctx.types.get(inner).type_var, .req = .not_error, .pos = self.ctx.startOf(node), .op = "`!`" });
            }
            const ty = try self.ctx.intern(.{ .fallible = inner });
            if (try self.misplacedAt(node, ty, .signature)) return self.ctx.types.invalid_id;
            return ty;
        }
        const ty = try self.resolveType(node);
        if (try self.misplacedAt(node, ty, .signature)) return self.ctx.types.invalid_id;
        return ty;
    }

    /// `(A, B)`, a function's several results (`sema.Type.results`):
    /// two or more, each a type one result may have, at most one of them
    /// a write view. Named results are not Rig's.
    fn resolveResults(self: *TypeResolver, node: Sexp) Error!TypeId {
        const t = &self.ctx.types;
        const nodes = ir.ResultsType.types(node);
        var parts: std.ArrayList(TypeId) = .empty;
        defer parts.deinit(self.ctx.allocator);
        var poisoned = false;
        var writes: usize = 0;
        for (nodes) |n| {
            if (n.isKind(.@":")) {
                try self.ctx.errAt(n, "results are not named: write their types, `-> ({s})`, and name them where they are bound, `{s} = f()`", .{ try self.typesOnly(nodes), try self.namesOnly(nodes) });
                return t.invalid_id;
            }
            const ty = try self.resolveType(n);
            if (self.isPoison(ty)) {
                poisoned = true;
                continue;
            }
            switch (self.ctx.types.get(ty)) {
                .void => {
                    try self.ctx.errAt(n, "a result is a value: `Void` is none", .{});
                    poisoned = true;
                    continue;
                },
                .fallible => {
                    try self.ctx.errAt(n, "a single result is not fallible: several results fail as a whole, `(A, B)!`", .{});
                    poisoned = true;
                    continue;
                },
                else => {},
            }
            if (try self.misplacedAt(n, ty, .signature)) {
                poisoned = true;
                continue;
            }
            // A write view stands in a signature only as `!T` or `(!T)?`.
            if (self.ctx.types.get(sema.unwrapOptionals(self.ctx, ty)) == .write_view) writes += 1;
            try parts.append(self.ctx.allocator, ty);
        }
        if (poisoned) return t.invalid_id;
        if (writes > 1) {
            try self.ctx.errAt(node, "at most one of a function's results is a write view", .{});
            return t.invalid_id;
        }
        return self.ctx.internCopy(.{ .results = parts.items });
    }

    /// `(q: Int, r: Int)` as `Int, Int`: the types of named results.
    fn typesOnly(self: *TypeResolver, nodes: []const Sexp) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (nodes, 0..) |n, i| {
            if (i > 0) try out.appendSlice(self.ctx.arena.allocator(), ", ");
            const ty = if (n.isKind(.@":")) ir.get(n, .type) else n;
            try out.appendSlice(self.ctx.arena.allocator(), diag.textOf(self.ctx.source, self.ctx.span(ty)));
        }
        return out.items;
    }

    /// `(q: Int, r: Int)` as `q, r`: the names of named results.
    fn namesOnly(self: *TypeResolver, nodes: []const Sexp) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (nodes, 0..) |n, i| {
            if (i > 0) try out.appendSlice(self.ctx.arena.allocator(), ", ");
            const name = if (n.isKind(.@":")) ir.get(n, .name) else n;
            try out.appendSlice(self.ctx.arena.allocator(), if (n.isKind(.@":")) diag.textOf(self.ctx.source, self.ctx.span(name)) else "_");
        }
        return out.items;
    }

    /// `*(?T)`, `~(!T)`: a handle keeps a value alive, and a view is
    /// no value it could keep.
    fn handleOfView(self: *TypeResolver, node: Sexp, inner: TypeId) Error!TypeId {
        try self.ctx.errAt(node, "a handle holds a value, not a view: `{s}` has no handle", .{try sema.formatType(self.ctx, inner)});
        return self.ctx.types.invalid_id;
    }

    pub fn resolveParamType(self: *TypeResolver, param: Sexp) Error!TypeId {
        switch (param) {
            .src => |s| {
                const name = identAt(self.ctx.source, param).?;
                if (std.mem.eql(u8, name, "self") and !self.nominal.isEmpty()) {
                    try self.ctx.err(s.pos, "`self` parameter requires an explicit receiver type; use `?self`, `!self`, or `<self`", .{});
                } else {
                    try self.ctx.err(s.pos, "parameter `{s}` needs a type annotation (`{s}: T`)", .{ name, name });
                }
                return self.ctx.types.invalid_id;
            },
            .list => {
                const h = param.kind() orelse return self.ctx.types.invalid_id;
                switch (h) {
                    .@":", .default => {
                        const ty = try self.resolveType(ir.get(param, .type));
                        if (try self.misplacedAt(ir.get(param, .type), ty, .signature)) return self.ctx.types.invalid_id;
                        return ty;
                    },
                    // `?self`, `!self`, `<self`: `self: ?Self`, `!Self`, `Self`.
                    .read, .write, .move => {
                        const operand = ir.get(param, .operand);
                        const name = identAt(self.ctx.source, operand) orelse return self.ctx.types.invalid_id;
                        const pos = srcPos(operand, 0);
                        if (!std.mem.eql(u8, name, "self")) {
                            try self.ctx.err(pos, "sigil-prefixed parameter is only allowed for `self`; for other parameters use `{s}: ?Type` / `{s}: !Type` / `{s}: Type`", .{ name, name, name });
                            return self.ctx.types.invalid_id;
                        }
                        const sigil: []const u8 = switch (h) {
                            .read => "?",
                            .write => "!",
                            else => "<",
                        };
                        if (self.nominal.isEmpty()) {
                            try self.ctx.err(pos, "`{s}self` is only allowed in a method body (inside an object, enum, or errors declaration)", .{sigil});
                            return self.ctx.types.invalid_id;
                        }
                        if (h == .move) _ = try self.misplacedAt(param, self.nominal.self_type, .signature);
                        return switch (h) {
                            .read => self.ctx.intern(.{ .read_view = self.nominal.self_type }),
                            .write => self.ctx.intern(.{ .write_view = self.nominal.self_type }),
                            else => self.nominal.self_type,
                        };
                    },
                    else => {},
                }
                try self.ctx.errAt(param, "unsupported parameter form", .{});
                return self.ctx.types.invalid_id;
            },
            else => return self.ctx.types.invalid_id,
        }
    }

    /// A Zig-backed `fun` or `sub` has a signature the checker can
    /// trust without a body: one with compile-time parameters would need
    /// requirements it cannot infer. One that fails returns errors of its
    /// module's error sets, which the emitter hands `rig.expectShim` to
    /// check its Zig function against, so the module must declare one.
    fn checkZigBacked(self: *TypeResolver, node: Sexp) Error!void {
        const name = ir.get(node, .name);
        const text = identAt(self.ctx.source, name) orelse "it";
        if (sema.tparamsOf(node).items().len > 0) {
            try self.ctx.errAt(name, "a Zig-backed function cannot take compile-time parameters: write `{s}` in Rig", .{text});
        }
        const f = self.ctx.types.get(self.ctx.symbols.items[self.ctx.symbolOf(name) orelse return].ty);
        const fails = rig.subFails(node) or (f == .function and self.ctx.types.get(f.function.returns) == .fallible);
        if (fails and !self.declares_errors) {
            try self.ctx.errAt(name, "`{s}` can fail, so its module must declare the errors its Zig function returns: add an error set, `error Name`, with a member for each", .{text});
        }
    }

    /// An `extern_fun` or `extern_sub`.
    fn resolveExternFun(self: *TypeResolver, node: Sexp) Error!void {
        const is_sub = node.isKind(.extern_sub);
        const name = ir.get(node, .name);
        const params = ir.get(node, .params);
        const returns: Sexp = if (is_sub) .nil else ir.ExternFun.returns(node);
        const return_ty = if (returns == .nil) self.ctx.types.void_id else try self.resolveReturnType(returns);
        // As for `fun`: an `extern fun` returns a value.
        if (!is_sub and (returns == .nil or return_ty == self.ctx.types.void_id)) {
            try self.ctx.errAt(if (returns == .nil) name else returns, "an `extern fun` returns a value; declare `-> T`, or make `{s}` an `extern sub`", .{identAt(self.ctx.source, name) orelse "it"});
        }
        var ps: std.ArrayList(TypeId) = .empty;
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
        try self.recordFrom(node, params, returns);
        try self.checkExternSignature(name, fn_ty);
    }

    /// A `fun`'s `from` clause, which `sema.computeOrigins` reads once
    /// every type's contents are known.
    fn recordFrom(self: *TypeResolver, node: Sexp, params: Sexp, returns: Sexp) Error!void {
        try self.recordKeeps(node, params);
        if (!node.isKind(.fun) and !node.isKind(.extern_fun)) return;
        const names = ir.get(node, .origins);
        if (names == .nil) return;
        const name = ir.get(node, .name);
        if (name != .src) return;
        try self.ctx.declared_origins.put(self.ctx.allocator, name.src.pos, .{ .names = names, .params = params, .returns = returns });
    }

    /// A function's `keeps` clause, which `sema.computeOrigins` reads
    /// once every type's contents are known.
    fn recordKeeps(self: *TypeResolver, node: Sexp, params: Sexp) Error!void {
        const names = ir.get(node, .keeps);
        if (names == .nil) return;
        const name = ir.get(node, .name);
        if (name != .src) return;
        try self.ctx.declared_keeps.put(self.ctx.allocator, name.src.pos, .{ .names = names, .params = params });
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
        if (self.ctx.symbols.items[id].ty != self.ctx.types.unknown_id) return self.ctx.symbols.items[id].ty;
        if (!self.ctx.alias_in_progress.contains(id)) try self.resolveNamedAliases(id);
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
        var ty = try module_resolver.resolveType(target);
        // A type built on one already reported (`poison`) is not reported
        // again, but nests no deeper either.
        const info = self.ctx.typeInfo(ty);
        if (info.height > sema.max_alias_height) {
            const s = self.ctx.symbols.items[id];
            if (!info.poison) try self.ctx.err(s.decl_pos, "type alias `{s}` names a type nested more than {d} deep through the aliases it names; no type may nest so deep", .{ s.name, sema.max_alias_height });
            ty = self.ctx.types.invalid_id;
        }
        self.ctx.symbols.items[id].ty = ty;
        return ty;
    }

    /// An alias `resolveNamedAliases` resolves once those its target names
    /// (`named`, from `next` on) are resolved.
    const PendingAlias = struct { id: SymbolId, named: []const SymbolId, next: usize = 0 };

    /// Resolve the aliases alias `id`'s target names, and those theirs
    /// name in turn, deepest first, so that resolving `id` does not nest
    /// once per link of a chain of aliases (`type A = B`, `type B = C`,
    /// ...). The walk keeps a stack of its own. An alias met again on it
    /// refers to itself, reported there as `resolveAlias` reports one it
    /// meets again.
    fn resolveNamedAliases(self: *TypeResolver, id: SymbolId) Error!void {
        var arena = std.heap.ArenaAllocator.init(self.ctx.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // An alias on the stack is open; one taken off it, closed.
        var open: std.AutoHashMapUnmanaged(SymbolId, bool) = .empty;
        var stack: std.ArrayList(PendingAlias) = .empty;
        try open.put(a, id, true);
        try stack.append(a, .{ .id = id, .named = try self.aliasesNamed(a, id) });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next < top.named.len) {
                const d = top.named[top.next];
                top.next += 1;
                const sym = &self.ctx.symbols.items[d];
                if (sym.ty != self.ctx.types.unknown_id or self.ctx.alias_in_progress.contains(d)) continue;
                const gop = try open.getOrPut(a, d);
                if (gop.found_existing) {
                    if (gop.value_ptr.*) {
                        try self.ctx.err(sym.decl_pos, "type alias `{s}` refers to itself", .{sym.name});
                        sym.ty = self.ctx.types.invalid_id;
                    }
                    continue;
                }
                gop.value_ptr.* = true;
                try stack.append(a, .{ .id = d, .named = try self.aliasesNamed(a, d) });
                continue;
            }
            const done = stack.pop().?.id;
            try open.put(a, done, false);
            if (done != id) _ = try self.resolveAlias(done);
        }
    }

    /// The aliases the target of alias `id` names, in the order
    /// `resolveType` meets them: each name it reads as a type here that is
    /// an alias.
    fn aliasesNamed(self: *TypeResolver, a: std.mem.Allocator, id: SymbolId) Error![]const SymbolId {
        const target = self.ctx.alias_targets.get(id) orelse return &.{};
        const scope = self.ctx.symbols.items[id].scope;
        var out: std.ArrayList(SymbolId) = .empty;
        var todo: std.ArrayList(Sexp) = .empty;
        try todo.append(a, target);
        while (todo.pop()) |e| switch (e) {
            .src => {
                const name = identAt(self.ctx.source, e) orelse continue;
                if (std.mem.eql(u8, name, "error") or primitiveTypeId(self.ctx, name) != null or sizedType(name) != null) continue;
                const found = self.ctx.lookup(scope, name) orelse continue;
                if (self.ctx.symbols.items[found].kind == .type_alias) try out.append(a, found);
            },
            // `m.T` names another module's `T`, not this one's.
            .list => if (e.isKind(.member)) {
                try todo.append(a, ir.Member.object(e));
            } else {
                const items = e.items();
                var i = items.len;
                while (i > 0) {
                    i -= 1;
                    try todo.append(a, items[i]);
                }
            },
            else => {},
        };
        return out.items;
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

        var fields: std.ArrayList(Field) = .empty;
        defer fields.deinit(self.ctx.allocator);
        // Each member's name -> where it is declared.
        var names: std.StringHashMapUnmanaged(u32) = .empty;
        defer names.deinit(self.ctx.allocator);
        const sym_name = self.ctx.symbols.items[sym_id].name;
        if (generic) try self.resolveValueParams(ir.get(node, .tparams));
        // Only a plain enum, without payloads or generic parameters, has
        // values, which its variants' fields record (`Field.value`).
        const plain_enum = head == .@"enum" and for (members) |m| {
            if (m.isKind(.variant)) break false;
        } else true;
        var values: EnumValues = .{};
        defer values.seen.deinit(self.ctx.allocator);

        for (members) |m| {
            switch (m) {
                .src => |s| {
                    const vname = identAt(self.ctx.source, m).?;
                    if (!is_enum) {
                        try self.ctx.err(s.pos, "field `{s}` needs a type (`{s}: T`)", .{ vname, vname });
                        continue;
                    }
                    try self.noneMember(head, vname, s.pos);
                    if (try self.reservedEnumMember(plain_enum, .variant, vname, s.pos)) continue;
                    if (try self.checkDuplicateMember(&names, vname, s.pos, sym_name)) continue;
                    const value = if (plain_enum) try self.enumValue(&values, m, null) else null;
                    try fields.append(self.ctx.allocator, .{ .name = vname, .ty = self.ctx.types.void_id, .decl_pos = s.pos, .is_variant = true, .value = value });
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
                            if (try self.checkDuplicateMember(&names, fname, fpos, sym_name)) continue;
                            var fty = try self.resolveType(ir.get(m, .type));
                            if (try self.fieldCallable(ir.get(m, .type), fty) or try self.misplacedAt(ir.get(m, .type), fty, .field)) fty = self.ctx.types.invalid_id;
                            try fields.append(self.ctx.allocator, .{ .name = fname, .ty = fty, .decl_pos = fpos, .default = if (h == .default) ir.Default.value(m) else null, .is_pub = self.isPubMember(m), .read_only = self.isReadOnlyMember(m) });
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
                            } else if (!plain_enum) {
                                try self.ctx.errAt(ir.Valued.value(m), "{s} cannot give its variants values; only a plain enum can", .{if (generic) "a generic enum" else "an enum with payload variants"});
                            }
                            try self.noneMember(head, vname, vpos);
                            if (try self.reservedEnumMember(plain_enum, .variant, vname, vpos)) continue;
                            if (try self.checkDuplicateMember(&names, vname, vpos, sym_name)) continue;
                            const value = if (plain_enum) try self.enumValue(&values, name_node, ir.Valued.value(m)) else null;
                            try fields.append(self.ctx.allocator, .{ .name = vname, .ty = self.ctx.types.void_id, .decl_pos = vpos, .is_variant = true, .value = value });
                        },
                        .variant => {
                            if (!is_enum or head == .errors) {
                                try self.ctx.errAt(m, "only enums declare payload variants", .{});
                                continue;
                            }
                            try self.noneMember(head, identAt(self.ctx.source, ir.Variant.name(m)).?, ir.Variant.name(m).src.pos);
                            try self.resolveVariant(m, &fields, &names, sym_name);
                        },
                        .fun, .sub => {
                            if (head == .errors) {
                                try self.ctx.errAt(ir.get(m, .name), "an error set cannot declare methods; write a function that takes the error", .{});
                                continue;
                            }
                            const mname_node = ir.get(m, .name);
                            if (try self.reservedEnumMember(plain_enum, .method, identAt(self.ctx.source, mname_node) orelse "", mname_node.src.pos)) continue;
                            try self.resolveMethod(m, sym_id, &fields, &names);
                        },
                        .read, .write, .move => {
                            const n = identAt(self.ctx.source, ir.get(m, .operand)) orelse "name";
                            try self.ctx.err(sema.paramPos(m, 0), "sigil-prefixed member (`?{s}` / `!{s}` / `<{s}`) is not allowed in a nominal body; sigil-prefix sugar is only valid for the `self` parameter of a method", .{ n, n, n });
                        },
                        .drop_decl => {
                            if (head == .@"struct") {
                                try self.resolveDropDecl(m, sym_id, &fields);
                            } else {
                                const where: []const u8 = switch (head) {
                                    .errors => "error sets",
                                    .generic_struct => "generic objects",
                                    else => "enums",
                                };
                                try self.ctx.errAt(m, "`drop` bodies are only for non-generic objects, not {s}", .{where});
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

    /// Whether `ty`, written `node` inside another type, is or holds a
    /// callable view, which no value holds. Reported.
    fn heldCallable(self: *TypeResolver, node: Sexp, ty: TypeId) Error!bool {
        if (!sema.holdsCallable(self.ctx, ty)) return false;
        try self.ctx.errAt(node, sema.held_callable, .{try sema.formatType(self.ctx, ty)});
        return true;
    }

    /// `ty`, written `node`, standing at `home` (`sema.misplaced`): a
    /// write view is decided at once, true when it is reported; a Cell
    /// once what every type holds is known. A type argument's Cell is
    /// decided with each instance (`checkGenericInstantiations`).
    pub fn misplacedAt(self: *TypeResolver, node: Sexp, ty: TypeId, home: sema.Home) Error!bool {
        if (self.isPoison(ty)) return false;
        if (sema.writeViewMisplaced(self.ctx, ty, home)) {
            try self.ctx.errAt(node, sema.write_view_misplaced, .{try sema.formatType(self.ctx, ty)});
            return true;
        }
        switch (home) {
            .field, .handle, .viewed, .type_arg => {},
            .signature, .binding, .element, .optional => try self.checkWhenResolved(.{ .cell_home = .{ .node = node, .ty = ty, .home = home } }),
        }
        return false;
    }

    /// `*fun(...) -> R` / `*sub(...)`, function type `ty` written
    /// `fun_type`: an owned closure is a method on its own environment
    /// (docs/INTERNALS.md, "Owned closures"), so its parameters and
    /// result stand where a function's do.
    fn ownedClosureSignature(self: *TypeResolver, fun_type: Sexp, ty: TypeId) Error!void {
        const f = self.ctx.types.get(ty).function;
        const is_fun_type = fun_type.isKind(.fun_type);
        const nodes: []const Sexp = if (is_fun_type) ir.FunType.params(fun_type).items() else &.{};
        for (f.params, 0..) |p, i| _ = try self.misplacedAt(if (i < nodes.len) nodes[i] else fun_type, p, .signature);
        if (f.is_sub) return;
        const at = if (is_fun_type and ir.FunType.returns(fun_type) != .nil) ir.FunType.returns(fun_type) else fun_type;
        _ = try self.misplacedAt(at, f.returns, .signature);
    }

    /// A field's type `ty`, written `node`: a callable view is not
    /// one. Reported.
    fn fieldCallable(self: *TypeResolver, node: Sexp, ty: TypeId) Error!bool {
        if (sema.callableFn(self.ctx, ty) == null) return false;
        try self.ctx.errAt(node, sema.held_callable, .{try sema.formatType(self.ctx, ty)});
        return true;
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

    /// The values a plain enum's variants have taken so far.
    const EnumValues = struct {
        /// The value of a variant without `= value`: the one after the
        /// previous variant's.
        next: Wide = 0,
        /// Each value taken -> the name of the variant that took it.
        seen: std.AutoHashMapUnmanaged(Wide, Sexp) = .empty,
        /// A value was rejected; the rest are not checked.
        failed: bool = false,
    };

    /// The value of a plain enum's variant named `name_node`, given by
    /// `value_node` or implicit: a constant integer that fits the
    /// emitted `enum(u32)` tag, which no other variant has. After a
    /// rejected value the rest are not checked, but every variant still
    /// has one, so the enum stays plain.
    fn enumValue(self: *TypeResolver, ev: *EnumValues, name_node: Sexp, value_node: ?Sexp) Error!Wide {
        const name = identAt(self.ctx.source, name_node).?;
        const value = blk: {
            const v = value_node orelse break :blk ev.next;
            if (ev.failed) break :blk ev.next;
            break :blk (try self.foldEnumValue(v, name)) orelse {
                ev.failed = true;
                break :blk ev.next;
            };
        };
        ev.next = value +| 1;
        if (ev.failed) return value;
        if (value < 0 or value > std.math.maxInt(u32)) {
            try self.ctx.errAt(value_node orelse name_node, "`{s}` has the value {d}, out of range: enum values run from 0 to {d}", .{ name, value, std.math.maxInt(u32) });
            ev.failed = true;
            return value;
        }
        const gop = try ev.seen.getOrPut(self.ctx.allocator, value);
        if (gop.found_existing) {
            const prev = identAt(self.ctx.source, gop.value_ptr.*).?;
            try self.ctx.errAt(name_node, "`{s}` has the value {d}, which `{s}` already has{s}", .{ name, value, prev, if (value_node != null) "" else " (a variant without `= value` takes the value after the previous variant's)" });
            try self.ctx.noteAt(gop.value_ptr.*, "`{s}` declared here", .{prev});
        } else gop.value_ptr.* = name_node;
        return value;
    }

    /// The value `= node` gives the variant `name`, as module constants
    /// are folded; null after a diagnostic.
    fn foldEnumValue(self: *TypeResolver, node: Sexp, name: []const u8) Error!?Wide {
        const what = "an enum value";
        const fold = sema.ctFoldBy(self.ctx, node, ConstNames{ .ctx = self.ctx, .scope = sema.module_scope });
        switch (fold) {
            .value => |t| return t.v,
            .overflow, .mismatch => try self.reportFold(node, fold, what),
            .not_constant => if (sema.perTargetLeaf(self.ctx, node)) |leaf| {
                try self.ctx.errAt(node, "{s} must be known when Rig checks the program; " ++ sema.per_target_why, .{ what, try self.sourceText(leaf) });
            } else if (!node.isKind(.member) or !try self.memberNotCtInt(node, what)) {
                try self.ctx.errAt(node, "the value of `{s}` must be a constant integer", .{name});
            },
        }
        return null;
    }

    /// Reports a variant or error named `none`, declared at `pos` in a
    /// nominal of kind `head`: `.none` would read as `none`, the absent
    /// value of an optional, and in a `T?` of the enum could be taken
    /// for it. The member is still declared, so its uses draw no
    /// further errors.
    fn noneMember(self: *TypeResolver, head: Tag, name: []const u8, pos: u32) Error!void {
        if (!std.mem.eql(u8, name, "none")) return;
        try self.ctx.err(pos, "{s} cannot be named `none`: `none` is the absent value of an optional, and `.none` would read as it; choose another name", .{if (head == .errors) "an error" else "a variant"});
    }

    /// Whether `name`, a variant or a method declared at `pos` in an enum
    /// (`plain` when it has values), is one every plain enum has built
    /// in: `from_int` and `from_text`, named through the type as a
    /// variant is, and `text`, named through a value as a method is (a
    /// variant named `text` is `E.text`, and clashes with neither).
    /// Reported.
    fn reservedEnumMember(self: *TypeResolver, plain: bool, kind: enum { variant, method }, name: []const u8, pos: u32) Error!bool {
        if (!plain) return false;
        if (std.mem.eql(u8, name, "from_int") or std.mem.eql(u8, name, "from_text")) {
            try self.ctx.err(pos, "`{s}` is built into every plain enum", .{name});
            return true;
        }
        if (kind == .method and std.mem.eql(u8, name, "text")) {
            try self.ctx.err(pos, "`text` is built into every plain enum: `e.text` is the name of `e`'s variant; give the method another name", .{});
            return true;
        }
        return false;
    }

    /// Whether `name`, declared at `pos`, names an earlier member of
    /// `owner` (`names`: each member's name -> where it is declared).
    /// Reported.
    fn checkDuplicateMember(self: *TypeResolver, names: *std.StringHashMapUnmanaged(u32), name: []const u8, pos: u32, owner: []const u8) Error!bool {
        const gop = try names.getOrPut(self.ctx.allocator, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = pos;
            return false;
        }
        try self.ctx.err(pos, "duplicate member `{s}` in `{s}`", .{ name, owner });
        try self.ctx.note(gop.value_ptr.*, "first declared here", .{});
        return true;
    }

    fn resolveVariant(self: *TypeResolver, variant: Sexp, fields: *std.ArrayList(Field), names: *std.StringHashMapUnmanaged(u32), owner: []const u8) Error!void {
        const name_node = ir.Variant.name(variant);
        const vname = identAt(self.ctx.source, name_node).?;
        const vpos = name_node.src.pos;
        if (try self.checkDuplicateMember(names, vname, vpos, owner)) return;
        var payload: std.ArrayList(Field) = .empty;
        defer payload.deinit(self.ctx.allocator);
        var payload_names: std.StringHashMapUnmanaged(u32) = .empty;
        defer payload_names.deinit(self.ctx.allocator);
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
                if (try self.checkDuplicateMember(&payload_names, fname, srcPos(field_name, 0), vname)) continue;
                var fty = try self.resolveType(ir.get(p, .type));
                if (try self.fieldCallable(ir.get(p, .type), fty) or try self.misplacedAt(ir.get(p, .type), fty, .field)) fty = self.ctx.types.invalid_id;
                try payload.append(self.ctx.allocator, .{
                    .name = fname,
                    .ty = fty,
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

    /// Whether a field or method is declared `pub`.
    fn isPubMember(self: *const TypeResolver, member: Sexp) bool {
        const p = self.ctx.parser orelse return false;
        return p.isPubMember(member);
    }

    fn isReadOnlyMember(self: *const TypeResolver, member: Sexp) bool {
        const p = self.ctx.parser orelse return false;
        return p.isReadOnlyMember(member);
    }

    fn resolveMethod(self: *TypeResolver, node: Sexp, nominal_sym: SymbolId, fields: *std.ArrayList(Field), names: *std.StringHashMapUnmanaged(u32)) Error!void {
        const name = ir.get(node, .name);
        const mname = identAt(self.ctx.source, name).?;
        const mpos = name.src.pos;
        const owner = self.ctx.symbols.items[nominal_sym].name;
        if (try self.checkDuplicateMember(names, mname, mpos, owner)) return;
        const fn_ty = try self.resolveFunction(node, nominal_sym);
        const marked = rig.markerOf(node) == .@"inline";
        if (marked) try self.ctx.inline_decls.put(self.ctx.allocator, mpos, node);
        const params = ir.get(node, .params);
        for (params.items(), 0..) |p, i| {
            if (i == 0) continue;
            if (self.isSelfParam(p)) {
                try self.ctx.err(sema.paramPos(p, mpos), "`self` must be the first parameter of a method", .{});
            }
            if (p.isKind(.read) or p.isKind(.write) or p.isKind(.move)) {
                try self.ctx.err(sema.paramPos(p, mpos), "sigil-prefixed parameter sugar (`?self` / `!self` / `<self`) is only allowed at the first parameter position", .{});
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
            .is_pub = self.isPubMember(node),
            .inline_marked = marked,
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
            .read_view => |inner| {
                if (inner == self_ty) return .read;
                try self.ctx.err(mpos, "`self` receiver type must be `?Self` or `?{s}`", .{nom});
            },
            .write_view => |inner| {
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

    fn resolveDropDecl(self: *TypeResolver, node: Sexp, nominal_sym: SymbolId, fields: *std.ArrayList(Field)) Error!void {
        const pos = self.ctx.startOf(node);
        for (fields.items) |f| {
            if (f.is_drop_method) {
                try self.ctx.err(pos, "duplicate `drop` declaration on this object; an object has at most one `drop`", .{});
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
        const ok = pty == .write_view and blk: {
            break :blk switch (self.ctx.types.get(pty.write_view)) {
                .nominal => |s| s == nominal_sym,
                else => false,
            };
        };
        if (!ok) {
            try self.ctx.err(sema.paramPos(first, pos), "`drop` takes its receiver lent to write: `drop(!self)`", .{});
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
            .drop => if (self.isSelf(ir.Drop.target(body))) {
                try self.ctx.errAt(ir.Drop.target(body), "cannot drop `self` inside its own drop body; the binding is being destroyed by the runtime", .{});
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
                // The keyword `error` is the type of an error of any set.
                if (std.mem.eql(u8, name, "error")) return t.any_error_id;
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
                try self.ctx.err(s.pos, "use of unbound type `{s}`{s}", .{ name, try self.typeHint(name, s.pos) });
                return t.invalid_id;
            },
            .list => {
                const head = sexp.kind() orelse return t.invalid_id;
                switch (head) {
                    .error_union => {
                        const inner = try self.resolveType(ir.ErrorUnion.type(sexp));
                        const ty = try self.ctx.intern(.{ .fallible = inner });
                        try self.ctx.errAt(sexp, "a fallible type `{s}` is only allowed as a function's return type", .{try sema.formatType(self.ctx, ty)});
                        return t.invalid_id;
                    },
                    .optional, .read_view, .write_view, .weak, .slice => {
                        const inner_node = if (head == .weak) ir.Weak.operand(sexp) else ir.get(sexp, .type);
                        const inner = try self.resolveType(inner_node);
                        if (inner == t.invalid_id) return t.invalid_id;
                        if (try self.heldCallable(inner_node, inner)) return t.invalid_id;
                        const home: sema.Home = switch (head) {
                            .optional => .optional,
                            .read_view, .write_view => .viewed,
                            .weak => .handle,
                            else => .element,
                        };
                        if (try self.misplacedAt(inner_node, inner, home)) return t.invalid_id;
                        // Nothing lends a `?String` place to write: it holds a read
                        // view of text, pointed elsewhere by assigning to it.
                        if (head == .write_view and inner == t.string_view_id) {
                            try self.ctx.errAt(sexp, "`!?String` cannot be written: a `?String` is a read view of text, which nothing lends to write; assign to the place to point it at other text, or hold a `String` to change text in place", .{});
                            return t.invalid_id;
                        }
                        // `?fun(...)` written as such is a callable
                        // view; a `?T` of a function type is a read
                        // view of a function value.
                        if (head == .read_view and inner_node.isKind(.fun_type)) return sema.callableOfFn(self.ctx, inner);
                        if (head == .weak and sema.isReadOrWriteView(self.ctx, inner)) return self.handleOfView(sexp, inner);
                        if (head == .weak) try sema.requireHandleOf(self.ctx, inner, self.ctx.startOf(sexp), "`~`");
                        return self.ctx.intern(switch (head) {
                            .optional => .{ .optional = inner },
                            .read_view => .{ .read_view = inner },
                            .write_view => .{ .write_view = inner },
                            .weak => .{ .weak = inner },
                            else => .{ .slice = .{ .elem = inner } },
                        });
                    },
                    .shared => {
                        const inner_node = ir.Shared.type(sexp);
                        const inner = try self.resolveType(inner_node);
                        if (inner == t.invalid_id) return t.invalid_id;
                        if (try self.heldCallable(inner_node, inner) or try self.misplacedAt(inner_node, inner, .handle)) return t.invalid_id;
                        if (sema.heapStacked(self.ctx, inner)) {
                            try self.ctx.errAt(sexp, sema.heap_stacked, .{try self.stackedSpelling('*', inner)});
                            return t.invalid_id;
                        }
                        if (sema.isReadOrWriteView(self.ctx, inner)) return self.handleOfView(sexp, inner);
                        if (self.ctx.types.get(inner) == .function) try self.ownedClosureSignature(inner_node, inner);
                        try sema.requireHandleOf(self.ctx, inner, self.ctx.startOf(sexp), "`*`");
                        return self.ctx.intern(.{ .shared = inner });
                    },
                    .array_type => {
                        const len = try self.resolveCtInt(ir.ArrayType.size(sexp), .array_len);
                        const elem_node = ir.ArrayType.type(sexp);
                        const elem = try self.resolveType(elem_node);
                        if (self.isPoison(len) or try self.heldCallable(elem_node, elem) or try self.misplacedAt(elem_node, elem, .element)) return t.invalid_id;
                        const ty = try self.ctx.intern(.{ .array = .{ .elem = elem, .len = len } });
                        // Once every type's contents are known, a type too
                        // large is poison.
                        const ready = self.ctx.contents_ready;
                        if (ready and !try sema.checkArrayBytes(self.ctx, self.ctx.startOf(sexp), ty)) return t.invalid_id;
                        try self.checkWhenResolved(.{ .array = .{ .node = elem_node, .elem = elem, .at = sexp, .ty = if (ready) null else ty } });
                        return ty;
                    },
                    .fun_type => {
                        var ps: std.ArrayList(TypeId) = .empty;
                        defer ps.deinit(self.ctx.allocator);
                        for (ir.FunType.params(sexp).items()) |p| try ps.append(self.ctx.allocator, try self.resolveType(p));
                        const ret = if (ir.FunType.fails(sexp) != .nil)
                            try self.ctx.intern(.{ .fallible = t.void_id })
                        else
                            try self.resolveReturnType(ir.FunType.returns(sexp));
                        // A function type returning nothing is spelled as a `sub`'s.
                        if (ir.FunType.returns(sexp) != .nil and sema.returnsNothing(self.ctx, ret)) {
                            try self.ctx.errAt(ir.FunType.returns(sexp), "a function type that returns nothing is a `sub` type: `sub(...){s}`", .{if (ret == t.void_id) "" else "!"});
                        }
                        return self.ctx.intern(.{ .function = .{
                            .params = try self.ctx.dupeIds(ps.items),
                            .returns = ret,
                            .is_sub = sema.returnsNothing(self.ctx, ret),
                        } });
                    },
                    .boxed => {
                        const inner_node = ir.Boxed.type(sexp);
                        const inner = try self.resolveType(inner_node);
                        if (sema.containsPoison(self.ctx, inner) or try self.heldCallable(inner_node, inner)) return t.invalid_id;
                        if (self.ctx.types.get(inner) == .function) {
                            try self.ctx.errAt(sexp, sema.boxed_function, .{});
                            return t.invalid_id;
                        }
                        if (sema.heapStacked(self.ctx, inner)) {
                            try self.ctx.errAt(sexp, sema.heap_stacked, .{try self.stackedSpelling('^', inner)});
                            return t.invalid_id;
                        }
                        return self.boxOf(inner, self.ctx.startOf(sexp));
                    },
                    .generic_inst => return self.resolveGenericInst(sexp),
                    .member => return self.resolveQualified(ir.Member.object(sexp), ir.Member.name(sexp)),
                    // Several results are a function's, after its `->`
                    // (`resolveReturnType`), and no value's type.
                    .results_type => {
                        try self.ctx.errAt(sexp, "`{s}` is a function's results, not a type a value can have: name an object for a stored pair", .{diag.textOf(self.ctx.source, self.ctx.span(sexp))});
                        return t.invalid_id;
                    },
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
        const fold = sema.ctFoldBy(self.ctx, node, names);
        switch (fold) {
            .value => |v| return .{ .ty = try sema.ctInt(self.ctx, v.v), .int = v.int },
            .overflow, .mismatch => {
                try self.reportFold(node, fold, what);
                return null;
            },
            .not_constant => {},
        }
        const text = try self.sourceText(node);
        if (sema.perTargetLeaf(self.ctx, node)) |leaf| {
            try self.ctx.errAt(node, "{s} must be known when Rig checks the program; " ++ sema.per_target_why, .{ what, try self.sourceText(leaf) });
            return null;
        }
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
            // A binding already reported.
            if (sym.ty == self.ctx.types.invalid_id) return null;
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
        try self.ctx.errAt(node, "{s} must be known at compile time; `{s}` is not: use an integer, a constant (`N = 4`), a compile-time parameter, or arithmetic on them", .{ what, text });
        return null;
    }

    /// Report why the compile-time integer `node`, used as `what`, has no
    /// value: `fold` overflows its type, or mixes two.
    fn reportFold(self: *TypeResolver, node: Sexp, fold: sema.CtFold, what: []const u8) Error!void {
        switch (fold) {
            .overflow => |o| {
                const at = try self.sourceText(o.node);
                const int = o.int orelse return self.ctx.errAt(o.node, "{s} `{s}` is too large to compute", .{ what, try self.sourceText(node) });
                const ty = try sema.formatType(self.ctx, try self.ctx.intern(.{ .int = int }));
                const b = sema.intRange(int);
                if (std.meta.eql(self.ctx.span(o.node), self.ctx.span(node)))
                    try self.ctx.errAt(node, "{s} `{s}` overflows `{s}` ({d}..{d})", .{ what, at, ty, b.min, b.max })
                else
                    try self.ctx.errAt(o.node, "{s} `{s}` overflows `{s}` ({d}..{d}) in `{s}`", .{ what, try self.sourceText(node), ty, b.min, b.max, at });
            },
            .mismatch => |m| try self.ctx.errAt(m.node, "{s} `{s}` combines `{s}` and `{s}`; convert one to the other's type", .{
                what,                                                                try self.sourceText(m.node),
                try sema.formatType(self.ctx, try self.ctx.intern(.{ .int = m.a })), try sema.formatType(self.ctx, try self.ctx.intern(.{ .int = m.b })),
            }),
            .value, .not_constant => unreachable,
        }
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
        const mod_id = self.ctx.lookupAt(self.scope, module_name, srcPos(obj, 0)) orelse {
            try self.ctx.errAt(obj, "use of unbound name `{s}`{s}", .{ module_name, try self.ctx.otherFileUse(module_name) });
            return true;
        };
        if (self.ctx.symbols.items[mod_id].kind != .module) return false;
        const foreign = self.ctx.foreign_semas.get(self.ctx.module_refs.get(mod_id) orelse return false) orelse return false;
        const name = identAt(self.ctx.source, ir.Member.name(node)) orelse return false;
        const fid = foreign.lookupInScopeOnly(sema.module_scope, name) orelse {
            try self.ctx.errAt(node, "no member `{s}` in module `{s}`{s}", .{ name, module_name, sema.stdNameHint(foreign, name) });
            return true;
        };
        const fsym = foreign.symbols.items[fid];
        if (!fsym.flags.is_public) {
            try sema.notPublic(self.ctx, self.ctx.startOf(node), module_name, name, foreign);
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
                const id = self.ctx.lookupAt(self.scope, identAt(self.ctx.source, obj) orelse return, srcPos(obj, 0)) orelse return;
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
        return .{ .ctx = self.ctx, .scope = self.scope, .type_params = self.nominal.type_params };
    }

    /// The symbol a name leaf in a compile-time integer denotes.
    fn lookupCt(self: *const TypeResolver, leaf: Sexp) ?SymbolId {
        return self.ctx.lookupBefore(self.scope, identAt(self.ctx.source, leaf) orelse return null, leaf.src.pos);
    }

    fn sourceText(self: *const TypeResolver, node: Sexp) Error![]const u8 {
        const sp = self.ctx.span(node);
        return diag.textOf(self.ctx.source, sp);
    }

    /// A declaration `module.Name` names in an imported module, or null
    /// after a diagnostic.
    const ForeignDecl = struct { foreign: *SemContext, origin: u32, id: SymbolId, sym: Symbol, module_name: []const u8, name: []const u8, pos: u32 };

    fn foreignDecl(self: *TypeResolver, module_node: Sexp, name_node: Sexp) Error!?ForeignDecl {
        const module_name = identAt(self.ctx.source, module_node) orelse return null;
        const name = identAt(self.ctx.source, name_node) orelse return null;
        const pos = srcPos(name_node, 0);
        const mod_id = self.ctx.lookupAt(self.scope, module_name, srcPos(module_node, 0)) orelse {
            const other = try self.ctx.otherFileUse(module_name);
            if (other.len > 0) {
                try self.ctx.errAt(module_node, "use of unbound module `{s}`{s}", .{ module_name, other });
            } else try self.ctx.errAt(module_node, "use of unbound module `{s}`; import it with `use {s}`", .{ module_name, module_name });
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
            try self.ctx.err(pos, "no type `{s}` in module `{s}`{s}", .{ name, module_name, sema.stdNameHint(foreign, name) });
            return null;
        };
        return .{ .foreign = foreign, .origin = origin, .id = fid, .sym = foreign.symbols.items[fid], .module_name = module_name, .name = name, .pos = pos };
    }

    /// Whether the declaration `d` names is public; reports it if not.
    fn checkPublic(self: *TypeResolver, d: ForeignDecl) Error!bool {
        if (d.sym.flags.is_public) return true;
        try sema.notPublic(self.ctx, d.pos, d.module_name, d.name, d.foreign);
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

    /// `module.Wrap` in `module.Wrap[Int]`: the proxy of a public generic
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
            // `lib.Wrap[Int]`: another module's generic type.
            sym_id = (try self.qualifiedGeneric(name_node)) orelse return t.invalid_id;
            pos = srcPos(ir.Member.name(name_node), 0);
        } else {
            const name = identAt(self.ctx.source, name_node).?;
            pos = name_node.src.pos;
            sym_id = self.ctx.lookup(self.scope, name) orelse {
                try self.ctx.err(pos, "use of unbound type `{s}`{s}", .{ name, try self.typeHint(name, pos) });
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
        var args: std.ArrayList(TypeId) = .empty;
        defer args.deinit(self.ctx.allocator);
        var any_bad = false;
        for (supplied, tparams, 0..) |a, tp, i| {
            const arg = if (self.ctx.symbols.items[tp].kind == .param)
                try self.resolveCtInt(a, .{ .arg = .{ .param = tp, .owner = name, .index = i } })
            else if (isValueSpelling(self.ctx.source, a)) blk: {
                try self.ctx.errAt(a, "`{s}` is a value; `{s}` takes a type", .{ try self.sourceText(a), self.ctx.symbols.items[tp].name });
                break :blk t.invalid_id;
            } else try self.resolveType(a);
            if (sema.containsPoison(self.ctx, arg) or try self.heldCallable(a, arg) or try self.misplacedAt(a, arg, .type_arg)) any_bad = true;
            try args.append(self.ctx.allocator, arg);
        }
        // An instance with a rejected argument is poison: what follows
        // from it was already reported.
        if (any_bad) return t.invalid_id;
        return self.instanceOf(sym_id, args.items, pos);
    }

    /// The type `sigil` over `inner` would be, as a diagnostic spells it.
    fn stackedSpelling(self: *TypeResolver, sigil: u8, inner: TypeId) Error![]const u8 {
        // A suffix binds tighter than a holding sigil: `*(~T?)`.
        const shown = try sema.formatType(self.ctx, inner);
        if (self.ctx.types.get(inner) == .optional) return self.ctx.arena.allocator().print("{c}({s})", .{ sigil, shown });
        return self.ctx.arena.allocator().print("{c}{s}", .{ sigil, shown });
    }

    /// `^T`: the built-in box of `T`, spelled at `pos`.
    pub fn boxOf(self: *TypeResolver, inner: TypeId, pos: u32) Error!TypeId {
        return self.instanceOf(self.ctx.box_sym_id, &.{inner}, pos);
    }

    /// The instance of generic `sym_id` at `args`, spelled at `pos`.
    fn instanceOf(self: *TypeResolver, sym_id: SymbolId, args_in: []const TypeId, pos: u32) Error!TypeId {
        if (sym_id == self.ctx.simd_sym_id) return simdInstance(self.ctx, args_in, pos);
        const sym = self.ctx.symbols.items[sym_id];
        const ty = try self.ctx.internCopy(.{ .parameterized_nominal = .{ .sym = sym_id, .args = args_in } });
        const inst = self.ctx.types.get(ty).parameterized_nominal;
        if (sym.decl_pos == sema.builtin_decl_pos) {
            try self.checkWhenResolved(.{ .builtin = .{ .pos = pos, .sym = sym_id, .args = inst.args } });
        }
        if (!sema.containsTypeVar(self.ctx, ty)) {
            if (sym.decl_pos != sema.builtin_decl_pos) try self.checkWhenResolved(.{ .instance_stacking = .{ .pos = pos, .ty = ty } });
            const gop = try self.ctx.instantiation_sites.getOrPut(self.ctx.allocator, ty);
            if (!gop.found_existing) gop.value_ptr.* = pos;
        } else {
            // Spelled inside a generic declaration: each instantiation of
            // that generic instantiates this too.
            try self.ctx.addGeneric(.uses, ty);
        }
        return ty;
    }
};

/// `Simd[T, n]`, spelled at `pos`: a vector, a type of its own kind
/// (`Type.simd`), not a generic instance. Its lanes are a number or
/// `Bool`, and `n` is a power of two from 2 to 64; a compile-time
/// parameter `n` is checked at each instance (`Requirement.lane_count`).
/// Poison after a diagnostic.
pub fn simdInstance(ctx: *SemContext, args: []const TypeId, pos: u32) Error!TypeId {
    const t = &ctx.types;
    if (args.len != 2 or sema.containsPoison(ctx, args[0]) or sema.containsPoison(ctx, args[1])) return t.invalid_id;
    const elem = args[0];
    const len = args[1];
    if (!sema.isLaneType(ctx, elem)) {
        try ctx.err(pos, "a lane of a `Simd` is a number or `Bool`; got `{s}`", .{try sema.formatType(ctx, elem)});
        return t.invalid_id;
    }
    switch (t.get(len)) {
        .ct_value => |v| if (!sema.lanesInRange(v.int)) {
            try ctx.err(pos, "a lane count is a power of two from 2 to 64; got {d}", .{v.int});
            return t.invalid_id;
        },
        .ct_param => |param| try ctx.generic_requirements.append(ctx.allocator, .{ .param = param, .req = .lane_count, .pos = pos, .op = "a lane count" }),
        else => return t.invalid_id,
    }
    return ctx.intern(.{ .simd = .{ .elem = elem, .len = len } });
}

/// Element-type rules of the built-in generics. An instance over generic
/// parameters (`List[T]` in `Stack[T]`) is checked for each instantiation
/// instead (`sema.expandInstantiations`).
pub fn builtinElementError(ctx: *SemContext, sym_id: SymbolId, args: []const TypeId) Error!?[]const u8 {
    if (args.len != 1 or sema.containsTypeVar(ctx, args[0])) return null;
    const a = ctx.arena.allocator();
    const arg = try sema.formatType(ctx, args[0]);
    if (sym_id == ctx.cell_sym_id) {
        if (sema.isPlainData(ctx, args[0]) or sema.moves(ctx, args[0]) == .yes) return null;
        return try a.print("`Cell[T]` requires `T` to be a value that copies (Int, Bool, Float, `?String`), plain data (an object, enum, optional, or array that owns nothing), a type that releases what it owns (`*T`, `~T`, `List[T]`, `*sub()`, a struct holding one of those or with a `drop` body), or a type declared `unique`; got `{s}`", .{arg});
    }
    if (sym_id == ctx.list_sym_id) {
        // A List holds any value, views included: its elements move in
        // and out whole, and each is a place (Core §5). A viewed
        // callable is only a parameter's, a local's, or a result's.
        if (!sema.holdsCallable(ctx, args[0])) return null;
        return try a.print(sema.held_callable, .{arg});
    }
    if (sym_id == ctx.signal_sym_id) {
        if (sema.isPlainData(ctx, args[0])) return null;
        return try a.print("`Signal[T]` requires `T` to be a value that copies (Int, Bool, Float, `?String`) or plain data (an object, enum, optional, or array that owns nothing); got `{s}`", .{arg});
    }
    return null;
}

/// A leaf match pattern that binds its name: not the wildcard `_`, and
/// not a literal (`1`, `true`).
pub fn patternBinds(source: []const u8, pattern: Sexp) bool {
    const text = identAt(source, pattern) orelse return false;
    for ([_][]const u8{ "_", "true", "false" }) |word| if (std.mem.eql(u8, text, word)) return false;
    return !sema.isIntLiteralText(text) and !sema.isFloatLiteralText(text);
}

const primitive_type_names = [_][]const u8{ "Int", "Float", "Bool", "String", "Static", "Void" };

fn primitiveTypeId(ctx: *const SemContext, name: []const u8) ?TypeId {
    const t = &ctx.types;
    const ids = [primitive_type_names.len]TypeId{ t.int_id, t.float_id, t.bool_id, t.string_id, t.static_id, t.void_id };
    for (primitive_type_names, ids) |n, id| {
        if (std.mem.eql(u8, name, n)) return id;
    }
    return null;
}

/// The bit width a sized type name spells: `I8`..`I128`, `U8`..`U128`,
/// `F32`, `F64`.
fn sizedTypeBits(name: []const u8) ?u8 {
    // No leading zero: `I08` is not `I8`.
    if (name.len < 2 or name.len > 4 or name[1] == '0') return null;
    const bits = std.fmt.parseInt(u8, name[1..], 10) catch return null;
    const ok = switch (name[0]) {
        'I', 'U' => bits == 8 or bits == 16 or bits == 32 or bits == 64 or bits == 128,
        'F' => bits == 32 or bits == 64,
        else => false,
    };
    return if (ok) bits else null;
}

/// A sized type. `I64` is `Int` and `F64` is `Float`: the same types
/// under their sized names.
fn sizedTypeId(ctx: *SemContext, name: []const u8) ?Error!TypeId {
    return ctx.intern(sizedType(name) orelse return null);
}

/// The type a sized type name spells: `I64` is `Int`, `F64` is `Float`.
fn sizedType(name: []const u8) ?Type {
    const bits = sizedTypeBits(name) orelse return null;
    return switch (name[0]) {
        'I' => .{ .int = .{ .bits = if (bits == 64) 0 else bits } },
        'U' => .{ .int = .{ .bits = bits, .signed = false } },
        else => .{ .float = .{ .bits = if (bits == 64) 0 else bits } },
    };
}

/// Every built-in type a name spells, once each (`I64` is `Int`): the
/// types `@name` of a type parameter names from a table (`emit`), which
/// is keyed by the Zig type. A `Static` is the Zig type of a `?String`, so
/// a type parameter bound to either is named `?String`.
pub fn builtinTypes(ctx: *const SemContext, a: std.mem.Allocator) Error![]const Type {
    var out: std.ArrayList(Type) = .empty;
    for (primitive_type_names) |name| {
        const ty = ctx.types.get(primitiveTypeId(ctx, name).?);
        if (ty != .static) try out.append(a, ty);
    }
    // The read view of a `String` has no name of its own, but `@name` names it.
    try out.append(a, ctx.types.get(ctx.types.string_view_id));
    // `error`, a keyword, is an error of any set.
    try out.append(a, ctx.types.get(ctx.types.any_error_id));
    var buf: [4]u8 = undefined;
    for ("IUF") |prefix| for ([_]u8{ 8, 16, 32, 64, 128 }) |bits| {
        const ty = sizedType(std.fmt.bufPrint(&buf, "{c}{d}", .{ prefix, bits }) catch unreachable) orelse continue;
        const seen = for (out.items) |t| {
            if (std.meta.eql(t, ty)) break true;
        } else false;
        if (!seen) try out.append(a, ty);
    };
    return out.items;
}

/// Whether `name` spells a built-in type: `Int`, `String`, `U8`, ...
pub fn isBuiltinTypeName(ctx: *const SemContext, name: []const u8) bool {
    return primitiveTypeId(ctx, name) != null or sizedTypeBits(name) != null or std.mem.eql(u8, name, "error");
}

/// Whether `name` spells a numeric type: `Int`, `Float`, or a sized one.
/// Called like a function, such a name converts a number to that type.
pub fn isNumericTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Int") or std.mem.eql(u8, name, "Float") or sizedTypeBits(name) != null;
}

// =============================================================================
// Built-in generic types
//
// `Cell[T]`, `List[T]`, `^T`, and `Signal[T]`, and the enum `Endian`, registered
// in every module scope before user declarations. The generics' methods
// are ordinary method Fields on generic symbols, so calls go through the
// same lookup and substitution as user generics; the runtime
// (`runtime.zig`) implements them.
// =============================================================================

const builtin_pos = sema.builtin_decl_pos;

// What the built-in methods that copy a `T` need of it: a `T` that
// copies (docs/CORE.md: sentence 1, for a copy out of what a method
// keeps; §5, "Only a value that copies is duplicated without `+`").

/// `c.get()` hands out a copy of the Cell's value.
const cell_get: sema.Needs = .{ .t = .copies, .op = "copies out with `Cell.get` a value", .says = .{
    .value_out = "write `(!cell).replace(<new)`, which puts `new` in and hands back the old value",
} };

/// `xs.get(i)` hands out a copy of an element.
const list_get: sema.Needs = .{ .t = .copies, .op = "copies an element out of a List", .says = .{
    .element_out = "read it in place with `v[i]`, or lend it with `?v[i]`",
} };

/// `List.filled(n, x)` writes a copy of `x` into every element.
const list_filled: sema.Needs = .{ .t = .copies, .op = "copies into every element of `List.filled` a value", .says = .{
    .into_elements = .{ .what = "`List.filled` copies its value into every element", .loop = "`for 0..n` with `!xs.push(+x)`" },
} };

/// `!xs.resize(n, x)` writes a copy of `x` into every element it adds.
/// The element type decides, so a call that only shrinks needs it too.
const list_resize: sema.Needs = .{ .t = .copies, .op = "copies into every element `resize` adds a value", .says = .{
    .into_elements = .{ .what = "`resize` copies its value into every element it adds", .loop = "`for xs.len..n` with `!xs.push(+x)`", .tail = "; `!xs.keep(n)` shrinks any List" },
} };

/// `s.get()` hands out a copy of the Signal's value, which every
/// `Signal[T]` holds as plain data (`builtinElementError`).
const signal_get: sema.Needs = .{ .t = .copies, .op = "copies out with `Signal.get` a value", .says = .{
    .value_out = "a `Signal` holds only plain data",
} };

pub fn registerBuiltins(ctx: *SemContext, module_scope: ScopeId) Error!void {
    // Cell[T]: the slot a shared handle shares. What changes it takes
    // `!self`, so a call marks the change: `!c.set(5)`.
    {
        const g = try addGeneric(ctx, module_scope, module_scope, "Cell", &.{"T"});
        ctx.cell_sym_id = g.sym;
        const t = g.params[0];
        const self_ty = try ctx.intern(.{ .read_view = g.self_ty });
        const write_self = try ctx.intern(.{ .write_view = g.self_ty });
        try setFields(ctx, g.sym, &.{
            .{ .name = "value", .ty = t, .decl_pos = builtin_pos },
            try method(ctx, "get", .read, &.{self_ty}, t, &cell_get),
            try method(ctx, "set", .write, &.{ write_self, t }, ctx.types.void_id, null),
            // Swap in a new value and return the old one as owned.
            try method(ctx, "replace", .write, &.{ write_self, t }, t, null),
        });
    }

    // List[T]: growable buffer that owns its elements.
    {
        const g = try addGeneric(ctx, module_scope, module_scope, "List", &.{"T"});
        ctx.list_sym_id = g.sym;
        const t = g.params[0];
        const read_self = try ctx.intern(.{ .read_view = g.self_ty });
        const write_self = try ctx.intern(.{ .write_view = g.self_ty });
        const opt_t = try ctx.intern(.{ .optional = t });
        try setFields(ctx, g.sym, &.{
            try method(ctx, "push", .write, &.{ write_self, t }, ctx.types.void_id, null),
            try method(ctx, "clear", .write, &.{write_self}, ctx.types.void_id, null),
            try method(ctx, "keep", .write, &.{ write_self, ctx.types.int_id }, ctx.types.void_id, null),
            try method(ctx, "reserve", .write, &.{ write_self, ctx.types.int_id }, ctx.types.void_id, null),
            try method(ctx, "get", .read, &.{ read_self, ctx.types.int_id }, opt_t, &list_get),
            try method(ctx, "pop", .write, &.{write_self}, opt_t, null),
            try method(ctx, "insert", .write, &.{ write_self, ctx.types.int_id, t }, ctx.types.void_id, null),
            try method(ctx, "remove", .write, &.{ write_self, ctx.types.int_id }, t, null),
            try method(ctx, "resize", .write, &.{ write_self, ctx.types.int_id, t }, ctx.types.void_id, &list_resize),
            // `List.filled(n, x)`: called through the type.
            try method(ctx, "filled", .none, &.{ ctx.types.int_id, t }, g.self_ty, &list_filled),
        });
    }

    // `^T`: one T on the heap, owned by the box. Its fields and methods
    // are reached through it; `unbox` moves the value out. No name
    // reaches it: `^` writes the type, and the symbol is named for how
    // a diagnostic would spell it.
    {
        const g = try addGeneric(ctx, null, module_scope, "^", &.{"T"});
        ctx.box_sym_id = g.sym;
        const t = g.params[0];
        try setFields(ctx, g.sym, &.{
            .{ .name = "value", .ty = t, .decl_pos = builtin_pos },
            try method(ctx, "unbox", .value, &.{g.self_ty}, t, null),
        });
    }

    // Endian: the byte order `read` and `write` take, `.little` or `.big`.
    {
        const sym = try ctx.addSymbol(.{
            .name = "Endian",
            .kind = .nominal_type,
            .ty = ctx.types.unknown_id,
            .decl_pos = builtin_pos,
            .scope = module_scope,
        });
        try ctx.addToScope(module_scope, sym);
        ctx.endian_sym_id = sym;
        try setFields(ctx, sym, &.{
            .{ .name = "little", .ty = ctx.types.void_id, .decl_pos = builtin_pos, .is_variant = true },
            .{ .name = "big", .ty = ctx.types.void_id, .decl_pos = builtin_pos, .is_variant = true },
        });
    }

    // Arch: the target's processor architecture, which `std.target`'s
    // `arch` gives. Its variants are Zig's (`std.Target.Cpu.Arch`), all of
    // them, and it lowers to that type, so every target Zig compiles for
    // has a name and none needs mapping.
    {
        const sym = try ctx.addSymbol(.{
            .name = "Arch",
            .kind = .nominal_type,
            .ty = ctx.types.unknown_id,
            .decl_pos = builtin_pos,
            .scope = module_scope,
        });
        try ctx.addToScope(module_scope, sym);
        ctx.arch_sym_id = sym;
        const names = @typeInfo(std.Target.Cpu.Arch).@"enum".field_names;
        var variants: [names.len]sema.Field = undefined;
        for (names, &variants) |n, *v| v.* = .{ .name = n, .ty = ctx.types.void_id, .decl_pos = builtin_pos, .is_variant = true };
        try setFields(ctx, sym, &variants);
    }

    // Simd[T, n: Int]: a vector of `n` lanes. An instance is a type of
    // its own kind (`simdInstance`), whose operators and methods typing
    // knows; the symbol only names it, so it is reserved like `List`.
    {
        const g = try addGeneric(ctx, module_scope, module_scope, "Simd", &.{ "T", "n" });
        ctx.simd_sym_id = g.sym;
        const n = ctx.symbols.items[g.sym].type_params.?[1];
        ctx.symbols.items[n].kind = .param;
        ctx.symbols.items[n].ty = ctx.types.int_id;
    }

    // Signal[T]: a value that copies, plus subscriber closures notified on `set`.
    {
        const g = try addGeneric(ctx, module_scope, module_scope, "Signal", &.{"T"});
        ctx.signal_sym_id = g.sym;
        const t = g.params[0];
        const self_ty = try ctx.intern(.{ .read_view = g.self_ty });
        const write_self = try ctx.intern(.{ .write_view = g.self_ty });
        // Subscribers are owned closures `*sub()`.
        const callback = try ctx.intern(.{ .function = .{ .params = &.{}, .returns = ctx.types.void_id, .is_sub = true } });
        const closure_handle = try ctx.intern(.{ .shared = callback });
        try setFields(ctx, g.sym, &.{
            .{ .name = "value", .ty = t, .decl_pos = builtin_pos },
            try method(ctx, "get", .read, &.{self_ty}, t, &signal_get),
            try method(ctx, "set", .write, &.{ write_self, t }, ctx.types.void_id, null),
            try method(ctx, "subscribe", .write, &.{ write_self, closure_handle }, ctx.types.void_id, null),
        });
    }
}

const Generic = struct {
    sym: SymbolId,
    /// `type_var` TypeIds of the parameters, in order.
    params: []const TypeId,
    /// The type applied to its own parameters: `List[T]`.
    self_ty: TypeId,
};

/// A built-in generic type, named in `named_in` when a name reaches it.
fn addGeneric(ctx: *SemContext, named_in: ?ScopeId, module_scope: ScopeId, name: []const u8, param_names: []const []const u8) Error!Generic {
    const sym = try ctx.addSymbol(.{
        .name = name,
        .kind = .generic_type,
        .ty = ctx.types.unknown_id,
        .decl_pos = builtin_pos,
        .scope = module_scope,
    });
    if (named_in) |scope| try ctx.addToScope(scope, sym);

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

/// A built-in method, with what it needs of its type's parameter `T`
/// (`sema.Needs`), or null when it needs nothing: every method that
/// copies a `T`, out of what it keeps or into elements it makes, says so.
fn method(ctx: *SemContext, name: []const u8, receiver: MethodReceiver, params: []const TypeId, returns: TypeId, needs: ?*const sema.Needs) Error!Field {
    const ty = try ctx.intern(.{ .function = .{
        .params = try ctx.dupeIds(params),
        .returns = returns,
        .is_sub = returns == ctx.types.void_id,
    } });
    return .{ .name = name, .ty = ty, .decl_pos = builtin_pos, .is_method = true, .receiver = receiver, .needs = needs };
}

fn setFields(ctx: *SemContext, sym: SymbolId, fields: []const Field) Error!void {
    ctx.symbols.items[sym].fields = try ctx.arena.allocator().dupe(Field, fields);
}

test "builtins: registered with methods" {
    var ctx = try SemContext.init(std.testing.allocator, "");
    defer ctx.deinit();
    const scope = try ctx.pushScopeKind(sema.scope_invalid, .module);
    try registerBuiltins(&ctx, scope);
    const list = ctx.lookup(scope, "List").?;
    try std.testing.expectEqual(ctx.list_sym_id, list);
    try std.testing.expectEqual(@as(usize, 10), ctx.symbols.items[list].fields.?.len);
    try std.testing.expect(ctx.lookup(scope, "T") == null);
}

test "builtins: a method that declares needs is a generic type's, with a T" {
    var ctx = try SemContext.init(std.testing.allocator, "");
    defer ctx.deinit();
    const scope = try ctx.pushScopeKind(sema.scope_invalid, .module);
    try registerBuiltins(&ctx, scope);
    var declared: usize = 0;
    for (ctx.symbols.items) |sym| for (sym.fields orelse &.{}) |f| if (f.needs != null) {
        // `meetsNeeds` reads `T` from the type's arguments at the call.
        try std.testing.expect(f.is_method);
        try std.testing.expectEqual(sema.SymbolKind.generic_type, sym.kind);
        try std.testing.expect(sym.type_params != null and sym.type_params.?.len >= 1);
        declared += 1;
    };
    // `Cell.get`, `List.get`, `List.filled`, `List.resize`, `Signal.get`.
    try std.testing.expectEqual(@as(usize, 5), declared);
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
