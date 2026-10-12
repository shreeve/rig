#!/usr/bin/env python3
"""The length distribution of keys and string values in JSON files.

usage: tools/json-string-stats.py [FILE ...]   (default: the benchmark corpus)

Lengths are the raw bytes between the quotes, escapes as written, which
is what a string scan reads. For each file and kind: the count, the
share of strings at most 16, 32, 64, and 128 bytes long, the mean, and
the share of all string bytes in strings longer than 32 bytes. Also: the
share of strings with an escape, and with a byte of 0x80 or more.
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FILES = ["twitter", "canada", "citm_catalog", "gsoc-2018", "github_events"]

def strings(data):
    """Yields (is_key, raw bytes) for every string, in order."""
    i, n = 0, len(data)
    while i < n:
        if data[i] != 0x22:
            i += 1; continue
        j = i + 1
        while data[j] != 0x22:
            j += 2 if data[j] == 0x5C else 1
        k = j + 1
        while k < n and data[k] in b" \t\r\n": k += 1
        yield (k < n and data[k] == 0x3A), data[i + 1:j]
        i = j + 1

def main():
    paths = sys.argv[1:] or [os.path.join(ROOT, "test", "json", "data", "simd-json", f + ".json") for f in FILES]
    print("| file | kind | count | <=16 | <=32 | <=64 | <=128 | mean | bytes in >32 | escaped | non-ASCII |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for p in paths:
        data = open(p, "rb").read()
        groups = {"keys": [], "values": []}
        for is_key, s in strings(data):
            groups["keys" if is_key else "values"].append(s)
        for kind, ss in groups.items():
            if not ss: continue
            lens = [len(s) for s in ss]
            total = sum(lens) or 1
            pct = lambda lim: 100.0 * sum(1 for x in lens if x <= lim) / len(lens)
            print("| %s | %s | %d | %.0f%% | %.0f%% | %.0f%% | %.0f%% | %.1f | %.0f%% | %.1f%% | %.1f%% |" % (
                os.path.splitext(os.path.basename(p))[0], kind, len(ss), pct(16), pct(32), pct(64), pct(128),
                total / len(ss), 100.0 * sum(x for x in lens if x > 32) / total,
                100.0 * sum(1 for s in ss if b"\\" in s) / len(ss),
                100.0 * sum(1 for s in ss if any(b >= 0x80 for b in s)) / len(ss)))

main()
