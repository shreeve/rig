#!/usr/bin/env python3
# time-rows.py ROUNDS OUT.csv ARM=BIN...: a program printing `NAME NS CHECK` rows, interleaved, shuffled per round
import os, random, subprocess, sys
rounds = int(sys.argv[1]); out = open(sys.argv[2], "a")
arms = [a.split("=", 1) for a in sys.argv[3:]]
for r in range(rounds):
    order = arms[:]; random.shuffle(order)
    for name, b in order:
        so = subprocess.run([b], capture_output=True, text=True).stdout
        for line in so.strip().splitlines():
            p = line.split()
            out.write(f"{p[0]},{name},{r},{p[1]},{p[-1]}\n")
    out.flush()
