//! The chars of `std.text`: Unicode's extended grapheme clusters (UAX #29,
//! rules GB1 to GB13 and GB999), with the classes of `grapheme_tables.zig`.
//!
//! The text is UTF-8 read as Go reads it: a byte that starts no
//! well-formed sequence is one U+FFFD of one byte. So every byte is in
//! exactly one rune and one char, and the chars of a text tile it.
//!
//! Forward, a char's end is found with the rules' state carried along
//! (`State`, run as the table `Dfa` built from it); backward,
//! `isBoundary` decides one position by the rules as UAX #29 writes them,
//! looking left only as far as GB9c, GB11, GB12, and GB13 need. Both are checked against Unicode's GraphemeBreakTest.txt
//! (test/behavior/std/text_chars_conformance.rig) and against each other
//! (the tests below). Text where an ASCII byte follows an ASCII byte breaks
//! between them unless they are CR LF, so a run of ASCII is counted 32
//! bytes at a time.
//!
//! Every safety check stays on. Where one would cost in a hot loop, the
//! code is shaped so the compiler proves it: each table is as long as the
//! range of the type that indexes it, and a rune's bytes are read through
//! one slice whose length test covers them.

const std = @import("std");
const tables = @import("grapheme_tables.zig");
const Class = tables.Class;

// ---- The text tools --------------------------------------------------------

/// How many chars `s` holds.
pub fn char_count(s: []const u8) i64 {
    return @intCast(walk(s, std.math.maxInt(usize)).count);
}

/// The byte where the char that starts at byte `i` of `s` ends; `i` is a
/// char boundary below `s.len`.
pub fn char_end(s: []const u8, i: i64) i64 {
    return @intCast(charEnd(s, @intCast(i)));
}

/// The bytes the first `n` chars of `s` take: all of `s` if it has fewer.
pub fn first_chars_end(s: []const u8, n: i64) i64 {
    if (n < 0) @panic("text.first_chars: the count is negative");
    return @intCast(walk(s, @intCast(n)).end);
}

/// Where the last `n` chars of `s` start: 0 if it has fewer.
pub fn last_chars_start(s: []const u8, n: i64) i64 {
    if (n < 0) @panic("text.last_chars: the count is negative");
    var back: Back = .{};
    var at = s.len;
    var k: i64 = 0;
    while (k < n and at > 0) : (k += 1) at = back.prevBoundary(s, at);
    return @intCast(at);
}

/// The char boundary at or before byte `i`, `0 <= i <= s.len`.
pub fn char_boundary(s: []const u8, i: i64) i64 {
    if (i < 0 or i > s.len) @panic("text.char_boundary: the index is out of bounds");
    const at: usize = @intCast(i);
    if (at == 0 or at == s.len) return i;
    var back: Back = .{};
    var j = runeStartAtOrBefore(s, at);
    while (j > 0 and !back.isBoundary(s, j)) j -= runeBefore(s, j).len;
    return @intCast(j);
}

// ---- Runes -----------------------------------------------------------------

const Rune = struct { cp: u21, len: u3 };
const bad: Rune = .{ .cp = 0xFFFD, .len = 1 };

inline fn isCont(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// The rune that starts at byte `i < s.len`, as Go's `DecodeRune` reads it.
fn decode(s: []const u8, i: usize) Rune {
    // One bounds check a rune: `t` is the text from `i`, and every byte
    // read after the first follows a test of `t.len` that covers it.
    const t = s[i..];
    const b0 = t[0];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    if (b0 < 0xC2) return bad;
    if (b0 < 0xE0) {
        if (t.len < 2 or !isCont(t[1])) return bad;
        return .{ .cp = @as(u21, b0 & 0x1F) << 6 | (t[1] & 0x3F), .len = 2 };
    }
    if (b0 < 0xF0) {
        if (t.len < 3) return bad;
        const b1 = t[1];
        const lo: u8 = if (b0 == 0xE0) 0xA0 else 0x80;
        const hi: u8 = if (b0 == 0xED) 0x9F else 0xBF;
        if (b1 < lo or b1 > hi or !isCont(t[2])) return bad;
        return .{ .cp = @as(u21, b0 & 0x0F) << 12 | @as(u21, b1 & 0x3F) << 6 | (t[2] & 0x3F), .len = 3 };
    }
    if (b0 < 0xF5) {
        if (t.len < 4) return bad;
        const b1 = t[1];
        const lo: u8 = if (b0 == 0xF0) 0x90 else 0x80;
        const hi: u8 = if (b0 == 0xF4) 0x8F else 0xBF;
        if (b1 < lo or b1 > hi or !isCont(t[2]) or !isCont(t[3])) return bad;
        return .{ .cp = @as(u21, b0 & 0x07) << 18 | @as(u21, b1 & 0x3F) << 12 | @as(u21, t[2] & 0x3F) << 6 | (t[3] & 0x3F), .len = 4 };
    }
    return bad;
}

/// The rune that ends at byte `i > 0`, a rune boundary, as Go's
/// `DecodeLastRune` reads `s[0..i]`: the rune that starts at the nearest
/// byte, at most four back, that is not a continuation byte, if it ends
/// at `i`; else the byte before `i`, alone. It is the rune a forward read
/// ends at `i` with, since only a well-formed sequence holds more than one
/// byte and it holds one byte that is not a continuation.
fn runeBefore(s: []const u8, i: usize) Rune {
    if (s[i - 1] < 0x80) return .{ .cp = s[i - 1], .len = 1 };
    const lim = i -| 4;
    var j = i - 1;
    while (j > lim and isCont(s[j])) j -= 1;
    const r = decode(s[0..i], j);
    return if (j + r.len == i) r else bad;
}

/// The rune boundary at or before byte `i <= s.len`: the start of the
/// well-formed sequence `i` is inside, else `i`.
fn runeStartAtOrBefore(s: []const u8, i: usize) usize {
    if (i == s.len or !isCont(s[i])) return i;
    const lim = i -| 3;
    var j = i;
    while (j > lim) {
        j -= 1;
        if (!isCont(s[j])) {
            const r = decode(s, j);
            return if (j + r.len > i) j else i;
        }
    }
    return i;
}

// ---- The rules ---------------------------------------------------------------

/// What the rules decide between two runes of the given classes: a break,
/// no break, or no break when the text before matches GB9c, GB11, or
/// GB12 and GB13.
const Pair = enum(u8) { split, join, conjunct, emoji, flag };

fn rule(p: Class, c: Class) Pair {
    const pi = @intFromEnum(p);
    const ci = @intFromEnum(c);
    if (p == .cr and c == .lf) return .join; // GB3
    if (pi >= @intFromEnum(Class.control) or ci >= @intFromEnum(Class.control)) return .split; // GB4, GB5
    if (p == .l and (c == .l or c == .v or c == .lv or c == .lvt)) return .join; // GB6
    if ((p == .lv or p == .v) and (c == .v or c == .t)) return .join; // GB7
    if ((p == .lvt or p == .t) and c == .t) return .join; // GB8
    if (ci >= @intFromEnum(Class.extend) and ci <= @intFromEnum(Class.zwj)) return .join; // GB9
    if (c == .spacing_mark or p == .prepend) return .join; // GB9a, GB9b
    if (c == .consonant and inConjunct(p)) return .conjunct; // GB9c
    if (p == .zwj and c == .pict) return .emoji; // GB11
    if (p == .ri and c == .ri) return .flag; // GB12, GB13
    return .split; // GB999
}

const n_classes = @typeInfo(Class).@"enum".field_names.len;
/// A class's number, a `u5`, indexes 32 entries, so no lookup by it needs
/// a bounds check; the entries past the classes are never read.
const class_range = 32;
const pairs: [class_range][class_range]Pair = blk: {
    var t: [class_range][class_range]Pair = @splat(@splat(.split));
    for (0..n_classes) |p| {
        for (0..n_classes) |c| t[p][c] = rule(@enumFromInt(p), @enumFromInt(c));
    }
    break :blk t;
};

/// The Extend of GB11: Grapheme_Cluster_Break Extend.
inline fn isExtend(c: Class) bool {
    return c == .extend or c == .incb_extend or c == .linker;
}

/// What GB9c lets stand between two consonants: InCB Extend (ZWJ among
/// them) and InCB Linker.
inline fn inConjunct(c: Class) bool {
    return c == .incb_extend or c == .linker or c == .zwj;
}

/// What the rules need to know of the text before a position, read
/// forward: the class of the rune before it and the runs GB9c, GB11, and
/// GB12 and GB13 test.
const State = struct {
    prev: Class,
    /// The runes before end with an odd run of regional indicators.
    odd_flags: bool = false,
    /// 1: they end with Extended_Pictographic Extend*; 2: with that and ZWJ.
    emoji: u2 = 0,
    /// 1: they end with an InCB Consonant and InCB Extend or Linker after
    /// it; 2: with a Linker among those.
    conjunct: u2 = 0,

    /// The state after a char starts with a rune of class `c`, whatever
    /// came before: a char boundary hides the text before it from every rule.
    fn start(c: Class) State {
        var st: State = .{ .prev = .control };
        st.add(c);
        return st;
    }

    fn add(st: *State, c: Class) void {
        st.odd_flags = c == .ri and !(st.prev == .ri and st.odd_flags);
        st.emoji = switch (c) {
            .pict => 1,
            .extend, .incb_extend, .linker => if (st.emoji == 1) 1 else 0,
            .zwj => if (st.emoji == 1) 2 else 0,
            else => 0,
        };
        st.conjunct = switch (c) {
            .consonant => 1,
            .linker => if (st.conjunct != 0) 2 else 0,
            .incb_extend, .zwj => st.conjunct,
            else => 0,
        };
        st.prev = c;
    }

    /// Whether a rune of class `c` starts a char, and then reads it.
    inline fn breaksBefore(st: *State, c: Class) bool {
        const split = switch (pairs[@intFromEnum(st.prev)][@intFromEnum(c)]) {
            .split => true,
            .join => false,
            .conjunct => st.conjunct != 2,
            .emoji => st.emoji != 2,
            .flag => !st.odd_flags,
        };
        st.add(c);
        return split;
    }
};

// ---- Forward ---------------------------------------------------------------

/// `State` as a table, built from it at compile time: each state the
/// text can reach is a number, and `next[n][c]` is the state after a rune
/// of class `c`, with bit 7 set when that rune starts a char. `start[c]`
/// is the state after a char starts with class `c`, and so the state
/// after an ASCII byte, whose class carries nothing further. A state's
/// number is below 64, so `step` indexes `next` by a `u6`, and no lookup
/// needs a bounds check.
const Dfa = struct {
    next: [max_states][class_range]u8,
    start: [class_range]u8,

    const max_states = 64;
    const split: u8 = 0x80;

    fn build() Dfa {
        @setEvalBranchQuota(100_000);
        var d: Dfa = .{ .next = @splat(@splat(0)), .start = @splat(0) };
        var states: [max_states]State = undefined;
        var n: usize = 0;
        for (0..n_classes) |c| d.start[c] = index(&states, &n, State.start(@enumFromInt(c)));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            for (0..n_classes) |c| {
                var st = states[i];
                const brk = st.breaksBefore(@enumFromInt(c));
                d.next[i][c] = index(&states, &n, st) | if (brk) split else 0;
            }
        }
        return d;
    }

    fn index(states: *[max_states]State, n: *usize, st: State) u8 {
        for (states[0..n.*], 0..) |known, k| {
            if (known.prev == st.prev and known.odd_flags == st.odd_flags and
                known.emoji == st.emoji and known.conjunct == st.conjunct) return k;
        }
        if (n.* == max_states) @compileError("more grapheme states than Dfa.max_states");
        states[n.*] = st;
        n.* += 1;
        return n.* - 1;
    }
};

const dfa = Dfa.build();

/// The state after a rune of class `c`, from state `st` (its bit 7 aside).
inline fn step(st: u8, c: Class) u8 {
    return dfa.next[@as(u6, @truncate(st))][@intFromEnum(c)];
}

/// The end of the char that starts at the char boundary `i < s.len`.
fn charEnd(s: []const u8, i: usize) usize {
    const b = s[i];
    if (b < 0x80) {
        if (i + 1 == s.len) return s.len;
        const n = s[i + 1];
        if (n < 0x80) return if (b == '\r' and n == '\n') i + 2 else i + 1;
    }
    var r = decode(s, i);
    var st = dfa.start[@intFromEnum(tables.of(r.cp))];
    var j = i + r.len;
    while (j < s.len) : (j += r.len) {
        r = decode(s, j);
        st = step(st, tables.of(r.cp));
        if (st & Dfa.split != 0) break;
    }
    return j;
}

const Walk = struct { count: usize, end: usize };
const lanes = 32;
const Lanes = @Vector(lanes, u8);
const Mask = @Int(.unsigned, lanes);

/// Reads the chars of `s` from its start, stopping where char `limit`
/// (counting from 0) starts: how many chars it read, and where it stopped.
fn walk(s: []const u8, limit: usize) Walk {
    var count: usize = 0;
    var i: usize = 0;
    // While `ascii`, the rune before `i` is ASCII (or `i` is 0) and `st` is
    // not kept: an ASCII byte at `i` starts a char unless it is LF after
    // CR. The start of the text acts as an ASCII control.
    var ascii = true;
    var after_cr = false;
    var st: u8 = undefined;
    while (i < s.len) {
        if (ascii and i > 0 and i + lanes <= s.len) {
            // Blocks of ASCII alone: each byte starts a char, but an LF
            // after a CR, which the block one byte back shows.
            while (i + lanes <= s.len) {
                const v: Lanes = s[i..][0..lanes].*;
                if (@reduce(.Max, v) >= 0x80) break;
                const back: Lanes = s[i - 1 ..][0..lanes].*;
                const joined = @intFromBool(v == @as(Lanes, @splat('\n'))) & @intFromBool(back == @as(Lanes, @splat('\r')));
                const starts = lanes - @as(usize, @reduce(.Add, @as(Lanes, joined)));
                if (count + starts > limit) break;
                count += starts;
                i += lanes;
            }
            after_cr = s[i - 1] == '\r';
            if (i == s.len) break;
        }
        if (ascii and i + lanes <= s.len) {
            // A block with ASCII before its first byte that is not: those
            // bytes alone.
            const rest = s[i..];
            const v: Lanes = rest[0..lanes].*;
            const high: Mask = @bitCast(v >= @as(Lanes, @splat(0x80)));
            const cr: Mask = @bitCast(v == @as(Lanes, @splat('\r')));
            // `k` is a `u6`, at most 32, so the shift and `rest[k - 1]`
            // below need no check.
            const k = @ctz(high);
            const prefix: Mask = @truncate((@as(u64, 1) << k) - 1);
            var starts: usize = k;
            if (after_cr or cr & prefix != 0) {
                const lf: Mask = @bitCast(v == @as(Lanes, @splat('\n')));
                starts -= @popCount(lf & (cr << 1 | @intFromBool(after_cr)) & prefix);
            }
            if (k > 0 and count + starts <= limit) {
                count += starts;
                i += k;
                after_cr = rest[k - 1] == '\r';
                continue;
            }
        }
        const b = s[i];
        if (ascii and b < 0x80) {
            if (!(after_cr and b == '\n')) {
                if (count == limit) return .{ .count = count, .end = i };
                count += 1;
            }
            after_cr = b == '\r';
            i += 1;
            continue;
        }
        if (ascii) st = dfa.start[@intFromEnum(if (i == 0) Class.control else tables.ascii(@intCast(s[i - 1])))];
        const r = decode(s, i);
        st = step(st, tables.of(r.cp));
        if (st & Dfa.split != 0) {
            if (count == limit) return .{ .count = count, .end = i };
            count += 1;
        }
        i += r.len;
        ascii = b < 0x80;
        after_cr = b == '\r';
    }
    return .{ .count = count, .end = s.len };
}

// ---- Backward --------------------------------------------------------------

/// Decides char boundaries by looking left. It remembers the last run of
/// regional indicators it counted, so stepping back through a long run
/// counts it once.
const Back = struct {
    flags_lo: usize = 0,
    flags_hi: usize = 0,

    /// Whether the rune boundary `i` (`0 < i < s.len`) is a char boundary.
    fn isBoundary(self: *Back, s: []const u8, i: usize) bool {
        const a = s[i - 1];
        const b = s[i];
        if (a < 0x80 and b < 0x80) return !(a == '\r' and b == '\n');
        const p = runeBefore(s, i);
        const pc = tables.of(p.cp);
        const cc = tables.of(decode(s, i).cp);
        return switch (pairs[@intFromEnum(pc)][@intFromEnum(cc)]) {
            .split => true,
            .join => false,
            .conjunct => !conjunctBefore(s, i),
            .emoji => !pictBefore(s, i - p.len),
            .flag => self.flagsBefore(s, i) % 2 == 0,
        };
    }

    /// The greatest char boundary below `i > 0`.
    fn prevBoundary(self: *Back, s: []const u8, i: usize) usize {
        var j = i - runeBefore(s, i).len;
        while (j > 0 and !self.isBoundary(s, j)) j -= runeBefore(s, j).len;
        return j;
    }

    /// How many regional indicators end at `i`. Each is four bytes (U+1F1E6
    /// to U+1F1FF).
    fn flagsBefore(self: *Back, s: []const u8, i: usize) usize {
        if (self.flags_lo <= i and i <= self.flags_hi and (i - self.flags_lo) % 4 == 0)
            return (i - self.flags_lo) / 4;
        var j = i;
        while (j > 0) {
            const r = runeBefore(s, j);
            if (tables.of(r.cp) != .ri) break;
            j -= r.len;
        }
        self.flags_lo = j;
        self.flags_hi = i;
        return (i - j) / 4;
    }
};

/// GB9c's left side ends at `i`: an InCB Consonant, then InCB Extend and
/// Linker with at least one Linker.
fn conjunctBefore(s: []const u8, i: usize) bool {
    var j = i;
    var linked = false;
    while (j > 0) {
        const r = runeBefore(s, j);
        const c = tables.of(r.cp);
        if (c == .consonant) return linked;
        if (!inConjunct(c)) return false;
        linked = linked or c == .linker;
        j -= r.len;
    }
    return false;
}

/// GB11's left side, but its ZWJ, ends at `i`: Extended_Pictographic, then
/// Extend.
fn pictBefore(s: []const u8, i: usize) bool {
    var j = i;
    while (j > 0) {
        const r = runeBefore(s, j);
        const c = tables.of(r.cp);
        if (c == .pict) return true;
        if (!isExtend(c)) return false;
        j -= r.len;
    }
    return false;
}

// ---- Tests -------------------------------------------------------------------
// `zig test std/grapheme.zig` (test/cli/grapheme_zig.sh): forward and
// backward agree on random text built from runes of every class and bytes
// that are not UTF-8.

const pool = [_][]const u8{
    "a",                "\r",           "\n",           "\x01",         "\u{301}",      "\u{200d}",
    "\u{1f1e6}",        "\u{1f1fa}",    "\u{600}",      "\u{903}",      "\u{1100}",     "\u{1161}",
    "\u{11a8}",         "\u{ac00}",     "\u{ac01}",     "\u{1f466}",    "\u{1f3fd}",    "\u{915}",
    "\u{94d}",          "\u{93c}",      "\u{e0020}",    "\u{ad}",       "\u{4e00}",     "\u{fffd}",
    "\xff",             "\xc3",         "\xe2\x82",     "\xed\xa0\x80", "\xf0\x9f",     "\x80",
    "\xf4\x90\x80\x80", "\xe0\x80\x80",
};

fn chars(s: []const u8, out: *std.ArrayList(usize), gpa: std.mem.Allocator) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < s.len) {
        try out.append(gpa, i);
        i = charEnd(s, i);
    }
}

test "forward and backward agree" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(29);
    const rand = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(gpa);
    for (0..20000) |round| {
        buf.clearRetainingCapacity();
        const n = rand.uintLessThan(usize, if (round % 10 == 0) 120 else 12);
        for (0..n) |_| try buf.appendSlice(gpa, pool[rand.uintLessThan(usize, pool.len)]);
        const s = buf.items;
        try chars(s, &starts, gpa);
        const count = starts.items.len;
        try std.testing.expectEqual(@as(i64, @intCast(count)), char_count(s));
        var k: usize = 0;
        for (0..s.len + 1) |i| {
            while (k + 1 < count and starts.items[k + 1] <= i) k += 1;
            const want: usize = if (i == s.len) s.len else starts.items[k];
            try std.testing.expectEqual(@as(i64, @intCast(want)), char_boundary(s, @intCast(i)));
        }
        for (0..count + 2) |m| {
            const first: usize = if (m < count) starts.items[m] else s.len;
            try std.testing.expectEqual(@as(i64, @intCast(first)), first_chars_end(s, @intCast(m)));
            const last: usize = if (m == 0) s.len else if (m <= count) starts.items[count - m] else 0;
            try std.testing.expectEqual(@as(i64, @intCast(last)), last_chars_start(s, @intCast(m)));
        }
    }
}

test "a long run of ASCII, with CR LF across the lanes" {
    var s: [200]u8 = undefined;
    for (&s, 0..) |*b, i| b.* = if (i % 31 == 30) '\r' else if (i % 31 == 0 and i > 0) '\n' else 'x';
    var n: i64 = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i = charEnd(&s, i);
    try std.testing.expectEqual(n, char_count(&s));
    try std.testing.expectEqual(@as(i64, 194), char_count(&s));
}

test "ASCII that ends the text at a block's end" {
    var buf: [200]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = if (i % 7 == 6) '\r' else if (i % 7 == 0) '\n' else 'y';
    for (0..buf.len + 1) |len| {
        for (0..4) |from| {
            if (from > len) continue;
            const s = buf[from..len];
            var starts: usize = 0;
            var i: usize = 0;
            while (i < s.len) : (starts += 1) i = charEnd(s, i);
            try std.testing.expectEqual(@as(i64, @intCast(starts)), char_count(s));
            for (0..starts + 2) |n| {
                var end: usize = 0;
                for (0..@min(n, starts)) |_| end = charEnd(s, end);
                try std.testing.expectEqual(@as(i64, @intCast(end)), first_chars_end(s, @intCast(n)));
            }
        }
    }
}

test "runes read backward are the runes read forward" {
    var prng = std.Random.DefaultPrng.init(11);
    const rand = prng.random();
    var s: [64]u8 = undefined;
    var ends: [65]bool = undefined;
    for (0..20000) |_| {
        for (&s) |*b| b.* = switch (rand.uintLessThan(u8, 4)) {
            0 => rand.int(u8),
            1 => 0x80 | rand.uintLessThan(u8, 0x40),
            2 => 0xE0 | rand.uintLessThan(u8, 0x15),
            else => rand.uintLessThan(u8, 0x80),
        };
        @memset(&ends, false);
        var i: usize = 0;
        while (i < s.len) : (i += decode(&s, i).len) ends[i] = true;
        ends[s.len] = true;
        for (1..s.len + 1) |e| {
            if (!ends[e]) continue;
            const r = runeBefore(&s, e);
            try std.testing.expect(ends[e - r.len]);
            try std.testing.expectEqual(decode(&s, e - r.len), r);
        }
        for (0..s.len + 1) |e| {
            const j = runeStartAtOrBefore(&s, e);
            try std.testing.expect(ends[j]);
            var k = j + 1;
            while (k <= e) : (k += 1) try std.testing.expect(!ends[k]);
        }
    }
}
