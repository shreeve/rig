#!/usr/bin/env python3
"""http_prof.py EXE LOADER OUT: system calls per request of an HTTP server
under bench/http's load (64 connections, 3 s), by count.dylib snapshots."""
import os, signal, socket, subprocess, sys, time
exe, loader, out = sys.argv[1:4]
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
addr = "127.0.0.1:%d" % port
env = dict(os.environ, DYLD_INSERT_LIBRARIES=os.path.abspath("count.dylib"), COUNT_OUT=out, COUNT_SIGNAL="1")
if os.path.exists(out): os.remove(out)
p = subprocess.Popen([exe, addr], stdout=subprocess.DEVNULL, env=env)
for _ in range(500):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=0.1).close(); break
    except OSError: time.sleep(0.02)
time.sleep(0.3)
p.send_signal(signal.SIGUSR2); time.sleep(0.2)
o = subprocess.run([loader, "-addr", addr, "-conns", "64", "-duration", "3s"], capture_output=True, text=True).stdout
p.send_signal(signal.SIGUSR2); time.sleep(0.2)
p.kill(); p.wait()
n = int(o.split()[0])
snaps = [l for l in open(out) if l.startswith("total:")]
csw = [l for l in open(out) if l.startswith("csw")]
def parse(l): return {kv.split("=")[0]: int(kv.split("=")[1]) for kv in l.split()[1:]}
a, b = parse(snaps[0]), parse(snaps[1])
ca, cb = parse(csw[0]), parse(csw[1])
print("requests", n, "req/s", o.split()[1])
print(" ".join("%s=%.2f" % (k, (b[k] - a[k]) / n) for k in b if b[k] != a[k]))
print("csw invol/req %.2f" % ((cb["involuntary"] - ca["involuntary"]) / n))
