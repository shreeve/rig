# variants.py NAME EDITS: a copy of `base` (pool.rig's package, with
# `work` made noinline) with hand edits to its Zig, one per comma-separated
# EDIT, for the copies each form costs (payload-in-place.md).
import sys, shutil, os
name, edits = sys.argv[1], sys.argv[2].split(',')
if os.path.exists(name): shutil.rmtree(name)
shutil.copytree('base', name)
def ed(path, a, b):
    s = open(path).read(); assert a in s, (path, a); open(path, 'w').write(s.replace(a, b))
M = name + '/__rig_main.zig'; R = name + '/rig/runtime.zig'
for e in edits:
    if e == 'nort':   # no rig.rt on the var initializer
        ed(M, 'var r = rig.rt(self.get());', 'var r = self.get();')
    elif e == 'hand':  # get pops in place
        ed(M, 'return (rig.some(self.free.pop()) orelse Big{});', 'const l = &self.free; if (l.len == 0) return Big{}; l.len -= 1; return l.buf.ptr[l.len];')
    elif e == 'ptr':   # ?? through the payload's address
        ed(M, 'return (rig.some(self.free.pop()) orelse Big{});', 'var o = self.free.pop(); return if (rig.somePtr(&o)) |p| p.* else Big{};')
    elif e == 'packsome':  # pop writes the Niche's bytes once
        ed(R, '''            self.len -= 1;
            return pack(Opt(T), self.mem()[self.len]);''', '''            self.len -= 1;
            return packSome(Opt(T), &self.mem()[self.len]);''')
        ed(R, 'pub inline fn pack(comptime O: type', '''pub inline fn packSome(comptime O: type, p: *const Payload(O)) O {
    if (comptime isOptStruct(O) and @hasField(O, "bytes")) {
        var o: O = undefined;
        @as(*Payload(O), @ptrCast(&o.bytes)).* = p.*;
        return o;
    }
    return pack(O, p.*);
}
pub inline fn pack(comptime O: type''')
    elif e == 'takeptr':
        ed(R, 'pub fn take(alive: *bool, value: anytype) @TypeOf(value) {', 'pub inline fn takeAt(alive: *bool, p: anytype) @TypeOf(p) { alive.* = false; return p; }\npub fn take(alive: *bool, value: anytype) @TypeOf(value) {')
        s = open(M).read()
        import re
        s = re.sub(r'rig\.take\(&(\w+), (\w+)\)', r'rig.takeAt(&\1, &\2).*', s)
        open(M, 'w').write(s)
    elif e == 'noargrt':
        ed(M, 'var r = rig.rt(__rig_arg_1);', 'var r = __rig_arg_1;')
    elif e == 'putrt':
        ed(M, 'rig.rt(self.put(', '(self.put(')
    elif e == 'popinline':
        ed(R, 'pub fn pop(self: *Self) Opt(T) {', 'pub inline fn pop(self: *Self) Opt(T) {')
    elif e == 'popat':
        ed(R, '        /// Remove and return the last element; the caller owns it.', '''        pub inline fn popAt(self: *Self) ?*T {
            if (self.len == 0) return null;
            self.len -= 1;
            return &self.mem()[self.len];
        }
        /// Remove and return the last element; the caller owns it.''')
        ed(M, 'return (rig.some(self.free.pop()) orelse Big{});', 'return if (self.free.popAt()) |p| p.* else Big{};')
    else: raise SystemExit('bad ' + e)
