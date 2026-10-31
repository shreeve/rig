# mkarm.py SRC OUT ARM [key=value...]: row 21's prototype arms over main's alloc.zig.
import sys
src, out, arm = sys.argv[1], sys.argv[2], sys.argv[3]
opts = dict(a.split("=") for a in sys.argv[4:])
s = open(src).read()
def rep(a, b, n=1):
    global s
    assert s.count(a) >= 1, a
    s = s.replace(a, b, n)

cfg = f'''
// PROTOTYPE (row 21, not for merge): which arm this build is.
const arm: enum {{ main, a, b }} = .{arm};
const take_remote = {opts.get("remote", "false")};
const lazy_free = {opts.get("lazy", "false")};
const probe = {opts.get("probe", "false")};
/// Of a heap that is not busy (`faultsAhead`), the most bytes of freed
/// large blocks it keeps resident.
const keep_resident: usize = {opts.get("res", "1 << 20")};
/// Arm b: what a heap moves to or from the pool at once, and the pool's most.
const pool_chunk: usize = {opts.get("chunk", "512 << 10")};
const pool_cap: usize = {opts.get("cap", "8 << 20")};

pub var pc: [12]std.atomic.Value(u64) = @splat(.init(0));
const pc_names = [_][]const u8{{ "large_alloc", "kept_hit", "pool_hit", "cold_hit", "map_new", "free_unmap", "decommit", "spill", "trim_unmap", "remote_other", "page_carve", "remote_free" }};
inline fn pinc(i: usize) void {{
    if (!probe) return;
    const n = pc[i].fetchAdd(1, .monotonic);
    if (i == 0 and n % (1 << 16) == 0 and n > 0) {{
        var buf: [600]u8 = undefined;
        var w: usize = 0;
        for (pc_names, 0..) |nm, k| {{
            const t = std.fmt.bufPrint(buf[w..], "{{s}}={{d}} ", .{{ nm, pc[k].load(.monotonic) }}) catch break;
            w += t.len;
        }}
        buf[w] = '\\n';
        _ = std.posix.system.write(2, &buf, w + 1);
    }}
}}

const Kept = struct {{
    large: [large_buckets]?*LargeFree = @splat(null),
    held: [large_words]u64 = @splat(0),
    bytes: usize = 0,
}};

const Pool = struct {{
    kept: Kept align(128) = .{{}},
    lock: std.atomic.Value(bool) align(128) = .init(false),
}};
var pool: Pool = .{{}};
fn poolLock() void {{
    while (pool.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}}
fn poolUnlock() void {{
    pool.lock.store(false, .release);
}}
fn poolHolds() bool {{
    return @atomicLoad(usize, &pool.kept.bytes, .monotonic) != 0;
}}

/// Give the pages of a kept block past its header back to the system,
/// keeping its addresses.
fn decommit(p: usize, len: usize) void {{
    pinc(6);
    const pg = std.heap.pageSize();
    if (len <= pg) return;
    const at: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(p + pg);
    const advice: u32 = if (builtin.os.tag == .linux) (if (lazy_free) std.os.linux.MADV.FREE else std.os.linux.MADV.DONTNEED) else if (builtin.os.tag.isDarwin()) 7 else return;
    std.posix.madvise(at, len - pg, advice) catch {{}};
}}
fn recommit(p: usize, len: usize) void {{
    if (!builtin.os.tag.isDarwin()) return;
    const pg = std.heap.pageSize();
    if (len <= pg) return;
    const at: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(p + pg);
    std.posix.madvise(at, len - pg, 8) catch {{}};
}}
'''
rep("const Block = struct { next: ?*Block };", cfg + "\nconst Block = struct { next: ?*Block };")

rep("""    large: [large_buckets]?*LargeFree = @splat(null),
    large_held: [large_words]u64 = @splat(0),
    large_bytes: usize = 0,""", """    kept: Kept = .{},
    cold: Kept = .{},""")

# arm c: take another heap's remote list before each page carved
rep("""        if (h.carve[c] + size > h.carve_end[c]) {
            const page""", """        if (h.carve[c] + size > h.carve_end[c]) {
            if (take_remote) if (takeRemote(h, c)) |b| return b;
            pinc(10);
            const page""")
rep("""    fn newPage(h: *Heap) ?usize {""", """    fn takeRemote(h: *Heap, c: usize) ?[*]u8 {
        var at = all_heaps.load(.acquire);
        while (at) |o| : (at = o.next_made) {
            if (o == h or o.remote[c].load(.monotonic) == null) continue;
            if (o.remote[c].swap(null, .acquire)) |list| {
                pinc(9);
                h.free[c] = list.next;
                return @ptrCast(list);
            }
        }
        return null;
    }

    fn newPage(h: *Heap) ?usize {""")
rep("""    next_free: ?*Heap = null,""", """    next_free: ?*Heap = null,
    next_made: ?*Heap = null,""")
rep("""        // Another thread's block: onto its heap's remote list.
        const owner = seg.heap;""", """        // Another thread's block: onto its heap's remote list.
        pinc(11);
        const owner = seg.heap;""")
rep("""    const h: *Heap = @ptrCast(@alignCast(bytes.ptr));
    h.* = .{};
    if (check_owner) h.owner = threadToken();
    my_heap = h;""", """    const h: *Heap = @ptrCast(@alignCast(bytes.ptr));
    h.* = .{};
    if (check_owner) h.owner = threadToken();
    if (take_remote) publish(h);
    my_heap = h;""")
rep("""/// Heaps given back by threads that ended, for the next to start.""", """var all_heaps: std.atomic.Value(?*Heap) = .init(null);
fn publish(h: *Heap) void {
    var top = all_heaps.load(.acquire);
    while (true) {
        h.next_made = top;
        top = all_heaps.cmpxchgWeak(top, h, .acq_rel, .acquire) orelse return;
    }
}

/// Heaps given back by threads that ended, for the next to start.""")

# allocLarge
rep("""    mustOwn(h);
    const size = largeSize(len);
    if (takeKept(h, size)) |p| {
        lent(h, size);
        return p;
    }
    const got = mapLarge""", """    mustOwn(h);
    const size = largeSize(len);
    pinc(0);
    if (takeKept(&h.kept, size)) |p| {
        pinc(1);
        lent(h, size);
        return p;
    }
    if (arm == .b) if (takePool(h, size)) |p| {
        pinc(2);
        lent(h, size);
        return p;
    };
    if (arm == .a) if (takeKept(&h.cold, size)) |p| {
        pinc(3);
        recommit(@intFromPtr(p), size);
        lent(h, size);
        return p;
    };
    pinc(4);
    const got = mapLarge""")

# kept functions
old_kept = s[s.index("/// A kept block for `size` bytes, best fit by bucket"):s.index("fn unmapLarge(p: usize, len: usize) void {")]
new_kept = '''/// A kept block of `k` for `size` bytes, best fit by bucket.
fn takeKept(k: *Kept, size: usize) ?[*]u8 {
    var j = nextHeld(k, largeBucket(size));
    while (j) |b| : (j = nextHeld(k, b + 1)) {
        const f = unkeep(k, b, size) orelse continue;
        const p = @intFromPtr(f);
        const len = f.len;
        if (len > size) keepPiece(k, p + size, len - size);
        return @ptrFromInt(p);
    }
    return null;
}

fn unkeep(k: *Kept, j: usize, len: usize) ?*LargeFree {
    var at = &k.large[j];
    while (at.*) |f| : (at = &f.next) {
        if (f.len < len) continue;
        at.* = f.next;
        if (k.large[j] == null) k.held[j / 64] &= ~(@as(u64, 1) << @intCast(j % 64));
        @atomicStore(usize, &k.bytes, k.bytes - f.len, .monotonic);
        return f;
    }
    return null;
}

fn nextHeld(k: *const Kept, from: usize) ?usize {
    var w = from / 64;
    if (w >= large_words) return null;
    var bits = k.held[w] & (~@as(u64, 0) << @intCast(from % 64));
    while (true) {
        if (bits != 0) return w * 64 + @ctz(bits);
        w += 1;
        if (w >= large_words) return null;
        bits = k.held[w];
    }
}

fn lastHeld(k: *const Kept) ?usize {
    var w: usize = large_words;
    while (w > 0) {
        w -= 1;
        const bits = k.held[w];
        if (bits != 0) return w * 64 + 63 - @clz(bits);
    }
    return null;
}

fn keepPiece(k: *Kept, p: usize, len: usize) void {
    if (len < minLarge()) return unmapLarge(p, len);
    const f: *LargeFree = @ptrFromInt(p);
    const b = largeBucket(len);
    f.* = .{ .next = k.large[b], .len = len };
    k.large[b] = f;
    k.held[b / 64] |= @as(u64, 1) << @intCast(b % 64);
    @atomicStore(usize, &k.bytes, k.bytes + len, .monotonic);
}

fn heldAll(h: *const Heap) usize {
    return h.kept.bytes + h.cold.bytes;
}

fn trimKept(h: *Heap) void {
    trimFrom(h, &h.cold);
    trimFrom(h, &h.kept);
}

fn trimFrom(h: *Heap, k: *Kept) void {
    while (heldAll(h) > keepBound(h)) {
        const over = heldAll(h) - keepBound(h);
        var j = nextHeld(k, largeBucket(over));
        const f = while (j) |b| : (j = nextHeld(k, b + 1)) {
            if (unkeep(k, b, over)) |f| break f;
        } else unkeep(k, lastHeld(k) orelse return, 0).?;
        pinc(8);
        unmapLarge(@intFromPtr(f), f.len);
    }
}

/// Arm b: move kept blocks of `h` past `keep_resident` to the pool, or
/// give back those the pool has no room for.
fn spill(h: *Heap) void {
    pinc(7);
    var chain: ?*LargeFree = null;
    while (h.kept.bytes > keep_resident) {
        const j = nextHeld(&h.kept, 0) orelse break;
        const f = unkeep(&h.kept, j, 0).?;
        f.next = chain;
        chain = f;
    }
    var rest: ?*LargeFree = null;
    poolLock();
    var room = pool_cap -| pool.kept.bytes;
    while (chain) |f| {
        chain = f.next;
        if (f.len <= room) {
            room -= f.len;
            keepPiece(&pool.kept, @intFromPtr(f), f.len);
        } else {
            f.next = rest;
            rest = f;
        }
    }
    poolUnlock();
    while (rest) |f| {
        rest = f.next;
        unmapLarge(@intFromPtr(f), f.len);
    }
}

/// Arm b: a block from the pool for `size` bytes, and up to a chunk more
/// of its bucket for `h`'s next.
fn takePool(h: *Heap, size: usize) ?[*]u8 {
    if (!poolHolds()) return null;
    poolLock();
    const p = takeKept(&pool.kept, size) orelse {
        poolUnlock();
        return null;
    };
    var chain: ?*LargeFree = null;
    var got: usize = size;
    const b = largeBucket(size);
    while (got < pool_chunk) {
        const f = unkeep(&pool.kept, b, size) orelse break;
        f.next = chain;
        chain = f;
        got += f.len;
    }
    poolUnlock();
    while (chain) |f| {
        chain = f.next;
        keepPiece(&h.kept, @intFromPtr(f), f.len);
    }
    return p;
}

'''
s = s.replace(old_kept, new_kept)

rep("""    h.large_peak = @max(h.large_peak, h.large_live);
    if (h.large_bytes + size > keepBound(h)) return unmapLarge(@intFromPtr(p), size);
    keepPiece(h, @intFromPtr(p), size);""", """    h.large_peak = @max(h.large_peak, h.large_live);
    if (heldAll(h) + size > keepBound(h)) {
        pinc(5);
        return unmapLarge(@intFromPtr(p), size);
    }
    if (arm == .main or faultsAhead(h)) return keepPiece(&h.kept, @intFromPtr(p), size);
    switch (arm) {
        .main => unreachable,
        .a => if (h.kept.bytes + size <= keep_resident) {
            keepPiece(&h.kept, @intFromPtr(p), size);
        } else {
            decommit(@intFromPtr(p), size);
            keepPiece(&h.cold, @intFromPtr(p), size);
        },
        .b => {
            keepPiece(&h.kept, @intFromPtr(p), size);
            if (h.kept.bytes > keep_resident + pool_chunk) spill(h);
        },
    }""")
rep("""    if (takeKept(h, new_size)) |p| {
        lent(h, new_size);""", """    if (takeKept(&h.kept, new_size)) |p| {
        lent(h, new_size);""")

# tests
s = s.replace("h.large_bytes", "heldAll(&h)")
s = s.replace("heldAll(&h) + h.large_live", "heldAll(&h) + h.large_live")
rep("""    while (lastHeld(h)) |j| {
        const f = unkeep(h, j, 0).?;
        unmapLarge(@intFromPtr(f), f.len);
    }""", """    for ([_]*Kept{ &h.kept, &h.cold }) |k| while (lastHeld(k)) |j| {
        const f = unkeep(k, j, 0).?;
        unmapLarge(@intFromPtr(f), f.len);
    };""")
s = s.replace("try std.testing.expectEqual(@as(usize, 0), heldAll(&h));", "try std.testing.expectEqual(@as(usize, 0), heldAll(h));")
open(out, "w").write(s)
