//! `std.datetime`: the wall clock, read through Zig's `std.Io`, and the
//! search of the zone tables tools/gen-tzdb.py generates
//! (tzdb_data.zig, which says how they are laid out). The wall clock is
//! the real clock under the deterministic scheduler too, which makes
//! only the monotonic clock virtual.
//!
//! A zone here is a number: a name's index in tzdb_names.zig, below
//! `test_base`, or `test_base` plus a zone's index in the test table
//! (tzdb_test_data.zig), which only std.datetime's own tests name. The
//! search returns numbers and parses nothing as the program runs: an
//! offset is the zone's type before its first transition, a
//! transition's type up to the next, and from the last transition on the
//! zone's rule, as Jiff reads a zone (jiff-core's tz/tzif/query.rs and
//! tz/posix.rs). Every function is total over the numbers std.datetime
//! gives it.

const std = @import("std");
const rig = @import("../runtime.zig");
const data = @import("tzdb_data.zig");
const names = @import("tzdb_names.zig");
const tests = @import("tzdb_test_data.zig");

pub fn wall_ns() i64 {
    return @intCast(std.Io.Timestamp.now(rig.io(), .real).nanoseconds);
}

// ---- names

/// The first number of a zone of the test table.
const test_base = 0x4000;

/// The data's version, `2026f`.
pub fn tzdb_version() []const u8 {
    return data.version;
}

/// Every name, in the order of their ASCII-lowercase bytes, built as Zig
/// compiles a program that asks for them.
const all_names: [data.name_zones.len][]const u8 = blk: {
    @setEvalBranchQuota(10_000);
    var out: [data.name_zones.len][]const u8 = undefined;
    for (&out, 0..) |*o, i| o.* = nameAt(i);
    break :blk out;
};

pub fn zone_names() []const []const u8 {
    return &all_names;
}

fn nameAt(i: usize) []const u8 {
    return names.text[data.name_starts[i] .. data.name_starts[i + 1] - 1];
}

fn caseless(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return std.math.order(lx, ly);
    }
    return std.math.order(a.len, b.len);
}

/// The zone named `name` in any ASCII case, or -1: a binary search of
/// the names, which are in caseless order.
pub fn zone_find(name: []const u8) i64 {
    var lo: usize = 0;
    var hi: usize = data.name_zones.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (caseless(nameAt(mid), name)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return @intCast(mid),
        }
    }
    return -1;
}

/// The zone of the test table named `name` exactly, or -1.
pub fn test_zone_find(name: []const u8) i64 {
    for (tests.names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return test_base + @as(i64, @intCast(i));
    }
    return -1;
}

/// Zone `id`'s name, in the data's spelling.
pub fn zone_name(id: i64) []const u8 {
    if (id >= test_base) return tests.names[@intCast(id - test_base)];
    return nameAt(@intCast(id));
}

/// Zone `id`'s primary identifier, as a zone: two names are the same
/// zone when their primaries are (Jiff's `tz/db/metadata.rs`). A zone of
/// the test table is its own.
pub fn zone_primary(id: i64) i64 {
    if (id >= test_base) return id;
    return data.name_primaries[@intCast(id)];
}

// ---- offsets

/// Zone `id`'s offset, in seconds east of UTC, at `t` seconds since
/// 1970-01-01T00:00Z.
pub fn zone_offset(id: i64, t: i64) i64 {
    if (id >= test_base) return zoneOffset(tests, tests.zones[@intCast(id - test_base)], t);
    return zoneOffset(data, data.zones[data.name_zones[@intCast(id)]], t);
}

/// How many of `xs` are at most `key`.
fn atMost(xs: []const u32, key: u32) usize {
    var lo: usize = 0;
    var hi: usize = xs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (xs[mid] <= key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// The offset of zone `z` of table `T` at `t`. A transition before 1970
/// is held as its time plus 2^32, after one at or after 1970 as its
/// time, so each half is a sorted u32 array.
fn zoneOffset(comptime T: type, z: data.Zone, t: i64) i64 {
    const types = T.zone_types[z.types..];
    const times = T.times[z.first..][0..z.count];
    const bias: i64 = 1 << 32;
    // n: how many transitions are at or before t.
    const n: usize = if (t < 0)
        (if (t + bias < 0) 0 else atMost(times[0..z.early], @intCast(t + bias)))
    else if (t >= bias)
        z.count
    else
        z.early + atMost(times[z.early..], @intCast(t));
    if (n == z.count and z.rule != data.no_rule) return ruleOffset(T, T.rules[z.rule], t);
    if (n == 0) return T.type_offsets[types[0]];
    return T.type_offsets[types[T.transition_types[z.first + n - 1]]];
}

// ---- the rule after the last transition, as jiff-core's tz/posix.rs

fn ruleOffset(comptime T: type, r: data.Rule, t: i64) i64 {
    const std_off: i64 = T.type_offsets[r.std];
    if (r.dst == data.no_dst) return std_off;
    const dst_off: i64 = T.type_offsets[r.dst];
    const year = yearOf(t);
    const start = dayTime(r.start, year, std_off);
    var end = dayTime(r.end, year, dst_off);
    // Permanent daylight saving written as from January 1 at 00:00 to an
    // end that, in standard time, is in the next year (Jiff's
    // `dst_info_utc`).
    if (start == yearStart(year) and yearOf(end + std_off) != year) end = yearStart(year + 1);
    const in_dst = if (start <= end) start <= t and t < end else !(end <= t and t < start);
    return if (in_dst) dst_off else std_off;
}

/// The instant, clamped to `year`, at which `d` falls in `year` in local
/// time of offset `offset`; the end of the year is `yearStart(year + 1)`,
/// which no instant of the year reaches. Jiff clamps a rule's end to
/// 23:59:59.999999999 of the year's last day, which is the same for
/// every whole second.
fn dayTime(d: data.Day, year: i64, offset: i64) i64 {
    const days = switch (d.kind) {
        .julian1 => daysFromCivil(year, 1, 1) + d.day - 1 + @intFromBool(isLeap(year) and d.day >= 60),
        .julian0 => if (d.day == 365 and !isLeap(year)) return yearStart(year + 1) else daysFromCivil(year, 1, 1) + d.day,
        .weekday => nthWeekday(year, d.month, d.week, d.weekday),
    };
    const at = days * 86400 + d.time - offset;
    if (at < yearStart(year)) return yearStart(year);
    if (at >= yearStart(year + 1)) return yearStart(year + 1);
    return at;
}

fn nthWeekday(year: i64, month: u8, week: u8, weekday: u8) i64 {
    const first = daysFromCivil(year, month, 1);
    // 1970-01-01 was a Thursday (4).
    const first_wd = @mod(first + 4, 7);
    var day = first + @mod(@as(i64, weekday) - first_wd, 7);
    if (week < 5) return day + 7 * (@as(i64, week) - 1);
    const next = if (month == 12) daysFromCivil(year + 1, 1, 1) else daysFromCivil(year, month + 1, 1);
    while (day + 7 < next) day += 7;
    return day;
}

fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

fn yearStart(y: i64) i64 {
    return daysFromCivil(y, 1, 1) * 86400;
}

fn yearOf(t: i64) i64 {
    return civilYear(@divFloor(t, 86400));
}

/// Days since 1970-01-01 of a date on the proleptic Gregorian calendar
/// (Howard Hinnant's algorithm).
fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilYear(days: i64) i64 {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    return yoe + era * 400 + @intFromBool(mp >= 10);
}
