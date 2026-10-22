#!/usr/bin/env python3
"""inter.py ROUNDS 'cmd1' 'cmd2' ...: runs the commands interleaved ROUNDS
times; each prints "<ps> ps/64B <checksum>"; prints per command the fastest,
the median, and the checksums seen."""
import shlex, subprocess, sys, statistics

rounds = int(sys.argv[1])
cmds = sys.argv[2:]
res = {c: [] for c in cmds}
sums = {c: set() for c in cmds}
for _ in range(rounds):
    for c in cmds:
        out = subprocess.run(shlex.split(c), capture_output=True, text=True)
        line = (out.stdout + out.stderr).strip().split("\n")[-1]
        f = line.split()
        res[c].append(int(f[0])); sums[c].add(f[-1])
for c in cmds:
    print(f"{min(res[c]):6d} min  {int(statistics.median(res[c])):6d} median  sums={sorted(sums[c])}  {c}")
