// A model of binarytrees' plain shape (a thread per depth, an arena per tree, post-order adds as
// `!a.add(Node(left: l, right: r))` makes them) with three link representations:
//   ptr16: 8-byte pointers, a 16-byte node (the approved Arena's `(?Node)?` fields)
//   rel32: 4-byte offsets from the node's own address, an 8-byte node (Goose's relative refs)
//   idx32: 4-byte indexes from the arena's base, an 8-byte node (the fast port's pool)
// An arena is a bump window in a per-thread block; dropping one rewinds it (recycled memory).
const std = @import("std");
const mode = @import("build_options").mode;

const Ptr16 = extern struct { l: ?*const Ptr16, r: ?*const Ptr16 };
const Link32 = extern struct { l: i32, r: i32 };
const Node = if (std.mem.startsWith(u8, mode, "ptr16")) Ptr16 else Link32;

const Arena = struct {
    base: [*]u8,
    cur: usize,
    end: usize,
    inline fn add(a: *Arena, n: Node) *Node {
        if (comptime std.mem.eql(u8, mode, "ptr16down")) {
            // bumps downward from the top, as bumpalo does
            if (a.end - a.cur < @sizeOf(Node)) @panic("arena full");
            a.end -= @sizeOf(Node);
            const q: *Node = @ptrCast(@alignCast(a.base + a.end));
            q.* = n;
            return q;
        }
        const at = a.cur;
        if (at + @sizeOf(Node) > a.end) @panic("arena full");
        a.cur = at + @sizeOf(Node);
        const p: *Node = @ptrCast(@alignCast(a.base + at));
        p.* = n;
        return p;
    }
};

fn make(a: *Arena, d: i64) *const Node {
    if (comptime std.mem.eql(u8, mode, "ptr16rev") or std.mem.eql(u8, mode, "ptr16down")) {
        if (d == 0) return a.add(.{ .l = null, .r = null });
        const l = make(a, d - 1);
        const r = make(a, d - 1);
        return a.add(.{ .l = l, .r = r });
    } else if (comptime std.mem.eql(u8, mode, "ptr16pre")) {
        // the node's place taken first, filled after its subtrees (rust-5's order)
        const p = a.add(undefined);
        if (d == 0) { p.* = .{ .l = null, .r = null }; return p; }
        const r = make(a, d - 1);
        const l = make(a, d - 1);
        p.* = .{ .l = l, .r = r };
        return p;
    } else if (comptime std.mem.eql(u8, mode, "rel32pre")) {
        const p = a.add(undefined);
        if (d == 0) { p.* = .{ .l = 0, .r = 0 }; return p; }
        const r = make(a, d - 1);
        const l = make(a, d - 1);
        const me: isize = @intCast(@intFromPtr(p));
        p.* = .{ .l = @intCast(@as(isize, @intCast(@intFromPtr(l))) - me), .r = @intCast(@as(isize, @intCast(@intFromPtr(r))) - me) };
        return p;
    } else if (comptime std.mem.eql(u8, mode, "ptr16")) {
        if (d == 0) return a.add(.{ .l = null, .r = null });
        const l = make(a, d - 1);
        const r = make(a, d - 1);
        return a.add(.{ .l = l, .r = r });
    } else if (comptime std.mem.eql(u8, mode, "rel32")) {
        if (d == 0) return a.add(.{ .l = 0, .r = 0 });
        const l = make(a, d - 1);
        const r = make(a, d - 1);
        const p = a.add(undefined); // built in place: the offsets need the node's address
        const me: isize = @intCast(@intFromPtr(p));
        p.* = .{ .l = @intCast(@as(isize, @intCast(@intFromPtr(l))) - me), .r = @intCast(@as(isize, @intCast(@intFromPtr(r))) - me) };
        return p;
    } else {
        if (d == 0) return a.add(.{ .l = -1, .r = -1 });
        const l = make(a, d - 1);
        const r = make(a, d - 1);
        const b: isize = @intCast(@intFromPtr(a.base));
        return a.add(.{ .l = @intCast(@divExact(@as(isize, @intCast(@intFromPtr(l))) - b, 8)), .r = @intCast(@divExact(@as(isize, @intCast(@intFromPtr(r))) - b, 8)) });
    }
}

fn check(base: [*]const u8, n: *const Node) i64 {
    if (comptime std.mem.eql(u8, mode, "ptr16rev") or std.mem.eql(u8, mode, "ptr16pre") or std.mem.eql(u8, mode, "ptr16down")) {
        if (n.l) |l| if (n.r) |r| return 1 + check(base, r) + check(base, l);
        return 1;
    } else if (comptime std.mem.eql(u8, mode, "rel32pre")) {
        if (n.l == 0) return 1;
        const me = @intFromPtr(n);
        const l: *const Node = @ptrFromInt(@as(usize, @bitCast(@as(isize, @bitCast(me)) + n.l)));
        const r: *const Node = @ptrFromInt(@as(usize, @bitCast(@as(isize, @bitCast(me)) + n.r)));
        return 1 + check(base, r) + check(base, l);
    } else if (comptime std.mem.eql(u8, mode, "ptr16")) {
        if (n.l) |l| if (n.r) |r| return 1 + check(base, l) + check(base, r);
        return 1;
    } else if (comptime std.mem.eql(u8, mode, "rel32")) {
        if (n.l == 0) return 1;
        const me = @intFromPtr(n);
        const l: *const Node = @ptrFromInt(@as(usize, @bitCast(@as(isize, @bitCast(me)) + n.l)));
        const r: *const Node = @ptrFromInt(@as(usize, @bitCast(@as(isize, @bitCast(me)) + n.r)));
        return 1 + check(base, l) + check(base, r);
    } else {
        if (n.l < 0) return 1;
        const nodes: [*]const Node = @ptrCast(@alignCast(base));
        return 1 + check(base, &nodes[@intCast(n.l)]) + check(base, &nodes[@intCast(n.r)]);
    }
}

fn block(bytes: usize) Arena {
    const m = std.heap.page_allocator.alloc(u8, bytes) catch @panic("oom");
    return .{ .base = m.ptr, .cur = 0, .end = bytes };
}

fn tree(a: *Arena, d: i64) i64 {
    const mark = a.cur; // a new arena
    defer a.cur = mark; // dropped: rewound
    const top = a.end;
    defer a.end = top;
    const root = make(a, d);
    return check(a.base, root);
}

var results: [16]i64 = undefined;

fn inner(slot: usize, depth: i64, iterations: i64) void {
    var a = block(@as(usize, 16) << @intCast(depth + 1));
    var chk: i64 = 0;
    var i: i64 = 0;
    while (i < iterations) : (i += 1) chk += tree(&a, depth);
    results[slot] = chk;
}

pub fn main() !void {
    const n: i64 = 21;
    const max_depth = n;
    var m = block(@as(usize, 16) << @intCast(max_depth + 3));
    std.debug.print("stretch tree of depth {d}\t check: {d}\n", .{ max_depth + 1, tree(&m, max_depth + 1) });
    const long_root = make(&m, max_depth);
    var threads: [16]std.Thread = undefined;
    var k: usize = 0;
    var d: i64 = 4;
    while (d <= max_depth) : (d += 2) {
        threads[k] = try std.Thread.spawn(.{}, inner, .{ k, d, @as(i64, 1) << @intCast(max_depth - d + 4) });
        k += 1;
    }
    d = 4;
    for (threads[0..k], 0..) |t, j| {
        t.join();
        std.debug.print("{d}\t trees of depth {d}\t check: {d}\n", .{ @as(i64, 1) << @intCast(max_depth - d + 4), d, results[j] });
        d += 2;
    }
    std.debug.print("long lived tree of depth {d}\t check: {d}\n", .{ max_depth, check(m.base, long_root) });
}
