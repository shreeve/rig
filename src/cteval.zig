//! Compile-time functions: `fun cap[n: Int] -> Int`, a `fun` with
//! compile-time parameters and no run-time list (`rig.isCtFun`). The
//! checker runs one, never Zig and never the program: a call, `cap[8]`,
//! is a constant wherever it is written, and every failure is a Rig
//! diagnostic at the call (docs/internals/INTERNALS.md, "Compile-time
//! functions").
//!
//! - `State` is each module's record: its compile-time functions and
//!   how far each is checked (`resolve.ensureCtFun`), the values calls
//!   computed (the memo), the value each checked call has
//!   (`Instance.ct_call`), and the hidden constants emit writes for
//!   arrays.
//! - `checkSignature`, `checkNames`, and `checkBody` hold a compile-time
//!   function to what runs at compile time: integers, `Bool`, plain
//!   enums, and arrays of them, through a positive list of forms.
//! - `Eval` runs a checked body over the types the checker recorded,
//!   with the arithmetic of constant folding (`sema.ctArith`), within
//!   fixed limits, so `rig check` gives the same verdict on every machine.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const sema = @import("sema.zig");
const resolve = @import("resolve.zig");
const diag = sema.diag;

const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const TypeId = sema.TypeId;
const Wide = sema.Wide;
const IntInfo = sema.IntInfo;
const NodeKey = sema.NodeKey;
const Error = std.mem.Allocator.Error;
const identAt = sema.identAt;

/// The most steps one evaluation takes: each expression, each loop
/// iteration, and each array element copied is a step.
pub const max_steps: u64 = 10_000_000;
/// The most compile-time calls nested in one another.
pub const max_depth: u32 = 256;
/// The most bytes of values one evaluation makes.
pub const max_bytes: u64 = 64 << 20;

/// A value a compile-time function computes: an integer (its type is
/// the checker's), a `Bool`, a plain enum's variant (its index among
/// the enum's members, `Symbol.fields`), or an array of them.
pub const CtVal = union(enum) {
    int: Wide,
    boolean: bool,
    variant: u32,
    array: []CtVal,
};

pub const Stage = enum(u2) { new, open, done };

/// A compile-time function of the module: its declaration, and how far
/// its signature and its body are checked (`resolve.ensureCtFun`).
pub const CtFun = struct {
    decl: Sexp,
    sig: Stage = .new,
    sig_ok: bool = false,
    body: Stage = .new,
    ok: bool = false,
};

/// Why an evaluation failed: what the call does (`compile-time call
/// \`f[0]\` {what}`), and the node of the body where, in module `module`.
pub const Failure = struct {
    what: []const u8,
    module: u32,
    pos: u32,
    node: []const u8,
    /// The call running the node when it is not the one asked for:
    /// `fib[93]` inside `fib[100]`.
    frame: []const u8,
};

pub const Outcome = union(enum) { value: CtVal, failed: Failure };

/// A memo key: the function's symbol, then each argument (`argKey`).
pub const Key = []const Wide;

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(k));
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return std.mem.eql(Wide, a, b);
    }
};

/// The value of a checked compile-time call (`Instance.ct_call`): its
/// value, its type in the module that calls, and the hidden constant
/// that holds it when it is an array a body reads (`hidden`).
pub const Result = struct { value: CtVal, ty: TypeId, hidden: ?u32 = null };

/// A hidden constant emit writes once per module for an array value
/// run-time code reads, `__rig_ct_<i>`.
pub const Hidden = struct { value: CtVal, ty: TypeId };

pub const State = struct {
    /// The module's compile-time functions, by symbol.
    funs: std.AutoHashMapUnmanaged(SymbolId, CtFun) = .empty,
    /// The plain enums resolved ahead of the other declarations, for a
    /// compile-time function that names one (`resolve.resolveEnumsNamed`),
    /// by node id.
    early: std.AutoHashMapUnmanaged(parser.NodeId, void) = .empty,
    /// What each call of a function of this module computed, by its
    /// arguments, failures too: each is computed once for the program.
    memo: std.HashMapUnmanaged(Key, Outcome, KeyContext, 80) = .empty,
    /// The values of the checked calls in this module's code.
    results: std.ArrayList(Result) = .empty,
    /// The hidden constants, and which value each holds: the declaring
    /// module's id, then the memo key.
    hidden: std.ArrayList(Hidden) = .empty,
    hidden_of: std.HashMapUnmanaged(Key, u32, KeyContext, 80) = .empty,
    /// The module's tree, whose declarations `plainEnumDecl` finds.
    tree: Sexp = .nil,

    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.funs.deinit(a);
        self.early.deinit(a);
        self.memo.deinit(a);
        self.results.deinit(a);
        self.hidden.deinit(a);
        self.hidden_of.deinit(a);
    }

    /// Record each compile-time function `tree` declares.
    pub fn declare(self: *State, ctx: *SemContext, tree: Sexp) Error!void {
        self.tree = tree;
        for (ir.Module.decls(tree)) |decl| {
            if (!rig.isCtFun(decl)) continue;
            const id = ctx.symbolOf(ir.Fun.name(rig.unpub(decl))) orelse continue;
            const gop = try self.funs.getOrPut(ctx.allocator, id);
            if (!gop.found_existing) gop.value_ptr.* = .{ .decl = decl };
        }
    }
};

/// Whether symbol `id` of `ctx` is a compile-time function.
pub fn isCtFunction(ctx: *const SemContext, id: SymbolId) bool {
    return ctx.ct.funs.contains(id);
}

/// The declaration of plain enum `id` of this module, when it is one: an
/// `enum` none of whose variants has a payload.
pub fn plainEnumDecl(ctx: *const SemContext, id: SymbolId) ?Sexp {
    const pos = ctx.symbols.items[id].decl_pos;
    if (ctx.ct.tree == .nil) return null;
    for (ir.Module.decls(ctx.ct.tree)) |decl| {
        const d = rig.unpub(decl);
        if (!d.isKind(.@"enum")) continue;
        const name = ir.get(d, .name);
        if (name != .src or name.src.pos != pos) continue;
        for (ir.rest(d, .members)) |m| if (m.isKind(.variant)) return null;
        return d;
    }
    return null;
}

// =============================================================================
// What runs at compile time
// =============================================================================

/// The types a compile-time function holds: an integer, `Bool`, a plain
/// enum, or a fixed array of them.
pub fn isPlain(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .int, .int_literal, .bool => true,
        .array => |a| isPlain(ctx, a.elem),
        .nominal, .imported_nominal => sema.isPlainEnum(ctx, ty),
        else => false,
    };
}

/// A scalar a compile-time parameter may be: an integer, `Bool`, or a
/// plain enum.
fn isScalar(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .int, .bool => true,
        .nominal, .imported_nominal => sema.isPlainEnum(ctx, ty),
        else => false,
    };
}

const plain_rule = "it holds only integers, `Bool`, plain enums, and arrays of them";

/// A compile-time function's signature, resolved as `fn_ty`: each
/// parameter a value of a scalar type, and its result one of those or an
/// array of them.
pub fn checkSignature(ctx: *SemContext, def: Sexp, fn_ty: TypeId) Error!void {
    const f = switch (ctx.types.get(fn_ty)) {
        .function => |f| f,
        else => return,
    };
    const name = identAt(ctx.source, ir.Fun.name(def)) orelse "f";
    for (ir.Fun.tparams(def).items(), f.ct_params) |p, ty| {
        if (sema.containsPoison(ctx, ty)) continue;
        if (isScalar(ctx, ty)) continue;
        try ctx.errAt(ir.get(p, .type), "compile-time function `{s}` cannot take a `{s}`: its parameters are integers, `Bool`, and plain enums", .{ name, try sema.formatType(ctx, ty) });
    }
    if (!sema.containsPoison(ctx, f.returns) and !isPlain(ctx, f.returns)) {
        try ctx.errAt(ir.Fun.returns(def), "compile-time function `{s}` cannot give a `{s}`: it gives an integer, a `Bool`, a plain enum, or an array of them", .{ name, try sema.formatType(ctx, f.returns) });
    }
}

/// The names a compile-time function's body reads that the module
/// declares, checked before the body is typed, which happens ahead of
/// the module's other declarations: a constant must be an integer one
/// (folded already, so its type is known), and a type a plain enum or an
/// integer alias. False after a diagnostic.
pub fn checkNames(ctx: *SemContext, def: Sexp) Error!bool {
    var w: Names = .{ .ctx = ctx };
    defer w.rejected.deinit(ctx.allocator);
    try w.walk(ir.Fun.body(def));
    return w.ok;
}

const Names = struct {
    ctx: *SemContext,
    ok: bool = true,
    /// The names rejected, each reported once.
    rejected: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,

    fn walk(self: *Names, node: Sexp) Error!void {
        const ctx = self.ctx;
        switch (node) {
            .src => {
                const name = identAt(ctx.source, node) orelse return;
                const id = ctx.lookupInScopeOnly(sema.module_scope, name) orelse return;
                if (self.rejected.contains(id)) return;
                const mark = ctx.diagnostics.items.len;
                defer if (ctx.diagnostics.items.len != mark) {
                    self.ok = false;
                    self.rejected.put(ctx.allocator, id, {}) catch {};
                };
                const ok = &self.ok;
                const sym = ctx.symbols.items[id];
                // A local binding of the body with the name of a declaration
                // is rejected where it is declared.
                if (ctx.symbolOf(node)) |own| if (own != id) return;
                switch (sym.kind) {
                    .local => if (sema.isModuleConst(ctx, id)) {
                        // A constant that depends on itself was reported.
                        if (sym.ty == ctx.types.invalid_id) {
                            ok.* = false;
                            return;
                        }
                        const c = ctx.const_ints.get(id) orelse {
                            try ctx.errAt(node, "a compile-time function cannot read `{s}`: it reads integer constants, and `{s}` is not one", .{ name, name });
                            ok.* = false;
                            return;
                        };
                        if (sym.ty == ctx.types.unknown_id) ctx.symbols.items[id].ty = try ctx.intern(.{ .int = c.int });
                    },
                    .nominal_type => if (plainEnumDecl(ctx, id) == null) {
                        try ctx.errAt(node, "a compile-time function cannot use `{s}`: " ++ plain_rule, .{name});
                        ok.* = false;
                    },
                    .generic_type => {
                        try ctx.errAt(node, "a compile-time function cannot use `{s}`: " ++ plain_rule, .{name});
                        ok.* = false;
                    },
                    // An alias of an integer type; any other names a type
                    // whose declaration may not be resolved yet.
                    .type_alias => if (sema.aliasIntType(ctx, id) == null) {
                        try ctx.errAt(node, "a compile-time function cannot use `{s}`: " ++ plain_rule ++ ", and `{s}` names no integer type", .{ name, name });
                        ok.* = false;
                    },
                    .@"extern" => {
                        try ctx.errAt(node, "a compile-time function cannot read `{s}`: C sets it when the program runs", .{name});
                        ok.* = false;
                    },
                    else => {},
                }
            },
            .list => {
                // A member's name and a keyword's are not names in scope.
                if (node.isKind(.member)) return self.walk(ir.Member.object(node));
                if (node.isKind(.enum_lit) or node.isKind(.symbol)) return;
                if (node.isKind(.kwarg)) return self.walk(ir.Kwarg.value(node));
                for (rig.children(node)) |c| try self.walk(c);
            },
            else => {},
        }
    }
};

/// The body of compile-time function `def`, typed, checked against the
/// positive list of what runs at compile time: each node a form the
/// evaluator runs (`Eval`), and each value one it holds (`isPlain`).
pub fn checkBody(ctx: *SemContext, def: Sexp) Error!void {
    var w: Pure = .{ .ctx = ctx, .name = identAt(ctx.source, ir.Fun.name(def)) orelse "f", .def = def };
    _ = try w.stmt(ir.Fun.body(def));
}

const Pure = struct {
    ctx: *SemContext,
    name: []const u8,
    def: Sexp,

    fn text(self: *Pure, node: Sexp) []const u8 {
        return diag.textOf(self.ctx.source, self.ctx.span(node));
    }

    /// Reject `node`: a compile-time function cannot `form`, for `why`.
    /// False, so a caller returns it.
    fn reject(self: *Pure, node: Sexp, comptime form: []const u8, form_args: anytype, comptime why: []const u8, why_args: anytype) Error!bool {
        const f = try self.ctx.arena.allocator().print(form, form_args);
        const y = try self.ctx.arena.allocator().print(why, why_args);
        try self.ctx.errAt(node, "a compile-time function cannot {s}: {s}", .{ f, y });
        return false;
    }

    /// Whether `node`'s value is one a compile-time function holds.
    fn plainValue(self: *Pure, node: Sexp) Error!bool {
        const ty = self.ctx.typeOf(node) orelse return true;
        if (sema.containsPoison(self.ctx, ty) or isPlain(self.ctx, ty)) return true;
        return self.reject(node, "hold `{s}`", .{self.text(node)}, "it is a `{s}`, and " ++ plain_rule, .{try sema.formatType(self.ctx, ty)});
    }

    fn stmts(self: *Pure, list: []const Sexp) Error!bool {
        var ok = true;
        for (list) |s| if (!try self.stmt(s)) {
            ok = false;
        };
        return ok;
    }

    fn stmt(self: *Pure, s: Sexp) Error!bool {
        const h = s.kind() orelse return self.expr(s);
        switch (h) {
            .block => return self.stmts(ir.Block.stmts(s)),
            .set => {
                const target = ir.Set.target(s);
                if (target != .src and !try self.place(target)) return false;
                return self.expr(ir.Set.value(s));
            },
            .@"while" => {
                var ok = try self.expr(ir.While.cond(s));
                if (ir.While.step(s) != .nil and !try self.stmt(ir.While.step(s))) ok = false;
                if (!try self.stmt(ir.While.body(s))) ok = false;
                if (ir.While.@"else"(s) != .nil and !try self.stmt(ir.While.@"else"(s))) ok = false;
                return ok;
            },
            .@"for" => {
                if (ir.For.mode(s).tag != .iter) return self.reject(s, "lend in a loop's source", .{}, "its values are plain and copied: write `for x in {s}`", .{self.text(ir.For.source(s))});
                const source = ir.For.source(s);
                var ok = if (source.isKind(.@"..")) blk: {
                    if (ir.get(source, .left) == .nil or ir.get(source, .right) == .nil) break :blk try self.reject(source, "loop over `{s}`", .{self.text(source)}, "a range it walks has both ends", .{});
                    break :blk (try self.expr(ir.get(source, .left))) and (try self.expr(ir.get(source, .right)));
                } else try self.expr(source);
                if (!try self.stmt(ir.For.body(s))) ok = false;
                if (ir.For.@"else"(s) != .nil and !try self.stmt(ir.For.@"else"(s))) ok = false;
                return ok;
            },
            .labeled => {
                const inner = ir.Labeled.stmt(s);
                if (!inner.isKind(.@"while") and !inner.isKind(.@"for")) return self.reject(s, "label `{s}`", .{self.text(s)}, "it labels only loops", .{});
                return self.stmt(inner);
            },
            .@"break" => {
                if (ir.Break.value(s) != .nil) return self.expr(ir.Break.value(s));
                return true;
            },
            .@"continue", .pass => return true,
            .@"return" => return if (ir.get(s, .value) == .nil) true else self.expr(ir.get(s, .value)),
            .panic => {
                var ok = true;
                for (ir.Panic.args(s)) |a| {
                    if (isStringLiteral(self.ctx.source, a)) continue;
                    if (!try self.expr(a)) ok = false;
                }
                return ok;
            },
            .@"if", .match => return self.expr(s),
            else => return self.expr(s),
        }
    }

    /// The target of an assignment: a local, or an element of a local
    /// array, `t[i]`, `t[i][j]`.
    fn place(self: *Pure, target: Sexp) Error!bool {
        if (target == .src) return true;
        if (target.isKind(.index) and self.ctx.instanceOf(target) == null) {
            return (try self.place(ir.get(target, .object))) and (try self.expr(ir.Index.index(target)));
        }
        return self.reject(target, "assign to `{s}`", .{self.text(target)}, "it assigns locals and elements of local arrays", .{});
    }

    fn exprs(self: *Pure, list: []const Sexp) Error!bool {
        var ok = true;
        for (list) |e| if (!try self.expr(e)) {
            ok = false;
        };
        return ok;
    }

    fn expr(self: *Pure, e: Sexp) Error!bool {
        if (e == .nil) return true;
        if (e == .src) {
            if (isStringLiteral(self.ctx.source, e)) return self.reject(e, "hold text", .{}, plain_rule, .{});
            return self.plainValue(e);
        }
        const h = e.kind() orelse return true;
        switch (h) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>", .@"&", .@"|", .@"^", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"and", .@"or" => {
                const ok = try self.exprs(&.{ ir.get(e, .left), ir.get(e, .right) });
                return ok and try self.plainValue(e);
            },
            .neg, .not => return (try self.expr(ir.get(e, .operand))) and try self.plainValue(e),
            .enum_lit => return self.plainValue(e),
            .member => {
                const obj = ir.Member.object(e);
                const name = identAt(self.ctx.source, ir.Member.name(e)) orelse "";
                // `t.len`, of an array the body holds.
                if (std.mem.eql(u8, name, "len")) if (self.ctx.typeOf(obj)) |ot| if (self.ctx.types.get(ot) == .array) return self.expr(obj);
                // `U8.max`, `Mode.loose`, `lib.N`: a constant.
                if (sema.intLimit(self.ctx, e) != null) return true;
                if (sema.patternConst(self.ctx, e)) |c| {
                    if (sema.constScalar(c) != null) return self.plainValue(e);
                    return self.reject(e, "read `{s}`", .{self.text(e)}, "it reads integer, `Bool`, and enum constants", .{});
                }
                if (self.ctx.typeOf(e)) |ty| if (sema.isPlainEnum(self.ctx, ty) and self.namesType(obj)) return true;
                return self.reject(e, "read `{s}`", .{self.text(e)}, "it reads its own values, constants, and `.len` of an array", .{});
            },
            .index, .inst => {
                if (self.ctx.instanceOf(e)) |inst| switch (inst) {
                    .ct_call => return (try self.exprs(sema.bracketArgs(e))) and try self.plainValue(e),
                    else => return self.reject(e, "use `{s}`", .{self.text(e)}, "it calls only compile-time functions", .{}),
                };
                if (h == .inst) return self.reject(e, "use `{s}`", .{self.text(e)}, "it calls only compile-time functions", .{});
                return (try self.expr(ir.get(e, .object))) and (try self.expr(ir.Index.index(e))) and try self.plainValue(e);
            },
            .call => {
                const callee = ir.Call.callee(e);
                if (ir.Call.task(e) != .nil) return self.reject(e, "start a task", .{}, "nothing runs beside the compiler", .{});
                if (isIntConversion(self.ctx, e)) return (try self.expr(ir.Call.args(e)[0])) and try self.plainValue(e);
                if (callee.isKind(.member)) {
                    const m = identAt(self.ctx.source, ir.Member.name(callee)) orelse "";
                    return self.reject(e, "call the method `{s}`", .{m}, "it reads only `.len` of an array", .{});
                }
                const shown = self.text(if (rig.isBracketList(callee)) ir.get(callee, .object) else callee);
                return self.reject(e, "call `{s}`", .{shown}, "`{s}` runs when the program does, and a compile-time function calls only compile-time functions, with brackets; if `{s}` runs when the program does too, write `fun {s}`", .{ shown, self.name, try self.header() });
            },
            .array => return (try self.exprs(ir.Array.elems(e))) and try self.plainValue(e),
            .array_fill => return (try self.expr(ir.ArrayFill.size(e))) and (try self.expr(ir.ArrayFill.value(e))) and try self.plainValue(e),
            .@"if" => {
                var ok = try self.expr(ir.If.cond(e));
                if (!try self.stmt(ir.If.then(e))) ok = false;
                if (ir.If.@"else"(e) != .nil and !try self.stmt(ir.If.@"else"(e))) ok = false;
                return ok;
            },
            .match => {
                var ok = try self.expr(ir.Match.subject(e));
                for (ir.Match.arms(e)) |arm| {
                    if (!try self.pattern(ir.Arm.pattern(arm))) ok = false;
                    if (ir.Arm.guard(arm) != .nil and !try self.expr(ir.Arm.guard(arm))) ok = false;
                    if (!try self.stmt(ir.Arm.body(arm))) ok = false;
                }
                return ok;
            },
            .block => return self.stmt(e),
            .@"break", .@"continue", .@"return", .panic, .set, .@"while", .@"for", .labeled, .pass => return self.stmt(e),
            .@"defer", .@"errdefer" => return self.reject(e, "defer", .{}, "it holds nothing to release", .{}),
            .raw_block => return self.reject(e, "use `raw`", .{}, "it runs only checked code", .{}),
            .lambda => return self.reject(e, "make a closure", .{}, plain_rule, .{}),
            .move, .read, .write, .clone, .share, .weak, .box => return self.reject(e, "use `{s}`", .{self.text(e)}, "its values are plain, and copied where they go, so nothing is lent, moved, or shared", .{}),
            .propagate, .propagate_none, .@"catch", .@"??" => return self.reject(e, "use `{s}`", .{self.text(e)}, "its values are never optional and nothing fails, so there is nothing to pass on or handle", .{}),
            .builtin => return self.reject(e, "use `{s}`", .{self.text(e)}, "it runs only the forms of a compile-time function", .{}),
            else => return self.reject(e, "use `{s}`", .{self.text(e)}, "it runs only the forms of a compile-time function", .{}),
        }
    }

    /// A match pattern a compile-time function compares with: a literal,
    /// a variant, a constant, a range, alternatives, `_`, or a name that
    /// binds the subject.
    fn pattern(self: *Pure, p: Sexp) Error!bool {
        if (p == .src) return true;
        switch (p.kind() orelse return true) {
            .enum_lit, .member, .range_pattern, .neg => return true,
            .alt_pattern => {
                var ok = true;
                for (ir.AltPattern.alts(p)) |a| if (!try self.pattern(a)) {
                    ok = false;
                };
                return ok;
            },
            else => return self.reject(p, "match `{s}`", .{self.text(p)}, "its patterns are literals, variants, constants, ranges, and `_`", .{}),
        }
    }

    /// Whether `node` names a type (`Mode` in `Mode.loose`).
    fn namesType(self: *Pure, node: Sexp) bool {
        if (node.isKind(.member)) return true;
        const id = self.ctx.symbolOf(node) orelse self.ctx.lookupInScopeOnly(sema.module_scope, identAt(self.ctx.source, node) orelse return false) orelse return false;
        return switch (self.ctx.symbols.items[id].kind) {
            .nominal_type, .type_alias => true,
            else => false,
        };
    }

    /// The function's header as a run-time function's,
    /// `cap[n: Int]() -> Int`.
    fn header(self: *Pure) Error![]const u8 {
        const src = self.ctx.source;
        const name = self.ctx.span(ir.Fun.name(self.def));
        var at: usize = name.end;
        var depth: u32 = 0;
        while (at < src.len) : (at += 1) {
            if (src[at] == '[') depth += 1;
            if (src[at] == ']') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        at = @min(at + 1, src.len);
        var end = at;
        while (end < src.len and src[end] != '\n' and src[end] != '#') end += 1;
        const rest = std.mem.trimEnd(u8, src[at..end], " \t\r");
        return self.ctx.arena.allocator().print("{s}(){s}", .{ src[name.start..at], rest });
    }
};

fn isStringLiteral(source: []const u8, e: Sexp) bool {
    if (e != .src) return false;
    const t = diag.textOf(source, rig.leafSpan(source, e));
    return t.len > 0 and (t[0] == '"' or t[0] == '\'');
}

/// `U8(x)`, `Int(x)`, `Byte(x)` of an alias: an integer conversion.
fn isIntConversion(ctx: *const SemContext, call: Sexp) bool {
    const args = ir.Call.args(call);
    if (args.len != 1 or args[0].isKind(.kwarg)) return false;
    const callee = ir.Call.callee(call);
    if (callee != .src) return false;
    const ty = ctx.typeOf(call) orelse return false;
    if (ctx.types.get(ty) != .int) return false;
    if (ctx.symbolOf(callee)) |id| return ctx.symbols.items[id].kind == .type_alias;
    return sema.intTypeNamed(identAt(ctx.source, callee) orelse return false) != null;
}

// =============================================================================
// Calls
// =============================================================================

/// The compile-time function a call names: its module's context, its
/// symbol there, and that module's id.
pub const Target = struct { ctx: *SemContext, sym: SymbolId, module_id: u32 };

/// The compile-time function the object of a bracket list `obj` names
/// (`cap`, `lib.cap`), as `names` sees names; null for anything else.
pub fn targetOf(ctx: *SemContext, obj: Sexp, names: anytype) ?Target {
    if (obj == .src) {
        const id = names.symbol(obj) orelse return null;
        if (!isCtFunction(ctx, id)) return null;
        return .{ .ctx = ctx, .sym = id, .module_id = ctx.module_id };
    }
    if (!obj.isKind(.member) or ir.Member.object(obj) != .src) return null;
    const module = names.symbol(ir.Member.object(obj)) orelse return null;
    if (ctx.symbols.items[module].kind != .module) return null;
    const module_id = ctx.module_refs.get(module) orelse return null;
    const foreign = ctx.foreign_semas.get(module_id) orelse return null;
    const fid = foreign.lookupInScopeOnly(sema.module_scope, identAt(ctx.source, ir.Member.name(obj)) orelse return null) orelse return null;
    if (!isCtFunction(foreign, fid) or !foreign.symbols.items[fid].flags.is_public) return null;
    return .{ .ctx = foreign, .sym = fid, .module_id = module_id };
}

/// The function type of `t`, once its signature is resolved; null when
/// it has none.
pub fn signatureOf(t: Target) Error!?sema.FunctionType {
    const f = t.ctx.ct.funs.get(t.sym) orelse return null;
    if (f.sig != .done) {
        if (!try resolve.ensureCtSig(t.ctx, t.sym)) return null;
    } else if (!f.sig_ok) return null;
    return switch (t.ctx.types.get(t.ctx.symbols.items[t.sym].ty)) {
        .function => |sig| if (sema.containsPoison(t.ctx, t.ctx.symbols.items[t.sym].ty)) null else sig,
        else => null,
    };
}

/// A compile-time call's value and its type in the module that calls.
pub const Called = struct { value: CtVal, ty: TypeId };

/// The result type of a call of `t` (of signature `f`) with `args`, in
/// the declaring module: its integer parameters replaced by their values.
fn resultIn(t: Target, f: sema.FunctionType, args: []const CtVal) Error!TypeId {
    var params: std.ArrayList(SymbolId) = .empty;
    var vals: std.ArrayList(TypeId) = .empty;
    const a = t.ctx.arena.allocator();
    for (f.ct_params, 0..) |pty, i| {
        if (t.ctx.types.get(pty) != .int or i >= f.ct_syms.len) continue;
        try params.append(a, f.ct_syms[i]);
        try vals.append(a, try sema.ctInt(t.ctx, args[i].int));
    }
    if (params.items.len == 0) return f.returns;
    return sema.substituteType(t.ctx, f.returns, .{ .params = params.items, .args = vals.items });
}

/// The memo key of a call of `sym` with `args`.
fn keyOf(a: std.mem.Allocator, prefix: []const Wide, args: []const CtVal) Error!Key {
    const k = try a.alloc(Wide, prefix.len + args.len);
    @memcpy(k[0..prefix.len], prefix);
    for (args, k[prefix.len..]) |v, *out| out.* = switch (v) {
        .int => |i| i,
        .boolean => |b| @intFromBool(b),
        .variant => |i| i,
        .array => unreachable,
    };
    return k;
}

/// The value of the compile-time call `call`, in `ctx`, of `t` with
/// `args`: computed once for the program and remembered, failures too.
/// Null after a diagnostic at the call, or when the function itself was
/// rejected (reported where it is declared).
pub fn callAt(ctx: *SemContext, call: Sexp, t: Target, args: []const CtVal) Error!?Called {
    if (t.ctx == ctx) {
        if (!try resolve.ensureCtFun(ctx, t.sym)) return null;
    } else if (t.ctx.ct.funs.get(t.sym)) |f| {
        if (!f.ok) return null;
    } else return null;
    const f = (try signatureOf(t)) orelse return null;
    const ty_there = try resultIn(t, f, args);
    const ty = if (t.ctx == ctx) ty_there else try sema.importType(ctx, t.ctx, ty_there, t.module_id);
    if (!try sema.checkArraysIn(ctx, ctx.startOf(call), ty)) return null;
    const key = try keyOf(t.ctx.arena.allocator(), &.{t.sym}, args);
    const outcome = if (t.ctx.ct.memo.get(key)) |o| o else blk: {
        var ev: Eval = .{ .ctx = t.ctx, .module_id = t.module_id, .gpa = ctx.allocator, .arena = .init(ctx.allocator) };
        defer ev.deinit();
        const o: Outcome = if (ev.call(t, args, call)) |v|
            .{ .value = try copyInto(t.ctx.arena.allocator(), v) }
        else |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CtFail => .{ .failed = try persist(t.ctx.arena.allocator(), ev.fail.?) },
            // A `break` or `continue` leaves only a loop of the body, and
            // the call takes a `return`.
            error.Jump => unreachable,
        };
        // A failure is remembered for the call asked for, whose limits
        // it ran under; a value for every call.
        try t.ctx.ct.memo.put(t.ctx.allocator, key, o);
        break :blk o;
    };
    switch (outcome) {
        .value => |v| return .{ .value = v, .ty = ty },
        .failed => |why| {
            try report(ctx, call, why);
            return null;
        },
    }
}

fn persist(a: std.mem.Allocator, f: Failure) Error!Failure {
    return .{ .what = try a.dupe(u8, f.what), .module = f.module, .pos = f.pos, .node = try a.dupe(u8, f.node), .frame = try a.dupe(u8, f.frame) };
}

/// Report failure `why` at `call`: the error there, and a note at the
/// node of the body that failed. A call reached again (a constant is
/// folded, then typed) reports nothing more while its error stands.
fn report(ctx: *SemContext, call: Sexp, why: Failure) Error!void {
    const msg = try ctx.arena.allocator().print("compile-time call `{s}` {s}", .{ diag.textOf(ctx.source, ctx.span(call)), why.what });
    const at = ctx.startOf(call);
    if (ctx.reported.get(.{ .pos = at, .message = std.hash.Wyhash.hash(0, msg) })) |i| {
        if (i < ctx.diagnostics.items.len and ctx.diagnostics.items[i].pos == at and std.mem.eql(u8, ctx.diagnostics.items[i].message, msg)) return;
    }
    try ctx.errAt(call, "{s}", .{msg});
    if (why.frame.len > 0) {
        try ctx.noteIn(why.module, why.pos, "in `{s}`, in `{s}`", .{ why.node, why.frame });
    } else try ctx.noteIn(why.module, why.pos, "in `{s}`", .{why.node});
}

/// The value of an argument for a parameter of type `ty` (of `ctx`), as
/// `names` knows constants: null when it is not known at compile time.
pub const Arg = union(enum) { value: CtVal, not_constant, failed, overflow };

pub fn argValue(ctx: *SemContext, arg: Sexp, ty: TypeId, names: anytype) Error!Arg {
    if (isCallNode(arg)) if (targetOf(ctx, objectOf(arg), names) != null) {
        const v = (try names.ctValue(arg)) orelse return .failed;
        return .{ .value = v };
    };
    switch (ctx.types.get(ty)) {
        .int => return switch (sema.ctFoldBy(ctx, arg, names)) {
            .value => |t| .{ .value = .{ .int = t.v } },
            .failed => .failed,
            .overflow => .overflow,
            .not_constant, .mismatch => .not_constant,
        },
        .bool => {
            if (sema.constBoolBy(ctx, arg, names)) |b| return .{ .value = .{ .boolean = b } };
            if (sema.patternConst(ctx, arg)) |c| if (sema.constScalar(c)) |s| if (s == .boolean) return .{ .value = .{ .boolean = s.boolean } };
            return .not_constant;
        },
        else => {
            const name: []const u8 = blk: {
                if (arg.isKind(.enum_lit)) break :blk identAt(ctx.source, ir.EnumLit.name(arg)) orelse return .not_constant;
                if (sema.patternConst(ctx, arg)) |c| if (sema.constScalar(c)) |s| if (s == .variant) break :blk s.variant;
                if (arg.isKind(.member)) break :blk identAt(ctx.source, ir.Member.name(arg)) orelse return .not_constant;
                return .not_constant;
            };
            const i = variantIndex(ctx, ty, name) orelse return .not_constant;
            return .{ .value = .{ .variant = i } };
        },
    }
}

/// The callee of a bracket list: `cap` of `cap[8]`.
fn objectOf(e: Sexp) Sexp {
    return if (e.isKind(.generic_inst)) ir.get(e, .name) else ir.get(e, .object);
}

fn isCallNode(e: Sexp) bool {
    return e.isKind(.index) or e.isKind(.inst) or e.isKind(.generic_inst);
}

/// The arguments of a bracket list as compile-time arguments, whatever
/// kind of node holds them.
fn argsOf(e: Sexp) []const Sexp {
    if (e.isKind(.generic_inst)) return rig.children(e)[1..];
    return sema.bracketArgs(e);
}

/// The index among the members of plain enum `ty` of its variant
/// `name`; null when it has none.
pub fn variantIndex(ctx: *const SemContext, ty: TypeId, name: []const u8) ?u32 {
    const decl = sema.nominalDecl(ctx, ty) orelse return null;
    const fields = decl.symbol().fields orelse return null;
    for (fields, 0..) |f, i| if (f.is_variant and std.mem.eql(u8, f.name, name)) return @intCast(i);
    return null;
}

/// The name of variant `i` of plain enum `ty`.
pub fn variantName(ctx: *const SemContext, ty: TypeId, i: u32) []const u8 {
    const decl = sema.nominalDecl(ctx, ty) orelse return "_";
    const fields = decl.symbol().fields orelse return "_";
    return if (i < fields.len) fields[i].name else "_";
}

/// The value of the compile-time call `e` (a bracket list, in a type, a
/// constant, or an enum value) of `ctx`, as `names` knows constants:
/// its arguments are values known where it is written. `not_call` when
/// `e` calls no compile-time function; `failed` after a diagnostic.
pub const Folded = union(enum) { not_call, failed, called: Called };

pub fn valueCall(ctx: *SemContext, e: Sexp, names: anytype) Error!Folded {
    const t = targetOf(ctx, objectOf(e), names) orelse return .not_call;
    const name = diag.textOf(ctx.source, ctx.span(objectOf(e)));
    const f = (try signatureOf(t)) orelse return .failed;
    const given = argsOf(e);
    if (given.len != f.ct_params.len) {
        try ctx.errAt(e, "`{s}` expects {d} compile-time argument{s}, got {d}", .{ name, f.ct_params.len, if (f.ct_params.len == 1) "" else "s", given.len });
        return .failed;
    }
    const vals = try ctx.arena.allocator().alloc(CtVal, given.len);
    var ok = true;
    for (given, f.ct_params, 0..) |g, pty_there, i| {
        const pty = if (t.ctx == ctx) pty_there else try sema.importType(ctx, t.ctx, pty_there, t.module_id);
        if (try paramArg(ctx, g, names)) |param| {
            try ctx.errAt(g, "compile-time argument {d} of `{s}` is the compile-time parameter `{s}`; a compile-time function is called with values known where the call is written", .{ i + 1, name, ctx.symbols.items[param].name });
            ok = false;
            continue;
        }
        switch (try argValue(ctx, g, pty, names)) {
            .value => |v| {
                if (!try fits(ctx, g, v, pty, i, name)) ok = false;
                vals[i] = v;
            },
            .failed => ok = false,
            .overflow => {
                try ctx.errAt(g, "compile-time argument {d} of `{s}` is too large to compute", .{ i + 1, name });
                ok = false;
            },
            .not_constant => {
                try ctx.errAt(g, "compile-time argument {d} of `{s}` must be known at compile time; pass a literal, an enum value, a module constant, a compile-time parameter, a `=!` binding of one, or arithmetic on them", .{ i + 1, name });
                ok = false;
            },
        }
    }
    if (!ok) return .failed;
    const called = (try callAt(ctx, e, t, vals)) orelse return .failed;
    return .{ .called = called };
}

/// The compile-time parameter of an enclosing generic function or type
/// that `arg` names, as `names` sees names; null for anything else.
fn paramArg(ctx: *SemContext, arg: Sexp, names: anytype) Error!?SymbolId {
    if (arg != .src) return null;
    const id = names.symbol(arg) orelse return null;
    if (ctx.ct_locals.contains(id)) return id;
    const sym = ctx.symbols.items[id];
    return if (sym.kind == .param and sym.flags.comptime_known) id else null;
}

/// Whether argument `i` of `name`, value `v`, fits its parameter's type
/// `ty`; reported when it does not.
pub fn fits(ctx: *SemContext, arg: Sexp, v: CtVal, ty: TypeId, i: usize, name: []const u8) Error!bool {
    if (v != .int or sema.intFits(ctx, ty, v.int)) return true;
    const shown = try sema.formatType(ctx, ty);
    try ctx.errAt(arg, "compile-time argument {d} of `{s}` is `{d}`, which {s} `{s}` cannot hold", .{ i + 1, name, v.int, resolve.an(shown), shown });
    return false;
}

/// `ctFoldBy`'s answer for a compile-time call where constants are
/// resolved (`resolve.ConstNames.ctCall`): its value, when an integer.
pub fn foldCall(ctx: *SemContext, e: Sexp, names: anytype) Error!sema.CtFold {
    return switch (try valueCall(ctx, e, names)) {
        .not_call => .not_constant,
        .failed => .failed,
        .called => |c| switch (c.value) {
            .int => |v| .{ .value = .{ .v = v, .int = switch (ctx.types.get(c.ty)) {
                .int => |i| i,
                else => null,
            } } },
            else => .not_constant,
        },
    };
}

/// Report that the compile-time call `node`, needed as `what` (an array
/// length, a compile-time argument), gives no integer; false when `node`
/// is no such call.
pub fn notInt(ctx: *SemContext, node: Sexp, what: []const u8) Error!bool {
    if (!isCallNode(node)) return false;
    const names: resolve.ConstNames = .{ .ctx = ctx, .scope = sema.module_scope, .eval = ctx };
    switch (try valueCall(ctx, node, names)) {
        .not_call => return false,
        .failed => return true,
        .called => |c| {
            const shown = try sema.formatType(ctx, c.ty);
            try ctx.errAt(node, "{s} is an integer; `{s}` gives {s} `{s}`", .{ what, diag.textOf(ctx.source, ctx.span(node)), resolve.an(shown), shown });
            return true;
        },
    }
}

/// `ctFoldBy`'s answer for a checked compile-time call
/// (`sema.CheckedNames.ctCall`): the value the checker recorded, when an
/// integer.
pub fn recordedInt(ctx: *const SemContext, e: Sexp) sema.CtFold {
    if (ctx.ct.results.items.len == 0) return .not_constant;
    const r = recorded(ctx, e) orelse return .not_constant;
    return switch (r.value) {
        .int => |v| .{ .value = .{ .v = v, .int = switch (ctx.types.get(r.ty)) {
            .int => |i| i,
            else => null,
        } } },
        else => .not_constant,
    };
}

/// The value the checker recorded for the compile-time call `e`.
pub fn recorded(ctx: *const SemContext, e: Sexp) ?Result {
    const inst = ctx.instanceOf(e) orelse return null;
    if (inst != .ct_call) return null;
    const i = inst.ct_call orelse return null;
    return ctx.ct.results.items[i];
}

/// Record the value of the checked call `e`: the hidden constant that
/// holds it, when it is an array read in a body (`hidden`), is decided
/// here, once per value.
pub fn recordCall(ctx: *SemContext, e: Sexp, t: Target, args: []const CtVal, c: Called, in_body: bool) Error!void {
    var hidden: ?u32 = null;
    if (in_body and c.value == .array) {
        const key = try keyOf(ctx.arena.allocator(), &.{ t.module_id, t.sym }, args);
        const gop = try ctx.ct.hidden_of.getOrPut(ctx.allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(ctx.ct.hidden.items.len);
            try ctx.ct.hidden.append(ctx.allocator, .{ .value = c.value, .ty = c.ty });
        }
        hidden = gop.value_ptr.*;
    }
    const i: u32 = @intCast(ctx.ct.results.items.len);
    try ctx.ct.results.append(ctx.allocator, .{ .value = c.value, .ty = c.ty, .hidden = hidden });
    try ctx.recordInstance(e, .{ .ct_call = i });
}

/// Write value `v` of type `ty` as `print` writes it: `7`, `true`,
/// `.loose`, `[1, 2]`.
pub fn writeValue(ctx: *const SemContext, w: *std.Io.Writer, v: CtVal, ty: TypeId) !void {
    switch (v) {
        .int => |i| try w.print("{d}", .{i}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .variant => |i| try w.print(".{s}", .{variantName(ctx, ty, i)}),
        .array => |elems| {
            const elem = switch (ctx.types.get(ty)) {
                .array => |a| a.elem,
                else => ty,
            };
            try w.writeAll("[");
            for (elems, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                try writeValue(ctx, w, e, elem);
            }
            try w.writeAll("]");
        },
    }
}

fn copyInto(a: std.mem.Allocator, v: CtVal) Error!CtVal {
    return switch (v) {
        .array => |elems| blk: {
            const out = try a.alloc(CtVal, elems.len);
            for (elems, out) |e, *o| o.* = try copyInto(a, e);
            break :blk .{ .array = out };
        },
        else => v,
    };
}

// =============================================================================
// The evaluator
// =============================================================================

const EvalError = error{ OutOfMemory, CtFail, Jump };

/// A transfer of control in flight (`error.Jump`): a `break` or a
/// `continue` of the loop `target`, or a `return`.
const Jump = union(enum) {
    none,
    brk: struct { target: parser.NodeId, value: ?CtVal },
    cont: parser.NodeId,
    ret: CtVal,
};

const Env = std.AutoHashMapUnmanaged(SymbolId, CtVal);

/// One call being run: its function, its arguments, and its locals.
const Frame = struct { t: Target, args: []const CtVal };

/// A tree-walking interpreter over the checked IR of a compile-time
/// function's body. Each node's type is the checker's (`typeOf`), so a
/// literal has the type its context gave it.
pub const Eval = struct {
    /// The module of the code being run; a call into another module's
    /// function runs in its context.
    ctx: *SemContext,
    module_id: u32,
    gpa: std.mem.Allocator,
    /// The values made, freed when the evaluation ends.
    arena: std.heap.ArenaAllocator,
    steps: u64 = 0,
    depth: u32 = 0,
    bytes: u64 = 0,
    env: ?*Env = null,
    frames: std.ArrayList(Frame) = .empty,
    jump: Jump = .none,
    fail: ?Failure = null,
    /// The innermost loop running, where a run out of steps is reported.
    loop: Sexp = .nil,

    fn deinit(self: *Eval) void {
        self.frames.deinit(self.gpa);
        self.arena.deinit();
    }

    fn a(self: *Eval) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn text(self: *Eval, node: Sexp) []const u8 {
        return diag.textOf(self.ctx.source, self.ctx.span(node));
    }

    /// Stop the evaluation at `node`: the call `{what}`.
    fn failAt(self: *Eval, node: Sexp, comptime what: []const u8, args: anytype) EvalError {
        const msg = try self.a().print(what, args);
        var frame: []const u8 = "";
        if (self.frames.items.len > 1) frame = try self.frameText(self.frames.items[self.frames.items.len - 1]);
        // A node over several lines is shown by its first.
        const shown = self.text(node);
        const line = shown[0 .. std.mem.findScalar(u8, shown, '\n') orelse shown.len];
        self.fail = .{ .what = msg, .module = self.module_id, .pos = self.ctx.startOf(node), .node = line, .frame = frame };
        return error.CtFail;
    }

    /// `fib[93]`: a call with its arguments' values.
    fn frameText(self: *Eval, f: Frame) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.a());
        const w = &out.writer;
        const fn_ty = f.t.ctx.types.get(f.t.ctx.symbols.items[f.t.sym].ty).function;
        w.print("{s}[", .{f.t.ctx.symbols.items[f.t.sym].name}) catch return error.OutOfMemory;
        for (f.args, 0..) |v, i| {
            if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
            writeValue(f.t.ctx, w, v, fn_ty.ct_params[i]) catch return error.OutOfMemory;
        }
        w.writeAll("]") catch return error.OutOfMemory;
        return out.written();
    }

    fn step(self: *Eval, node: Sexp, n: u64) EvalError!void {
        self.steps += n;
        if (self.steps > max_steps) return self.failAt(if (self.loop != .nil) self.loop else node, "takes more than {d} steps", .{max_steps});
    }

    fn alloc(self: *Eval, node: Sexp, n: usize) EvalError![]CtVal {
        self.bytes += @as(u64, n) * @sizeOf(CtVal);
        if (self.bytes > max_bytes) return self.failAt(node, "makes more than {d} MiB of values", .{max_bytes >> 20});
        try self.step(node, n);
        return self.a().alloc(CtVal, n);
    }

    /// A copy of `v` the evaluation may change.
    fn copy(self: *Eval, node: Sexp, v: CtVal) EvalError!CtVal {
        return switch (v) {
            .array => |elems| blk: {
                const out = try self.alloc(node, elems.len);
                for (elems, out) |e, *o| o.* = try self.copy(node, e);
                break :blk .{ .array = out };
            },
            else => v,
        };
    }

    /// Run function `t` with `args`, from the call `at`.
    fn call(self: *Eval, t: Target, args: []const CtVal, at: Sexp) EvalError!CtVal {
        if (self.depth >= max_depth) return self.failAt(at, "nests more than {d} compile-time calls", .{max_depth});
        try self.step(at, 1);
        const key = try keyOf(self.a(), &.{t.sym}, args);
        if (t.ctx.ct.memo.get(key)) |o| switch (o) {
            .value => |v| return self.copy(at, v),
            .failed => {},
        };
        if (!try resolve.ensureCtFun(t.ctx, t.sym)) return self.failAt(at, "calls `{s}`, which was rejected", .{t.ctx.symbols.items[t.sym].name});
        const def = rig.unpub(t.ctx.ct.funs.get(t.sym).?.decl);
        const fn_ty = t.ctx.types.get(t.ctx.symbols.items[t.sym].ty).function;

        var env: Env = .empty;
        defer env.deinit(self.gpa);
        for (fn_ty.ct_syms, args) |sym, v| try env.put(self.gpa, sym, v);
        const saved_env = self.env;
        const saved_ctx = self.ctx;
        const saved_module = self.module_id;
        const saved_loop = self.loop;
        self.env = &env;
        self.ctx = t.ctx;
        self.module_id = t.module_id;
        self.loop = .nil;
        self.depth += 1;
        try self.frames.append(self.gpa, .{ .t = t, .args = args });
        defer {
            self.env = saved_env;
            self.ctx = saved_ctx;
            self.module_id = saved_module;
            self.loop = saved_loop;
            self.depth -= 1;
            _ = self.frames.pop();
        }
        const v = self.blockValue(ir.Fun.body(def)) catch |e| switch (e) {
            error.Jump => switch (self.jump) {
                .ret => |r| blk: {
                    self.jump = .none;
                    break :blk r;
                },
                else => return e,
            },
            else => return e,
        };
        // A value for the memo, which outlives this evaluation.
        try t.ctx.ct.memo.put(t.ctx.allocator, try keyOf(t.ctx.arena.allocator(), &.{t.sym}, args), .{ .value = try copyInto(t.ctx.arena.allocator(), v) });
        return v;
    }

    /// The value of a block or statement whose last line gives one.
    fn blockValue(self: *Eval, body: Sexp) EvalError!CtVal {
        if (!body.isKind(.block)) return self.value(body);
        const list = ir.Block.stmts(body);
        if (list.len == 0) return .{ .int = 0 };
        for (list[0 .. list.len - 1]) |s| try self.exec(s);
        const last = list[list.len - 1];
        if (yieldsValue(self.ctx, last)) return self.value(last);
        try self.exec(last);
        return .{ .int = 0 };
    }

    fn exec(self: *Eval, s: Sexp) EvalError!void {
        const h = s.kind() orelse {
            _ = try self.value(s);
            return;
        };
        try self.step(s, 1);
        switch (h) {
            .block => for (ir.Block.stmts(s)) |x| try self.exec(x),
            .set => try self.assign(s),
            .@"while" => _ = try self.loopWhile(s),
            .@"for" => _ = try self.loopFor(s),
            .labeled => try self.exec(ir.Labeled.stmt(s)),
            .@"break" => {
                const dest = self.ctx.jumpDestOf(s) orelse return self.failAt(s, "breaks out of nothing it runs", .{});
                const v = if (ir.Break.value(s) != .nil) try self.value(ir.Break.value(s)) else null;
                self.jump = .{ .brk = .{ .target = dest.target.list.id, .value = v } };
                return error.Jump;
            },
            .@"continue" => {
                const dest = self.ctx.jumpDestOf(s) orelse return self.failAt(s, "continues nothing it runs", .{});
                self.jump = .{ .cont = dest.target.list.id };
                return error.Jump;
            },
            .@"return" => {
                const v = if (ir.get(s, .value) != .nil) try self.value(ir.get(s, .value)) else CtVal{ .int = 0 };
                self.jump = .{ .ret = v };
                return error.Jump;
            },
            .pass => {},
            .panic => return self.panicAt(s),
            .@"if" => {
                const c = try self.boolean(ir.If.cond(s));
                if (c) {
                    try self.exec(ir.If.then(s));
                } else if (ir.If.@"else"(s) != .nil) try self.exec(ir.If.@"else"(s));
            },
            .match => _ = try self.match(s, false),
            else => _ = try self.value(s),
        }
    }

    fn panicAt(self: *Eval, s: Sexp) EvalError {
        var out: std.Io.Writer.Allocating = .init(self.a());
        const w = &out.writer;
        for (ir.Panic.args(s), 0..) |arg, i| {
            if (i > 0) w.writeAll(" ") catch return error.OutOfMemory;
            if (isStringLiteral(self.ctx.source, arg)) {
                writeStringLiteral(w, self.text(arg)) catch return error.OutOfMemory;
                continue;
            }
            const v = try self.value(arg);
            writeValue(self.ctx, w, v, self.ctx.typeOf(arg) orelse self.ctx.types.int_id) catch return error.OutOfMemory;
        }
        return self.failAt(s, "panics: {s}", .{out.written()});
    }

    /// `x = v`, `x op= v`, `t[i] = v`, `t[i] op= v`.
    fn assign(self: *Eval, s: Sexp) EvalError!void {
        const target = ir.Set.target(s);
        const op = rig.bindingKindOf(ir.Set.op(s)).operator();
        const rhs = ir.Set.value(s);
        const slot = try self.slotOf(target);
        var v = try self.value(rhs);
        if (op) |o| {
            v = .{ .int = try self.arith(s, o, slot.*.int, v.int, self.intOf(target)) };
        } else if (isPlace(rhs)) v = try self.copy(s, v);
        slot.* = v;
    }

    /// The slot an assignment's target names: a local's, or an element's
    /// of a local array.
    fn slotOf(self: *Eval, target: Sexp) EvalError!*CtVal {
        if (target == .src) {
            const sym = self.ctx.symbolOf(target) orelse return self.failAt(target, "assigns what it cannot name", .{});
            const gop = try self.env.?.getOrPut(self.gpa, sym);
            if (!gop.found_existing) gop.value_ptr.* = .{ .int = 0 };
            return gop.value_ptr;
        }
        const obj = try self.slotOf(ir.get(target, .object));
        const i = try self.int(ir.Index.index(target));
        const elems = obj.array;
        if (i < 0 or i >= elems.len) return self.failAt(target, "indexes {d} in an array of length {d}", .{ i, elems.len });
        return &elems[@intCast(i)];
    }

    /// `while c : step` with its `else`: the loop's value, when a `break`
    /// gives one.
    fn loopWhile(self: *Eval, s: Sexp) EvalError!?CtVal {
        const id = s.list.id;
        const saved = self.loop;
        defer self.loop = saved;
        self.loop = s;
        while (true) {
            try self.step(s, 1);
            if (!try self.boolean(ir.While.cond(s))) break;
            self.exec(ir.While.body(s)) catch |e| switch (try self.caught(e, id)) {
                .brk => |v| return v,
                .cont => {},
            };
            if (ir.While.step(s) != .nil) try self.exec(ir.While.step(s));
        }
        if (ir.While.@"else"(s) != .nil) try self.exec(ir.While.@"else"(s));
        return null;
    }

    const Caught = union(enum) { brk: ?CtVal, cont };

    /// What error `e` from a loop's body means to loop `id`: a jump that
    /// leaves or continues it; any other passes on.
    fn caught(self: *Eval, e: EvalError, id: parser.NodeId) EvalError!Caught {
        if (e != error.Jump) return e;
        switch (self.jump) {
            .brk => |b| if (b.target == id) {
                self.jump = .none;
                return .{ .brk = b.value };
            },
            .cont => |c| if (c == id) {
                self.jump = .none;
                return .cont;
            },
            else => {},
        }
        return e;
    }

    /// `for x in a..b`, `for x in t`, `for x, i in t`, with its `else`.
    fn loopFor(self: *Eval, s: Sexp) EvalError!?CtVal {
        const id = s.list.id;
        const saved = self.loop;
        defer self.loop = saved;
        self.loop = s;
        const source = ir.For.source(s);
        const var_sym = if (ir.For.@"var"(s) == .src) self.ctx.symbolOf(ir.For.@"var"(s)) else null;
        const index_sym = if (ir.For.index(s) == .src) self.ctx.symbolOf(ir.For.index(s)) else null;
        if (source.isKind(.@"..")) {
            const lo = try self.int(ir.get(source, .left));
            var hi = try self.int(ir.get(source, .right));
            if (ir.get(source, .inclusive) != .nil) hi += 1;
            var i = lo;
            while (i < hi) : (i += 1) {
                try self.step(s, 1);
                if (var_sym) |v| try self.env.?.put(self.gpa, v, .{ .int = i });
                self.exec(ir.For.body(s)) catch |e| switch (try self.caught(e, id)) {
                    .brk => |v| return v,
                    .cont => {},
                };
            }
        } else {
            const arr = (try self.value(source)).array;
            for (arr, 0..) |elem, i| {
                try self.step(s, 1);
                if (var_sym) |v| try self.env.?.put(self.gpa, v, try self.copy(s, elem));
                if (index_sym) |v| try self.env.?.put(self.gpa, v, .{ .int = @intCast(i) });
                self.exec(ir.For.body(s)) catch |e| switch (try self.caught(e, id)) {
                    .brk => |v| return v,
                    .cont => {},
                };
            }
        }
        if (ir.For.@"else"(s) != .nil) try self.exec(ir.For.@"else"(s));
        return null;
    }

    /// A `match`: the value of the arm whose pattern meets the subject;
    /// when `want` and none does, a failure.
    fn match(self: *Eval, m: Sexp, want: bool) EvalError!?CtVal {
        const subject = try self.value(ir.Match.subject(m));
        const subject_ty = self.ctx.typeOf(ir.Match.subject(m)) orelse self.ctx.types.int_id;
        for (ir.Match.arms(m)) |arm| {
            try self.step(arm, 1);
            if (!try self.meets(ir.Arm.pattern(arm), subject, subject_ty)) continue;
            if (ir.Arm.guard(arm) != .nil and !try self.boolean(ir.Arm.guard(arm))) continue;
            const body = ir.Arm.body(arm);
            if (want) return try self.blockValue(body);
            try self.exec(body);
            return null;
        }
        if (want) return self.failAt(m, "matches no arm", .{});
        return null;
    }

    /// Whether pattern `p` meets `v`, a value of type `ty`; a pattern
    /// that binds a name binds it.
    fn meets(self: *Eval, p: Sexp, v: CtVal, ty: TypeId) EvalError!bool {
        if (p == .src) {
            const word = identAt(self.ctx.source, p) orelse "";
            if (std.mem.eql(u8, word, "_")) return true;
            if (sema.isIntLiteralText(word)) return v.int == (std.fmt.parseInt(Wide, word, 0) catch return false);
            if (std.mem.eql(u8, word, "true")) return v.boolean;
            if (std.mem.eql(u8, word, "false")) return !v.boolean;
            if (sema.patternConst(self.ctx, p)) |c| return eqlVal(v, try self.scalar(p, c, ty));
            const sym = self.ctx.symbolOf(p) orelse return true;
            try self.env.?.put(self.gpa, sym, v);
            return true;
        }
        switch (p.kind() orelse return false) {
            .enum_lit => return v.variant == (variantIndex(self.ctx, ty, identAt(self.ctx.source, ir.EnumLit.name(p)) orelse "") orelse return false),
            .member => {
                if (sema.patternConst(self.ctx, p)) |c| return eqlVal(v, try self.scalar(p, c, ty));
                if (sema.intLimit(self.ctx, p)) |t| return v.int == t.v;
                return v.variant == (variantIndex(self.ctx, ty, identAt(self.ctx.source, ir.Member.name(p)) orelse "") orelse return false);
            },
            .neg => return v.int == try self.int(p),
            .range_pattern => {
                const lo = try self.int(ir.RangePattern.lo(p));
                const hi = try self.int(ir.RangePattern.hi(p));
                return v.int >= lo and (if (ir.RangePattern.inclusive(p) != .nil) v.int <= hi else v.int < hi);
            },
            .alt_pattern => {
                for (ir.AltPattern.alts(p)) |alt| if (try self.meets(alt, v, ty)) return true;
                return false;
            },
            else => return false,
        }
    }

    /// The value of a module constant `c` that `node` names, of type `ty`.
    fn scalar(self: *Eval, node: Sexp, c: sema.PatternConst, ty: TypeId) EvalError!CtVal {
        const s = sema.constScalar(c) orelse return self.failAt(node, "reads `{s}`, whose value Rig does not know", .{self.text(node)});
        return switch (s) {
            .int => |i| .{ .int = i },
            .boolean => |b| .{ .boolean = b },
            .variant => |name| .{ .variant = variantIndex(self.ctx, ty, name) orelse return self.failAt(node, "reads `{s}`, whose value Rig does not know", .{self.text(node)}) },
        };
    }

    fn boolean(self: *Eval, e: Sexp) EvalError!bool {
        return (try self.value(e)).boolean;
    }

    fn int(self: *Eval, e: Sexp) EvalError!Wide {
        return (try self.value(e)).int;
    }

    /// The integer type the checker gave `e`.
    fn intOf(self: *Eval, e: Sexp) IntInfo {
        const ty = self.ctx.typeOf(e) orelse return .{};
        return switch (self.ctx.types.get(ty)) {
            .int => |i| i,
            else => .{},
        };
    }

    fn arith(self: *Eval, node: Sexp, op: Tag, x: Wide, y: Wide, info: IntInfo) EvalError!Wide {
        return switch (sema.ctArith(op, x, y, info)) {
            .value => |v| v,
            .overflow => {
                const r = sema.intRange(info);
                return self.failAt(node, "overflows `{s}` ({d}..{d})", .{ try sema.formatType(self.ctx, try self.ctx.intern(.{ .int = info })), r.min, r.max });
            },
            .div_zero => self.failAt(node, "divides by zero", .{}),
            .shift_range => self.failAt(node, "shifts by {d}, outside 0..{d}", .{ y, info.width() - 1 }),
        };
    }

    /// The value of expression `e`.
    fn value(self: *Eval, e: Sexp) EvalError!CtVal {
        try self.step(e, 1);
        if (e == .src) return self.leaf(e);
        const h = e.kind() orelse return self.failAt(e, "has no value", .{});
        switch (h) {
            .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>", .@"&", .@"|", .@"^" => {
                const x = try self.int(ir.get(e, .left));
                const y = try self.int(ir.get(e, .right));
                // A shift is in its left operand's type.
                const info = if (h == .@"<<" or h == .@"<<%" or h == .@">>") self.intOf(ir.get(e, .left)) else self.intOf(e);
                return .{ .int = try self.arith(e, h, x, y, info) };
            },
            .neg => {
                const x = try self.int(ir.Neg.operand(e));
                return .{ .int = try self.arith(e, .@"-", 0, x, self.intOf(e)) };
            },
            .not => return .{ .boolean = !try self.boolean(ir.Not.operand(e)) },
            .@"and" => return .{ .boolean = (try self.boolean(ir.And.left(e))) and (try self.boolean(ir.And.right(e))) },
            .@"or" => return .{ .boolean = (try self.boolean(ir.Or.left(e))) or (try self.boolean(ir.Or.right(e))) },
            .@"==", .@"!=" => {
                const eq = eqlVal(try self.value(ir.get(e, .left)), try self.value(ir.get(e, .right)));
                return .{ .boolean = if (h == .@"==") eq else !eq };
            },
            .@"<", .@">", .@"<=", .@">=" => {
                const x = try self.int(ir.get(e, .left));
                const y = try self.int(ir.get(e, .right));
                return .{ .boolean = switch (h) {
                    .@"<" => x < y,
                    .@">" => x > y,
                    .@"<=" => x <= y,
                    else => x >= y,
                } };
            },
            .enum_lit => {
                const ty = self.ctx.typeOf(e) orelse return self.failAt(e, "has no type", .{});
                return .{ .variant = variantIndex(self.ctx, ty, identAt(self.ctx.source, ir.EnumLit.name(e)) orelse "") orelse return self.failAt(e, "names no variant", .{}) };
            },
            .member => return self.member(e),
            .index, .inst => {
                if (self.ctx.instanceOf(e)) |inst| if (inst == .ct_call) return self.ctCall(e);
                if (h == .inst) return self.failAt(e, "cannot run at compile time", .{});
                const arr = (try self.value(ir.get(e, .object))).array;
                const i = try self.int(ir.Index.index(e));
                if (i < 0 or i >= arr.len) return self.failAt(e, "indexes {d} in an array of length {d}", .{ i, arr.len });
                return arr[@intCast(i)];
            },
            .call => {
                // `U8(x)`: a conversion, which must keep the value.
                const x = try self.int(ir.Call.args(e)[0]);
                const info = self.intOf(e);
                if (!sema.intInfoFits(info, x)) {
                    const r = sema.intRange(info);
                    return self.failAt(e, "converts {d} to `{s}`, which holds {d}..{d}", .{ x, try sema.formatType(self.ctx, try self.ctx.intern(.{ .int = info })), r.min, r.max });
                }
                return .{ .int = x };
            },
            .array => {
                const elems = ir.Array.elems(e);
                const out = try self.alloc(e, elems.len);
                for (elems, out) |x, *o| {
                    const v = try self.value(x);
                    o.* = if (isPlace(x)) try self.copy(x, v) else v;
                }
                return .{ .array = out };
            },
            .array_fill => {
                const n = try self.int(ir.ArrayFill.size(e));
                if (n < 0 or n > sema.max_array_len) return self.failAt(e, "makes an array of length {d}: an array length runs from 0 to {d}", .{ n, sema.max_array_len });
                const v = try self.value(ir.ArrayFill.value(e));
                const out = try self.alloc(e, @intCast(n));
                for (out) |*o| o.* = try self.copy(e, v);
                return .{ .array = out };
            },
            .@"if" => {
                const c = try self.boolean(ir.If.cond(e));
                return self.blockValue(if (c) ir.If.then(e) else ir.If.@"else"(e));
            },
            .match => return (try self.match(e, true)).?,
            .block => return self.blockValue(e),
            .labeled => {
                const inner = ir.Labeled.stmt(e);
                return self.value(inner);
            },
            .@"while" => return (try self.loopWhile(e)) orelse self.failAt(e, "ends without a value", .{}),
            .@"for" => return (try self.loopFor(e)) orelse self.failAt(e, "ends without a value", .{}),
            .@"return", .@"break", .@"continue", .panic => {
                try self.exec(e);
                unreachable;
            },
            else => return self.failAt(e, "cannot run at compile time", .{}),
        }
    }

    fn leaf(self: *Eval, e: Sexp) EvalError!CtVal {
        const word = identAt(self.ctx.source, e) orelse "";
        if (sema.isIntLiteralText(word)) return .{ .int = std.fmt.parseInt(Wide, word, 0) catch return self.failAt(e, "is too large to compute", .{}) };
        if (std.mem.eql(u8, word, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, word, "false")) return .{ .boolean = false };
        const sym = self.ctx.symbolOf(e) orelse return self.failAt(e, "reads what it cannot name", .{});
        if (self.env.?.get(sym)) |v| return v;
        if (self.ctx.const_ints.get(sym)) |c| return .{ .int = c.value };
        if (sema.patternConst(self.ctx, e)) |c| return self.scalar(e, c, self.ctx.typeOf(e) orelse self.ctx.types.int_id);
        return self.failAt(e, "reads `{s}` before it has a value", .{word});
    }

    fn member(self: *Eval, e: Sexp) EvalError!CtVal {
        const obj = ir.Member.object(e);
        const name = identAt(self.ctx.source, ir.Member.name(e)) orelse "";
        if (std.mem.eql(u8, name, "len")) if (self.ctx.typeOf(obj)) |ot| if (self.ctx.types.get(ot) == .array) {
            return .{ .int = @intCast((try self.value(obj)).array.len) };
        };
        if (sema.intLimit(self.ctx, e)) |t| return .{ .int = t.v };
        const ty = self.ctx.typeOf(e) orelse self.ctx.types.int_id;
        if (sema.patternConst(self.ctx, e)) |c| return self.scalar(e, c, ty);
        return .{ .variant = variantIndex(self.ctx, ty, name) orelse return self.failAt(e, "reads `{s}`, whose value Rig does not know", .{self.text(e)}) };
    }

    /// A compile-time call in a body: its arguments' values, then the
    /// call, each argument checked against its parameter's type.
    fn ctCall(self: *Eval, e: Sexp) EvalError!CtVal {
        const names = BodyNames{ .ctx = self.ctx };
        const t = targetOf(self.ctx, ir.get(e, .object), names) orelse return self.failAt(e, "calls no compile-time function", .{});
        const fn_ty = t.ctx.types.get(t.ctx.symbols.items[t.sym].ty).function;
        const given = sema.bracketArgs(e);
        const args = try self.a().alloc(CtVal, given.len);
        for (given, args, 0..) |g, *out, i| {
            const v = try self.value(g);
            if (v == .int) {
                const pty = fn_ty.ct_params[i];
                const info = switch (t.ctx.types.get(pty)) {
                    .int => |info| info,
                    else => IntInfo{},
                };
                if (!sema.intInfoFits(info, v.int)) {
                    const r = sema.intRange(info);
                    return self.failAt(g, "passes {d} to `{s}`, which holds {d}..{d}", .{ v.int, t.ctx.symbols.items[fn_ty.ct_syms[i]].name, r.min, r.max });
                }
            }
            out.* = v;
        }
        return self.call(t, args, e);
    }
};

/// What a body's names are, from the facts its check recorded.
const BodyNames = struct {
    ctx: *const SemContext,

    pub fn symbol(self: BodyNames, e: Sexp) ?SymbolId {
        return self.ctx.symbolOf(e) orelse self.ctx.lookupInScopeOnly(sema.module_scope, identAt(self.ctx.source, e) orelse return null);
    }
};

/// Whether `e` reads a value where it is (a name, an element, a call's
/// remembered value), so storing it copies it.
fn isPlace(e: Sexp) bool {
    return e == .src or e.isKind(.index) or e.isKind(.inst) or e.isKind(.member);
}

fn eqlVal(x: CtVal, y: CtVal) bool {
    return switch (x) {
        .int => |i| y == .int and y.int == i,
        .boolean => |b| y == .boolean and y.boolean == b,
        .variant => |i| y == .variant and y.variant == i,
        .array => |xs| y == .array and xs.len == y.array.len and for (xs, y.array) |p, q| {
            if (!eqlVal(p, q)) break false;
        } else true,
    };
}

/// Whether statement `s`, last in a body, gives the body's value.
fn yieldsValue(ctx: *const SemContext, s: Sexp) bool {
    const h = s.kind() orelse return true;
    return switch (h) {
        .set, .@"return", .@"break", .@"continue", .pass, .panic, .@"while", .@"for", .labeled => false,
        .@"if" => ir.If.@"else"(s) != .nil and ctx.typeOf(s) != null,
        .match => ctx.typeOf(s) != null,
        else => true,
    };
}

/// A string literal's text as `panic` writes it: without its quotes,
/// its escapes read.
fn writeStringLiteral(w: *std.Io.Writer, lit: []const u8) !void {
    if (lit.len < 2) return w.writeAll(lit);
    const body = lit[1 .. lit.len - 1];
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '\\' or i + 1 == body.len) {
            try w.writeByte(body[i]);
            continue;
        }
        i += 1;
        try w.writeByte(switch (body[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0' => 0,
            else => body[i],
        });
    }
}
