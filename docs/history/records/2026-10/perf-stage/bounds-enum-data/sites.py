# sites.py BIN OFFS PATTERN TOPN: sample addresses whose innermost line matches PATTERN, top N, with context.
import re, sys, subprocess, collections
binp, offs, pat, topn = sys.argv[1], sys.argv[2], re.compile(sys.argv[3]), int(sys.argv[4])
syms = {}
for line in subprocess.run(["nm", "-C", "--defined-only", binp], capture_output=True, text=True).stdout.splitlines():
    m = re.match(r"([0-9a-f]+) [tTwW] (.*)$", line)
    if m: syms.setdefault(m.group(2), int(m.group(1), 16))
cnt = collections.Counter(); name = {}
for line in open(offs):
    m = re.match(r"\s*(\d+)\s+(.*)\+0x([0-9a-f]+)\s*$", line)
    if not m or m.group(2) not in syms: continue
    a = syms[m.group(2)] + int(m.group(3), 16); cnt[a] += int(m.group(1)); name[a] = m.group(2) + "+0x" + m.group(3)
addrs = sorted(cnt)
a2l = subprocess.run(["addr2line", "-e", binp], input="\n".join("%x" % a for a in addrs), capture_output=True, text=True).stdout.splitlines()
hits = [(cnt[a], a) for a, s in zip(addrs, a2l) if pat.search(s)]
hits.sort(reverse=True)
tot = sum(c for c, _ in hits); print("total samples", tot, "sites", len(hits))
for c, a in hits[:topn]:
    print("\n=== %d samples  %s" % (c, name[a]))
    chain = subprocess.run(["addr2line", "-i", "-f", "-C", "-e", binp, "%x" % a], capture_output=True, text=True).stdout.splitlines()
    print("   inline:", " <- ".join(chain[1::2][:5]))
    out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", "-C", "--start-address=0x%x" % (a - 48), "--stop-address=0x%x" % (a + 16), binp], capture_output=True, text=True).stdout
    for l in out.splitlines():
        m = re.match(r"\s+([0-9a-f]+):\s+(.*)$", l)
        if m:
            x = int(m.group(1), 16)
            print("  %s %6s %s" % (">>" if x == a else "  ", cnt.get(x, ""), m.group(2)))
