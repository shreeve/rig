//! Rig Zig Emitter (M3).
//!
//! Lowers the normalized semantic IR (from `rig.Parser`) to Zig 0.16
//! source. Boring lowering first; clever later.
//!
//! Per GPT-5.5 review:
//!   - `print x` lowers to `std.debug.print("{s}\n", .{x})` for strings,
//!     `{any}` otherwise.
//!   - `(set x e)` first occurrence in fn scope → `var x = e;` ; rebind
//!     → `x = e;`. Tracked via per-scope symbol table.
//!   - `(shadow x e)` always emits a fresh Zig symbol (`x_1`, `x_2`, ...)
//!     because Zig forbids name shadowing.
//!   - `(fixed_bind x e)` / `(typed_fixed x T e)` → `const`.
//!   - `(propagate e)` → `try e`.
//!   - `(try_block ...)` value-yielding form: emitter unsupported in MVP.
//!   - Ownership wrappers (`(read x)`, `(write x)`, `(move x)`, `(clone x)`)
//!     just emit the inner expression for V1 — semantics are enforced by
//!     M2 and Zig's regular semantics handle the runtime side.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");

const Sexp = parser.Sexp;
const Tag = rig.Tag;
const BindingKind = rig.BindingKind;
const Writer = std.Io.Writer;

pub const Error = std.mem.Allocator.Error || Writer.Error || rig.BindingKindError;

const SymbolEntry = struct {
    rig_name: []const u8,
    zig_name: []const u8, // may differ from rig_name due to shadowing
};

const ScopeFrame = struct {
    symbols: std.ArrayListUnmanaged(SymbolEntry),
};

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    w: *Writer,
    indent: u32 = 0,

    /// All emitter-allocated strings (currently just `freshShadow`'s
    /// generated `x_<n>` names) live in this arena. `deinit` frees the
    /// whole arena in one call, so we don't need per-allocation
    /// bookkeeping. Without this, `freshShadow` allocations leaked under
    /// the test allocator (the CLI's outer arena masked the bug).
    name_arena: std.heap.ArenaAllocator,

    /// Stack of per-block scope frames. Symbol lookup walks up.
    scopes: std.ArrayListUnmanaged(ScopeFrame) = .empty,

    /// Counter for shadow-renames: each `new x = ...` gets `x_<n>`.
    shadow_counter: u32 = 0,

    /// Per-function pre-scan: names that are reassigned in the body,
    /// so they need `var` instead of `const` in Zig. Reset at the
    /// start of each `emitFun`.
    fn_mutated: std.StringHashMapUnmanaged(void) = .{},

    /// True iff THIS function's declared return type is `(error_union T)`
    /// — set per-function in `emitFun` from the IR, NOT from body
    /// inspection. The effects checker (src/effects.zig) is responsible
    /// for ensuring body-level fallibility matches the declaration.
    fn_is_fallible: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, w: *Writer) Emitter {
        return .{
            .allocator = allocator,
            .source = source,
            .w = w,
            .name_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Emitter) void {
        for (self.scopes.items) |*s| s.symbols.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.fn_mutated.deinit(self.allocator);
        self.name_arena.deinit();
    }

    pub fn emit(self: *Emitter, sexp: Sexp) Error!void {
        try self.w.writeAll("const std = @import(\"std\");\n");
        if (sexp == .list and sexp.list.len > 0 and sexp.list[0] == .tag and
            sexp.list[0].tag == .@"module")
        {
            for (sexp.list[1..]) |child| {
                try self.w.writeAll("\n");
                try self.emitDecl(child);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Top-level declarations
    // -------------------------------------------------------------------------

    fn emitDecl(self: *Emitter, sexp: Sexp) Error!void {
        if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) return;
        const items = sexp.list;
        switch (items[0].tag) {
            .@"fun" => try self.emitFun(items, false),
            .@"sub" => try self.emitFun(items, true),
            .@"use" => try self.emitUse(items),
            .@"pub" => {
                // V1: Rig has no module system, so functions are public by
                // default and `emitFun` always prefixes `pub`. The explicit
                // `(pub child)` wrapper is therefore redundant — strip it
                // and recurse without injecting another `pub` (the prior
                // `try writeAll("pub ")` here produced `pub pub fn ...`).
                if (items.len >= 2) try self.emitDecl(items[1]);
            },
            else => try self.emitUnsupported("top-level decl"),
        }
    }

    fn emitUse(self: *Emitter, items: []const Sexp) Error!void {
        // (use name) → const <name> = @import("<name>");
        // Skip `std` because we always inject `const std = @import("std");`
        // at the top of the emitted file.
        if (items.len < 2) return;
        const name = identText(self.source, items[1]) orelse return;
        if (std.mem.eql(u8, name, "std")) return;
        try self.w.print("const {s} = @import(\"{s}\");\n", .{ name, name });
    }

    fn emitFun(self: *Emitter, items: []const Sexp, is_sub: bool) Error!void {
        // Both shapes are position-stable as (head name params returns body),
        // with returns = nil for `sub` and for `fun` without explicit return type.
        if (items.len < 5) return;
        const name = identText(self.source, items[1]) orelse "anon";
        const params = items[2];
        const returns_node: ?Sexp = if (is_sub) null else items[3];
        const body = items[4];

        // Per-fn pre-scan: mutation analysis (var vs const) only.
        // Fallibility comes from the IR (declared return type), not body
        // inspection — the effects checker enforces that they agree.
        self.fn_mutated.clearRetainingCapacity();
        try scanMutations(&self.fn_mutated, self.allocator, body, self.source);

        // Special case: `sub main()` lowers to `pub fn main() !void` if its
        // body propagates, matching Zig's `pub fn main() !void` idiom. The
        // effects checker explicitly allows this for `main`.
        const is_main_sub = is_sub and std.mem.eql(u8, name, "main");
        const main_uses_propagate = is_main_sub and containsPropagate(body);
        self.fn_is_fallible = main_uses_propagate or
            (returns_node != null and isErrorUnion(returns_node.?));

        try self.w.print("pub fn {s}(", .{name});
        try self.emitParams(params);
        try self.w.writeAll(") ");

        // Return type — emit exactly what the IR declares (no signature
        // inference). For `sub` we always emit `void` unless the special
        // main-propagates case promotes to `!void`.
        if (is_sub) {
            if (main_uses_propagate) try self.w.writeAll("!void ") else try self.w.writeAll("void ");
        } else if (returns_node) |r| {
            try self.emitType(r);
            try self.w.writeAll(" ");
        } else {
            try self.w.writeAll("void ");
        }

        // Body. For non-sub functions with a return type, the last
        // statement of the block is the implicit return value and is
        // emitted as `return <expr>;`.
        try self.pushScope();
        if (params == .list) {
            for (params.list) |p| try self.bindParam(p);
        }
        if (is_sub) {
            try self.emitBlock(body);
        } else {
            try self.emitFunBody(body);
        }
        try self.popScope();
        try self.w.writeAll("\n");
    }

    /// Like emitBlock, but rewrites the last expression-statement to a
    /// `return <expr>;` so a `fun foo() -> Int { 1 + 2 }` actually returns.
    fn emitFunBody(self: *Emitter, body: Sexp) Error!void {
        try self.w.writeAll("{\n");
        self.indent += 1;
        try self.pushScope();

        const stmts: []const Sexp = if (body == .list and body.list.len > 0 and
            body.list[0] == .tag and body.list[0].tag == .@"block")
            body.list[1..]
        else
            &[_]Sexp{body};

        for (stmts, 0..) |stmt, i| {
            try self.indentSpaces();
            if (i == stmts.len - 1 and isExprStmt(stmt)) {
                try self.w.writeAll("return ");
                try self.emitExpr(stmt);
                try self.w.writeAll(";");
            } else {
                try self.emitStmt(stmt);
            }
            try self.w.writeAll("\n");
        }
        try self.popScope();
        self.indent -= 1;
        try self.indentSpaces();
        try self.w.writeAll("}");
    }

    fn emitParams(self: *Emitter, params: Sexp) Error!void {
        if (params != .list) return;
        var first = true;
        for (params.list) |p| {
            if (!first) try self.w.writeAll(", ");
            first = false;
            try self.emitParam(p);
        }
    }

    fn emitParam(self: *Emitter, p: Sexp) Error!void {
        // Param shapes: name | (: name type) | (pre_param name type) | (default name type expr)
        switch (p) {
            .src => |s| try self.w.print("{s}: anytype", .{self.source[s.pos..][0..s.len]}),
            .list => |items| {
                if (items.len < 2 or items[0] != .tag) return;
                switch (items[0].tag) {
                    .@":" => {
                        const name = identText(self.source, items[1]) orelse "_";
                        try self.w.print("{s}: ", .{name});
                        if (items.len >= 3) try self.emitType(items[2]) else try self.w.writeAll("anytype");
                    },
                    .pre_param => {
                        const name = identText(self.source, items[1]) orelse "_";
                        try self.w.print("comptime {s}: ", .{name});
                        if (items.len >= 3) try self.emitType(items[2]) else try self.w.writeAll("anytype");
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn bindParam(self: *Emitter, p: Sexp) Error!void {
        var name_node: Sexp = .{ .nil = {} };
        switch (p) {
            .src => name_node = p,
            .list => {
                if (p.list.len >= 2 and p.list[0] == .tag) {
                    switch (p.list[0].tag) {
                        .@":", .pre_param, .default, .aligned => name_node = p.list[1],
                        else => {},
                    }
                }
            },
            else => return,
        }
        if (name_node != .src) return;
        const nm = self.source[name_node.src.pos..][0..name_node.src.len];
        try self.declare(nm, nm);
    }

    // -------------------------------------------------------------------------
    // Scope / symbol table
    // -------------------------------------------------------------------------

    fn pushScope(self: *Emitter) Error!void {
        try self.scopes.append(self.allocator, .{ .symbols = .empty });
    }

    fn popScope(self: *Emitter) Error!void {
        if (self.scopes.items.len == 0) return;
        var top = self.scopes.pop().?;
        top.symbols.deinit(self.allocator);
    }

    fn declare(self: *Emitter, rig_name: []const u8, zig_name: []const u8) Error!void {
        if (self.scopes.items.len == 0) try self.pushScope();
        const top = &self.scopes.items[self.scopes.items.len - 1];
        try top.symbols.append(self.allocator, .{ .rig_name = rig_name, .zig_name = zig_name });
    }

    /// Look up the Zig name for a Rig name, walking scopes.
    fn lookup(self: *Emitter, rig_name: []const u8) ?[]const u8 {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const frame = &self.scopes.items[i];
            var j = frame.symbols.items.len;
            while (j > 0) {
                j -= 1;
                const s = frame.symbols.items[j];
                if (std.mem.eql(u8, s.rig_name, rig_name)) return s.zig_name;
            }
        }
        return null;
    }

    fn lookupCurrent(self: *Emitter, rig_name: []const u8) ?[]const u8 {
        if (self.scopes.items.len == 0) return null;
        const frame = &self.scopes.items[self.scopes.items.len - 1];
        for (frame.symbols.items) |s| {
            if (std.mem.eql(u8, s.rig_name, rig_name)) return s.zig_name;
        }
        return null;
    }

    fn freshShadow(self: *Emitter, base: []const u8) Error![]const u8 {
        self.shadow_counter += 1;
        // Allocated in `name_arena` so deinit reclaims everything. The
        // generated name is referenced by `SymbolEntry.zig_name`, which
        // lives only as long as the Emitter, so arena lifetime is right.
        return try std.fmt.allocPrint(self.name_arena.allocator(), "{s}_{d}", .{ base, self.shadow_counter });
    }

    /// Emit a Rig single-quoted string literal as a Zig double-quoted
    /// string literal. `text` includes the surrounding quotes.
    ///
    /// Rules:
    ///   `\'` in source → `'` in output (escape no longer needed)
    ///   `"`  in source → `\"` in output (must escape now)
    ///   everything else (including `\n`, `\t`, `\\`, etc.) passes through
    fn emitSingleQuotedAsZigString(self: *Emitter, text: []const u8) Error!void {
        try self.w.writeAll("\"");
        const inner = text[1 .. text.len - 1];
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            const c = inner[i];
            if (c == '\\' and i + 1 < inner.len and inner[i + 1] == '\'') {
                try self.w.writeAll("'");
                i += 1;
            } else if (c == '"') {
                try self.w.writeAll("\\\"");
            } else {
                try self.w.writeByte(c);
            }
        }
        try self.w.writeAll("\"");
    }

    // -------------------------------------------------------------------------
    // Statements / blocks
    // -------------------------------------------------------------------------

    fn emitBlock(self: *Emitter, body: Sexp) Error!void {
        try self.w.writeAll("{\n");
        self.indent += 1;
        try self.pushScope();
        if (body == .list and body.list.len > 0 and body.list[0] == .tag and
            body.list[0].tag == .@"block")
        {
            for (body.list[1..]) |stmt| {
                try self.indentSpaces();
                try self.emitStmt(stmt);
                try self.w.writeAll("\n");
            }
        } else {
            try self.indentSpaces();
            try self.emitStmt(body);
            try self.w.writeAll("\n");
        }
        try self.popScope();
        self.indent -= 1;
        try self.indentSpaces();
        try self.w.writeAll("}");
    }

    fn emitStmt(self: *Emitter, sexp: Sexp) Error!void {
        if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) {
            try self.emitExpr(sexp);
            try self.w.writeAll(";");
            return;
        }
        const items = sexp.list;
        switch (items[0].tag) {
            .@"set" => try self.emitSet(items),
            .@"drop" => {
                // No-op for V1 (Zig handles cleanup at scope or via deinit).
                try self.w.writeAll("// drop ");
                if (items.len >= 2) try self.emitExpr(items[1]);
            },
            .@"return" => try self.emitReturn(items),
            .@"if" => try self.emitIf(items),
            .@"while" => try self.emitWhile(items),
            .@"for" => try self.emitFor(items),
            .@"block" => try self.emitBlock(sexp),
            .@"break" => try self.w.writeAll("break;"),
            .@"continue" => try self.w.writeAll("continue;"),
            .@"defer" => {
                try self.w.writeAll("defer ");
                if (items.len >= 2) try self.emitStmt(items[1]);
            },
            .@"errdefer" => {
                try self.w.writeAll("errdefer ");
                if (items.len >= 2) try self.emitStmt(items[1]);
            },
            else => {
                try self.emitExpr(sexp);
                try self.w.writeAll(";");
            },
        }
    }

    fn emitSet(self: *Emitter, items: []const Sexp) Error!void {
        // Unified 5-child shape: (set <kind> name type-or-_ expr).
        // BindingKind is exhaustive, so the switch below is checked by Zig.
        if (items.len < 5) return;
        const kind = try rig.bindingKindOf(items[1]);
        const name = identText(self.source, items[2]) orelse return;
        const type_node = items[3];
        const expr = items[4];

        switch (kind) {
            .@"+=", .@"-=", .@"*=", .@"/=" => try self.emitCompoundAssign(name, kind, expr),
            .@"move", .default => try self.emitSetOrBind(name, type_node, expr, false, false),
            .fixed => try self.emitSetOrBind(name, type_node, expr, true, false),
            .shadow => try self.emitSetOrBind(name, type_node, expr, false, true),
        }
        // Exhaustive on BindingKind — Zig enforces.
    }

    fn emitCompoundAssign(self: *Emitter, name: []const u8, kind: BindingKind, expr: Sexp) Error!void {
        const zig_name = self.lookup(name) orelse name;
        const op_str: []const u8 = switch (kind) {
            .@"+=" => "+=",
            .@"-=" => "-=",
            .@"*=" => "*=",
            .@"/=" => "/=",
            else => unreachable,
        };
        try self.w.print("{s} {s} ", .{ zig_name, op_str });
        try self.emitExpr(expr);
        try self.w.writeAll(";");
    }

    fn emitSetOrBind(
        self: *Emitter,
        name: []const u8,
        type_node: Sexp,
        expr: Sexp,
        is_fixed: bool,
        is_shadow: bool,
    ) Error!void {
        const has_type = type_node != .nil;
        var zig_name: []const u8 = name;
        const found = self.lookup(name);

        if (is_shadow or found == null) {
            if (is_shadow and found != null) {
                // Mark the shadowed binding as "used" so Zig doesn't error
                // on the now-unreachable original.
                try self.w.print("_ = {s}; ", .{found.?});
                zig_name = try self.freshShadow(name);
            }
            try self.declare(name, zig_name);
            // `var` only if reassigned later. `=!` always emits `const`.
            const is_mutated = self.fn_mutated.contains(name);
            const decl_kw: []const u8 = if (is_fixed or !is_mutated) "const" else "var";
            if (has_type) {
                try self.w.print("{s} {s}: ", .{ decl_kw, zig_name });
                try self.emitType(type_node);
                try self.w.writeAll(" = ");
            } else {
                try self.w.print("{s} {s} = ", .{ decl_kw, zig_name });
            }
            try self.emitExpr(expr);
            try self.w.writeAll(";");
        } else {
            try self.w.print("{s} = ", .{found.?});
            try self.emitExpr(expr);
            try self.w.writeAll(";");
        }
    }

    fn emitReturn(self: *Emitter, items: []const Sexp) Error!void {
        if (items.len < 2) {
            try self.w.writeAll("return;");
            return;
        }
        try self.w.writeAll("return ");
        try self.emitExpr(items[1]);
        try self.w.writeAll(";");
    }

    fn emitIf(self: *Emitter, items: []const Sexp) Error!void {
        // (if cond then else?)
        if (items.len < 3) return;
        try self.w.writeAll("if (");
        try self.emitExpr(items[1]);
        try self.w.writeAll(") ");
        try self.emitBlockOrInline(items[2]);
        if (items.len >= 4) {
            try self.w.writeAll(" else ");
            try self.emitBlockOrInline(items[3]);
        }
    }

    fn emitWhile(self: *Emitter, items: []const Sexp) Error!void {
        if (items.len < 4) return;
        try self.w.writeAll("while (");
        try self.emitExpr(items[1]);
        try self.w.writeAll(") ");
        try self.emitBlockOrInline(items[3]);
    }

    fn emitFor(self: *Emitter, items: []const Sexp) Error!void {
        // (for <mode> binding1 binding2-or-_ source body else?)
        //
        // Mode is informational for V1 (Zig's `for` doesn't distinguish
        // borrow modes); ownership semantics were enforced by M2.
        // mode = `ptr` could lower to Zig's `for (xs) |*x| { ... }` for
        // pointer iteration; for V1 we emit plain `for (xs) |x| { ... }`
        // and let Zig figure out the binding shape from context.
        if (items.len < 6) return;
        const binding1 = items[2];
        const binding2 = items[3];
        const source = items[4];
        const body = items[5];

        try self.w.writeAll("for (");
        try self.emitExpr(source);
        try self.w.writeAll(") |");
        if (binding1 == .src) try self.w.writeAll(self.source[binding1.src.pos..][0..binding1.src.len]);
        if (binding2 == .src) {
            try self.w.writeAll(", ");
            try self.w.writeAll(self.source[binding2.src.pos..][0..binding2.src.len]);
        }
        try self.w.writeAll("| ");
        try self.emitBlockOrInline(body);
    }

    fn emitBlockOrInline(self: *Emitter, sexp: Sexp) Error!void {
        if (sexp == .list and sexp.list.len > 0 and sexp.list[0] == .tag and
            sexp.list[0].tag == .@"block")
        {
            try self.emitBlock(sexp);
        } else {
            try self.w.writeAll("{ ");
            try self.emitStmt(sexp);
            try self.w.writeAll(" }");
        }
    }

    // -------------------------------------------------------------------------
    // Expressions
    // -------------------------------------------------------------------------

    fn emitExpr(self: *Emitter, sexp: Sexp) Error!void {
        switch (sexp) {
            .nil => try self.w.writeAll("undefined"),
            .src => |s| {
                const text = self.source[s.pos..][0..s.len];
                // If this is a known Rig binding, emit the Zig name
                // (handles shadow renaming).
                if (self.lookup(text)) |zig_name| {
                    try self.w.writeAll(zig_name);
                } else if (text.len >= 2 and text[0] == '\'' and text[text.len - 1] == '\'') {
                    // Single-quoted Rig string → double-quoted Zig string.
                    // Zig's `'x'` is a u8 character literal, not a string,
                    // so passing source verbatim produces a syntax error
                    // for anything but a single-char literal. Emit a
                    // properly-escaped Zig string literal instead.
                    try self.emitSingleQuotedAsZigString(text);
                } else {
                    try self.w.writeAll(text);
                }
            },
            .str => |s| try self.w.writeAll(s),
            .tag => try self.w.writeAll(@tagName(sexp.tag)),
            .list => |items| {
                if (items.len == 0) {
                    try self.w.writeAll("undefined");
                    return;
                }
                if (items[0] != .tag) {
                    try self.w.writeAll("undefined");
                    return;
                }
                try self.emitExprList(items);
            },
        }
    }

    fn emitExprList(self: *Emitter, items: []const Sexp) Error!void {
        const head = items[0].tag;
        switch (head) {
            // Ownership wrappers: emit inner (Zig handles ref/move at runtime;
            // M2 already enforced ownership semantics).
            .@"move", .@"read", .@"write", .@"clone", .@"share", .@"weak", .@"pin", .@"raw" => {
                if (items.len >= 2) try self.emitExpr(items[1]);
            },
            // Calls
            .@"call" => try self.emitCall(items),
            // Member / index
            .@"member" => {
                if (items.len >= 3) {
                    try self.emitExpr(items[1]);
                    try self.w.writeAll(".");
                    try self.emitExpr(items[2]);
                }
            },
            .@"deref" => {
                if (items.len >= 2) {
                    try self.emitExpr(items[1]);
                    try self.w.writeAll(".*");
                }
            },
            .@"index" => {
                if (items.len >= 3) {
                    try self.emitExpr(items[1]);
                    try self.w.writeAll("[");
                    try self.emitExpr(items[2]);
                    try self.w.writeAll("]");
                }
            },
            .@"builtin" => {
                if (items.len >= 2) {
                    try self.w.writeAll("@");
                    try self.emitExpr(items[1]);
                    try self.w.writeAll("(");
                    var first = true;
                    for (items[2..]) |arg| {
                        if (!first) try self.w.writeAll(", ");
                        first = false;
                        try self.emitExpr(arg);
                    }
                    try self.w.writeAll(")");
                }
            },
            .@"propagate", .@"try" => {
                // `expr!` and `try expr` both lower to Zig `try expr`.
                // No `in_try_context` bookkeeping needed: the emitter is
                // dumb here, and the effects checker has already proven
                // that the underlying call is fallible-allowed.
                try self.w.writeAll("try ");
                if (items.len >= 2) try self.emitExpr(items[1]);
            },
            .@"neg" => {
                try self.w.writeAll("-");
                if (items.len >= 2) try self.emitExpr(items[1]);
            },
            .@"not" => {
                try self.w.writeAll("!");
                if (items.len >= 2) try self.emitExpr(items[1]);
            },
            .@"addr_of" => {
                try self.w.writeAll("&");
                if (items.len >= 2) try self.emitExpr(items[1]);
            },
            .@"enum_lit" => {
                try self.w.writeAll(".");
                if (items.len >= 2) try self.emitExpr(items[1]);
            },
            // Infix arithmetic / comparison / logic — emit `(a OP b)`.
            .@"+", .@"-", .@"*", .@"/", .@"%",
            .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=",
            .@"&&", .@"||", .@"&", .@"|", .@"^", .@"<<", .@">>",
            => try self.emitInfix(items, head),
            // Block-as-expression (e.g., `if cond block else block` returning value)
            .@"block" => try self.emitBlock(.{ .list = items }),
            else => {
                try self.w.writeAll("@compileError(\"rig: emitter does not yet support `");
                try self.w.writeAll(@tagName(head));
                try self.w.writeAll("`\")");
            },
        }
    }

    fn emitCall(self: *Emitter, items: []const Sexp) Error!void {
        // (call fn args...)
        // Special: `print` as builtin → std.debug.print.
        if (items.len >= 2 and items[1] == .src) {
            const fn_name = self.source[items[1].src.pos..][0..items[1].src.len];
            if (std.mem.eql(u8, fn_name, "print")) {
                try self.emitPrint(items[2..]);
                return;
            }
        }
        if (items.len < 2) return;

        // Distinguish positional vs constructor-call (record):
        // If ANY arg is a (kwarg ...), emit as `Type{ .name = value, ... }`.
        var has_kwarg = false;
        for (items[2..]) |arg| {
            if (arg == .list and arg.list.len > 0 and arg.list[0] == .tag and
                arg.list[0].tag == .@"kwarg")
            {
                has_kwarg = true;
                break;
            }
        }

        try self.emitExpr(items[1]);
        if (has_kwarg) {
            try self.w.writeAll("{ ");
            var first = true;
            for (items[2..]) |arg| {
                if (!first) try self.w.writeAll(", ");
                first = false;
                if (arg == .list and arg.list.len >= 3 and arg.list[0] == .tag and
                    arg.list[0].tag == .@"kwarg")
                {
                    try self.w.writeAll(".");
                    try self.emitExpr(arg.list[1]);
                    try self.w.writeAll(" = ");
                    try self.emitExpr(arg.list[2]);
                } else {
                    try self.emitExpr(arg);
                }
            }
            try self.w.writeAll(" }");
        } else {
            try self.w.writeAll("(");
            var first = true;
            for (items[2..]) |arg| {
                if (!first) try self.w.writeAll(", ");
                first = false;
                try self.emitExpr(arg);
            }
            try self.w.writeAll(")");
        }
    }

    fn emitPrint(self: *Emitter, args: []const Sexp) Error!void {
        if (args.len == 0) {
            try self.w.writeAll("std.debug.print(\"\\n\", .{})");
            return;
        }
        // V1: single arg only.
        const arg = args[0];
        const is_str = self.isStringLiteral(arg);
        const fmt: []const u8 = if (is_str) "{s}\\n" else "{any}\\n";
        try self.w.print("std.debug.print(\"{s}\", .{{ ", .{fmt});
        try self.emitExpr(arg);
        try self.w.writeAll(" })");
    }

    /// True if `sexp` looks like a string literal (peeks at the source).
    fn isStringLiteral(self: *const Emitter, sexp: Sexp) bool {
        switch (sexp) {
            .src => |s| {
                if (s.pos >= self.source.len) return false;
                const c = self.source[s.pos];
                return c == '"' or c == '\'';
            },
            .list => |items| {
                if (items.len >= 2 and items[0] == .tag) {
                    switch (items[0].tag) {
                        .@"read", .@"write", .@"move", .@"clone", .@"share" => return self.isStringLiteral(items[1]),
                        else => return false,
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    fn emitInfix(self: *Emitter, items: []const Sexp, op: Tag) Error!void {
        if (items.len < 3) return;
        try self.w.writeAll("(");
        try self.emitExpr(items[1]);
        try self.w.print(" {s} ", .{@tagName(op)});
        try self.emitExpr(items[2]);
        try self.w.writeAll(")");
    }

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    fn emitType(self: *Emitter, t: Sexp) Error!void {
        switch (t) {
            .src => |s| {
                const txt = self.source[s.pos..][0..s.len];
                try self.w.writeAll(mapTypeName(txt));
            },
            .list => |items| {
                if (items.len < 2 or items[0] != .tag) return;
                switch (items[0].tag) {
                    .@"optional" => {
                        try self.w.writeAll("?");
                        try self.emitType(items[1]);
                    },
                    .@"error_union" => {
                        try self.w.writeAll("!");
                        try self.emitType(items[1]);
                    },
                    .@"borrow_read", .@"borrow_write" => {
                        // Type-position borrows (`?T` / `!T`) lower to plain
                        // `T` in Zig — borrow semantics were enforced by M2;
                        // Zig is loose about borrows at the type level.
                        try self.emitType(items[1]);
                    },
                    .@"slice" => {
                        try self.w.writeAll("[]");
                        try self.emitType(items[1]);
                    },
                    .@"array_type" => {
                        try self.w.writeAll("[");
                        try self.emitExpr(items[1]);
                        try self.w.writeAll("]");
                        if (items.len >= 3) try self.emitType(items[2]);
                    },
                    else => try self.w.writeAll("anytype"),
                }
            },
            else => try self.w.writeAll("anytype"),
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    fn indentSpaces(self: *Emitter) Error!void {
        var i: u32 = 0;
        while (i < self.indent) : (i += 1) try self.w.writeAll("    ");
    }

    fn emitUnsupported(self: *Emitter, what: []const u8) Error!void {
        try self.w.writeAll("// rig: emitter does not yet support ");
        try self.w.writeAll(what);
        try self.w.writeAll("\n");
    }
};

// =============================================================================
// Free helpers
// =============================================================================

fn identText(source: []const u8, sexp: Sexp) ?[]const u8 {
    return switch (sexp) {
        .src => |s| source[s.pos..][0..s.len],
        else => null,
    };
}

fn mapTypeName(rig_name: []const u8) []const u8 {
    if (std.mem.eql(u8, rig_name, "Int")) return "i32";
    if (std.mem.eql(u8, rig_name, "Float")) return "f32";
    if (std.mem.eql(u8, rig_name, "I8")) return "i8";
    if (std.mem.eql(u8, rig_name, "I16")) return "i16";
    if (std.mem.eql(u8, rig_name, "I32")) return "i32";
    if (std.mem.eql(u8, rig_name, "I64")) return "i64";
    if (std.mem.eql(u8, rig_name, "U8")) return "u8";
    if (std.mem.eql(u8, rig_name, "U16")) return "u16";
    if (std.mem.eql(u8, rig_name, "U32")) return "u32";
    if (std.mem.eql(u8, rig_name, "U64")) return "u64";
    if (std.mem.eql(u8, rig_name, "F32")) return "f32";
    if (std.mem.eql(u8, rig_name, "F64")) return "f64";
    if (std.mem.eql(u8, rig_name, "Bool")) return "bool";
    if (std.mem.eql(u8, rig_name, "String")) return "[]const u8";
    if (std.mem.eql(u8, rig_name, "Bytes")) return "[]const u8";
    if (std.mem.eql(u8, rig_name, "Void")) return "void";
    return rig_name;
}

fn isErrorUnion(t: Sexp) bool {
    return t == .list and t.list.len >= 2 and t.list[0] == .tag and t.list[0].tag == .@"error_union";
}

// =============================================================================
// Tests
// =============================================================================

fn emitSourceToString(allocator: std.mem.Allocator, rig_source: []const u8) ![]u8 {
    // `parser.Parser` auto-wires to `rig.Parser`, so parseProgram returns
    // the fully-rewritten IR directly.
    var p = parser.Parser.init(allocator, rig_source);
    defer p.deinit();
    const ir = try p.parseProgram();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var em = Emitter.init(allocator, rig_source, &out.writer);
    defer em.deinit();
    try em.emit(ir);
    return try allocator.dupe(u8, out.written());
}

test "emit: hello world" {
    const source =
        \\sub main()
        \\  print "hello, rig"
        \\
    ;
    const out = try emitSourceToString(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "std.debug.print") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"hello, rig\"") != null);
}

test "emit: const for unmutated, var for mutated" {
    const source =
        \\sub main()
        \\  x = 1
        \\  y = 2
        \\  x = 3
        \\
    ;
    const out = try emitSourceToString(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "var x =") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const y =") != null);
}

test "emit: fixed_bind always const" {
    const source =
        \\sub main()
        \\  user =! 1
        \\
    ;
    const out = try emitSourceToString(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "const user =") != null);
}

test "emit: propagate becomes try; no signature inference; no auto-try" {
    // M4.5: emitter is dumb. It trusts the IR's declared return type
    // and does NOT mutate signatures or auto-prefix `try` at call sites.
    // The effects checker would reject this Rig source (foo declares `Int`
    // but body propagates), but here we feed the emitter directly to
    // verify it emits exactly what the IR says.
    const source =
        \\fun foo() -> Int!
        \\  bar()!
        \\
        \\sub main()
        \\  x = foo()!
        \\
    ;
    const out = try emitSourceToString(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    // `bar()!` lowers to `try bar()`.
    try std.testing.expect(std.mem.indexOf(u8, out, "try bar()") != null);
    // foo signature should be `!i32` (declared `Int!`).
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn foo() !i32") != null);
    // `foo()!` lowers to `try foo()`. The emitter does NOT add `try` for
    // the bare `foo()` form anymore.
    try std.testing.expect(std.mem.indexOf(u8, out, "try foo()") != null);
}

test "emit: bare fallible call is NOT auto-tried" {
    // Verifies the auto-try removal: `x = foo()` (no `!`) emits as
    // `const x = foo()` even though foo is fallible. Zig will error on
    // this, which is fine — the effects checker is the proper gate.
    const source =
        \\fun foo() -> Int!
        \\  1
        \\
        \\sub main()
        \\  x = foo()
        \\
    ;
    const out = try emitSourceToString(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "try foo()") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "= foo()") != null);
}

/// Recursively check if `sexp` (or any descendant) is a `(propagate ...)`
/// or explicit `(try ...)` form. Used to decide whether the enclosing
/// function should be marked fallible (`!T` return type).
fn containsPropagate(sexp: Sexp) bool {
    if (sexp != .list) return false;
    const items = sexp.list;
    if (items.len == 0) return false;
    if (items[0] == .tag and (items[0].tag == .@"propagate" or items[0].tag == .@"try")) return true;
    // Don't descend into nested fn/sub/lambda — those have their own scope.
    if (items[0] == .tag and
        (items[0].tag == .@"fun" or items[0].tag == .@"sub" or items[0].tag == .@"lambda"))
        return false;
    for (items) |child| if (containsPropagate(child)) return true;
    return false;
}

/// Walk `body` and add the name of every binding that is `set` more than
/// once (the second `set` is a reassignment). Names with single `set`
/// declarations should be `const` in Zig; reassigned names need `var`.
fn scanMutations(
    out: *std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,
    body: Sexp,
    source: []const u8,
) (std.mem.Allocator.Error || rig.BindingKindError)!void {
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(allocator);
    try scanMutationsRec(out, &seen, allocator, body, source);
}

fn scanMutationsRec(
    out: *std.StringHashMapUnmanaged(void),
    seen: *std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,
    sexp: Sexp,
    source: []const u8,
) (std.mem.Allocator.Error || rig.BindingKindError)!void {
    if (sexp != .list) return;
    const items = sexp.list;
    if (items.len == 0) return;
    if (items[0] == .tag) {
        const tag = items[0].tag;
        // Don't descend into nested fn/sub/lambda
        if (tag == .@"fun" or tag == .@"sub" or tag == .@"lambda") return;
        if (tag == .@"set" and items.len >= 5) {
            // (set <kind> name type expr). Only kinds that actually
            // reassign an existing slot count toward "must be `var`".
            // Exhaustive switch on BindingKind — adding a new kind to
            // the enum forces an explicit decision here.
            const kind = try rig.bindingKindOf(items[1]);
            const counts_as_mut: bool = switch (kind) {
                .default, .@"move", .@"+=", .@"-=", .@"*=", .@"/=" => true,
                .fixed, .shadow => false,
            };
            if (counts_as_mut) {
                const target = items[2];
                if (target == .src) {
                    const nm = source[target.src.pos..][0..target.src.len];
                    if (seen.contains(nm)) {
                        try out.put(allocator, nm, {});
                    } else {
                        try seen.put(allocator, nm, {});
                    }
                }
            }
        }
    }
    for (items) |child| try scanMutationsRec(out, seen, allocator, child, source);
}

/// True if `sexp` is an expression-statement (i.e., not a binding/return/etc).
/// These are the things that can be rewritten to `return <expr>;` when they
/// appear as the last statement of a function body.
fn isExprStmt(sexp: Sexp) bool {
    if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) return true;
    return switch (sexp.list[0].tag) {
        .@"set", .@"drop",
        .@"return", .@"break", .@"continue",
        .@"defer", .@"errdefer",
        .@"block",
        => false,
        else => true,
    };
}
