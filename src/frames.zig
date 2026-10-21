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
pub const Frame = struct { name: []const u8, bytes: u64 };

const Machine = enum { aarch64, x86_64 };

/// A function symbol: its name and address.
const Symbol = struct { name: []const u8, addr: u64 };

/// The section of code: where it is in memory and in the file.
const Text = struct { addr: u64, offset: u64, size: u64 };

/// Every function of the executable `bytes` with the frame it reserves,
/// in no order; empty for a file this does not read.
pub fn read(allocator: std.mem.Allocator, bytes: []const u8) ![]Frame {
    var symbols: std.ArrayList(Symbol) = .empty;
    var text: Text = undefined;
    var machine: Machine = undefined;
    var probe: ?u64 = null;
    if (bytes.len >= 32 and u32At(bytes, 0) == 0xfeedfacf) {
        machine = switch (u32At(bytes, 4)) {
            0x0100000c => .aarch64,
            0x01000007 => .x86_64,
            else => return &.{},
        };
        text = (try machO(allocator, bytes, &symbols, &probe)) orelse return &.{};
    } else if (bytes.len >= 64 and std.mem.eql(u8, bytes[0..4], "\x7fELF") and bytes[4] == 2 and bytes[5] == 1) {
        machine = switch (u16At(bytes, 18)) {
            183 => .aarch64,
            62 => .x86_64,
            else => return &.{},
        };
        text = (try elf(allocator, bytes, &symbols, &probe)) orelse return &.{};
    } else return &.{};

    std.mem.sort(Symbol, symbols.items, {}, struct {
        fn lessThan(_: void, a: Symbol, b: Symbol) bool {
            return a.addr < b.addr;
        }
    }.lessThan);
    var out: std.ArrayList(Frame) = .empty;
    for (symbols.items, 0..) |s, i| {
        if (s.addr < text.addr or s.addr >= text.addr + text.size) continue;
        const end_addr = if (i + 1 < symbols.items.len) @min(symbols.items[i + 1].addr, text.addr + text.size) else text.addr + text.size;
        const start = text.offset + (s.addr - text.addr);
        const end = text.offset + (end_addr - text.addr);
        if (end > bytes.len or start >= end) continue;
        const code = bytes[@intCast(start)..@intCast(end)];
        const n = switch (machine) {
            .aarch64 => armFrame(code),
            .x86_64 => x86Frame(code, s.addr, probe),
        };
        try out.append(allocator, .{ .name = s.name, .bytes = n });
    }
    return out.items;
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
fn machO(allocator: std.mem.Allocator, bytes: []const u8, symbols: *std.ArrayList(Symbol), probe: *?u64) !?Text {
    const ncmds = u32At(bytes, 16);
    var off: usize = 32;
    var text: ?Text = null;
    var text_index: u32 = 0;
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
        if (cmd == 0x19) {
            const nsects = u32At(bytes, off + 64);
            var k: u32 = 0;
            while (k < nsects) : (k += 1) {
                const s = off + 72 + k * 80;
                if (s + 80 > bytes.len) return null;
                sect_count += 1;
                if (std.mem.eql(u8, name16(bytes[s..][0..16]), "__text") and std.mem.eql(u8, name16(bytes[s + 16 ..][0..16]), "__TEXT")) {
                    text = .{ .addr = u64At(bytes, s + 32), .size = u64At(bytes, s + 40), .offset = u32At(bytes, s + 48) };
                    text_index = sect_count;
                }
            }
        } else if (cmd == 0x2) {
            symoff = u32At(bytes, off + 8);
            nsyms = u32At(bytes, off + 12);
            stroff = u32At(bytes, off + 16);
            strsize = u32At(bytes, off + 20);
        }
        if (size == 0) return null;
        off += size;
    }
    if (text == null or symoff + nsyms * 16 > bytes.len or stroff + strsize > bytes.len) return null;
    const strs = bytes[stroff..][0..strsize];
    var i: usize = 0;
    while (i < nsyms) : (i += 1) {
        const e = symoff + i * 16;
        const n_type = bytes[e + 4];
        // A defined symbol of a section, not a debugging entry.
        if (n_type & 0xe0 != 0 or n_type & 0x0e != 0x0e or bytes[e + 5] != text_index) continue;
        const name = cString(strs, u32At(bytes, e)) orelse continue;
        const shown = if (name.len > 0 and name[0] == '_') name[1..] else name;
        const addr = u64At(bytes, e + 8);
        if (std.mem.eql(u8, shown, "__zig_probe_stack")) probe.* = addr;
        try symbols.append(allocator, .{ .name = shown, .addr = addr });
    }
    return text;
}

/// The ELF executable's function symbols, and its `.text`.
fn elf(allocator: std.mem.Allocator, bytes: []const u8, symbols: *std.ArrayList(Symbol), probe: *?u64) !?Text {
    const shoff: usize = @intCast(u64At(bytes, 40));
    const shentsize: usize = u16At(bytes, 58);
    const shnum: usize = u16At(bytes, 60);
    const shstrndx: usize = u16At(bytes, 62);
    if (shentsize < 64 or shoff + shnum * shentsize > bytes.len or shstrndx >= shnum) return null;
    const names = section(bytes, shoff + shstrndx * shentsize) orelse return null;
    var text: ?Text = null;
    var symtab: ?usize = null;
    var k: usize = 0;
    while (k < shnum) : (k += 1) {
        const h = shoff + k * shentsize;
        const name = cString(names, u32At(bytes, h)) orelse continue;
        if (std.mem.eql(u8, name, ".text")) text = .{ .addr = u64At(bytes, h + 16), .offset = u64At(bytes, h + 24), .size = u64At(bytes, h + 32) };
        if (u32At(bytes, h + 4) == 2) symtab = h;
    }
    const st = symtab orelse return null;
    if (text == null) return null;
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
    return text;
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
