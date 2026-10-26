//! replay.zig: replays a Map trace that a program built with
//! RIG_MAP_TRACE=1 wrote (docs/internals/INTERNALS.md, "The Map trace")
//! against two designs of the built-in Map and Set:
//!
//!   today  a copy of std/__rig_builtin.rig as emitted: dense entries
//!          `Entry{key, value: V?}`, hashes beside them for keys over 8
//!          bytes, a small path of 8 entries, and a table of one tag byte
//!          and one U32 a slot, probed one tag at a time, grown when the
//!          next entry would pass 4/5 full to a size at most 2/5 full.
//!   cand   the map-stage candidate (design.md, Candidate 2): up to 8
//!          entries a dense small path that compares keys of 16 bytes or
//!          fewer with no hash; then packed slots `Entry{key, value: V?}`
//!          where the hash puts them, Swiss control bytes (0 free, 0x01
//!          taken, top 7 hash bits | 0x80 full) probed 16 at a time with
//!          15 mirrored bytes, at most 7/8 full counting taken slots,
//!          doubled (or rebuilt at its size when half its full bytes are
//!          taken), and the order kept as a List of U32 slot numbers. A
//!          free slot holds a default key and `none`; a rebuild fills the
//!          control bytes in one memset and rehashes each key (no stored
//!          hash), as design.md's §4 layout has it.
//!
//! The variants (`Design`): `today_nf` is today's layout with the `V?`
//! flag moved to a bitset; `cand_nf` the candidate with presence in the
//! control byte alone; `_sh` keeps the hash in the slot; `_ph` is given
//! each hash (the bound on a whole hash); `cand2` and `cand_nf2` add the
//! two fixes the first replay called for (a first table of 32 slots and a
//! rebuild in memory order, `CandCfg.tuned`); `cand_nf3` also keeps a small
//! table through `clear`; `dense2` keeps today's dense entries behind a
//! Swiss index (the bound that needs no free slots), and `dense2e` is it
//! rebuilt by walking the entries rather than the old index; `noop` is
//! the loop alone.
//!
//! The replayed K/V types (`shapes`) are plain data of at most 24 bytes
//! with entries of at most 32, so every replayed map is packed under the
//! candidate; no map needs Candidate 1's dense layout.
//!
//! Usage: replay TRACE DESIGN [--only SHAPE] [--pollute KB] [--mem]
//!        replay TRACE stats
//! It prints the user cycles and instructions of the replay itself
//! (perf_event_open on Linux), its time, the result checks, and the
//! designs' bytes at their peak; `--mem` adds the peak bytes of each
//! shape and of its three largest maps. build.sh builds it.

const std = @import("std");
const builtin = @import("builtin");
const ralloc = @import("alloc.zig");

const gpa = ralloc.allocator;

// ---------------------------------------------------------------------------
// Hashing, as src/runtime.zig's `rig.hash`
// ---------------------------------------------------------------------------

const hash_seed: u64 = 0x2d358dccaa6c78a5;
const hash_mul: u64 = 0x4b33a62ed433d4a3;

inline fn fold(x: u64) u64 {
    const p = @as(u128, x) * hash_mul;
    return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64));
}
inline fn hashWord(w: u64) u64 {
    return fold(w ^ hash_seed);
}
inline fn hashMix(h: u64, part: u64) u64 {
    return fold(h ^ part);
}

// ---------------------------------------------------------------------------
// Keys: the shapes Trig's maps use
// ---------------------------------------------------------------------------

/// A 4-byte integer key (`ast.Atom`, `Sym`, `TypeId`, `U32`).
const K4 = extern struct {
    v: u32 = 0,
    inline fn hash(k: K4) u64 {
        return hashWord(k.v);
    }
    inline fn eql(a: K4, b: K4) bool {
        return a.v == b.v;
    }
    fn from(b: *const [24]u8) K4 {
        return .{ .v = std.mem.readInt(u32, b[0..4], .little) };
    }
};

/// A signed 4-byte key (`I32`): hashed sign-extended.
const K4s = extern struct {
    v: i32 = 0,
    inline fn hash(k: K4s) u64 {
        return hashWord(@bitCast(@as(i64, k.v)));
    }
    inline fn eql(a: K4s, b: K4s) bool {
        return a.v == b.v;
    }
    fn from(b: *const [24]u8) K4s {
        return .{ .v = std.mem.readInt(i32, b[0..4], .little) };
    }
};

/// An 8-byte integer key (`Int`, `U64`).
const K8 = extern struct {
    v: u64 = 0,
    inline fn hash(k: K8) u64 {
        return hashWord(k.v);
    }
    inline fn eql(a: K8, b: K8) bool {
        return a.v == b.v;
    }
    fn from(b: *const [24]u8) K8 {
        return .{ .v = std.mem.readInt(u64, b[0..8], .little) };
    }
};

/// An object of two 4-byte words.
const K2x4 = extern struct {
    a: u32 = 0,
    b: u32 = 0,
    inline fn hash(k: K2x4) u64 {
        return hashMix(hashMix(hash_seed, hashWord(k.a)), hashWord(k.b));
    }
    inline fn eql(x: K2x4, y: K2x4) bool {
        return x.a == y.a and x.b == y.b;
    }
    fn from(b: *const [24]u8) K2x4 {
        return .{ .a = std.mem.readInt(u32, b[0..4], .little), .b = std.mem.readInt(u32, b[4..8], .little) };
    }
};

/// `CacheKey`: two U64 words.
const K16 = extern struct {
    lo: u64 = 0,
    hi: u64 = 0,
    inline fn hash(k: K16) u64 {
        return hashMix(hashMix(hash_seed, hashWord(k.lo)), hashWord(k.hi));
    }
    inline fn eql(a: K16, b: K16) bool {
        return a.lo == b.lo and a.hi == b.hi;
    }
    fn from(b: *const [24]u8) K16 {
        return .{ .lo = std.mem.readInt(u64, b[0..8], .little), .hi = std.mem.readInt(u64, b[8..16], .little) };
    }
};

/// `InstantiationKey`: a U64 owner and a `CacheKey`.
const K24 = extern struct {
    owner: u64 = 0,
    lo: u64 = 0,
    hi: u64 = 0,
    inline fn hash(k: K24) u64 {
        const inner = hashMix(hashMix(hash_seed, hashWord(k.lo)), hashWord(k.hi));
        return hashMix(hashMix(hash_seed, hashWord(k.owner)), inner);
    }
    inline fn eql(a: K24, b: K24) bool {
        return a.owner == b.owner and a.lo == b.lo and a.hi == b.hi;
    }
    fn from(b: *const [24]u8) K24 {
        return .{
            .owner = std.mem.readInt(u64, b[0..8], .little),
            .lo = std.mem.readInt(u64, b[8..16], .little),
            .hi = std.mem.readInt(u64, b[16..24], .little),
        };
    }
};

/// `InferenceKey`: three U32 words and two Bools, 14 bytes of parts.
const K14 = struct {
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    d: bool = false,
    e: bool = false,
    inline fn hash(k: K14) u64 {
        var h = hashMix(hash_seed, hashWord(k.a));
        h = hashMix(h, hashWord(k.b));
        h = hashMix(h, hashWord(k.c));
        h = hashMix(h, hashWord(@intFromBool(k.d)));
        return hashMix(h, hashWord(@intFromBool(k.e)));
    }
    inline fn eql(x: K14, y: K14) bool {
        return x.a == y.a and x.b == y.b and x.c == y.c and x.d == y.d and x.e == y.e;
    }
    fn from(b: *const [24]u8) K14 {
        return .{
            .a = std.mem.readInt(u32, b[0..4], .little),
            .b = std.mem.readInt(u32, b[4..8], .little),
            .c = std.mem.readInt(u32, b[8..12], .little),
            .d = b[12] != 0,
            .e = b[13] != 0,
        };
    }
};

const KeyClass = enum(u8) { k4, k4s, k8, k2x4, k14, k16, k24 };

fn KeyOf(comptime c: KeyClass) type {
    return switch (c) {
        .k4 => K4,
        .k4s => K4s,
        .k8 => K8,
        .k2x4 => K2x4,
        .k14 => K14,
        .k16 => K16,
        .k24 => K24,
    };
}

/// A value of `n` bytes aligned to `a`, as the Rig type it stands for.
fn Val(comptime n: usize, comptime a: usize) type {
    if (n == 0) return void;
    return switch (a) {
        8 => [n / 8]u64,
        4 => [n / 4]u32,
        else => [n]u8,
    };
}

fn valFrom(comptime V: type, x: u64) V {
    if (V == void) return {};
    var v: V = std.mem.zeroes(V);
    v[0] = @truncate(x);
    return v;
}

fn valWord(comptime V: type, v: *const V) u64 {
    if (V == void) return 1;
    return v[0];
}

// ---------------------------------------------------------------------------
// Memory: the designs' bytes, live and at their peak
// ---------------------------------------------------------------------------

var live_bytes: usize = 0;
var peak_bytes: usize = 0;

inline fn took(n: usize) void {
    live_bytes += n;
    if (live_bytes > peak_bytes) peak_bytes = live_bytes;
}
inline fn gave(n: usize) void {
    live_bytes -= n;
}

fn allocSlice(comptime T: type, n: usize) []T {
    if (n == 0) return &.{};
    const p = gpa.rawAlloc(@sizeOf(T) * n, .fromByteUnits(@alignOf(T)), @returnAddress()) orelse @panic("oom");
    took(@sizeOf(T) * n);
    return @as([*]T, @ptrCast(@alignCast(p)))[0..n];
}

fn freeSlice(comptime T: type, buf: []T) void {
    if (buf.len == 0) return;
    gave(@sizeOf(T) * buf.len);
    gpa.rawFree(std.mem.sliceAsBytes(buf), .fromByteUnits(@alignOf(T)), @returnAddress());
}

/// As runtime.zig's `reallocSlice`: remapped in place when the allocator
/// can, otherwise copied.
fn reallocSlice(comptime T: type, old: []T, n: usize) []T {
    if (old.len == 0) return allocSlice(T, n);
    const alignment: std.mem.Alignment = .fromByteUnits(@alignOf(T));
    const bytes = @sizeOf(T) * n;
    const old_bytes = std.mem.sliceAsBytes(old);
    gave(old_bytes.len);
    took(bytes);
    if (gpa.rawRemap(old_bytes, alignment, bytes, @returnAddress())) |p| return @as([*]T, @ptrCast(@alignCast(p)))[0..n];
    const p = gpa.rawAlloc(bytes, alignment, @returnAddress()) orelse @panic("oom");
    @memcpy(p[0..@min(bytes, old_bytes.len)], old_bytes[0..@min(bytes, old_bytes.len)]);
    gpa.rawFree(old_bytes, alignment, @returnAddress());
    return @as([*]T, @ptrCast(@alignCast(p)))[0..n];
}

/// Rig's List: a buffer and a length, growing to max(want, 4, 2 * cap).
fn List(comptime T: type) type {
    return struct {
        buf: []T = &.{},
        len: usize = 0,
        const Self = @This();

        inline fn items(self: *const Self) []T {
            return self.buf.ptr[0..self.len];
        }
        inline fn push(self: *Self, v: T) void {
            if (self.len == self.buf.len) self.grow(self.len + 1);
            self.buf.ptr[self.len] = v;
            self.len += 1;
        }
        noinline fn grow(self: *Self, want: usize) void {
            self.buf = reallocSlice(T, self.buf, @max(want, 4, self.buf.len * 2));
        }
        fn reserveTotal(self: *Self, want: usize) void {
            if (want > self.buf.len) self.grow(want);
        }
        fn filled(n: usize, v: T) Self {
            if (n == 0) return .{};
            const buf = allocSlice(T, n);
            @memset(buf, v);
            return .{ .buf = buf, .len = n };
        }
        fn withCapacity(n: usize) Self {
            return .{ .buf = allocSlice(T, n) };
        }
        fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buf[self.len];
        }
        fn free(self: *Self) void {
            freeSlice(T, self.buf);
            self.* = .{};
        }
        fn bytes(self: *const Self) usize {
            return self.buf.len * @sizeOf(T);
        }
    };
}

const SMALL = 8;

// ---------------------------------------------------------------------------
// Today's Map: std/__rig_builtin.rig
// ---------------------------------------------------------------------------

fn tagOf(h: u64) u8 {
    return @as(u8, @truncate(h >> 57)) | 0x80;
}

fn tableSize(want: usize, now: usize) usize {
    var n: usize = if (now < 16) 16 else now;
    while (want * 5 > n * 2) n *= 2;
    return n;
}

/// `flag` keeps today's `value: V?`; without it an entry is `key, value`
/// and a bitset beside the entries marks those taken, read only while
/// some are (`len < es.len`).
const TodayCfg = struct { flag: bool = true };

fn Today(comptime K: type, comptime V: type, comptime cfg: TodayCfg) type {
    return struct {
        const Self = @This();
        const stores_hashes = @sizeOf(K) > 8;
        const Entry = if (cfg.flag) struct { key: K, value: ?V } else struct { key: K, value: V };

        len: usize = 0,
        es: List(Entry) = .{},
        hs: List(u64) = .{},
        tags: List(u8) = .{},
        at: List(u32) = .{},
        /// Without `flag`: a bit per entry, set when it is taken.
        dead: if (cfg.flag) void else List(u64) = if (cfg.flag) {} else .{},

        inline fn live(self: *const Self, j: usize) bool {
            if (cfg.flag) return self.es.items()[j].value != null;
            if (self.len == self.es.len) return true;
            return (self.dead.items()[j >> 6] >> @intCast(j & 63)) & 1 == 0;
        }
        inline fn valPtr(self: *const Self, j: usize) *V {
            return if (cfg.flag) &(self.es.items()[j].value.?) else &self.es.items()[j].value;
        }

        fn find(self: *const Self, k: K, h: u64) ?usize {
            if (self.tags.len == 0) {
                if (stores_hashes) {
                    const hs = self.hs.items();
                    var j: usize = 0;
                    while (j < hs.len) : (j += 1) {
                        if (hs[j] == h and self.live(j)) {
                            if (self.es.items()[j].key.eql(k)) return j;
                        }
                    }
                } else {
                    const es = self.es.items();
                    var j: usize = 0;
                    while (j < es.len) : (j += 1) {
                        if (es[j].key.eql(k)) {
                            if (self.live(j)) return j;
                        }
                    }
                }
                return null;
            }
            const ts = self.tags.items();
            const tag = tagOf(h);
            var i: usize = @intCast(h & (ts.len - 1));
            for (0..2) |_| {
                while (i < ts.len) : (i += 1) {
                    const t = ts[i];
                    if (t == 0) return null;
                    if (t == tag) {
                        const j: usize = self.at.items()[i];
                        if (self.es.items()[j].key.eql(k)) return j;
                    }
                }
                i = 0;
            }
            return null;
        }

        inline fn get(self: *const Self, k: K, _: u64) ?*V {
            const h = k.hash();
            if (self.find(k, h)) |j| return self.valPtr(j);
            return null;
        }

        /// `replace`/`put`/`put_new`/`ensure`: whether `k` was there.
        inline fn put(self: *Self, k: K, v: V, _: u64) bool {
            const h = k.hash();
            if (self.find(k, h)) |j| {
                self.valPtr(j).* = v;
                return true;
            }
            self.addEntry(k, v, h);
            return false;
        }

        noinline fn addEntry(self: *Self, k: K, v: V, h: u64) void {
            self.insert(k, v, h);
        }

        fn insert(self: *Self, k: K, v: V, h: u64) void {
            if (self.tags.len == 0) {
                if (self.es.len >= SMALL) self.grow();
            } else if ((self.es.len + 1) * 5 > self.tags.len * 4) self.grow();
            self.es.push(.{ .key = k, .value = v });
            if (stores_hashes) self.hs.push(h);
            self.len += 1;
            if (self.tags.len > 0) self.place(self.es.len - 1, h);
        }

        inline fn place(self: *Self, j: usize, h: u64) void {
            const i = self.freeSlot(h);
            self.tags.items()[i] = tagOf(h);
            self.at.items()[i] = @intCast(j);
        }

        inline fn freeSlot(self: *const Self, h: u64) usize {
            const ts = self.tags.items();
            var i: usize = @intCast(h & (ts.len - 1));
            for (0..2) |_| {
                while (i < ts.len) : (i += 1) if (ts[i] == 0) return i;
                i = 0;
            }
            unreachable;
        }

        noinline fn grow(self: *Self) void {
            if (self.len < self.es.len) self.compact();
            if (self.tags.len == 0 and self.len < SMALL) return;
            self.rebuild(tableSize(self.len + 1, self.tags.len));
        }

        fn compact(self: *Self) void {
            var back = List(Entry).withCapacity(self.es.len);
            var back_hs = List(u64).withCapacity(self.es.len);
            while (self.es.len > 0) {
                const alive = self.live(self.es.len - 1);
                const e = self.es.pop().?;
                const h = self.hs.pop() orelse 0;
                if (alive) {
                    back.push(e);
                    back_hs.push(h);
                }
            }
            if (!cfg.flag) @memset(self.dead.items(), 0);
            while (back.pop()) |e| {
                self.es.push(e);
                const h = back_hs.pop() orelse 0;
                if (stores_hashes) self.hs.push(h);
            }
            back.free();
            back_hs.free();
        }

        fn rebuild(self: *Self, n: usize) void {
            if (self.len < self.es.len) self.compact();
            self.tags.free();
            self.at.free();
            self.tags = List(u8).filled(n, 0);
            self.at = List(u32).filled(n, 0);
            for (0..self.es.len) |j| self.place(j, self.hashAt(j));
        }

        inline fn hashAt(self: *const Self, j: usize) u64 {
            if (stores_hashes) return self.hs.items()[j];
            return self.es.items()[j].key.hash();
        }

        fn take(self: *Self, k: K, _: u64) bool {
            const h = k.hash();
            if (self.find(k, h)) |j| {
                if (!cfg.flag) {
                    const words = (self.es.buf.len + 63) / 64;
                    if (self.dead.len < words) {
                        while (self.dead.len < words) self.dead.push(0);
                    }
                    self.dead.items()[j >> 6] |= @as(u64, 1) << @intCast(j & 63);
                }
                self.len -= 1;
                if (self.tags.len > 0) self.unlink(j, h);
                if (cfg.flag) self.es.items()[j].value = null;
                return true;
            }
            return false;
        }

        fn unlink(self: *Self, j: usize, h: u64) void {
            const mask = self.tags.len - 1;
            const tags = self.tags.items();
            const at = self.at.items();
            var hole: usize = @intCast(h & mask);
            while (tags[hole] == 0 or at[hole] != j) hole = (hole + 1) & mask;
            var s = (hole + 1) & mask;
            while (tags[s] != 0) {
                const home: usize = @intCast(self.hashAt(at[s]) & mask);
                if (((s -% home) & mask) >= ((s -% hole) & mask)) {
                    tags[hole] = tags[s];
                    at[hole] = at[s];
                    hole = s;
                }
                s = (s + 1) & mask;
            }
            tags[hole] = 0;
        }

        fn clear(self: *Self) void {
            if (!cfg.flag) {
                if (self.len < self.es.len) @memset(self.dead.items(), 0);
            }
            self.es.len = 0;
            self.hs.len = 0;
            self.tags.len = 0;
            self.at.len = 0;
            self.len = 0;
        }

        fn reserve(self: *Self, n: usize) void {
            self.es.reserveTotal(self.es.len + n);
            if (stores_hashes) self.hs.reserveTotal(self.hs.len + n);
            const want = self.es.len + n;
            if (want > SMALL) {
                const size = tableSize(want, self.tags.len);
                if (size > self.tags.len) self.rebuild(size);
            }
        }

        /// A rebuild the trace recorded that no put of ours makes: a
        /// `reserve` or a `retain`, at `slots` slots.
        fn explicitRebuild(self: *Self, slots: usize) void {
            if (slots > self.tags.len) {
                self.es.reserveTotal(self.es.len + (slots * 2 / 5 -| self.es.len));
                self.rebuild(slots);
            } else if (self.tags.len > 0) self.rebuild(self.tags.len);
        }

        fn deinit(self: *Self) void {
            self.es.free();
            self.hs.free();
            self.tags.free();
            self.at.free();
            if (!cfg.flag) self.dead.free();
        }

        fn bytes(self: *const Self) usize {
            const d = if (cfg.flag) 0 else self.dead.bytes();
            return self.es.bytes() + self.hs.bytes() + self.tags.bytes() + self.at.bytes() + d;
        }
    };
}

// ---------------------------------------------------------------------------
// The candidate: packed slots behind Swiss control bytes
// ---------------------------------------------------------------------------

const GROUP = 16;
const TAKEN: u8 = 0x01;
const Group = @Vector(GROUP, u8);

inline fn groupAt(ctrl: []const u8, pos: usize) Group {
    return ctrl[pos..][0..GROUP].*;
}
inline fn matchBits(g: Group, b: u8) u16 {
    return @bitCast(g == @as(Group, @splat(b)));
}

/// How many of `n` slots may be full or taken: 7/8.
inline fn capacityOf(n: usize) usize {
    return n - n / 8;
}

/// The slots a table needs for `want` entries: a power of two, at least
/// 16, at most 7/8 full.
fn slotsFor(want: usize) usize {
    var n: usize = 16;
    while (capacityOf(n) < want) n *= 2;
    return n;
}

/// How a candidate is built: `flag` keeps design.md's `value: V?` in each
/// slot; without it a slot is `key, value` and the control byte alone says
/// whether it is full (in the small path every entry is live: a take
/// shifts the later ones down). `store_hash` keeps the hash in the slot
/// for keys over 8 bytes, so a rebuild hashes nothing. `prehash` takes
/// each operation's hash from the trace instead of hashing the key: the
/// bound on what a whole hash (a key that is already a hash) would save.
/// `tuned` adds what the first replay showed the candidate lacked: the
/// first table has 32 slots, not 16, and a rebuild walks the old slots in
/// memory order (recording where each went) rather than in insertion
/// order, which reads a large table's slots at random. `keep_clear` keeps a
/// table of at most 256 slots through `clear` (its control bytes zeroed),
/// so a pooled map that refills past the small path builds nothing.
const CandCfg = struct { flag: bool = true, store_hash: bool = false, prehash: bool = false, tuned: bool = false, keep_clear: bool = false };

fn Cand(comptime K: type, comptime V: type, comptime cfg: CandCfg) type {
    return struct {
        const Self = @This();
        const keep_hash = cfg.store_hash and @sizeOf(K) > 8;
        const Entry = if (cfg.flag)
            struct { key: K, value: ?V }
        else if (keep_hash)
            struct { key: K, value: V, h: u64 }
        else
            struct { key: K, value: V };
        const free_entry: Entry = if (cfg.flag)
            .{ .key = .{}, .value = null }
        else if (keep_hash)
            .{ .key = .{}, .value = std.mem.zeroes(V), .h = 0 }
        else
            .{ .key = .{}, .value = std.mem.zeroes(V) };
        /// Small keys are compared directly in the small path, unhashed.
        const direct = @sizeOf(K) <= 16;

        len: usize = 0,
        /// The small path's dense entries, or the table's slots.
        es: List(Entry) = .{},
        /// The small path's hashes, for keys over 16 bytes.
        hs: List(u64) = .{},
        /// The control bytes: `slots + 15` once the table is built, else empty.
        ctrl: List(u8) = .{},
        /// The order: the slot of each entry put in, in order.
        at: List(u32) = .{},
        /// Full and taken slots.
        used: usize = 0,
        /// The table's slots (a power of two), 0 in the small path.
        slots: usize = 0,

        inline fn live(e: *const Entry) bool {
            return if (cfg.flag) e.value != null else true;
        }
        inline fn valPtr(e: *Entry) *V {
            return if (cfg.flag) &(e.value.?) else &e.value;
        }
        inline fn make(k: K, v: V, h: u64) Entry {
            if (cfg.flag) return .{ .key = k, .value = v };
            if (keep_hash) return .{ .key = k, .value = v, .h = h };
            return .{ .key = k, .value = v };
        }
        inline fn hashOfEntry(e: *const Entry) u64 {
            if (keep_hash) return e.h;
            return e.key.hash();
        }
        inline fn hashKey(k: K, traced: u64) u64 {
            return if (cfg.prehash) traced else k.hash();
        }

        inline fn findSmall(self: *const Self, k: K, h: u64) ?usize {
            const es = self.es.items();
            if (direct) {
                var j: usize = 0;
                while (j < es.len) : (j += 1) {
                    if (es[j].key.eql(k)) {
                        if (live(&es[j])) return j;
                    }
                }
            } else {
                const hs = self.hs.items();
                var j: usize = 0;
                while (j < hs.len) : (j += 1) {
                    if (hs[j] == h and live(&es[j])) {
                        if (es[j].key.eql(k)) return j;
                    }
                }
            }
            return null;
        }

        inline fn findTable(self: *const Self, k: K, h: u64) ?usize {
            const ctrl = self.ctrl.items();
            const es = self.es.buf;
            const mask = self.slots - 1;
            const tag = tagOf(h);
            var pos: usize = @intCast(h & mask);
            while (true) {
                const g = groupAt(ctrl, pos);
                var m = matchBits(g, tag);
                while (m != 0) {
                    const s = (pos + @ctz(m)) & mask;
                    if (es[s].key.eql(k)) return s;
                    m &= m - 1;
                }
                if (matchBits(g, 0) != 0) return null;
                pos = (pos + GROUP) & mask;
            }
        }

        /// The entry of `k` (an index of `es`), hashing `k` only where the
        /// small path needs a hash.
        inline fn lookup(self: *const Self, k: K, traced: u64) ?usize {
            if (self.slots == 0) {
                if (direct) return self.findSmall(k, 0);
                return self.findSmall(k, hashKey(k, traced));
            }
            return self.findTable(k, hashKey(k, traced));
        }

        inline fn get(self: *const Self, k: K, traced: u64) ?*V {
            if (self.lookup(k, traced)) |j| return valPtr(&self.es.buf[j]);
            return null;
        }

        inline fn put(self: *Self, k: K, v: V, traced: u64) bool {
            if (self.slots == 0) {
                const h: u64 = if (direct) 0 else hashKey(k, traced);
                if (self.findSmall(k, h)) |j| {
                    valPtr(&self.es.buf[j]).* = v;
                    return true;
                }
                self.addSmall(k, v, h, traced);
                return false;
            }
            const h = hashKey(k, traced);
            if (self.findTable(k, h)) |s| {
                valPtr(&self.es.buf[s]).* = v;
                return true;
            }
            self.addTable(k, v, h);
            return false;
        }

        noinline fn addSmall(self: *Self, k: K, v: V, h: u64, traced: u64) void {
            if (cfg.flag and self.es.len >= SMALL and self.len < self.es.len) self.compactSmall();
            if (self.es.len < SMALL) {
                self.es.push(make(k, v, h));
                if (!direct) self.hs.push(h);
                self.len += 1;
                return;
            }
            self.buildTable(if (cfg.tuned) 32 else 16);
            self.insertTable(k, v, hashKey(k, traced));
        }

        noinline fn addTable(self: *Self, k: K, v: V, h: u64) void {
            self.insertTable(k, v, h);
        }

        inline fn insertTable(self: *Self, k: K, v: V, h: u64) void {
            if (self.used + 1 > capacityOf(self.slots)) self.grow();
            const s = self.freeSlot(h);
            self.setCtrl(s, tagOf(h));
            self.es.buf[s] = make(k, v, h);
            self.at.push(@intCast(s));
            self.used += 1;
            self.len += 1;
        }

        noinline fn grow(self: *Self) void {
            // Mostly taken slots: rebuild at the same size, else double.
            if (self.len + 1 <= capacityOf(self.slots) / 2) self.rebuild(self.slots) else self.rebuild(self.slots * 2);
        }

        inline fn freeSlot(self: *const Self, h: u64) usize {
            const ctrl = self.ctrl.items();
            const mask = self.slots - 1;
            var pos: usize = @intCast(h & mask);
            while (true) {
                const m = matchBits(groupAt(ctrl, pos), 0);
                if (m != 0) return (pos + @ctz(m)) & mask;
                pos = (pos + GROUP) & mask;
            }
        }

        inline fn setCtrl(self: *Self, s: usize, c: u8) void {
            const ctrl = self.ctrl.items();
            ctrl[s] = c;
            if (s < GROUP - 1) ctrl[self.slots + s] = c;
        }

        fn compactSmall(self: *Self) void {
            var w: usize = 0;
            const es = self.es.items();
            for (0..es.len) |j| {
                if (live(&es[j])) {
                    es[w] = es[j];
                    if (!direct) self.hs.items()[w] = self.hs.items()[j];
                    w += 1;
                }
            }
            self.es.len = w;
            if (!direct) self.hs.len = w;
        }

        /// The small path's entries, then hashes of each for the table:
        /// the stored ones for keys over 16 bytes, else each key hashed.
        fn buildTable(self: *Self, n: usize) void {
            var tmp: [SMALL]Entry = undefined;
            var tmp_h: [SMALL]u64 = undefined;
            var count: usize = 0;
            for (self.es.items(), 0..) |e, j| {
                if (live(&e)) {
                    tmp[count] = e;
                    tmp_h[count] = if (direct) e.key.hash() else self.hs.items()[j];
                    count += 1;
                }
            }
            if (self.es.buf.len < n) {
                self.es.free();
                self.es = List(Entry).withCapacity(n);
            }
            @memset(self.es.buf[0..n], free_entry);
            self.es.len = n;
            self.hs.len = 0;
            self.ctrl.reserveTotal(n + GROUP - 1);
            self.ctrl.len = n + GROUP - 1;
            @memset(self.ctrl.items(), 0);
            self.at.len = 0;
            self.at.reserveTotal(@max(count, 4));
            self.slots = n;
            self.used = 0;
            self.len = 0;
            for (tmp[0..count], tmp_h[0..count]) |*e, h| self.insertTable(e.key, valPtr(e).*, h);
        }

        /// The table built anew with `n` slots: the control bytes in one
        /// fill, each live entry moved in order, its key hashed again (or
        /// its hash read from the slot), and the order compacted.
        fn rebuild(self: *Self, n: usize) void {
            var ctrl = List(u8).filled(n + GROUP - 1, 0);
            var es = List(Entry).withCapacity(n);
            @memset(es.buf, free_entry);
            es.len = n;
            var at = List(u32).withCapacity(@max(self.len + 1, 4));
            const old_ctrl = self.ctrl.items();
            const old = self.es.buf;
            const mask = n - 1;
            if (cfg.tuned) {
                // The old slots in memory order, each live one's new slot
                // kept in `remap`; then the order rewritten through it.
                const remap = allocSlice(u32, self.slots);
                for (0..self.slots) |s| {
                    if (old_ctrl[s] < 0x80) continue;
                    const e = &old[s];
                    const h = hashOfEntry(e);
                    var pos: usize = @intCast(h & mask);
                    const slot = while (true) {
                        const m = matchBits(groupAt(ctrl.items(), pos), 0);
                        if (m != 0) break (pos + @ctz(m)) & mask;
                        pos = (pos + GROUP) & mask;
                    };
                    ctrl.items()[slot] = tagOf(h);
                    if (slot < GROUP - 1) ctrl.items()[n + slot] = tagOf(h);
                    es.buf[slot] = e.*;
                    remap[s] = @intCast(slot);
                }
                for (self.at.items()) |s| {
                    if (old_ctrl[s] >= 0x80) at.push(remap[s]);
                }
                freeSlice(u32, remap);
            } else {
                for (self.at.items()) |s| {
                    if (old_ctrl[s] < 0x80) continue;
                    const e = old[s];
                    const h = hashOfEntry(&e);
                    var pos: usize = @intCast(h & mask);
                    const slot = while (true) {
                        const m = matchBits(groupAt(ctrl.items(), pos), 0);
                        if (m != 0) break (pos + @ctz(m)) & mask;
                        pos = (pos + GROUP) & mask;
                    };
                    ctrl.items()[slot] = tagOf(h);
                    if (slot < GROUP - 1) ctrl.items()[n + slot] = tagOf(h);
                    es.buf[slot] = e;
                    at.push(@intCast(slot));
                }
            }
            self.ctrl.free();
            self.es.free();
            self.at.free();
            self.ctrl = ctrl;
            self.es = es;
            self.at = at;
            self.slots = n;
            self.used = self.len;
        }

        fn take(self: *Self, k: K, traced: u64) bool {
            if (self.lookup(k, traced)) |j| {
                self.len -= 1;
                if (self.slots > 0) {
                    if (cfg.flag) self.es.buf[j].value = null;
                    self.setCtrl(j, TAKEN);
                } else if (cfg.flag) {
                    self.es.buf[j].value = null;
                } else {
                    // No flag: the later entries move down, in order.
                    const es = self.es.items();
                    std.mem.copyForwards(Entry, es[j .. es.len - 1], es[j + 1 ..]);
                    self.es.len -= 1;
                    if (!direct) {
                        const hs = self.hs.items();
                        std.mem.copyForwards(u64, hs[j .. hs.len - 1], hs[j + 1 ..]);
                        self.hs.len -= 1;
                    }
                }
                return true;
            }
            return false;
        }

        fn clear(self: *Self) void {
            if (cfg.keep_clear and self.slots > 0 and self.slots <= 256) {
                @memset(self.ctrl.items(), 0);
                self.at.len = 0;
                self.used = 0;
                self.len = 0;
                return;
            }
            self.es.len = 0;
            self.hs.len = 0;
            self.ctrl.len = 0;
            self.at.len = 0;
            self.used = 0;
            self.slots = 0;
            self.len = 0;
        }

        fn reserve(self: *Self, n: usize) void {
            const want = self.len + n;
            if (want <= SMALL) return;
            const size = slotsFor(want);
            if (self.slots == 0) {
                self.buildTable(size);
            } else if (size > self.slots) self.rebuild(size);
        }

        /// The trace's `reserve` or `retain` rebuild at today's `slots`:
        /// room for the entries today's table holds at 2/5 full.
        fn explicitRebuild(self: *Self, slots: usize) void {
            self.reserve((slots * 2 / 5) -| self.len);
        }

        fn deinit(self: *Self) void {
            self.es.free();
            self.hs.free();
            self.ctrl.free();
            self.at.free();
        }

        fn bytes(self: *const Self) usize {
            return self.es.bytes() + self.hs.bytes() + self.ctrl.bytes() + self.at.bytes();
        }
    };
}

// ---------------------------------------------------------------------------
// dense2: today's dense entries behind a Swiss index
// ---------------------------------------------------------------------------

/// The slots a dense2 index needs for `want` entries: a power of two, at
/// least 32, at most 7/8 full.
fn slotsFor32(want: usize) usize {
    var n: usize = 32;
    while (capacityOf(n) < want) n *= 2;
    return n;
}

/// `walk_entries` rebuilds by walking the entries in order (as today
/// does) rather than the old index in memory order.
const Dense2Cfg = struct { walk_entries: bool = false };

/// Today's dense entries, exactly as today (`Entry{key, value: V?}`, the
/// hashes beside them for keys over 8 bytes, the same small path of 8
/// entries), with today's index replaced by Swiss control bytes (0 free,
/// 0x01 taken, top 7 hash bits | 0x80 full, 15 mirrored) probed 16 at a
/// time, a 4-byte entry number in each slot, at most 7/8 full counting
/// taken slots, doubled (or rebuilt at its size when half its full bytes
/// are taken), a first table of 32 slots, and a rebuild that walks the
/// old index in memory order with the control bytes written in one fill.
fn Dense2(comptime K: type, comptime V: type, comptime cfg: Dense2Cfg) type {
    return struct {
        const Self = @This();
        const stores_hashes = @sizeOf(K) > 8;
        const Entry = struct { key: K, value: ?V };

        len: usize = 0,
        es: List(Entry) = .{},
        hs: List(u64) = .{},
        /// `slots + 15` control bytes once the index is built, else empty.
        ctrl: List(u8) = .{},
        /// Each slot's entry number.
        at: List(u32) = .{},
        /// Full and taken slots.
        used: usize = 0,
        /// The index's slots (a power of two), 0 in the small path.
        slots: usize = 0,

        inline fn live(self: *const Self, j: usize) bool {
            return self.es.items()[j].value != null;
        }
        inline fn valPtr(self: *const Self, j: usize) *V {
            return &(self.es.items()[j].value.?);
        }
        inline fn hashAt(self: *const Self, j: usize) u64 {
            if (stores_hashes) return self.hs.items()[j];
            return self.es.items()[j].key.hash();
        }

        inline fn findSmall(self: *const Self, k: K, h: u64) ?usize {
            if (stores_hashes) {
                const hs = self.hs.items();
                var j: usize = 0;
                while (j < hs.len) : (j += 1) {
                    if (hs[j] == h and self.live(j)) {
                        if (self.es.items()[j].key.eql(k)) return j;
                    }
                }
            } else {
                const es = self.es.items();
                var j: usize = 0;
                while (j < es.len) : (j += 1) {
                    if (es[j].key.eql(k)) {
                        if (self.live(j)) return j;
                    }
                }
            }
            return null;
        }

        /// The slot whose entry holds `k`, or null.
        inline fn findSlot(self: *const Self, k: K, h: u64) ?usize {
            const ctrl = self.ctrl.items();
            const at = self.at.buf;
            const es = self.es.buf;
            const mask = self.slots - 1;
            const tag = tagOf(h);
            var pos: usize = @intCast(h & mask);
            while (true) {
                const g = groupAt(ctrl, pos);
                var m = matchBits(g, tag);
                while (m != 0) {
                    const s = (pos + @ctz(m)) & mask;
                    if (es[at[s]].key.eql(k)) return s;
                    m &= m - 1;
                }
                if (matchBits(g, 0) != 0) return null;
                pos = (pos + GROUP) & mask;
            }
        }

        inline fn find(self: *const Self, k: K, h: u64) ?usize {
            if (self.slots == 0) return self.findSmall(k, h);
            if (self.findSlot(k, h)) |s| return self.at.buf[s];
            return null;
        }

        inline fn get(self: *const Self, k: K, _: u64) ?*V {
            const h = k.hash();
            if (self.find(k, h)) |j| return self.valPtr(j);
            return null;
        }

        inline fn put(self: *Self, k: K, v: V, _: u64) bool {
            const h = k.hash();
            if (self.find(k, h)) |j| {
                self.valPtr(j).* = v;
                return true;
            }
            self.addEntry(k, v, h);
            return false;
        }

        noinline fn addEntry(self: *Self, k: K, v: V, h: u64) void {
            self.insert(k, v, h);
        }

        fn insert(self: *Self, k: K, v: V, h: u64) void {
            if (self.slots == 0) {
                if (self.es.len >= SMALL) self.grow();
            } else if (self.used + 1 > capacityOf(self.slots)) self.grow();
            self.es.push(.{ .key = k, .value = v });
            if (stores_hashes) self.hs.push(h);
            self.len += 1;
            if (self.slots > 0) self.place(self.es.len - 1, h);
        }

        inline fn setCtrl(self: *Self, s: usize, c: u8) void {
            const ctrl = self.ctrl.items();
            ctrl[s] = c;
            if (s < GROUP - 1) ctrl[self.slots + s] = c;
        }

        inline fn freeSlot(self: *const Self, h: u64) usize {
            const ctrl = self.ctrl.items();
            const mask = self.slots - 1;
            var pos: usize = @intCast(h & mask);
            while (true) {
                const m = matchBits(groupAt(ctrl, pos), 0);
                if (m != 0) return (pos + @ctz(m)) & mask;
                pos = (pos + GROUP) & mask;
            }
        }

        inline fn place(self: *Self, j: usize, h: u64) void {
            const s = self.freeSlot(h);
            self.setCtrl(s, tagOf(h));
            self.at.buf[s] = @intCast(j);
            self.used += 1;
        }

        noinline fn grow(self: *Self) void {
            if (self.slots == 0) {
                if (self.len < self.es.len) self.compact(null);
                if (self.len < SMALL) return;
                self.buildIndex(slotsFor32(self.len + 1));
                return;
            }
            if (self.len + 1 <= capacityOf(self.slots) / 2) self.rebuild(self.slots) else self.rebuild(self.slots * 2);
        }

        /// Drop the entries taken, keeping the rest in order, in place;
        /// `remap`, when given, gets each old entry's new number.
        fn compact(self: *Self, remap: ?[]u32) void {
            const es = self.es.items();
            var w: usize = 0;
            for (0..es.len) |j| {
                if (es[j].value != null) {
                    if (remap) |r| r[j] = @intCast(w);
                    es[w] = es[j];
                    if (stores_hashes) self.hs.items()[w] = self.hs.items()[j];
                    w += 1;
                }
            }
            self.es.len = w;
            if (stores_hashes) self.hs.len = w;
        }

        /// The first index, of `n` slots, from the small path's entries.
        fn buildIndex(self: *Self, n: usize) void {
            if (self.len < self.es.len) self.compact(null);
            self.ctrl.reserveTotal(n + GROUP - 1);
            self.ctrl.len = n + GROUP - 1;
            @memset(self.ctrl.items(), 0);
            self.at.reserveTotal(n);
            self.at.len = n;
            self.slots = n;
            self.used = 0;
            for (0..self.es.len) |j| self.place(j, self.hashAt(j));
        }

        /// The index built anew with `n` slots: the control bytes in one
        /// fill, then the old index walked in memory order, each full
        /// slot's entry placed again (renumbered if entries were taken).
        fn rebuild(self: *Self, n: usize) void {
            const old_ctrl = self.ctrl;
            const old_at = self.at;
            const old_slots = self.slots;
            var remap: []u32 = &.{};
            const compacted = self.len < self.es.len;
            if (compacted) {
                remap = allocSlice(u32, self.es.len);
                self.compact(remap);
            }
            self.ctrl = List(u8).filled(n + GROUP - 1, 0);
            self.at = List(u32).withCapacity(n);
            self.at.len = n;
            self.slots = n;
            self.used = 0;
            if (cfg.walk_entries) {
                for (0..self.es.len) |j| self.place(j, self.hashAt(j));
            } else {
                const oc = old_ctrl.items();
                const oa = old_at.items();
                for (0..old_slots) |s| {
                    if (oc[s] < 0x80) continue;
                    const j: usize = if (compacted) remap[oa[s]] else oa[s];
                    self.place(j, self.hashAt(j));
                }
            }
            if (compacted) freeSlice(u32, remap);
            var oc2 = old_ctrl;
            var oa2 = old_at;
            oc2.free();
            oa2.free();
        }

        fn take(self: *Self, k: K, _: u64) bool {
            const h = k.hash();
            if (self.slots == 0) {
                if (self.findSmall(k, h)) |j| {
                    self.len -= 1;
                    self.es.items()[j].value = null;
                    return true;
                }
                return false;
            }
            if (self.findSlot(k, h)) |s| {
                const j = self.at.buf[s];
                self.len -= 1;
                self.setCtrl(s, TAKEN);
                self.es.items()[j].value = null;
                return true;
            }
            return false;
        }

        fn clear(self: *Self) void {
            self.es.len = 0;
            self.hs.len = 0;
            self.ctrl.len = 0;
            self.at.len = 0;
            self.used = 0;
            self.slots = 0;
            self.len = 0;
        }

        fn reserve(self: *Self, n: usize) void {
            self.es.reserveTotal(self.es.len + n);
            if (stores_hashes) self.hs.reserveTotal(self.hs.len + n);
            const want = self.len + n;
            if (want <= SMALL) return;
            const size = slotsFor32(want);
            if (self.slots == 0) {
                self.buildIndex(size);
            } else if (size > self.slots) self.rebuild(size);
        }

        /// As the candidate's: room for the entries today's table holds
        /// at 2/5 full.
        fn explicitRebuild(self: *Self, slots: usize) void {
            self.reserve((slots * 2 / 5) -| self.len);
        }

        fn deinit(self: *Self) void {
            self.es.free();
            self.hs.free();
            self.ctrl.free();
            self.at.free();
        }

        fn bytes(self: *const Self) usize {
            return self.es.bytes() + self.hs.bytes() + self.ctrl.bytes() + self.at.bytes();
        }
    };
}

// ---------------------------------------------------------------------------
// The trace
// ---------------------------------------------------------------------------

const Rec = extern struct {
    op: u8,
    hit: u8,
    width: u16,
    id: u32,
    vbytes: u32,
    len: u32,
    hash: u64,
    key: [24]u8,
};
comptime {
    std.debug.assert(@sizeOf(Rec) == 48);
}

const OpKind = enum(u8) { get, put, remove, clear, new, drop, grow, retain };

/// One decoded operation, read before the clock starts.
const Op = extern struct {
    kind: OpKind,
    hit: u8,
    shape: u16,
    map: u32,
    /// A grow's slots, or a retain's length after it.
    aux: u64,
    key: [24]u8 align(8),
};

/// A key class and a value: one instantiation of each design, for the
/// maps whose K, V, and kind the trace's `.types` names.
const Shape = struct { k: KeyClass, v: usize, va: usize, set: bool, kname: []const u8, vname: []const u8 };

/// The shapes replayed: ts-pattern's ten busiest K/V types, 96% of its
/// lookups, puts, and takes.
const shapes = [_]Shape{
    .{ .k = .k16, .v = 4, .va = 4, .set = false, .kname = "checker.CacheKey", .vname = "U32" },
    .{ .k = .k4, .v = 4, .va = 4, .set = false, .kname = "U32", .vname = "U32" },
    .{ .k = .k24, .v = 4, .va = 4, .set = false, .kname = "checker.InstantiationKey", .vname = "U32" },
    .{ .k = .k2x4, .v = 4, .va = 4, .set = false, .kname = "checker.CachedTypeKey", .vname = "U32" },
    .{ .k = .k16, .v = 0, .va = 1, .set = true, .kname = "checker.CacheKey", .vname = "-" },
    .{ .k = .k8, .v = 0, .va = 1, .set = true, .kname = "U64", .vname = "-" },
    .{ .k = .k4, .v = 8, .va = 8, .set = false, .kname = "U32", .vname = "Int" },
    .{ .k = .k14, .v = 4, .va = 4, .set = false, .kname = "checker.InferenceKey", .vname = "I32" },
    .{ .k = .k4, .v = 0, .va = 1, .set = true, .kname = "U32", .vname = "-" },
    .{ .k = .k4, .v = 8, .va = 4, .set = false, .kname = "U32", .vname = "checker.MappedSymbolLinks" },
};

fn shapeByName(k: []const u8, v: []const u8, kind: []const u8) ?u16 {
    const set = std.mem.eql(u8, kind, "Set");
    for (shapes, 0..) |s, i| {
        if (s.set == set and std.mem.eql(u8, s.kname, k) and std.mem.eql(u8, s.vname, v)) return @intCast(i);
    }
    return null;
}

/// The designs replayed: today's Map, with and without its `V?` flag;
/// the candidate as design.md has it (`cand`), without the flag
/// (`cand_nf`), with the hash kept in the slot as well (`cand_nf_sh`),
/// and with each operation's hash given (`cand_nf_ph`, a bound).
const Design = enum { today, today_nf, cand, cand_nf, cand_nf_sh, cand_nf_ph, cand_nf2, cand_nf3, cand2, dense2, dense2e, noop, none };

/// A map that does nothing: the replay loop's own cost, decoding each
/// operation, building its key, and checking its result, which it reads
/// from the operation (`expect`), so it hashes nothing and mispredicts
/// nothing the designs would not.
fn Noop(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        len: usize = 0,
        v: V = std.mem.zeroes(V),
        inline fn get(self: *const Self, k: K, _: u64) ?*V {
            std.mem.doNotOptimizeAway(k);
            if (expect.*) return @constCast(&self.v);
            return null;
        }
        inline fn put(_: *Self, k: K, _: V, _: u64) bool {
            std.mem.doNotOptimizeAway(k);
            return expect.*;
        }
        inline fn take(_: *Self, k: K, _: u64) bool {
            std.mem.doNotOptimizeAway(k);
            return expect.*;
        }
        fn clear(_: *Self) void {}
        fn deinit(_: *Self) void {}
        fn explicitRebuild(_: *Self, _: usize) void {}
        fn bytes(_: *const Self) usize {
            return 0;
        }
    };
}

var expect_byte: bool = false;
const expect: *volatile bool = &expect_byte;

fn MapOf(comptime d: Design, comptime s: Shape) type {
    const K = KeyOf(s.k);
    const V = Val(s.v, s.va);
    return switch (d) {
        .today => Today(K, V, .{}),
        .today_nf => Today(K, V, .{ .flag = false }),
        .cand, .none => Cand(K, V, .{}),
        .cand_nf => Cand(K, V, .{ .flag = false }),
        .cand_nf_sh => Cand(K, V, .{ .flag = false, .store_hash = true }),
        .cand_nf_ph => Cand(K, V, .{ .flag = false, .prehash = true }),
        .cand_nf2 => Cand(K, V, .{ .flag = false, .tuned = true }),
        .cand_nf3 => Cand(K, V, .{ .flag = false, .tuned = true, .keep_clear = true }),
        .cand2 => Cand(K, V, .{ .tuned = true }),
        .dense2 => Dense2(K, V, .{}),
        .dense2e => Dense2(K, V, .{ .walk_entries = true }),
        .noop => Noop(K, V),
    };
}

/// The bytes of one Map's header in each design: today's `len` and four
/// Lists; the candidate's adds `used` and `slots`.
fn headerBytes(comptime d: Design) usize {
    return switch (d) {
        .today => 104,
        .today_nf => 104,
        else => 120,
    };
}

/// Every map of one shape, by its index in the shape.
fn Maps(comptime d: Design) type {
    var types: [shapes.len]type = undefined;
    for (shapes, 0..) |s, i| types[i] = []MapOf(d, s);
    return @Tuple(&types);
}

var sink: u64 = 0;
var live_maps: usize = 0;
var peak_maps: usize = 0;
var mismatches: u64 = 0;
var first_mismatch: ?usize = null;

fn noteMismatch(i: usize) void {
    mismatches += 1;
    if (first_mismatch == null) first_mismatch = i;
}

var shape_live: [shapes.len]isize = @splat(0);
var shape_peak: [shapes.len]isize = @splat(0);
var map_peak: [shapes.len][]usize = undefined;

fn run(comptime d: Design, comptime track: bool, ops: []const Op, counts: []const u32, pollute: []u64) void {
    var maps: Maps(d) = undefined;
    inline for (shapes, 0..) |s, si| {
        const M = MapOf(d, s);
        maps[si] = std.heap.page_allocator.alloc(M, counts[si]) catch @panic("oom");
        for (maps[si]) |*m| m.* = .{};
        if (track) {
            map_peak[si] = std.heap.page_allocator.alloc(usize, counts[si]) catch @panic("oom");
            @memset(map_peak[si], 0);
        }
    }
    var pi: usize = 0;
    for (ops, 0..) |*op, i| {
        if (pollute.len > 0) {
            // Read a line of a buffer larger than the caches, as the
            // checker's own work evicts the maps' lines.
            sink +%= pollute[pi];
            pi = (pi + 8 * 61) % pollute.len;
        }
        switch (op.shape) {
            inline 0...shapes.len - 1 => |si| {
                const s = shapes[si];
                const K = KeyOf(s.k);
                const V = Val(s.v, s.va);
                const m = &maps[si][op.map];
                const k = K.from(&op.key);
                if (d == .noop) expect.* = op.hit == 1;
                const before = if (track) live_bytes else 0;
                defer if (track) {
                    shape_live[si] += @as(isize, @intCast(live_bytes)) - @as(isize, @intCast(before));
                    if (shape_live[si] > shape_peak[si]) shape_peak[si] = shape_live[si];
                    const b = m.bytes();
                    if (b > map_peak[si][op.map]) map_peak[si][op.map] = b;
                };
                switch (op.kind) {
                    .get => {
                        const hit = if (m.get(k, op.aux)) |p| blk: {
                            sink +%= valWord(V, p);
                            break :blk true;
                        } else false;
                        if (@intFromBool(hit) != op.hit) noteMismatch(i);
                    },
                    .put => {
                        const hit = m.put(k, valFrom(V, i), op.aux);
                        if (@intFromBool(hit) != op.hit) noteMismatch(i);
                    },
                    .remove => {
                        const hit = m.take(k, op.aux);
                        if (@intFromBool(hit) != op.hit) noteMismatch(i);
                    },
                    .clear => m.clear(),
                    .new => {
                        m.* = .{};
                        live_maps += 1;
                        if (live_maps > peak_maps) peak_maps = live_maps;
                    },
                    .drop => {
                        m.deinit();
                        m.* = .{};
                        live_maps -|= 1;
                    },
                    .grow => m.explicitRebuild(@intCast(op.aux)),
                    .retain => {},
                }
            },
            else => unreachable,
        }
    }
    if (track) {
        for (shapes, 0..) |sh, si| {
            var top: [3]usize = @splat(0);
            for (map_peak[si]) |b| {
                if (b > top[2]) {
                    top[2] = b;
                    if (top[2] > top[1]) std.mem.swap(usize, &top[1], &top[2]);
                    if (top[1] > top[0]) std.mem.swap(usize, &top[0], &top[1]);
                }
            }
            std.debug.print("MEM shape={d} {s}{s}->{s} peak_bytes={d} top_map_peaks={d},{d},{d}\n", .{ si, if (sh.set) "Set:" else "", sh.kname, sh.vname, shape_peak[si], top[0], top[1], top[2] });
        }
    }
}

// ---------------------------------------------------------------------------
// Counters
// ---------------------------------------------------------------------------

const Counter = struct {
    fd: i32 = -1,
    fn open(config: u64) Counter {
        if (builtin.target.os.tag != .linux) return .{};
        const linux = std.os.linux;
        var attr = std.mem.zeroes(linux.perf_event_attr);
        attr.type = .HARDWARE;
        attr.config = config;
        attr.flags.disabled = true;
        attr.flags.exclude_kernel = true;
        attr.flags.exclude_hv = true;
        const rc = linux.perf_event_open(&attr, 0, -1, -1, 0);
        const fd: isize = @bitCast(rc);
        if (fd < 0) return .{};
        return .{ .fd = @intCast(fd) };
    }
    fn start(self: Counter) void {
        if (self.fd < 0) return;
        const linux = std.os.linux;
        _ = linux.ioctl(self.fd, linux.PERF.EVENT_IOC.RESET, 0);
        _ = linux.ioctl(self.fd, linux.PERF.EVENT_IOC.ENABLE, 0);
    }
    fn stop(self: Counter) u64 {
        if (self.fd < 0) return 0;
        const linux = std.os.linux;
        _ = linux.ioctl(self.fd, linux.PERF.EVENT_IOC.DISABLE, 0);
        var v: u64 = 0;
        _ = linux.read(self.fd, @ptrCast(&v), 8);
        return v;
    }
};

// ---------------------------------------------------------------------------
// Reading the trace
// ---------------------------------------------------------------------------

fn hashOf(c: KeyClass, key: *const [24]u8) u64 {
    return switch (c) {
        inline else => |cc| KeyOf(cc).from(key).hash(),
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: replay TRACE today|cand|none|stats [--pollute KB]\n", .{});
        std.process.exit(2);
    }
    const path = args[1];
    const mode = args[2];
    var pollute_kb: usize = 0;
    var only: ?u16 = null;
    var track = false;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--pollute")) {
            i += 1;
            pollute_kb = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--only")) {
            i += 1;
            only = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--mem")) {
            track = true;
        }
    }

    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, path, arena, .unlimited);
    const types_path = try std.mem.concat(arena, u8, &.{ path, ".types" });
    const types_text = try cwd.readFileAlloc(io, types_path, arena, .unlimited);

    // id -> (key type name, value type name, Map or Set)
    var names: std.AutoHashMapUnmanaged(u32, [3][]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, types_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const id = try std.fmt.parseInt(u32, f.next().?, 10);
        const k = f.next().?;
        const v = f.next().?;
        const kind = f.next().?;
        try names.put(arena, id, .{ k, v, kind });
    }

    const recs = std.mem.bytesAsSlice(Rec, data[0 .. data.len - data.len % 48]);
    // Per id: its shape and its index within the shape.
    var shape_of: std.AutoHashMapUnmanaged(u32, struct { shape: u16, index: u32 }) = .empty;
    var counts: [shapes.len]u32 = @splat(0);
    var unknown: std.StringHashMapUnmanaged(u64) = .empty;
    const ops = try arena.alloc(Op, recs.len);
    var n_ops: usize = 0;
    var hash_bad: u64 = 0;
    var skipped: u64 = 0;
    // The next record of each map, to tell a grow that a put makes from
    // a reserve.
    for (recs) |*r| {
        const kind: OpKind = @enumFromInt(r.op & 7);
        const nm = names.get(r.id) orelse [3][]const u8{ "?", "?", "?" };
        const gop = try shape_of.getOrPut(arena, r.id);
        if (!gop.found_existing) {
            const si: ?u16 = shapeByName(nm[0], nm[1], nm[2]);
            if (si) |s| {
                gop.value_ptr.* = .{ .shape = s, .index = counts[s] };
                counts[s] += 1;
            } else {
                gop.value_ptr.* = .{ .shape = std.math.maxInt(u16), .index = 0 };
                const label = try std.fmt.allocPrint(arena, "{s} {s} -> {s}", .{ nm[2], nm[0], nm[1] });
                const u = try unknown.getOrPut(arena, label);
                if (!u.found_existing) u.value_ptr.* = 0;
            }
        }
        const sh = gop.value_ptr.*;
        if (sh.shape == std.math.maxInt(u16)) {
            skipped += 1;
            continue;
        }
        if (kind == .retain) {
            skipped += 1;
            continue;
        }
        if (only) |o| if (sh.shape != o) continue;
        if (kind == .get or kind == .put or kind == .remove) {
            if (hashOf(shapes[sh.shape].k, &r.key) != r.hash) hash_bad += 1;
        }
        ops[n_ops] = .{
            .kind = kind,
            .hit = r.hit & 1,
            .shape = sh.shape,
            .map = sh.index,
            .aux = r.hash,
            .key = r.key,
        };
        n_ops += 1;
    }

    // A grow record that a put we replay makes itself is dropped: the
    // next record of its map is a put of a new key. Others (`reserve`,
    // `Map.new(capacity)`) stay, as explicit rebuilds.
    {
        var next_of: std.AutoHashMapUnmanaged(u64, usize) = .empty;
        const keep = try arena.alloc(bool, n_ops);
        @memset(keep, true);
        var j: usize = n_ops;
        while (j > 0) {
            j -= 1;
            const op = &ops[j];
            const key = (@as(u64, op.shape) << 32) | op.map;
            if (op.kind == .grow) {
                if (next_of.get(key)) |nx| {
                    const o = &ops[nx];
                    if (o.kind == .put and o.hit == 0) keep[j] = false;
                }
            }
            try next_of.put(arena, key, j);
        }
        var w: usize = 0;
        var dropped: usize = 0;
        for (0..n_ops) |x| {
            if (keep[x]) {
                ops[w] = ops[x];
                w += 1;
            } else dropped += 1;
        }
        std.debug.print("grow records made by puts: {d}; explicit rebuilds kept: ", .{dropped});
        var explicit: usize = 0;
        for (ops[0..w]) |op| explicit += @intFromBool(op.kind == .grow);
        std.debug.print("{d}\n", .{explicit});
        n_ops = w;
    }

    std.debug.print("{d} records, {d} ops replayed, {d} skipped, {d} hashes differ from the trace's\n", .{ recs.len, n_ops, skipped, hash_bad });
    var it = unknown.iterator();
    while (it.next()) |e| std.debug.print("  unreplayed shape: {s}\n", .{e.key_ptr.*});
    for (shapes, 0..) |s, si| {
        if (counts[si] > 0) std.debug.print("  shape {d}: {s} {s} -> {s}: {d} maps\n", .{ si, if (s.set) "Set" else "Map", s.kname, s.vname, counts[si] });
    }
    if (std.mem.eql(u8, mode, "stats")) return;

    const pollute = try std.heap.page_allocator.alloc(u64, pollute_kb * 1024 / 8);
    for (pollute, 0..) |*p, x| p.* = x;

    const cycles = Counter.open(@intFromEnum(std.os.linux.PERF.COUNT.HW.CPU_CYCLES));
    const instrs = Counter.open(@intFromEnum(std.os.linux.PERF.COUNT.HW.INSTRUCTIONS));
    const t0 = std.Io.Clock.awake.now(io);
    cycles.start();
    instrs.start();
    var header: usize = 0;
    const design = std.meta.stringToEnum(Design, mode) orelse {
        std.debug.print("no design `{s}`\n", .{mode});
        std.process.exit(2);
    };
    switch (design) {
        .none => {},
        inline else => |d| {
            if (track) run(d, true, ops[0..n_ops], &counts, pollute) else run(d, false, ops[0..n_ops], &counts, pollute);
            header = headerBytes(d);
        },
    }
    const ic = instrs.stop();
    const cc = cycles.stop();
    const ns = t0.untilNow(io, .awake).toNanoseconds();
    std.debug.print("RESULT design={s} cycles={d} instructions={d} ns={d} mismatches={d} peak_bytes={d} end_bytes={d} peak_maps={d} header_bytes={d} sink={d}\n", .{ mode, cc, ic, ns, mismatches, peak_bytes, live_bytes, peak_maps, peak_maps * header, sink });
    if (first_mismatch) |fm| std.debug.print("first mismatch at op {d}\n", .{fm});
}
