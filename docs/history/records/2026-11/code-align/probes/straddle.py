#!/usr/bin/env python3
"""straddle.py [--all] BIN...: the layout check prototype. Every loop (a
backward branch and its target) in the program section (__rig_text; with
--all, in all of __TEXT) of at most 256 bytes whose span crosses a 4 KiB boundary, by function."""
import re, subprocess, sys
MAX = 256  # a loop of at most this many bytes: the inner, hot kind
allsec = "--all" in sys.argv
for b in [a for a in sys.argv[1:] if a != "--all"]:
    args = ["xcrun", "llvm-objdump", "-d", "--no-show-raw-insn"] + ([] if allsec else ["--section=__rig_text"]) + [b]
    fn, hits, loops = None, [], 0
    for l in subprocess.run(args, capture_output=True, text=True).stdout.splitlines():
        m = re.match(r"([0-9a-f]+) <(.*)>:", l)
        if m: fn = m.group(2); continue
        m = re.match(r"\s*([0-9a-f]+):\s+(b\.\w+|b|cbn?z|tbn?z)\s+(.*)", l)
        if not m: continue
        t = re.search(r"0x([0-9a-f]+) <", m.group(3))
        if not t: continue
        a, ta = int(m.group(1), 16), int(t.group(1), 16)
        if ta <= a:
            loops += 1
            if ta // 4096 != a // 4096 and a + 4 - ta <= MAX: hits.append("%s %x..%x (%d B)" % (fn, ta, a + 4, a + 4 - ta))
    print("%s: %d loops, %d cross 4 KiB%s" % (b.split("scratchpad/")[-1], loops, len(hits), "".join("\n    " + h for h in hits)))
