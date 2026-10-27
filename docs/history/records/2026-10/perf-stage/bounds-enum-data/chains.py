# chains.py BIN OFFS PATTERN DEPTH [SKIP]: samples whose innermost line matches PATTERN, grouped by inline chain.
import re, sys, subprocess, collections, os
binp, offs, pat, depth = sys.argv[1], sys.argv[2], re.compile(sys.argv[3]), int(sys.argv[4])
skip = re.compile(sys.argv[5]) if len(sys.argv) > 5 else None
syms = {}
for line in subprocess.run(["nm", "-C", "--defined-only", binp], capture_output=True, text=True).stdout.splitlines():
    m = re.match(r"([0-9a-f]+) [tTwW] (.*)$", line)
    if m: syms.setdefault(m.group(2), int(m.group(1), 16))
cnt = collections.Counter()
for line in open(offs):
    m = re.match(r"\s*(\d+)\s+(.*)\+0x([0-9a-f]+)\s*$", line)
    if not m or m.group(2) not in syms: continue
    cnt[syms[m.group(2)] + int(m.group(3), 16)] += int(m.group(1))
addrs = sorted(cnt)
out = subprocess.run(["addr2line", "-i", "-a", "-e", binp], input="\n".join("%x" % a for a in addrs) + "\n", capture_output=True, text=True).stdout.splitlines()
chains = {}; cur = None
for l in out:
    if l.startswith("0x"): cur = int(l, 16); chains[cur] = []
    else: chains[cur].append(os.path.basename(l.split()[0]))
g = collections.Counter(); tot = 0; allt = sum(cnt.values())
for a in addrs:
    ch = chains.get(a, [])
    if not ch or not pat.search(ch[0]): continue
    rest = [x for x in ch[1:] if not (skip and skip.search(x))]
    key = ch[0] + " | " + " <- ".join(rest[:depth])
    g[key] += cnt[a]; tot += cnt[a]
print("matched %d of %d samples (%.2f%%)" % (tot, allt, 100.0*tot/allt))
for k, n in g.most_common(40): print("%5d %5.1f%%  %s" % (n, 100.0*n/tot, k))
