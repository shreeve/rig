#!/usr/bin/env python3
# pop.py STRACE: the MADV_POPULATE_WRITE calls of a run, split into the
# segment region's (advised MADV_HUGEPAGE) and the rest (large blocks), with
# the whole 2 MiB-aligned windows inside each call's range.
import re, sys
H = 2 << 20
seg = None; tot = {"seg": 0, "blk": 0}; win = 0; n = {"seg": 0, "blk": 0}; sizes = {}
for line in open(sys.argv[1]):
    m = re.search(r"mmap\(NULL, (\d+), PROT_READ\|PROT_WRITE, MAP_PRIVATE\|MAP_ANONYMOUS\|MAP_NORESERVE, -1, 0\) = (0x[0-9a-f]+)", line)
    if m and int(m[1]) > 1 << 36: seg = (int(m[2], 16), int(m[2], 16) + int(m[1]))
    m = re.search(r"madvise\((0x[0-9a-f]+), (\d+), MADV_POPULATE_WRITE\)", line)
    if not m: continue
    a, l = int(m[1], 16), int(m[2])
    k = "seg" if seg and seg[0] <= a < seg[1] else "blk"
    tot[k] += l; n[k] += 1
    if k == "blk":
        lo = (a + H - 1) // H * H; hi = (a + l) // H * H
        win += max(0, (hi - lo) // H)
        b = 1 << (l.bit_length() - 1); sizes[b] = sizes.get(b, 0) + l
print(f"segment region populate: {n['seg']} calls, {tot['seg']/2**20:.1f} MiB")
print(f"large-block populate: {n['blk']} calls, {tot['blk']/2**20:.1f} MiB; whole 2 MiB windows inside: {win} ({2*win} MiB)")
for b in sorted(sizes): print(f"  calls of {b>>10} KiB to {2*b>>10} KiB: {sizes[b]/2**20:.1f} MiB")
