import os, sys, collections
lines, files = collections.Counter(), collections.Counter()
for p in sys.stdin.buffer.read().split(b"\0"):
    if not p or not os.path.isfile(p): continue
    data = open(p, "rb").read()
    if b"\0" in data[:8192]: continue
    ext = os.path.splitext(p)[1].decode() or os.path.basename(p).decode()
    lines[ext] += data.count(b"\n"); files[ext] += 1
for ext, n in lines.most_common(): print("%-14s %6d files %9d lines" % (ext, files[ext], n))
print("%-14s %6d files %9d lines" % ("TOTAL", sum(files.values()), sum(lines.values())))
