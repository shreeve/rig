#!/usr/bin/env python3
# memtrace.py TRACE BIN OUT [SAMPLES...]
#
# Reads a private build's allocation trace (alloc-trace.diff: 64-byte
# records, TRACE.names, TRACE.maps) and, for each perf-script sample file
# given (lines "TIME EVENT: ADDR IP", from `perf script -F time,event,addr,ip
# --ns`, recorded with `-k CLOCK_MONOTONIC`), charges each sample's data
# address to the block live at that time that holds it: its owner (the type
# allocated, or a tag: "map index K -> V", "table T", "box T") and its site
# (the return addresses of the calls that made it). Writes OUT.json:
#   volume: bytes and blocks allocated, by owner and by site;
#   samples: per event, counts by owner, by site, by region.
import json, struct, sys, bisect, collections, os

REC = struct.Struct('<QQQQ4Q')
SEG = 4 << 20
PAGE = 64 << 10
MAX_SMALL = 32 << 10


def class_size(c):
    if c < 8:
        return (c + 1) * 8
    k = c - 8
    base = 64 << (k // 4)
    return base + (base // 4) * (k % 4 + 1)


SIZES = [class_size(c) for c in range(8 + 4 * 9)]


def block_size(n):
    # alloc.zig's classOf for alignment <= 8: the least class that fits.
    if n > MAX_SMALL:
        return None
    return SIZES[bisect.bisect_left(SIZES, max(n, 8))]


def load_names(path):
    names = {0: 'untyped'}
    for line in open(path, errors='replace'):
        i, _, name = line.rstrip('\n').partition('\t')
        if i.isdigit():
            names[int(i)] = name
    return names


def load_maps(path):
    out = []
    for line in open(path, errors='replace'):
        parts = line.split(None, 5)
        lo, hi = (int(x, 16) for x in parts[0].split('-'))
        name = parts[5].strip() if len(parts) > 5 else ''
        out.append((lo, hi, name))
    out.sort()
    return out


def load_samples(paths, ns_of):
    by_event = collections.defaultdict(list)
    for p in paths:
        for line in open(p, errors='replace'):
            f = line.split()
            if len(f) < 4:
                continue
            try:
                t = int(round(float(f[0].rstrip(':')) * 1e9))
                ev = f[1].rstrip(':')
                addr = int(f[2], 16)
                ip = int(f[3], 16)
            except ValueError:
                continue
            by_event[ev].append((t, addr, ip))
    return by_event


def main():
    trace, binary, out = sys.argv[1:4]
    sample_files = sys.argv[4:]
    names = load_names(trace + '.names')
    maps = load_maps(trace + '.maps')
    raw = open(trace, 'rb').read()
    n = len(raw) // REC.size
    # The clock: the first and last records are (tsc, CLOCK_MONOTONIC ns).
    first = REC.unpack_from(raw, 0)
    last = REC.unpack_from(raw, (n - 1) * REC.size)
    assert first[3] & 0xff == 6 and last[3] & 0xff == 6, 'no clock records'
    k = (last[1] - first[1]) / (last[0] - first[0])

    def ns_of(tsc):
        return first[1] + (tsc - first[0]) * k

    samples = load_samples(sample_files, ns_of)
    # Every sample, in time order, as (tsc, event, addr, ip).
    allsamp = []
    for ev, rows in samples.items():
        for t, a, ip in rows:
            tsc = first[0] + (t - first[1]) / k
            allsamp.append((tsc, ev, a, ip))
    allsamp.sort()

    vol_owner = collections.defaultdict(lambda: [0, 0, 0])  # bytes, blocks, bytes of block sizes
    vol_site = collections.defaultdict(lambda: [0, 0])
    sites = {}  # frames tuple -> id
    site_owner = {}
    live_small = {}  # block start -> (owner, site)
    page_size_of = {}  # 64 KiB page -> block size
    live_large = {}  # start -> (len, owner, site)
    large_starts = []
    tables = []  # (start, end, owner)
    copies = collections.defaultdict(lambda: [0, 0])  # site -> bytes copied by growth that moved, count
    hits = collections.defaultdict(lambda: collections.Counter())  # event -> (owner, site, region) counter
    peak_live = 0
    live_bytes = 0
    si = 0
    nsamp = len(allsamp)
    prev = None  # the last alloc record, for alloc-then-free copy pairs

    def resolve(a):
        # Tables first, then large blocks, then a small block's start.
        j = bisect.bisect_right(tables, (a, 1 << 64)) - 1
        if j >= 0 and tables[j][0] <= a < tables[j][1]:
            return ('table', tables[j][2], -1)
        j = bisect.bisect_right(large_starts, a) - 1
        if j >= 0:
            s = large_starts[j]
            ln, o, st = live_large[s]
            if a < s + ln:
                return ('large', o, st)
        page = a & ~(PAGE - 1)
        bs = page_size_of.get(page)
        if bs:
            start = page + ((a - page) // bs) * bs
            got = live_small.get(start)
            if got:
                return ('small', got[0], got[1])
            return ('freed', -1, -1)
        j = bisect.bisect_right(maps, (a, 1 << 64, '')) - 1
        if j >= 0 and maps[j][0] <= a < maps[j][1]:
            nm = maps[j][2]
            if nm.startswith('[stack'):
                return ('stack', -2, -1)
            if nm:
                return ('file ' + os.path.basename(nm), -3, -1)
            return ('anon', -4, -1)
        return ('unmapped', -5, -1)

    def add_live(ptr, ln, o, st):
        bs = block_size(ln)
        if bs is None:
            if ptr not in live_large:
                bisect.insort(large_starts, ptr)
            live_large[ptr] = (ln, o, st)
            return ln
        page_size_of[ptr & ~(PAGE - 1)] = bs
        live_small[ptr] = (o, st)
        return bs

    def drop_live(ptr, ln):
        bs = block_size(ln)
        if bs is None:
            if ptr in live_large:
                del live_large[ptr]
                j = bisect.bisect_left(large_starts, ptr)
                if j < len(large_starts) and large_starts[j] == ptr:
                    large_starts.pop(j)
            return ln
        live_small.pop(ptr, None)
        return bs

    def site_of(frames, o):
        key = (o,) + tuple(frames)
        sid = sites.get(key)
        if sid is None:
            sid = len(sites)
            sites[key] = sid
            site_owner[sid] = o
        return sid

    for i in range(1, n - 1):
        tsc, ptr, ln, oo, f0, f1, f2, f3 = REC.unpack_from(raw, i * REC.size)
        while si < nsamp and allsamp[si][0] <= tsc:
            _, ev, a, ip = allsamp[si]
            region, o, st = resolve(a)
            hits[ev][(region, o, st, ip)] += 1
            si += 1
        op = oo & 0xff
        o = (oo >> 8) & 0xffffff
        if op == 1:
            st = site_of((f0, f1, f2, f3), o)
            b = add_live(ptr, ln, o, st)
            v = vol_owner[o]; v[0] += ln; v[1] += 1; v[2] += b
            w = vol_site[st]; w[0] += ln; w[1] += 1
            live_bytes += b
            prev = (ptr, ln, st)
        elif op == 2:
            b = drop_live(ptr, ln)
            live_bytes -= b
            # reallocSlice's move: alloc new, copy, free old, in that order.
            if prev is not None and prev[0] != ptr and prev[1] > ln:
                c = copies[prev[2]]; c[0] += ln; c[1] += 1
            prev = None
        elif op == 3:
            old_len = oo >> 32
            old_ptr = f3
            st = site_of((f0, f1, f2, 0), o)
            drop_live(old_ptr, old_len)
            add_live(ptr, ln, o, st)
            v = vol_owner[o]; v[0] += ln - old_len; v[2] += ln - old_len
            w = vol_site[st]; w[0] += ln - old_len
            live_bytes += ln - old_len
            prev = None
        elif op == 4:
            old_len = oo >> 32
            if block_size(ln) is None:
                add_live(ptr, ln, live_large.get(ptr, (0, o, 0))[1], live_large.get(ptr, (0, o, 0))[2])
            v = vol_owner[o]; v[0] += ln - old_len
            prev = None
        elif op == 5:
            bisect.insort(tables, (ptr, ptr + ln, o))
            prev = None
        peak_live = max(peak_live, live_bytes)
    while si < nsamp:
        _, ev, a, ip = allsamp[si]
        region, o, st = resolve(a)
        hits[ev][(region, o, st, ip)] += 1
        si += 1

    res = {
        'records': n,
        'names': {str(k): v for k, v in names.items()},
        'peak_live_block_bytes': peak_live,
        'volume_owner': {str(k): v for k, v in vol_owner.items()},
        'volume_site': {str(k): v for k, v in vol_site.items()},
        'copies_site': {str(k): v for k, v in copies.items()},
        'sites': {str(v): [k[0]] + ['%x' % x for x in k[1:]] for k, v in sites.items()},
        'tables': [[('%x' % a), b - a, o] for a, b, o in tables],
        'samples': {ev: [[r, o, st, '%x' % ip, c] for (r, o, st, ip), c in cnt.items()] for ev, cnt in hits.items()},
    }
    json.dump(res, open(out, 'w'))
    print('records', n, 'peak block bytes', peak_live, 'sites', len(sites), 'samples', nsamp)


main()
