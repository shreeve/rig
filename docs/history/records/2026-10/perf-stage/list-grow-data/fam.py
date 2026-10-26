import re, sys, bisect, collections, os
OUT = "/zfs/trig-pup/trial/ab/main/out"
IDX = {}
def fn_index(path):
    starts, names = [], []
    for i, line in enumerate(open(path, errors="replace"), 1):
        m = re.search(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", line)
        if m: starts.append(i); names.append(m.group(1))
    return starts, names
def enclosing(file, line):
    if file not in IDX:
        p = None
        for cand in (OUT + "/rig/" + file, OUT + "/" + file):
            if os.path.exists(cand): p = cand; break
        IDX[file] = fn_index(p) if p else ([], [])
    s, n = IDX[file]
    k = bisect.bisect_right(s, line) - 1
    return n[k] if k >= 0 else "?"
acc = collections.Counter(); tot = 0
for line in open(sys.argv[1]):
    m = re.match(r"\s*([0-9.]+)%\s+(\S+)\s+\[(.)\]\s+(.*)$", line.rstrip())
    if not m: continue
    pct, src, kind, sym = float(m.group(1)), m.group(2), m.group(3), m.group(4).strip()
    tot += pct
    f, _, ln = src.rpartition(":")
    base = f.split("/")[-1]
    try: ln = int(ln)
    except: ln = 0
    if base == "runtime.zig":
        fn = enclosing(base, ln) if ln else "?"
        acc["runtime:" + fn + (" [in " + sym.split("(")[0].split(".")[-1] + "]" if re.match(r"^(mem|memConst|push|grow)$", fn) else "")] += pct
    elif base.startswith("memcpy") or base.startswith("memset") or sym.startswith("compiler_rt"):
        acc["crt:" + sym] += pct
