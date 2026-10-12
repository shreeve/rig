#!/usr/bin/env python3
"""Per-candidate tables from optime.py's JSON_OUT files.

usage: tables.py RESULT.json [RESULT.json ...] -- VARIANT[=LABEL] ...

Each table row is a file; each cell is the change against `base` from the
same run, in time and in cycles, as "N% faster" or "N% slower". A variant
is taken from the first result file that has it."""
import json, sys

FILES = ["twitter", "twitterescaped", "canada", "citm_catalog", "gsoc-2018", "github_events"]


def pct(b, n):
    r = b / n - 1
    if abs(r) < 0.005:
        return "0%"
    return "%.0f%% %s" % (abs(r) * 100, "faster" if r > 0 else "slower")


def main():
    i = sys.argv.index("--")
    results = [json.load(open(p)) for p in sys.argv[1:i]]
    cols = []
    for v in sys.argv[i + 1:]:
        name, _, label = v.partition("=")
        cols.append((name, label or name))
    print("| file | " + " | ".join("`%s`" % l for _, l in cols) + " |")
    print("|---|" + "---|" * len(cols))
    for f in FILES:
        cells = []
        for name, _ in cols:
            for r in results:
                if "%s %s" % (f, name) in r:
                    b, x = r["%s base" % f], r["%s %s" % (f, name)]
                    cy = pct(b["cycles"], x["cycles"]) if b.get("cycles") else "-"
                    cells.append("%s / %s" % (pct(b["ns"], x["ns"]), cy))
                    break
            else:
                cells.append("-")
        print("| %s | %s |" % (f, " | ".join(cells)))


main()
