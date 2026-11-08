//! Rig language module for the Nexus-generated parser (src/parser.zig).
//!
//! The generated parser has two stages, each wrapped here and auto-wired
//! in by Nexus through `@hasDecl`:
//!
//!   stage   generated (parser.zig)   wrapper (this file)
//!   lex     BaseLexer                Lexer   — layout, keywords, position
//!   parse   BaseParser               Parser  — post-parse IR rewrites,
//!                                              diagnostics
//!
//! so `parser.Parser.init(allocator, source).parseProgram()` returns the
//! semantic IR described in docs/internals/INTERNALS.md.
//!
//! Also here: `Tag` (re-exported from the generated parser), IR helpers
//! over the generated accessors, `BindingKind`, and the identifier
//! escaping that emit needs (`writeZigIdent`).

const std = @import("std");
const parser = @import("parser.zig");
const diag = @import("diag.zig");
const ir = parser.ir;
const BaseLexer = parser.BaseLexer;
const BaseParser = parser.BaseParser;
const Token = parser.Token;
const TokenCat = parser.TokenCat;
const Sexp = parser.Sexp;

// =============================================================================
// Tag and IR helpers
// =============================================================================

/// Every node kind and marker tag of the IR, generated from the `@schema`
/// in rig.grammar (which also gives each kind's roles).
pub const Tag = parser.Tag;

/// The declared return type of a `fun`; `_` for a `sub`, which has none.
pub fn returnType(fun_or_sub: Sexp) Sexp {
    return if (fun_or_sub.isKind(.fun)) ir.Fun.returns(fun_or_sub) else .nil;
}

/// A compile-time function: a `fun` with compile-time parameters and no
/// run-time parameter list, `fun cap[n: Int] -> Int`, which the checker
/// runs and the program never does. The Parser wrapper lets this form
/// stand only at module level (`ctFunShape`), so the IR decides it: the
/// one classifier every pass reads.
pub fn isCtFun(decl: Sexp) bool {
    const def = unpub(decl);
    return def.isKind(.fun) and ir.Fun.params(def) == .nil and ir.Fun.tparams(def) != .nil;
}

/// A declaration without its `pub`.
pub fn unpub(decl: Sexp) Sexp {
    return if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
}

/// Whether the function body `body` ends in a panic on every path: its
/// last statement panics, or is an `if` with an `else` or a `match`
/// each of whose branches does, and nothing in it returns or passes a
/// failure or a `none` on first.
pub fn alwaysPanics(body: Sexp) bool {
    if (holdsExit(body)) return false;
    return endsInPanic(body);
}

fn endsInPanic(s: Sexp) bool {
    const h = s.kind() orelse return false;
    return switch (h) {
        .panic => true,
        .block => blk: {
            const items = ir.Block.stmts(s);
            break :blk items.len > 0 and endsInPanic(items[items.len - 1]);
        },
        .@"if" => ir.If.@"else"(s) != .nil and endsInPanic(ir.If.then(s)) and endsInPanic(ir.If.@"else"(s)),
        .match => for (ir.Match.arms(s)) |arm| {
            if (!endsInPanic(ir.Arm.body(arm))) break false;
        } else ir.Match.arms(s).len > 0,
        else => false,
    };
}

/// Whether `e` holds a `return`, or a `!` or `?` that passes a failure
/// or a `none` on, outside the closures in it.
fn holdsExit(e: Sexp) bool {
    if (e != .list) return false;
    if (e.kind()) |h| switch (h) {
        .lambda => return false,
        .@"return", .propagate, .propagate_none => return true,
        else => {},
    };
    for (e.items()) |c| if (holdsExit(c)) return true;
    return false;
}

/// A fallible `sub`: `sub save(p: Page)!`.
/// The error set a `sub`'s or a `sub` type's `!` names (`sub f()!E`),
/// or nil for a bare `!`, which fails with any error.
pub fn failSet(fails: Sexp) Sexp {
    return if (fails == .tag) .nil else fails;
}

pub fn subFails(fun_or_sub: Sexp) bool {
    return fun_or_sub.isKind(.sub) and ir.Sub.fails(fun_or_sub) != .nil;
}

/// A function's marker, which asks for a speed and never changes what
/// the program means: `inline fun` (inline it at every call), `called
/// fun` (every call stays a call), a body whose first line is `rarely`
/// (it is rarely called), or none (`inlining.decide` decides). The header
/// says how calls compile and wins over the body's `rarely`.
pub const Marker = enum { none, @"inline", called, rarely };

pub fn markerOf(fun_or_sub: Sexp) Marker {
    const m = ir.get(fun_or_sub, .mark);
    if (m == .nil) return if (startsRarely(ir.get(fun_or_sub, .body))) .rarely else .none;
    return switch (m.kind().?) {
        .@"inline" => .@"inline",
        .called => .called,
        else => unreachable,
    };
}

/// Where the marker of a `fun` or `sub` is written: its header's word,
/// or the `rarely` that starts its body.
pub fn markNode(fun_or_sub: Sexp) Sexp {
    const m = ir.get(fun_or_sub, .mark);
    if (m != .nil) return m;
    const body = ir.get(fun_or_sub, .body);
    return if (startsRarely(body)) ir.Block.stmts(body)[0] else fun_or_sub;
}

/// The `rarely` that starts the body of the `fun` or `sub`, or nil. It
/// makes the function cold, whatever its header's marker; a `rarely`
/// that starts a branch, a `catch` handler, or a loop's body makes it
/// unlikely.
pub fn funRarely(fun_or_sub: Sexp) Sexp {
    const body = ir.get(fun_or_sub, .body);
    return if (startsRarely(body)) ir.Block.stmts(body)[0] else .nil;
}

/// Whether `body`, a block, starts with `rarely`: it rarely runs.
pub fn startsRarely(body: Sexp) bool {
    if (!body.isKind(.block)) return false;
    const stmts = ir.Block.stmts(body);
    return stmts.len > 0 and stmts[0].isKind(.rarely);
}

/// A module-level constant (`name = value`, or a `pub` one). Passes take
/// them before the other declarations, so functions anywhere in the
/// module see them.
pub fn isModuleConst(decl: Sexp) bool {
    return (if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl).isKind(.set);
}

/// An `if` or `while` condition that binds: `a as x`, or parts joined by
/// `and`, one of them `a as x`. `as` binds tighter than `and`, so
/// `a as x and x > 0 and b as y` is
/// `(and (and (as a x) (> x 0)) (as b y))`: its parts are the leaves of
/// the left spine, checked in order, each binding visible to the parts
/// after it and to the body.
pub fn bindsInCondition(cond: Sexp) bool {
    if (isAsPart(cond)) return true;
    if (!cond.isKind(.@"and")) return false;
    return isAsPart(ir.get(cond, .right)) or bindsInCondition(ir.get(cond, .left));
}

/// A part of a condition that binds: `a as x`, `f() as a, b`, which
/// binds a call's several results (`as_results`), or `s matches .circle(r)`,
/// which binds a variant's fields (`as_match`).
pub fn isAsPart(e: Sexp) bool {
    return e.isKind(.as) or e.isKind(.as_results) or e.isKind(.as_match);
}

/// The one-arm `match` an `as_match` part is (`Parser.asMatch`).
pub fn asMatchOf(part: Sexp) Sexp {
    return part.items()[1];
}

/// The one arm of the `match` an `as_match` part is: its pattern binds,
/// and the rest of the condition and the body go on in it.
pub fn asMatchArm(part: Sexp) Sexp {
    return ir.Match.arms(asMatchOf(part))[0];
}

/// Whether `match` is a `matches` the wrapper lowered (`Parser.boolMatch`,
/// `Parser.asMatch`): two arms, the pattern's and the hidden `_` every
/// other value takes.
pub fn isMatchesTest(match: Sexp) bool {
    const arms = ir.Match.arms(match);
    return arms.len == 2 and isHiddenLeaf(ir.Arm.pattern(arms[1]));
}

/// Whether `cond` joins two parts of a binding condition: an `and` on
/// its left spine.
pub fn isConditionJoin(cond: Sexp) bool {
    return cond.isKind(.@"and") and bindsInCondition(cond);
}

/// Call `visitor.part(p)` for each guard part of an `if` or `while`
/// condition, in the order they run: each part a binding condition joins
/// (`isConditionJoin`), which is a header of its own, or else the whole
/// condition, which is one. The one list of a condition's parts: emit
/// writes one `if` per part, and the storage plan, the type checker, the
/// symbol resolver, and the ownership checker walk the same parts. A
/// visitor with a `join` method is also given each `and` that joins
/// parts, after the parts it joins.
pub fn eachGuardPart(cond: Sexp, visitor: anytype) !void {
    if (isConditionJoin(cond)) {
        try eachGuardPart(ir.get(cond, .left), visitor);
        try eachGuardPart(ir.get(cond, .right), visitor);
        const V = @TypeOf(visitor);
        const T = if (@typeInfo(V) == .pointer) @typeInfo(V).pointer.child else V;
        if (@hasDecl(T, "join")) try visitor.join(cond);
        return;
    }
    try visitor.part(cond);
}

/// The nodes that leave the function or closure body holding them, on
/// the edge where they fail or always: `return`, `e!`, `e?`. A jump
/// (`jump_kinds`) goes to its `JumpDest` in the body instead.
pub const body_exit_kinds = [_]Tag{ .@"return", .propagate, .propagate_none };

/// The jumps, `break` and `continue`, each to the construct its
/// `JumpDest` names.
pub const jump_kinds = [_]Tag{ .@"break", .@"continue" };

/// Whether `e` leaves the body that holds it (`body_exit_kinds`): the
/// positive list of a body's exits.
pub fn leavesBody(e: Sexp) bool {
    const k = e.kind() orelse return false;
    return std.mem.findScalar(Tag, &body_exit_kinds, k) != null;
}

/// Whether `e` ends the code that follows it in its block: a `return`,
/// a jump (`isJump`), or a `panic`, which ends the program.
pub fn leaves(e: Sexp) bool {
    const k = e.kind() orelse return false;
    return k == .@"return" or k == .panic or std.mem.findScalar(Tag, &jump_kinds, k) != null;
}

/// Whether `e` is a jump (`jump_kinds`).
pub fn isJump(e: Sexp) bool {
    const k = e.kind() orelse return false;
    return std.mem.findScalar(Tag, &jump_kinds, k) != null;
}

/// Call `f(ctx, owner, body)` for the body of each function, `sub`,
/// `test`, and `drop` declared in module `root`, members of types
/// included: the bodies `eachUnit` lists the units of.
pub fn eachBody(root: Sexp, ctx: anytype, comptime f: anytype) !void {
    if (root.kind() != .module) return;
    for (ir.Module.decls(root)) |d| try bodiesOfDecl(d, ctx, f);
}

fn bodiesOfDecl(decl: Sexp, ctx: anytype, comptime f: anytype) !void {
    switch (decl.kind() orelse return) {
        .@"pub" => try bodiesOfDecl(ir.Pub.decl(decl), ctx, f),
        .fun, .sub, .drop_decl, .@"test" => if (ir.get(decl, .body) != .nil) try f(ctx, decl, ir.get(decl, .body)),
        .@"struct", .@"enum", .generic_struct, .generic_enum => for (ir.rest(decl, .members)) |m| try bodiesOfDecl(m, ctx, f),
        else => {},
    }
}

/// What a unit is (`eachUnit`).
pub const UnitKind = enum {
    /// A statement of a block that orders no others (`stmtClass`).
    stmt,
    /// The step of a `while`.
    step,
    /// A guard part of an `if` or `while` condition: an `as` part, or an
    /// operand of the top `and` chain of any other part.
    guard,
    /// The source of a `for`.
    source,
    /// A statement `match`'s selection: its subject, every pattern, and
    /// every guard, which run before an arm's body and never after it.
    selection,
    /// A `raw` block, opaque: no unit is listed inside it.
    raw,
};

/// What a statement of a block is to the units of a body
/// (`skeletonOf`). Every IR tag is listed, so a new one fails to compile
/// until it is placed.
pub const StmtClass = enum {
    /// It orders the units it holds, and is no unit itself.
    structured,
    /// One unit: it orders nothing inside it.
    unit,
    /// A `raw` block: one opaque unit.
    raw,
    /// Never a statement (a declaration, a pattern, a type, a part of
    /// another node): met as one, it is an opaque unit.
    none,
};

pub fn stmtClass(tag: Tag) StmtClass {
    return switch (tag) {
        .block, .@"if", .@"while", .@"for", .match, .labeled, .@"defer", .@"errdefer" => .structured,
        .raw_block => .raw,
        // Assignments, drops, `pass`, the exits and jumps, and expressions.
        .set, .destructure, .tuple, .drop, .pass, .rarely, .@"return", .@"break", .@"continue", .panic, .propagate, .propagate_none, .@"catch", .call, .builtin, .member, .index, .inst, .ct_call, .array, .array_fill, .lambda, .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"==", .@"!=", .@"<", .@">", .@"<=", .@">=", .@"&", .@"|", .@"^", .@"<<", .@"<<%", .@">>", .@"??", .@"and", .@"or", .@"..", .neg, .not, .move, .read, .write, .clone, .share, .weak, .box, .template => .unit,
        .module, .use, .fun, .sub, .@"struct", .@"enum", .errors, .error_join, .generic_struct, .generic_enum, .api, .api_type, .api_add, .type, .@"test", .@"pub", .@"extern", .extern_fun, .extern_sub, .zig_extern, .zig_const, .drop_decl, .@"inline", .called, .@":", .bound, .assoc_bound, .default, .valued, .none_value, .variant, .as, .as_results, .as_pattern, .as_match, .matches, .item_type, .item_value, .results, .result_part, .results_type, .arm, .alt_pattern, .paren_alts, .range_pattern, .set_pattern, .variant_pattern, .some_pattern, .none_pattern, .enum_lit, .symbol, .captures, .cap_clone, .cap_move, .cap_weak, .cap_read, .cap_write, .kwarg, .optional, .error_union, .read_view, .write_view, .shared, .boxed, .slice, .generic_inst, .array_type, .fun_type, .api_object, .fails, .unique, .exact, .fixed, .task, .shadow, .shadow_fixed, .@"+=", .@"-=", .@"*=", .@"/=", .@"%=", .@"+%=", .@"-%=", .@"*%=", .@"+|=", .@"-|=", .@"&=", .@"|=", .@"^=", .@"<<=", .@"<<%=", .@">>=", .iter, .inclusive, .show => .none,
        // `>t`, rewritten to a call; `f: once T`, rewritten to a
        // parameter; `a..=b`, rewritten to an inclusive `..`; and `(e)`,
        // whose `paren` is dropped; `loop`, rewritten to a `while`: each
        // before any pass reads a statement.
        .wait, .once, .@"..=", .paren, .loop => .none,
        // A function's marker, never a statement.
        .outside => .none,
    };
}

/// How a statement orders the units it holds: the one skeleton `eachUnit`
/// lists the units by and the proof pass walks (docs/internals/INTERNALS.md,
/// "Proven checks").
pub const Skeleton = union(enum) {
    /// One unit, of kind `stmt` or `raw`.
    unit: UnitKind,
    /// A block: its statements in order.
    block: Sexp,
    @"if": struct { cond: Sexp, then: Sexp, @"else": Sexp },
    @"while": struct { cond: Sexp, body: Sexp, step: Sexp },
    @"for": struct { source: Sexp, body: Sexp },
    /// A statement `match`: its selection unit, then each arm's body.
    match: Sexp,
    /// A labeled statement: the statement.
    labeled: Sexp,
    /// A `defer` or `errdefer`: its body, run at its block's exits.
    @"defer": Sexp,
};

/// The skeleton of statement `stmt` (`StmtClass`). A leaf is a unit that
/// holds nothing to check or write.
pub fn skeletonOf(stmt: Sexp) Skeleton {
    const tag = stmt.kind() orelse return .{ .unit = .stmt };
    return switch (stmtClass(tag)) {
        .unit => .{ .unit = .stmt },
        .raw, .none => .{ .unit = .raw },
        .structured => switch (tag) {
            .block => .{ .block = stmt },
            .@"if" => .{ .@"if" = .{ .cond = ir.If.cond(stmt), .then = ir.If.then(stmt), .@"else" = ir.If.@"else"(stmt) } },
            .@"while" => .{ .@"while" = .{ .cond = ir.While.cond(stmt), .body = ir.While.body(stmt), .step = ir.While.step(stmt) } },
            .@"for" => .{ .@"for" = .{ .source = ir.For.source(stmt), .body = ir.For.body(stmt) } },
            .match => .{ .match = stmt },
            .labeled => .{ .labeled = ir.Labeled.stmt(stmt) },
            .@"defer", .@"errdefer" => .{ .@"defer" = ir.get(stmt, .body) },
            else => unreachable,
        },
    };
}

/// Call `visitor.enter(root, kind)` and `visitor.exit(root)` around each
/// unit of a function or closure body, in the order the body runs them
/// (docs/internals/INTERNALS.md, "Proven checks"). A unit is a part of a body
/// inside which nothing is ordered: a statement, a guard part, a `while`
/// step, a `for` source, a statement `match`'s selection, or a `raw`
/// block. A block inside a unit's expression (an arm of a value `match`,
/// a branch of a value `if`, a `catch` handler, a loop's body) and a
/// closure's body hold units of their own, listed between the enter and
/// the exit of the unit around them. The selection's root is the `match`
/// node; its nodes are the subject, the patterns, and the guards
/// (`selectionParts`). The one list of a body's units: the storage plan
/// records each node's unit from it (`SemContext.unitOf`), and the proof
/// pass and emit enter the same units.
pub fn eachUnit(body: Sexp, visitor: anytype) VisitError(@TypeOf(visitor))!void {
    try unitsOfBranch(body, visitor);
}

/// The errors a unit visitor's `enter` may return, which every step of
/// `eachUnit` passes on.
fn VisitError(comptime V: type) type {
    const T = if (@typeInfo(V) == .pointer) @typeInfo(V).pointer.child else V;
    return @typeInfo(@typeInfo(@TypeOf(T.enter)).@"fn".return_type.?).error_union.error_set;
}

/// A branch: a block, or one statement.
fn unitsOfBranch(b: Sexp, visitor: anytype) VisitError(@TypeOf(visitor))!void {
    if (b.isKind(.block)) {
        for (ir.Block.stmts(b)) |s| try unitsOfStmt(s, visitor);
        return;
    }
    if (b != .nil) try unitsOfStmt(b, visitor);
}

fn unitsOfStmt(stmt: Sexp, visitor: anytype) VisitError(@TypeOf(visitor))!void {
    switch (skeletonOf(stmt)) {
        .unit => |kind| try unitOf(stmt, kind, visitor),
        .block => |b| try unitsOfBranch(b, visitor),
        .@"if" => |x| {
            try unitsOfCond(x.cond, visitor);
            try unitsOfBranch(x.then, visitor);
            try unitsOfBranch(x.@"else", visitor);
        },
        .@"while" => |x| {
            try unitsOfCond(x.cond, visitor);
            try unitsOfBranch(x.body, visitor);
            if (x.step != .nil) try unitOf(x.step, .step, visitor);
        },
        .@"for" => |x| {
            try unitOf(x.source, .source, visitor);
            try unitsOfBranch(x.body, visitor);
        },
        .match => |m| {
            try unitOf(m, .selection, visitor);
            for (ir.Match.arms(m)) |arm| try unitsOfBranch(ir.Arm.body(arm), visitor);
        },
        .labeled => |inner| try unitsOfStmt(inner, visitor),
        .@"defer" => |body| try unitsOfBranch(body, visitor),
    }
}

/// The guard parts of a condition (`eachGuardPart`), each `and` operand
/// of a part that binds nothing its own unit. A part `s matches .circle(r)`
/// is the selection of the `match` it is (`asMatchOf`).
fn unitsOfCond(cond: Sexp, visitor: anytype) VisitError(@TypeOf(visitor))!void {
    const Parts = struct {
        v: @TypeOf(visitor),
        pub fn part(self: @This(), p: Sexp) VisitError(@TypeOf(visitor))!void {
            if (p.isKind(.as_match)) return unitOf(asMatchOf(p), .selection, self.v);
            try eachGuardOperand(p, self, @This().unit);
        }
        fn unit(self: @This(), p: Sexp) VisitError(@TypeOf(visitor))!void {
            try unitOf(p, .guard, self.v);
        }
    };
    try eachGuardPart(cond, Parts{ .v = visitor });
}

/// Call `f(ctx, e)` for each operand of guard part `part`'s top `and`
/// chain, left to right, or for the part itself: an `as` part, or one
/// that is no `and`. Zig's `and` runs each only when those before it
/// held, as Rig's does.
pub fn eachGuardOperand(part: Sexp, ctx: anytype, comptime f: anytype) !void {
    if (part.isKind(.@"and")) {
        try eachGuardOperand(ir.get(part, .left), ctx, f);
        return eachGuardOperand(ir.get(part, .right), ctx, f);
    }
    try f(ctx, part);
}

/// The nodes of a statement `match`'s selection unit: its subject, then
/// each arm's pattern and guard.
pub fn selectionParts(a: std.mem.Allocator, match: Sexp) ![]const Sexp {
    var out: std.ArrayList(Sexp) = .empty;
    try out.append(a, ir.Match.subject(match));
    for (ir.Match.arms(match)) |arm| {
        try out.append(a, ir.Arm.pattern(arm));
        if (ir.Arm.guard(arm) != .nil) try out.append(a, ir.Arm.guard(arm));
    }
    return out.items;
}

fn unitOf(root: Sexp, kind: UnitKind, visitor: anytype) VisitError(@TypeOf(visitor))!void {
    // A leaf (a name, a literal) holds nothing to check or write.
    if (root != .list) return;
    try visitor.enter(root, kind);
    switch (kind) {
        // Nothing inside `raw` is a unit of its own.
        .raw => {},
        .selection => {
            try nestedUnits(ir.Match.subject(root), visitor);
            for (ir.Match.arms(root)) |arm| {
                try nestedUnits(ir.Arm.pattern(arm), visitor);
                try nestedUnits(ir.Arm.guard(arm), visitor);
            }
        },
        else => try nestedUnits(root, visitor),
    }
    try visitor.exit(root);
}

/// The units of the blocks and closure bodies inside a unit's expression.
/// A visitor with a `nest` method is given each such block before and
/// after its units.
fn nestedUnits(e: Sexp, visitor: anytype) VisitError(@TypeOf(visitor))!void {
    if (e != .list) return;
    if (e.isKind(.block)) {
        const V = @TypeOf(visitor);
        const T = if (@typeInfo(V) == .pointer) @typeInfo(V).pointer.child else V;
        if (@hasDecl(T, "nest")) try visitor.nest(e, true);
        try unitsOfBranch(e, visitor);
        if (@hasDecl(T, "nest")) try visitor.nest(e, false);
        return;
    }
    for (e.items()) |c| try nestedUnits(c, visitor);
}

/// `x[...]`: an index, or compile-time arguments (sema tells which).
pub fn isBracketList(e: Sexp) bool {
    return e.isKind(.index) or e.isKind(.inst);
}

/// Whether a call of `callee` is a method call: a member, or a member
/// followed by a bracket list (`v.put[2](x)`).
pub fn isMethodCallee(callee: Sexp) bool {
    if (callee.isKind(.member)) return true;
    return isBracketList(callee) and ir.get(callee, .object).isKind(.member);
}

/// The member a variant pattern names, `.name(...)` or `E.name(...)`:
/// its name's leaf.
pub fn variantPatternName(p: Sexp) Sexp {
    const n = ir.VariantPattern.name(p);
    return if (n.isKind(.member)) ir.Member.name(n) else n;
}

/// Whether range `r`, a `..` or a range pattern, includes its end:
/// `a..=b`.
pub fn isInclusive(r: Sexp) bool {
    return ir.get(r, .inclusive) != .nil;
}

/// A slice, `xs[a..b]`: an index node whose index is a range.
pub fn isRangeIndex(e: Sexp) bool {
    return e.isKind(.index) and ir.Index.index(e).isKind(.@"..");
}

/// Every child of a node, in slot order (absent optional slots are `_`),
/// for passes that visit all of them; empty for a leaf. Passes that need
/// a particular child read it by role (`parser.ir`).
pub fn children(node: Sexp) []const Sexp {
    if (node.kind() == null) return &.{};
    return node.items()[1..];
}

// =============================================================================
// Templates
// =============================================================================

/// A template, `(template text slot text ... text)`: its text pieces and
/// its slots alternate, first and last a piece (SPEC "Templates").
pub const Template = struct {
    /// How many slots `t` has.
    pub fn slotCount(t: Sexp) usize {
        return ir.Template.parts(t).len / 2;
    }

    /// Slot `i` of `t`: an expression, or a show slot `(show eq value)`.
    pub fn slot(t: Sexp, i: usize) Sexp {
        return ir.Template.parts(t)[2 * i + 1];
    }

    /// Text piece `i` of `t`, of `slotCount(t) + 1`: the token, its
    /// delimiters included (`templateText` gives what it holds).
    pub fn piece(t: Sexp, i: usize) Sexp {
        return ir.Template.parts(t)[2 * i];
    }

    /// The value slot `i` writes: its expression, or a show slot's.
    pub fn value(t: Sexp, i: usize) Sexp {
        return slotValue(slot(t, i));
    }
};

/// The expression a slot writes: itself, or a show slot's value.
pub fn slotValue(s: Sexp) Sexp {
    return if (s.isKind(.show)) ir.Show.value(s) else s;
}

/// Whether `text` is a template's text piece: a token from a backtick or
/// a slot's `}` to a slot's `{` or the closing backtick.
pub fn isTemplateText(text: []const u8) bool {
    return text.len >= 2 and (text[0] == '`' or text[0] == '}');
}

/// What a template piece's token holds between its delimiters, escapes
/// as written.
pub fn templateText(text: []const u8) []const u8 {
    return text[1 .. text.len - 1];
}

/// The label a show slot `{=e}` of template `t` writes: `e` as written,
/// its outer spaces trimmed, from the `=` to the slot's `}` (the next
/// piece's start).
pub fn showLabel(source: []const u8, t: Sexp, i: usize) []const u8 {
    const eq = ir.Show.eq(Template.slot(t, i));
    const next = Template.piece(t, i + 1);
    return std.mem.trim(u8, diag.textBetween(source, eq.src.pos + 1, next.src.pos), " ");
}

// =============================================================================
// BindingKind — the op slot of (set <op> ...)
// =============================================================================

/// Exhaustive view of the op slot, so dispatch sites must handle every
/// kind: `_` → default, `fixed` (`x =!`, and `new x =!`), `shadow`
/// (`new x =`), and the compound assignments (`x op= e`, one per binary
/// arithmetic, wrapping, bitwise, and shift operator). Every kind but
/// `default` is named after its tag in the schema's `op:tag(...)` for
/// `set`. `new x =! e` is the tag `shadow_fixed`, decoded as `fixed`: it
/// binds as `x =! e` does, and only declaring the name tells the two
/// apart (`shadows`).
pub const BindingKind = enum {
    default,
    fixed,
    shadow,
    @"+=",
    @"-=",
    @"*=",
    @"/=",
    @"%=",
    @"+%=",
    @"-%=",
    @"*%=",
    @"+|=",
    @"-|=",
    @"&=",
    @"|=",
    @"^=",
    @"<<=",
    @"<<%=",
    @">>=",

    comptime {
        for (@typeInfo(BindingKind).@"enum".field_names[1..]) |f| {
            if (!@hasField(Tag, f)) @compileError("BindingKind." ++ f ++ " is not a tag of the IR");
        }
    }

    /// The binary operator a compound assignment applies (`+=` applies
    /// `+`), or null for a plain binding or assignment.
    pub fn operator(k: BindingKind) ?Tag {
        return switch (k) {
            .default, .fixed, .shadow => null,
            inline else => |c| @field(Tag, @tagName(c)[0 .. @tagName(c).len - 1]),
        };
    }
};

/// Decode the op slot of `(set <op> ...)`. Nexus builds it from the
/// schema's `op:tag(...)`, so any other value is unreachable.
pub fn bindingKindOf(op: Sexp) BindingKind {
    return switch (op) {
        .nil => .default,
        .tag => |t| switch (t) {
            .shadow_fixed => .fixed,
            inline else => |c| if (@hasField(BindingKind, @tagName(c))) @field(BindingKind, @tagName(c)) else unreachable,
        },
        else => unreachable,
    };
}

/// Whether the op slot of `(set <op> ...)` binds a new name even where
/// one is already visible: `new x = e` and `new x =! e`.
pub fn shadows(op: Sexp) bool {
    return op == .tag and (op.tag == .shadow or op.tag == .shadow_fixed);
}

// =============================================================================
// Keywords
// =============================================================================

/// The categories from `true` to `yield` in rig.grammar's `tokens`
/// block are Rig's keywords. Every keyword is reserved and is a lexer
/// rule, so the base lexer gives it its own category, except `new`, `obj`,
/// `inline`, `called`, and `rarely`, which lex as names and are keywords only where
/// the rewriter classifies them (`classifyWord`): `new` at the start of a
/// statement followed by a name (`new x = ...`, `new x =! ...`), so
/// `fun new(...)` and `Point.new(...)` stay ordinary names.
pub fn isKeyword(cat: TokenCat) bool {
    return @intFromEnum(cat) >= @intFromEnum(TokenCat.true) and @intFromEnum(cat) <= @intFromEnum(TokenCat.yield);
}

/// A word the base lexer reads: a name or a reserved word.
fn isWord(cat: TokenCat) bool {
    return cat == .ident or isKeyword(cat);
}

/// The token category of a keyword, or null for a plain name.
pub fn keyword(word: []const u8) ?TokenCat {
    if (std.mem.eql(u8, word, "new")) return .new;
    var base = BaseLexer.init(word);
    const tok = base.next();
    return if (endOf(&base, tok) == word.len and isKeyword(tok.cat)) tok.cat else null;
}

/// Where a token the lexer `base` scanned or built ends: `pos + len`, and
/// for a token over 65534 bytes (its `len` is 65535, `@longtokens`) the
/// end `base` recorded. Every end of a token on the lexer's side is read
/// here; the parser's side reads `BaseParser.tokenEnd`.
pub fn endOf(base: *const BaseLexer, tok: Token) u32 {
    if (tok.len < std.math.maxInt(u16)) return tok.pos + tok.len;
    return base.longEnds.find(tok.pos).?;
}

// =============================================================================
// Zig identifiers for emitted code
// =============================================================================

const zig_keywords = std.StaticStringMap(void).initComptime(.{
    .{"addrspace"},   .{"align"},   .{"allowzero"},   .{"and"},
    .{"anyframe"},    .{"anytype"}, .{"asm"},         .{"break"},
    .{"callconv"},    .{"catch"},   .{"comptime"},    .{"const"},
    .{"continue"},    .{"defer"},   .{"else"},        .{"enum"},
    .{"errdefer"},    .{"error"},   .{"export"},      .{"extern"},
    .{"fn"},          .{"for"},     .{"if"},          .{"inline"},
    .{"linksection"}, .{"noalias"}, .{"noinline"},    .{"nosuspend"},
    .{"opaque"},      .{"or"},      .{"orelse"},      .{"packed"},
    .{"pub"},         .{"resume"},  .{"return"},      .{"struct"},
    .{"suspend"},     .{"switch"},  .{"test"},        .{"threadlocal"},
    .{"try"},         .{"union"},   .{"unreachable"}, .{"var"},
    .{"volatile"},    .{"while"},
});

const zig_primitives = std.StaticStringMap(void).initComptime(.{
    .{"anyerror"}, .{"anyopaque"},      .{"bool"},         .{"c_char"},
    .{"c_int"},    .{"c_long"},         .{"c_longdouble"}, .{"c_longlong"},
    .{"c_short"},  .{"c_uint"},         .{"c_ulong"},      .{"c_ulonglong"},
    .{"c_ushort"}, .{"comptime_float"}, .{"comptime_int"}, .{"f128"},
    .{"f16"},      .{"f32"},            .{"f64"},          .{"f80"},
    .{"false"},    .{"isize"},          .{"noreturn"},     .{"null"},
    .{"true"},     .{"type"},           .{"undefined"},    .{"usize"},
    .{"void"},
});

/// Names a Rig name may not keep in the emitted Zig: the ones the emitted
/// prelude declares (`std`, `rig`, and `panic`, the root module's panic
/// handler), and the ones Zig's standard library looks up in the root
/// module with `@hasDecl(root, ...)` and uses as hooks (`debug`, `os`,
/// `std_options`, the entry points of each target), and `self`, which
/// `@` is written as. Every one is renamed wherever it
/// stands, so no hook depends on which module or scope declares it.
const emitter_names = std.StaticStringMap(void).initComptime(.{
    .{"std"},       .{"rig"},                .{"panic"},
    .{"debug"},     .{"os"},                 .{"tracy"},
    .{"_start"},    .{"__start"},            .{"main"},
    .{"WinMain"},   .{"wWinMain"},           .{"WinMainCRTStartup"},
    .{"DllMain"},   .{"wWinMainCRTStartup"}, .{"DllMainCRTStartup"},
    .{"EfiMain"},   .{"_DllMainCRTStartup"}, .{"self"},
});
/// The prefixes of the names emitter temporaries take (`__rig_tmp_3`),
/// and of the `std_options_*` hooks.
const emitter_prefixes = [_][]const u8{ "__rig", "std_options" };

pub fn isPlainName(name: []const u8) bool {
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn isZigIntType(name: []const u8) bool {
    if (name.len < 2 or (name[0] != 'i' and name[0] != 'u')) return false;
    for (name[1..]) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Whether the Zig spelling of the Rig name `name` is another name: the
/// name `writeZigIdent` gives it a `'` suffix.
pub fn zigRenames(name: []const u8) bool {
    if (!isPlainName(name)) return false;
    if (emitter_names.has(name)) return true;
    for (emitter_prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// How a name is written: a Rig name of the program (`.rig`), or a name
/// that must be spelled exactly, as the Zig or C it denotes declares it
/// (`.exact`: a function of a standard library Zig file).
pub const ZigSpelling = enum { rig, exact };

/// Write `name` as a Zig identifier that denotes the Rig name and nothing
/// else. This is the one place a Rig name becomes a Zig name: every
/// declaration and every use of a local, parameter, capture, field,
/// method, variant, type, generic parameter, constant, function,
/// label, or module the program names is written here, so a use is
/// always spelled as its declaration.
///   * self, `@`, is `self`;
///   * a name the emitter or Zig's standard library uses
///     (`zigRenames`: `std`, `rig`, `debug`, `self`, `__rig*`) gets a `'`
///     suffix, which no Rig identifier can contain: `@"rig'"`; an
///     `.exact` name never does;
///   * a Zig keyword or primitive (`var`, `fn`, `u8`, `type`), and `_`,
///     which alone is Zig's discard, are quoted: `@"var"`, `@"_"`;
///   * anything else is written as is.
/// The mapping is one to one, so two Rig names never meet in one Zig
/// name, and the runtime strips the suffix where a name is printed
/// (`rig.rigName`).
pub fn writeZigIdent(w: *std.Io.Writer, name: []const u8, spelling: ZigSpelling) std.Io.Writer.Error!void {
    if (std.mem.eql(u8, name, "@")) {
        try w.writeAll("self");
    } else if (!isPlainName(name)) {
        // A name no program writes (`hiddenLeaf`).
        try w.print("@\"{s}\"", .{name});
    } else if (spelling == .rig and zigRenames(name)) {
        try w.print("@\"{s}'\"", .{name});
    } else if (zig_keywords.has(name) or zig_primitives.has(name) or isZigIntType(name) or std.mem.eql(u8, name, "_")) {
        try w.print("@\"{s}\"", .{name});
    } else {
        try w.writeAll(name);
    }
}

// =============================================================================
// Lexer — layout and token classification over the generated BaseLexer
// =============================================================================
//
// Layout
//   Leading spaces set a line's indentation; deeper lines open a block
//   (INDENT), shallower ones close blocks (OUTDENT) and must land on an
//   enclosing level. Blank and comment-only lines are ignored. Inside
//   ( ) and [ ] newlines are whitespace, so an expression may span lines.
//   A trailing `\` also joins the next line. Tabs are rejected in
//   indentation.
//
//   Closure bodies inside brackets: a closure's bar list that ends its
//   line inside ( ) or [ ] opens a layout island, so the body below is
//   laid out in blocks like anywhere else:
//
//       sig.subscribe(*|~sig|
//         if sig.upgrade() as s
//           print(s.get())
//       )
//
//   The island closes when a line comes back to the indentation of the
//   line the closure started on, or when the bracket around it closes;
//   its open blocks end there. The line that closes it starts with that
//   bracket, at the indentation of the line that opened the bracket; a
//   bracket that closes it anywhere else is recorded (`layouts`), and
//   reported once the source parses.
//
// Position
//   Whitespace inside an expression never picks a form. A character that
//   both starts and continues an operand (`<x` and `a < b`, `f(x)` and
//   `(x)`, `?T` and `T?`, `.red` and `a.b`) is one token, and the parser
//   tells the forms apart by where it stands. The lexer still reads
//   position where the parser cannot: after a value (a name, the type
//   `error`, a literal, `)`, `]`, or a `?` / `!` suffix) a character
//   continues it; anywhere else it starts an operand, as a prefix:
//
//     `|x| ...` starts a closure's bar list; after a value `|` is
//     bitwise or.
//
//     A prefix sigil touches its operand: `- b` and `< x` are errors,
//     so `a <- b` is not quietly `a < -b`. After a type's `]` the
//     parser decides (`[2]?T`), and the Parser wrapper checks the touch.
//
//     Spacing never picks a form, but spacing that reads as another
//     form is wrong: an infix operator has the same spacing on both
//     sides (`a < b`, `a<b`, never `a <b`), a postfix `?` or `!` touches
//     what it follows, a member `.` touches both sides (a chain may go
//     on at the start of the next line inside brackets), an enum
//     literal's `.` touches its name, and a range's `..` with one bound
//     touches it. The lexer records each such operator (`spacings`);
//     the Parser wrapper reports them once the source parses, so that a
//     parse error is the one reported.
//
//   Token boundaries still matter, as in `!=` and `==`: `=!` is one
//   token, so `x =!y` could be a fixed binding of `y` or `x = !y`; a
//   `=!` without a space or tab after it is an error.
//
// `if`
//   After `return`/`break`/`continue` or a value, `if` is a postfix guard
//   (`return x if done`), or the inline ternary when an `else` follows on
//   the same logical line (`a if c else b`). Elsewhere it opens a block.
//
// `of`
//   After a value directly inside [ ], `of` separates a fill literal's
//   count from its element (`[n of x]`). Elsewhere it is a name.
//
// `obj`
//   At the start of a statement (after any `pub`), when a name follows
//   it, `obj` starts a type declaration (`obj Point`). Elsewhere it is a
//   name (`obj = 5`, `obj.x`, `f(obj: 1)`), and so is `struct`.
//
// A leading `.`
//   A line that starts with `.` and a name, indented deeper than its
//   statement, continues that statement (`continuesChain`). The
//   statement must be complete and open no block, so `match` arms and
//   the members of a type are unchanged.
//
// `unique`, `from`, `static`
//   Names to the lexer: the parser reads each as a keyword where its
//   state takes it (rig.grammar, `@keywords`).
//
// `..`
//   Before `]` (past any line break, which is whitespace inside
//   brackets), `..` ends an open range (`xs[a..]`, `xs[..]`):
//   DOTDOT_OPEN, so the expression before it ends there.

pub const Lexer = struct {
    base: BaseLexer,

    // Indentation: `levels[0..depth]` are the enclosing block columns.
    levels: [max_indent_depth]u32 = undefined,
    depth: u32 = 0,
    /// Per depth: the current line there opened a block that `else` may
    /// continue (it has a block `if`, `while`, or `for`). An `else` after
    /// any other block (a match arm) is a new line.
    takes_else: [max_indent_depth + 1]bool = @splat(false),
    /// Per depth: the block is the member list of an object, enum, or
    /// error set, where a keyword may name a field or method.
    in_members: [max_indent_depth + 1]bool = @splat(false),
    /// Per depth: the block is the arm list of a `match`, where each line
    /// is an arm and a deeper line is its body.
    in_arms: [max_indent_depth + 1]bool = @splat(false),
    /// The first token of the current statement, after any `pub`, and
    /// where it starts.
    line_head: TokenCat = .eof,
    /// The logical line has a token that opens a block (`fun`, `if`,
    /// `match`, `obj`, ...), wherever it stands: `x = match c` opens one
    /// as `match c` does.
    line_opens: bool = false,
    /// The line has a `match`, so the block it opens holds arms.
    line_match: bool = false,
    head_pos: u32 = 0,
    /// The position of the last postfix `if` guard, which ends its
    /// statement: a deeper line after it is reported at it.
    guard_pos: ?u32 = null,
    column: u32 = 0,
    pending_outdents: u32 = 0,
    pending_newline: bool = false,
    pending_pos: u32 = 0,

    // Positions of the open ( and [; newlines inside them are whitespace.
    brackets: [max_nesting]u32 = undefined,
    nesting: u32 = 0,

    /// Category of the last token returned.
    last_cat: TokenCat = .eof,
    /// Where the last token starts.
    last_pos: u32 = 0,
    /// The last token ends an operand (`isValue`, or a `?` / `!` suffix
    /// after one), so a character after it continues the operand.
    after_value: bool = false,
    /// The last token is a `$` that declares a statement's label; the
    /// name after it is the label.
    label_sigil: bool = false,
    /// The last token is the name of a label being declared: its `:`
    /// is next, and it ends no operand.
    label_name: bool = false,
    /// The last token is a label's `:` (`$outer:`): a statement starts
    /// after it.
    after_label: bool = false,
    /// The last token is the label of a jump (`break $outer`): what
    /// follows it starts the jump's value, and ends no operand.
    after_jump_label: bool = false,
    /// The category of the token before the last one.
    last2_cat: TokenCat = .eof,
    /// The last token is a symbol's `:`: the word after it is the
    /// symbol's name, a keyword too (`:if`).
    symbol_name: bool = false,
    /// The operators whose spacing breaks the rule (an infix operator
    /// has the same spacing on both sides; a postfix, a member `.`, and a
    /// range's open end touch what they join), and the closure bodies
    /// laid out below their bar lists that end anywhere but on a line of
    /// their own: the first `max_layouts` of them, reported once the
    /// source parses (`Parser.layoutMessage`).
    layouts: [max_layouts]Layout = undefined,
    layout_count: u32 = 0,
    /// The bracket nesting of the `while` header being lexed, whose first
    /// `:` there starts the step; null outside one.
    while_header: ?u32 = null,
    /// Start and end of the last real (non-layout) token; an unexpected
    /// end of block or file is reported at its end.
    prev_pos: u32 = 0,
    prev_end: u32 = 0,
    prev_cat: TokenCat = .eof,
    /// The real token before that one, which a parse error's hint reads.
    before_cat: TokenCat = .eof,
    before_pos: u32 = 0,
    /// Position of the `|` that closes the bar list being lexed.
    capture_close: ?u32 = null,
    /// The last token closed a closure's bar list.
    closed_bars: bool = false,
    /// Layout islands: closure bodies laid out inside brackets, innermost
    /// last.
    islands: [max_islands]Island = undefined,
    island_count: u32 = 0,
    /// A token held back until pending OUTDENTs are returned.
    pending_token: ?Token = null,
    /// Where the name after an `@` touching it starts (`@hits`): the
    /// next token is a `.` there, which makes `@hits` the member access
    /// `@ . hits`.
    member_dot: ?u32 = null,
    /// A module of several files, joined: where each file but the last
    /// ends in the source, ascending. Each file closes its own blocks and
    /// brackets: no token is read across an end while a bracket is open,
    /// and a file's first line is not indented.
    ends: []const u32 = &.{},
    /// The index in `ends` of the end of the file being read.
    file: u32 = 0,

    /// The slot of a template being lexed (`` `a{x}b` ``): the bracket
    /// nesting outside it, where its `}` closes it and the template's
    /// text goes on. Templates do not nest, so one is open at most.
    slot: ?Slot = null,

    /// Why the last `.err` token was produced.
    err: LexError = .none,

    pub const max_indent_depth = 64;
    pub const max_nesting = 512;
    pub const max_islands = 32;
    pub const max_layouts = 32;

    /// A closure body laid out inside brackets. Its blocks sit on the
    /// layout stack above `depth`; `column` is the indentation of the
    /// line the closure starts on, and the layout state to restore is
    /// `depth` / `outer_column`.
    const Island = struct { nesting: u32, depth: u32, column: u32, outer_column: u32 };

    /// An open slot: `open` is its `{`, `nesting` the bracket nesting
    /// around it.
    const Slot = struct { open: u32, nesting: u32 };

    /// An operator whose spacing, or a closure body whose layout, breaks
    /// the rule, at `pos`.
    pub const Layout = struct {
        pos: u32,
        len: u32,
        kind: Kind,
        /// For a closure body: the indentation of the line that opened
        /// the bracket around it, where its closing bracket goes.
        column: u32 = 0,

        pub const Kind = enum {
            /// An infix operator with whitespace before it only (`a <b`).
            infix_before,
            /// An infix operator with whitespace after it only (`a< b`).
            infix_after,
            /// A postfix `?` or `!` apart from what it follows (`f() !`).
            postfix,
            /// A member `.` with whitespace beside it (`w . get()`).
            member,
            /// An enum literal's `.` apart from its name (`. red`).
            enum_dot,
            /// A range's `..` apart from its only bound (`.. b`, `a ..]`).
            range_end,
            /// A call's or index's bracket apart from what it follows
            /// (`f (x)`, `xs [0]`).
            call_bracket,
            /// The bracket around a closure body laid out below its bar
            /// list closes on the body's last line (`print(x))`).
            closure_hanging,
            /// The line that ends such a body starts with something other
            /// than that bracket (`, 1)`).
            closure_close,
            /// It starts with the bracket, at another indentation than
            /// the line that opened the bracket.
            closure_indent,
        };
    };

    pub const LexError = enum {
        none,
        bad_char,
        unterminated_string,
        tab_indent,
        bad_dedent,
        first_line_indented,
        indent_too_deep,
        nesting_too_deep,
        islands_too_deep,
        and_operator,
        or_operator,
        or_fallback,
        power_operator,
        increment,
        decrement,
        slash_comment,
        self_dot,
        dollar_detached,
        dollar_stray,
        label_keyword,
        label_decl,
        label_touch,
        symbol_detached,
        symbol_name,
        symbol_long,
        control_in_string,
        lone_cr,
        leading_zero,
        radix_case,
        bad_number,
        fixed_touch,
        detached_prefix,
        semicolon,
        brace,
        two_markers,
        repeated_marker,
        marker_before_pub,
        matches_paren,
        matches_list,
        template_no_slot,
        template_unclosed,
        template_empty,
        template_ticks,
        template_tagged,
        template_brace,
        template_control,
        template_bidi,
        template_join,
        slot_empty,
        slot_line,
        slot_colon,
        slot_comment,
        slot_template,
        slot_show_space,
        slot_show_after,
        template_long,

        pub fn message(e: LexError) []const u8 {
            return switch (e) {
                .none => "invalid token",
                .bad_char => "invalid character",
                .unterminated_string => "unterminated string",
                .control_in_string => "control character in a string; write it as an escape (`\\t`, `\\n`) in a double-quoted string",
                .lone_cr => "carriage return without a line feed; end lines with `\\n` or `\\r\\n`",
                .leading_zero => "a decimal number has no leading zero",
                .radix_case => "radix prefixes are lowercase: `0x`, `0b`, `0o`",
                .bad_number => "malformed number; `_` may separate digits, and a space or an operator ends a number",
                .fixed_touch => "`=!` needs a space after it: write `x =! y` for a fixed binding, or `x = !y` to lend `y` to write",
                .detached_prefix => "a prefix sigil touches its operand",
                .semicolon => "unexpected `;`",
                .brace => "Rig has no braces: a block is the lines indented under its header",
                .tab_indent => "tab in indentation; indent with spaces",
                .bad_dedent => "indentation does not match any enclosing block",
                .first_line_indented => "unexpected indentation",
                .indent_too_deep => "indentation is nested too deeply",
                .nesting_too_deep => "brackets are nested too deeply",
                .islands_too_deep => "closures laid out inside brackets are nested too deeply",
                .and_operator => "`&&` is not a Rig operator; use `and`",
                .or_operator => "`||` is not a Rig operator; use `or`, or `??` for an optional's fallback",
                .or_fallback => "`||` is not a Rig operator; a fallback value for an optional is written with `??`: `x ?? 0`",
                .power_operator => "`**` is not a Rig operator",
                .increment => "Rig has no `++`; write `x += 1`",
                .decrement => "Rig has no `--`; write `x -= 1`",
                .slash_comment => "comments start with `#`; Rig has no `//` or `/* */` comments",
                .self_dot => "a member of self is written `@name`, the name touching the `@`",
                .dollar_detached => "`$` touches the name after it: a builtin call is written `$size(T)`, a label `$outer:` (`break $outer`)",
                .dollar_stray => "`$name` is a builtin call, `$size(T)`, with the name touching its `(`, or a label: `$outer:` where a statement starts, and `break $outer` or `continue $outer`",
                .label_keyword => "a keyword is not a label name",
                .label_decl => "a label is declared with a `:` touching its name: `$outer: for ...`, or `$outer:` on a line of its own over the block it names",
                .label_touch => "a jump's label ends at its name: put a space before the value, `break $outer -1`",
                .symbol_detached => "a prefix `:` touches its operand: a symbol is written `:width`",
                .symbol_name => "a symbol is `:` and a name: `:width`, `:content-type`",
                .symbol_long => "a symbol's name is too long",
                .marker_before_pub => "`pub` comes before a function's marker: write `pub inline fun` or `pub called fun`",
                .repeated_marker => "a function's marker is written once",
                .two_markers => "a function takes one marker: `inline` (inline it at every call) or `called` (keep every call a call), which contradict each other",
                .matches_paren => "write `matches (`: alternatives follow `matches` after a space",
                .matches_list => "put alternatives in parentheses: `matches (.a, .b)`",
                .template_no_slot => "a template has a slot; fixed text is written in double quotes, `\"…\"`",
                .template_unclosed => "unterminated template: it ends with a backtick on its line",
                .template_empty => "an empty template ``` `` ``` is reserved; empty text is `\"\"`",
                .template_ticks => "two backticks together are reserved; a backtick in a template is written `\\``",
                .template_tagged => "a name touching a backtick is reserved for tagged templates; put a space or a bracket between them",
                .template_brace => "a lone `}` in a template; write a brace as `\\}`",
                .template_control => "control character in a template; write it as an escape (`\\t`, `\\n`)",
                .template_bidi => "a bidirectional control character in a template; write it as an escape, `\\u{202e}`",
                .template_join => "a `\\` at the end of a template's line is reserved for joining lines",
                .slot_empty => "an empty slot; a slot holds an expression, `{x}`, or `{=x}` to show it",
                .slot_line => "a slot ends on its template's line: close it with `}`",
                .slot_colon => "a `:` in a slot is reserved for formatting; format with a method, or put the expression in parentheses",
                .slot_comment => "a slot holds no `#`; a template's text ends with its backtick",
                .slot_template => "a template inside a slot is reserved; build the inner text first",
                .slot_show_space => "the show form is written `{=x}`, the `=` touching the `{`",
                .slot_show_after => "a slot shows its expression as `{=x}`, with the `=` first",
                .template_long => "a template's text between two slots is longer than 65534 bytes",
            };
        }
    };

    pub fn init(source: []const u8) Lexer {
        var lexer: Lexer = .{ .base = BaseLexer.init(source) };
        if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) lexer.base.pos = 3; // a UTF-8 byte order mark
        return lexer;
    }

    pub fn next(self: *Lexer) Token {
        const tok = self.produce();
        self.after_label = tok.cat == .label_colon;
        self.label_name = self.label_sigil and tok.cat == .ident;
        self.label_sigil = tok.cat == .label and !isLabelJump(self.last_cat);
        self.after_jump_label = tok.cat == .ident and self.last_cat == .label and isLabelJump(self.last2_cat);
        self.after_value = !self.label_name and !self.after_jump_label and (isValue(tok.cat) or (self.after_value and (tok.cat == .question or tok.cat == .not_sym)));
        self.last2_cat = self.last_cat;
        self.last_cat = tok.cat;
        self.last_pos = tok.pos;
        switch (tok.cat) {
            .newline, .indent, .outdent => {
                self.line_opens = false;
                self.line_match = false;
            },
            else => {},
        }
        switch (tok.cat) {
            .@"while" => self.while_header = self.nesting,
            .newline, .indent, .outdent, .eof, .step_colon => self.while_header = null,
            else => {},
        }
        if (tok.len > 0 and tok.cat != .err) { // a real token, not layout
            self.before_cat = self.prev_cat;
            self.before_pos = self.prev_pos;
            self.prev_cat = tok.cat;
            self.prev_pos = tok.pos;
            self.prev_end = endOf(&self.base, tok);
        }
        if (self.closed_bars) {
            self.closed_bars = false;
            if (self.nesting > 0 and !self.inIsland() and self.lineEndsAfter()) {
                if (self.island_count == max_islands) return self.fail(.islands_too_deep, tok.pos);
                const column = self.lineIndent(tok.pos);
                self.islands[self.island_count] = .{ .nesting = self.nesting, .depth = self.depth, .column = column, .outer_column = self.column };
                self.island_count += 1;
                self.column = column;
            }
        }
        return tok;
    }

    /// Newlines at the current bracket depth are layout: the innermost
    /// island is open at this depth.
    fn inIsland(self: *const Lexer) bool {
        return self.island_count > 0 and self.islands[self.island_count - 1].nesting == self.nesting;
    }

    /// Nothing but a comment follows on the current line.
    fn lineEndsAfter(self: *const Lexer) bool {
        var probe = self.base;
        var t = probe.next();
        if (t.cat == .comment) t = probe.next();
        return t.cat == .newline or t.cat == .eof;
    }

    /// Indentation of the line containing `pos`.
    fn lineIndent(self: *const Lexer, pos: u32) u32 {
        var start = pos;
        while (start > 0 and self.base.source[start - 1] != '\n') start -= 1;
        var p = start;
        while (p < self.base.source.len and self.base.source[p] == ' ') p += 1;
        return p - start;
    }

    /// Close the innermost island: its open blocks end here. Returns the
    /// first OUTDENT, with the rest pending and `after` held back, or
    /// null when no block was open.
    fn closeIsland(self: *Lexer, pos: u32, after: ?Token) ?Token {
        self.island_count -= 1;
        const island = self.islands[self.island_count];
        const open = self.depth - island.depth;
        self.depth = island.depth;
        self.column = island.outer_column;
        if (open == 0) return null;
        self.pending_outdents = open - 1;
        self.pending_pos = pos;
        self.pending_newline = false;
        self.pending_token = after;
        return synthetic(.outdent, pos);
    }

    fn produce(self: *Lexer) Token {
        if (self.pending_outdents > 0) {
            self.pending_outdents -= 1;
            return synthetic(.outdent, self.pending_pos);
        }
        if (self.pending_newline) {
            self.pending_newline = false;
            return synthetic(.newline, self.pending_pos);
        }
        if (self.pending_token) |t| {
            self.pending_token = null;
            return self.classify(t);
        }
        if (self.member_dot) |pos| {
            self.member_dot = null;
            return synthetic(.dot, pos);
        }

        while (true) {
            const tok = self.base.next();
            if (self.slot != null) switch (tok.cat) {
                .comment => return self.fail(.slot_comment, tok.pos),
                .skip, .newline, .eof => return self.fail(.slot_line, self.slot.?.open),
                else => {},
            };
            switch (tok.cat) {
                .comment => continue,
                .skip => continue, // `\` line continuation
                .newline => {
                    if (!self.inIsland() and (self.nesting > 0 or self.last_cat == .eof)) continue;
                    return self.lineBreak(tok);
                },
                .eof => return self.endOfInput(tok),
                else => {},
            }
            if (self.last_cat == .eof and tok.pre > 0) return self.firstLineIndented(tok);
            if (self.crossesFile(tok.pos)) {
                if (self.nesting > 0) return self.endOfFile();
                if (self.last_cat != .eof) {
                    // The file ended with no line break (a `\` before its
                    // end): its last line ends there.
                    return self.lineBreak(synthetic(.newline, self.ends[self.file]));
                }
                // The files before this token hold none.
                while (self.crossesFile(tok.pos)) self.file += 1;
            }
            return self.classify(tok);
        }
    }

    fn synthetic(cat: TokenCat, pos: u32) Token {
        return .{ .cat = cat, .pre = 0, .pos = pos, .len = 0 };
    }

    fn fail(self: *Lexer, e: LexError, pos: u32) Token {
        self.err = e;
        return .{ .cat = .err, .pre = 0, .pos = pos, .len = 0 };
    }

    /// The first token of the file is indented: with a tab, or spaces.
    fn firstLineIndented(self: *Lexer, tok: Token) Token {
        const src = self.base.source;
        var start = tok.pos;
        while (start > 0 and (src[start - 1] == ' ' or src[start - 1] == '\t')) start -= 1;
        if (std.mem.findScalar(u8, src[start..tok.pos], '\t')) |tab| return self.fail(.tab_indent, start + @as(u32, @intCast(tab)));
        return self.fail(.first_line_indented, tok.pos);
    }

    // -------------------------------------------------------------------------
    // Layout
    // -------------------------------------------------------------------------

    /// A newline outside brackets: find the next line with content and
    /// turn its indentation into NEWLINE, INDENT, or OUTDENTs.
    fn lineBreak(self: *Lexer, nl: Token) Token {
        const src = self.base.source;
        var line: u32 = endOf(&self.base, nl);
        while (true) {
            var p = line;
            var tab: ?u32 = null;
            while (p < src.len and (src[p] == ' ' or src[p] == '\t')) : (p += 1) {
                if (src[p] == '\t' and tab == null) tab = p;
            }
            if (p >= src.len) {
                self.base.pos = @intCast(src.len);
                return self.endOfInput(synthetic(.eof, @intCast(src.len)));
            }
            switch (src[p]) {
                '\n' => {
                    line = p + 1;
                    continue;
                },
                '\r' => if (p + 1 < src.len and src[p + 1] == '\n') {
                    line = p + 2;
                    continue;
                },
                '#' => {
                    while (p < src.len and src[p] != '\n') p += 1;
                    line = p;
                    continue;
                },
                else => {},
            }
            if (tab) |t| return self.fail(.tab_indent, t);
            if (self.crossesFile(p)) {
                if (self.nesting > 0) return self.endOfFile();
                self.file += 1;
                while (self.crossesFile(p)) self.file += 1;
                if (p > line) return self.fail(.first_line_indented, @intCast(p));
                // A block of the file before closes; no `else` continues it.
                self.takes_else = @splat(false);
            }
            self.base.pos = line;
            // Back at the closure's own line: the island ends and the
            // bracketed expression continues.
            if (self.inIsland() and p - line <= self.islands[self.island_count - 1].column) {
                self.checkIslandClose(p, p - line);
                return self.closeIsland(p, null) orelse self.produce();
            }
            if (p - line > self.column and self.continuesChain(src, p)) {
                self.base.pos = @intCast(p);
                return self.produce();
            }
            return self.indentTo(p - line, p, nl);
        }
    }

    /// The line at `p`, indented deeper than its statement, starts with
    /// a member access (`.name`) and continues the expression statement
    /// above it. That statement is complete (its last token ends an
    /// operand) and its line opens no block (it has none of the tokens
    /// that open one), and it is not an arm or a member, whose deeper
    /// `.variant` line is the body. Blank and comment lines between two chain lines are skipped
    /// before this is asked, so they do not end the chain.
    fn continuesChain(self: *const Lexer, src: []const u8, p: usize) bool {
        if (src[p] != '.' or p + 1 >= src.len or !isIdentStart(src[p + 1])) return false;
        if (!self.after_value or self.nesting > 0 or self.line_opens) return false;
        return !self.in_members[self.depth] and !self.in_arms[self.depth];
    }

    fn indentTo(self: *Lexer, width: u32, pos: u32, nl: Token) Token {
        if (width > self.column) {
            if (self.depth == max_indent_depth) return self.fail(.indent_too_deep, pos);
            self.levels[self.depth] = self.column;
            self.depth += 1;
            self.column = width;
            self.takes_else[self.depth] = false;
            self.in_arms[self.depth] = self.line_match;
            self.in_members[self.depth] = switch (self.line_head) {
                .obj, .api, .add => true,
                else => false,
            } or switch (self.line_head) {
                .@"enum", .@"error" => true,
                else => false,
            };
            return synthetic(.indent, pos);
        }
        if (width == self.column) {
            self.takes_else[self.depth] = false;
            return nl;
        }

        var closed: u32 = 0;
        while (self.column > width) {
            if (self.depth == 0) return self.fail(.bad_dedent, pos);
            self.depth -= 1;
            self.column = self.levels[self.depth];
            closed += 1;
        }
        if (self.column != width) return self.fail(.bad_dedent, pos);

        self.pending_outdents = closed - 1;
        self.pending_pos = pos;
        if (self.takes_else[self.depth] and self.startsWithElse(pos)) {
            self.pending_newline = false;
        } else {
            self.pending_newline = true;
            self.takes_else[self.depth] = false;
        }
        return synthetic(.outdent, pos);
    }

    /// The line at `pos` starts with `else`, which continues the block
    /// that just closed, so no NEWLINE separates them.
    fn startsWithElse(self: *const Lexer, pos: u32) bool {
        var probe = self.base;
        probe.pos = pos;
        const tok = probe.next();
        return tok.cat == .@"else";
    }

    /// Whether `pos` is past the end of the file being read.
    fn crossesFile(self: *const Lexer, pos: usize) bool {
        return self.file < self.ends.len and pos >= self.ends[self.file];
    }

    /// The file being read ends inside a bracket: the input ends there,
    /// and no token of the next file is read.
    fn endOfFile(self: *Lexer) Token {
        const end = self.ends[self.file];
        self.base.pos = @intCast(self.base.source.len);
        return self.endOfInput(synthetic(.eof, end));
    }

    fn endOfInput(self: *Lexer, eof: Token) Token {
        if (self.depth > 0) {
            self.pending_outdents = self.depth - 1;
            self.pending_pos = eof.pos;
            self.depth = 0;
            self.column = 0;
            return synthetic(.outdent, eof.pos);
        }
        return eof;
    }

    // -------------------------------------------------------------------------
    // Classification
    // -------------------------------------------------------------------------

    fn classify(self: *Lexer, tok: Token) Token {
        if (self.symbol_name) {
            self.symbol_name = false;
            return self.symbolName(tok);
        }
        // The bracket around an island closes on the body's last line:
        // so do the island's blocks. The bracket belongs on a line of its
        // own.
        if ((tok.cat == .rparen or tok.cat == .rbracket) and self.inIsland()) {
            const kind: Layout.Kind = if (self.startsLine(tok)) .closure_indent else .closure_hanging;
            self.recordLayout(.{ .pos = tok.pos, .len = 1, .kind = kind, .column = self.lineIndent(self.brackets[self.nesting - 1]) });
            if (self.closeIsland(tok.pos, tok)) |outdent| return outdent;
        }
        if (tok.cat == .backtick) return self.templateHead(tok);
        if (tok.cat == .rbrace) if (self.slot) |slot| if (self.nesting == slot.nesting) return self.templateText(tok.pos);
        if (self.slot) |slot| if (self.nesting == slot.nesting) if (self.slotError(tok)) |e| return self.fail(e, tok.pos);
        const after_value = self.after_value;
        var out = tok;
        if (tok.cat == .assign and self.slot != null and (self.last_cat == .tpl_head or self.last_cat == .tpl_mid) and tok.pos == self.prev_end) {
            out.cat = .tpl_show;
            return out;
        }
        out.cat = switch (tok.cat) {
            .ident => if (self.misplacedMarker(tok)) |bad| return self.fail(bad.err, bad.pos) else if (self.isMatches(tok)) blk: {
                if (self.misplacedMatches(tok)) |bad| return self.fail(bad.err, bad.pos);
                break :blk .matches;
            } else self.classifyWord(tok),
            // An API object's braces join lines as brackets do.
            .lparen, .lbracket, .lbrace => blk: {
                if (self.nesting == max_nesting) return self.fail(.nesting_too_deep, tok.pos);
                self.brackets[self.nesting] = tok.pos;
                self.nesting += 1;
                break :blk tok.cat;
            },
            .rparen, .rbracket, .rbrace => blk: {
                if (self.nesting > 0) self.nesting -= 1;
                break :blk tok.cat;
            },
            .at => if (self.selfMember(tok)) |err| return self.fail(err, tok.pos) else .ident,
            .dollar => switch (self.classifyDollar(tok)) {
                .cat => |cat| cat,
                .err => |err| return self.fail(err, tok.pos),
            },
            .bar => if (self.isCaptureBar(tok, after_value)) .bar_capture else .bar,
            .and_sym => return self.fail(.and_operator, tok.pos),
            // `||` where an operand starts is an empty closure bar list.
            .or_sym => if (!after_value) blk: {
                self.closed_bars = true;
                break :blk .bar_empty;
            } else return self.fail(if (self.literalFollows()) .or_fallback else .or_operator, tok.pos),
            .slash => if (self.charAfter(tok) == '/' or self.charAfter(tok) == '*') return self.fail(.slash_comment, tok.pos) else .slash,
            .power => return self.fail(.power_operator, tok.pos),
            // `x =!y`: a fixed binding of `y`, or `x = !y`, a write lend?
            .fixed_assign => if (!isBlank(self.charAfter(tok))) return self.fail(.fixed_touch, tok.pos) else tok.cat,
            // `xs[a..]`: an open range ends at the `]`.
            .dotdot => if (self.nextJoined().cat == .rbracket) .dotdot_open else .dotdot,
            .colon => if (self.label_name) .label_colon else switch (self.classifyColon(tok, after_value)) {
                .cat => |cat| cat,
                .err => |err| return self.fail(err.err, err.pos),
            },
            // `get(k) ?? return none`: a jump as the fallback.
            .nullish => if (self.nextIsJump()) .nullish_jump else .nullish,
            .ampersand => if (self.isTaskAmp(tok)) .task_amp else .ampersand,
            // `if f() as a, b`: a `,` after `as name` outside brackets
            // joins the names `as` binds. Inside brackets a `,` after
            // `x as a` separates arguments or elements, unless names and
            // a ternary's `else` follow (`f(a + b if g() as a, b else 0)`).
            .comma => if (self.last_cat == .ident and (self.last2_cat == .as or self.last2_cat == .as_comma) and (self.nesting == 0 or namesThenElse(self.base))) .as_comma else .comma,
            .err => return self.lexError(tok),
            else => if (isKeyword(tok.cat)) self.classifyKeyword(tok) else tok.cat,
        };
        // A jump's label ends at its name: a value after it stands apart
        // (`break $outer -1`, not `break $outer-1`).
        if (self.after_jump_label and tok.pos == self.prev_end and startsOperand(tok.cat)) return self.fail(.label_touch, tok.pos);
        // A prefix sigil touches its operand (`-b`, `<x`, `*T`); `i++`
        // is no increment.
        if (!after_value and isSigil(tok.cat) and isSpace(self.charAfter(tok))) {
            const twice = tok.pos > 0 and self.base.source[tok.pos - 1] == self.base.source[tok.pos];
            if (twice and tok.cat == .plus) return self.fail(.increment, tok.pos - 1);
            if (twice and tok.cat == .minus) return self.fail(.decrement, tok.pos - 1);
            return self.fail(.detached_prefix, tok.pos);
        }
        if (self.layout_count < max_layouts) self.checkSpacing(tok, out.cat, after_value);
        switch (out.cat) {
            .@"if", .@"while", .@"for" => self.takes_else[self.depth] = true,
            else => {},
        }
        switch (out.cat) {
            .fun, .sub, .@"enum", .@"error", .@"if", .@"else", .@"while", .loop, .@"for", .match, .@"test", .raw, .@"extern", .drop, .obj, .api, .add => self.line_opens = true,
            else => {},
        }
        if (out.cat == .match) self.line_match = true;
        if (self.stmtStart() or self.last_cat == .@"pub") {
            self.line_head = out.cat;
            self.head_pos = tok.pos;
        }
        if (out.cat == .post_if) self.guard_pos = tok.pos;
        return out;
    }

    /// Record the first operator whose spacing breaks the rule:
    /// `after_value` says the token follows an operand, so it continues
    /// it (an infix operator, a postfix, a member `.`).
    fn checkSpacing(self: *Lexer, tok: Token, cat: TokenCat, after_value: bool) void {
        const src = self.base.source;
        const before = tok.pos > 0 and isSpaceBefore(src[tok.pos - 1]);
        const after = isSpace(self.charAfter(tok));
        const kind: ?Layout.Kind = switch (cat) {
            .question, .not_sym => if (after_value and before) .postfix else null,
            // A member may start a line inside brackets, continuing a
            // chain from the line before.
            .dot => if (after_value) (if ((before and !self.startsLine(tok)) or after) .member else null) else if (after) .enum_dot else null,
            .dotdot, .dotdot_eq => if (!after_value) (if (after) .range_end else null) else if (before != after) (if (before) .infix_before else .infix_after) else null,
            .dotdot_open => if (after_value and before) .range_end else null,
            .lparen, .lbracket => if (after_value and before and !self.startsLine(tok)) .call_bracket else null,
            else => if (after_value and isInfix(cat) and before != after) (if (before) .infix_before else .infix_after) else null,
        };
        if (kind) |k| self.recordLayout(.{ .pos = tok.pos, .len = endOf(&self.base, tok) - tok.pos, .kind = k });
    }

    fn recordLayout(self: *Lexer, layout: Layout) void {
        if (self.layout_count == max_layouts) return;
        self.layouts[self.layout_count] = layout;
        self.layout_count += 1;
    }

    /// The line at `pos`, `width` deep, ends a closure body laid out in
    /// the innermost island: it starts with the bracket around the body,
    /// at the indentation of the line that opened that bracket.
    fn checkIslandClose(self: *Lexer, pos: u32, width: u32) void {
        const open = self.brackets[self.nesting - 1];
        const closer: u8 = if (self.base.source[open] == '(') ')' else ']';
        const want = self.lineIndent(open);
        if (self.base.source[pos] != closer) {
            self.recordLayout(.{ .pos = pos, .len = 1, .kind = .closure_close, .column = want });
        } else if (width != want) {
            self.recordLayout(.{ .pos = pos, .len = 1, .kind = .closure_indent, .column = want });
        }
    }

    /// Only whitespace stands before `tok` on its line.
    fn startsLine(self: *const Lexer, tok: Token) bool {
        var p = tok.pos;
        while (p > 0) : (p -= 1) switch (self.base.source[p - 1]) {
            ' ', '\t', '\r' => {},
            '\n' => return true,
            else => return false,
        };
        return true;
    }

    /// `catch` before a jump, after any `|e|` (`f() catch return -1`),
    /// is CATCH_JUMP, whose handler takes the rest of the expression;
    /// before `|e|` and the end of the line, CATCH_BLOCK, whose handler
    /// is the block below; any other is CATCH, an operator on `??`'s
    /// level.
    fn catchCat(self: *const Lexer) TokenCat {
        var probe = self.base;
        var t = probe.next();
        var bars = false;
        if (t.cat == .bar) {
            _ = probe.next();
            if (probe.next().cat != .bar) return .@"catch";
            t = probe.next();
            bars = true;
        }
        return switch (t.cat) {
            .@"return", .@"break", .@"continue" => .catch_jump,
            .newline, .comment, .eof => if (bars) .catch_block else .@"catch",
            else => .@"catch",
        };
    }

    fn classifyKeyword(self: *const Lexer, tok: Token) TokenCat {
        const kw = tok.cat;
        if (kw != .@"if") return self.memberName(tok) orelse if (kw == .@"catch") self.catchCat() else kw;
        switch (self.last_cat) {
            .@"return", .@"break", .@"continue", .pass => return .post_if,
            else => {},
        }
        if (self.after_jump_label) return .post_if;
        if (!self.after_value) return .@"if";
        return if (self.elseFollows()) .ternary_if else .post_if;
    }

    fn classifyWord(self: *const Lexer, tok: Token) TokenCat {
        const word = self.base.text(tok);
        // A name before `:` inside ( ) names a keyword argument or a
        // payload field, `new` too (`O(new: 1)`, `.pp(new: x)`).
        if (self.argNameNext(tok)) return .kwarg_name;
        if (std.mem.eql(u8, word, "new")) return if (self.stmtStart() and self.nextIsName()) .new else .ident;
        if (std.mem.eql(u8, word, "of") and self.isFillOf()) return .of;
        if (std.mem.eql(u8, word, "obj")) return if ((self.stmtStart() or self.last_cat == .@"pub") and self.nextIsName()) .obj else .ident;
        // `api` and `add` start a module-level declaration, and are
        // names everywhere else: `user.api`, `!set.add(x)`, `add = 2`.
        if (std.mem.eql(u8, word, "api")) return if (self.moduleDeclStart(true) and self.nextIsName()) .api else .ident;
        if (std.mem.eql(u8, word, "add")) return if (self.moduleDeclStart(true) and self.nextStartsType()) .add else .ident;
        if (isMarker(word)) {
            if (!(self.stmtStart() or self.last_cat == .@"pub") or !self.nextIsFunOrSub()) return .ident;
            return if (word[0] == 'i') .@"inline" else .called;
        }
        // `rarely` alone on its line starts the block it marks.
        if (std.mem.eql(u8, word, "rarely")) return if (self.stmtStart() and self.nextEndsLine()) .rarely else .ident;
        return .ident;
    }

    /// The next token ends the line: a newline, a comment, or the end.
    fn nextEndsLine(self: *const Lexer) bool {
        var probe = self.base;
        return switch (probe.next().cat) {
            .newline, .comment, .eof => true,
            else => false,
        };
    }

    /// The next token is `fun` or `sub`: a function's marker (`inline`,
    /// `called`) stands right before it.
    fn nextIsFunOrSub(self: *const Lexer) bool {
        var probe = self.base;
        const t = probe.next();
        return t.cat == .fun or t.cat == .sub;
    }

    /// A marker `tok` puts where a declaration cannot take it: a second
    /// one (`inline called fun f()`), since a function takes one, the same
    /// one again (`inline inline fun f()`), or one before `pub`
    /// (`inline pub fun f()`), which comes first.
    fn misplacedMarker(self: *const Lexer, tok: Token) ?struct { err: LexError, pos: u32 } {
        if (!isMarker(self.base.text(tok)) or !(self.stmtStart() or self.last_cat == .@"pub")) return null;
        var probe = self.base;
        const second = probe.next();
        const second_marks = second.cat == .ident and isMarker(probe.text(second));
        const t = if (second.cat == .@"pub" or second_marks) probe.next() else second;
        if (t.cat != .fun and t.cat != .sub) return null;
        if (second.cat == .@"pub") return .{ .err = .marker_before_pub, .pos = tok.pos };
        if (!second_marks) return null;
        const same = std.mem.eql(u8, probe.text(second), self.base.text(tok));
        return .{ .err = if (same) .repeated_marker else .two_markers, .pos = second.pos };
    }

    fn isMarker(word: []const u8) bool {
        return std.mem.eql(u8, word, "inline") or std.mem.eql(u8, word, "called");
    }

    /// `matches` after a value tests it against a pattern (`x matches
    /// .ready(r)`); anywhere else it is a name. After `from` and `keeps`,
    /// which the parser reads as words, a name stands.
    fn isMatches(self: *const Lexer, tok: Token) bool {
        if (!self.after_value or !std.mem.eql(u8, self.base.text(tok), "matches")) return false;
        if (self.last_cat != .ident) return true;
        const src = self.base.source;
        var end = self.last_pos;
        while (end < src.len and (std.ascii.isAlphanumeric(src[end]) or src[end] == '_')) end += 1;
        const last = src[self.last_pos..end];
        for ([_][]const u8{ "from", "keeps", "static", "once", "unique", "exact" }) |w| if (std.mem.eql(u8, last, w)) return false;
        return true;
    }

    /// Alternatives after `matches` are a list in parentheses after a
    /// space: `matches(` is never a call, and a pattern followed by `,`
    /// outside brackets, or by `, .name` inside them, is a list missing
    /// its parentheses (`x matches .a, .b`).
    fn misplacedMatches(self: *const Lexer, tok: Token) ?struct { err: LexError, pos: u32 } {
        var probe = self.base;
        var t = probe.next();
        if (t.cat == .lparen) return if (t.pos == endOf(&self.base, tok)) .{ .err = .matches_paren, .pos = tok.pos } else null;
        var depth: u32 = 0;
        while (t.cat != .eof) : (t = probe.next()) switch (t.cat) {
            .lparen => depth += 1,
            .rparen => {
                if (depth == 0) return null;
                depth -= 1;
            },
            .comma => {
                if (depth > 0) continue;
                if (self.nesting == 0 or probe.next().cat == .dot) return .{ .err = .matches_list, .pos = t.pos };
                return null;
            },
            .dot, .ident, .integer, .string_sq, .string_dq, .minus, .dotdot, .dotdot_eq, .question, .true, .false, .colon => {},
            else => if (depth == 0) return null,
        };
        return null;
    }

    /// `of` after a value directly inside [ ] separates a fill literal's
    /// count from its element (`[n of x]`); anywhere else it is a name.
    fn isFillOf(self: *const Lexer) bool {
        return self.after_value and self.nesting > 0 and !self.inIsland() and
            self.base.source[self.brackets[self.nesting - 1]] == '[';
    }

    /// A keyword names a member where nothing else can stand: after
    /// `.`, before `:` inside ( ) (a keyword argument or payload field),
    /// and in a member list before `:` (a field) or after `fun` / `sub`
    /// (a method). After `$` it names a builtin (`$type(x)`).
    fn memberName(self: *const Lexer, tok: Token) ?TokenCat {
        switch (self.last_cat) {
            .dot, .dollar => return .ident,
            .fun, .sub => return if (self.in_members[self.depth]) .ident else null,
            else => {},
        }
        if (self.nextCat() != .colon) return null;
        if (self.inParens()) return if (self.argNameNext(tok)) .kwarg_name else null;
        return if (self.in_members[self.depth] and (self.stmtStart() or self.last_cat == .@"pub")) .ident else null;
    }

    /// `word` names a keyword argument, a payload field, or a parameter:
    /// it stands directly inside ( ) where an argument starts, right
    /// after `(`, `,`, or a closure's opening bar, and a `:` follows it
    /// (`f(a: 1)`, `O(new: 1)`, `K(break : 3)`). A `:` with a space before
    /// it and a name touching it starts a symbol instead (`f(not :a)`).
    fn argNameNext(self: *const Lexer, word: Token) bool {
        if (!self.inParens()) return false;
        switch (self.last_cat) {
            .lparen, .comma, .bar_capture => {},
            else => return false,
        }
        var probe = self.base;
        const colon = probe.next();
        if (colon.cat != .colon) return false;
        if (colon.pos == endOf(&self.base, word)) return true;
        const after = endOf(&probe, colon);
        return after >= self.base.source.len or !isIdentStart(self.base.source[after]);
    }

    /// What a `:` is, decided once, by where it stands:
    ///
    ///   * the step of a `while` header, at the header's bracket depth,
    ///     after a value or a jump (`while i < n : i += 1`,
    ///     `while a ?? break : i += 1`);
    ///   * the `:` of a type, a field, or a keyword argument after a
    ///     value anywhere else (`x: Int`, `f(a: 1)`);
    ///   * a symbol's `:` where an operand starts, touching its name
    ///     (`x = :width`, `:a =>`).
    fn classifyColon(self: *Lexer, tok: Token, after_value: bool) union(enum) { cat: TokenCat, err: struct { err: LexError, pos: u32 } } {
        const jump_end = self.after_jump_label or switch (self.last_cat) {
            .@"return", .@"break", .@"continue" => true,
            else => false,
        };
        if (self.while_header == self.nesting and (after_value or jump_end)) return .{ .cat = .step_colon };
        if (after_value or self.last_cat == .kwarg_name) return .{ .cat = .colon };
        const end = endOf(&self.base, tok);
        const src = self.base.source;
        const touches = end < src.len and isIdentStart(src[end]);
        if (!touches) return .{ .err = .{ .err = if (end >= src.len or isBlank(src[end])) .symbol_detached else .symbol_name, .pos = tok.pos } };
        self.symbol_name = true;
        return .{ .cat = .symbol_colon };
    }

    /// The name after a symbol's `:`, a keyword too (`:if`): a word,
    /// then runs of `-` or `.` each followed by a letter, digit, or `_`
    /// (`:content-type`, `:utf-8`, `:a.b`). It stops at `..`, at a `-`
    /// or `.` with no name character after it, and at a space.
    fn symbolName(self: *Lexer, tok: Token) Token {
        const src = self.base.source;
        var end: usize = endOf(&self.base, tok);
        while (end + 1 < src.len and (src[end] == '-' or src[end] == '.') and isIdentCont(src[end + 1])) {
            end += 2;
            while (end < src.len and isIdentCont(src[end])) end += 1;
        }
        if (end - tok.pos >= std.math.maxInt(u16)) return self.fail(.symbol_long, tok.pos);
        self.base.pos = @intCast(end);
        var out = tok;
        out.cat = .ident;
        out.len = @intCast(end - tok.pos);
        return out;
    }

    /// `@` is self, a name, and `@name` its member `name`: an
    /// `@` touching a name is followed by a `.` before it, which the
    /// next call returns (`member_dot`). Self's member is never written
    /// `@.name`.
    fn selfMember(self: *Lexer, at: Token) ?LexError {
        var probe = self.base;
        const after = probe.next();
        if (after.pos != endOf(&self.base, at)) return null;
        if (after.cat == .dot) return .self_dot;
        if (isWord(after.cat)) self.member_dot = after.pos;
        return null;
    }

    /// `$name(...)` is a builtin call, anywhere: the `$` touches the
    /// name, and the name the `(`. Any other `$name` is a label: declared
    /// where a statement that takes one starts, its `:` touching the name
    /// (`$outer: for`, or `$outer:` on a line of its own over the block
    /// it names), and named after `break` or `continue` (`break $outer`,
    /// `break $outer (x)`, which leaves `outer` with the value `(x)`).
    fn classifyDollar(self: *const Lexer, dollar: Token) union(enum) { cat: TokenCat, err: LexError } {
        var probe = self.base;
        const name = probe.next();
        const after = probe.next();
        if (!isWord(name.cat) or name.pos != endOf(&self.base, dollar)) return .{ .err = .dollar_detached };
        const touches = after.pos == endOf(&probe, name);
        if (after.cat == .lparen and touches) return .{ .cat = .dollar };
        const jump = isLabelJump(self.last_cat);
        // A `loop` a binding or `return` takes may be labeled:
        // `r = $found: loop`.
        const value_loop = switch (self.last_cat) {
            .assign, .fixed_assign, .@"return" => after.cat == .colon and touches and probe.next().cat == .loop,
            else => false,
        };
        if (!jump and !value_loop and !self.labelStart()) return .{ .err = .dollar_stray };
        if (name.cat != .ident) return .{ .err = .label_keyword };
        if (!jump and (after.cat != .colon or !touches)) return .{ .err = .label_decl };
        return .{ .cat = .label };
    }

    /// The character right after `tok`, or 0 at the end of the source.
    fn charAfter(self: *const Lexer, tok: Token) u8 {
        const end = endOf(&self.base, tok);
        return if (end < self.base.source.len) self.base.source[end] else 0;
    }

    /// A `|` that starts an operand opens a closure's bar list:
    /// `entry (, entry)* [,]` and a closing bar. An entry is a sigiled
    /// capture (`+x`, `<x`, `~x`, `?x`, `!x`) or a parameter name with
    /// an optional type (`a`, `a: Int`, `f: *fun(Int) -> Int`). The
    /// closing bar is the one this probe finds.
    fn isCaptureBar(self: *Lexer, tok: Token, after_value: bool) bool {
        if (self.capture_close) |close| if (close == tok.pos) {
            self.capture_close = null;
            self.closed_bars = true;
            return true;
        };
        if (after_value) return false;
        var probe = self.base;
        while (true) {
            var t = probe.next();
            if (t.cat == .plus or t.cat == .lt or t.cat == .tilde or t.cat == .question or t.cat == .not_sym) t = probe.next();
            // A keyword entry still makes a bar list, so that the parser
            // reports the keyword (`|when: Int|`). Self, `@`, is a
            // name (`|?@|`).
            if (!isWord(t.cat) and t.cat != .at) return true;
            var sep = probe.next();
            // A capture's place: `@name`, then `.name` steps, and an
            // index or call the Parser wrapper rejects (`|?xs[0]|`).
            if (t.cat == .at and isWord(sep.cat) and sep.pos == t.pos + t.len) sep = probe.next();
            while (true) switch (sep.cat) {
                .dot => {
                    if (!isWord(probe.next().cat)) return true;
                    sep = probe.next();
                },
                .lbracket, .lparen => {
                    var depth: u32 = 1;
                    while (depth > 0) {
                        const b = probe.next();
                        switch (b.cat) {
                            .lbracket, .lparen => depth += 1,
                            .rbracket, .rparen => depth -= 1,
                            .eof, .newline => return true,
                            else => {},
                        }
                    }
                    sep = probe.next();
                },
                else => break,
            };
            if (sep.cat == .colon) sep = skipType(&probe) orelse return true;
            switch (sep.cat) {
                .bar => {
                    self.capture_close = sep.pos;
                    return true;
                },
                .comma => {
                    var after = probe;
                    const close = after.next();
                    if (close.cat == .bar) {
                        self.capture_close = close.pos;
                        return true;
                    }
                },
                else => return true,
            }
        }
    }

    /// Skip a parameter type in a bar list; returns the token after it
    /// (a `,` or `|` outside brackets), or null if the tokens cannot be a
    /// type.
    fn skipType(probe: *BaseLexer) ?Token {
        var depth: u32 = 0;
        while (true) {
            const t = probe.next();
            switch (t.cat) {
                // An API object's braces, `?{Shape + Print}`, nest as
                // brackets do.
                .lparen, .lbracket, .lbrace => depth += 1,
                .rparen, .rbracket, .rbrace => {
                    if (depth == 0) return null;
                    depth -= 1;
                },
                .comma, .bar => if (depth == 0) return t,
                .ident, .integer, .dot, .question, .not_sym, .star, .tilde, .caret, .arrow => {},
                // Arithmetic in an array size: `[N + 1]Int`.
                .plus, .minus, .slash, .percent => if (depth == 0) return null,
                else => if (!isKeyword(t.cat)) return null,
            }
        }
    }

    /// Scan ahead on the current logical line for an `else` at this
    /// nesting level (the ternary form `a if c else b`). A `,` between
    /// the names `as` binds (`if f() as a, b else 0`) goes on.
    fn elseFollows(self: *const Lexer) bool {
        var probe = self.base;
        var depth: u32 = 0;
        var prev: TokenCat = .eof;
        var names = false;
        while (true) {
            const t = probe.next();
            switch (t.cat) {
                .eof => return false,
                .newline => if (depth == 0 and (self.nesting == 0 or self.inIsland())) return false,
                .lparen, .lbracket => depth += 1,
                .rparen, .rbracket => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                .comma => if (depth == 0 and !(names and prev == .ident and namesThenElse(probe))) return false,
                .@"else" => if (depth == 0) return true,
                else => {},
            }
            names = switch (t.cat) {
                .ident => prev == .as or (names and prev == .comma),
                .comma => names,
                else => false,
            };
            prev = t.cat;
        }
    }

    /// Whether the rest of the names `as` binds and then a ternary's
    /// `else` follow the `,` `from` stands after: `b else` or `b, c else`.
    fn namesThenElse(from: BaseLexer) bool {
        var probe = from;
        while (true) {
            var t = probe.next();
            while (t.cat == .newline) t = probe.next();
            if (t.cat != .ident) return false;
            t = probe.next();
            while (t.cat == .newline) t = probe.next();
            switch (t.cat) {
                .comma => {},
                .@"else" => return true,
                else => return false,
            }
        }
    }

    /// A statement starts here: at the start of a line, after `=>`,
    /// `defer`, or `errdefer`, or after a statement's label (`$outer:`).
    fn stmtStart(self: *const Lexer) bool {
        return self.after_label or switch (self.last_cat) {
            .newline, .indent, .outdent, .eof, .fat_arrow, .@"defer", .@"errdefer" => true,
            else => false,
        };
    }

    /// A statement that may take a label starts here: at the start of a
    /// line, or after another label. The statement after `=>`, `defer`,
    /// or `errdefer` takes none.
    fn labelStart(self: *const Lexer) bool {
        return self.after_label or switch (self.last_cat) {
            .newline, .indent, .outdent, .eof => true,
            else => false,
        };
    }

    /// Directly inside ( ), not in a closure body laid out there.
    fn inParens(self: *const Lexer) bool {
        return self.nesting > 0 and !self.inIsland() and self.base.source[self.brackets[self.nesting - 1]] == '(';
    }

    fn nextCat(self: *const Lexer) TokenCat {
        var probe = self.base;
        return probe.next().cat;
    }

    /// The next token, past comments, `\` line joins, and line breaks
    /// where they are whitespace (inside brackets).
    fn nextJoined(self: *const Lexer) Token {
        var probe = self.base;
        const joins = self.nesting > 0 and !self.inIsland();
        while (true) {
            const t = probe.next();
            switch (t.cat) {
                .comment, .skip => continue,
                .newline => if (!joins) return t,
                else => return t,
            }
        }
    }

    /// `f(x)&`: a `&` that touches the `)` before it, with no operand
    /// touching it on the right, makes the call a task. Any other `&` is
    /// bitwise and, whose spacing is the same on both sides (`a & b`,
    /// `f()&b`).
    fn isTaskAmp(self: *const Lexer, tok: Token) bool {
        if (self.last_cat != .rparen or tok.pos != self.prev_end) return false;
        const c = self.charAfter(tok);
        return c == 0 or isSpaceBefore(c) or c == ')' or c == ']' or c == ',' or c == '#';
    }

    /// The next token is `return`, `break`, or `continue`.
    fn nextIsJump(self: *const Lexer) bool {
        return switch (self.nextJoined().cat) {
            .@"return", .@"break", .@"continue" => true,
            else => false,
        };
    }

    /// A literal comes next: a number, a string, or an array.
    fn literalFollows(self: *const Lexer) bool {
        return switch (self.nextJoined().cat) {
            .integer, .real, .string_sq, .string_dq, .lbracket => true,
            else => false,
        };
    }

    /// A declaration at the module's margin starts here: at the start of a
    /// line outside any block or bracket, or after its `pub` when
    /// `after_pub`.
    fn moduleDeclStart(self: *const Lexer, after_pub: bool) bool {
        if (self.depth != 0 or self.nesting != 0) return false;
        return (self.stmtStart() and !self.after_label) or (after_pub and self.last_cat == .@"pub");
    }

    /// A type starts next: a name, or a sigil or bracket a type may start
    /// with (`add ?Square: Shape` parses, to be rejected).
    fn nextStartsType(self: *const Lexer) bool {
        var probe = self.base;
        const t = probe.next();
        return switch (t.cat) {
            .ident => !std.mem.eql(u8, probe.text(t), "new"),
            .question, .not_sym, .star, .caret, .tilde, .lbracket, .lparen => true,
            else => false,
        };
    }

    fn nextIsName(self: *const Lexer) bool {
        var probe = self.base;
        const t = probe.next();
        return t.cat == .ident and !std.mem.eql(u8, probe.text(t), "new");
    }

    // -------------------------------------------------------------------------
    // Templates
    // -------------------------------------------------------------------------

    /// What may not stand at the top of a slot, outside its own
    /// brackets: a `:` (formatting is a method's), a `=` apart from the
    /// `{` (`{ =x}`) or last (`{x=}`).
    fn slotError(self: *const Lexer, tok: Token) ?LexError {
        return switch (tok.cat) {
            .colon => if (self.symbolColonAt(tok)) null else .slot_colon,
            .assign => if (self.last_cat == .tpl_head or self.last_cat == .tpl_mid) (if (tok.pos == self.prev_end) null else .slot_show_space) else if (self.closesSlot(tok)) .slot_show_after else null,
            else => null,
        };
    }

    /// A `:` touching a name where an operand starts: a symbol's
    /// (`{x ?? :a}`), not a format's.
    fn symbolColonAt(self: *const Lexer, tok: Token) bool {
        if (self.after_value) return false;
        const end = tok.pos + 1;
        const src = self.base.source;
        return end < src.len and isIdentStart(src[end]);
    }

    /// Only spaces stand between `tok` and a `}`.
    fn closesSlot(self: *const Lexer, tok: Token) bool {
        const src = self.base.source;
        var p = endOf(&self.base, tok);
        while (p < src.len and src[p] == ' ') p += 1;
        return p < src.len and src[p] == '}';
    }

    /// A backtick opens a template: its text up to the first slot's `{`
    /// is the head (`` `a{ ``).
    fn templateHead(self: *Lexer, tok: Token) Token {
        const src = self.base.source;
        if (self.slot != null) return self.fail(.slot_template, tok.pos);
        if (tok.pos > 0 and src[tok.pos - 1] == '`') return self.fail(.template_ticks, tok.pos - 1);
        if (tok.pos + 1 < src.len and src[tok.pos + 1] == '`') {
            const run = tok.pos + 2 < src.len and src[tok.pos + 2] == '`';
            return self.fail(if (run) .template_ticks else .template_empty, tok.pos);
        }
        if (tok.pos > 0 and isIdentCont(src[tok.pos - 1])) return self.fail(.template_tagged, tok.pos);
        return self.templatePiece(tok.pos, .tpl_head);
    }

    /// A slot's `}` at `pos`: the template's text goes on to the next
    /// slot's `{` (`}b{`) or to its closing backtick (`` }c` ``).
    fn templateText(self: *Lexer, pos: u32) Token {
        return self.templatePiece(pos, .tpl_mid);
    }

    /// The piece of text starting at `start` (a backtick or a slot's
    /// `}`), through the `{` that opens the next slot or the closing
    /// backtick. Escapes are checked with a string's (typecheck); here
    /// the piece must end on its line and hold no raw control.
    fn templatePiece(self: *Lexer, start: u32, kind: TokenCat) Token {
        const src = self.base.source;
        var p: u32 = start + 1;
        while (p < src.len) {
            const c = src[p];
            switch (c) {
                '\\' => {
                    if (p + 1 >= src.len or src[p + 1] == '\n' or src[p + 1] == '\r') return self.fail(.template_join, p);
                    if (src[p + 1] < 0x20 or src[p + 1] == 0x7f) return self.fail(.template_control, p + 1);
                    // `\u{e9}`: its braces are the escape's, not a slot's.
                    if (src[p + 1] == 'u' and p + 2 < src.len and src[p + 2] == '{') {
                        var q = p + 3;
                        while (q < src.len and std.ascii.isHex(src[q])) q += 1;
                        if (q < src.len and src[q] == '}') {
                            p = q + 1;
                            continue;
                        }
                    }
                    p += 2;
                    continue;
                },
                '{' => {
                    if (p + 1 - start >= std.math.maxInt(u16)) return self.fail(.template_long, start);
                    self.base.pos = p + 1;
                    if (p + 1 < src.len and src[p + 1] == '}') return self.fail(.slot_empty, p);
                    if (p + 2 < src.len and src[p + 1] == '=' and src[p + 2] == '}') return self.fail(.slot_empty, p);
                    self.slot = .{ .open = p, .nesting = self.nesting };
                    return .{ .cat = kind, .pre = 0, .pos = start, .len = @intCast(p + 1 - start) };
                },
                '`' => {
                    if (kind == .tpl_head) return self.fail(.template_no_slot, start);
                    if (p + 1 - start >= std.math.maxInt(u16)) return self.fail(.template_long, start);
                    self.base.pos = p + 1;
                    self.slot = null;
                    return .{ .cat = .tpl_tail, .pre = 0, .pos = start, .len = @intCast(p + 1 - start) };
                },
                '}' => return self.fail(.template_brace, p),
                '\n', '\r' => return self.fail(.template_unclosed, if (kind == .tpl_head) start else self.templateStart(start)),
                else => {
                    if (c < 0x20 or c == 0x7f) return self.fail(.template_control, p);
                    if (bidiAt(src, p)) return self.fail(.template_bidi, p);
                },
            }
            p += 1;
        }
        return self.fail(.template_unclosed, if (kind == .tpl_head) start else self.templateStart(start));
    }

    /// The opening backtick of the template whose text goes on at `pos`:
    /// the last one before it on its line.
    fn templateStart(self: *const Lexer, pos: u32) u32 {
        const src = self.base.source;
        var p = pos;
        while (p > 0 and src[p - 1] != '\n') : (p -= 1) {
            if (src[p - 1] == '`') return p - 1;
        }
        return pos;
    }

    /// Why the grammar produced an `err` token.
    fn lexError(self: *Lexer, tok: Token) Token {
        const t = self.base.text(tok);
        return switch (t[0]) {
            '"', '\'' => self.stringError(tok.pos),
            '0'...'9' => self.fail(if (t.len > 1 and t[0] == '0' and std.mem.findScalar(u8, "XBO", t[1]) != null)
                .radix_case
            else if (t.len > 1 and t[0] == '0' and (std.ascii.isDigit(t[1]) or t[1] == '_'))
                .leading_zero
            else
                .bad_number, tok.pos),
            '\r' => self.fail(.lone_cr, tok.pos),
            ';' => self.fail(.semicolon, tok.pos),
            else => self.fail(.bad_char, tok.pos),
        };
    }

    /// A string starting at `open` that does not lex: a control character
    /// inside it, or no closing quote on its line.
    fn stringError(self: *Lexer, open: u32) Token {
        const src = self.base.source;
        const quote = src[open];
        var p = open + 1;
        while (p < src.len and src[p] != '\n') : (p += 1) {
            if (quote == '"' and src[p] == '\\' and p + 1 < src.len and src[p + 1] != '\n') {
                p += 1; // the escaped character
            } else if (src[p] == quote) {
                if (quote == '"' or p + 1 == src.len or src[p + 1] != quote) break;
                p += 1; // `''` in a single-quoted string
                continue;
            }
            const at_line_end = src[p] == '\r' and p + 1 < src.len and src[p + 1] == '\n';
            if ((src[p] < 0x20 or src[p] == 0x7f) and !at_line_end) return self.fail(.control_in_string, p);
        }
        return self.fail(.unterminated_string, open);
    }
};

/// Token categories that end an operand: a `(` / `[` / `?` / `!` or
/// another shared character after one of these continues it, as a
/// call, an index, a suffix, or an infix operator. The keyword `error`
/// ends one as the type of any error, so `error?` is its optional.
fn isValue(cat: TokenCat) bool {
    return switch (cat) {
        .ident,
        .@"error",
        .integer,
        .real,
        .string_sq,
        .string_dq,
        .true,
        .false,
        .rparen,
        .rbracket,
        .rbrace,
        .task_amp,
        .tpl_tail,
        => true,
        else => false,
    };
}

/// The characters that start an operand as a prefix sigil.
/// A token that starts an operand and does not continue a name: what may
/// not touch a jump's label (`break $outer-1`, `break $outer.red`).
fn startsOperand(cat: TokenCat) bool {
    return isSigil(cat) or switch (cat) {
        .lparen, .lbracket, .dot, .dotdot, .dotdot_eq, .bar, .or_sym, .at, .dollar, .string_sq, .string_dq, .tpl_head => true,
        else => false,
    };
}

/// `break` or `continue`: the jumps that name a label.
fn isLabelJump(cat: TokenCat) bool {
    return cat == .@"break" or cat == .@"continue";
}

fn isSigil(cat: TokenCat) bool {
    return switch (cat) {
        .minus, .lt, .gt, .plus, .star, .question, .not_sym, .tilde, .caret => true,
        else => false,
    };
}

/// The infix operators, whose spacing is the same on both sides.
fn isInfix(cat: TokenCat) bool {
    return switch (cat) {
        .plus, .minus, .star, .slash, .percent, .plus_wrap, .minus_wrap, .star_wrap, .plus_sat, .minus_sat => true,
        .eq, .ne, .lt, .gt, .le, .ge, .nullish, .nullish_jump => true,
        .bar, .ampersand, .caret, .lshift, .lshift_wrap, .rshift => true,
        .assign, .fixed_assign, .plus_assign, .minus_assign, .star_assign, .slash_assign, .percent_assign => true,
        .amp_assign, .bar_assign, .caret_assign, .lshift_assign, .lshift_wrap_assign, .rshift_assign => true,
        .plus_wrap_assign, .minus_wrap_assign, .star_wrap_assign, .plus_sat_assign, .minus_sat_assign => true,
        else => false,
    };
}

/// Whitespace before a token.
fn isSpaceBefore(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

/// A space or a tab: what must follow `=!`.
fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Whitespace, or the end of the line or source, after a token.
fn isSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', '\\', '#', 0 => true,
        else => false,
    };
}

/// A bidirectional control character starts at `p` (U+061C, U+200E,
/// U+200F, U+202A to U+202E, U+2066 to U+2069): written raw it can make
/// text read otherwise than it runs, so a template takes it only as an
/// escape.
fn bidiAt(src: []const u8, p: usize) bool {
    if (p + 1 < src.len and src[p] == 0xD8 and src[p + 1] == 0x9C) return true;
    if (p + 2 >= src.len or src[p] != 0xE2) return false;
    const b = src[p + 1];
    const c = src[p + 2];
    return (b == 0x80 and (c == 0x8E or c == 0x8F or (c >= 0xAA and c <= 0xAE))) or (b == 0x81 and c >= 0xA6 and c <= 0xA9);
}

pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

/// The name that starts at `at`.
fn identAt(src: []const u8, at: usize) []const u8 {
    var e = at;
    while (e < src.len and isIdentCont(src[e])) e += 1;
    return src[at..e];
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

// =============================================================================
// Parser — post-parse rewrites and diagnostics over the generated BaseParser
// =============================================================================

/// The names of the leaves a rewrite builds that no source text holds.
const HiddenName = enum(u16) {
    /// The method every iterator declares.
    next = 0,
    /// The binding that holds a loop's source. It has a space, so no
    /// program can write it, and a message that names it says what it is.
    iterator = 1,
    /// The variable of a bare `for`, which binds nothing: `for xs` is
    /// `for _ in xs`.
    discard = 2,
    /// The type of each byte of a byte string, `[U8(65), U8(66)]`.
    u8 = 3,
    /// The method a wait calls: `>t` is `<t.wait()`, on a task or a set
    /// of tasks (`isWaitCall`).
    wait = 4,
    /// The module of the built-in types written in Rig (`Map`, `Set`),
    /// which a module that names one uses (`Parser.preludeUse`).
    builtin_module = 5,
    /// The values of a `matches` that holds in a Bool position: the arms
    /// of the `match` it is (`Parser.boolMatch`).
    true_value = 6,
    false_value = 7,
    /// The hidden bindings of a chain's loop (`Parser.desugarChains`), each
    /// with a space, so no program writes one.
    chain_source = 8,
    chain_item = 9,
    chain_value = 10,
    chain_best = 11,
    chain_key = 12,
    chain_first = 13,
    chain_next = 14,
    zero_value = 15,
    one_value = 16,
    none_value = 17,
    list_type = 18,
    push_name = 19,
    chain_index = 20,
    int_type = 21,
    len_name = 22,
    range_from = 23,
    range_to = 24,
    /// The index of the first item a `min` over a List's made values
    /// took, so the loop over the rest starts after it.
    chain_at = 25,
    /// An inclusive range's cursor has taken its end, which may be its
    /// type's largest value, past which it cannot step.
    chain_done = 26,
    /// The hidden bindings of a chain's stages, three a stage
    /// (`Parser.stageName`), `max_chain_stages` of them: the names past
    /// the last one above.
    _,

    fn text(self: HiddenName) []const u8 {
        return switch (self) {
            .next => "next",
            .iterator => "for iterator",
            .discard => "_",
            .u8 => "U8",
            .wait => "wait",
            .builtin_module => builtin_binding_name,
            .true_value => "true",
            .false_value => "false",
            .chain_source => "chain source",
            .chain_item => "chain item",
            .chain_value => "chain value",
            .chain_best => "chain best",
            .chain_key => "chain key",
            .chain_first => "chain first",
            .chain_next => "chain next",
            .zero_value => "0",
            .one_value => "1",
            .none_value => "none",
            .list_type => "List",
            .push_name => "push",
            .chain_index => "chain index",
            .int_type => "Int",
            .len_name => "len",
            .range_from => "chain from",
            .range_to => "chain to",
            .chain_at => "chain at",
            .chain_done => "chain done",
            _ => stage_texts[@intFromEnum(self) - first_stage],
        };
    }

    /// The first stage's names follow the last named one.
    const first_stage = @intFromEnum(HiddenName.chain_done) + 1;

    /// `chain stage n`, `chain count n`, and `chain limit n` of each stage.
    const stage_texts = blk: {
        @setEvalBranchQuota(100_000);
        var texts: [3 * max_chain_stages][]const u8 = undefined;
        for (0..max_chain_stages) |i| for ([_][]const u8{ "stage", "count", "limit" }, 0..) |w, j| {
            texts[3 * i + j] = std.fmt.comptimePrint("chain {s} {d}", .{ w, i + 1 });
        };
        break :blk texts;
    };

    comptime {
        std.debug.assert(first_stage + stage_texts.len <= 0x100);
    }
};

/// The stages a chain may have: each binds three hidden names, and
/// hidden names have 256 ids in all (`hidden_id_base`).
pub const max_chain_stages = 64;

/// Whether a pattern tests an optional payload field, `r?` or `none`,
/// in any alternative: its arm may not run for the values of its
/// variant, as a guarded arm may not.
pub fn patternTests(pattern: Sexp) bool {
    if (pattern.isKind(.alt_pattern)) {
        for (ir.AltPattern.alts(pattern)) |alt| if (patternTests(alt)) return true;
        return false;
    }
    if (!pattern.isKind(.variant_pattern)) return false;
    for (ir.VariantPattern.bindings(pattern)) |b| {
        const v = if (b.isKind(.kwarg)) ir.Kwarg.value(b) else b;
        if (v.isKind(.some_pattern) or v.isKind(.none_pattern)) return true;
    }
    return false;
}

/// Whether a pattern after `matches` binds a name: a payload field it
/// names (`.ready(r)`, `.ready(r?)`), in any alternative.
pub fn matchesBinds(source: []const u8, pattern: Sexp) bool {
    var count: CountBinds = .{};
    eachPatternBinding(source, pattern, &count);
    return count.n > 0;
}

const CountBinds = struct {
    n: usize = 0,
    fn bind(self: *CountBinds, _: Sexp) void {
        self.n += 1;
    }
};

/// Call `v.bind(leaf)` for each name leaf a pattern binds, `_` aside:
/// its payload fields', in every alternative.
pub fn eachPatternBinding(source: []const u8, pattern: Sexp, v: anytype) void {
    if (pattern.isKind(.alt_pattern)) {
        for (ir.AltPattern.alts(pattern)) |alt| eachPatternBinding(source, alt, v);
        return;
    }
    if (!pattern.isKind(.variant_pattern)) return;
    for (ir.VariantPattern.bindings(pattern)) |b| {
        var leaf = if (b.isKind(.kwarg)) ir.Kwarg.value(b) else b;
        if (leaf.isKind(.some_pattern)) leaf = ir.SomePattern.name(leaf);
        if (leaf != .src) continue;
        if (std.mem.eql(u8, leafText(source, leaf.src), "_")) continue;
        v.bind(leaf);
    }
}

fn bindingLeaves(source: []const u8, pattern: Sexp, out: *std.ArrayList(Sexp), a: std.mem.Allocator) !void {
    const Collect = struct {
        out: *std.ArrayList(Sexp),
        a: std.mem.Allocator,
        failed: bool = false,
        fn bind(self: *@This(), leaf: Sexp) void {
            self.out.append(self.a, leaf) catch {
                self.failed = true;
            };
        }
    };
    var c: Collect = .{ .out = out, .a = a };
    eachPatternBinding(source, pattern, &c);
    if (c.failed) return error.OutOfMemory;
}

/// Whether `node` is a wait, `>t`: the call the wrapper builds for it,
/// whose method is the hidden `wait` (`Parser.waitCall`).
pub fn isWaitCall(node: Sexp) bool {
    return node.isKind(.call) and isWaitMember(ir.Call.callee(node));
}

/// Whether `member` is the callee of a wait, `>t`: its name is the
/// hidden `wait`.
pub fn isWaitMember(member: Sexp) bool {
    if (!member.isKind(.member)) return false;
    const name = ir.Member.name(member);
    return name == .src and name.src.id == hidden_id_base + @intFromEnum(HiddenName.wait);
}

/// The name of the module of the built-in types written in Rig, the
/// prelude: every program has it, so none imports it (`use std.prelude`
/// is rejected).
pub const builtin_module_name = "prelude";

/// The name every program's hidden import of the prelude binds, which
/// no program can write: names starting `__rig` are the compiler's, so
/// a program's own `prelude` never meets it.
pub const builtin_binding_name = "__rig_prelude";

/// The built-in types written in Rig, in `std/prelude.rig`: a
/// program names them with no import, and its own declaration of one
/// hides it.
/// Each has a bit of `Parser.prelude_names`.
const builtin_type_names = std.StaticStringMap(u16).initComptime(.{
    .{ "Map", 1 << 0 },        .{ "Set", 1 << 1 },        .{ "Item", 1 << 2 },        .{ "Items", 1 << 3 },
    .{ "Keys", 1 << 4 },       .{ "Values", 1 << 5 },     .{ "Members", 1 << 6 },     .{ "HashMap", 1 << 7 },
    .{ "HashSet", 1 << 8 },    .{ "HashItems", 1 << 9 },  .{ "HashKeys", 1 << 10 },   .{ "HashValues", 1 << 11 },
    .{ "HashMembers", 1 << 12 }, .{ "Lanes", 1 << 13 },
});

/// The bit of `Parser.prelude_names` that says a module names the
/// built-in type `name`, or 0 when `name` is none.
pub fn builtinTypeBit(name: []const u8) u16 {
    return builtin_type_names.get(name) orelse 0;
}

/// Whether `leaf` is the hidden name of the module of the built-in types
/// written in Rig (`Parser.preludeUse`).
pub fn isBuiltinModuleLeaf(leaf: Sexp) bool {
    return leaf == .src and leaf.src.id == hidden_id_base + @intFromEnum(HiddenName.builtin_module);
}

/// The name of the binding that holds a `for` loop's source.
pub fn hiddenIteratorName() []const u8 {
    return HiddenName.iterator.text();
}

/// The last position a hidden leaf takes (`Parser.hiddenPos`): the two
/// above it are sema's sentinels (`sema.imported_decl_pos`), and a leaf
/// there ends with no overflow.
pub const last_hidden_pos: u32 = std.math.maxInt(u32) - 2;

/// A leaf for a name no source text holds, at `pos` inside the `for`
/// keyword (which holds no leaf); its `id` tells `leafText` which name.
fn hiddenLeaf(pos: u32, name: HiddenName) Sexp {
    return .{ .src = .{ .pos = pos, .len = 1, .id = hidden_id_base + @intFromEnum(name) } };
}

/// The integer leaf of byte `value`, which spans `len` bytes at `pos`
/// (a string literal where a `U8` goes, or one byte of one where a
/// `[N]U8` goes) and reads as its decimal value.
fn byteLeaf(pos: u32, len: u16, value: u8) Sexp {
    return .{ .src = .{ .pos = pos, .len = len, .id = byte_id_base + value } };
}

/// Leaf ids from here to `hidden_id_base` are bytes (`byteLeaf`).
const byte_id_base: u16 = 0xFE00;

/// The id of the name of a capture of a field path (`|?p.a|`), whose leaf
/// spans the path from its sigil, so that it holds a position no other
/// leaf does (the path's root holds its own), and reads as the path.
const path_capture_id: u16 = byte_id_base - 1;

/// Whether `leaf` names a capture of a field path, `|?@template|`: the
/// capture's value is then the lend it makes (`Parser.capturePlace`).
pub fn isPathCapture(leaf: Sexp) bool {
    return leaf == .src and leaf.src.id == path_capture_id;
}

/// Each byte's value in decimal, the text of its leaf.
const byte_texts = blk: {
    @setEvalBranchQuota(100_000);
    var texts: [256][]const u8 = undefined;
    for (&texts, 0..) |*t, i| t.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk texts;
};

/// Whether `leaf` is a name a rewrite built (`hiddenLeaf`), such as the
/// `next` a `for` over an iterator calls.
pub fn isHiddenLeaf(leaf: Sexp) bool {
    return leaf == .src and leaf.src.id >= hidden_id_base;
}

/// Leaf ids from here are hidden names; the lexer's are keyword ordinals.
const hidden_id_base: u16 = 0xFF00;

/// The built-in APIs a bound or a type's header names (docs/design/apis.md,
/// Stage 2). The first five are facts the compiler derives from a type's
/// parts; `Eq`, `Hash`, `Ord`, and `Print` a type may give a meaning of
/// its own by naming them on its header; the number APIs only the
/// built-in numbers provide.
pub const Api = enum {
    Copy,
    Clone,
    Owned,
    Sends,
    Syncs,
    Eq,
    Hash,
    Ord,
    Print,
    Num,
    Integer,
    Signed,
    /// What a `for` loop walks: a type that declares `next(!@) -> T?`,
    /// whose `Item` is `T` (`sema.iterItem`); derived, never named on a
    /// header.
    Iter,

    /// The API a name spells, or null.
    pub fn named(text: []const u8) ?Api {
        return std.meta.stringToEnum(Api, text);
    }
};

/// The text of a leaf: the source it spans, or its name when the rewrite
/// built it (`hiddenLeaf`). Every pass reads a name through this.
pub fn leafText(source: []const u8, leaf: parser.Src) []const u8 {
    if (leaf.id >= hidden_id_base) return @as(HiddenName, @enumFromInt(leaf.id - hidden_id_base)).text();
    if (leaf.id >= byte_id_base) return byte_texts[leaf.id - byte_id_base];
    if (leaf.id == path_capture_id) return diag.textBetween(source, leaf.pos + 1, leafEnd(source, leaf));
    return diag.textBetween(source, leaf.pos, leafEnd(source, leaf));
}

/// Where a leaf's text ends: `pos + len`, and for a leaf of a token over
/// 65534 bytes (its `len` is 65535, `@longtokens`) the end of the token
/// the generated lexer scans from its start. That lexer keeps no state
/// between tokens, and the wrapper builds no long token, so this is the
/// end the parser kept for the token (`Parser.parseTree` checks it).
/// Every end of a leaf is read here.
pub fn leafEnd(source: []const u8, leaf: parser.Src) u32 {
    if (leaf.len < std.math.maxInt(u16) or leaf.pos >= source.len) return leaf.pos + leaf.len;
    var lx = BaseLexer.init(source);
    lx.pos = leaf.pos;
    return endOf(&lx, lx.next());
}

/// `sexp`'s span as far as its leaves tell. Keywords and punctuation are
/// not leaves, so this is a fallback for trees without the parser's
/// spans; it is empty at 0 for a node without leaves.
pub fn leafSpan(source: []const u8, sexp: Sexp) diag.Span {
    switch (sexp) {
        .src => |s| return .{ .start = s.pos, .end = leafEnd(source, s) },
        .list => {
            var out: ?diag.Span = null;
            for (sexp.items()) |c| {
                const cs = leafSpan(source, c);
                if (cs.end == 0) continue;
                out = if (out) |o| .{ .start = @min(o.start, cs.start), .end = @max(o.end, cs.end) } else cs;
            }
            return out orelse .empty;
        },
        else => return .empty,
    }
}

/// Print `tree` on one line as `Sexp.write` does, with the whole text of
/// a leaf of a token over 65534 bytes (`leafText`), which `Sexp.write`
/// does not hold.
pub fn writeTree(tree: Sexp, source: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var stack: std.ArrayList([]const Sexp) = .empty;
    defer stack.deinit(std.heap.page_allocator);
    var s = tree;
    while (true) {
        // Whether the next item of the innermost list follows another.
        var sep = true;
        switch (s) {
            .nil => try w.writeAll("_"),
            .tag => |t| try w.writeAll(std.enums.tagName(parser.Tag, t) orelse "?"),
            .src => |x| if (x.id == path_capture_id) try w.writeAll(leafText(source, x)) else {
                try w.writeAll(diag.textBetween(source, x.pos, leafEnd(source, x)));
                if (x.id != 0) try w.print("#{d}", .{x.id});
            },
            .str => |x| try w.print("\"{s}\"", .{x}),
            .list => |l| {
                try w.writeByte('(');
                stack.append(std.heap.page_allocator, l.items()) catch return error.WriteFailed;
                sep = false;
            },
        }
        while (true) {
            if (stack.items.len == 0) return;
            const rest = &stack.items[stack.items.len - 1];
            if (rest.len > 0) {
                if (sep) try w.writeByte(' ');
                s = rest.*[0];
                rest.* = rest.*[1..];
                break;
            }
            _ = stack.pop();
            try w.writeByte(')');
            sep = true;
        }
    }
}

/// How a `for` over an iterator walks its source, which decides the
/// `while` it is rewritten into (docs/internals/INTERNALS.md, "Loops over an
/// iterator").
pub const IterSource = enum {
    /// A place the loop advances where it stands: `for x in it` and
    /// `for x in !it` are `while (!it).next() as x`.
    place,
    /// A value made here, held in a hidden binding for the whole loop:
    /// `for x in mk()`, or `for x in ?b.each()`, whose `?` lends the
    /// call's self as before any call.
    made,
    /// A place the loop takes (`for x in <it`), moved into the hidden
    /// binding it holds for the whole loop.
    moved,
};

/// A `for` node to rewrite (`Parser.desugarIterLoops`), with how it
/// walks its source.
pub const IterLoop = struct { node: parser.NodeId, source: IterSource };

/// What a chain walks (`Chain`): an iterator, which the loop advances in
/// place; a List, array, or slice, read by element; or a range.
pub const ChainSource = enum { iterator, elements, range };

/// A chain typecheck found (`Parser.desugarChains`): the call of its
/// consumer, or the `for` whose source it is, and what it walks.
/// `copies`: an element of a List, array, or slice source is plain data,
/// which a loop's item copies; else the loop lends it, and a consumer
/// that keeps one keeps its index (`Parser.lowerPeel`).
/// `zip` and `zip_copies` say the same of a `zip`'s second source.
pub const Chain = struct { node: parser.NodeId, source: ChainSource, copies: bool = true, zip: ChainSource = .elements, zip_copies: bool = true };

/// The stages a chain may take, in a call on a `for` source whose type
/// declares no method of the name.
pub const chain_stages = [_][]const u8{ "map", "filter", "take", "skip", "enumerate", "zip" };

/// The consumers that end a chain.
pub const chain_consumers = [_][]const u8{ "sum", "count", "reduce", "collect", "any", "all", "find", "min", "max", "min_by", "max_by" };

pub fn isChainStage(name: []const u8) bool {
    for (chain_stages) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

pub fn isChainConsumer(name: []const u8) bool {
    for (chain_consumers) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// A string literal typecheck found where a `U8` or a `[N]U8` goes
/// (`Parser.byteLiterals`): the position of its leaf and its bytes.
pub const ByteLiteral = struct { pos: u32, bytes: []const u8, array: bool };

pub const Parser = struct {
    base: BaseParser,
    /// Set when parsing succeeded but the tree was rejected.
    failure: ?diag.Diagnostic = null,
    /// The definitions after the first rejected one that also leave
    /// out their parameter list, each reported, so that one run shows
    /// every header to fix.
    more_failures: std.ArrayList(diag.Diagnostic) = .empty,
    /// How many hidden leaves `hiddenPos` has placed; each takes the
    /// next position past the end of the source, which no leaf of the
    /// source holds, so facts keyed by position stay apart.
    padded: u32 = 0,
    /// Where each hidden leaf `hiddenPos` placed belongs (the start of a
    /// padded closure, or the name a chain's names stand for), so a
    /// diagnostic about it points into the source.
    pad_homes: std.ArrayList(u32) = .empty,
    /// The node ids of the `(read place)`, `(write place)`, and
    /// `(move place)` selves written in front of the call
    /// (`!v.push(x)`), not in parentheses.
    self_sigils: std.AutoHashMapUnmanaged(parser.NodeId, void) = .empty,
    /// The positions of the names a `for` over a chain binds, which its
    /// loop binds in its body (`lowerForChain`): loop bindings, as
    /// immutable as any `for`'s (`isLoopName`).
    loop_names: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The node ids of the `(share x)` and `(weak x)` whose operand has a
    /// `?` suffix inside parentheses that open right after the sigil
    /// (`*(T?)`), which the tree does not keep.
    paren_suffixes: std.AutoHashMapUnmanaged(parser.NodeId, void) = .empty,
    /// The methods declared outside a body that name no type of this
    /// module as it declares it (`fun Nope.m()`, `fun geo.Point.m()`),
    /// each as written, `pub` included; the checker says why.
    detached: std.ArrayList(Sexp) = .empty,

    /// How many `obj` or `enum` bodies the node being rewritten is in: a
    /// function there is a method.
    type_depth: u32 = 0,
    /// The module is the prelude, which declares the built-in types it
    /// names (`preludeUse`).
    prelude: bool = false,
    /// The built-in types written in Rig the module names, a bit each
    /// (`builtinTypeBit`), which resolve declares for it
    /// (`resolve.registerPrelude`).
    prelude_names: u16 = 0,

    /// Every pass walks the tree recursively; deeper trees are rejected
    /// here instead of exhausting the stack later.
    pub const max_tree_depth = 1000;

    pub fn init(alloc: std.mem.Allocator, source: []const u8) Parser {
        return .{ .base = BaseParser.init(alloc, source) };
    }

    /// Start over on `source` as `init` would, keeping the memory of
    /// earlier parses for the next (`BaseParser.reset`). Every tree and
    /// everything the wrapper recorded about one is gone, so nothing from
    /// an earlier parse may be held across it.
    pub fn reset(self: *Parser, source: []const u8) void {
        // What the wrapper holds lives in the base's arena, which the
        // base's reset frees: its own fields only go back to their
        // defaults.
        self.base.reset(source);
        self.* = .{ .base = self.base };
    }

    /// A parser over a directory module's files joined, each but the
    /// last ending at the matching `ends` position (`Lexer.ends`).
    pub fn initFiles(alloc: std.mem.Allocator, source: []const u8, ends: []const u32) Parser {
        var p = init(alloc, source);
        const lexer = &p.base.lexer;
        lexer.ends = ends;
        // The parser read its first token as it started: the files before
        // it hold none.
        while (lexer.crossesFile(lexer.prev_pos)) lexer.file += 1;
        return p;
    }

    pub fn deinit(self: *Parser) void {
        self.base.deinit();
    }

    /// Parse and rewrite into the semantic IR. On `error.ParseError`,
    /// `diagnostic()` describes the failure.
    pub fn parseProgram(self: *Parser) !Sexp {
        const tree = try self.rewrite(try self.parseTree());
        // Spacing is checked once the source parses, so that an error in
        // the parse is the one reported.
        if (self.failure == null) {
            const lexer = &self.base.lexer;
            for (lexer.layouts[0..lexer.layout_count]) |sp| {
                if (self.afterOnce(sp)) continue;
                const d: diag.Diagnostic = .{ .severity = .@"error", .pos = sp.pos, .end = sp.pos + sp.len, .message = self.layoutMessage(sp) };
                if (self.failure == null) self.failure = d else try self.more_failures.append(self.allocator(), d);
            }
        }
        if (self.failure != null) return error.ParseError;
        return tree;
    }

    /// Whether spacing record `sp` is the sigil that starts the type after
    /// `once` in a parameter (`f: once ?fun() -> T`), where `once` is a
    /// keyword, not a value the sigil would follow.
    fn afterOnce(self: *Parser, sp: Lexer.Layout) bool {
        const src = self.base.source;
        var i = sp.pos;
        while (i > 0 and isSpace(src[i - 1])) i -= 1;
        if (i < 4 or !std.mem.eql(u8, src[i - 4 .. i], "once")) return false;
        var j = i - 4;
        if (j > 0 and (std.ascii.isAlphanumeric(src[j - 1]) or src[j - 1] == '_')) return false;
        while (j > 0 and isSpace(src[j - 1])) j -= 1;
        return j > 0 and src[j - 1] == ':';
    }

    /// Why an operator's spacing is wrong, with the text to write.
    fn layoutMessage(self: *Parser, sp: Lexer.Layout) []const u8 {
        const src = self.base.source;
        const op = src[sp.pos .. sp.pos + sp.len];
        const left = operandBefore(src, sp.pos) orelse "a";
        const right = operandAfter(src, sp.pos + sp.len) orelse "b";
        // `print -1`: a call without its parentheses.
        if (sp.kind == .infix_before and isOutputCall(left)) return self.format("`{s}` is called with parentheses: `{s}({s}{s})`", .{ left, left, op, right });
        return switch (sp.kind) {
            .infix_before => if (prefixMeaning(op)) |m|
                self.format("`{s} {s}{s}`: an operator has the same spacing on both sides; write `{s} {s} {s}` to {s}, or `{s}, {s}{s}` to {s} `{s}` as a value of its own", .{ left, op, right, left, op, right, m.infix, left, op, right, m.prefix, right })
            else if (std.mem.eql(u8, op, "..") or std.mem.eql(u8, op, "..="))
                self.format("`{s} {s}{s}`: an operator has the same spacing on both sides; write `{s}{s}{s}` or `{s} {s} {s}`", .{ left, op, right, left, op, right, left, op, right })
            else
                self.format("`{s} {s}{s}`: an operator has the same spacing on both sides; write `{s} {s} {s}`", .{ left, op, right, left, op, right }),
            .infix_after => if (std.mem.eql(u8, op, "..") or std.mem.eql(u8, op, "..="))
                self.format("`{s}{s} {s}`: an operator has the same spacing on both sides; write `{s}{s}{s}` or `{s} {s} {s}`", .{ left, op, right, left, op, right, left, op, right })
            else
                self.format("`{s}{s} {s}`: an operator has the same spacing on both sides; write `{s} {s} {s}`", .{ left, op, right, left, op, right }),
            .postfix => if (sp.pos + sp.len < src.len and !isSpace(src[sp.pos + sp.len]))
                self.format("`{s} {s}{s}`: a `{s}` after a value touches it; write `{s}{s}{s}`", .{ left, op, right, op, left, op, right })
            else
                self.format("`{s} {s}`: a postfix `{s}` touches what it follows; write `{s}{s}`", .{ left, op, op, left, op }),
            .member => self.format("a member `.` touches both sides; write `{s}.{s}`", .{ left, right }),
            .enum_dot => self.format("`.` touches the name after it; write `.{s}`", .{right}),
            .call_bracket => if (bracketAfter(src, sp.pos)) |args|
                self.format("`{s} {s}`: a call's or index's bracket touches what it follows; write `{s}{s}`", .{ left, args, left, args })
            else
                self.format("`{s} {s}`: a call's or index's bracket touches what it follows; write `{s}{s}`", .{ left, op, left, op }),
            .range_end => if (sp.pos + sp.len < src.len and src[sp.pos + sp.len] == ']')
                self.format("a range's `..` touches its only bound; write `{s}..`", .{left})
            else
                self.format("a range's `{s}` touches its only bound; write `{s}{s}`", .{ op, op, right }),
            .closure_hanging => self.format("a closure body below its bar list ends with `{s}` on a line of its own: end this line before the `{s}`, and write `{s}` on the next line at the indentation of the line that opened it (column {d}); a one-line body may instead follow the bar list on its line", .{ op, op, op, sp.column + 1 }),
            .closure_close => self.format("a closure body below its bar list ends where the `{c}` around it stands alone at the start of a line, at the indentation of the line that opened it (column {d})", .{ closerOf(src, sp), sp.column + 1 }),
            .closure_indent => self.format("write this `{s}`, which ends a closure body below its bar list, at the indentation of the line that opened it (column {d})", .{ op, sp.column + 1 }),
        };
    }

    /// The bracket that closes the island a `closure_close` ends.
    fn closerOf(src: []const u8, sp: Lexer.Layout) u8 {
        // The opening bracket is on the line at `column`'s indentation
        // above; the island's bracket is the innermost one open there.
        var depth: i32 = 0;
        var p = sp.pos;
        while (p > 0) {
            p -= 1;
            switch (src[p]) {
                ')', ']' => depth += 1,
                '(', '[' => {
                    if (depth == 0) return if (src[p] == '(') ')' else ']';
                    depth -= 1;
                },
                else => {},
            }
        }
        return ')';
    }

    const Meaning = struct { infix: []const u8, prefix: []const u8 };

    /// What an operator that is also a prefix sigil does in each place.
    fn prefixMeaning(op: []const u8) ?Meaning {
        if (op.len != 1) return null;
        return switch (op[0]) {
            '<' => .{ .infix = "compare", .prefix = "move" },
            '>' => .{ .infix = "compare", .prefix = "wait for" },
            '-' => .{ .infix = "subtract", .prefix = "negate" },
            '+' => .{ .infix = "add", .prefix = "clone" },
            '*' => .{ .infix = "multiply", .prefix = "share" },
            else => null,
        };
    }

    /// The operand that ends at `end` (past whitespace, line breaks
    /// included, and a comment that ends a line), as written, when it is
    /// short: a name, a literal, or a call or index on one (`f(x)`,
    /// `a.b[i]`).
    fn operandBefore(src: []const u8, end: u32) ?[]const u8 {
        var e: usize = end;
        while (true) {
            while (e > 0 and (src[e - 1] == ' ' or src[e - 1] == '\t' or src[e - 1] == '\r')) e -= 1;
            if (e == 0 or src[e - 1] != '\n') break;
            // The line before may end in a comment, which is no operand.
            e -= 1;
            const line = if (std.mem.lastIndexOfScalar(u8, src[0..e], '\n')) |nl| nl + 1 else 0;
            if (commentStart(src[line..e])) |c| e = line + c;
        }
        var s = e;
        while (s > 0) {
            const c = src[s - 1];
            if (c == ')' or c == ']') {
                const open: u8 = if (c == ')') '(' else '[';
                var depth: u32 = 0;
                while (s > 0) {
                    s -= 1;
                    if (src[s] == '\n') return null;
                    if (src[s] == c) depth += 1;
                    if (src[s] == open) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
            } else if (c == '"' or c == '\'') {
                s -= 1;
                while (s > 0 and src[s - 1] != c) : (s -= 1) if (src[s - 1] == '\n') return null;
                if (s == 0) return null;
                s -= 1;
            } else if (isIdentCont(c) or c == '.' or c == '?' or c == '!') {
                s -= 1;
            } else break;
        }
        while (s < e and (src[s] == '.' or src[s] == '?' or src[s] == '!')) s += 1;
        if (s == e or e - s > 24) return null;
        return src[s..e];
    }

    /// The bracketed text that starts at `open`, `(x)` or `[0]`, when it
    /// closes on its line and is short.
    fn bracketAfter(src: []const u8, open: u32) ?[]const u8 {
        const want: u8 = if (src[open] == '(') ')' else ']';
        var depth: u32 = 0;
        var e: usize = open;
        while (e < src.len and e - open <= 24) : (e += 1) {
            switch (src[e]) {
                '(', '[' => depth += 1,
                ')', ']' => {
                    depth -= 1;
                    if (depth == 0) return if (src[e] == want) src[open .. e + 1] else null;
                },
                '\n' => return null,
                else => {},
            }
        }
        return null;
    }

    /// Where a comment starts on `line`: its first `#` outside a string.
    fn commentStart(line: []const u8) ?usize {
        var i: usize = 0;
        while (i < line.len) : (i += 1) switch (line[i]) {
            '#' => return i,
            '"', '\'' => {
                const q = line[i];
                i += 1;
                while (i < line.len and line[i] != q) : (i += 1) {
                    if (q == '"' and line[i] == '\\') i += 1;
                }
            },
            else => {},
        };
        return null;
    }

    /// The operand that starts at `start` (past whitespace on its line),
    /// as written, when it is short.
    fn operandAfter(src: []const u8, start: u32) ?[]const u8 {
        var s: usize = start;
        while (s < src.len and (src[s] == ' ' or src[s] == '\t')) s += 1;
        var e = s;
        while (e < src.len and std.mem.findScalar(u8, "<?!+-*~.", src[e]) != null) e += 1;
        if (e < src.len and (src[e] == '"' or src[e] == '\'')) {
            const q = src[e];
            e += 1;
            while (e < src.len and src[e] != q and src[e] != '\n') e += 1;
            if (e == src.len or src[e] != q) return null;
            e += 1;
        }
        while (e < src.len) {
            const c = src[e];
            if (isIdentCont(c) or c == '.') {
                e += 1;
            } else if (c == '(' or c == '[') {
                const close: u8 = if (c == '(') ')' else ']';
                var depth: u32 = 0;
                while (e < src.len) : (e += 1) {
                    if (src[e] == '\n') return null;
                    if (src[e] == c) depth += 1;
                    if (src[e] == close) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                if (e == src.len) return null;
                e += 1;
            } else break;
        }
        while (e > s and src[e - 1] == '.') e -= 1;
        if (e == s or e - s > 24) return null;
        return src[s..e];
    }

    /// Parse without the IR rewrites: the grammar's own output.
    pub fn parseTree(self: *Parser) !Sexp {
        const tree = try self.base.parseProgram();
        // `leafEnd` finds a long token's end by scanning it again.
        for (self.base.longTokenEnds.items) |kept| {
            const leaf: parser.Src = .{ .pos = kept.pos, .len = std.math.maxInt(u16), .id = 0 };
            if (leafEnd(self.base.source, leaf) != kept.end) @panic("a token over 65534 bytes scans to another end than the parser kept");
        }
        if (tooDeep(tree, 0)) |deep| {
            self.reject(deep, "expression is nested too deeply or too long; split it with named intermediate values");
            return error.ParseError;
        }
        return tree;
    }

    /// Reject the tree at `node`, unless it is already rejected.
    fn reject(self: *Parser, node: Sexp, message: []const u8) void {
        if (self.failure != null) return;
        const at = self.span(node);
        self.failure = .{ .severity = .@"error", .pos = at.start, .end = at.end, .message = message };
    }

    /// The source span of a node (see `BaseParser.span`).
    /// A hidden parameter of a padded closure spans the start of its
    /// closure, not the positions past the source's end its leaf holds.
    pub fn span(self: *const Parser, sexp: Sexp) parser.Span {
        if (sexp == .src and sexp.src.pos >= self.base.source.len) {
            const k = sexp.src.pos - self.base.source.len;
            if (k >= 1 and k <= self.pad_homes.items.len) {
                const home = self.pad_homes.items[k - 1];
                return .{ .start = home, .end = home };
            }
        }
        return self.base.span(sexp);
    }

    /// The first subtree nested `max_tree_depth` deep, or null.
    fn tooDeep(sexp: Sexp, depth: u32) ?Sexp {
        if (sexp != .list) return null;
        if (depth == max_tree_depth) return sexp;
        for (sexp.items()) |item| if (tooDeep(item, depth + 1)) |deep| return deep;
        return null;
    }

    /// Why parsing failed: at the token where the parser stopped, or the
    /// rejected tree. A token the parser did not expect is followed by
    /// what it expected there, when that is a short list.
    pub fn diagnostic(self: *Parser) diag.Diagnostic {
        if (self.failure) |f| return f;
        const failure = self.base.lastError().?;
        const lexer = &self.base.lexer;
        const tok = lexer.base.token(failure.cat, 0, failure.span.start, failure.span.end);
        const src = self.base.source;
        var pos = tok.pos;
        var end = failure.span.end;
        if (self.openRange(tok)) |d| return d;
        if (self.foreignForm(tok)) |d| return d;
        if (self.foreignWord(tok)) |d| return d;
        if (self.headerColon(tok)) |d| return d;
        if (self.bareResults(tok)) |d| return d;
        if (self.guardBlock(tok)) |d| return d;
        const message: []const u8 = switch (tok.cat) {
            .err => return .{ .severity = .@"error", .pos = pos, .end = end, .message = switch (lexer.err) {
                .semicolon => self.semicolonMessage(tok),
                .detached_prefix => self.detachedPrefix(tok),
                .brace => self.format("unexpected `{c}`; {s}", .{ src[pos], lexer.err.message() }),
                else => lexer.err.message(),
            } },
            // A brace stands only in a type (`?{Shape}`), so one the
            // parser did not expect is one outside a type: in an
            // expression's brackets or after a holding sigil, a type
            // with no expression spelling; inside braces, after `{` or
            // `+`, a name left out; anywhere else, a brace Rig does not
            // have.
            .lbrace => return .{ .severity = .@"error", .pos = pos, .end = end, .message = if (self.braceInExpression(tok)) "unexpected `{`; an API object's type has no expression spelling: as a type argument in an expression, name it with a `type` alias, or annotate the binding instead" else self.format("unexpected `{{`; {s}", .{Lexer.LexError.brace.message()}) },
            .rbrace => if (lexer.before_cat == .lbrace or lexer.before_cat == .plus) "unexpected `}`" else return .{ .severity = .@"error", .pos = pos, .end = end, .message = self.format("unexpected `}}`; {s}", .{Lexer.LexError.brace.message()}) },
            .eof, .outdent => blk: {
                pos = lexer.prev_end;
                end = pos;
                break :blk if (tok.cat == .eof) "unexpected end of file" else "unexpected end of block";
            },
            .newline => "unexpected end of line",
            .indent => "unexpected indentation",
            // After `s matches .circle(r)`: no guard in the pattern, and
            // alternatives in parentheses (docs/design/matches.md, "Rules").
            .post_if => if (afterMatchesPattern(src, pos)) "a pattern after `matches` takes no `if` guard: join the condition with `and`, `if s matches .circle(r) and r > 10`" else "a postfix `if` guard must end a statement; write `a if c else b` for a value",
            .comma => if (afterMatchesPattern(src, pos)) "put alternatives in parentheses: `matches (.a, .b)`" else self.format("unexpected `{s}`", .{src[pos..end]}),
            .ident => self.format("unexpected name `{s}`", .{src[pos..end]}),
            else => if (keyword(src[pos..end]) != null)
                self.format("unexpected keyword `{s}`", .{src[pos..end]})
            else
                self.format("unexpected `{s}`", .{src[pos..end]}),
        };
        const expected = self.expectedHint(failure.state);
        const with_expected = if (expected) |hint| self.format("{s}; expected {s}", .{ message, hint }) else message;
        const hint = self.printHint(tok) orelse self.bracketHint(tok) orelse self.typeSuffixHint(tok) orelse tokenHint(tok) orelse self.waitHint(src, tok) orelse chainedComparison(src, tok) orelse reservedHint(src, tok, expected orelse "");
        const full = if (hint) |h| self.format("{s}; {s}", .{ with_expected, h }) else with_expected;
        return .{ .severity = .@"error", .pos = pos, .end = end, .message = full };
    }

    /// Whether `{`, which the parser did not expect, stands where an
    /// expression spells a type: touching a holding sigil, `?{Shape}`,
    /// or first in an expression's brackets, `List[{Shape}]`.
    fn braceInExpression(self: *Parser, tok: Token) bool {
        const lexer = &self.base.lexer;
        const src = self.base.source;
        if (tok.pos > 0 and std.mem.findScalar(u8, "?!^*~", src[tok.pos - 1]) != null) return true;
        const in_brackets = lexer.nesting > 0 and src[lexer.brackets[lexer.nesting - 1]] == '[';
        return in_brackets and (lexer.before_cat == .lbracket or lexer.before_cat == .comma);
    }

    /// A deeper line after a statement that ends in a guard,
    /// `return if c` with branches below: a guard takes no block.
    /// Reported at the guard's `if`.
    fn guardBlock(self: *Parser, tok: Token) ?diag.Diagnostic {
        const lexer = &self.base.lexer;
        if (tok.cat != .indent) return null;
        const at = lexer.guard_pos orelse return null;
        if (at < lexer.head_pos) return null;
        const fix = switch (lexer.line_head) {
            .@"return" => "put `return` in each branch, or leave it out where the `if` is the function's last expression",
            .@"break" => "put `break` in each branch",
            else => "write the `if` first, with the statement in its block",
        };
        return .{ .severity = .@"error", .pos = at, .end = at + 2, .message = self.format("a guard `if` ends its statement and takes no block; {s}", .{fix}) };
    }

    /// A range with a side left out where only a slice may leave one
    /// out: `for i in 0..`, `1.. =>`, `[..3]`. Reported at the `..`.
    fn openRange(self: *Parser, tok: Token) ?diag.Diagnostic {
        const lexer = &self.base.lexer;
        const at: Token, const side: []const u8 = switch (tok.cat) {
            .dotdot, .dotdot_eq => .{ tok, "a start" },
            .dotdot_open => .{ tok, if (lexer.before_cat == .lbracket) "both ends" else "an end" },
            else => blk: {
                // The real token before this one; a layout token is not
                // one, so the last real token is.
                const cat, const pos = if (tok.len > 0) .{ lexer.before_cat, lexer.before_pos } else .{ lexer.prev_cat, lexer.prev_pos };
                if ((cat != .dotdot and cat != .dotdot_eq) or tok.cat == .err) return null;
                if (cat == .dotdot_eq) {
                    // The `..=` ends where the space before this token
                    // starts.
                    var end = if (tok.len > 0) tok.pos else pos + 3;
                    while (end > 3 and isSpaceBefore(self.base.source[end - 1])) end -= 1;
                    return .{ .severity = .@"error", .pos = end - 3, .end = end, .message = "`a..=` needs the end it includes; only `..` leaves a slice's end open: `xs[a..]`" };
                }
                break :blk .{ .{ .cat = .dotdot, .pre = 0, .pos = pos, .len = 2 }, "an end" };
            },
        };
        return .{ .severity = .@"error", .pos = at.pos, .end = self.base.tokenEnd(at), .message = self.format("a range needs {s}; only a slice leaves a side open: `xs[a..]`, `xs[..b]`, `xs[..]`", .{side}) };
    }

    /// A word other languages use where Rig has its own form, at the
    /// start of a statement (`def f()`, `let x = 5`, `loop` before its
    /// block) or where it fails itself (`if x then`): reported at the
    /// word, with Rig's spelling.
    fn foreignWord(self: *Parser, tok: Token) ?diag.Diagnostic {
        const lexer = &self.base.lexer;
        const src = self.base.source;
        const start: u32, const end: u32 = blk: {
            // The word the parser failed on, written where no Rig form
            // takes a name (`if x then`, `const x = 5`).
            if (tok.len > 0 and (tok.cat == .ident or keyword(self.base.tokenText(tok)) != null)) {
                if (foreign_words.get(self.base.tokenText(tok))) |f| if (f.alone and (!f.before_word or wordFollows(src, self.base.tokenEnd(tok)))) break :blk .{ tok.pos, self.base.tokenEnd(tok) };
            }
            // The statement's first word, right before the failure.
            const cat, const pos = if (tok.len > 0) .{ lexer.before_cat, lexer.before_pos } else .{ lexer.prev_cat, lexer.prev_pos };
            if (cat != .ident or pos != lexer.head_pos) return null;
            var end = pos;
            while (end < src.len and isIdentCont(src[end])) end += 1;
            break :blk .{ pos, end };
        };
        const word = src[start..end];
        const f = foreign_words.get(word) orelse return null;
        return .{ .severity = .@"error", .pos = start, .end = end, .message = self.format("Rig has no `{s}`; {s}", .{ word, f.fix }) };
    }

    /// A form other languages write where Rig has its own: a block after
    /// `??`, a list comprehension, an arrow function or a `lambda`, and
    /// `if let`. Reported where it starts, with Rig's spelling.
    fn foreignForm(self: *Parser, tok: Token) ?diag.Diagnostic {
        const lexer = &self.base.lexer;
        const src = self.base.source;
        const prev = if (tok.len > 0) lexer.before_cat else lexer.prev_cat;
        const prev_pos = if (tok.len > 0) lexer.before_pos else lexer.prev_pos;
        const prev_text = wordAt(src, prev_pos);
        // A keyword written as a name: `loop = 3`, `print(match)`. A
        // keyword that ends an operand or a jump is no name.
        if (prev_pos < src.len and keyword(prev_text) != null and prev_text.len > 0 and !std.mem.eql(u8, prev_text, "new")) {
            const names_it = switch (tok.cat) {
                .assign, .fixed_assign, .plus_assign, .minus_assign, .star_assign, .slash_assign, .percent_assign => lexer.head_pos == prev_pos,
                .rparen, .comma => true,
                else => false,
            };
            const ends_operand = for ([_][]const u8{ "true", "false", "break", "continue", "return", "pass", "panic" }) |w| {
                if (std.mem.eql(u8, prev_text, w)) break true;
            } else false;
            if (names_it and !ends_operand) {
                return .{ .severity = .@"error", .pos = prev_pos, .end = prev_pos + @as(u32, @intCast(prev_text.len)), .message = self.format("`{s}` is a keyword; choose another name", .{prev_text}) };
            }
        }
        // `x = o ??` with a block below, or nothing after it.
        if ((tok.cat == .indent or tok.cat == .newline) and prev == .nullish) {
            return .{ .severity = .@"error", .pos = prev_pos, .end = prev_pos + 2, .message = "after `??` comes one value or a jump (`?? 0`, `?? return`); for several lines write `if o as x ... else ...`" };
        }
        // `loop` and its block, then `else`: the header at the `else`'s
        // column above it opens a `loop`.
        if (tok.cat == .@"else" and loopAbove(src, tok.pos)) {
            return .{ .severity = .@"error", .pos = tok.pos, .end = tok.pos + 4, .message = "a loop has no `else`; to act when nothing matched, test first, as in `if not xs.any(f)` or `xs.find(f) ?? d`" };
        }
        // `[x * 2 for x in xs]`.
        if (tok.cat == .@"for" and lexer.nesting > 0 and src[lexer.brackets[lexer.nesting - 1]] == '[') {
            return .{ .severity = .@"error", .pos = tok.pos, .end = self.base.tokenEnd(tok), .message = "Rig has no list comprehension; write a chain, `xs.map(|x| x * 2).collect()`, or a `for` loop that pushes to a List" };
        }
        // `x => x * 2`, `(a, b) => a + b`.
        // A `=>` that touches the name before it is a wait, `x=>t`
        // (`waitHint`).
        if (tok.cat == .fat_arrow and (prev == .ident or prev == .rparen) and tok.pos > 0 and src[tok.pos - 1] == ' ') {
            return .{ .severity = .@"error", .pos = tok.pos, .end = self.base.tokenEnd(tok), .message = "a closure is `|x| ...`: write `|x| x * 2`" };
        }
        // `lambda x: x * 2`.
        if (prev == .ident and std.mem.eql(u8, prev_text, "lambda")) {
            return .{ .severity = .@"error", .pos = prev_pos, .end = prev_pos + 6, .message = "Rig has no `lambda`; a closure is `|x| ...`: write `|x| x * 2`" };
        }
        // `if let x = o`, `while let x = o`.
        if (prev == .ident and std.mem.eql(u8, prev_text, "let") and (lexer.line_head == .@"if" or lexer.line_head == .@"while")) {
            const kw = if (lexer.line_head == .@"if") "if" else "while";
            const name = wordAt(src, tok.pos);
            // The value after the `=`, to the end of the line.
            var value: []const u8 = "o";
            if (std.mem.findScalarPos(u8, src, tok.pos, '=')) |eq_at| {
                var e = eq_at + 1;
                while (e < src.len and src[e] != '\n' and src[e] != '#') e += 1;
                const v = std.mem.trim(u8, src[eq_at + 1 .. e], " \t\r");
                if (v.len > 0 and std.mem.findScalar(u8, src[tok.pos..eq_at], '\n') == null) value = v;
            }
            return .{ .severity = .@"error", .pos = prev_pos, .end = prev_pos + 3, .message = self.format("Rig has no `{s} let`; write `{s} {s} as {s}`", .{ kw, kw, value, if (name.len > 0) name else "x" }) };
        }
        return null;
    }

    /// Whether the nearest line above the one at `at` that starts at its
    /// column opens a `loop`: `loop`, `$l: loop`, or `x = loop`.
    fn loopAbove(src: []const u8, at: u32) bool {
        const line = if (std.mem.findScalarLast(u8, src[0..at], '\n')) |nl| nl + 1 else 0;
        const col = at - line;
        var end = line;
        while (end > 0) {
            const start = if (std.mem.findScalarLast(u8, src[0 .. end - 1], '\n')) |nl| nl + 1 else 0;
            const text = src[start .. end - 1];
            end = start;
            var c: usize = 0;
            while (c < text.len and text[c] == ' ') c += 1;
            if (c == text.len or text[c] == '#' or c > col) continue;
            if (c < col) return false;
            var rest = std.mem.trimEnd(u8, text[c..], " \t\r");
            if (std.mem.findScalar(u8, rest, '#')) |h| rest = std.mem.trimEnd(u8, rest[0..h], " \t");
            return std.mem.endsWith(u8, rest, "loop") and (rest.len == 4 or !isIdentCont(rest[rest.len - 5]));
        }
        return false;
    }

    /// The name that starts at `at`, or "".
    fn wordAt(src: []const u8, at: u32) []const u8 {
        var end = at;
        while (end < src.len and isIdentCont(src[end])) end += 1;
        return src[at..end];
    }

    const Foreign = struct {
        fix: []const u8,
        /// Named even where the parse fails on the word itself, not only
        /// when it starts a statement: a keyword of Rig's, or a word that
        /// ends a header.
        alone: bool = false,
        /// Named alone only where a word follows on its line (`async
        /// fun f()`, `await t`), not where it stands as a name.
        before_word: bool = false,
    };

    /// A word starts after the spaces at `at`, on the same line.
    fn wordFollows(src: []const u8, at: u32) bool {
        var p = at;
        while (p < src.len and (src[p] == ' ' or src[p] == '\t')) p += 1;
        return p > at and p < src.len and (std.ascii.isAlphabetic(src[p]) or src[p] == '_');
    }

    /// Other languages' words for forms Rig spells differently.
    const foreign_words = std.StaticStringMap(Foreign).initComptime(.{
        .{ "def", Foreign{ .fix = "declare a function with `fun` (it returns a value) or `sub`" } },
        .{ "fn", Foreign{ .fix = "declare a function with `fun` (it returns a value) or `sub`" } },
        .{ "func", Foreign{ .fix = "declare a function with `fun` (it returns a value) or `sub`" } },
        .{ "function", Foreign{ .fix = "declare a function with `fun` (it returns a value) or `sub`" } },
        .{ "let", Foreign{ .fix = "bind a name with `x = 5`, or `x =! 5` for one that never changes" } },
        .{ "var", Foreign{ .fix = "bind a name with `x = 5`, or `x =! 5` for one that never changes" } },
        .{ "const", Foreign{ .fix = "write `x =! e` for a binding that never changes", .alone = true } },
        .{ "class", Foreign{ .fix = "declare a type with `obj`" } },
        .{ "struct", Foreign{ .fix = "write `obj Name`: `struct` is spelled `obj`" } },
        .{ "impl", Foreign{ .fix = "write `add`: `add Int: Shape` adds an API to a type, and `obj Square: Shape` names one on its header", .alone = true } },
        .{ "trait", Foreign{ .fix = "write `api`: `api Shape` declares the methods a type provides", .alone = true } },
        .{ "async", Foreign{ .fix = "any function runs as a task with `&`: `t = f(x)&` starts one, and `>t` waits for its result", .alone = true, .before_word = true } },
        .{ "await", Foreign{ .fix = "a task started with `&` is waited for with `>t`: `t = f(x)&`, then `>t`", .alone = true, .before_word = true } },
        .{ "switch", Foreign{ .fix = "write `match`" } },
        .{ "case", Foreign{ .fix = "a match arm is `pattern => ...`" } },
        .{ "elif", Foreign{ .fix = "write `else if`" } },
        .{ "elsif", Foreign{ .fix = "write `else if`" } },
        .{ "elseif", Foreign{ .fix = "write `else if`" } },
        .{ "unless", Foreign{ .fix = "write `if not`" } },
        .{ "until", Foreign{ .fix = "write `while not`" } },
        .{ "import", Foreign{ .fix = "use a module with `use name`" } },
        .{ "require", Foreign{ .fix = "use a module with `use name`" } },
        .{ "include", Foreign{ .fix = "use a module with `use name`" } },
        .{ "forever", Foreign{ .fix = "write `loop`" } },
        .{ "do", Foreign{ .fix = "a block is the indented lines below the line that opens it", .alone = true } },
        .{ "begin", Foreign{ .fix = "a block is the indented lines below the line that opens it", .alone = true } },
        .{ "then", Foreign{ .fix = "a block is the indented lines below the line that opens it", .alone = true } },
    });

    /// `if x:`, `while x:`, `obj S:`: a `:` ending a block's header,
    /// as in Python. Reported at the `:`.
    fn headerColon(self: *Parser, tok: Token) ?diag.Diagnostic {
        const lexer = &self.base.lexer;
        const src = self.base.source;
        const pos = switch (tok.cat) {
            // `while x:` reads the `:` as the start of a step.
            .indent, .newline => if (lexer.prev_cat == .step_colon) lexer.prev_pos else return null,
            .colon, .step_colon => blk: {
                var p = tok.pos + 1;
                while (p < src.len and (src[p] == ' ' or src[p] == '\r')) p += 1;
                if (p < src.len and src[p] != '\n' and src[p] != '#') return null;
                break :blk tok.pos;
            },
            else => return null,
        };
        return .{ .severity = .@"error", .pos = pos, .end = pos + 1, .message = "unexpected `:`; a block's header ends without one: remove the `:`, and indent the block below" };
    }

    /// `a / b, a % b` as a statement: a function's several results are
    /// given by `return`, never by a bare list, which no statement is.
    /// Reported at the line, where the parse fails on its `,` or its end.
    fn bareResults(self: *Parser, tok: Token) ?diag.Diagnostic {
        const lexer = &self.base.lexer;
        const src = self.base.source;
        if (lexer.nesting > 0) return null;
        const at: u32 = switch (tok.cat) {
            .comma => tok.pos,
            .newline, .outdent, .eof => lexer.prev_pos,
            else => return null,
        };
        const start: u32 = if (std.mem.findScalarLast(u8, src[0..at], '\n')) |nl| @intCast(nl + 1) else 0;
        var end: u32 = at;
        while (end < src.len and src[end] != '\n' and src[end] != '#') end += 1;
        const line = std.mem.trim(u8, src[start..end], " \t\r");
        if (line.len == 0) return null;
        // A statement that starts with a keyword is no bare list.
        var w: usize = 0;
        while (w < line.len and isIdentCont(line[w])) w += 1;
        if (w > 0 and keyword(line[0..w]) != null) return null;
        // A comma outside brackets, and no `=` of a binding.
        var depth: i32 = 0;
        var comma = false;
        for (line, 0..) |c, i| switch (c) {
            '(', '[' => depth += 1,
            ')', ']' => depth -= 1,
            '"', '\'' => return null,
            ',' => if (depth == 0) {
                comma = true;
            },
            '=' => if (depth == 0) {
                const before = if (i > 0) line[i - 1] else ' ';
                const after = if (i + 1 < line.len) line[i + 1] else ' ';
                if (after != '=' and after != '>' and std.mem.findScalar(u8, "=!<>+-*/%&|^", before) == null) return null;
            },
            else => {},
        };
        if (!comma) return null;
        const first = start + @as(u32, @intCast(std.mem.find(u8, src[start..end], line).?));
        return .{ .severity = .@"error", .pos = first, .end = first + @as(u32, @intCast(line.len)), .message = self.format("results are written `return {s}`", .{line}) };
    }

    /// A note for a parse error inside a bracket opened on an earlier
    /// line that nothing after the error closes: the innermost such
    /// bracket, which is likely the one left open.
    pub fn unclosedBracket(self: *Parser) ?diag.Diagnostic {
        if (self.failure != null) return null;
        const lexer = &self.base.lexer;
        const src = self.base.source;
        // How many of the open brackets the rest of the source closes.
        const at = self.base.lastError().?.span.start;
        var probe = BaseLexer.init(src);
        probe.pos = at;
        // The rest of the file `at` is in.
        const end = for (lexer.ends) |e| {
            if (at <= e) break e;
        } else src.len;
        var depth: u32 = 0;
        var closed: u32 = 0;
        while (closed < lexer.nesting) {
            const tok = probe.next();
            if (tok.pos >= end) break;
            switch (tok.cat) {
                .lparen, .lbracket => depth += 1,
                .rparen, .rbracket => if (depth > 0) {
                    depth -= 1;
                } else {
                    closed += 1;
                },
                .eof => break,
                else => {},
            }
        } else return null;
        const open = lexer.brackets[lexer.nesting - 1 - closed];
        if (std.mem.findScalar(u8, src[open..at], '\n') == null) return null;
        return .{ .severity = .note, .pos = open, .end = open + 1, .message = self.format("the `{c}` opened here is not closed", .{src[open]}) };
    }

    /// Why an unexpected token is not Rig: it starts a reserved form, or
    /// Rig spells what it starts differently.
    fn reservedHint(src: []const u8, tok: Token, expected: []const u8) ?[]const u8 {
        const in_pattern = std.mem.find(u8, expected, "a match arm") != null or std.mem.find(u8, expected, "a pattern") != null;
        // Only a function type's result must follow here.
        if (std.mem.eql(u8, expected, "`->`")) return "a function type writes its result after `->`: `fun(Int) -> Int`";
        return switch (tok.cat) {
            .real, .string_sq, .string_dq => if (in_pattern) "a pattern is a name, an integer, a string, `true`, `false`, or an enum variant" else null,
            .@"else" => if (in_pattern) "the catch-all arm is `_`, or a name that binds the value" else null,
            .@"try" => "`try` blocks are reserved: propagate with `e!` or handle with `e catch ...`",
            .zig => "inline Zig is reserved: use `raw` blocks and `extern` declarations",
            .star => if (precededBy(src, tok.pos, "for")) reserved_for_star else null,
            .in => if (forStar(src, tok.pos)) reserved_for_star else null,
            .ident, .not_sym, .question => if (precededBy(src, tok.pos, "drop")) "a drop body takes self in parentheses: `drop(!@)`" else null,
            else => null,
        };
    }

    /// Whether the source just before `pos`, on its line, is a pattern
    /// after `matches`: `matches .name` or `matches .name(...)`.
    fn afterMatchesPattern(src: []const u8, pos: u32) bool {
        var at: usize = pos;
        while (at > 0 and src[at - 1] == ' ') at -= 1;
        if (at > 0 and src[at - 1] == ')') {
            var depth: usize = 0;
            while (at > 0) : (at -= 1) {
                const c = src[at - 1];
                if (c == '\n') return false;
                if (c == ')') depth += 1;
                if (c == '(') {
                    depth -= 1;
                    if (depth == 0) {
                        at -= 1;
                        break;
                    }
                }
            }
        }
        const name_end = at;
        while (at > 0 and isIdentCont(src[at - 1])) at -= 1;
        if (at == name_end or at == 0 or src[at - 1] != '.') return false;
        at -= 1;
        return precededBy(src, @intCast(at), "matches");
    }

    /// Compile-time parameters and arguments written where Rig does not
    /// take them: in parentheses (`obj Wrap(T)`, `List(Int)` in a type,
    /// `pre n: Int`), on a type alias, or as a type an expression cannot
    /// spell (`List[[]Int]()`). Also an object declared with `type`.
    fn bracketHint(self: *Parser, tok: Token) ?[]const u8 {
        const src = self.base.source;
        const before = std.mem.trimEnd(u8, src[0..tok.pos], if (tok.cat == .indent) " \r\n" else " ");
        var start = before.len;
        while (start > 0 and isIdentCont(before[start - 1])) start -= 1;
        const word = before[start..];
        const declared = std.mem.trimEnd(u8, before[0..start], " ");
        // `type` declares only an alias: `type Name = T`.
        if (word.len > 0 and endsWithWord(declared, "type")) switch (tok.cat) {
            .indent => return self.format("an object is declared with `obj`: `obj {s}`", .{word}),
            .lbracket, .lparen => {
                const eol = std.mem.findScalarPos(u8, src, tok.pos, '\n') orelse src.len;
                if (std.mem.findScalar(u8, src[tok.pos..eol], '=') != null) return "a type alias takes no type parameters; generic aliases are not supported";
                return self.format("an object is declared with `obj`: `obj {s}[T]`", .{word});
            },
            else => {},
        };
        const decl_kw: ?[]const u8 = for ([_][]const u8{ "obj", "enum", "fun", "sub" }) |kw| {
            if (endsWithWord(declared, kw)) break kw;
        } else null;
        switch (tok.cat) {
            .lparen => {
                if (word.len == 0) return null;
                if (decl_kw) |kw| if (!std.mem.eql(u8, kw, "fun") and !std.mem.eql(u8, kw, "sub")) return self.format("type parameters go in brackets: `{s} {s}[T]`", .{ kw, word });
                if (std.ascii.isUpper(word[0])) return self.format("type arguments go in brackets: `{s}[...]`", .{word});
                return null;
            },
            .lbracket => if (word.len > 0 and endsWithWord(declared, "error")) {
                return "an error set takes no type parameters";
            },
            .rbracket => if (before.len > 0 and before[before.len - 1] == '[') {
                return "empty brackets: give the compile-time arguments, as in `List[Int]()`";
            },
            .fun, .sub => if (self.base.lexer.nesting > 0 and src[self.base.lexer.brackets[self.base.lexer.nesting - 1]] == '[') {
                return "a function type has no expression spelling: as a type argument in an expression, name it with a `type` alias, or annotate the binding instead";
            },
            else => {},
        }
        if (std.mem.eql(u8, word, "pre") and self.base.lexer.inParens()) {
            return "compile-time parameters go in brackets after the name, before the run-time ones: `fun f[n: Int](x: Int)`";
        }
        if (tok.cat == .ident and tok.pos > 0 and src[tok.pos - 1] == ']') {
            return "a slice or array type has no expression spelling: as a type argument in an expression, name it with a `type` alias, or annotate the binding instead";
        }
        return null;
    }

    /// Whether `name` is `print` or `warn`, which are called with parentheses.
    fn isOutputCall(name: []const u8) bool {
        return std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "warn");
    }

    /// `print "hi"`: `print` or `warn` named without its call's parentheses.
    fn printHint(self: *Parser, tok: Token) ?[]const u8 {
        const lex = &self.base.lexer;
        if (tok.len == 0 or lex.before_cat != .ident) return null;
        const src = self.base.source;
        var end = lex.before_pos;
        while (end < src.len and isIdentCont(src[end])) end += 1;
        const name = src[lex.before_pos..end];
        if (!isOutputCall(name)) return null;
        return self.format("`{s}` is called with parentheses: `{s}(...)`", .{ name, name });
    }

    /// A prefix sigil with whitespace after it (`- b`): named with the
    /// operand it should touch.
    fn detachedPrefix(self: *Parser, tok: Token) []const u8 {
        const src = self.base.source;
        var probe = BaseLexer.init(src);
        probe.pos = tok.pos + 1;
        const next = while (true) {
            const t = probe.next();
            if (t.cat != .skip and t.cat != .comment) break t;
        };
        const operand = switch (next.cat) {
            .ident, .integer, .real, .string_sq, .string_dq => probe.text(next),
            else => if (isKeyword(next.cat)) probe.text(next) else "x",
        };
        return self.format("a prefix `{c}` touches its operand: write `{c}{s}`", .{ src[tok.pos], src[tok.pos], operand });
    }

    /// A `;`, which Rig does not take: one ending a statement, Rust's
    /// fill literal `[x; n]`, or Rust's array type `[T; n]`.
    fn semicolonMessage(self: *Parser, tok: Token) []const u8 {
        const src = self.base.source;
        const lex = &self.base.lexer;
        if (lex.nesting == 0) {
            // `a = 1; b = 2`: another statement follows on the line.
            const eol = std.mem.findScalarPos(u8, src, tok.pos, '\n') orelse src.len;
            const rest = std.mem.trim(u8, src[tok.pos + 1 .. eol], " \r");
            if (rest.len > 0 and rest[0] != '#') return "unexpected `;`; Rig ends a statement at the end of its line; put each statement on its own line";
            return "unexpected `;`; Rig ends a statement at the end of its line; remove the `;`";
        }
        const open = lex.brackets[lex.nesting - 1];
        if (src[open] != '[') return "unexpected `;`";
        const either = "unexpected `;`; `[x; n]` is written `[n of x]`, and `[Int; 3]` is written `[3]Int`";
        const eol = std.mem.findScalarPos(u8, src, tok.pos, '\n') orelse src.len;
        const close = std.mem.findScalarPos(u8, src[0..eol], tok.pos, ']') orelse return either;
        const elem = std.mem.trim(u8, src[open + 1 .. tok.pos], " ");
        const len = std.mem.trim(u8, src[tok.pos + 1 .. close], " ");
        if (elem.len == 0 or len.len == 0 or std.mem.findAny(u8, elem, ",;") != null or std.mem.findAny(u8, len, ",;([") != null) return either;
        // `[Int; 3]`: the brackets stand where a type goes (after `:` or
        // `->`), or the element reads as a type: `Int`, `U8`, `T`, not a
        // constant such as `LIMIT`, nor a constructor call.
        const before = std.mem.trimEnd(u8, src[0..open], " ");
        const in_type = std.mem.endsWith(u8, before, ":") or std.mem.endsWith(u8, before, "->");
        const rest = elem[1..];
        const typelike = in_type or (std.ascii.isUpper(elem[0]) and std.mem.findScalar(u8, elem, '(') == null and
            (rest.len == 0 or std.mem.findAny(u8, rest, "abcdefghijklmnopqrstuvwxyz") != null or
                std.mem.findNone(u8, rest, "0123456789") == null));
        if (typelike) return self.format("unexpected `;`; an array type puts its length first: `[{s}]{s}`", .{ len, elem });
        return self.format("unexpected `;`; a fill literal puts its count first: `[{s} of {s}]`", .{ len, elem });
    }

    /// `sub()?`, `*fun(Int) -> Int` then `!`: a function type takes no
    /// suffix, so an optional one is written in parentheses.
    fn typeSuffixHint(self: *Parser, tok: Token) ?[]const u8 {
        if (tok.cat != .question and tok.cat != .not_sym) return null;
        const src = self.base.source;
        if (tok.pos == 0 or src[tok.pos - 1] != ')') return null;
        // The `(` that the `)` before the suffix closes.
        var depth: u32 = 0;
        var p = tok.pos;
        const open = while (p > 0) {
            p -= 1;
            switch (src[p]) {
                ')' => depth += 1,
                '(' => {
                    depth -= 1;
                    if (depth == 0) break p;
                },
                '\n' => return null,
                else => {},
            }
        } else return null;
        if (!endsWithWord(src[0..open], "sub") and !endsWithWord(src[0..open], "fun")) return null;
        var start = open - 3;
        while (start > 0 and (src[start - 1] == '*' or src[start - 1] == '~' or src[start - 1] == '^')) start -= 1;
        return self.format("a function type takes no suffix; write `({s}){c}`", .{ src[start..tok.pos], src[tok.pos] });
    }

    /// `[a, 2 of 3]`: a fill literal is the whole bracket. `Int??`: `??`
    /// is an operator, and where the parser does not take one, it was
    /// meant as two suffixes.
    fn tokenHint(tok: Token) ?[]const u8 {
        return switch (tok.cat) {
            .of => "a fill literal `[n of x]` holds one count and one element; it cannot share brackets with a list",
            .nullish => "`??` is the fallback operator; an optional of an optional is written `(T?)?`",
            // Where no operator could come: C and Rust's address-of.
            .ampersand => "Rig lends with `?x` (to read) or `!x` (to write)",
            else => null,
        };
    }

    /// A wait whose `>` the token before it took: `x=>t` is the match
    /// arm's `=>`, and `->t` a function's `->`.
    fn waitHint(self: *Parser, src: []const u8, tok: Token) ?[]const u8 {
        const end = tok.pos + tok.len;
        if (end >= src.len or !isIdentStart(src[end])) return null;
        const name = identAt(src, end);
        return switch (tok.cat) {
            .fat_arrow => self.format("`=>` ends a match arm's pattern; to wait for the task `{s}`, write `= >{s}`", .{ name, name }),
            .arrow => self.format("`->` gives a function's result type; to negate what the task `{s}` gives, write `-(>{s})`", .{ name, name }),
            else => null,
        };
    }

    /// A comparison operator after a value, where the parser takes none:
    /// a second comparison in a chain (`a == b | c == d` reads as
    /// `a == (b | c) == d`, since `|`, `&`, and `^` bind tighter).
    fn chainedComparison(src: []const u8, tok: Token) ?[]const u8 {
        switch (tok.cat) {
            .eq, .ne, .le, .ge, .lt, .gt => {},
            else => return null,
        }
        const before = std.mem.trimEnd(u8, src[0..tok.pos], " ");
        if (before.len == 0) return null;
        const c = before[before.len - 1];
        if (!isIdentCont(c) and c != ')' and c != ']' and c != '"' and c != '\'') return null;
        return "comparisons do not chain, and `|`, `&`, and `^` bind tighter than a comparison: put each comparison in parentheses, `(a == b) | (c == d)`";
    }

    fn endsWithWord(text: []const u8, word: []const u8) bool {
        return std.mem.endsWith(u8, text, word) and (text.len == word.len or !isIdentCont(text[text.len - word.len - 1]));
    }

    const reserved_for_star = "`for *x in` is reserved: iterate with `for x in xs`, `?xs`, or `!xs`";

    /// Whether the `in` at `pos` closes a `for *x` header, which reads as
    /// a bare `for` over `*x` until the `in`.
    fn forStar(src: []const u8, pos: u32) bool {
        const start = if (std.mem.findScalarLast(u8, src[0..pos], '\n')) |nl| nl + 1 else 0;
        const line = std.mem.trimStart(u8, src[start..pos], " \t");
        return std.mem.startsWith(u8, line, "for *");
    }

    /// The word before `pos` is `word`.
    fn precededBy(src: []const u8, pos: u32, word: []const u8) bool {
        return endsWithWord(std.mem.trimEnd(u8, src[0..pos], " "), word);
    }

    /// The generated parser's expected set where it stopped (its
    /// `@display` and `@errors` names, distinct), or null when it names
    /// more than a few things.
    fn expectedHint(self: *Parser, state: u16) ?[]const u8 {
        var buf: [parser.maxExpected][]const u8 = undefined;
        const names = BaseParser.expectedNames(state, &buf);
        if (names.len == 0 or names.len > max_expected) return null;
        var out: std.Io.Writer.Allocating = .init(self.allocator());
        for (names, 0..) |n, i| {
            out.writer.writeAll(if (i == 0) "" else if (i + 1 == names.len) " or " else ", ") catch return null;
            out.writer.writeAll(n) catch return null;
        }
        return out.written();
    }

    /// The longest expected set a parse error lists.
    const max_expected = 3;

    fn format(self: *Parser, comptime fmt: []const u8, args: anytype) []const u8 {
        return self.allocator().print(fmt, args) catch "unexpected token";
    }

    fn allocator(self: *Parser) std.mem.Allocator {
        return self.base.allocator();
    }

    // -------------------------------------------------------------------------
    // Rewrites that need to inspect the tree:
    //
    //   * a closure's bar list (the grammar's `params`) splits into its
    //     captures and parameters:
    //       (lambda _ ((cap_clone v) a) _ body)  →  (lambda (captures (cap_clone v)) (a) _ body)
    //   * a `for` source sigil the self rewrite (below) leaves in place
    //     moves into the mode slot:
    //       (for iter x _ (read xs) body _)  →  (for read x _ xs body _)
    //   * a statement `<e` whose value is not used drops now: a block's
    //     statement, a `defer` or `errdefer` body, an arm's body, or a
    //     labeled statement becomes (drop x) for a name, and
    //     (drop (move e)) for anything else; the last statement of a
    //     `fun` body, a closure body, a `break` or `return` value, a
    //     binding's value, or a branch, arm, `catch` handler, or loop
    //     `else` block whose value is used keeps its (move e):
    //       (block (move x))  →  (block (drop x))
    //   * a jump fallback belongs to the nearest `??` (the grammar reads
    //     it at the level of `catch`, after the chain before it):
    //       (?? (?? a b) (return v))  →  (?? a (?? b (return v)))
    //   * `?`, `!`, or `<` before a place followed by a method call is the
    //     self's mode:
    //       (write (call (member (member x v) push) 1))  →  (call (member (write (member x v)) push) 1)
    //
    // Every rewritten node keeps its node id, and so its span; the new
    // `captures` node and self sigil get their own (`newNode`).
    // -------------------------------------------------------------------------

    pub fn rewrite(self: *Parser, sexp: Sexp) std.mem.Allocator.Error!Sexp {
        if (sexp != .list) return sexp;
        var items = sexp.items();
        if (sexp.kind() == .@"for") {
            const copy = try self.allocator().dupe(Sexp, items);
            self.bareFor(sexp, copy);
            items = copy;
        }
        const walked = try self.allocator().alloc(Sexp, items.len);
        const in_type = switch (sexp.kind() orelse .module) {
            .@"struct", .@"enum", .errors, .generic_struct, .generic_enum, .api, .api_add => true,
            else => false,
        };
        if (in_type) self.type_depth += 1;
        for (items, 0..) |child, i| walked[i] = try self.rewrite(child);
        if (in_type) self.type_depth -= 1;
        // A `for` source sigil the self rewrite left in place is the
        // loop's mode; one before a method call went to its self.
        if (sexp.kind() == .@"for") normFor(walked);
        dropParens(sexp.kind(), walked);
        const out: Sexp = .{ .list = parser.List.withId(walked, sexp.list.id) };
        try self.lowerMatches(out.kind(), walked);
        switch (out.kind() orelse return out) {
            .module => {
                stripParens(out);
                self.strayRarely(out, false, false);
                self.moduleConsts(out);
                return self.preludeUse(try self.attachMethods(out));
            },
            .@"struct", .@"enum", .errors, .api, .api_add => try self.pubMembers(out),
            .generic_struct => {
                try self.tparamBounds(walked, ir.slot(.generic_struct, .tparams), ir.slot(.generic_struct, .bounds), false);
                try self.pubMembers(out);
            },
            .generic_enum => {
                try self.tparamBounds(walked, ir.slot(.generic_enum, .tparams), ir.slot(.generic_enum, .bounds), false);
                try self.pubMembers(out);
            },
            .lambda => {
                try self.splitBars(out, walked);
                // A closure's value is its body's last line.
                try self.valueTail(&walked[ir.slot(.lambda, .body)]);
            },
            .block => for (walked[1..]) |*stmt| try self.dropStatement(stmt),
            .@"defer", .@"errdefer" => try self.dropStatement(&walked[ir.slot(.@"defer", .body)]),
            .labeled => try self.dropStatement(&walked[ir.slot(.labeled, .stmt)]),
            .@"??" => return self.nearestFallback(try self.rightNested(out)),
            .destructure => try self.destructureTargets(walked),
            .as_results => try self.resultNames(walked),
            .as_pattern => {
                const src = self.base.source;
                const value = self.span(ir.AsPattern.value(out));
                const pattern = self.span(ir.AsPattern.pattern(out));
                self.reject(out, self.format("write `{s} matches {s}`: `as` names a value, and `matches` tests a pattern", .{ src[value.start..value.end], src[pattern.start..pattern.end] }));
                return out;
            },
            .matches => self.checkMatches(out),
            .variant_pattern => try self.pbindNone(walked),
            .arm => {
                if (ir.Arm.pattern(out).isKind(.paren_alts)) {
                    const alts = ir.rest(ir.Arm.pattern(out), .alts);
                    const first = self.span(alts[0]);
                    const last = self.span(alts[alts.len - 1]);
                    self.reject(ir.Arm.pattern(out), self.format("write `{s} =>`: an arm lists its alternatives without parentheses", .{self.base.source[first.start..last.end]}));
                }
                try self.dropStatement(&walked[ir.slot(.arm, .body)]);
            },
            .read, .write, .move => return self.selfSigil(out),
            .wait => {
                self.touchesOperand(out);
                return self.waitCall(out);
            },
            // A function records which (`onceParams`).
            .once => return self.base.newNode(.@":", &.{ ir.get(out, .name), ir.get(out, .type) }, self.span(out)),
            .@"..=" => return self.base.newNode(.@"..", &.{ ir.get(out, .left), ir.get(out, .right), .{ .tag = .inclusive } }, self.span(out)),
            .member, .index, .inst => self.waitTakesName(out, ir.get(out, .object)),
            .call => self.waitTakesName(out, ir.Call.callee(out)),
            .share, .box => try self.noteParenSuffix(out),
            .weak => {
                self.touchesOperand(out);
                try self.noteParenSuffix(out);
            },
            .read_view, .write_view, .shared, .boxed => self.touchesOperand(out),
            // The body's value is returned.
            .fun => {
                try self.tparamBounds(walked, ir.slot(.fun, .tparams), ir.slot(.fun, .bounds), false);
                try self.tparamBounds(walked, ir.slot(.fun, .owner_params), ir.slot(.fun, .owner_bounds), true);
                try self.onceParams(items[ir.slot(.fun, .params)], walked, ir.slot(.fun, .params), ir.slot(.fun, .once));
                try self.paramList(out);
                if (ir.Fun.returns(out) != .nil) try self.valueTail(&walked[ir.slot(.fun, .body)]);
            },
            .sub => {
                try self.tparamBounds(walked, ir.slot(.sub, .tparams), ir.slot(.sub, .bounds), false);
                try self.tparamBounds(walked, ir.slot(.sub, .owner_params), ir.slot(.sub, .owner_bounds), true);
                try self.onceParams(items[ir.slot(.sub, .params)], walked, ir.slot(.sub, .params), ir.slot(.sub, .once));
                try self.paramList(out);
            },
            .extern_fun => {
                try self.onceParams(items[ir.slot(.extern_fun, .params)], walked, ir.slot(.extern_fun, .params), ir.slot(.extern_fun, .once));
                try self.paramList(out);
            },
            .extern_sub => {
                try self.onceParams(items[ir.slot(.extern_sub, .params)], walked, ir.slot(.extern_sub, .params), ir.slot(.extern_sub, .once));
                try self.paramList(out);
            },
            // The expression's value is bound or returned.
            .set => try self.valueTail(&walked[ir.slot(.set, .value)]),
            .@"return" => try self.valueTail(&walked[ir.slot(.@"return", .value)]),
            // A loop's value is always used.
            .@"break" => try self.valueTail(&walked[ir.slot(.@"break", .value)]),
            .@"while" => {
                self.whileTrue(out);
                self.loopElse(out);
            },
            .@"for" => self.loopElse(out),
            .loop => return self.loopBlock(out),
            else => {},
        }
        return out;
    }

    /// `while true` in the source: the loop that runs until a `break` is
    /// `loop`, and a `while` takes a condition that can end it. Only the
    /// literal `true`; a `loop` is a `while` whose `true` is hidden
    /// (`loopBlock`).
    fn whileTrue(self: *Parser, node: Sexp) void {
        const cond = ir.While.cond(node);
        if (self.failure != null or cond != .src or isHiddenLeaf(cond)) return;
        if (!std.mem.eql(u8, leafText(self.base.source, cond.src), "true")) return;
        self.failure = .{ .severity = .@"error", .pos = self.span(node).start, .end = self.span(cond).end, .message = "write `loop`: `while` takes a condition that can end it" };
    }

    /// A loop's `else`, which no loop has: reported at the `else`.
    fn loopElse(self: *Parser, node: Sexp) void {
        const else_ = ir.get(node, .@"else");
        if (self.failure != null or else_ == .nil) return;
        const start = self.span(else_).start;
        const kw: u32 = if (std.mem.findLast(u8, self.base.source[0..start], "else")) |k| @intCast(k) else start;
        self.failure = .{ .severity = .@"error", .pos = kw, .end = kw + 4, .message = "a loop has no `else`; to act when nothing matched, test first, as in `if not xs.any(f)` or `xs.find(f) ?? d`" };
    }

    /// `loop` and its block: a `while` whose condition is a `true` no
    /// source holds, at the keyword. Every pass reads it as the one loop
    /// that ends only by a jump, and the one that gives a value.
    fn loopBlock(self: *Parser, node: Sexp) std.mem.Allocator.Error!Sexp {
        const at = self.span(node);
        return self.base.newNode(.@"while", &.{ hiddenLeaf(at.start, .true_value), .nil, ir.Loop.body(node), .nil }, at);
    }

    /// The slot of a node of `kind` whose parentheses, a `paren` the
    /// grammar keeps, the wrapper still reads once the node is walked:
    /// a link of a chain, where the self-sigil rule stops at a
    /// parenthesized part (`selfSigil`), a handle's operand, where a
    /// suffix may sit inside them (`noteParenSuffix`). Null for every
    /// other node, whose children lose their parentheses as soon as it is
    /// walked, but a fallback, `??`, which keeps both sides' for its
    /// grouping (`rightNested`).
    fn parenSlot(kind: parser.Tag) ?usize {
        return switch (kind) {
            .member => ir.slot(.member, .object),
            .index => ir.slot(.index, .object),
            .inst => ir.slot(.inst, .object),
            .call => ir.slot(.call, .callee),
            .propagate => ir.slot(.propagate, .value),
            .propagate_none => ir.slot(.propagate_none, .value),
            .read => ir.slot(.read, .operand),
            .write => ir.slot(.write, .operand),
            .move => ir.slot(.move, .operand),
            .share => ir.slot(.share, .operand),
            .weak => ir.slot(.weak, .operand),
            .box => ir.slot(.box, .operand),
            else => null,
        };
    }

    /// The node inside any parentheses around `e`.
    fn unparen(e: Sexp) Sexp {
        var x = e;
        while (x.isKind(.paren)) x = ir.Paren.value(x);
        return x;
    }

    /// Drops the parentheses around each child of a node of `kind` just
    /// walked, `walked`, but the one its `parenSlot` keeps.
    fn dropParens(kind: ?parser.Tag, walked: []Sexp) void {
        if (kind == .@"??") return;
        const keep = if (kind) |k| parenSlot(k) else null;
        for (walked, 0..) |*c, i| {
            if (keep != null and keep.? == i) continue;
            c.* = unparen(c.*);
        }
    }

    /// Drops every `paren` left in the tree under `e`, in place, so no
    /// pass after the wrapper sees one.
    fn stripParens(e: Sexp) void {
        if (e != .list) return;
        for (@constCast(e.items())) |*c| {
            c.* = unparen(c.*);
            stripParens(c.*);
        }
    }

    /// A module that names a built-in type written in Rig
    /// (`builtin_type_names`), or a `lanes` method, whose mask iterator is
    /// one, uses the hidden module that declares them, the prelude, at
    /// the first such name. Resolve puts the types it names in a scope
    /// around the module's (`resolve.registerPrelude`), where a name means
    /// a built-in type only when no declaration or narrower scope takes it.
    fn preludeUse(self: *Parser, module: Sexp) std.mem.Allocator.Error!Sexp {
        if (self.prelude) return module;
        var first: ?u32 = null;
        self.builtinNames(module, &first);
        const pos = first orelse return module;
        // The leaf holds a position past the source's end, as a chain's
        // names do, so the name at `pos` keeps its own.
        const use = try self.base.newNode(.use, &.{ try self.synthLeaf(pos, .builtin_module), .nil }, .{ .start = pos, .end = pos + 1 });
        const items = module.items();
        const all = try std.mem.concat(self.allocator(), Sexp, &.{ items[0..1], &.{use}, items[1..] });
        return .{ .list = parser.List.withId(all, module.list.id) };
    }

    /// Each leaf of `node` spelled as a built-in type written in Rig, in
    /// `prelude_names`, and the position of the first, or of a member
    /// `lanes`, in `first` (`preludeUse`). A member's name, `lib.Set`, is
    /// another module's.
    fn builtinNames(self: *Parser, node: Sexp, first: *?u32) void {
        switch (node) {
            .src => |leaf| {
                if (isHiddenLeaf(node)) return;
                const bit = builtinTypeBit(leafText(self.base.source, leaf));
                if (bit == 0) return;
                self.prelude_names |= bit;
                if (first.* == null) first.* = leaf.pos;
            },
            .list => if (node.isKind(.member)) {
                self.builtinNames(ir.Member.object(node), first);
                const name = ir.Member.name(node);
                if (first.* == null and name == .src and std.mem.eql(u8, leafText(self.base.source, name.src), "lanes")) first.* = name.src.pos;
            } else for (node.items()) |c| self.builtinNames(c, first),
            else => {},
        }
    }

    /// The type parameters among `walked[slot]`, a declaration's
    /// compile-time parameters, written with bounds: `[T: Ord]`, whose
    /// name after the colon is a built-in API (`Api`), `[T: Shape]`, a
    /// type parameter (a capital letter) named after the colon, and `[K:
    /// Hash + Print]`. Each becomes a bare name, as `[T]`, and the node
    /// that bounds it moves to the group at `walked[into]`, which
    /// `boundsIn` reads by the name's leaf; resolve tells an API from a
    /// type. `[S: Source, S.Item: Ord]` bounds an associated type, and
    /// its `assoc_bound` moves there too. `[n: Int]` names a type and
    /// stays a compile-time value. With `whole`, the group holds every
    /// parameter as written, bare or bound, in order: the type's
    /// parameters as a method declared outside its body names them
    /// (`owner_bounds`), whose list the wrapper drops (`attachMethods`).
    fn tparamBounds(self: *Parser, walked: []Sexp, slot: usize, into: usize, whole: bool) std.mem.Allocator.Error!void {
        const group = walked[slot];
        if (group != .list) return;
        const items = try self.allocator().dupe(Sexp, group.items());
        var moved: std.ArrayList(Sexp) = .empty;
        var changed = false;
        for (items) |*p| {
            const name: Sexp = switch (p.kind() orelse {
                if (whole) try moved.append(self.allocator(), p.*);
                continue;
            }) {
                .@":" => blk: {
                    const ty = ir.get(p.*, .type);
                    const pname = ir.get(p.*, .name);
                    const builtin = ty == .src and Api.named(leafText(self.base.source, ty.src)) != null;
                    const capital = pname == .src and std.ascii.isUpper(leafText(self.base.source, pname.src)[0]);
                    const named = (ty == .src and std.ascii.isUpper(leafText(self.base.source, ty.src)[0])) or ty.isKind(.member);
                    if (!builtin and !(capital and named)) {
                        // `[n: Int]`: a value, whose name stands for it in a
                        // whole group, so a `:` there is always a bound.
                        if (whole) try moved.append(self.allocator(), pname);
                        continue;
                    }
                    break :blk pname;
                },
                .bound => ir.get(p.*, .name),
                else => continue,
            };
            if (name != .src) continue;
            try moved.append(self.allocator(), p.*);
            p.* = name;
            changed = true;
        }
        // `S.Item: Ord`: bounds on an associated type of a parameter the
        // same brackets name, and no parameter of its own.
        var kept: std.ArrayList(Sexp) = .empty;
        for (items) |p| {
            if (!p.isKind(.assoc_bound)) {
                try kept.append(self.allocator(), p);
                continue;
            }
            changed = true;
            const owner = ir.get(p, .owner);
            const named = for (items) |q| {
                const qn = if (q == .src) q else if (q.isKind(.@":") or q.isKind(.bound)) ir.get(q, .name) else Sexp.nil;
                if (qn == .src and owner == .src and std.mem.eql(u8, leafText(self.base.source, qn.src), leafText(self.base.source, owner.src))) break true;
            } else false;
            if (!named) {
                self.reject(p, "an associated type's bound names a parameter of the same brackets: `[S: Source, S.Item: Ord]`");
                continue;
            }
            try moved.append(self.allocator(), p);
        }
        if (!changed) return;
        walked[slot] = .{ .list = parser.List.withId(kept.items, group.list.id) };
        walked[into] = try self.base.newList(moved.items, self.span(group));
    }

    /// The parameters of a function written `f: once ?fun() -> T`, each
    /// a `(once f type)` among `written`, its parameters as parsed, and a
    /// `(: f type)` among `walked[slot]`, as rewritten: their names, in
    /// the group at `walked[into]`, which resolve reads (`inNames`).
    fn onceParams(self: *Parser, written: Sexp, walked: []Sexp, slot: usize, into: usize) std.mem.Allocator.Error!void {
        if (written != .list) return;
        var names: std.ArrayList(Sexp) = .empty;
        for (written.items(), walked[slot].items()) |w, p| {
            if (w.isKind(.once)) try names.append(self.allocator(), ir.get(p, .name));
        }
        if (names.items.len > 0) walked[into] = try self.base.newList(names.items, self.span(walked[slot]));
    }

    /// Whether `group`, a declaration's `once`, `pubs`, or `read_only`
    /// group of name leaves, holds the name `name` is: the same leaf.
    pub fn inNames(group: Sexp, name: Sexp) bool {
        if (group != .list or name != .src) return false;
        for (group.items()) |n| {
            if (n == .src and n.src.pos == name.src.pos) return true;
        }
        return false;
    }

    /// The name of a member of a type's body: a field's, a method's, or a
    /// variant's.
    pub fn memberName(m: Sexp) Sexp {
        return switch (m.kind() orelse return m) {
            .@":", .default, .fun, .sub, .variant, .valued => ir.get(m, .name),
            else => .nil,
        };
    }

    /// The APIs a bound in a `bounds` or `owner_bounds` group names: a
    /// `(: T Ord)`'s one, or a `(bound K (Hash Print))`'s; empty for
    /// anything else.
    pub fn boundApis(entry: Sexp) []const Sexp {
        return switch (entry.kind() orelse return &.{}) {
            .@":" => entry.items()[ir.slot(.@":", .type)..][0..1],
            .bound => ir.get(entry, .apis).items(),
            else => &.{},
        };
    }

    /// The APIs written on the type parameter `name`, a bare name of a
    /// declaration's `tparams`, from the declaration's `bounds` group
    /// (`tparamBounds`): its bound's name is that same leaf. Empty for one
    /// written bare.
    pub fn boundsIn(group: Sexp, name: Sexp) []const Sexp {
        if (group != .list or name != .src) return &.{};
        for (group.items()) |e| {
            if (!e.isKind(.@":") and !e.isKind(.bound)) continue;
            const n = ir.get(e, .name);
            if (n == .src and n.src.pos == name.src.pos) return boundApis(e);
        }
        return &.{};
    }

    /// The blocks a `rarely` may mark, as their first line: the body of a
    /// function, a branch of `if` or `match`, a `catch` handler, or a
    /// loop. The block then rarely runs: emit starts a function with
    /// Zig's cold hint, and any other block with its unlikely hint
    /// (`funRarely`).
    fn markableBodies(node: Sexp) [2]Sexp {
        return switch (node.kind() orelse return .{ .nil, .nil }) {
            .fun, .sub => .{ ir.get(node, .body), .nil },
            .@"if" => .{ ir.If.then(node), ir.If.@"else"(node) },
            .arm => .{ ir.Arm.body(node), .nil },
            .@"while" => .{ ir.While.body(node), .nil },
            .@"for" => .{ ir.For.body(node), .nil },
            .@"catch" => .{ ir.Catch.handler(node), .nil },
            else => .{ .nil, .nil },
        };
    }

    /// A `rarely` anywhere but the first line of a block it may mark
    /// (`markableBodies`) is rejected: `first` says it is a block's first
    /// line, and `marks` that the block is one it may mark.
    fn strayRarely(self: *Parser, node: Sexp, first: bool, marks: bool) void {
        if (node != .list) return;
        if (node.isKind(.rarely) and !(first and marks)) return self.reject(node, if (first)
            "`rarely` marks the body of a function, a branch of `if` or `match`, a `catch` handler, or a loop"
        else
            "`rarely` is the first line of the block it marks");
        const block = node.isKind(.block);
        const bodies = markableBodies(node);
        // A group (a parameter list) has no kind in front.
        const kids = if (node.kind() != null) node.items()[1..] else node.items();
        for (kids, 0..) |child, i| {
            const body = child == .list and for (bodies) |b| {
                if (b == .list and b.list.id == child.list.id) break true;
            } else false;
            self.strayRarely(child, block and i == 0, if (block) marks and i == 0 else body);
        }
    }

    /// `q, r = f()`: each target but `_` takes the result in its position,
    /// as the binding `(set op q _ (result_part))`, which every pass
    /// reads as the `x = e` it is (docs/internals/INTERNALS.md, "Several
    /// results"). A `_` stays a leaf: its result is left in the
    /// statement's temporary, which drops it at the statement's end.
    fn destructureTargets(self: *Parser, walked: []Sexp) std.mem.Allocator.Error!void {
        const slot = ir.slot(.destructure, .targets);
        const group = walked[slot];
        const op = walked[ir.slot(.destructure, .op)];
        const targets = group.items();
        const out = try self.allocator().alloc(Sexp, targets.len);
        for (targets, out) |t, *o| {
            if (t == .src and std.mem.eql(u8, leafText(self.base.source, t.src), "_")) {
                o.* = t;
                continue;
            }
            const at = self.span(t);
            const part = try self.base.newNode(.result_part, &.{}, at);
            o.* = try self.base.newNode(.set, &.{ op, t, .nil, part }, at);
        }
        walked[slot] = .{ .list = parser.List.withId(out, group.list.id) };
    }

    /// `s matches .circle(r)` in a condition: the `match` it is, `(as_match (match s (arm
    /// .circle(r) _ pass) (arm _ _ pass)))`. Its first arm goes on with
    /// the rest of the condition and the body; any other value takes the
    /// second, which falls to the `else` (docs/design/matches.md). Every pass
    /// reads its subject and its pattern as a `match`'s, and emit writes
    /// the `match`, which drops a value `<s` took when no arm keeps it.
    fn asMatch(self: *Parser, node: Sexp) std.mem.Allocator.Error!Sexp {
        const at = self.span(node);
        const pattern = ir.get(node, .pattern);
        const pat_at = self.span(pattern);
        const pass = try self.base.newNode(.pass, &.{}, pat_at);
        const arm = try self.base.newNode(.arm, &.{ pattern, .nil, pass }, pat_at);
        const other = try self.base.newNode(.arm, &.{ hiddenLeaf(pat_at.start, .discard), .nil, try self.base.newNode(.pass, &.{}, pat_at) }, pat_at);
        const match = try self.base.newNode(.match, &.{ ir.get(node, .value), arm, other }, at);
        return self.base.newNode(.as_match, &.{match}, at);
    }

    /// Lowers each `matches` among the children `walked` of a node of
    /// `kind` just walked: in the condition of an `if` or `while`, a
    /// `matches` that binds is the one-arm `match` `as_match` is, whose
    /// names the rest of the condition and the body see
    /// (`lowerCondition`); anywhere else it is a `Bool`, and names it
    /// binds flow right through `and` (`lowerValue`). An `and` or a
    /// parenthesis leaves its `matches` to the node around it, which
    /// knows where it stands.
    fn lowerMatches(self: *Parser, kind: ?parser.Tag, walked: []Sexp) std.mem.Allocator.Error!void {
        if (kind == .@"and" or kind == .paren) return;
        for (walked, 0..) |*child, i| {
            if (!pendingMatches(child.*)) continue;
            const cond = (kind == .@"if" and i == ir.slot(.@"if", .cond)) or (kind == .@"while" and i == ir.slot(.@"while", .cond));
            child.* = if (cond) try self.lowerCondition(child.*) else try self.lowerValue(child.*);
        }
    }

    /// Whether `e` is a `matches` not yet lowered, or an `and` or a
    /// parenthesis with one on its spine.
    fn pendingMatches(e: Sexp) bool {
        if (e.isKind(.matches)) return true;
        if (e.isKind(.paren)) return pendingMatches(ir.Paren.value(e));
        if (e.isKind(.@"and")) return pendingMatches(ir.get(e, .left)) or pendingMatches(ir.get(e, .right));
        return false;
    }

    /// A condition's `matches`, each part its `and`s join: one that binds
    /// or takes its subject (`<s`) is `as_match`, and any other a `Bool`.
    fn lowerCondition(self: *Parser, e: Sexp) std.mem.Allocator.Error!Sexp {
        if (e.isKind(.@"and")) {
            const items = @constCast(e.items());
            items[ir.slot(.@"and", .left)] = try self.lowerCondition(items[ir.slot(.@"and", .left)]);
            items[ir.slot(.@"and", .right)] = try self.lowerCondition(items[ir.slot(.@"and", .right)]);
            return e;
        }
        // So is one that takes its subject, whose fields the pattern
        // leaves out drop at the end of the block.
        if (e.isKind(.matches) and (matchesBinds(self.base.source, ir.get(e, .pattern)) or ir.get(e, .value).isKind(.move))) return self.asMatch(e);
        return self.lowerValue(e);
    }

    /// A `matches` where a `Bool` goes: `x matches P` is `match x` with
    /// `P => true` and `_ => false`. A chain of `and` whose part binds
    /// names is that match with the rest of the chain for `P`'s value,
    /// so the names flow right: `x matches .ready(s) and s > 0`.
    fn lowerValue(self: *Parser, e: Sexp) std.mem.Allocator.Error!Sexp {
        if (e.isKind(.paren)) {
            const items = @constCast(e.items());
            items[ir.slot(.paren, .value)] = try self.lowerValue(items[ir.slot(.paren, .value)]);
            return e;
        }
        if (!e.isKind(.@"and")) {
            if (!e.isKind(.matches)) return e;
            if (matchesBinds(self.base.source, ir.get(e, .pattern))) self.unreadBinding(e);
            return self.boolMatch(e, null);
        }
        var parts: std.ArrayList(Sexp) = .empty;
        try self.andParts(e, &parts);
        return self.lowerChain(parts.items);
    }

    /// The parts of the chain of `and` `e`, left to right.
    fn andParts(self: *Parser, e: Sexp, out: *std.ArrayList(Sexp)) std.mem.Allocator.Error!void {
        if (e.isKind(.@"and")) {
            try self.andParts(ir.get(e, .left), out);
            try self.andParts(ir.get(e, .right), out);
            return;
        }
        try out.append(self.allocator(), e);
    }

    fn lowerChain(self: *Parser, parts: []const Sexp) std.mem.Allocator.Error!Sexp {
        var i: usize = 0;
        var left: Sexp = .nil;
        while (i < parts.len) : (i += 1) {
            const p = parts[i];
            const part = if (p.isKind(.matches) and matchesBinds(self.base.source, ir.get(p, .pattern))) blk: {
                if (i + 1 == parts.len) self.unreadBinding(p);
                const rest = if (i + 1 == parts.len) null else try self.lowerChain(parts[i + 1 ..]);
                i = parts.len;
                break :blk try self.boolMatch(p, rest);
            } else try self.lowerValue(p);
            left = if (left == .nil) part else try self.base.newNode(.@"and", &.{ left, part }, .{ .start = self.span(left).start, .end = self.span(part).end });
        }
        return left;
    }

    /// `x matches P` as `match x` with `P => then` (`true` when null) and
    /// `_ => false`; the hidden leaves stand inside the `matches` keyword,
    /// where no other leaf does.
    fn boolMatch(self: *Parser, node: Sexp, then: ?Sexp) std.mem.Allocator.Error!Sexp {
        const at = self.span(node);
        const kw = self.matchesKeyword(node);
        const pattern = ir.get(node, .pattern);
        const pat_at = self.span(pattern);
        const yes = then orelse hiddenLeaf(kw + 1, .true_value);
        const arm = try self.base.newNode(.arm, &.{ pattern, .nil, yes }, pat_at);
        const other = try self.base.newNode(.arm, &.{ hiddenLeaf(kw, .discard), .nil, hiddenLeaf(kw + 2, .false_value) }, pat_at);
        return self.base.newNode(.match, &.{ ir.get(node, .value), arm, other }, at);
    }

    /// Where the `matches` keyword of `node` starts: after its value.
    fn matchesKeyword(self: *Parser, node: Sexp) u32 {
        const src = self.base.source;
        const from = self.span(ir.get(node, .value)).end;
        return @intCast(std.mem.indexOfPos(u8, src, from, "matches") orelse from);
    }

    /// A `matches` whose names nothing can read: one in a `Bool` position
    /// that no `and` follows. Its pattern without the names is the test
    /// it means: a field bound by a name is left out, and `r?` is `_?`.
    fn unreadBinding(self: *Parser, node: Sexp) void {
        const src = self.base.source;
        const pattern = ir.get(node, .pattern);
        var names: std.ArrayList(Sexp) = .empty;
        bindingLeaves(src, pattern, &names, self.allocator()) catch return;
        if (names.items.len == 0) return;
        const first = self.span(names.items[0]);
        const alts: []const Sexp = if (pattern.isKind(.alt_pattern)) ir.AltPattern.alts(pattern) else (&pattern)[0..1];
        var out: std.ArrayList(u8) = .empty;
        const a = self.allocator();
        if (alts.len > 1) out.append(a, '(') catch return;
        for (alts, 0..) |alt, i| {
            if (i > 0) out.appendSlice(a, ", ") catch return;
            self.unboundText(alt, &out) catch return;
        }
        if (alts.len > 1) out.append(a, ')') catch return;
        self.reject(node, self.format("`{s}` is bound but never read; write `{s}`", .{ src[first.start..first.end], out.items }));
    }

    /// Pattern `alt` as `unreadBinding` writes it, its names gone.
    fn unboundText(self: *Parser, alt: Sexp, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
        const src = self.base.source;
        const a = self.allocator();
        const at = self.span(alt);
        if (!alt.isKind(.variant_pattern)) return out.appendSlice(a, src[at.start..at.end]);
        try out.appendSlice(a, src[at.start..self.span(ir.VariantPattern.name(alt)).end]);
        var n: usize = 0;
        for (ir.VariantPattern.bindings(alt)) |b| {
            const keyed = b.isKind(.kwarg);
            const v = if (keyed) ir.Kwarg.value(b) else b;
            if (!v.isKind(.some_pattern) and !v.isKind(.none_pattern)) continue;
            try out.appendSlice(a, if (n == 0) "(" else ", ");
            n += 1;
            if (keyed) try out.print(a, "{s}: ", .{leafText(src, ir.Kwarg.name(b).src)});
            try out.appendSlice(a, if (v.isKind(.some_pattern)) "_?" else "none");
        }
        if (n > 0) try out.append(a, ')');
    }

    /// The rules of a `matches` as written: a list holds two or more
    /// alternatives, and none is `none`. (Whether one matches every value
    /// waits for the names: a constant compares.)
    fn checkMatches(self: *Parser, node: Sexp) void {
        const src = self.base.source;
        const pattern = ir.get(node, .pattern);
        const value = self.span(ir.get(node, .value));
        const alts: []const Sexp = if (pattern.isKind(.alt_pattern)) ir.AltPattern.alts(pattern) else (&pattern)[0..1];
        if (pattern.isKind(.alt_pattern) and alts.len == 1) {
            const one = self.span(alts[0]);
            return self.reject(pattern, self.format("write `{s} matches {s}`: a list holds two or more alternatives", .{ src[value.start..value.end], src[one.start..one.end] }));
        }
        for (alts) |alt| if (alt == .src and std.mem.eql(u8, leafText(src, alt.src), "none")) {
            return self.reject(alt, self.format("write `{s} == none`: an optional is tested against `none` with `==`, and `matches` tests a variant or a value", .{src[value.start..value.end]}));
        };
    }

    /// `.ready(none)`: a payload position that holds `none` tests that the
    /// optional field holds none, `(none_pattern none)`, and binds
    /// nothing.
    fn pbindNone(self: *Parser, walked: []Sexp) std.mem.Allocator.Error!void {
        const src = self.base.source;
        for (walked[ir.slot(.variant_pattern, .name) + 1 ..]) |*b| {
            const slot: *Sexp = if (b.isKind(.kwarg)) &@constCast(b.items())[ir.slot(.kwarg, .value)] else b;
            if (slot.* == .src and std.mem.eql(u8, leafText(src, slot.src), "none")) slot.* = try self.base.newNode(.none_pattern, &.{slot.*}, self.span(slot.*));
        }
    }

    /// `if f() as a, b`: each name but `_` is a new binding of the result
    /// in its position, `(set shadow a _ (result_part))`, as a
    /// destructure's target is (`destructureTargets`).
    fn resultNames(self: *Parser, walked: []Sexp) std.mem.Allocator.Error!void {
        const slot = ir.slot(.as_results, .names);
        const group = walked[slot];
        const names = group.items();
        const out = try self.allocator().alloc(Sexp, names.len);
        for (names, out) |n, *o| {
            if (n == .src and std.mem.eql(u8, leafText(self.base.source, n.src), "_")) {
                o.* = n;
                continue;
            }
            const at = self.span(n);
            const part = try self.base.newNode(.result_part, &.{}, at);
            o.* = try self.base.newNode(.set, &.{ .{ .tag = .shadow }, n, .nil, part }, at);
        }
        walked[slot] = .{ .list = parser.List.withId(out, group.list.id) };
    }

    /// A module-level binding is a constant, written with `=`: its
    /// `(set _ ...)` becomes `(set fixed ...)`, the fixed binding every
    /// pass reads. A `=!` there is rejected, as it would say nothing
    /// more.
    fn moduleConsts(self: *Parser, module: Sexp) void {
        for (ir.Module.decls(module)) |decl| {
            const set = if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
            if (!set.isKind(.set)) continue;
            switch (bindingKindOf(ir.Set.op(set))) {
                .default => @constCast(set.items())[ir.slot(.set, .op)] = .{ .tag = .fixed },
                .fixed => {
                    const src = self.base.source;
                    const target = self.span(ir.Set.target(set));
                    const value = self.span(ir.Set.value(set));
                    const ty = ir.Set.type(set);
                    const annot = if (ty == .nil) "" else src[target.end..self.span(ty).end];
                    const shown = src[value.start..value.end];
                    const short = shown.len <= 40 and std.mem.findScalar(u8, shown, '\n') == null;
                    self.reject(set, self.format("a module-level binding is already a constant; write `{s}{s} = {s}`", .{ src[target.start..target.end], annot, if (short) shown else "..." }));
                },
                else => {},
            }
        }
    }

    /// A function's parameter list is always written, even when empty,
    /// as its calls and its type write theirs: `sub main()`, not `sub
    /// main`. The grammar parses a definition without one so that the
    /// fix-it can show the header with it.
    fn paramList(self: *Parser, def: Sexp) std.mem.Allocator.Error!void {
        if (ir.get(def, .params) != .nil) return;
        const src = self.base.source;
        const name = ir.get(def, .name);
        const start = self.span(def).start;
        if (try self.ctFunShape(def)) return;
        // The list goes after the name and its compile-time parameters.
        const at = self.afterTparams(name);
        var end = at;
        while (end < src.len and src[end] != '\n' and src[end] != '#') end += 1;
        const rest = std.mem.trimEnd(u8, src[at..end], " \t\r");
        const message = self.format("write `{s}(){s}`: a function's parameter list is always written, even when empty", .{ src[start..at], rest });
        if (self.failure == null) return self.reject(name, message);
        const at_name = self.span(name);
        try self.more_failures.append(self.allocator(), .{ .severity = .@"error", .pos = at_name.start, .end = at_name.end, .message = message });
    }

    /// Where a definition's header goes on after its name and its
    /// compile-time parameters, `[...]`.
    fn afterTparams(self: *Parser, name: Sexp) usize {
        const src = self.base.source;
        var at: usize = self.span(name).end;
        var probe = at;
        while (probe < src.len and src[probe] == ' ') probe += 1;
        if (probe < src.len and src[probe] == '[') {
            var depth: u32 = 0;
            while (probe < src.len) : (probe += 1) {
                if (src[probe] == '[') depth += 1;
                if (src[probe] == ']') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            at = @min(probe + 1, src.len);
        }
        return at;
    }

    /// A `fun` with compile-time parameters and no run-time list is a
    /// compile-time function (`isCtFun`), declared at module level, whose
    /// every parameter is a value (`n: Int`) and which gives a value
    /// (`-> T`). True when `def` takes that form: accepted, or rejected
    /// here with why. False when it is a run-time function missing its
    /// list, which the caller's fix-it shows.
    fn ctFunShape(self: *Parser, def: Sexp) std.mem.Allocator.Error!bool {
        if (!def.isKind(.fun) and !def.isKind(.sub)) return false;
        const tparams = ir.get(def, .tparams);
        if (tparams == .nil or tparams.items().len == 0) return false;
        for (tparams.items()) |p| if (!p.isKind(.@":")) return false;
        const src = self.base.source;
        const name = ir.get(def, .name);
        const header = src[self.span(name).start..self.afterTparams(name)];
        if (def.isKind(.sub)) {
            self.reject(name, self.format("a compile-time function gives a value: write `fun {s} -> T`; a `sub` writes its parameter list: `sub {s}()`", .{ header, header }));
            return true;
        }
        if (!def.isKind(.fun)) return false;
        if (self.type_depth > 0 or ir.get(def, .owner) != .nil) {
            self.reject(name, self.format("a compile-time function is declared at module level; a method writes its parameter list: `fun {s}(?@)`", .{header}));
            return true;
        }
        const mark = ir.get(def, .mark);
        if (mark != .nil) {
            self.reject(mark, self.format("`{s}` is a compile-time function, which the checker runs, so no call of it is left to mark `{s}`: drop the `{s}`", .{ header, @tagName(mark.kind().?), @tagName(mark.kind().?) }));
            return true;
        }
        if (ir.Fun.returns(def) == .nil) {
            self.reject(name, self.format("a compile-time function gives a value: write its type, `fun {s} -> T`", .{header}));
            return true;
        }
        if (ir.get(def, .body) == .nil) {
            self.reject(name, self.format("`{s}` runs in the compiler, which runs only Rig: give it a body", .{header}));
            return true;
        }
        if (ir.get(def, .origins) != .nil or ir.get(def, .keeps) != .nil) {
            self.reject(name, self.format("`{s}` gives a value made at compile time, which views nothing: drop its `from` and `keeps`", .{header}));
            return true;
        }
        return true;
    }

    /// The rejections after the first (`diagnostic()`), in source order.
    pub fn moreDiagnostics(self: *const Parser) []const diag.Diagnostic {
        return if (self.failure != null) self.more_failures.items else &.{};
    }

    /// `pub` on a field or method: the member stands in the member list
    /// as itself, as every pass reads it, and its name is in the type's
    /// `pubs` group; a field declared `pub ?name: T` is also in its
    /// `read_only` group (`inNames`).
    fn pubMembers(self: *Parser, node: Sexp) std.mem.Allocator.Error!void {
        const is_enum = node.isKind(.@"enum") or node.isKind(.generic_enum) or node.isKind(.errors);
        var pubs: std.ArrayList(Sexp) = .empty;
        var read_only: std.ArrayList(Sexp) = .empty;
        for (@constCast(ir.rest(node, .members))) |*m| {
            // `?len: Int` alone: `?` says who may read a field, and only a
            // `pub` field is read by anyone but its own module.
            if (readOnlyField(m.*)) |field| {
                self.reject(m.*, "`?` before a field means other modules may read it but not write it, which only a `pub` field allows: write `pub ?name: T`, or drop the `?`");
                m.* = field;
                continue;
            }
            if (!m.isKind(.@"pub")) continue;
            var inner = ir.Pub.decl(m.*);
            // `pub ?len: Int`: public to read, written only by this module.
            if (readOnlyField(inner)) |field| {
                if (is_enum) self.reject(m.*, "an enum has no fields to make read-only");
                try read_only.append(self.allocator(), memberName(field));
                inner = field;
            }
            // A bare name is a variant; in an object, the checker rejects
            // it, and any other member that is not a field or method.
            switch (inner.kind() orelse .variant) {
                .@":", .default, .fun, .sub => {},
                .drop_decl => self.reject(m.*, "a `drop` body is never called by name, so it takes no `pub`"),
                .@"pub" => self.reject(inner, "`pub` is written once"),
                else => if (is_enum) self.reject(m.*, "an enum's variants are always public; remove the `pub`"),
            }
            if (inner == .list) try pubs.append(self.allocator(), memberName(inner));
            m.* = inner;
        }
        try self.memberGroups(node, pubs.items, read_only.items);
    }

    /// The slot of a type declaration of `kind`'s `pubs` group; its
    /// `read_only` group is the next.
    fn pubsSlot(kind: parser.Tag) usize {
        return switch (kind) {
            .@"struct" => ir.slot(.@"struct", .pubs),
            .@"enum" => ir.slot(.@"enum", .pubs),
            .errors => ir.slot(.errors, .pubs),
            .generic_struct => ir.slot(.generic_struct, .pubs),
            .generic_enum => ir.slot(.generic_enum, .pubs),
            .api => ir.slot(.api, .pubs),
            .api_add => ir.slot(.api_add, .pubs),
            else => unreachable,
        };
    }

    comptime {
        for ([_]parser.Tag{ .@"struct", .@"enum", .errors, .generic_struct, .generic_enum, .api, .api_add }) |k|
            std.debug.assert(ir.slot(k, .read_only) == ir.slot(k, .pubs) + 1);
    }

    /// Sets the type declaration `node`'s `pubs` and `read_only` groups,
    /// each the names given, or `_` where none.
    fn memberGroups(self: *Parser, node: Sexp, pubs: []const Sexp, read_only: []const Sexp) std.mem.Allocator.Error!void {
        const slot = pubsSlot(node.kind().?);
        const items = @constCast(node.items());
        const at = self.span(node);
        if (pubs.len > 0) items[slot] = try self.base.newList(pubs, at);
        if (read_only.len > 0) items[slot + 1] = try self.base.newList(read_only, at);
    }

    /// A method declared outside its type's body is the member it names
    /// (docs/internals/INTERNALS.md, "Methods outside the body"): in a module that
    /// declares `obj T[P]` or `enum T[P]`, `[pub] fun T[P].m(...)` is
    /// `[pub] fun m(...)` appended to `T`'s members, with `T`'s
    /// parameters named exactly as the declaration names them. One that
    /// names no such type is set aside (`detached`).
    fn attachMethods(self: *Parser, module: Sexp) std.mem.Allocator.Error!Sexp {
        const a = self.allocator();
        const decls = ir.Module.decls(module);
        var methods: usize = 0;
        for (decls) |d| methods += @intFromBool(ownerOf(d) != .nil);
        if (methods == 0) return module;
        const src = self.base.source;
        // Each type's members, with the methods it gains appended.
        var added = std.AutoArrayHashMapUnmanaged(usize, std.ArrayList(Sexp)).empty;
        // The names of the `pub` methods each type gains.
        var added_pubs = std.AutoArrayHashMapUnmanaged(usize, std.ArrayList(Sexp)).empty;
        var kept: std.ArrayList(Sexp) = .empty;
        const head = module.items().len - decls.len;
        try kept.appendSlice(a, module.items()[0..head]);
        for (decls) |d| {
            const owner = ownerOf(d);
            if (owner == .nil) {
                try kept.append(a, d);
                continue;
            }
            const method = if (d.isKind(.@"pub")) ir.Pub.decl(d) else d;
            const at = (if (owner == .src) typeDeclNamed(src, decls, leafText(src, owner.src)) else null) orelse {
                try self.detached.append(a, d);
                continue;
            };
            if (!sameParams(src, ir.get(method, .owner_params), tparamsOf(unpub(decls[at])))) {
                try self.detached.append(a, d);
                continue;
            }
            const items = @constCast(method.items());
            const fun = method.isKind(.fun);
            items[if (fun) ir.slot(.fun, .owner) else ir.slot(.sub, .owner)] = .nil;
            items[if (fun) ir.slot(.fun, .owner_params) else ir.slot(.sub, .owner_params)] = .nil;
            items[if (fun) ir.slot(.fun, .outside) else ir.slot(.sub, .outside)] = .{ .tag = .outside };
            if (d.isKind(.@"pub")) {
                const pubs = try added_pubs.getOrPut(a, at);
                if (!pubs.found_existing) pubs.value_ptr.* = .empty;
                try pubs.value_ptr.append(a, ir.get(method, .name));
            }
            const entry = try added.getOrPut(a, at);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(a, method);
        }
        const out = kept.items;
        for (out[head..]) |*d| {
            const at = std.mem.indexOfScalar(usize, added.keys(), indexIn(decls, d.*) orelse continue) orelse continue;
            const extra = added.values()[at].items;
            const ty = unpub(d.*);
            const members = try std.mem.concat(a, Sexp, &.{ ty.items(), extra });
            const node: Sexp = .{ .list = parser.List.withId(members, ty.list.id) };
            if (added_pubs.get(indexIn(decls, d.*).?)) |names| {
                const slot = pubsSlot(ty.kind().?);
                const had: []const Sexp = if (members[slot] == .list) members[slot].items() else &.{};
                members[slot] = try self.base.newList(try std.mem.concat(a, Sexp, &.{ had, names.items }), self.span(ty));
            }
            if (d.isKind(.@"pub")) {
                @constCast(d.items())[ir.slot(.@"pub", .decl)] = node;
            } else d.* = node;
        }
        return .{ .list = parser.List.withId(out, module.list.id) };
    }

    /// A type declaration's compile-time parameters, or `_`.
    pub fn tparamsOf(ty: Sexp) Sexp {
        return if (ir.has(ty.kind() orelse return .nil, .tparams)) ir.get(ty, .tparams) else .nil;
    }

    /// The owner of a method declared outside a body, or `_`.
    fn ownerOf(decl: Sexp) Sexp {
        const d = unpub(decl);
        return if (d.isKind(.fun) or d.isKind(.sub)) ir.get(d, .owner) else .nil;
    }

    /// The index in `decls` of the `obj` or `enum` named `name`.
    fn typeDeclNamed(src: []const u8, decls: []const Sexp, name: []const u8) ?usize {
        for (decls, 0..) |d, i| {
            const t = unpub(d);
            switch (t.kind() orelse continue) {
                .@"struct", .@"enum", .generic_struct, .generic_enum => {},
                else => continue,
            }
            const n = ir.get(t, .name);
            if (n == .src and std.mem.eql(u8, leafText(src, n.src), name)) return i;
        }
        return null;
    }

    fn indexIn(decls: []const Sexp, d: Sexp) ?usize {
        for (decls, 0..) |e, i| if (e == .list and d == .list and e.list.id == d.list.id) return i;
        return null;
    }

    /// Whether a method's owner names its type's parameters (`[T, n]`)
    /// exactly as the type's declaration does (`[T, n: Int]`): the same
    /// names, bare, in the same order.
    pub fn sameParams(src: []const u8, written: Sexp, declared: Sexp) bool {
        const w = if (written == .nil) &[_]Sexp{} else written.items();
        const d = if (declared == .nil) &[_]Sexp{} else declared.items();
        if (w.len != d.len) return false;
        for (w, d) |x, y| {
            if (x != .src) return false;
            const name = if (y.isKind(.@":")) ir.get(y, .name) else y;
            if (name != .src or !std.mem.eql(u8, leafText(src, x.src), leafText(src, name.src))) return false;
        }
        return true;
    }

    /// The field `?name: T` (or `?name: T = v`) declares, or null: the
    /// grammar reads the `?` as a read sigil around the field.
    fn readOnlyField(m: Sexp) ?Sexp {
        if (!m.isKind(.read)) return null;
        const field = ir.Read.operand(m);
        return if (field.isKind(.@":") or field.isKind(.default)) field else null;
    }

    /// `a ?? b ?? c`: the grammar reads a chain left to right, `(a ?? b)
    /// ?? c`, and every pass reads it nested to the right, `a ?? (b ??
    /// c)`, which gives the same value and lets each fallback have the
    /// payload's type. A parenthesized left side keeps its grouping: it
    /// is a `paren`. A jump fallback is `nearestFallback`'s.
    fn rightNested(self: *Parser, node: Sexp) std.mem.Allocator.Error!Sexp {
        const right = ir.@"??".right(node);
        if (right.kind()) |k| switch (k) {
            .@"return", .@"break", .@"continue" => return node,
            else => {},
        };
        // A parenthesized left side, `(a ?? b) ?? c`, is a group of its own.
        const left = ir.@"??".left(node);
        if (!left.isKind(.@"??")) return node;
        const middle = ir.@"??".right(left);
        // The new right side starts where `middle` is written; a grouped
        // `middle` is a `paren`, whose span holds its parentheses.
        const inner = try self.rightNested(try self.base.newNode(.@"??", &.{ middle, right }, .{ .start = self.span(middle).start, .end = self.span(node).end }));
        return self.base.newNode(.@"??", &.{ ir.@"??".left(left), inner }, self.span(node));
    }

    /// `a ?? b ?? return v`: the grammar reads a jump fallback after the
    /// whole chain before it, `(a ?? b) ?? return v`; `??` is
    /// right-associative, so the jump goes to the innermost right side,
    /// `a ?? (b ?? return v)`. A parenthesized left side keeps its
    /// grouping: it is a `paren`.
    fn nearestFallback(self: *Parser, node: Sexp) std.mem.Allocator.Error!Sexp {
        const right = ir.@"??".right(node);
        switch (right.kind() orelse return node) {
            .@"return", .@"break", .@"continue" => {},
            else => return node,
        }
        // A parenthesized left side, `(a ?? b) ?? c`, is a group of its own.
        const left = ir.@"??".left(node);
        if (!left.isKind(.@"??")) return node;
        return self.attachFallback(left, right);
    }

    /// `chain ?? jump`, the jump attached to the last right side of the
    /// `??` chain that is not parenthesized.
    fn attachFallback(self: *Parser, chain: Sexp, jump: Sexp) std.mem.Allocator.Error!Sexp {
        const inner = ir.@"??".right(chain);
        const grouped = !inner.isKind(.@"??");
        const new_right = if (grouped)
            try self.base.newNode(.@"??", &.{ inner, jump }, .{ .start = self.span(inner).start, .end = self.span(jump).end })
        else
            try self.attachFallback(inner, jump);
        return self.base.newNode(.@"??", &.{ ir.@"??".left(chain), new_right }, .{ .start = self.span(chain).start, .end = self.span(jump).end });
    }

    /// `*(T?)`, `~(T?)`, `*(~T?)`: a `?` suffix sits inside parentheses
    /// within a chain of handles, so it belongs to what a handle holds.
    /// In `*T?`, `*~T?`, and `*(T)?` every suffix follows the whole chain:
    /// no `?` is inside a `paren` the handles and suffixes reach.
    fn noteParenSuffix(self: *Parser, node: Sexp) std.mem.Allocator.Error!void {
        var op = ir.get(node, .operand);
        while (true) switch (op.kind() orelse return) {
            .share, .weak, .box => op = ir.get(op, .operand),
            .propagate_none => op = ir.PropagateNone.value(op),
            .paren => {
                // `*(~T?)`: a parenthesized handle with a suffix of its own.
                var inner = ir.Paren.value(op);
                while (inner.isKind(.share) or inner.isKind(.weak) or inner.isKind(.box)) inner = ir.get(inner, .operand);
                if (inner.isKind(.propagate_none)) try self.paren_suffixes.put(self.allocator(), node.list.id, {});
                return;
            },
            else => return,
        };
    }

    /// A type's prefix sigil touches its operand. The lexer checks every
    /// other prefix; a sigil after a type's `]` (`[]*T`) reads to it as a
    /// suffix, which may stand apart.
    fn touchesOperand(self: *Parser, node: Sexp) void {
        const at = self.span(node).start;
        const src = self.base.source;
        // The view inside `^?T` has no sigil of its own: the box's `^?` is
        // checked as one token pair.
        if (at >= src.len or std.mem.findScalar(u8, "<>+-?!*~^", src[at]) == null) return;
        if (!isSpace(if (at + 1 < src.len) src[at + 1] else 0) or self.failure != null) return;
        self.failure = .{ .severity = .@"error", .pos = at, .end = at + 1, .message = self.detachedPrefix(.{ .cat = .err, .pre = 0, .pos = at, .len = 1 }) };
    }

    /// Whether `node`, a `share` or `weak`, has a parenthesized suffix in
    /// its operand: `*(T?)`, not `*T?` or `*(T)?`.
    pub fn hasParenSuffix(self: *const Parser, node: Sexp) bool {
        return node == .list and self.paren_suffixes.contains(node.list.id);
    }

    /// `>t`: the call `<t.wait()` makes, `(call _ (member (move t) wait))`,
    /// with a hidden `wait` (`isWaitCall`). Every node spans the `>t`, so
    /// a message quotes it as written, and the move is a self sigil,
    /// as the one `<t.wait()` writes is.
    fn waitCall(self: *Parser, node: Sexp) std.mem.Allocator.Error!Sexp {
        const at = self.span(node);
        const moved = try self.base.newNode(.move, &.{ir.get(node, .operand)}, at);
        try self.self_sigils.put(self.allocator(), moved.list.id, {});
        const member = try self.base.newNode(.member, &.{ moved, hiddenLeaf(at.start, .wait) }, at);
        return self.base.newNode(.call, &.{ .nil, member }, at);
    }

    /// A wait takes a name alone, and a `!` or `?` after it applies to
    /// what it gives: `>t!` is `(>t)!`. Anything else after it is written
    /// on the parenthesized wait, so it never reads as the task's own:
    /// `(>t).len`, not `>t.len`.
    fn waitTakesName(self: *Parser, node: Sexp, head: Sexp) void {
        var w = head;
        while (w.isKind(.propagate) or w.isKind(.propagate_none)) w = ir.get(w, .value);
        // `(>t).len`: a parenthesized wait is a `paren`, and no wait call.
        if (!isWaitCall(w) or self.failure != null) return;
        const src = self.base.source;
        const whole = self.span(node);
        const written = diag.textBetween(src, self.span(head).start, self.span(head).end);
        const rest = diag.textBetween(src, self.span(head).end, whole.end);
        // `>f(x)` and `>f(x)&`: a wait takes a task that is held, which a
        // call is not.
        if (node.isKind(.call) and w.list.id == head.list.id) {
            const call = diag.textBetween(src, self.span(head).start + 1, whole.end);
            self.failure = .{
                .severity = .@"error",
                .pos = self.span(head).start,
                .end = whole.end,
                .message = (if (ir.Call.task(node) != .nil)
                    std.fmt.allocPrint(self.allocator(), "`>{s}` starts a task and waits for it at once, which is the call itself: write `{s}`", .{ call, call[0 .. call.len - 1] })
                else
                    std.fmt.allocPrint(self.allocator(), "`>` waits for a task that is held: make the call a task and bind it, `t = {s}&`, then wait for it, `>t`", .{call})) catch "a wait takes a task that is held: `t = f(x)&`, then `>t`",
            };
            return;
        }
        // `>@t` waits for self: its field is `(>@).t`.
        const dot = if (std.mem.endsWith(u8, written, "@") and rest.len > 0 and isIdentStart(rest[0])) "." else "";
        self.failure = .{
            .severity = .@"error",
            .pos = self.span(head).end,
            .end = whole.end,
            .message = std.fmt.allocPrint(self.allocator(), "`{s}` waits for a task, and `{s}` applies to what it gives: write `({s}){s}{s}`; to wait for a task that `{s}{s}` holds, take it out to a name first, then wait for that, `>t`", .{ written, rest, written, dot, rest, written[1..], rest }) catch "a wait takes a name alone: write `(>t).x`",
        };
    }

    /// Whether `leaf` is a name a `for` over a chain binds (`loop_names`).
    pub fn isLoopName(self: *const Parser, leaf: Sexp) bool {
        return leaf == .src and self.loop_names.contains(leaf.src.pos);
    }

    /// Whether `node` is a self sigil the wrapper moved onto the
    /// self: `!v` in `!v.push(x)`, not in `(!v).push(x)`.
    pub fn isSelfSigil(self: *const Parser, node: Sexp) bool {
        return node == .list and self.self_sigils.contains(node.list.id);
    }

    /// `?`, `!`, and `<` before a place (a name and the fields and elements
    /// after it) followed by a method call apply to the place; the call
    /// and every postfix after it apply to the lent or moved place:
    ///   (write (propagate_none (call (member v pop))))
    ///   → (propagate_none (call (member (write v) pop)))
    /// The sigil reaches the self of the chain's first method call.
    /// A `!` reaches one that is a value no name holds too: one a call
    /// that is no method call makes (`!mk().bump()` is
    /// `(!mk()).bump()`), a literal, or a parenthesized expression
    /// (`!(+s).bump()`); a call of a call's value is walked through to
    /// the first call (`!a.b(x)(y).g()` is `(!a).b(x)(y).g()`). Anything
    /// else keeps its
    /// sigil outside: a chain that is all place (`!x.v`), a `?` or `<`
    /// chain whose head is called (`<f(x).g()`), and one whose spine is
    /// parenthesized (`!(v.pop())`): the chain stops at a `paren`, which
    /// links of a chain keep until this rule has read them (`parenSlot`).
    fn selfSigil(self: *Parser, node: Sexp) std.mem.Allocator.Error!Sexp {
        const tag: parser.Tag = node.kind().?;
        // `!` lends any value to write, so its chain may start from a
        // value no name holds: a call that is no method call
        // (`!mk().bump()`), a literal (`![a, b][0].bump()`), or a
        // parenthesized expression (`!(+s).bump()`).
        const any_head = tag == .write;
        // The chain from the operand down to its head, outermost first.
        var chain: std.ArrayList(Sexp) = .empty;
        var e = ir.get(node, .operand);
        while (true) {
            if (e.isKind(.paren)) {
                if (!any_head or chain.items.len == 0) return node;
                try chain.append(self.allocator(), e);
                break;
            }
            try chain.append(self.allocator(), e);
            e = switch (e.kind() orelse break) {
                .propagate, .propagate_none => ir.get(e, .value),
                .member, .index, .inst => ir.get(e, .object),
                // A call of a call's value (`a.b(x)(y)`) is walked to
                // the first call, as before.
                .call => if (any_head and !isMethodCallee(ir.Call.callee(e)) and !ir.Call.callee(e).isKind(.call)) break else ir.Call.callee(e),
                else => if (any_head) break else return node,
            };
        }
        const spine = chain.items;
        const n = spine.len;
        // Grow the place up from the head through fields and elements,
        // stopping at the member a call follows, directly or after a
        // bracket list (`!v.put[2](x)`, compile-time arguments): the
        // method.
        var top = n - 1;
        while (top > 0) {
            const up = spine[top - 1];
            if (up.isKind(.member) and top >= 2 and spine[top - 2].isKind(.call)) break;
            if (up.isKind(.member) and top >= 3 and isBracketList(spine[top - 2]) and spine[top - 3].isKind(.call)) break;
            if (!up.isKind(.member) and !up.isKind(.index)) return node;
            top -= 1;
        }
        if (top == 0) return node;
        const place = spine[top];
        var out = try self.base.newNode(tag, &.{place}, .{ .start = self.span(node).start, .end = self.span(place).end });
        try self.self_sigils.put(self.allocator(), out.list.id, {});
        var i = top;
        while (i > 0) {
            i -= 1;
            const link = spine[i];
            const slot = switch (link.kind().?) {
                .propagate => ir.slot(.propagate, .value),
                .propagate_none => ir.slot(.propagate_none, .value),
                .member => ir.slot(.member, .object),
                .index => ir.slot(.index, .object),
                .inst => ir.slot(.inst, .object),
                .call => ir.slot(.call, .callee),
                else => unreachable,
            };
            const copy = try self.allocator().dupe(Sexp, link.items());
            copy[slot] = out;
            out = .{ .list = parser.List.withId(copy, link.list.id) };
        }
        return out;
    }

    /// `(lambda _ entries _ body)`: sigiled entries are captures, the
    /// rest parameters. Captures come first.
    fn splitBars(self: *Parser, node: Sexp, items: []Sexp) std.mem.Allocator.Error!void {
        const bars = ir.Lambda.params(node);
        var caps: std.ArrayList(Sexp) = .empty;
        var params: std.ArrayList(Sexp) = .empty;
        var paths: std.ArrayList(Sexp) = .empty;
        for (bars.items()) |e| {
            const is_capture = if (e.kind()) |k| switch (k) {
                .cap_clone, .cap_move, .cap_weak, .cap_read, .cap_write => true,
                else => false,
            } else false;
            if (!is_capture) {
                try params.append(self.allocator(), e);
                continue;
            }
            if (params.items.len > 0) self.reject(e, "captures come before parameters in a closure's bar list: `|+v, a| ...`");
            const cap = try self.capturePlace(e);
            if (isPathCapture(ir.get(cap, .name))) try paths.append(self.allocator(), cap);
            try caps.append(self.allocator(), cap);
        }
        // In the body, each captured path names its capture.
        if (paths.items.len > 0) {
            const at = ir.slot(.lambda, .body);
            items[at] = try self.namePaths(items[at], paths.items);
        }
        items[ir.slot(.lambda, .captures)] = if (caps.items.len > 0) try self.base.newNode(.captures, caps.items, .{
            .start = self.span(caps.items[0]).start,
            .end = self.span(caps.items[caps.items.len - 1]).end,
        }) else .nil;
        items[ir.slot(.lambda, .params)] = if (params.items.len > 0) .{ .list = parser.List.withId(params.items, bars.list.id) } else .nil;
    }

    /// A capture as the grammar gives it, `(cap_read _ place)`, as the
    /// passes read it: a name is the capture's name, `(cap_read x)`; a
    /// field path keeps the lend its sigil makes there as its value, and
    /// a name spanning the path from the sigil, `(cap_read ?p.a (read
    /// (member p a)))`, which the body's paths name (`namePaths`).
    fn capturePlace(self: *Parser, cap: Sexp) std.mem.Allocator.Error!Sexp {
        const kind = cap.kind().?;
        const place = ir.get(cap, .value);
        const out = try self.allocator().alloc(Sexp, 3);
        out[0] = .{ .tag = kind };
        out[ir.slot(.cap_read, .name)] = .nil;
        out[ir.slot(.cap_read, .value)] = .nil;
        const node: Sexp = .{ .list = parser.List.withId(out, cap.list.id) };
        if (place == .src) {
            out[ir.slot(.cap_read, .name)] = place;
            return node;
        }
        const at = self.span(cap);
        const text = self.pathText(place) orelse {
            const shown = diag.textBetween(self.base.source, self.span(place).start, self.span(place).end);
            self.reject(place, if (place.isKind(.index))
                std.fmt.allocPrint(self.allocator(), "a capture names a local or a field of one, not an element: lend it first, `x = ?{s}`, and capture `?x`", .{shown}) catch "a capture names a local or a field of one, not an element"
            else
                std.fmt.allocPrint(self.allocator(), "a capture names a local or a field of one: bind `{s}` to a name first, and capture the name", .{shown}) catch "a capture names a local or a field of one");
            return node;
        };
        const lend: parser.Tag = switch (kind) {
            .cap_clone => .clone,
            .cap_move => .move,
            .cap_weak => .weak,
            .cap_read => .read,
            .cap_write => .write,
            else => unreachable,
        };
        // The name's leaf spans the sigil too, and its `len` stays under
        // 65535, which stands for a long token `leafEnd` scans again.
        if (text.len + 1 >= std.math.maxInt(u16)) {
            self.reject(place, "a captured field path is longer than 65533 bytes; bind it to a shorter name first, and capture the name");
            return node;
        }
        out[ir.slot(.cap_read, .name)] = .{ .src = .{ .pos = at.start, .len = @intCast(text.len + 1), .id = path_capture_id } };
        out[ir.slot(.cap_read, .value)] = try self.base.newNode(lend, &.{place}, at);
        return node;
    }

    /// The source text of `place` when it is a field path written as one
    /// (`p.a.b`, `@template`): a name, or `@`, then `.field` steps, with
    /// nothing between them. Null for anything else.
    fn pathText(self: *const Parser, place: Sexp) ?[]const u8 {
        if (!place.isKind(.member)) return null;
        var root = place;
        while (root.isKind(.member)) root = ir.Member.object(root);
        if (root != .src) return null;
        const extent = self.span(place);
        const text = diag.textBetween(self.base.source, extent.start, extent.end);
        // The path's own text, spelled from its parts, is the source's.
        var p = place;
        var end = text.len;
        while (p.isKind(.member)) : (p = ir.Member.object(p)) {
            const field = leafText(self.base.source, ir.Member.name(p).src);
            if (end < field.len or !std.mem.eql(u8, text[end - field.len .. end], field)) return null;
            end -= field.len;
            const self_member = ir.Member.object(p) == .src and std.mem.eql(u8, leafText(self.base.source, ir.Member.object(p).src), "@");
            if (!self_member) {
                if (end == 0 or text[end - 1] != '.') return null;
                end -= 1;
            }
        }
        if (!std.mem.eql(u8, text[0..end], leafText(self.base.source, root.src))) return null;
        return text;
    }

    /// Whether member chain `node` names the path `text` (`p.a`,
    /// `@template`) by its parts, however it is spaced.
    fn spellsPath(self: *const Parser, node: Sexp, text: []const u8) bool {
        var rest = text;
        var p = node;
        while (p.isKind(.member)) : (p = ir.Member.object(p)) {
            const field = leafText(self.base.source, ir.Member.name(p).src);
            if (!std.mem.endsWith(u8, rest, field)) return false;
            rest = rest[0 .. rest.len - field.len];
            const at_self = ir.Member.object(p) == .src and std.mem.eql(u8, leafText(self.base.source, ir.Member.object(p).src), "@");
            if (!at_self) {
                if (!std.mem.endsWith(u8, rest, ".")) return false;
                rest = rest[0 .. rest.len - 1];
            }
        }
        return p == .src and std.mem.eql(u8, rest, leafText(self.base.source, p.src));
    }

    /// `body` with each member chain that spells a captured path in
    /// `paths` replaced by a name spanning it, which names the capture.
    fn namePaths(self: *Parser, body: Sexp, paths: []const Sexp) std.mem.Allocator.Error!Sexp {
        return try self.namePathsIn(body, paths) orelse body;
    }

    /// `namePaths`, or null when `node` holds no captured path.
    fn namePathsIn(self: *Parser, node: Sexp, paths: []const Sexp) std.mem.Allocator.Error!?Sexp {
        if (node != .list) return null;
        if (node.isKind(.member)) for (paths) |cap| {
            const path = leafText(self.base.source, ir.get(cap, .name).src);
            if (!self.spellsPath(node, path)) continue;
            const text = self.pathText(node) orelse {
                self.reject(node, std.fmt.allocPrint(self.allocator(), "write `{s}`, the path this closure captures, on one line", .{path}) catch "write the path this closure captures on one line");
                return null;
            };
            return .{ .src = .{ .pos = self.span(node).start, .len = @intCast(text.len), .id = 0 } };
        };
        const items = node.items();
        var copy: ?[]Sexp = null;
        for (items, 0..) |child, i| {
            const named = try self.namePathsIn(child, paths) orelse continue;
            if (copy == null) copy = try self.allocator().dupe(Sexp, items);
            copy.?[i] = named;
        }
        return if (copy) |c| .{ .list = parser.List.withId(c, node.list.id) } else null;
    }

    /// A statement `<e` drops what it moves: `(move x)` of a name becomes
    /// `(drop x)`, keeping its node id; `(move e)` of anything else is
    /// held by a new `(drop (move e))`, so that every pass reads the move
    /// as `_ = <e` reads it. `valueTail` undoes it where the value is used.
    fn dropStatement(self: *Parser, slot: *Sexp) std.mem.Allocator.Error!void {
        if (!slot.isKind(.move)) return;
        const operand = ir.Move.operand(slot.*);
        if (operand == .src and isBindingName(self.base.source, operand)) {
            @constCast(slot.items())[0] = .{ .tag = .drop };
            return;
        }
        slot.* = try self.base.newNode(.drop, &.{slot.*}, self.span(slot.*));
    }

    /// A name a binding may have, self, `@`, too: not a literal,
    /// `true`, or `false`.
    fn isBindingName(source: []const u8, leaf: Sexp) bool {
        const text = leafText(source, leaf.src);
        if (std.mem.eql(u8, text, "@")) return true;
        if (text.len == 0 or !isIdentStart(text[0])) return false;
        return keyword(text) == null;
    }

    /// `slot` (already walked, so its lists are freshly allocated) is in
    /// value position: a drop `dropStatement` made of its last statement
    /// is the move again.
    fn valueTail(self: *Parser, slot: *Sexp) std.mem.Allocator.Error!void {
        const kind = slot.kind() orelse return;
        const items = @constCast(slot.items());
        switch (kind) {
            .drop => {
                const target = ir.Drop.target(slot.*);
                if (target == .list) {
                    slot.* = target;
                } else {
                    items[0] = .{ .tag = .move };
                }
            },
            .block => if (items.len > 1) try self.valueTail(&items[items.len - 1]),
            .@"if" => {
                try self.valueTail(&items[ir.slot(.@"if", .then)]);
                try self.valueTail(&items[ir.slot(.@"if", .@"else")]);
            },
            .match => for (ir.Match.arms(slot.*)) |arm| try self.valueTail(&@constCast(arm.items())[ir.slot(.arm, .body)]),
            .@"catch" => try self.valueTail(&items[ir.slot(.@"catch", .handler)]),
            .labeled => try self.valueTail(&items[ir.slot(.labeled, .stmt)]),
            .raw_block => try self.valueTail(&items[ir.slot(.raw_block, .body)]),
            else => {},
        }
    }

    /// A closure whose type returns nothing has no value: the last line
    /// `valueTail` kept as a move, and that of each branch ending it, is a
    /// statement `<e` again, which drops (`dropStatement`). The type
    /// checker calls it on the body of such a closure before any pass reads
    /// it, and it changes nothing a second time.
    pub fn dropTail(self: *const Parser, slot: *Sexp) std.mem.Allocator.Error!void {
        const mutable: *Parser = @constCast(self);
        try mutable.dropTailOf(slot);
    }

    /// A closure that declares fewer parameters than the function type it
    /// is checked against is the same closure with `_` for each trailing
    /// parameter it leaves out. The type checker calls it on a closure
    /// literal before any pass reads the parameters; it changes nothing
    /// when the closure already has `count` parameters.
    pub fn padLambda(self: *const Parser, lambda: Sexp, count: usize) std.mem.Allocator.Error!void {
        const mutable: *Parser = @constCast(self);
        const slot = &@constCast(lambda.items())[ir.slot(.lambda, .params)];
        const have = slot.items();
        if (have.len >= count) return;
        const out = try mutable.allocator().alloc(Sexp, count);
        @memcpy(out[0..have.len], have);
        const at = mutable.span(lambda).start;
        for (out[have.len..]) |*p| p.* = hiddenLeaf(try mutable.hiddenPos(at), .discard);
        slot.* = try mutable.base.newList(out, .{ .start = at, .end = at });
    }

    fn dropTailOf(self: *Parser, slot: *Sexp) std.mem.Allocator.Error!void {
        const kind = slot.kind() orelse return;
        const items = @constCast(slot.items());
        switch (kind) {
            .move => try self.dropStatement(slot),
            .block => if (items.len > 1) try self.dropTailOf(&items[items.len - 1]),
            .@"if" => {
                try self.dropTailOf(&items[ir.slot(.@"if", .then)]);
                try self.dropTailOf(&items[ir.slot(.@"if", .@"else")]);
            },
            .match => for (ir.Match.arms(slot.*)) |arm| try self.dropTailOf(&@constCast(arm.items())[ir.slot(.arm, .body)]),
            .labeled => try self.dropTailOf(&items[ir.slot(.labeled, .stmt)]),
            .raw_block => try self.dropTailOf(&items[ir.slot(.raw_block, .body)]),
            else => {},
        }
    }

    // -------------------------------------------------------------------------
    // Loops over an iterator
    //
    // Typecheck finds the `for` loops whose source is an iterator, since
    // the type of a source is known only there, and the module is checked
    // again on this rewrite (docs/internals/INTERNALS.md, "Loops over an iterator").
    // The nodes it builds are IR nodes like the parser's: each spans the
    // loop's source, and a name no source text holds (a method's `next`,
    // the hidden binding) is a leaf at a position inside the loop's `for`
    // keyword, which no other leaf has, with the name's text from
    // `leafText`. So every position the checkers order by lies in the loop,
    // as in the loop written by hand.
    // -------------------------------------------------------------------------

    const IterRewrite = struct {
        loops: []const IterLoop,

        fn find(self: IterRewrite, node: Sexp) ?usize {
            if (node != .list or !node.isKind(.@"for")) return null;
            for (self.loops, 0..) |l, i| if (l.node == node.list.id) return i;
            return null;
        }
    };

    /// Each string literal of `lits` in `tree` as the literal it is
    /// where it stands: where a `U8` goes, the integer leaf of its byte,
    /// spanning the string; where a `[N]U8` goes, the array literal of
    /// its bytes, each a leaf inside the string, so that no two share a
    /// position. Every other node keeps its position and id.
    pub fn byteLiterals(self: *Parser, tree: Sexp, lits: []const ByteLiteral) std.mem.Allocator.Error!void {
        if (lits.len == 0) return;
        var at: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        defer at.deinit(self.allocator());
        for (lits, 0..) |l, i| try at.put(self.allocator(), l.pos, i);
        try self.bytesIn(tree, lits, &at);
    }

    fn bytesIn(self: *Parser, node: Sexp, lits: []const ByteLiteral, at: *const std.AutoHashMapUnmanaged(u32, usize)) std.mem.Allocator.Error!void {
        if (node != .list) return;
        for (@constCast(node.items())) |*slot| switch (slot.*) {
            .src => |leaf| if (at.get(leaf.pos)) |i| {
                const lit = lits[i];
                if (!lit.array) {
                    slot.* = byteLeaf(leaf.pos, leaf.len, lit.bytes[0]);
                    continue;
                }
                const elems = try self.allocator().alloc(Sexp, lit.bytes.len);
                for (lit.bytes, elems, 0..) |b, *e, k| e.* = byteLeaf(leaf.pos + 1 + @as(u32, @intCast(k)), 1, b);
                slot.* = try self.base.newNode(.array, elems, .{ .start = leaf.pos, .end = leafEnd(self.base.source, leaf) });
            },
            .list => try self.bytesIn(slot.*, lits, at),
            else => {},
        };
    }

    /// Rewrite each `for` of `loops` in `tree` into the `while` it means.
    /// Every other node keeps its position and id.
    /// Each chain of `chains` in `tree` as the loop it means
    /// (docs/design/iterators.md): a value that is a `loop` run
    /// once, which holds the source and binds each stage's function, then
    /// walks the source and gives the consumer's result with `break`; a
    /// `for` over a chain is a block of the same holds around its loop.
    /// Every name it binds is hidden, at a position past the source's end
    /// whose home is the chain (`span`), and a type it needs is written
    /// `(item_type h)`: what the hidden binding `h` gives
    /// (`resolve.TypeResolver.chainItemType`). An inner chain, in a stage's
    /// function, is rewritten first.
    pub fn desugarChains(self: *Parser, tree: Sexp, chains: []const Chain) std.mem.Allocator.Error!void {
        if (tree != .list) return;
        for (@constCast(tree.items())) |*slot| {
            try self.desugarChains(slot.*, chains);
            if (slot.* != .list) continue;
            const id = slot.list.id;
            for (chains) |c| if (c.node == id) {
                slot.* = try self.lowerIterChain(slot.*, c);
                break;
            };
        }
    }

    const ChainStep = struct { name: []const u8, args: []const Sexp, at: u32 };

    /// The rewrite of one chain (`desugarChains`).
    const ChainLowering = struct {
        p: *Parser,
        home: u32,
        extent: parser.Span,
        source: ChainSource,
        steps: []const ChainStep,
        /// Per stage: the hidden name its function is bound to, if any.
        funs: []?HiddenName,
        /// The type of each stage's item before it runs, by the hidden
        /// binding whose `(item_type ...)` it is; and of the item after
        /// the last stage.
        item_of: []HiddenName,
        /// The second value each stage after `enumerate` or `zip` passes,
        /// and the hidden binding whose `(item_type ...)` is its type,
        /// bound before the loop.
        second_of: []?HiddenName,
        second_ty: []?HiddenName,
        /// Per stage number: whether the second value an `enumerate` or
        /// `zip` there passes is read, by a later stage's or the
        /// consumer's function or a `for`'s index. One no one reads is
        /// not bound.
        pair_read: []bool,
        /// What a `zip`'s second source is (`Chain.zip`).
        zip: ChainSource = .elements,
        zip_copies: bool = true,
        /// The consumer is `count`, which reads no item.
        counts: bool = false,
        /// An element source's elements are plain data (`Chain.copies`).
        copies: bool = true,
        /// A range source includes its end (`a..=b`).
        inclusive: bool = false,

        fn leaf(l: *const ChainLowering, name: HiddenName) std.mem.Allocator.Error!Sexp {
            return l.p.synthLeaf(l.home, name);
        }

        fn node(l: *const ChainLowering, kind: parser.Tag, kids: []const Sexp) std.mem.Allocator.Error!Sexp {
            return l.p.base.newNode(kind, kids, l.extent);
        }

        fn itemType(l: *const ChainLowering, of: HiddenName) std.mem.Allocator.Error!Sexp {
            return l.node(.item_type, &.{try l.leaf(of)});
        }

        fn itemValue(l: *const ChainLowering, of: HiddenName) std.mem.Allocator.Error!Sexp {
            return l.node(.item_value, &.{try l.leaf(of)});
        }

        /// `new name: ty = value`.
        fn bind(l: *const ChainLowering, name: HiddenName, ty: Sexp, value: Sexp) std.mem.Allocator.Error!Sexp {
            return l.node(.set, &.{ .{ .tag = .shadow }, try l.leaf(name), ty, value });
        }

        fn assign(l: *const ChainLowering, name: HiddenName, value: Sexp) std.mem.Allocator.Error!Sexp {
            return l.node(.set, &.{ .nil, try l.leaf(name), .nil, value });
        }

        fn addTo(l: *const ChainLowering, name: HiddenName, value: Sexp) std.mem.Allocator.Error!Sexp {
            return l.node(.set, &.{ .{ .tag = .@"+=" }, try l.leaf(name), .nil, value });
        }

        fn call(l: *const ChainLowering, f: HiddenName, with: []const HiddenName) std.mem.Allocator.Error!Sexp {
            var items: [4]Sexp = undefined;
            items[0] = .nil;
            items[1] = try l.leaf(f);
            for (with, 0..) |a, i| items[2 + i] = try l.leaf(a);
            return l.node(.call, items[0 .. 2 + with.len]);
        }

        /// The element at index binding `at` of the held source: a copy
        /// of plain data, a read view of anything else.
        fn elem(l: *const ChainLowering, at: HiddenName) std.mem.Allocator.Error!Sexp {
            const e = try l.node(.index, &.{ try l.leaf(.chain_source), try l.leaf(at) });
            return if (l.copies) e else l.node(.read, &.{e});
        }

        fn callOn(l: *const ChainLowering, f: HiddenName, arg: Sexp) std.mem.Allocator.Error!Sexp {
            return l.node(.call, &.{ .nil, try l.leaf(f), arg });
        }

        /// Whether a consumer that keeps an item keeps its index instead:
        /// an element source no `map` changed, whose loop item is a view
        /// the loop lends (or a copy, read again at the end).
        fn keepsIndex(l: *const ChainLowering) bool {
            if (l.source != .elements) return false;
            for (l.steps) |st| if (eq(st.name, "map")) return false;
            return true;
        }

        fn block(l: *const ChainLowering, stmts: []const Sexp) std.mem.Allocator.Error!Sexp {
            return l.node(.block, stmts);
        }

        fn when(l: *const ChainLowering, cond: Sexp, stmts: []const Sexp) std.mem.Allocator.Error!Sexp {
            return l.node(.@"if", &.{ cond, try l.block(stmts), .nil });
        }

        fn brk(l: *const ChainLowering, value: Sexp) std.mem.Allocator.Error!Sexp {
            return l.node(.@"break", &.{ value, .nil });
        }

        /// How a stage ends the chain's walk: a `break`.
        fn stop(l: *const ChainLowering) std.mem.Allocator.Error!Sexp {
            return l.brk(.nil);
        }

        fn skip(l: *const ChainLowering) std.mem.Allocator.Error!Sexp {
            return l.node(.@"continue", &.{.nil});
        }

        fn passed(l: *const ChainLowering, i: usize) std.mem.Allocator.Error![]const HiddenName {
            const s = l.second_of[i] orelse return &.{.chain_item};
            return l.p.allocator().dupe(HiddenName, &.{ .chain_item, s });
        }

        /// The statements each stage runs on an item, in order, into
        /// `body`: a filter skips it, a map binds the item again, a count
        /// stops or skips. Written once per loop of the chain.
        fn stages(l: *const ChainLowering, body: *std.ArrayList(Sexp)) std.mem.Allocator.Error!void {
            const a = l.p.allocator();
            for (l.steps, 0..) |st, i| {
                const n = i + 1;
                if (eq(st.name, "filter")) {
                    try body.append(a, try l.when(try l.node(.not, &.{try l.call(l.funs[i].?, try l.passed(i))}), &.{try l.skip()}));
                } else if (eq(st.name, "map")) {
                    const value = try l.call(l.funs[i].?, try l.passed(i));
                    try body.append(a, if (l.readFrom(n)) try l.bind(.chain_item, .nil, value) else try l.assign(.discard, value));
                } else if (eq(st.name, "take")) {
                    // An iterator or a range stops before its next item
                    // instead (`headWith`).
                    if (l.source == .elements) try body.append(a, try l.when(try l.node(.@">=", &.{ try l.leaf(countName(n)), try l.leaf(limitName(n)) }), &.{try l.stop()}));
                    try body.append(a, try l.addTo(countName(n), try l.leaf(.one_value)));
                } else if (eq(st.name, "skip")) {
                    try body.append(a, try l.when(try l.node(.@"<", &.{ try l.leaf(countName(n)), try l.leaf(limitName(n)) }), &.{ try l.addTo(countName(n), try l.leaf(.one_value)), try l.skip() }));
                } else if (eq(st.name, "enumerate")) {
                    // An index no one reads is not counted.
                    if (l.pair_read[n]) {
                        try body.append(a, try l.bind(limitName(n), .nil, try l.leaf(countName(n))));
                        try body.append(a, try l.addTo(countName(n), try l.leaf(.one_value)));
                    }
                } else if (eq(st.name, "zip")) {
                    // The second source's next item, or the end of both;
                    // the item is bound only when it is read.
                    if (l.zip == .iterator) {
                        const next = try l.node(.member, &.{ try l.node(.write, &.{try l.leaf(stageName(n))}), try l.leaf(.next) });
                        const value = try l.node(.@"??", &.{ try l.node(.call, &.{ .nil, next }), try l.stop() });
                        try body.append(a, if (l.pair_read[n]) try l.bind(limitName(n), .nil, value) else try l.assign(.discard, value));
                    } else {
                        const len = try l.node(.member, &.{ try l.leaf(stageName(n)), try l.leaf(.len_name) });
                        try body.append(a, try l.when(try l.node(.@">=", &.{ try l.leaf(countName(n)), len }), &.{try l.stop()}));
                        if (l.pair_read[n]) {
                            const e = try l.node(.index, &.{ try l.leaf(stageName(n)), try l.leaf(countName(n)) });
                            try body.append(a, try l.bind(limitName(n), .nil, if (l.zip_copies) e else try l.node(.read, &.{e})));
                        }
                        try body.append(a, try l.addTo(countName(n), try l.leaf(.one_value)));
                    }
                }
            }
        }

        /// The head of a loop over the source, `item` its binding: `while
        /// (!h).next() as item` for an iterator, after each `take`'s test,
        /// so none pulls an item it does not need; `for item in h`
        /// otherwise.
        /// A loop's head, made before its body so that the names it binds
        /// stand before their uses.
        /// `pre`: what a range's loop does first with each step: bind the
        /// item, and advance the cursor (`range_from`).
        const Head = struct { item: Sexp, index: Sexp = .nil, src: Sexp, cond: Sexp, pre: [2]Sexp = .{ .nil, .nil } };

        fn head(l: *const ChainLowering) std.mem.Allocator.Error!Head {
            return l.headWith(false, l.readFrom(0));
        }

        /// Whether a stage from `i` on, or the consumer, reads the item:
        /// one no one reads is not bound (`_`).
        fn readFrom(l: *const ChainLowering, i: usize) bool {
            if (!l.counts) return true;
            for (l.steps[i..]) |st| if (eq(st.name, "map") or eq(st.name, "filter")) return true;
            return false;
        }

        /// Whether a stage reads the item (a `filter` or `map`).
        fn stagesRead(l: *const ChainLowering) bool {
            for (l.steps) |st| if (eq(st.name, "map") or eq(st.name, "filter")) return true;
            return false;
        }

        /// A loop's head that also binds each element's index (an element
        /// source alone).
        fn headWith(l: *const ChainLowering, indexed: bool, reads: bool) std.mem.Allocator.Error!Head {
            if (l.source == .range) {
                // A range is walked by a cursor every loop of the chain
                // continues, as an iterator is, so the second loop of a
                // `min` takes up where the first stopped.
                // An inclusive range stops at its end rather than step
                // past it, which overflows at its type's largest value.
                if (l.inclusive) {
                    const open = try l.node(.not, &.{try l.leaf(.chain_done)});
                    const cond = try l.withRooms(try l.node(.@"and", &.{ open, try l.node(.@"<=", &.{ try l.leaf(.range_from), try l.leaf(.range_to) }) }));
                    const item: Sexp = if (reads) try l.bind(.chain_item, .nil, try l.leaf(.range_from)) else .nil;
                    const at_end = try l.node(.@"==", &.{ try l.leaf(.range_from), try l.leaf(.range_to) });
                    const step = try l.node(.@"if", &.{ at_end, try l.block(&.{try l.assign(.chain_done, try l.leaf(.true_value))}), try l.block(&.{try l.addTo(.range_from, try l.leaf(.one_value))}) });
                    return .{ .item = .nil, .src = .nil, .cond = cond, .pre = .{ item, step } };
                }
                const more = try l.node(.@"<", &.{ try l.leaf(.range_from), try l.leaf(.range_to) });
                const cond = try l.withRooms(more);
                const item: Sexp = if (reads) try l.bind(.chain_item, .nil, try l.leaf(.range_from)) else .nil;
                return .{ .item = .nil, .src = .nil, .cond = cond, .pre = .{ item, try l.addTo(.range_from, try l.leaf(.one_value)) } };
            }
            if (l.source != .iterator) {
                const src = try l.leaf(.chain_source);
                const item = try l.leaf(if (reads) .chain_item else .discard);
                return .{ .item = item, .index = if (indexed) try l.leaf(.chain_index) else .nil, .src = src, .cond = .nil };
            }
            var rooms: std.ArrayList(Sexp) = .empty;
            for (l.steps, 0..) |st, i| if (eq(st.name, "take")) {
                try rooms.append(l.p.allocator(), try l.node(.@"<", &.{ try l.leaf(countName(i + 1)), try l.leaf(limitName(i + 1)) }));
            };
            const lend = try l.node(.write, &.{try l.leaf(.chain_source)});
            const next = try l.node(.member, &.{ lend, try l.leaf(.next) });
            var cond = try l.node(.as, &.{ try l.node(.call, &.{ .nil, next }), try l.leaf(if (reads) .chain_item else .discard) });
            var i = rooms.items.len;
            while (i > 0) : (i -= 1) cond = try l.node(.@"and", &.{ rooms.items[i - 1], cond });
            return .{ .item = .nil, .src = .nil, .cond = cond };
        }

        /// `cond` after each `take`'s test, so no loop takes a step it
        /// does not need.
        fn withRooms(l: *const ChainLowering, cond: Sexp) std.mem.Allocator.Error!Sexp {
            var out = cond;
            var i = l.steps.len;
            while (i > 0) : (i -= 1) if (eq(l.steps[i - 1].name, "take")) {
                out = try l.node(.@"and", &.{ try l.node(.@"<", &.{ try l.leaf(countName(i)), try l.leaf(limitName(i)) }), out });
            };
            return out;
        }

        fn loop(l: *const ChainLowering, h: Head, body: Sexp) std.mem.Allocator.Error!Sexp {
            if (l.source == .elements) return l.node(.@"for", &.{ .{ .tag = .iter }, h.item, h.index, h.src, body, .nil, .nil });
            if (h.pre[1] == .nil) return l.node(.@"while", &.{ h.cond, .nil, body, .nil });
            var stmts: std.ArrayList(Sexp) = .empty;
            for (h.pre) |s| if (s != .nil) try stmts.append(l.p.allocator(), s);
            try stmts.appendSlice(l.p.allocator(), ir.rest(body, .stmts));
            return l.node(.@"while", &.{ h.cond, .nil, try l.block(stmts.items), .nil });
        }
    };

    fn eq(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    fn countName(n: usize) HiddenName {
        return @enumFromInt(@intFromEnum(stageName(n)) + 1);
    }

    fn limitName(n: usize) HiddenName {
        return @enumFromInt(@intFromEnum(stageName(n)) + 2);
    }

    /// The hidden names of stage `n`, from 1 (`HiddenName.stage_texts`).
    fn stageName(n: usize) HiddenName {
        return @enumFromInt(HiddenName.first_stage + (n - 1) * 3);
    }

    /// A leaf of hidden name `name` at a position past the source's end,
    /// which `span` reads as `home`.
    fn synthLeaf(self: *Parser, home: u32, name: HiddenName) std.mem.Allocator.Error!Sexp {
        return hiddenLeaf(try self.hiddenPos(home), name);
    }

    /// The next position past the source's end, for a hidden leaf that
    /// `span` reads as `home`. A source holds under 2 GiB
    /// (`modules.max_source_bytes`), so over 2^31 of them fit below
    /// `last_hidden_pos`; past it the room for hidden leaves is used up,
    /// and the parse fails as out of memory.
    fn hiddenPos(self: *Parser, home: u32) std.mem.Allocator.Error!u32 {
        const pos = self.base.source.len + self.padded + 1;
        if (pos > last_hidden_pos) return error.OutOfMemory;
        try self.pad_homes.append(self.allocator(), home);
        self.padded += 1;
        return @intCast(pos);
    }

    /// One chain as its loop (`desugarChains`).
    fn lowerIterChain(self: *Parser, node: Sexp, c: Chain) std.mem.Allocator.Error!Sexp {
        const source = c.source;
        const a = self.allocator();
        const is_for = node.isKind(.@"for");
        var cur = if (is_for) ir.For.source(node) else node;
        var consumer: ?ChainStep = null;
        if (!is_for) {
            const callee = ir.Call.callee(cur);
            consumer = .{ .name = leafText(self.base.source, ir.Member.name(callee).src), .args = ir.Call.args(cur), .at = ir.Member.name(callee).src.pos };
            cur = ir.Member.object(callee);
        }
        var steps: std.ArrayList(ChainStep) = .empty;
        while (cur.isKind(.call) and ir.Call.callee(cur).isKind(.member) and isChainStage(leafText(self.base.source, ir.Member.name(ir.Call.callee(cur)).src))) {
            const callee = ir.Call.callee(cur);
            try steps.append(a, .{ .name = leafText(self.base.source, ir.Member.name(callee).src), .args = ir.Call.args(cur), .at = ir.Member.name(callee).src.pos });
            cur = ir.Member.object(callee);
        }
        std.mem.reverse(ChainStep, steps.items);
        // Typecheck rejects a longer chain (`max_chain_stages`).
        std.debug.assert(steps.items.len <= max_chain_stages);
        const root = cur;
        const extent = self.span(node);
        const home = if (consumer) |cs| cs.at else if (steps.items.len > 0) steps.items[steps.items.len - 1].at else extent.start;
        const n = steps.items.len;
        var l: ChainLowering = .{
            .p = self,
            .home = home,
            .extent = extent,
            .source = source,
            .steps = steps.items,
            .funs = try a.alloc(?HiddenName, n + 1),
            .item_of = try a.alloc(HiddenName, n + 1),
            .second_of = try a.alloc(?HiddenName, n + 2),
            .second_ty = try a.alloc(?HiddenName, n + 2),
            .pair_read = try a.alloc(bool, n + 1),
            .copies = c.copies,
            .zip = c.zip,
            .zip_copies = c.zip_copies,
        };
        // Which second values are read: by a later `map` or `filter`
        // before another pair, or by the consumer's function or the
        // `for`'s index.
        @memset(l.pair_read, false);
        var live: ?usize = null;
        for (steps.items, 0..) |st, i| {
            if (eq(st.name, "enumerate") or eq(st.name, "zip")) {
                live = i + 1;
            } else if (eq(st.name, "map") or eq(st.name, "filter")) {
                if (live) |k| l.pair_read[k] = true;
            }
        }
        if (live) |k| {
            if (is_for) {
                if (ir.For.index(node) != .nil) l.pair_read[k] = true;
            } else {
                const cn = consumer.?.name;
                if (eq(cn, "any") or eq(cn, "all") or eq(cn, "find")) l.pair_read[k] = true;
            }
        }
        var pre: std.ArrayList(Sexp) = .empty;
        // The source, held: a range by its bounds, a place lent to read
        // (an iterator to write), a value made here owned.
        switch (source) {
            .range => {
                l.inclusive = isInclusive(root);
                try pre.append(a, try l.bind(.range_from, .nil, ir.get(root, .left)));
                try pre.append(a, try l.bind(.range_to, .nil, ir.get(root, .right)));
                if (l.inclusive) try pre.append(a, try l.bind(.chain_done, .nil, try l.leaf(.false_value)));
                l.item_of[0] = .range_from;
            },
            else => {
                // A sigil the program wrote stands; a place is lent to read.
                const made = root.isKind(.call) or root.isKind(.array) or root.isKind(.paren) or root.isKind(.write) or root.isKind(.read) or root.isKind(.move);
                const held = if (made) root else try l.node(if (source == .iterator) .write else .read, &.{root});
                try pre.append(a, try l.bind(.chain_source, .nil, held));
                l.item_of[0] = .chain_source;
            },
        }
        // Each stage's function, bound once, its parameters typed by the
        // items it takes; each count's limit, evaluated once.
        l.second_of[0] = null;
        l.second_ty[0] = null;
        for (steps.items, 0..) |st, i| {
            const k = i + 1;
            l.funs[i] = null;
            l.item_of[k] = l.item_of[i];
            l.second_of[k] = l.second_of[i];
            l.second_ty[k] = l.second_ty[i];
            if (eq(st.name, "map") or eq(st.name, "filter")) {
                try pre.append(a, try l.bind(stageName(k), .nil, try self.typedFunction(&l, st.args[0], i)));
                l.funs[i] = stageName(k);
                if (eq(st.name, "map")) l.item_of[k] = stageName(k);
            } else if (eq(st.name, "take") or eq(st.name, "skip")) {
                try pre.append(a, try l.bind(countName(k), .nil, try l.leaf(.zero_value)));
                try pre.append(a, try l.bind(limitName(k), .nil, st.args[0]));
            } else if (eq(st.name, "enumerate")) {
                if (l.pair_read[k]) try pre.append(a, try l.bind(countName(k), .nil, try l.leaf(.zero_value)));
                l.second_of[k] = limitName(k);
                l.second_ty[k] = countName(k);
            } else if (eq(st.name, "zip")) {
                // The second source, held as the first is.
                const ys = st.args[0];
                const made = ys.isKind(.call) or ys.isKind(.array) or ys.isKind(.write) or ys.isKind(.read) or ys.isKind(.move);
                try pre.append(a, try l.bind(stageName(k), .nil, if (made) ys else try l.node(.read, &.{ys})));
                if (c.zip == .elements) try pre.append(a, try l.bind(countName(k), .nil, try l.leaf(.zero_value)));
                l.second_of[k] = limitName(k);
                l.second_ty[k] = stageName(k);
            }
        }
        l.counts = !is_for and eq(consumer.?.name, "count");
        if (is_for) return self.lowerForChain(&l, node, &pre);
        return self.lowerConsumer(&l, consumer.?, &pre);
    }

    /// Stage function `f` for the stage at `i`, as a closure whose
    /// parameters are typed by the items it takes: a closure literal's
    /// untyped parameters gain `(item_type ...)`; any other function is
    /// called by a closure that is.
    fn typedFunction(self: *Parser, l: *const ChainLowering, f: Sexp, i: usize) std.mem.Allocator.Error!Sexp {
        const tys = [2]?HiddenName{ l.item_of[i], l.second_ty[i] };
        if (f.isKind(.lambda)) {
            const params = ir.get(f, .params);
            if (params != .list) return f;
            for (@constCast(params.items()), 0..) |*prm, j| {
                if (prm.* != .src or j >= 2) continue;
                const of = tys[j] orelse continue;
                prm.* = try self.base.newNode(.@":", &.{ prm.*, try l.itemType(of) }, self.span(prm.*));
            }
            return f;
        }
        var ps: std.ArrayList(Sexp) = .empty;
        var cargs: std.ArrayList(Sexp) = .empty;
        try cargs.append(self.allocator(), .nil);
        try cargs.append(self.allocator(), f);
        const names = [2]HiddenName{ .chain_item, .chain_key };
        for (tys, names) |t, nm| if (t) |of| {
            try ps.append(self.allocator(), try l.node(.@":", &.{ try l.leaf(nm), try l.itemType(of) }));
            try cargs.append(self.allocator(), try l.leaf(nm));
        };
        const params = try self.base.newList(ps.items, l.extent);
        const body = try l.block(&.{try l.node(.call, cargs.items)});
        return l.node(.lambda, &.{ .nil, params, body });
    }

    /// The key function of a `min_by` or `max_by`, which takes each item
    /// alone, as `min` compares it, though a pair passes the stages.
    fn keyFunction(self: *Parser, l: *ChainLowering, f: Sexp) std.mem.Allocator.Error!Sexp {
        const last = l.steps.len;
        const saved = l.second_ty[last];
        defer l.second_ty[last] = saved;
        l.second_ty[last] = null;
        return self.typedFunction(l, f, last);
    }

    /// `for x in chain`: a block of the holds and the loop, whose body
    /// runs the stages and then binds the loop's names to the item.
    fn lowerForChain(self: *Parser, l: *const ChainLowering, node: Sexp, pre: *std.ArrayList(Sexp)) std.mem.Allocator.Error!Sexp {
        const a = self.allocator();
        const h = try l.head();
        var body: std.ArrayList(Sexp) = .empty;
        try l.stages(&body);
        const last = l.steps.len;
        const made = last > 0 and eq(l.steps[last - 1].name, "map");
        // A List's element the loop lends is lent on, `?item`; a value a
        // `map` made moves; anything else is the item.
        const item = try l.leaf(.chain_item);
        const lends = l.source == .elements and !l.copies and !made;
        const value = if (made) try l.node(.move, &.{item}) else if (lends) try l.node(.read, &.{item}) else item;
        try body.append(a, try l.node(.set, &.{ .{ .tag = .shadow }, ir.For.@"var"(node), .nil, value }));
        try self.loop_names.put(a, ir.For.@"var"(node).src.pos, {});
        if (ir.For.index(node) != .nil) if (l.second_of[last]) |s| {
            try body.append(a, try l.node(.set, &.{ .{ .tag = .shadow }, ir.For.index(node), .nil, try l.leaf(s) }));
            try self.loop_names.put(a, ir.For.index(node).src.pos, {});
        };
        for (ir.rest(ir.For.body(node), .stmts)) |s| try body.append(a, s);
        try pre.append(a, try l.loop(h, try l.block(body.items)));
        return l.block(pre.items);
    }

    /// A chain ended by its consumer: a `loop` value. The state
    /// first, then the loop's head, its stages, and what the consumer does
    /// with each item, then the result: each name stands before its uses.
    fn lowerConsumer(self: *Parser, l: *ChainLowering, c: ChainStep, pre: *std.ArrayList(Sexp)) std.mem.Allocator.Error!Sexp {
        const a = self.allocator();
        const last = l.steps.len;
        const item_ty = l.item_of[last];
        if (eq(c.name, "min") or eq(c.name, "max") or eq(c.name, "min_by") or eq(c.name, "max_by")) return self.lowerPeel(l, c, pre);
        const made = last > 0 and eq(l.steps[last - 1].name, "map");
        // The state.
        if (eq(c.name, "count")) {
            try pre.append(a, try l.bind(.chain_value, .nil, try l.leaf(.zero_value)));
        } else if (eq(c.name, "sum")) {
            try pre.append(a, try l.bind(.chain_value, try l.itemValue(item_ty), try l.leaf(.zero_value)));
        } else if (eq(c.name, "any") or eq(c.name, "all")) {
            try pre.append(a, try l.bind(.chain_key, .nil, try self.typedFunction(l, c.args[0], last)));
            try pre.append(a, try l.bind(.chain_value, .nil, try l.leaf(if (eq(c.name, "any")) .false_value else .true_value)));
        } else if (eq(c.name, "find") and l.keepsIndex()) {
            return self.lowerFindIndex(l, c, pre);
        } else if (eq(c.name, "find")) {
            try pre.append(a, try l.bind(.chain_key, .nil, try self.typedFunction(l, c.args[0], last)));
            try pre.append(a, try l.bind(.chain_value, try l.node(.optional, &.{try l.itemType(item_ty)}), try l.leaf(.none_value)));
        } else if (eq(c.name, "reduce")) {
            try pre.append(a, try l.bind(.chain_value, .nil, c.args[0]));
            // The running value's type, then the item's.
            const saved = l.item_of[last];
            const saved_second = l.second_ty[last];
            l.item_of[last] = .chain_value;
            l.second_ty[last] = saved;
            const f = try self.typedFunction(l, c.args[1], last);
            l.item_of[last] = saved;
            l.second_ty[last] = saved_second;
            try pre.append(a, try l.bind(.chain_key, .nil, f));
        } else if (eq(c.name, "collect")) {
            const ty = try l.node(.generic_inst, &.{ try l.leaf(.list_type), try l.itemType(item_ty) });
            try pre.append(a, try l.bind(.chain_value, ty, try l.node(.call, &.{ .nil, try l.leaf(.list_type) })));
        } else unreachable;
        // The loop.
        const h = try l.head();
        var body: std.ArrayList(Sexp) = .empty;
        try l.stages(&body);
        if (eq(c.name, "count")) {
            try body.append(a, try l.addTo(.chain_value, try l.leaf(.one_value)));
        } else if (eq(c.name, "sum")) {
            try body.append(a, try l.addTo(.chain_value, try l.leaf(.chain_item)));
        } else if (eq(c.name, "any") or eq(c.name, "all")) {
            const any = eq(c.name, "any");
            const test_ = try l.call(.chain_key, try l.passed(last));
            const cond = if (any) test_ else try l.node(.not, &.{test_});
            try body.append(a, try l.when(cond, &.{ try l.assign(.chain_value, try l.leaf(if (any) .true_value else .false_value)), try l.brk(.nil) }));
        } else if (eq(c.name, "find")) {
            try body.append(a, try l.when(try l.call(.chain_key, try l.passed(last)), &.{ try l.assign(.chain_value, try l.leaf(.chain_item)), try l.brk(.nil) }));
        } else if (eq(c.name, "reduce")) {
            try body.append(a, try l.assign(.chain_value, try l.call(.chain_key, &.{ .chain_value, .chain_item })));
        } else if (eq(c.name, "collect")) {
            const push = try l.node(.member, &.{ try l.node(.write, &.{try l.leaf(.chain_value)}), try l.leaf(.push_name) });
            const item = try l.leaf(.chain_item);
            try body.append(a, try l.node(.call, &.{ .nil, push, if (made) try l.node(.move, &.{item}) else item }));
        }
        try pre.append(a, try l.loop(h, try l.block(body.items)));
        try pre.append(a, try l.brk(try l.leaf(.chain_value)));
        return self.onceValue(l, pre.items);
    }

    /// `find` over an element source: the index of the first item `f`
    /// passes, then the element there.
    fn lowerFindIndex(self: *Parser, l: *ChainLowering, c: ChainStep, pre: *std.ArrayList(Sexp)) std.mem.Allocator.Error!Sexp {
        const a = self.allocator();
        const last = l.steps.len;
        try pre.append(a, try l.bind(.chain_key, .nil, try self.typedFunction(l, c.args[0], last)));
        const int_opt = try l.node(.optional, &.{try l.leaf(.int_type)});
        const h = try l.headWith(true, true);
        var body: std.ArrayList(Sexp) = .empty;
        try l.stages(&body);
        try body.append(a, try l.when(try l.call(.chain_key, try l.passed(last)), &.{ try l.assign(.chain_first, try l.leaf(.chain_index)), try l.brk(.nil) }));
        try pre.append(a, try l.bind(.chain_first, int_opt, try l.leaf(.none_value)));
        try pre.append(a, try l.loop(h, try l.block(body.items)));
        return self.indexResult(l, pre);
    }

    /// The end of a consumer that kept an index in `chain first`: none,
    /// or the element there.
    fn indexResult(self: *Parser, l: *ChainLowering, pre: *std.ArrayList(Sexp)) std.mem.Allocator.Error!Sexp {
        const a = self.allocator();
        try pre.append(a, try l.bind(.chain_best, .nil, try l.node(.@"??", &.{ try l.leaf(.chain_first), try l.brk(try l.leaf(.none_value)) })));
        const opt_ty = try l.node(.optional, &.{try l.itemType(.chain_source)});
        try pre.append(a, try l.bind(.chain_next, opt_ty, try l.elem(.chain_best)));
        try pre.append(a, try l.brk(try l.leaf(.chain_next)));
        return self.onceValue(l, pre.items);
    }

    /// `min`, `max`, `min_by`, `max_by` over an element source: the index
    /// of the first item the stages pass, then of the best of the rest,
    /// whose element the result is. Each item before the first is passed
    /// over in the second loop before any stage runs.
    fn lowerPeelIndex(self: *Parser, l: *ChainLowering, c: ChainStep, pre: *std.ArrayList(Sexp)) std.mem.Allocator.Error!Sexp {
        const a = self.allocator();
        const by = eq(c.name, "min_by") or eq(c.name, "max_by");
        const is_min = eq(c.name, "min") or eq(c.name, "min_by");
        if (by) try pre.append(a, try l.bind(.chain_key, .nil, try self.keyFunction(l, c.args[0])));
        const int_opt = try l.node(.optional, &.{try l.leaf(.int_type)});
        const fh = try l.headWith(true, l.stagesRead());
        var fb: std.ArrayList(Sexp) = .empty;
        try l.stages(&fb);
        try fb.append(a, try l.assign(.chain_first, try l.leaf(.chain_index)));
        try fb.append(a, try l.brk(.nil));
        try pre.append(a, try l.bind(.chain_first, int_opt, try l.leaf(.none_value)));
        try pre.append(a, try l.loop(fh, try l.block(fb.items)));
        try pre.append(a, try l.bind(.chain_best, .nil, try l.node(.@"??", &.{ try l.leaf(.chain_first), try l.brk(try l.leaf(.none_value)) })));
        if (by) try pre.append(a, try l.bind(.chain_value, .nil, try l.callOn(.chain_key, try l.elem(.chain_best))));
        const rh = try l.headWith(true, true);
        var rb: std.ArrayList(Sexp) = .empty;
        try rb.append(a, try l.when(try l.node(.@"<=", &.{ try l.leaf(.chain_index), try l.leaf(.chain_best) }), &.{try l.skip()}));
        try l.stages(&rb);
        const better: parser.Tag = if (is_min) .@"<" else .@">=";
        if (by) {
            try rb.append(a, try l.bind(.chain_next, .nil, try l.call(.chain_key, &.{.chain_item})));
            try rb.append(a, try l.when(try l.node(better, &.{ try l.leaf(.chain_next), try l.leaf(.chain_value) }), &.{
                try l.assign(.chain_best, try l.leaf(.chain_index)),
                try l.assign(.chain_value, try l.leaf(.chain_next)),
            }));
        } else {
            try rb.append(a, try l.when(try l.node(better, &.{ try l.leaf(.chain_item), try l.elem(.chain_best) }), &.{try l.assign(.chain_best, try l.leaf(.chain_index))}));
        }
        try pre.append(a, try l.loop(rh, try l.block(rb.items)));
        try pre.append(a, try l.assign(.chain_first, try l.leaf(.chain_best)));
        return self.indexResult(l, pre);
    }

    /// `loop` around `stmts`, which end in its `break`: a value.
    fn onceValue(self: *Parser, l: *const ChainLowering, stmts: []const Sexp) std.mem.Allocator.Error!Sexp {
        _ = self;
        return l.node(.@"while", &.{ try l.leaf(.true_value), .nil, try l.block(stmts), .nil });
    }

    /// `min`, `max`, `min_by`, `max_by`: the first item the stages pass,
    /// then the rest of the source against it. `min` keeps the first of
    /// equal items, `max` the last, as Rust's do.
    fn lowerPeel(self: *Parser, l: *ChainLowering, c: ChainStep, pre: *std.ArrayList(Sexp)) std.mem.Allocator.Error!Sexp {
        if (l.keepsIndex()) return self.lowerPeelIndex(l, c, pre);
        const a = self.allocator();
        const last = l.steps.len;
        const item_ty = l.item_of[last];
        const by = eq(c.name, "min_by") or eq(c.name, "max_by");
        const is_min = eq(c.name, "min") or eq(c.name, "min_by");
        if (by) try pre.append(a, try l.bind(.chain_key, .nil, try self.keyFunction(l, c.args[0])));
        // The first item, or none. A List's loop starts again from its
        // first element, so the loop over the rest passes over each
        // element up to the first item's, `chain at`, before any stage
        // runs (an iterator or a range continues where it stopped).
        const indexed = l.source == .elements;
        if (indexed) try pre.append(a, try l.bind(.chain_at, .nil, try l.leaf(.zero_value)));
        const opt_ty = try l.node(.optional, &.{try l.itemType(item_ty)});
        const fh = try l.headWith(indexed, l.readFrom(0));
        var fb: std.ArrayList(Sexp) = .empty;
        try l.stages(&fb);
        if (indexed) try fb.append(a, try l.assign(.chain_at, try l.leaf(.chain_index)));
        try fb.append(a, try l.assign(.chain_first, try l.leaf(.chain_item)));
        try fb.append(a, try l.brk(.nil));
        try pre.append(a, try l.bind(.chain_first, opt_ty, try l.leaf(.none_value)));
        try pre.append(a, try l.loop(fh, try l.block(fb.items)));
        // Typed, so a view stays a view rather than reading out the
        // number it views (SPEC "The fallback of `??`").
        try pre.append(a, try l.bind(.chain_best, try l.itemType(item_ty), try l.node(.@"??", &.{ try l.leaf(.chain_first), try l.brk(try l.leaf(.none_value)) })));
        if (by) try pre.append(a, try l.bind(.chain_value, .nil, try l.call(.chain_key, &.{.chain_best})));
        // The rest.
        const rh = try l.headWith(indexed, l.readFrom(0));
        var rb: std.ArrayList(Sexp) = .empty;
        if (indexed) try rb.append(a, try l.when(try l.node(.@"<=", &.{ try l.leaf(.chain_index), try l.leaf(.chain_at) }), &.{try l.skip()}));
        try l.stages(&rb);
        const better: parser.Tag = if (is_min) .@"<" else .@">=";
        if (by) {
            try rb.append(a, try l.bind(.chain_next, .nil, try l.call(.chain_key, &.{.chain_item})));
            try rb.append(a, try l.when(try l.node(better, &.{ try l.leaf(.chain_next), try l.leaf(.chain_value) }), &.{
                try l.assign(.chain_best, try l.leaf(.chain_item)),
                try l.assign(.chain_value, try l.leaf(.chain_next)),
            }));
        } else {
            try rb.append(a, try l.when(try l.node(better, &.{ try l.leaf(.chain_item), try l.leaf(.chain_best) }), &.{try l.assign(.chain_best, try l.leaf(.chain_item))}));
        }
        try pre.append(a, try l.loop(rh, try l.block(rb.items)));
        try pre.append(a, try l.assign(.chain_first, try l.leaf(.chain_best)));
        try pre.append(a, try l.brk(try l.leaf(.chain_first)));
        return self.onceValue(l, pre.items);
    }

    pub fn desugarIterLoops(self: *Parser, tree: Sexp, loops: []const IterLoop) std.mem.Allocator.Error!void {
        try self.desugarIn(tree, .{ .loops = loops });
    }

    fn desugarIn(self: *Parser, node: Sexp, state: IterRewrite) std.mem.Allocator.Error!void {
        if (node != .list) return;
        const items = @constCast(node.items());
        for (items) |*slot| slot.* = try self.desugarChild(slot.*, state);
    }

    /// `child` with the loops inside it rewritten, or what replaces it
    /// when it is one: a loop that holds its source is a block of the
    /// binding and the `while`, around the label when it has one.
    fn desugarChild(self: *Parser, child: Sexp, state: IterRewrite) std.mem.Allocator.Error!Sexp {
        const labeled = child.isKind(.labeled);
        const loop = if (labeled) ir.Labeled.stmt(child) else child;
        const at = state.find(loop) orelse {
            try self.desugarIn(child, state);
            return child;
        };
        try self.desugarIn(loop, state);
        const built = try self.iterWhile(loop, state.loops[at]);
        if (labeled) {
            const copy = try self.allocator().dupe(Sexp, child.items());
            copy[ir.slot(.labeled, .stmt)] = built.loop;
            const out: Sexp = .{ .list = parser.List.withId(copy, child.list.id) };
            return if (built.hold) |h| self.base.newNode(.block, &.{ h, out }, self.span(child)) else out;
        }
        return if (built.hold) |h| self.base.newNode(.block, &.{ h, built.loop }, self.span(child)) else built.loop;
    }

    const IterWhile = struct { loop: Sexp, hold: ?Sexp };

    /// `for x in it` as `while (!it).next() as x`; a held source `e` is
    /// bound first, `h = e` (`h = <e` for a place the loop takes), and
    /// walked as `(!h)`.
    fn iterWhile(self: *Parser, loop: Sexp, l: IterLoop) std.mem.Allocator.Error!IterWhile {
        const source = ir.For.source(loop);
        const binding = ir.For.@"var"(loop);
        const at = self.span(source);
        const key = self.span(loop).start;
        var hold: ?Sexp = null;
        var iter = source;
        if (l.source != .place) {
            const value = if (l.source == .moved) try self.base.newNode(.move, &.{source}, at) else source;
            // `h` is declared before the loop, at the position before
            // its `for`, so the loop does not enclose its declaration:
            // what it holds stays in force through every iteration
            // (`ownership.Checker.liveFrom`).
            hold = try self.base.newNode(.set, &.{ .{ .tag = .shadow }, hiddenLeaf(key - 1, .iterator), .nil, value }, at);
            iter = hiddenLeaf(key + 2, .iterator);
        }
        const lend = try self.base.newNode(.write, &.{iter}, at);
        const member = try self.base.newNode(.member, &.{ lend, hiddenLeaf(key, .next) }, at);
        const call = try self.base.newNode(.call, &.{ .nil, member }, at);
        const bound = try self.base.newNode(.as, &.{ call, binding }, .{ .start = self.span(binding).start, .end = at.end });
        const out = try self.allocator().alloc(Sexp, 5);
        out[0] = .{ .tag = .@"while" };
        out[ir.slot(.@"while", .cond)] = bound;
        out[ir.slot(.@"while", .step)] = .nil;
        out[ir.slot(.@"while", .body)] = ir.For.body(loop);
        out[ir.slot(.@"while", .@"else")] = .nil;
        return .{ .loop = .{ .list = parser.List.withId(out, loop.list.id) }, .hold = hold };
    }

    /// A bare `for xs` is `for _ in xs`: the variable the grammar left
    /// out is the discard name, at the `for` keyword.
    fn bareFor(self: *Parser, loop: Sexp, items: []Sexp) void {
        const slot = ir.slot(.@"for", .@"var");
        if (items[slot] != .nil) return;
        const at = self.span(loop).start;
        items[slot] = hiddenLeaf(at, .discard);
    }

    /// Promote the source's `?xs` / `!xs` / `<xs` wrapper into the mode.
    fn normFor(items: []Sexp) void {
        const node = Sexp.listOf(items);
        if (ir.For.mode(node).tag != .iter) return;
        const source = ir.For.source(node);
        const kind = source.kind() orelse return;
        switch (kind) {
            .read, .write, .move => {
                items[ir.slot(.@"for", .mode)] = .{ .tag = kind };
                items[ir.slot(.@"for", .source)] = ir.get(source, .operand);
            },
            else => {},
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn expectCats(source: []const u8, expected: []const TokenCat) !void {
    var lx = Lexer.init(source);
    for (expected) |want| {
        const got = lx.next();
        testing.expectEqual(want, got.cat) catch |e| {
            std.debug.print("source: {s}\n  at `{s}`\n", .{ source, lx.base.text(got) });
            return e;
        };
    }
}

/// The token at `index` reads `want`, and the next one starts after it.
fn expectText(source: []const u8, index: usize, want: []const u8) !void {
    var lx = Lexer.init(source);
    for (0..index) |_| _ = lx.next();
    const got = lx.next();
    try testing.expectEqual(TokenCat.ident, got.cat);
    try testing.expectEqualStrings(want, lx.base.text(got));
    try testing.expectEqual(TokenCat.eof, lx.next().cat);
}

test "keywords are reserved; `new` only at statement start" {
    try testing.expectEqual(TokenCat.@"else", keyword("else").?);
    try testing.expect(keyword("fn") == null);
    for ([_][]const u8{ "trait", "impl", "where", "async", "await", "yield", "when", "const" }) |w| {
        try testing.expect(keyword(w) != null);
    }
    try testing.expect(keyword("var") == null);
    // Every keyword category but `new`, `obj`, `inline`, `called`, and
    // `rarely` is a lexer rule.
    for (@intFromEnum(TokenCat.true)..@intFromEnum(TokenCat.yield) + 1) |c| {
        const cat: TokenCat = @enumFromInt(c);
        if (cat == .obj or cat == .api or cat == .add or cat == .@"inline" or cat == .called or cat == .rarely) continue;
        try testing.expectEqual(cat, keyword(@tagName(cat)).?);
        if (cat != .new) try expectCats(@tagName(cat), &.{cat});
    }
    try expectCats("new x = 1", &.{ .new, .ident, .assign, .integer });
    try expectCats("p = Point.new(1)", &.{ .ident, .assign, .ident, .dot, .ident, .lparen, .integer, .rparen });
    try expectCats("O(new: 1)", &.{ .ident, .lparen, .kwarg_name, .colon, .integer, .rparen });
}

test "`obj` is a keyword only where a declaration starts; `struct` is a name" {
    try testing.expect(keyword("obj") == null and keyword("struct") == null);
    try expectCats("obj P", &.{ .obj, .ident });
    try expectCats("pub obj P[T] unique", &.{ .@"pub", .obj, .ident, .lbracket, .ident, .rbracket, .ident });
    try expectCats("obj = 5", &.{ .ident, .assign, .integer });
    try expectCats("obj.x = obj", &.{ .ident, .dot, .ident, .assign, .ident });
    try expectCats("f(obj: 1)", &.{ .ident, .lparen, .kwarg_name, .colon, .integer, .rparen });
    try expectCats("x = obj P", &.{ .ident, .assign, .ident, .ident });
    try expectCats("struct P", &.{ .ident, .ident });
    try parses("obj = 5\n");
    try parses("struct = 5\nobj = struct\n");
    try parses("fun f(obj: Int, struct: Int) -> Int\n  obj + struct\n");
    try parses("obj P\n  obj: Int\n  struct: Int\n");
}

test "`inline` and `called` are keywords only before a declaration's `fun` or `sub`, and `rarely` only alone on its line" {
    try testing.expect(keyword("inline") == null and keyword("called") == null and keyword("rarely") == null);
    try expectCats("inline fun f()", &.{ .@"inline", .fun, .ident, .lparen, .rparen });
    try expectCats("called fun f()", &.{ .called, .fun, .ident, .lparen, .rparen });
    try expectCats("called = 1", &.{ .ident, .assign, .integer });
    try expectCats("pub called sub s()", &.{ .@"pub", .called, .sub, .ident, .lparen, .rparen });
    try expectCats("rarely", &.{.rarely});
    try expectCats("rarely  # cold", &.{.rarely});
    try expectCats("rarely fun f()", &.{ .ident, .fun, .ident, .lparen, .rparen });
    try expectCats("rarely = 2", &.{ .ident, .assign, .integer });
    try expectCats("inline = 5", &.{ .ident, .assign, .integer });
    try expectCats("x = rarely", &.{ .ident, .assign, .ident });
    try expectCats("f(inline: 1)", &.{ .ident, .lparen, .kwarg_name, .colon, .integer, .rparen });
    try expectCats("p.inline(rarely)", &.{ .ident, .dot, .ident, .lparen, .ident, .rparen });
    try parses("inline fun f() -> Int\n  1\n");
    try parses("obj P\n  inline: Int\n  rarely: Int\n  called sub m(?@)\n    pass\n  fun inline(?@) -> Int\n    @inline\n");
    try parses("fun f(inline: Int, rarely: Int) -> Int\n  inline + rarely\n");
    try parses("fun f(n: Int) -> Int\n  rarely\n  n\n");
}

test "a deeper line starting with `.` continues a complete statement" {
    // The chain joins the lines: no NEWLINE or INDENT between them.
    try expectCats("b = B()\n  .add(1)\n  .add(2)\nc = 3", &.{
        .ident, .assign, .ident, .lparen, .rparen, .dot, .ident, .lparen, .integer, .rparen,
        .dot,   .ident,  .lparen, .integer, .rparen, .newline, .ident, .assign, .integer,
    });
    // Blank and comment lines do not end it.
    try expectCats("b\n  .x\n\n  # c\n  .y", &.{ .ident, .dot, .ident, .dot, .ident });
    // A line at the statement's own indentation does not continue it.
    try expectCats("b\n.x", &.{ .ident, .newline, .dot, .ident });
    // `.5` is a number, not a member.
    try expectCats("b\n  .5", &.{ .ident, .indent, .real });
    // A line that opens a block is not continued: its block starts.
    try expectCats("match c\n  .red", &.{ .match, .ident, .indent, .dot, .ident });
    try expectCats("fun f() -> Int\n  .x", &.{ .fun, .ident, .lparen, .rparen, .arrow, .ident, .indent, .dot, .ident });
    try expectCats("obj P\n  x: Int\n    .y", &.{ .obj, .ident, .indent, .ident, .colon, .ident, .indent, .dot, .ident });
    // An arm written above its body: the body's first line is not a chain.
    try expectCats("match c\n  .red\n    .blue => 1", &.{ .match, .ident, .indent, .dot, .ident, .indent, .dot, .ident, .fat_arrow, .integer });
}

/// The tree of `source`'s first declaration, past any `pub`.
fn firstDecl(p: *Parser) !Sexp {
    const decl = ir.Module.decls(try p.parseTree())[0];
    return if (decl.isKind(.@"pub")) ir.Pub.decl(decl) else decl;
}

/// Whether `source` declares a unique object first.
fn structUnique(source: []const u8) !bool {
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    return ir.get(try firstDecl(&p), .unique) != .nil;
}

/// The origins of `source`'s first declaration, a function: how many
/// names follow `from`, 0 for `from static`, null for none.
fn originCount(source: []const u8) !?usize {
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    const origins = ir.get(try firstDecl(&p), .origins);
    return if (origins == .nil) null else origins.items().len;
}

test "`unique` is a keyword only after an obj header's name or type parameters" {
    try testing.expect(keyword("unique") == null);
    try expectCats("obj R unique", &.{ .obj, .ident, .ident });
    try testing.expect(try structUnique("obj R unique\n  x: Int\n"));
    try testing.expect(try structUnique("pub obj R unique # note\n  x: Int\n"));
    try testing.expect(try structUnique("obj R[T] unique\n  x: T\n"));
    try testing.expect(!try structUnique("obj R[unique]\n  x: Int\n"));
    try testing.expect(!try structUnique("obj unique\n  x: Int\n"));
    try testing.expect(!try structUnique("obj R\n  unique: Bool\n"));
    try testing.expectError(error.ParseError, parses("enum E unique\n  a\n"));
    try parses("unique = x.unique\n");
    try expectCats("f(unique: 1)", &.{ .ident, .lparen, .kwarg_name, .colon, .integer, .rparen });
}

/// Whether `source` declares an `exact` object first.
fn structExact(source: []const u8) !bool {
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    return ir.get(try firstDecl(&p), .exact) != .nil;
}

test "`exact` is a keyword only after an obj header's name" {
    try testing.expect(keyword("exact") == null);
    try expectCats("obj R exact", &.{ .obj, .ident, .ident });
    try testing.expect(try structExact("obj R exact\n  x: U32\n"));
    try testing.expect(try structExact("pub obj R exact # note\n  x: U32\n"));
    try testing.expect(try structExact("obj R exact: Eq\n  x: U32\n"));
    try testing.expect(!try structExact("obj exact\n  x: Int\n"));
    try testing.expect(!try structExact("obj R\n  exact: Bool\n"));
    try testing.expectError(error.ParseError, parses("enum E exact\n  a\n"));
    try parses("exact = x.exact\n");
    try expectCats("f(exact: 1)", &.{ .ident, .lparen, .kwarg_name, .colon, .integer, .rparen });
}

test "`from` and `static` are keywords only after a function's result type" {
    try testing.expect(keyword("from") == null and keyword("static") == null);
    try testing.expectEqual(@as(?usize, 1), try originCount("fun f(a: ?T) -> ?T from a\n  a\n"));
    try testing.expectEqual(@as(?usize, 0), try originCount("pub fun f() -> ?String from static\n  s\n"));
    try testing.expectEqual(@as(?usize, 2), try originCount("fun f() -> T? from a, b\n  a\n"));
    try testing.expectEqual(@as(?usize, 1), try originCount("extern fun f(s: ?String) -> ?String from s\n"));
    try testing.expectEqual(@as(?usize, null), try originCount("fun span(from: Int) -> Int\n  from\n"));
    try testing.expectEqual(@as(?usize, null), try originCount("fun f() -> Int\n  from\n"));
    try testing.expectEqual(@as(?usize, null), try originCount("fun f(g: fun(Int) -> Int, from: Int) -> Int\n  from\n"));
    try parses("from = static\n");
    try parses("f = |x: Int| x\nfrom = 1\n");
}

/// The `keeps` list of `source`'s first declaration, a function: how
/// many names it lists, null for none.
fn keepsCount(source: []const u8) !?usize {
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    const keeps = ir.get(try firstDecl(&p), .keeps);
    return if (keeps == .nil) null else keeps.items().len;
}

test "`keeps` is a keyword only at the end of a function's header" {
    try testing.expectEqual(@as(?usize, 1), try keepsCount("sub f(!@, s: ?String) keeps s\n  pass\n"));
    try testing.expectEqual(@as(?usize, 2), try keepsCount("fun f(o: !T, s: ?T) -> ?T from s keeps s, o\n  s\n"));
    try testing.expectEqual(@as(?usize, 1), try keepsCount("fun f(o: !T, s: ?T) -> Int keeps s\n  1\n"));
    try testing.expectEqual(@as(?usize, 1), try keepsCount("sub f(o: !T, s: ?T)! keeps s\n  pass\n"));
    try testing.expectEqual(@as(?usize, 1), try keepsCount("extern sub f(o: !T, s: ?T) keeps s\n"));
    try testing.expectEqual(@as(?usize, null), try keepsCount("fun keeps(keeps: Int) -> Int\n  keeps\n"));
    try testing.expectEqual(@as(?usize, null), try keepsCount("sub f(g: sub(Int), keeps: Int)\n  g(keeps)\n"));
    try parses("keeps = 1\nf(keeps: keeps)\n");
}

test "a prefix sigil touches its operand; after a value it is infix or a suffix" {
    for ([_][]const u8{ "a < b", "a<b", "a <b", "a< b" }) |src| try expectCats(src, &.{ .ident, .lt, .ident });
    for ([_][]const u8{ "a - 1", "a-1", "a -1" }) |src| try expectCats(src, &.{ .ident, .minus, .integer });
    try expectCats("x = <y", &.{ .ident, .assign, .lt, .ident });
    try expectCats("x = < y", &.{ .ident, .assign, .err });
    try expectCats("x = * y", &.{ .ident, .assign, .err });
    try expectCats("f(! x)", &.{ .ident, .lparen, .err });
    try expectCats("T? x! T ? x !", &.{ .ident, .question, .ident, .not_sym, .ident, .question, .ident, .not_sym });
    try expectCats("a | b | c", &.{ .ident, .bar, .ident, .bar, .ident });
    try expectCats("f = |a, +b| a", &.{ .ident, .assign, .bar_capture, .ident, .comma, .plus, .ident, .bar_capture, .ident });
    try expectCats("f = | +b , a | a", &.{ .ident, .assign, .bar_capture, .plus, .ident, .comma, .ident, .bar_capture, .ident });
}

test "`=!` binds fixed only with a space after it" {
    try expectCats("x =! y", &.{ .ident, .fixed_assign, .ident });
    try expectCats("x =! !y", &.{ .ident, .fixed_assign, .not_sym, .ident });
    try expectCats("x =!\ty", &.{ .ident, .fixed_assign, .ident });
    try expectCats("new x =! y", &.{ .new, .ident, .fixed_assign, .ident });
    try expectCats("x: Int =! 1", &.{ .ident, .colon, .ident, .fixed_assign, .integer });
    try expectCats("x = !y", &.{ .ident, .assign, .not_sym, .ident });
    try expectCats("x != y", &.{ .ident, .ne, .ident });
    for ([_][]const u8{ "x =!y", "x=!y", "x =!(y)", "x =!=y", "x =!= y", "x =!1", "x =!", "x =!\n", "x =!# c", "x =!\\\n  1" }) |src| {
        try expectCats(src, &.{ .ident, .err });
    }
    try expectLayout("x =! y", &.{});
    try expectLayout("x=! y", &.{.infix_after});
}

/// The spacing kinds the lexer records for `source`, in order.
fn expectLayout(source: []const u8, expected: []const Lexer.Layout.Kind) !void {
    var lx = Lexer.init(source);
    while (true) {
        const t = lx.next();
        if (t.cat == .eof or t.cat == .err) break;
    }
    const got = lx.layouts[0..lx.layout_count];
    testing.expectEqual(expected.len, got.len) catch |e| {
        std.debug.print("source: {s}\n", .{source});
        return e;
    };
    for (expected, got) |want, sp| try testing.expectEqual(want, sp.kind);
}

test "spacing: an infix operator is balanced; a postfix, a member, and an open range touch" {
    for ([_][]const u8{ "a < b", "a<b", "a - 1", "a-1", "x = -1", "x=1", "a ?? b", "0..n", "0 .. n", "f()!", "x?", "w.get()", "c = .red", "xs[..2]", "xs[a..]", "a < -b", "a<-b", "f(\n  a\n  .b())", "[]?T", "[2]*T", "break $a !n", "break $a (n)", "f = |a| a + 1", "while i < n : i += 1" }) |src| {
        try expectLayout(src, &.{});
    }
    try expectLayout("a <b", &.{.infix_before});
    try expectLayout("a< b", &.{.infix_after});
    try expectLayout("x =1", &.{.infix_before});
    try expectLayout("f() !", &.{.postfix});
    try expectLayout("[] ?T", &.{.postfix});
    try expectLayout("w . get()", &.{.member});
    try expectLayout("w .get()", &.{.member});
    try expectLayout("c = . red", &.{.enum_dot});
    try expectLayout("xs[.. 2]", &.{.range_end});
    try expectLayout("xs[a ..]", &.{.range_end});
    try expectLayout("0 ..n", &.{.infix_before});
    // Inside brackets a line break is whitespace, so a line starting
    // `-1` after a value is a subtraction with one side spaced.
    try expectLayout("f(a\n  -1)", &.{.infix_before});
    try expectLayout("a -1 + b *c", &.{ .infix_before, .infix_before });
}

test "`name:` is a keyword argument inside ( ), a name inside [ ]" {
    try expectCats("fun f[n: Int](x: Int)", &.{ .fun, .ident, .lbracket, .ident, .colon, .ident, .rbracket, .lparen, .kwarg_name, .colon, .ident, .rparen });
    try expectCats("pre = 1", &.{ .ident, .assign, .integer });
}

test "a statement label ends no operand" {
    try expectCats("$a: if x", &.{ .label, .ident, .label_colon, .@"if", .ident });
    try expectCats("$a: -x", &.{ .label, .ident, .label_colon, .minus, .ident });
    try expectCats("$a: (x)", &.{ .label, .ident, .label_colon, .lparen, .ident, .rparen });
    try expectCats("$a: $b: for x in y", &.{ .label, .ident, .label_colon, .label, .ident, .label_colon, .@"for", .ident, .in, .ident });
    try expectCats("$a:\n  x", &.{ .label, .ident, .label_colon, .indent, .ident, .outdent });
}

test "a `,` after `as name` outside brackets joins the names `as` binds" {
    try expectCats("if f() as a, b", &.{ .@"if", .ident, .lparen, .rparen, .as, .ident, .as_comma, .ident });
    try expectCats("while g() as a, b, c", &.{ .@"while", .ident, .lparen, .rparen, .as, .ident, .as_comma, .ident, .as_comma, .ident });
    try expectCats("f(x as a, b)", &.{ .ident, .lparen, .ident, .as, .ident, .comma, .ident, .rparen });
    try expectCats("q, r = f()", &.{ .ident, .comma, .ident, .assign, .ident, .lparen, .rparen });
}

test "`$name(` with the `(` touching is a builtin; `$name` alone is a label" {
    try expectCats("$size(T)", &.{ .dollar, .ident, .lparen, .ident, .rparen });
    try expectCats("$type(x)", &.{ .dollar, .ident, .lparen, .ident, .rparen });
    try expectCats("x = $size(T)", &.{ .ident, .assign, .dollar, .ident, .lparen, .ident, .rparen });
    try expectCats("break $size(T)", &.{ .@"break", .dollar, .ident, .lparen, .ident, .rparen });
    try expectCats("$size", &.{.err});
    try expectCats("$ size(T)", &.{.err});
    try expectCats("$size (T)", &.{.err});
    try expectCats("break $a", &.{ .@"break", .label, .ident });
    try expectCats("break $a (x)", &.{ .@"break", .label, .ident, .lparen, .ident, .rparen });
    try expectCats("break $a x if c", &.{ .@"break", .label, .ident, .ident, .post_if, .ident });
    try expectCats("continue $a if c", &.{ .@"continue", .label, .ident, .post_if, .ident });
    try expectCats("break $a -1", &.{ .@"break", .label, .ident, .minus, .integer });
    try expectCats("break $a-1", &.{ .@"break", .label, .ident, .err });
    try expectCats("break $a.red", &.{ .@"break", .label, .ident, .err });
    try expectCats("break $a - 1", &.{ .@"break", .label, .ident, .err });
    try expectCats("break $a |x| x", &.{ .@"break", .label, .ident, .bar_capture, .ident, .bar_capture, .ident });
    try expectCats("break $a, 1", &.{ .@"break", .label, .ident, .comma, .integer });
    try expectCats("break $for", &.{ .@"break", .err });
    try expectCats("$a for x in y", &.{.err});
    try expectCats("$a : for x in y", &.{.err});
    try expectCats("$ a: for x in y", &.{.err});
    try expectCats("$for: for x in y", &.{.err});
    try expectCats("x => $a: for y in z", &.{ .ident, .fat_arrow, .err });
    try expectCats("defer $a: for y in z", &.{ .@"defer", .err });
    try expectCats("x = $a", &.{ .ident, .assign, .err });
    try expectCats("f($a)", &.{ .ident, .lparen, .err });
}

test "`@` is self, and `@name` its member" {
    try expectCats("@", &.{.ident});
    try expectCats("x = @a", &.{ .ident, .assign, .ident, .dot, .ident });
    try expectCats("f(!@)", &.{ .ident, .lparen, .not_sym, .ident, .rparen });
    try expectCats("@type.x", &.{ .ident, .dot, .ident, .dot, .ident });
    try expectCats("@a[0] += 1", &.{ .ident, .dot, .ident, .lbracket, .integer, .rbracket, .plus_assign, .integer });
    try expectCats("!@a.push(1)", &.{ .not_sym, .ident, .dot, .ident, .dot, .ident, .lparen, .integer, .rparen });
    try expectCats("@[0]", &.{ .ident, .lbracket, .integer, .rbracket });
    try expectCats("@.a", &.{.err});
    try expectCats("g = |?@| 1", &.{ .ident, .assign, .bar_capture, .question, .ident, .bar_capture, .integer });
}

test "a `:` touching a name where an operand starts is a symbol" {
    try expectCats("x = :a", &.{ .ident, .assign, .symbol_colon, .ident });
    try expectCats("x = :if", &.{ .ident, .assign, .symbol_colon, .ident });
    try expectCats(":a => 1", &.{ .symbol_colon, .ident, .fat_arrow, .integer });
    try expectCats("break :a", &.{ .@"break", .symbol_colon, .ident });
    try expectCats("x = a ?? break :b", &.{ .ident, .assign, .ident, .nullish_jump, .@"break", .symbol_colon, .ident });
    try expectCats("f(a: :b)", &.{ .ident, .lparen, .kwarg_name, .colon, .symbol_colon, .ident, .rparen });
    try expectCats("f(c or :a)", &.{ .ident, .lparen, .ident, .@"or", .symbol_colon, .ident, .rparen });
    try expectCats("f(not :a)", &.{ .ident, .lparen, .not, .symbol_colon, .ident, .rparen });
    try expectCats("f(not: 1)", &.{ .ident, .lparen, .kwarg_name, .colon, .integer, .rparen });
    try expectCats("K(break : 3)", &.{ .ident, .lparen, .kwarg_name, .colon, .integer, .rparen });
    try expectCats("f(x if c else :b)", &.{ .ident, .lparen, .ident, .ternary_if, .ident, .@"else", .symbol_colon, .ident, .rparen });
    try expectCats("[:a, :b]", &.{ .lbracket, .symbol_colon, .ident, .comma, .symbol_colon, .ident, .rbracket });
    try expectCats("while s != :done : s = t", &.{ .@"while", .ident, .ne, .symbol_colon, .ident, .step_colon, .ident, .assign, .ident });
    try expectCats("y = : a", &.{ .ident, .assign, .err });
    try expectCats("y = :1", &.{ .ident, .assign, .err });
}

test "a symbol's name runs on over `-` and `.` before a name character" {
    try expectText("x = :content-type", 3, "content-type");
    try expectText("x = :utf-8", 3, "utf-8");
    try expectText("x = :a.b-c", 3, "a.b-c");
    try expectText("x = :width.text", 3, "width.text");
    try expectCats("x = :a..b", &.{ .ident, .assign, .symbol_colon, .ident, .dotdot, .ident });
    try expectCats("x = :a - b", &.{ .ident, .assign, .symbol_colon, .ident, .minus, .ident });
}

test "a `while` header's first `:` starts its step, and a jump there may name a label" {
    try expectCats("while x : y", &.{ .@"while", .ident, .step_colon, .ident });
    try expectCats("while f(a: 1) : y", &.{ .@"while", .ident, .lparen, .kwarg_name, .colon, .integer, .rparen, .step_colon, .ident });
    try expectCats("while a ?? break : y", &.{ .@"while", .ident, .nullish_jump, .@"break", .step_colon, .ident });
    try expectCats("while a ?? break $b : y", &.{ .@"while", .ident, .nullish_jump, .@"break", .label, .ident, .step_colon, .ident });
    try expectCats("while x : y = a ?? break $b", &.{ .@"while", .ident, .step_colon, .ident, .assign, .ident, .nullish_jump, .@"break", .label, .ident });
    try expectCats("x = a ?? break $b", &.{ .ident, .assign, .ident, .nullish_jump, .@"break", .label, .ident });
}

test "minus: infix or negation, never a drop" {
    try expectCats("a - b", &.{ .ident, .minus, .ident });
    try expectCats("-x", &.{ .minus, .ident });
    try expectCats("- x", &.{.err});
    try expectCats("-x + 1", &.{ .minus, .ident, .plus, .integer });
    try expectCats("y = -x", &.{ .ident, .assign, .minus, .ident });
    try expectCats("defer -x", &.{ .@"defer", .minus, .ident });
}

test "if: block, guard, ternary" {
    try expectCats("if c", &.{ .@"if", .ident });
    try expectCats("return if c", &.{ .@"return", .post_if, .ident });
    try expectCats("return x if c", &.{ .@"return", .ident, .post_if, .ident });
    try expectCats("x = a if c else b", &.{ .ident, .assign, .ident, .ternary_if, .ident, .@"else", .ident });
    try expectCats("x = a if f() as a, b else 0", &.{ .ident, .assign, .ident, .ternary_if, .ident, .lparen, .rparen, .as, .ident, .as_comma, .ident, .@"else", .integer });
    try expectCats("f(a if c, b)", &.{ .ident, .lparen, .ident, .post_if, .ident, .comma, .ident, .rparen });
    try expectCats("[a if g() as a, b if c else 0]", &.{ .lbracket, .ident, .post_if, .ident, .lparen, .rparen, .as, .ident, .comma, .ident, .ternary_if, .ident, .@"else", .integer, .rbracket });
    try expectCats("f(a if g() as a, b else 0, c)", &.{ .ident, .lparen, .ident, .ternary_if, .ident, .lparen, .rparen, .as, .ident, .as_comma, .ident, .@"else", .integer, .comma, .ident, .rparen });
    try expectCats("f(a if c else b)", &.{ .ident, .lparen, .ident, .ternary_if, .ident, .@"else", .ident, .rparen });
}

test "layout: indentation, joined lines, tabs" {
    try expectCats("a\n  b\nc", &.{ .ident, .indent, .ident, .outdent, .newline, .ident, .eof });
    try expectCats("f(1,\n  2)\nx", &.{ .ident, .lparen, .integer, .comma, .integer, .rparen, .newline, .ident });
    try expectCats("a\n\tb", &.{ .ident, .err });
    try expectCats("a\n    b\n  c", &.{ .ident, .indent, .ident, .err });
}

test "closure bar lists: typed parameters, empty bars, owned star" {
    try expectCats("f = |+v, a: Int| a", &.{ .ident, .assign, .bar_capture, .plus, .ident, .comma, .ident, .colon, .ident, .bar_capture, .ident });
    try expectCats("f = |s: ?{A + B}| s", &.{ .ident, .assign, .bar_capture, .ident, .colon, .question, .lbrace, .ident, .plus, .ident, .rbrace, .bar_capture, .ident });
    try expectCats("f = |?v, !w, a| a", &.{ .ident, .assign, .bar_capture, .question, .ident, .comma, .not_sym, .ident, .comma, .ident, .bar_capture, .ident });
    try expectCats("g = || 1", &.{ .ident, .assign, .bar_empty, .integer });
    try expectCats("h = *|a| a", &.{ .ident, .assign, .star, .bar_capture, .ident, .bar_capture, .ident });
    try expectCats("x = a | b", &.{ .ident, .assign, .ident, .bar, .ident });
    try expectCats("x = a * b", &.{ .ident, .assign, .ident, .star, .ident });
    try expectCats("x = a || b", &.{ .ident, .assign, .ident, .err });
}

/// `n` copies of `c`, for building long test strings.
fn chars(comptime c: u8, comptime n: usize) *const [n]u8 {
    const s: [n]u8 = @splat(c);
    return &s;
}

test "tokens over 65534 bytes keep their category and their end" {
    try expectCats("#" ++ chars('c', 70000) ++ "\nx", &.{ .ident, .eof });
    try expectCats("x = 1 # " ++ chars('c', 70000) ++ "\ny", &.{ .ident, .assign, .integer, .newline, .ident, .eof });
    const source = "x = \"" ++ chars('y', 70000) ++ "\" + " ++ chars('z', 65535) ++ "\n";
    var lx = Lexer.init(source);
    _ = lx.next();
    _ = lx.next();
    const str = lx.next();
    try testing.expectEqual(TokenCat.string_dq, str.cat);
    try testing.expectEqual(@as(u32, 4 + 70002), endOf(&lx.base, str));
    try testing.expectEqual(@as(u32, 4 + 70002), lx.prev_end);
    try testing.expectEqual(TokenCat.plus, lx.next().cat);
    const name = lx.next();
    try testing.expectEqual(TokenCat.ident, name.cat);
    try testing.expectEqual(@as(u32, source.len - 1), endOf(&lx.base, name));
    try testing.expectEqual(@as(?TokenCat, null), keyword(chars('a', 70000)));
}

test "leafEnd and leafText: a long leaf's whole text, as the parser kept it" {
    const source = "sub main()\n  s = '" ++ chars('q', 65533) ++ "'\n  print(s)\n";
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    const tree = try p.parseProgram();
    _ = tree;
    try testing.expectEqual(@as(usize, 1), p.base.longTokenEnds.items.len);
    const kept = p.base.longTokenEnds.items[0];
    const leaf: parser.Src = .{ .pos = kept.pos, .len = std.math.maxInt(u16), .id = 0 };
    try testing.expectEqual(kept.end, leafEnd(source, leaf));
    try testing.expectEqual(@as(usize, 65535), leafText(source, leaf).len);
    try testing.expectEqualStrings(p.base.leafText(.{ .src = leaf }), leafText(source, leaf));
}

test "hidden leaves take the positions past the source's end, up to `last_hidden_pos`" {
    const source = "sub main()\n  print(1)\n";
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    const first = try p.hiddenPos(3);
    try testing.expectEqual(@as(u32, source.len + 1), first);
    try testing.expectEqual(parser.Span{ .start = 3, .end = 3 }, p.span(hiddenLeaf(first, .discard)));
    // As many as fit past a source of the most bytes a module holds;
    // the last ends with no overflow, and one more is out of room.
    p.padded = last_hidden_pos - 1 - source.len;
    const last = try p.hiddenPos(5);
    try testing.expectEqual(last_hidden_pos, last);
    try testing.expectEqual(last_hidden_pos + 1, leafEnd(source, hiddenLeaf(last, .discard).src));
    try testing.expectError(error.OutOfMemory, p.hiddenPos(5));
}

test "leafSpan: from the first leaf to the end of the last" {
    var inner = [_]Sexp{ .{ .tag = .@"+" }, .{ .src = .{ .pos = 4, .len = 1, .id = 0 } }, .{ .src = .{ .pos = 8, .len = 2, .id = 0 } } };
    const s = leafSpan("0123456789", Sexp.listOf(&inner));
    try testing.expectEqual(@as(u32, 4), s.start);
    try testing.expectEqual(@as(u32, 10), s.end);
}

test "layout: a closure body inside brackets is laid out in blocks" {
    try expectCats("f(*|x|\n  g(x)\n  h)\ny", &.{
        .ident,  .lparen,  .star,   .bar_capture, .ident,  .bar_capture,
        .indent, .ident,   .lparen, .ident,       .rparen, .newline,
        .ident,  .outdent, .rparen, .newline,     .ident,
    });
    // Coming back to the closure's line ends the body.
    try expectCats("f(||\n  g\n, 1)", &.{ .ident, .lparen, .bar_empty, .indent, .ident, .outdent, .comma, .integer, .rparen });
    // The bracket around the body goes on a line of its own, at the
    // indentation of the line that opened it.
    try expectLayout("f(*|x|\n  g(x)\n  h\n)\ny", &.{});
    try expectLayout("  r = (|+n|\n    n\n  )()", &.{});
    try expectLayout("f(*|x|\n  g(x)\n  h)\ny", &.{.closure_hanging});
    try expectLayout("f(||\n  g\n, 1)", &.{.closure_close});
    try expectLayout("f(||\n  g\n  )", &.{.closure_indent});
}

test "writeZigIdent escapes Zig keywords and emitter names" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    for ([_][]const u8{ "var", "u8", "rig", "count", "_", "debug", "std_options_cwd", "__rig_x" }) |n| {
        try writeZigIdent(&w, n, .rig);
        try w.writeAll(" ");
    }
    try writeZigIdent(&w, "panic", .exact);
    try testing.expectEqualStrings("@\"var\" @\"u8\" @\"rig'\" count @\"_\" @\"debug'\" @\"std_options_cwd'\" @\"__rig_x'\" panic", w.buffered());
}

test "a condition's guard parts: each part a binding condition joins, or the whole condition" {
    const source =
        \\while a as x and x > 0 and b as y: i += 1
        \\  pass
        \\while i < n and s[i] > 0
        \\  pass
        \\if a as x and (p and q)
        \\  pass
        \\
    ;
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    const tree = try p.parseProgram();
    const Parts = struct {
        texts: [4][]const u8 = undefined,
        n: usize = 0,
        parser: *const Parser,
        fn part(self: *@This(), e: Sexp) !void {
            const sp = self.parser.span(e);
            self.texts[self.n] = self.parser.base.source[sp.start..sp.end];
            self.n += 1;
        }
    };
    const decls = ir.Module.decls(tree);
    const want = [_][]const []const u8{
        &.{ "a as x", "x > 0", "b as y" },
        &.{"i < n and s[i] > 0"},
        &.{ "a as x", "p and q" },
    };
    for (decls, want) |d, w| {
        const cond = if (d.isKind(.@"while")) ir.While.cond(d) else ir.If.cond(d);
        var parts: Parts = .{ .parser = &p };
        try eachGuardPart(cond, &parts);
        try testing.expectEqual(w.len, parts.n);
        for (w, parts.texts[0..parts.n]) |a, b| try testing.expectEqualStrings(a, std.mem.trim(u8, b, " "));
    }
}

test "a body's units: statements, guard parts, steps, sources, selections, and raw blocks, nested in the unit holding their block" {
    const source =
        \\fun f(s: ?String, o: Int?, k: Int) -> Int
        \\  i = 0
        \\  while o as x and i < s.len and s[i] > 0: i += 1
        \\    if i > 2 and x > 1
        \\      break
        \\  for c in s[i..]
        \\    print(c)
        \\  match k
        \\    1 if i > 0 => print(1)
        \\    _ => pass
        \\  y = match k
        \\    1
        \\      print(2)
        \\      3
        \\    _ => 4
        \\  raw
        \\    print(5)
        \\  defer print(6)
        \\  g = |n: Int| n + 1
        \\  i + y + g(1)
        \\
    ;
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    const tree = try p.parseProgram();
    const Units = struct {
        lines: std.ArrayList(u8) = .empty,
        depth: usize = 0,
        parser: *const Parser,
        pub fn enter(self: *@This(), root: Sexp, kind: UnitKind) std.mem.Allocator.Error!void {
            const sp = self.parser.span(root);
            const text = std.mem.trim(u8, self.parser.base.source[sp.start..sp.end], " \n");
            const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
            for (0..self.depth) |_| try self.lines.appendSlice(testing.allocator, "  ");
            try self.lines.print(testing.allocator, "{s} {s}\n", .{ @tagName(kind), text[0..line_end] });
            self.depth += 1;
        }
        pub fn exit(self: *@This(), _: Sexp) std.mem.Allocator.Error!void {
            self.depth -= 1;
        }
    };
    var units: Units = .{ .parser = &p };
    defer units.lines.deinit(testing.allocator);
    const Body = struct {
        fn each(u: *Units, _: Sexp, body: Sexp) std.mem.Allocator.Error!void {
            try eachUnit(body, u);
        }
    };
    try eachBody(tree, &units, Body.each);
    try testing.expectEqualStrings(
        \\stmt i = 0
        \\guard o as x
        \\guard i < s.len
        \\guard s[i] > 0
        \\guard i > 2
        \\guard x > 1
        \\stmt break
        \\step i += 1
        \\source s[i..]
        \\stmt print(c)
        \\selection match k
        \\stmt print(1)
        \\stmt pass
        \\stmt y = match k
        \\  stmt print(2)
        \\raw raw
        \\stmt print(6)
        \\stmt g = |n: Int| n + 1
        \\  stmt n + 1
        \\stmt i + y + g(1)
        \\
    , units.lines.items);
}

test "a body's exits are `return`, `!`, and `?`; the jumps are `break` and `continue`" {
    const source =
        \\fun f(o: Int?, r: Int!) -> Int?
        \\  for i in 0..3
        \\    break if i == 1
        \\    continue
        \\  x = o?
        \\  y = r!
        \\  return x + y
        \\
    ;
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    const tree = try p.parseProgram();
    const Count = struct {
        exits: usize = 0,
        jumps: usize = 0,
        fn walk(self: *@This(), e: Sexp) void {
            if (leavesBody(e)) self.exits += 1;
            if (isJump(e)) self.jumps += 1;
            std.debug.assert(!(leavesBody(e) and isJump(e)));
            if (e == .list) for (e.items()) |c| self.walk(c);
        }
    };
    var c: Count = .{};
    c.walk(tree);
    try testing.expectEqual(3, c.exits);
    try testing.expectEqual(2, c.jumps);
}

test "parser: for-source sigil moves into the mode slot" {
    var p = Parser.init(testing.allocator, "for x in ?xs\n  print(x)\n");
    defer p.deinit();
    const tree = try p.parseProgram();
    const loop = ir.Module.decls(tree)[0];
    try testing.expectEqual(Tag.read, ir.For.mode(loop).tag);
    try testing.expectEqualStrings("xs", ir.For.source(loop).getText(p.base.source));
}

test "parser: a self sigil moves onto the place before the method" {
    const source = "!x.v[0].push(1)\n(!v).push(2)\n!(v.pop())\n!f(x).g()\n?p.m()\n?(p.m())\n?f(x).g()\n!(+s).g()\n!a.b(x)(y).g()\n";
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    const tree = try p.parseProgram();
    const stmts = ir.Module.decls(tree);
    // (call (member (write (index (member x v) 0)) push) 1)
    const recv = ir.Member.object(ir.Call.callee(stmts[0]));
    try testing.expect(recv.isKind(.write) and p.isSelfSigil(recv));
    const s = p.span(recv);
    try testing.expectEqualStrings("!x.v[0]", source[s.start..s.end]);
    try testing.expect(ir.Write.operand(recv).isKind(.index));
    // Parentheses keep their meaning, and are not a self sigil.
    const long = ir.Member.object(ir.Call.callee(stmts[1]));
    try testing.expect(long.isKind(.write) and !p.isSelfSigil(long));
    try testing.expect(stmts[2].isKind(.write));
    // `!` lends any value to write: a called head is self.
    const made = ir.Member.object(ir.Call.callee(stmts[3]));
    try testing.expect(made.isKind(.write) and p.isSelfSigil(made));
    try testing.expect(ir.Write.operand(made).isKind(.call));
    // `?` reaches self too, and lends a parenthesized call.
    const read = ir.Member.object(ir.Call.callee(stmts[4]));
    try testing.expect(read.isKind(.read) and p.isSelfSigil(read));
    try testing.expect(stmts[5].isKind(.read));
    // A `?` before a called head lends the result.
    try testing.expect(stmts[6].isKind(.read));
    // A parenthesized self is lent to write by `!`.
    const paren = ir.Member.object(ir.Call.callee(stmts[7]));
    try testing.expect(paren.isKind(.write) and p.isSelfSigil(paren));
    try testing.expect(ir.Write.operand(paren).isKind(.clone));
    // A call of a call's value: the first method call's self, `a`.
    var head = stmts[8];
    while (!head.isKind(.write)) head = if (head.isKind(.call)) ir.Call.callee(head) else ir.get(head, .object);
    try testing.expect(p.isSelfSigil(head) and ir.Write.operand(head) == .src);
}

test "parser: bar lists split into captures and parameters, all with node ids" {
    const source = "f = |+c, a| a + c\n";
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    const raw = try p.parseTree();
    const tree = try p.rewrite(raw);
    const set = ir.Module.decls(tree)[0];
    try testing.expectEqual(ir.Module.decls(raw)[0].list.id, set.list.id);
    const lambda = ir.Set.value(set);
    const captures = ir.Lambda.captures(lambda);
    try testing.expect(captures.isKind(.captures));
    try testing.expectEqual(@as(usize, 1), ir.Lambda.params(lambda).items().len);
    const s = p.span(lambda);
    try testing.expectEqualStrings("|+c, a| a + c", source[s.start..s.end]);
    // The wrapper's `captures` node gets its own id, spanning its entries.
    try testing.expect(captures.list.id != 0);
    const cs = p.span(captures);
    try testing.expectEqualStrings("+c", source[cs.start..cs.end]);
}

fn parses(source: []const u8) !void {
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    _ = try p.parseProgram();
}

test "parser: every form parses" {
    try parses(
        \\use m
        \\
        \\type Id = U64
        \\
        \\obj Wrap[T]
        \\  value: T
        \\
        \\  fun get(?@) -> T
        \\    @value
        \\
        \\enum Shape
        \\  circle(radius: Int)
        \\  empty()
        \\  dot
        \\
        \\enum Code
        \\  ok = 200
        \\
        \\error Net
        \\  timeout
        \\
        \\obj P
        \\  n: Int
        \\
        \\  drop(!@)
        \\    print(@n)
        \\
        \\obj Random unique
        \\  seed: Int
        \\
        \\pub obj Ring[T] unique
        \\  item: T
        \\
        \\extern fun abs(n: Int) -> Int
        \\extern fun tick(n: Int)
        \\extern sub halt()
        \\extern count: Int
        \\
        \\pub fun f[c: Int](a: Int, b: Int = 2) -> Int!
        \\  a
        \\
        \\test "t"
        \\  print(1)
        \\
        \\sub main()
        \\  x = 1
        \\  y: [2]Int =! [1, 2]
        \\  y2 =! y
        \\  new x = x + 1
        \\  new x: Int = x + 1
        \\  new x =! x + 1
        \\  new y2: [2]Int =! y
        \\  x += 1
        \\  x <<= 2
        \\  z = <w
        \\  <z
        \\  if x > 1
        \\    print(x, y)
        \\  else if not (x < 0 and true)
        \\    return
        \\  if m as v
        \\    print(v)
        \\  $outer: while x < 3 : x += 1
        \\    break $outer
        \\  $done:
        \\    break $done if x > 2
        \\    x += 1
        \\  while m as v
        \\    continue
        \\  loop
        \\    break
        \\  for a, i in ?xs
        \\    print(a[i])
        \\  match s
        \\    .circle(r) => print(r)
        \\    1..3 => print(-1)
        \\    _
        \\      print(2)
        \\  g = |+c, <d, ~e, k: Int, j| c + k
        \\  h = *|+c| c.set($size(Int))
        \\  i = || print(1)
        \\  v = f(1, b: 3) catch 0
        \\  u = f(1)!
        \\  t = f(1) catch |err| 0
        \\  q = a ?? b
        \\  o = 1 if c else 2
        \\  defer print(1)
        \\  raw
        \\    print($intCast(x))
        \\  print(+a, <b, ?c, !d, *e, ~f, v.w[0])
        \\  n: fun() -> Int = f
        \\  n2: *sub(Int, ?Wrap[Int]) = h
        \\  n3: sub() = i
        \\  o2: *Wrap[Int]? = none
        \\  p2 = Pair[Int, ?String].make(f[3](1), v[0])
        \\  o3: []~Int = o
        \\  return x
        \\
    );
}

test "parser: a definition writes its parameter list, even when empty" {
    const cases = [_][2][]const u8{
        .{ "sub main\n  pass\n", "write `sub main()`: a function's parameter list is always written, even when empty" },
        .{ "fun answer -> Int  # the answer\n  42\n", "write `fun answer() -> Int`" },
        .{ "fun first[T, n: Int] -> T?\n  none\n", "write `fun first[T, n: Int]() -> T?`" },
        .{ "sub save!\n  pass\n", "write `sub save()!`" },
        .{ "obj S\n  n: Int\n\n  pub fun get -> Int\n    1\n", "write `fun get() -> Int`" },
        .{ "extern fun now -> Int\n", "write `extern fun now() -> Int`" },
        .{ "extern sub halt\n", "write `extern sub halt()`" },
        .{ "extern zig \"z.zig\"\n  pub fun one -> Int\n", "write `fun one() -> Int`" },
    };
    for (cases) |c| {
        var p = Parser.init(testing.allocator, c[0]);
        defer p.deinit();
        try testing.expectError(error.ParseError, p.parseProgram());
        const d = p.diagnostic();
        testing.expect(std.mem.startsWith(u8, d.message, c[1])) catch |e| {
            std.debug.print("source: {s}\n  got: {s}\n", .{ c[0], d.message });
            return e;
        };
    }
}

test "a keyword after `$` names a builtin" {
    try expectCats("$type(x)", &.{ .dollar, .ident, .lparen, .ident, .rparen });
    try expectCats("$size($type(x))", &.{ .dollar, .ident, .lparen, .dollar, .ident, .lparen, .ident, .rparen, .rparen });
}

/// What one parse of `p` gave, as text: the tree with every node's id
/// and span, or the diagnostics, and what the wrapper recorded beside it.
fn parseOutcome(p: *Parser, out: *std.Io.Writer.Allocating) !void {
    const w = &out.writer;
    if (p.parseProgram()) |tree| {
        try p.base.writeFacts(w, tree);
        try tree.write(p.base.source, w);
    } else |err| switch (err) {
        error.ParseError => {
            try w.print("{s}\n", .{p.diagnostic().message});
            for (p.moreDiagnostics()) |d| try w.print("{s}\n", .{d.message});
        },
        else => |e| return e,
    }
    try w.print("\nsigils {d} suffixes {d} detached {d} padded {d} homes {d} depth {d}\n", .{
        p.self_sigils.count(), p.paren_suffixes.count(), p.detached.items.len, p.padded, p.pad_homes.items.len, p.type_depth,
    });
}

test "parser: a reset parser parses as a new one" {
    const sources = [_][]const u8{
        // Self sigils, a `?` in parentheses after a sigil, a method
        // outside its type's body.
        "obj Box\n  n: Int\n\nfun Nope.m() -> Int\n  1\n\nsub main()\n  !v.push(1)\n  x: *(Int?) = none\n",
        "use std.text\n\nfun twice(n: Int) -> Int\n  n * 2\n\nsub main()\n  print(twice(21))\n",
        // Rejected after it parses: the failure and the ones after it.
        "sub main\n  pass\n\nfun answer -> Int\n  42\n",
        "",
    };
    for (sources) |first| for (sources) |second| {
        var fresh = Parser.init(testing.allocator, second);
        defer fresh.deinit();
        var want: std.Io.Writer.Allocating = .init(testing.allocator);
        defer want.deinit();
        try parseOutcome(&fresh, &want);

        var p = Parser.init(testing.allocator, first);
        defer p.deinit();
        var ignored: std.Io.Writer.Allocating = .init(testing.allocator);
        defer ignored.deinit();
        try parseOutcome(&p, &ignored);
        p.reset(second);
        var got: std.Io.Writer.Allocating = .init(testing.allocator);
        defer got.deinit();
        try parseOutcome(&p, &got);
        testing.expectEqualStrings(want.written(), got.written()) catch |e| {
            std.debug.print("after: {s}\n", .{first});
            return e;
        };
    };
}

test "parser: a parser reset over many parses keeps no more memory" {
    const source = "fun twice(n: Int) -> Int\n  n * 2\n\nsub main()\n  !v.push(twice(1))\n";
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    _ = try p.parseProgram();
    p.reset(source);
    _ = try p.parseProgram();
    const held = p.base.arena.queryCapacity();
    for (0..50) |_| {
        p.reset(source);
        _ = try p.parseProgram();
    }
    try testing.expect(p.base.arena.queryCapacity() <= held);
}
