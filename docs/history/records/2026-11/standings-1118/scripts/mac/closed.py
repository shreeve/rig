#!/usr/bin/env python3
"""closed.py ROUNDS OUT label=exe ...: bench/http's closed-loop load (64 connections, 3 s) against each server
(started on a free port, waited for by connecting), arms rotated each round. One JSON line a run."""
import json, os, socket, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
LOAD = os.path.join(HERE, "arms", "http-load")
if os.path.exists(os.path.expanduser("~/Data/Code/mumps-compare/.mac-quiet")): sys.exit("closed.py: .mac-quiet exists")
rounds, out = int(sys.argv[1]), sys.argv[2]
arms = [a.split("=", 1) for a in sys.argv[3:]]
def la(): return subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()
def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0)); return s.getsockname()[1]
for r in range(rounds):
    order = arms[r % len(arms):] + arms[: r % len(arms)]
    for label, exe in order:
        port = free_port(); addr = "127.0.0.1:%d" % port
        load0 = la()
        p = subprocess.Popen([exe, addr], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(500):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1): break
            except OSError: time.sleep(0.02)
        time.sleep(0.3)
        o = subprocess.run([LOAD, "-addr", addr, "-conns", "64", "-duration", "3s"], check=True, capture_output=True, text=True).stdout
        _, _, ru = p.kill() or os.wait4(p.pid, 0)
        n, rps, p50, p99 = (int(x) for x in o.split()[-4:])
        row = {"round": r, "arm": label, "loadavg": load0, "n": n, "rps": rps, "p50": p50, "p99": p99,
               "server_user": ru.ru_utime, "server_sys": ru.ru_stime}
        with open(out, "a") as f: f.write(json.dumps(row) + "\n")
        print(r, label, rps, p50, p99, "load", load0, flush=True)
        time.sleep(0.5)
