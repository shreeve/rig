#!/usr/bin/env python3
"""compact.py TRACE OUT: the records of Maps and Sets keyed by U32 (Map U32 -> U32, Map U32 -> Int, Set U32)
as 12-byte records {op u8, kind u8, pad u16, id u32, key u32}; kind 0 Map U32->U32, 1 Map U32->Int, 2 Set U32.
Ids are renumbered densely per kind."""
import sys
import numpy as np
path, out = sys.argv[1], sys.argv[2]
dt = np.dtype([('op', 'u1'), ('hit', 'u1'), ('w', '<u2'), ('id', '<u4'), ('vb', '<u4'), ('len', '<u4'), ('h', '<u8'), ('key', '<u4'), ('rest', 'V20')])
r = np.fromfile(path, dtype=dt)
kinds = {}
for line in open(path + '.types'):
    i, k, v, kind = line.rstrip('\n').split('\t')
    t = (kind, k, v)
    if t == ('Map', 'U32', 'U32'): kinds[int(i)] = 0
    elif t == ('Map', 'U32', 'Int'): kinds[int(i)] = 1
    elif t == ('Set', 'U32', '-'): kinds[int(i)] = 2
n = int(r['id'].max()) + 1
kind_of = np.full(n, 255, np.uint8)
for i, k in kinds.items(): kind_of[i] = k
kk = kind_of[r['id']]
sel = kk != 255
r = r[sel]; kk = kk[sel]
op = r['op'] & 7
keep = op != 6  # grows are implicit
r = r[keep]; kk = kk[keep]; op = op[keep]
newid = np.zeros(n, np.uint32)
counts = []
for k in range(3):
    ids = np.unique(r['id'][kk == k])
    newid[ids] = np.arange(len(ids), dtype=np.uint32)
    counts.append(len(ids))
o = np.zeros(len(r), dtype=np.dtype([('op', 'u1'), ('kind', 'u1'), ('pad', '<u2'), ('id', '<u4'), ('key', '<u4')]))
o['op'] = op; o['kind'] = kk; o['id'] = newid[r['id']]; o['key'] = r['key']
with open(out, 'wb') as f:
    f.write(np.array(counts, dtype='<u4').tobytes())
    f.write(o.tobytes())
print(out, len(o), 'records; maps per kind', counts, 'ops', np.bincount(op, minlength=8).tolist())
