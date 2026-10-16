//! What an editor shows of one Rig file, in byte offsets of its text:
//! the parse errors, the classified tokens (semantic highlighting), the
//! outline of its declarations, and the ranges that fold. `src/lsp.zig`
//! turns these into the language server's positions.
//!
//! Everything here reads the compiler's own stages. The tokens are the
//! lexer wrapper's (`rig.Lexer`), so a contextual word, a layout token, or
//! a postfix `if` has the kind the compiler gives it; the comments, which
//! the wrapper drops, come from the generated lexer under it. The tree is
//! the grammar's own output, read by role through `parser.ir`. It comes
//! from `parseTolerant`, which parses on past a syntax error (rig.grammar,
//! `@repair`), so one error does not hide the rest of the file. The parse
//! errors come from the strict parse `rig check` runs.

const std = @import("std");
const parser = @import("parser.zig");
const rig = @import("rig.zig");
const diag = @import("diag.zig");
const ir = parser.ir;
const Sexp = parser.Sexp;
const TokenCat = parser.TokenCat;

/// The parse errors of `source`, exactly as `rig check` reports them for
/// a module that does not parse (`ModuleGraph.add`): the first error, the
/// ones after it, and the note on a bracket left open. Empty when the
/// source parses. Allocated in `a`, which must outlive the result.
pub fn parseDiagnostics(a: std.mem.Allocator, source: []const u8) ![]const diag.Diagnostic {
    var p = rig.Parser.init(a, source);
    defer p.deinit();
    _ = p.parseProgram() catch |err| switch (err) {
        error.ParseError => {
            var out: std.ArrayList(diag.Diagnostic) = .empty;
            try out.append(a, try own(a, p.diagnostic()));
            for (p.moreDiagnostics()) |d| try out.append(a, try own(a, d));
            if (p.unclosedBracket()) |note| try out.append(a, try own(a, note));
            return out.items;
        },
        error.OutOfMemory => |e| return e,
        // The source is the editor's text, which no limit stops short of a
        // parse; a parse that fails another way has no diagnostic to show.
        else => return &.{},
    };
    return &.{};
}

/// `d` with its message copied out of the parser's memory.
fn own(a: std.mem.Allocator, d: diag.Diagnostic) !diag.Diagnostic {
    var copy = d;
    copy.message = try a.dupe(u8, d.message);
    return copy;
}

/// The most repairs the tolerant parse makes before it stops: past them
/// the outline holds what was parsed up to there.
const repair_budget = 200;

/// The deepest a walk of the tree goes; the strict parse rejects deeper
/// trees (`rig.Parser.max_tree_depth`), so a tolerant one is cut there.
const max_depth = rig.Parser.max_tree_depth;

/// A file parsed for the editor: the tree as far as the tolerant parse
/// could build it, and the parser that holds it.
pub const Parsed = struct {
    p: *rig.Parser,
    /// The top-level declarations: the module's, or, when the parse could
    /// not be completed, the pieces it had built.
    roots: []const Sexp,
    /// The parse completed (possibly with repairs).
    complete: bool,

    pub fn init(a: std.mem.Allocator, source: []const u8) !Parsed {
        const p = try a.create(rig.Parser);
        p.* = rig.Parser.init(a, source);
        const t = p.base.parseTolerant(.program, repair_budget) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return .{ .p = p, .roots = &.{}, .complete = false },
        };
        if (t.complete and t.sexp.isKind(.module)) return .{ .p = p, .roots = ir.Module.decls(t.sexp), .complete = true };
        return .{ .p = p, .roots = t.pieces, .complete = false };
    }

    pub fn deinit(self: *Parsed) void {
        self.p.deinit();
    }

    fn span(self: *const Parsed, node: Sexp) parser.Span {
        return self.p.base.span(node);
    }

    /// A leaf's span; null for one that holds no text of the source (a
    /// repaired hole, or a name a rewrite made).
    fn leafSpan(self: *const Parsed, leaf: Sexp) ?parser.Span {
        if (leaf != .src or leaf.src.len == 0) return null;
        const source = self.p.base.source;
        if (leaf.src.pos >= source.len) return null;
        return .{ .start = leaf.src.pos, .end = @min(rig.leafEnd(source, leaf.src), @as(u32, @intCast(source.len))) };
    }

    /// `s` without the line breaks and spaces after its last token (a
    /// block's span runs to the start of the next line).
    fn trimmed(self: *const Parsed, s: parser.Span) parser.Span {
        const source = self.p.base.source;
        var end = @min(s.end, @as(u32, @intCast(source.len)));
        while (end > s.start and std.ascii.isWhitespace(source[end - 1])) end -= 1;
        return .{ .start = @min(s.start, end), .end = end };
    }

    fn text(self: *const Parsed, s: parser.Span) []const u8 {
        return s.text(self.p.base.source);
    }
};

// =============================================================================
// Tokens
// =============================================================================

/// The kinds of token an editor colours, in the order of the language
/// server's legend, named as the protocol names them. Each matches a scope
/// of rig.grammar's `@highlight`.
pub const Kind = enum(u32) {
    keyword,
    operator,
    string,
    number,
    comment,
    /// The name of a `type`.
    type,
    /// The name of an object (`obj`), which the protocol calls a struct.
    @"struct",
    /// The name of an enum or an error set.
    @"enum",
    enumMember,
    /// A field of an object.
    property,
    function,
    method,
    /// A parameter, a closure's capture, or a keyword argument's name.
    parameter,
    label,
    /// An ownership sigil (`@highlight`'s `storage.modifier`).
    modifier,
    /// A token the lexer rejects (`@highlight`'s `invalid`).
    invalid,
};

/// Modifiers of a token's kind, as bits in the legend's order.
pub const Modifier = enum(u5) {
    /// A keyword of control flow (`@highlight`'s `keyword.control`).
    control,
    /// The name a declaration introduces.
    declaration,
    /// A builtin, `@name`.
    defaultLibrary,

    pub fn bit(m: Modifier) u32 {
        return @as(u32, 1) << @backingInt(m);
    }
};

pub const Token = struct {
    pos: u32,
    end: u32,
    kind: Kind,
    modifiers: u32 = 0,
};

/// The classified tokens of `source`, in source order, none overlapping.
/// A token the editor colours by its own grammar (a plain name,
/// punctuation, `true`) is left out.
pub fn tokens(a: std.mem.Allocator, source: []const u8, parsed: *const Parsed) ![]const Token {
    var by_tree: std.AutoHashMapUnmanaged(u32, Class) = .empty;
    var leaves: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var c: Classifier = .{ .a = a, .parsed = parsed, .by_pos = &by_tree, .leaves = &leaves };
    for (parsed.roots) |root| try c.walk(root, 0);

    var out: std.ArrayList(Token) = .empty;
    var comments = Comments.init(source);
    var lexer = rig.Lexer.init(source);
    // The wrapper makes at most a few tokens per byte (a line's layout
    // tokens among them); a bound keeps it from looping after an error.
    var budget = source.len * 4 + 64;
    var last_end: u32 = 0;
    while (budget > 0) : (budget -= 1) {
        const tok = lexer.next();
        if (tok.cat == .eof) break;
        if (isLayout(tok.cat) or tok.pos < last_end) continue;
        // The wrapper reports a token it rejects with no length; the
        // generated lexer's token there gives its extent.
        const end = if (tok.cat == .err) rejectedEnd(source, tok.pos) else rig.endOf(&lexer.base, tok);
        if (end <= tok.pos) continue;
        while (comments.nextBefore(tok.pos)) |cm| try out.append(a, cm);
        last_end = end;
        const class = by_tree.get(tok.pos) orelse c.failsMarker(tok) orelse
            classOf(tok.cat, tok.pos, source[tok.pos..@min(end, source.len)], parsed, &leaves) orelse continue;
        if (class.need) |want| if (!want.contains(tok.cat)) continue;
        try out.append(a, .{ .pos = tok.pos, .end = end, .kind = class.kind, .modifiers = class.modifiers });
    }
    while (comments.nextBefore(std.math.maxInt(u32))) |cm| try out.append(a, cm);
    return out.items;
}

/// Where the token the generated lexer reads at `pos` ends; `pos` when it
/// reads none there.
fn rejectedEnd(source: []const u8, pos: u32) u32 {
    var probe = parser.BaseLexer.init(source);
    probe.pos = pos;
    const t = probe.next();
    return if (t.pos == pos and t.cat != .eof) rig.endOf(&probe, t) else pos;
}

fn isLayout(cat: TokenCat) bool {
    return switch (cat) {
        .indent, .outdent, .newline => true,
        else => false,
    };
}

/// What a token is coloured as.
const Class = struct {
    kind: Kind,
    modifiers: u32 = 0,
    /// The token categories the tree's class applies to: a sigil the tree
    /// places at a node's first or last byte is coloured only when the
    /// token there is one.
    need: ?Cats = null,
};

const Cats = std.EnumSet(TokenCat);

/// The categories of the sigils: `<` `?` `!` `+` `^` `*` `~`.
const sigil_cats: Cats = .initMany(&.{ .lt, .question, .not_sym, .plus, .caret, .star, .tilde });

/// The class of a token by its category alone (the tree's classes come
/// first). Null for a token left to the editor's grammar.
fn classOf(cat: TokenCat, pos: u32, text: []const u8, parsed: *const Parsed, leaves: *const std.AutoHashMapUnmanaged(u32, void)) ?Class {
    return switch (colourOf(cat)) {
        .class => |c| c,
        .uncoloured => null,
        // A contextual keyword (`unique`, `from`, `static`) the parser read
        // as a keyword holds no leaf of the tree; read as a name, it does.
        .name => if (parsed.complete and parser.ctxAs(text) != null and !leaves.contains(pos)) .{ .kind = .keyword } else null,
    };
}

/// What a token category is coloured as.
const Colour = union(enum) {
    class: Class,
    /// Layout, punctuation, and the literals the editor's grammar colours.
    uncoloured,
    /// A name: the tree says what it names, or that the parser read it as
    /// a contextual keyword.
    name,
};

const control: Class = .{ .kind = .keyword, .modifiers = Modifier.control.bit() };
const keyword: Class = .{ .kind = .keyword };
const operator: Class = .{ .kind = .operator };

/// The colour of every token category the lexer and its wrapper make. The
/// switch names each one, so a new category does not compile until it is
/// given a colour here.
fn colourOf(cat: TokenCat) Colour {
    return switch (cat) {
        .ident => .name,
        .integer, .real => .{ .class = .{ .kind = .number } },
        .string_sq, .string_dq => .{ .class = .{ .kind = .string } },
        .comment => .{ .class = .{ .kind = .comment } },
        .err => .{ .class = .{ .kind = .invalid } },
        .kwarg_name => .{ .class = .{ .kind = .parameter } },
        .true, .false => .uncoloured,
        .@"if", .@"else", .@"while", .@"for", .in, .match, .@"return", .@"break", .@"continue", .pass, .@"defer", .@"errdefer", .@"catch", .@"try", .await, .yield, .post_if, .ternary_if => .{ .class = control },
        .as, .drop, .@"enum", .@"error", .@"extern", .fun, .new, .obj, .rarely, .called, .@"inline", .@"pub", .raw, .sub, .@"test", .type, .use, .zig, .async, .@"const", .impl, .trait, .when, .where, .of => .{ .class = keyword },
        .@"and", .@"or", .not => .{ .class = operator },
        .plus, .minus, .star, .slash, .percent, .plus_wrap, .minus_wrap, .star_wrap, .plus_sat, .minus_sat, .power => .{ .class = operator },
        .eq, .ne, .lt, .gt, .le, .ge, .and_sym, .or_sym, .not_sym, .question, .nullish, .nullish_jump => .{ .class = operator },
        .bar, .ampersand, .caret, .tilde, .lshift, .lshift_wrap, .rshift, .bar_capture, .bar_empty => .{ .class = operator },
        .assign, .fixed_assign, .plus_assign, .minus_assign, .star_assign, .slash_assign, .percent_assign, .amp_assign, .bar_assign, .caret_assign => .{ .class = operator },
        .lshift_assign, .lshift_wrap_assign, .rshift_assign, .plus_wrap_assign, .minus_wrap_assign, .star_wrap_assign, .plus_sat_assign, .minus_sat_assign => .{ .class = operator },
        .arrow, .fat_arrow => .{ .class = operator },
        .at, .lparen, .rparen, .lbracket, .rbracket, .comma, .as_comma, .colon, .dot, .dotdot, .dotdot_open, .step_colon => .uncoloured,
        .label_at => .{ .class = .{ .kind = .label } },
        .indent, .outdent, .newline, .eof, .skip => .uncoloured,
    };
}

/// Classifies the tokens the tree tells apart: declared names, parameters,
/// labels, builtins, and the sigils, which the parser tells from operators
/// by where they stand.
const Classifier = struct {
    a: std.mem.Allocator,
    parsed: *const Parsed,
    by_pos: *std.AutoHashMapUnmanaged(u32, Class),
    leaves: *std.AutoHashMapUnmanaged(u32, void),
    /// The headers of the fallible `sub`s, from the name to the body: the
    /// `!` there is the marker `sub save()!`, which the tree holds as a
    /// tag, without a place.
    fails: std.ArrayList(parser.Span) = .empty,

    /// The class of the `!` that marks a fallible `sub`.
    fn failsMarker(c: *const Classifier, tok: parser.Token) ?Class {
        if (tok.cat != .not_sym) return null;
        for (c.fails.items) |h| if (tok.pos >= h.start and tok.pos < h.end) return .{ .kind = .modifier };
        return null;
    }

    fn put(c: *Classifier, leaf: Sexp, class: Class) !void {
        const s = c.parsed.leafSpan(leaf) orelse return;
        try c.by_pos.put(c.a, s.start, class);
    }

    fn putAt(c: *Classifier, pos: u32, class: Class) !void {
        try c.by_pos.put(c.a, pos, class);
    }

    fn declared(kind: Kind) Class {
        return .{ .kind = kind, .modifiers = Modifier.declaration.bit() };
    }

    fn walk(c: *Classifier, node: Sexp, depth: u32) error{OutOfMemory}!void {
        if (depth >= max_depth) return;
        switch (node) {
            .src => |s| {
                if (s.len > 0) try c.leaves.put(c.a, s.pos, {});
                return;
            },
            .list => {},
            else => return,
        }
        const k = node.kind() orelse {
            for (node.items()) |item| try c.walk(item, depth + 1);
            return;
        };
        const sp = c.parsed.span(node);
        switch (k) {
            .fun, .sub => {
                const method = ir.get(node, .owner) != .nil;
                try c.put(ir.get(node, .name), declared(if (method) .method else .function));
                try c.params(ir.get(node, .params));
                if (k == .sub and ir.get(node, .fails) != .nil) if (c.parsed.leafSpan(ir.get(node, .name))) |name| {
                    const body = ir.get(node, .body);
                    const end = if (body != .nil) c.parsed.span(body).start else sp.end;
                    if (end > name.end) try c.fails.append(c.a, .{ .start = name.end, .end = end });
                };
            },
            .extern_fun, .extern_sub => {
                try c.put(ir.get(node, .name), declared(.function));
                try c.params(ir.get(node, .params));
            },
            .lambda => try c.params(ir.Lambda.params(node)),
            // A capture, `+x`, `<x`, `~x`, `?x`, or `!x`.
            .cap_clone, .cap_move, .cap_weak, .cap_read, .cap_write => {
                try c.put(ir.get(node, .name), declared(.parameter));
                if (!sp.isEmpty()) try c.putAt(sp.start, .{ .kind = .modifier, .need = sigil_cats });
            },
            .@"struct", .generic_struct, .@"enum", .generic_enum, .errors => {
                // The members are walked first, so a method's name is
                // classified as one, not as a function.
                for (rig.children(node)) |child| try c.walk(child, depth + 1);
                const is_struct = k == .@"struct" or k == .generic_struct;
                try c.put(ir.get(node, .name), declared(if (is_struct) .@"struct" else .@"enum"));
                try c.members(node, if (is_struct) .property else .enumMember);
                return;
            },
            .type => try c.put(ir.Type.name(node), declared(.type)),
            // A member's name, which may be a reserved word (`x.type`): a
            // method where it is called, else a field.
            .call => {
                const callee = ir.get(node, .callee);
                if (callee.isKind(.member)) try c.put(ir.get(callee, .name), .{ .kind = .method });
            },
            .member => if (c.parsed.leafSpan(ir.get(node, .name))) |name| {
                const gop = try c.by_pos.getOrPut(c.a, name.start);
                if (!gop.found_existing) gop.value_ptr.* = .{ .kind = .property };
            },
            .enum_lit, .variant_pattern => try c.put(ir.get(node, .name), .{ .kind = .enumMember }),
            .labeled => try c.label(ir.Labeled.label(node)),
            .@"break" => try c.label(ir.get(node, .label)),
            .@"continue" => try c.label(ir.get(node, .label)),
            .builtin => {
                const lib: Class = .{ .kind = .function, .modifiers = Modifier.defaultLibrary.bit() };
                try c.putAt(sp.start, .{ .kind = lib.kind, .modifiers = lib.modifiers, .need = .initOne(.at) });
                try c.put(ir.get(node, .name), lib);
            },
            // Prefix sigils: the node starts at its sigil.
            .move, .read, .write, .clone, .share, .weak, .box, .read_view, .write_view, .shared, .boxed => if (!sp.isEmpty())
                try c.putAt(sp.start, .{ .kind = .modifier, .need = sigil_cats }),
            // Suffix sigils: the node ends at its sigil.
            .propagate, .propagate_none, .optional, .error_union => if (sp.end > sp.start)
                try c.putAt(sp.end - 1, .{ .kind = .modifier, .need = .initMany(&.{ .question, .not_sym }) }),
            else => {},
        }
        for (rig.children(node)) |child| try c.walk(child, depth + 1);
    }

    /// The parameters of a group: a name, `name: T`, `name: T = v`, or
    /// one of these behind a sigil (`?self`).
    fn params(c: *Classifier, group: Sexp) !void {
        for (group.items()) |item| {
            var x = item;
            while (x.kind()) |k| switch (k) {
                .read, .write, .move, .clone, .share, .weak, .box => x = ir.get(x, .operand),
                else => break,
            };
            if (x == .src) {
                try c.put(x, declared(.parameter));
            } else if (x.isKind(.@":") or x.isKind(.default)) {
                try c.put(ir.get(x, .name), declared(.parameter));
            }
        }
    }

    /// The fields or variants, and the methods, of a type's member list.
    fn members(c: *Classifier, node: Sexp, field: Kind) !void {
        for (ir.rest(node, .members)) |member| {
            const m = memberOf(member);
            if (m == .src) {
                try c.put(m, declared(field));
            } else if (m.isKind(.@":") or m.isKind(.default) or m.isKind(.valued) or m.isKind(.variant)) {
                try c.put(ir.get(m, .name), declared(field));
            } else if (m.isKind(.fun) or m.isKind(.sub)) {
                try c.put(ir.get(m, .name), declared(.method));
            }
        }
    }

    /// A label's name; the `@` before it is its own token, `label_at`.
    fn label(c: *Classifier, leaf: Sexp) !void {
        const s = c.parsed.leafSpan(leaf) orelse return;
        try c.putAt(s.start, .{ .kind = .label });
    }
};

/// A member of a type's member list without its `pub` or the sigil that
/// says who may read it (`pub ?len: Int`).
fn memberOf(member: Sexp) Sexp {
    var m = member;
    while (m.kind()) |k| switch (k) {
        .@"pub" => m = ir.Pub.decl(m),
        .read, .write => m = ir.get(m, .operand),
        else => break,
    };
    return m;
}

/// The comments of a source, which the lexer wrapper drops: the generated
/// lexer under it reads them, in order.
const Comments = struct {
    lexer: parser.BaseLexer,
    pending: ?Token = null,
    done: bool = false,

    fn init(source: []const u8) Comments {
        var lexer = parser.BaseLexer.init(source);
        if (std.mem.startsWith(u8, source, bom)) lexer.pos = bom.len;
        return .{ .lexer = lexer };
    }

    /// The next comment if it starts before `pos`.
    fn nextBefore(self: *Comments, pos: u32) ?Token {
        if (self.pending == null and !self.done) self.pending = self.find();
        const t = self.pending orelse return null;
        if (t.pos >= pos) return null;
        self.pending = null;
        return t;
    }

    fn find(self: *Comments) ?Token {
        while (true) {
            const tok = self.lexer.next();
            if (tok.cat == .eof) {
                self.done = true;
                return null;
            }
            if (tok.cat == .comment) return .{ .pos = tok.pos, .end = rig.endOf(&self.lexer, tok), .kind = .comment };
        }
    }
};

// =============================================================================
// Outline
// =============================================================================

/// What a declaration is, as the language server's symbol kinds name it.
pub const SymbolKind = enum(u8) {
    /// An `extern zig` block.
    module = 2,
    method = 6,
    field = 8,
    /// An enum or an error set.
    @"enum" = 10,
    /// A `fun`, a `sub`, or a `test`.
    function = 12,
    /// An `extern` value.
    variable = 13,
    constant = 14,
    enum_member = 22,
    /// An object (`obj`).
    @"struct" = 23,
    /// A `type`.
    type_parameter = 26,
};

pub const Symbol = struct {
    name: []const u8,
    /// The declaring word, or a field's type.
    detail: []const u8,
    kind: SymbolKind,
    /// The whole declaration.
    span: parser.Span,
    /// Its name.
    name_span: parser.Span,
    children: []const Symbol = &.{},
};

/// The outline of a file: its declarations, a type's fields, variants, and
/// methods under it.
pub fn symbols(a: std.mem.Allocator, parsed: *const Parsed) ![]const Symbol {
    var out: std.ArrayList(Symbol) = .empty;
    for (parsed.roots) |root| try declSymbol(a, parsed, root, &out);
    return out.items;
}

fn declSymbol(a: std.mem.Allocator, parsed: *const Parsed, node: Sexp, out: *std.ArrayList(Symbol)) error{OutOfMemory}!void {
    // A `pub` declaration spans its `pub`.
    const whole = parsed.trimmed(parsed.span(node));
    var decl = node;
    while (decl.isKind(.@"pub")) decl = ir.Pub.decl(decl);
    const k = decl.kind() orelse return;
    switch (k) {
        .fun, .sub => {
            const owner = ir.get(decl, .owner);
            const name = ir.get(decl, .name);
            const ns = parsed.leafSpan(name) orelse return;
            // A method declared outside its type's body: `fun Point.norm`.
            const shown = if (owner != .nil) try std.mem.concat(a, u8, &.{ parsed.text(parsed.span(owner)), ".", parsed.text(ns) }) else parsed.text(ns);
            try out.append(a, symbol(whole, ns, shown, @tagName(k), if (owner != .nil) .method else .function));
        },
        .extern_fun, .extern_sub => try named(a, parsed, out, whole, ir.get(decl, .name), "extern", .function),
        .@"extern" => try named(a, parsed, out, whole, ir.get(decl, .name), "extern", .variable),
        .zig_const => try named(a, parsed, out, whole, ir.get(decl, .name), "const", .constant),
        .@"struct", .generic_struct, .@"enum", .generic_enum, .errors => {
            const ns = parsed.leafSpan(ir.get(decl, .name)) orelse return;
            const is_struct = k == .@"struct" or k == .generic_struct;
            var kids: std.ArrayList(Symbol) = .empty;
            for (ir.rest(decl, .members)) |member| try memberSymbol(a, parsed, member, is_struct, &kids);
            var s = symbol(whole, ns, parsed.text(ns), if (is_struct) "obj" else if (k == .errors) "error" else "enum", if (is_struct) .@"struct" else .@"enum");
            s.children = kids.items;
            try out.append(a, s);
        },
        .type => try named(a, parsed, out, whole, ir.Type.name(decl), "type", .type_parameter),
        .@"test" => {
            const ns = parsed.leafSpan(ir.Test.name(decl)) orelse return;
            const raw = parsed.text(ns);
            const name = if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\'')) raw[1 .. raw.len - 1] else raw;
            try out.append(a, symbol(whole, ns, if (name.len == 0) raw else name, "test", .function));
        },
        .set => {
            if (!rig.isModuleConst(node)) return;
            try named(a, parsed, out, whole, ir.Set.target(decl), "const", .constant);
        },
        .zig_extern => {
            const ns = parsed.leafSpan(ir.ZigExtern.file(decl)) orelse return;
            var kids: std.ArrayList(Symbol) = .empty;
            for (ir.ZigExtern.decls(decl)) |d| try declSymbol(a, parsed, d, &kids);
            var s = symbol(whole, ns, parsed.text(ns), "extern zig", .module);
            s.children = kids.items;
            try out.append(a, s);
        },
        else => {},
    }
}

fn memberSymbol(a: std.mem.Allocator, parsed: *const Parsed, member: Sexp, in_struct: bool, out: *std.ArrayList(Symbol)) !void {
    const whole = parsed.trimmed(parsed.span(member));
    const m = memberOf(member);
    if (m == .src) {
        const ns = parsed.leafSpan(m) orelse return;
        return out.append(a, symbol(whole, ns, parsed.text(ns), "", if (in_struct) .field else .enum_member));
    }
    const k = m.kind() orelse return;
    switch (k) {
        .@":", .default => {
            const ns = parsed.leafSpan(ir.get(m, .name)) orelse return;
            try out.append(a, symbol(whole, ns, parsed.text(ns), parsed.text(parsed.span(ir.get(m, .type))), if (in_struct) .field else .enum_member));
        },
        .valued, .variant => {
            const ns = parsed.leafSpan(ir.get(m, .name)) orelse return;
            try out.append(a, symbol(whole, ns, parsed.text(ns), "", .enum_member));
        },
        .fun, .sub => {
            const ns = parsed.leafSpan(ir.get(m, .name)) orelse return;
            try out.append(a, symbol(whole, ns, parsed.text(ns), @tagName(k), .method));
        },
        else => {},
    }
}

fn named(a: std.mem.Allocator, parsed: *const Parsed, out: *std.ArrayList(Symbol), whole: parser.Span, name: Sexp, detail: []const u8, kind: SymbolKind) !void {
    const ns = parsed.leafSpan(name) orelse return;
    try out.append(a, symbol(whole, ns, parsed.text(ns), detail, kind));
}

/// A symbol whose span holds its name, as the protocol requires.
fn symbol(whole: parser.Span, name_span: parser.Span, name: []const u8, detail: []const u8, kind: SymbolKind) Symbol {
    const span: parser.Span = .{ .start = @min(whole.start, name_span.start), .end = @max(whole.end, name_span.end) };
    return .{ .name = name, .detail = detail, .kind = kind, .span = span, .name_span = name_span };
}

// =============================================================================
// Folding
// =============================================================================

pub const Fold = struct {
    /// Where the folded range starts and ends: the last token of a block's
    /// header and the last token of the block, or the first and last
    /// comment of a run of comment lines.
    start: u32,
    end: u32,
    comment: bool,
};

/// The ranges that fold: every indented block (the INDENT and OUTDENT the
/// lexer wrapper makes), and every run of two or more lines that hold only
/// a comment.
pub fn folds(a: std.mem.Allocator, source: []const u8) ![]const Fold {
    var out: std.ArrayList(Fold) = .empty;
    var open: std.ArrayList(u32) = .empty;
    var lexer = rig.Lexer.init(source);
    var budget = source.len * 4 + 64;
    var last: u32 = 0;
    while (budget > 0) : (budget -= 1) {
        const tok = lexer.next();
        switch (tok.cat) {
            .eof => break,
            // The wrapper goes on past a token it rejects, as the
            // tolerant parse does.
            .err => {},
            .indent => try open.append(a, last),
            .outdent => if (open.pop()) |start| try out.append(a, .{ .start = start, .end = last, .comment = false }),
            .newline => {},
            else => if (tok.len > 0) {
                last = tok.pos;
            },
        }
    }
    // Blocks still open at an error or the end close at the last token.
    while (open.pop()) |start| try out.append(a, .{ .start = start, .end = last, .comment = false });

    var comments = Comments.init(source);
    var run: ?Fold = null;
    while (comments.nextBefore(std.math.maxInt(u32))) |cm| {
        if (!aloneOnLine(source, cm.pos)) continue;
        if (run) |*r| {
            if (nextLine(source, r.end) == lineStart(source, cm.pos)) {
                r.end = cm.pos;
                continue;
            }
            if (r.start != r.end) try out.append(a, r.*);
        }
        run = .{ .start = cm.pos, .end = cm.pos, .comment = true };
    }
    if (run) |r| if (r.start != r.end) try out.append(a, r);
    return out.items;
}

/// Whether only spaces and tabs come before `pos` on its line (and, on
/// the first, a byte order mark).
fn aloneOnLine(source: []const u8, pos: u32) bool {
    var i = pos;
    while (i > 0) : (i -= 1) {
        if (i == bom.len and std.mem.startsWith(u8, source, bom)) return true;
        switch (source[i - 1]) {
            ' ', '\t' => {},
            '\n' => return true,
            else => return false,
        }
    }
    return true;
}

const bom = "\xEF\xBB\xBF";

fn lineStart(source: []const u8, pos: u32) u32 {
    var i = pos;
    while (i > 0 and source[i - 1] != '\n') i -= 1;
    return i;
}

/// The start of the line after the one `pos` is on (the end of the source
/// on the last line).
fn nextLine(source: []const u8, pos: u32) u32 {
    var i = pos;
    while (i < source.len and source[i] != '\n') i += 1;
    return @intCast(@min(i + 1, source.len));
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Each classified token of `source` as `text:kind`, with `.modifier`s.
fn renderTokens(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var parsed = try Parsed.init(a, source);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    for (try tokens(a, source, &parsed)) |t| {
        try out.writer.print("{s}:{t}", .{ source[t.pos..t.end], t.kind });
        inline for (@typeInfo(Modifier).@"enum".field_names) |m| {
            if (t.modifiers & @field(Modifier, m).bit() != 0) try out.writer.print(".{s}", .{m});
        }
        try out.writer.writeByte(' ');
    }
    return out.written();
}

test "colourOf: every token category has a colour in the legend, or none" {
    const legend = @typeInfo(Kind).@"enum".field_names.len;
    var coloured: usize = 0;
    inline for (@typeInfo(TokenCat).@"enum".field_names) |name| {
        const cat = @field(TokenCat, name);
        switch (colourOf(cat)) {
            .class => |c| {
                try testing.expect(@backingInt(c.kind) < legend);
                coloured += 1;
            },
            .uncoloured, .name => {},
        }
        // Layout is never coloured, a keyword always is (but `true` and
        // `false`, which the editor's grammar colours as constants).
        switch (cat) {
            .indent, .outdent, .newline, .eof, .skip => try testing.expect(colourOf(cat) == .uncoloured),
            .true, .false => {},
            else => if (rig.isKeyword(cat)) try testing.expect(colourOf(cat) == .class),
        }
    }
    try testing.expect(coloured > 0);
}

test "tokens: sigils, contextual words, and a postfix if, as the compiler reads them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "sub:keyword main:function.declaration ?:modifier q:parameter.declaration " ++
            "new:keyword =:operator <:modifier # moved:comment =:operator <:operator " ++
            "if:keyword.control >:operator 0:number ",
        try renderTokens(arena.allocator(),
            \\sub main(?q: Int)
            \\  new x = <q # moved
            \\  b = x < q
            \\  print(x) if x > 0
            \\
        ),
    );
}

test "tokens: a word is a name where the compiler reads one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `new` names a method, `unique` is a keyword after an obj's name,
    // `obj` and `unique` are names in an expression, and a member may be
    // named by a reserved word.
    try testing.expectEqualStrings(
        "obj:keyword R:struct.declaration unique:keyword n:property.declaration " ++
            "fun:keyword new:method.declaration ->:operator n:parameter 1:number " ++
            "sub:keyword f:function.declaration obj:parameter.declaration unique:parameter.declaration =:operator +:operator " ++
            "=:operator type:property =:operator new:method ",
        try renderTokens(arena.allocator(),
            \\obj R unique
            \\  n: Int
            \\
            \\  fun new() -> R
            \\    R(n: 1)
            \\
            \\sub f(obj: Int, unique: Int)
            \\  x = obj + unique
            \\  t = x.type
            \\  r = R.new()
            \\
        ),
    );
}

test "tokens: labels, builtins, suffix sigils, and a rejected token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try renderTokens(arena.allocator(),
        \\sub f()!
        \\  @outer while true
        \\    break @outer
        \\  n = @sizeOf(Int)
        \\  x = g()?
        \\  y = 1 && 2
        \\
    );
    for ([_][]const u8{ "f:function.declaration !:modifier ", "@:label outer:label ", "while:keyword.control ", "break:keyword.control @:label outer:label ", "@:function.defaultLibrary sizeOf:function.defaultLibrary ", "?:modifier ", "&&:invalid " }) |want| {
        if (std.mem.find(u8, got, want) == null) {
            std.debug.print("missing `{s}` in: {s}\n", .{ want, got });
            return error.TestExpectedEqual;
        }
    }
}

test "symbols: an object with fields and methods, an enum, a method outside its body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\obj Point
        \\  x: Int
        \\  pub y: Int
        \\
        \\  fun norm(?self) -> Int
        \\    self.x
        \\
        \\fun Point.twice(?self) -> Int
        \\  self.x * 2
        \\
        \\enum Color
        \\  red
        \\  green
        \\
        \\limit = 10
        \\
        \\test "adds"
        \\  pass
        \\
    ;
    var parsed = try Parsed.init(a, source);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    try writeSymbols(&out.writer, source, try symbols(a, &parsed), 0);
    try testing.expectEqualStrings(
        \\struct Point [1:1-6:11] obj
        \\  field x [2:3-2:9] Int
        \\  field y [3:3-3:13] Int
        \\  method norm [5:3-6:11] fun
        \\method Point.twice [8:1-9:13] fun
        \\enum Color [11:1-13:8] enum
        \\  enum_member red [12:3-12:6]
        \\  enum_member green [13:3-13:8]
        \\constant limit [15:1-15:11] const
        \\function adds [17:1-18:7] test
        \\
    , out.written());
}

fn writeSymbols(w: *std.Io.Writer, source: []const u8, syms: []const Symbol, depth: usize) !void {
    for (syms) |s| {
        try w.splatByteAll(' ', depth * 2);
        const from = diag.lineCol(source, s.span.start);
        const to = diag.lineCol(source, s.span.end);
        try w.print("{t} {s} [{d}:{d}-{d}:{d}]", .{ s.kind, s.name, from.line, from.col, to.line, to.col });
        if (s.detail.len > 0) try w.print(" {s}", .{s.detail});
        try w.writeByte('\n');
        try writeSymbols(w, source, s.children, depth + 1);
    }
}

test "symbols: the declarations before a syntax error, and after it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\fun one() -> Int
        \\  1 +
        \\
        \\fun two() -> Int
        \\  2
        \\
    ;
    var parsed = try Parsed.init(a, source);
    defer parsed.deinit();
    const syms = try symbols(a, &parsed);
    try testing.expectEqual(@as(usize, 2), syms.len);
    try testing.expectEqualStrings("one", syms[0].name);
    try testing.expectEqualStrings("two", syms[1].name);
}

test "folds: blocks, nested blocks, and comment runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\# one
        \\# two
        \\sub main()
        \\  for i in 0..3
        \\    print(i)
        \\  x = 1 # not alone
        \\  # alone
        \\
    ;
    var out: std.Io.Writer.Allocating = .init(a);
    for (try folds(a, source)) |f| try out.writer.print("{d}-{d}{s} ", .{ diag.lineCol(source, f.start).line, diag.lineCol(source, f.end).line, if (f.comment) "c" else "" });
    try testing.expectEqualStrings("4-5 3-6 1-2c ", out.written());
}
