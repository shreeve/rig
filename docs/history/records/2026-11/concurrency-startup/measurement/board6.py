#!/usr/bin/env python3
"""board6.py SET ROUNDS OUT: the built fix (worker 1 maps each worker's
first stacks, then starts the others) against main, with an A/A arm (a
copy of main's binary), each run a fresh process, arms rotated each round.
Prints each row's fastest and median, and each arm's median against main's.

SET is startup (startup.rig by mode, and Rayon), tasks (bench/tasks: every
row and memory), spawn (bench/tasks's spawn row alone, which is bimodal on
the Mac, so for many rounds), actors (bench/actors) or net (bench/net). The binaries
are read from BIN (default prog/): startup-{main,aa,tree}, rayon,
tasks-{main,aa,tree}, actors-{...}, net-{...}."""
import subprocess, sys, os, statistics, json, time

S = os.path.dirname(os.path.abspath(__file__))
B = os.environ.get("BIN", S + "/prog")
RIGS = ["main", "aa", "tree"]
MANY = 10000


def startup_arms():
    arms = {}
    for r in RIGS:
        for mode in ["cold", "pre", "gap"]:
            arms["%s-%s" % (r, mode)] = ("startup-" + r, [], {"STARTUP_MODE": mode})
        for mode in ["cold", "pre"]:
            arms["%s1-%s" % (r, mode)] = ("startup-" + r, [], {"STARTUP_MODE": mode, "RIG_WORKERS": "1"})
    for mode in ["cold", "pre", "gap"]:
        arms["rayon-" + mode] = ("rayon", [], {"STARTUP_MODE": mode})
    arms["rayon1-cold"] = ("rayon", [], {"STARTUP_MODE": "cold", "RAYON_NUM_THREADS": "1"})
    return arms


def bench_arms(name):
    return {r: ("%s-%s" % (name, r), [], {}) for r in RIGS}


def ports():
    """Local ports outgoing connections may use, and TCP sockets held now."""
    if sys.platform == "darwin":
        get = lambda k: int(subprocess.run(["sysctl", "-n", k], capture_output=True, text=True).stdout)
        return get("net.inet.ip.portrange.last") - get("net.inet.ip.portrange.first") + 1, get("net.inet.tcp.pcbcount")
    with open("/proc/sys/net/ipv4/ip_local_port_range") as f:
        lo, hi = map(int, f.read().split())
    with open("/proc/net/sockstat") as f:
        tcp = next(l.split() for l in f if l.startswith("TCP:"))
    return hi - lo + 1, int(tcp[tcp.index("inuse") + 1]) + int(tcp[tcp.index("tw") + 1])


def ports_settle():
    while (p := ports()) and p[1] + 2000 > p[0]:
        time.sleep(1)


def peak(exe, mode):
    """Peak resident bytes of `exe mode`: the child's ru_maxrss on macOS,
    its own VmHWM on Linux (ru_maxrss there counts the fork's copy)."""
    p = subprocess.Popen([exe, mode], stdout=subprocess.PIPE, text=True)
    hwm = 0
    if sys.platform != "darwin":
        while p.poll() is None:
            try:
                with open("/proc/%d/status" % p.pid) as f:
                    for line in f:
                        if line.startswith("VmHWM:"):
                            hwm = max(hwm, int(line.split()[1]) * 1024)
            except (OSError, ValueError):
                pass
            time.sleep(0.005)
        p.stdout.read()
        assert p.returncode == 0
        return hwm
    p.stdout.read()
    _, status, usage = os.wait4(p.pid, 0)
    assert os.waitstatus_to_exitcode(status) == 0
    return usage.ru_maxrss


def run(set_, exe, args, env):
    if set_ == "net":
        ports_settle()
    o = subprocess.run([os.path.join(B, exe)] + args, capture_output=True, text=True, timeout=600, check=True, env={**os.environ, **env}).stdout
    rows = {}
    for line in o.splitlines():
        name, ns, chk = line.split()
        rows[name] = int(ns) / 1e6
    if set_ == "spawn":
        rows = {"spawn": rows["spawn"]}
    if set_ == "tasks":
        exe = os.path.join(B, exe)
        rows["memory"] = max(1, peak(exe, "many") - peak(exe, "idle")) / MANY / 1e6
    return rows


set_, rounds, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
arms = startup_arms() if set_ == "startup" else bench_arms("tasks" if set_ == "spawn" else set_)
names = list(arms)
data = {}
for k in range(rounds):
    turn = names[k % len(names):] + names[:k % len(names)]
    for n in turn:
        for row, v in run(set_, *arms[n]).items():
            data.setdefault((n, row), []).append(v)
if rounds:
    json.dump({"%s|%s" % k: v for k, v in data.items()}, open(out, "w"))
else:
    # ROUNDS 0: report what OUT holds.
    data = {tuple(k.split("|")): v for k, v in json.load(open(out)).items()}
    rounds = max(len(v) for v in data.values())
# Rows that time something (not a mode's marker row, as `pre`).
data = {k: v for k, v in data.items() if max(v) > 0}
rows = sorted({r for (_, r) in data}, key=lambda r: [x for (_, x) in data].index(r))
unit = "B/task" if set_ == "tasks" else "ms"
print("rounds %d; fastest / median, ms (memory: bytes a live task)" % rounds)
print("%-14s" % "arm" + "".join("%22s" % r for r in rows))
for n in names:
    if not any((n, r) in data for r in rows):
        continue
    cells = []
    for r in rows:
        v = data.get((n, r))
        if not v:
            cells.append("%22s" % "-")
        elif r == "memory":
            cells.append("%22s" % ("%.0f / %.0f" % (min(v) * 1e6, statistics.median(v) * 1e6)))
        else:
            cells.append("%22s" % ("%.3f / %.3f" % (min(v), statistics.median(v))))
    print("%-14s" % n + "".join(cells))


def against(a, b):
    """a's median against b's: N% faster or slower."""
    x, y = statistics.median(a), statistics.median(b)
    d = (y - x) / y * 100
    return "%.1f%% %s" % (abs(d), "faster" if d >= 0 else "slower")


print("\nmedians against main's")
pairs = []
for n in names:
    for base in RIGS[1:]:
        if n.startswith(base):
            pairs.append((n, "main" + n[len(base):]))
for n, m in pairs:
    print("%-14s" % (n + ":") + "".join("%22s" % (against(data[n, r], data[m, r]) if (n, r) in data and (m, r) in data else "-") for r in rows))
