//! `std.crypto`: what its Rig code cannot say. Arm's data-independent
//! timing bit (DIT), set and restored around secret arithmetic; a wipe
//! the optimizer keeps; a value barrier; and the operating system's
//! entropy, for a new secret key.

const std = @import("std");
const builtin = @import("builtin");
const rig = @import("../runtime.zig");

const aarch64 = builtin.cpu.arch == .aarch64;

/// DIT, as `mrs`/`msr` name it by number (S3_3_C4_C2_5), which every
/// assembler takes whatever the target's features. Bit 24 is the flag.
const dit_flag: u64 = 1 << 24;

/// Whether this core has DIT (ARMv8.4's FEAT_DIT). Known at compile time
/// when the target has it (every Apple core does); on Linux otherwise,
/// asked of the kernel once: 0 not yet asked, 1 no, 2 yes.
var dit_known: std.atomic.Value(u8) = .init(0);

fn hasDit() bool {
    if (!aarch64) return false;
    if (comptime std.Target.aarch64.featureSetHas(builtin.cpu.features, .dit)) return true;
    if (builtin.os.tag != .linux) return false;
    switch (dit_known.load(.monotonic)) {
        1 => return false,
        2 => return true,
        else => {
            const yes = std.os.linux.getauxval(std.elf.AT_HWCAP) & std.os.linux.HWCAP.DIT != 0;
            dit_known.store(if (yes) 2 else 1, .monotonic);
            return yes;
        },
    }
}

/// Sets DIT, so the core's timing does not depend on the data it works
/// on, and gives the earlier state for `dit_restore`. Elsewhere, and on a
/// core without DIT, it does nothing and gives 0.
pub fn dit_on() u64 {
    if (comptime !aarch64) return 0;
    if (!hasDit()) return 0;
    const old = asm volatile ("mrs %[old], S3_3_C4_C2_5"
        : [old] "=r" (-> u64),
    );
    asm volatile ("msr S3_3_C4_C2_5, %[on]"
        :
        : [on] "r" (dit_flag),
        : .{ .memory = true });
    return old;
}

/// Puts DIT back as `dit_on` found it.
pub fn dit_restore(old: u64) void {
    if (comptime !aarch64) return;
    if (!hasDit()) return;
    asm volatile ("msr S3_3_C4_C2_5, %[old]"
        :
        : [old] "r" (old & dit_flag),
        : .{ .memory = true });
}

/// Zeroes `b` with volatile stores, which the optimizer keeps even when
/// nothing reads `b` again.
pub fn wipe(b: []u8) void {
    std.crypto.secureZero(u8, b);
}

/// `x`, through an empty `asm` the optimizer cannot see into: a mask made
/// from a secret stays a mask, never turned into a branch.
pub fn barrier(x: u64) u64 {
    var v = x;
    asm volatile (""
        : [v] "+r" (v),
    );
    return v;
}

/// Fills `b` from the operating system's entropy; panics when it has none.
pub fn entropy(b: []u8) void {
    rig.io().randomSecure(b) catch |err| std.debug.panic("crypto: no entropy from the operating system ({s})", .{@errorName(err)});
}

/// Zeroes the words of `w` as `wipe` zeroes bytes.
pub fn wipe_words(w: []u32) void {
    std.crypto.secureZero(u32, w);
}
