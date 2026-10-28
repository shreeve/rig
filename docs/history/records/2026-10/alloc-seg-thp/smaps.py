import os, re, subprocess, sys, time
exe, proj = sys.argv[1], sys.argv[2]
p = subprocess.Popen(["taskset", "-c", "6", exe, "-p", "tsconfig.trig.json", "--noEmit", "--checkers", "1"], cwd="/zfs/trig-pup/full/trig/misc/projects/" + proj, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
last = None; thr = 0
while p.poll() is None:
    try:
        t = open("/proc/%d/smaps" % p.pid).read(); thr = max(thr, len(os.listdir("/proc/%d/task" % p.pid)))
        last = t
    except OSError: break
    time.sleep(0.02)
cur = None; rows = []
for line in last.splitlines():
    m = re.match(r"([0-9a-f]+)-([0-9a-f]+) ", line)
    if m: cur = [int(m.group(2), 16) - int(m.group(1), 16), 0, 0, ""]; rows.append(cur); continue
    if line.startswith("Rss:"): cur[1] = int(line.split()[1])
    if line.startswith("AnonHugePages:"): cur[2] = int(line.split()[1])
    if line.startswith("VmFlags:"): cur[3] = "hg" if " hg" in line else ("nh" if " nh" in line else "")
print("threads", thr)
rows.sort(key=lambda r: -r[1])
for r in rows[:int(os.environ.get("TOP", "12"))]: print("size %8.1f MB rss %7.1f MB huge %6.1f MB %s" % (r[0] / 2**20, r[1] / 1024, r[2] / 1024, r[3]))
print("total rss %.1f MB, nh-flag rss %.1f MB, hg rss %.1f, hg huge %.1f" % (sum(r[1] for r in rows) / 1024, sum(r[1] for r in rows if r[3] == "nh") / 1024, sum(r[1] for r in rows if r[3] == "hg") / 1024, sum(r[2] for r in rows if r[3] == "hg") / 1024))
