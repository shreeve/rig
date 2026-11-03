#!/usr/bin/env python3
# hps.py KIND STOPKB CWD CORES -- CMD...
# KIND: trig or tsrs (how mappings are classed). Runs CMD under strace (memory
# syscalls only, seccomp-bpf) pinned to CORES, samples /proc/PID/smaps every
# few ms. If STOPKB > 0, the first time Rss reaches STOPKB it SIGSTOPs the
# process, scans /proc/PID/pagemap of each anonymous mapping with Rss for
# resident pages, touched 2 MiB windows and fully resident windows, then
# SIGCONTs it. Prints: peak Rss sample by class; max AnonHugePages; the scan.
import os, re, signal, subprocess, sys, time
kind, stopkb, cwd, cores = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
cmd = sys.argv[sys.argv.index("--") + 1:]
H = 2 << 20
tr = f"/tmp/hp/st.{os.getpid()}.txt"

def vmstat():
    d = {}
    for l in open("/proc/vmstat"):
        k, v = l.split()
        if k.startswith(("thp_fault", "compact_stall", "compact_fail", "compact_success", "thp_collapse")): d[k] = int(v)
    return d

def free_huge():
    n = 0
    for l in open("/proc/buddyinfo"):
        w = l.split()
        if w[3] == "DMA": continue
        c = list(map(int, w[4:]))
        n += sum(c[o] << (o - 9) for o in range(9, len(c)))
    return n

def smaps(pid):
    rows, cur = [], None
    with open(f"/proc/{pid}/smaps") as f:
        txt = f.read()
    for line in txt.splitlines():
        m = re.match(r"^([0-9a-f]+)-([0-9a-f]+) (\S+) \S+ \S+ (\S+)\s*(.*)$", line)
        if m:
            cur = {"a": int(m[1], 16), "b": int(m[2], 16), "perm": m[3], "inode": m[4], "name": m[5], "Rss": 0, "AnonHugePages": 0, "f": "", "THPeligible": 0}
            rows.append(cur); continue
        k, _, v = line.partition(":")
        if k in ("Rss", "AnonHugePages", "THPeligible"): cur[k] = int(v.split()[0])
        elif k == "VmFlags": cur["f"] = " " + v.strip() + " "
    return rows

def scan(pid, rows):
    out = []
    fd = os.open(f"/proc/{pid}/pagemap", os.O_RDONLY)
    zero512 = bytes(512)
    for r in rows:
        if r["Rss"] == 0 or r["inode"] != "0" or r["name"].startswith("[v"): continue
        a, b = r["a"], r["b"]
        res = touched = full = 0
        step = 32 << 30
        x = a
        while x < b:
            y = min(b, x + step)
            d = os.pread(fd, (y - x) // 4096 * 8, x // 4096 * 8)
            top = d[7::8].translate(bytes(0x80) + b"\x01" * 0x80)  # 1 if present
            res += top.count(1)
            # windows: aligned 2 MiB windows wholly in [a,b)
            w0 = (max(x, (a + H - 1) // H * H) - x) // 4096
            wend = (min(y, b // H * H) - x) // 4096
            i = w0
            while i + 512 <= wend:
                s = top[i:i + 512]
                if s != zero512:
                    touched += 1
                    if s.count(1) == 512: full += 1
                i += 512
            x = y
        r.update(res=res, touched=touched, full=full)
        out.append(r)
    os.close(fd)
    return out

# classes from the strace log: list of (a, b, cls), latest wins
def trace_classes():
    ev = []
    for l in open(tr):
        m = re.search(r"mmap\((\S+), (\d+), (\S+), (\S+), -1, 0\) = (0x[0-9a-f]+)", l)
        if m:
            ln, prot, fl, at = int(m[2]), m[3], m[4], int(m[5], 16)
            nr = "NORESERVE" in fl
            if kind == "trig":
                if ln == (64 << 30) + (4 << 20): c = "segments"
                elif ln == (256 << 30) + (2 << 20): c = "tables"
                elif nr and prot == "PROT_READ|PROT_WRITE" and ln > (8 << 20): c = "tables"
                elif prot == "PROT_NONE": c = "stacks"
                elif nr: c = "other-nr"
                else: c = "large"
            else:
                if at == 0x400100000000 or ln == (1 << 35): c = "arena"
                elif ln >= (1 << 30): c = "mimalloc"
                elif prot == "PROT_NONE" and ln >= (1 << 30): c = "mimalloc"
                elif prot == "PROT_NONE": c = "stacks"
                else: c = "mmap-other"
            ev.append((at, at + ln, c)); continue
        m = re.search(r"mremap\((0x[0-9a-f]+), (\d+), (\d+), \S+.*\) = (0x[0-9a-f]+)", l)
        if m:
            at, ln = int(m[4], 16), int(m[3])
            ev.append((at, at + ln, "large" if kind == "trig" else "mmap-other"))
    return ev

def classify(r, ev):
    if r["inode"] != "0": return "file"
    if r["name"] == "[heap]": return "brk"
    if r["name"] == "[stack]": return "stacks"
    if r["name"].startswith("["): return "other"
    for a, b, c in reversed(ev):
        if a <= r["a"] < b: return c
    return "unknown"

vm0, fh0 = vmstat(), free_huge()
p = subprocess.Popen(["strace", "-f", "--seccomp-bpf", "-e", "trace=mmap,munmap,mremap,madvise", "-o", tr, "--", "taskset", "-c", cores] + cmd,
                     cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
pid = None
exe = os.path.basename(cmd[0])
while pid is None and p.poll() is None:
    try:
        for ch in open(f"/proc/{p.pid}/task/{p.pid}/children").read().split():
            if open(f"/proc/{ch}/comm").read().strip() == exe[:15]: pid = int(ch)
    except OSError: pass
best = None; best_rss = 0; max_ahp = 0; ahp_at_peak = 0; stopped = None; tl = []
t0 = time.time()
while p.poll() is None:
    try:
        rows = smaps(pid)
    except Exception as e:
        print('# sample error', repr(e)); break
    rss = sum(r["Rss"] for r in rows); ahp = sum(r["AnonHugePages"] for r in rows)
    tl.append((time.time() - t0, rss, ahp))
    if rss > best_rss: best_rss, best = rss, rows
    max_ahp = max(max_ahp, ahp)
    if stopkb and stopped is None and rss >= stopkb:
        os.kill(pid, signal.SIGSTOP); time.sleep(0.02)
        try:
            rows2 = smaps(pid); stopped = (rss, scan(pid, rows2))
        finally:
            os.kill(pid, signal.SIGCONT)
    time.sleep(0.003)
p.wait()
vm1, fh1 = vmstat(), free_huge()
ev = trace_classes()
madv = open(tr).read()
print(f"# kind={kind} cores={cores} cmd={' '.join(cmd)}")
print(f"# free 2MiB blocks before {fh0} after {fh1}; samples {len(tl)}; vmstat delta " + " ".join(f"{k}={vm1[k]-vm0[k]}" for k in sorted(vm1) if vm1[k] != vm0[k]))
print(f"# madvise HUGEPAGE calls {madv.count('MADV_HUGEPAGE')}, NOHUGEPAGE {madv.count('MADV_NOHUGEPAGE')}, POPULATE_WRITE {madv.count('MADV_POPULATE_WRITE')}, COLLAPSE {madv.count('MADV_COLLAPSE')}")
print(f"peak Rss {best_rss/1024:.1f} MiB; max AnonHugePages seen {max_ahp/1024:.1f} MiB")
agg = {}
for r in best:
    c = classify(r, ev)
    g = agg.setdefault(c, [0, 0, 0, 0, 0])
    g[0] += r["Rss"]; g[1] += r["AnonHugePages"]
    if " hg " in r["f"]: g[2] += r["Rss"]
    if " nh " in r["f"]: g[3] += r["Rss"]
    if r["THPeligible"]: g[4] += r["Rss"]
print(f"{'class':10} {'Rss MiB':>8} {'AnonHuge':>9} {'in hg':>8} {'in nh':>8} {'eligible':>9}")
for c, g in sorted(agg.items(), key=lambda x: -x[1][0]):
    if g[0] < 256: continue
    print(f"{c:10} {g[0]/1024:8.1f} {g[1]/1024:9.1f} {g[2]/1024:8.1f} {g[3]/1024:8.1f} {g[4]/1024:9.1f}")
if stopped:
    rss, out = stopped
    print(f"scan at Rss {rss/1024:.1f} MiB (stopped): per class resident MiB, 2MiB windows touched / full, AnonHuge MiB")
    sc = {}
    for r in out:
        c = classify(r, ev)
        g = sc.setdefault(c, [0, 0, 0, 0, 0, 0])
        g[0] += r["res"]; g[1] += r["touched"]; g[2] += r["full"]; g[3] += r["AnonHugePages"]
        g[4] += 1 if r["res"] else 0
        if r["res"] * 4096 < H: g[5] += r["res"]
    print(f"{'class':10} {'res MiB':>8} {'touched':>8} {'full':>6} {'AHP MiB':>8} {'vmas':>5} {'in <2MiB vmas':>13}")
    for c, g in sorted(sc.items(), key=lambda x: -x[1][0]):
        if g[0] < 64: continue
        print(f"{c:10} {g[0]*4/1024:8.1f} {g[1]:8} {g[2]:6} {g[3]/1024:8.1f} {g[4]:5} {g[5]*4/1024:13.1f}")
    if os.environ.get("HPS_VMAS"):
        for r in sorted(out, key=lambda r: -r["res"])[:40]:
            print(f"  {r['a']:#x} {(r['b']-r['a'])>>20:8} MiB {classify(r, ev):9} res {r['res']*4/1024:6.1f} MiB touched {r['touched']:4} full {r['full']:4} ahp {r['AnonHugePages']/1024:5.1f} flags{r['f'].rstrip()}")
step = max(1, len(tl) // 12)
print("timeline s/RssMiB/AHPMiB: " + " ".join(f"{t:.2f}/{r/1024:.0f}/{a/1024:.0f}" for t, r, a in tl[::step]))
os.unlink(tr)
