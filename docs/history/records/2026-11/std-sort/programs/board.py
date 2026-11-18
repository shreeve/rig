#!/usr/bin/env python3
"""Interleaved board for std.sort: each outer round runs every arm on
every row in a fresh shuffled order; a row's figure is the fastest of
all rounds (ns per element). board.py BOARD OUTER INNER OUT.tsv
BOARD: unstable | stable-small | stable-large
"""
import random, subprocess, sys, os, time

H = os.path.dirname(os.path.abspath(__file__))
board, outer, inner, out = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
PATTERNS = ["rand", "sorted", "rev", "dups"]


def rig(arm):
    return lambda kind, pat, n: [f"{H}/rsort-{arm}", kind, pat, str(n), inner]


def zig(mode, algo, kindmap=None):
    def f(kind, pat, n):
        k = (kindmap or {}).get(kind, kind)
        return [f"{H}/zsort-{mode}", k, pat, str(n), inner, algo]
    return f


def rust(algo, kindmap=None):
    def f(kind, pat, n):
        k = (kindmap or {}).get(kind, kind)
        return [f"{H}/rust/target/release/rsortbench", k, pat, str(n), inner, algo]
    return f


if board == "unstable":
    sizes = [16, 256, 4096, 65536, 1 << 20, 1 << 22]
    kinds = ["int", "str", "obj"]
    arms = {"old": rig("old"), "new": rig("new"), "zig-pdq-safe": zig("safe", "pdq"),
            "zig-pdqv-safe": zig("safe", "pdqv"), "zig-pdqv-fast": zig("fast", "pdqv"),
            "rust-unstable": rust("unstable")}
else:
    sizes = [16, 256, 4096, 65536, 1 << 20]
    kinds = ["rec", "reco", "sint", "sstr"]
    km = {"reco": "rec", "sint": "int", "sstr": "str"}
    arms = {"old": rig("old"), "branch": rig("new"), "symi": rig("symi"), "a": rig("a"), "b": rig("b"),
            "zig-block-safe": zig("safe", "block", km), "rust-stable": rust("stable", km)}

best = {}
t_start = time.time()
BUDGET = float(os.environ.get("BUDGET", "900"))


def write():
    with open(out, "w") as f:
        f.write("kind\tpattern\tn\t" + "\t".join(arms) + "\n")
        for k in kinds:
            for p in PATTERNS:
                for n in sizes:
                    f.write(f"{k}\t{p}\t{n}\t" + "\t".join(f"{best.get((k, p, n, a), float('nan')):.2f}" for a in arms) + "\n")


for rnd in range(outer):
    if rnd > 0 and (time.time() - t_start) / rnd * (rnd + 1) > BUDGET:
        print(f"stopping after {rnd} rounds: budget", file=sys.stderr)
        break
    jobs = [(a, k, p, n) for a in arms for k in kinds for p in PATTERNS for n in sizes]
    random.shuffle(jobs)
    for a, k, p, n in jobs:
        # Rust and Zig have one record kind; reco is the same row there.
        cmd = arms[a](k, p, n)
        r = subprocess.run(cmd, capture_output=True, text=True)
        try:
            v = float(r.stdout.strip().split()[-1])
        except Exception:
            print("FAIL", a, k, p, n, r.stdout[-200:], r.stderr[-400:], file=sys.stderr)
            continue
        key = (k, p, n, a)
        best[key] = min(best.get(key, v), v)
    write()
    print(f"round {rnd + 1} done at {time.time() - t_start:.0f}s", file=sys.stderr, flush=True)

print(open(out).read())
