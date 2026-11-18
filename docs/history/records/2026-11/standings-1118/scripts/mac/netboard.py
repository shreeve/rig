#!/usr/bin/env python3
"""bb/netboard.py REPS OUT label=cmd[;ENV=V...] ...: interleaved, rotated board of
programs that print `NAME NS CHECK` lines. Every run is written to OUT as JSON
lines with the child's rusage (user, system seconds, voluntary and involuntary
context switches), stderr kept (RIG_SCHED_STATS, count.dylib)."""
import subprocess, sys, time, json, os, statistics
reps = int(sys.argv[1]); out = sys.argv[2]
arms = []
for a in sys.argv[3:]:
    label, rest = a.split("=", 1)
    parts = rest.split(";")
    env = dict(p.split("=", 1) for p in parts[1:])
    arms.append((label, parts[0].split(), env))
def get(k): return int(subprocess.run(["sysctl", "-n", k], capture_output=True, text=True).stdout)
def settle():
    room = get("net.inet.ip.portrange.last") - get("net.inet.ip.portrange.first") + 1
    while get("net.inet.tcp.pcbcount") + 2500 > room: time.sleep(1)
def state():
    return subprocess.run([os.path.join(os.path.dirname(os.path.abspath(__file__)), "state.sh")], capture_output=True, text=True).stdout
rows = []
f = open(out, "a")
f.write(json.dumps({"state": state(), "at": time.strftime("%F %T"), "arms": sys.argv[3:]}) + "\n")
for r in range(reps):
    order = arms[r % len(arms):] + arms[: r % len(arms)]
    for label, cmd, env in order:
        settle()
        e = dict(os.environ); e.update(env)
        t0 = time.monotonic()
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
        so, se = p.stdout.read().decode(), p.stderr.read().decode()
        _, status, ru = os.wait4(p.pid, 0)
        p.returncode = status
        wall = time.monotonic() - t0
        row = {"round": r, "arm": label, "wall": wall, "user": ru.ru_utime, "sys": ru.ru_stime, "vcsw": ru.ru_nvcsw, "ivcsw": ru.ru_nivcsw, "status": status, "stderr": se}
        for line in so.splitlines():
            name, ns, check = line.split()[:3]
            row.setdefault("ns", {}).setdefault(name, []).append(int(ns))
        rows.append(row); f.write(json.dumps(row) + "\n"); f.flush()
f.write(json.dumps({"state": state(), "at": time.strftime("%F %T"), "end": True}) + "\n")
f.close()
