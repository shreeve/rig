#!/usr/bin/env python3
"""padcost.py BIN: what aligning functions would cost in the program
section: for the functions holding an inner loop (a backward branch
spanning at most 256 bytes), their count, bytes, and the expected padding
(half the alignment each) of align(64) on them, and of each aligned to its
size's next power of two (at most 4 KiB; which keeps such a function,
and so its loops, off any 4 KiB boundary when it is at most 4 KiB)."""
import re, subprocess, sys
b = sys.argv[1]
d = subprocess.run(["xcrun", "llvm-objdump", "-d", "--no-show-raw-insn", "--section=__rig_text", b], capture_output=True, text=True).stdout
starts, loopy, fn = [], set(), None
for l in d.splitlines():
    m = re.match(r"([0-9a-f]+) <(.*)>:", l)
    if m: fn = m.group(2); starts.append((int(m.group(1), 16), fn)); continue
    m = re.match(r"\s*([0-9a-f]+):\s+(b\.\w+|b|cbn?z|tbn?z)\s+.*?0x([0-9a-f]+) <", l)
    if m:
        a, t = int(m.group(1), 16), int(m.group(3), 16)
        if t <= a and a + 4 - t <= 256: loopy.add(fn)
end = starts[-1][0] + 4
size = {}
for (a, f), (n, _) in zip(starts, starts[1:] + [(end, None)]): size[f] = n - a
tot = sum(size.values()); ls = [size[f] for f in loopy]
p2 = lambda s: min(4096, 1 << max(2, (s - 1).bit_length()))
print("program section %d bytes, %d functions; %d hold an inner loop, %d bytes" % (tot, len(size), len(ls), sum(ls)))
print("align(64) on those: expected padding %d bytes (%.1f%%)" % (len(ls) * 32, 100.0 * len(ls) * 32 / tot))
print("align(next power of two of size, at most 4096) on those: expected padding %d bytes (%.1f%%); %d of them are over 4 KiB" % (
    sum(p2(s) // 2 for s in ls), 100.0 * sum(p2(s) // 2 for s in ls) / tot, sum(s > 4096 for s in ls)))
