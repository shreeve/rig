//! Rig Effects / Fallibility Checker.
//!
//! Pipeline slot: parse → normalize → sema → **effects.check** → ownership.check → emit.
//!
//! Enforces:
//!
//!   1. A call to a function declared `-> T!` must be wrapped in
//!      `(propagate ...)` (`expr!`) or `(catch ...)`. A bare consumed
//!      result (assignment / argument / return value) silently leaks
//!      a fallible past the user — the exact bug we paid down in M4.5.
//!
//!   2. A function whose body contains `(propagate ...)` must declare
//!      a fallible return type. Special exception for `sub main()`
//!      which lowers to `!void` per Zig idiom.
//!
//! Errors are reported in the standard
//! `<file>:<line>:<col>: error: <msg>` format used by the ownership
//! and sema checkers, so the CLI can stream all diagnostic streams
//! together.
//!
//! ## Sema integration (M5(4/n))
//!
//! When a `*const types.SemContext` is supplied at construction, the
//! checker pulls function signatures from sema's symbol table instead
//! of doing its own scan over the IR. The local `FunSig` collection is
//! kept as a fallback so unit tests with hand-built IR (no sema) still
//! work without rewriting them.
//!
//! Future M5+: fold this whole pass into `types.synthExpr` once
//! expression typing is rich enough to express "expected non-fallible
//! at this position" naturally — at which point this file goes away.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const types = @import("types.zig");

const Sexp = parser.Sexp;
const Tag = rig.Tag;

pub const Severity = enum { @"error", note };

pub const Diagnostic = struct {
    severity: Severity,
    pos: u32,
    message: []const u8,
};

pub const Error = std.mem.Allocator.Error;

pub const FunSig = struct {
    name: []const u8,
    is_fallible: bool,
    decl_pos: u32,
};

pub const Checker = struct {
    allocator: std.mem.Allocator,
    source: []const u8,

    /// Optional sema context. When present, signature lookups go through
    /// sema's symbol table (the source of truth post-M5); when absent
    /// (unit tests), we fall back to a local IR-walk signature scan.
    sema: ?*const types.SemContext = null,

    /// Local fallback signature table (populated only when `sema == null`).
    sigs: std.StringHashMapUnmanaged(FunSig) = .empty,

    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,

    /// True for the immediate child of `(propagate ...)` or `(catch ...)`.
    /// We only need to suppress the unwrapped-fallible-call check at the
    /// direct call site; deeper nesting is unaffected.
    in_handle_context: bool = false,

    /// `main` is allowed to use `expr!` even without declaring `-> T!`
    /// (it lowers to Zig `pub fn main() !void` per Zig idiom).
    in_main_sub: bool = false,

    /// Position to point `propagate-without-fallible-return` diagnostics
    /// at the enclosing function name (better UX than pointing at the `!`).
    current_fn_pos: u32 = 0,
    current_fn_name: []const u8 = "",
    current_fn_is_fallible: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Error!Checker {
        return .{ .allocator = allocator, .source = source };
    }

    /// Constructor that wires the sema context. Use this from the CLI
    /// pipeline so signature lookups consume sema's authoritative
    /// symbol table (no duplicate IR scan, and we automatically pick
    /// up everything sema knows — including resolved type aliases).
    pub fn initWithSema(allocator: std.mem.Allocator, source: []const u8, sema: *const types.SemContext) Error!Checker {
        return .{ .allocator = allocator, .source = source, .sema = sema };
    }

    pub fn deinit(self: *Checker) void {
        self.sigs.deinit(self.allocator);
        for (self.diagnostics.items) |d| {
            self.allocator.free(d.message);
        }
        self.diagnostics.deinit(self.allocator);
    }

    pub fn hasErrors(self: *const Checker) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    pub fn check(self: *Checker, ir: Sexp) Error!void {
        // Pass 1: collect signatures from the IR — only when sema is
        // not available. With sema, lookups go through its symbol
        // table directly (see `lookupFallibility`).
        if (self.sema == null) {
            try self.collectSignatures(ir);
        }
        // Pass 2: walk the IR and validate fallibility visibility.
        try self.walk(ir);
    }

    /// Look up whether a function name refers to a fallible function.
    /// Prefers the sema context (authoritative); falls back to the
    /// local `sigs` table for unit-test paths that don't have sema.
    /// Returns null if the name doesn't resolve at all.
    fn lookupFallibility(self: *const Checker, name: []const u8) ?FunSig {
        if (self.sema) |sema| {
            const sym_id = sema.lookup(1, name) orelse return null; // 1 = module scope
            const sym = sema.symbols.items[sym_id];
            const sym_ty = sema.types.get(sym.ty);
            const is_fallible = switch (sym_ty) {
                .function => |fn_ty| blk: {
                    const ret = sema.types.get(fn_ty.returns);
                    break :blk ret == .fallible;
                },
                else => false,
            };
            return .{
                .name = name,
                .is_fallible = is_fallible,
                .decl_pos = sym.decl_pos,
            };
        }
        return self.sigs.get(name);
    }

    pub fn writeDiagnostics(self: *const Checker, file_path: []const u8, w: anytype) !void {
        for (self.diagnostics.items) |d| {
            const lc = lineCol(self.source, d.pos);
            const tag = switch (d.severity) {
                .@"error" => "error",
                .note => "  note",
            };
            try w.print("{s}:{d}:{d}: {s}: {s}\n", .{ file_path, lc.line, lc.col, tag, d.message });
        }
    }

    // -------------------------------------------------------------------------
    // Pass 1: collect signatures
    // -------------------------------------------------------------------------

    fn collectSignatures(self: *Checker, ir: Sexp) Error!void {
        if (ir != .list or ir.list.len == 0) return;
        const items = ir.list;
        // Top-level: (module decls...).
        if (items[0] == .tag and items[0].tag == .@"module") {
            for (items[1..]) |child| try self.collectFromDecl(child);
        }
    }

    fn collectFromDecl(self: *Checker, sexp: Sexp) Error!void {
        if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) return;
        const items = sexp.list;
        switch (items[0].tag) {
            .@"pub" => if (items.len >= 2) try self.collectFromDecl(items[1]),
            .@"fun", .@"sub" => {
                if (items.len < 5) return;
                const name = identText(self.source, items[1]) orelse return;
                const decl_pos: u32 = if (items[1] == .src) items[1].src.pos else 0;
                const returns = items[3];
                const is_sub = items[0].tag == .@"sub";
                const fallible = !is_sub and isErrorUnion(returns);
                try self.sigs.put(self.allocator, name, .{
                    .name = name,
                    .is_fallible = fallible,
                    .decl_pos = decl_pos,
                });
            },
            else => {},
        }
    }

    // -------------------------------------------------------------------------
    // Pass 2: walk IR validating fallibility visibility
    // -------------------------------------------------------------------------

    fn walk(self: *Checker, sexp: Sexp) Error!void {
        if (sexp != .list or sexp.list.len == 0) return;
        const items = sexp.list;
        if (items[0] != .tag) {
            for (items) |child| try self.walk(child);
            return;
        }

        switch (items[0].tag) {
            .@"module" => for (items[1..]) |child| try self.walk(child),

            .@"pub" => if (items.len >= 2) try self.walk(items[1]),

            .@"fun", .@"sub" => try self.walkFun(items),

            // Direct child of propagate/catch is "handled" — skip the
            // unwrapped check for THAT child, but recurse normally to
            // catch deeper unwrapped calls.
            .@"propagate" => {
                if (items.len >= 2) {
                    // SPEC: `expr!` requires the enclosing fn to be fallible
                    // (or be `main`). If not, that's a hidden-effect bug.
                    if (!self.current_fn_is_fallible and !self.in_main_sub) {
                        const pos: u32 = if (items[1] == .list) firstSrcPos(items[1]) else 0;
                        try self.err(pos, "use of `!` propagation requires the enclosing function `{s}` to declare a fallible return type (`-> T!`)", .{self.current_fn_name});
                        if (self.current_fn_pos > 0) {
                            try self.note(self.current_fn_pos, "`{s}` declared here", .{self.current_fn_name});
                        }
                    }
                    const prev = self.in_handle_context;
                    self.in_handle_context = true;
                    try self.walk(items[1]);
                    self.in_handle_context = prev;
                }
            },

            .@"catch" => {
                // `(catch expr name? body)` — the first child is the
                // fallible expression being caught.
                if (items.len >= 2) {
                    const prev = self.in_handle_context;
                    self.in_handle_context = true;
                    try self.walk(items[1]);
                    self.in_handle_context = prev;
                    // The recovery body / name binding are not in handle
                    // context (further fallible calls inside need their
                    // own wrap).
                    for (items[2..]) |child| try self.walk(child);
                }
            },

            .@"call" => try self.walkCall(items),

            else => {
                // Default: recurse into children. Children are NOT in
                // handle context (only direct children of propagate/catch are).
                const prev = self.in_handle_context;
                self.in_handle_context = false;
                for (items[1..]) |child| try self.walk(child);
                self.in_handle_context = prev;
            },
        }
    }

    fn walkFun(self: *Checker, items: []const Sexp) Error!void {
        if (items.len < 5) return;
        const name = identText(self.source, items[1]) orelse "";
        const name_pos: u32 = if (items[1] == .src) items[1].src.pos else 0;
        const returns = items[3];
        const body = items[4];
        const is_sub = items[0].tag == .@"sub";
        const fallible = !is_sub and isErrorUnion(returns);

        const prev_pos = self.current_fn_pos;
        const prev_name = self.current_fn_name;
        const prev_fall = self.current_fn_is_fallible;
        const prev_main = self.in_main_sub;
        defer {
            self.current_fn_pos = prev_pos;
            self.current_fn_name = prev_name;
            self.current_fn_is_fallible = prev_fall;
            self.in_main_sub = prev_main;
        }

        self.current_fn_pos = name_pos;
        self.current_fn_name = name;
        self.current_fn_is_fallible = fallible;
        self.in_main_sub = is_sub and std.mem.eql(u8, name, "main");

        // Skip params for now (no fallible default exprs in V1) and walk body.
        try self.walk(body);
    }

    fn walkCall(self: *Checker, items: []const Sexp) Error!void {
        // (call callee args...). Validate the callee, then recurse into
        // the args (each arg is a fresh non-handle context since arguments
        // are positionally consumed).
        if (items.len < 2) return;

        const callee = items[1];
        if (callee == .src) {
            const fn_name = self.source[callee.src.pos..][0..callee.src.len];
            if (self.lookupFallibility(fn_name)) |sig| {
                if (sig.is_fallible and !self.in_handle_context) {
                    try self.err(callee.src.pos, "fallible call to `{s}` must be wrapped with `!` (propagate) or `catch` (handle)", .{fn_name});
                    if (sig.decl_pos > 0) {
                        try self.note(sig.decl_pos, "`{s}` declared as fallible here", .{fn_name});
                    }
                }
            }
        }

        // Recurse into callee + each arg with handle context cleared,
        // since arguments are positions where a fallible value would be
        // silently consumed too.
        const prev = self.in_handle_context;
        self.in_handle_context = false;
        for (items[1..]) |child| try self.walk(child);
        self.in_handle_context = prev;
    }

    // -------------------------------------------------------------------------
    // Diagnostics helpers
    // -------------------------------------------------------------------------

    fn err(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.diagnostics.append(self.allocator, .{ .severity = .@"error", .pos = pos, .message = msg });
    }

    fn note(self: *Checker, pos: u32, comptime fmt: []const u8, args: anytype) Error!void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.diagnostics.append(self.allocator, .{ .severity = .note, .pos = pos, .message = msg });
    }
};

// =============================================================================
// Helpers
// =============================================================================

fn identText(source: []const u8, sexp: Sexp) ?[]const u8 {
    if (sexp != .src) return null;
    return source[sexp.src.pos..][0..sexp.src.len];
}

fn isErrorUnion(returns: Sexp) bool {
    if (returns != .list or returns.list.len == 0 or returns.list[0] != .tag) return false;
    return returns.list[0].tag == .@"error_union";
}

fn firstSrcPos(sexp: Sexp) u32 {
    return switch (sexp) {
        .src => |s| s.pos,
        .list => |items| blk: {
            for (items) |c| {
                const p = firstSrcPos(c);
                if (p > 0) break :blk p;
            }
            break :blk 0;
        },
        else => 0,
    };
}

const LineCol = struct { line: u32, col: u32 };

fn lineCol(source: []const u8, pos: u32) LineCol {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: u32 = 0;
    const end = @min(pos, source.len);
    while (i < end) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ .line = line, .col = col };
}

// =============================================================================
// Tests
// =============================================================================

test "effects: bare fallible call without `!` or `catch` is an error" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    // Hand-build IR for:
    //   fun foo() -> User!
    //     User
    //   sub main()
    //     x = foo()
    //
    // Names point into a synthetic source string.
    const source = "fun foo()->User! User sub main() x=foo()";

    // (fun foo () (error_union User) (block User))
    const foo_name = Sexp{ .src = .{ .pos = 4, .len = 3, .id = 0 } };
    var eu_items = [_]Sexp{ .{ .tag = .@"error_union" }, .{ .src = .{ .pos = 11, .len = 4, .id = 0 } } };
    const eu = Sexp{ .list = &eu_items };
    var foo_body_items = [_]Sexp{ .{ .tag = .@"block" } };
    const foo_body = Sexp{ .list = &foo_body_items };
    var foo_items = [_]Sexp{ .{ .tag = .@"fun" }, foo_name, .{ .nil = {} }, eu, foo_body };
    const foo = Sexp{ .list = &foo_items };

    // (sub main () _ (block (set _ x _ (call foo))))
    const main_name = Sexp{ .src = .{ .pos = 25, .len = 4, .id = 0 } };
    const x_name = Sexp{ .src = .{ .pos = 33, .len = 1, .id = 0 } };
    const foo_callee = Sexp{ .src = .{ .pos = 35, .len = 3, .id = 0 } };
    var call_items = [_]Sexp{ .{ .tag = .@"call" }, foo_callee };
    const call = Sexp{ .list = &call_items };
    var set_items = [_]Sexp{ .{ .tag = .@"set" }, .{ .nil = {} }, x_name, .{ .nil = {} }, call };
    const set = Sexp{ .list = &set_items };
    var main_body_items = [_]Sexp{ .{ .tag = .@"block" }, set };
    const main_body = Sexp{ .list = &main_body_items };
    var main_items = [_]Sexp{ .{ .tag = .@"sub" }, main_name, .{ .nil = {} }, .{ .nil = {} }, main_body };
    const main_decl = Sexp{ .list = &main_items };

    var module_items = [_]Sexp{ .{ .tag = .@"module" }, foo, main_decl };
    const module = Sexp{ .list = &module_items };
    _ = aalloc;

    var c = try Checker.init(allocator, source);
    defer c.deinit();
    try c.check(module);

    try std.testing.expect(c.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), c.diagnostics.items.len); // 1 error + 1 note
}

test "effects: sema-driven signature lookup catches the same error" {
    // M5(4/n): when constructed with a SemContext, effects looks up
    // function fallibility via sema's symbol table instead of doing
    // its own IR scan. End-to-end test: parse → sema → effects.
    const source =
        \\fun loadUser(id: U64) -> User!
        \\  User
        \\
        \\sub main()
        \\  x = loadUser(1)
        \\
    ;
    const allocator = std.testing.allocator;
    var p = parser.Parser.init(allocator, source);
    defer p.deinit();
    const ir = try p.parseProgram();

    var sema = try types.check(allocator, source, ir);
    defer sema.deinit();

    var c = try Checker.initWithSema(allocator, source, &sema);
    defer c.deinit();
    try c.check(ir);

    try std.testing.expect(c.hasErrors());
    var found = false;
    for (c.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, "fallible call to `loadUser`") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "effects: propagate inside fallible function is fine" {
    const allocator = std.testing.allocator;
    const source = "fun foo()->User! User fun bar()->User! foo()!";

    const foo_name = Sexp{ .src = .{ .pos = 4, .len = 3, .id = 0 } };
    var eu_items = [_]Sexp{ .{ .tag = .@"error_union" }, .{ .src = .{ .pos = 11, .len = 4, .id = 0 } } };
    const eu = Sexp{ .list = &eu_items };
    var foo_body = [_]Sexp{ .{ .tag = .@"block" } };
    var foo_items = [_]Sexp{ .{ .tag = .@"fun" }, foo_name, .{ .nil = {} }, eu, .{ .list = &foo_body } };
    const foo = Sexp{ .list = &foo_items };

    const bar_name = Sexp{ .src = .{ .pos = 24, .len = 3, .id = 0 } };
    const foo_callee = Sexp{ .src = .{ .pos = 38, .len = 3, .id = 0 } };
    var call_items = [_]Sexp{ .{ .tag = .@"call" }, foo_callee };
    const call = Sexp{ .list = &call_items };
    var prop_items = [_]Sexp{ .{ .tag = .@"propagate" }, call };
    const prop = Sexp{ .list = &prop_items };
    var bar_body = [_]Sexp{ .{ .tag = .@"block" }, prop };
    var bar_items = [_]Sexp{ .{ .tag = .@"fun" }, bar_name, .{ .nil = {} }, eu, .{ .list = &bar_body } };
    const bar = Sexp{ .list = &bar_items };

    var module = [_]Sexp{ .{ .tag = .@"module" }, foo, bar };

    var c = try Checker.init(allocator, source);
    defer c.deinit();
    try c.check(.{ .list = &module });

    try std.testing.expect(!c.hasErrors());
}
