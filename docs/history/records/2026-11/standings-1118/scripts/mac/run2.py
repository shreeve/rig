#!/usr/bin/env python3
"""run2.py ROUNDS OUT RATE label=exe ...: each server under the new bench/mixed generator
(5f8ff1dcd) at RATE, once with -pace spin and once with -pace sleep; MIX, IDLE from the
environment; 128 connections, 1 s warm-up, 5 s counted; the (arm, pace) runs rotated each
round. RIG_WORKERS / TOKIO_WORKER_THREADS pass through; SRV_GOMAXPROCS is the server's
GOMAXPROCS, GEN_GOMAXPROCS the generator's. One JSON line a run to OUT."""
import json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
LOAD = HERE + "/arms/load"
rounds, out, rate = int(sys.argv[1]), sys.argv[2], sys.argv[3]
arms = [a.split("=", 1) for a in sys.argv[4:]]
runs = [(l, e, p) for l, e in arms for p in os.environ.get("PACES", "spin,sleep").split(",")]
DUR, TB = 5, 125 / 3
def pru(pid):
    o = subprocess.run([HERE + "/pru", str(pid)], capture_output=True, text=True).stdout.split("\n")[0]
    return {k: int(v) for k, v in (kv.split("=") for kv in o.split())}
for r in range(rounds):
    k = (r * 3) % len(runs)
    order = runs[k:] + runs[:k]
    for label, exe, pace in order:
        env = dict(os.environ, RIG_HTTP_IDLE_MS="600000")
        env.pop("GOMAXPROCS", None)
        if os.environ.get("SRV_GOMAXPROCS"):
            env["GOMAXPROCS"] = os.environ["SRV_GOMAXPROCS"]
        p = subprocess.Popen([exe, "127.0.0.1:0"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, text=True)
        port = p.stdout.readline().strip()
        time.sleep(0.3)
        genv = {k2: v for k2, v in os.environ.items() if k2 != "GOMAXPROCS"}
        if os.environ.get("GEN_GOMAXPROCS"):
            genv["GOMAXPROCS"] = os.environ["GEN_GOMAXPROCS"]
        if pace.endswith("-np"):
            genv["GODEBUG"] = "asyncpreemptoff=1"
        g = subprocess.Popen([LOAD, "-addr", "127.0.0.1:" + port, "-rates", rate, "-mix", os.environ.get("MIX", "4"),
                              "-idle", os.environ.get("IDLE", "0"), "-conns", "128", "-warmup", "1s", "-duration", "%ds" % DUR,
                              "-pace", pace.split("-")[0]], stdout=subprocess.PIPE, text=True, env=genv)
        snaps, line, idle = [], None, ""
        for l in g.stdout:
            if l.strip() == "mark":
                snaps.append(pru(p.pid))
            elif l.startswith("idle"):
                idle = l.split()[1]
            elif l.strip() and l.strip() != "ready":
                line = l.split()
        g.wait(); p.kill(); p.wait()
        achieved = int(line[1]); n = achieved * DUR
        a, b = snaps[0], snaps[1]
        row = {"round": r, "arm": label, "pace": pace, "rate": int(rate), "achieved": achieved, "sent": int(line[2]),
               "unsent": int(line[3]), "errors": int(line[4]), "p50": int(line[5]), "p99": int(line[6]), "p999": int(line[7]),
               "max": int(line[8]), "triv_p99": int(line[9]), "comp_p99": int(line[10]), "timer_p99": int(line[11]),
               "load_cores": float(line[12]), "idle": idle, "t": time.strftime("%H:%M:%S")}
        for k2 in ("user_ns", "sys_ns"):
            row[k2] = (b[k2] - a[k2]) * TB / n
        for k2 in ("cycles", "instr", "csw", "int_wk"):
            row[k2] = (b[k2] - a[k2]) / n
        with open(out, "a") as f:
            f.write(json.dumps(row) + "\n")
        print("%d %-6s %-5s %6d req/s cyc %6.0f csw %.3f p50 %d p99 %d p999 %d max %d timer99 %d gen %.2f cores unsent %d err %d idle %s" % (
            r, label, pace, achieved, row["cycles"], row["csw"], row["p50"], row["p99"], row["p999"], row["max"],
            row["timer_p99"], row["load_cores"], row["unsent"], row["errors"], idle), flush=True)
        time.sleep(1)
