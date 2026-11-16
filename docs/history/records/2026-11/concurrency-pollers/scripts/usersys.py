#!/usr/bin/env python3
"""usersys.py OUT RATE LABEL=EXE...: each server under bench/mixed's load
(RATE a second, 5,000 idle connections), its user and system CPU over the
5 s counted window (ps at the generator's marks), in cores."""
import os, socket, subprocess, sys, time
S = os.path.dirname(os.path.abspath(__file__))
out, rate = sys.argv[1], sys.argv[2]
def t(x):
    v = 0.0
    for part in x.replace("-", ":").split(":"): v = v * 60 + float(part)
    return v
def us(pid):
    u, s = subprocess.check_output(["ps", "-o", "utime=,stime=", "-p", str(pid)], text=True).split()
    return t(u), t(s), time.monotonic()
for arg in sys.argv[3:]:
    label, exe = arg.split("=", 1)
    sk = socket.socket(); sk.bind(("127.0.0.1", 0)); port = sk.getsockname()[1]; sk.close()
    addr = "127.0.0.1:%d" % port
    p = subprocess.Popen([exe, addr], stdout=subprocess.DEVNULL, env=dict(os.environ, RIG_HTTP_IDLE_MS="600000"))
    for _ in range(500):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.1).close(); break
        except OSError: time.sleep(0.02)
    time.sleep(0.3)
    g = subprocess.Popen([S + "/mixed/load", "-addr", addr, "-rates", rate, "-conns", "128", "-duration", "5s", "-warmup", "1s", "-mix", "4", "-idle", "5000"], stdout=subprocess.PIPE, text=True)
    marks, lines = [], []
    for line in g.stdout:
        if line.strip() == "mark": marks.append(us(p.pid))
        else: lines.append(line)
    g.wait(); p.kill(); p.wait()
    (u0, s0, t0), (u1, s1, t1) = marks[0], marks[1]
    f = lines[0].split()
    row = "%s %s req/s %s p50 %s p99 %s user %.2f sys %.2f cores" % (label, rate, f[1], f[5], f[6], (u1 - u0) / (t1 - t0), (s1 - s0) / (t1 - t0))
    print(row, flush=True)
    with open(out, "a") as fh: fh.write(row + "\n")
