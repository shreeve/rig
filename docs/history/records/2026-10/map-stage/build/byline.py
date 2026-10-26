#!/usr/bin/env python3
"""byline.py BIN OFFS PATTERN: the samples whose innermost source line
matches PATTERN, by symbol, and the hottest such instructions."""
import sys, re, subprocess, collections
binp, offs, pat = sys.argv[1:4]
syms = {}
for line in subprocess.run(["nm", "-C", "--defined-only", binp], capture_output=True, text=True).stdout.splitlines():
    m = re.match(r"([0-9a-f]+) [tTwW] (.*)$", line)
    if m: syms.setdefault(m.group(2), int(m.group(1), 16))
cnt = collections.Counter(); owner = {}
for line in open(offs):
    m = re.match(r"\s*(\d+)\s+(.*)\+0x([0-9a-f]+)\s*$", line)
    if not m or m.group(2) not in syms: continue
    a = syms[m.group(2)] + int(m.group(3), 16); cnt[a] += int(m.group(1)); owner[a] = m.group(2)
addrs = sorted(cnt)
a2l = subprocess.run(["addr2line", "-e", binp], input="\n".join("%x" % a for a in addrs), capture_output=True, text=True).stdout.splitlines()
hit = [(a, l) for a, l in zip(addrs, a2l) if re.search(pat, l)]
bysym = collections.Counter()
for a, l in hit: bysym[owner[a]] += cnt[a]
tot = sum(cnt.values())
print(f"{sum(cnt[a] for a, _ in hit)} of {tot} samples")
for s, n in bysym.most_common(12): print(f"  {n:6d}  {s[:110]}")
top = sorted(hit, key=lambda x: -cnt[x[0]])[:12]
for a, l in top:
    d = subprocess.run(["objdump", "-d", "--no-show-raw-insn", "--start-address=0x%x" % a, "--stop-address=0x%x" % (a + 16), binp], capture_output=True, text=True).stdout.splitlines()
    ins = [x for x in d if re.match(r"\s+[0-9a-f]+:", x)]
    print(f"  {cnt[a]:5d} {ins[0].strip() if ins else '?'}   {owner[a][:60]}")
