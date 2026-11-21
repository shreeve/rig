#!/usr/bin/env python3
"""Generate the zone tables of std.datetime from Jiff's bundle of the IANA
Time Zone Database: tzdb_data.zig (the zones), tzdb_names.zig (their
names), and tzdb_test_data.zig (the test table).

    tools/gen-tzdb.py [--cache DIR] [--check] [OUT]

OUT is the directory written (default zig-out/tzdb, which git ignores).
The inputs are the crates `jiff` and `jiff-tzdb` of JIFF_VERSION, from
crates.io, and the test zone file below, from Jiff's repository at the
commit those crates were published from; each is used only when its
sha256 is the pinned one, so every run writes the same bytes. They are
read from DIR ($RIG_TZDB by default, else ~/.cache/rig-tzdb) and fetched
when absent. A crate is read as an archive and never unpacked or run.
`--check` writes nothing and fails when a file in OUT differs from the
one generated.

The data: jiff-tzdb's concatenated-zoneinfo.dat holds one TZif file
(RFC 9636, version 2 or later, "slim") per distinct zone, and tzname.rs
maps each of the 598 names to one. Each name's primary identifier comes
from jiff's src/tz/db/metadata.rs. A zone is what Jiff reads from its
file (jiff-core's tzif/parser.rs and tz/posix.rs): before the first
transition, local type 0; from a transition up to the next, that
transition's type; from the last transition on, the footer's POSIX TZ
rule (all of them, when there are no transitions), or the last type
when there is no footer. Jiff decides by offsets, so the daylight-saving
flag is dropped and a local type is its offset and abbreviation.

The layout (tzdb_data.zig says it again for its reader):

- `times` holds every zone's transitions, in seconds since 1970, each
  as a u32: the zone's first `early` transitions, those before 1970, as
  t + 2^32, and the rest as t. So each half is a plain sorted u32 array
  that a binary search reads directly, and four bytes cover 1833 to 2106
  (the data spans 1845 to 2086) where an i64 would take eight. The
  generator refuses a transition outside that range.
- `transition_types` holds each transition's local type, a u8 index into
  its zone's run of `zone_types` (at most 11 in a zone); `zone_types`
  holds u16 indexes of the shared types, and a zone's type 0 is the type
  before its first transition.
- The 557 distinct types are `type_offsets` (i32 seconds east of UTC)
  and `type_abbrs` (a u8 index of the 178 abbreviations, one string
  `abbr_text` cut at `abbr_starts`).
- `rules` holds the 94 distinct POSIX rules, parsed: the standard and
  daylight-saving types, and each end's day and local time.
- `zones` holds per zone its first transition, how many it has, how many
  are early, its first type, and its rule. Zones are deduplicated: the
  598 names share 345.
- Names: tzdb_names.zig holds the names, one a line, in the order of
  their ASCII-lowercase bytes (Jiff's), so a case-blind binary search
  finds one; the compiler reads it to check a literal name. The data
  cuts it at `name_starts` and maps each name to its zone (`name_zones`)
  and to its primary identifier (`name_primaries`, a name index).

The test table holds two zones whose rules do not change with the data,
in the same layout: Europe/Dublin in the standard form (negative daylight
saving: winter is the flagged half), Jiff's test file, and Test/Morocco,
no transitions and the made-up rule of permanent daylight saving that
Jiff tests (`XXX-2<+01>-1,0/0,J365/23`, jiff's src/tz/posix.rs, issue
386).
"""
import argparse
import hashlib
import io
import json
import os
import re
import struct
import sys
import tarfile
import urllib.request

JIFF_VERSION = "1.0.0"
# The commit both crates were published from (each crate's
# .cargo_vcs_info.json says so, and the generator checks it).
JIFF_COMMIT = "3b1bdf9d787e23ae840cf32e765caac32b7ad8ee"
TZDB_VERSION = "2026f"
CRATE_URL = "https://static.crates.io/crates/%s/%s-%s.crate"
REPO_URL = "https://raw.githubusercontent.com/BurntSushi/jiff/%s/%s"
# file name in the cache -> (url, sha256). The crates' sums are the ones
# the crates.io index gives (`cksum`).
PINNED = {
    "jiff-1.0.0.crate": (CRATE_URL % ("jiff", "jiff", JIFF_VERSION),
                         "9cc767b5763de45e810109520123bb2829a653f3a7ed9be40b2bc4f81158f595"),
    "jiff-tzdb-1.0.0.crate": (CRATE_URL % ("jiff-tzdb", "jiff-tzdb", JIFF_VERSION),
                              "12e71a1b68a875a44a33bb7a1dd84392cb77145a3367a552a3cfe6a4f5cf3afc"),
    "europe-dublin.tzif": (REPO_URL % (JIFF_COMMIT, "crates/jiff/src/tz/testdata/europe-dublin.tzif"),
                           "40e8d2a1c3b572284da39f6f4245b1bc814f452c44f5aa73d0a011571d5ccc43"),
}
# The made-up Morocco rule, which must appear in jiff's own source.
MOROCCO_RULE = "XXX-2<+01>-1,0/0,J365/23"
MOROCCO_SOURCE = "src/tz/posix.rs"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(ROOT, "zig-out", "tzdb")
EARLY_BIAS = 1 << 32
NO_RULE = 255
NO_DST = 0xFFFF


def fail(msg):
    sys.exit("gen-tzdb: " + msg)


def pinned(cache, name):
    """The bytes of the pinned file `name`, fetched into `cache` when absent."""
    url, pin = PINNED[name]
    path = os.path.join(cache, name)
    if not os.path.exists(path):
        os.makedirs(cache, exist_ok=True)
        with urllib.request.urlopen(url) as r:
            data = r.read()
        if hashlib.sha256(data).hexdigest() != pin:
            fail("%s: the download from %s is not the pinned file" % (name, url))
        with open(path + ".part", "wb") as f:
            f.write(data)
        os.replace(path + ".part", path)
    with open(path, "rb") as f:
        data = f.read()
    if hashlib.sha256(data).hexdigest() != pin:
        fail("%s: sha256 is not the pinned %s" % (path, pin))
    return data


def crate_files(data, crate, wanted):
    """{name: bytes} of the files `wanted` in the crate archive `data`,
    read in memory; the crate must come from JIFF_COMMIT."""
    top = "%s-%s/" % (crate, JIFF_VERSION)
    out = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for name in wanted + [".cargo_vcs_info.json"]:
            member = tar.getmember(top + name)
            if not member.isfile():
                fail("%s: %s is not a file" % (crate, name))
            out[name] = tar.extractfile(member).read()
    vcs = json.loads(out.pop(".cargo_vcs_info.json"))
    if vcs["git"]["sha1"] != JIFF_COMMIT:
        fail("%s: published from %s, not %s" % (crate, vcs["git"]["sha1"], JIFF_COMMIT))
    return out


# ---- the names and their files

def tznames(source):
    """(version, [(name, start, end)]) from jiff-tzdb's tzname.rs."""
    text = source.decode("utf-8")
    m = re.search(r'^pub\(super\) static VERSION: &str = "([^"]+)";$', text, re.M)
    if not m:
        fail("tzname.rs: no VERSION")
    head = "pub(super) static TZNAME_TO_OFFSET: &[(&str, core::ops::Range<usize>)] = &[\n"
    start = text.index(head) + len(head)
    end = text.index("];\n", start)
    out = []
    for line in text[start:end].splitlines():
        e = re.fullmatch(r'    \(r"([A-Za-z0-9_+\-/]+)", (\d+)\.\.(\d+)\),', line)
        if not e:
            fail("tzname.rs: cannot read %r" % line)
        out.append((e.group(1), int(e.group(2)), int(e.group(3))))
    return m.group(1), out


def primaries(source):
    """{name: primary identifier} from jiff's tz/db/metadata.rs."""
    text = source.decode("utf-8")
    head = "pub(super) static TIME_ZONE_PRIMARY_IDENTIFIER: &[(&str, &str)] = &[\n"
    start = text.index(head) + len(head)
    end = text.index("];\n", start)
    out = {}
    for line in text[start:end].splitlines():
        e = re.fullmatch(r'    \("([A-Za-z0-9_+\-/]+)", "([A-Za-z0-9_+\-/]+)"\),', line)
        if not e:
            fail("metadata.rs: cannot read %r" % line)
        out[e.group(1)] = e.group(2)
    return out


def caseless(name):
    return name.encode("ascii").lower()


# ---- TZif (RFC 9636)

def tzif(data, where):
    """(times, types, footer): the transitions [(t, type index)], the local
    types [(offset, abbreviation)] and the footer, of a TZif file of
    version 2 or later, the 64-bit block; refuses what Jiff refuses and
    leap seconds, which the bundle never has."""
    def header(p):
        if data[p:p + 4] != b"TZif":
            fail("%s: no TZif header at %d" % (where, p))
        if data[p + 4] not in b"234":
            fail("%s: TZif version %r, not 2 or later" % (where, data[p + 4:p + 5]))
        isut, isstd, leap, timecnt, typecnt, charcnt = struct.unpack(">6L", data[p + 20:p + 44])
        if typecnt == 0 or (isut not in (0, typecnt)) or (isstd not in (0, typecnt)):
            fail("%s: bad TZif counts" % where)
        return isut, isstd, leap, timecnt, typecnt, charcnt
    isut, isstd, leap, timecnt, typecnt, charcnt = header(0)
    p = 44 + timecnt * 5 + typecnt * 6 + charcnt + leap * 8 + isstd + isut
    isut, isstd, leap, timecnt, typecnt, charcnt = header(p)
    if leap:
        fail("%s: leap seconds" % where)
    p += 44
    times = struct.unpack(">%dq" % timecnt, data[p:p + 8 * timecnt])
    p += 8 * timecnt
    idx = data[p:p + timecnt]
    p += timecnt
    raw = [struct.unpack(">lBB", data[p + 6 * i:p + 6 * i + 6]) for i in range(typecnt)]
    p += 6 * typecnt
    chars = data[p:p + charcnt]
    p += charcnt + isstd + isut
    if data[p:p + 1] != b"\n":
        fail("%s: no footer" % where)
    e = data.index(b"\n", p + 1)
    footer = data[p + 1:e].decode("ascii")
    if e + 1 != len(data):
        fail("%s: %d bytes after the footer" % (where, len(data) - e - 1))
    types = []
    for off, dst, ai in raw:
        if dst > 1 or ai >= charcnt or b"\0" not in chars[ai:]:
            fail("%s: bad local time type" % where)
        if not -93599 <= off <= 93599:
            fail("%s: offset %d out of range" % (where, off))
        types.append((off, chars[ai:chars.index(b"\0", ai)].decode("ascii")))
    for i, t in enumerate(times):
        if idx[i] >= typecnt:
            fail("%s: transition %d names type %d of %d" % (where, i, idx[i], typecnt))
        if i and t <= times[i - 1]:
            fail("%s: transitions out of order at %d" % (where, i))
    return [(t, idx[i]) for i, t in enumerate(times)], types, footer


# ---- POSIX TZ rules, as jiff-core's tz/posix.rs reads a TZif footer

class Posix:
    def __init__(self, text, where):
        self.s, self.i, self.where = text, 0, where

    def bad(self, what):
        fail("%s: footer %r: %s at %d" % (self.where, self.s, what, self.i))

    def peek(self):
        return self.s[self.i] if self.i < len(self.s) else ""

    def number(self, most, exact=False):
        start = self.i
        while self.i < len(self.s) and self.s[self.i].isdigit() and self.i - start < most:
            self.i += 1
        if self.i == start or (exact and self.i - start != most):
            self.bad("expected a number")
        return int(self.s[start:self.i])

    def ranged(self, lo, hi, most, exact=False):
        n = self.number(most, exact)
        if not lo <= n <= hi:
            self.bad("%d not in %d..%d" % (n, lo, hi))
        return n

    def abbr(self):
        start = self.i
        if self.peek() == "<":
            self.i += 1
            while self.peek().isalnum() or self.peek() in "+-":
                self.i += 1
            name = self.s[start + 1:self.i]
            if self.peek() != ">":
                self.bad("unclosed abbreviation")
            self.i += 1
        else:
            while self.peek().isalpha():
                self.i += 1
            name = self.s[start:self.i]
        if not 3 <= len(name) <= 30 or not name.isascii():
            self.bad("abbreviation %r" % name)
        return name

    def hms(self, hours, most):
        sign = 1
        if self.peek() in "+-":
            sign = -1 if self.peek() == "-" else 1
            self.i += 1
        h = self.ranged(0, hours, most)
        m = s = 0
        if self.peek() == ":":
            self.i += 1
            m = self.ranged(0, 59, 2, True)
            if self.peek() == ":":
                self.i += 1
                s = self.ranged(0, 59, 2, True)
        return sign * (h * 3600 + m * 60 + s)

    def offset(self):
        """A POSIX offset, west positive, as seconds east of UTC."""
        return -self.hms(24, 2)

    def day(self):
        c = self.peek()
        if c == "J":
            self.i += 1
            d = ("julian1", self.ranged(1, 365, 3), 0, 0, 0)
        elif c.isdigit():
            d = ("julian0", self.ranged(0, 365, 3), 0, 0, 0)
        elif c == "M":
            self.i += 1
            month = self.ranged(1, 12, 2)
            if self.peek() != ".":
                self.bad("expected '.'")
            self.i += 1
            week = self.ranged(1, 5, 1, True)
            if self.peek() != ".":
                self.bad("expected '.'")
            self.i += 1
            weekday = self.ranged(0, 6, 1, True)
            d = ("weekday", 0, month, week, weekday)
        else:
            self.bad("expected a day")
        time = 7200
        if self.peek() == "/":
            self.i += 1
            time = self.hms(167, 3)
        return d + (time,)

    def parse(self):
        """((std offset, std abbr), (dst offset, dst abbr) or None, start, end)."""
        std_abbr = self.abbr()
        std = (self.offset(), std_abbr)
        dst = start = end = None
        if self.i < len(self.s):
            dst_abbr = self.abbr()
            dst_off = std[0] + 3600
            if self.peek() != ",":
                dst_off = self.offset()
            if self.peek() != ",":
                self.bad("expected ',' and a rule")
            self.i += 1
            start = self.day()
            if self.peek() != ",":
                self.bad("expected ','")
            self.i += 1
            end = self.day()
            dst = (dst_off, dst_abbr)
        if self.i != len(self.s):
            self.bad("left over")
        return std, dst, start, end


# ---- the tables

class Tables:
    """Zones in the shared layout, deduplicated as they are added."""

    def __init__(self):
        self.zones = []          # (first, count, early, types, rule)
        self.times = []          # u32
        self.local = []          # u8, per transition
        self.zone_types = []     # u16
        self.types = {}          # (offset, abbr) -> index; ordered at finish
        self.rules = {}          # parsed rule -> index
        self.seen = {}           # TZif bytes -> zone index

    def type_key(self, t):
        self.types.setdefault(t, None)
        return t

    def add(self, data, where):
        """The index of the zone of the TZif file `data`."""
        if data not in self.seen:
            self.seen[data] = self.add_zone(*tzif(data, where), where)
        return self.seen[data]

    def add_zone(self, trans, types, footer, where):
        """Add a zone of transitions [(t, type index)], local types
        [(offset, abbreviation)] and a POSIX footer; its index."""
        # The zone's own types, without the daylight-saving flag, in order of
        # their first index, so its type 0 stays 0.
        local_of = []
        local = []
        for t in types:
            if t not in local:
                local.append(t)
            local_of.append(local.index(t))
        if len(local) > 255:
            fail("%s: %d local types" % (where, len(local)))
        early = 0
        first = len(self.times)
        for t, ti in trans:
            if not -EARLY_BIAS <= t < EARLY_BIAS:
                fail("%s: transition %d does not fit the u32 layout" % (where, t))
            if t < 0:
                early += 1
                self.times.append(t + EARLY_BIAS)
            else:
                self.times.append(t)
            self.local.append(local_of[ti])
        rule = NO_RULE
        if footer:
            std, dst, start, end = Posix(footer, where).parse()
            key = (self.type_key(std), self.type_key(dst) if dst else None, start, end)
            if key not in self.rules:
                self.rules[key] = len(self.rules)
            rule = self.rules[key]
            if rule >= NO_RULE:
                fail("too many rules")
        types_at = len(self.zone_types)
        self.zone_types.extend(self.type_key(t) for t in local)
        self.zones.append((first, len(trans), early, types_at, rule))
        if len(self.times) > 0xFFFF or len(self.zone_types) > 0xFFFF:
            fail("more than 65535 transitions or types")
        return len(self.zones) - 1

    def finish(self):
        """Order the shared types and the abbreviations; returns nothing."""
        order = sorted(self.types)
        self.type_index = {t: i for i, t in enumerate(order)}
        self.type_list = order
        self.abbrs = sorted(set(a for _, a in order))
        if len(self.abbrs) > 255:
            fail("more than 255 abbreviations")
        abbr_index = {a: i for i, a in enumerate(self.abbrs)}
        self.type_abbr = [abbr_index[a] for _, a in order]
        self.zone_types = [self.type_index[t] for t in self.zone_types]
        self.rule_list = [None] * len(self.rules)
        for (std, dst, start, end), i in self.rules.items():
            self.rule_list[i] = (self.type_index[std], self.type_index[dst] if dst else NO_DST, start, end)


def rows(items, per, fmt="%d"):
    return "\n".join("    " + " ".join(fmt % x + "," for x in items[i:i + per])
                     for i in range(0, len(items), per))


def zig_day(d):
    kind, day, month, week, weekday, time = d
    return ".{ .kind = .%s, .day = %d, .month = %d, .week = %d, .weekday = %d, .time = %d }" % (
        kind, day, month, week, weekday, time)


def zig_rule(r):
    std, dst, start, end = r
    if dst == NO_DST:
        return "    .{ .std = %d, .dst = no_dst, .start = .{}, .end = .{} }," % std
    return "    .{ .std = %d, .dst = %d,\n       .start = %s,\n       .end = %s }," % (
        std, dst, zig_day(start), zig_day(end))


def body(tb):
    """The shared declarations of a table, as Zig."""
    abbr_starts = [0]
    for a in tb.abbrs:
        abbr_starts.append(abbr_starts[-1] + len(a))
    out = []
    out.append("/// Each zone, in the order of the first name that names it.")
    out.append("pub const zones = [%d]Zone{" % len(tb.zones))
    out.extend("    .{ .first = %d, .count = %d, .early = %d, .types = %d, .rule = %s }," % (
        f, c, e, t, "no_rule" if r == NO_RULE else str(r)) for f, c, e, t, r in tb.zones)
    out.append("};")
    out.append("")
    out.append("/// The transitions of every zone, seconds since 1970: a zone's first")
    out.append("/// `early` as t + 2^32, the rest as t.")
    out.append("pub const times = [%d]u32{" % len(tb.times))
    out.append(rows(tb.times, 8))
    out.append("};")
    out.append("")
    out.append("/// Each transition's local type: an index into its zone's `zone_types`.")
    out.append("pub const transition_types = [%d]u8{" % len(tb.local))
    out.append(rows(tb.local, 24))
    out.append("};")
    out.append("")
    out.append("/// Each zone's local types, indexes into `type_offsets` and `type_abbrs`.")
    out.append("pub const zone_types = [%d]u16{" % len(tb.zone_types))
    out.append(rows(tb.zone_types, 16))
    out.append("};")
    out.append("")
    out.append("/// Each type's offset, in seconds east of UTC.")
    out.append("pub const type_offsets = [%d]i32{" % len(tb.type_list))
    out.append(rows([o for o, _ in tb.type_list], 12))
    out.append("};")
    out.append("")
    out.append("/// Each type's abbreviation: an index into `abbr_starts`.")
    out.append("pub const type_abbrs = [%d]u8{" % len(tb.type_abbr))
    out.append(rows(tb.type_abbr, 24))
    out.append("};")
    out.append("")
    out.append("/// The abbreviations, abbreviation i at `abbr_text[abbr_starts[i]..abbr_starts[i + 1]]`.")
    out.append("pub const abbr_text = \"%s\";" % "".join(tb.abbrs))
    out.append("pub const abbr_starts = [%d]u16{" % len(abbr_starts))
    out.append(rows(abbr_starts, 16))
    out.append("};")
    out.append("")
    out.append("/// The rules after the last transition.")
    out.append("pub const rules = [%d]Rule{" % len(tb.rule_list))
    out.extend(zig_rule(r) for r in tb.rule_list)
    out.append("};")
    return "\n".join(out)


TYPES = '''/// A zone: its transitions are `times[first..][0..count]` with their
/// types in `transition_types`, the first `early` of them before 1970.
pub const Zone = struct {
    first: u16,
    count: u16,
    early: u16,
    /// Its local types start at `zone_types[types]`; its type 0 holds
    /// before its first transition.
    types: u16,
    /// Its rule from the last transition on (for all time when `count`
    /// is 0), an index into `rules`, or `no_rule`: the last type holds.
    rule: u8,
};

pub const no_rule: u8 = 255;
pub const no_dst: u16 = 0xFFFF;

/// A POSIX TZ rule, as a TZif footer gives it (RFC 9636 section 3.3).
pub const Rule = struct {
    /// Standard time's type, an index into `type_offsets` and `type_abbrs`.
    std: u16,
    /// Daylight-saving time's type, or `no_dst` (then `start` and `end`
    /// are unused).
    dst: u16,
    /// Daylight saving starts at `start`, in standard local time, and
    /// ends at `end`, in daylight-saving local time.
    start: Day,
    end: Day,
};

/// A day of a year and a local time on it.
pub const Day = struct {
    /// `julian1` is `Jn`: `day` 1 to 365, February 29 never counted.
    /// `julian0` is `n`: `day` 0 to 365, February 29 counted.
    /// `weekday` is `Mm.w.d`: weekday `weekday` (0 is Sunday) of week
    /// `week` (5 is the last) of month `month`.
    kind: enum(u8) { julian1, julian0, weekday } = .weekday,
    day: u16 = 0,
    month: u8 = 0,
    week: u8 = 0,
    weekday: u8 = 0,
    /// Seconds after local midnight, -167 to 167 hours.
    time: i32 = 0,
};'''


def data_source(version, tb, names, zone_of, primary_of):
    starts = [0]
    for n in names:
        starts.append(starts[-1] + len(n) + 1)
    head = '''//! The zone data of std.datetime: the IANA Time Zone Database %s,
//! from Jiff's bundle (jiff-tzdb %s). Generated by tools/gen-tzdb.py,
//! which says how it is laid out; never edit it. %d names, %d zones,
//! %d transitions, %d types, %d rules.

pub const version = "%s";
''' % (version, JIFF_VERSION, len(names), len(tb.zones), len(tb.times), len(tb.type_list),
       len(tb.rule_list), version)
    tail = '''
/// Where each name starts in tzdb_names.zig's `text`; name i ends one
/// byte before `name_starts[i + 1]`.
pub const name_starts = [%d]u16{
%s
};

/// Each name's zone, an index into `zones`.
pub const name_zones = [%d]u16{
%s
};

/// Each name's primary identifier, a name index: two names are one zone
/// for equality when these agree.
pub const name_primaries = [%d]u16{
%s
};
''' % (len(starts), rows(starts, 12), len(zone_of), rows(zone_of, 16), len(primary_of), rows(primary_of, 16))
    return head + "\n" + TYPES + "\n\n" + body(tb) + "\n" + tail


def names_source(version, names):
    lines = "\n".join("    \\\\" + n for n in names)
    return '''//! The names of the zones of std.datetime (the IANA Time Zone Database
//! %s), one a line in `text`, in the order of their ASCII-lowercase
//! bytes. Generated by tools/gen-tzdb.py; never edit it.

pub const text =
%s
;
''' % (version, lines)


def test_source(tb, names):
    return '''//! The test table of std.datetime: zones whose rules do not change with
//! the data, laid out as tzdb_data.zig is. Generated by
//! tools/gen-tzdb.py; never edit it.

const data = @import("tzdb_data.zig");
pub const Zone = data.Zone;
pub const Rule = data.Rule;
pub const Day = data.Day;
pub const no_rule = data.no_rule;
pub const no_dst = data.no_dst;

/// Zone i is named `names[i]`.
pub const names = [_][]const u8{ %s };

%s
''' % (", ".join('"%s"' % n for n in names), body(tb))


def generate(cache):
    jiff = crate_files(pinned(cache, "jiff-1.0.0.crate"), "jiff", ["src/tz/db/metadata.rs", MOROCCO_SOURCE])
    tzdb = crate_files(pinned(cache, "jiff-tzdb-1.0.0.crate"), "jiff-tzdb", ["tzname.rs", "concatenated-zoneinfo.dat"])
    version, entries = tznames(tzdb["tzname.rs"])
    if version != TZDB_VERSION:
        fail("jiff-tzdb holds %s, not %s" % (version, TZDB_VERSION))
    blob = tzdb["concatenated-zoneinfo.dat"]
    names = [n for n, _, _ in entries]
    for a, b in zip(names, names[1:]):
        if not caseless(a) < caseless(b):
            fail("tzname.rs: %s and %s are not in caseless order" % (a, b))
    prim = primaries(jiff["src/tz/db/metadata.rs"])
    if set(prim) != set(names):
        fail("metadata.rs names other zones than tzname.rs")
    index = {n: i for i, n in enumerate(names)}
    tb = Tables()
    zone_of = []
    for name, a, b in entries:
        if not 0 <= a < b <= len(blob):
            fail("%s: range %d..%d" % (name, a, b))
        zone_of.append(tb.add(blob[a:b], "jiff-tzdb %s (%d..%d)" % (name, a, b)))
    tb.finish()
    primary_of = []
    for n in names:
        p = prim[n]
        if prim.get(p) != p:
            fail("%s: primary %s is not its own primary" % (n, p))
        primary_of.append(index[p])
    if len(names) > 0xFFFF or sum(len(n) + 1 for n in names) > 0xFFFF:
        fail("too many names")

    if MOROCCO_RULE not in jiff[MOROCCO_SOURCE].decode("utf-8"):
        fail("jiff's %s no longer holds %s" % (MOROCCO_SOURCE, MOROCCO_RULE))
    tt = Tables()
    tt.add(pinned(cache, "europe-dublin.tzif"), "europe-dublin.tzif")
    # No transitions, the rule's standard type as type 0, and the rule.
    tt.add_zone([], [Posix(MOROCCO_RULE, "Test/Morocco").parse()[0]], MOROCCO_RULE, "Test/Morocco")
    tt.finish()
    return [("tzdb_names.zig", names_source(version, names)),
            ("tzdb_data.zig", data_source(version, tb, names, zone_of, primary_of)),
            ("tzdb_test_data.zig", test_source(tt, ["Europe/Dublin", "Test/Morocco"]))]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cache", help="directory of the pinned inputs")
    ap.add_argument("--check", action="store_true", help="fail when a file in OUT differs")
    ap.add_argument("out", nargs="?", default=DEFAULT_OUT, help="directory written")
    args = ap.parse_args()
    cache = args.cache or os.environ.get("RIG_TZDB") or os.path.expanduser("~/.cache/rig-tzdb")
    outputs = generate(cache)
    bad = False
    for name, text in outputs:
        path = os.path.join(args.out, name)
        if args.check:
            try:
                with open(path, encoding="utf-8") as f:
                    same = f.read() == text
            except FileNotFoundError:
                same = False
            if not same:
                print("%s is not what tools/gen-tzdb.py generates" % path, file=sys.stderr)
                bad = True
        else:
            os.makedirs(args.out, exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            print("wrote", path)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
