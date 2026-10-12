#!/usr/bin/env python3
"""Instructions retired per byte (exact, from /usr/bin/time -l) for builds
in a bench-json --out dir: (instructions of N parses - instructions of 1)
/ (N - 1) / bytes, N giving at least 60 MB parsed; the median of 5.  usage: ins.py DIR FILES VARIANTS [N]"""
import os, re, subprocess, sys
d, files, variants = sys.argv[1], sys.argv[2].split(","), sys.argv[3].split(",")
n = int(sys.argv[4]) if len(sys.argv) > 4 else 21
DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "test", "json", "data", "simd-json")
def ins(f, v, k):
    p = subprocess.run(["/usr/bin/time", "-l", os.path.join(d, "%s-%s" % (f, v), "prog"), str(k)],
                       capture_output=True, text=True)
    return int(re.search(r"(\d+)\s+instructions retired", p.stderr).group(1))
base = variants[1] if len(variants) > 1 else variants[0]
res = {}
for f in files:
    size = os.path.getsize(os.path.join(DATA, f + ".json"))
    k = max(n, int(6e7 / size))  # about 60 MB of parsing, so startup noise is small
    for v in variants:
        res[f, v] = sorted((ins(f, v, k) - ins(f, v, 1)) / (k - 1) / size for _ in range(5))[2]
print("instructions retired per byte (exact); %% vs %s" % base)
print("| file | " + " | ".join(variants) + " |")
print("|---|" + "---:|" * len(variants))
for f in files:
    print("| %s | %s |" % (f, " | ".join("%.3f (%+.1f%%)" % (res[f, v], 100 * (res[f, v] / res[f, base] - 1)) for v in variants)))
