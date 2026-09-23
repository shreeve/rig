//! Rig language module for the Nexus-generated parser (src/parser.zig).
//!
//! The generated parser has two stages, each wrapped here and auto-wired
//! in by Nexus through `@hasDecl`:
//!
//!   stage   generated (parser.zig)   wrapper (this file)
//!   lex     BaseLexer                Lexer   — layout, keywords, spacing
//!   parse   BaseParser               Parser  — post-parse IR rewrites,
//!                                              diagnostics
//!
//! so `parser.Parser.init(allocator, source).parseProgram()` returns the
//! semantic IR described in docs/IR.md.
//!
//! Also here: the IR `Tag` enum, `BindingKind`, source positions
//! (`lineCol`), and the identifier escaping that emit needs
//! (`writeZigIdent`).

const std = @import("std");
const parser = @import("parser.zig");
const BaseLexer = parser.BaseLexer;
const BaseParser = parser.BaseParser;
const Token = parser.Token;
const TokenCat = parser.TokenCat;
const Sexp = parser.Sexp;

// =============================================================================
// Tag — IR node heads and marker tags
// =============================================================================

pub const Tag = enum(u8) {
    // Declarations
    @"module",
    @"use",
    @"fun",
    @"sub",
    @"lambda",
    @"struct",
    @"enum",
    @"errors",
    @"type",            // type alias: (type Name T)
    @"generic_type",    // (generic_type Name params? members...)
    @"generic_enum",    // (generic_enum Name params members...)
    @"test",
    @"pub",
    @"extern",          // (extern _ name T): extern variable
    @"extern_fun",      // (extern_fun name params? returns?)
    @"extern_sub",      // (extern_sub name params?)
    @"drop_decl",       // (drop_decl (param) block): user-defined drop
    @"zig",             // reserved: rejected by sema
    @"labeled",         // (labeled name stmt)

    // Members and parameters
    @":",               // (: name T)
    @"default",         // (default name T expr)
    @"valued",          // enum member with a value: (valued name expr)
    @"variant",         // payload variant: (variant name params)
    @"pre_param",       // (pre_param name T)

    // Bindings: (set <kind> target type-or-_ expr); see BindingKind.
    @"set",
    @"fixed",
    @"shadow",
    @"+=",
    @"-=",
    @"*=",
    @"/=",
    @"drop",            // (drop name): `-name` statement

    // Control flow
    @"if",              // (if cond then else?): block if, ternary, guard
    @"while",           // (while cond cont-or-_ body else:?)
    @"for",             // (for mode binding index-or-_ source body else?)
    @"iter",            // for modes
    @"ptr",
    @"match",
    @"arm",             // (arm pattern _ body)
    @"range_pattern",
    @"variant_pattern", // .circle(r)
    @"enum_lit",        // .red
    @"return",
    @"break",           // (break value-or-_ label?)
    @"continue",        // (continue label?)
    @"defer",
    @"errdefer",
    @"raw_block",
    @"pre_block",       // reserved: rejected by sema
    @"pre",             // reserved: rejected by sema
    @"try_block",       // reserved: rejected by sema
    @"catch_block",
    @"catch",           // (catch expr name-or-_ handler)
    @"propagate",       // expr!
    @"block",

    // Closures
    @"captures",
    @"cap_copy",        // |x|
    @"cap_clone",       // |+x|
    @"cap_weak",        // |~x|
    @"cap_move",        // |<x|

    // Calls and access
    @"call",
    @"builtin",         // @name(args)
    @"member",
    @"index",
    @"array",
    @"kwarg",

    // Operators
    @"+",
    @"-",
    @"*",
    @"/",
    @"%",
    @"neg",
    @"not",
    @"and",
    @"or",
    @"==",
    @"!=",
    @"<",
    @">",
    @"<=",
    @">=",
    @"&",
    @"|",
    @"^",
    @"<<",
    @">>",
    @"??",
    @"..",

    // Ownership sigils in expression position
    @"move",            // <x
    @"read",            // ?x
    @"write",           // !x
    @"clone",           // +x
    @"share",           // *x
    @"weak",            // ~x (also ~T in type position)
    @"pin",             // @x, reserved
    @"raw",             // %x

    // Types
    @"optional",        // T?
    @"error_union",     // T!
    @"borrow_read",     // ?T
    @"borrow_write",    // !T
    @"shared",          // *T
    @"generic_inst",    // Box(Int)
    @"slice",           // []T
    @"array_type",      // [N]T
    @"fun_type",        // fun(A, B) R

    // Not produced by the grammar; still named by other passes.
    @"packed",
    @"export",
    @"callconv",
    @"opaque",
    @"aligned",
    @"record",
    @"anon_init",
    @"deref",
    @"addr_of",
    @"try",
    @"ternary",
    @"enum_pattern",
    @"**",

    _,
};

// =============================================================================
// BindingKind — the kind slot of (set <kind> ...)
// =============================================================================

/// Exhaustive view of the kind slot, so dispatch sites must handle every
/// kind: `_` → default, `fixed` (`=!`), `shadow` (`new x =`), `move`
/// (`<-`), and the compound assignments.
pub const BindingKind = enum {
    default,
    fixed,
    shadow,
    @"move",
    @"+=",
    @"-=",
    @"*=",
    @"/=",
};

pub const BindingKindError = error{InvalidBindingKind};

/// Decode the kind slot of `(set <kind> ...)`. An unknown kind means the
/// IR is corrupt, so it is an error rather than a silent default.
pub fn bindingKindOf(kind_slot: Sexp) BindingKindError!BindingKind {
    if (kind_slot == .nil) return .default;
    if (kind_slot != .tag) return error.InvalidBindingKind;
    return switch (kind_slot.tag) {
        .fixed => .fixed,
        .shadow => .shadow,
        .@"move" => .@"move",
        .@"+=" => .@"+=",
        .@"-=" => .@"-=",
        .@"*=" => .@"*=",
        .@"/=" => .@"/=",
        else => error.InvalidBindingKind,
    };
}

// =============================================================================
// Source positions and diagnostics
// =============================================================================

pub const LineCol = struct { line: u32, col: u32 };

/// 1-based line and column (in bytes) of `pos` in `source`.
pub fn lineCol(source: []const u8, pos: u32) LineCol {
    const end = @min(pos, source.len);
    var line: u32 = 1;
    var line_start: usize = 0;
    for (source[0..end], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .col = @intCast(end - line_start + 1) };
}

/// A front-end error: a byte position and a message.
pub const Diagnostic = struct {
    pos: u32,
    message: []const u8,
};

// =============================================================================
// Keywords
// =============================================================================

/// Every Rig keyword is reserved, except `new`, which is a keyword only
/// at the start of a statement followed by a name (`new x = ...`), so
/// `fun new(...)` and `Point.new(...)` stay ordinary names.
const keywords = std.StaticStringMap(TokenCat).initComptime(.{
    .{ "and", .@"and" },
    .{ "break", .@"break" },
    .{ "catch", .@"catch" },
    .{ "continue", .@"continue" },
    .{ "defer", .@"defer" },
    .{ "drop", .@"drop" },
    .{ "else", .@"else" },
    .{ "enum", .@"enum" },
    .{ "errdefer", .@"errdefer" },
    .{ "error", .@"error" },
    .{ "extern", .@"extern" },
    .{ "false", .@"false" },
    .{ "for", .@"for" },
    .{ "fun", .@"fun" },
    .{ "if", .@"if" },
    .{ "in", .@"in" },
    .{ "match", .@"match" },
    .{ "new", .@"new" },
    .{ "not", .@"not" },
    .{ "or", .@"or" },
    .{ "pre", .@"pre" },
    .{ "pub", .@"pub" },
    .{ "raw", .@"raw" },
    .{ "return", .@"return" },
    .{ "struct", .@"struct" },
    .{ "sub", .@"sub" },
    .{ "test", .@"test" },
    .{ "true", .@"true" },
    .{ "try", .@"try" },
    .{ "type", .@"type" },
    .{ "use", .@"use" },
    .{ "while", .@"while" },
    .{ "zig", .@"zig" },
});

/// The token category of a reserved word, or null for a plain name.
pub fn keyword(word: []const u8) ?TokenCat {
    return keywords.get(word);
}

pub fn isKeyword(word: []const u8) bool {
    return keywords.has(word);
}

// =============================================================================
// Zig identifiers for emitted code
// =============================================================================

const zig_keywords = std.StaticStringMap(void).initComptime(.{
    .{"addrspace"},   .{"align"},       .{"allowzero"},   .{"and"},
    .{"anyframe"},    .{"anytype"},     .{"asm"},         .{"break"},
    .{"callconv"},    .{"catch"},       .{"comptime"},    .{"const"},
    .{"continue"},    .{"defer"},       .{"else"},        .{"enum"},
    .{"errdefer"},    .{"error"},       .{"export"},      .{"extern"},
    .{"fn"},          .{"for"},         .{"if"},          .{"inline"},
    .{"linksection"}, .{"noalias"},     .{"noinline"},    .{"nosuspend"},
    .{"opaque"},      .{"or"},          .{"orelse"},      .{"packed"},
    .{"pub"},         .{"resume"},      .{"return"},      .{"struct"},
    .{"suspend"},     .{"switch"},      .{"test"},        .{"threadlocal"},
    .{"try"},         .{"union"},       .{"unreachable"}, .{"var"},
    .{"volatile"},    .{"while"},
});

const zig_primitives = std.StaticStringMap(void).initComptime(.{
    .{"anyerror"},       .{"anyopaque"},     .{"bool"},        .{"c_char"},
    .{"c_int"},          .{"c_long"},        .{"c_longdouble"}, .{"c_longlong"},
    .{"c_short"},        .{"c_uint"},        .{"c_ulong"},     .{"c_ulonglong"},
    .{"c_ushort"},       .{"comptime_float"}, .{"comptime_int"}, .{"f128"},
    .{"f16"},            .{"f32"},           .{"f64"},         .{"f80"},
    .{"false"},          .{"isize"},         .{"noreturn"},    .{"null"},
    .{"true"},           .{"type"},          .{"undefined"},   .{"usize"},
    .{"void"},
});

/// Names the emitted prelude declares, and the prefix of emitter
/// temporaries. A Rig name that collides with one of these is renamed.
const emitter_names = std.StaticStringMap(void).initComptime(.{
    .{"std"}, .{"rig"},
});
const emitter_prefix = "__rig";

fn isZigIntType(name: []const u8) bool {
    if (name.len < 2 or (name[0] != 'i' and name[0] != 'u')) return false;
    for (name[1..]) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Write `name` as a Zig identifier that denotes the Rig name and nothing
/// else:
///   * a Zig keyword or primitive (`var`, `fn`, `u8`, `type`) is quoted:
///     `@"var"`;
///   * a name the emitter itself declares (`std`, `rig`, `__rig*`) gets a
///     `'` suffix, which no Rig identifier can contain: `@"rig'"`;
///   * anything else is written as is.
pub fn writeZigIdent(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    if (emitter_names.has(name) or std.mem.startsWith(u8, name, emitter_prefix)) {
        try w.print("@\"{s}'\"", .{name});
    } else if (zig_keywords.has(name) or zig_primitives.has(name) or isZigIntType(name)) {
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
// Spacing
//   A character that touches its operand and not the preceding value is a
//   prefix; otherwise it is infix (or a suffix when it touches the value):
//
//     `a < b`, `a<b` less-than        `<x`, `f <x` move
//     `a * b`         multiply        `*x`, `f *x` share, `*T` shared type
//     `a | b`         bitwise or      `|x| ...`    closure captures
//     `f(x)`, `a[i]`  call, index     `f (x)`, `f [1]`  new operand of f
//     `a.b`           member          `.red`, `f .red`  enum literal
//     `x!`, `T?`      suffix          `!x`, `?x`   write / read borrow
//
//   `-x` at the start of a statement that is nothing but `-name` is a
//   drop; otherwise `-x` is negation.
//
// `if`
//   After `return`/`break`/`continue` or a value, `if` is a postfix guard
//   (`return x if done`), or the inline ternary when an `else` follows on
//   the same logical line (`a if c else b`). Elsewhere it opens a block.

pub const Lexer = struct {
    base: BaseLexer,

    // Indentation: `levels[0..depth]` are the enclosing block columns.
    levels: [max_indent_depth]u32 = undefined,
    depth: u32 = 0,
    column: u32 = 0,
    pending_outdents: u32 = 0,
    pending_newline: bool = false,
    pending_pos: u32 = 0,

    // Open ( and [; newlines inside them are whitespace.
    brackets: [max_nesting]u8 = undefined,
    nesting: u32 = 0,

    /// Category of the last token returned.
    last_cat: TokenCat = .eof,
    /// A newline or `\` continuation was skipped since the last token.
    joined: bool = false,
    /// Position of the `|` that closes the capture list being lexed.
    capture_close: ?u32 = null,

    /// Why the last `.err` token was produced.
    err: LexError = .none,

    pub const max_indent_depth = 64;
    pub const max_nesting = 512;

    pub const LexError = enum {
        none,
        bad_char,
        unterminated_string,
        tab_indent,
        bad_dedent,
        first_line_indented,
        indent_too_deep,
        nesting_too_deep,
        and_operator,
        or_operator,
        power_operator,

        pub fn message(e: LexError) []const u8 {
            return switch (e) {
                .none => "invalid token",
                .bad_char => "invalid character",
                .unterminated_string => "unterminated string",
                .tab_indent => "tab in indentation; indent with spaces",
                .bad_dedent => "indentation does not match any enclosing block",
                .first_line_indented => "unexpected indentation",
                .indent_too_deep => "indentation is nested too deeply",
                .nesting_too_deep => "brackets are nested too deeply",
                .and_operator => "`&&` is not a Rig operator; use `and`",
                .or_operator => "`||` is not a Rig operator; use `or`",
                .power_operator => "`**` is not a Rig operator",
            };
        }
    };

    pub fn init(source: []const u8) Lexer {
        return .{ .base = BaseLexer.init(source) };
    }

    pub fn text(self: *const Lexer, tok: Token) []const u8 {
        return self.base.text(tok);
    }

    pub fn reset(self: *Lexer) void {
        self.* = init(self.base.source);
    }

    pub fn next(self: *Lexer) Token {
        const tok = self.produce();
        self.last_cat = tok.cat;
        if (tok.cat != .newline and tok.cat != .indent and tok.cat != .outdent) self.joined = false;
        return tok;
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

        while (true) {
            const tok = self.base.matchRules();
            switch (tok.cat) {
                .comment => continue,
                .skip => { // `\` line continuation
                    self.joined = true;
                    continue;
                },
                .newline => {
                    if (self.nesting > 0 or self.last_cat == .eof) {
                        self.joined = true;
                        continue;
                    }
                    return self.lineBreak(tok);
                },
                .eof => return self.endOfInput(tok),
                else => {},
            }
            if (self.last_cat == .eof and self.columnOf(tok.pos) > 0) {
                return self.fail(.first_line_indented, tok.pos);
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

    fn columnOf(self: *const Lexer, pos: u32) u32 {
        var i = pos;
        while (i > 0 and self.base.source[i - 1] != '\n') i -= 1;
        return pos - i;
    }

    // -------------------------------------------------------------------------
    // Layout
    // -------------------------------------------------------------------------

    /// A newline outside brackets: find the next line with content and
    /// turn its indentation into NEWLINE, INDENT, or OUTDENTs.
    fn lineBreak(self: *Lexer, nl: Token) Token {
        const src = self.base.source;
        var line: u32 = nl.pos + nl.len;
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
                '\n', '\r' => {
                    line = p + 1;
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
            self.base.pos = line;
            return self.indentTo(p - line, p, nl);
        }
    }

    fn indentTo(self: *Lexer, width: u32, pos: u32, nl: Token) Token {
        if (width > self.column) {
            if (self.depth == max_indent_depth) return self.fail(.indent_too_deep, pos);
            self.levels[self.depth] = self.column;
            self.depth += 1;
            self.column = width;
            return synthetic(.indent, pos);
        }
        if (width == self.column) return nl;

        var closed: u32 = 0;
        while (self.column > width) {
            if (self.depth == 0) return self.fail(.bad_dedent, pos);
            self.depth -= 1;
            self.column = self.levels[self.depth];
            closed += 1;
        }
        if (self.column != width) return self.fail(.bad_dedent, pos);

        self.pending_outdents = closed - 1;
        self.pending_newline = !self.continuesBlock(pos);
        self.pending_pos = pos;
        return synthetic(.outdent, pos);
    }

    /// True when the line at `pos` continues the construct whose block
    /// just closed: `else ...` (but not an `else =>` match arm) or
    /// `catch ...`. No NEWLINE separates the two.
    fn continuesBlock(self: *const Lexer, pos: u32) bool {
        var probe = self.base;
        probe.pos = pos;
        const tok = probe.matchRules();
        if (tok.cat != .ident) return false;
        const word = self.base.text(tok);
        if (std.mem.eql(u8, word, "catch")) return true;
        if (!std.mem.eql(u8, word, "else")) return false;
        return probe.matchRules().cat != .fat_arrow;
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
        var out = tok;
        out.cat = switch (tok.cat) {
            .ident => self.classifyWord(tok),
            .dot => if (self.isEnumLiteralDot(tok)) .dot_lit else .dot,
            .lparen, .lbracket => blk: {
                if (self.nesting == max_nesting) return self.fail(.nesting_too_deep, tok.pos);
                self.brackets[self.nesting] = self.base.source[tok.pos];
                self.nesting += 1;
                if (!self.touchesValue(tok)) break :blk tok.cat;
                break :blk if (tok.cat == .lparen) .lparen_call else .lbracket_index;
            },
            .rparen, .rbracket => blk: {
                if (self.nesting > 0) self.nesting -= 1;
                break :blk tok.cat;
            },
            .minus => self.classifyMinus(tok),
            .lt => if (self.isPrefix(tok)) .move_pfx else .lt,
            .plus => if (self.isPrefix(tok)) .clone_pfx else .plus,
            .percent => if (self.isPrefix(tok)) .raw_pfx else .percent,
            .star => if (self.isPrefix(tok)) .share_pfx else .star,
            .at => if (self.isPrefix(tok) and !self.isBuiltinCall(tok)) .pin_pfx else .at,
            .question => if (self.touchesValue(tok)) .suffix_q else if (self.isPrefix(tok)) .read_pfx else .question,
            .not_sym => if (self.touchesValue(tok)) .suffix_bang else if (self.isPrefix(tok)) .write_pfx else .not_sym,
            .bar => if (self.isCaptureBar(tok)) .bar_capture else .bar,
            .and_sym => return self.fail(.and_operator, tok.pos),
            .or_sym => return self.fail(.or_operator, tok.pos),
            .power => return self.fail(.power_operator, tok.pos),
            .err => return self.fail(self.lexErrorAt(tok), tok.pos),
            else => tok.cat,
        };
        return out;
    }

    fn classifyWord(self: *const Lexer, tok: Token) TokenCat {
        const word = self.base.text(tok);
        if (keyword(word)) |kw| switch (kw) {
            .@"if" => {
                switch (self.last_cat) {
                    .@"return", .@"break", .@"continue" => return .post_if,
                    else => {},
                }
                if (!isValue(self.last_cat)) return .@"if";
                return if (self.elseFollows()) .ternary_if else .post_if;
            },
            .@"new" => return if (self.atStatementStart() and self.nextIsName()) .@"new" else .ident,
            else => return kw,
        };
        if (self.inParens() and self.nextCat() == .colon) return .kwarg_name;
        return .ident;
    }

    /// `-` is infix when spaced after or attached to a value (`a - b`,
    /// `a-b`); otherwise a prefix: a drop when `-name` is a whole
    /// statement, negation otherwise.
    fn classifyMinus(self: *const Lexer, tok: Token) TokenCat {
        if (!self.isPrefix(tok)) return .minus;
        if ((self.atStatementStart() or self.last_cat == .@"defer" or self.last_cat == .@"errdefer") and
            self.isWholeDropStatement())
        {
            return .drop_stmt;
        }
        return .minus_prefix;
    }

    /// After `-` comes a name and then the end of the line, a comment, or
    /// a postfix guard.
    fn isWholeDropStatement(self: *const Lexer) bool {
        var probe = self.base;
        const name = probe.matchRules();
        if (name.cat != .ident or name.pre != 0 or keyword(self.base.text(name)) != null) return false;
        const after = probe.matchRules();
        return switch (after.cat) {
            .newline, .eof, .comment => true,
            .ident => std.mem.eql(u8, self.base.text(after), "if"),
            else => false,
        };
    }

    /// The character touches its operand, and does not touch a preceding
    /// value (`<x`, `f <x`, but not `a<b` or `a < b`).
    fn isPrefix(self: *const Lexer, tok: Token) bool {
        const end = tok.pos + tok.len;
        if (end >= self.base.source.len or !isOperandStart(self.base.source[end])) return false;
        return !isValue(self.last_cat) or self.spacedBefore(tok);
    }

    /// The token touches the value before it (`f(`, `a[`, `T?`, `x!`).
    fn touchesValue(self: *const Lexer, tok: Token) bool {
        return isValue(self.last_cat) and !self.spacedBefore(tok);
    }

    fn spacedBefore(self: *const Lexer, tok: Token) bool {
        return tok.pre > 0 or self.joined;
    }

    /// `.name` starts an enum literal unless it touches a value (member
    /// access). A `.` that begins a continuation line inside brackets is
    /// member access, so method chains can be split across lines.
    fn isEnumLiteralDot(self: *const Lexer, tok: Token) bool {
        const end = tok.pos + tok.len;
        if (end >= self.base.source.len or !isIdentStart(self.base.source[end])) return false;
        if (!isValue(self.last_cat)) return true;
        return tok.pre > 0 and !self.joined;
    }

    /// `@name(` is a builtin call; `@name` alone is the (reserved) pin.
    fn isBuiltinCall(self: *const Lexer, tok: Token) bool {
        var p = tok.pos + tok.len;
        const src = self.base.source;
        while (p < src.len and isIdentCont(src[p])) p += 1;
        return p < src.len and src[p] == '(';
    }

    /// An opening capture bar touches its first capture and is followed by
    /// `[+<~]name (, [+<~]name)*` and a closing bar touching the last
    /// name. The closing bar is recognized by position.
    fn isCaptureBar(self: *Lexer, tok: Token) bool {
        if (self.capture_close) |close| if (close == tok.pos) {
            self.capture_close = null;
            return true;
        };
        if (!self.isPrefix(tok)) return false;
        var probe = self.base;
        while (true) {
            var t = probe.matchRules();
            if (t.cat == .plus or t.cat == .lt or t.cat == .tilde) {
                const name = probe.matchRules();
                if (name.pre != 0) return false;
                t = name;
            }
            if (t.cat != .ident or keyword(self.base.text(t)) != null) return false;
            const sep = probe.matchRules();
            switch (sep.cat) {
                .bar => {
                    if (sep.pre != 0) return false;
                    self.capture_close = sep.pos;
                    return true;
                },
                .comma => {},
                else => return false,
            }
        }
    }

    /// Scan ahead on the current logical line for an `else` at this
    /// nesting level (the ternary form `a if c else b`).
    fn elseFollows(self: *const Lexer) bool {
        var probe = self.base;
        var depth: u32 = 0;
        while (true) {
            const t = probe.matchRules();
            switch (t.cat) {
                .eof => return false,
                .newline => if (depth == 0 and self.nesting == 0) return false,
                .lparen, .lbracket, .lbrace => depth += 1,
                .rparen, .rbracket, .rbrace => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                .comma => if (depth == 0) return false,
                .ident => if (depth == 0 and std.mem.eql(u8, self.base.text(t), "else")) return true,
                else => {},
            }
        }
    }

    fn atStatementStart(self: *const Lexer) bool {
        return switch (self.last_cat) {
            .newline, .indent, .outdent, .eof => true,
            else => false,
        };
    }

    fn inParens(self: *const Lexer) bool {
        return self.nesting > 0 and self.brackets[self.nesting - 1] == '(';
    }

    fn nextCat(self: *const Lexer) TokenCat {
        var probe = self.base;
        return probe.matchRules().cat;
    }

    fn nextIsName(self: *const Lexer) bool {
        var probe = self.base;
        const t = probe.matchRules();
        return t.cat == .ident and keyword(self.base.text(t)) == null;
    }

    fn lexErrorAt(self: *const Lexer, tok: Token) LexError {
        const c = self.base.source[tok.pos];
        return if (c == '"' or c == '\'') .unterminated_string else .bad_char;
    }
};

/// Token categories that end an operand: a following `(` / `[` / `?` /
/// `!` touching one of these is a suffix, not a prefix.
fn isValue(cat: TokenCat) bool {
    return switch (cat) {
        .ident, .integer, .real, .string_sq, .string_dq, .@"true", .@"false",
        .rparen, .rbracket, .suffix_q, .suffix_bang,
        => true,
        else => false,
    };
}

fn isOperandStart(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9') or switch (c) {
        '(', '[', '"', '\'', '.', '<', '?', '!', '+', '-', '*', '~', '@', '%' => true,
        else => false,
    };
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

// =============================================================================
// Parser — post-parse rewrites and diagnostics over the generated BaseParser
// =============================================================================

pub const Parser = struct {
    base: BaseParser,

    pub fn init(alloc: std.mem.Allocator, source: []const u8) Parser {
        return .{ .base = BaseParser.init(alloc, source) };
    }

    pub fn deinit(self: *Parser) void {
        self.base.deinit();
    }

    /// Parse and rewrite into the semantic IR. On `error.ParseError`,
    /// `diagnostic()` describes the failure.
    pub fn parseProgram(self: *Parser) !Sexp {
        const raw = try self.base.parseProgram();
        return self.rewrite(raw);
    }

    /// The error at the token where parsing stopped.
    pub fn diagnostic(self: *Parser) Diagnostic {
        const tok = self.base.current;
        const src = self.base.source;
        const message: []const u8 = switch (tok.cat) {
            .err => self.base.lexer.err.message(),
            .eof => "unexpected end of file",
            .newline => "unexpected end of line",
            .indent => "unexpected indentation",
            .outdent => "unexpected end of block",
            .post_if => "a postfix `if` guard must end a statement; write `a if c else b` for a value",
            .ident => self.format("unexpected name `{s}`", .{src[tok.pos..][0..tok.len]}),
            else => if (keyword(src[tok.pos..][0..tok.len]) != null)
                self.format("unexpected keyword `{s}`", .{src[tok.pos..][0..tok.len]})
            else
                self.format("unexpected `{s}`", .{src[tok.pos..][0..tok.len]}),
        };
        return .{ .pos = tok.pos, .message = message };
    }

    fn format(self: *Parser, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.allocator(), fmt, args) catch "unexpected token";
    }

    fn allocator(self: *Parser) std.mem.Allocator {
        return self.base.arena.allocator();
    }

    // -------------------------------------------------------------------------
    // Rewrites that need to inspect the tree:
    //
    //   * `for` source sigils move into the mode slot:
    //       (for iter x _ (read xs) body)  →  (for read x _ xs body)
    //   * a `-name` statement whose value is used is negation, not a drop:
    //     the last statement of a `fun` body, or of a branch or arm whose
    //     value is used, becomes (neg name).
    // -------------------------------------------------------------------------

    pub fn rewrite(self: *Parser, sexp: Sexp) std.mem.Allocator.Error!Sexp {
        return self.walk(sexp);
    }

    fn walk(self: *Parser, sexp: Sexp) std.mem.Allocator.Error!Sexp {
        const items = switch (sexp) {
            .list => |l| l,
            else => return sexp,
        };
        const out = try self.allocator().alloc(Sexp, items.len);
        for (items, 0..) |child, i| out[i] = try self.walk(child);
        if (out.len == 0 or out[0] != .tag) return .{ .list = out };
        switch (out[0].tag) {
            .@"for" => normFor(out),
            // (fun name params returns body): the body's value is returned.
            .@"fun" => if (out.len >= 5 and out[3] != .nil) valueTail(out[4]),
            // (set kind target type expr): the expression's value is bound.
            .@"set" => if (out.len >= 5) valueTail(out[4]),
            else => {},
        }
        return .{ .list = out };
    }

    /// `sexp` (already walked, so its lists are freshly allocated) is in
    /// value position: a trailing `(drop x)` there is `(neg x)`.
    fn valueTail(sexp: Sexp) void {
        if (sexp != .list or sexp.list.len == 0 or sexp.list[0] != .tag) return;
        const items = @constCast(sexp.list);
        switch (items[0].tag) {
            .@"drop" => items[0] = .{ .tag = .@"neg" },
            .@"block" => if (items.len >= 2) valueTail(items[items.len - 1]),
            .@"if" => if (items.len >= 4) {
                valueTail(items[2]);
                valueTail(items[3]);
            },
            .@"match" => for (items[2..]) |arm| {
                if (arm == .list and arm.list.len >= 4) valueTail(arm.list[3]);
            },
            else => {},
        }
    }

    /// Promote the source's `?xs` / `!xs` / `<xs` wrapper into the mode.
    fn normFor(items: []Sexp) void {
        if (items.len < 6) return;
        if (items[1] != .tag or items[1].tag != .iter) return;
        const source = items[4];
        if (source != .list or source.list.len < 2 or source.list[0] != .tag) return;
        switch (source.list[0].tag) {
            .@"read", .@"write", .@"move" => {
                items[1] = source.list[0];
                items[4] = source.list[1];
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
            std.debug.print("source: {s}\n  at `{s}`\n", .{ source, lx.text(got) });
            return e;
        };
    }
}

test "keywords are reserved; `new` only at statement start" {
    try testing.expectEqual(TokenCat.@"else", keyword("else").?);
    try testing.expect(keyword("fn") == null);
    try testing.expect(keyword("var") == null);
    try expectCats("new x = 1", &.{ .@"new", .ident, .assign, .integer });
    try expectCats("p = Point.new(1)", &.{ .ident, .assign, .ident, .dot, .ident, .lparen_call, .integer, .rparen });
}

test "spacing decides prefix vs infix" {
    try expectCats("a < b", &.{ .ident, .lt, .ident });
    try expectCats("a<b", &.{ .ident, .lt, .ident });
    try expectCats("f <x", &.{ .ident, .move_pfx, .ident });
    try expectCats("a * b", &.{ .ident, .star, .ident });
    try expectCats("x = *b", &.{ .ident, .assign, .share_pfx, .ident });
    try expectCats("a | b | c", &.{ .ident, .bar, .ident, .bar, .ident });
    try expectCats("f = |a, +b| a", &.{ .ident, .assign, .bar_capture, .ident, .comma, .clone_pfx, .ident, .bar_capture, .ident });
    try expectCats("f(x) f (x)", &.{ .ident, .lparen_call, .ident, .rparen, .ident, .lparen, .ident, .rparen });
    try expectCats("a[i] f [1]", &.{ .ident, .lbracket_index, .ident, .rbracket, .ident, .lbracket, .integer, .rbracket });
    try expectCats("a.b f .c", &.{ .ident, .dot, .ident, .ident, .dot_lit, .ident });
    try expectCats("return .red", &.{ .@"return", .dot_lit, .ident });
    try expectCats("T? x!", &.{ .ident, .suffix_q, .ident, .suffix_bang });
}

test "minus: infix, negation, drop" {
    try expectCats("a - b", &.{ .ident, .minus, .ident });
    try expectCats("a -b", &.{ .ident, .minus_prefix, .ident });
    try expectCats("-x", &.{.drop_stmt, .ident});
    try expectCats("-x + 1", &.{ .minus_prefix, .ident, .plus, .integer });
    try expectCats("y = -x", &.{ .ident, .assign, .minus_prefix, .ident });
}

test "if: block, guard, ternary" {
    try expectCats("if c", &.{ .@"if", .ident });
    try expectCats("return if c", &.{ .@"return", .post_if, .ident });
    try expectCats("return x if c", &.{ .@"return", .ident, .post_if, .ident });
    try expectCats("x = a if c else b", &.{ .ident, .assign, .ident, .ternary_if, .ident, .@"else", .ident });
    try expectCats("f(a if c else b)", &.{ .ident, .lparen_call, .ident, .ternary_if, .ident, .@"else", .ident, .rparen });
}

test "layout: indentation, joined lines, tabs" {
    try expectCats("a\n  b\nc", &.{ .ident, .indent, .ident, .outdent, .newline, .ident, .eof });
    try expectCats("f(1,\n  2)\nx", &.{ .ident, .lparen_call, .integer, .comma, .integer, .rparen, .newline, .ident });
    try expectCats("a\n\tb", &.{ .ident, .err });
    try expectCats("a\n    b\n  c", &.{ .ident, .indent, .ident, .err });
}

test "lineCol" {
    try testing.expectEqual(LineCol{ .line = 1, .col = 1 }, lineCol("ab\ncd", 0));
    try testing.expectEqual(LineCol{ .line = 2, .col = 2 }, lineCol("ab\ncd", 4));
}

test "writeZigIdent escapes Zig keywords and emitter names" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeZigIdent(&w, "var");
    try w.writeAll(" ");
    try writeZigIdent(&w, "u8");
    try w.writeAll(" ");
    try writeZigIdent(&w, "rig");
    try w.writeAll(" ");
    try writeZigIdent(&w, "count");
    try testing.expectEqualStrings("@\"var\" @\"u8\" @\"rig'\" count", w.buffered());
}

test "parser: for-source sigil moves into the mode slot" {
    var read_items = [_]Sexp{ .{ .tag = .@"read" }, .{ .str = "xs" } };
    var raw_items = [_]Sexp{
        .{ .tag = .@"for" },  .{ .tag = .iter }, .{ .str = "x" }, .nil,
        .{ .list = &read_items }, .{ .str = "body" },
    };
    var p = Parser.init(testing.allocator, "");
    defer p.deinit();
    const out = try p.rewrite(.{ .list = &raw_items });
    try testing.expectEqual(Tag.@"read", out.list[1].tag);
    try testing.expect(out.list[4] == .str);
}
