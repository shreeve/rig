//! The stack each function of a built program reserves, read from the
//! executable itself: its symbols, and the prologue of each function,
//! which reserves the function's frame. `rig build` reads it to warn
//! about frames larger than a page (`main.warnFrames`).
//!
//! The prologues read, by machine:
//!
//! - aarch64: each `sub sp, sp, #N` (`, lsl #12` scales `N` by 4096) and
//!   the pair `stp ..., [sp, #-N]!` pushes, within its first 32
//!   instructions;
//! - x86_64: `sub rsp, N`, a `mov eax, N` the call of the stack probe
//!   follows, and the step of a probe loop, `sub r11, N`, within its
//!   first 96 bytes: the largest of them.
//!
//! Mach-O (macOS) and ELF (Linux) executables; any other gives none.

const std = @import("std");

/// A function of the executable and the bytes its prologue reserves.
/// `reach` bounds what its whole body may reserve (`armReach`, `x86Reach`),
/// an overestimate on purpose; null when a stack adjustment in it cannot
/// be read.
pub const Frame = struct { name: []const u8, bytes: u64, reach: ?u64 };

const Machine = enum { aarch64, x86_64 };

/// A function symbol: its name and address.
const Symbol = struct { name: []const u8, addr: u64 };

/// A section of code: where it is in memory and in the file.
const Text = struct { addr: u64, offset: u64, size: u64 };

/// The sections of code read: the linker's, and the program's own, which
/// a program built to be preempted keeps its functions in
/// (`rig.preempt_section`).
const Texts = struct {
    items: [2]Text = undefined,
    len: usize = 0,

    fn add(t: *Texts, s: Text) void {
        if (t.len < t.items.len) {
            t.items[t.len] = s;
            t.len += 1;
        }
    }

    /// The section that holds `addr`.
    fn holding(t: *const Texts, addr: u64) ?Text {
        for (t.items[0..t.len]) |s| if (addr >= s.addr and addr < s.addr + s.size) return s;
        return null;
    }
};

/// Every function of the executable `bytes` with the frame it reserves,
/// in no order; empty for a file this does not read.
pub fn read(allocator: std.mem.Allocator, bytes: []const u8) ![]Frame {
    var symbols: std.ArrayList(Symbol) = .empty;
    var texts: Texts = .{};
    var machine: Machine = undefined;
    var probe: ?u64 = null;
    if (bytes.len >= 32 and u32At(bytes, 0) == 0xfeedfacf) {
        machine = switch (u32At(bytes, 4)) {
            0x0100000c => .aarch64,
            0x01000007 => .x86_64,
            else => return &.{},
        };
        texts = (try machO(allocator, bytes, &symbols, &probe)) orelse return &.{};
    } else if (bytes.len >= 64 and std.mem.eql(u8, bytes[0..4], "\x7fELF") and bytes[4] == 2 and bytes[5] == 1) {
        machine = switch (u16At(bytes, 18)) {
            183 => .aarch64,
            62 => .x86_64,
            else => return &.{},
        };
        texts = (try elf(allocator, bytes, &symbols, &probe)) orelse return &.{};
    } else return &.{};

    std.mem.sort(Symbol, symbols.items, {}, struct {
        fn lessThan(_: void, a: Symbol, b: Symbol) bool {
            return a.addr < b.addr;
        }
    }.lessThan);
    var out: std.ArrayList(Frame) = .empty;
    for (symbols.items, 0..) |s, i| {
        const text = texts.holding(s.addr) orelse continue;
        const end_addr = if (i + 1 < symbols.items.len) @min(symbols.items[i + 1].addr, text.addr + text.size) else text.addr + text.size;
        const start = text.offset + (s.addr - text.addr);
        const end = text.offset + (end_addr - text.addr);
        if (end > bytes.len or start >= end) continue;
        const code = bytes[@intCast(start)..@intCast(end)];
        const n = switch (machine) {
            .aarch64 => armFrame(code),
            .x86_64 => x86Frame(code, s.addr, probe),
        };
        const reach = switch (machine) {
            .aarch64 => armReach(code),
            .x86_64 => x86Reach(code, s.addr, probe),
        };
        try out.append(allocator, .{ .name = s.name, .bytes = n, .reach = reach });
    }
    return out.items;
}

/// The most stack any function of the executable `bytes` may reserve at
/// once, or null when that cannot be known: a file this does not read, or
/// a function with a stack adjustment it cannot read. What a guard below
/// a stack is sized from, so it fails closed.
pub fn largestReach(allocator: std.mem.Allocator, bytes: []const u8) !?u64 {
    const all = try read(allocator, bytes);
    if (all.len == 0) return null;
    var most: u64 = 0;
    for (all) |f| most = @max(most, f.reach orelse return null);
    return most + reach_margin;
}

/// Added to the largest bound: what `read` does not count, an x86
/// function's pushes and its return address, and the room a frame that
/// aligns itself rounds down by on x86.
const reach_margin: u64 = 8 << 10;

/// A bound on what an aarch64 function reserves anywhere in its body:
/// every adjustment of the stack pointer added up, each read wherever it
/// is, since shrink wrapping moves them out of the prologue. Several on
/// separate paths count together, and bytes that only look like one
/// count too; both only raise it. A register's value subtracted from the
/// stack pointer gives null.
fn armReach(code: []const u8) ?u64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i + 4 <= code.len) : (i += 4) {
        const ins = u32At(code, i);
        // `sub Xd, sp, #imm{, lsl #12}`, Xd the stack pointer, or a
        // register an aligned frame then moves to it.
        if (ins & 0xff8003e0 == 0xd10003e0) {
            const imm: u64 = (ins >> 10) & 0xfff;
            total += if ((ins >> 22) & 1 == 1) imm << 12 else imm;
        }
        // `stp A, B, [sp, #-N]!`, of general or vector registers
        if (ins & 0x3bc003e0 == 0x298003e0) {
            const imm7: i64 = @as(i7, @bitCast(@as(u7, @truncate(ins >> 15))));
            const vector = (ins >> 26) & 1 == 1;
            const opc = ins >> 30;
            const scale: i64 = if (vector) @as(i64, 4) << @intCast(opc) else if (opc == 2) 8 else 4;
            if (imm7 < 0) total += @intCast(-imm7 * scale);
        }
        // `str A, [sp, #-N]!`
        if (ins & 0x3b600fe0 == 0x38000fe0) {
            const imm9: i64 = @as(i9, @bitCast(@as(u9, @truncate(ins >> 12))));
            if (imm9 < 0) total += @intCast(-imm9);
        }
        // `and sp, Xn, #mask`: an aligned frame rounds down, by less than
        // a page for any alignment Zig asks of a local.
        if (ins & 0xff80001f == 0x9200001f) total += 4096;
        // `sub sp, sp, Xm`
        if (ins & 0xffe003ff == 0xcb2003ff) return null;
    }
    return total;
}

/// `armReach` for x86_64, by the bytes of each form at every offset,
/// with no decoder: bytes that only look like a form raise the bound, and
/// nothing lowers it. A register subtracted from the stack pointer is
/// left out: x86's bytes cannot tell one from the middle of another
/// instruction, and only the stack probe's call, which is counted, comes
/// before one, since neither Zig nor Rig allocates on the stack by a
/// run-time size. Pushes are left to the guard's margin (`reach_margin`).
fn x86Reach(code: []const u8, addr: u64, probe: ?u64) u64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        const rest = code[i..];
        // `sub rsp, imm32`
        if (rest.len >= 7 and rest[0] == 0x48 and rest[1] == 0x81 and rest[2] == 0xec) total += u32At(rest, 3);
        // The step of a probe loop, `sub r11, imm32`: a prologue's.
        if (i < 96 and rest.len >= 7 and rest[0] == 0x49 and rest[1] == 0x81 and rest[2] == 0xeb) total += u32At(rest, 3);
        // `sub rsp, imm8`
        if (rest.len >= 4 and rest[0] == 0x48 and rest[1] == 0x83 and rest[2] == 0xec) total += rest[3];
        // `mov eax, imm32` then `call probe`
        if (probe) |p| if (rest.len >= 10 and rest[0] == 0xb8 and rest[5] == 0xe8) {
            const rel: i32 = @bitCast(u32At(rest, 6));
            const next: i64 = @intCast(addr + i + 10);
            if (next + rel == @as(i64, @intCast(p))) total += u32At(rest, 1);
        };
    }
    return total;
}

/// What an aarch64 prologue reserves.
fn armFrame(code: []const u8) u64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i + 4 <= code.len and i < 32 * 4) : (i += 4) {
        const ins = u32At(code, i);
        // `sub sp, sp, #imm{, lsl #12}`
        if (ins & 0xff8003ff == 0xd10003ff) {
            const imm: u64 = (ins >> 10) & 0xfff;
            total += if ((ins >> 22) & 1 == 1) imm << 12 else imm;
        }
        // `stp xA, xB, [sp, #-N]!`
        if (ins & 0xffc003e0 == 0xa98003e0) {
            const imm7: i64 = @as(i7, @bitCast(@as(u7, @truncate(ins >> 15))));
            if (imm7 < 0) total += @intCast(-imm7 * 8);
        }
    }
    return total;
}

/// What an x86_64 prologue at `addr` reserves; `probe` is the stack
/// probe's address, when the executable names it.
fn x86Frame(code: []const u8, addr: u64, probe: ?u64) u64 {
    var most: u64 = 0;
    const limit = @min(code.len, 96);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const rest = code[i..];
        // `sub rsp, imm32` and `sub r11, imm32`
        if (rest.len >= 7 and ((rest[0] == 0x48 and rest[1] == 0x81 and rest[2] == 0xec) or (rest[0] == 0x49 and rest[1] == 0x81 and rest[2] == 0xeb))) {
            most = @max(most, u32At(rest, 3));
        }
        // `sub rsp, imm8`
        if (rest.len >= 4 and rest[0] == 0x48 and rest[1] == 0x83 and rest[2] == 0xec) most = @max(most, rest[3]);
        // `mov eax, imm32` then `call probe`
        if (probe) |p| if (rest.len >= 10 and rest[0] == 0xb8 and rest[5] == 0xe8) {
            const rel: i32 = @bitCast(u32At(rest, 6));
            const next: i64 = @intCast(addr + i + 10);
            if (next + rel == @as(i64, @intCast(p))) most = @max(most, u32At(rest, 1));
        };
    }
    return most;
}

/// The Mach-O executable's function symbols, and its `__TEXT,__text`.
fn machO(allocator: std.mem.Allocator, bytes: []const u8, symbols: *std.ArrayList(Symbol), probe: *?u64) !?Texts {
    const ncmds = u32At(bytes, 16);
    var off: usize = 32;
    var texts: Texts = .{};
    var text_index: [2]u32 = @splat(0);
    var sect_count: u32 = 0;
    var symoff: usize = 0;
    var nsyms: usize = 0;
    var stroff: usize = 0;
    var strsize: usize = 0;
    var c: u32 = 0;
    while (c < ncmds) : (c += 1) {
        if (off + 8 > bytes.len) return null;
        const cmd = u32At(bytes, off);
        const size = u32At(bytes, off + 4);
        if (off + size > bytes.len) return null;
        if (cmd == 0x19) {
            if (size < 72) return null;
            const nsects = u32At(bytes, off + 64);
            var k: usize = 0;
            while (k < nsects) : (k += 1) {
                const s = off + 72 + k * 80;
                if (s + 80 > bytes.len) return null;
                sect_count += 1;
                const sect = name16(bytes[s..][0..16]);
                if (std.mem.eql(u8, name16(bytes[s + 16 ..][0..16]), "__TEXT") and (std.mem.eql(u8, sect, "__text") or std.mem.eql(u8, sect, "__rig_text"))) {
                    if (texts.len < text_index.len) text_index[texts.len] = sect_count;
                    texts.add(.{ .addr = u64At(bytes, s + 32), .size = u64At(bytes, s + 40), .offset = u32At(bytes, s + 48) });
                }
            }
        } else if (cmd == 0x2) {
            if (size < 24) return null;
            symoff = u32At(bytes, off + 8);
            nsyms = u32At(bytes, off + 12);
            stroff = u32At(bytes, off + 16);
            strsize = u32At(bytes, off + 20);
        }
        if (size == 0) return null;
        off += size;
    }
    if (texts.len == 0 or symoff + nsyms * 16 > bytes.len or stroff + strsize > bytes.len) return null;
    const strs = bytes[stroff..][0..strsize];
    var i: usize = 0;
    while (i < nsyms) : (i += 1) {
        const e = symoff + i * 16;
        const n_type = bytes[e + 4];
        // A defined symbol of a section, not a debugging entry.
        if (n_type & 0xe0 != 0 or n_type & 0x0e != 0x0e or (bytes[e + 5] != text_index[0] and bytes[e + 5] != text_index[1])) continue;
        const name = cString(strs, u32At(bytes, e)) orelse continue;
        const shown = if (name.len > 0 and name[0] == '_') name[1..] else name;
        const addr = u64At(bytes, e + 8);
        if (std.mem.eql(u8, shown, "__zig_probe_stack")) probe.* = addr;
        try symbols.append(allocator, .{ .name = shown, .addr = addr });
    }
    return texts;
}

/// The ELF executable's function symbols, and its `.text`.
fn elf(allocator: std.mem.Allocator, bytes: []const u8, symbols: *std.ArrayList(Symbol), probe: *?u64) !?Texts {
    const shoff: usize = @intCast(u64At(bytes, 40));
    const shentsize: usize = u16At(bytes, 58);
    const shnum: usize = u16At(bytes, 60);
    const shstrndx: usize = u16At(bytes, 62);
    if (shentsize < 64 or shoff + shnum * shentsize > bytes.len or shstrndx >= shnum) return null;
    const names = section(bytes, shoff + shstrndx * shentsize) orelse return null;
    var texts: Texts = .{};
    var symtab: ?usize = null;
    var k: usize = 0;
    while (k < shnum) : (k += 1) {
        const h = shoff + k * shentsize;
        const name = cString(names, u32At(bytes, h)) orelse continue;
        if (std.mem.eql(u8, name, ".text") or std.mem.eql(u8, name, "rig_text")) texts.add(.{ .addr = u64At(bytes, h + 16), .offset = u64At(bytes, h + 24), .size = u64At(bytes, h + 32) });
        if (u32At(bytes, h + 4) == 2) symtab = h;
    }
    const st = symtab orelse return null;
    if (texts.len == 0) return null;
    const syms = section(bytes, st) orelse return null;
    const link: usize = u32At(bytes, st + 40);
    if (link >= shnum) return null;
    const strs = section(bytes, shoff + link * shentsize) orelse return null;
    var e: usize = 0;
    while (e + 24 <= syms.len) : (e += 24) {
        const name = cString(strs, u32At(syms, e)) orelse continue;
        const addr = u64At(syms, e + 8);
        if (std.mem.eql(u8, name, "__zig_probe_stack")) probe.* = addr;
        if (syms[e + 4] & 0xf != 2) continue;
        try symbols.append(allocator, .{ .name = name, .addr = addr });
    }
    return texts;
}

/// The bytes of the ELF section whose header is at `h`.
fn section(bytes: []const u8, h: usize) ?[]const u8 {
    const at: usize = @intCast(u64At(bytes, h + 24));
    const len: usize = @intCast(u64At(bytes, h + 32));
    if (at > bytes.len or len > bytes.len - at) return null;
    return bytes[at..][0..len];
}

fn name16(b: *const [16]u8) []const u8 {
    return b[0 .. std.mem.findScalar(u8, b, 0) orelse 16];
}

fn cString(table: []const u8, at: u32) ?[]const u8 {
    if (at >= table.len) return null;
    const rest = table[at..];
    return rest[0 .. std.mem.findScalar(u8, rest, 0) orelse return null];
}

fn u16At(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn u32At(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn u64At(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], .little);
}

test "an aarch64 prologue's frame" {
    // stp x28, x27, [sp, #-48]!; sub sp, sp, #1, lsl #12; sub sp, sp, #1920
    const code = [_]u32{ 0xa9bd6ffc, 0xd14007ff, 0xd11e03ff };
    try std.testing.expectEqual(@as(u64, 48 + 4096 + 1920), armFrame(std.mem.sliceAsBytes(&code)));
}

test "an x86_64 prologue's frame" {
    // push rbp; mov rbp, rsp; sub rsp, 0x1d8
    const code = [_]u8{ 0x55, 0x48, 0x89, 0xe5, 0x48, 0x81, 0xec, 0xd8, 0x01, 0x00, 0x00 };
    try std.testing.expectEqual(@as(u64, 0x1d8), x86Frame(&code, 0, null));
    // mov eax, 6000; call the probe, at 0x100 + 10 + 0x20
    const probed = [_]u8{ 0xb8, 0x70, 0x17, 0x00, 0x00, 0xe8, 0x20, 0x00, 0x00, 0x00 };
    try std.testing.expectEqual(@as(u64, 6000), x86Frame(&probed, 0x100, 0x100 + 10 + 0x20));
}
