//! Typecheck's compatibility and classification: whether a value of
//! one type goes where another is expected, and the questions about a
//! type the checks ask.

const std = @import("std");
const parser = @import("../parser.zig");
const rig = @import("../rig.zig");
const sema = @import("../sema.zig");
const Wide = sema.Wide;
const Sexp = parser.Sexp;
const ir = parser.ir;
const Tag = rig.Tag;
const SemContext = sema.SemContext;
const SymbolId = sema.SymbolId;
const TypeId = sema.TypeId;
const Type = sema.Type;
const Field = sema.Field;
const Error = std.mem.Allocator.Error;
const identAt = sema.identAt;
const tc = @import("../typecheck.zig");
const Checker = tc.Checker;

/// The type an operator reads from an operand: a viewed Copy value
/// (`readValue`), or the `T` a viewed type parameter reaches. Every
/// `T` an operator's requirement admits is plain data, so reading one
/// through its view copies no resource.
pub fn operandValue(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view => |inner| if (ctx.types.get(inner) == .type_var) inner else readValue(ctx, ty),
        else => ty,
    };
}

/// A view of a scalar (`sema.readsAsValue`) reads as the scalar to an
/// operator: `n + 1` with `n: ?Int` or `n: !Int` is an `Int`.
pub fn readValue(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .read_view, .write_view => |inner| if (sema.readsAsValue(ctx, inner)) inner else ty,
        else => ty,
    };
}

/// The type a binding with no type takes from a bare name or place of
/// type `ty` (Core sentence 1): a write view, which is never copied,
/// reads the value it reaches where that copies (`sema.copiedThrough`);
/// a read view is copied, but one of a scalar binds the scalar
/// (`readValue`).
pub fn bindingValue(ctx: *const SemContext, ty: TypeId) TypeId {
    return switch (ctx.types.get(ty)) {
        .write_view => sema.copiedThrough(ctx, ty) orelse ty,
        else => readValue(ctx, ty),
    };
}

/// Whether `ty` can be written in an expression's bracket list
/// (`id[Wrap[Int]](...)`): array, slice, and function types cannot.
pub fn spelledInBrackets(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .slice, .array, .function => false,
        .optional, .read_view, .write_view, .shared, .weak => |inner| spelledInBrackets(ctx, inner),
        .fallible => |inner| spelledInBrackets(ctx, inner.ok),
        .parameterized_nominal => |pn| for (pn.args) |arg| {
            if (!spelledInBrackets(ctx, arg)) break false;
        } else true,
        else => true,
    };
}

/// `x` of `?x`, `!x`, or `<x`; any other node as it is.
pub fn stripSigil(e: Sexp) Sexp {
    return if (e.isKind(.read) or e.isKind(.write) or e.isKind(.move)) ir.get(e, .operand) else e;
}

/// The place `?x` or `!x` views (through any number of them); any other
/// node, `<x` among them, as it is.
pub fn viewedPlace(e: Sexp) Sexp {
    var p = e;
    while (p.isKind(.read) or p.isKind(.write)) p = ir.get(p, .operand);
    return p;
}

/// The leaf a place starts from, through views and moves of its parts:
/// `a` in `!(!a.b)[i]`.
pub fn placeRoot(e: Sexp) ?Sexp {
    const x = sema.pathRoot(e);
    if (x == .src) return x;
    return if (x.isKind(.read) or x.isKind(.write) or x.isKind(.move)) placeRoot(ir.get(x, .operand)) else null;
}

/// The first `<x` in `e`, if any.
pub fn findMove(e: Sexp) ?Sexp {
    if (e != .list) return null;
    if (e.isKind(.move)) return e;
    for (e.items()) |c| if (findMove(c)) |m| return m;
    return null;
}

/// Can a value of type `actual` be used where `expected` is required?
/// As itself (`meets`), or as a copy of the value a view of it reaches
/// (`copiedOut`).
pub fn compatible(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
    return meets(ctx, actual, expected) or copiedOut(ctx, actual, expected);
}

/// Whether a view `actual` meets `expected` only as a copy of the value
/// it reaches (`sema.copiedThrough`): that value meets `expected`,
/// and the view itself does not. A view of a value that copies is copied
/// out where the value is expected (Core §4), and the view is read
/// through there (`Checker.recordAdapted`).
pub fn copiedOut(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
    const inner = sema.copiedThrough(ctx, actual) orelse return false;
    return !meets(ctx, actual, expected) and compatible(ctx, inner, expected);
}

/// How many levels of optional `ty` has.
pub fn optionalDepth(ctx: *const SemContext, ty: TypeId) u32 {
    var n: u32 = 0;
    var t = ty;
    while (ctx.types.get(t) == .optional) : (n += 1) t = ctx.types.get(t).optional;
    return n;
}

/// Can a value of type `actual` be used as itself where `expected` is
/// required?
pub fn meets(ctx: *const SemContext, actual: TypeId, expected: TypeId) bool {
    if (actual == expected) return true;
    const ts = &ctx.types;
    if (actual == ts.invalid_id or actual == ts.unknown_id or expected == ts.invalid_id or expected == ts.unknown_id) return true;
    if (actual == ts.noreturn_id) return true;
    const a = ts.get(actual);
    const e = ts.get(expected);
    switch (e) {
        .optional => |inner| {
            if (a == .none_literal) return true;
            // A `Static?` is read as a `(?String)?`.
            if (a == .optional) if (sema.readsAsStringView(ctx, a.optional, inner)) return true;
            return meets(ctx, actual, inner);
        },
        // A `Static` is read as the `?String` it is, a view that carries
        // no loan. Only where the text is read: a place that can be
        // written (`!x`) holds exactly its type.
        .string_view => if (a == .static) return true,
        .read_view => |inner| if (sema.readsAsStringView(ctx, actual, expected)) return true else if (a == .write_view) return a.write_view == inner else if (inner == ts.any_error_id and a == .read_view and sema.isSetParam(ctx, a.read_view)) return true,
        // A `T!` holds a `T`; an error value meets it only as `return`'s
        // operand (`Checker.isReturnLeaf`).
        .fallible => |inner| {
            // A `T!A` meets a `T!L` whose set holds `A`'s.
            if (a == .fallible) return a.fallible.ok == inner.ok and sema.errorSubset(ctx, a.fallible.set, inner.set);
            return meets(ctx, actual, inner.ok);
        },
        // `error` holds an error of any set, a set parameter's included.
        .any_error => if (sema.isErrorSet(ctx, actual) or sema.isSetParam(ctx, actual)) return true,
        // A `![]T` (or a `?[]T`) reads as the `[]T` it views.
        .slice => |want| switch (a) {
            .read_view, .write_view => |inner| if (inner == expected) return true,
            // The elements of a `[]Static` are read as `?String`s.
            .slice => |have| if (sema.readsAsStringView(ctx, have.elem, want.elem)) return true,
            else => {},
        },
        // A union holds an error of each set it joins.
        .nominal => if (sema.isErrorUnion(ctx, expected) and sema.isErrorSet(ctx, actual) and sema.errorSubset(ctx, actual, expected)) return true,
        else => {},
    }
    return switch (a) {
        // A literal is a `Slot[n]` below `n` (`Checker.checkLiteralFits`).
        .int_literal => e == .int or e == .float or e == .slot,
        .float_literal => e == .float,
        else => false,
    };
}

pub const SelfTypeKind = enum { owned_nominal, read_view, write_view, shared, other };

/// What kind of value a method's self is, for the type whose symbol
/// is `nominal_sym` (`symbol_invalid` for an imported type).
pub fn classifySelfType(ctx: *const SemContext, ty_id: TypeId, nominal_sym: SymbolId) SelfTypeKind {
    const matches = struct {
        fn f(c: *const SemContext, id: TypeId, sym: SymbolId) bool {
            // A box's value is reached as the box is: owned, or viewed,
            // or through the read view it holds.
            if (c.ref(sym) != c.builtins.box) if (sema.boxedType(c, id)) |inner| return f(c, sema.unwrapViews(c, inner), sym);
            return switch (c.types.get(id)) {
                .nominal => |s| if (c.owns(s)) s.sym == sym else sym == sema.symbol_invalid,
                .parameterized_nominal => |pn| pn.sym == c.ref(sym),
                else => false,
            };
        }
    }.f;
    // A view of a shared handle (`!h.m()` with `h: *T`) still reaches
    // the value through the handle, and so does a box of one, for a
    // method of the value (not the box's own).
    if (ctx.types.get(sema.unwrapViews(ctx, ty_id)) == .shared) return .shared;
    if (ctx.ref(nominal_sym) != ctx.builtins.box and sema.accessThroughShared(ctx, ty_id)) return .shared;
    // A box of a read view (`^?T`) reaches its value through the view.
    if (ctx.ref(nominal_sym) != ctx.builtins.box and sema.boxedReadView(ctx, ty_id) != null) return if (matches(ctx, sema.unwrapViews(ctx, ty_id), nominal_sym)) .read_view else .other;
    return switch (ctx.types.get(ty_id)) {
        .read_view => |i| if (matches(ctx, i, nominal_sym)) .read_view else .other,
        .write_view => |i| if (matches(ctx, i, nominal_sym)) .write_view else .other,
        else => if (matches(ctx, ty_id, nominal_sym)) .owned_nominal else .other,
    };
}

/// How a self is written: with a self sigil (`?v.m()`, `!v.m()`,
/// `<v.m()`, Core §8), or bare, by what it hands over
/// (`Checker.selfShape`).
pub const SelfShape = enum { read_explicit, write_explicit, move_explicit, made, branches, place };

/// The sigil of a self sigil node, as written.
pub fn sigilText(recv: Sexp) []const u8 {
    return if (recv.isKind(.read)) "?" else if (recv.isKind(.write)) "!" else "<";
}

/// The element type of a Cell self (`Cell[T]`, `?Cell[T]`, `*Cell[T]`, ...).
pub fn cellElementType(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const pn = switch (ctx.types.get(sema.unwrapReadAccess(ctx, ty))) {
        .parameterized_nominal => |pn| pn,
        else => return null,
    };
    if (pn.sym != ctx.builtins.cell or pn.args.len != 1) return null;
    return pn.args[0];
}

/// Whether `node` lies in the index of an element read in `tree`.
pub fn inIndex(tree: Sexp, node: Sexp) bool {
    if (tree != .list) return false;
    if (tree.isKind(.index) and contains(ir.Index.index(tree), node)) return true;
    for (tree.items()) |item| if (inIndex(item, node)) return true;
    return false;
}

/// Whether `node` lies in an argument of a call in `tree`.
pub fn inArgument(tree: Sexp, node: Sexp) bool {
    if (tree != .list) return false;
    if (tree.isKind(.call)) for (ir.Call.args(tree)) |a| if (contains(a, node)) return true;
    for (tree.items()) |item| if (inArgument(item, node)) return true;
    return false;
}

/// Whether `node` is `tree` or inside it.
pub fn contains(tree: Sexp, node: Sexp) bool {
    if (sameNode(tree, node)) return true;
    if (tree != .list) return false;
    for (tree.items()) |item| if (contains(item, node)) return true;
    return false;
}

/// The element type of a Cell holding a List (`Cell[List[E]]`, `?Cell[List[E]]`, `*Cell[List[E]]`, ...).
pub fn cellListElement(ctx: *const SemContext, ty: TypeId) ?TypeId {
    return listElementType(ctx, cellElementType(ctx, ty) orelse return null);
}

pub const slice_of_temporary = "only a named array, List, or String, or a field or element of one, can be sliced; bind this value to a name first";

pub const cell_list_handle = "cannot read or overwrite an element of a `{s}` in place: its elements are handles, which would be copied out or released while the cell holds them; `pop` the element, or `swap` the List out to work on it";

/// The data field (not a method or variant) named `name`.
pub fn findDataField(ctx: *SemContext, fields: []const Field, name: []const u8) Error!?Field {
    return fields[(try sema.findMember(ctx, fields, name, .data)) orelse return null];
}

/// The element type of a `List[T]`.
pub fn listElementType(ctx: *const SemContext, ty: TypeId) ?TypeId {
    const pn = switch (ctx.types.get(ty)) {
        .parameterized_nominal => |pn| pn,
        else => return null,
    };
    if (pn.sym != ctx.builtins.list or pn.args.len != 1) return null;
    return pn.args[0];
}

/// An arithmetic operation: unary minus or a binary arithmetic,
/// bitwise, or shift operator.
pub fn isArithmetic(e: Sexp) bool {
    const h = e.kind() orelse return false;
    return switch (h) {
        .neg, .@"+", .@"-", .@"*", .@"/", .@"%", .@"+%", .@"-%", .@"*%", .@"+|", .@"-|", .@"<<", .@"<<%", .@">>", .@"&", .@"|", .@"^" => true,
        else => false,
    };
}

/// What a slice argument (`Checker.slicedArg`) of type `actual` views
/// where a `view` is expected: the view it is, which goes where its own
/// type does (a `[]T` or a `?String`, or an optional of one). Null
/// elsewhere.
pub fn sliceArgView(ctx: *const SemContext, actual: TypeId, view: TypeId) ?sema.View {
    return if (compatible(ctx, actual, view)) .{ .ty = view } else null;
}

/// `String` for a type that reaches a String through boxes and handles
/// (`sema.unwrapAccess`), which is viewed through them; any other type as
/// it is.
pub fn stringOrBoxed(ctx: *const SemContext, ty: TypeId) TypeId {
    return if (sema.unwrapAccess(ctx, ty) == ctx.types.string_id) ctx.types.string_id else ty;
}

/// Why enum `ty`, which has variants, is not plain: its payloads, or its
/// type parameters.
pub fn notPlainWhy(ctx: *const SemContext, ty: TypeId) []const u8 {
    const generic = if (sema.nominalDecl(ctx, ty)) |d| d.symbol().type_params != null else false;
    return if (generic) "is generic" else "has variants with payloads";
}

pub const isText = sema.isText;

/// The bytes a string literal holds: a double-quoted one with its escapes
/// read as Zig reads them, a single-quoted one as `sema.SingleQuoted`
/// reads it. Null for an escape the checker rejects.
pub fn textLiteralBytes(a: std.mem.Allocator, lit: []const u8) ?[]const u8 {
    if (rig.isBlockText(lit)) return rig.literalBytes(a, lit);
    if (lit[0] == '"') return std.zig.string_literal.parseAlloc(a, lit) catch null;
    var bytes: std.ArrayList(u8) = .empty;
    var it = sema.SingleQuoted.init(lit);
    while (it.next()) |c| bytes.append(a, c) catch return null;
    return bytes.items;
}

pub fn numericBits(t: sema.Type) ?u16 {
    return switch (t) {
        .int => |i| intBounds(i).bits,
        .float => |f| if (f.bits == 0) 64 else f.bits,
        else => null,
    };
}

pub const IntBounds = struct { min: Wide, max: Wide, bits: u8 };

/// The width and value range of an integer type.
pub fn intBounds(info: sema.IntInfo) IntBounds {
    const bits: u8 = if (info.bits == 0) 64 else info.bits;
    const half = @as(Wide, 1) << @intCast(bits - 1);
    return if (info.signed) .{ .min = -half, .max = half - 1, .bits = bits } else .{ .min = 0, .max = 2 * half - 1, .bits = bits };
}

/// The first division of whole-number literals (`7 / 2`, `9 % 4`) that
/// a literal context reaches in `e`: through negation, a ternary's
/// branches, `+`, `-`, `*`, a comparison of literals, and a division
/// that is not one.
pub fn wholeDivision(source: []const u8, e: Sexp) ?Sexp {
    const h = e.kind() orelse return null;
    return switch (h) {
        .neg => wholeDivision(source, ir.Neg.operand(e)),
        .@"if" => wholeDivision(source, ir.If.then(e)) orelse wholeDivision(source, ir.If.@"else"(e)),
        .@"+", .@"-", .@"*", .@"<", .@">", .@"<=", .@">=", .@"==", .@"!=" => wholeDivision(source, ir.get(e, .left)) orelse wholeDivision(source, ir.get(e, .right)),
        .@"/", .@"%" => if (wholeLiterals(source, ir.get(e, .left)) and wholeLiterals(source, ir.get(e, .right)))
            e
        else
            wholeDivision(source, ir.get(e, .left)) orelse wholeDivision(source, ir.get(e, .right)),
        else => null,
    };
}

/// An expression of whole-number literals: integer literals, and
/// arithmetic and builtins (`$size(T)`) over them.
pub fn wholeLiterals(source: []const u8, e: Sexp) bool {
    return switch (e) {
        .src => sema.isIntLiteralText(identAt(source, e) orelse ""),
        .list => switch (e.kind() orelse return false) {
            .neg => wholeLiterals(source, ir.Neg.operand(e)),
            .@"+", .@"-", .@"*", .@"/", .@"%" => wholeLiterals(source, ir.get(e, .left)) and wholeLiterals(source, ir.get(e, .right)),
            .builtin => true,
            else => false,
        },
        else => false,
    };
}

/// Whether numeric type `ty` holds the integer `v`: in range for an
/// integer type, exactly representable for a float type (Zig rejects a
/// constant that would round).
pub fn holdsInt(ctx: *const SemContext, ty: TypeId, v: Wide) bool {
    return switch (ctx.types.get(ty)) {
        .slot => |n| if (sema.slotCount(ctx, n)) |c| v >= 0 and v < c else false,
        .int => |info| v >= intBounds(info).min and v <= intBounds(info).max,
        .float => |f| blk: {
            const mantissa: u8 = if (f.bits == 32) 24 else 53;
            const a = @abs(v);
            break :blk a == 0 or @bitSizeOf(Wide) - @clz(a) - @ctz(a) <= mantissa;
        },
        else => true,
    };
}

/// `loop` with no `break` out of it: the loop only ends by
/// `return`, so a function may end with it.
pub fn loopsForever(source: []const u8, s: Sexp) bool {
    return sema.isLoop(source, s) and !sema.breaksOut(source, s, false);
}

/// `return`, `break`, `continue`, or `panic`: a fallback that leaves.
pub fn isJumpNode(e: Sexp) bool {
    return rig.leaves(e);
}

/// Whether `e` names `name` anywhere in `source`.
pub fn readsNameIn(source: []const u8, e: Sexp, name: []const u8) bool {
    return switch (e) {
        .src => |leaf| std.mem.eql(u8, rig.leafText(source, leaf), name),
        .list => for (e.items()) |c| {
            if (readsNameIn(source, c, name)) break true;
        } else false,
        else => false,
    };
}

/// The call whose value `e` is: `e` itself, or the call under a `!`,
/// `?`, `catch`, or on the left of `??`.
pub fn resultCall(e: Sexp) ?Sexp {
    const head = e.kind() orelse return null;
    return switch (head) {
        .call => e,
        .propagate => resultCall(ir.Propagate.value(e)),
        .propagate_none => resultCall(ir.PropagateNone.value(e)),
        .@"catch" => resultCall(ir.Catch.value(e)),
        .@"??" => resultCall(ir.@"??".left(e)),
        else => null,
    };
}

/// `a` and `b` are the same parsed node.
pub fn sameNode(a: Sexp, b: Sexp) bool {
    return a == .list and b == .list and a.list.ptr == b.list.ptr;
}

/// Whether `a` and `b` are the same node, a leaf by its place in the
/// source.
pub fn sameSite(a: Sexp, b: Sexp) bool {
    if (a == .src and b == .src) return a.src.pos == b.src.pos and a.src.len == b.src.len;
    return sameNode(a, b);
}

/// `text` with each comment (`#` to the end of its line, outside a
/// string) taken out, for a hint that writes source spanning lines.
pub fn withoutComments(a: std.mem.Allocator, text: []const u8) Error![]const u8 {
    if (std.mem.findScalar(u8, text, '#') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote) |q| {
            if (c == '\\' and q == '"' and i + 1 < text.len) {
                try out.appendSlice(a, text[i .. i + 2]);
                i += 1;
                continue;
            }
            if (c == q) quote = null;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#') {
            while (i < text.len and text[i] != '\n') i += 1;
            while (out.items.len > 0 and isBlank(out.items[out.items.len - 1])) out.items.len -= 1;
            if (i < text.len) try out.append(a, '\n');
            continue;
        }
        try out.append(a, c);
    }
    return out.items;
}

/// `text` on one line: each run of blanks with a line break in it is one
/// space.
pub fn oneLine(a: std.mem.Allocator, text: []const u8) Error![]const u8 {
    if (std.mem.findScalar(u8, text, '\n') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!isBlank(text[i])) {
            try out.append(a, text[i]);
            continue;
        }
        var j = i;
        var broke = false;
        while (j < text.len and isBlank(text[j])) : (j += 1) broke = broke or text[j] == '\n';
        if (broke) {
            const prev = if (out.items.len > 0) out.items[out.items.len - 1] else ' ';
            const next = if (j < text.len) text[j] else ' ';
            if (prev != '(' and prev != '[' and next != ')' and next != ']' and next != '.') try out.append(a, ' ');
        } else try out.appendSlice(a, text[i..j]);
        i = j - 1;
    }
    return out.items;
}

pub fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// The id a node is recorded by.
pub fn nodeId(e: Sexp) parser.NodeId {
    return if (e == .list) e.list.id else 0;
}

/// Whether `view` views a slice, the view it makes (`?t[..]`).
pub fn viewsSlice(view: Sexp) bool {
    const viewed = viewedPlace(view);
    return viewed.isKind(.index) and ir.Index.index(viewed).isKind(.@"..");
}

/// Whether a postfix written after `e` binds to all of it: a name, a
/// field, an element, or a call.
pub fn postfixBinds(e: Sexp) bool {
    return e == .src or e.isKind(.member) or e.isKind(.index) or e.isKind(.call);
}

/// The node within `root` that holds `target` as a child, outside the
/// closures in it.
pub fn parentIn(root: Sexp, target: Sexp) ?Sexp {
    if (root != .list or root.isKind(.lambda)) return null;
    for (root.items()) |c| {
        if (sameExpr(c, target)) return root;
        if (parentIn(c, target)) |p| return p;
    }
    return null;
}

/// Whether member `m` within `root` names the method a call calls, with
/// or without compile-time arguments (`(!w).put[2](3)`).
pub fn isCallee(root: Sexp, m: Sexp) bool {
    if (!m.isKind(.member)) return false;
    var callee = m;
    var p = parentIn(root, m) orelse return false;
    if ((p.isKind(.index) or p.isKind(.inst)) and sameExpr(ir.get(p, .object), m)) {
        callee = p;
        p = parentIn(root, p) orelse return false;
    }
    return p.isKind(.call) and sameExpr(ir.Call.callee(p), callee);
}

/// Whether the code of `src`, its comments aside, holds `word` as a
/// whole name: a name a hint may bind is declared nowhere in the module.
pub fn hasCodeWord(src: []const u8, word: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const code = if (std.mem.findScalar(u8, line, '#')) |h| line[0..h] else line;
        if (hasWord(code, word)) return true;
    }
    return false;
}

/// Whether `text` holds `word` as a whole name.
pub fn hasWord(text: []const u8, word: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findPos(u8, text, i, word)) |at| : (i = at + 1) {
        const before = at == 0 or !(std.ascii.isAlphanumeric(text[at - 1]) or text[at - 1] == '_');
        const end = at + word.len;
        const after = end == text.len or !(std.ascii.isAlphanumeric(text[end]) or text[end] == '_');
        if (before and after) return true;
    }
    return false;
}

/// `a` and `b` are the same parsed expression: a list node, or a leaf at
/// one position.
pub fn sameExpr(a: Sexp, b: Sexp) bool {
    if (a == .src and b == .src) return a.src.pos == b.src.pos;
    return sameNode(a, b);
}

/// Forms whose type comes from the other operand: `.variant`,
/// `.variant(field: value)`, `none`.
pub fn isContextual(source: []const u8, e: Sexp) bool {
    if (e.isKind(.call) and ir.Call.callee(e).isKind(.enum_lit)) return true;
    return e.isKind(.enum_lit) or std.mem.eql(u8, identAt(source, e) orelse "", "none");
}

/// Literal forms allowed as default parameter values: the same text
/// means the same value at every call site, in any module.
pub fn isDefaultLiteral(source: []const u8, e: Sexp) bool {
    return switch (e) {
        .src => isLiteralText(identAt(source, e).?) or std.mem.eql(u8, identAt(source, e).?, "none"),
        .list => e.isKind(.enum_lit) or e.isKind(.symbol) or
            (e.isKind(.neg) and ir.Neg.operand(e) == .src and isLiteralText(identAt(source, ir.Neg.operand(e)).?)),
        else => false,
    };
}

/// The last statement of a block (the block itself when it is empty),
/// or a lone statement.
pub fn lastStmt(body: Sexp) Sexp {
    if (!body.isKind(.block)) return body;
    const stmts = ir.Block.stmts(body);
    return if (stmts.len > 0) stmts[stmts.len - 1] else body;
}

/// An `if` (or `else if` chain) that lacks a final `else`.
pub fn ifWithoutValue(e: Sexp) bool {
    if (!e.isKind(.@"if")) return false;
    const other = ir.If.@"else"(e);
    return other == .nil or ifWithoutValue(other);
}

/// A keyword a duration in seconds might be meant by, for `seconds:`.
pub fn isSecondsName(name: []const u8) bool {
    for ([_][]const u8{ "second", "secs", "sec", "s" }) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The value of a float literal, possibly negated: `2.5`, `-1e3`.
pub fn constFloatOf(source: []const u8, e: Sexp) ?f64 {
    if (e.isKind(.neg)) return -(constFloatOf(source, ir.Neg.operand(e)) orelse return null);
    const t = identAt(source, e) orelse return null;
    if (!sema.isFloatLiteralText(t)) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

/// `if c` with no `else`: a statement, never a value.
pub fn isIfWithoutElse(s: Sexp) bool {
    return s.isKind(.@"if") and ir.If.@"else"(s) == .nil;
}

/// Whether `ty` is `U8`, the byte.
pub fn isU8(ctx: *const SemContext, ty: TypeId) bool {
    return switch (ctx.types.get(ty)) {
        .int => |info| info.bits == 8 and !info.signed,
        else => false,
    };
}

/// An integer literal, possibly negated: `42`, `-1`.
pub fn isIntLiteralNode(source: []const u8, e: Sexp) bool {
    if (e.isKind(.neg)) return isIntLiteralNode(source, ir.Neg.operand(e));
    return e == .src and sema.isIntLiteralText(identAt(source, e) orelse "");
}

pub fn isLiteralText(s: []const u8) bool {
    if (s.len == 0) return false;
    if (sema.isStringLiteralText(s)) return true;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return true;
    return sema.isIntLiteralText(s) or sema.isFloatLiteralText(s);
}

/// The article before a type's name in a diagnostic: "an `Int`",
/// "a `String`".
pub fn article(name: []const u8) []const u8 {
    if (name.len == 0) return "a";
    return switch (name[0]) {
        'A', 'E', 'I', 'O', 'a', 'e', 'i', 'o' => "an",
        else => "a",
    };
}

/// The first `n` parameters.
pub fn paramsMask(n: usize) sema.ParamMask {
    return if (n >= 64) sema.all_params else (@as(sema.ParamMask, 1) << @intCast(n)) - 1;
}

pub fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}
