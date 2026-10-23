const std = @import("std");
const rig = @import("rig/runtime.zig");

const __rig_m3_std_target = @import("__rig_std_target.zig");

const __rig_m4_std_text = @import("__rig_std_text.zig");

pub const TAB: u8 = 0x09;

pub const LF: u8 = 0x0A;

pub const CR: u8 = 0x0D;

pub const SPACE: u8 = 0x20;

pub const QUOTE: u8 = 0x22;

pub const PLUS: u8 = 0x2B;

pub const COMMA: u8 = 0x2C;

pub const MINUS: u8 = 0x2D;

pub const DOT: u8 = 0x2E;

pub const ZERO: u8 = 0x30;

pub const NINE: u8 = 0x39;

pub const COLON: u8 = 0x3A;

pub const LBRACKET: u8 = 0x5B;

pub const BACKSLASH: u8 = 0x5C;

pub const RBRACKET: u8 = 0x5D;

pub const LOWER_E: u8 = 0x65;

pub const LOWER_U: u8 = 0x75;

pub const BACKSLASH_U: u16 = 0x755C;

pub const LBRACE: u8 = 0x7B;

pub const RBRACE: u8 = 0x7D;

pub const MAX_DEPTH: i64 = 1024;

pub const MAX_INPUT: i64 = 0xFFFFFFFF;

pub const MAX_STRING: i64 = 0x7FFFFFF;

pub const SMALL_INT: i64 = 0x7FFFFFFFFFFFFFF;

pub const T_NULL: i64 = 0;

pub const T_FALSE: i64 = 1;

pub const T_TRUE: i64 = 2;

pub const T_INT: i64 = 3;

pub const T_BIG_INT: i64 = 4;

pub const T_FLOAT: i64 = 5;

pub const T_STR: i64 = 6;

pub const T_ESC_STR: i64 = 7;

pub const T_ARRAY: i64 = 8;

pub const T_ARRAY_END: i64 = 9;

pub const T_OBJECT: i64 = 10;

pub const T_OBJECT_END: i64 = 11;

pub const Kind = enum {
    @"null",
    @"bool",
    int,
    float,
    string,
    array,
    array_end,
    object,
    object_end,
    pub const __rig_name = .{ .module = "std.json", .name = .{ "Kind" } };
};

pub const JsonError = error{
    @"std.json.JsonError.bad",
};
pub const JsonError__bad = struct {
    kind: Error,
    at: i64,
};

pub const Error = enum {
    ok,
    empty,
    unexpected,
    eof,
    number,
    range,
    escape,
    surrogate,
    control,
    utf8,
    trailing,
    depth,
    too_large,
    pub const __rig_name = .{ .module = "std.json", .name = .{ "Error" } };
};

pub inline fn error_name(__rig_in_e: Error) []const u8 {
    const e = rig.rt(__rig_in_e);
    return switch (e) {
        .ok => @as([]const u8, "ok"),
        .empty => @as([]const u8, "empty"),
        .unexpected => @as([]const u8, "unexpected"),
        .eof => @as([]const u8, "eof"),
        .number => @as([]const u8, "number"),
        .range => @as([]const u8, "range"),
        .escape => @as([]const u8, "escape"),
        .surrogate => @as([]const u8, "surrogate"),
        .control => @as([]const u8, "control"),
        .utf8 => @as([]const u8, "utf8"),
        .trailing => @as([]const u8, "trailing"),
        .depth => @as([]const u8, "depth"),
        .too_large => @as([]const u8, "too_large"),
    };
}

pub const Doc = struct {
    src: []const u8,
    tape: rig.List(i64),
    text: rig.String,
    floats: rig.List(f64),
    ints: rig.List(i64),
    @"error": Error,
    error_pos: i64,
    pub const __rig_name = .{ .module = "std.json", .name = .{ "Doc" } };

    pub inline fn size(__rig_in_self: *const Doc) i64 {
        const self = rig.rt(__rig_in_self);
        return rig.lenOf(self.tape);
    }

    pub inline fn kind(__rig_in_self: *const Doc, __rig_in_i: i64) Kind {
        const self = rig.rt(__rig_in_self);
        const i = rig.rt(__rig_in_i);
        return switch (self.tape.at(i) & 15) {
            0 => .@"null",
            1, 2 => .@"bool",
            3, 4 => .int,
            5 => .float,
            6, 7 => .string,
            8 => .array,
            9 => .array_end,
            10 => .object,
            else => .object_end,
        };
    }

    pub inline fn get_bool(__rig_in_self: *const Doc, __rig_in_i: i64) bool {
        const self = rig.rt(__rig_in_self);
        const i = rig.rt(__rig_in_i);
        return (self.tape.at(i) & 15) == T_TRUE;
    }

    pub inline fn get_int(__rig_in_self: *const Doc, __rig_in_i: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const i = rig.rt(__rig_in_i);
        const e: i64 = self.tape.at(i);
        if ((e & 15) == T_BIG_INT) {
            return self.ints.at(@as(i64, e) >> @intCast(4));
        }
        return @as(i64, e) >> @intCast(4);
    }

    pub inline fn get_float(__rig_in_self: *const Doc, __rig_in_i: i64) f64 {
        const self = rig.rt(__rig_in_self);
        const i = rig.rt(__rig_in_i);
        return self.floats.at(@as(i64, self.tape.at(i)) >> @intCast(4));
    }

    pub inline fn get_str(__rig_in_self: *const Doc, __rig_in_i: i64) []const u8 {
        const self = rig.rt(__rig_in_self);
        const i = rig.rt(__rig_in_i);
        const e: i64 = self.tape.at(i);
        const at: i64 = @as(i64, e) >> @intCast(31);
        const n: i64 = (@as(i64, e) >> @intCast(4)) & MAX_STRING;
        if ((e & 15) == T_ESC_STR) {
            return rig.slice(self.text.bytes(), at, at + n);
        }
        return rig.slice(self.src, at, at + n);
    }

    pub inline fn next(__rig_in_self: *const Doc, __rig_in_i: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const i = rig.rt(__rig_in_i);
        const e: i64 = self.tape.at(i);
        const tag: i64 = e & 15;
        if ((tag == T_ARRAY) or (tag == T_OBJECT)) {
            return (@as(i64, e) >> @intCast(4)) + 1;
        }
        return rig.addProven(i, 1);
    }

    pub inline fn parse(__rig_in_self: *Doc, __rig_in_src: []const u8) bool {
        const self = rig.rt(__rig_in_self);
        const src = rig.rt(__rig_in_src);
        self.src = src;
        self.tape.clear();
        self.text.clear();
        self.floats.clear();
        self.ints.clear();
        self.@"error" = .ok;
        self.error_pos = 0;
        if (self.document(src) >= 0) {
            return true;
        }
        self.tape.clear();
        self.text.clear();
        self.floats.clear();
        self.ints.clear();
        return false;
    }

    pub inline fn load(__rig_in_self: *Doc, __rig_in_src: []const u8, __out: rig.ErrSlot) JsonError!void {
        _ = &__out;
        const self = rig.rt(__rig_in_self);
        const src = rig.rt(__rig_in_src);
        if (rig.rt(self.parse(src))) {
            return;
        }
        return @errorCast(rig.failWith(__out, error.@"std.json.JsonError.bad", @as(JsonError__bad, .{ .kind = self.@"error", .at = self.error_pos })));
    }

    pub fn document(self: *Doc, src: []const u8) i64 {
        @setEvalBranchQuota(rig.eval_quota);
        const n: i64 = rig.lenOf(src);
        if (n > MAX_INPUT) {
            return rig.rt(self.fail(.too_large, 0));
        }
        var i: i64 = rig.rt(skip_space(src, 0));
        if (i == n) {
            return rig.rt(self.fail(.empty, i));
        }
        var top: i64 = @as(i64, -1);
        var depth: i64 = 0;
        while (true) {
            __rig_body_3: {
                if (i >= n) {
                    return rig.rt(self.fail(.eof, i));
                }
                var c: u8 = rig.at(src, i);
                if ((c == LBRACE) or (c == LBRACKET)) {
                    if (depth >= MAX_DEPTH) {
                        return rig.rt(self.fail(.depth, i));
                    }
                    depth += 1;
                    { const __rig_new_4: i64 = rig.rt(self.open(c, top)); top = __rig_new_4; }
                    { const __rig_new_5: i64 = rig.rt(skip_space(src, rig.addProven(i, 1))); i = __rig_new_5; }
                    if ((i < n) and (rig.atProven(src, i, .upper) == (c + 2))) {
                        { const __rig_new_6: i64 = rig.rt(self.close(top)); top = __rig_new_6; }
                        depth -= 1;
                        i = rig.addProven(i, 1);
                    } else if (c == LBRACE) {
                        { const __rig_new_7: i64 = rig.rt(self.key(src, i)); i = __rig_new_7; }
                        if (i < 0) {
                            return @as(i64, -1);
                        }
                        break :__rig_body_3;
                    } else {
                        break :__rig_body_3;
                    }
                } else {
                    { const __rig_new_8: i64 = self.scalar(src, i, c); i = __rig_new_8; }
                    if (i < 0) {
                        return @as(i64, -1);
                    }
                }
                __rig_while_10: while (true) {
                    {
                        { const __rig_new_12: i64 = rig.rt(skip_space(src, i)); i = __rig_new_12; }
                        if (top < 0) {
                            if (i == n) {
                                return 0;
                            }
                            return rig.rt(self.fail(.trailing, i));
                        }
                        if (i >= n) {
                            return rig.rt(self.fail(.eof, i));
                        }
                        c = rig.at(src, i);
                        const in_object: bool = (top & 1) == 1;
                        if (c == COMMA) {
                            { const __rig_new_13: i64 = rig.rt(skip_space(src, rig.addProven(i, 1))); i = __rig_new_13; }
                            if (in_object) {
                                { const __rig_new_14: i64 = rig.rt(self.key(src, i)); i = __rig_new_14; }
                                if (i < 0) {
                                    return @as(i64, -1);
                                }
                            }
                            break :__rig_while_10;
                        }
                        if (c == @as(u8, if (in_object) RBRACE else RBRACKET)) {
                            { const __rig_new_15: i64 = rig.rt(self.close(top)); top = __rig_new_15; }
                            depth -= 1;
                            i += 1;
                        } else {
                            return rig.rt(self.fail(.unexpected, i));
                        }
                    }
                }
            }
        }
        return @as(i64, -1);
    }

    pub inline fn fail(__rig_in_self: *Doc, __rig_in_e: Error, __rig_in_at: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const e = rig.rt(__rig_in_e);
        const at = rig.rt(__rig_in_at);
        self.@"error" = e;
        self.error_pos = at;
        return @as(i64, -1);
    }

    pub inline fn open(__rig_in_self: *Doc, __rig_in_c: u8, __rig_in_top: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const c = rig.rt(__rig_in_c);
        const top = rig.rt(__rig_in_top);
        const is_object: bool = c == LBRACE;
        const entry: i64 = (rig.lenOf(self.tape) * 2) + @as(i64, if (is_object) 1 else 0);
        self.tape.push((top * 16) + @as(i64, if (is_object) rig.rt(T_OBJECT) else rig.rt(T_ARRAY)));
        return entry;
    }

    pub inline fn close(__rig_in_self: *Doc, __rig_in_top: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const top = rig.rt(__rig_in_top);
        const start: i64 = @as(i64, top) >> @intCast(1);
        const tag: i64 = @as(i64, if ((top & 1) == 1) T_OBJECT else T_ARRAY);
        const outer: i64 = @as(i64, self.tape.at(start)) >> @intCast(4);
        self.tape.slot(start).* = (rig.lenOf(self.tape) * 16) + tag;
        self.tape.push(((start * 16) + tag) + 1);
        return outer;
    }

    pub inline fn key(__rig_in_self: *Doc, __rig_in_src: []const u8, __rig_in_at: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const src = rig.rt(__rig_in_src);
        const at = rig.rt(__rig_in_at);
        if (at >= rig.lenOf(src)) {
            return rig.rt(self.fail(.eof, at));
        }
        if (rig.at(src, at) != QUOTE) {
            return rig.rt(self.fail(.unexpected, at));
        }
        const end: i64 = rig.rt(self.string(src, at));
        if (end < 0) {
            return @as(i64, -1);
        }
        const i: i64 = rig.rt(skip_space(src, end));
        if (i >= rig.lenOf(src)) {
            return rig.rt(self.fail(.eof, i));
        }
        if (rig.at(src, i) != COLON) {
            return rig.rt(self.fail(.unexpected, i));
        }
        return rig.rt(skip_space(src, i + 1));
    }

    pub fn scalar(self: *Doc, src: []const u8, at: i64, c: u8) i64 {
        @setEvalBranchQuota(rig.eval_quota);
        return @as(i64, switch (c) {
            0x22 => rig.rt(self.string(src, at)),
            0x2D, 48...57 => self.number(src, at),
            0x74 => rig.rt(self.literal(src, at, "true", T_TRUE)),
            0x66 => rig.rt(self.literal(src, at, "false", T_FALSE)),
            0x6E => rig.rt(self.literal(src, at, "null", T_NULL)),
            else => rig.rt(self.fail(.unexpected, at)),
        });
    }

    pub inline fn literal(__rig_in_self: *Doc, __rig_in_src: []const u8, __rig_in_at: i64, __rig_in_word: []const u8, __rig_in_tag: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const src = rig.rt(__rig_in_src);
        const at = rig.rt(__rig_in_at);
        const word = rig.rt(__rig_in_word);
        const tag = rig.rt(__rig_in_tag);
        const end: i64 = at + rig.lenOf(word);
        if ((end <= rig.lenOf(src)) and rig.eql(rig.slice(src, at, end), word)) {
            self.tape.push(tag);
            return end;
        }
        for (word, 0..) |b, __rig_i_19| {
            const k: i64 = @as(i64, @bitCast(@as(u64, __rig_i_19)));
            if ((at + k) >= rig.lenOf(src)) {
                return rig.rt(self.fail(.eof, at + k));
            }
            if (rig.at(src, at + k) != b) {
                return rig.rt(self.fail(.unexpected, at + k));
            }
        }
        return @as(i64, -1);
    }

    pub inline fn string(__rig_in_self: *Doc, __rig_in_src: []const u8, __rig_in_at: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const src = rig.rt(__rig_in_src);
        const at = rig.rt(__rig_in_at);
        const start: i64 = at + 1;
        const i: i64 = skip_plain_ascii(src, start);
        if (((i >= 0) and (i < rig.lenOf(src))) and (rig.atProven(src, i, .both) == QUOTE)) {
            if (rig.rt(self.add_string(T_STR, start, i - start, at)) < 0) {
                return @as(i64, -1);
            }
            return rig.addProven(i, 1);
        }
        return rig.rt(self.string_rest(src, start, at, i));
    }

    pub inline fn string_rest(__rig_in_self: *Doc, __rig_in_src: []const u8, __rig_in_start: i64, __rig_in_at: i64, __rig_in_from: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const src = rig.rt(__rig_in_src);
        const start = rig.rt(__rig_in_start);
        const at = rig.rt(__rig_in_at);
        const from = rig.rt(__rig_in_from);
        var i: i64 = from;
        if ((i < rig.lenOf(src)) and (rig.atProven(src, i, .upper) >= 0x80)) {
            { const __rig_new_20: i64 = self.utf8_text(src, i); i = __rig_new_20; }
            if (i < 0) {
                return @as(i64, -1);
            }
        }
        if (i >= rig.lenOf(src)) {
            return rig.rt(self.fail(.eof, i));
        }
        const c: u8 = rig.at(src, i);
        if (c == QUOTE) {
            if (rig.rt(self.add_string(T_STR, start, i - start, at)) < 0) {
                return @as(i64, -1);
            }
            return rig.addProven(i, 1);
        }
        if (c == BACKSLASH) {
            return self.escaped(src, start, i);
        }
        return rig.rt(self.fail(.control, i));
    }

    pub inline fn add_string(__rig_in_self: *Doc, __rig_in_tag: i64, __rig_in_offset: i64, __rig_in_n: i64, __rig_in_at: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const tag = rig.rt(__rig_in_tag);
        const offset = rig.rt(__rig_in_offset);
        const n = rig.rt(__rig_in_n);
        const at = rig.rt(__rig_in_at);
        if (n > MAX_STRING) {
            return rig.rt(self.fail(.too_large, at));
        }
        self.tape.push(((@shlExact(@as(i64, offset), @intCast(27)) + n) * 16) + tag);
        return 0;
    }

    pub inline fn plain(__rig_in_self: *Doc, __rig_in_src: []const u8, __rig_in_at: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const src = rig.rt(__rig_in_src);
        const at = rig.rt(__rig_in_at);
        const i: i64 = skip_plain_ascii(src, at);
        if ((i >= rig.lenOf(src)) or (rig.at(src, i) < 0x80)) {
            return i;
        }
        return self.utf8_text(src, i);
    }

    pub fn utf8_text(self: *Doc, src: []const u8, at: i64) i64 {
        @setEvalBranchQuota(rig.eval_quota);
        const n: i64 = rig.lenOf(src);
        var prev = rig.rt(@as(@Vector(16, u8), @splat(0)));
        var errors = rig.rt(@as(@Vector(16, u8), @splat(0)));
        var i: i64 = at;
        __rig_while_22: while (true) : ({ i = rig.addProven(i, 16); }) {
            if (!((i + 16) <= n)) break;
            {
                const cur = rig.simdReadProven(@Vector(16, u8), src, i, rig.Endian.little, .upper);
                const stops = rig.maskOr(rig.maskOr(rig.mask(cur == rig.rt(@as(@Vector(16, u8), @splat(QUOTE)))), rig.mask(cur == rig.rt(@as(@Vector(16, u8), @splat(BACKSLASH))))), rig.mask(cur < rig.rt(@as(@Vector(16, u8), @splat(SPACE)))));
                if (rig.maskFirst(stops)) |k| {
                    { const __rig_new_25: @Vector(16, u8) = rig.rt(utf8_errors(cur, prev)); errors |= __rig_new_25; }
                    if (rig.maskAll(rig.mask(errors == rig.rt(@as(@Vector(16, u8), @splat(0)))))) {
                        return i + k;
                    }
                    break :__rig_while_22;
                }
                { const __rig_new_26: @Vector(16, u8) = rig.rt(utf8_errors(cur, prev)); errors |= __rig_new_26; }
                prev = cur;
            }
        }
        var start: i64 = at;
        if ((i > at) and rig.maskAll(rig.mask(errors == rig.rt(@as(@Vector(16, u8), @splat(0)))))) {
            start = i;
            {
                var __rig_i_30: i64 = 1;
                const __rig_end_30: i64 = 4;
                __rig_for_28: while (__rig_i_30 < __rig_end_30) : (__rig_i_30 += 1) {
                    const k = __rig_i_30;
                    if (rig.at(src, i - k) >= 0xC0) {
                        start = i - k;
                        break :__rig_for_28;
                    }
                }
            }
        }
        i = start;
        while (true) {
            {
                while (true) {
                    if (!((i < n) and (rig.atProven(src, i, .upper) >= 0x80))) break;
                    {
                        const j: i64 = rig.rt(utf8_end3(src, i));
                        if (j < 0) {
                            return rig.rt(self.fail(.utf8, i));
                        }
                        i = j;
                    }
                }
                { const __rig_new_37: i64 = skip_plain_ascii(src, i); i = __rig_new_37; }
                if ((i >= n) or (rig.at(src, i) < 0x80)) {
                    return i;
                }
            }
        }
        return n;
    }

    pub fn escaped(self: *Doc, src: []const u8, start: i64, at: i64) i64 {
        @setEvalBranchQuota(rig.eval_quota);
        const offset: i64 = self.text.length();
        self.text.add(.{ rig.slice(src, start, at) });
        var i: i64 = at;
        while (true) {
            __rig_body_40: {
                const c: u8 = rig.at(src, i);
                if (c == QUOTE) {
                    if (rig.rt(self.add_string(T_ESC_STR, offset, self.text.length() - offset, start - 1)) < 0) {
                        return @as(i64, -1);
                    }
                    return rig.addProven(i, 1);
                }
                if (c != BACKSLASH) {
                    return rig.rt(self.fail(.control, i));
                }
                { const __rig_new_41: i64 = rig.rt(self.escape(src, i)); i = __rig_new_41; }
                if (i < 0) {
                    return @as(i64, -1);
                }
                if ((i < rig.lenOf(src)) and (rig.atProven(src, i, .upper) == BACKSLASH)) {
                    break :__rig_body_40;
                }
                { const __rig_new_42: i64 = rig.rt(self.copy_plain(src, i)); i = __rig_new_42; }
                if ((i < rig.lenOf(src)) and (((rig.atProven(src, i, .upper) == QUOTE) or (rig.atProven(src, i, .upper) == BACKSLASH)) or (rig.atProven(src, i, .upper) < SPACE))) {
                    break :__rig_body_40;
                }
                const j: i64 = rig.rt(self.plain(src, i));
                if (j < 0) {
                    return @as(i64, -1);
                }
                if (j >= rig.lenOf(src)) {
                    return rig.rt(self.fail(.eof, j));
                }
                self.text.add(.{ rig.slice(src, i, j) });
                i = j;
            }
        }
        return @as(i64, -1);
    }

    pub inline fn copy_plain(__rig_in_self: *Doc, __rig_in_src: []const u8, __rig_in_at: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const src = rig.rt(__rig_in_src);
        const at = rig.rt(__rig_in_at);
        var i: i64 = at;
        while (true) : ({ i = rig.addProven(i, 16); }) {
            if (!((i + 16) <= rig.lenOf(src))) break;
            {
                const block = rig.simdReadProven(@Vector(16, u8), src, i, rig.Endian.little, .upper);
                if (rig.maskFirst(rig.rt(special(block)))) |k| {
                    self.text.pushKeep(@Vector(16, u8), block, k, rig.Endian.little);
                    return i + k;
                }
                self.text.pushKeep(@Vector(16, u8), block, 16, rig.Endian.little);
            }
        }
        return i;
    }

    pub inline fn escape(__rig_in_self: *Doc, __rig_in_src: []const u8, __rig_in_at: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const src = rig.rt(__rig_in_src);
        const at = rig.rt(__rig_in_at);
        if ((at + 1) >= rig.lenOf(src)) {
            return rig.rt(self.fail(.eof, at + 1));
        }
        const e: u8 = rig.at(src, at + 1);
        if (e == LOWER_U) {
            return self.unicode(src, at);
        }
        const out: u8 = ESCAPES[rig.index(e, 256)];
        if (out == 0) {
            return rig.rt(self.fail(.escape, rig.addProven(at, 1)));
        }
        self.text.push(out);
        return rig.addProven(at, 2);
    }

    pub fn unicode(self: *Doc, src: []const u8, at: i64) i64 {
        @setEvalBranchQuota(rig.eval_quota);
        var c: i64 = rig.rt(self.hex4(src, at + 2));
        if (c < 0) {
            return @as(i64, -1);
        }
        var i: i64 = at + 6;
        if ((((c >= 0x800) and ((c < 0xD800) or (c > 0xDFFF))) and ((i + 6) <= rig.lenOf(src))) and (rig.readIntProven(u16, src, i, .little, .upper) == BACKSLASH_U)) {
            const d: i64 = rig.rt(hex_value(src, rig.addProven(i, 2)));
            if ((d >= 0x800) and ((d < 0xD800) or (d > 0xDFFF))) {
                rig.rt(push_utf8_two3(&self.text, c, d));
                return rig.addProven(i, 6);
            }
        }
        if ((c >= 0xDC00) and (c <= 0xDFFF)) {
            return rig.rt(self.fail(.surrogate, at));
        }
        if ((c >= 0xD800) and (c <= 0xDBFF)) {
            if ((((i + 1) >= rig.lenOf(src)) or (rig.at(src, i) != BACKSLASH)) or (rig.at(src, i + 1) != LOWER_U)) {
                return rig.rt(self.fail(.surrogate, at));
            }
            const low: i64 = rig.rt(self.hex4(src, i + 2));
            if (low < 0) {
                return @as(i64, -1);
            }
            if ((low < 0xDC00) or (low > 0xDFFF)) {
                return rig.rt(self.fail(.surrogate, at));
            }
            c = (0x10000 + @shlExact(@as(i64, c - 0xD800), @intCast(10))) + (low - 0xDC00);
            i += 6;
        }
        push_utf8(&self.text, c);
        return i;
    }

    pub inline fn hex4(__rig_in_self: *Doc, __rig_in_src: []const u8, __rig_in_at: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const src = rig.rt(__rig_in_src);
        const at = rig.rt(__rig_in_at);
        const v: i64 = rig.rt(hex_value(src, at));
        if (v >= 0) {
            return v;
        }
        return rig.rt(self.hex_error(src, at));
    }

    pub inline fn hex_error(__rig_in_self: *Doc, __rig_in_src: []const u8, __rig_in_at: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const src = rig.rt(__rig_in_src);
        const at = rig.rt(__rig_in_at);
        {
            var __rig_i_50: i64 = 0;
            const __rig_end_50: i64 = 4;
            while (__rig_i_50 < __rig_end_50) : (__rig_i_50 += 1) {
                const k = __rig_i_50;
                const i: i64 = at + k;
                if (i >= rig.lenOf(src)) {
                    return rig.rt(self.fail(.eof, i));
                }
                if (HEX[rig.index(rig.at(src, i), 256)] < 0) {
                    return rig.rt(self.fail(.escape, i));
                }
            }
        }
        return @as(i64, -1);
    }

    pub fn number(self: *Doc, src: []const u8, at: i64) i64 {
        @setEvalBranchQuota(rig.eval_quota);
        const n: i64 = rig.lenOf(src);
        var i: i64 = at;
        const negative: bool = rig.rt(peek(src, i)) == MINUS;
        if (negative) {
            i += 1;
        }
        const first: i64 = i;
        var m: u64 = 0; _ = &m;
        { const __rig_new_51: i64 = rig.rt(take_digits(src, i, &m)); i = __rig_new_51; }
        const int_digits: i64 = i - first;
        if (int_digits == 0) {
            return rig.rt(self.fail(.number, i));
        }
        if ((int_digits > 1) and (rig.rt(peek(src, first)) == ZERO)) {
            return rig.rt(self.fail(.number, first + 1));
        }
        var frac_digits: i64 = 0;
        var is_float: bool = false;
        if (rig.rt(peek(src, i)) == DOT) {
            is_float = true;
            i += 1;
            const dot: i64 = i;
            { const __rig_new_52: i64 = rig.rt(take_digits(src, i, &m)); i = __rig_new_52; }
            frac_digits = i - dot;
            if (frac_digits == 0) {
                return rig.rt(self.fail(.number, i));
            }
        }
        var exp: i64 = 0;
        if ((rig.rt(peek(src, i)) | 0x20) == LOWER_E) {
            is_float = true;
            i += 1;
            const exp_negative: bool = (i < n) and (rig.at(src, i) == MINUS);
            if ((i < n) and ((rig.atProven(src, i, .upper) == MINUS) or (rig.atProven(src, i, .upper) == PLUS))) {
                i = rig.addProven(i, 1);
            }
            const exp_first: i64 = i;
            const __rig_ok_53 = rig.okBelow(n, 0, src.len) and rig.okNonneg(i); _ = &__rig_ok_53; while (true) {
                if (!((i < n) and rig.rt(is_digit(rig.atIf(src, i, .upper, .lower, __rig_ok_53))))) break;
                {
                    if (exp < 100000) {
                        { const __rig_new_57: i64 = (exp * 10) + @as(i64, @intCast(@as(u8, rig.atIf(src, i, .upper, .lower, __rig_ok_53) - rig.rt(ZERO)))); exp = __rig_new_57; }
                    }
                    i = rig.addProven(i, 1);
                }
            }
            if (i == exp_first) {
                return rig.rt(self.fail(.number, i));
            }
            if (exp_negative) {
                exp = -exp;
            }
        }
        const digits: i64 = int_digits + frac_digits;
        if (!is_float and (digits <= 19)) {
            if (negative and (m == 0)) {
                rig.rt(self.add_float(-@as(f64, 0.0)));
                return i;
            }
            if (m <= 0x7FFFFFFFFFFFFFFF) {
                const v: i64 = @as(i64, @intCast(@as(u64, m)));
                rig.rt(self.add_int(@as(i64, if (negative) -v else v)));
                return i;
            }
            if (negative and (m == 0x8000000000000000)) {
                rig.rt(self.add_int(@as(i64, -9223372036854775808)));
                return i;
            }
        }
        var v: f64 = @as(f64, 0.0);
        if (digits <= 19) {
            { const __rig_new_58: f64 = (rig.rt(decimal_to_float(m, exp - frac_digits, digits)) orelse rig.rt(slow_float(rig.slice(src, at, i)))); v = __rig_new_58; }
            if (negative) {
                v = -v;
            }
        } else {
            { const __rig_new_59: f64 = rig.rt(slow_float(rig.slice(src, at, i))); v = __rig_new_59; }
        }
        if ((v > @as(f64, std.math.floatMax(f64))) or (v < @as(f64, -std.math.floatMax(f64)))) {
            return rig.rt(self.fail(.range, at));
        }
        rig.rt(self.add_float(v));
        return i;
    }

    pub inline fn add_float(__rig_in_self: *Doc, __rig_in_v: f64) void {
        const self = rig.rt(__rig_in_self);
        const v = rig.rt(__rig_in_v);
        self.tape.push((rig.lenOf(self.floats) * 16) + rig.rt(T_FLOAT));
        self.floats.push(v);
    }

    pub inline fn add_int(__rig_in_self: *Doc, __rig_in_v: i64) void {
        const self = rig.rt(__rig_in_self);
        const v = rig.rt(__rig_in_v);
        if ((v >= @as(i64, -576460752303423487)) and (v <= SMALL_INT)) {
            self.tape.push((v * 16) + rig.rt(T_INT));
        } else {
            self.tape.push((rig.lenOf(self.ints) * 16) + rig.rt(T_BIG_INT));
            self.ints.push(v);
        }
    }
};

pub inline fn new_doc() Doc {
    return Doc{ .src = "", .tape = rig.List(i64).empty, .text = rig.String.of(.{}), .floats = rig.List(f64).empty, .ints = rig.List(i64).empty, .@"error" = .ok, .error_pos = 0 };
}

pub inline fn peek(__rig_in_s: []const u8, __rig_in_i: i64) u8 {
    const s = rig.rt(__rig_in_s);
    const i = rig.rt(__rig_in_i);
    if ((i < 0) or (i >= rig.lenOf(s))) {
        return 0;
    }
    return rig.at(s, i);
}

pub inline fn is_digit(__rig_in_c: u8) bool {
    const c = rig.rt(__rig_in_c);
    return (c >= ZERO) and (c <= NINE);
}

pub inline fn hex_value(__rig_in_s: []const u8, __rig_in_at: i64) i64 {
    const s = rig.rt(__rig_in_s);
    const at = rig.rt(__rig_in_at);
    if ((at < 0) or ((at + 4) > rig.lenOf(s))) {
        return @as(i64, -1);
    }
    const w: u32 = rig.readInt(u32, s, at, .big);
    return (((@as(i64, HEX[rig.index(@as(u32, w) >> @intCast(24), 256)]) << @intCast(12)) | (@as(i64, HEX[rig.index((@as(u32, w) >> @intCast(16)) & 0xFF, 256)]) << @intCast(8))) | (@as(i64, HEX[rig.index((@as(u32, w) >> @intCast(8)) & 0xFF, 256)]) << @intCast(4))) | HEX[rig.index(w & 0xFF, 256)];
}

pub const HEX: [256]i64 = [_]i64{ @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), 10, 11, 12, 13, 14, 15, @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), 10, 11, 12, 13, 14, 15, @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1), @as(i64, -1) };

pub const ESCAPES: [256]u8 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x2F, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x5C, 0, 0, 0, 0, 0, 0x08, 0, 0, 0, 0x0C, 0, 0, 0, 0, 0, 0, 0, 0x0A, 0, 0, 0, 0x0D, 0, 0x09, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

pub const SPACES: u64 = 0x2020202020202020;

pub inline fn skip_space(__rig_in_s: []const u8, __rig_in_at: i64) i64 {
    const s = rig.rt(__rig_in_s);
    const at = rig.rt(__rig_in_at);
    if (at < 0) {
        return at;
    }
    var i: i64 = at;
    const __rig_ok_60 = rig.okNonneg(i); _ = &__rig_ok_60; while (true) {
        if (!(i < rig.lenOf(s))) break;
        {
            const c: u8 = rig.atIf(s, i, .upper, .lower, __rig_ok_60);
            if (c > SPACE) {
                return i;
            }
            if (((c == SPACE) and (rig.addProven(i, 8) <= rig.lenOf(s))) and (rig.readIntProven(u64, s, i, .little, .both) == SPACES)) {
                i = rig.addProven(i, 8);
            } else if ((((c == SPACE) or (c == LF)) or (c == CR)) or (c == TAB)) {
                i = rig.addProven(i, 1);
            } else {
                return i;
            }
        }
    }
    return i;
}

pub inline fn take_digits(__rig_in_s: []const u8, __rig_in_at: i64, __rig_in_m: *u64) i64 {
    const s = rig.rt(__rig_in_s);
    const at = rig.rt(__rig_in_at);
    const m = rig.rt(__rig_in_m);
    if ((at < 0) or (at > rig.lenOf(s))) {
        return at;
    }
    var i: i64 = at;
    while (true) {
        if (!((i + 8) <= rig.lenOf(s))) break;
        {
            const d: u64 = @as(u64, rig.readIntProven(u64, s, i, .little, .upper)) -% @as(u64, 3472328296227680304);
            const bad: u64 = (d | (@as(u64, d) +% @as(u64, 8536140394893047414))) & @as(u64, 9259542123273814144);
            if (bad != 0) {
                const k: i64 = rig.rt(first_marked64(bad));
                if (k > 0) {
                    { const __rig_new_67: u64 = @as(u64, @as(u64, m.*) *% POW10_U64[rig.index(k, 9)]) +% rig.rt(eight_digits(@as(u64, d) << @intCast(@as(u64, @intCast(64 - (8 * k)))))); m.* = __rig_new_67; }
                }
                return i + k;
            }
            { const __rig_new_68: u64 = @as(u64, @as(u64, m.*) *% 100000000) +% rig.rt(eight_digits(d)); m.* = __rig_new_68; }
            i = rig.addProven(i, 8);
        }
    }
    return rig.rt(take_last_digits(s, i, m));
}

pub inline fn take_last_digits(__rig_in_s: []const u8, __rig_in_at: i64, __rig_in_m: *u64) i64 {
    const s = rig.rt(__rig_in_s);
    const at = rig.rt(__rig_in_at);
    const m = rig.rt(__rig_in_m);
    if (at < 0) {
        return at;
    }
    var i: i64 = at;
    const __rig_ok_69 = rig.okNonneg(i); _ = &__rig_ok_69; while (true) {
        if (!((i < rig.lenOf(s)) and rig.rt(is_digit(rig.atIf(s, i, .upper, .lower, __rig_ok_69))))) break;
        {
            { const __rig_new_73: u64 = @as(u64, @as(u64, m.*) *% 10) +% @as(u64, @intCast(@as(u8, rig.atIf(s, i, .upper, .lower, __rig_ok_69) - rig.rt(ZERO)))); m.* = __rig_new_73; }
            i = rig.addProven(i, 1);
        }
    }
    return i;
}

pub const POW10_U64: [9]u64 = [_]u64{ 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000 };

pub inline fn eight_digits(__rig_in_d: u64) u64 {
    const d = rig.rt(__rig_in_d);
    var v: u64 = (@as(u64, @as(u64, d) *% 2561) >> @intCast(8)) & 0x00FF00FF00FF00FF;
    v = (@as(u64, @as(u64, v) *% 6553601) >> @intCast(16)) & 0x0000FFFF0000FFFF;
    return @as(u64, @as(u64, v) *% 42949672960001) >> @intCast(32);
}

pub const TIER: i64 = @as(i64, if (__rig_m3_std_target.arch == .x86_64) 0 else 16);

pub const ONES64: u64 = 0x0101010101010101;

pub inline fn special(__rig_in_v: @Vector(16, u8)) rig.Mask(16) {
    const v = rig.rt(__rig_in_v);
    return rig.maskOr(rig.maskOr(rig.maskOr(rig.mask(v == rig.rt(@as(@Vector(16, u8), @splat(QUOTE)))), rig.mask(v == rig.rt(@as(@Vector(16, u8), @splat(BACKSLASH))))), rig.mask(v < rig.rt(@as(@Vector(16, u8), @splat(SPACE))))), rig.mask(v >= rig.rt(@as(@Vector(16, u8), @splat(0x80)))));
}

pub fn skip_plain_ascii(s: []const u8, at: i64) i64 {
    @setEvalBranchQuota(rig.eval_quota);
    if ((at < 0) or (at > rig.lenOf(s))) {
        return at;
    }
    var i: i64 = at;
    const stop: i64 = at + rig.rt(TIER);
    while (true) {
        if (!(((i + 8) <= rig.lenOf(s)) and (i < stop))) break;
        {
            const m: u64 = rig.rt(special64(rig.readIntProven(u64, s, i, .little, .upper)));
            if (m != 0) {
                return i + rig.rt(first_marked64(m));
            }
            i = rig.addProven(i, 8);
        }
    }
    while (true) : ({ i = rig.addProven(i, 16); }) {
        if (!((i + 16) <= rig.lenOf(s))) break;
        {
            if (rig.maskFirst(rig.rt(special(rig.simdReadProven(@Vector(16, u8), s, i, rig.Endian.little, .upper))))) |k| {
                return i + k;
            }
        }
    }
    if ((i < rig.lenOf(s)) and (rig.lenOf(s) >= 16)) {
        const m: u64 = @as(u64, rig.maskBits(rig.rt(special(rig.simdRead(@Vector(16, u8), s, rig.lenOf(s) - 16, rig.Endian.little))))) >> @intCast(@as(u64, @intCast(rig.addProven(i, 16) - rig.lenOf(s))));
        if (m != 0) {
            return i + @as(i64, @ctz(@as(u64, m)));
        }
        return rig.lenOf(s);
    }
    while (true) {
        if (!((i + 8) <= rig.lenOf(s))) break;
        {
            const m: u64 = rig.rt(special64(rig.readIntProven(u64, s, i, .little, .upper)));
            if (m != 0) {
                return i + rig.rt(first_marked64(m));
            }
            i = rig.addProven(i, 8);
        }
    }
    for (rig.slice(s, i, null), 0..) |c, __rig_i_87| {
        const k: i64 = @as(i64, @bitCast(@as(u64, __rig_i_87)));
        if ((((c == QUOTE) or (c == BACKSLASH)) or (c < SPACE)) or (c >= 0x80)) {
            return i + k;
        }
    }
    return rig.lenOf(s);
}

pub inline fn special64(__rig_in_w: u64) u64 {
    const w = rig.rt(__rig_in_w);
    const quote: u64 = w ^ @as(u64, 2459565876494606882);
    const slash: u64 = w ^ @as(u64, 6655295901103053916);
    const zero_quote: u64 = (@as(u64, quote) -% rig.rt(ONES64)) & (~@as(u64, quote));
    const zero_slash: u64 = (@as(u64, slash) -% rig.rt(ONES64)) & (~@as(u64, slash));
    const control: u64 = (@as(u64, w) -% @as(u64, 2314885530818453536)) & (~@as(u64, w));
    return (((zero_quote | zero_slash) | control) | w) & @as(u64, 9259542123273814144);
}

pub inline fn first_marked64(__rig_in_m: u64) i64 {
    const m = rig.rt(__rig_in_m);
    return @as(i64, @as(i64, @ctz(@as(u64, m)))) >> @intCast(3);
}

pub fn utf8_end(s: []const u8, at: i64) i64 {
    @setEvalBranchQuota(rig.eval_quota);
    var width: i64 = 0;
    var lo: u8 = 0x80;
    var hi: u8 = 0xBF;
    switch (rig.at(s, at)) {
        194...223 => {
            width = 2;
        },
        0xE0 => {
            width = 3;
            lo = 0xA0;
        },
        225...236, 238...239 => {
            width = 3;
        },
        0xED => {
            width = 3;
            hi = 0x9F;
        },
        0xF0 => {
            width = 4;
            lo = 0x90;
        },
        241...243 => {
            width = 4;
        },
        0xF4 => {
            width = 4;
            hi = 0x8F;
        },
        else => {
            return @as(i64, -1);
        },
    }
    if ((at + width) > rig.lenOf(s)) {
        return @as(i64, -1);
    }
    const second: u8 = rig.at(s, at + 1);
    if ((second < lo) or (second > hi)) {
        return @as(i64, -1);
    }
    {
        var __rig_i_91: i64 = 2;
        const __rig_end_91: i64 = width;
        while (__rig_i_91 < __rig_end_91) : (__rig_i_91 += 1) {
            const k = __rig_i_91;
            if ((rig.at(s, at + k) & 0xC0) != 0x80) {
                return @as(i64, -1);
            }
        }
    }
    return at + width;
}

pub const Block = @Vector(16, u8);

pub const TOO_SHORT: u8 = 0x01;

pub const TOO_LONG: u8 = 0x02;

pub const OVERLONG_3: u8 = 0x04;

pub const TOO_LARGE: u8 = 0x08;

pub const SURROGATE: u8 = 0x10;

pub const OVERLONG_2: u8 = 0x20;

pub const TOO_LARGE_1000: u8 = 0x40;

pub const OVERLONG_4: u8 = 0x40;

pub const TWO_CONTS: u8 = 0x80;

pub const CARRY: u8 = @as(u8, 131);

pub var BYTE_1_HIGH: @Vector(16, u8) = rig.rt(@as(@Vector(16, u8), [_]u8{ TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TWO_CONTS, TWO_CONTS, TWO_CONTS, TWO_CONTS, @as(u8, 33), TOO_SHORT, @as(u8, 21), @as(u8, 73) }));

pub var BYTE_1_LOW: @Vector(16, u8) = rig.rt(@as(@Vector(16, u8), [_]u8{ @as(u8, 231), @as(u8, 163), CARRY, CARRY, @as(u8, 139), @as(u8, 203), @as(u8, 203), @as(u8, 203), @as(u8, 203), @as(u8, 203), @as(u8, 203), @as(u8, 203), @as(u8, 203), @as(u8, 219), @as(u8, 203), @as(u8, 203) }));

pub var BYTE_2_HIGH: @Vector(16, u8) = rig.rt(@as(@Vector(16, u8), [_]u8{ TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, @as(u8, 230), @as(u8, 174), @as(u8, 186), @as(u8, 186), TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT }));

pub inline fn utf8_errors(__rig_in_cur: @Vector(16, u8), __rig_in_prev: @Vector(16, u8)) @Vector(16, u8) {
    const cur = rig.rt(__rig_in_cur);
    const prev = rig.rt(__rig_in_prev);
    const b1 = rig.lag(1, cur, prev);
    const pair = (rig.lookup(BYTE_1_HIGH, rig.vecShr(b1, 4)) & rig.lookup(BYTE_1_LOW, b1 & rig.rt(@as(@Vector(16, u8), @splat(0x0F))))) & rig.lookup(BYTE_2_HIGH, rig.vecShr(cur, 4));
    const must23 = (rig.vecSubSat(rig.lag(2, cur, prev), rig.rt(@as(@Vector(16, u8), @splat(0x60)))) | rig.vecSubSat(rig.lag(3, cur, prev), rig.rt(@as(@Vector(16, u8), @splat(0x70))))) & rig.rt(@as(@Vector(16, u8), @splat(0x80)));
    return must23 ^ pair;
}

pub inline fn utf8_end3(__rig_in_s: []const u8, __rig_in_at: i64) i64 {
    const s = rig.rt(__rig_in_s);
    const at = rig.rt(__rig_in_at);
    if ((at + 4) <= rig.lenOf(s)) {
        const w: u32 = rig.readIntProven(u32, s, at, .little, .upper);
        const lead: u32 = w & 0xFF;
        if ((((w & 0xC0C0F0) == 0x8080E0) and (lead != 0xE0)) and (lead != 0xED)) {
            return rig.addProven(at, 3);
        }
    }
    return utf8_end(s, at);
}

pub fn push_utf8(out: *rig.String, c: i64) void {
    @setEvalBranchQuota(rig.eval_quota);
    if (c < 0x80) {
        out.*.push(@as(u8, @intCast(@as(u64, @intCast(@as(i64, c))))));
    } else if (c < 0x800) {
        out.*.pushInt(u16, @as(u16, @intCast(@as(u64, @intCast(@as(i64, (0xC080 | @shlExact(@as(i64, @as(i64, c) >> @intCast(6)), @intCast(8))) | (c & 0x3F)))))), .big);
    } else if (c < 0x10000) {
        out.*.pushInt(u16, @as(u16, @intCast(@as(u64, @intCast(@as(i64, (0xE080 | @shlExact(@as(i64, @as(i64, c) >> @intCast(12)), @intCast(8))) | ((@as(i64, c) >> @intCast(6)) & 0x3F)))))), .big);
        out.*.push(@as(u8, @intCast(@as(u64, @intCast(@as(i64, 0x80 | (c & 0x3F)))))));
    } else {
        out.*.pushInt(u32, @as(u32, @intCast(@as(u64, @intCast(@as(i64, (((0xF0808080 | @shlExact(@as(i64, @as(i64, c) >> @intCast(18)), @intCast(24))) | @shlExact(@as(i64, (@as(i64, c) >> @intCast(12)) & 0x3F), @intCast(16))) | @shlExact(@as(i64, (@as(i64, c) >> @intCast(6)) & 0x3F), @intCast(8))) | (c & 0x3F)))))), .big);
    }
}

pub inline fn push_utf8_two3(__rig_in_out: *rig.String, __rig_in_c: i64, __rig_in_d: i64) void {
    const out = rig.rt(__rig_in_out);
    const c = rig.rt(__rig_in_c);
    const d = rig.rt(__rig_in_d);
    out.*.pushInt(u32, @as(u32, @intCast(@as(u64, @intCast(@as(i64, (((0xE08080E0 | @shlExact(@as(i64, @as(i64, c) >> @intCast(12)), @intCast(24))) | @shlExact(@as(i64, (@as(i64, c) >> @intCast(6)) & 0x3F), @intCast(16))) | @shlExact(@as(i64, c & 0x3F), @intCast(8))) | (@as(i64, d) >> @intCast(12))))))), .big);
    out.*.pushInt(u16, @as(u16, @intCast(@as(u64, @intCast(@as(i64, (0x8080 | @shlExact(@as(i64, (@as(i64, d) >> @intCast(6)) & 0x3F), @intCast(8))) | (d & 0x3F)))))), .big);
}

pub const POW10: [23]f64 = [_]f64{ @as(f64, 1e0), @as(f64, 1e1), @as(f64, 1e2), @as(f64, 1e3), @as(f64, 1e4), @as(f64, 1e5), @as(f64, 1e6), @as(f64, 1e7), @as(f64, 1e8), @as(f64, 1e9), @as(f64, 1e10), @as(f64, 1e11), @as(f64, 1e12), @as(f64, 1e13), @as(f64, 1e14), @as(f64, 1e15), @as(f64, 1e16), @as(f64, 1e17), @as(f64, 1e18), @as(f64, 1e19), @as(f64, 1e20), @as(f64, 1e21), @as(f64, 1e22) };

pub inline fn decimal_to_float(__rig_in_m: u64, __rig_in_q: i64, __rig_in_digits: i64) ?f64 {
    const m = rig.rt(__rig_in_m);
    const q = rig.rt(__rig_in_q);
    const digits = rig.rt(__rig_in_digits);
    if (((digits <= 15) and (q >= @as(i64, -22))) and (q <= 22)) {
        const f: f64 = @as(f64, @floatFromInt(@as(u64, m)));
        if (q < 0) {
            return (f / POW10[rig.index(-q, 23)]);
        }
        return f * POW10[rig.index(q, 23)];
    }
    if (((m != 0) and (q > @as(i64, -307))) and (q < 288)) {
        if (rig.rt(normal_float_bits(m, q))) |bits| {
            return @as(f64, @bitCast(@as(u64, bits)));
        }
    }
    if (eisel_lemire(m, q)) |bits| {
        return @as(f64, @bitCast(@as(u64, bits)));
    }
    return null;
}

pub inline fn slow_float(__rig_in_s: []const u8) f64 {
    const s = rig.rt(__rig_in_s);
    return (__rig_fb_92: { var __rig_fail_92: rig.ErrData = undefined; break :__rig_fb_92 (__rig_m4_std_text.parse_float(s, rig.failSlot(&__rig_fail_92)) catch |__rig_fail_92_c| if (rig.dropFailure(__rig_fail_92_c, &__rig_fail_92)) rig.rt(infinity()) else unreachable); });
}

pub inline fn infinity() f64 {
    var big: f64 = @as(f64, std.math.floatMax(f64)); _ = &big;
    return big * @as(f64, 2.0);
}

pub const INFINITY_BITS: u64 = 0x7FF0000000000000;

pub const MANTISSA_BITS: i64 = 52;

pub const LOW64: u128 = 0xFFFFFFFFFFFFFFFF;

pub fn eisel_lemire(m: u64, q: i64) ?u64 {
    @setEvalBranchQuota(rig.eval_quota);
    if ((m == 0) or (q < @as(i64, -342))) {
        return 0;
    }
    if (q > 308) {
        return INFINITY_BITS;
    }
    const lz: i64 = @as(i64, @clz(@as(u64, m)));
    const w: u64 = @shlExact(@as(u64, m), @intCast(@as(u64, @intCast(lz))));
    const index: i64 = q + 342;
    const first: u128 = @as(u128, @intCast(@as(u64, w))) * @as(u128, @intCast(@as(u64, POW5_HI[rig.index(index, 651)])));
    var hi: u64 = @as(u64, @intCast(@as(u128, @as(u128, first) >> @intCast(64))));
    var lo: u64 = @as(u64, @intCast(@as(u128, first & rig.rt(LOW64))));
    var mask: u64 = 0x1FF; _ = &mask;
    if ((hi & mask) == mask) {
        const second: u64 = @as(u64, @intCast(@as(u128, @as(u128, @as(u128, @intCast(@as(u64, w))) * @as(u128, @intCast(@as(u64, POW5_LO[rig.index(index, 651)])))) >> @intCast(64))));
        lo = @as(u64, lo) +% second;
        if (second > lo) {
            hi += 1;
        }
    }
    if ((lo == @as(u64, 18446744073709551615)) and ((q < @as(i64, -27)) or (q > 55))) {
        return null;
    }
    const upper: i64 = @as(i64, @intCast(@as(u64, @as(u64, hi) >> @intCast(63))));
    const shift: i64 = ((upper + 64) - rig.rt(MANTISSA_BITS)) - 3;
    var mantissa: u64 = @as(u64, hi) >> @intCast(@as(u64, @intCast(shift)));
    var power2: i64 = ((((@as(i64, q * @as(i64, 217706)) >> @intCast(16)) + 63) + upper) - lz) + 1023;
    if (power2 <= 0) {
        if ((-power2 + 1) >= 64) {
            return 0;
        }
        mantissa = @as(u64, mantissa) >> @intCast(@as(u64, @intCast(-power2 + 1)));
        mantissa += mantissa & 1;
        mantissa = @as(u64, mantissa) >> @intCast(1);
        return mantissa;
    }
    if (((((lo <= 1) and (q >= @as(i64, -4))) and (q <= 23)) and ((mantissa & 3) == 1)) and (@shlExact(@as(u64, mantissa), @intCast(@as(u64, @intCast(shift)))) == hi)) {
        mantissa = mantissa ^ 1;
    }
    mantissa += mantissa & 1;
    mantissa = @as(u64, mantissa) >> @intCast(1);
    if (mantissa >= @as(u64, 9007199254740992)) {
        { const __rig_new_93: u64 = @as(u64, 4503599627370496); mantissa = __rig_new_93; }
        power2 += 1;
    }
    { const __rig_new_94: u64 = mantissa & @as(u64, 4503599627370495); mantissa = __rig_new_94; }
    if (power2 >= 0x7FF) {
        return INFINITY_BITS;
    }
    return mantissa | @shlExact(@as(u64, @as(u64, @intCast(@as(i64, power2)))), @intCast(@as(u64, @intCast(rig.rt(MANTISSA_BITS)))));
}

pub inline fn normal_float_bits(__rig_in_m: u64, __rig_in_q: i64) ?u64 {
    const m = rig.rt(__rig_in_m);
    const q = rig.rt(__rig_in_q);
    const lz: i64 = @as(i64, @clz(@as(u64, m)));
    const w: u64 = @shlExact(@as(u64, m), @intCast(@as(u64, @intCast(lz))));
    const index: i64 = q + 342;
    const product: u128 = @as(u128, @intCast(@as(u64, w))) * @as(u128, @intCast(@as(u64, POW5_HI[rig.index(index, 651)])));
    var hi: u64 = @as(u64, @intCast(@as(u128, @as(u128, product) >> @intCast(64))));
    if (((@as(u64, hi) +% 1) & 0x1FE) == 0) {
        if (rig.rt(settle_hi(w, index, product))) |settled| {
            hi = settled;
        } else {
            return null;
        }
    }
    const upper: i64 = @as(i64, @intCast(@as(u64, @as(u64, hi) >> @intCast(63))));
    var mantissa: u64 = @as(u64, hi) >> @intCast(@as(u64, @intCast(((upper + 64) - rig.rt(MANTISSA_BITS)) - 3)));
    mantissa = (@as(u64, mantissa) >> @intCast(1)) + (mantissa & 1);
    const power2: i64 = ((((@as(i64, q * @as(i64, 217706)) >> @intCast(16)) + 63) + upper) - lz) + 1023;
    return mantissa + @shlExact(@as(u64, @as(u64, @intCast(@as(i64, power2 - 1)))), @intCast(@as(u64, @intCast(rig.rt(MANTISSA_BITS)))));
}

pub inline fn settle_hi(__rig_in_w: u64, __rig_in_index: i64, __rig_in_product: u128) ?u64 {
    const w = rig.rt(__rig_in_w);
    const index = rig.rt(__rig_in_index);
    const product = rig.rt(__rig_in_product);
    var hi: u64 = @as(u64, @intCast(@as(u128, @as(u128, product) >> @intCast(64))));
    const lo: u64 = @as(u64, @intCast(@as(u128, product & rig.rt(LOW64))));
    const next: u64 = @as(u64, lo) +% @as(u64, @intCast(@as(u128, @as(u128, @as(u128, @intCast(@as(u64, w))) * @as(u128, @intCast(@as(u64, POW5_LO[rig.index(index, 651)])))) >> @intCast(64))));
    if ((next == 0) or (next == @as(u64, 18446744073709551615))) {
        return null;
    }
    if (next < lo) {
        hi += 1;
    }
    return hi;
}

pub const POW5_HI: [651]u64 = [_]u64{ 0xeef453d6923bd65a, 0x9558b4661b6565f8, 0xbaaee17fa23ebf76, 0xe95a99df8ace6f53, 0x91d8a02bb6c10594, 0xb64ec836a47146f9, 0xe3e27a444d8d98b7, 0x8e6d8c6ab0787f72, 0xb208ef855c969f4f, 0xde8b2b66b3bc4723, 0x8b16fb203055ac76, 0xaddcb9e83c6b1793, 0xd953e8624b85dd78, 0x87d4713d6f33aa6b, 0xa9c98d8ccb009506, 0xd43bf0effdc0ba48, 0x84a57695fe98746d, 0xa5ced43b7e3e9188, 0xcf42894a5dce35ea, 0x818995ce7aa0e1b2, 0xa1ebfb4219491a1f, 0xca66fa129f9b60a6, 0xfd00b897478238d0, 0x9e20735e8cb16382, 0xc5a890362fddbc62, 0xf712b443bbd52b7b, 0x9a6bb0aa55653b2d, 0xc1069cd4eabe89f8, 0xf148440a256e2c76, 0x96cd2a865764dbca, 0xbc807527ed3e12bc, 0xeba09271e88d976b, 0x93445b8731587ea3, 0xb8157268fdae9e4c, 0xe61acf033d1a45df, 0x8fd0c16206306bab, 0xb3c4f1ba87bc8696, 0xe0b62e2929aba83c, 0x8c71dcd9ba0b4925, 0xaf8e5410288e1b6f, 0xdb71e91432b1a24a, 0x892731ac9faf056e, 0xab70fe17c79ac6ca, 0xd64d3d9db981787d, 0x85f0468293f0eb4e, 0xa76c582338ed2621, 0xd1476e2c07286faa, 0x82cca4db847945ca, 0xa37fce126597973c, 0xcc5fc196fefd7d0c, 0xff77b1fcbebcdc4f, 0x9faacf3df73609b1, 0xc795830d75038c1d, 0xf97ae3d0d2446f25, 0x9becce62836ac577, 0xc2e801fb244576d5, 0xf3a20279ed56d48a, 0x9845418c345644d6, 0xbe5691ef416bd60c, 0xedec366b11c6cb8f, 0x94b3a202eb1c3f39, 0xb9e08a83a5e34f07, 0xe858ad248f5c22c9, 0x91376c36d99995be, 0xb58547448ffffb2d, 0xe2e69915b3fff9f9, 0x8dd01fad907ffc3b, 0xb1442798f49ffb4a, 0xdd95317f31c7fa1d, 0x8a7d3eef7f1cfc52, 0xad1c8eab5ee43b66, 0xd863b256369d4a40, 0x873e4f75e2224e68, 0xa90de3535aaae202, 0xd3515c2831559a83, 0x8412d9991ed58091, 0xa5178fff668ae0b6, 0xce5d73ff402d98e3, 0x80fa687f881c7f8e, 0xa139029f6a239f72, 0xc987434744ac874e, 0xfbe9141915d7a922, 0x9d71ac8fada6c9b5, 0xc4ce17b399107c22, 0xf6019da07f549b2b, 0x99c102844f94e0fb, 0xc0314325637a1939, 0xf03d93eebc589f88, 0x96267c7535b763b5, 0xbbb01b9283253ca2, 0xea9c227723ee8bcb, 0x92a1958a7675175f, 0xb749faed14125d36, 0xe51c79a85916f484, 0x8f31cc0937ae58d2, 0xb2fe3f0b8599ef07, 0xdfbdcece67006ac9, 0x8bd6a141006042bd, 0xaecc49914078536d, 0xda7f5bf590966848, 0x888f99797a5e012d, 0xaab37fd7d8f58178, 0xd5605fcdcf32e1d6, 0x855c3be0a17fcd26, 0xa6b34ad8c9dfc06f, 0xd0601d8efc57b08b, 0x823c12795db6ce57, 0xa2cb1717b52481ed, 0xcb7ddcdda26da268, 0xfe5d54150b090b02, 0x9efa548d26e5a6e1, 0xc6b8e9b0709f109a, 0xf867241c8cc6d4c0, 0x9b407691d7fc44f8, 0xc21094364dfb5636, 0xf294b943e17a2bc4, 0x979cf3ca6cec5b5a, 0xbd8430bd08277231, 0xece53cec4a314ebd, 0x940f4613ae5ed136, 0xb913179899f68584, 0xe757dd7ec07426e5, 0x9096ea6f3848984f, 0xb4bca50b065abe63, 0xe1ebce4dc7f16dfb, 0x8d3360f09cf6e4bd, 0xb080392cc4349dec, 0xdca04777f541c567, 0x89e42caaf9491b60, 0xac5d37d5b79b6239, 0xd77485cb25823ac7, 0x86a8d39ef77164bc, 0xa8530886b54dbdeb, 0xd267caa862a12d66, 0x8380dea93da4bc60, 0xa46116538d0deb78, 0xcd795be870516656, 0x806bd9714632dff6, 0xa086cfcd97bf97f3, 0xc8a883c0fdaf7df0, 0xfad2a4b13d1b5d6c, 0x9cc3a6eec6311a63, 0xc3f490aa77bd60fc, 0xf4f1b4d515acb93b, 0x991711052d8bf3c5, 0xbf5cd54678eef0b6, 0xef340a98172aace4, 0x9580869f0e7aac0e, 0xbae0a846d2195712, 0xe998d258869facd7, 0x91ff83775423cc06, 0xb67f6455292cbf08, 0xe41f3d6a7377eeca, 0x8e938662882af53e, 0xb23867fb2a35b28d, 0xdec681f9f4c31f31, 0x8b3c113c38f9f37e, 0xae0b158b4738705e, 0xd98ddaee19068c76, 0x87f8a8d4cfa417c9, 0xa9f6d30a038d1dbc, 0xd47487cc8470652b, 0x84c8d4dfd2c63f3b, 0xa5fb0a17c777cf09, 0xcf79cc9db955c2cc, 0x81ac1fe293d599bf, 0xa21727db38cb002f, 0xca9cf1d206fdc03b, 0xfd442e4688bd304a, 0x9e4a9cec15763e2e, 0xc5dd44271ad3cdba, 0xf7549530e188c128, 0x9a94dd3e8cf578b9, 0xc13a148e3032d6e7, 0xf18899b1bc3f8ca1, 0x96f5600f15a7b7e5, 0xbcb2b812db11a5de, 0xebdf661791d60f56, 0x936b9fcebb25c995, 0xb84687c269ef3bfb, 0xe65829b3046b0afa, 0x8ff71a0fe2c2e6dc, 0xb3f4e093db73a093, 0xe0f218b8d25088b8, 0x8c974f7383725573, 0xafbd2350644eeacf, 0xdbac6c247d62a583, 0x894bc396ce5da772, 0xab9eb47c81f5114f, 0xd686619ba27255a2, 0x8613fd0145877585, 0xa798fc4196e952e7, 0xd17f3b51fca3a7a0, 0x82ef85133de648c4, 0xa3ab66580d5fdaf5, 0xcc963fee10b7d1b3, 0xffbbcfe994e5c61f, 0x9fd561f1fd0f9bd3, 0xc7caba6e7c5382c8, 0xf9bd690a1b68637b, 0x9c1661a651213e2d, 0xc31bfa0fe5698db8, 0xf3e2f893dec3f126, 0x986ddb5c6b3a76b7, 0xbe89523386091465, 0xee2ba6c0678b597f, 0x94db483840b717ef, 0xba121a4650e4ddeb, 0xe896a0d7e51e1566, 0x915e2486ef32cd60, 0xb5b5ada8aaff80b8, 0xe3231912d5bf60e6, 0x8df5efabc5979c8f, 0xb1736b96b6fd83b3, 0xddd0467c64bce4a0, 0x8aa22c0dbef60ee4, 0xad4ab7112eb3929d, 0xd89d64d57a607744, 0x87625f056c7c4a8b, 0xa93af6c6c79b5d2d, 0xd389b47879823479, 0x843610cb4bf160cb, 0xa54394fe1eedb8fe, 0xce947a3da6a9273e, 0x811ccc668829b887, 0xa163ff802a3426a8, 0xc9bcff6034c13052, 0xfc2c3f3841f17c67, 0x9d9ba7832936edc0, 0xc5029163f384a931, 0xf64335bcf065d37d, 0x99ea0196163fa42e, 0xc06481fb9bcf8d39, 0xf07da27a82c37088, 0x964e858c91ba2655, 0xbbe226efb628afea, 0xeadab0aba3b2dbe5, 0x92c8ae6b464fc96f, 0xb77ada0617e3bbcb, 0xe55990879ddcaabd, 0x8f57fa54c2a9eab6, 0xb32df8e9f3546564, 0xdff9772470297ebd, 0x8bfbea76c619ef36, 0xaefae51477a06b03, 0xdab99e59958885c4, 0x88b402f7fd75539b, 0xaae103b5fcd2a881, 0xd59944a37c0752a2, 0x857fcae62d8493a5, 0xa6dfbd9fb8e5b88e, 0xd097ad07a71f26b2, 0x825ecc24c873782f, 0xa2f67f2dfa90563b, 0xcbb41ef979346bca, 0xfea126b7d78186bc, 0x9f24b832e6b0f436, 0xc6ede63fa05d3143, 0xf8a95fcf88747d94, 0x9b69dbe1b548ce7c, 0xc24452da229b021b, 0xf2d56790ab41c2a2, 0x97c560ba6b0919a5, 0xbdb6b8e905cb600f, 0xed246723473e3813, 0x9436c0760c86e30b, 0xb94470938fa89bce, 0xe7958cb87392c2c2, 0x90bd77f3483bb9b9, 0xb4ecd5f01a4aa828, 0xe2280b6c20dd5232, 0x8d590723948a535f, 0xb0af48ec79ace837, 0xdcdb1b2798182244, 0x8a08f0f8bf0f156b, 0xac8b2d36eed2dac5, 0xd7adf884aa879177, 0x86ccbb52ea94baea, 0xa87fea27a539e9a5, 0xd29fe4b18e88640e, 0x83a3eeeef9153e89, 0xa48ceaaab75a8e2b, 0xcdb02555653131b6, 0x808e17555f3ebf11, 0xa0b19d2ab70e6ed6, 0xc8de047564d20a8b, 0xfb158592be068d2e, 0x9ced737bb6c4183d, 0xc428d05aa4751e4c, 0xf53304714d9265df, 0x993fe2c6d07b7fab, 0xbf8fdb78849a5f96, 0xef73d256a5c0f77c, 0x95a8637627989aad, 0xbb127c53b17ec159, 0xe9d71b689dde71af, 0x9226712162ab070d, 0xb6b00d69bb55c8d1, 0xe45c10c42a2b3b05, 0x8eb98a7a9a5b04e3, 0xb267ed1940f1c61c, 0xdf01e85f912e37a3, 0x8b61313bbabce2c6, 0xae397d8aa96c1b77, 0xd9c7dced53c72255, 0x881cea14545c7575, 0xaa242499697392d2, 0xd4ad2dbfc3d07787, 0x84ec3c97da624ab4, 0xa6274bbdd0fadd61, 0xcfb11ead453994ba, 0x81ceb32c4b43fcf4, 0xa2425ff75e14fc31, 0xcad2f7f5359a3b3e, 0xfd87b5f28300ca0d, 0x9e74d1b791e07e48, 0xc612062576589dda, 0xf79687aed3eec551, 0x9abe14cd44753b52, 0xc16d9a0095928a27, 0xf1c90080baf72cb1, 0x971da05074da7bee, 0xbce5086492111aea, 0xec1e4a7db69561a5, 0x9392ee8e921d5d07, 0xb877aa3236a4b449, 0xe69594bec44de15b, 0x901d7cf73ab0acd9, 0xb424dc35095cd80f, 0xe12e13424bb40e13, 0x8cbccc096f5088cb, 0xafebff0bcb24aafe, 0xdbe6fecebdedd5be, 0x89705f4136b4a597, 0xabcc77118461cefc, 0xd6bf94d5e57a42bc, 0x8637bd05af6c69b5, 0xa7c5ac471b478423, 0xd1b71758e219652b, 0x83126e978d4fdf3b, 0xa3d70a3d70a3d70a, 0xcccccccccccccccc, 0x8000000000000000, 0xa000000000000000, 0xc800000000000000, 0xfa00000000000000, 0x9c40000000000000, 0xc350000000000000, 0xf424000000000000, 0x9896800000000000, 0xbebc200000000000, 0xee6b280000000000, 0x9502f90000000000, 0xba43b74000000000, 0xe8d4a51000000000, 0x9184e72a00000000, 0xb5e620f480000000, 0xe35fa931a0000000, 0x8e1bc9bf04000000, 0xb1a2bc2ec5000000, 0xde0b6b3a76400000, 0x8ac7230489e80000, 0xad78ebc5ac620000, 0xd8d726b7177a8000, 0x878678326eac9000, 0xa968163f0a57b400, 0xd3c21bcecceda100, 0x84595161401484a0, 0xa56fa5b99019a5c8, 0xcecb8f27f4200f3a, 0x813f3978f8940984, 0xa18f07d736b90be5, 0xc9f2c9cd04674ede, 0xfc6f7c4045812296, 0x9dc5ada82b70b59d, 0xc5371912364ce305, 0xf684df56c3e01bc6, 0x9a130b963a6c115c, 0xc097ce7bc90715b3, 0xf0bdc21abb48db20, 0x96769950b50d88f4, 0xbc143fa4e250eb31, 0xeb194f8e1ae525fd, 0x92efd1b8d0cf37be, 0xb7abc627050305ad, 0xe596b7b0c643c719, 0x8f7e32ce7bea5c6f, 0xb35dbf821ae4f38b, 0xe0352f62a19e306e, 0x8c213d9da502de45, 0xaf298d050e4395d6, 0xdaf3f04651d47b4c, 0x88d8762bf324cd0f, 0xab0e93b6efee0053, 0xd5d238a4abe98068, 0x85a36366eb71f041, 0xa70c3c40a64e6c51, 0xd0cf4b50cfe20765, 0x82818f1281ed449f, 0xa321f2d7226895c7, 0xcbea6f8ceb02bb39, 0xfee50b7025c36a08, 0x9f4f2726179a2245, 0xc722f0ef9d80aad6, 0xf8ebad2b84e0d58b, 0x9b934c3b330c8577, 0xc2781f49ffcfa6d5, 0xf316271c7fc3908a, 0x97edd871cfda3a56, 0xbde94e8e43d0c8ec, 0xed63a231d4c4fb27, 0x945e455f24fb1cf8, 0xb975d6b6ee39e436, 0xe7d34c64a9c85d44, 0x90e40fbeea1d3a4a, 0xb51d13aea4a488dd, 0xe264589a4dcdab14, 0x8d7eb76070a08aec, 0xb0de65388cc8ada8, 0xdd15fe86affad912, 0x8a2dbf142dfcc7ab, 0xacb92ed9397bf996, 0xd7e77a8f87daf7fb, 0x86f0ac99b4e8dafd, 0xa8acd7c0222311bc, 0xd2d80db02aabd62b, 0x83c7088e1aab65db, 0xa4b8cab1a1563f52, 0xcde6fd5e09abcf26, 0x80b05e5ac60b6178, 0xa0dc75f1778e39d6, 0xc913936dd571c84c, 0xfb5878494ace3a5f, 0x9d174b2dcec0e47b, 0xc45d1df942711d9a, 0xf5746577930d6500, 0x9968bf6abbe85f20, 0xbfc2ef456ae276e8, 0xefb3ab16c59b14a2, 0x95d04aee3b80ece5, 0xbb445da9ca61281f, 0xea1575143cf97226, 0x924d692ca61be758, 0xb6e0c377cfa2e12e, 0xe498f455c38b997a, 0x8edf98b59a373fec, 0xb2977ee300c50fe7, 0xdf3d5e9bc0f653e1, 0x8b865b215899f46c, 0xae67f1e9aec07187, 0xda01ee641a708de9, 0x884134fe908658b2, 0xaa51823e34a7eede, 0xd4e5e2cdc1d1ea96, 0x850fadc09923329e, 0xa6539930bf6bff45, 0xcfe87f7cef46ff16, 0x81f14fae158c5f6e, 0xa26da3999aef7749, 0xcb090c8001ab551c, 0xfdcb4fa002162a63, 0x9e9f11c4014dda7e, 0xc646d63501a1511d, 0xf7d88bc24209a565, 0x9ae757596946075f, 0xc1a12d2fc3978937, 0xf209787bb47d6b84, 0x9745eb4d50ce6332, 0xbd176620a501fbff, 0xec5d3fa8ce427aff, 0x93ba47c980e98cdf, 0xb8a8d9bbe123f017, 0xe6d3102ad96cec1d, 0x9043ea1ac7e41392, 0xb454e4a179dd1877, 0xe16a1dc9d8545e94, 0x8ce2529e2734bb1d, 0xb01ae745b101e9e4, 0xdc21a1171d42645d, 0x899504ae72497eba, 0xabfa45da0edbde69, 0xd6f8d7509292d603, 0x865b86925b9bc5c2, 0xa7f26836f282b732, 0xd1ef0244af2364ff, 0x8335616aed761f1f, 0xa402b9c5a8d3a6e7, 0xcd036837130890a1, 0x802221226be55a64, 0xa02aa96b06deb0fd, 0xc83553c5c8965d3d, 0xfa42a8b73abbf48c, 0x9c69a97284b578d7, 0xc38413cf25e2d70d, 0xf46518c2ef5b8cd1, 0x98bf2f79d5993802, 0xbeeefb584aff8603, 0xeeaaba2e5dbf6784, 0x952ab45cfa97a0b2, 0xba756174393d88df, 0xe912b9d1478ceb17, 0x91abb422ccb812ee, 0xb616a12b7fe617aa, 0xe39c49765fdf9d94, 0x8e41ade9fbebc27d, 0xb1d219647ae6b31c, 0xde469fbd99a05fe3, 0x8aec23d680043bee, 0xada72ccc20054ae9, 0xd910f7ff28069da4, 0x87aa9aff79042286, 0xa99541bf57452b28, 0xd3fa922f2d1675f2, 0x847c9b5d7c2e09b7, 0xa59bc234db398c25, 0xcf02b2c21207ef2e, 0x8161afb94b44f57d, 0xa1ba1ba79e1632dc, 0xca28a291859bbf93, 0xfcb2cb35e702af78, 0x9defbf01b061adab, 0xc56baec21c7a1916, 0xf6c69a72a3989f5b, 0x9a3c2087a63f6399, 0xc0cb28a98fcf3c7f, 0xf0fdf2d3f3c30b9f, 0x969eb7c47859e743, 0xbc4665b596706114, 0xeb57ff22fc0c7959, 0x9316ff75dd87cbd8, 0xb7dcbf5354e9bece, 0xe5d3ef282a242e81, 0x8fa475791a569d10, 0xb38d92d760ec4455, 0xe070f78d3927556a, 0x8c469ab843b89562, 0xaf58416654a6babb, 0xdb2e51bfe9d0696a, 0x88fcf317f22241e2, 0xab3c2fddeeaad25a, 0xd60b3bd56a5586f1, 0x85c7056562757456, 0xa738c6bebb12d16c, 0xd106f86e69d785c7, 0x82a45b450226b39c, 0xa34d721642b06084, 0xcc20ce9bd35c78a5, 0xff290242c83396ce, 0x9f79a169bd203e41, 0xc75809c42c684dd1, 0xf92e0c3537826145, 0x9bbcc7a142b17ccb, 0xc2abf989935ddbfe, 0xf356f7ebf83552fe, 0x98165af37b2153de, 0xbe1bf1b059e9a8d6, 0xeda2ee1c7064130c, 0x9485d4d1c63e8be7, 0xb9a74a0637ce2ee1, 0xe8111c87c5c1ba99, 0x910ab1d4db9914a0, 0xb54d5e4a127f59c8, 0xe2a0b5dc971f303a, 0x8da471a9de737e24, 0xb10d8e1456105dad, 0xdd50f1996b947518, 0x8a5296ffe33cc92f, 0xace73cbfdc0bfb7b, 0xd8210befd30efa5a, 0x8714a775e3e95c78, 0xa8d9d1535ce3b396, 0xd31045a8341ca07c, 0x83ea2b892091e44d, 0xa4e4b66b68b65d60, 0xce1de40642e3f4b9, 0x80d2ae83e9ce78f3, 0xa1075a24e4421730, 0xc94930ae1d529cfc, 0xfb9b7cd9a4a7443c, 0x9d412e0806e88aa5, 0xc491798a08a2ad4e, 0xf5b5d7ec8acb58a2, 0x9991a6f3d6bf1765, 0xbff610b0cc6edd3f, 0xeff394dcff8a948e, 0x95f83d0a1fb69cd9, 0xbb764c4ca7a4440f, 0xea53df5fd18d5513, 0x92746b9be2f8552c, 0xb7118682dbb66a77, 0xe4d5e82392a40515, 0x8f05b1163ba6832d, 0xb2c71d5bca9023f8, 0xdf78e4b2bd342cf6, 0x8bab8eefb6409c1a, 0xae9672aba3d0c320, 0xda3c0f568cc4f3e8, 0x8865899617fb1871, 0xaa7eebfb9df9de8d, 0xd51ea6fa85785631, 0x8533285c936b35de, 0xa67ff273b8460356, 0xd01fef10a657842c, 0x8213f56a67f6b29b, 0xa298f2c501f45f42, 0xcb3f2f7642717713, 0xfe0efb53d30dd4d7, 0x9ec95d1463e8a506, 0xc67bb4597ce2ce48, 0xf81aa16fdc1b81da, 0x9b10a4e5e9913128, 0xc1d4ce1f63f57d72, 0xf24a01a73cf2dccf, 0x976e41088617ca01, 0xbd49d14aa79dbc82, 0xec9c459d51852ba2, 0x93e1ab8252f33b45, 0xb8da1662e7b00a17, 0xe7109bfba19c0c9d, 0x906a617d450187e2, 0xb484f9dc9641e9da, 0xe1a63853bbd26451, 0x8d07e33455637eb2, 0xb049dc016abc5e5f, 0xdc5c5301c56b75f7, 0x89b9b3e11b6329ba, 0xac2820d9623bf429, 0xd732290fbacaf133, 0x867f59a9d4bed6c0, 0xa81f301449ee8c70, 0xd226fc195c6a2f8c, 0x83585d8fd9c25db7, 0xa42e74f3d032f525, 0xcd3a1230c43fb26f, 0x80444b5e7aa7cf85, 0xa0555e361951c366, 0xc86ab5c39fa63440, 0xfa856334878fc150, 0x9c935e00d4b9d8d2, 0xc3b8358109e84f07, 0xf4a642e14c6262c8, 0x98e7e9cccfbd7dbd, 0xbf21e44003acdd2c, 0xeeea5d5004981478, 0x95527a5202df0ccb, 0xbaa718e68396cffd, 0xe950df20247c83fd, 0x91d28b7416cdd27e, 0xb6472e511c81471d, 0xe3d8f9e563a198e5, 0x8e679c2f5e44ff8f };

pub const POW5_LO: [651]u64 = [_]u64{ 0x113faa2906a13b3f, 0x4ac7ca59a424c507, 0x5d79bcf00d2df649, 0xf4d82c2c107973dc, 0x79071b9b8a4be869, 0x9748e2826cdee284, 0xfd1b1b2308169b25, 0xfe30f0f5e50e20f7, 0xbdbd2d335e51a935, 0xad2c788035e61382, 0x4c3bcb5021afcc31, 0xdf4abe242a1bbf3d, 0xd71d6dad34a2af0d, 0x8672648c40e5ad68, 0x680efdaf511f18c2, 0x0212bd1b2566def2, 0x014bb630f7604b57, 0x419ea3bd35385e2d, 0x52064cac828675b9, 0x7343efebd1940993, 0x1014ebe6c5f90bf8, 0xd41a26e077774ef6, 0x8920b098955522b4, 0x55b46e5f5d5535b0, 0xeb2189f734aa831d, 0xa5e9ec7501d523e4, 0x47b233c92125366e, 0x999ec0bb696e840a, 0xc00670ea43ca250d, 0x380406926a5e5728, 0xc605083704f5ecf2, 0xf7864a44c633682e, 0x7ab3ee6afbe0211d, 0x5960ea05bad82964, 0x6fb92487298e33bd, 0xa5d3b6d479f8e056, 0x8f48a4899877186c, 0x331acdabfe94de87, 0x9ff0c08b7f1d0b14, 0x07ecf0ae5ee44dd9, 0xc9e82cd9f69d6150, 0xbe311c083a225cd2, 0x6dbd630a48aaf406, 0x092cbbccdad5b108, 0x25bbf56008c58ea5, 0xaf2af2b80af6f24e, 0x1af5af660db4aee1, 0x50d98d9fc890ed4d, 0xe50ff107bab528a0, 0x1e53ed49a96272c8, 0x25e8e89c13bb0f7a, 0x77b191618c54e9ac, 0xd59df5b9ef6a2417, 0x4b0573286b44ad1d, 0x4ee367f9430aec32, 0x229c41f793cda73f, 0x6b43527578c1110f, 0x830a13896b78aaa9, 0x23cc986bc656d553, 0x2cbfbe86b7ec8aa8, 0x7bf7d71432f3d6a9, 0xdaf5ccd93fb0cc53, 0xd1b3400f8f9cff68, 0x23100809b9c21fa1, 0xabd40a0c2832a78a, 0x16c90c8f323f516c, 0xae3da7d97f6792e3, 0x99cd11cfdf41779c, 0x40405643d711d583, 0x482835ea666b2572, 0xda3243650005eecf, 0x90bed43e40076a82, 0x5a7744a6e804a291, 0x711515d0a205cb36, 0x0d5a5b44ca873e03, 0xe858790afe9486c2, 0x626e974dbe39a872, 0xfb0a3d212dc8128f, 0x7ce66634bc9d0b99, 0x1c1fffc1ebc44e80, 0xa327ffb266b56220, 0x4bf1ff9f0062baa8, 0x6f773fc3603db4a9, 0xcb550fb4384d21d3, 0x7e2a53a146606a48, 0x2eda7444cbfc426d, 0xfa911155fefb5308, 0x793555ab7eba27ca, 0x4bc1558b2f3458de, 0x9eb1aaedfb016f16, 0x465e15a979c1cadc, 0x0bfacd89ec191ec9, 0xcef980ec671f667b, 0x82b7e12780e7401a, 0xd1b2ecb8b0908810, 0x861fa7e6dcb4aa15, 0x67a791e093e1d49a, 0xe0c8bb2c5c6d24e0, 0x58fae9f773886e18, 0xaf39a475506a899e, 0x6d8406c952429603, 0xc8e5087ba6d33b83, 0xfb1e4a9a90880a64, 0x5cf2eea09a55067f, 0xf42faa48c0ea481e, 0xf13b94daf124da26, 0x76c53d08d6b70858, 0x54768c4b0c64ca6e, 0xa9942f5dcf7dfd09, 0xd3f93b35435d7c4c, 0xc47bc5014a1a6daf, 0x359ab6419ca1091b, 0xc30163d203c94b62, 0x79e0de63425dcf1d, 0x985915fc12f542e4, 0x3e6f5b7b17b2939d, 0xa705992ceecf9c42, 0x50c6ff782a838353, 0xa4f8bf5635246428, 0x871b7795e136be99, 0x28e2557b59846e3f, 0x331aeada2fe589cf, 0x3ff0d2c85def7621, 0x0fed077a756b53a9, 0xd3e8495912c62894, 0x64712dd7abbbd95c, 0xbd8d794d96aacfb3, 0xecf0d7a0fc5583a0, 0xf41686c49db57244, 0x311c2875c522ced5, 0x7d633293366b828b, 0xae5dff9c02033197, 0xd9f57f830283fdfc, 0xd072df63c324fd7b, 0x4247cb9e59f71e6d, 0x52d9be85f074e608, 0x67902e276c921f8b, 0x00ba1cd8a3db53b6, 0x80e8a40eccd228a4, 0x6122cd128006b2cd, 0x796b805720085f81, 0xcbe3303674053bb0, 0xbedbfc4411068a9c, 0xee92fb5515482d44, 0x751bdd152d4d1c4a, 0xd262d45a78a0635d, 0x86fb897116c87c34, 0xd45d35e6ae3d4da0, 0x8974836059cca109, 0x2bd1a438703fc94b, 0x7b6306a34627ddcf, 0x1a3bc84c17b1d542, 0x20caba5f1d9e4a93, 0x547eb47b7282ee9c, 0xe99e619a4f23aa43, 0x6405fa00e2ec94d4, 0xde83bc408dd3dd04, 0x9624ab50b148d445, 0x3badd624dd9b0957, 0xe54ca5d70a80e5d6, 0x5e9fcf4ccd211f4c, 0x7647c3200069671f, 0x29ecd9f40041e073, 0xf468107100525890, 0x7182148d4066eeb4, 0xc6f14cd848405530, 0xb8ada00e5a506a7c, 0xa6d90811f0e4851c, 0x908f4a166d1da663, 0x9a598e4e043287fe, 0x40eff1e1853f29fd, 0xd12bee59e68ef47c, 0x82bb74f8301958ce, 0xe36a52363c1faf01, 0xdc44e6c3cb279ac1, 0x29ab103a5ef8c0b9, 0x7415d448f6b6f0e7, 0x111b495b3464ad21, 0xcab10dd900beec34, 0x3d5d514f40eea742, 0x0cb4a5a3112a5112, 0x47f0e785eaba72ab, 0x59ed216765690f56, 0x306869c13ec3532c, 0x1e414218c73a13fb, 0xe5d1929ef90898fa, 0xdf45f746b74abf39, 0x6b8bba8c328eb783, 0x066ea92f3f326564, 0xc80a537b0efefebd, 0xbd06742ce95f5f36, 0x2c48113823b73704, 0xf75a15862ca504c5, 0x9a984d73dbe722fb, 0xc13e60d0d2e0ebba, 0x318df905079926a8, 0xfdf17746497f7052, 0xfeb6ea8bedefa633, 0xfe64a52ee96b8fc0, 0x3dfdce7aa3c673b0, 0x06bea10ca65c084e, 0x486e494fcff30a62, 0x5a89dba3c3efccfa, 0xf89629465a75e01c, 0xf6bbb397f1135823, 0x746aa07ded582e2c, 0xa8c2a44eb4571cdc, 0x92f34d62616ce413, 0x77b020baf9c81d17, 0x0ace1474dc1d122e, 0x0d819992132456ba, 0x10e1fff697ed6c69, 0xca8d3ffa1ef463c1, 0xbd308ff8a6b17cb2, 0xac7cb3f6d05ddbde, 0x6bcdf07a423aa96b, 0x86c16c98d2c953c6, 0xe871c7bf077ba8b7, 0x11471cd764ad4972, 0xd598e40d3dd89bcf, 0x4aff1d108d4ec2c3, 0xcedf722a585139ba, 0xc2974eb4ee658828, 0x733d226229feea32, 0x0806357d5a3f525f, 0xca07c2dcb0cf26f7, 0xfc89b393dd02f0b5, 0xbbac2078d443ace2, 0xd54b944b84aa4c0d, 0x0a9e795e65d4df11, 0x4d4617b5ff4a16d5, 0x504bced1bf8e4e45, 0xe45ec2862f71e1d6, 0x5d767327bb4e5a4c, 0x3a6a07f8d510f86f, 0x890489f70a55368b, 0x2b45ac74ccea842e, 0x3b0b8bc90012929d, 0x09ce6ebb40173744, 0xcc420a6a101d0515, 0x9fa946824a12232d, 0x47939822dc96abf9, 0x59787e2b93bc56f7, 0x57eb4edb3c55b65a, 0xede622920b6b23f1, 0xe95fab368e45eced, 0x11dbcb0218ebb414, 0xd652bdc29f26a119, 0x4be76d3346f0495f, 0x6f70a4400c562ddb, 0xcb4ccd500f6bb952, 0x7e2000a41346a7a7, 0x8ed400668c0c28c8, 0x728900802f0f32fa, 0x4f2b40a03ad2ffb9, 0xe2f610c84987bfa8, 0x0dd9ca7d2df4d7c9, 0x91503d1c79720dbb, 0x75a44c6397ce912a, 0xc986afbe3ee11aba, 0xfbe85badce996168, 0xfae27299423fb9c3, 0xdccd879fc967d41a, 0x5400e987bbc1c920, 0x290123e9aab23b68, 0xf9a0b6720aaf6521, 0xf808e40e8d5b3e69, 0xb60b1d1230b20e04, 0xb1c6f22b5e6f48c2, 0x1e38aeb6360b1af3, 0x25c6da63c38de1b0, 0x579c487e5a38ad0e, 0x2d835a9df0c6d851, 0xf8e431456cf88e65, 0x1b8e9ecb641b58ff, 0xe272467e3d222f3f, 0x5b0ed81dcc6abb0f, 0x98e947129fc2b4e9, 0x3f2398d747b36224, 0x8eec7f0d19a03aad, 0x1953cf68300424ac, 0x5fa8c3423c052dd7, 0x3792f412cb06794d, 0xe2bbd88bbee40bd0, 0x5b6aceaeae9d0ec4, 0xf245825a5a445275, 0xeed6e2f0f0d56712, 0x55464dd69685606b, 0xaa97e14c3c26b886, 0xd53dd99f4b3066a8, 0xe546a8038efe4029, 0xde98520472bdd033, 0x963e66858f6d4440, 0xdde7001379a44aa8, 0x5560c018580d5d52, 0xaab8f01e6e10b4a6, 0xcab3961304ca70e8, 0x3d607b97c5fd0d22, 0x8cb89a7db77c506a, 0x77f3608e92adb242, 0x55f038b237591ed3, 0x6b6c46dec52f6688, 0x2323ac4b3b3da015, 0xabec975e0a0d081a, 0x96e7bd358c904a21, 0x7e50d64177da2e54, 0xdde50bd1d5d0b9e9, 0x955e4ec64b44e864, 0xbd5af13bef0b113e, 0xecb1ad8aeacdd58e, 0x67de18eda5814af2, 0x80eacf948770ced7, 0xa1258379a94d028d, 0x096ee45813a04330, 0x8bca9d6e188853fc, 0x775ea264cf55347e, 0x95364afe032a819e, 0x3a83ddbd83f52205, 0xc4926a9672793543, 0x75b7053c0f178294, 0x5324c68b12dd6339, 0xd3f6fc16ebca5e04, 0x88f4bb1ca6bcf585, 0x2b31e9e3d06c32e6, 0x3aff322e62439fd0, 0x09befeb9fad487c3, 0x4c2ebe687989a9b4, 0x0f9d37014bf60a11, 0x538484c19ef38c95, 0x2865a5f206b06fba, 0xf93f87b7442e45d4, 0xf78f69a51539d749, 0xb573440e5a884d1c, 0x31680a88f8953031, 0xfdc20d2b36ba7c3e, 0x3d32907604691b4d, 0xa63f9a49c2c1b110, 0x0fcf80dc33721d54, 0xd3c36113404ea4a9, 0x645a1cac083126ea, 0x3d70a3d70a3d70a4, 0xcccccccccccccccd, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x4000000000000000, 0x5000000000000000, 0xa400000000000000, 0x4d00000000000000, 0xf020000000000000, 0x6c28000000000000, 0xc732000000000000, 0x3c7f400000000000, 0x4b9f100000000000, 0x1e86d40000000000, 0x1314448000000000, 0x17d955a000000000, 0x5dcfab0800000000, 0x5aa1cae500000000, 0xf14a3d9e40000000, 0x6d9ccd05d0000000, 0xe4820023a2000000, 0xdda2802c8a800000, 0xd50b2037ad200000, 0x4526f422cc340000, 0x9670b12b7f410000, 0x3c0cdd765f114000, 0xa5880a69fb6ac800, 0x8eea0d047a457a00, 0x72a4904598d6d880, 0x47a6da2b7f864750, 0x999090b65f67d924, 0xfff4b4e3f741cf6d, 0xbff8f10e7a8921a4, 0xaff72d52192b6a0d, 0x9bf4f8a69f764490, 0x02f236d04753d5b4, 0x01d762422c946590, 0x424d3ad2b7b97ef5, 0xd2e0898765a7deb2, 0x63cc55f49f88eb2f, 0x3cbf6b71c76b25fb, 0x8bef464e3945ef7a, 0x97758bf0e3cbb5ac, 0x3d52eeed1cbea317, 0x4ca7aaa863ee4bdd, 0x8fe8caa93e74ef6a, 0xb3e2fd538e122b44, 0x60dbbca87196b616, 0xbc8955e946fe31cd, 0x6babab6398bdbe41, 0xc696963c7eed2dd1, 0xfc1e1de5cf543ca2, 0x3b25a55f43294bcb, 0x49ef0eb713f39ebe, 0x6e3569326c784337, 0x49c2c37f07965404, 0xdc33745ec97be906, 0x69a028bb3ded71a3, 0xc40832ea0d68ce0c, 0xf50a3fa490c30190, 0x792667c6da79e0fa, 0x577001b891185938, 0xed4c0226b55e6f86, 0x544f8158315b05b4, 0x696361ae3db1c721, 0x03bc3a19cd1e38e9, 0x04ab48a04065c723, 0x62eb0d64283f9c76, 0x3ba5d0bd324f8394, 0xca8f44ec7ee36479, 0x7e998b13cf4e1ecb, 0x9e3fedd8c321a67e, 0xc5cfe94ef3ea101e, 0xbba1f1d158724a12, 0x2a8a6e45ae8edc97, 0xf52d09d71a3293bd, 0x593c2626705f9c56, 0x6f8b2fb00c77836c, 0x0b6dfb9c0f956447, 0x4724bd4189bd5eac, 0x58edec91ec2cb657, 0x2f2967b66737e3ed, 0xbd79e0d20082ee74, 0xecd8590680a3aa11, 0xe80e6f4820cc9495, 0x3109058d147fdcdd, 0xbd4b46f0599fd415, 0x6c9e18ac7007c91a, 0x03e2cf6bc604ddb0, 0x84db8346b786151c, 0xe612641865679a63, 0x4fcb7e8f3f60c07e, 0xe3be5e330f38f09d, 0x5cadf5bfd3072cc5, 0x73d9732fc7c8f7f6, 0x2867e7fddcdd9afa, 0xb281e1fd541501b8, 0x1f225a7ca91a4226, 0x3375788de9b06958, 0x0052d6b1641c83ae, 0xc0678c5dbd23a49a, 0xf840b7ba963646e0, 0xb650e5a93bc3d898, 0xa3e51f138ab4cebe, 0xc66f336c36b10137, 0xb80b0047445d4184, 0xa60dc059157491e5, 0x87c89837ad68db2f, 0x29babe4598c311fb, 0xf4296dd6fef3d67a, 0x1899e4a65f58660c, 0x5ec05dcff72e7f8f, 0x76707543f4fa1f73, 0x6a06494a791c53a8, 0x0487db9d17636892, 0x45a9d2845d3c42b6, 0x0b8a2392ba45a9b2, 0x8e6cac7768d7141e, 0x3207d795430cd926, 0x7f44e6bd49e807b8, 0x5f16206c9c6209a6, 0x36dba887c37a8c0f, 0xc2494954da2c9789, 0xf2db9baa10b7bd6c, 0x6f92829494e5acc7, 0xcb772339ba1f17f9, 0xff2a760414536efb, 0xfef5138519684aba, 0x7eb258665fc25d69, 0xef2f773ffbd97a61, 0xaafb550ffacfd8fa, 0x95ba2a53f983cf38, 0xdd945a747bf26183, 0x94f971119aeef9e4, 0x7a37cd5601aab85d, 0xac62e055c10ab33a, 0x577b986b314d6009, 0xed5a7e85fda0b80b, 0x14588f13be847307, 0x596eb2d8ae258fc8, 0x6fca5f8ed9aef3bb, 0x25de7bb9480d5854, 0xaf561aa79a10ae6a, 0x1b2ba1518094da04, 0x90fb44d2f05d0842, 0x353a1607ac744a53, 0x42889b8997915ce8, 0x69956135febada11, 0x43fab9837e699095, 0x94f967e45e03f4bb, 0x1d1be0eebac278f5, 0x6462d92a69731732, 0x7d7b8f7503cfdcfe, 0x5cda735244c3d43e, 0x3a0888136afa64a7, 0x088aaa1845b8fdd0, 0x8aad549e57273d45, 0x36ac54e2f678864b, 0x84576a1bb416a7dd, 0x656d44a2a11c51d5, 0x9f644ae5a4b1b325, 0x873d5d9f0dde1fee, 0xa90cb506d155a7ea, 0x09a7f12442d588f2, 0x0c11ed6d538aeb2f, 0x8f1668c8a86da5fa, 0xf96e017d694487bc, 0x37c981dcc395a9ac, 0x85bbe253f47b1417, 0x93956d7478ccec8e, 0x387ac8d1970027b2, 0x06997b05fcc0319e, 0x441fece3bdf81f03, 0xd527e81cad7626c3, 0x8a71e223d8d3b074, 0xf6872d5667844e49, 0xb428f8ac016561db, 0xe13336d701beba52, 0xecc0024661173473, 0x27f002d7f95d0190, 0x31ec038df7b441f4, 0x7e67047175a15271, 0x0f0062c6e984d386, 0x52c07b78a3e60868, 0xa7709a56ccdf8a82, 0x88a66076400bb691, 0x6acff893d00ea435, 0x0583f6b8c4124d43, 0xc3727a337a8b704a, 0x744f18c0592e4c5c, 0x1162def06f79df73, 0x8addcb5645ac2ba8, 0x6d953e2bd7173692, 0xc8fa8db6ccdd0437, 0x1d9c9892400a22a2, 0x2503beb6d00cab4b, 0x2e44ae64840fd61d, 0x5ceaecfed289e5d2, 0x7425a83e872c5f47, 0xd12f124e28f77719, 0x82bd6b70d99aaa6f, 0x636cc64d1001550b, 0x3c47f7e05401aa4e, 0x65acfaec34810a71, 0x7f1839a741a14d0d, 0x1ede48111209a050, 0x934aed0aab460432, 0xf81da84d5617853f, 0x36251260ab9d668e, 0xc1d72b7c6b426019, 0xb24cf65b8612f81f, 0xdee033f26797b627, 0x169840ef017da3b1, 0x8e1f289560ee864e, 0xf1a6f2bab92a27e2, 0xae10af696774b1db, 0xacca6da1e0a8ef29, 0x17fd090a58d32af3, 0xddfc4b4cef07f5b0, 0x4abdaf101564f98e, 0x9d6d1ad41abe37f1, 0x84c86189216dc5ed, 0x32fd3cf5b4e49bb4, 0x3fbc8c33221dc2a1, 0x0fabaf3feaa5334a, 0x29cb4d87f2a7400e, 0x743e20e9ef511012, 0x914da9246b255416, 0x1ad089b6c2f7548e, 0xa184ac2473b529b1, 0xc9e5d72d90a2741e, 0x7e2fa67c7a658892, 0xddbb901b98feeab7, 0x552a74227f3ea565, 0xd53a88958f87275f, 0x8a892abaf368f137, 0x2d2b7569b0432d85, 0x9c3b29620e29fc73, 0x8349f3ba91b47b8f, 0x241c70a936219a73, 0xed238cd383aa0110, 0xf4363804324a40aa, 0xb143c6053edcd0d5, 0xdd94b7868e94050a, 0xca7cf2b4191c8326, 0xfd1c2f611f63a3f0, 0xbc633b39673c8cec, 0xd5be0503e085d813, 0x4b2d8644d8a74e18, 0xddf8e7d60ed1219e, 0xcabb90e5c942b503, 0x3d6a751f3b936243, 0x0cc512670a783ad4, 0x27fb2b80668b24c5, 0xb1f9f660802dedf6, 0x5e7873f8a0396973, 0xdb0b487b6423e1e8, 0x91ce1a9a3d2cda62, 0x7641a140cc7810fb, 0xa9e904c87fcb0a9d, 0x546345fa9fbdcd44, 0xa97c177947ad4095, 0x49ed8eabcccc485d, 0x5c68f256bfff5a74, 0x73832eec6fff3111, 0xc831fd53c5ff7eab, 0xba3e7ca8b77f5e55, 0x28ce1bd2e55f35eb, 0x7980d163cf5b81b3, 0xd7e105bcc332621f, 0x8dd9472bf3fefaa7, 0xb14f98f6f0feb951, 0x6ed1bf9a569f33d3, 0x0a862f80ec4700c8, 0xcd27bb612758c0fa, 0x8038d51cb897789c, 0xe0470a63e6bd56c3, 0x1858ccfce06cac74, 0x0f37801e0c43ebc8, 0xd30560258f54e6ba, 0x47c6b82ef32a2069, 0x4cdc331d57fa5441, 0xe0133fe4adf8e952, 0x58180fddd97723a6, 0x570f09eaa7ea7648 };
