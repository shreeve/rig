#!/usr/bin/env python3
"""tools/map-trace.py [FILE]: summarize a Map trace that a program built
with RIG_MAP_TRACE=1 wrote (default rig-map-trace.bin, with FILE.types
beside it): op counts per map id and per K/V type, the hit rate of
lookups and writes, and histograms of key width and length after each op.

A record is 48 bytes, little-endian (docs/internals/INTERNALS.md, "The
Map trace"):

    0   u8   op in bits 0-2, thread bits 0-4 in bits 3-7
    1   u8   hit in bit 0, thread bits 5-11 in bits 1-7
    2   u16  key width in bytes (65535 for any wider)
    4   u32  map id, from 1 in the order the trace first saw each
    8   u32  the value's size in bytes (0 for a Set)
    12  u32  length after the op
    16  u64  key hash, as the Map hashes it (a grow: the table's slots)
    24  24B  the key's first 24 bytes, zero-padded

--records N prints the first N records as well.
"""
import struct
import sys
from collections import Counter, defaultdict

OPS = ["get", "put", "remove", "clear", "new", "drop", "grow", "retain"]
RECORD = struct.Struct("<BBHIIIQ24s")


def records(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) % RECORD.size:
        sys.exit(f"{path}: {len(data)} bytes is not a whole number of {RECORD.size}-byte records")
    for fields in RECORD.iter_unpack(data):
        op_byte, hit_byte, width, map_id, value_bytes, length, h, head = fields
        yield {
            "op": OPS[op_byte & 7],
            "thread": (op_byte >> 3) | ((hit_byte >> 1) << 5),
            "hit": bool(hit_byte & 1),
            "width": width,
            "id": map_id,
            "value_bytes": value_bytes,
            "len": length,
            "hash": h,
            "key": head[: min(width, 24)],
        }


def types(path):
    names = {}
    try:
        with open(path) as f:
            for line in f:
                map_id, k, v, kind = line.rstrip("\n").split("\t")
                names[int(map_id)] = (k, v, kind)
    except FileNotFoundError:
        pass
    return names


def bucket(n):
    """The power-of-two range `n` falls in: 0, 1, 2-3, 4-7, ..."""
    if n < 2:
        return str(n)
    lo = 1 << (n.bit_length() - 1)
    return f"{lo}-{2 * lo - 1}"


def bucket_key(label):
    return int(label.split("-")[0])


def histogram(title, counts):
    total = sum(counts.values())
    print(f"\n{title}")
    for label in sorted(counts, key=bucket_key):
        n = counts[label]
        print(f"  {label:>13}  {n:>12}  {100 * n / total:5.1f}%")


def main():
    args = sys.argv[1:]
    show = 0
    if "--records" in args:
        i = args.index("--records")
        show = int(args[i + 1])
        del args[i : i + 2]
    path = args[0] if args else "rig-map-trace.bin"
    names = types(path + ".types")
    per_map = defaultdict(Counter)
    per_type = defaultdict(Counter)
    hits = Counter()
    tries = Counter()
    widths = Counter()
    lengths = Counter()
    threads = Counter()
    n = 0
    for r in records(path):
        if n < show:
            print(r)
        n += 1
        op = r["op"]
        per_map[r["id"]][op] += 1
        per_type[names.get(r["id"], ("?", "?", "?"))][op] += 1
        threads[r["thread"]] += 1
        if op in ("get", "put", "remove"):
            tries[op] += 1
            hits[op] += r["hit"]
            widths[bucket(r["width"])] += 1
        lengths[bucket(r["len"])] += 1
    print(f"{n} records, {len(per_map)} maps, {len(threads)} threads")
    if n == 0:
        return
    print("\nhit rate")
    for op in ("get", "put", "remove"):
        if tries[op]:
            print(f"  {op:>6}  {hits[op]:>12} of {tries[op]:>12}  {100 * hits[op] / tries[op]:5.1f}%")
    print("\nops per K/V type")
    for (k, v, kind), c in sorted(per_type.items(), key=lambda e: -sum(e[1].values())):
        ops = "  ".join(f"{op} {c[op]}" for op in OPS if c[op])
        print(f"  {kind} {k} -> {v}: {sum(c.values())}  ({ops})")
    print("\nops per map (the 40 busiest)")
    for map_id, c in sorted(per_map.items(), key=lambda e: -sum(e[1].values()))[:40]:
        k, v, kind = names.get(map_id, ("?", "?", "?"))
        ops = "  ".join(f"{op} {c[op]}" for op in OPS if c[op])
        print(f"  {map_id:>8} {kind} {k} -> {v}: {sum(c.values())}  ({ops})")
    histogram("key width in bytes (get, put, remove)", widths)
    histogram("length after each op", lengths)


if __name__ == "__main__":
    main()
