//! `std.shared`: the table behind `Map[K, V]`, a map several tasks
//! fill and read at once. A key keeps the first value put under it, and
//! nothing is replaced or taken, so an entry, once published, is never
//! changed, moved, or freed until the map is dropped. That is what lets a
//! lookup take no lock and write nothing, and hand back a view of the
//! value where it lies.
//!
//! The table is 64 shards, chosen by the top bits of a key's hash. Each
//! shard has an index, a power of two of one-word slots, probed in turn
//! from the hash's home slot: 0 for a free slot, else the address of an
//! entry with 16 bits of its hash above it, so a probe reads an entry
//! only when the 16 bits match. Its entries lie in blocks the shard
//! allocates, which never move.
//!
//! A lookup reads the shard's index with an acquire load, then each slot
//! the same way: an entry is written in full before the release store
//! that publishes its slot, and an index before the release store that
//! publishes it, so a lookup that sees either sees all of it. It writes
//! nothing, not even a count, so lookups on many cores share the lines
//! they read.
//!
//! An insert first looks the key up as a lookup does, and only when it is
//! missing takes the shard's lock (the scheduler's spin lock, never held
//! across a wait), looks again, writes the entry, and publishes its slot.
//! A new block of entries and a larger index are allocated under the
//! lock, so the insert that takes one holds the lock that long, as
//! seldom as a block fills or the shard's index doubles.
//! When the shard's index passes 70% full, the insert builds an index of
//! twice the slots, publishes it, and keeps the old one, linked from the
//! new, for lookups still reading it; they find every entry it held,
//! since entries do not move, and a key put since then is found by the
//! insert's second look under the lock. The old indexes are freed with
//! the map: they add up to less than the index in use.

const std = @import("std");
const rig = @import("../runtime.zig");

const shard_bits = 6;
const shard_count = 1 << shard_bits;

/// A slot holds an entry's address in its low 48 bits, which on every
/// target Rig runs on is all an address uses, and 16 bits of the entry's
/// hash above them.
const addr_bits = 48;
const addr_mask: u64 = (1 << addr_bits) - 1;

/// An index starts with this many slots, at least, and grows past 70%.
const min_slots = 8;
const load_num = 7;
const load_den = 10;

/// A shard's first block holds this many entries; each next one twice
/// as many, up to the last size.
const first_block = 8;
const last_block = 1024;

const cache_line = std.atomic.cache_line;

/// What `free` reads, knowing no types: the drop of the table it heads.
const Header = struct {
    free: *const fn (*Header) void,
};

fn Table(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        header: Header,
        /// Each shard's index, read by every lookup and written only
        /// when the shard grows: apart from the locks, so a lock taken
        /// does not take a reader's line.
        indexes: [shard_count]*Index align(cache_line),
        shards: [shard_count]Shard,

        const KeyView = rig.ReadView(K);
        const int_key = @typeInfo(K) == .int and @bitSizeOf(K) <= 64;
        const text_key = K == rig.String or K == []const u8;

        /// Written once, before the slot that holds its address is
        /// published, and never changed after.
        const Entry = struct {
            hash: u64,
            key: K,
            value: V,
        };

        const Index = struct {
            /// The slots less one.
            mask: usize,
            slots: []u64,
            /// The index this one replaced, which lookups may still read.
            older: ?*Index,
        };

        const Shard = struct {
            lock: rig.sched.SpinLock align(cache_line) = .{},
            /// The entries; read by `len` while it changes.
            count: usize = 0,
            /// The blocks of entries, oldest first, and how many of the
            /// last are used.
            blocks: [][]Entry = &.{},
            used: usize = 0,
        };

        // hashing ///////////////////////////////////////////////////////

        inline fn hashKey(k: KeyView) u64 {
            if (int_key) return @as(u64, @as(@Int(.unsigned, @bitSizeOf(K)), @bitCast(k))) *% rig.int_hash_mul;
            if (text_key) return rig.textHash(rig.stringBytes(k));
            return rig.hash(k);
        }

        inline fn keyMatches(e: *const Entry, k: KeyView) bool {
            if (text_key) return rig.bytesEql(rig.stringBytes(e.key), rig.stringBytes(k));
            return switch (@typeInfo(K)) {
                .int, .bool, .@"enum" => e.key == k,
                else => rig.eql(e.key, k),
            };
        }

        inline fn shardOf(h: u64) usize {
            return @intCast(h >> (64 - shard_bits));
        }

        /// The home slot's number, before the mask: the low bits, folded
        /// with higher ones so an integer key's low bits alone do not
        /// decide it.
        inline fn homeOf(h: u64) usize {
            return @truncate(h ^ (h >> 29));
        }

        inline fn tagOf(h: u64) u64 {
            return (h >> 40) & 0xffff;
        }

        /// The slot of `e`, whose address fits in 48 bits (`put` checks).
        inline fn slotOf(e: *const Entry) u64 {
            return @as(u64, @intFromPtr(e)) | tagOf(e.hash) << addr_bits;
        }

        inline fn entryOf(w: u64) *Entry {
            return @ptrFromInt(@as(usize, @intCast(w & addr_mask)));
        }

        // lookups ///////////////////////////////////////////////////////

        fn of(m: anytype) *Self {
            const h: *Header = @ptrFromInt(@as(usize, @intCast(m.t.addr.get())));
            return @alignCast(@fieldParentPtr("header", h));
        }

        /// The entry of `k`, whose hash is `h`, in `ix`, or null.
        inline fn probe(ix: *const Index, h: u64, k: KeyView) ?*const Entry {
            const tag = tagOf(h);
            var i = homeOf(h) & ix.mask;
            while (true) : (i = (i + 1) & ix.mask) {
                const w = @atomicLoad(u64, &ix.slots[i], .acquire);
                if (w == 0) return null;
                if (w >> addr_bits == tag) {
                    const e = entryOf(w);
                    if (e.hash == h and keyMatches(e, k)) return e;
                }
            }
        }

        inline fn lookup(t: *const Self, h: u64, k: KeyView) ?*const Entry {
            return probe(@atomicLoad(*Index, &t.indexes[shardOf(h)], .acquire), h, k);
        }

        // inserts ///////////////////////////////////////////////////////

        fn newIndex(slots: usize, older: ?*Index) *Index {
            const ix = &rig.allocSlice(Index, 1)[0];
            ix.* = .{ .mask = slots - 1, .slots = rig.allocSliceZeroed(u64, slots), .older = older };
            return ix;
        }

        /// Write `w`, the slot of an entry whose hash is `h`, in the first
        /// free slot from its home: atomically, releasing the entry, when
        /// `ix` is published.
        inline fn place(ix: *Index, w: u64, h: u64, comptime published: bool) void {
            var i = homeOf(h) & ix.mask;
            while (ix.slots[i] != 0) i = (i + 1) & ix.mask;
            if (published) @atomicStore(u64, &ix.slots[i], w, .release) else ix.slots[i] = w;
        }

        /// A shard's index of twice the slots, holding every entry the old
        /// one holds, published; the old one is kept for lookups.
        fn grow(t: *Self, s: usize, old: *Index) *Index {
            const ix = newIndex(2 * (old.mask + 1), old);
            for (old.slots) |w| if (w != 0) place(ix, w, entryOf(w).hash, false);
            @atomicStore(*Index, &t.indexes[s], ix, .release);
            return ix;
        }

        /// Room for one more entry in shard `sh`, which never moves.
        fn newEntry(sh: *Shard) *Entry {
            const n = sh.blocks.len;
            if (n == 0 or sh.used == sh.blocks[n - 1].len) {
                const size = if (n == 0) first_block else @min(2 * sh.blocks[n - 1].len, last_block);
                sh.blocks = rig.reallocSlice([]Entry, sh.blocks, n + 1);
                sh.blocks[n] = rig.allocSlice(Entry, size);
                sh.used = 0;
            }
            const e = &sh.blocks[sh.blocks.len - 1][sh.used];
            sh.used += 1;
            return e;
        }

        /// The entry under `k`: `k` and `v`'s, when `k` was new, or the
        /// one put first, when they are dropped; and whether it was new.
        fn put(t: *Self, k: K, v: V) struct { *const Entry, bool } {
            var key = k;
            var value = v;
            const h = hashKey(rig.lend(&key));
            if (lookup(t, h, rig.lend(&key))) |e| {
                rig.dropElement(K, &key);
                rig.dropElement(V, &value);
                return .{ e, false };
            }
            const s = shardOf(h);
            const sh = &t.shards[s];
            sh.lock.lock();
            var ix = t.indexes[s];
            if (probe(ix, h, rig.lend(&key))) |e| {
                sh.lock.unlock();
                rig.dropElement(K, &key);
                rig.dropElement(V, &value);
                return .{ e, false };
            }
            if ((sh.count + 1) * load_den > (ix.mask + 1) * load_num) ix = grow(t, s, ix);
            const e = newEntry(sh);
            // A panic under the lock would leave every other task that
            // puts in this shard spinning: the lock is let go first.
            if (@as(u64, @intFromPtr(e)) >> addr_bits != 0) {
                sh.lock.unlock();
                @panic("std.shared: an address above 48 bits");
            }
            e.* = .{ .hash = h, .key = key, .value = value };
            place(ix, slotOf(e), h, true);
            @atomicStore(usize, &sh.count, sh.count + 1, .monotonic);
            sh.lock.unlock();
            return .{ e, true };
        }

        // making and freeing ////////////////////////////////////////////

        fn make(capacity: i64) *Self {
            const t = &rig.allocSlice(Self, 1)[0];
            const per: usize = @intCast(@divFloor(@max(capacity, 0), shard_count) + 1);
            const slots = std.math.ceilPowerOfTwoAssert(usize, @max(min_slots, per * load_den / load_num + 1));
            t.header = .{ .free = drop };
            for (&t.indexes, &t.shards) |*ix, *sh| {
                ix.* = newIndex(slots, null);
                sh.* = .{};
            }
            return t;
        }

        fn drop(h: *Header) void {
            const t: *Self = @alignCast(@fieldParentPtr("header", h));
            for (&t.indexes, &t.shards) |ix, *sh| {
                for (sh.blocks, 0..) |block, i| {
                    const used = if (i + 1 == sh.blocks.len) sh.used else block.len;
                    for (block[0..used]) |*e| {
                        rig.dropElement(K, &e.key);
                        rig.dropElement(V, &e.value);
                    }
                    rig.freeSlice(Entry, block);
                }
                rig.freeSlice([]Entry, sh.blocks);
                var at: ?*Index = ix;
                while (at) |x| {
                    at = x.older;
                    rig.freeSlice(u64, x.slots);
                    rig.freeSlice(Index, @as([*]Index, @ptrCast(x))[0..1]);
                }
            }
            rig.freeSlice(Self, @as([*]Self, @ptrCast(t))[0..1]);
        }
    };
}

pub fn make(comptime K: type, comptime V: type, capacity: i64) i64 {
    const t = Table(K, V).make(capacity);
    return @intCast(@intFromPtr(&t.header));
}

pub fn find(comptime K: type, comptime V: type, m: anytype, k: rig.ReadView(K)) ?rig.ReadView(V) {
    const T = Table(K, V);
    const e = T.lookup(T.of(m), T.hashKey(k), k) orelse return null;
    return rig.lend(&e.value);
}

pub fn holds(comptime K: type, comptime V: type, m: anytype, k: rig.ReadView(K)) bool {
    const T = Table(K, V);
    return T.lookup(T.of(m), T.hashKey(k), k) != null;
}

pub fn insert(comptime K: type, comptime V: type, m: anytype, k: K, v: V) bool {
    const T = Table(K, V);
    return T.put(T.of(m), k, v)[1];
}

pub fn settle(comptime K: type, comptime V: type, m: anytype, k: K, v: V) rig.ReadView(V) {
    const T = Table(K, V);
    return rig.lend(&T.put(T.of(m), k, v)[0].value);
}

pub fn count(comptime K: type, comptime V: type, m: anytype) i64 {
    const t = Table(K, V).of(m);
    var n: usize = 0;
    for (&t.shards) |*sh| n += @atomicLoad(usize, &sh.count, .monotonic);
    return @intCast(n);
}

pub fn free(t: i64) void {
    const h: *Header = @ptrFromInt(@as(usize, @intCast(t)));
    h.free(h);
}
