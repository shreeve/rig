#!/usr/bin/env python3
"""The speed census: Rig builds against each other, interleaved, fastest of N.

usage:
  census.py build OUT NAME=TREE ...     build every bench in each tree, with
                                        that tree's bin/rig, into OUT/NAME
  census.py time OUT BENCH ROUNDS NAME ...
                                        time BENCH (json, tasks, actors, net,
                                        http) for each NAME, one run of each in
                                        turn per round; print fastest of all

json: each round runs `bench/json/bench-json --time-only --reps 3` per
tree (rig-safe, rig-fast), MB/s, the highest counts. tasks, actors, net:
each round runs each program once; ns per benchmark, the lowest counts.
http: each round runs a 3-second load of 64 connections against each
server, with one load generator (the first tree's); req/s, the highest
counts, with that run's p50 and p99. Pin by running this under taskset.

OUT is an absolute path. CENSUS_JSON_VARIANTS (rig-safe,rig-fast),
CENSUS_JSON_FILES (all six) and CENSUS_JSON_REPS (3) narrow a json run;
CENSUS_NET_PAUSE (3 s) waits before each net run, so the sockets earlier
runs left in TIME_WAIT do not use up the ports.
"""
import os, re, socket, subprocess, sys, time

CONC = ["tasks", "actors", "net", "http"]
SRC = {"tasks": "tasks.rig", "actors": "actors.rig", "net": "net.rig", "http": "server.rig"}


def build(out, specs):
    for spec in specs:
        name, tree = spec.split("=", 1)
        d = os.path.join(out, name)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "tree"), "w") as f:
            f.write(tree + "\n")
        env = dict(os.environ, RIG=os.path.join(tree, "bin", "rig"))
        subprocess.run([os.path.join(tree, "bench/json/bench-json"), "--out", os.path.join(d, "json"),
                        "--build-only", "--variants", "rig-safe,rig-fast"], check=True, cwd=tree, env=env)
        for b in CONC:
            bd = os.path.join(d, b)
            os.makedirs(bd, exist_ok=True)
            exe = os.path.join(bd, "rig-fast")
            if not os.path.exists(exe):
                e = dict(env, RIG_OUT_DIR=os.path.join(bd, "rig-out"))
                subprocess.run([env["RIG"], "build", "--release=fast", "-o", exe,
                                os.path.join(tree, "bench", b, SRC[b])], check=True, env=e)
            if b == "http" and not os.path.exists(os.path.join(bd, "load")):
                subprocess.run(["go", "build", "-o", os.path.join(bd, "load"), "."], check=True,
                               cwd=os.path.join(tree, "bench/http/load"))
        print("built", name, file=sys.stderr)


def tree_of(out, name):
    return open(os.path.join(out, name, "tree")).read().strip()


def json_round(out, name):
    tree = tree_of(out, name)
    env = dict(os.environ, RIG=os.path.join(tree, "bin", "rig"))
    p = subprocess.run([os.path.join(tree, "bench/json/bench-json"), "--out", os.path.join(out, name, "json"),
                        "--time-only", "--variants", os.environ.get("CENSUS_JSON_VARIANTS", "rig-safe,rig-fast"),
                        "--reps", os.environ.get("CENSUS_JSON_REPS", "3")]
                       + (["--files", os.environ["CENSUS_JSON_FILES"]] if "CENSUS_JSON_FILES" in os.environ else []),
                       check=True, cwd=tree, env=env, capture_output=True, text=True)
    r = {}
    cols = [v.replace("rig-", "") for v in os.environ.get("CENSUS_JSON_VARIANTS", "rig-safe,rig-fast").split(",")]
    for line in p.stdout.splitlines():
        m = re.match(r"\| (\S+) \| \d+ \| (\d+) \|(?: (\d+) \|)?", line)
        if m:
            r[m.group(1) + " " + cols[0]] = int(m.group(2))
            if m.group(3):
                r[m.group(1) + " " + cols[1]] = int(m.group(3))
    return r


def conc_round(out, name, b):
    if b == "net":
        # Each run leaves about 600 sockets in TIME_WAIT; macOS has about
        # 16,000 ports for outgoing connections and holds each 30 s.
        time.sleep(float(os.environ.get("CENSUS_NET_PAUSE", "3")))
    p = subprocess.run([os.path.join(out, name, b, "rig-fast")], check=True, capture_output=True, text=True)
    r = {}
    for line in p.stdout.splitlines():
        k, ns, _ = line.split()
        r[k] = int(ns)
    return r


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def http_round(out, name, loader):
    port = free_port()
    addr = "127.0.0.1:%d" % port
    p = subprocess.Popen([os.path.join(out, name, "http", "rig-fast"), addr], stdout=subprocess.DEVNULL)
    try:
        for _ in range(500):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.02)
        time.sleep(0.3)
        o = subprocess.run([loader, "-addr", addr, "-conns", "64", "-duration", "3s"], check=True,
                           capture_output=True, text=True).stdout
        n, rps, p50, p99 = (int(x) for x in o.split())
        return {"rps": rps, "p50": p50, "p99": p99}
    finally:
        p.kill()
        p.wait()


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    if sys.argv[1] == "build":
        return build(sys.argv[2], sys.argv[3:])
    out, bench, rounds, names = sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5:]
    best = {n: {} for n in names}
    higher = bench in ("json", "http")
    loader = os.path.join(out, names[0], "http", "load")
    for i in range(rounds):
        for n in names:
            if bench == "json":
                r = json_round(out, n)
            elif bench == "http":
                r = http_round(out, n, loader)
                if r["rps"] > best[n].get("rps", 0):
                    best[n] = r
                continue
            else:
                r = conc_round(out, n, bench)
            for k, v in r.items():
                old = best[n].get(k)
                best[n][k] = v if old is None else (max(old, v) if higher else min(old, v))
        print("round %d of %d" % (i + 1, rounds), file=sys.stderr, flush=True)
    base = names[0]
    keys = list(best[base])
    print("| %s | %s |" % (bench, " | ".join(names)) + "".join(" %s vs %s |" % (n, base) for n in names[1:]))
    print("|---|" + "---:|" * (2 * len(names) - 1))
    for k in keys:
        cells = [str(best[n][k]) for n in names]
        cmp = []
        for n in names[1:]:
            a, b = best[base][k], best[n][k]
            if k in ("p50", "p99"):
                cmp.append("")
                continue
            # Speed of n against base: >1 is faster.
            s = (b / a) if higher else (a / b)
            cmp.append("%.1f%% %s" % (abs(s - 1) * 100, "faster" if s >= 1 else "slower"))
        print("| %s | %s |" % (k, " | ".join(cells)) + "".join(" %s |" % c for c in cmp))


if __name__ == "__main__":
    main()
