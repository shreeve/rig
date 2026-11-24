#!/usr/bin/env python3
"""mkpoison.py ERR OUT [nolib]: the validation pass's table from a c1 census run (the poison build's stderr): for each
file's tree, positions, text and names (bits 1 2 4 8), the touch number after which the census says no read of them
is left (LRQ; 0 for none after the load's end), sorted. `nolib` leaves the bundled libs out."""
import sys
err, out = sys.argv[1], sys.argv[2]
opts = sys.argv[3:]
nolib = "nolib" in opts
mask = 15
for o in opts:
    if o.startswith("bits="):
        mask = int(o[5:])
only = [int(o[5:]) for o in opts if o.startswith("file=")]
q, files, libs = {}, set(), set()
for line in open(err, errors="replace"):
    p = line.rstrip("\n").split("\t")
    if p[0] == "LRQ":
        q[(int(p[1]), int(p[2]))] = int(p[3])
    elif p[0] == "LRF":
        files.add(int(p[1]) + 1)
        if p[2] == "1":
            libs.add(int(p[1]) + 1)
rows = []
for f in files:
    if nolib and f in libs:
        continue
    if only and f not in only:
        continue
    for bit in range(4):
        if not (mask >> bit) & 1:
            continue
        rows.append((q.get((f, bit), 0), f, 1 << bit))
rows.sort()
with open(out, "w") as o:
    for s, f, b in rows:
        o.write("%d\t%d\t%d\n" % (s, f, b))
print("%d releases, %d files" % (len(rows), len(files)))
