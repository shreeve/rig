#!/usr/bin/env python3
# peak.py BIN PROJECTDIR [ARGS...]: run BIN on core 6, read /proc/PID/smaps
# every 5 ms, keep the snapshot of largest Rss, and print each mapping of
# 1 MiB Rss or more with its AnonHugePages and flags, then the segment
# region (the mappings beside the 64 GiB reservation) summed.
import os, re, subprocess, sys, time
binp, proj = sys.argv[1], sys.argv[2]
args = sys.argv[3:] or ["-p", "tsconfig.trig.json", "--noEmit", "--checkers", "1"]
p = subprocess.Popen(["taskset", "-c", "6", binp] + args, cwd=proj, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
best, best_rss = None, 0
def parse(text):
    rows, cur = [], None
    for line in text.splitlines():
        m = re.match(r"^([0-9a-f]+)-([0-9a-f]+) (\S+) \S+ \S+ \S+\s*(.*)$", line)
        if m:
            cur = {"a": int(m[1], 16), "b": int(m[2], 16), "name": m[4], "Rss": 0, "AnonHugePages": 0, "f": ""}
            rows.append(cur); continue
        k, _, v = line.partition(":")
        if cur is None: continue
        if k in ("Rss", "AnonHugePages"): cur[k] = int(v.split()[0])
        elif k == "VmFlags": cur["f"] = v.strip()
    return rows
while p.poll() is None:
    try:
        t = open(f"/proc/{p.pid}/smaps").read()
    except Exception:
        break
    rows = parse(t)
    rss = sum(r["Rss"] for r in rows)
    if rss > best_rss: best, best_rss = rows, rss
    time.sleep(0.005)
p.wait()
print(f"peak sampled Rss {best_rss/1024:.1f} MB, AnonHugePages {sum(r['AnonHugePages'] for r in best)/1024:.1f} MB")
for r in best:
    sz = (r["b"] - r["a"]) >> 20
    if r["Rss"] >= 1024 or sz >= 1 << 14:
        print(f"{r['a']:#x} {sz:>6} MiB rss {r['Rss']/1024:7.1f} thp {r['AnonHugePages']/1024:6.1f} {r['f']} {r['name']}")
