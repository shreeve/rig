# Make map-prof.zig: map.zig whose main runs only the rows named on argv
# (sized:100000 bigs:16 ...), each `reps` times (env REPS, default 1).
import re, sys
src = open(sys.argv[1]).read()
i = src.index("pub fn main(")
head = src[:i]
main = '''pub fn main(init: std.process.Init.Minimal) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var args = init.args.iterate();
    _ = args.skip();
    var reps: usize = 1;
    while (args.next()) |a| {
        if (std.mem.startsWith(u8, a, "x")) { reps = try std.fmt.parseInt(usize, a[1..], 10); continue; }
        if (std.mem.eql(u8, a, "on")) {
            // perf record -D -1 --control=fifo:CTL: start counting here.
            const fd = std.c.open("/zfs/worktrees/rig/alloc-grow/perf.ctl", .{ .ACCMODE = .WRONLY });
            _ = std.c.write(fd, "enable\\n", 7);
            _ = std.c.close(fd);
            continue;
        }
        const c = std.mem.indexOfScalar(u8, a, ':').?;
        const s = try std.fmt.parseInt(i64, a[c + 1 ..], 10);
        const f = a[0..c];
        for (0..reps) |_| {
            if (std.mem.eql(u8, f, "sized")) try sized(io, s)
            else if (std.mem.eql(u8, f, "bigs")) try bigs(io, s)
            else if (std.mem.eql(u8, f, "random")) try random(io, s)
            else if (std.mem.eql(u8, f, "texts")) try texts(io, s)
            else if (std.mem.eql(u8, f, "churn")) try churn(io, s)
            else if (std.mem.eql(u8, f, "latency")) try latency(io, s)
            else if (std.mem.eql(u8, f, "mixed")) try mixed(io, s)
            else return error.Row;
            rowDone();
        }
    }
}
'''
open(sys.argv[2], "w").write(head + main)
