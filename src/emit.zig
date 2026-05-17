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

/// M20e: classification of a binding's resource type. File-scope so
/// the SymbolEntry / scope-table can carry it without a circular ref.
pub const ResourceKind = enum { shared, weak };

const SymbolEntry = struct {
    rig_name: []const u8,
    zig_name: []const u8, // may differ from rig_name due to shadowing
    /// M20e.1: resource classification carried in the emitter's scope
    /// table so use-site disarm (`<rc`, `-rc`, `return rc`) and the
    /// auto-deref bridge can dispatch correctly under shadowing. The
    /// original M20e(1/5) implementation used a global symbol scan
    /// (`resourceKindOfBareUse`) which first-match-wins picked the
    /// wrong binding when the same name was reused across functions
    /// — and for auto-drop disarm that's a memory-safety bug (a
    /// returned handle could be dropped by the function defer if the
    /// disarm missed). Per GPT-5.5's M20e post-implementation review:
    /// scoped emitter metadata is the correct phase to carry this.
    resource_kind: ?ResourceKind = null,
    /// M20g(3/5): set on a binding produced by `f = fn |...| body`.
    /// `emitCall` consults this when the callee resolves to such a
    /// binding and emits `<zig_name>.invoke(args)` instead of the
    /// regular `<zig_name>(args)`. Closure bindings emit as Zig
    /// `var` (the invoke method takes `self: *@This()`); the
    /// ownership pass enforces the V1 non-copyability so the
    /// emitter doesn't need to defend against rebinds.
    is_closure: bool = false,
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

    /// M20e: parameter list for the function whose body we're about
    /// to emit. The body emit (`emitBlock` / `emitFunBody`) consumes
    /// this once, right after writing the open brace, to install
    /// `__rig_alive_<param>` guards + `defer` for each resource-typed
    /// parameter. Set by `emitFun` before delegating to the body
    /// emitter; cleared by whichever body emitter consumed it.
    pending_param_guards: ?Sexp = null,

    /// M20f(3/4): the LHS type annotation Sexp currently being emitted
    /// into, threaded by `emitSetOrBind` so deep emit paths can
    /// recover the expected target type without re-walking sema. The
    /// `(share x)` emit needs this when `x` is a built-in nominal
    /// constructor (e.g., `Cell(value: 0)`) — without an explicit
    /// type on the struct literal, `rig.rcNew(anytype)` infers a
    /// synthetic comptime struct instead of `rig.Cell(T)`. Saved/
    /// restored on entry/exit of `emitSetOrBind` to keep nested
    /// bindings sound.
    current_set_type: ?Sexp = null,

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
        // M20e: stage the param list so the body emit can install
        // resource-binding guards for each `*T` / `~T` param right
        // after the open brace. Cleared by the body emit.
        self.pending_param_guards = params;
        if (is_sub) {
            try self.emitBlock(body);
        } else {
            try self.emitFunBody(body);
        }
        self.pending_param_guards = null;
        try self.popScope();
        try self.w.writeAll("\n");
    }

    /// Like emitBlock, but rewrites the last expression-statement to a
    /// `return <expr>;` so a `fun foo() -> Int { 1 + 2 }` actually returns.
    fn emitFunBody(self: *Emitter, body: Sexp) Error!void {
        try self.w.writeAll("{\n");
        self.indent += 1;
        try self.pushScope();
        // M20e: install param guards (consumes pending_param_guards).
        try self.flushPendingParamGuards();

        const stmts: []const Sexp = if (body == .list and body.list.len > 0 and
            body.list[0] == .tag and body.list[0].tag == .@"block")
            body.list[1..]
        else
            &[_]Sexp{body};

        for (stmts, 0..) |stmt, i| {
            try self.indentSpaces();
            if (i == stmts.len - 1 and isExprStmt(stmt)) {
                // M20e(2/5): same disarm-before-return rule as
                // emitReturn — the implicit-return path also exits
                // the function with the value, so resource bindings
                // need to be disarmed first.
                try self.emitReturnDisarmIfResource(stmt);
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

    /// M20e: consume `pending_param_guards` and emit a guard +
    /// `defer` for each resource-typed parameter, at the top of a
    /// function body (right after the `{`). Clearing the pending
    /// pointer means nested `emitBlock` calls (if/while bodies)
    /// don't accidentally re-emit guards.
    fn flushPendingParamGuards(self: *Emitter) Error!void {
        const params = self.pending_param_guards orelse return;
        self.pending_param_guards = null;
        if (params != .list) return;
        for (params.list) |p| {
            const name_node = paramNameNode(p) orelse continue;
            const kind = self.resourceKindOfBinding(name_node) orelse continue;
            // For params, the Zig-side name equals the source-side
            // name (no shadow renaming at the function entry).
            const name = if (name_node == .src)
                self.source[name_node.src.pos..][0..name_node.src.len]
            else
                continue;
            try self.indentSpaces();
            try self.emitResourceGuard(name, kind);
            try self.w.writeAll("\n");
        }
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
        // M20e.1: record param's resource classification (if any)
        // alongside its scope-table entry, so use-site lookups see
        // the correct kind under shadowing.
        try self.declareWithResourceKind(nm, nm, self.resourceKindOfBinding(name_node));
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
        try self.declareWithResourceKind(rig_name, zig_name, null);
    }

    /// M20e.1: like `declare`, but records the binding's resource
    /// classification (`shared` / `weak`) in the emitter's scope
    /// table. Callers query via `lookupResourceKind` at use sites —
    /// scope-aware lookup, sound under shadowing.
    fn declareWithResourceKind(
        self: *Emitter,
        rig_name: []const u8,
        zig_name: []const u8,
        kind: ?ResourceKind,
    ) Error!void {
        if (self.scopes.items.len == 0) try self.pushScope();
        const top = &self.scopes.items[self.scopes.items.len - 1];
        try top.symbols.append(self.allocator, .{
            .rig_name = rig_name,
            .zig_name = zig_name,
            .resource_kind = kind,
        });
    }

    /// M20g(3/5): mark the most-recently-declared symbol with the
    /// given rig_name in the current scope as a closure binding.
    /// Used by `emitClosureBinding` right after writing the
    /// closure `var` declaration so `emitCall` can later rewrite
    /// `<name>(args)` → `<name>.invoke(args)`.
    fn markClosure(self: *Emitter, rig_name: []const u8) void {
        if (self.scopes.items.len == 0) return;
        const top = &self.scopes.items[self.scopes.items.len - 1];
        var i = top.symbols.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, top.symbols.items[i].rig_name, rig_name)) {
                top.symbols.items[i].is_closure = true;
                return;
            }
        }
    }

    /// M20g(3/5): true iff the bare name resolves to a closure
    /// binding in the visible scope chain. Walked innermost-first
    /// so a closure shadowing an outer name correctly wins.
    fn lookupIsClosure(self: *const Emitter, rig_name: []const u8) bool {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const frame = &self.scopes.items[i];
            var j = frame.symbols.items.len;
            while (j > 0) {
                j -= 1;
                const s = frame.symbols.items[j];
                if (std.mem.eql(u8, s.rig_name, rig_name)) return s.is_closure;
            }
        }
        return false;
    }

    /// M20e.1: scope-aware resource classification for use sites
    /// (`<rc`, `-rc`, `return rc`, the auto-deref bridge). Replaces
    /// the M20e(1/5) `resourceKindOfBareUse` global scan, which had
    /// first-match-wins shadowing fragility unacceptable for auto-
    /// drop disarm (a missed disarm = dangling pointer returned to
    /// caller). Walks the scope stack innermost-first.
    fn lookupResourceKind(self: *const Emitter, rig_name: []const u8) ?ResourceKind {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const frame = &self.scopes.items[i];
            var j = frame.symbols.items.len;
            while (j > 0) {
                j -= 1;
                const s = frame.symbols.items[j];
                if (std.mem.eql(u8, s.rig_name, rig_name)) return s.resource_kind;
            }
        }
        return null;
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
        // M20e: install param guards if this is a function-root block
        // (consumes pending_param_guards if set). Nested blocks find
        // it null and skip.
        try self.flushPendingParamGuards();
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
                // M20d: explicit `-x` for shared/weak handles maps to
                // runtime refcount ops. M20e: also disarms the M20e
                // guard so the scope-exit `defer` is a no-op.
                if (items.len < 2) {
                    try self.w.writeAll("// drop");
                    return;
                }
                const kind = self.handleKindOf(items[1]);
                switch (kind) {
                    .shared => {
                        try self.emitExpr(items[1]);
                        try self.w.writeAll(".dropStrong();");
                        try self.emitDisarmIfBareResourceName(items[1]);
                    },
                    .weak => {
                        try self.emitExpr(items[1]);
                        try self.w.writeAll(".dropWeak();");
                        try self.emitDisarmIfBareResourceName(items[1]);
                    },
                    .other => {
                        try self.w.writeAll("// drop ");
                        try self.emitExpr(items[1]);
                    },
                }
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
            // M20e.1 (per GPT-5.5's M20e post-implementation review):
            // `<-` move-assign with a resource RHS must consume the
            // source — same as the `(move x)` wrapped form. Without
            // this, `rc2 <- rc` lowered to `rc2 = rc;` (Zig pointer
            // copy) leaving BOTH guards armed → scope-exit defers
            // double-drop on the same RcBox → UAF. Synthesize a
            // `(move RHS)` wrapper so the resource-aware emit path
            // installs the disarm.
            .@"move" => {
                var wrapped_items = [_]Sexp{ .{ .tag = .@"move" }, expr };
                const wrapped = Sexp{ .list = &wrapped_items };
                try self.emitSetOrBind(name, name_node, type_node, wrapped, false, false);
            },
            .default => try self.emitSetOrBind(name, name_node, type_node, expr, false, false),
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

        // M20f(3/4): make the LHS type visible to deep emit paths
        // (specifically the `(share x)` arm for built-in nominal
        // constructors) via a saved/restored Emitter field.
        const prev_set_type = self.current_set_type;
        self.current_set_type = if (has_type) type_node else null;
        defer self.current_set_type = prev_set_type;

        // M20g(3/5): closure binding. The RHS is a lambda literal
        // `(lambda CAPTURES PARAMS RETURNS BODY)`; lower to an
        // anonymous Zig struct + `pub fn invoke(self: *@This())`
        // method. The binding is `var` so `invoke` has a valid
        // mutable pointer; `_ = &name;` pacifies Zig's
        // "never mutated" warning in the common case where the
        // closure is only invoked. ownership.zig has already
        // enforced V1 non-copyability / non-escape, so the
        // emitter doesn't have to defend against rebinds here.
        if (isLambdaExpr(expr)) {
            try self.emitClosureBinding(name, name_node, expr, is_shadow, found);
            return;
        }

        if (is_shadow or found == null) {
            if (is_shadow and found != null) {
                // Mark the shadowed binding as "used" so Zig doesn't error
                // on the now-unreachable original.
                try self.w.print("_ = {s}; ", .{found.?});
                zig_name = try self.freshShadow(name);
            }
            // M20e.1: record the binding's resource classification
            // in the emitter's scope table so use-site disarms find
            // it via scope-aware lookup (sound under shadowing).
            try self.declareWithResourceKind(name, zig_name, self.resourceKindOfBinding(name_node));
            // `var` only if reassigned later. `=!` always emits `const`.
            //
            // M20f(2/4): Cell(T) (and other future interior-mutable
            // nominals) need their Zig storage to be mutable so the
            // `set(self: *Self, value: T)` runtime method has a
            // valid mutable pointer. Per GPT-5.5's M20f design pass:
            // emit Cell locals as `var` unconditionally — Rig's `=!`
            // still prevents rebinding at the Rig level (SPEC
            // permits interior mutation through fixed bindings).
            const is_mutated = self.fn_mutated.contains(name);
            const is_interior_mutable = self.isInteriorMutableBinding(name_node);
            const want_var = is_mutated or is_interior_mutable;
            const decl_kw: []const u8 = if (is_fixed and !is_interior_mutable)
                "const"
            else if (want_var) "var" else "const";
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
            // M20e: if this binding is a resource (`*T` / `~T`), install
            // a `var __rig_alive_<zig_name> = true;` guard + `defer` that
            // drops via the runtime if the guard is still armed at scope
            // exit. Explicit `-x` / `<x` / bare `return x` disarm the
            // guard (subsequent sub-commits cover those discharges).
            if (self.resourceKindOfBinding(name_node)) |kind| {
                try self.emitResourceGuard(zig_name, kind);
            }
            // M20f(2/4): Cell bindings are emitted as `var` so the
            // runtime `set(self: *Self, value: T)` method has a valid
            // mutable pointer. If the binding is only field-read in
            // the body (no `c.set(...)` calls), Zig fires
            // "local variable is never mutated, consider using 'const'".
            // Pacify with `_ = &<name>;` — the address-taken hint tells
            // Zig the var may be mutated through an alias. Harmless
            // when the binding IS mutated; necessary when it isn't.
            if (is_interior_mutable) {
                try self.w.print(" _ = &{s};", .{zig_name});
            }
        } else {
            // M20e(3/5): reassigning a resource binding must drop the
            // previous handle before overwriting. Without this, the
            // old strong/weak handle would leak silently. The
            // sequence is:
            //   1. Conditional drop of the previous handle (only if
            //      the guard is still armed — explicit `-rc` earlier
            //      in this scope may have already disarmed).
            //   2. The actual assignment.
            //   3. Re-arm the guard to true so scope-exit / future
            //      reassign sites can drop the new handle.
            // Together these preserve the M20e invariant: every
            // resource binding has exactly-one drop per allocation.
            //
            // Per GPT-5.5's M20e design pass: this is the only safe
            // option — silent overwrite would leak; rejection would
            // break the natural `rc = *fresh(...)` pattern.
            const found_name = found.?;
            const resource_kind = self.resourceKindOfBareUse(name);
            if (resource_kind) |kind| {
                // M20e.1 (per GPT-5.5 post-implementation review):
                // disarm INSIDE the drop-old block, BEFORE evaluating
                // the RHS. The original M20e(3/5) ordering
                //     drop_old; rhs; arm = true
                // double-dropped on fallible RHS: if `<rhs>` propagated
                // an error (via `expr!`), Zig unwinds the scope with
                // `__rig_alive_x == true` but the old handle had
                // already been dropped — the scope-exit defer would
                // call dropStrong on a freed box.
                //
                // Correct shape: clear the flag as part of the old-
                // handle release atomic step, then evaluate RHS, then
                // re-arm only after the assignment completes. If RHS
                // propagates, the flag is false and the defer is a
                // no-op (correct: the new handle never landed).
                const drop_method: []const u8 = switch (kind) {
                    .shared => "dropStrong",
                    .weak => "dropWeak",
                };
                try self.w.print("if (__rig_alive_{s}) {{ {s}.{s}(); __rig_alive_{s} = false; }} ", .{
                    found_name, found_name, drop_method, found_name,
                });
            }
            try self.w.print("{s} = ", .{found_name});
            try self.emitExpr(expr);
            try self.w.writeAll(";");
            if (resource_kind != null) {
                try self.w.print(" __rig_alive_{s} = true;", .{found_name});
            }
        }
    }

    // -------------------------------------------------------------------------
    // M20g(3/5): closure emit
    // -------------------------------------------------------------------------

    /// `(set kind name _ (lambda CAPTURES PARAMS RETURNS BODY))` →
    ///
    ///   var <name> = struct {
    ///       cap_<n1>: <T1>,
    ///       ...
    ///       pub fn invoke(self: *@This()) <RT> {
    ///           // body, with captures rewritten to `self.cap_<n>`
    ///       }
    ///   }{
    ///       .cap_<n1> = <init_expr1>,
    ///       ...
    ///   };
    ///   _ = &<name>;
    ///
    /// Per GPT-5.5's M20g(2/5) post-implementation guidance:
    ///   - receiver is `*@This()` (anchors the invoke call site;
    ///     future-proof for mutable captures)
    ///   - closure binding emits as `var` (so `f.invoke()` can take
    ///     `&f` implicitly)
    ///   - `_ = &<name>;` pacifies Zig's "never mutated" complaint
    ///     when the closure is only invoked (no direct mutation)
    ///   - capture-name references inside the body resolve to
    ///     `self.cap_<name>` via a scope-frame mapping pushed
    ///     before walking the body
    ///
    /// V1 scope per the GPT-5.5 tactical Q&A: ALL capture modes
    /// (cap_copy / cap_clone / cap_weak / cap_move) are supported
    /// at the emit level, but auto-drop guards for resource
    /// captures land in M20g(4/5). EMIT_TARGETS in (3/5) covers
    /// the Copy-capture and no-capture cases only; resource-capture
    /// closures pass sema but their emitted Zig leaks until (4/5).
    fn emitClosureBinding(
        self: *Emitter,
        rig_name: []const u8,
        name_node: Sexp,
        lambda: Sexp,
        is_shadow: bool,
        found: ?[]const u8,
    ) Error!void {
        // Resolve the shadow rename. If we're shadowing an outer
        // binding, generate a fresh `<name>_<n>` and mark the old
        // one as "used" so Zig doesn't fire dead-code warnings.
        var zig_name: []const u8 = rig_name;
        if (is_shadow and found != null) {
            try self.w.print("_ = {s}; ", .{found.?});
            zig_name = try self.freshShadow(rig_name);
        }
        try self.declareWithResourceKind(rig_name, zig_name, null);
        self.markClosure(rig_name);

        // Pull the IR pieces.
        const items = lambda.list;
        const captures = items[1];
        const params = items[2];
        const body = items[4];

        // Render the closure struct + init.
        try self.w.print("var {s} = struct {{\n", .{zig_name});
        self.indent += 1;
        try self.emitClosureFields(captures);
        try self.emitClosureInvoke(captures, params, body, lambda);
        self.indent -= 1;
        try self.indentSpaces();
        try self.w.writeAll("}");
        // Initializer.
        try self.emitClosureInit(captures);
        try self.w.writeAll(";");
        // Pacify Zig's never-mutated warning for closures that are
        // only invoked.
        try self.w.print(" _ = &{s};", .{zig_name});

        // M20g(4/5): install one M20e-style guard per RESOURCE
        // capture, anchored at the closure-instance's enclosing
        // scope. The guard's drop expression accesses the captured
        // handle through the closure struct (`<closure>.cap_<n>`)
        // so it's keyed on the closure-instance lifetime, NOT
        // per-invocation — closures may be invoked many times,
        // and the captured handle must persist until the closure
        // binding itself leaves scope.
        //
        // Pairs with M20g(3/5)'s emit of the capture init:
        //   - cap_clone shared/weak: clone() bumped refcount;
        //     guard drops the cloned handle at scope exit.
        //   - cap_weak: weakRef() created a fresh weak; guard
        //     drops it (dropWeak) at scope exit.
        //   - cap_move resource: outer's guard already disarmed
        //     via the M20e labeled-block recipe at construction
        //     time; new guard takes over from there.
        //   - cap_copy / cap_clone Copy: no resource, no guard.
        //
        // Defer ordering is LIFO — the closure's capture defers
        // fire BEFORE the outer's bare-binding defers, so e.g.
        // `rc = *Cell(...); f = fn |+rc| ...` cleanly drops the
        // closure's cloned strong handle before the outer's
        // original handle at scope exit.
        try self.emitClosureCaptureGuards(captures, zig_name);
        _ = name_node;
    }

    fn emitClosureCaptureGuards(
        self: *Emitter,
        captures: Sexp,
        closure_zig_name: []const u8,
    ) Error!void {
        if (!isCapturesNode(captures)) return;
        for (captures.list[1..]) |cap| {
            const name_node = captureNameSrc(cap) orelse continue;
            const kind = self.closureCaptureBodyResourceKind(cap, name_node) orelse continue;
            const cap_name = self.source[name_node.src.pos..][0..name_node.src.len];
            const drop_method: []const u8 = switch (kind) {
                .shared => "dropStrong",
                .weak => "dropWeak",
            };
            // Variable name: `__rig_alive_<closure>_cap_<n>` — the
            // closure-and-capture pair uniquely identifies the
            // guard, so multiple closures with same-named captures
            // (across sibling scopes) never collide.
            try self.w.writeAll("\n");
            try self.indentSpaces();
            try self.w.print(
                "var __rig_alive_{s}_cap_{s}: bool = true;",
                .{ closure_zig_name, cap_name },
            );
            try self.w.writeAll("\n");
            try self.indentSpaces();
            try self.w.print(
                "defer if (__rig_alive_{s}_cap_{s}) {{ __rig_alive_{s}_cap_{s} = false; {s}.cap_{s}.{s}(); }};",
                .{
                    closure_zig_name, cap_name,
                    closure_zig_name, cap_name,
                    closure_zig_name, cap_name,
                    drop_method,
                },
            );
        }
    }

    fn emitClosureFields(self: *Emitter, captures: Sexp) Error!void {
        if (!isCapturesNode(captures)) return;
        for (captures.list[1..]) |cap| {
            const name_node = captureNameSrc(cap) orelse continue;
            const name = self.source[name_node.src.pos..][0..name_node.src.len];
            try self.indentSpaces();
            try self.w.print("cap_{s}: ", .{name});
            try self.emitCapturedType(cap, name_node);
            try self.w.writeAll(",\n");
        }
    }

    /// Emit the Zig type for a capture field. Mode-aware:
    ///   - cap_copy / cap_clone (Copy types): outer's type
    ///   - cap_clone shared: still `*T` (cloneStrong returns same)
    ///   - cap_clone weak:   still `~T`
    ///   - cap_weak:          `~T` (we converted shared → weak)
    ///   - cap_move:          outer's type, unchanged
    ///
    /// Lookup of the outer's type goes through `self.sema` by the
    /// capture name + outer source position. Falls back to
    /// `anytype` if we can't recover a concrete type (shouldn't
    /// happen for the V1 capture shapes sema validated).
    fn emitCapturedType(self: *Emitter, cap: Sexp, name_node: Sexp) Error!void {
        const sema = self.sema orelse {
            try self.w.writeAll("anytype");
            return;
        };
        const mode = cap.list[0].tag;
        const name = self.source[name_node.src.pos..][0..name_node.src.len];
        const outer_ty_id = self.findOuterCaptureType(sema, name, name_node.src.pos) orelse {
            try self.w.writeAll("anytype");
            return;
        };
        // cap_weak converts shared(T) → weak(T). We can't intern new
        // TypeIds from emit (sema is `*const`), so handle the
        // weak-wrap directly at the Zig-type spelling level.
        if (mode == .@"cap_weak") {
            const outer_ty = sema.types.get(outer_ty_id);
            if (outer_ty == .shared) {
                try self.w.writeAll("rig.WeakHandle(");
                try self.emitZigTypeForTypeId(outer_ty.shared);
                try self.w.writeAll(")");
                return;
            }
            // Sema should have rejected non-shared cap_weak earlier.
            // Defensive fall-through emits the outer's type spelling.
        }
        try self.emitZigTypeForTypeId(outer_ty_id);
    }

    fn emitClosureInvoke(
        self: *Emitter,
        captures: Sexp,
        params: Sexp,
        body: Sexp,
        lambda: Sexp,
    ) Error!void {
        try self.indentSpaces();
        try self.w.writeAll("pub fn invoke(self: *@This()");
        if (params == .list) {
            for (params.list) |p| {
                try self.w.writeAll(", ");
                try self.emitParam(p);
            }
        }
        try self.w.writeAll(") ");
        try self.emitClosureReturnType(lambda);
        try self.w.writeAll(" ");

        // Push a fresh scope frame for the invoke method. Captures
        // become locals whose `zig_name` is the fully-qualified
        // `self.cap_<name>` expression (so a plain bare-name
        // reference inside the body emits as `self.cap_x`). Params
        // bind ordinarily.
        try self.pushScope();
        defer self.popScope() catch {};

        if (isCapturesNode(captures)) {
            for (captures.list[1..]) |cap| {
                const name_node = captureNameSrc(cap) orelse continue;
                const name = self.source[name_node.src.pos..][0..name_node.src.len];
                const qualified = std.fmt.allocPrint(
                    self.name_arena.allocator(),
                    "self.cap_{s}",
                    .{name},
                ) catch return error.OutOfMemory;
                // Capture's resource kind inside the body. We carry
                // it so the M20d read-only auto-deref bridge
                // (handleKindOf via lookupResourceKind) fires on
                // `rc.field` correctly for shared/weak captures.
                const cap_kind = self.closureCaptureBodyResourceKind(cap, name_node);
                try self.declareWithResourceKind(name, qualified, cap_kind);
            }
        }
        if (params == .list) {
            for (params.list) |p| try self.bindParam(p);
        }

        try self.emitClosureBody(body, lambda);
    }

    /// Render the lambda body. For a `(block ...)` body, the last
    /// statement is the implicit-return expression unless the
    /// inferred return type is `void` (in which case it stays a
    /// plain statement). For a single-expression body, we always
    /// emit it as a `return <expr>;`.
    fn emitClosureBody(self: *Emitter, body: Sexp, lambda: Sexp) Error!void {
        try self.w.writeAll("{\n");
        self.indent += 1;
        try self.pushScope();
        const ret_is_void = self.closureReturnIsVoid(lambda);

        // Pacify Zig's unused-parameter check on `self` for the
        // case where the body never reads any capture (Zig also
        // forbids a `_ = self;` discard when self IS used — so
        // we must scan first). Without this, a void-body lambda
        // like `fn |+rc| print('alive')` would fail Zig compile
        // with "unused function parameter" on the synthesized
        // `self: *@This()` slot.
        const captures = lambda.list[1];
        if (!bodyReferencesAnyCapture(self.source, body, captures)) {
            try self.indentSpaces();
            try self.w.writeAll("_ = self;\n");
        }

        if (body == .list and body.list.len > 0 and body.list[0] == .tag and
            body.list[0].tag == .@"block")
        {
            const stmts = body.list[1..];
            for (stmts, 0..) |stmt, i| {
                try self.indentSpaces();
                if (i == stmts.len - 1 and !ret_is_void and isExprStmt(stmt)) {
                    try self.w.writeAll("return ");
                    try self.emitExpr(stmt);
                    try self.w.writeAll(";");
                } else {
                    try self.emitStmt(stmt);
                }
                try self.w.writeAll("\n");
            }
        } else {
            try self.indentSpaces();
            if (!ret_is_void) {
                try self.w.writeAll("return ");
                try self.emitExpr(body);
                try self.w.writeAll(";");
            } else {
                try self.emitStmt(body);
            }
            try self.w.writeAll("\n");
        }
        try self.popScope();
        self.indent -= 1;
        try self.indentSpaces();
        try self.w.writeAll("}\n");
    }

    fn emitClosureInit(self: *Emitter, captures: Sexp) Error!void {
        try self.w.writeAll("{");
        if (!isCapturesNode(captures)) {
            try self.w.writeAll("}");
            return;
        }
        try self.w.writeAll(" ");
        var first = true;
        for (captures.list[1..]) |cap| {
            const name_node = captureNameSrc(cap) orelse continue;
            const name = self.source[name_node.src.pos..][0..name_node.src.len];
            if (!first) try self.w.writeAll(", ");
            first = false;
            try self.w.print(".cap_{s} = ", .{name});
            try self.emitCaptureInitExpr(cap, name_node, name);
        }
        try self.w.writeAll(" }");
    }

    fn emitCaptureInitExpr(
        self: *Emitter,
        cap: Sexp,
        name_node: Sexp,
        name: []const u8,
    ) Error!void {
        const mode = cap.list[0].tag;
        // The outer source spelling — pass through emit's symbol
        // table for shadow handling.
        const outer_zig = self.lookup(name) orelse name;
        const outer_kind = self.resourceKindOfBareUse(name);
        switch (mode) {
            .@"cap_copy" => {
                // Plain Zig value copy.
                try self.w.writeAll(outer_zig);
            },
            .@"cap_clone" => {
                // shared → cloneStrong, weak → cloneWeak, else copy.
                if (outer_kind) |k| {
                    const m: []const u8 = switch (k) {
                        .shared => "cloneStrong",
                        .weak => "cloneWeak",
                    };
                    try self.w.print("{s}.{s}()", .{ outer_zig, m });
                } else {
                    try self.w.writeAll(outer_zig);
                }
            },
            .@"cap_weak" => {
                // outer is shared(T); produce a weak handle.
                try self.w.print("{s}.weakRef()", .{outer_zig});
            },
            .@"cap_move" => {
                // For resource captures: disarm the outer guard via
                // the labeled-block recipe so the outer's defer is
                // a no-op when scope exits. For non-resource: plain
                // value passthrough.
                if (outer_kind) |_| {
                    const label = self.block_label_counter;
                    self.block_label_counter += 1;
                    try self.w.print(
                        "rig_mv_{d}: {{ __rig_alive_{s} = false; break :rig_mv_{d} {s}; }}",
                        .{ label, outer_zig, label, outer_zig },
                    );
                } else {
                    try self.w.writeAll(outer_zig);
                }
            },
            else => try self.w.writeAll(outer_zig),
        }
        _ = name_node;
    }

    /// Emit the Zig type for the lambda's invoke return slot.
    /// Reads `sema.lambda_return_types` keyed by the lambda IR's
    /// first src pos (populated in `ExprChecker.synthLambda`).
    /// Falls back to `void` for unknown types — degrades cleanly
    /// for closures whose body is a statement (e.g., a
    /// `print(...)` call that returns void).
    fn emitClosureReturnType(self: *Emitter, lambda: Sexp) Error!void {
        const sema = self.sema orelse {
            try self.w.writeAll("void");
            return;
        };
        const pos = firstSrcPosEmit(lambda);
        const ty_id = sema.lambda_return_types.get(pos) orelse {
            try self.w.writeAll("void");
            return;
        };
        try self.emitZigTypeForTypeId(ty_id);
    }

    fn closureReturnIsVoid(self: *const Emitter, lambda: Sexp) bool {
        const sema = self.sema orelse return true;
        const pos = firstSrcPosEmit(lambda);
        const ty_id = sema.lambda_return_types.get(pos) orelse return true;
        const ty = sema.types.get(ty_id);
        return switch (ty) {
            .void, .unknown, .invalid => true,
            else => false,
        };
    }

    /// Map a sema TypeId to the corresponding Zig type spelling.
    /// V1 covers the types lambdas commonly return: primitives,
    /// shared/weak handles, nominal types, parameterized
    /// nominals (Cell, etc.), optional / fallible wrappers, and
    /// borrow wrappers. Unknown/invalid → `void`.
    fn emitZigTypeForTypeId(self: *Emitter, ty_id: types.TypeId) Error!void {
        const sema = self.sema orelse {
            try self.w.writeAll("anytype");
            return;
        };
        const ty = sema.types.get(ty_id);
        switch (ty) {
            .void, .unknown, .invalid => try self.w.writeAll("void"),
            .bool => try self.w.writeAll("bool"),
            .string => try self.w.writeAll("[]const u8"),
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
            .shared => |inner| {
                try self.w.writeAll("*rig.RcBox(");
                try self.emitZigTypeForTypeId(inner);
                try self.w.writeAll(")");
            },
            .weak => |inner| {
                try self.w.writeAll("rig.WeakHandle(");
                try self.emitZigTypeForTypeId(inner);
                try self.w.writeAll(")");
            },
            .nominal => |sym_id| {
                const sym = sema.symbols.items[sym_id];
                if (isBuiltinNominalName(sym.name)) {
                    try self.w.print("rig.{s}", .{sym.name});
                } else {
                    try self.w.writeAll(sym.name);
                }
            },
            .parameterized_nominal => |pn| {
                const sym = sema.symbols.items[pn.sym];
                if (isBuiltinNominalName(sym.name)) {
                    try self.w.print("rig.{s}", .{sym.name});
                } else {
                    try self.w.writeAll(sym.name);
                }
                try self.w.writeAll("(");
                var first = true;
                for (pn.args) |arg| {
                    if (!first) try self.w.writeAll(", ");
                    first = false;
                    try self.emitZigTypeForTypeId(arg);
                }
                try self.w.writeAll(")");
            },
            else => try self.w.writeAll("void"),
        }
    }

    /// Walk sema's symbol table to find the OUTER symbol named
    /// `name` whose `decl_pos` is < `cap_pos`. Used by capture-
    /// emit to discover the outer's type at the capture site.
    /// We approximate by finding the symbol with the largest
    /// `decl_pos < cap_pos` matching name (closest preceding
    /// declaration is the most-likely outer source).
    fn findOuterCaptureType(
        self: *const Emitter,
        sema: *const types.SemContext,
        name: []const u8,
        cap_pos: u32,
    ) ?types.TypeId {
        _ = self;
        var best_pos: u32 = 0;
        var best_ty: ?types.TypeId = null;
        for (sema.symbols.items) |sym| {
            if (!std.mem.eql(u8, sym.name, name)) continue;
            if (sym.decl_pos == 0 or sym.decl_pos >= cap_pos) continue;
            // Skip the capture symbol itself (kind == .capture
            // lives inside the lambda body scope, decl_pos == name
            // node pos, which equals cap_pos here, so the
            // `< cap_pos` guard already filters it out).
            if (sym.decl_pos > best_pos) {
                best_pos = sym.decl_pos;
                best_ty = sym.ty;
            }
        }
        return best_ty;
    }

    /// What's the resource kind of a capture INSIDE the lambda
    /// body? Mostly mirrors the outer's kind, with cap_weak
    /// converting shared → weak. Used to register the capture in
    /// the body's emit scope so the M20d read-auto-deref bridge
    /// (`handleKindOf` → `lookupResourceKind`) fires correctly.
    fn closureCaptureBodyResourceKind(
        self: *const Emitter,
        cap: Sexp,
        name_node: Sexp,
    ) ?ResourceKind {
        const sema = self.sema orelse return null;
        const name = self.source[name_node.src.pos..][0..name_node.src.len];
        const outer_ty_id = self.findOuterCaptureType(sema, name, name_node.src.pos) orelse return null;
        const outer_ty = sema.types.get(outer_ty_id);
        const mode = cap.list[0].tag;
        return switch (mode) {
            .@"cap_weak" => switch (outer_ty) {
                .shared => .weak,
                else => null,
            },
            .@"cap_copy", .@"cap_clone", .@"cap_move" => switch (outer_ty) {
                .shared => .shared,
                .weak => .weak,
                else => null,
            },
            else => null,
        };
    }

    /// M20d: classify whether an expression Sexp evaluates to a shared
    /// or weak handle, for operator-emit dispatch.
    ///
    /// Best-effort, sema-aware. Currently handles the cases that matter
    /// for the common shapes the M20d emit lowering sees:
    ///   - bare name (`rc`) — global name scan over sema.symbols
    ///   - already-classified wrappers: `(read x)` / `(write x)` /
    ///     `(move x)` / `(clone x)` — recurse on operand (so e.g.
    ///     `(clone (clone rc))` still sees shared)
    ///   - `(share _)` heads — by construction `shared(_)`
    ///   - `(weak rc)` — by sema invariant `weak(_)` (operand must be
    ///     shared, enforced upstream)
    /// Returns `.other` for unknown shapes; emit falls back to the
    /// pass-through path which preserves existing non-handle behavior.
    ///
    /// Phase discipline note: the global name scan is the same
    /// fragility M20a.2's `method_two_self_methods` test pinned —
    /// first-match-wins under shadowing. Acceptable for M20d (rare
    /// collision with shared/weak names), revisited when emit grows
    /// real scope-aware symbol resolution.
    /// M20f(3/4): true when the inner expr of a `(share ...)` is a
    /// built-in-nominal constructor call AND we know the LHS type
    /// requires the corresponding `*Builtin(T)` shape. Drives the
    /// explicit-typed struct literal emit so `rig.rcNew(anytype)`
    /// can infer the right payload type. Currently only Cell.
    fn shouldExplicitTypeShareInner(self: *const Emitter, inner: Sexp) bool {
        if (inner != .list or inner.list.len < 2 or inner.list[0] != .tag) return false;
        if (inner.list[0].tag != .@"call") return false;
        const callee = inner.list[1];
        if (callee != .src) return false;
        const callee_name = self.source[callee.src.pos..][0..callee.src.len];
        if (!isBuiltinNominalName(callee_name)) return false;
        // Verify the LHS type wraps an instantiation of the same
        // built-in (i.e., `*Cell(...)`).
        const lhs = self.current_set_type orelse return false;
        if (lhs != .list or lhs.list.len < 2 or lhs.list[0] != .tag) return false;
        if (lhs.list[0].tag != .@"shared") return false;
        const inner_lhs = lhs.list[1];
        if (inner_lhs != .list or inner_lhs.list.len < 2 or inner_lhs.list[0] != .tag) return false;
        if (inner_lhs.list[0].tag != .@"generic_inst") return false;
        const lhs_name = inner_lhs.list[1];
        if (lhs_name != .src) return false;
        const lhs_name_str = self.source[lhs_name.src.pos..][0..lhs_name.src.len];
        return std.mem.eql(u8, lhs_name_str, callee_name);
    }

    /// M20f(3/4): emit a built-in nominal constructor call as an
    /// explicit-typed struct literal (`rig.Cell(i32){ .value = 0 }`
    /// rather than `.{ .value = 0 }`). The explicit type derives
    /// from the current LHS type annotation.
    fn emitExplicitTypedConstruction(self: *Emitter, call: Sexp) Error!void {
        // Type prefix: emit the inner of the `(shared (generic_inst Name T))`
        // LHS type as a Zig type. That gives us `rig.Cell(i32)`.
        const lhs = self.current_set_type.?;
        const inner_lhs = lhs.list[1]; // (generic_inst Name T)
        try self.emitType(inner_lhs);
        try self.w.writeAll("{ ");
        var first = true;
        for (call.list[2..]) |arg| {
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
    }

    /// M20f(2/4): is this binding's sema-side type an
    /// interior-mutable nominal (currently just `Cell(T)`)? Used by
    /// `emitSetOrBind` to force `var` emission so the runtime
    /// `set(self: *Self, value: T)` method has a valid mutable
    /// pointer. Per GPT-5.5's M20f design pass: emit Cell locals as
    /// `var` unconditionally — Rig's `=!` still prevents rebinding
    /// at the Rig level (SPEC permits interior mutation through
    /// fixed bindings).
    fn isInteriorMutableBinding(self: *const Emitter, name_node: Sexp) bool {
        const sema = self.sema orelse return false;
        if (name_node != .src) return false;
        const decl_pos = name_node.src.pos;
        const name = self.source[name_node.src.pos..][0..name_node.src.len];
        // M20f.1 per GPT-5.5: also match on `name`. The
        // `decl_pos`-only bridge was vulnerable to collision with
        // built-in symbols (which use `builtin_decl_pos` now, but
        // belt-and-suspenders: future builtins or other phases
        // adding decl_pos-less symbols won't accidentally match).
        for (sema.symbols.items) |sym| {
            if (sym.decl_pos != decl_pos) continue;
            if (!std.mem.eql(u8, sym.name, name)) continue;
            const ty = sema.types.get(sym.ty);
            return switch (ty) {
                .parameterized_nominal => |pn| pn.sym == sema.cell_sym_id,
                .nominal => |s| s == sema.cell_sym_id,
                else => false,
            };
        }
        return false;
    }

    /// M20e: classify a binding (by its declared-site `.src` Sexp) as
    /// `shared` / `weak` / null (not a resource). Used by M20e's
    /// auto-drop emit to decide whether to install a Zig `defer`
    /// guard for the binding.
    ///
    /// Looks up the binding's sema-side type via `decl_pos` (the same
    /// pattern as `tryEmitInferredType` / `semaBindingIsCopy` — sound
    /// under shadowing because `decl_pos` is unique per declaration).
    /// Returns null when sema isn't wired, the binding isn't found,
    /// or its type isn't shared/weak.
    ///
    /// NOTE: distinct from `handleKindOf(expr)` which classifies an
    /// expression's TYPE via a name scan — that helper is the
    /// known-fragile global-scan used for dispatch on uses. This helper
    /// is sound because declarations are unique by position.
    fn resourceKindOfBinding(self: *const Emitter, name_node: Sexp) ?ResourceKind {
        const sema = self.sema orelse return null;
        if (name_node != .src) return null;
        const decl_pos = name_node.src.pos;
        const name = self.source[name_node.src.pos..][0..name_node.src.len];
        // M20f.1: cross-check name alongside decl_pos. Defense
        // against collisions with builtin symbols.
        for (sema.symbols.items) |sym| {
            if (sym.decl_pos != decl_pos) continue;
            if (!std.mem.eql(u8, sym.name, name)) continue;
            const ty = sema.types.get(sym.ty);
            return switch (ty) {
                .shared => .shared,
                .weak => .weak,
                else => null,
            };
        }
        return null;
    }

    /// M20e.1: classify a use-site bare-name reference via the
    /// emitter's scope-aware metadata. Replaces the M20e(1/5) global
    /// sema scan — that approach was first-match-wins and could
    /// mis-classify resources under cross-function shadowing, which
    /// for auto-drop disarm is a memory-safety hazard (a missed
    /// disarm leaves the function-scope defer dropping a returned
    /// handle). Per GPT-5.5's M20e post-implementation review:
    /// scope-aware metadata carried at `declareWithResourceKind`
    /// time is the correct phase for this lookup.
    fn resourceKindOfBareUse(self: *const Emitter, name: []const u8) ?ResourceKind {
        return self.lookupResourceKind(name);
    }

    /// M20e: emit the resource-binding guard preamble.
    ///
    ///   var __rig_alive_<zig_name>: bool = true;
    ///   defer if (__rig_alive_<zig_name>) {
    ///       __rig_alive_<zig_name> = false;
    ///       <zig_name>.{dropStrong|dropWeak}();
    ///   }
    ///
    /// The disarm-inside-defer keeps Zig's "never mutated" check
    /// happy in the pure-auto-drop case (no explicit discharge in
    /// the body) while remaining semantically a no-op: explicit
    /// discharges always set the flag false BEFORE the defer fires,
    /// so the body of the defer's if-true branch only runs when
    /// auto-drop actually applies.
    ///
    /// Caller must have already emitted the binding declaration (so
    /// `<zig_name>` is in scope). Writes a trailing newline + indent.
    fn emitResourceGuard(self: *Emitter, zig_name: []const u8, kind: ResourceKind) Error!void {
        const drop_method: []const u8 = switch (kind) {
            .shared => "dropStrong",
            .weak => "dropWeak",
        };
        try self.w.writeAll("\n");
        try self.indentSpaces();
        try self.w.print("var __rig_alive_{s}: bool = true;", .{zig_name});
        try self.w.writeAll("\n");
        try self.indentSpaces();
        try self.w.print(
            "defer if (__rig_alive_{s}) {{ __rig_alive_{s} = false; {s}.{s}(); }};",
            .{ zig_name, zig_name, zig_name, drop_method },
        );
    }

    /// M20e: emit the disarm of a resource binding's guard. Called at
    /// every explicit discharge site (`-rc`, `<rc`, bare `return rc` —
    /// the last two land in subsequent sub-commits).
    fn emitResourceDisarm(self: *Emitter, zig_name: []const u8) Error!void {
        try self.w.print(" __rig_alive_{s} = false;", .{zig_name});
    }

    /// M20e: convenience for the common pattern "expr is a bare name
    /// referring to a resource binding; emit the disarm." Silent
    /// no-op for non-name or non-resource expressions, so callers
    /// can use it unconditionally.
    fn emitDisarmIfBareResourceName(self: *Emitter, expr: Sexp) Error!void {
        if (expr != .src) return;
        const name = self.source[expr.src.pos..][0..expr.src.len];
        const kind = self.resourceKindOfBareUse(name) orelse return;
        _ = kind;
        const zig_name = self.lookup(name) orelse name;
        try self.emitResourceDisarm(zig_name);
    }

    const HandleKind = enum { shared, weak, other };
    fn handleKindOf(self: *const Emitter, expr: Sexp) HandleKind {
        return switch (expr) {
            .src => |s| blk: {
                const name = self.source[s.pos..][0..s.len];
                // M20e.1: scope-aware bare-name classification via
                // the emitter's `lookupResourceKind` (declared at
                // `declareWithResourceKind` time on each binding).
                // Replaces the prior first-match-wins global sema
                // scan, which was fragile under cross-function
                // shadowing. The scope-aware path is sound under
                // shadowing because each binding's resource_kind is
                // recorded against its own scope frame.
                if (self.lookupResourceKind(name)) |kind| {
                    break :blk switch (kind) {
                        .shared => .shared,
                        .weak => .weak,
                    };
                }
                break :blk .other;
            },
            .list => |items| blk: {
                if (items.len < 2 or items[0] != .tag) break :blk .other;
                break :blk switch (items[0].tag) {
                    .@"share" => .shared,
                    .@"weak" => .weak,
                    // Recurse through transparent wrappers.
                    .@"read", .@"write", .@"move", .@"clone", .@"pin", .@"raw" => self.handleKindOf(items[1]),
                    else => .other,
                };
            },
            else => .other,
        };
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
        // M20e(2/5): bare `return rc` of a resource binding must
        // disarm the guard before the return so the scope-exit defer
        // is a no-op. Without this the caller sees the handle but
        // the defer drops it immediately, leaving a dangling pointer.
        try self.emitReturnDisarmIfResource(items[1]);
        try self.w.writeAll("return ");
        try self.emitExpr(items[1]);
        try self.w.writeAll(";");
    }

    /// M20e(2/5): if `expr` is a bare resource-binding reference,
    /// emit the disarm statement right before the `return`. Silent
    /// no-op for wrapped forms (`+rc` / `<rc` / `~rc` etc.) and
    /// non-resource expressions — those have their own discharge
    /// handling (clone keeps original alive; move already disarms
    /// via the labeled-block; etc.).
    fn emitReturnDisarmIfResource(self: *Emitter, expr: Sexp) Error!void {
        if (expr != .src) return;
        const name = self.source[expr.src.pos..][0..expr.src.len];
        if (self.resourceKindOfBareUse(name) == null) return;
        const zig_name = self.lookup(name) orelse name;
        try self.w.print("__rig_alive_{s} = false; ", .{zig_name});
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
            // Ownership wrappers: most lower transparently. M20d adds
            // runtime dispatch for shared/weak ops (below). M20e wraps
            // `(move x)` for resource bindings in a labeled-block
            // expression that disarms the guard before yielding the
            // bare handle, so the scope-exit `defer` is a no-op and
            // the callee gets a clean handle.
            .@"read", .@"write", .@"pin", .@"raw" => {
                if (items.len >= 2) try self.emitExpr(items[1]);
            },
            .@"move" => {
                if (items.len < 2) return;
                // For bare resource-name moves, emit:
                //   blk_NN: { __rig_alive_<name> = false; break :blk_NN <name>; }
                // The labeled-block form is the smallest Zig expression
                // that lets us run a side-effect (disarm) before
                // yielding the value, in any expression context.
                const inner = items[1];
                if (inner == .src) {
                    const name = self.source[inner.src.pos..][0..inner.src.len];
                    if (self.resourceKindOfBareUse(name)) |_| {
                        const zig_name = self.lookup(name) orelse name;
                        const label = self.block_label_counter;
                        self.block_label_counter += 1;
                        try self.w.print(
                            "rig_mv_{d}: {{ __rig_alive_{s} = false; break :rig_mv_{d} {s}; }}",
                            .{ label, zig_name, label, zig_name },
                        );
                        return;
                    }
                }
                // Non-resource move: pass through (M2 enforced
                // ownership; Zig's value semantics handle the transfer).
                try self.emitExpr(inner);
            },
            // M20d: `(share x)` always constructs a fresh Rc box.
            // Operator semantics: `*expr` MOVES `expr` into the new
            // RcBox (per GPT-5.5's M20d design pass — implicit clone
            // would silently duplicate ownership). The OOM behavior
            // is panic (Rust-style); the runtime helper returns an
            // error union for future recoverable-allocation APIs.
            //
            // M20f(3/4): when the inner is a built-in nominal
            // construction (e.g., `Cell(value: 0)`) and the LHS
            // type peels to that built-in, emit the inner as an
            // explicit-typed struct literal so `rig.rcNew(anytype)`
            // can infer the right RcBox payload type. Without this,
            // the anonymous struct literal `.{ .value = 0 }` would
            // get inferred as a synthetic comptime struct and the
            // resulting `*RcBox(synthetic_struct)` mismatches the
            // expected `*RcBox(rig.Cell(i32))`.
            .@"share" => {
                if (items.len < 2) return;
                try self.w.writeAll("(rig.rcNew(");
                if (self.shouldExplicitTypeShareInner(items[1])) {
                    try self.emitExplicitTypedConstruction(items[1]);
                } else {
                    try self.emitExpr(items[1]);
                }
                try self.w.writeAll(") catch @panic(\"Rig Rc allocation failed\"))");
            },
            // M20d: `(clone x)` dispatches on the operand's TYPE.
            //   shared(T) → x.cloneStrong()
            //   weak(T)   → x.cloneWeak()
            //   else      → pass-through (Zig value copy)
            // When the operand's type is unknown (sema couldn't infer),
            // we conservatively pass through so existing non-shared
            // `+x` uses keep working.
            .@"clone" => {
                if (items.len < 2) return;
                const kind = self.handleKindOf(items[1]);
                switch (kind) {
                    .shared => {
                        try self.emitExpr(items[1]);
                        try self.w.writeAll(".cloneStrong()");
                    },
                    .weak => {
                        try self.emitExpr(items[1]);
                        try self.w.writeAll(".cloneWeak()");
                    },
                    .other => try self.emitExpr(items[1]),
                }
            },
            // M20d: `(weak x)` constructs a weak handle from a shared
            // operand. Sema already requires operand to be shared(T)
            // (see types.zig synthList .@"weak" arm), so we can emit
            // `.weakRef()` unconditionally — failures would have been
            // caught upstream.
            .@"weak" => {
                if (items.len < 2) return;
                try self.emitExpr(items[1]);
                try self.w.writeAll(".weakRef()");
            },
            // Calls
            .@"call" => try self.emitCall(items),
            // Member / index
            .@"member" => {
                if (items.len >= 3) {
                    try self.emitExpr(items[1]);
                    // M20d(4/5) read-only auto-deref: when the obj's
                    // type is `shared(T)`, Zig sees a `*rig.RcBox(T)`
                    // — field/method access on T requires bridging
                    // through `.value`. Sema has already validated
                    // that the access is read-only (write/value
                    // receivers and field-target assigns are rejected
                    // by checkReceiverMode / checkSet).
                    if (self.handleKindOf(items[1]) == .shared) {
                        try self.w.writeAll(".value");
                    }
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

        // M20g(3/5): closure invocation. If the callee is a bare
        // name resolving to a closure binding (marked by
        // `emitClosureBinding` via `is_closure=true` on the
        // SymbolEntry), lower `f(args)` to `f.invoke(args)`. The
        // ownership pass already guarantees the closure is in
        // call-receiver position, so we never see this name in
        // a context that would require .invoke handling elsewhere.
        if (items[1] == .src) {
            const cn = self.source[items[1].src.pos..][0..items[1].src.len];
            if (self.lookupIsClosure(cn)) {
                const zig_name = self.lookup(cn) orelse cn;
                try self.w.print("{s}.invoke(", .{zig_name});
                var first = true;
                for (items[2..]) |arg| {
                    if (!first) try self.w.writeAll(", ");
                    first = false;
                    try self.emitExpr(arg);
                }
                try self.w.writeAll(")");
                return;
            }
        }

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
                    // M20d: type-position `*T` and `~T` lower to the
                    // runtime's RcBox / WeakHandle generic instantiations.
                    // Variable bindings of shared type carry a Zig pointer
                    // (`*rig.RcBox(T)`); weak bindings carry the struct
                    // value (`rig.WeakHandle(T)`).
                    .@"shared" => {
                        try self.w.writeAll("*rig.RcBox(");
                        try self.emitType(items[1]);
                        try self.w.writeAll(")");
                    },
                    .@"weak" => {
                        try self.w.writeAll("rig.WeakHandle(");
                        try self.emitType(items[1]);
                        try self.w.writeAll(")");
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
                    //
                    // M20f: built-in nominal types (`Cell`) live in the
                    // runtime module, so the emitted Zig form is
                    // `rig.Cell(T)` not bare `Cell(T)`. Identified by
                    // name; the corresponding sema symbol is registered
                    // by `registerBuiltins` at module-scope creation.
                    .@"generic_inst" => {
                        const name_node = items[1];
                        if (name_node == .src) {
                            const name = self.source[name_node.src.pos..][0..name_node.src.len];
                            if (isBuiltinNominalName(name)) try self.w.writeAll("rig.");
                            try self.w.writeAll(name);
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

/// M20f: is `name` one of Rig's built-in nominal types whose Zig
/// implementation lives in `_rig_runtime.zig`? Currently just
/// `Cell`. The list grows as more stdlib types get runtime-baked.
fn isBuiltinNominalName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Cell");
}

/// M20e helper: extract the name `.src` node from any param shape.
/// Returns null for shapes that don't carry a normal name (e.g.,
/// destructured params if/when those land).
fn paramNameNode(p: Sexp) ?Sexp {
    switch (p) {
        .src => return p,
        .list => |items| {
            if (items.len < 2 or items[0] != .tag) return null;
            return switch (items[0].tag) {
                .@":", .pre_param, .default, .aligned, .@"read", .@"write" => items[1],
                else => null,
            };
        },
        else => return null,
    }
}

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

/// M20g(3/5): true iff `sexp` is a lambda literal `(lambda ...)`.
fn isLambdaExpr(sexp: Sexp) bool {
    if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) return false;
    return sexp.list[0].tag == .@"lambda";
}

/// M20g(3/5): true iff `sexp` is the `(captures cap_node...)` wrapper.
fn isCapturesNode(sexp: Sexp) bool {
    if (sexp != .list or sexp.list.len < 2 or sexp.list[0] != .tag) return false;
    return sexp.list[0].tag == .@"captures";
}

/// M20g(3/5): extract the NAME `.src` from a capture node
/// `(cap_xxx NAME)`. Returns null for malformed shapes.
fn captureNameSrc(cap: Sexp) ?Sexp {
    if (cap != .list or cap.list.len < 2 or cap.list[0] != .tag) return null;
    return switch (cap.list[0].tag) {
        .@"cap_copy", .@"cap_clone", .@"cap_weak", .@"cap_move" => cap.list[1],
        else => null,
    };
}

/// M20g(3/5): true iff `body` contains any bare-name reference
/// (`.src`) matching one of the capture names in `captures`.
/// Drives the `_ = self;` pacification: Zig forbids the discard
/// when self IS used, but also requires self use somewhere. Body
/// references to capture names get rewritten in emit to
/// `self.cap_<n>`, so a capture-name `.src` reaching this scan
/// means the body will reference `self.cap_<n>` and we should
/// SKIP the discard. Returns true for the lookup-finds-capture
/// case AND for explicit `(deref self)`/`(member self ...)`
/// shapes — both keep `self` live for Zig.
fn bodyReferencesAnyCapture(source: []const u8, body: Sexp, captures: Sexp) bool {
    if (!isCapturesNode(captures)) return false;
    return scanBodyForCaptureRef(source, body, captures.list[1..]);
}

fn scanBodyForCaptureRef(source: []const u8, sexp: Sexp, caps: []const Sexp) bool {
    return switch (sexp) {
        .src => |s| blk: {
            const text = source[s.pos..][0..s.len];
            for (caps) |c| {
                const nn = captureNameSrc(c) orelse continue;
                if (nn != .src) continue;
                const cn = source[nn.src.pos..][0..nn.src.len];
                if (std.mem.eql(u8, text, cn)) break :blk true;
            }
            break :blk false;
        },
        .list => |items| blk: {
            // Don't recurse into nested lambdas (those have their
            // own scope; the outer captures are not visible by
            // M20g sema, so any bare-name match would be a false
            // positive from a same-named local inside the inner
            // lambda).
            if (items.len > 0 and items[0] == .tag and items[0].tag == .@"lambda") {
                break :blk false;
            }
            for (items) |child| {
                if (scanBodyForCaptureRef(source, child, caps)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// M20g(3/5): recursively find the first `.src` position in a Sexp
/// (mirrors the helper in src/types.zig). Used to key the
/// `lambda_return_types` map between sema and emit; both ends
/// derive the key from the lambda IR itself, so the
/// stash + read sites agree.
fn firstSrcPosEmit(s: Sexp) u32 {
    return switch (s) {
        .src => |x| x.pos,
        .list => |items| blk: {
            for (items) |c| {
                const p = firstSrcPosEmit(c);
                if (p > 0) break :blk p;
            }
            break :blk 0;
        },
        else => 0,
    };
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
