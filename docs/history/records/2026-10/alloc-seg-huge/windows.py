#!/usr/bin/env python3
# windows.py BIN PROJECTDIR: run BIN on core 6; at the sample of largest Rss,
# for each mapping of small pages (no AnonHugePages), count the 2 MiB-aligned
# windows wholly inside it that are wholly resident (pagemap's present bit),
# which huge pages could have held at no cost in memory.
import os, re, struct, subprocess, sys, time
binp, proj = sys.argv[1], sys.argv[2]
args = ["-p", "tsconfig.trig.json", "--noEmit", "--checkers", "1"]
p = subprocess.Popen(["taskset", "-c", "6", binp] + args, cwd=proj, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
H = 2 << 20
def maps(pid):
    rows, cur = [], None
    for line in open(f"/proc/{pid}/smaps").read().splitlines():
        m = re.match(r"^([0-9a-f]+)-([0-9a-f]+) (\S+) \S+ \S+ \S+\s*(.*)$", line)
        if m:
            cur = {"a": int(m[1], 16), "b": int(m[2], 16), "name": m[4], "Rss": 0, "AnonHugePages": 0, "f": ""}
            rows.append(cur); continue
        k, _, v = line.partition(":")
        if k in ("Rss", "AnonHugePages"): cur[k] = int(v.split()[0])
        elif k == "VmFlags": cur["f"] = v.strip()
    return rows
best = None; best_rss = 0
while p.poll() is None:
    try:
        rows = maps(p.pid)
        rss = sum(r["Rss"] for r in rows)
        if rss > best_rss:
            best_rss = rss
            out = []
            with open(f"/proc/{p.pid}/pagemap", "rb") as pm:
                for r in rows:
                    if r["name"] or r["Rss"] < 2048 or " nh" in r["f"] or " hg" in r["f"]: continue
                    a = (r["a"] + H - 1) // H * H
                    full = 0
                    while a + H <= r["b"]:
                        pm.seek(a // 4096 * 8)
                        d = pm.read(512 * 8)
                        if len(d) == 4096 and all((x >> 63) & 1 for x in struct.unpack("512Q", d)): full += 1
                        a += H
                    out.append((r["a"], (r["b"] - r["a"]) >> 10, r["Rss"], full))
            best = out
    except Exception as e:
        break
    time.sleep(0.01)
p.wait()
tot = sum(x[2] for x in best); fw = sum(x[3] for x in best)
print(f"peak Rss {best_rss/1024:.1f} MB; plain anonymous mappings of 2 MiB Rss or more: {tot/1024:.1f} MB, in {len(best)} mappings; whole resident 2 MiB windows: {fw} ({fw*2} MiB)")
for a, sz, rss, full in best: print(f"  {a:#x} {sz/1024:6.1f} MiB rss {rss/1024:6.1f} windows {full}")
