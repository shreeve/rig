//! Rig Language Module
//!
//! Provides keyword lookup, semantic Tag enum, and the indentation /
//! sigil-classifying Lexer rewriter for the Rig parser.
//! Imported by the generated parser via `@lang = "rig"`.

const std = @import("std");
const parser = @import("parser.zig");
const BaseLexer = parser.BaseLexer;
const Token = parser.Token;
const TokenCat = parser.TokenCat;

// =============================================================================
// Tag enum — semantic node types for S-expression output
// =============================================================================
//
// Inherited from Zag with renames per SPEC:
//   - `comptime` paths are renamed to `pre`
//   - `=!` Tag renamed `fixed_bind` (was `const_assign` in Zag)
// Added by Rig:
//   - ownership: move, read, write, clone, drop, share, weak, pin, raw
//   - bindings:  fixed_bind, move_assign, shadow
//   - control:   try_block, catch_block, propagate
//   - iteration: for_read, for_write, for_move
//   - meta:      pre, pre_param, pre_block

pub const Tag = enum(u8) {
    // Module structure
    @"module",
    @"use",
    @"enum",
    @"struct",
    @"packed",
    @"labeled",
    @"type",
    @"pub",
    @"extern",
    @"export",
    @"callconv",
    @"extern_var",
    @"extern_const",
    @"opaque",
    @"generic_type",    // type Box(T) ...
    @"volatile_ptr",
    @"many_ptr",
    @"sentinel_ptr",
    @"array_type",
    @"aligned",
    @"errors",
    @"test",
    @"zig",
    @"null",
    @"unreachable",
    @"undefined",
    @"as",
    @"??",
    @"catch",
    @"ternary",
    @"builtin",
    @"error_union",

    // Routines
    @"fun",
    @"sub",
    @"return",

    // Bindings (Rig)
    //
    // The raw parser emits `=` for assignment-or-bind (M2 decides which).
    // Normalize renames it to `set` so the M2 ownership checker sees a
    // neutral form and isn't visually overloaded with the operator literal.
    @"set",             // normalized `=` (set/bind, M2 disambiguates)
    @"set_op",          // normalized compound: (set_op `+=` target expr)
    @"fixed_bind",      // x =! expr     (was Zag `const_assign`)
    @"move_assign",     // x <- expr     (raw; normalized to (set x (move e)))
    @"shadow",          // new x = expr  (explicit shadowing)
    @"typed_assign",    // raw: name : T = expr
    @"typed_fixed",     // raw: name : T =! expr
    @"typed_set",       // normalized typed_assign
    @"=",
    @"+=",
    @"-=",
    @"*=",
    @"/=",

    // Control flow
    @"if",
    @"while",
    // for: (for <mode> binding source body else?)
    //   mode is one of `read`, `write`, `move`, `none`
    // SPEC §"Semantic IR Nodes" specifies the (for mode ...) shape.
    @"for",
    @"for_ptr",         // Zag-inherited pointer iteration, kept separate
                        // because it has an extra binding
    @"match",
    @"arm",
    @"range_pattern",
    @"enum_pattern",
    @"enum_lit",        // .strict (inferred-type enum value)
    @"none",            // generic "no mode" marker (e.g., (for none ...))
    @"break",
    @"continue",
    @"defer",
    @"errdefer",
    @"try",             // prefix: try expr
    @"try_block",       // value-yielding try INDENT body OUTDENT
    @"catch_block",     // catch |err| INDENT body OUTDENT
    @"propagate",       // expr?  (suffix propagation)
    @"inline",
    @"lambda",

    // Calls and access
    @"addr_of",
    @"call",
    @".",               // raw member access from parser
    @"member",          // normalized `.` (cosmetic rename)
    @"deref",
    @"index",
    @"array",
    @"record",
    @"pair",            // raw `name: expr` from parser
    @"kwarg",           // normalized `pair` (cosmetic rename)

    // Operators — arithmetic
    @"+",
    @"-",
    @"*",
    @"/",
    @"%",
    @"**",
    @"neg",
    @"not",

    // Operators — comparison
    @"==",
    @"!=",
    @"<",
    @">",
    @"<=",
    @">=",

    // Operators — logical
    @"||",
    @"&&",

    // Operators — bitwise
    @"&",
    @"|",
    @"^",
    @"<<",
    @">>",

    // Operators — pipe and range
    @"|>",
    @"..",

    // Type annotations and type constructors
    @"typed",
    @"valued",
    @"default",
    @":",
    @"?",               // raw optional type from parser (type position)
    @"optional",        // normalized `?T` (cosmetic rename)
    @"ptr",
    @"const_ptr",
    @"sentinel_slice",
    @"fn_type",
    @"error_merge",
    @"pre_param",       // (Zag: comptime_param)
    @"anon_init",
    @"slice",

    // Rig ownership ops (expression position; from atom rules and rewriter)
    @"move",            // <x
    @"read",            // ?x
    @"write",           // !x
    @"clone",           // +x
    @"drop",            // -x  (statement position)
    @"share",           // *x
    @"weak",            // ~x
    @"pin",             // @x
    @"raw",             // %x

    // Compile-time
    @"pre",             // pre block / pre fun / pre-call (Zag: comptime)
    @"pre_block",       // pre INDENT body OUTDENT

    // Structure
    @"block",

    _,
};

// =============================================================================
// Keyword lookup — maps identifier text to parser symbol IDs
// =============================================================================
//
// Inherited from Zag set, with these Rig deltas:
//   removed: `comptime`  (replaced by `pre`)
//   added:   `pre`, `new`

pub const KeywordId = enum(u16) {
    FUN,
    SUB,
    USE,
    IF,
    ELSE,
    WHILE,
    FOR,
    IN,
    MATCH,
    RETURN,
    BREAK,
    CONTINUE,
    DEFER,
    ERRDEFER,
    TRY,
    FN,
    PUB,
    EXTERN,
    EXPORT,
    INLINE,
    VOLATILE,
    CONST,
    ALIGN,
    CALLCONV,
    ENUM,
    STRUCT,
    PACKED,
    OPAQUE,
    ERROR,
    TYPE,
    TEST,
    PRE,            // Rig: replaces COMPTIME
    NEW,            // Rig: explicit shadowing
    ZIG,
    NULL,
    UNREACHABLE,
    UNDEFINED,
    AS,
    CATCH,
    TRUE,
    FALSE,
    AND,
    OR,
    NOT,
    COMMENT,
    NEWLINE,
    IDENT,
    INTEGER,
    REAL,
    STRING_SQ,
    STRING_DQ,
    INDENT,
    OUTDENT,
};

const keywordMap = std.StaticStringMap(KeywordId).initComptime(.{
    .{ "fun", .FUN },
    .{ "sub", .SUB },
    .{ "use", .USE },
    .{ "if", .IF },
    .{ "else", .ELSE },
    .{ "while", .WHILE },
    .{ "for", .FOR },
    .{ "in", .IN },
    .{ "match", .MATCH },
    .{ "return", .RETURN },
    .{ "break", .BREAK },
    .{ "continue", .CONTINUE },
    .{ "defer", .DEFER },
    .{ "errdefer", .ERRDEFER },
    .{ "try", .TRY },
    .{ "fn", .FN },
    .{ "pub", .PUB },
    .{ "extern", .EXTERN },
    .{ "export", .EXPORT },
    .{ "inline", .INLINE },
    .{ "volatile", .VOLATILE },
    .{ "const", .CONST },
    .{ "align", .ALIGN },
    .{ "callconv", .CALLCONV },
    .{ "enum", .ENUM },
    .{ "struct", .STRUCT },
    .{ "packed", .PACKED },
    .{ "opaque", .OPAQUE },
    .{ "error", .ERROR },
    .{ "type", .TYPE },
    .{ "test", .TEST },
    .{ "pre", .PRE },         // Rig
    .{ "new", .NEW },         // Rig
    .{ "zig", .ZIG },
    .{ "null", .NULL },
    .{ "unreachable", .UNREACHABLE },
    .{ "undefined", .UNDEFINED },
    .{ "as", .AS },
    .{ "catch", .CATCH },
    .{ "true", .TRUE },
    .{ "false", .FALSE },
    .{ "and", .AND },
    .{ "or", .OR },
    .{ "not", .NOT },
});

pub fn keywordAs(name: []const u8) ?KeywordId {
    return keywordMap.get(name);
}

// =============================================================================
// Lexer — indentation + sigil-classifying wrapper around generated BaseLexer
// =============================================================================
//
// Indentation logic copied verbatim from Zag's well-tested implementation.
//
// Rig-specific classifications layered on top:
//
//   <x   tight + expression-start  → move_pfx     (else `lt`)
//   +x   tight + expression-start  → clone_pfx    (else `plus`)
//   %x   tight + expression-start  → raw_pfx      (else `percent`)
//   @x   tight + expression-start  → pin_pfx      (when ident not followed by `(`;
//                                                  builtin call `@name(...)` stays `at`)
//   -x   tight + statement-start   → drop_stmt    (else `minus_prefix` per Zag rule
//                                                  or infix `minus`)
//   x?   tight + value-ender prev  → prop_q       (else `question`)
//
// Ownership prefixes that ALSO need rewriter classification (because
// the bare token is also infix or has a type-rule role that would
// conflict with the atom-rule alternative):
//   ?x   tight + expression context  → read_pfx    (else `question` for postfix unused)
//   !x   tight + expression context  → write_pfx   (else `not_sym`)
//   *x   tight + expression context  → share_pfx   (else `star`; `.*` deref preserved
//                                                   by the `last_cat == .dot` exclusion)
//
// `~x` (weak) needs no rewriter token: `~` has no infix role in Rig V1
// (we drop Zag's bit-not), so the grammar's `unary = "~" unary → (weak 2)`
// is unambiguous.

pub const Lexer = struct {
    base: BaseLexer,

    // Indentation tracking (mirrored from Zag)
    indent_level: u32 = 0,
    indent_stack: [64]u32 = .{0} ** 64,
    indent_depth: u8 = 0,
    indent_pending: u8 = 0,
    indent_queued: ?Token = null,
    indent_trailing_newline: bool = false,

    // Rewriter context
    last_cat: TokenCat = .eof,
    flow_if_active: bool = false,
    bracket_depth: u8 = 0,

    // After classifying an opening `|` as bar_capture, expect the closing
    // `|` (after one ident) to also be bar_capture. Cleared on any other
    // structural token.
    pending_close_bar: bool = false,

    pub fn init(source: []const u8) Lexer {
        return .{ .base = BaseLexer.init(source) };
    }

    pub fn text(self: *const Lexer, tok: Token) []const u8 {
        return self.base.text(tok);
    }

    pub fn reset(self: *Lexer) void {
        self.base.reset();
        self.indent_level = 0;
        self.indent_depth = 0;
        self.indent_pending = 0;
        self.indent_queued = null;
        self.indent_trailing_newline = false;
        self.last_cat = .eof;
        self.flow_if_active = false;
        self.bracket_depth = 0;
        self.pending_close_bar = false;
    }

    pub fn next(self: *Lexer) Token {
        if (self.indent_queued) |q| {
            self.indent_queued = null;
            self.last_cat = q.cat;
            return q;
        }
        if (self.indent_pending > 0) {
            self.indent_pending -= 1;
            if (self.indent_pending == 0 and self.indent_trailing_newline) {
                self.indent_trailing_newline = false;
                self.indent_queued = Token{ .cat = .newline, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
            }
            self.last_cat = .outdent;
            return Token{ .cat = .outdent, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
        }

        while (true) {
            const tok = self.base.matchRules();

            // Skip comment tokens
            if (tok.cat == .comment) continue;

            // Collapse repeated newlines, but still process indent changes on the last one
            if (tok.cat == .newline and (self.last_cat == .newline or self.last_cat == .indent or self.last_cat == .outdent or self.last_cat == .eof)) {
                var ws: u32 = 0;
                while (self.base.pos + ws < self.base.source.len) {
                    const ch = self.base.source[self.base.pos + ws];
                    if (ch == ' ' or ch == '\t') {
                        ws += 1;
                    } else break;
                }
                const dup_at_eof = self.base.pos + ws >= self.base.source.len;
                const dup_next = if (!dup_at_eof) self.base.source[self.base.pos + ws] else 0;
                const dup_is_empty = dup_at_eof or dup_next == '\n' or dup_next == '\r';
                if (dup_is_empty) continue;
                if (dup_next == '#' and ws == self.indent_level) continue;
                if (ws != self.indent_level) {
                    self.flow_if_active = false;
                    const result = self.handleIndent(tok);
                    self.last_cat = result.cat;
                    return result;
                }
                continue;
            }

            if (tok.cat == .newline) {
                self.flow_if_active = false;
                const result = self.handleIndent(tok);
                self.last_cat = result.cat;
                return result;
            }

            if (tok.cat == .eof) {
                self.flow_if_active = false;
                if (self.indent_depth > 0) {
                    self.indent_depth -= 1;
                    if (self.indent_depth > 0) {
                        self.indent_pending = self.indent_depth;
                        self.indent_depth = 0;
                    }
                    self.indent_level = 0;
                    self.indent_trailing_newline = false;
                    self.last_cat = .outdent;
                    return Token{ .cat = .outdent, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
                }
                self.last_cat = .eof;
                return tok;
            }

            // Bracket depth tracking
            if (tok.cat == .lbracket) self.bracket_depth += 1;
            if (tok.cat == .rbracket and self.bracket_depth > 0) self.bracket_depth -= 1;

            // .{ → fuse into dot_lbrace token for anonymous struct init
            if (tok.cat == .dot and self.base.pos < self.base.source.len and
                self.base.source[self.base.pos] == '{')
            {
                var fused = tok;
                fused.cat = .dot_lbrace;
                fused.len = 2;
                self.base.pos += 1;
                self.base.brace += 1;
                self.last_cat = .dot_lbrace;
                return fused;
            }

            // . → dot | dot_lit
            //
            // dot_lit fires when at expression-start (last_cat is not a
            // value-ender) AND the next char starts an ident. This is the
            // enum literal form `.strict`. Member-access `obj.name` stays
            // as `dot` (last_cat is ident → value-ender).
            if (tok.cat == .dot and !isValueCat(self.last_cat) and
                self.base.pos < self.base.source.len and
                isIdentStart(self.base.source[self.base.pos]))
            {
                var dl = tok;
                dl.cat = .dot_lit;
                self.last_cat = .dot_lit;
                return dl;
            }

            // -----------------------------------------------------------------
            // Rig sigil classification (in order of token category)
            // -----------------------------------------------------------------

            // - → minus | minus_prefix | drop_stmt
            if (tok.cat == .minus) {
                var classified = tok;
                classified.cat = self.classifyMinus(tok);
                self.last_cat = classified.cat;
                return classified;
            }

            // < → lt | move_pfx
            if (tok.cat == .lt) {
                if (self.isPrefixSigil(tok)) {
                    var move = tok;
                    move.cat = .move_pfx;
                    self.last_cat = .move_pfx;
                    return move;
                }
            }

            // + → plus | clone_pfx
            if (tok.cat == .plus) {
                if (self.isPrefixSigil(tok)) {
                    var clone = tok;
                    clone.cat = .clone_pfx;
                    self.last_cat = .clone_pfx;
                    return clone;
                }
            }

            // % → percent | raw_pfx
            if (tok.cat == .percent) {
                if (self.isPrefixSigil(tok)) {
                    var raw = tok;
                    raw.cat = .raw_pfx;
                    self.last_cat = .raw_pfx;
                    return raw;
                }
            }

            // @ → at | pin_pfx
            //
            // pin_pfx wins when: looks like a prefix sigil AND the next ident
            // is NOT followed by `(` (which would make it a builtin call).
            if (tok.cat == .at) {
                if (self.isPrefixSigil(tok) and self.atIsPinNotBuiltin()) {
                    var pin = tok;
                    pin.cat = .pin_pfx;
                    self.last_cat = .pin_pfx;
                    return pin;
                }
            }

            // ? → question | prop_q | read_pfx
            //
            //   tight + value-ender preceding   → prop_q     (postfix propagation `expr?`)
            //   isPrefixSigil                   → read_pfx   (`?T`, `?x`, `?user`)
            //   else                            → question
            if (tok.cat == .question) {
                if (tok.pre == 0 and isValueCat(self.last_cat)) {
                    var prop = tok;
                    prop.cat = .prop_q;
                    self.last_cat = .prop_q;
                    return prop;
                }
                if (self.isPrefixSigil(tok)) {
                    var rp = tok;
                    rp.cat = .read_pfx;
                    self.last_cat = .read_pfx;
                    return rp;
                }
            }

            // ! → not_sym | write_pfx
            //
            //   isPrefixSigil  → write_pfx   (`!user`, `!T`)
            //   else           → not_sym
            if (tok.cat == .not_sym) {
                if (self.isPrefixSigil(tok)) {
                    var wp = tok;
                    wp.cat = .write_pfx;
                    self.last_cat = .write_pfx;
                    return wp;
                }
            }

            // * → star | share_pfx
            //
            //   isPrefixSigil  → share_pfx   (`*user`, `*T`; `.*` deref excluded
            //                                  via the `last_cat == .dot` check
            //                                  inside isPrefixSigil)
            //   else           → star
            if (tok.cat == .star) {
                if (self.isPrefixSigil(tok)) {
                    var sp = tok;
                    sp.cat = .share_pfx;
                    self.last_cat = .share_pfx;
                    return sp;
                }
            }

            // | → bar | bar_capture
            //
            // Opening `|` is classified when probe sees `ident |` ahead.
            // After that, `pending_close_bar` is set and the next `|`
            // (after the captured ident) is auto-classified.
            if (tok.cat == .bar) {
                if (self.pending_close_bar) {
                    self.pending_close_bar = false;
                    var cap = tok;
                    cap.cat = .bar_capture;
                    self.last_cat = .bar_capture;
                    return cap;
                }
                if (self.isCapturePipe()) {
                    var cap = tok;
                    cap.cat = .bar_capture;
                    self.last_cat = .bar_capture;
                    self.pending_close_bar = true;
                    return cap;
                }
            }

            // if → if | post_if | ternary_if (Zag classification, kept verbatim)
            if (tok.cat == .ident) {
                const ident_text = self.base.source[tok.pos..][0..tok.len];
                if (std.mem.eql(u8, ident_text, "if") and self.flow_if_active and
                    self.base.paren == 0 and self.base.brace == 0 and self.bracket_depth == 0)
                {
                    var post = tok;
                    post.cat = .post_if;
                    self.flow_if_active = false;
                    self.last_cat = .post_if;
                    return post;
                }
                if (std.mem.eql(u8, ident_text, "if") and !self.flow_if_active and
                    isValueCat(self.last_cat) and self.hasElseOnLine())
                {
                    var ternary = tok;
                    ternary.cat = .ternary_if;
                    self.last_cat = .ternary_if;
                    return ternary;
                }
                if (std.mem.eql(u8, ident_text, "return") or
                    std.mem.eql(u8, ident_text, "break") or
                    std.mem.eql(u8, ident_text, "continue"))
                {
                    self.flow_if_active = true;
                }

                // ident → kwarg_name when inside parens AND immediately followed
                // by `:` (constructor / call kwarg sugar). The grammar's `arg`
                // rule then accepts `KWARG_NAME ":" expr → (pair 1 3)`.
                if (self.base.paren > 0 and self.nextSignificantIsColon()) {
                    var kw = tok;
                    kw.cat = .kwarg_name;
                    self.last_cat = .kwarg_name;
                    return kw;
                }
            }

            self.last_cat = tok.cat;
            return tok;
        }
    }

    // -------------------------------------------------------------------------
    // Sigil classification helpers
    // -------------------------------------------------------------------------

    /// True when this `<sigil>` token should be reclassified as a prefix
    /// operator. Mirrors Zag's `classifyMinus` rule, which handles three
    /// surface forms uniformly:
    ///
    ///   `<x`         (statement start)        prefix
    ///   `f <x`       (Ruby-style arg pos)     prefix          (last_cat value, pre > 0)
    ///   `a < b`      (infix less-than)        NOT prefix      (space after)
    ///   `a<b`        (compact infix)          NOT prefix      (last_cat value, pre == 0)
    ///   `= <x`       (after assign etc.)      prefix          (last_cat NOT value)
    ///
    /// Conditions:
    ///   1. Operand-like char immediately follows (no space after).
    ///   2. Either (a) we're in expression-start context, or
    ///      (b) we're in arg position (value-ender preceded with space).
    fn isPrefixSigil(self: *const Lexer, tok: Token) bool {
        const end = tok.pos + tok.len;
        if (end >= self.base.source.len) return false;
        const c = self.base.source[end];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return false;
        if (!isOperandStart(c)) return false;

        // `.*` is postfix deref, not share/anything. Don't rewrite.
        if (self.last_cat == .dot) return false;

        if (!isValueCat(self.last_cat)) return true;
        if (tok.pre > 0) return true;
        return false;
    }

    /// `@` is pin (not builtin) when followed by ident NOT followed by `(`.
    /// `@name(` is a builtin call; `@name` (no paren) is pin.
    fn atIsPinNotBuiltin(self: *const Lexer) bool {
        var p = self.base.pos;
        // Already past the `@`. Must have an ident-start char.
        if (p >= self.base.source.len) return false;
        const c0 = self.base.source[p];
        if (!isIdentStart(c0)) return false;
        // Skip the ident
        p += 1;
        while (p < self.base.source.len and isIdentCont(self.base.source[p])) : (p += 1) {}
        // If followed by `(` it's a builtin call; otherwise pin
        if (p >= self.base.source.len) return true;
        return self.base.source[p] != '(';
    }

    /// Reclassify `-` per Zag's rule, plus drop_stmt at statement-start.
    fn classifyMinus(self: *const Lexer, tok: Token) TokenCat {
        const end = tok.pos + tok.len;
        const space_after = end >= self.base.source.len or
            self.base.source[end] == ' ' or self.base.source[end] == '\t' or
            self.base.source[end] == '\n' or self.base.source[end] == '\r';

        // Drop statement: `-x` at statement start, tight, ident operand
        if (!space_after and isStmtStart(self.last_cat)) {
            const c = self.base.source[end];
            if (isIdentStart(c)) return .drop_stmt;
        }

        if (space_after) return .minus;
        if (!canEndExpr(self.last_cat) or tok.pre > 0) return .minus_prefix;
        return .minus;
    }

    fn canEndExpr(cat: TokenCat) bool {
        return switch (cat) {
            .ident, .integer, .real, .string_sq, .string_dq,
            .true, .false,
            .rparen, .rbracket, .rbrace,
            .prop_q,
            => true,
            else => false,
        };
    }

    fn isStmtStart(cat: TokenCat) bool {
        return switch (cat) {
            .newline, .indent, .outdent, .eof => true,
            else => false,
        };
    }

    fn isValueCat(cat: TokenCat) bool {
        return switch (cat) {
            .ident, .integer, .real, .string_sq, .string_dq,
            .true, .false,
            .rparen, .rbracket, .rbrace,
            .prop_q,
            => true,
            else => false,
        };
    }

    fn isOperandStart(c: u8) bool {
        return isIdentStart(c) or
            (c >= '0' and c <= '9') or
            c == '(' or c == '[' or c == '{' or
            c == '"' or c == '\'' or
            // sigils chaining is allowed in V1 lexer; the parser/normalizer
            // decides legality (e.g., `<+x` would parse but normalize will
            // typically reject)
            c == '<' or c == '?' or c == '!' or c == '+' or c == '-' or
            c == '*' or c == '~' or c == '@' or c == '%' or c == '.';
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isIdentCont(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }

    // -------------------------------------------------------------------------
    // Indentation handling — copied verbatim from Zag (well-tested)
    // -------------------------------------------------------------------------

    fn handleIndent(self: *Lexer, nl_tok: Token) Token {
        if (self.base.paren > 0 or self.base.brace > 0) return nl_tok;

        var ws: u32 = 0;
        while (self.base.pos + ws < self.base.source.len) {
            const ch = self.base.source[self.base.pos + ws];
            if (ch == ' ' or ch == '\t') {
                ws += 1;
            } else break;
        }
        // Scan past blank lines to find the first content line's indent
        var line_start = self.base.pos;
        while (line_start + ws < self.base.source.len) {
            const ch = self.base.source[line_start + ws];
            if (ch == '\n' or ch == '\r') {
                line_start = line_start + ws + 1;
                ws = 0;
                while (line_start + ws < self.base.source.len) {
                    const wc = self.base.source[line_start + ws];
                    if (wc == ' ' or wc == '\t') {
                        ws += 1;
                    } else break;
                }
                continue;
            }
            break;
        }
        const at_eof = line_start + ws >= self.base.source.len;
        if (!at_eof) {
            const next_ch = self.base.source[line_start + ws];
            if (next_ch == '#' and ws == self.indent_level) {
                return nl_tok;
            }
        }
        var ws_eff = ws;
        if (at_eof) ws_eff = 0;

        if (ws_eff > self.indent_level) {
            if (self.indent_depth >= 63)
                return Token{ .cat = .err, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
            self.indent_stack[self.indent_depth] = self.indent_level;
            self.indent_depth += 1;
            self.indent_level = ws_eff;
            return Token{ .cat = .indent, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
        } else if (ws_eff < self.indent_level) {
            var count: u8 = 0;
            var next_level = self.indent_level;
            while (next_level > ws_eff) {
                if (self.indent_depth == 0)
                    return Token{ .cat = .err, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
                self.indent_depth -= 1;
                next_level = self.indent_stack[self.indent_depth];
                count += 1;
            }
            if (next_level != ws_eff)
                return Token{ .cat = .err, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
            self.indent_level = ws_eff;
            if (count > 0) {
                const needs_newline = !at_eof and !self.nextTokenIsElse();
                if (count > 1) {
                    self.indent_pending = count - 1;
                    self.indent_trailing_newline = needs_newline;
                } else if (needs_newline) {
                    self.indent_queued = Token{ .cat = .newline, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
                }
                return Token{ .cat = .outdent, .pre = 0, .pos = @intCast(self.base.pos), .len = 0 };
            }
            return nl_tok;
        }
        return nl_tok;
    }

    fn nextTokenIsElse(self: *const Lexer) bool {
        var probe = self.base;
        const tok = probe.matchRules();
        if (tok.cat != .ident) return false;
        const ident_text = self.base.source[tok.pos..][0..tok.len];
        // Block-continuation keywords that should NOT be split off the
        // preceding block by an injected newline.
        return std.mem.eql(u8, ident_text, "else") or
            std.mem.eql(u8, ident_text, "catch");
    }

    fn hasElseOnLine(self: *const Lexer) bool {
        var probe = self.base;
        var depth: i32 = 0;
        while (true) {
            const tok = probe.matchRules();
            switch (tok.cat) {
                .newline, .eof => return false,
                .lparen => depth += 1,
                .rparen => depth -= 1,
                .lbracket => depth += 1,
                .rbracket => depth -= 1,
                .lbrace => depth += 1,
                .rbrace => depth -= 1,
                .ident => {
                    if (depth == 0 and tok.len == 4 and
                        std.mem.eql(u8, self.base.source[tok.pos..][0..4], "else"))
                        return true;
                },
                else => {},
            }
        }
    }

    fn isCapturePipe(self: *const Lexer) bool {
        var probe = self.base;
        const tok1 = probe.matchRules();
        if (tok1.cat != .ident) return false;
        const tok2 = probe.matchRules();
        return tok2.cat == .bar;
    }

    /// Probe ahead: is the next significant token a `:` ?
    fn nextSignificantIsColon(self: *const Lexer) bool {
        var probe = self.base;
        const tok = probe.matchRules();
        return tok.cat == .colon;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "keywordAs - core Rig keywords" {
    try std.testing.expectEqual(KeywordId.FUN, keywordAs("fun").?);
    try std.testing.expectEqual(KeywordId.SUB, keywordAs("sub").?);
    try std.testing.expectEqual(KeywordId.PRE, keywordAs("pre").?);
    try std.testing.expectEqual(KeywordId.NEW, keywordAs("new").?);
    try std.testing.expectEqual(KeywordId.IF, keywordAs("if").?);
    try std.testing.expectEqual(KeywordId.CATCH, keywordAs("catch").?);
    try std.testing.expectEqual(KeywordId.TRY, keywordAs("try").?);
    try std.testing.expectEqual(KeywordId.TRUE, keywordAs("true").?);
}

test "keywordAs - comptime is gone (replaced by pre)" {
    try std.testing.expect(keywordAs("comptime") == null);
}

test "keywordAs - inherited from Zag still present" {
    try std.testing.expectEqual(KeywordId.DEFER, keywordAs("defer").?);
    try std.testing.expectEqual(KeywordId.ERRDEFER, keywordAs("errdefer").?);
    try std.testing.expectEqual(KeywordId.EXTERN, keywordAs("extern").?);
    try std.testing.expectEqual(KeywordId.PACKED, keywordAs("packed").?);
    try std.testing.expectEqual(KeywordId.VOLATILE, keywordAs("volatile").?);
    try std.testing.expectEqual(KeywordId.CALLCONV, keywordAs("callconv").?);
    try std.testing.expectEqual(KeywordId.INLINE, keywordAs("inline").?);
    try std.testing.expectEqual(KeywordId.ENUM, keywordAs("enum").?);
    try std.testing.expectEqual(KeywordId.STRUCT, keywordAs("struct").?);
    try std.testing.expectEqual(KeywordId.ERROR, keywordAs("error").?);
    try std.testing.expectEqual(KeywordId.TEST, keywordAs("test").?);
    try std.testing.expectEqual(KeywordId.ZIG, keywordAs("zig").?);
    try std.testing.expectEqual(KeywordId.NULL, keywordAs("null").?);
    try std.testing.expectEqual(KeywordId.UNDEFINED, keywordAs("undefined").?);
    try std.testing.expectEqual(KeywordId.UNREACHABLE, keywordAs("unreachable").?);
}

test "keywordAs - non-keywords" {
    try std.testing.expect(keywordAs("loadUser") == null);
    try std.testing.expect(keywordAs("user") == null);
    try std.testing.expect(keywordAs("packet") == null);
    try std.testing.expect(keywordAs("") == null);
    try std.testing.expect(keywordAs("var") == null);    // intentionally not a keyword
    try std.testing.expect(keywordAs("let") == null);    // intentionally not a keyword
}
