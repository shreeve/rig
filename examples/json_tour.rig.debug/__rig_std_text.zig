const std = @import("std");
const rig = @import("rig/runtime.zig");

const __rig_m5_std_utf8 = @import("__rig_std_utf8.zig");

pub const ParseError = error{
    @"std.text.ParseError.invalid",
    @"std.text.ParseError.overflow",
};

pub inline fn contains(__rig_in_s: []const u8, __rig_in_pat: []const u8) bool {
    const s = rig.rt(__rig_in_s);
    const pat = rig.rt(__rig_in_pat);
    return find(s, pat) != null;
}

pub inline fn starts_with(__rig_in_s: []const u8, __rig_in_prefix: []const u8) bool {
    const s = rig.rt(__rig_in_s);
    const prefix = rig.rt(__rig_in_prefix);
    return (rig.lenOf(prefix) <= rig.lenOf(s)) and rig.eql(rig.slice(s, 0, rig.lenOf(prefix)), prefix);
}

pub inline fn ends_with(__rig_in_s: []const u8, __rig_in_suffix: []const u8) bool {
    const s = rig.rt(__rig_in_s);
    const suffix = rig.rt(__rig_in_suffix);
    return (rig.lenOf(suffix) <= rig.lenOf(s)) and rig.eql(rig.slice(s, rig.lenOf(s) - rig.lenOf(suffix), null), suffix);
}

pub fn find_any(comptime set: []const u8, s: []const u8, i: i64) ?i64 {
    @setEvalBranchQuota(rig.eval_quota);
    if ((i >= 0) and (i <= rig.lenOf(s))) {
        if (rig.lenOf(set) == 0) {
            return null;
        }
        var j: i64 = i;
        while (true) : ({ j = rig.addProven(j, 16); }) {
            if (!((j + 16) <= rig.lenOf(s))) break;
            {
                if (rig.maskFirst(rig.rt(set16(set, rig.simdReadProven(@Vector(16, u8), s, j, rig.Endian.little, .both))))) |k| {
                    return j + k;
                }
            }
        }
        if ((j < rig.lenOf(s)) and (rig.lenOf(s) >= 16)) {
            const m: u64 = @as(u64, rig.maskBits(rig.rt(set16(set, rig.simdRead(@Vector(16, u8), s, rig.lenOf(s) - 16, rig.Endian.little))))) >> @intCast(@as(u64, @intCast(rig.addProven(j, 16) - rig.lenOf(s))));
            if (m != 0) {
                return j + @as(i64, @ctz(@as(u64, m)));
            }
            return null;
        }
        if ((j + 8) <= rig.lenOf(s)) {
            const m: u64 = rig.rt(set64(set, rig.readIntProven(u64, s, j, .little, .both)));
            if (m != 0) {
                return j + (@as(i64, @as(i64, @ctz(@as(u64, m)))) >> @intCast(3));
            }
            j = rig.addProven(j, 8);
        }
        while (true) : ({ j = rig.addProven(j, 1); }) {
            if (!(j < rig.lenOf(s))) break;
            {
                for (set) |b| {
                    if (rig.atProven(s, j, .both) == b) {
                        return j;
                    }
                }
            }
        }
        return null;
    }
    _ = rig.at(s, i);
    return null;
}

pub inline fn set16(comptime set: []const u8, __rig_in_v: @Vector(16, u8)) rig.Mask(16) {
    const v = rig.rt(__rig_in_v);
    var m = rig.rt(rig.maskOf(rig.Mask(16), @splat(false)));
    for (set) |b| {
        m = rig.maskOr(m, rig.mask(v == rig.rt(@as(@Vector(16, u8), @splat(b)))));
    }
    return m;
}

pub inline fn set64(comptime set: []const u8, __rig_in_w: u64) u64 {
    const w = rig.rt(__rig_in_w);
    var m: u64 = 0;
    for (set) |b| {
        const x: u64 = w ^ (rig.rt(ONES64) * @as(u64, @intCast(@as(u8, b))));
        { const __rig_new_21: u64 = (@as(u64, x) -% rig.rt(ONES64)) & (~@as(u64, x)); m |= __rig_new_21; }
    }
    return m & HIGHS64;
}

pub inline fn class_end(__rig_in_s: []const u8, __rig_in_i: i64, __rig_in_table: *const [256]u8, __rig_in_mask: u8) i64 {
    const s = rig.rt(__rig_in_s);
    const i = rig.rt(__rig_in_i);
    const table = rig.rt(__rig_in_table);
    const mask = rig.rt(__rig_in_mask);
    if ((i >= 0) and (i <= rig.lenOf(s))) {
        var j: i64 = i;
        while (true) {
            if (!((j < rig.lenOf(s)) and ((table.*[rig.index(rig.atProven(s, j, .both), 256)] & mask) != 0))) break;
            {
                j = rig.addProven(j, 1);
            }
        }
        return j;
    }
    _ = rig.at(s, i);
    return rig.lenOf(s);
}

pub const ONES64: u64 = 0x0101010101010101;

pub const HIGHS64: u64 = 0x8080808080808080;

pub inline fn trim(__rig_in_s: []const u8) []const u8 {
    const s = rig.rt(__rig_in_s);
    return rig.rt(trim_end(rig.rt(trim_start(s))));
}

pub inline fn trim_start(__rig_in_s: []const u8) []const u8 {
    const s = rig.rt(__rig_in_s);
    var i: i64 = 0;
    while (true) {
        if (!((i < rig.lenOf(s)) and rig.rt(is_space(rig.atProven(s, i, .both))))) break;
        {
            i = rig.addProven(i, 1);
        }
    }
    return rig.slice(s, i, null);
}

pub inline fn trim_end(__rig_in_s: []const u8) []const u8 {
    const s = rig.rt(__rig_in_s);
    var n: i64 = rig.lenOf(s);
    while (true) {
        if (!((n > 0) and rig.rt(is_space(rig.at(s, n - 1))))) break;
        {
            n -= 1;
        }
    }
    return rig.slice(s, 0, n);
}

pub inline fn strip_prefix(__rig_in_s: []const u8, __rig_in_prefix: []const u8) ?[]const u8 {
    const s = rig.rt(__rig_in_s);
    const prefix = rig.rt(__rig_in_prefix);
    if (!rig.rt(starts_with(s, prefix))) {
        return null;
    }
    return rig.slice(s, rig.lenOf(prefix), null);
}

pub inline fn strip_suffix(__rig_in_s: []const u8, __rig_in_suffix: []const u8) ?[]const u8 {
    const s = rig.rt(__rig_in_s);
    const suffix = rig.rt(__rig_in_suffix);
    if (!rig.rt(ends_with(s, suffix))) {
        return null;
    }
    return rig.slice(s, 0, rig.lenOf(s) - rig.lenOf(suffix));
}

pub const Cut = struct {
    before: []const u8,
    after: []const u8,
    pub const __rig_name = .{ .module = "std.text", .name = .{ "Cut" } };
};

pub inline fn cut(__rig_in_s: []const u8, __rig_in_sep: []const u8) rig.Opt(Cut) {
    const s = rig.rt(__rig_in_s);
    const sep = rig.rt(__rig_in_sep);
    const i: i64 = (find(s, sep) orelse return rig.pack(rig.Opt(Cut), null));
    return rig.pack(rig.Opt(Cut), Cut{ .before = rig.slice(s, 0, i), .after = rig.slice(s, i + rig.lenOf(sep), null) });
}

pub const Split = struct {
    rest: []const u8,
    sep: []const u8,
    done: bool,
    pub const __rig_name = .{ .module = "std.text", .name = .{ "Split" } };

    pub inline fn next(__rig_in_self: *Split) ?[]const u8 {
        const self = rig.rt(__rig_in_self);
        if (self.done) {
            return null;
        }
        const at: i64 = (find(self.rest, self.sep) orelse @as(i64, -1));
        if (at < 0) {
            self.done = true;
            return self.rest;
        }
        const part: []const u8 = rig.slice(self.rest, 0, at);
        self.rest = rig.slice(self.rest, at + rig.lenOf(self.sep), null);
        return part;
    }
};

pub inline fn split(__rig_in_s: []const u8, __rig_in_sep: []const u8) Split {
    const s = rig.rt(__rig_in_s);
    const sep = rig.rt(__rig_in_sep);
    if (rig.lenOf(sep) == 0) {
        empty_separator();
    }
    return Split{ .rest = s, .sep = sep, .done = false };
}

pub const Lines = struct {
    rest: []const u8,
    pub const __rig_name = .{ .module = "std.text", .name = .{ "Lines" } };

    pub inline fn next(__rig_in_self: *Lines) ?[]const u8 {
        const self = rig.rt(__rig_in_self);
        if (rig.lenOf(self.rest) == 0) {
            return null;
        }
        const end: i64 = (find(self.rest, "\n") orelse @as(i64, -1));
        if (end < 0) {
            const line: []const u8 = self.rest;
            self.rest = "";
            return line;
        }
        const line: []const u8 = rig.slice(self.rest, 0, end);
        self.rest = rig.slice(self.rest, end + 1, null);
        return (rig.rt(strip_suffix(line, "\r")) orelse line);
    }
};

pub inline fn lines(__rig_in_s: []const u8) Lines {
    const s = rig.rt(__rig_in_s);
    return Lines{ .rest = s };
}

pub const Words = struct {
    rest: []const u8,
    pub const __rig_name = .{ .module = "std.text", .name = .{ "Words" } };

    pub inline fn next(__rig_in_self: *Words) ?[]const u8 {
        const self = rig.rt(__rig_in_self);
        const s: []const u8 = rig.rt(trim_start(self.rest));
        if (rig.lenOf(s) == 0) {
            return null;
        }
        var end: i64 = 0;
        while (true) {
            if (!((end < rig.lenOf(s)) and !rig.rt(is_space(rig.atProven(s, end, .both))))) break;
            {
                end = rig.addProven(end, 1);
            }
        }
        self.rest = rig.slice(s, end, null);
        return rig.slice(s, 0, end);
    }
};

pub inline fn words(__rig_in_s: []const u8) Words {
    const s = rig.rt(__rig_in_s);
    return Words{ .rest = s };
}

pub const Chars = struct {
    rest: []const u8,
    pub const __rig_name = .{ .module = "std.text", .name = .{ "Chars" } };

    pub inline fn next(__rig_in_self: *Chars) ?[]const u8 {
        const self = rig.rt(__rig_in_self);
        if (rig.lenOf(self.rest) == 0) {
            return null;
        }
        const end: i64 = char_end(self.rest, 0);
        const c: []const u8 = rig.slice(self.rest, 0, end);
        self.rest = rig.slice(self.rest, end, null);
        return c;
    }
};

pub inline fn chars(__rig_in_s: []const u8) Chars {
    const s = rig.rt(__rig_in_s);
    return Chars{ .rest = s };
}

pub inline fn first_chars(__rig_in_s: []const u8, __rig_in_n: i64) []const u8 {
    const s = rig.rt(__rig_in_s);
    const n = rig.rt(__rig_in_n);
    return rig.slice(s, 0, first_chars_end(s, n));
}

pub inline fn last_chars(__rig_in_s: []const u8, __rig_in_n: i64) []const u8 {
    const s = rig.rt(__rig_in_s);
    const n = rig.rt(__rig_in_n);
    return rig.slice(s, last_chars_start(s, n), null);
}

pub const CharBreak = struct {
    state: i64,
    tailored: bool,
    pub const __rig_name = .{ .module = "std.text", .name = .{ "CharBreak" } };

    pub inline fn new(__rig_in_tailored: bool) CharBreak {
        const tailored = rig.rt(__rig_in_tailored);
        return CharBreak{ .state = @as(i64, -1), .tailored = tailored };
    }

    pub inline fn next(__rig_in_self: *CharBreak, __rig_in_r: i64) bool {
        const self = rig.rt(__rig_in_self);
        const r = rig.rt(__rig_in_r);
        const s: i64 = char_step(self.state, r, self.tailored);
        self.state = s & 0x7F;
        return (s & 0x80) != 0;
    }

    pub inline fn reset(__rig_in_self: *CharBreak) void {
        const self = rig.rt(__rig_in_self);
        self.state = @as(i64, -1);
    }
};

pub inline fn parse_bool(__rig_in_s: []const u8, __out: rig.ErrSlot) anyerror!bool {
    _ = &__out;
    const s = rig.rt(__rig_in_s);
    if (rig.eql(s, "true")) {
        return true;
    }
    if (rig.eql(s, "false")) {
        return false;
    }
    return error.@"std.text.ParseError.invalid";
}

pub inline fn parse_int(__rig_in_s: []const u8, __rig_in_base: i64, __out: rig.ErrSlot) anyerror!i64 {
    _ = &__out;
    const s = rig.rt(__rig_in_s);
    const base = rig.rt(__rig_in_base);
    if ((base < 2) or (base > 36)) {
        bad_base("text.parse_int");
    }
    return try parse_radix(s, base, __out);
}

pub fn format_int(n: i64, base: i64, upper: bool) rig.String {
    @setEvalBranchQuota(rig.eval_quota);
    if ((base < 2) or (base > 36)) {
        bad_base("text.format_int");
    }
    var buf: [64]u8 = undefined; @memset(&buf, @as(u8, 0));
    var i: i64 = rig.lenOf(buf);
    var rest: u64 = @as(u64, if (n < 0) @as(u64, @bitCast(@as(i64, @as(i64, 0) -% n))) else @as(u64, @intCast(@as(i64, n))));
    if (base == 10) {
        while (true) {
            if (!(rest >= 100)) break;
            {
                const q: u64 = @divTrunc(rest, 100);
                const p: i64 = @as(i64, @intCast(@as(u64, rest - (q * 100)))) * 2;
                i -= 2;
                buf[rig.index(i, 64)] = rig.at(rig.rt(PAIRS), p);
                buf[rig.index(i + 1, 64)] = rig.at(rig.rt(PAIRS), p + 1);
                rest = q;
            }
        }
        if (rest >= 10) {
            i -= 2;
            { const __rig_new_37: u8 = rig.at(rig.rt(PAIRS), @as(i64, @intCast(@as(u64, rest))) * 2); const __rig_ix_37_1: i64 = i; buf[rig.index(__rig_ix_37_1, 64)] = __rig_new_37; }
            { const __rig_new_38: u8 = rig.at(rig.rt(PAIRS), (@as(i64, @intCast(@as(u64, rest))) * 2) + 1); const __rig_ix_38_1: i64 = i + 1; buf[rig.index(__rig_ix_38_1, 64)] = __rig_new_38; }
        } else {
            i -= 1;
            { const __rig_new_39: u8 = @as(u8, @intCast(@as(u64, rest))) + 48; const __rig_ix_39_1: i64 = i; buf[rig.index(__rig_ix_39_1, 64)] = __rig_new_39; }
        }
    } else {
        const digits: []const u8 = if (upper) @as([]const u8, UPPER_DIGITS) else @as([]const u8, LOWER_DIGITS);
        const b: u64 = @as(u64, @intCast(@as(i64, base)));
        __rig_while_41: while (true) {
            {
                const q: u64 = @divTrunc(rest, b);
                i -= 1;
                { const __rig_new_43: u8 = rig.at(digits, @as(i64, @intCast(@as(u64, rest - (q * b))))); const __rig_ix_43_1: i64 = i; buf[rig.index(__rig_ix_43_1, 64)] = __rig_new_43; }
                rest = q;
                if (rest == 0) {
                    break :__rig_while_41;
                }
            }
        }
    }
    var out = rig.String.of(.{});
    var __rig_alive_out = true;
    defer if (__rig_alive_out) { __rig_alive_out = false; rig.drop(&out); };
    out.reserve((rig.lenOf(buf) - i) + 1);
    if (n < 0) {
        out.push(45);
    }
    {
        var __rig_i_47: i64 = i;
        const __rig_end_47: i64 = rig.lenOf(buf);
        while (__rig_i_47 < __rig_end_47) : (__rig_i_47 += 1) {
            const k = __rig_i_47;
            out.push(buf[rig.index(k, 64)]);
        }
    }
    return rig.take(&__rig_alive_out, out);
}

pub const LOWER_DIGITS: []const u8 = "0123456789abcdefghijklmnopqrstuvwxyz";

pub const UPPER_DIGITS: []const u8 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

pub const PAIRS: []const u8 = "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899";

pub fn edit_distance(a: []const u8, b: []const u8, row: *rig.List(i64), max: i64) i64 {
    @setEvalBranchQuota(rig.eval_quota);
    const m: i64 = __rig_m5_std_utf8.rune_count(b);
    const n: i64 = __rig_m5_std_utf8.rune_count(a);
    if ((max >= 0) and (((n - m) > max) or ((m - n) > max))) {
        return max + 1;
    }
    while (true) {
        if (!(rig.lenOf(row) > (m + 1))) break;
        {
            _ = row.pop();
        }
    }
    while (true) {
        if (!(rig.lenOf(row) < (m + 1))) break;
        {
            row.push(0);
        }
    }
    {
        var __rig_i_57: i64 = 0;
        const __rig_end_57: i64 = m + 1;
        while (__rig_i_57 < __rig_end_57) : (__rig_i_57 += 1) {
            const k = __rig_i_57;
            row.*.slotProven(k, .lower).* = k;
        }
    }
    var i: i64 = 0;
    var y: i64 = 0;
    while (true) {
        if (!(i < rig.lenOf(a))) break;
        {
            const da = rig.rt(__rig_m5_std_utf8.rune_after(a, i));
            const ra: i64 = rig.rt(rune_key(da, rig.atProven(a, i, .upper)));
            i = rig.addProven(i, da.size);
            y += 1;
            var diag: i64 = row.*.at(0);
            row.*.slot(0).* = y;
            var low: i64 = y;
            var j: i64 = 0;
            var x: i64 = 0;
            while (true) {
                if (!(j < rig.lenOf(b))) break;
                {
                    const db = rig.rt(__rig_m5_std_utf8.rune_after(b, j));
                    const rb: i64 = rig.rt(rune_key(db, rig.atProven(b, j, .upper)));
                    j = rig.addProven(j, db.size);
                    x += 1;
                    const above: i64 = row.*.atProven(x, .lower);
                    var best: i64 = diag + @as(i64, if (ra == rb) 0 else 1);
                    best = @as(i64, if ((above + 1) < best) (above + 1) else best);
                    best = @as(i64, if ((row.*.at(x - 1) + 1) < best) (row.*.at(x - 1) + 1) else best);
                    row.*.slotProven(x, .both).* = best;
                    diag = above;
                    low = @as(i64, if (best < low) best else low);
                }
            }
            if ((max >= 0) and (low > max)) {
                return rig.addProven(max, 1);
            }
        }
    }
    const d: i64 = row.*.at(m);
    return @as(i64, if ((max >= 0) and (d > max)) rig.addProven(max, 1) else d);
}

pub inline fn rune_key(__rig_in_d: __rig_m5_std_utf8.Decoded, __rig_in_first: u8) i64 {
    const d = rig.rt(__rig_in_d);
    const first = rig.rt(__rig_in_first);
    if ((d.size == 1) and (first >= 0x80)) {
        return 0x110000 + @as(i64, @intCast(@as(u8, first)));
    }
    return d.rune;
}

pub inline fn is_digit(__rig_in_b: u8) bool {
    const b = rig.rt(__rig_in_b);
    return (b >= 48) and (b <= 57);
}

pub inline fn is_alpha(__rig_in_b: u8) bool {
    const b = rig.rt(__rig_in_b);
    return ((b >= 65) and (b <= 90)) or ((b >= 97) and (b <= 122));
}

pub inline fn is_space(__rig_in_b: u8) bool {
    const b = rig.rt(__rig_in_b);
    return (b == 32) or ((b >= 9) and (b <= 13));
}

pub inline fn to_upper(__rig_in_b: u8) u8 {
    const b = rig.rt(__rig_in_b);
    return @as(u8, if ((b >= 97) and (b <= 122)) (b - 32) else b);
}

pub inline fn to_lower(__rig_in_b: u8) u8 {
    const b = rig.rt(__rig_in_b);
    return @as(u8, if ((b >= 65) and (b <= 90)) (b + 32) else b);
}

const __rig_shim_64 = @import("rig/std/text.zig");
pub const empty_separator = __rig_shim_64.empty_separator;
comptime {
    rig.expectShim(__rig_shim_64.empty_separator, fn () void, ParseError, "std.text.empty_separator");
}
pub const find = __rig_shim_64.find;
comptime {
    rig.expectShim(__rig_shim_64.find, fn ([]const u8, []const u8) ?i64, ParseError, "std.text.find");
}
pub const find_last = __rig_shim_64.find_last;
comptime {
    rig.expectShim(__rig_shim_64.find_last, fn ([]const u8, []const u8) ?i64, ParseError, "std.text.find_last");
}
pub const count = __rig_shim_64.count;
comptime {
    rig.expectShim(__rig_shim_64.count, fn ([]const u8, []const u8) i64, ParseError, "std.text.count");
}
pub fn parse_radix(__rig_a0: []const u8, __rig_a1: i64, __out: rig.ErrSlot) anyerror!i64 {
    _ = __out;
    return __rig_shim_64.parse_radix(__rig_a0, __rig_a1);
}
comptime {
    rig.expectShim(__rig_shim_64.parse_radix, fn ([]const u8, i64) anyerror!i64, ParseError, "std.text.parse_radix");
}
pub fn parse_float(__rig_a0: []const u8, __out: rig.ErrSlot) anyerror!f64 {
    _ = __out;
    return __rig_shim_64.parse_float(__rig_a0);
}
comptime {
    rig.expectShim(__rig_shim_64.parse_float, fn ([]const u8) anyerror!f64, ParseError, "std.text.parse_float");
}
pub const bad_base = __rig_shim_64.bad_base;
comptime {
    rig.expectShim(__rig_shim_64.bad_base, fn ([]const u8) void, ParseError, "std.text.bad_base");
}
pub const compare = __rig_shim_64.compare;
comptime {
    rig.expectShim(__rig_shim_64.compare, fn ([]const u8, []const u8) i64, ParseError, "std.text.compare");
}

const __rig_shim_65 = @import("rig/std/char.zig");
pub const char_count = __rig_shim_65.char_count;
comptime {
    rig.expectShim(__rig_shim_65.char_count, fn ([]const u8) i64, ParseError, "std.text.char_count");
}
pub const char_width = __rig_shim_65.char_width;
comptime {
    rig.expectShim(__rig_shim_65.char_width, fn ([]const u8) i64, ParseError, "std.text.char_width");
}
pub const width = __rig_shim_65.width;
comptime {
    rig.expectShim(__rig_shim_65.width, fn ([]const u8) i64, ParseError, "std.text.width");
}
pub const char_boundary = __rig_shim_65.char_boundary;
comptime {
    rig.expectShim(__rig_shim_65.char_boundary, fn ([]const u8, i64) i64, ParseError, "std.text.char_boundary");
}
pub const char_end = __rig_shim_65.char_end;
comptime {
    rig.expectShim(__rig_shim_65.char_end, fn ([]const u8, i64) i64, ParseError, "std.text.char_end");
}
pub const char_step = __rig_shim_65.char_step;
comptime {
    rig.expectShim(__rig_shim_65.char_step, fn (i64, i64, bool) i64, ParseError, "std.text.char_step");
}
pub const first_chars_end = __rig_shim_65.first_chars_end;
comptime {
    rig.expectShim(__rig_shim_65.first_chars_end, fn ([]const u8, i64) i64, ParseError, "std.text.first_chars_end");
}
pub const last_chars_start = __rig_shim_65.last_chars_start;
comptime {
    rig.expectShim(__rig_shim_65.last_chars_start, fn ([]const u8, i64) i64, ParseError, "std.text.last_chars_start");
}

pub const Interner = struct {
    len: i64 = 0,
    bytes: rig.String = rig.String.empty,
    ends: rig.List(u32) = rig.List(u32).empty,
    hs: rig.List(u64) = rig.List(u64).empty,
    table: IdTable = IdTable{},
    pub const __rig_name = .{ .module = "std.text", .name = .{ "Interner" } };

    pub fn intern(self: *Interner, s: []const u8) u32 {
        @setEvalBranchQuota(rig.eval_quota);
        const h: u64 = rig.hash(s);
        if (self.find(s, h)) |__rig_local_id_66| {
            return __rig_local_id_66;
        }
        const __rig_local_id_67: u32 = @as(u32, @intCast(@as(u64, @intCast(@as(i64, self.len)))));
        self.bytes.add(.{ s });
        self.ends.push(@as(u32, @intCast(@as(u64, @intCast(@as(i64, self.bytes.length()))))));
        self.hs.push(h);
        self.len += 1;
        if ((rig.lenOf(self.table.tags) > 0) and ((self.len * 5) <= (rig.lenOf(self.table.tags) * 4))) {
            rig.rt(self.table.place(@as(i64, @intCast(@as(u32, __rig_local_id_67))), h));
        } else if ((rig.lenOf(self.table.tags) > 0) or (self.len > ID_SMALL)) {
            rig.rt(self.rebuild(rig.rt(id_table_size(self.len, rig.lenOf(self.table.tags)))));
        }
        return __rig_local_id_67;
    }

    pub inline fn id(__rig_in_self: *const Interner, __rig_in_s: []const u8) ?u32 {
        const self = rig.rt(__rig_in_self);
        const s = rig.rt(__rig_in_s);
        return self.find(s, rig.hash(s));
    }

    pub inline fn text(__rig_in_self: *const Interner, __rig_in_id: u32) []const u8 {
        const self = rig.rt(__rig_in_self);
        const __rig_local_id_68 = rig.rt(__rig_in_id);
        const i: i64 = @as(i64, @intCast(@as(u32, __rig_local_id_68)));
        const start: i64 = @as(i64, if (i == 0) 0 else @as(i64, @intCast(@as(u32, self.ends.at(i - 1)))));
        return rig.slice(self.bytes.bytes(), start, @as(i64, @intCast(@as(u32, self.ends.atProven(i, .lower)))));
    }

    pub inline fn reserve(__rig_in_self: *Interner, __rig_in_n: i64, __rig_in_bytes: i64) void {
        const self = rig.rt(__rig_in_self);
        const n = rig.rt(__rig_in_n);
        const bytes = rig.rt(__rig_in_bytes);
        self.ends.reserve(n);
        self.hs.reserve(n);
        if (bytes > 0) {
            self.bytes.reserve(bytes);
        }
        const want: i64 = self.len + n;
        if (want > ID_SMALL) {
            const size: i64 = rig.rt(id_table_size(want, rig.lenOf(self.table.tags)));
            if (size > rig.lenOf(self.table.tags)) {
                rig.rt(self.rebuild(size));
            }
        }
    }

    pub fn find(self: *const Interner, s: []const u8, h: u64) ?u32 {
        @setEvalBranchQuota(rig.eval_quota);
        if (rig.lenOf(self.table.tags) == 0) {
            const hs = rig.slice(self.hs.items(), 0, null);
            var j: i64 = 0;
            while (true) {
                if (!((0 <= j) and (j < rig.lenOf(hs)))) break;
                {
                    if (rig.atProven(hs, j, .both) == h) {
                        if (rig.eql(rig.rt(self.text(@as(u32, @intCast(@as(u64, @intCast(@as(i64, j))))))), s)) {
                            return @as(u32, @intCast(@as(u64, @intCast(@as(i64, j)))));
                        }
                    }
                    j = rig.addProven(j, 1);
                }
            }
            return null;
        }
        const ts = rig.slice(self.table.tags.items(), 0, null);
        const tag: u8 = rig.rt(id_tag_of(h));
        var i: i64 = @as(i64, @intCast(@as(u64, h & @as(u64, @intCast(@as(i64, rig.lenOf(ts) - 1))))));
        {
            var __rig_i_75: i64 = 0;
            const __rig_end_75: i64 = 2;
            while (__rig_i_75 < __rig_end_75) : (__rig_i_75 += 1) {
                while (true) {
                    if (!((0 <= i) and (i < rig.lenOf(ts)))) break;
                    {
                        const t: u8 = rig.atProven(ts, i, .both);
                        if (t == 0) {
                            return null;
                        }
                        if (t == tag) {
                            const __rig_local_id_79: u32 = self.table.at.atProven(i, .lower);
                            if (rig.eql(rig.rt(self.text(__rig_local_id_79)), s)) {
                                return __rig_local_id_79;
                            }
                        }
                        i = rig.addProven(i, 1);
                    }
                }
                i = 0;
            }
        }
        return null;
    }

    pub inline fn rebuild(__rig_in_self: *Interner, __rig_in_n: i64) void {
        const self = rig.rt(__rig_in_self);
        const n = rig.rt(__rig_in_n);
        rig.rt(self.table.reset(n));
        {
            var __rig_i_83: i64 = 0;
            const __rig_end_83: i64 = rig.lenOf(self.hs);
            while (__rig_i_83 < __rig_end_83) : (__rig_i_83 += 1) {
                const j = __rig_i_83;
                rig.rt(self.table.place(j, self.hs.atProven(j, .lower)));
            }
        }
    }
};

pub const ID_SMALL: i64 = 8;

pub const IdTable = struct {
    tags: rig.List(u8) = rig.List(u8).empty,
    at: rig.List(u32) = rig.List(u32).empty,
    pub const __rig_name = .{ .module = "std.text", .name = .{ "IdTable" } };

    pub inline fn place(__rig_in_self: *IdTable, __rig_in_j: i64, __rig_in_h: u64) void {
        const self = rig.rt(__rig_in_self);
        const j = rig.rt(__rig_in_j);
        const h = rig.rt(__rig_in_h);
        const i: i64 = rig.rt(self.free_slot(h));
        { const __rig_new_84: u8 = rig.rt(id_tag_of(h)); const __rig_ix_84_1: i64 = i; self.tags.slot(__rig_ix_84_1).* = __rig_new_84; }
        { const __rig_new_85: u32 = @as(u32, @intCast(@as(u64, @intCast(@as(i64, j))))); const __rig_ix_85_1: i64 = i; self.at.slot(__rig_ix_85_1).* = __rig_new_85; }
    }

    pub inline fn free_slot(__rig_in_self: *const IdTable, __rig_in_h: u64) i64 {
        const self = rig.rt(__rig_in_self);
        const h = rig.rt(__rig_in_h);
        const ts = rig.slice(self.tags.items(), 0, null);
        var i: i64 = @as(i64, @intCast(@as(u64, h & @as(u64, @intCast(@as(i64, rig.lenOf(ts) - 1))))));
        {
            var __rig_i_89: i64 = 0;
            const __rig_end_89: i64 = 2;
            while (__rig_i_89 < __rig_end_89) : (__rig_i_89 += 1) {
                while (true) {
                    if (!((0 <= i) and (i < rig.lenOf(ts)))) break;
                    {
                        if (rig.atProven(ts, i, .both) == 0) {
                            return i;
                        }
                        i = rig.addProven(i, 1);
                    }
                }
                i = 0;
            }
        }
        return @as(i64, -1);
    }

    pub inline fn reset(__rig_in_self: *IdTable, __rig_in_n: i64) void {
        const self = rig.rt(__rig_in_self);
        const n = rig.rt(__rig_in_n);
        self.tags.clear();
        self.at.clear();
        self.tags.reserve(n);
        self.at.reserve(n);
        {
            var __rig_i_96: i64 = 0;
            const __rig_end_96: i64 = n;
            while (__rig_i_96 < __rig_end_96) : (__rig_i_96 += 1) {
                self.tags.push(0);
                self.at.push(0);
            }
        }
    }
};

pub inline fn id_table_size(__rig_in_want: i64, __rig_in_now: i64) i64 {
    const want = rig.rt(__rig_in_want);
    const now = rig.rt(__rig_in_now);
    var n: i64 = @as(i64, if (now < 16) 16 else now);
    while (true) {
        if (!((want * 5) > (n * 2))) break;
        {
            n *= 2;
        }
    }
    return n;
}

pub inline fn id_tag_of(__rig_in_h: u64) u8 {
    const h = rig.rt(__rig_in_h);
    return @as(u8, @intCast(@as(u64, @as(u64, h) >> @intCast(57)))) | 0x80;
}
