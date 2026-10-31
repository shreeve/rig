#!/usr/bin/env python3
"""where.py TRACE: on a trace with prefault off (RIG_KT=tslg), where the
touched pages lie: in new large blocks (first 3/4 vs last 1/4), in growths
(first half of the gain vs second), and in segment stretches (below vs above
the highest touched page of the segment: a tail never reached)."""
import sys, collections
PG = 4096
ev = [l.split() for l in open(sys.argv[1])]
ev = [w for w in ev if w and w[0] in ('madvise', 'munmap', 'mmap', 'mremap', 'fault')]
ev.sort(key=lambda w: int(w[1]))
blocks = {}  # start -> [len, touched set(page offsets), kind, gain_lo, gain_hi]
segs = {}    # seg base -> set of touched page offsets
seg_pref = collections.defaultdict(set)  # seg base -> pages covered by (skipped) prefault ranges
res = collections.Counter()
nxt = None
def blk(addr):
    for s, b in blocks.items():
        if s <= addr < s + b[0]: return s, b
    return None, None
def close(s, b):
    n = b[0] // PG
    if b[2] == 'new':
        q = (n - n // 4)
        res['new pages'] += n; res['new touched <3/4'] += sum(1 for o in b[1] if o < q); res['new touched >=3/4'] += sum(1 for o in b[1] if o >= q)
        res['new pages >=3/4'] += n - q
for w in ev:
    k = w[0]
    if k == 'madvise':
        beh = int(w[5])
        if beh >= 0x7700:
            nxt = beh - 0x7700
            a, n = int(w[3], 16), int(w[4])
            if nxt == 15: segs[a] = set()
            if nxt in (1, 2):
                base = a & ~((4 << 20) - 1)
                for p in range(a // PG, (a + n) // PG): seg_pref[base].add(p - base // PG)
        continue
    if k == 'mmap' and nxt == 14:
        blocks[int(w[6], 16)] = [int(w[4]), set(), 'new', 0, 0]; nxt = None; continue
    if k == 'mremap':
        a, on, nn, ret = int(w[3], 16), int(w[4]), int(w[5]), int(w[6], 16)
        b = blocks.pop(a, None)
        if b is None: continue
        # close the previous growth window
        if b[2] == 'grow': 
            pass
        else:
            close(a, b)
        lo, hi = on // PG, nn // PG
        half = lo + (hi - lo) // 2
        res['grow pages'] += hi - lo
        nb = [nn, set(b[1]), 'grow', lo, hi]
        blocks[ret] = nb; continue
    if k == 'munmap':
        a, n = int(w[3], 16), int(w[4])
        for s in list(blocks):
            if a <= s < a + n:
                b = blocks.pop(s)
                if b[2] == 'new': close(s, b)
        continue
    if k == 'fault':
        addr = int(w[3], 16)
        s, b = blk(addr)
        if b is not None:
            off = (addr - s) // PG
            if off not in b[1]:
                b[1].add(off)
                if b[2] == 'grow' and b[3] <= off < b[4]:
                    half = b[3] + (b[4] - b[3]) // 2
                    res['grow touched 1st half' if off < half else 'grow touched 2nd half'] += 1
            continue
        base = addr & ~((4 << 20) - 1)
        if base in segs: segs[base].add((addr - base) // PG)
for s, b in blocks.items():
    if b[2] == 'new': close(s, b)
# segments: untouched prefaulted pages below vs above the highest touched page
below = above = 0
for base, t in segs.items():
    if not t: continue
    top = max(t)
    for p in seg_pref[base]:
        if p in t: continue
        if p > top: above += 1
        else: below += 1
for k in sorted(res): print(f'{k:28} {res[k]}')
print(f'segment prefault untouched: inside the reached part {below}, past the highest touched page {above}')
