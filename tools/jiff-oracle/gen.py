#!/usr/bin/env python3
"""The inputs of the Jiff oracle (README.md), and the check of its zone data.

    gen.py DIR                 write DIR/calendar.in, zones.in, counts.in,
                               text.in and round.in
    gen.py --kind KIND         write one kind to stdout
    gen.py --bundle-check BIN  check that BIN, the oracle, answers from
                               Jiff's bundled 2026f data and nothing else

Every input is the same on every run and every machine: the values come
from a fixed seed and the zone data that jiff-tzdb 1.0.0 bundles, which is
read from the copy Cargo fetched for this folder (`cargo metadata
--locked`; Cargo checks it against the checksum in Cargo.lock). The
bundle is decoded here, independently of Jiff: its TZif records and the
POSIX rule at the end of each.
"""

import bisect
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TZDB_VERSION = "2026f"

# Through this year every transition is tested, explicit or from a rule;
# after it, a zone's rule is tested in a few years more.
HORIZON = 2040
RULE_YEARS = (2100, 2400, 9998)

# Zones with every kind of change: the US, a southern rule, a 30-minute
# change, a skipped date, Dublin and Morocco (flagged the other way round),
# a day that starts at 01:00, a late-evening change, a repeated time across
# midnight, Brazil's dropped rule, a historic offset in seconds, and three
# with no change.
ZONES = [
    "America/New_York", "America/Denver", "America/St_Johns", "America/Havana",
    "America/Nuuk", "America/Sao_Paulo", "America/Toronto", "Australia/Lord_Howe",
    "Australia/Sydney", "Pacific/Apia", "Pacific/Chatham", "Europe/Dublin",
    "Europe/London", "Europe/Paris", "Africa/Casablanca", "Africa/Monrovia",
    "Africa/Cairo", "Asia/Beirut", "America/Santiago", "Antarctica/Casey",
    "Antarctica/Troll", "Asia/Kolkata", "Asia/Tokyo", "UTC",
]


# --- Random numbers: splitmix64, so that the inputs never depend on
# Python's own generator.

class Rand:
    def __init__(self, seed):
        self.s = seed & 0xFFFFFFFFFFFFFFFF

    def next(self):
        self.s = (self.s + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        z = self.s
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & 0xFFFFFFFFFFFFFFFF
        return z ^ (z >> 31)

    def below(self, n):
        return self.next() % n

    def range(self, lo, hi):
        """An integer in lo..hi, both included."""
        return lo + self.below(hi - lo + 1)

    def pick(self, seq):
        return seq[self.below(len(seq))]


# --- The proleptic Gregorian calendar, for any year.

def is_leap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def days_in_month(y, m):
    return (31, 29 if is_leap(y) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[m - 1]


def days_from_civil(y, m, d):
    y -= m <= 2
    era = y // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def civil_from_days(z):
    z += 719468
    era = z // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + (3 if mp < 10 else -9)
    return y + (m <= 2), m, d


def weekday(days):
    """0 is Sunday, as in a POSIX rule."""
    return (days + 4) % 7


NS = 1_000_000_000
DAY = 86400
MIN_DAY = days_from_civil(-9999, 1, 1)
MAX_DAY = days_from_civil(9999, 12, 31)
# The range of instants, in seconds (§7.1).
MIN_INSTANT = days_from_civil(-9999, 1, 2) * DAY + 1 * 3600 + 59 * 60 + 59
MAX_INSTANT = days_from_civil(9999, 12, 30) * DAY + 22 * 3600


# --- Text, as Jiff prints it.

def fmt_year(y):
    return "%04d" % y if 0 <= y <= 9999 else ("-" if y < 0 else "+") + "%06d" % abs(y)


def fmt_date_days(days):
    y, m, d = civil_from_days(days)
    return "%s-%02d-%02d" % (fmt_year(y), m, d)


def fmt_frac(ns):
    return ("." + ("%09d" % ns).rstrip("0")) if ns else ""


def fmt_time(secs, ns=0):
    return "%02d:%02d:%02d%s" % (secs // 3600, secs // 60 % 60, secs % 60, fmt_frac(ns))


def fmt_datetime(secs, ns=0):
    """A date and time given as seconds from 1970-01-01T00:00 on the clock."""
    return fmt_date_days(secs // DAY) + "T" + fmt_time(secs % DAY, ns)


def fmt_instant(secs, ns=0):
    return fmt_datetime(secs, ns) + "Z"


def fmt_dur(total_ns):
    """A duration in ISO 8601, as Jiff prints it (and Rig's `iso()`)."""
    sign = "-" if total_ns < 0 else ""
    s, ns = divmod(abs(total_ns), NS)
    h, m, s = s // 3600, s // 60 % 60, s % 60
    t = ("%dH" % h if h else "") + ("%dM" % m if m else "")
    if s or ns or not t:
        t += "%d%sS" % (s, fmt_frac(ns))
    return sign + "PT" + t


def fmt_dur_seconds(total_ns):
    """The same duration in seconds alone, which reads as the same."""
    sign = "-" if total_ns < 0 else ""
    s, ns = divmod(abs(total_ns), NS)
    return "%sPT%d%sS" % (sign, s, fmt_frac(ns))


def fmt_offset(secs, colon=True, seconds=True):
    sign = "-" if secs < 0 else "+"
    a = abs(secs)
    h, m, s = a // 3600, a // 60 % 60, a % 60
    sep = ":" if colon else ""
    t = "%s%02d%s%02d" % (sign, h, sep, m)
    if s and seconds:
        t += "%s%02d" % (sep, s)
    return t


# --- The bundle: jiff-tzdb 1.0.0's TZif records, and their POSIX rules.

def bundle_dir():
    out = subprocess.run(
        ["cargo", "metadata", "--locked", "--format-version", "1"],
        cwd=HERE, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("gen.py: cargo metadata failed:\n" + out.stderr)
    for p in json.loads(out.stdout)["packages"]:
        if p["name"] == "jiff-tzdb" and p["source"]:
            if p["version"] != "1.0.0":
                sys.exit("gen.py: jiff-tzdb is %s, not 1.0.0" % p["version"])
            return os.path.dirname(p["manifest_path"])
    sys.exit("gen.py: Cargo.lock names no jiff-tzdb")


def parse_offset(s, i):
    """[+-]hh[:mm[:ss]] at s[i:], as seconds: (value, next index)."""
    sign = 1
    if s[i] in "+-":
        sign = -1 if s[i] == "-" else 1
        i += 1
    m = re.compile(r"(\d{1,3})(?::(\d{2}))?(?::(\d{2}))?").match(s, i)
    h, mi, se = m.group(1), m.group(2) or "0", m.group(3) or "0"
    return sign * (int(h) * 3600 + int(mi) * 60 + int(se)), m.end()


def parse_abbr(s, i):
    if s[i] == "<":
        j = s.index(">", i)
        return s[i + 1:j], j + 1
    j = i
    while j < len(s) and s[j].isalpha():
        j += 1
    return s[i:j], j


def parse_rule_date(s, i):
    if s[i] == "J":
        m = re.compile(r"J(\d+)").match(s, i)
        return ("J", int(m.group(1))), m.end()
    if s[i] == "M":
        m = re.compile(r"M(\d+)\.(\d)\.(\d)").match(s, i)
        return ("M", int(m.group(1)), int(m.group(2)), int(m.group(3))), m.end()
    m = re.compile(r"(\d+)").match(s, i)
    return ("N", int(m.group(1))), m.end()


class Posix:
    """A POSIX TZ rule, as the footer of a TZif record gives it."""

    def __init__(self, s):
        self.text = s
        self.std_abbr, i = parse_abbr(s, 0)
        off, i = parse_offset(s, i)
        self.std = -off
        self.dst = None
        if i < len(s):
            self.dst_abbr, i = parse_abbr(s, i)
            if i < len(s) and s[i] != ",":
                off, i = parse_offset(s, i)
                self.dst = -off
            else:
                self.dst = self.std + 3600
            assert s[i] == ",", s
            self.start, i = parse_rule_date(s, i + 1)
            self.start_time = 7200
            if i < len(s) and s[i] == "/":
                self.start_time, i = parse_offset(s, i + 1)
            assert s[i] == ",", s
            self.end, i = parse_rule_date(s, i + 1)
            self.end_time = 7200
            if i < len(s) and s[i] == "/":
                self.end_time, i = parse_offset(s, i + 1)
        assert i == len(s), s

    @staticmethod
    def day(year, r):
        if r[0] == "J":
            n = r[1]
            return days_from_civil(year, 1, 1) + n - 1 + (1 if is_leap(year) and n >= 60 else 0)
        if r[0] == "N":
            return days_from_civil(year, 1, 1) + r[1]
        _, month, week, wd = r
        first = days_from_civil(year, month, 1)
        d = first + (wd - weekday(first)) % 7
        if week == 5:
            last = first + days_in_month(year, month) - 1
            while d + 7 <= last:
                d += 7
        else:
            d += 7 * (week - 1)
        return d

    def year(self, y):
        """This year's transitions: (unix seconds, offset, abbreviation)."""
        if self.dst is None:
            return []
        on = self.day(y, self.start) * DAY + self.start_time - self.std
        off = self.day(y, self.end) * DAY + self.end_time - self.dst
        return sorted([(on, self.dst, self.dst_abbr), (off, self.std, self.std_abbr)])


class Zone:
    def __init__(self, name, data):
        self.name = name
        self.data = data
        assert data[:4] == b"TZif" and data[4] >= ord("2"), name
        cnt = struct.unpack(">6l", data[20:44])
        isut, isstd, leap, time, typ, char = cnt
        skip = 44 + time * 5 + typ * 6 + char + leap * 8 + isstd + isut
        d = data[skip:]
        assert d[:4] == b"TZif", name
        isut, isstd, leap, time, typ, char = struct.unpack(">6l", d[20:44])
        assert leap == 0, name
        p = 44
        times = struct.unpack(">%dq" % time, d[p:p + 8 * time]); p += 8 * time
        idx = d[p:p + time]; p += time
        types = [struct.unpack(">lBB", d[p + 6 * k:p + 6 * k + 6]) for k in range(typ)]; p += 6 * typ
        chars = d[p:p + char]; p += char + isstd + isut
        footer = d[p:].decode()
        assert footer[0] == "\n" and footer[-1] == "\n", name
        self.posix = Posix(footer[1:-1]) if footer[1:-1] else None

        def abbr(k):
            j = types[k][2]
            return chars[j:chars.index(b"\0", j)].decode()

        if types:
            self.first = (types[0][0], abbr(0))
        else:
            self.first = (self.posix.std, self.posix.std_abbr)
        self.explicit = [(t, types[k][0], abbr(k)) for t, k in zip(times, idx)]

    def transitions(self, end_year=HORIZON):
        """Every transition before the start of end_year + 1, in UTC."""
        if end_year == HORIZON and hasattr(self, "_through_horizon"):
            return self._through_horizon
        end = days_from_civil(end_year + 1, 1, 1) * DAY
        out = [t for t in self.explicit if t[0] < end]
        if self.posix and self.posix.dst is not None:
            last = self.explicit[-1][0] if self.explicit else None
            y = civil_from_days(last // DAY)[0] if last is not None else 1970
            while y <= end_year:
                for t in self.posix.year(y):
                    if (last is None or t[0] > last) and t[0] < end:
                        out.append(t)
                y += 1
        if end_year == HORIZON:
            self._through_horizon = out
        return out

    def offset_at(self, secs):
        if not hasattr(self, "_times"):
            self._times = [t[0] for t in self.explicit]
        k = bisect.bisect_right(self._times, secs)
        if k < len(self.explicit):
            return self.explicit[k - 1][1] if k else self.first[0]
        off = self.explicit[-1][1] if self.explicit else self.first[0]
        if self.posix is None:
            return off
        if self.posix.dst is None:
            return self.posix.std
        y = civil_from_days(secs // DAY)[0]
        cand = [t for yy in (y - 1, y, y + 1) for t in self.posix.year(yy)]
        last = self.explicit[-1][0] if self.explicit else None
        for t in sorted(cand):
            if t[0] > secs:
                break
            if last is None or t[0] > last:
                off = t[1]
        return off

    def rule_transitions(self):
        """The rule's transitions in RULE_YEARS."""
        if not (self.posix and self.posix.dst is not None):
            return []
        return [t for y in RULE_YEARS for t in self.posix.year(y)]


def load_bundle():
    d = bundle_dir()
    src = open(os.path.join(d, "tzname.rs")).read()
    version = re.search(r'VERSION: &str = "([^"]+)"', src).group(1)
    if version != TZDB_VERSION:
        sys.exit("gen.py: the bundle is %s, not %s" % (version, TZDB_VERSION))
    data = open(os.path.join(d, "concatenated-zoneinfo.dat"), "rb").read()
    zones, primary = {}, {}
    for name, a, b in re.findall(r'\(r"([^"]+)", (\d+)\.\.(\d+)\)', src):
        a, b = int(a), int(b)
        zones[name] = Zone(name, data[a:b])
        primary.setdefault((a, b), name)
    if len(zones) != 598:
        sys.exit("gen.py: the bundle has %d names, not 598" % len(zones))
    # The names whose rules are another's (the first name with the same
    # bytes) are tested more lightly: zones.in tests the rules once.
    alias = {}
    for name, a, b in re.findall(r'\(r"([^"]+)", (\d+)\.\.(\d+)\)', src):
        p = primary[(int(a), int(b))]
        if p != name:
            alias[name] = p
    return zones, alias


# --- Values.

def rand_date_days(r, years=None):
    if years:
        y = r.pick(years)
        return days_from_civil(y, 1, 1) + r.below(366 if is_leap(y) else 365)
    return r.range(MIN_DAY, MAX_DAY)


def rand_ns(r):
    k = r.below(4)
    return (0, r.below(1000) * 1_000_000, r.below(NS), r.below(1_000_000) * 1000)[k]


def rand_dur_ns(r, sign):
    """A duration of the given sign, of a size from nanoseconds to years."""
    k = r.below(8)
    if k == 0:
        v = 0
    elif k == 1:
        v = r.range(1, 999)
    elif k == 2:
        v = r.range(1, 59) * NS
    elif k == 3:
        v = r.range(1, 48) * 3600 * NS
    elif k == 4:
        v = r.range(1, 1500) * 60 * NS + rand_ns(r)
    elif k == 5:
        v = r.range(1, 400 * DAY) * NS + rand_ns(r)
    elif k == 6:
        v = r.range(0, 86399) * NS + rand_ns(r)
    else:
        v = r.range(1, 20000 * 366 * DAY) * NS
    return sign * v


def amounts(r, sign, small=False):
    y = r.range(0, 3) if r.below(3) == 0 else 0
    m = r.range(0, 14) if r.below(2) == 0 else 0
    w = r.range(0, 6) if r.below(3) == 0 else 0
    d = r.range(0, 40) if r.below(2) == 0 else 0
    if small:
        y = 0
    return [sign * v for v in (y, m, w, d)]


SAMPLE_YEARS = [-9999, -9998, -1, 0, 1, 4, 100, 1600, 1900, 1969, 1970, 2000,
                2023, 2024, 2025, 2100, 2400, 9998, 9999]


def sample_dates():
    for y in SAMPLE_YEARS:
        a = days_from_civil(y, 1, 1)
        for d in range(a, days_from_civil(y + 1, 1, 1) if y < 9999 else MAX_DAY + 1):
            yield d


# --- 1. Calendar arithmetic.

def gen_calendar(w, zones, alias):
    r = Rand(1)
    for d in sample_dates():
        t = fmt_date_days(d)
        w("date.info %s" % t)
        for k in range(-24, 25):
            w("date.add %s 0 %d 0 0" % (t, k))
        for y in (1, -1, 4, -4, 100, -100, 400, -400, 19998, -19998, 19999):
            w("date.add %s %d 0 0 0" % (t, y))
        for _ in range(3):
            s = r.pick((1, -1))
            w("date.add %s %d %d %d %d" % ((t,) + tuple(amounts(r, s))))
    for _ in range(40000):
        d = rand_date_days(r, SAMPLE_YEARS if r.below(2) else None)
        secs = d * DAY + r.below(DAY)
        s = r.pick((1, -1))
        a = amounts(r, s)
        w("datetime.add %s %d %d %d %d %s" % ((fmt_datetime(secs, rand_ns(r)),) + tuple(a) + (fmt_dur(rand_dur_ns(r, s)),)))
    names = sorted(zones)
    for k in range(40000):
        name = r.pick(ZONES) if k % 2 else r.pick(names)
        at = near_transition(r, zones[name]) if r.below(3) else r.range(-2208988800, 4102444800)
        s = r.pick((1, -1))
        a = amounts(r, s)
        dur = rand_dur_ns(r, s) if r.below(2) else 0
        if abs(dur) > 400 * DAY * NS:
            dur = 0
        w("zoned.add %s %s %d %d %d %d %s" % ((name, fmt_instant(at, rand_ns(r))) + tuple(a) + (fmt_dur(dur),)))
    for _ in range(10000):
        s = r.pick((1, -1))
        w("time.add %s %s" % (fmt_time(r.below(DAY), rand_ns(r)), fmt_dur(rand_dur_ns(r, s))))
    for k in range(10000):
        s = r.pick((1, -1))
        if k % 10 == 0:
            at = (MAX_INSTANT - r.below(3 * DAY)) if s > 0 else (MIN_INSTANT + r.below(3 * DAY))
        else:
            at = r.range(MIN_INSTANT, MAX_INSTANT)
        w("instant.add %s %s" % (fmt_instant(at, rand_ns(r)), fmt_dur(rand_dur_ns(r, s))))
    # The helpers of §6.7, `with`, and `since` on a time and a date and
    # time, from a stream of their own.
    r = Rand(6)
    names = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
    for d in sample_dates():
        t = fmt_date_days(d)
        for n in (1, -1, r.pick((2, -2, 5, -5, 53, -53, 0, 1_000_000, -1_000_000))):
            w("date.nth_weekday %s %d %s" % (t, n, r.pick(names)))
        for _ in range(2):
            w("date.nth_weekday_of_month %s %d %s" % (t, r.range(-6, 6), r.pick(names)))
        y, m, dd = civil_from_days(rand_date_days(r))
        w("date.with %s %d %d %d" % (t, r.pick((y, y, -10000, 10000)), r.pick((m, m, 0, 13)), r.pick((dd, dd, 29, 30, 31, 0, 32))))
    for _ in range(10000):
        w("time.since %s %s" % (fmt_time(r.below(DAY), rand_ns(r)), fmt_time(r.below(DAY), rand_ns(r))))
    for _ in range(20000):
        a = rand_date_days(r, SAMPLE_YEARS if r.below(2) else None) * DAY + r.below(DAY)
        b = a + r.range(-400 * DAY, 400 * DAY) if r.below(2) else rand_date_days(r) * DAY + r.below(DAY)
        b = max(MIN_DAY * DAY, min(MAX_DAY * DAY + DAY - 1, b))
        w("datetime.since %s %s" % (fmt_datetime(a, rand_ns(r)), fmt_datetime(b, rand_ns(r))))
    # An instant's Unix time and `since`, from a stream of their own:
    # instants within an `Int` of nanoseconds of 1970 most often, and
    # across the whole range, each exact (§5.1).
    r = Rand(7)
    span = (1 << 63) // NS
    ends = (MIN_INSTANT, MIN_INSTANT + 1, -span - 1, -span, -1, 0, span - 1, span, MAX_INSTANT - 1, MAX_INSTANT)
    for k in range(10000):
        if k < len(ends):
            at = ends[k]
        elif k % 4:
            at = r.range(-span, span - 1)
        else:
            at = r.range(MIN_INSTANT, MAX_INSTANT)
        w("instant.unix %s" % fmt_instant(at, rand_ns(r) if at != MIN_INSTANT else 0))
    for _ in range(20000):
        a = r.range(-span, span - 1) if r.below(2) else r.range(MIN_INSTANT, MAX_INSTANT)
        b = a + r.range(-400 * DAY, 400 * DAY) if r.below(2) else r.range(MIN_INSTANT, MAX_INSTANT)
        b = max(MIN_INSTANT, min(MAX_INSTANT, b))
        w("instant.since %s %s" % (fmt_instant(a, rand_ns(r)), fmt_instant(b, rand_ns(r) if b != MIN_INSTANT else 0)))


def near_transition(r, zone):
    ts = zone.transitions()
    if not ts:
        return r.range(-2208988800, 4102444800)
    return r.pick(ts)[0] + r.range(-2 * DAY, 2 * DAY)


# --- 2. Every zone, an hour either side of each transition.

def gen_zones(w, zones, alias):
    names = sorted(zones)
    for name in names:
        w("zone.name %s" % name)
        w("zone.name %s" % name.lower())
        w("zone.name %s" % name.upper())
        w("zone.eq %s %s" % (name, name.lower()))
        if name in alias:
            w("zone.eq %s %s" % (name, alias[name]))
    for a, b in (("Asia/Calcutta", "Asia/Kolkata"), ("America/Denver", "America/Shiprock"),
                 ("Africa/Accra", "Africa/Abidjan"), ("UTC", "Etc/UTC"), ("UTC", "+00:00"),
                 ("utc", "UTC"), ("Etc/GMT+7", "-07:00"), ("-07:00", "-07:00"),
                 ("+05:30", "+05:30"), ("+05:30", "+05:31")):
        w("zone.eq %s %s" % (a, b))
    for name in names:
        z = zones[name]
        ts = z.transitions()
        if name in alias:
            # The rules are tested under their first name; here, only that
            # this name reaches them.
            for t, _, _ in ts:
                w("instant.in_zone %s %s" % (fmt_instant(t - 1), name))
                w("instant.in_zone %s %s" % (fmt_instant(t), name))
            continue
        prev = z.first[0]
        every = [(t, o, prev_o) for (t, o, _), prev_o in zip(ts, [prev] + [x[1] for x in ts])]
        rule = z.rule_transitions()
        for t, o, _ in rule:
            every.append((t, o, z.offset_at(t - 1)))
        for t, after, before in every:
            for at in (t - 3600, t - 1, t, t + 1, t + 3600):
                w("instant.in_zone %s %s" % (fmt_instant(at), name))
            lo, hi = sorted((t + before, t + after))
            clock = [lo - 3600, lo - 1, lo, lo + 1, hi - 1, hi, hi + 1, hi + 3600]
            if hi - lo > 2:
                clock.append((lo + hi) // 2)
            for c in sorted(set(clock)):
                w("datetime.in_zone %s %s" % (fmt_datetime(c), name))
            for d in sorted({(lo - 3600) // DAY, (hi + 3600) // DAY}):
                w("date.in_zone %s %s" % (fmt_date_days(d), name))
            for at in (t - 1, t + 1):
                w("zoned.start_of_day %s %s" % (name, fmt_instant(at)))
            # `with` from a value either side of the change to a time on
            # the clock in, at, and either side of the gap or the repeat.
            for at in (t - 1800, t + 1800):
                for c in sorted({lo - 1, lo, (lo + hi) // 2, hi - 1, hi}):
                    w("zoned.with %s %s %s" % (name, fmt_instant(at), fmt_datetime(c)))
            for at in (t - 1800, t + 1800):
                i = fmt_instant(at)
                w("zoned.add %s %s 0 0 0 1 PT0S" % (name, i))
                w("zoned.add %s %s 0 0 0 -1 PT0S" % (name, i))
                w("zoned.add %s %s 0 0 0 0 PT24H" % (name, i))
                w("zoned.add %s %s 0 0 0 0 -PT24H" % (name, i))
    # The ends of the range, in zones east and west, and in fixed zones.
    for name in ("UTC", "Asia/Tokyo", "America/Denver", "Pacific/Kiritimati", "Etc/GMT+12", "+25:59", "-25:59"):
        for d in (MIN_DAY, MIN_DAY + 1, MIN_DAY + 2, MAX_DAY - 1, MAX_DAY):
            w("date.in_zone %s %s" % (fmt_date_days(d), name))
            for secs in (0, 3600, 86399):
                w("datetime.in_zone %s %s" % (fmt_datetime(d * DAY + secs), name))
        for at in (MIN_INSTANT, MIN_INSTANT + 1, MAX_INSTANT - 1, MAX_INSTANT):
            w("instant.in_zone %s %s" % (fmt_instant(at), name))
    # The offset alone (`tz.offset_at(i)`, §7.4), for every name, its
    # rules' too: an hour and a second before each transition through
    # 2040 and each of its rule's in RULE_YEARS, at it and an hour after;
    # then the first and last instants, and fixed zones.
    for name in names:
        z = zones[name]
        for t in [x[0] for x in z.transitions()] + [x[0] for x in z.rule_transitions()]:
            for at in (t - 3600, t - 1, t, t + 3600):
                w("zone.offset %s %s" % (name, fmt_instant(at)))
        for at in (MIN_INSTANT, MAX_INSTANT):
            w("zone.offset %s %s" % (name, fmt_instant(at)))
    for name in ("+25:59", "-25:59", "+05:30", "-00:44", "+00:00"):
        for at in (MIN_INSTANT, 0, MAX_INSTANT):
            w("zone.offset %s %s" % (name, fmt_instant(at)))


# --- 3. Counts, in both directions.

def gen_counts(w, zones, alias):
    r = Rand(3)

    def both(op, a, b):
        w("%s %s %s" % (op, a, b))
        w("%s %s %s" % (op, b, a))

    steps = [0, 1, 6, 7, 8, 27, 28, 29, 30, 31, 32, 58, 59, 60, 61, 62, 89, 90, 91, 92,
             364, 365, 366, 367, 1460, 1461]
    for y in (-1, 0, 1900, 2000, 2023, 2024):
        a = days_from_civil(y, 1, 1)
        for d in range(a, days_from_civil(y + 1, 1, 1)):
            for k in steps:
                both("date.count", fmt_date_days(d), fmt_date_days(d + k))
    for _ in range(30000):
        a = rand_date_days(r)
        b = rand_date_days(r) if r.below(2) else min(MAX_DAY, a + r.below(800))
        both("date.count", fmt_date_days(a), fmt_date_days(b))
    for (a, b) in (("2023-12-30T10:00:00", "2024-03-01T00:00:00"),
                   ("2023-11-30T09:00:00", "2024-02-29T09:00:00")):
        both("datetime.count", a, b)
    for _ in range(30000):
        a = rand_date_days(r, SAMPLE_YEARS if r.below(2) else None) * DAY + r.below(DAY)
        k = r.below(4)
        if k == 0:
            b = a + r.range(-DAY, DAY)
        elif k == 1:
            b = a + r.range(-100 * DAY, 100 * DAY)
        elif k == 2:
            b = (a // DAY + r.range(-800, 800)) * DAY + r.below(DAY)
        else:
            b = rand_date_days(r) * DAY + r.below(DAY)
        b = max(MIN_DAY * DAY, min(MAX_DAY * DAY + DAY - 1, b))
        both("datetime.count", fmt_datetime(a, rand_ns(r)), fmt_datetime(b, rand_ns(r)))

    def zboth(name, a, b):
        w("zoned.count %s %s %s" % (name, a, b))
        w("zoned.count %s %s %s" % (name, b, a))

    # The design's cases (§12), then pairs about the transitions.
    zboth("America/Denver", "2026-03-07T09:30:00Z", "2026-03-08T09:00:00Z")
    zboth("Antarctica/Casey", "2010-03-03T13:00:00Z", "2010-03-04T15:00:00Z")
    zboth("America/New_York", "2024-11-03T05:50:00Z", "2024-11-04T06:00:00Z")
    gaps = [3600, 23 * 3600, 24 * 3600, 25 * 3600, 24 * 3600 + 600, 26 * 3600, 48 * 3600,
            7 * DAY, 28 * DAY, 31 * DAY, 92 * DAY, 366 * DAY, 800 * DAY]
    for k in range(40000):
        name = r.pick(ZONES)
        a = near_transition(r, zones[name])
        b = a + r.pick((1, -1)) * (r.pick(gaps) + r.range(-3600, 3600))
        zboth(name, fmt_instant(a, rand_ns(r)), fmt_instant(b, rand_ns(r)))
    for name in sorted(zones):
        if name in alias:
            continue
        for _ in range(20):
            a = near_transition(r, zones[name])
            b = a + r.pick((1, -1)) * (r.pick(gaps) + r.range(-3600, 3600))
            zboth(name, fmt_instant(a), fmt_instant(b))


# --- 4. Parse and print round trips.

def gen_text(w, zones, alias):
    r = Rand(4)
    names = sorted(zones)
    # Values in the form each prints, which must read back as themselves.
    for _ in range(5000):
        w("date.parse %s" % fmt_date_days(rand_date_days(r)))
        w("time.parse %s" % fmt_time(r.below(DAY), rand_ns(r)))
        w("datetime.parse %s" % fmt_datetime(rand_date_days(r) * DAY + r.below(DAY), rand_ns(r)))
        w("instant.parse %s" % fmt_instant(r.range(MIN_INSTANT, MAX_INSTANT), rand_ns(r)))
        d = rand_dur_ns(r, r.pick((1, -1)))
        w("duration.parse %s" % fmt_dur(d))
        if r.below(5) == 0:
            w("duration.parse %s" % fmt_dur_seconds(d))
    for k in range(10000):
        name = r.pick(ZONES) if k % 2 else r.pick(names)
        z = zones[name]
        at = near_transition(r, z) if r.below(2) else r.range(-2208988800, 4102444800)
        off = z.offset_at(at)
        clock = fmt_datetime(at + off, rand_ns(r))
        w("zoned.parse %s%s[%s]" % (clock, fmt_offset(off), name))
        # Offsets rounded to the minute, as Jiff prints them (§7.6).
        if off % 60:
            w("zoned.parse %s%s[%s]" % (clock, fmt_offset(30 * round(off / 30.0), seconds=False), name))
        w("zoned.parse %s[%s]" % (clock, name))
        w("zoned.parse %sZ[%s]" % (fmt_datetime(at), name))
        # An offset the zone does not have then: the other side of a
        # transition, or half an hour off.
        other = [o for o in (z.offset_at(at - 7200), z.offset_at(at + 7200)) if o != off]
        w("zoned.parse %s%s[%s]" % (clock, fmt_offset(other[0] if other else off + 1800), name))
    # Each spelling Jiff's grammar reads or rejects (§8.1, §5.5). Date, Time
    # and DateTime are given only their own form: where the text has more,
    # Rig rejects what Jiff drops without a word (§8.1, §9 item 15).
    fixed = [
        "date.parse 2024-03-10", "date.parse 20240310", "date.parse +002024-03-10",
        "date.parse -000001-01-01", "date.parse -000000-01-01", "date.parse 2023-02-29",
        "date.parse 2024-02-29", "date.parse 2024-13-01", "date.parse 2024-1-01",
        "date.parse 2024-03-10T03:30:00Z", "date.parse -010000-01-01", "date.parse +010000-01-01",
        "date.parse 2024-W10-1", "date.parse 2024-070", "date.parse 2024-03-1",
        "time.parse 03:30", "time.parse 0330", "time.parse 033000", "time.parse T03:30",
        "time.parse t03:30", "time.parse 03:30:00.123456789", "time.parse 03:30:00,5",
        "time.parse 03:30:00.1234567891", "time.parse 24:00:00", "time.parse 23:59:60",
        "time.parse 23:59:61", "time.parse 3:30", "time.parse 03", "time.parse 2024-03-10T03:30:00Z",
        "datetime.parse 2024-03-10T03:30", "datetime.parse 2024-03-10 03:30:00",
        "datetime.parse 2024-03-10t03:30", "datetime.parse 20240310T033000",
        "datetime.parse 2024-03-10", "datetime.parse 2024-03-10T24:00",
        "datetime.parse 2024-06-30T23:59:60", "datetime.parse 2024-06-30T23:59:60.5",
        "datetime.parse 2024-03-10T03:30:00Z", "datetime.parse 2024-03-10T03",
        "datetime.parse 2024-03-10T0330", "datetime.parse 2024-03-10T03:30:00.000000000",
        "instant.parse 2024-03-10T03:30:00", "instant.parse 2024-03-10t03:30:00z",
        "instant.parse 2024-03-10 03:30:00,5Z", "instant.parse 2024-03-10T03:30:00-06:00[America/Denver]",
        "instant.parse 2024-03-10T03:30:00+05:30", "instant.parse 2024-03-10T03:30:00+0530",
        "instant.parse 2024-03-10T03:30:00+05", "instant.parse 2024-03-10T03:30:00-00:00",
        "instant.parse 2024-03-10T03:30:00+00:00", "instant.parse 2024-03-10T03:30:00+05:30:15",
        "instant.parse 2024-03-10T03:30:00+24:00", "instant.parse 2024-03-10T03:30:00+25:59",
        "instant.parse 2024-03-10T03:30:00+26:00", "instant.parse 2024-03-10",
        "instant.parse 1968-02-01T23:15:00-00:45[Africa/Monrovia]",
        "instant.parse -009999-01-02T01:59:59Z", "instant.parse -009999-01-02T01:59:58Z",
        "instant.parse 9999-12-30T22:00:00.999999999Z", "instant.parse 9999-12-30T22:00:01Z",
        "instant.parse 9999-12-31T23:59:59+25:59", "instant.parse 2024-06-30T23:59:60Z",
        "zoned.parse 2024-03-10T03:30:00[America/Denver]",
        "zoned.parse 2024-03-10T02:30:00[America/Denver]",
        "zoned.parse 2024-11-03T01:30:00[America/New_York]",
        "zoned.parse 2024-11-03T01:30:00-05:00[America/New_York]",
        "zoned.parse 2024-11-03T01:30:00-04:00[America/New_York]",
        "zoned.parse 2024-03-10T03:30:00-06:00[america/denver]",
        "zoned.parse 2024-03-10T03:30:00-07:00[-07:00]", "zoned.parse 2024-03-10T03:30:00-07:00[-0700]",
        "zoned.parse 2024-03-10T03:30:00-07:00[-07]", "zoned.parse 2024-03-10T03:30:00[-07:00]",
        "zoned.parse 2024-03-10T03:30:00+05:30[+05:30]", "zoned.parse 2024-03-10T03:30:00-06:00",
        "zoned.parse 2024-03-10T03:30:00Z", "zoned.parse 2024-03-10T03:30:00Z[UTC]",
        "zoned.parse 2024-03-10T03:30:00Z[utc]", "zoned.parse 2024-03-10T03:30:00Z[Etc/UTC]",
        "zoned.parse 2024-03-10T03:30:00Z[Z]", "zoned.parse 2024-03-10T03:30:00+00:00[UTC]",
        "zoned.parse 2024-03-10T03:30:00-00:00[UTC]", "zoned.parse 2024-03-10T03:30:00Z[No/Such_Zone]",
        "zoned.parse 2030-12-01T12:00-02:00[America/Sao_Paulo]",
        "zoned.parse 2030-12-01T12:00Z[America/Sao_Paulo]",
        "zoned.parse 1968-02-01T23:15:00-00:45[Africa/Monrovia]",
        "zoned.parse 1968-02-01T23:15:00-00:44:30[Africa/Monrovia]",
        "zoned.parse 2011-12-30T12:00:00[Pacific/Apia]",
        "zoned.parse 2024-03-10T03:30:00-06:00[!America/Denver]",
        "zoned.parse 2024-03-10T03:30:00-06:00[America/Denver][u-ca=iso8601]",
        "zoned.parse 2024-03-10T03:30:00-06:00[America/Denver][u-ca=gregory]",
        "zoned.parse 2024-03-10",
    ]
    durations = [
        "1.5h", "1h30m", "1h 30m", "1 hour, 30 minutes", "01:30:00", "2h 30m ago", "1h 90m",
        "1500ms", "+1h", "PT1.5H", "1µs", "1us", "-1h", "-1h 30m", "1h -30m", "30m 1h", "1h 1h",
        "PT-1H", "P1D", "1 day", "90", "PT0S", "0s", "PT2H30M", "PT0.001234567S", "-PT1.5S",
        "PT9600H", "1ms 234us 567ns", "-1s 500ms", "1s 500ms ago", "P1W", "P1Y", "PT1M",
        "pt1h", "PT1H30M0.5S", "1 hr", "1 min 2 sec", "2562047788015215h 30m 7s 999ms 999us 999ns",
        "2562047788015215h 30m 8s", "-2562047788015215h 30m 8s", "PT1H1.5M", "1.5h 30m", "",
    ]
    for f in fixed:
        w(f)
    for d in durations:
        w("duration.parse %s" % d)


# --- 5. Rounding, and the floor.

def divisors(n, below):
    """The divisors of n below a bound, n being a product of 2, 3 and 5."""
    out = [1]
    for p in (2, 3, 5):
        e = 0
        while n % p == 0:
            n //= p
            e += 1
        out = [d * p ** k for d in out for k in range(e + 1)]
    assert n == 1
    return sorted(d for d in out if d < below)


def gen_round(w, zones, alias):
    r = Rand(5)
    # The increments of a Time, a DateTime and a ZonedDateTime: each divides
    # the next larger unit and is smaller than it (§6.8).
    clock = {"ns": divisors(1000, 1000), "us": divisors(1000, 1000), "ms": divisors(1000, 1000),
             "seconds": divisors(60, 60), "minutes": divisors(60, 60), "hours": divisors(24, 24)}
    per = {"ns": 1, "us": 1000, "ms": 1_000_000, "seconds": NS, "minutes": 60 * NS, "hours": 3600 * NS}
    # An Instant's: each divides 24 hours.
    inst = {u: [k for k in divisors(DAY * NS // p, min(DAY * NS // p, NS) + 1)] for u, p in per.items()}
    units = list(clock)

    def value_ns(r, u, inc):
        """A time of day in ns: often exactly on a half or a multiple."""
        step = per[u] * inc
        k = r.below(4)
        base = r.below(DAY * NS)
        if k == 0 and step % 2 == 0:
            return base - base % step + step // 2
        if k == 1:
            return base - base % step
        return base

    for _ in range(15000):
        u = r.pick(units)
        inc = r.pick(clock[u])
        t = value_ns(r, u, inc)
        w("time.round %s %s %d" % (fmt_time(t // NS, t % NS), u, inc))
    for k in range(15000):
        if k % 10 == 0:
            u, inc = "days", 1
        else:
            u = r.pick(units)
            inc = r.pick(clock[u])
        t = value_ns(r, u if u != "days" else "hours", inc if u != "days" else 12)
        # Years at or below 0 one time in ten: Rig's round differs there
        # (§6.8), so only the floor is checked.
        if r.below(10):
            d = r.range(days_from_civil(1, 1, 1), MAX_DAY - 1)
        else:
            d = r.range(MIN_DAY, days_from_civil(1, 1, 1) - 1)
        w("datetime.round %s %s %d" % (fmt_datetime(d * DAY + t // NS, t % NS), u, inc))
    for k in range(15000):
        u = r.pick(units)
        inc = r.pick(inst[u])
        step = per[u] * inc
        at = r.range(MIN_INSTANT + DAY, MAX_INSTANT - DAY) if k % 3 else r.range(-3 * 10**9, 3 * 10**9)
        total = at * NS + rand_ns(r)
        if r.below(3) == 0:
            total = total - total % step + (step // 2 if step % 2 == 0 else 0)
        w("instant.round %s %s %d" % (fmt_instant(total // NS, total % NS), u, inc))
    names = sorted(zones)
    for k in range(20000):
        name = r.pick(ZONES) if k % 2 else r.pick(names)
        if k % 5 == 0:
            u, inc = "days", 1
        else:
            u = r.pick(units)
            inc = r.pick(clock[u])
        at = near_transition(r, zones[name]) if r.below(3) else r.range(-2208988800, 4102444800)
        w("zoned.round %s %s %s %d" % (name, fmt_instant(at, rand_ns(r)), u, inc))
    for _ in range(10000):
        u = r.pick(units)
        inc = r.pick((1, 2, 3, 5, 7, 10, 15, 30, 60, 90, 1000, 999999999, 1000000000))
        d = rand_dur_ns(r, r.pick((1, -1)))
        if r.below(3) == 0:
            step = per[u] * inc
            d = d - d % step + step // 2
        w("duration.round %s %s %d" % (fmt_dur(d), u, inc))


KINDS = {
    "calendar": gen_calendar,
    "zones": gen_zones,
    "counts": gen_counts,
    "text": gen_text,
    "round": gen_round,
}


def write_kind(kind, f, zones, alias):
    buf = []
    KINDS[kind](buf.append, zones, alias)
    f.write("\n".join(buf))
    f.write("\n")
    return len(buf)


# --- The bundle check.

def bundle_check(binary):
    """The oracle answers from jiff-tzdb's 2026f bundle: Jiff's transitions
    for every name equal this file's own decoding of the bundle, and its
    answers do not change with TZ or TZDIR pointing elsewhere."""
    zones, alias = load_bundle()
    ver = subprocess.run([binary, "--version"], capture_output=True, text=True).stdout.strip()
    if "Bundled" not in ver or TZDB_VERSION not in ver:
        sys.exit("bundle-check: the oracle says %r" % ver)
    print("oracle:", ver)
    names = sorted(zones)
    end = fmt_instant(days_from_civil(HORIZON + 1, 1, 1) * DAY)
    inp = "".join("zone.transitions %s %s\n" % (n, end) for n in names)
    out = subprocess.run([binary], input=inp, capture_output=True, text=True, check=True).stdout
    lines = out.splitlines()
    bad = 0
    total = 0
    for name, line in zip(names, lines):
        z = zones[name]
        want = ["%d/%s" % z.first] + ["%d/%d/%s" % t for t in z.transitions()]
        total += len(want) - 1
        if line.split(" ") != want:
            bad += 1
            if bad <= 3:
                got = line.split(" ")
                k = next((i for i, (a, b) in enumerate(zip(got, want)) if a != b), min(len(got), len(want)))
                print("bundle-check: %s differs at %d: Jiff %s, bundle %s" % (name, k, got[k:k + 2], want[k:k + 2]))
    if len(lines) != len(names) or bad:
        sys.exit("bundle-check: %d of %d names differ from the bundle" % (bad, len(names)))
    print("transitions through %d: %d names, %d transitions, each as the bundle has it" % (HORIZON, len(names), total))

    # The same answers with the machine's zone settings pointed elsewhere:
    # a TZDIR whose America/New_York is Tokyo's, and TZ set to it.
    tmp = tempfile.mkdtemp()
    try:
        fake = os.path.join(tmp, "zoneinfo")
        os.makedirs(os.path.join(fake, "America"))
        with open(os.path.join(fake, "America", "New_York"), "wb") as f:
            f.write(zones["Asia/Tokyo"].data)
        with open(os.path.join(fake, "UTC"), "wb") as f:
            f.write(zones["Asia/Tokyo"].data)
        buf = []
        gen_zones(buf.append, {n: zones[n] for n in ("America/New_York", "UTC", "Asia/Tokyo")}, {})
        probe = inp + "\n".join(buf) + "\n"
        base = dict(os.environ)
        for k in ("TZ", "TZDIR"):
            base.pop(k, None)
        first = subprocess.run([binary], input=probe, capture_output=True, text=True, env=base, check=True).stdout
        for extra in ({"TZDIR": fake}, {"TZ": "Asia/Tokyo"}, {"TZDIR": fake, "TZ": ":America/New_York"},
                      {"TZDIR": "/nonexistent"}):
            env = dict(base, **extra)
            again = subprocess.run([binary], input=probe, capture_output=True, text=True, env=env, check=True).stdout
            if again != first:
                sys.exit("bundle-check: answers change with %s" % extra)
        print("the same %d answers with TZDIR at a false zoneinfo and with TZ set" % first.count("\n"))
    finally:
        shutil.rmtree(tmp)


def main(argv):
    if len(argv) == 3 and argv[1] == "--bundle-check":
        bundle_check(argv[2])
        return
    if len(argv) == 3 and argv[1] == "--kind" and argv[2] in KINDS:
        zones, alias = load_bundle()
        write_kind(argv[2], sys.stdout, zones, alias)
        return
    if len(argv) == 2 and not argv[1].startswith("-"):
        zones, alias = load_bundle()
        os.makedirs(argv[1], exist_ok=True)
        for kind in KINDS:
            with open(os.path.join(argv[1], kind + ".in"), "w") as f:
                n = write_kind(kind, f, zones, alias)
            print("%s.in %d" % (kind, n))
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
