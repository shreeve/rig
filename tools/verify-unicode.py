#!/usr/bin/env python3
"""Check std.unicode's properties against the Character Database.

    tools/verify-unicode.py [--ucd DIR] [--rig bin/rig]

Runs tools/unicode_ranges.rig, which looks up every code point from 0 to
0x10FFFF through std.unicode, and compares its White_Space runs with
PropList.txt, and its identifier runs, code point by code point, with:

1. the classes DerivedCoreProperties.txt lists;
2. the classes derived again, independently, by the definition in UAX #31
   from UnicodeData.txt and PropList.txt: ID_Start is the letters (Lu,
   Ll, Lt, Lm, Lo), the letter numbers (Nl), and Other_ID_Start; ID_Continue
   adds Mn, Mc, Nd, Pc, and Other_ID_Continue; Pattern_Syntax and
   Pattern_White_Space are in neither;
3. the same derivation from Python's `unicodedata`, which has its own
   Unicode version. The difference between versions is accounted for: a
   code point may differ only when it is unassigned in 15.1 (a later version
   assigned it) or the later version moved it to another general category,
   and every such code point is listed by range.

Exits non-zero on any difference of White_Space, 1, or 2.
"""
import argparse
import importlib.util
import os
import subprocess
import sys
import tempfile
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gen_unicode", os.path.join(HERE, "gen-unicode.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

LIMIT = gen.LIMIT


def from_ranges(lines):
    """(start, continue, space) bytearrays from `start|continue|space FIRST LAST` lines."""
    out = {"start": bytearray(LIMIT), "continue": bytearray(LIMIT), "space": bytearray(LIMIT)}
    for line in lines:
        if not line.strip():
            continue
        kind, a, b = line.split()
        for c in range(int(a, 16), int(b, 16) + 1):
            out[kind][c] = 1
    return out["start"], out["continue"], out["space"]


def unicode_data(path):
    """The general category of each code point of UnicodeData.txt, "Cn" when unlisted."""
    cat = ["Cn"] * LIMIT
    first = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            f1 = line.split(";")
            c, name, gc = int(f1[0], 16), f1[1], f1[2]
            if name.endswith(", First>"):
                first = c
            elif name.endswith(", Last>"):
                for x in range(first, c + 1):
                    cat[x] = gc
            else:
                cat[c] = gc
    return cat


def derive(cat, other_start, other_cont, pattern):
    """(start, continue) from general categories by the UAX #31 definition."""
    st = bytearray(LIMIT)
    ct = bytearray(LIMIT)
    for c in range(LIMIT):
        g = cat(c)
        s = g in ("Lu", "Ll", "Lt", "Lm", "Lo", "Nl") or other_start[c]
        k = s or g in ("Mn", "Mc", "Nd", "Pc") or other_cont[c]
        if pattern[c]:
            s = k = False
        st[c], ct[c] = bool(s), bool(k)
    return st, ct


def mark(ranges):
    v = bytearray(LIMIT)
    for a, b in ranges:
        for c in range(a, b + 1):
            v[c] = 1
    return v


def spans(cps):
    out = []
    for c in cps:
        if out and out[-1][1] == c - 1:
            out[-1][1] = c
        else:
            out.append([c, c])
    return ["%04X..%04X" % (a, b) if a != b else "%04X" % a for a, b in out]


def diff(name, a, b):
    cps = [c for c in range(LIMIT) if a[c] != b[c]]
    if cps:
        print("%s: %d code points differ: %s" % (name, len(cps), " ".join(spans(cps)[:20])))
    return cps


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ucd")
    ap.add_argument("--rig", default=os.path.join(gen.ROOT, "bin", "rig"))
    args = ap.parse_args()
    ucd = gen.ucd_dir(args.ucd)
    with tempfile.TemporaryDirectory() as tmp:
        out = subprocess.run([args.rig, "run", os.path.join(HERE, "unicode_ranges.rig")],
                             capture_output=True, text=True, env=dict(os.environ, RIG_OUT_DIR=tmp))
    if out.returncode != 0:
        sys.exit("rig run failed:\n" + out.stderr)
    got_s, got_c, got_w = from_ranges(out.stdout.splitlines())

    # 1. DerivedCoreProperties
    cls = gen.classes(ucd)
    der_s = bytearray(1 if x & 2 else 0 for x in cls)
    der_c = bytearray(1 if x & 1 else 0 for x in cls)
    bad = len(diff("start vs DerivedCoreProperties", got_s, der_s))
    bad += len(diff("continue vs DerivedCoreProperties", got_c, der_c))

    # 2. UAX #31 from UnicodeData and PropList
    pl = gen.property_ranges(gen.ucd_file(ucd, "PropList.txt"),
                             ["Other_ID_Start", "Other_ID_Continue", "Pattern_Syntax", "Pattern_White_Space", "White_Space"])
    bad += len(diff("space vs White_Space", got_w, mark(pl["White_Space"])))
    cat = unicode_data(gen.ucd_file(ucd, "UnicodeData.txt"))
    pattern = mark(pl["Pattern_Syntax"] + pl["Pattern_White_Space"])
    oid_s, oid_c = mark(pl["Other_ID_Start"]), mark(pl["Other_ID_Continue"])
    ind_s, ind_c = derive(lambda c: cat[c], oid_s, oid_c, pattern)
    bad += len(diff("start vs UAX #31 from UnicodeData", got_s, ind_s))
    bad += len(diff("continue vs UAX #31 from UnicodeData", got_c, ind_c))

    # 3. Python's unicodedata, whatever its version
    py_s, py_c = derive(lambda c: unicodedata.category(chr(c)), oid_s, oid_c, pattern)
    allowed = 0
    for name, got, py in (("start", got_s, py_s), ("continue", got_c, py_c)):
        cps = [c for c in range(LIMIT) if got[c] != py[c]]
        unassigned = [c for c in cps if cat[c] == "Cn"]
        moved = [c for c in cps if cat[c] != "Cn" and cat[c] != unicodedata.category(chr(c))]
        other = [c for c in cps if cat[c] != "Cn" and cat[c] == unicodedata.category(chr(c))]
        allowed += len(unassigned) + len(moved)
        print("%s vs unicodedata %s: %d differ; %d unassigned in %s, %d changed category %s; %d unexplained %s" % (
            name, unicodedata.unidata_version, len(cps), len(unassigned), gen.VERSION, len(moved),
            " ".join(spans(moved)[:12]), len(other), " ".join(spans(other)[:12])))
        bad += len(other)
    n = sum(got_s), sum(got_c)
    print("%d ID_Start, %d ID_Continue, and %d White_Space code points checked over 0..10FFFF" % (n + (sum(got_w),)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
