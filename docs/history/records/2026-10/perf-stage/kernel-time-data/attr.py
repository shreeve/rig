#!/usr/bin/env python3
"""attr.py TRACE: attribute a trace.bt run of the prototype build (RIG_KT
with t) to the allocator's sites. Each site's tag, an invalid madvise
(0x7700 + site), names the kernel call(s) after it. Prints, per site, the
calls, bytes and time in the kernel; the user page faults by the kind of
mapping they fall in; and, for prefault sites that were skipped (RIG_KT s,
l or g), how many of the pages they would have faulted in were touched
before they were unmapped or the program ended."""
import sys, collections
SITES = {1: 'segment: next 1 MiB prefault', 2: 'segment: new, first 1 MiB prefault', 3: 'segment: huge advice',
         4: 'large: new block prefault (3/4)', 5: 'large: new >=16 MiB huge advice', 6: 'large: growth prefault (half the gain)',
         7: 'large: growth huge advice', 8: 'large: mapLarge 2 MiB alignment unmaps', 9: 'large: keepPiece remnant unmap',
         10: 'large: trimKept unmap', 11: 'large: freeLarge over keepBound unmap', 12: 'large: growth mremap',
         13: 'large: failed growth unmap', 14: 'large: mapPages mmap', 15: 'segment taken from the region',
         20: 'table: reserve, small pages (mmap + NOHUGEPAGE)', 21: 'table: reserve, huge (mmap, trims, advice)', 22: 'table: unreserve munmap'}
ALLOW = {20: {'mmap': 1, 'madvise': 1}, 21: {'mmap': 1, 'munmap': 2, 'madvise': 2}}
MADV = {23: 'POPULATE_WRITE', 14: 'HUGEPAGE', 15: 'NOHUGEPAGE', 4: 'DONTNEED', 8: 'FREE', 0: 'NORMAL'}
PG = 4096
ev = []
for line in open(sys.argv[1]):
    w = line.split()
    if not w or w[0] not in ('madvise', 'munmap', 'mmap', 'mremap', 'fault', 'exit'): continue
    ev.append(w)
ev.sort(key=lambda w: int(w[1]))
stat = collections.defaultdict(lambda: [0, 0, 0])  # calls, bytes, ns
maps = []  # [start, end, kind]
def addmap(a, n, kind): maps.append([a, a + n, kind])
def unmap(a, n):
    global maps
    out = []
    for s, e, k in maps:
        if e <= a or s >= a + n: out.append([s, e, k]); continue
        if s < a: out.append([s, a, k])
        if e > a + n: out.append([a + n, e, k])
    maps = out
def kindof(x):
    for s, e, k in maps:
        if s <= x < e: return k
    return 'other'
faults = collections.Counter()
pending = {}  # page -> site, prefault ranges skipped
touched = collections.Counter(); untouched = collections.Counter(); would = collections.Counter()
cur = None; budget = None; last_tag_skip = None
def drop_pending(a, n):
    for pg in range(a // PG, (a + n + PG - 1) // PG):
        s = pending.pop(pg, None)
        if s is not None: untouched[s] += 1
def take(kind, w):
    """The site this untagged call belongs to, by the last tag."""
    global cur, budget
    if cur is None: return None
    if cur in ALLOW:
        if budget.get(kind, 0) > 0:
            budget[kind] -= 1; return cur
        return None
    if budget.get(kind, 0) > 0:
        budget[kind] -= 1; s = cur
        if sum(budget.values()) == 0: cur = None
        return s
    return None
EXPECT = {1: 'madvise', 2: 'madvise', 3: 'madvise', 4: 'madvise', 5: 'madvise', 6: 'madvise', 7: 'madvise', 8: 'munmap',
          9: 'munmap', 10: 'munmap', 11: 'munmap', 12: 'mremap', 13: 'munmap', 14: 'mmap', 22: 'munmap'}
skipped_tag = None
for w in ev:
    k = w[0]
    if k == 'fault':
        if skipped_tag is not None:
            sa, sn, ss = skipped_tag
            for pg in range(sa // PG, (sa + sn) // PG): pending.setdefault(pg, ss)
            would[ss] += sn // PG; skipped_tag = None
        addr = int(w[3], 16); faults[kindof(addr)] += 1
        s = pending.pop(addr // PG, None)
        if s is not None: touched[s] += 1
        continue
    if k == 'exit': continue
    t, tid = int(w[1]), int(w[2])
    if k == 'madvise':
        a, n, beh, ret, ns = int(w[3], 16), int(w[4]), int(w[5]), int(w[6]), int(w[7])
        if beh >= 0x7700:
            site = beh - 0x7700
            # a prefault tag whose populate did not follow was skipped
            if skipped_tag is not None:
                sa, sn, ss = skipped_tag
                for pg in range(sa // PG, (sa + sn) // PG): pending.setdefault(pg, ss)
                would[ss] += sn // PG
                skipped_tag = None
            if site == 15: addmap(a, n, 'segment'); stat[site][0] += 1; stat[site][1] += n; continue
            if site in (1, 2, 4, 6): skipped_tag = (a, n, site)
            cur = site; budget = dict(ALLOW[site]) if site in ALLOW else {EXPECT.get(site, 'x'): 1}
            continue
        if skipped_tag is not None and beh == 23 and a == skipped_tag[0]:
            skipped_tag = None
        elif skipped_tag is not None:
            sa, sn, ss = skipped_tag
            for pg in range(sa // PG, (sa + sn) // PG): pending.setdefault(pg, ss)
            would[ss] += sn // PG; skipped_tag = None
        site = take('madvise', w)
        key = site if site is not None else 'other madvise ' + MADV.get(beh, str(beh))
        stat[key][0] += 1; stat[key][1] += n; stat[key][2] += ns
        continue
    if skipped_tag is not None:
        sa, sn, ss = skipped_tag
        for pg in range(sa // PG, (sa + sn) // PG): pending.setdefault(pg, ss)
        would[ss] += sn // PG; skipped_tag = None
    if k == 'mmap':
        a, n, fl, ret, ns = int(w[3], 16), int(w[4]), int(w[5]), int(w[6], 16), int(w[7])
        site = take('mmap', w)
        if site in (20, 21): addmap(ret, n, 'table')
        elif site == 14: addmap(ret, n, 'large')
        elif n > (32 << 30): addmap(ret, n, 'region')
        else: addmap(ret, n, 'other-anon' if fl & 0x20 else 'file')
        key = site if site is not None else ('other mmap noreserve' if fl & 0x4000 else 'other mmap')
        stat[key][0] += 1; stat[key][1] += n; stat[key][2] += ns
    elif k == 'munmap':
        a, n, ns = int(w[3], 16), int(w[4]), int(w[7])
        site = take('munmap', w)
        drop_pending(a, n); unmap(a, n)
        key = site if site is not None else 'other munmap'
        stat[key][0] += 1; stat[key][1] += n; stat[key][2] += ns
    elif k == 'mremap':
        a, on, nn, ret, ns = int(w[3], 16), int(w[4]), int(w[5]), int(w[6], 16), int(w[7])
        site = take('mremap', w)
        kind = kindof(a)
        # move pending pages with the block
        moved = {}
        for pg in list(pending):
            if a // PG <= pg < (a + on) // PG:
                moved[pg - a // PG + ret // PG] = pending.pop(pg)
        pending.update(moved)
        unmap(a, on); unmap(ret, nn); addmap(ret, nn, kind if kind != 'other' else 'large')
        key = site if site is not None else 'other mremap'
        stat[key][0] += 1; stat[key][1] += nn - on; stat[key][2] += ns
for s in pending.values(): untouched[s] += 1
tot = sum(v[2] for v in stat.values())
print(f"{'site':52} {'calls':>6} {'MiB':>9} {'ms':>7} {'share':>6}")
for key, (c, b, ns) in sorted(stat.items(), key=lambda kv: -kv[1][2]):
    name = SITES.get(key, key) if isinstance(key, int) else key
    print(f"{name:52} {c:6d} {b / 2**20:9.1f} {ns / 1e6:7.2f} {100 * ns / tot if tot else 0:5.1f}%")
print(f"{'total':52} {sum(v[0] for v in stat.values()):6d} {'':9} {tot / 1e6:7.2f}")
print()
print('user page faults by mapping:', dict(faults), 'total', sum(faults.values()))
if would:
    print()
    print(f"{'skipped prefault site':40} {'pages':>8} {'touched':>8} {'untouched':>9} {'%untouched':>10}")
    for s in sorted(would):
        print(f"{SITES[s]:40} {would[s]:8d} {touched[s]:8d} {untouched[s]:9d} {100 * untouched[s] / max(1, would[s]):9.1f}%")
