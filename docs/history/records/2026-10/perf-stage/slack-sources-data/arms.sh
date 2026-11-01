#!/bin/bash
# Slack sources: arms of Trig 4bc7a9a's release package (rig a32adf178).
R=/zfs/worktrees/rig-rust-ports/slack
cd $R
for a in m n k h all; do rm -rf p-$a; cp -a pkg p-$a; rm -rf p-$a/.zig-cache; done
N='s|^const huge_large: usize = 16 << 20;|const huge_large: usize = std.math.maxInt(usize);|'
K1='s|^    if (takeKept(\&h.kept, size)) \|p\| {$|    if (takeKept(\&h.kept, size)) \|p\| { const keep_w = std.mem.alignForward(usize, size / 2, std.heap.pageSize()); if (size > keep_w) decommit(@intFromPtr(p) + keep_w, size - keep_w);|'
K2='s|^        @memcpy(p\[0..memory.len\], memory);$|        @memcpy(p[0..memory.len], memory); { const keep_w = std.mem.alignForward(usize, memory.len, std.heap.pageSize()); if (new_size > keep_w) decommit(@intFromPtr(p) + keep_w, new_size - keep_w); }|'
H='s|prefault(h, got, likelyFilled(size - size / 4));|prefault(h, got, likelyFilled(size / 2));|; s|prefault(h, rc + old_size, likelyFilled((new_size - old_size) / 2));||'
sed -i "$N" p-n/rig/alloc.zig
sed -i -e "$K1" -e "$K2" p-k/rig/alloc.zig
sed -i "$H" p-h/rig/alloc.zig
sed -i -e "$N" -e "$K1" -e "$K2" -e "$H" p-all/rig/alloc.zig
for a in m n k h all; do diff pkg/rig/alloc.zig p-$a/rig/alloc.zig > d-$a.diff; echo "$a: $(grep -c '^>' d-$a.diff) lines"; done
