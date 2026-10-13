#!/usr/bin/env python3
"""Generate std/unicode_tables.zig, the identifier tables of std.unicode,
from the Unicode Character Database, and the boundary test of the tables.

    tools/gen-unicode.py [--ucd DIR] [--check]

The input is DerivedCoreProperties.txt of the pinned version below, read
from DIR (default $RIG_UCD, else ~/.cache/rig-ucd/VERSION) and fetched
from unicode.org when DIR lacks it. A file is used only when its sha256
is the pinned one, so every run writes the same bytes. `--check` writes
nothing and fails when a checked-in output differs from the generated one.

Each code point holds two bits: bit 0, ID_Continue; bit 1, ID_Start.
DerivedCoreProperties lists ID_Start and ID_Continue with Other_ID_Start
and Other_ID_Continue already included (UAX #31, "Default Identifiers").
The table is two-level: an index of blocks over the code points, and the
distinct blocks, four code points to a byte. The block size is the one
that makes the table smallest.
"""
import argparse
import hashlib
import os
import sys
import urllib.request

VERSION = "15.1.0"
BASE = "https://www.unicode.org/Public/" + VERSION + "/ucd/"
# file name -> sha256
PINNED = {
    "DerivedCoreProperties.txt": "f55d0db69123431a7317868725b1fcbf1eab6b265d756d1bd7f0f6d9f9ee108b",
    "PropList.txt": "05672956317b6296bc2ec3d6cef1f6452b57ff4f2efc6dc55b0a19277d5fcfd1",
    "UnicodeData.txt": "2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86",
}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLES = os.path.join(ROOT, "std", "unicode_tables.zig")
CENSUS = os.path.join(ROOT, "test", "behavior", "std", "unicode_ids_table.rig")
LIMIT = 0x110000


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def ucd_file(directory, name):
    """The path of the pinned UCD file `name` in `directory`, fetched when absent."""
    path = os.path.join(directory, name)
    if not os.path.exists(path):
        os.makedirs(directory, exist_ok=True)
        with urllib.request.urlopen(BASE + name) as r:
            data = r.read()
        if hashlib.sha256(data).hexdigest() != PINNED[name]:
            sys.exit("%s: the download from %s is not the pinned file" % (name, BASE))
        with open(path, "wb") as f:
            f.write(data)
    if sha256(path) != PINNED[name]:
        sys.exit("%s: sha256 is not the pinned %s" % (path, PINNED[name]))
    return path


def ucd_dir(arg):
    return arg or os.environ.get("RIG_UCD") or os.path.expanduser("~/.cache/rig-ucd/" + VERSION)


def property_ranges(path, names):
    """{name: [(first, last), ...]} for the properties `names` of a UCD property file."""
    out = {n: [] for n in names}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            span, prop = [x.strip() for x in line.split(";")[:2]]
            if prop not in out:
                continue
            first, _, last = span.partition("..")
            out[prop].append((int(first, 16), int(last or first, 16)))
    return out


def classes(ucd):
    """The two bits of every code point: bit 0 ID_Continue, bit 1 ID_Start."""
    path = ucd_file(ucd, "DerivedCoreProperties.txt")
    props = property_ranges(path, ["ID_Start", "ID_Continue"])
    v = bytearray(LIMIT)
    for first, last in props["ID_Continue"]:
        for c in range(first, last + 1):
            v[c] |= 1
    for first, last in props["ID_Start"]:
        for c in range(first, last + 1):
            if not v[c] & 1:
                sys.exit("U+%04X is ID_Start but not ID_Continue" % c)
            v[c] |= 2
    return v


def runs(v, bit):
    """The maximal runs (first, last) of code points whose class has `bit`."""
    out = []
    c = 0
    while c < LIMIT:
        if v[c] & bit:
            d = c
            while d + 1 < LIMIT and v[d + 1] & bit:
                d += 1
            out.append((c, d))
            c = d + 1
        else:
            c += 1
    return out


def pack(v, shift):
    """(index, blocks) for blocks of 1 << shift code points, from the first block on."""
    size = 1 << shift
    top = max(c for c in range(LIMIT) if v[c]) + 1
    nblocks = (top + size - 1) >> shift
    seen = {}
    index = []
    blocks = bytearray()
    for b in range(nblocks):
        chunk = bytes(v[b * size:(b + 1) * size]).ljust(size, b"\0")
        packed = bytearray()
        for i in range(0, size, 4):
            x = 0
            for j in range(4):
                x |= chunk[i + j] << (2 * j)
            packed.append(x)
        key = bytes(packed)
        if key not in seen:
            seen[key] = len(seen)
            blocks += packed
        index.append(seen[key])
    return index, blocks


def best(v):
    """(shift, index, blocks) of the smallest table."""
    cands = []
    for shift in range(3, 11):
        index, blocks = pack(v, shift)
        width = 1 if len(blocks) // (1 << (shift - 2)) <= 256 else 2
        cands.append((len(index) * width + len(blocks), shift, index, blocks))
    cands.sort(key=lambda t: (t[0], t[1]))
    _, shift, index, blocks = cands[0]
    return shift, index, blocks


def rows(items, per, fmt):
    lines = []
    for i in range(0, len(items), per):
        lines.append("    " + " ".join(fmt % x + "," for x in items[i:i + per]))
    return "\n".join(lines)


def tables_source(v):
    shift, index, blocks = best(v)
    size = 1 << shift
    bytes_per_block = size // 4
    width = "u8" if max(index) < 256 else "u16"
    top = len(index) << shift
    ascii_start = sum(1 << c for c in range(128) if v[c] & 2)
    ascii_cont = sum(1 << c for c in range(128) if v[c] & 1)
    size_total = len(index) * (1 if width == "u8" else 2) + len(blocks)
    return """//! GENERATED by tools/gen-unicode.py from the Unicode Character Database
//! {version} (DerivedCoreProperties.txt); do not edit.
//!
//! The identifier classes of `std.unicode`: ID_Start and ID_Continue of
//! UAX #31, with Other_ID_Start and Other_ID_Continue included. A code
//! point has two bits, bit 0 for ID_Continue and bit 1 for ID_Start; the
//! table is an index over blocks of {size} code points and the {nblocks}
//! distinct blocks, four code points to a byte ({total} bytes in all).

pub const version = "{version}";

const block_shift = {shift};
const block_bytes = {bytes_per_block};
/// Code points at or beyond this have neither class.
const limit: i64 = {top:#x};
const ascii_start: u128 = {ascii_start:#x};
const ascii_continue: u128 = {ascii_cont:#x};

fn class(r: i64) u8 {{
    if (r < 0 or r >= limit) return 0;
    const cp: usize = @intCast(r);
    const block: usize = index[cp >> block_shift];
    const byte = blocks[block * block_bytes + ((cp & ((1 << block_shift) - 1)) >> 2)];
    return (byte >> @intCast((cp & 3) * 2)) & 3;
}}

pub fn is_id_start(r: i64) bool {{
    if (0 <= r and r < 128) return (ascii_start >> @intCast(r)) & 1 != 0;
    return class(r) & 2 != 0;
}}

pub fn is_id_continue(r: i64) bool {{
    if (0 <= r and r < 128) return (ascii_continue >> @intCast(r)) & 1 != 0;
    return class(r) & 1 != 0;
}}

const index = [_]{width}{{
{index_rows}
}};

const blocks = [_]u8{{
{block_rows}
}};
""".format(
        version=VERSION, size=size, nblocks=len(blocks) // bytes_per_block, total=size_total,
        shift=shift, bytes_per_block=bytes_per_block, top=top, ascii_start=ascii_start,
        ascii_cont=ascii_cont, width=width,
        index_rows=rows(index, 16, "%d"), block_rows=rows(list(blocks), 16, "0x%02x"))


def census(v):
    """(starts, continues, runs of start, runs of continue, hash of the classes), as the test computes them."""
    h = 0
    for c in range(LIMIT):
        h = (h * 31 + (v[c] & 1) + 2 * (v[c] >> 1 & 1)) % 4294967296
    starts = sum(1 for c in range(LIMIT) if v[c] & 2)
    conts = sum(1 for c in range(LIMIT) if v[c] & 1)
    return starts, conts, len(runs(v, 2)), len(runs(v, 1)), h


def census_source(v):
    """A Rig test that counts the code points of each class, the runs they form, and hashes all classes."""
    starts, conts, sruns, cruns, h = census(v)
    return """# GENERATED by tools/gen-unicode.py; do not edit.
# Every code point from 0 to 0x10FFFF is looked up in both classes of
# Unicode {version}, and the counts, the number of runs, and a hash of all
# the classes equal those of the Character Database.
use std.unicode

sub main()
  starts = 0
  conts = 0
  start_runs = 0
  cont_runs = 0
  was_start = false
  was_cont = false
  h = 0
  for c in 0..0x110000
    s = unicode.is_id_start(c)
    k = unicode.is_id_continue(c)
    starts += 1 if s else 0
    conts += 1 if k else 0
    start_runs += 1 if s and not was_start else 0
    cont_runs += 1 if k and not was_cont else 0
    was_start = s
    was_cont = k
    h = (h * 31 + (1 if k else 0) + (2 if s else 0)) % 4294967296
  print(starts, conts)
  print(start_runs, cont_runs)
  print(h)

# expect:
# {starts} {conts}
# {sruns} {cruns}
# {h}
""".format(version=VERSION, starts=starts, conts=conts, sruns=sruns, cruns=cruns, h=h)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ucd", help="directory of the pinned UCD files")
    ap.add_argument("--check", action="store_true", help="fail when a checked-in output differs")
    args = ap.parse_args()
    ucd = ucd_dir(args.ucd)
    for name in PINNED:
        ucd_file(ucd, name)
    v = classes(ucd)
    outputs = [(TABLES, tables_source(v)), (CENSUS, census_source(v))]
    bad = False
    for path, text in outputs:
        if args.check:
            with open(path, encoding="utf-8") as f:
                if f.read() != text:
                    print("%s is not what tools/gen-unicode.py generates" % path, file=sys.stderr)
                    bad = True
        else:
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            print("wrote", path)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
