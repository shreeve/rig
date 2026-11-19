#!/usr/bin/env python3
"""layout.py BIN...: where each build puts qsort and std.sort's functions,
and the partition loop's hot span (qsort+0xe4 to +0x170: the loop head,
both push paths, the counter and the back branches) against 32, 64, 128
byte, 4 KiB and 16 KiB boundaries. Also a hash of qsort's instruction
sequence (mnemonics), to show the code is the same in every build."""
import hashlib, re, subprocess, sys
FN = ["___rig_main.qsort", "_rig.std.sort.Ipn(i64).quicksort", "_rig.std.sort.Ipn(i64).sortRegion", "_rig.std.sort.Ipn(i64).heapsort", "___rig_main.psum"]
def funcs(b):
    d = subprocess.run(["xcrun", "llvm-objdump", "-d", "--no-show-raw-insn", "--section=__rig_text", b], capture_output=True, text=True).stdout
    out, cur = {}, None
    for l in d.splitlines():
        m = re.match(r"([0-9a-f]+) <(.*)>:", l)
        if m: cur = m.group(2); out[cur] = [int(m.group(1), 16), []]; continue
        m = re.match(r"\s*([0-9a-f]+):\s+(\S+)", l)
        if m and cur: out[cur][1].append(m.group(2))
    return out
def crosses(lo, hi, n):
    return lo // n != (hi - 1) // n
for b in sys.argv[1:]:
    f = funcs(b)
    a = f[FN[0]][0]
    h = hashlib.md5(" ".join(f[FN[0]][1]).encode()).hexdigest()[:8]
    lo, hi = a + 0xe4, a + 0x170
    x = [str(n) for n in (32, 64, 128, 4096, 16384) if crosses(a + 0xe4, a + 0x110, n)]
    y = [str(n) for n in (32, 64, 128, 4096, 16384) if crosses(lo, hi, n)]
    print("%-28s qsort %x mod64 %2d mod128 %3d head mod64 %2d lo-path crosses %-18s span crosses %-18s %s %s" % (
        b.split("/")[-1], a, a % 64, a % 128, (a + 0xe4) % 64, ",".join(x) or "-", ",".join(y) or "-", h,
        " ".join("%s@%x" % (n.split(".")[-1], f[n][0] % 16384) for n in FN[1:] if n in f)))
