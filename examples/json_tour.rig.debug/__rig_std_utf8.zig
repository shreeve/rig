const std = @import("std");
const rig = @import("rig/runtime.zig");

pub const REPLACEMENT: i64 = 0xFFFD;

pub const RUNE_SELF: i64 = 0x80;

pub const Decoded = struct {
    rune: i64,
    size: i64,
    pub const __rig_name = .{ .module = "std.utf8", .name = .{ "Decoded" } };
};

pub inline fn rune_after(__rig_in_s: []const u8, __rig_in_i: i64) Decoded {
    const s = rig.rt(__rig_in_s);
    const i = rig.rt(__rig_in_i);
    if ((i >= 0) and (i < rig.lenOf(s))) {
        const b: u8 = rig.atProven(s, i, .both);
        if (b < 0x80) {
            return Decoded{ .rune = @as(i64, @intCast(@as(u8, b))), .size = 1 };
        }
        return rig.rt(multi_after(s, i));
    }
    if (i != rig.lenOf(s)) {
        _ = rig.at(s, i);
    }
    return Decoded{ .rune = REPLACEMENT, .size = 0 };
}

pub inline fn multi_after(__rig_in_s: []const u8, __rig_in_i: i64) Decoded {
    const s = rig.rt(__rig_in_s);
    const i = rig.rt(__rig_in_i);
    const x: u8 = LEAD[rig.index(rig.at(s, i) - 0x80, 128)];
    const n: i64 = @as(i64, @intCast(@as(u8, x & 7)));
    if ((n < 2) or ((i + n) > rig.lenOf(s))) {
        return rig.rt(bad());
    }
    const c1: u8 = rig.at(s, i + 1);
    if ((c1 < SECOND_LO[rig.index(@as(u8, x) >> @intCast(4), 5)]) or (c1 > SECOND_HI[rig.index(@as(u8, x) >> @intCast(4), 5)])) {
        return rig.rt(bad());
    }
    const r: i64 = @shlExact(@as(i64, @as(i64, @intCast(@as(u8, rig.atProven(s, i, .upper)))) & (@as(i64, 0x7F) >> @intCast(@as(u64, @intCast(n))))), @intCast(6)) | @as(i64, @intCast(@as(u8, c1 & 0x3F)));
    if (n < 3) {
        return Decoded{ .rune = r, .size = 2 };
    }
    return rig.rt(long_after(s, i, n, r));
}

pub inline fn long_after(__rig_in_s: []const u8, __rig_in_i: i64, __rig_in_n: i64, __rig_in_r: i64) Decoded {
    const s = rig.rt(__rig_in_s);
    const i = rig.rt(__rig_in_i);
    const n = rig.rt(__rig_in_n);
    const r = rig.rt(__rig_in_r);
    const c2: u8 = rig.at(s, i + 2);
    if ((c2 & 0xC0) != 0x80) {
        return rig.rt(bad());
    }
    const r3: i64 = @shlExact(@as(i64, r), @intCast(6)) | @as(i64, @intCast(@as(u8, c2 & 0x3F)));
    if (n < 4) {
        return Decoded{ .rune = r3, .size = 3 };
    }
    const c3: u8 = rig.at(s, rig.addProven(i, 3));
    if ((c3 & 0xC0) != 0x80) {
        return rig.rt(bad());
    }
    return Decoded{ .rune = @shlExact(@as(i64, r3), @intCast(6)) | @as(i64, @intCast(@as(u8, c3 & 0x3F))), .size = 4 };
}

pub inline fn bad() Decoded {
    return Decoded{ .rune = REPLACEMENT, .size = 1 };
}

pub const LEAD: [128]u8 = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x13, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x23, 0x03, 0x03, 0x34, 0x04, 0x04, 0x04, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

pub const SECOND_LO: [5]u8 = [_]u8{ 0x80, 0xA0, 0x80, 0x90, 0x80 };

pub const SECOND_HI: [5]u8 = [_]u8{ 0xBF, 0xBF, 0x9F, 0xBF, 0x8F };

pub inline fn rune_before(__rig_in_s: []const u8, __rig_in_i: i64) Decoded {
    const s = rig.rt(__rig_in_s);
    const i = rig.rt(__rig_in_i);
    if ((i > 0) and (i <= rig.lenOf(s))) {
        const b: u8 = rig.at(s, i - 1);
        if (b < 0x80) {
            return Decoded{ .rune = @as(i64, @intCast(@as(u8, b))), .size = 1 };
        }
        return rig.rt(multi_before(s, i));
    }
    if (i != 0) {
        _ = rig.at(s, i - 1);
    }
    return Decoded{ .rune = REPLACEMENT, .size = 0 };
}

pub inline fn multi_before(__rig_in_s: []const u8, __rig_in_i: i64) Decoded {
    const s = rig.rt(__rig_in_s);
    const i = rig.rt(__rig_in_i);
    var start: i64 = @as(i64, if (i > 1) (i - 2) else 0);
    if (i >= 4) {
        if ((rig.at(s, i - 2) & 0xC0) == 0x80) {
            start = @as(i64, if ((rig.at(s, i - 3) & 0xC0) == 0x80) (i - 4) else (i - 3));
        }
    } else {
        while (true) {
            if (!((start > 0) and ((rig.atProven(s, start, .lower) & 0xC0) == 0x80))) break;
            {
                start -= 1;
            }
        }
    }
    const d = rig.rt(rune_after(s, start));
    if ((start + d.size) == i) {
        return Decoded{ .rune = d.rune, .size = d.size };
    }
    return rig.rt(bad());
}

pub const Runes = struct {
    s: []const u8,
    at: i64,
    pub const __rig_name = .{ .module = "std.utf8", .name = .{ "Runes" } };

    pub inline fn next(__rig_in_self: *Runes) ?i64 {
        const self = rig.rt(__rig_in_self);
        if (self.at == rig.lenOf(self.s)) {
            return null;
        }
        const d = rig.rt(rune_after(self.s, self.at));
        self.at += d.size;
        return d.rune;
    }
};

pub inline fn runes(__rig_in_s: []const u8) Runes {
    const s = rig.rt(__rig_in_s);
    return Runes{ .s = s, .at = 0 };
}

pub inline fn rune_size(__rig_in_s: []const u8, __rig_in_i: i64) ?i64 {
    const s = rig.rt(__rig_in_s);
    const i = rig.rt(__rig_in_i);
    if (i == rig.lenOf(s)) {
        return null;
    }
    if (rig.at(s, i) < 0x80) {
        return 1;
    }
    const n: i64 = (rig.rt(rune_after(s, i))).size;
    if (n == 1) {
        return null;
    }
    return n;
}

pub fn rune_count(s: []const u8) i64 {
    @setEvalBranchQuota(rig.eval_quota);
    var n: i64 = 0;
    var i: i64 = 0;
    var prev = rig.rt(@as(@Vector(16, u8), @splat(0)));
    var ones = rig.rt(@as(@Vector(16, u8), @splat(0)));
    var held: i64 = 0;
    var high: bool = false;
    __rig_while_5: while (true) : ({ i = rig.addProven(i, 64); }) {
        if (!((i + 64) <= rig.lenOf(s))) break;
        {
            const a = rig.simdReadProven(@Vector(16, u8), s, i, rig.Endian.little, .both);
            const b = rig.simdRead(@Vector(16, u8), s, rig.addProven(i, 16), rig.Endian.little);
            const c = rig.simdRead(@Vector(16, u8), s, rig.addProven(i, 32), rig.Endian.little);
            const d = rig.simdRead(@Vector(16, u8), s, rig.addProven(i, 48), rig.Endian.little);
            if (rig.maskAll(rig.mask((((a | b) | c) | d) < rig.rt(@as(@Vector(16, u8), @splat(0x80)))))) {
                if (high and rig.maskAny(rig.mask(rig.vecSubSat(prev, ENDS) != rig.rt(@as(@Vector(16, u8), @splat(0)))))) {
                    break :__rig_while_5;
                }
                high = false;
                n += 64;
            } else {
                if (rig.maskAny(rig.mask((((rig.rt(errors(a, prev)) | rig.rt(errors(b, a))) | rig.rt(errors(c, b))) | rig.rt(errors(d, c))) != rig.rt(@as(@Vector(16, u8), @splat(0)))))) {
                    break :__rig_while_5;
                }
                { const __rig_new_8: @Vector(16, u8) = rig.vecAdd(rig.vecAdd(rig.vecAdd(rig.rt(starts(a)), rig.rt(starts(b))), rig.rt(starts(c))), rig.rt(starts(d))); ones = rig.vecAdd(ones, __rig_new_8); }
                held += 1;
                if (held == 63) {
                    { const __rig_new_9: i64 = rig.rt(lanes_sum(ones)); n += __rig_new_9; }
                    { const __rig_new_10: @Vector(16, u8) = rig.rt(@as(@Vector(16, u8), @splat(0))); ones = __rig_new_10; }
                    held = 0;
                }
                high = true;
            }
            prev = d;
        }
    }
    __rig_while_12: while (true) : ({ i = rig.addProven(i, 16); }) {
        if (!((i + 16) <= rig.lenOf(s))) break;
        {
            const a = rig.simdReadProven(@Vector(16, u8), s, i, rig.Endian.little, .both);
            if (rig.maskAll(rig.mask(a < rig.rt(@as(@Vector(16, u8), @splat(0x80)))))) {
                if (high and rig.maskAny(rig.mask(rig.vecSubSat(prev, ENDS) != rig.rt(@as(@Vector(16, u8), @splat(0)))))) {
                    break :__rig_while_12;
                }
                high = false;
                n += 16;
            } else {
                if (rig.maskAny(rig.mask(rig.rt(errors(a, prev)) != rig.rt(@as(@Vector(16, u8), @splat(0)))))) {
                    break :__rig_while_12;
                }
                { const __rig_new_15: @Vector(16, u8) = rig.rt(starts(a)); ones = rig.vecAdd(ones, __rig_new_15); }
                high = true;
            }
            prev = a;
        }
    }
    { const __rig_new_16: i64 = rig.rt(lanes_sum(ones)); n += __rig_new_16; }
    var j: i64 = i;
    while (true) {
        if (!(((j > 0) and (j > (i - 3))) and ((rig.at(s, j - 1) & 0xC0) == 0x80))) break;
        {
            j -= 1;
        }
    }
    if ((j > 0) and (rig.at(s, j - 1) >= 0xC0)) {
        i = j - 1;
        n -= 1;
    }
    while (true) {
        if (!(i < rig.lenOf(s))) break;
        {
            if (rig.atProven(s, i, .upper) < 0x80) {
                const k: i64 = rig.rt(ascii_end(s, i));
                n += k - i;
                i = k;
            } else {
                i = rig.addProven(i, (rig.rt(rune_after(s, i))).size);
                n += 1;
            }
        }
    }
    return n;
}

pub const Block = @Vector(16, u8);

pub inline fn errors(__rig_in_cur: @Vector(16, u8), __rig_in_prev: @Vector(16, u8)) @Vector(16, u8) {
    const cur = rig.rt(__rig_in_cur);
    const prev = rig.rt(__rig_in_prev);
    const p1 = rig.lag(1, cur, prev);
    const pair = (rig.lookup(BY_FIRST_HIGH, rig.vecShr(p1, 4)) & rig.lookup(BY_FIRST_LOW, p1 & rig.rt(@as(@Vector(16, u8), @splat(0x0F))))) & rig.lookup(BY_SECOND_HIGH, rig.vecShr(cur, 4));
    const must = rig.mask((rig.vecSubSat(rig.lag(2, cur, prev), rig.rt(@as(@Vector(16, u8), @splat(@as(u8, 96))))) | rig.vecSubSat(rig.lag(3, cur, prev), rig.rt(@as(@Vector(16, u8), @splat(@as(u8, 112)))))) >= rig.rt(@as(@Vector(16, u8), @splat(0x80))));
    return rig.maskSelect(must, rig.rt(@as(@Vector(16, u8), @splat(TWO_CONTINUATIONS))), rig.rt(@as(@Vector(16, u8), @splat(0)))) ^ pair;
}

pub const TOO_SHORT: u8 = 0x01;

pub const TOO_LONG: u8 = 0x02;

pub const OVERLONG_3: u8 = 0x04;

pub const TOO_LARGE: u8 = 0x08;

pub const SURROGATE: u8 = 0x10;

pub const OVERLONG_2: u8 = 0x20;

pub const TOO_LARGE_1000: u8 = 0x40;

pub const OVERLONG_4: u8 = 0x40;

pub const TWO_CONTINUATIONS: u8 = 0x80;

pub const CARRY: u8 = 0x83;

pub var BY_FIRST_HIGH: @Vector(16, u8) = rig.rt(@as(@Vector(16, u8), [_]u8{ 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x80, 0x80, 0x80, 0x80, 0x21, 0x01, 0x15, 0x49 }));

pub var BY_FIRST_LOW: @Vector(16, u8) = rig.rt(@as(@Vector(16, u8), [_]u8{ 0xE7, 0xA3, 0x83, 0x83, 0x8B, 0xCB, 0xCB, 0xCB, 0xCB, 0xCB, 0xCB, 0xCB, 0xCB, 0xDB, 0xCB, 0xCB }));

pub var BY_SECOND_HIGH: @Vector(16, u8) = rig.rt(@as(@Vector(16, u8), [_]u8{ 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xE6, 0xAE, 0xBA, 0xBA, 0x01, 0x01, 0x01, 0x01 }));

pub var ENDS: @Vector(16, u8) = rig.rt(@as(@Vector(16, u8), [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF, 0xDF, 0xBF }));

pub inline fn starts(__rig_in_v: @Vector(16, u8)) @Vector(16, u8) {
    const v = rig.rt(__rig_in_v);
    return rig.maskSelect(rig.maskOr(rig.mask(v < rig.rt(@as(@Vector(16, u8), @splat(0x80)))), rig.mask(v >= rig.rt(@as(@Vector(16, u8), @splat(0xC0))))), rig.rt(@as(@Vector(16, u8), @splat(1))), rig.rt(@as(@Vector(16, u8), @splat(0))));
}

pub inline fn lanes_sum(__rig_in_v: @Vector(16, u8)) i64 {
    const v = rig.rt(__rig_in_v);
    var n: i64 = 0;
    for (@as([16]u8, v)) |x| {
        { const __rig_new_27: i64 = @as(i64, @intCast(@as(u8, x))); n += __rig_new_27; }
    }
    return n;
}

pub inline fn is_valid(__rig_in_s: []const u8) bool {
    const s = rig.rt(__rig_in_s);
    var i: i64 = 0;
    while (true) {
        if (!(i < rig.lenOf(s))) break;
        {
            if (rig.atProven(s, i, .upper) < 0x80) {
                { const __rig_new_31: i64 = rig.rt(ascii_end(s, i)); i = __rig_new_31; }
            } else {
                const n: i64 = (rig.rt(rune_after(s, i))).size;
                if (n == 1) {
                    return false;
                }
                i += n;
            }
        }
    }
    return true;
}

pub inline fn is_ascii(__rig_in_s: []const u8) bool {
    const s = rig.rt(__rig_in_s);
    var i: i64 = 0;
    while (true) {
        if (!((i + 8) <= rig.lenOf(s))) break;
        {
            if ((rig.readIntProven(u64, s, i, .little, .both) & 0x8080808080808080) != 0) {
                return false;
            }
            i = rig.addProven(i, 8);
        }
    }
    while (true) {
        if (!(i < rig.lenOf(s))) break;
        {
            if (rig.atProven(s, i, .both) >= 0x80) {
                return false;
            }
            i = rig.addProven(i, 1);
        }
    }
    return true;
}

pub const Decoder = struct {
    state: i64,
    acc: i64,
    retry: bool,
    pub const __rig_name = .{ .module = "std.utf8", .name = .{ "Decoder" } };

    pub inline fn new() Decoder {
        return Decoder{ .state = 0, .acc = 0, .retry = false };
    }

    pub inline fn pending(__rig_in_self: *const Decoder) bool {
        const self = rig.rt(__rig_in_self);
        return self.state != 0;
    }

    pub inline fn next(__rig_in_self: *Decoder, __rig_in_b: u8) ?i64 {
        const self = rig.rt(__rig_in_self);
        const b = rig.rt(__rig_in_b);
        const class: i64 = @as(i64, @intCast(@as(u8, CLASS[rig.index(b, 256)])));
        const first: bool = self.state == 0;
        if (first) {
            { const __rig_new_38: i64 = (@as(i64, 0xFF) >> @intCast(@as(u64, @intCast(class)))) & @as(i64, @intCast(@as(u8, b))); self.acc = __rig_new_38; }
        } else {
            { const __rig_new_39: i64 = @shlExact(@as(i64, self.acc), @intCast(6)) | @as(i64, @intCast(@as(u8, b & 0x3F))); self.acc = __rig_new_39; }
        }
        { const __rig_new_40: i64 = @as(i64, @intCast(@as(u8, STEP[rig.index(self.state + class, 108)]))); self.state = __rig_new_40; }
        self.retry = false;
        if (self.state == 0) {
            return self.acc;
        }
        if (self.state != REJECT) {
            return null;
        }
        self.state = 0;
        self.acc = 0;
        self.retry = !first;
        return REPLACEMENT;
    }
};

pub const REJECT: i64 = 12;

pub const CLASS: [256]u8 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 10, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 4, 3, 3, 11, 6, 6, 6, 5, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8 };

pub const STEP: [108]u8 = [_]u8{ 0, 12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 0, 12, 12, 12, 12, 12, 0, 12, 0, 12, 12, 12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12, 12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12, 12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12 };

pub inline fn ascii_end(__rig_in_s: []const u8, __rig_in_i: i64) i64 {
    const s = rig.rt(__rig_in_s);
    const i = rig.rt(__rig_in_i);
    if ((i >= 0) and (i <= rig.lenOf(s))) {
        if (rig.addProven(i, 16) <= rig.lenOf(s)) {
            const m: u128 = rig.readIntProven(u128, s, i, .little, .both) & HIGH128;
            if (m == 0) {
                return vector_end(s, rig.addProven(i, 16));
            }
            const low: u64 = @as(u64, @intCast(@as(u128, m & 0xFFFFFFFFFFFFFFFF)));
            if (low != 0) {
                return i + (@as(i64, @as(i64, @ctz(@as(u64, low)))) >> @intCast(3));
            }
            return rig.addProven(i, 8) + (@as(i64, @as(i64, @ctz(@as(u64, @as(u64, @intCast(@as(u128, @as(u128, m) >> @intCast(64)))))))) >> @intCast(3));
        }
        return short_end(s, i);
    }
    _ = rig.at(s, i);
    return rig.lenOf(s);
}

pub fn vector_end(s: []const u8, at: i64) i64 {
    @setEvalBranchQuota(rig.eval_quota);
    if (at >= 0) {
        var k: i64 = at;
        __rig_while_42: while (true) : ({ k = rig.addProven(k, 64); }) {
            if (!((k + 64) <= rig.lenOf(s))) break;
            {
                if (rig.maskAny(rig.mask(rig.simdReadProven(@Vector(64, u8), s, k, rig.Endian.little, .both) >= rig.rt(@as(@Vector(64, u8), @splat(0x80)))))) {
                    break :__rig_while_42;
                }
            }
        }
        while (true) : ({ k = rig.addProven(k, 16); }) {
            if (!((k + 16) <= rig.lenOf(s))) break;
            {
                if (rig.maskFirst(rig.mask(rig.simdReadProven(@Vector(16, u8), s, k, rig.Endian.little, .both) >= rig.rt(@as(@Vector(16, u8), @splat(0x80)))))) |j| {
                    return k + j;
                }
            }
        }
        if (k == rig.lenOf(s)) {
            return k;
        }
        const seen: i64 = (k + 16) - rig.lenOf(s);
        if (rig.maskFirst(rig.maskAnd(rig.mask(rig.simdRead(@Vector(16, u8), s, rig.lenOf(s) - 16, rig.Endian.little) >= rig.rt(@as(@Vector(16, u8), @splat(0x80)))), rig.mask(LANES >= rig.rt(@as(@Vector(16, u8), @splat(@as(u8, @intCast(@as(u64, @intCast(@as(i64, seen)))))))))))) |j| {
            return (k + j) - seen;
        }
    }
    return rig.lenOf(s);
}

pub fn short_end(s: []const u8, at: i64) i64 {
    @setEvalBranchQuota(rig.eval_quota);
    const n: i64 = rig.lenOf(s);
    var k: i64 = at;
    if (n >= 8) {
        if ((k + 8) <= n) {
            const m: u64 = rig.readIntProven(u64, s, k, .little, .upper) & HIGH;
            if (m != 0) {
                return k + (@as(i64, @as(i64, @ctz(@as(u64, m)))) >> @intCast(3));
            }
            k = rig.addProven(k, 8);
        }
        if (k >= n) {
            return n;
        }
        const m: u64 = @as(u64, rig.readInt(u64, s, n - 8, .little) & rig.rt(HIGH)) >> @intCast(@as(u64, @intCast(@shlExact(@as(i64, (k + 8) - n), @intCast(3)))));
        if (m != 0) {
            return k + (@as(i64, @as(i64, @ctz(@as(u64, m)))) >> @intCast(3));
        }
        return n;
    }
    if (k >= n) {
        return n;
    }
    var w: u64 = 0;
    if (n >= 4) {
        { const __rig_new_49: u64 = @as(u64, @intCast(@as(u32, rig.readInt(u32, s, 0, .little)))) | (@as(u64, @as(u64, @intCast(@as(u32, rig.readInt(u32, s, n - 4, .little))))) << @intCast(@as(u64, @intCast(@shlExact(@as(i64, n - 4), @intCast(3)))))); w = __rig_new_49; }
    } else {
        const h: i64 = @as(i64, n) >> @intCast(1);
        { const __rig_new_50: u64 = (@as(u64, @intCast(@as(u8, rig.at(s, 0)))) | (@as(u64, @as(u64, @intCast(@as(u8, rig.at(s, h))))) << @intCast(@as(u64, @intCast(@shlExact(@as(i64, h), @intCast(3))))))) | (@as(u64, @as(u64, @intCast(@as(u8, rig.at(s, n - 1))))) << @intCast(@as(u64, @intCast(@shlExact(@as(i64, n - 1), @intCast(3)))))); w = __rig_new_50; }
    }
    const m: u64 = @as(u64, w & rig.rt(HIGH)) >> @intCast(@as(u64, @intCast(@shlExact(@as(i64, k), @intCast(3)))));
    if (m != 0) {
        return k + (@as(i64, @as(i64, @ctz(@as(u64, m)))) >> @intCast(3));
    }
    return n;
}

pub const HIGH: u64 = 0x8080808080808080;

pub const HIGH128: u128 = 0x80808080808080808080808080808080;

pub var LANES: @Vector(16, u8) = rig.rt(@as(@Vector(16, u8), [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }));

pub inline fn size(__rig_in_r: i64) ?i64 {
    const r = rig.rt(__rig_in_r);
    if (((r < 0) or (r > 0x10FFFF)) or ((r >= 0xD800) and (r <= 0xDFFF))) {
        return null;
    }
    return ((1 - (@as(i64, 0x7F - r) >> @intCast(63))) - (@as(i64, 0x7FF - r) >> @intCast(63))) - (@as(i64, 0xFFFF - r) >> @intCast(63));
}

pub inline fn push_rune(__rig_in_out: *rig.String, __rig_in_r: i64) void {
    const out = rig.rt(__rig_in_out);
    const r = rig.rt(__rig_in_r);
    if ((r >= 0) and (r < 0x80)) {
        out.*.push(@as(u8, @intCast(@as(u64, @intCast(@as(i64, r))))));
    } else if (((r < 0) or (r > 0x10FFFF)) or ((r >= 0xD800) and (r <= 0xDFFF))) {
        rig.rt(push_multi(out, REPLACEMENT));
    } else {
        rig.rt(push_multi(out, r));
    }
}

pub inline fn push_multi(__rig_in_out: *rig.String, __rig_in_r: i64) void {
    const out = rig.rt(__rig_in_out);
    const r = rig.rt(__rig_in_r);
    if (r < 0x800) {
        out.*.pushInt(u16, @as(u16, @intCast(@as(u64, @intCast(@as(i64, (0xC080 | @shlExact(@as(i64, @as(i64, r) >> @intCast(6)), @intCast(8))) | (r & 0x3F)))))), .big);
    } else if (r < 0x10000) {
        out.*.pushInt(u16, @as(u16, @intCast(@as(u64, @intCast(@as(i64, (0xE080 | @shlExact(@as(i64, @as(i64, r) >> @intCast(12)), @intCast(8))) | ((@as(i64, r) >> @intCast(6)) & 0x3F)))))), .big);
        out.*.push(@as(u8, @intCast(@as(u64, @intCast(@as(i64, 0x80 | (r & 0x3F)))))));
    } else {
        out.*.pushInt(u32, @as(u32, @intCast(@as(u64, @intCast(@as(i64, (((0xF0808080 | @shlExact(@as(i64, @as(i64, r) >> @intCast(18)), @intCast(24))) | @shlExact(@as(i64, (@as(i64, r) >> @intCast(12)) & 0x3F), @intCast(16))) | @shlExact(@as(i64, (@as(i64, r) >> @intCast(6)) & 0x3F), @intCast(8))) | (r & 0x3F)))))), .big);
    }
}
