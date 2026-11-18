#!/usr/bin/env python3
"""board.py ROUNDS OUT: rotate the arms, each a fresh process; fastest and median of each row (ms).
BOARD=1: base runtime, modes against Rayon. BOARD=2: the scratch runtime's fix prototypes (knobs)."""
import subprocess, sys, os, statistics, json
S = os.path.dirname(os.path.abspath(__file__))
R = S + "/prog/rig-base"; Y = S + "/rayon/target/release/startup"; I = S + "/prog/rig-inst"
board1 = {
 "rig-cold": (R, {"STARTUP_MODE": "cold"}),
 "rig-pre": (R, {"STARTUP_MODE": "pre"}),
 "rig-gap": (R, {"STARTUP_MODE": "gap"}),
 "rayon-cold": (Y, {"STARTUP_MODE": "cold"}),
 "rayon-pre": (Y, {"STARTUP_MODE": "pre"}),
 "rayon-gap": (Y, {"STARTUP_MODE": "gap"}),
 "rig1-cold": (R, {"STARTUP_MODE": "cold", "RIG_WORKERS": "1"}),
 "rig1-pre": (R, {"STARTUP_MODE": "pre", "RIG_WORKERS": "1"}),
 "rayon1-cold": (Y, {"STARTUP_MODE": "cold", "RAYON_NUM_THREADS": "1"}),
}
board2 = {
 "base-cold": (R, {"STARTUP_MODE": "cold"}),
 "i-cold": (I, {"STARTUP_MODE": "cold"}),
 "i-pre": (I, {"STARTUP_MODE": "pre"}),
 "i-tiny": (I, {"STARTUP_MODE": "tiny"}),
 "i-eager": (I, {"STARTUP_MODE": "cold", "RIG_X_EAGER": "1"}),
 "i-pf4": (I, {"STARTUP_MODE": "cold", "RIG_X_PREFAULT": "4"}),
 "i-pf16": (I, {"STARTUP_MODE": "cold", "RIG_X_PREFAULT": "16"}),
 "i-eager-pf16": (I, {"STARTUP_MODE": "cold", "RIG_X_EAGER": "1", "RIG_X_PREFAULT": "16"}),
 "i-eager-pf32": (I, {"STARTUP_MODE": "cold", "RIG_X_EAGER": "1", "RIG_X_PREFAULT": "32"}),
 "rayon-cold": (Y, {"STARTUP_MODE": "cold"}),
 "i1-cold": (I, {"STARTUP_MODE": "cold", "RIG_WORKERS": "1"}),
 "i1-pf32": (I, {"STARTUP_MODE": "cold", "RIG_WORKERS": "1", "RIG_X_PREFAULT": "32"}),
}
board3 = {
 "i-cold": (I, {"STARTUP_MODE": "cold"}),
 "i-eager": (I, {"STARTUP_MODE": "cold", "RIG_X_EAGER": "1"}),
 "i-eager-pf4": (I, {"STARTUP_MODE": "cold", "RIG_X_EAGER": "1", "RIG_X_PREFAULT": "4"}),
 "i-eager-pf8": (I, {"STARTUP_MODE": "cold", "RIG_X_EAGER": "1", "RIG_X_PREFAULT": "8"}),
 "i-eager-pf16": (I, {"STARTUP_MODE": "cold", "RIG_X_EAGER": "1", "RIG_X_PREFAULT": "16"}),
 "i-eager-map16": (I, {"STARTUP_MODE": "cold", "RIG_X_EAGER": "1", "RIG_X_PREFAULT": "16", "RIG_X_NOTOUCH": "1"}),
 "i-tree": (I, {"STARTUP_MODE": "cold", "RIG_X_TREE": "1"}),
 "i-tree-pf4": (I, {"STARTUP_MODE": "cold", "RIG_X_TREE": "1", "RIG_X_PREFAULT": "4"}),
 "rayon-cold": (Y, {"STARTUP_MODE": "cold"}),
}
board4 = {
 "i-cold": (I, {"STARTUP_MODE": "cold"}),
 "i-tree": (I, {"STARTUP_MODE": "cold", "RIG_X_TREE": "1"}),
 "i-mapall": (I, {"STARTUP_MODE": "cold", "RIG_X_MAPALL": "1"}),
 "i-tree-mapall": (I, {"STARTUP_MODE": "cold", "RIG_X_TREE": "1", "RIG_X_MAPALL": "1"}),
 "i-eager": (I, {"STARTUP_MODE": "cold", "RIG_X_EAGER": "1"}),
 "i-eager-map16": (I, {"STARTUP_MODE": "cold", "RIG_X_EAGER": "1", "RIG_X_PREFAULT": "16", "RIG_X_NOTOUCH": "1"}),
 "i1-cold": (I, {"STARTUP_MODE": "cold", "RIG_WORKERS": "1"}),
 "i1-mapall": (I, {"STARTUP_MODE": "cold", "RIG_WORKERS": "1", "RIG_X_MAPALL": "1"}),
 "rayon-cold": (Y, {"STARTUP_MODE": "cold"}),
}
arms = board4 if os.environ.get("BOARD") == "4" else board3 if os.environ.get("BOARD") == "3" else board2 if os.environ.get("BOARD") == "2" else board1
extra = os.environ.get("ARMS")
if extra: arms = {k: v for k, v in arms.items() if k in extra.split(",")}
rounds = int(sys.argv[1]); out = sys.argv[2]
data = {}; names = list(arms)
for k in range(rounds):
    turn = names[k % len(names):] + names[:k % len(names)]
    for n in turn:
        cmd, env = arms[n]
        o = subprocess.run([cmd], capture_output=True, text=True, timeout=120, check=True, env={**os.environ, **env}).stdout
        for row in o.splitlines():
            name, ns, chk = row.split()
            data.setdefault((n, name), []).append(int(ns) / 1e6)
json.dump({"%s|%s" % k: v for k, v in data.items()}, open(out, "w"))
rows = ["psum1", "psum2", "psum3"]
print("%-14s" % "arm" + "".join("%16s" % (r + " min/med") for r in rows))
for n in names:
    print("%-14s" % n + "".join("%9.3f/%6.3f" % (min(data[n, r]), statistics.median(data[n, r])) for r in rows))
