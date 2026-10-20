#!/usr/bin/env python3
"""Generate std/unicode_tables.zig, the identifier tables of std.unicode,
std/char_tables.zig, the char classes behind the chars of std.text, and
std/width_tables.zig, the terminal widths of std.unicode and std.text,
from the Unicode Character Database, and the tests of all three.

    tools/gen-unicode.py [--ucd DIR] [--check]

The inputs are the pinned files of the versions below, read from
DIR/VERSION (DIR is $RIG_UCD by default, else ~/.cache/rig-ucd) and
fetched from unicode.org when absent. A file is used only when its sha256
is the pinned one, so every run writes the same bytes. `--check` writes
nothing and fails when a checked-in output differs from the generated one.

Identifiers: each code point holds two bits: bit 0, ID_Continue; bit 1,
ID_Start. DerivedCoreProperties lists ID_Start and ID_Continue with
Other_ID_Start and Other_ID_Continue already included (UAX #31, "Default
Identifiers"). The table is two-level: an index of blocks over the code
points, and the distinct blocks, four code points to a byte. The block
size is the one that makes the table smallest.

Chars: each code point holds its char class, four bits, in a table of
the same shape: its Grapheme_Cluster_Break (GraphemeBreakProperty.txt),
split by Extended_Pictographic (emoji-data.txt) and Indic_Conjunct_Break
(DerivedCoreProperties.txt). The rules of UAX #29 are written here too
(`is_break`), and every test of GraphemeBreakTest.txt must pass them; the
generated tests check std.text against that file and against every code
point's class.

Widths: each code point holds four bits: bits 0 and 1, its width in
terminal columns, 0, 1, or 2; bit 2, whether it takes no column of its
own inside a char; bit 3, whether a variation selector may follow it to
ask for text or emoji style (emoji-variation-sequences.txt). The rules
are those of Ghostty's tables (uucode's wcwidth): see `widths`.
"""
import argparse
import hashlib
import os
import sys
import urllib.request

# The identifier classes stay at Unicode 15.1.0, the version of
# TypeScript's scanner, so a scanner built on std.unicode reads the
# identifiers tsc reads. Chars and widths follow VERSION, the version of
# Ghostty's tables.
ID_VERSION = "15.1.0"
VERSION = "17.0.0"
# (version, file name) -> sha256
PINNED = {
    (ID_VERSION, "DerivedCoreProperties.txt"): "f55d0db69123431a7317868725b1fcbf1eab6b265d756d1bd7f0f6d9f9ee108b",
    (ID_VERSION, "PropList.txt"): "05672956317b6296bc2ec3d6cef1f6452b57ff4f2efc6dc55b0a19277d5fcfd1",
    (ID_VERSION, "UnicodeData.txt"): "2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86",
    (VERSION, "DerivedCoreProperties.txt"): "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08",
    (VERSION, "auxiliary/GraphemeBreakProperty.txt"): "d6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89",
    (VERSION, "auxiliary/GraphemeBreakTest.txt"): "e2d134d2c52919bace503ebb6a551c1855fe1a1faec18478c78fff254a1793ec",
    (VERSION, "emoji/emoji-data.txt"): "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b",
    (VERSION, "emoji/emoji-variation-sequences.txt"): "bb3d09ef03f206012c7532dd52dc0a21c9efddba0135ea4cf0d9201b8b9bba7e",
    (VERSION, "extracted/DerivedEastAsianWidth.txt"): "0b5523a2217cb318d20b329a05d31eec5af5686ba09d263b85bb75a28989a3a8",
    (VERSION, "extracted/DerivedGeneralCategory.txt"): "d62e5bab70ca74f099343f71224fa051cb1fdd61a1ab45c0488c44cfc0b6102e",
}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLES = os.path.join(ROOT, "std", "unicode_tables.zig")
# The generated tests are one test file of four cases, written through
# tools/to-rig-test.py from the programs below.
TESTS = os.path.join(ROOT, "test", "rig", "std-unicode-tables.rig.test")
LIMIT = 0x110000


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def ucd_file(directory, name, version=VERSION):
    """The path of the pinned UCD file `name` of `version` under `directory`, fetched when absent."""
    path = os.path.join(directory, version, name)
    pin = PINNED[version, name]
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        url = "https://www.unicode.org/Public/%s/ucd/%s" % (version, name)
        with urllib.request.urlopen(url) as r:
            data = r.read()
        if hashlib.sha256(data).hexdigest() != pin:
            sys.exit("%s: the download from %s is not the pinned file" % (name, url))
        with open(path, "wb") as f:
            f.write(data)
    if sha256(path) != pin:
        sys.exit("%s: sha256 is not the pinned %s" % (path, pin))
    return path


def ucd_dir(arg):
    """The directory holding a directory of each version's files."""
    return arg or os.environ.get("RIG_UCD") or os.path.expanduser("~/.cache/rig-ucd")


def property_ranges(path, names):
    """{name: [(first, last), ...]} for the properties `names` of a UCD
    property file; a property with a value is named `Property=Value`."""
    out = {n: [] for n in names}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            fields = [x.strip() for x in line.split(";")]
            span, prop = fields[0], fields[1]
            if len(fields) > 2:
                prop += "=" + fields[2]
            if prop not in out:
                continue
            first, _, last = span.partition("..")
            out[prop].append((int(first, 16), int(last or first, 16)))
    return out


def classes(ucd):
    """The two bits of every code point: bit 0 ID_Continue, bit 1 ID_Start."""
    path = ucd_file(ucd, "DerivedCoreProperties.txt", ID_VERSION)
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


def pack(v, shift, bits=2):
    """(index, blocks) for blocks of 1 << shift code points, from the first
    block on, each code point taking `bits` bits (2 or 8) of its block."""
    size = 1 << shift
    per = 8 // bits
    top = max(c for c in range(LIMIT) if v[c]) + 1
    nblocks = (top + size - 1) >> shift
    seen = {}
    index = []
    blocks = bytearray()
    for b in range(nblocks):
        chunk = bytes(v[b * size:(b + 1) * size]).ljust(size, b"\0")
        packed = bytearray()
        for i in range(0, size, per):
            x = 0
            for j in range(per):
                x |= chunk[i + j] << (bits * j)
            packed.append(x)
        key = bytes(packed)
        if key not in seen:
            seen[key] = len(seen)
            blocks += packed
        index.append(seen[key])
    return index, blocks


def best(v, bits=2):
    """(shift, index, blocks) of the smallest table."""
    cands = []
    for shift in range(3, 11):
        index, blocks = pack(v, shift, bits)
        width = 1 if len(blocks) // ((1 << shift) * bits // 8) <= 256 else 2
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
        version=ID_VERSION, size=size, nblocks=len(blocks) // bytes_per_block, total=size_total,
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
""".format(version=ID_VERSION, starts=starts, conts=conts, sruns=sruns, cruns=cruns, h=h)


# ---- Chars: extended grapheme clusters (UAX #29) -------------------------

CHAR_TABLES = os.path.join(ROOT, "std", "char_tables.zig")

# The char classes, in the order of their numbers: each is a
# Grapheme_Cluster_Break value, split where Extended_Pictographic (GB11) or
# Indic_Conjunct_Break (GB9c) tells code points of one value apart. The
# order keeps the ranges the rules test together: extend..linker are the
# Extend of GB11, extend..zwj the code points GB9 joins, incb_extend..zwj
# the InCB Extend and Linker of GB9c, and control..lf those GB4 and GB5
# break around. CR and LF, the last two, are ASCII, so the table, which
# holds the other sixteen, four bits to a code point, never needs them.
CHAR_CLASSES = [
    "other", "pict", "consonant", "prepend", "spacing_mark", "l", "v", "t", "lv", "lvt",
    "ri", "extend", "incb_extend", "linker", "zwj", "control", "cr", "lf",
]
# The classes Ghostty's tailored chars add (uucode's grapheme breaks), past
# the table's: an emoji modifier, which joins only an emoji modifier base
# just before it, and that base. std/char.zig refines `extend`,
# `incb_extend`, and `pict` into them, and only for tailored chars.
TAILORED_CLASSES = ["emoji_modifier", "emoji_base"]
G = {name: i for i, name in enumerate(CHAR_CLASSES)}
GBP = {
    "CR": "cr", "LF": "lf", "Control": "control", "Extend": "extend", "ZWJ": "zwj",
    "Regional_Indicator": "ri", "Prepend": "prepend", "SpacingMark": "spacing_mark",
    "L": "l", "V": "v", "T": "t", "LV": "lv", "LVT": "lvt",
}


def char_classes(ucd):
    """The char class of every code point, checking that each property
    falls in the Grapheme_Cluster_Break values the classes assume."""
    v = bytearray(LIMIT)
    gbp = property_ranges(ucd_file(ucd, "auxiliary/GraphemeBreakProperty.txt"), list(GBP))
    for prop, name in GBP.items():
        for first, last in gbp[prop]:
            for c in range(first, last + 1):
                v[c] = G[name]
    pict = property_ranges(ucd_file(ucd, "emoji/emoji-data.txt"), ["Extended_Pictographic"])
    for first, last in pict["Extended_Pictographic"]:
        for c in range(first, last + 1):
            if v[c] != G["other"]:
                sys.exit("U+%04X is Extended_Pictographic but not Grapheme_Cluster_Break Other" % c)
            v[c] = G["pict"]
    incb = property_ranges(ucd_file(ucd, "DerivedCoreProperties.txt"),
                           ["InCB=Consonant", "InCB=Linker", "InCB=Extend"])
    for value, base, name in [("Consonant", "other", "consonant"), ("Linker", "extend", "linker"),
                              ("Extend", "extend", "incb_extend")]:
        for first, last in incb["InCB=" + value]:
            for c in range(first, last + 1):
                if v[c] == G["zwj"] and value == "Extend":
                    continue
                if v[c] != G[base]:
                    sys.exit("U+%04X is InCB %s but not the class %s" % (c, value, base))
                v[c] = G[name]
    if any(v[c] == G["ri"] for c in range(LIMIT) if not 0x1F1E6 <= c <= 0x1F1FF):
        sys.exit("a regional indicator is outside U+1F1E6..U+1F1FF, the four-byte runes std/char.zig counts")
    zwj = [c for c in range(LIMIT) if v[c] == G["zwj"]]
    in_extend = any(a <= 0x200D <= b for a, b in incb["InCB=Extend"])
    if zwj != [0x200D] or not in_extend:
        sys.exit("ZWJ is not the one code point of its class, or is not InCB Extend")
    return v


def emoji_sets(ucd):
    """(the Emoji_Modifier_Base code points, sorted), checking that the
    emoji modifiers are U+1F3FB..U+1F3FF, the bases Extended_Pictographic,
    and every base past the BMP in U+1F000..U+1FFFF, as std/char_tables.zig
    assumes."""
    e = property_ranges(ucd_file(ucd, "emoji/emoji-data.txt"),
                        ["Emoji_Modifier", "Emoji_Modifier_Base", "Extended_Pictographic"])
    if e["Emoji_Modifier"] != [(0x1F3FB, 0x1F3FF)]:
        sys.exit("the emoji modifiers are not U+1F3FB..U+1F3FF")
    pict = set(c for a, b in e["Extended_Pictographic"] for c in range(a, b + 1))
    bases = sorted(c for a, b in e["Emoji_Modifier_Base"] for c in range(a, b + 1))
    if any(c not in pict for c in bases):
        sys.exit("an emoji modifier base is not Extended_Pictographic")
    if any(0x10000 <= c < 0x1F000 or c >= 0x20000 for c in bases):
        sys.exit("an emoji modifier base past the BMP is outside U+1F000..U+1FFFF")
    return bases


def is_break(cls, i):
    """Whether UAX #29 breaks between the code points i - 1 and i of the
    classes `cls` (0 < i < len(cls)): rules GB3 to GB999, each tested on
    the text before i as the rule writes it, with no state carried."""
    p, c = cls[i - 1], cls[i]
    if p == G["cr"] and c == G["lf"]:
        return False                                               # GB3
    if p >= G["control"] or c >= G["control"]:
        return True                                                # GB4, GB5
    if p == G["l"] and c in (G["l"], G["v"], G["lv"], G["lvt"]):
        return False                                               # GB6
    if p in (G["lv"], G["v"]) and c in (G["v"], G["t"]):
        return False                                               # GB7
    if p in (G["lvt"], G["t"]) and c == G["t"]:
        return False                                               # GB8
    if G["extend"] <= c <= G["zwj"] or c == G["spacing_mark"] or p == G["prepend"]:
        return False                                               # GB9, GB9a, GB9b
    if c == G["consonant"]:                                        # GB9c
        j, linked = i - 1, False
        while j >= 0 and G["incb_extend"] <= cls[j] <= G["zwj"]:
            linked = linked or cls[j] == G["linker"]
            j -= 1
        if linked and j >= 0 and cls[j] == G["consonant"]:
            return False
    if p == G["zwj"] and c == G["pict"]:                           # GB11
        j = i - 2
        while j >= 0 and G["extend"] <= cls[j] <= G["linker"]:
            j -= 1
        if j >= 0 and cls[j] == G["pict"]:
            return False
    if p == G["ri"] and c == G["ri"]:                              # GB12, GB13
        j = i - 1
        while j >= 0 and cls[j] == G["ri"]:
            j -= 1
        if (i - 1 - j) % 2 == 1:
            return False
    return True                                                    # GB999


def char_sizes(v, cps):
    """The UTF-8 sizes of the chars of the code points `cps`."""
    cls = [v[c] for c in cps]
    sizes, size = [], 0
    for i, c in enumerate(cps):
        if i > 0 and is_break(cls, i):
            sizes.append(size)
            size = 0
        size += len(chr(c).encode("utf-8"))
    if cps:
        sizes.append(size)
    return sizes


def break_tests(ucd, v):
    """[(line, code points, char sizes)] for each test of GraphemeBreakTest.txt,
    checking that the rules above split each one as the line says."""
    out = []
    with open(ucd_file(ucd, "auxiliary/GraphemeBreakTest.txt"), encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            body = line.split("#", 1)[0].split()
            if not body:
                continue
            cps, sizes, size = [], [], 0
            for tok in body[1:]:
                if tok in ("\N{DIVISION SIGN}", "\N{MULTIPLICATION SIGN}"):
                    if tok == "\N{DIVISION SIGN}":
                        sizes.append(size)
                        size = 0
                else:
                    cps.append(int(tok, 16))
                    size += len(chr(cps[-1]).encode("utf-8"))
            if char_sizes(v, cps) != sizes:
                sys.exit("GraphemeBreakTest.txt line %d: the rules give %s" % (n, char_sizes(v, cps)))
            out.append((n, cps, sizes))
    return out


def char_tables_source(v, bases):
    for c in range(128):
        want = {0x0D: "cr", 0x0A: "lf"}.get(c, "control" if c < 0x20 or c == 0x7F else "other")
        if v[c] != G[want]:
            sys.exit("U+%04X is not of the ASCII class std/char_tables.zig gives it" % c)
    if any(v[c] >= G["cr"] for c in range(128, LIMIT)):
        sys.exit("a code point beyond ASCII is CR or LF")
    if any(v[c] != G["other"] for c in range(0x100000, LIMIT)):
        sys.exit("a code point of plane 16 is not `other`, which std/char_tables.zig makes it")
    # Each level fills its index type's whole range, so no index needs a
    # check: 4096 entries for `c >> 8` below 0x100000 (a u12), and 128
    # blocks for an entry (a u7), each 128 bytes for `c >> 1` (a u7).
    v = bytearray(min(x, G["control"]) for x in v)
    index, blocks = pack(v, 8, 4)
    nblocks = len(blocks) // 128
    other = [k for k in range(nblocks) if blocks[k * 128:(k + 1) * 128] == bytes(128)]
    if not other:
        sys.exit("no block of the char table is all `other`")
    index += [other[0]] * (4096 - len(index))
    if nblocks > 128:
        sys.exit("the char table has more than 128 distinct blocks")
    blocks += bytes(128 * (128 - nblocks))
    total = len(index) + len(blocks)
    enum = "\n".join("    %s," % name for name in CHAR_CLASSES + TAILORED_CLASSES)
    bmp = [c for c in bases if c < 0x10000]
    spans = []
    for c in bmp:
        if spans and spans[-1][1] == c - 1:
            spans[-1][1] = c
        else:
            spans.append([c, c])
    bmp_cases = ", ".join("0x%04X" % a if a == b else "0x%04X...0x%04X" % (a, b) for a, b in spans)
    words = [0] * 64
    for c in bases:
        if c >= 0x1F000:
            words[(c - 0x1F000) >> 6] |= 1 << ((c - 0x1F000) & 63)
    base_rows = "\n".join("    " + " ".join("0x%016x," % w for w in words[k:k + 4]) for k in range(0, 64, 4))
    block_rows = "\n".join("    .{ " + ", ".join("0x%02x" % x for x in blocks[k * 128:(k + 1) * 128]) + " },"
                            for k in range(128))
    return """//! GENERATED by tools/gen-unicode.py from the Unicode Character Database
//! {version} (GraphemeBreakProperty.txt, emoji-data.txt, and
//! DerivedCoreProperties.txt); do not edit.
//!
//! The char class of every code point, for the chars of `std.text`
//! (std/char.zig): its Grapheme_Cluster_Break value, with
//! Extended_Pictographic and Indic_Conjunct_Break splitting the values
//! they refine. The table is an index over blocks of 256 code points and
//! the {nblocks} distinct blocks, four bits to a code point ({total} bytes in
//! all); ASCII, where CR and LF are, is classed without it, and plane 16 is
//! all `other`. Each level fills the range of the type that indexes it, so
//! no lookup needs a bounds check.

pub const version = "{version}";

pub const Class = enum(u5) {{
{enum}
}};

/// The class of code point `c`.
pub inline fn of(c: u21) Class {{
    if (c < 0x80) return ascii(@truncate(c));
    if (c >= 0x100000) return .other;
    const block = index[@as(u12, @truncate(c >> 8))];
    const byte = blocks[block][@as(u7, @truncate(c >> 1))];
    return @enumFromInt(@as(u4, @truncate(byte >> (@as(u3, @truncate(c & 1)) << 2))));
}}

/// Whether `c` is an emoji modifier (Emoji_Modifier, a skin tone), of
/// class `extend` or `incb_extend`.
pub inline fn isEmojiModifier(c: u21) bool {{
    return c >= 0x1F3FB and c <= 0x1F3FF;
}}

/// Whether `c` is an emoji modifier base (Emoji_Modifier_Base), of class
/// `pict`: {nbases} code points, those past the BMP in U+1F000..U+1FFFF.
pub fn isEmojiBase(c: u21) bool {{
    if (c < 0x1F000) return switch (c) {{
        {bmp_cases} => true,
        else => false,
    }};
    if (c >= 0x20000) return false;
    const i: u12 = @truncate(c - 0x1F000);
    return emoji_bases[i >> 6] >> @as(u6, @truncate(i)) & 1 != 0;
}}

const emoji_bases: [64]u64 = .{{
{base_rows}
}};

/// The class of the ASCII byte `b`.
pub inline fn ascii(b: u7) Class {{
    return switch (b) {{
        '\\r' => .cr,
        '\\n' => .lf,
        0...0x09, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => .control,
        else => .other,
    }};
}}

const index: [4096]u7 = .{{
{index_rows}
}};

const blocks: [128][128]u8 = .{{
{block_rows}
}};
""".format(
        version=VERSION, nblocks=nblocks, total=total, enum=enum,
        index_rows=rows(index, 16, "%d"), block_rows=block_rows,
        nbases=len(bases), bmp_cases=bmp_cases, base_rows=base_rows)



# The texts around a code point X whose char counts tell every char
# class apart: (the code points before X, those after X).
PROBES = [
    ([0x61], []), ([], [0x61]), ([], [0x301]), ([0x0D], []), ([], [0x0A]), ([], [0x1161]),
    ([], [0x11A8]), ([], [0x1100]), ([], [0x1F1E6]), ([0x1F600, 0x200D], []), ([0x915, 0x94D], []),
    ([0x915], [0x915]), ([0x915, 0x94D], [0x915]), ([0x1F600], [0x200D, 0x1F600]), ([0xAC00], []),
]


def probe_signatures(v):
    """{class: signature}: the char counts of the probes around a code point
    of each class, two bits each, by the rules above."""
    out = {}
    for k in range(len(CHAR_CLASSES)):
        sig = 0
        for i, (before, after) in enumerate(PROBES):
            cls = [v[x] for x in before] + [k] + [v[x] for x in after]
            n = 1 + sum(1 for j in range(1, len(cls)) if is_break(cls, j))
            sig |= (n - 1) << (2 * i)
        out[k] = sig
    if len(set(out.values())) != len(out):
        sys.exit("the probes do not tell every char class apart")
    return out


def char_census_source(v):
    """A Rig test that puts every code point but the surrogates in each
    probe and hashes the char counts."""
    sigs = probe_signatures(v)
    h = 0
    for c in range(LIMIT):
        if 0xD800 <= c < 0xE000:
            continue
        h = (h * 31 + sigs[v[c]]) % 4294967296
    probes = "\n".join("    sig += (count(!t, %s, c, %s) - 1) << %d" % (rig_text(a), rig_text(b), 2 * i)
                       for i, (a, b) in enumerate(PROBES))
    return """# GENERATED by tools/gen-unicode.py; do not edit.
# Every code point but the surrogates is put in short texts whose char
# counts tell its char class of Unicode {version} apart, and a hash of
# all the counts equals that of the Character Database.
use std.text

# Appends `c` to `t` in UTF-8.
sub push_rune(t: !String, c: Int)
  if c < 0x80
    !t.push(U8(c))
  else if c < 0x800
    !t.push(U8(0xC0 + c / 64))
    !t.push(U8(0x80 + c % 64))
  else if c < 0x10000
    !t.push(U8(0xE0 + c / 4096))
    !t.push(U8(0x80 + c / 64 % 64))
    !t.push(U8(0x80 + c % 64))
  else
    !t.push(U8(0xF0 + c / 262144))
    !t.push(U8(0x80 + c / 4096 % 64))
    !t.push(U8(0x80 + c / 64 % 64))
    !t.push(U8(0x80 + c % 64))

# The chars of `before`, `c`, and `after`, written in `t`.
fun count(t: !String, before: ?String, c: Int, after: ?String) -> Int
  !t.clear()
  !t.add(before)
  push_rune(!t, c)
  !t.add(after)
  text.char_count(?t[..])

sub main()
  t = String()
  h = 0
  for c in 0..0x110000
    continue if c >= 0xD800 and c < 0xE000
    sig = 0
{probes}
    h = (h * 31 + sig) % 4294967296
  print(h)

# expect:
# {h}
""".format(version=VERSION, probes=probes, h=h)


def rig_text(cps):
    """`cps` as a Rig string literal."""
    return '"' + "".join("\\u{%x}" % c for c in cps) + '"'


def char_test_source(tests):
    calls = "\n".join("  bad += check(%d, %s, \"%s\")" % (n, rig_text(cps), " ".join(map(str, sizes)))
                      for n, cps, sizes in tests)
    return """# GENERATED by tools/gen-unicode.py from GraphemeBreakTest.txt of Unicode
# {version}; do not edit.
# Every test of Unicode's grapheme break test: `text.chars` splits the
# text into chars of the byte sizes the test gives, and `char_count`,
# `first_chars`, `last_chars`, and `char_boundary` agree with them at
# every char and every byte.
use std.text

# 0 when `s` splits into chars of the byte sizes `want` (separated by
# spaces) and the other char tools agree; else 1, after printing why.
fun check(line: Int, s: ?String, want: ?String) -> Int
  got = String()
  starts = List[Int]()
  at = 0
  for c in text.chars(s)
    !got.add(" ") if got.len > 0
    !got.add(c.len)
    !starts.push(at)
    at += c.len
  if got != want
    print("line", line, "sizes", got, "want", want)
    return 1
  n = starts.len
  if text.char_count(s) != n
    print("line", line, "char_count", text.char_count(s))
    return 1
  for k in 0..n
    end = starts[k + 1] if k + 1 < n else s.len
    for i in starts[k]..end
      if text.char_boundary(s, i) != starts[k]
        print("line", line, "char_boundary", i, text.char_boundary(s, i))
        return 1
    if text.first_chars(s, k).len != starts[k]
      print("line", line, "first_chars", k)
      return 1
    if text.last_chars(s, n - k).len != s.len - starts[k]
      print("line", line, "last_chars", n - k)
      return 1
  if text.char_boundary(s, s.len) != s.len or text.first_chars(s, n).len != s.len or text.last_chars(s, 0).len != 0
    print("line", line, "at the end")
    return 1
  0

sub main()
  bad = 0
{calls}
  print({count}, "tests,", bad, "failed")

# release
# expect:
# {count} tests, 0 failed
""".format(version=VERSION, calls=calls, count=len(tests))


# ---- Widths: terminal columns ------------------------------------------

WIDTH_TABLES = os.path.join(ROOT, "std", "width_tables.zig")
ZERO_IN_CHAR = 4
VS_BASE = 8


def missing_ranges(path):
    """[(first, last, value)] of the `# @missing` lines of a UCD file, the
    values of the code points its data lines leave out, in file order."""
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("# @missing:"):
                span, value = [x.strip() for x in line[len("# @missing:"):].split(";")]
                first, _, last = span.partition("..")
                out.append((int(first, 16), int(last or first, 16), value))
    return out


def value_of(ucd, name, default, aliases):
    """The value of a one-valued property file at every code point: the
    `# @missing` defaults first, then the data lines. The defaults are
    written with long names, which `aliases` maps to the short ones."""
    path = ucd_file(ucd, name)
    v = [default] * LIMIT
    for first, last, value in missing_ranges(path):
        for c in range(first, last + 1):
            v[c] = aliases.get(value, value)
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            span, value = [x.strip() for x in line.split(";")]
            first, _, last = span.partition("..")
            for c in range(int(first, 16), int(last or first, 16) + 1):
                v[c] = value
    return v


def widths(ucd):
    """The width bits of every code point, by the rules of Ghostty's tables
    (uucode's wcwidth_standalone and wcwidth_zero_in_grapheme, joined as
    Ghostty's WidthComponent joins them).

    Alone, a code point takes 0 columns when it is a control (Cc), a
    surrogate (Cs), a line or paragraph separator (Zl, Zp), or
    Default_Ignorable_Code_Point other than the soft hyphen U+00AD; 2 when
    its East_Asian_Width is Wide or Fullwidth or it is a regional
    indicator, and U+2E3A and U+2E3B (the two- and three-em dashes); else 1.
    Inside a char it takes no column of its own when it takes none alone,
    or it is an emoji modifier, a nonspacing or enclosing mark (Mn, Me), a
    Hangul vowel or trailing consonant (V, T), or a prepend. Its width is
    0 when it takes no column inside a char, unless it is an emoji modifier
    or a prepend, which keep their width alone so they still show when
    they stand alone; else its width alone."""
    gc = value_of(ucd, "extracted/DerivedGeneralCategory.txt", "Cn", {"Unassigned": "Cn"})
    eaw = value_of(ucd, "extracted/DerivedEastAsianWidth.txt", "N", {"Neutral": "N", "Wide": "W"})
    core = property_ranges(ucd_file(ucd, "DerivedCoreProperties.txt"), ["Default_Ignorable_Code_Point"])
    emoji = property_ranges(ucd_file(ucd, "emoji/emoji-data.txt"), ["Emoji_Modifier"])
    gbp = property_ranges(ucd_file(ucd, "auxiliary/GraphemeBreakProperty.txt"),
                          ["V", "T", "Prepend", "Regional_Indicator"])
    ignorable = set(c for a, b in core["Default_Ignorable_Code_Point"] for c in range(a, b + 1))
    modifier = set(c for a, b in emoji["Emoji_Modifier"] for c in range(a, b + 1))
    gcb = {}
    for prop, spans in gbp.items():
        for a, b in spans:
            for c in range(a, b + 1):
                gcb[c] = prop
    vs_base = set()
    with open(ucd_file(ucd, "emoji/emoji-variation-sequences.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                base, selector = line.split(";")[0].split()
                if selector in ("FE0E", "FE0F"):
                    vs_base.add(int(base, 16))
    v = bytearray(LIMIT)
    for c in range(LIMIT):
        if gc[c] in ("Cc", "Cs", "Zl", "Zp"):
            alone = 0
        elif c == 0xAD:
            alone = 1
        elif c in ignorable:
            alone = 0
        elif c in (0x2E3A, 0x2E3B) or eaw[c] in ("W", "F") or gcb.get(c) == "Regional_Indicator":
            alone = 2
        else:
            alone = 1
        zero = (alone == 0 or c in modifier or gc[c] in ("Mn", "Me")
                or gcb.get(c) in ("V", "T", "Prepend"))
        if c == 0x20E3:
            alone = 2
        width = 0 if zero and c not in modifier and gcb.get(c) != "Prepend" else alone
        v[c] = width | (ZERO_IN_CHAR if zero else 0) | (VS_BASE if c in vs_base else 0)
    return v


def width_tables_source(w, g):
    for c in range(0x20, 0x7F):
        if w[c] & 3 != 1:
            sys.exit("U+%04X is not of width 1, which std/width_tables.zig gives printable ASCII" % c)
    if any(w[c] != 1 or g[c] != G["other"] for c in range(0x100000, LIMIT)):
        sys.exit("a code point of plane 16 is not of width 1 and class other, which std/width_tables.zig makes it")
    # A byte a code point: the width bits low, the char class high (as
    # std/char_tables.zig holds it, CR and LF as `control`), so a terminal
    # finds both in one lookup. The shape of std/char_tables.zig: 4096
    # entries for `c >> 8` below 0x100000, 128 blocks of 256 bytes.
    v = bytearray(w[c] | (min(g[c], G["control"]) << 4) for c in range(LIMIT))
    index, blocks = pack(v, 8, 8)
    nblocks = len(blocks) // 256
    one = [k for k in range(nblocks) if blocks[k * 256:(k + 1) * 256] == bytes([0x01] * 256)]
    if not one:
        sys.exit("no block of the width table is all width 1 and class other")
    index = index[:4096] + [one[0]] * (4096 - len(index))
    if nblocks > 128:
        sys.exit("the width table has %d distinct blocks, more than 128" % nblocks)
    blocks += bytes(256 * (128 - nblocks))
    total = len(index) + len(blocks)
    block_rows = "\n".join("    .{ " + ", ".join("0x%02x" % x for x in blocks[k * 256:(k + 1) * 256]) + " },"
                            for k in range(128))
    return """//! GENERATED by tools/gen-unicode.py from the Unicode Character Database
//! {version} (DerivedGeneralCategory.txt, DerivedEastAsianWidth.txt,
//! DerivedCoreProperties.txt, GraphemeBreakProperty.txt, emoji-data.txt,
//! and emoji-variation-sequences.txt); do not edit.
//!
//! The terminal widths of `std.unicode` and `std.text`, by the rules of
//! Ghostty's tables (see `widths` in tools/gen-unicode.py), with each code
//! point's char class beside them, so a terminal in mode 2027 finds both
//! at once. Each code point has a byte: bits 0 and 1 its width, 0, 1, or
//! 2; `zero_in_char`, whether it takes no column of its own inside a char;
//! `vs_base`, whether a variation selector may follow it to ask for text
//! or emoji style; and in the high four bits its class of
//! std/char_tables.zig (CR and LF as `control`). The table is an index
//! over blocks of 256 code points and the {nblocks} distinct blocks ({total}
//! bytes in all); plane 16 is all width 1 and class `other`. Each level
//! fills the range of the type that indexes it, so no lookup needs a
//! bounds check.

pub const version = "{version}";

pub const zero_in_char: u4 = {zero};
pub const vs_base: u4 = {vs};

/// The byte of code point `c`: its width bits low, its char class high.
pub inline fn entry(c: u21) u8 {{
    if (c >= 0x100000) return 1;
    return blocks[index[@as(u12, @truncate(c >> 8))]][@as(u8, @truncate(c))];
}}

/// The width bits of code point `c`.
pub inline fn props(c: u21) u4 {{
    return @truncate(entry(c));
}}

/// The columns rune `r` takes in a terminal, 0, 1, or 2; 0 for a value
/// that is not a rune.
pub fn width(r: i64) i64 {{
    if (0x20 <= r and r < 0x7F) return 1;
    if (r < 0 or r > 0x10FFFF) return 0;
    // Truncated, not @intCast: Zig 0.17 lowers @intCast from a signed type
    // to an unsigned one as `trunc nsw`, which tells LLVM the result fits
    // the signed type, so a rune of plane 16 would test as below 0x100000.
    return props(@truncate(@as(u64, @bitCast(r)))) & 3;
}}

/// The width bits of rune `r` (see `props`); 0 for a value that is not a
/// rune.
pub fn width_props(r: i64) i64 {{
    if (r < 0 or r > 0x10FFFF) return 0;
    return props(@truncate(@as(u64, @bitCast(r))));
}}

const index: [4096]u7 = .{{
{index_rows}
}};

const blocks: [128][256]u8 = .{{
{block_rows}
}};
""".format(
        version=VERSION, nblocks=nblocks, total=total, zero=ZERO_IN_CHAR, vs=VS_BASE,
        index_rows=rows(index, 16, "%d"), block_rows=block_rows)


def char_width(w, g, cps):
    """The columns the first char of the code points `cps` takes: the
    width of its first code point, then each one after it in the char that
    takes a column of its own makes it 2, and a variation selector after a
    code point that takes one makes it 2 (U+FE0F) or 1 (U+FE0E)."""
    if not cps:
        return 0
    cls = [g[c] for c in cps]
    width, prev = w[cps[0]] & 3, cps[0]
    for i in range(1, len(cps)):
        if is_break(cls, i):
            break
        c = cps[i]
        if c in (0xFE0E, 0xFE0F):
            if not w[prev] & VS_BASE:
                continue
            width = 2 if c == 0xFE0F else 1
        elif not w[c] & ZERO_IN_CHAR:
            width = 2
        prev = c
    return width


def width_census_source(w, g):
    """A Rig test that hashes every code point's width alone, after a
    letter, and before U+FE0F, and counts the code points of each width."""
    h = 0
    counts = [0, 0, 0]
    for c in range(LIMIT):
        if 0xD800 <= c < 0xE000:
            continue
        counts[w[c] & 3] += 1
        sig = (w[c] & 3) + 3 * char_width(w, g, [0x61, c]) + 9 * char_width(w, g, [c, 0xFE0F])
        h = (h * 31 + sig) % 4294967296
    return """# GENERATED by tools/gen-unicode.py; do not edit.
# Every code point but the surrogates: its width of Unicode {version},
# and the width of the char it makes after a letter and before U+FE0F,
# hashed, and the code points of each width counted, equal those of the
# Character Database.
use std.text
use std.unicode

# Appends `c` to `t` in UTF-8.
sub push_rune(t: !String, c: Int)
  if c < 0x80
    !t.push(U8(c))
  else if c < 0x800
    !t.push(U8(0xC0 + c / 64))
    !t.push(U8(0x80 + c % 64))
  else if c < 0x10000
    !t.push(U8(0xE0 + c / 4096))
    !t.push(U8(0x80 + c / 64 % 64))
    !t.push(U8(0x80 + c % 64))
  else
    !t.push(U8(0xF0 + c / 262144))
    !t.push(U8(0x80 + c / 4096 % 64))
    !t.push(U8(0x80 + c / 64 % 64))
    !t.push(U8(0x80 + c % 64))

sub main()
  t = String()
  counts = [0, 0, 0]
  h = 0
  for c in 0..0x110000
    continue if c >= 0xD800 and c < 0xE000
    w = unicode.width(c)
    counts[w] += 1
    !t.clear()
    !t.add("a")
    push_rune(!t, c)
    after = text.char_width(?t[..])
    !t.clear()
    push_rune(!t, c)
    !t.add("\\u{{fe0f}}")
    before = text.char_width(?t[..])
    h = (h * 31 + w + 3 * after + 9 * before) % 4294967296
  print(counts[0], counts[1], counts[2])
  print(h)

# release
# expect:
# {c0} {c1} {c2}
# {h}
""".format(version=VERSION, c0=counts[0], c1=counts[1], c2=counts[2], h=h)


def tests_source(programs):
    """The test file of the generated programs, `{name: source}`: each a
    behavior test, converted by tools/to-rig-test.py as any test written
    as a program of its own is."""
    import importlib.util
    import tempfile
    spec = importlib.util.spec_from_file_location("to_rig_test", os.path.join(ROOT, "tools", "to-rig-test.py"))
    conv = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(conv)
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for name, source in programs.items():
            path = os.path.join(tmp, "behavior", "std", name + ".rig")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(source)
            paths.append((path, None))
        out = os.path.join(tmp, "out.rig.test")
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()):
            conv.write(out, "std.unicode and std.text: the tests tools/gen-unicode.py generates from the pinned Character Database. Regenerate this file; never edit it.", paths)
        with open(out, encoding="utf-8", newline="") as f:
            return f.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ucd", help="directory of the pinned UCD files")
    ap.add_argument("--check", action="store_true", help="fail when a checked-in output differs")
    args = ap.parse_args()
    ucd = ucd_dir(args.ucd)
    for version, name in PINNED:
        ucd_file(ucd, name, version)
    v = classes(ucd)
    g = char_classes(ucd)
    w = widths(ucd)
    outputs = [(TABLES, tables_source(v)), (CHAR_TABLES, char_tables_source(g, emoji_sets(ucd))),
               (WIDTH_TABLES, width_tables_source(w, g)),
               (TESTS, tests_source({"unicode_ids_table": census_source(v),
                                     "text_chars_conformance": char_test_source(break_tests(ucd, g)),
                                     "text_chars_table": char_census_source(g),
                                     "unicode_widths_table": width_census_source(w, g)}))]
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
