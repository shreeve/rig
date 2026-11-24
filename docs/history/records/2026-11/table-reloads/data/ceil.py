#!/usr/bin/env python3
# ceil.py OUTDIR MODE: patch Rig's generated Zig in OUTDIR (a copy, never Rig's source) for the dependent-load ceiling.
#   MODE map: every reserved Table of the checker's Store is mapped at a fixed address (initAt), accessors unchanged.
#   MODE fixed: as map, and every `self.store.F.{at,constSlot,slot,atInt,constSlotInt,slotInt}(` reads through a
#   comptime-constant base (fx), so no access loads a Table head. One Store per process only (c1): a second
#   initAt of the same address panics. Scratch, never to land.
import sys, re, os
out, mode = sys.argv[1], sys.argv[2]
tz = os.path.join(out, 'rig', 'table.zig'); cz = os.path.join(out, 'checker.zig')
t = open(tz).read()
anchor = '        /// `t[s]`: the slot\'s value, with no test.\n'
assert anchor in t and 'initAt' not in t
add = '''        /// CEILING (dload, scratch): a reserved table mapped at `addr`, as `reserve`'s huge-page path maps one.
        pub fn initAt(comptime addr: usize) Self {
            comptime std.debug.assert(how == .reserved);
            const bytes = std.mem.alignForward(usize, @as(usize, @intCast(n)) * @sizeOf(T), huge);
            const prot: std.posix.PROT = .{ .READ = true, .WRITE = true };
            const flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true, .FIXED_NOREPLACE = true };
            const m = std.posix.mmap(@ptrFromInt(addr), bytes, prot, flags, -1, 0) catch @panic("ceiling: initAt refused");
            if (@intFromPtr(m.ptr) != addr) @panic("ceiling: initAt moved");
            if (bytes > huge) {
                std.posix.madvise(m.ptr, huge, std.posix.MADV.NOHUGEPAGE) catch {};
                std.posix.madvise(@ptrFromInt(addr + huge), bytes - huge, std.posix.MADV.HUGEPAGE) catch {};
            } else std.posix.madvise(m.ptr, m.len, std.posix.MADV.NOHUGEPAGE) catch {};
            var s: Self = undefined;
            s = std.mem.zeroes(Self);
            s.slots = @ptrCast(@alignCast(m.ptr));
            return s;
        }
        /// CEILING: the table's slots at the constant address `addr` (where initAt mapped it).
        pub inline fn fx(self: *const Self, comptime addr: usize) Fixed(addr) {
            _ = self;
            return .{};
        }
        pub fn Fixed(comptime addr: usize) type {
            return struct {
                inline fn base() [*]T {
                    return @ptrFromInt(addr);
                }
                pub inline fn at(_: @This(), s: Index) T {
                    return base()[offset(s)];
                }
                pub inline fn constSlot(_: @This(), s: Index) *const T {
                    return &base()[offset(s)];
                }
                pub inline fn slot(_: @This(), s: Index) *T {
                    return &base()[offset(s)];
                }
                pub inline fn atInt(self: @This(), i: anytype) T {
                    return self.at(index(i));
                }
                pub inline fn constSlotInt(self: @This(), i: anytype) *const T {
                    return self.constSlot(index(i));
                }
                pub inline fn slotInt(self: @This(), i: anytype) *T {
                    return self.slot(index(i));
                }
            };
        }

'''
t = t.replace(anchor, add + anchor)
open(tz, 'w').write(t)
c = open(cz).read()
m = re.search(r'var s = Store\{(.*?)\};\n', c)
assert m, 'no Store init'
body = m.group(1)
fields = re.findall(r'\.(\w+) = rig\.Table\(([^)]*\)?[^)]*)\)\.init\(\)', body)
addr = {}
newbody = body
for k, (f, targs) in enumerate(fields):
    a = 0x200000000000 + (k << 36); addr[f] = a
    newbody = newbody.replace(f'.{f} = rig.Table({targs}).init()', f'.{f} = rig.Table({targs}).initAt(0x{a:x})', 1)
assert newbody.count('initAt') == len(fields), (newbody.count('initAt'), len(fields))
c = c.replace(m.group(0), m.group(0).replace(body, newbody))
n = 0
if mode == 'fixed':
    def rep(mm):
        global n
        f = mm.group(1)
        if f not in addr: return mm.group(0)
        n += 1
        return f'self.store.{f}.fx(0x{addr[f]:x}).{mm.group(2)}('
    c = re.sub(r'self\.store\.(\w+)\.(at|constSlot|slot|atInt|constSlotInt|slotInt)\(', rep, c)
open(cz, 'w').write(c)
print(f'{len(fields)} tables mapped at fixed addresses; {n} access sites through a constant base ({mode})')
