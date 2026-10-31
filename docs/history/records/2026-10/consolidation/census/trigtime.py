#!/usr/bin/env python3
"""Trig timing for the census: two trig builds on Trig's projects, and
`rig check --time` of Trig with two compilers, interleaved, fastest of N.

usage:
  trigtime.py run ROUNDS PROJECTS_DIR NAME=TRIG ...      trig -p tsconfig.trig.json --noEmit
  trigtime.py check ROUNDS TRIG_SRC NAME=RIG ...         rig check --time TRIG_SRC/main.rig

Prefix with taskset to pin. On macOS each run also reports the instructions
retired and cycles of its fastest run, from /usr/bin/time -l.
"""
import os, re, subprocess, sys, tempfile, time

PROJECTS = os.environ.get("TRIG_PROJECTS", "ts-pattern,zod3").split(",")
MAC = sys.platform == "darwin"


def timed(cmd, cwd, env=None):
    if MAC:
        cmd = ["/usr/bin/time", "-l"] + cmd
    t = time.perf_counter()
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)
    wall = time.perf_counter() - t
    ins = cyc = 0
    if MAC:
        m = re.search(r"(\d+)\s+instructions retired", p.stderr)
        ins = int(m.group(1)) if m else 0
        m = re.search(r"(\d+)\s+cycles elapsed", p.stderr)
        cyc = int(m.group(1)) if m else 0
    return wall, ins, cyc, p


def pct(a, b, higher=False):
    s = (b / a) if higher else (a / b)
    return "%.1f%% %s" % (abs(s - 1) * 100, "faster" if s >= 1 else "slower")


def run(rounds, pdir, specs):
    names = [s.split("=", 1)[0] for s in specs]
    exe = dict(s.split("=", 1) for s in specs)
    best = {}
    out = {}
    for proj in PROJECTS:
        d = os.path.join(pdir, proj)
        for n in names:
            _, _, _, p = timed([exe[n], "-p", "tsconfig.trig.json", "--noEmit"], d)
            out[(proj, n)] = (p.returncode, p.stdout)
        first = out[(proj, names[0])]
        for n in names[1:]:
            if out[(proj, n)] != first:
                sys.exit("trigtime: %s prints differently under %s" % (proj, n))
    # Each round starts with the next build: the first run after a switch
    # meets a core that idled, at a lower clock (3.8 GHz against 4.4 on pup).
    for r in range(rounds):
        for proj in PROJECTS:
            d = os.path.join(pdir, proj)
            for n in names[r % len(names):] + names[:r % len(names)]:
                w, i, c, _ = timed([exe[n], "-p", "tsconfig.trig.json", "--noEmit"], d)
                k = (proj, n)
                if k not in best or w < best[k][0]:
                    best[k] = (w, i, c)
        print("round %d of %d" % (r + 1, rounds), file=sys.stderr, flush=True)
    print("| project | " + " | ".join(names) + " | %s vs %s |" % (names[-1], names[0]) + (" instructions | cycles |" if MAC else ""))
    print("|---|" + "---:|" * (len(names) + 1) + ("---:|---:|" if MAC else ""))
    for proj in PROJECTS:
        a, b = best[(proj, names[0])], best[(proj, names[-1])]
        cells = ["%.3f s" % best[(proj, n)][0] for n in names]
        extra = ""
        if MAC:
            extra = " %s → %s (%s) | %s → %s |" % (fmt(a[1]), fmt(b[1]), pct(a[1], b[1]).replace("faster", "fewer").replace("slower", "more"),
                                                 fmt(a[2]), fmt(b[2]))
        print("| %s | %s | %s |%s" % (proj, " | ".join(cells), pct(a[0], b[0]), extra))


def fmt(n):
    return "%.2fG" % (n / 1e9)


def check(rounds, src, specs):
    names = [s.split("=", 1)[0] for s in specs]
    rig = dict(s.split("=", 1) for s in specs)
    best = {}
    tmp = tempfile.mkdtemp(prefix="trigtime-")
    for r in range(rounds):
        for n in names[r % len(names):] + names[:r % len(names)]:
            env = dict(os.environ, RIG_OUT_DIR=os.path.join(tmp, n))
            p = subprocess.run([rig[n], "check", "--time", "main.rig"], cwd=src, capture_output=True, text=True, env=env)
            if p.returncode != 0:
                sys.exit("trigtime: %s check failed: %s" % (n, p.stderr[-500:]))
            for line in (p.stdout + p.stderr).splitlines():
                m = re.match(r"(\S.*?)\s+([\d.]+) ms$", line)
                if m:
                    k = (m.group(1), n)
                    best[k] = min(best.get(k, 1e18), float(m.group(2)))
        print("round %d of %d" % (r + 1, rounds), file=sys.stderr, flush=True)
    passes = []
    for (p, n) in best:
        if p not in passes:
            passes.append(p)
    print("| pass | " + " | ".join(names) + " | %s vs %s |" % (names[-1], names[0]))
    print("|---|" + "---:|" * (len(names) + 1))
    for p in passes:
        cells = ["%.0f ms" % best[(p, n)] for n in names]
        print("| %s | %s | %s |" % (p, " | ".join(cells), pct(best[(p, names[0])], best[(p, names[-1])])))


if __name__ == "__main__":
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    (run if sys.argv[1] == "run" else check)(int(sys.argv[2]), sys.argv[3], sys.argv[4:])
