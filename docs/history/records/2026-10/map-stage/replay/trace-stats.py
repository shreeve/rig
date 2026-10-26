#!/usr/bin/env python3
"""trace-stats.py TRACE [N]: per K/V type of a Map trace, the N busiest:
maps, ops, get/put/remove counts and hit rates, clears, grows, the key's
width and the value's bytes, and the largest length any of its maps
reached; then the share of lookups that found a key put in within the
last 16 puts of its map (the locality dense entries keep)."""
import struct, sys, collections
R = struct.Struct("<BBHIIIQ24s")
path = sys.argv[1]
top = int(sys.argv[2]) if len(sys.argv) > 2 else 14
names = {}
for line in open(path + ".types"):
    i, k, v, kind = line.rstrip("\n").split("\t")
    names[int(i)] = f"{kind} {k} -> {v}"
data = open(path, "rb").read()
T = collections.defaultdict(lambda: collections.Counter())
widths = {}; vbytes = {}
maxlen = collections.Counter()
maps = collections.defaultdict(set)
for f in R.iter_unpack(data):
    op = f[0] & 7; hit = f[1] & 1; mid = f[3]
    t = names.get(mid, "?")
    c = T[t]
    c[op] += 1
    if op <= 2:
        c[(op, hit)] += 1
        widths[t] = f[2]; vbytes[t] = f[4]
    maps[t].add(mid)
    if f[5] > maxlen[mid]: maxlen[mid] = f[5]
tot = sum(sum(c[o] for o in (0, 1, 2)) for c in T.values())
print(f"{tot} lookups, puts, and takes; {sum(len(s) for s in maps.values())} maps")
print(f"{'type':<58} {'maps':>7} {'get':>9} {'hit%':>5} {'put':>9} {'new%':>5} {'take':>7} {'clear':>8} {'grow':>6} {'K B':>4} {'V B':>4} {'max len':>8} {'share':>6}")
for t, c in sorted(T.items(), key=lambda e: -sum(e[1][o] for o in (0, 1, 2)))[:top]:
    g, p, r = c[0], c[1], c[2]
    ml = max(maxlen[m] for m in maps[t])
    share = 100 * (g + p + r) / tot
    gh = 100 * c[(0, 1)] / g if g else 0
    pn = 100 * c[(1, 0)] / p if p else 0
    print(f"{t[:58]:<58} {len(maps[t]):>7} {g:>9} {gh:>5.1f} {p:>9} {pn:>5.1f} {r:>7} {c[3]:>8} {c[6]:>6} {widths.get(t, 0):>4} {vbytes.get(t, 0):>4} {ml:>8} {share:>5.1f}%")
# Size histogram of the maps of the top two types by count.
for t in ("Map U32 -> U32", "Map checker.CacheKey -> U32", "Map checker.InferenceKey -> I32"):
    h = collections.Counter()
    for m in maps.get(t, ()):
        n = maxlen[m]
        h["0" if n == 0 else "1-8" if n <= 8 else "9-16" if n <= 16 else "17-64" if n <= 64 else "65-1k" if n <= 1024 else ">1k"] += 1
    print(f"{t}: largest length of each map: " + ", ".join(f"{k}: {h[k]}" for k in ("0", "1-8", "9-16", "17-64", "65-1k", ">1k")))
