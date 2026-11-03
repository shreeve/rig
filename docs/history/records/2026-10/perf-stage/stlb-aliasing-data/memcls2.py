#!/usr/bin/env python3
# memcls.py KIND DATA...: classify sampled loads (perf mem, -d --data-page-size) by mapping and TLB result.
import re, subprocess, sys, collections
kind = sys.argv[1]
tot = collections.Counter(); walk = collections.Counter(); wlat = collections.Counter()
for f in sys.argv[2:]:
    out = subprocess.run(["perf", "script", "-i", f, "--show-mmap-events", "-F", "pid,addr,data_src,data_page_size,weight"], capture_output=True, text=True).stdout
    maps = []  # (a, b, cls)
    for l in out.splitlines():
        m = re.search(r"PERF_RECORD_MMAP2? \d+/\d+: \[(0x[0-9a-f]+)\((0x[0-9a-f]+)\) @ \S+(?: [^\]]*)?\]: (\S+) (.*)$", l)
        if m:
            a, ln, prot, name = int(m[1], 16), int(m[2], 16), m[3], m[4].strip()
            if name.startswith("//anon") or name == "":
                if kind == "trig":
                    if ln == (64 << 30) + (4 << 20): c = "segments"
                    elif ln == (256 << 30) + (2 << 20): c = "tables"
                    elif prot.startswith("rw") and ln in (0x4000000, 0x1001000, 0x1000000): c = f"stack{ln>>20}M"
                    elif ln > (16 << 20): c = f"anon{ln>>20}M"
                    else: c = "large"
                else:
                    if a == 0x400100000000: c = "arena"
                    elif ln >= (1 << 30): c = "mimalloc"
                    elif prot.startswith("rw") and ln >= (1 << 20) and ln < (64 << 20) and ln % (1<<20) in (0, 4096): c = f"stack?{ln>>20}M"
                    else: c = "anon-other"
            elif "[stack]" in name: c = "stack"
            elif "[heap]" in name: c = "brk"
            elif name.startswith("/tmp/hp") or name.startswith("/zfs"): c = "binary"
            else: c = "lib/other"
            maps.append((a, a + ln, c)); continue
        if "|OP" not in l: continue
        parts = l.split("|")
        head = parts[0].split(); tail = parts[-1].split()
        addr = int(head[1], 16); ds = "|".join(parts[1:-1]); ps = tail[-1]; wt = int(tail[-2])
        c = "unmapped"
        for a, b, cc in reversed(maps):
            if a <= addr < b: c = cc; break
        if addr >= 0xffff800000000000: c = "kernel"
        key = (c, ps, "p0" if ((addr >> 12) & 511) == 0 else "p>0")
        tot[key] += 1
        if True:
            walk[key] += 1; wlat[key] += wt
T = sum(tot.values()); W = sum(walk.values())
print(f"samples {T}, STLB-miss samples {W} ({100*W/max(T,1):.1f}%)")
print(f"{'class':12} {'page':>6} {'loads %':>8} {'STLB-miss %':>12} {'miss lat %':>10}")
WL = sum(wlat.values())
for k in sorted(tot, key=lambda k: -walk[k]):
    if tot[k] < T * 0.002 and walk[k] == 0: continue
    print(f"{k[0]:12} {k[1]:>6} {k[2]:>4} {100*tot[k]/T:8.1f} {100*walk[k]/max(W,1):12.1f} {100*wlat[k]/max(WL,1):10.1f}")
