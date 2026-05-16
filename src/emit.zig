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
const types = @import("types.zig");

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

    /// Counter for labeled-block labels used when lowering value-position
    /// constructs (currently `if`-as-expression). Each labeled block gets
    /// a unique `rig_blk_<n>` label so nested expressions never shadow.
    /// See `emitBranchExpr`.
    block_label_counter: u32 = 0,

    /// Per-function pre-scan: names that are reassigned in the body,
    /// so they need `var` instead of `const` in Zig. Reset at the
    /// start of each `emitFun`.
    fn_mutated: std.StringHashMapUnmanaged(void) = .{},

    /// True iff THIS function's declared return type is `(error_union T)`
    /// — set per-function in `emitFun` from the IR, NOT from body
    /// inspection. The effects checker (src/effects.zig) is responsible
    /// for ensuring body-level fallibility matches the declaration.
    fn_is_fallible: bool = false,

    /// Optional sema context. When wired, `emitCall` consults sema's
    /// symbol table to decide whether `Foo(...)` should lower to a
    /// Zig struct literal (`Foo{ ... }`) or a function call (`Foo(...)`)
    /// based on whether `Foo` resolves to a nominal type vs a function.
    /// Without sema, falls back to the kwarg-presence heuristic that
    /// the M3/M4 emitter shipped with.
    sema: ?*const types.SemContext = null,

    /// M20a: name of the enclosing nominal when emitting a method body
    /// (or its signature), so `Self` in type position substitutes to
    /// the nominal's name. Null when not inside a nominal body.
    current_nominal_name: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, w: *Writer) Emitter {
        return .{
            .allocator = allocator,
            .source = source,
            .w = w,
            .name_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// Constructor that wires the sema context. Use this from the CLI
    /// pipeline so emit decisions consult the authoritative symbol
    /// table instead of relying on syntactic heuristics.
    pub fn initWithSema(allocator: std.mem.Allocator, source: []const u8, w: *Writer, sema: *const types.SemContext) Emitter {
        var e = init(allocator, source, w);
        e.sema = sema;
        return e;
    }

    pub fn deinit(self: *Emitter) void {
        for (self.scopes.items) |*s| s.symbols.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.fn_mutated.deinit(self.allocator);
        self.name_arena.deinit();
    }

    pub fn emit(self: *Emitter, sexp: Sexp) Error!void {
        try self.w.writeAll("const std = @import(\"std\");\n");
        // M20d: every emitted module imports the Rig runtime as a
        // sibling file (`_rig_runtime.zig`), regardless of whether
        // it uses `*T`/`~T`. Top-level unused namespace imports are
        // permitted by Zig, so an unused `rig` reference is harmless.
        // The driver writes the runtime to the same dir for `run` /
        // multi-file `build`; single-file `build` emits to stdout and
        // the runtime file is the caller's responsibility (`bin/rig
        // run` is the supported execution path).
        try self.w.writeAll("const rig = @import(\"_rig_runtime.zig\");\n");
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
            .@"struct" => try self.emitStruct(items),
            .@"enum" => try self.emitEnum(items),
            .@"errors" => try self.emitErrorSet(items),
            .@"generic_type" => try self.emitGenericType(items),
            .@"generic_enum" => try self.emitGenericEnum(items),
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

    /// `(struct Name (: field type) ... (fun method ...) ...)` →
    /// Zig `const Name = struct { ... };`. M12: method members
    /// (`fun`/`sub`) emit as `pub fn` declarations inside the
    /// struct's body so they're callable as `Name.method(args)`.
    /// Method bodies aren't yet sema-checked but lower as-is via
    /// the existing `emitFun` path.
    fn emitStruct(self: *Emitter, items: []const Sexp) Error!void {
        if (items.len < 2) return;
        const name = identText(self.source, items[1]) orelse "AnonStruct";
        try self.w.print("pub const {s} = struct {{\n", .{name});

        // M20a: set the nominal context so `Self` in member signatures
        // / bodies substitutes correctly via `emitType`.
        const prev_nominal = self.current_nominal_name;
        self.current_nominal_name = name;
        defer self.current_nominal_name = prev_nominal;

        // Emit data fields first (Zig allows mixed order, but data-
        // then-methods reads more naturally).
        for (items[2..]) |member| {
            if (member != .list or member.list.len < 3 or member.list[0] != .tag) continue;
            if (member.list[0].tag != .@":") continue;
            const fname = identText(self.source, member.list[1]) orelse continue;
            try self.w.print("    {s}: ", .{fname});
            try self.emitType(member.list[2]);
            try self.w.writeAll(",\n");
        }

        try self.emitNominalMethods(items[2..], 1);
        try self.w.writeAll("};\n");
    }

    /// M20a: emit `fun`/`sub` members of a nominal body as nested
    /// Zig `pub fn` declarations. Factored out of `emitStruct` so
    /// `emitEnum` and `emitErrorSet` can use the same machinery.
    /// Caller is responsible for setting `current_nominal_name`.
    /// `indent_levels` controls how much extra indent to push for
    /// method body emission (1 for top-level structs/enums; 2 for
    /// generic types whose struct is nested inside `return struct {...}`).
    fn emitNominalMethods(self: *Emitter, members: []const Sexp, indent_levels: u32) Error!void {
        var any_methods = false;
        for (members) |member| {
            if (member != .list or member.list.len < 5 or member.list[0] != .tag) continue;
            const head = member.list[0].tag;
            if (head != .@"fun" and head != .@"sub") continue;
            if (!any_methods) {
                try self.w.writeAll("\n");
                any_methods = true;
            }
            // Write leading spaces for the `pub fn` line itself.
            var i: u32 = 0;
            while (i < indent_levels) : (i += 1) try self.w.writeAll("    ");
            const prev_indent = self.indent;
            self.indent += indent_levels;
            try self.emitFun(member.list, head == .@"sub");
            self.indent = prev_indent;
        }
    }

    /// `(generic_type Name (T1 T2 ...) members...)` → Zig
    /// `pub fn Name(comptime T1: type, ...) type { return struct {
    /// const Self = @This(); /* fields */ /* methods */ }; }`.
    /// M14 v1 was struct-only with no method emission (latent bug);
    /// M20b(5/5) closes the bug now that sema understands generic
    /// methods (M20b(3/5) + M20b(4/5)).
    ///
    /// Per GPT-5.5: `Self` inside a generic body must lower to Zig
    /// `Self` (via `const Self = @This();`), NOT to the bare type
    /// name `Box`. We set `current_nominal_name = "Self"` for the
    /// duration of the body, so `emitType`'s `Self`-substitution
    /// arm emits `Self` (a no-op rename that pairs with the alias).
    fn emitGenericType(self: *Emitter, items: []const Sexp) Error!void {
        if (items.len < 4) return;
        const name = identText(self.source, items[1]) orelse "AnonGeneric";
        const params = items[2];

        // M20b(5/5): Self → Zig Self inside the generic struct body.
        const prev_nominal = self.current_nominal_name;
        self.current_nominal_name = "Self";
        defer self.current_nominal_name = prev_nominal;

        try self.w.print("pub fn {s}(", .{name});
        if (params == .list) {
            var first = true;
            for (params.list) |p| {
                if (p != .src) continue;
                if (!first) try self.w.writeAll(", ");
                first = false;
                try self.w.print("comptime {s}: type", .{self.source[p.src.pos..][0..p.src.len]});
            }
        }
        try self.w.writeAll(") type {\n    return struct {\n");

        // M20b(5/5): `const Self = @This();` so methods can use Self
        // and the `?self` sugar (lowers to `self: Self` per M20a.1).
        try self.w.writeAll("        const Self = @This();\n\n");

        for (items[3..]) |member| {
            if (member != .list or member.list.len < 3 or member.list[0] != .tag) continue;
            if (member.list[0].tag != .@":") continue;
            const fname = identText(self.source, member.list[1]) orelse continue;
            try self.w.print("        {s}: ", .{fname});
            try self.emitType(member.list[2]);
            try self.w.writeAll(",\n");
        }

        // M20b(5/5): method members — same machinery as `emitStruct` /
        // `emitEnum`, just indented one extra level (the inner struct
        // sits inside `return struct { ... }`).
        try self.emitNominalMethods(items[3..], 2);

        try self.w.writeAll("    };\n}\n");
    }

    /// `(generic_enum Name (T1 T2 ...) variants...)` → Zig
    /// `pub fn Name(comptime T1: type, ...) type { return union(enum)
    /// { const Self = @This(); /* variants */ /* methods */ }; }`.
    /// M20c: parallel to `emitGenericType` but the inner body is a
    /// tagged union since generic enums always have at least some
    /// payload (otherwise the type params are unused).
    ///
    /// Per GPT-5.5: `Self` inside the inner body lowers to Zig
    /// `Self` (via `const Self = @This();`), NOT to the bare type
    /// name `Option`. Method receiver sugar (`?self` lowering to
    /// `self: Self`) then composes naturally.
    fn emitGenericEnum(self: *Emitter, items: []const Sexp) Error!void {
        if (items.len < 4) return;
        const name = identText(self.source, items[1]) orelse "AnonGenericEnum";
        const params = items[2];

        const prev_nominal = self.current_nominal_name;
        self.current_nominal_name = "Self";
        defer self.current_nominal_name = prev_nominal;

        try self.w.print("pub fn {s}(", .{name});
        if (params == .list) {
            var first = true;
            for (params.list) |p| {
                if (p != .src) continue;
                if (!first) try self.w.writeAll(", ");
                first = false;
                try self.w.print("comptime {s}: type", .{self.source[p.src.pos..][0..p.src.len]});
            }
        }
        try self.w.writeAll(") type {\n    return union(enum) {\n");
        try self.w.writeAll("        const Self = @This();\n\n");

        // Variants: bare `red` → `red: void`; valued `ok = 0` →
        // `ok: void` (the value can't co-exist with payload-bearing
        // tagged-union form, matches the plain `emitEnum`
        // has_payloads branch); payload `some(value: T)` →
        // `some: T` (single-field unwrap) or `some: struct { ... }`
        // (multi-field).
        for (items[3..]) |variant| {
            switch (variant) {
                .src => |s| {
                    const vname = self.source[s.pos..][0..s.len];
                    try self.w.print("        {s}: void,\n", .{vname});
                },
                .list => |sub| {
                    if (sub.len < 2 or sub[0] != .tag) continue;
                    switch (sub[0].tag) {
                        .@"variant" => {
                            if (sub.len < 3) continue;
                            const vname = identText(self.source, sub[1]) orelse continue;
                            const vparams = sub[2];
                            if (vparams != .list or vparams.list.len == 0) {
                                try self.w.print("        {s}: void,\n", .{vname});
                                continue;
                            }
                            // Single-field unwrap.
                            if (vparams.list.len == 1) {
                                const p = vparams.list[0];
                                if (p == .list and p.list.len >= 3 and p.list[0] == .tag and p.list[0].tag == .@":") {
                                    try self.w.print("        {s}: ", .{vname});
                                    try self.emitType(p.list[2]);
                                    try self.w.writeAll(",\n");
                                    continue;
                                }
                            }
                            // Multi-field → anonymous struct.
                            try self.w.print("        {s}: struct {{ ", .{vname});
                            var first = true;
                            for (vparams.list) |p| {
                                if (p != .list or p.list.len < 3 or p.list[0] != .tag) continue;
                                if (p.list[0].tag != .@":") continue;
                                if (!first) try self.w.writeAll(", ");
                                first = false;
                                const fname = identText(self.source, p.list[1]) orelse continue;
                                try self.w.print("{s}: ", .{fname});
                                try self.emitType(p.list[2]);
                            }
                            try self.w.writeAll(" },\n");
                        },
                        .@"valued" => {
                            // Valued variant in a tagged union — falls
                            // back to bare `: void` (value can't be
                            // expressed in union(enum) form). Matches
                            // emitEnum's has_payloads-with-valued path.
                            if (identText(self.source, sub[1])) |vname| {
                                try self.w.print("        {s}: void,\n", .{vname});
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        // Method members — indent +2 like emitGenericType.
        try self.emitNominalMethods(items[3..], 2);

        try self.w.writeAll("    };\n}\n");
    }

    /// `(errors Name v1 v2 ...)` → Zig `const Name = error { v1, v2, ... };`.
    /// Same IR shape as `enum`; lowers to Zig's distinct `error` set
    /// type so calls returning `Name` propagate naturally with `try`.
    fn emitErrorSet(self: *Emitter, items: []const Sexp) Error!void {
        if (items.len < 2) return;
        const name = identText(self.source, items[1]) orelse "AnonError";
        try self.w.print("pub const {s} = error {{\n", .{name});
        for (items[2..]) |variant| {
            switch (variant) {
                .src => |s| {
                    const vname = self.source[s.pos..][0..s.len];
                    try self.w.print("    {s},\n", .{vname});
                },
                else => {},
            }
        }
        try self.w.writeAll("};\n");
    }

    /// `(enum Name v1 v2 ...)` lowers to one of three Zig forms based
    /// on what variant shapes appear in the body:
    ///
    ///   - all bare           → `pub const Name = enum { v1, v2, };`
    ///   - any `(valued)`     → `pub const Name = enum(u32) { v1 = 0, ... };`
    ///   - any `(variant ...)` → `pub const Name = union(enum) { v1: T1, ... };`
    ///
    /// The union(enum) form is Zig's tagged union — exactly what we
    /// need for payload-bearing variants. Bare variants in the same
    /// declaration get `: void` so the union accepts them too. Bare-
    /// variant-only enums stay as plain enums (cheaper / matches
    /// user intent).
    fn emitEnum(self: *Emitter, items: []const Sexp) Error!void {
        if (items.len < 2) return;
        const name = identText(self.source, items[1]) orelse "AnonEnum";

        // M20a: set the nominal context so `Self` in method signatures
        // / bodies substitutes correctly via `emitType`.
        const prev_nominal = self.current_nominal_name;
        self.current_nominal_name = name;
        defer self.current_nominal_name = prev_nominal;

        // First pass: classify variant shapes.
        var has_values = false;
        var has_payloads = false;
        for (items[2..]) |variant| {
            if (variant != .list or variant.list.len == 0 or variant.list[0] != .tag) continue;
            switch (variant.list[0].tag) {
                .@"valued" => has_values = true,
                .@"variant" => has_payloads = true,
                else => {},
            }
        }

        // Tagged union takes precedence over `(valued)` numeric tagging
        // — Rig V1 doesn't mix them, and emit picks the one that lets
        // every variant compile.
        if (has_payloads) {
            try self.w.print("pub const {s} = union(enum) {{\n", .{name});
            for (items[2..]) |variant| {
                switch (variant) {
                    .src => |s| {
                        const vname = self.source[s.pos..][0..s.len];
                        try self.w.print("    {s}: void,\n", .{vname});
                    },
                    .list => |sub| {
                        if (sub.len < 2 or sub[0] != .tag) continue;
                        switch (sub[0].tag) {
                            .@"variant" => {
                                if (sub.len < 3) continue;
                                const vname = identText(self.source, sub[1]) orelse continue;
                                const params = sub[2];
                                if (params != .list or params.list.len == 0) {
                                    try self.w.print("    {s}: void,\n", .{vname});
                                    continue;
                                }
                                // Single-payload variant → unwrap to the
                                // bare type. Multi-payload → anonymous
                                // struct.
                                if (params.list.len == 1) {
                                    const p = params.list[0];
                                    if (p == .list and p.list.len >= 3 and p.list[0] == .tag and p.list[0].tag == .@":") {
                                        try self.w.print("    {s}: ", .{vname});
                                        try self.emitType(p.list[2]);
                                        try self.w.writeAll(",\n");
                                        continue;
                                    }
                                }
                                try self.w.print("    {s}: struct {{ ", .{vname});
                                var first = true;
                                for (params.list) |p| {
                                    if (p != .list or p.list.len < 3 or p.list[0] != .tag) continue;
                                    if (p.list[0].tag != .@":") continue;
                                    if (!first) try self.w.writeAll(", ");
                                    first = false;
                                    const fname = identText(self.source, p.list[1]) orelse continue;
                                    try self.w.print("{s}: ", .{fname});
                                    try self.emitType(p.list[2]);
                                }
                                try self.w.writeAll(" },\n");
                            },
                            // `(valued ...)` inside a payload-bearing
                            // enum is uncommon but harmless — fall back
                            // to bare `: void` (the explicit value
                            // can't co-exist cleanly with a tagged union).
                            else => {
                                if (identText(self.source, sub[1])) |vname| {
                                    try self.w.print("    {s}: void,\n", .{vname});
                                }
                            },
                        }
                    },
                    else => {},
                }
            }
            try self.emitNominalMethods(items[2..], 1);
            try self.w.writeAll("};\n");
            return;
        }

        if (has_values) {
            try self.w.print("pub const {s} = enum(u32) {{\n", .{name});
        } else {
            try self.w.print("pub const {s} = enum {{\n", .{name});
        }
        for (items[2..]) |variant| {
            switch (variant) {
                .src => |s| {
                    const vname = self.source[s.pos..][0..s.len];
                    try self.w.print("    {s},\n", .{vname});
                },
                .list => |sub| {
                    if (sub.len < 3 or sub[0] != .tag or sub[0].tag != .@"valued") continue;
                    const vname = identText(self.source, sub[1]) orelse continue;
                    try self.w.print("    {s} = ", .{vname});
                    try self.emitExpr(sub[2]);
                    try self.w.writeAll(",\n");
                },
                else => {},
            }
        }
        try self.emitNominalMethods(items[2..], 1);
        try self.w.writeAll("};\n");
    }

    fn emitUse(self: *Emitter, items: []const Sexp) Error!void {
        // (use name) → const <name> = @import("<name>.zig");
        //
        // Skip `std` because we always inject `const std = @import("std");`
        // at the top of the emitted file.
        //
        // M15: explicit `.zig` extension because each Rig module
        // emits to a sibling `.zig` file in the project's output dir.
        // Zig's `@import` with a quoted path resolves the file
        // relative to the importing module's location.
        if (items.len < 2) return;
        const name = identText(self.source, items[1]) orelse return;
        if (std.mem.eql(u8, name, "std")) return;
        try self.w.print("const {s} = @import(\"{s}.zig\");\n", .{ name, name });
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
        // Param shapes:
        //   name                       — untyped
        //   (: name type)              — typed
        //   (pre_param name type)      — comptime-typed
        //   (default name type expr)   — typed with default
        //   (read NAME) / (write NAME) — M20a.1 `?self` / `!self` sugar;
        //                                desugars to NAME: EnclosingType
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
                    // M20a.1: `?self` / `!self` sugar. Emit as
                    // `NAME: EnclosingType`. Borrow stripping in
                    // emit follows the same convention as the
                    // explicit `self: ?User` form (Zig is loose
                    // about borrows at the type level — M2 enforced
                    // them).
                    .@"read", .@"write" => {
                        const name = identText(self.source, items[1]) orelse "_";
                        try self.w.print("{s}: ", .{name});
                        if (self.current_nominal_name) |nom| {
                            try self.w.writeAll(nom);
                        } else {
                            try self.w.writeAll("anytype");
                        }
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
                        // M20a.1: `?self` / `!self` sugar — bind the
                        // wrapped name (typically `self`) into the
                        // emit scope.
                        .@"read", .@"write" => name_node = p.list[1],
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
            .@"match" => try self.emitMatch(items, false),
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
        const name_node = items[2];
        const name = identText(self.source, name_node) orelse return;
        const type_node = items[3];
        const expr = items[4];

        switch (kind) {
            .@"+=" => try self.emitCompoundAssign(name, "+=", expr),
            .@"-=" => try self.emitCompoundAssign(name, "-=", expr),
            .@"*=" => try self.emitCompoundAssign(name, "*=", expr),
            .@"/=" => try self.emitCompoundAssign(name, "/=", expr),
            .@"move", .default => try self.emitSetOrBind(name, name_node, type_node, expr, false, false),
            .fixed => try self.emitSetOrBind(name, name_node, type_node, expr, true, false),
            .shadow => try self.emitSetOrBind(name, name_node, type_node, expr, false, true),
        }
        // Exhaustive on BindingKind — Zig enforces.
    }

    fn emitCompoundAssign(self: *Emitter, name: []const u8, op_str: []const u8, expr: Sexp) Error!void {
        const zig_name = self.lookup(name) orelse name;
        try self.w.print("{s} {s} ", .{ zig_name, op_str });
        try self.emitExpr(expr);
        try self.w.writeAll(";");
    }

    fn emitSetOrBind(
        self: *Emitter,
        name: []const u8,
        name_node: Sexp,
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
            } else if (decl_kw[0] == 'v') {
                // M19: mutable binding with no source-level type annotation.
                // Zig refuses `var x = 0;` because `comptime_int` isn't
                // a runtime type. If sema inferred a concrete type for
                // this binding, emit it as a Zig type annotation. Falls
                // back to the bare form for non-numeric inferred types
                // and when sema is unavailable (parser-only mode).
                if (self.tryEmitInferredType(name_node, name)) {
                    try self.w.print("{s} {s}: ", .{ decl_kw, zig_name });
                    try self.emitInferredType(name_node, name);
                    try self.w.writeAll(" = ");
                } else {
                    try self.w.print("{s} {s} = ", .{ decl_kw, zig_name });
                }
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

    /// True iff sema has a concrete type for the binding declared at
    /// `name_node` whose source spelling is `name`. Used by `emitSetOrBind`
    /// to decide whether to emit a Zig type annotation for a `var`
    /// binding that lacked a source-level annotation.
    ///
    /// Lookup strategy: match by `decl_pos` (the binding name's source
    /// position). The sema's `SymbolResolver` records this for every
    /// local declaration site, so it uniquely identifies the symbol
    /// even when the same name is reused in sibling scopes.
    fn tryEmitInferredType(self: *Emitter, name_node: Sexp, name: []const u8) bool {
        _ = name;
        const sema = self.sema orelse return false;
        if (name_node != .src) return false;
        const decl_pos = name_node.src.pos;
        for (sema.symbols.items) |sym| {
            if (sym.decl_pos != decl_pos) continue;
            if (sym.ty == sema.types.invalid_id or sym.ty == sema.types.unknown_id) return false;
            const ty = sema.types.get(sym.ty);
            return switch (ty) {
                .int, .float, .int_literal, .float_literal, .bool => true,
                else => false,
            };
        }
        return false;
    }

    /// Emit the Zig type spelling for the inferred type of `name`'s
    /// binding at `name_node`. Caller must have already checked
    /// `tryEmitInferredType`. Defaults `int_literal` → `i32` and
    /// `float_literal` → `f32` for unconstrained literals.
    fn emitInferredType(self: *Emitter, name_node: Sexp, name: []const u8) Error!void {
        _ = name;
        const sema = self.sema.?;
        const decl_pos = name_node.src.pos;
        for (sema.symbols.items) |sym| {
            if (sym.decl_pos != decl_pos) continue;
            const ty = sema.types.get(sym.ty);
            switch (ty) {
                .int_literal => try self.w.writeAll("i32"),
                .float_literal => try self.w.writeAll("f32"),
                .int => |info| {
                    if (info.bits == 0) {
                        try self.w.writeAll("i32");
                    } else if (info.signed) {
                        try self.w.print("i{d}", .{info.bits});
                    } else {
                        try self.w.print("u{d}", .{info.bits});
                    }
                },
                .float => |info| {
                    try self.w.print("f{d}", .{if (info.bits == 0) @as(u32, 32) else info.bits});
                },
                .bool => try self.w.writeAll("bool"),
                else => try self.w.writeAll("anytype"), // defensive, shouldn't reach
            }
            return;
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

    /// Lower `(if cond (block ...) (block ...))` used in expression
    /// position (RHS of a binding, function return value, argument to
    /// a call, branch of another `if`, etc.).
    ///
    /// Zig's `if (c) a else b` is itself an expression, so the shape is
    /// the same as the statement form — but each branch must produce a
    /// value. Multi-statement branches become labeled blocks; single
    /// expression branches are emitted inline.
    ///
    /// Without an else branch the result type would be `void`, which
    /// is almost certainly not what the user wanted. We emit a
    /// `@compileError` safety net so the generated Zig fails with a
    /// clear message rather than silently producing wrong code. A
    /// real Rig diagnostic should come from sema (M17b).
    fn emitIfExpr(self: *Emitter, items: []const Sexp) Error!void {
        if (items.len < 4) {
            try self.w.writeAll("@compileError(\"rig: if-expression requires an else branch\")");
            return;
        }
        try self.w.writeAll("if (");
        try self.emitExpr(items[1]);
        try self.w.writeAll(") ");
        try self.emitBranchExpr(items[2]);
        try self.w.writeAll(" else ");
        try self.emitBranchExpr(items[3]);
    }

    /// Emit one branch of a value-position `if`. The branch is always
    /// a `(block stmts...)` from the grammar, but we tolerate a bare
    /// expression too (defensive against future IR shapes).
    ///
    /// Cases:
    /// - 0 stmts → `@compileError` safety net.
    /// - 1 stmt that's an expression → emit inline (no labeled block).
    /// - Final stmt is terminating (`return`/`break`/`continue`) →
    ///   labeled block, no trailing `break :label …` (the branch has
    ///   type `noreturn` and coerces to the other branch's type).
    /// - Final stmt is an expression → labeled block with
    ///   `break :rig_blk_N <expr>;` as the final line.
    /// - Otherwise (non-expression, non-terminating final stmt) →
    ///   `@compileError` (this branch doesn't produce a value).
    fn emitBranchExpr(self: *Emitter, branch: Sexp) Error!void {
        // Pull out `(block stmts...)` if applicable.
        const stmts: []const Sexp = blk: {
            if (branch == .list and branch.list.len > 0 and branch.list[0] == .tag and
                branch.list[0].tag == .@"block")
            {
                break :blk branch.list[1..];
            }
            // Bare-expression branch: treat as a one-element stmt list
            // so the single-expr fast path picks it up.
            break :blk @as([]const Sexp, &[_]Sexp{branch});
        };

        if (stmts.len == 0) {
            try self.w.writeAll("@compileError(\"rig: empty value-position branch\")");
            return;
        }

        if (stmts.len == 1 and isExprStmt(stmts[0])) {
            try self.emitExpr(stmts[0]);
            return;
        }

        // When the final stmt is terminating (return/break/continue),
        // the branch produces `noreturn` and we never `break :label`
        // out of it. Emitting a label in that case triggers Zig's
        // "unused block label" error. Detect and emit a *plain* block
        // (no label) for the noreturn case.
        const last = stmts[stmts.len - 1];
        const terminating = isTerminatingStmt(last);
        const want_label = !terminating and isExprStmt(last);

        var label_id: u32 = 0;
        if (want_label) {
            label_id = self.block_label_counter;
            self.block_label_counter += 1;
            try self.w.print("rig_blk_{d}: {{\n", .{label_id});
        } else {
            try self.w.writeAll("{\n");
        }
        self.indent += 1;
        try self.pushScope();

        // All but the final statement: emit as ordinary statements.
        for (stmts[0 .. stmts.len - 1]) |s| {
            try self.indentSpaces();
            try self.emitStmt(s);
            try self.w.writeAll("\n");
        }

        try self.indentSpaces();
        if (terminating) {
            try self.emitStmt(last);
        } else if (want_label) {
            try self.w.print("break :rig_blk_{d} ", .{label_id});
            try self.emitExpr(last);
            try self.w.writeAll(";");
        } else {
            // Final stmt is something like `(set ...)` with no value.
            // The branch doesn't produce a value — emit a diagnostic.
            try self.w.writeAll("@compileError(\"rig: value-position branch does not produce a value\");");
        }
        try self.w.writeAll("\n");

        try self.popScope();
        self.indent -= 1;
        try self.indentSpaces();
        try self.w.writeAll("}");
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

    /// `(match scrutinee arm...)` lowers to a Zig `switch` statement.
    /// Each `(arm pattern binding-or-_ body)` becomes one prong:
    ///
    ///   pattern shape           Zig prong              notes
    ///   -----------------------  ---------------------  ----------------
    ///   (enum_lit X)            `.X => body,`          enum variant
    ///   .src bare ident `_`     `else => body,`        catch-all
    ///   .src bare ident name    `else => body,`        catch-all (binding ignored in M8)
    ///   integer literal `42`    `42 => body,`          int match
    ///   string literal `"foo"`  uses raw text          rare
    ///
    /// If no catch-all arm is supplied, we append `else => unreachable,`
    /// so Zig's switch-must-be-exhaustive rule is satisfied. M9+ will
    /// add real exhaustiveness checking + bind names from `_` arms.
    /// Lower `(match scrutinee arm...)` to a Zig `switch`.
    ///
    /// `value_position` is `true` when the match is being used as an
    /// expression (binding RHS, function return, argument, branch of
    /// another expression). In that case multi-statement arm bodies
    /// must produce a value, and the M18 labeled-block recipe
    /// (`emitArmBodyValue`) kicks in. When `false`, arm bodies are
    /// emitted as void-returning blocks (`emitMatchArmBody`).
    fn emitMatch(self: *Emitter, items: []const Sexp, value_position: bool) Error!void {
        if (items.len < 2) return;
        try self.w.writeAll("switch (");
        try self.emitExpr(items[1]);
        try self.w.writeAll(") {\n");
        self.indent += 1;

        var has_default = false;
        var enum_variants_covered: usize = 0;
        for (items[2..]) |arm| {
            if (arm != .list or arm.list.len < 4 or arm.list[0] != .tag or
                arm.list[0].tag != .@"arm")
            {
                continue;
            }
            const pattern = arm.list[1];
            const body = arm.list[arm.list.len - 1];

            try self.indentSpaces();

            // Track payload destructuring: `(variant_pattern X b1 b2 ...)`
            // generates `.X => |__payload| { const b1 = __payload.field1; ... body }`.
            // For single-payload `(variant_pattern X b1)` the capture
            // is the bare value (matches the union(enum) unwrapping).
            var capture_names: []const Sexp = &.{};
            var is_variant_pattern = false;

            if (isDefaultPattern(pattern)) {
                has_default = true;
                try self.w.writeAll("else => ");
            } else if (pattern == .list and pattern.list.len >= 2 and
                pattern.list[0] == .tag and pattern.list[0].tag == .@"enum_lit")
            {
                try self.w.writeAll(".");
                try self.emitExpr(pattern.list[1]);
                try self.w.writeAll(" => ");
                enum_variants_covered += 1;
            } else if (pattern == .list and pattern.list.len >= 3 and
                pattern.list[0] == .tag and pattern.list[0].tag == .@"range_pattern")
            {
                // M13: `lo..hi => body` lowers to Zig's inclusive
                // range syntax `lo...hi => body`. Rig V1 treats `..`
                // as inclusive on the high end (matches `(range_pattern
                // 1 3)` covering 1, 2, 3). M14+ may add `..<` for
                // exclusive once SPEC settles.
                try self.emitExpr(pattern.list[1]);
                try self.w.writeAll("...");
                try self.emitExpr(pattern.list[2]);
                try self.w.writeAll(" => ");
            } else if (pattern == .list and pattern.list.len >= 2 and
                pattern.list[0] == .tag and pattern.list[0].tag == .@"variant_pattern")
            {
                is_variant_pattern = true;
                capture_names = pattern.list[2..];
                try self.w.writeAll(".");
                try self.emitExpr(pattern.list[1]);
                try self.w.writeAll(" => ");
                if (capture_names.len == 1) {
                    // Single-payload: `.X => |b| body` — Zig's natural
                    // capture syntax (matches the unwrapped union arm).
                    try self.w.writeAll("|");
                    try self.emitExpr(capture_names[0]);
                    try self.w.writeAll("| ");
                } else if (capture_names.len > 1) {
                    // Multi-payload: capture into a synthetic name and
                    // alias each field at the start of the wrapped body.
                    try self.w.writeAll("|__payload| ");
                }
                enum_variants_covered += 1;
            } else {
                // Literal or other expression-shaped pattern — emit the
                // pattern verbatim and let Zig validate.
                try self.emitExpr(pattern);
                try self.w.writeAll(" => ");
            }

            if (is_variant_pattern and capture_names.len == 1) {
                // Single-payload destructure. If the body actually uses
                // the binding, just emit the body as-is. Otherwise wrap
                // in `{ _ = b; ... }` to silence Zig's unused-capture
                // error. Zig errors EITHER way (used → "pointless
                // discard" if we always emit `_ =`; unused → "unused
                // capture" if we don't), so we have to decide per-arm.
                const b = capture_names[0];
                if (b == .src) {
                    const bname = self.source[b.src.pos..][0..b.src.len];
                    if (std.mem.eql(u8, bname, "_") or isNameUsedInBody(self.source, body, bname)) {
                        try self.emitArmBody(body, value_position);
                    } else {
                        // Unused capture: insert `_ = name;` discard.
                        // Note: this path forces a void-returning wrap,
                        // so it's incompatible with value-position match
                        // arms. Keep the M3 behavior; revisit if a real
                        // case appears.
                        try self.w.writeAll("{ _ = ");
                        try self.w.writeAll(bname);
                        try self.w.writeAll("; ");
                        try self.emitStmt(body);
                        try self.w.writeAll(" }");
                    }
                } else {
                    try self.emitArmBody(body, value_position);
                }
            } else if (is_variant_pattern and capture_names.len > 1) {
                // Multi-payload destructure: alias each binding from
                // `__payload.fieldN` before emitting the body. Wrap in
                // a plain block so the aliases scope to this arm only.
                // emitStmt terminates with `;`; the trailing block
                // close keeps Zig's switch-arm syntax happy.
                //
                // After each alias we also emit `_ = name;` so Zig's
                // unused-local rule doesn't fire when the user's body
                // happens to ignore one of the destructured fields.
                // Same pattern shadow renames use.
                try self.w.writeAll("{ ");
                const payload_field_names = self.lookupVariantPayloadNames(pattern.list[1]);
                for (capture_names, 0..) |b, i| {
                    if (b != .src) continue;
                    const bname = self.source[b.src.pos..][0..b.src.len];
                    if (std.mem.eql(u8, bname, "_")) continue;
                    const fname: []const u8 = if (payload_field_names) |names|
                        (if (i < names.len) names[i] else "")
                    else
                        ""; // sema unavailable — emit nothing (Zig will fail)
                    if (fname.len > 0) {
                        try self.w.print("const {s} = __payload.{s}; ", .{ bname, fname });
                        // Only silence binding when the body doesn't use it.
                        if (!isNameUsedInBody(self.source, body, bname)) {
                            try self.w.print("_ = {s}; ", .{bname});
                        }
                    }
                }
                try self.emitStmt(body);
                try self.w.writeAll(" }");
            } else {
                // Body. Zig switch arms accept an expression; the
                // value/void dispatch happens inside `emitArmBody`.
                try self.emitArmBody(body, value_position);
            }
            try self.w.writeAll(",\n");
        }

        // Only emit `else => unreachable` if Zig actually needs it.
        // It needs it when the switch isn't already exhaustive — i.e.,
        // when there's no default arm AND the scrutinee isn't a sema
        // enum whose every variant is covered by an `(enum_lit X)` arm.
        const exhaustive = has_default or self.matchExhaustive(items[1], enum_variants_covered);
        if (!exhaustive) {
            try self.indentSpaces();
            try self.w.writeAll("else => unreachable,\n");
        }
        self.indent -= 1;
        try self.indentSpaces();
        try self.w.writeAll("}");
    }

    /// Returns true if a `match` on `scrutinee` is exhaustive given
    /// `enum_arms_seen` enum-literal arms. Requires sema to know the
    /// scrutinee's nominal enum and its variant count. Sema's
    /// duplicate-detection ensures arm count matches DIFFERENT
    /// variants, so we can rely on the count check here.
    fn matchExhaustive(self: *Emitter, scrutinee: Sexp, enum_arms_seen: usize) bool {
        const sema = self.sema orelse return false;
        if (scrutinee != .src) return false;
        const name = self.source[scrutinee.src.pos..][0..scrutinee.src.len];
        for (sema.symbols.items) |sym| {
            if (!std.mem.eql(u8, sym.name, name)) continue;
            // M20a / M20a.2 / M20c: peel borrow_read / borrow_write so
            // `match self` on `self: ?Color` / `self: ?Option(Int)`
            // finds the underlying enum. M20c per GPT-5.5: also
            // handle `parameterized_nominal` via `nominalSymOfReceiver`
            // so generic enum match-exhaustiveness works.
            const sym_id = types.nominalSymOfReceiver(sema, sym.ty) orelse continue;
            const enum_sym = sema.symbols.items[sym_id];
            const fields = enum_sym.fields orelse return false;
            // M20c: count actual variants (is_variant=true) only.
            // Data fields (struct case — unreachable here in practice)
            // and methods don't contribute to exhaustiveness.
            var variant_count: usize = 0;
            for (fields) |f| {
                if (f.is_variant) variant_count += 1;
            }
            return enum_arms_seen >= variant_count;
        }
        return false;
    }

    /// Look up the payload field names (in declaration order) for a
    /// variant referenced by name, scanning all sema enum symbols.
    /// Returns null if no match is found. Used by `emitMatch` when
    /// destructuring multi-field payload variants so we can alias
    /// bindings to the correct Zig field names.
    fn lookupVariantPayloadNames(self: *Emitter, variant_name_node: Sexp) ?[]const []const u8 {
        const sema = self.sema orelse return null;
        if (variant_name_node != .src) return null;
        const variant_name = self.source[variant_name_node.src.pos..][0..variant_name_node.src.len];
        for (sema.symbols.items) |sym| {
            // M20c: accept both plain (`nominal_type`) and generic
            // (`generic_type`) enum symbols; filter to actual
            // variants via `is_variant` to avoid matching methods.
            if (sym.kind != .nominal_type and sym.kind != .generic_type) continue;
            const fields = sym.fields orelse continue;
            for (fields) |v| {
                if (!v.is_variant) continue;
                if (!std.mem.eql(u8, v.name, variant_name)) continue;
                const payload = v.payload orelse continue;
                // Build a flat slice of name strings in arena memory.
                const out = self.name_arena.allocator().alloc([]const u8, payload.len) catch return null;
                for (payload, 0..) |f, i| out[i] = f.name;
                return out;
            }
        }
        return null;
    }

    /// Match-arm body dispatcher.
    ///
    /// In **value position** (M18): multi-statement arm bodies must
    /// produce a value, so route through `emitBranchExpr` (the M17
    /// labeled-block recipe — `rig_blk_N: { ...; break :rig_blk_N
    /// expr; }`). Single-expression arm bodies emit inline. Final-
    /// terminating bodies (`return`/`break`/`continue`) emit a plain
    /// unlabeled block.
    ///
    /// In **statement position** (legacy `emitMatchArmBody`): arm
    /// bodies are void-returning. Single statements wrap in `{ stmt; }`
    /// so things like `return`/`break`/side-effecting calls work.
    fn emitArmBody(self: *Emitter, body: Sexp, value_position: bool) Error!void {
        if (value_position) {
            try self.emitBranchExpr(body);
        } else {
            try self.emitMatchArmBody(body);
        }
    }

    /// Emit a match-arm body in STATEMENT position. Arm bodies are
    /// void-returning. For statement-shaped sexps (call, set, etc.)
    /// wrap in a block expression `{ stmt; }` since Zig switch arms
    /// expect an expression position. Bare expressions emit as-is.
    /// See `emitArmBody` for the value-position variant.
    fn emitMatchArmBody(self: *Emitter, body: Sexp) Error!void {
        if (body == .list and body.list.len > 0 and body.list[0] == .tag) {
            const head = body.list[0].tag;
            // Block / control-flow statements should be wrapped.
            switch (head) {
                .@"block" => return self.emitBlock(body),
                .@"call", .@"set", .@"return", .@"if", .@"while",
                .@"for", .@"match", .@"break", .@"continue",
                .@"defer", .@"errdefer", .@"drop",
                => {
                    try self.w.writeAll("{ ");
                    try self.emitStmt(body);
                    try self.w.writeAll(" }");
                    return;
                },
                else => {},
            }
        }
        try self.emitExpr(body);
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
            // M10: value-position match. Same lowering as statement
            // position — Zig's `switch` is also an expression — but
            // arm bodies need the value-block recipe (M18) so multi-
            // statement arms produce a value via labeled `break`.
            .@"match" => try self.emitMatch(items, true),
            // M17: value-position if. Branches are wrapped in labeled
            // blocks when they need them; single-expression branches
            // are emitted inline. See `emitIfExpr` / `emitBranchExpr`.
            .@"if" => try self.emitIfExpr(items),
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

        // M9b: payload-bearing variant construction. When the callee is
        // `(enum_lit name)`, the call is constructing a tagged-union
        // value. Lower to Zig's anonymous-tagged-union literal so the
        // surrounding context (typed binding / function arg) coerces
        // it into the right enum type:
        //
        //   .variant            no args  → `.variant`
        //   .variant(x)         one arg  → `.{ .variant = x }`
        //   .variant(a, b)      pos args → `.{ .variant = .{ a, b } }`
        //   .variant(name: x)   kwargs   → `.{ .variant = .{ .name = x } }`
        if (items[1] == .list and items[1].list.len >= 2 and
            items[1].list[0] == .tag and items[1].list[0].tag == .@"enum_lit")
        {
            try self.emitPayloadVariantLit(items[1].list, items[2..]);
            return;
        }

        // Constructor-vs-call disambiguation. Per GPT-5.5's M5 design
        // pass (Q4): "resolved nominal > resolved function > fallback
        // heuristic". Sema knows whether `Foo` refers to a struct,
        // type alias, generic_type, or function — use that
        // authoritative answer when available. Without sema, fall back
        // to "any kwarg arg means struct literal" (M3/M4 heuristic).
        //
        // M14: `generic_type` callees emit as ANONYMOUS struct
        // literals (`.{ .value = 5 }`) since the named identifier is
        // a Zig fn, not a type. The surrounding type context
        // (typed binding LHS, fn arg, return) coerces the literal.
        const ConstrKind = enum { regular_struct, anon_struct, regular_call };
        const constr: ConstrKind = blk: {
            if (self.sema) |sema| {
                if (items[1] == .src) {
                    const fn_name = self.source[items[1].src.pos..][0..items[1].src.len];
                    if (sema.lookup(1, fn_name)) |sym_id| {
                        const sym = sema.symbols.items[sym_id];
                        switch (sym.kind) {
                            .nominal_type, .type_alias => break :blk .regular_struct,
                            .generic_type => break :blk .anon_struct,
                            .function => break :blk .regular_call,
                            else => {},
                        }
                    }
                }
            }
            for (items[2..]) |arg| {
                if (arg == .list and arg.list.len > 0 and arg.list[0] == .tag and
                    arg.list[0].tag == .@"kwarg")
                {
                    break :blk .regular_struct;
                }
            }
            break :blk .regular_call;
        };

        if (constr == .anon_struct) {
            // M14: generic-type construction. Emit `.{ ... }` and let
            // Zig coerce from the contextually-expected `Box(i32)`.
            try self.w.writeAll(".{ ");
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
            return;
        }

        try self.emitExpr(items[1]);
        if (constr == .regular_struct) {
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

    /// Lower a payload-variant construction to Zig's anonymous tagged-
    /// union literal. The surrounding type context (a typed binding,
    /// fn arg, return value) coerces the literal to the correct enum
    /// type — this matches Zig's natural construction style.
    ///
    /// The shape depends on the variant's payload arity, which we
    /// consult sema for (matches what `emitEnum` produced):
    ///
    ///   payload count 0 → `.variant`
    ///   payload count 1 → `.{ .variant = value }` (single arg unwraps;
    ///                      kwarg's value is extracted)
    ///   payload count N → `.{ .variant = .{ ...fields... } }`
    fn emitPayloadVariantLit(self: *Emitter, callee: []const Sexp, args: []const Sexp) Error!void {
        // No payload args → just emit `.name` (M7 path).
        if (args.len == 0) {
            try self.w.writeAll(".");
            try self.emitExpr(callee[1]);
            return;
        }

        const variant_name: ?[]const u8 = identText(self.source, callee[1]);
        const single_payload = blk: {
            if (variant_name == null or self.sema == null) break :blk false;
            // Find a sema enum with this variant name AND determine
            // its payload arity. We don't know the enclosing enum
            // type from emit alone — scan all symbols for a matching
            // variant. False positives are harmless (worst case we
            // emit a more verbose form that Zig rejects).
            // M20c: also accept `.generic_type` symbols (generic enums
            // store their variants on a generic_type symbol — same
            // structural layout via `is_variant`-flagged Fields).
            for (self.sema.?.symbols.items) |sym| {
                if (sym.kind != .nominal_type and sym.kind != .generic_type) continue;
                const fields = sym.fields orelse continue;
                for (fields) |v| {
                    if (!v.is_variant) continue;
                    if (!std.mem.eql(u8, v.name, variant_name.?)) continue;
                    const payload = v.payload orelse continue;
                    if (payload.len == 1) break :blk true;
                }
            }
            break :blk false;
        };

        try self.w.writeAll(".{ .");
        try self.emitExpr(callee[1]);
        try self.w.writeAll(" = ");

        if (single_payload and args.len == 1) {
            // Unwrap single-arg construction (matches the unwrapped
            // `variant: T` form emitted by `emitEnum`).
            const a = args[0];
            if (a == .list and a.list.len >= 3 and a.list[0] == .tag and a.list[0].tag == .@"kwarg") {
                try self.emitExpr(a.list[2]);
            } else {
                try self.emitExpr(a);
            }
        } else {
            // Multi-field or non-unwrap path: anonymous struct literal.
            try self.w.writeAll(".{ ");
            var first = true;
            for (args) |a| {
                if (!first) try self.w.writeAll(", ");
                first = false;
                if (a == .list and a.list.len >= 3 and a.list[0] == .tag and a.list[0].tag == .@"kwarg") {
                    try self.w.writeAll(".");
                    try self.emitExpr(a.list[1]);
                    try self.w.writeAll(" = ");
                    try self.emitExpr(a.list[2]);
                } else {
                    try self.emitExpr(a);
                }
            }
            try self.w.writeAll(" }");
        }
        try self.w.writeAll(" }");
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

    /// True if `sexp` is a string at emit time. M7 v1 checks:
    ///   - Raw `.src` slice quoted with `"` or `'` (string literals)
    ///   - Sigil-wrapped string literal (`?s`, `!s`, etc.)
    ///   - `.src` identifier whose sema-declared type is `string`
    ///   - `(member obj name)` where the field's type is `string`
    /// Returning true makes `print` use `{s}` instead of `{any}` so
    /// strings render as text not byte arrays.
    fn isStringLiteral(self: *const Emitter, sexp: Sexp) bool {
        switch (sexp) {
            .src => |s| {
                if (s.pos >= self.source.len) return false;
                const c = self.source[s.pos];
                if (c == '"' or c == '\'') return true;
                // M7: also true if sema knows this name is a String binding.
                // Emit doesn't track scope, so we scan all symbols for a
                // name match — first hit wins. Good enough for print
                // disambiguation (no semantic risk).
                if (self.sema) |sema| {
                    const name = self.source[s.pos..][0..s.len];
                    for (sema.symbols.items) |sym| {
                        if (std.mem.eql(u8, sym.name, name)) {
                            return sym.ty == sema.types.string_id;
                        }
                    }
                }
                return false;
            },
            .list => |items| {
                if (items.len >= 2 and items[0] == .tag) {
                    switch (items[0].tag) {
                        .@"read", .@"write", .@"move", .@"clone", .@"share" => return self.isStringLiteral(items[1]),
                        // (member obj name): if obj is a known nominal
                        // with a String field of that name, this is a
                        // string-typed expression. Same name-scan as
                        // the .src arm — emit doesn't track scope.
                        .@"member" => {
                            if (items.len < 3 or self.sema == null) return false;
                            const sema = self.sema.?;
                            const obj = items[1];
                            const fname = if (items[2] == .src)
                                self.source[items[2].src.pos..][0..items[2].src.len]
                            else
                                return false;
                            if (obj != .src) return false;
                            const oname = self.source[obj.src.pos..][0..obj.src.len];
                            for (sema.symbols.items) |sym| {
                                if (!std.mem.eql(u8, sym.name, oname)) continue;
                                // M20a / M20a.2: method params carry
                                // borrow_read / borrow_write types;
                                // peel to reach the nominal for field
                                // lookup. (Helper lives in types.zig.)
                                const peeled = types.unwrapBorrows(sema, sym.ty);
                                const ty = sema.types.get(peeled);
                                // M20b(5/5) per GPT-5.5: also handle
                                // parameterized nominals (`b: Box(String)`)
                                // — look up on the generic's fields list
                                // with the receiver's type args
                                // substituting T. Comparison goes
                                // through `typeEqualsAfterSubst` (const,
                                // non-allocating) so emit doesn't mutate
                                // sema's interner.
                                var owner_sym_id: types.SymbolId = 0;
                                var subst: types.TypeSubst = types.TypeSubst.empty;
                                if (ty == .nominal) {
                                    owner_sym_id = ty.nominal;
                                } else if (ty == .parameterized_nominal) {
                                    owner_sym_id = ty.parameterized_nominal.sym;
                                    const owner_sym = sema.symbols.items[ty.parameterized_nominal.sym];
                                    const tparams = owner_sym.type_params orelse &.{};
                                    subst = .{ .params = tparams, .args = ty.parameterized_nominal.args };
                                } else continue;
                                const owner = sema.symbols.items[owner_sym_id];
                                const fields = owner.fields orelse continue;
                                for (fields) |f| {
                                    if (std.mem.eql(u8, f.name, fname)) {
                                        return types.typeEqualsAfterSubst(sema, f.ty, subst, sema.types.string_id);
                                    }
                                }
                            }
                            return false;
                        },
                        // (call callee args...): if sema knows the
                        // callee's return type is String, treat as
                        // string-typed. Handles top-level fn calls
                        // (`greet()`) and qualified method calls
                        // (`User.greet()`).
                        .@"call" => {
                            if (items.len < 2 or self.sema == null) return false;
                            const sema = self.sema.?;
                            const callee = items[1];
                            const ret_ty: ?types.TypeId = blk: {
                                if (callee == .src) {
                                    const cname = self.source[callee.src.pos..][0..callee.src.len];
                                    for (sema.symbols.items) |sym| {
                                        if (!std.mem.eql(u8, sym.name, cname)) continue;
                                        const t = sema.types.get(sym.ty);
                                        if (t == .function) break :blk t.function.returns;
                                    }
                                }
                                if (callee == .list and callee.list.len >= 3 and
                                    callee.list[0] == .tag and callee.list[0].tag == .@"member")
                                {
                                    const owner_node = callee.list[1];
                                    const m_node = callee.list[2];
                                    if (m_node != .src) break :blk null;
                                    const mname = self.source[m_node.src.pos..][0..m_node.src.len];
                                    // Two flavors:
                                    //   - owner is a bare type name (`User.greet()`): nominal_type symbol with that name
                                    //   - M20a: owner is a value binding (`u.greet()`): nominal_type via the binding's ty.nominal
                                    if (owner_node == .src) {
                                        const oname = self.source[owner_node.src.pos..][0..owner_node.src.len];
                                        for (sema.symbols.items) |sym| {
                                            if (!std.mem.eql(u8, sym.name, oname)) continue;
                                            if (sym.kind == .nominal_type) {
                                                // Namespaced: User.greet
                                                const fields = sym.fields orelse continue;
                                                for (fields) |f| {
                                                    if (!std.mem.eql(u8, f.name, mname)) continue;
                                                    const ft = sema.types.get(f.ty);
                                                    if (ft == .function) break :blk ft.function.returns;
                                                }
                                            } else {
                                                // M20a: value binding — follow its type to its nominal.
                                                var st = sema.types.get(sym.ty);
                                                while (true) {
                                                    switch (st) {
                                                        .borrow_read => |inner| st = sema.types.get(inner),
                                                        .borrow_write => |inner| st = sema.types.get(inner),
                                                        else => break,
                                                    }
                                                }
                                                if (st != .nominal) continue;
                                                const owner = sema.symbols.items[st.nominal];
                                                const fields = owner.fields orelse continue;
                                                for (fields) |f| {
                                                    if (!std.mem.eql(u8, f.name, mname)) continue;
                                                    const ft = sema.types.get(f.ty);
                                                    if (ft == .function) break :blk ft.function.returns;
                                                }
                                            }
                                        }
                                    }
                                }
                                break :blk null;
                            };
                            if (ret_ty) |rt| return rt == sema.types.string_id;
                            return false;
                        },
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
                // M20a: substitute `Self` to the enclosing nominal name
                // when emitting inside a struct/enum/errors body.
                if (std.mem.eql(u8, txt, "Self")) {
                    if (self.current_nominal_name) |nom| {
                        try self.w.writeAll(nom);
                        return;
                    }
                }
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
                    // M14: `(generic_inst Name (T1 T2 ...))` lowers to
                    // a Zig function call `Name(T1, T2, ...)` since
                    // `(generic_type ...)` lowers to a type-returning
                    // function. Box(Int) → Box(i32).
                    .@"generic_inst" => {
                        const name_node = items[1];
                        if (name_node == .src) {
                            try self.w.writeAll(self.source[name_node.src.pos..][0..name_node.src.len]);
                        } else {
                            try self.w.writeAll("anytype");
                        }
                        try self.w.writeAll("(");
                        var first = true;
                        for (items[2..]) |arg| {
                            if (!first) try self.w.writeAll(", ");
                            first = false;
                            try self.emitType(arg);
                        }
                        try self.w.writeAll(")");
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

/// True if `body` (an IR Sexp) contains any `.src` reference whose
/// source-text equals `name`. Used by `emitMatch` to decide whether
/// to emit a `_ = name;` silencer for destructured payload bindings.
fn isNameUsedInBody(source: []const u8, body: parser.Sexp, name: []const u8) bool {
    return switch (body) {
        .src => |s| std.mem.eql(u8, source[s.pos..][0..s.len], name),
        .list => |items| blk: {
            for (items) |c| if (isNameUsedInBody(source, c, name)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// True if a match-arm pattern is a catch-all: bare `_`, or any bare
/// identifier (which acts as a "match anything and bind it" pattern).
/// M8 v1 doesn't yet thread the binding through to the body — `else =>`
/// is sufficient for control-flow correctness; the binding name is
/// available in scope via the symbol resolver's arm-scope.
fn isDefaultPattern(pattern: parser.Sexp) bool {
    return switch (pattern) {
        .src => true, // bare ident — `other`, `_`, etc.
        .nil => true,
        else => false,
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
        // Don't descend into nested fn/sub/lambda — they're separate scopes
        // analyzed by their own scanMutations call.
        if (tag == .@"fun" or tag == .@"sub" or tag == .@"lambda") return;

        // Each `(block ...)` opens a new lexical scope. Use a fresh
        // `seen` set within so a binding name reused across sibling
        // scopes (e.g., the same `tmp` in two match arms) doesn't get
        // misdetected as a reassignment of the first.
        if (tag == .@"block") {
            var inner_seen: std.StringHashMapUnmanaged(void) = .{};
            defer inner_seen.deinit(allocator);
            for (items[1..]) |child| {
                try scanMutationsRec(out, &inner_seen, allocator, child, source);
            }
            return;
        }

        if (tag == .@"set" and items.len >= 5) {
            // (set <kind> name type expr). Decide whether this site
            // means "declare a new binding" or "mutate an existing one":
            //
            //   compound ops (`+=` `-=` `*=` `/=`)  → always mutation
            //   move-assign (`<-`)                  → always mutation
            //   plain `=`                           → mutation iff target was already declared in this scope
            //   `=!` (fixed) / `new` (shadow)       → fresh binding (no mutation)
            //
            // Exhaustive switch on BindingKind — adding a new kind to
            // the enum forces an explicit decision here.
            const kind = try rig.bindingKindOf(items[1]);
            const target = items[2];
            if (target == .src) {
                const nm = source[target.src.pos..][0..target.src.len];
                switch (kind) {
                    .@"+=", .@"-=", .@"*=", .@"/=", .@"move" => {
                        // Always counts as mutation; doesn't affect `seen`.
                        try out.put(allocator, nm, {});
                    },
                    .default => {
                        if (seen.contains(nm)) {
                            try out.put(allocator, nm, {});
                        } else {
                            try seen.put(allocator, nm, {});
                        }
                    },
                    .fixed, .shadow => {
                        // Fresh binding — record in scope, don't mutate.
                        try seen.put(allocator, nm, {});
                    },
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

/// True if `sexp` is a control-flow statement that never falls through
/// to a subsequent statement (i.e., its Zig type is `noreturn`).
///
/// Used by `emitBranchExpr` to decide whether to append a `break :label
/// <expr>;` after the branch's final statement. For terminating final
/// statements, the branch produces `noreturn` and Zig coerces it to
/// the other branch's type — no `break` needed (and would be
/// unreachable).
fn isTerminatingStmt(sexp: Sexp) bool {
    if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) return false;
    return switch (sexp.list[0].tag) {
        .@"return", .@"break", .@"continue" => true,
        else => false,
    };
}
