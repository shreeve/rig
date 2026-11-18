#!/usr/bin/env python3
"""mixprof.py OUT RATE LABEL=EXE...: each server under bench/mixed's load
(RATE a second, 5,000 idle connections, 5 s counted) with count.dylib:
system calls and context switches per request over the counted window
(snapshots at the generator's marks)."""
import os, signal, socket, subprocess, sys, time
S = os.path.dirname(os.path.abspath(__file__))
out, rate = sys.argv[1], sys.argv[2]
res = []
for arg in sys.argv[3:]:
    label, exe = arg.split("=", 1)
    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    addr = "127.0.0.1:%d" % port
    cf = "%s.%s.%s.count" % (out, label, rate)
    if os.path.exists(cf): os.remove(cf)
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=S + "/cnt/count.dylib", COUNT_OUT=cf, COUNT_SIGNAL="1", RIG_HTTP_IDLE_MS="600000")
    p = subprocess.Popen([exe, addr], stdout=subprocess.DEVNULL, env=env)
    for _ in range(500):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.1).close(); break
        except OSError: time.sleep(0.02)
    time.sleep(0.3)
    g = subprocess.Popen([S + "/mixed/load", "-addr", addr, "-rates", rate, "-conns", "128", "-duration", "5s", "-warmup", "1s", "-mix", "4", "-idle", "5000"], stdout=subprocess.PIPE, text=True)
    lines = []
    for line in g.stdout:
        if line.strip() == "mark": p.send_signal(signal.SIGUSR2)
        else: lines.append(line)
    g.wait(); time.sleep(0.3); p.kill(); p.wait()
    f = lines[0].split(); done = int(f[1]) * 5
    def parse(l): return {kv.split("=")[0]: int(kv.split("=")[1]) for kv in l.split()[1:]}
    snaps = [parse(l) for l in open(cf) if l.startswith("total:")]
    csw = [parse(l) for l in open(cf) if l.startswith("csw")]
    a, b = snaps[0], snaps[1]
    row = "%s %s req/s %s p99 %s | " % (label, rate, f[1], f[6]) + " ".join("%s=%.3f" % (k, (b.get(k, 0) - a.get(k, 0)) / done) for k in b if b.get(k, 0) != a.get(k, 0))
    row += " | csw invol/req %.3f vol/req %.3f" % ((csw[1]["involuntary"] - csw[0]["involuntary"]) / done, (csw[1]["voluntary"] - csw[0]["voluntary"]) / done)
    print(row, flush=True); res.append(row)
with open(out, "a") as fh:
    for r in res: fh.write(r + "\n")
