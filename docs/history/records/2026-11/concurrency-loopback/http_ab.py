#!/usr/bin/env python3
"""http_ab.py REPS OUT LOADER label=exe ...: bench/http's load run (64
connections, 3 s), interleaved and rotated; best req/s of each."""
import socket, subprocess, sys, time

reps, out, loader = int(sys.argv[1]), sys.argv[2], sys.argv[3]
vs = [a.split("=", 1) for a in sys.argv[4:]]


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start(exe):
    port = free_port()
    addr = "127.0.0.1:%d" % port
    p = subprocess.Popen([exe, addr], stdout=subprocess.DEVNULL)
    for _ in range(500):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                return p, addr
        except OSError:
            time.sleep(0.02)
    p.kill()
    sys.exit("never took connections: " + exe)


def settle():
    get = lambda k: int(subprocess.run(["sysctl", "-n", k], capture_output=True, text=True).stdout)
    room = get("net.inet.ip.portrange.last") - get("net.inet.ip.portrange.first") + 1
    while get("net.inet.tcp.pcbcount") + 2000 > room:
        time.sleep(1)


best, rows = {}, []
for r in range(reps):
    order = vs[r % len(vs):] + vs[: r % len(vs)]
    for label, exe in order:
        settle()
        p, addr = start(exe)
        try:
            time.sleep(0.3)
            o = subprocess.run([loader, "-addr", addr, "-conns", "64", "-duration", "3s"], check=True, capture_output=True, text=True, timeout=60).stdout
        finally:
            p.kill()
            p.wait()
        n, rps, p50, p99 = (int(x) for x in o.split())
        rows.append((r, label, rps, p50, p99))
        if rps > best.get(label, (0,))[0]:
            best[label] = (rps, p50, p99)
with open(out, "w") as f:
    for row in rows:
        f.write("%d %s %d %d %d\n" % row)
    f.write("# best of %d: req/s p50 p99\n" % reps)
    for label, (rps, p50, p99) in best.items():
        f.write("%-10s %8d %5d us %5d us\n" % (label, rps, p50, p99))
print(open(out).read().split("# best", 1)[1])
