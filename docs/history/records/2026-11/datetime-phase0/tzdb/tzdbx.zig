//! The measuring shim of the zone tables (tools/gen-tzdb.py): a zone's
//! offset at an instant, found by name. It reads the tables as
//! tzdb_data.zig lays them out and the rule after the last transition as
//! Jiff does (jiff-core's tz/tzif/query.rs and tz/posix.rs). It lives in
//! a copy of std made for the measurement (measure.sh), never in std.

const std = @import("std");
const data = @import("tzdb_data.zig");
const names = @import("tzdb_names.zig");

/// The offset, in seconds east of UTC, of the zone named `name` (in any
/// ASCII case) at `t` seconds since 1970; null for an unknown name.
pub fn offset_at(name: []const u8, t: i64) ?i64 {
    const i = find(name) orelse return null;
    return zoneOffset(data.zones[data.name_zones[i]], t);
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

fn find(name: []const u8) ?usize {
    var lo: usize = 0;
    var hi: usize = data.name_zones.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (caseless(nameAt(mid), name)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return mid,
        }
    }
    return null;
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

fn zoneOffset(z: data.Zone, t: i64) i64 {
    const types = data.zone_types[z.types..];
    const times = data.times[z.first..][0..z.count];
    const bias: i64 = 1 << 32;
    // n: how many transitions are at or before t.
    const n: usize = if (t < 0)
        (if (t + bias < 0) 0 else atMost(times[0..z.early], @intCast(t + bias)))
    else if (t >= bias)
        z.count
    else
        z.early + atMost(times[z.early..], @intCast(t));
    if (n == z.count and z.rule != data.no_rule) return ruleOffset(data.rules[z.rule], t);
    if (n == 0) return data.type_offsets[types[0]];
    return data.type_offsets[types[data.transition_types[z.first + n - 1]]];
}

// ---- the rule after the last transition, as jiff-core's tz/posix.rs

fn ruleOffset(r: data.Rule, t: i64) i64 {
    const std_off: i64 = data.type_offsets[r.std];
    if (r.dst == data.no_dst) return std_off;
    const dst_off: i64 = data.type_offsets[r.dst];
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
/// which no instant of the year reaches.
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

/// Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm).
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
