#!/usr/bin/env python3
# scanwin.py STOPKB OUT CWD CORES -- CMD: run CMD (setarch -R) pinned, SIGSTOP when Rss >= STOPKB,
# write per-2MiB-window resident page counts of every anonymous VMA with Rss to OUT (addr count), then SIGCONT.
import os, signal, subprocess, sys, time
stopkb, out, cwd, cores = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
cmd = sys.argv[sys.argv.index("--") + 1:]
H = 2 << 20
p = subprocess.Popen(["setarch", "-R", "taskset", "-c", cores] + cmd, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
exe = os.path.basename(cmd[0])[:15]
def rss(pid):
    for l in open(f"/proc/{pid}/status"):
        if l.startswith("VmRSS"): return int(l.split()[1])
    return 0
done = False
while p.poll() is None and not done:
    try:
        if open(f"/proc/{p.pid}/comm").read().strip() != exe: time.sleep(0.001); continue
        r = rss(p.pid)
    except OSError: break
    if r >= stopkb:
        os.kill(p.pid, signal.SIGSTOP); time.sleep(0.02)
        fd = os.open(f"/proc/{p.pid}/pagemap", os.O_RDONLY)
        rows = []
        for l in open(f"/proc/{p.pid}/smaps"):
            pass
        vm = []
        cur = None
        for l in open(f"/proc/{p.pid}/smaps"):
            w = l.split()
            if "-" in w[0] and len(w) >= 5 and ":" not in w[0]:
                a, b = (int(x, 16) for x in w[0].split("-")); cur = [a, b, w[4], 0, 0]; vm.append(cur)
            elif w[0] == "Rss:": cur[3] = int(w[1])
            elif w[0] == "AnonHugePages:": cur[4] = int(w[1])
        with open(out, "w") as f:
            f.write(f"# rss_kb {r}\n")
            for a, b, ino, rs, ahp in vm:
                if rs == 0 or ino != "0": continue
                f.write(f"V {a:x} {b:x} {rs} {ahp}\n")
                x = a
                while x < b:
                    y = min(b, x + (32 << 30))
                    d = os.pread(fd, (y - x) // 4096 * 8, x // 4096 * 8)
                    top = d[7::8].translate(bytes(0x80) + b"\x01" * 0x80)
                    base = x // 4096
                    i = 0; n = len(top)
                    # windows aligned to 2 MiB in absolute address
                    off = (-base) % 512
                    if off and top[:off].count(1): f.write(f"W {x:x} {top[:off].count(1)}\n")
                    i = off
                    while i < n:
                        s = top[i:i + 512]
                        c = s.count(1)
                        if c: f.write(f"W {(base + i) * 4096:x} {c}\n")
                        i += 512
                    x = y
        os.close(fd)
        os.kill(p.pid, signal.SIGCONT); done = True
    time.sleep(0.002)
p.wait()
print("scanned" if done else "not reached")
