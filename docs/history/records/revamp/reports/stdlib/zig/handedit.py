# Turn the emitted stand-in program into the Zig-backed one: every
# stand-in declaration becomes a reference to its shim, plus the
# compile-time signature checks the emitter would write. Call sites are
# left exactly as the emitter wrote them.
import re
src = open('standin.emitted.zig').read()
start = src.index('pub const Text = struct {')
end = src.index('pub const Node = struct {')
shims = '''// Zig-backed declarations (std/text.rig, std/map.rig). The emitter
// would qualify each call (`std_text.trim(p)`); aliases keep this
// hand edit to the declarations alone.
const std_text = @import("rig/std/text.zig");
const std_map = @import("rig/std/map.zig");
const std_os = @import("rig/std/os.zig");
const boundary = @import("rig/std/boundary.zig");

pub const Text = std_text.Text;
pub const Lines = std_text.Lines;
pub const trim = std_text.trim;
pub const trim_view = std_text.trim_view;
pub const split = std_text.split;
pub const parse_int = std_text.parse_int;
pub const read_file = std_text.read_file;
pub const read_line = std_text.read_line;
pub const sort_by = std_map.sort_by;
pub const args = std_os.args;
pub const env = std_os.env;
pub const Map = std_map.Map;
pub const sorted_keys = std_map.sorted_keys;

// One check per declaration, and per method of each generic instance
// the program uses, each spelled from the Rig signature.
comptime {
    boundary.expectKind(Text, .owns);
    boundary.expectKind(Lines, .view);
    boundary.expect(Text.new, fn () Text, StdError);
    boundary.expect(Text.push, fn (*Text, []const u8) void, StdError);
    boundary.expect(Text.push_view, fn (*Text, []const u8) void, StdError);
    boundary.expect(Text.push_int, fn (*Text, i64) void, StdError);
    boundary.expect(Text.len, fn (*const Text) i64, StdError);
    boundary.expect(Text.view, fn (*const Text) []const u8, StdError);
    boundary.expect(Text.lines, fn (*const Text) Lines, StdError);
    boundary.expect(Lines.next, fn (*Lines) ?[]const u8, StdError);
    boundary.expect(trim, fn ([]const u8) []const u8, StdError);
    boundary.expect(trim_view, fn ([]const u8) []const u8, StdError);
    boundary.expect(split, fn ([]const u8, []const u8) rig.Vec([]const u8), StdError);
    boundary.expect(parse_int, fn ([]const u8) anyerror!i64, StdError);
    boundary.expect(read_file, fn ([]const u8) anyerror!Text, StdError);
    boundary.expect(args, fn () rig.Vec([]const u8), StdError);
    boundary.expect(env, fn ([]const u8) ?[]const u8, StdError);
    boundary.expect(read_line, fn () anyerror!?Text, StdError);
    for (.{
        .{ []const u8, i64 },
        .{ i64, *rig.RcBox(Node) },
        .{ Text, i64 },
    }) |kv| {
        const K = kv[0];
        const V = kv[1];
        const M = Map(K, V);
        boundary.expectKind(M, .owns);
        boundary.expect(M.new, fn () M, StdError);
        boundary.expect(M.put, fn (*M, K, V) ?V, StdError);
        boundary.expect(M.get, fn (*const M, rig.ReadBorrow(K)) ?V, StdError);
        boundary.expect(M.contains, fn (*const M, rig.ReadBorrow(K)) bool, StdError);
        boundary.expect(M.remove, fn (*M, rig.ReadBorrow(K)) ?V, StdError);
        boundary.expect(M.len, fn (*const M) i64, StdError);
    }
    boundary.expectResult("sort_by", @TypeOf(sort_by(i64, undefined, undefined)), void, StdError);
    boundary.expectResult("sorted_keys", @TypeOf(sorted_keys([]const u8, i64, undefined)), rig.Vec([]const u8), StdError);
}

'''
out = src[:start] + shims + src[end:]
# Zig 0.16 has no global argv: main takes Init.Minimal and hands it over.
out = out.replace('pub fn main() anyerror!void {\n', 'pub fn main(__rig_init: std.process.Init.Minimal) anyerror!void {\n    std_os.start(__rig_init);\n')
open('proto/__rig_main.zig', 'w').write(out)
