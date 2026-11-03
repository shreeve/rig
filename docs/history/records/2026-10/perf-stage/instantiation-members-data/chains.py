# chains.py DATA BIN OUT: each sample as its frames, each frame its inline
# chain of source functions (innermost first), from perf script + nm + addr2line
import sys, subprocess, re, collections, json
data, binp, out = sys.argv[1:4]
syms = {}
for l in subprocess.run(["nm", "--defined-only", binp], capture_output=True, text=True).stdout.splitlines():
    p = l.split(" ", 2)
    if len(p) == 3 and p[1] in "tTwW": syms.setdefault(p[2], int(p[0], 16))
ps = subprocess.run(["perf", "script", "-i", data, "-F", "period,ip,sym,symoff", "--no-inline", "--no-demangle"], capture_output=True, text=True).stdout
samples = []; cur = None
fr = re.compile(r"^\s+([0-9a-f]+)\s+(.+)\+0x([0-9a-f]+)\s*$")
for l in ps.splitlines():
    if not l.strip():
        cur = None; continue
    if not l.startswith("\t") and not l.startswith(" " * 8):
        m = re.match(r"\s*(\d+)", l)
        cur = [int(m.group(1)), []] if m else None
        if cur: samples.append(cur)
        continue
    m = fr.match(l)
    if cur is not None:
        if m and m.group(2) in syms: cur[1].append(syms[m.group(2)] + int(m.group(3), 16))
        else: cur[1].append(None)
addrs = set()
for _, fs in samples:
    for i, a in enumerate(fs):
        if a is not None: addrs.add(a if i == 0 else a - 1)
addrs = sorted(addrs)
def crate(f):
    m = re.search(r"/crates/(tsrs_\w+)/", f)
    if m: return m.group(1)
    if re.search(r"/library/(core|alloc|std)/|hashbrown|indexmap|rustc.hash|memchr|mimalloc|/lib/std/|/rig/(runtime|ordered|unordered|alloc|sched|table)\.zig|compiler_rt", f): return "lib"
    m = re.search(r"/out/(\w+)\.zig", f)
    return m.group(1) if m else "?"

r = subprocess.run(["addr2line", "-e", binp, "-i", "-f", "-C", "-a"], input="\n".join("%x" % a for a in addrs) + "\n", capture_output=True, text=True).stdout.splitlines()
chain = {}; a = None; i = 0
while i < len(r):
    if r[i].startswith("0x"): a = int(r[i], 16); chain[a] = []; i += 1; continue
    chain[a].append([r[i], crate(r[i+1] if i+1 < len(r) else "")]); i += 2
res = []
for p, fs in samples:
    res.append([p, [chain.get(x if k == 0 else x - 1, [["?","?"]]) if x is not None else [["?","?"]] for k, x in enumerate(fs)]])
json.dump(res, open(out, "w"))
print(out, len(samples), "samples", len(addrs), "addresses")
