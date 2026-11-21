#!/usr/bin/env python3
"""Check the tables tools/gen-tzdb.py writes against the zone files of the
jiff-tzdb crate they come from, read here by a TZif reader of its own and
by Python's zoneinfo, never the machine's zone files.

    check.py TABLES CACHE [ZONE]

TABLES is the directory gen-tzdb.py wrote, CACHE the directory of its
pinned inputs, and ZONE, when given, the measuring program built from
zone.rig, whose answers are checked too.

For the sample zones (SAMPLE), exactly: every transition's instant,
offset and abbreviation, and the type before the first, against the
crate's TZif file; then the offset at each transition and a second either
side, and from the last transition to 2200 every three hours and a second
either side of each change, from the tables (the rule read as Jiff reads
it) against zoneinfo reading the same file. For every name: its zone's
offsets at each transition and a second either side, and on January 1 and
July 1 of each year from 1800 to 2200, against zoneinfo; and its primary
identifier against Jiff's metadata.rs. The test table: Dublin against the
pinned file, and the Morocco rule in daylight saving all year.
"""
import bisect
import datetime as dt
import hashlib
import io
import re
import struct
import subprocess
import sys
import tarfile
import zoneinfo

SAMPLE = ["America/New_York", "Australia/Lord_Howe", "Pacific/Apia",
          "Antarctica/Casey", "Africa/Monrovia", "Europe/Dublin"]
PINS = {"jiff-tzdb-1.0.0.crate": "12e71a1b68a875a44a33bb7a1dd84392cb77145a3367a552a3cfe6a4f5cf3afc",
        "jiff-1.0.0.crate": "9cc767b5763de45e810109520123bb2829a653f3a7ed9be40b2bc4f81158f595",
        "europe-dublin.tzif": "40e8d2a1c3b572284da39f6f4245b1bc814f452c44f5aa73d0a011571d5ccc43"}
EPOCH = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)
BAD = []


def bad(msg):
    BAD.append(msg)
    if len(BAD) <= 20:
        print("MISMATCH", msg)


def pinned(cache, name):
    data = open("%s/%s" % (cache, name), "rb").read()
    if hashlib.sha256(data).hexdigest() != PINS[name]:
        sys.exit("%s: not the pinned file" % name)
    return data


def member(crate, name):
    with tarfile.open(fileobj=io.BytesIO(crate), mode="r:gz") as tar:
        return tar.extractfile(tar.getmember(name)).read()


# ---- the generated Zig, read back

def zig_array(src, name):
    m = re.search(r"pub const %s = \[\d+\]\w+\{\n(.*?)\n\};" % name, src, re.S)
    return [int(x) for x in re.findall(r"-?\d+", m.group(1))]


def zig_tables(src):
    t = {k: zig_array(src, k) for k in ["times", "transition_types", "zone_types", "type_offsets", "type_abbrs", "abbr_starts"]}
    t["abbr_text"] = re.search(r'pub const abbr_text = "([^"]*)";', src).group(1)
    t["zones"] = [tuple(int(x) if x != "no_rule" else 255 for x in m) for m in re.findall(
        r"\.\{ \.first = (\d+), \.count = (\d+), \.early = (\d+), \.types = (\d+), \.rule = (\w+) \}", src)]
    rules = []
    block = re.search(r"pub const rules = \[\d+\]Rule\{\n(.*?)\n\};", src, re.S).group(1)
    for m in re.finditer(r"^    \.\{ \.std = (\d+), \.dst = (\w+)(.*?)(?=^    \.\{|\Z)", block, re.S | re.M):
        days = re.findall(r"\.kind = \.(\w+), \.day = (\d+), \.month = (\d+), \.week = (\d+), \.weekday = (\d+), \.time = (-?\d+)", m.group(3))
        days = [(k,) + tuple(int(x) for x in rest) for k, *rest in days]
        rules.append((int(m.group(1)), None if m.group(2) == "no_dst" else int(m.group(2)), days))
    t["rules"] = rules
    return t


def abbr(t, i):
    return t["abbr_text"][t["abbr_starts"][i]:t["abbr_starts"][i + 1]]


def zone_history(t, zi):
    """(type 0 as (offset, abbr), [(instant, offset, abbr)]) of zone zi."""
    cache = t.setdefault("history", {})
    if zi not in cache:
        cache[zi] = read_history(t, zi)
    return cache[zi]


def read_history(t, zi):
    first, count, early, types, rule = t["zones"][zi]
    def ty(local):
        g = t["zone_types"][types + local]
        return t["type_offsets"][g], abbr(t, t["type_abbrs"][g])
    out = []
    for k in range(count):
        v = t["times"][first + k]
        inst = v - (1 << 32) if k < early else v
        out.append((inst,) + ty(t["transition_types"][first + k]))
    return ty(0), out


def offset_at(t, zi, inst):
    """The offset of zone zi at `inst`, as Jiff reads it."""
    t0, hist = zone_history(t, zi)
    rule = t["zones"][zi][4]
    n = bisect.bisect_right(hist, (inst, 1 << 40))
    if n == len(hist) and rule != 255:
        return rule_offset(t, t["rules"][rule], inst)
    return t0[0] if n == 0 else hist[n - 1][1]


# ---- the rule, as jiff-core's tz/posix.rs evaluates it

def year_start(y):
    return int((dt.datetime(y, 1, 1, tzinfo=dt.timezone.utc) - EPOCH).total_seconds()) if 1 <= y <= 9999 else None


def year_of(inst):
    return (EPOCH + dt.timedelta(seconds=inst)).year


def day_time(d, year, offset):
    kind, day, month, week, weekday, time = d
    leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
    if kind == "julian1":
        date = dt.date(year, 1, 1) + dt.timedelta(days=day - 1 + (1 if leap and day >= 60 else 0))
    elif kind == "julian0":
        if day == 365 and not leap:
            return year_start(year + 1)
        date = dt.date(year, 1, 1) + dt.timedelta(days=day)
    else:
        first = dt.date(year, month, 1)
        date = first + dt.timedelta(days=(weekday - (first.isoweekday() % 7)) % 7)
        if week < 5:
            date += dt.timedelta(days=7 * (week - 1))
        else:
            while (date + dt.timedelta(days=7)).month == month:
                date += dt.timedelta(days=7)
    at = (date - dt.date(1970, 1, 1)).days * 86400 + time - offset
    return min(max(at, year_start(year)), year_start(year + 1))


def rule_offset(t, r, inst):
    std = t["type_offsets"][r[0]]
    if r[1] is None:
        return std
    dst = t["type_offsets"][r[1]]
    y = year_of(inst)
    start = day_time(r[2][0], y, std)
    end = day_time(r[2][1], y, dst)
    if start == year_start(y) and year_of(end + std) != y:
        end = year_start(y + 1)
    in_dst = start <= inst < end if start <= end else not (end <= inst < start)
    return dst if in_dst else std


def rule_changes(t, r, y):
    """The instants in year y at which the rule may change."""
    if r[1] is None:
        return []
    std, dst = t["type_offsets"][r[0]], t["type_offsets"][r[1]]
    return [day_time(r[2][0], y, std), day_time(r[2][1], y, dst)]


# ---- the crate's zone files, read here

def tzif(data):
    """(type 0, [(instant, offset, abbr)], footer), the 64-bit block."""
    def counts(p):
        assert data[p:p + 4] == b"TZif" and data[p + 4] >= ord("2")
        return struct.unpack(">6L", data[p + 20:p + 44])
    isut, isstd, leap, n, ntypes, nchars = counts(0)
    p = 44 + n * 5 + ntypes * 6 + nchars + leap * 8 + isstd + isut
    isut, isstd, leap, n, ntypes, nchars = counts(p)
    p += 44
    times = struct.unpack(">%dq" % n, data[p:p + 8 * n])
    idx = data[p + 8 * n:p + 9 * n]
    p += 9 * n
    types = []
    for i in range(ntypes):
        off, _, ai = struct.unpack(">lBB", data[p + 6 * i:p + 6 * i + 6])
        chars = data[p + 6 * ntypes:p + 6 * ntypes + nchars]
        types.append((off, chars[ai:chars.index(b"\0", ai)].decode()))
    p += 6 * ntypes + nchars + leap * 12 + isstd + isut
    footer = data[p + 1:data.index(b"\n", p + 1)].decode()
    return types[0], [(times[i],) + types[idx[i]] for i in range(n)], footer


def zi_offset(z, inst):
    return int((EPOCH + dt.timedelta(seconds=inst)).astimezone(z).utcoffset().total_seconds())


def compare(t, zi, data, name, detailed):
    z = zoneinfo.ZoneInfo.from_file(io.BytesIO(data), key=name)
    t0, hist = zone_history(t, zi)
    insts = set()
    if detailed:
        f0, fhist, footer = tzif(data)
        if (t0, hist) != (f0, fhist):
            bad("%s: transitions differ from the zone file" % name)
    for h in hist:
        insts.update((h[0] - 1, h[0], h[0] + 1))
    last = hist[-1][0] if hist else year_start(1800)
    rule = t["zones"][zi][4]
    for y in range(1800, 2201):
        insts.update((year_start(y), year_start(y) + 181 * 86400))
        if detailed and rule != 255 and year_start(y + 1) > last:
            for c in rule_changes(t, t["rules"][rule], y):
                insts.update((c - 1, c, c + 1))
    if detailed:
        insts.update(range(last, year_start(2200), 3 * 3600))
    for inst in sorted(insts):
        a, b = offset_at(t, zi, inst), zi_offset(z, inst)
        if a != b:
            bad("%s at %d: tables %d, zoneinfo %d" % (name, inst, a, b))
    return len(insts)


def main():
    tables, cache = sys.argv[1], sys.argv[2]
    zone_bin = sys.argv[3] if len(sys.argv) > 3 else None
    tzdb = pinned(cache, "jiff-tzdb-1.0.0.crate")
    blob = member(tzdb, "jiff-tzdb-1.0.0/concatenated-zoneinfo.dat")
    entries = [(n, int(a), int(b)) for n, a, b in re.findall(
        r'\(r"([^"]+)", (\d+)\.\.(\d+)\)', member(tzdb, "jiff-tzdb-1.0.0/tzname.rs").decode())]
    meta = member(pinned(cache, "jiff-1.0.0.crate"), "jiff-1.0.0/src/tz/db/metadata.rs").decode()
    meta = meta[:meta.index("TIME_ZONE_METADATA")]
    prim = dict(re.findall(r'\("([^"]+)", "([^"]+)"\),', meta))
    src = open(tables + "/tzdb_data.zig").read()
    t = zig_tables(src)
    names = re.findall(r"^    \\\\(.*)$", open(tables + "/tzdb_names.zig").read(), re.M)
    name_zones = zig_array(src, "name_zones")
    name_primaries = zig_array(src, "name_primaries")
    if names != [n for n, _, _ in entries]:
        bad("names differ from tzname.rs")
    checked = 0
    for i, (name, a, b) in enumerate(entries):
        if names[name_primaries[i]] != prim[name]:
            bad("%s: primary %s, not %s" % (name, names[name_primaries[i]], prim[name]))
        checked += compare(t, name_zones[i], blob[a:b], name, name in SAMPLE)
    print("all %d names: %d instants" % (len(entries), checked))

    tt = zig_tables(open(tables + "/tzdb_test_data.zig").read())
    n = compare(tt, 0, pinned(cache, "europe-dublin.tzif"), "Europe/Dublin (test)", True)
    print("test Dublin: %d instants" % n)
    for y in (1970, 2026, 2087, 2199):
        for inst in (year_start(y), year_start(y) + 1, year_start(y + 1) - 1, year_start(y) + 200 * 86400):
            if offset_at(tt, 1, inst) != 3600:
                bad("Test/Morocco at %d: %d, not +01" % (inst, offset_at(tt, 1, inst)))

    if zone_bin:
        runs = 0
        for name in SAMPLE:
            i = names.index(name)
            t0, hist = zone_history(t, name_zones[i])
            insts = [h[0] + d for h in hist[-12:] for d in (-1, 0)]
            insts += [year_start(y) + d * 86400 for y in (1900, 1960, 2030, 2100) for d in (0, 90, 180, 270)]
            for inst in insts:
                out = subprocess.run([zone_bin, name.lower(), str(inst)], capture_output=True, text=True).stdout.strip()
                runs += 1
                if out != str(offset_at(t, name_zones[i], inst)):
                    bad("%s at %d: zone prints %s" % (name, inst, out))
        print("zone program: %d runs" % runs)
    print("FAIL: %d mismatches" % len(BAD) if BAD else "OK")
    sys.exit(1 if BAD else 0)


if __name__ == "__main__":
    main()
