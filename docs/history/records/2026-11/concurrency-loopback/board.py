#!/usr/bin/env python3
"""Interleaved board: board.py REPS OUT 'label=cmd args' ... ; each command
prints `NAME NS CHECK` lines; keeps the fastest of each (label, name) and
writes every run to OUT. Rotates the order each round."""
import subprocess, sys, time, json, os

reps = int(sys.argv[1])
out = sys.argv[2]
vs = [a.split("=", 1) for a in sys.argv[3:]]
CALLS = {"pingpong": 20000, "echo": 100000, "connect": 500}


def ports():
    """Local ports for outgoing connections, and TCP sockets held now
    (bench/net/bench-net's count), on macOS or Linux."""
    if sys.platform == "darwin":
        get = lambda k: int(subprocess.run(["sysctl", "-n", k], capture_output=True, text=True).stdout)
        return get("net.inet.ip.portrange.last") - get("net.inet.ip.portrange.first") + 1, get("net.inet.tcp.pcbcount")
    with open("/proc/sys/net/ipv4/ip_local_port_range") as f:
        lo, hi = map(int, f.read().split())
    with open("/proc/net/sockstat") as f:
        tcp = next(l.split() for l in f if l.startswith("TCP:"))
    return hi - lo + 1, int(tcp[tcp.index("inuse") + 1]) + int(tcp[tcp.index("tw") + 1])


def settle():
    while (p := ports())[1] + 2000 > p[0]:
        time.sleep(1)


best = {}
runs = []
for r in range(reps):
    order = vs[r % len(vs):] + vs[: r % len(vs)]
    for label, cmd in order:
        settle()
        env = dict(os.environ)
        p = subprocess.run(cmd.split(), capture_output=True, text=True, env=env, timeout=120)
        for line in p.stdout.splitlines():
            name, ns, check = line.split()
            ns = int(ns)
            runs.append((r, label, name, ns))
            k = (label, name)
            best[k] = min(ns, best.get(k, ns))
with open(out, "w") as f:
    for row in runs:
        f.write("%d %s %s %d\n" % row)
    f.write("# fastest of %d\n" % reps)
    for (label, name), ns in sorted(best.items(), key=lambda x: (x[0][1], x[0][0])):
        f.write("%-12s %-9s %8.2f us\n" % (label, name, ns / CALLS.get(name, 1) / 1e3))
print(open(out).read().split("# fastest", 1)[1])
