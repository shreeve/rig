#!/usr/bin/env python3
"""bench.py: the uutils coreutils divan benchmarks, run as processes.

Every src/uu/*/benches/*.rs in uutils coreutils is a divan bench that calls
the utility's `uumain` in-process. This script rebuilds each bench's input
exactly (the generators of uucore::benchmark::text_data, fs_tree, and
binary_data, ported byte for byte), then times `BINARY UTIL ARGS...` as a
process for every binary given, so a Rig port can be measured against the
Rust one on the same input.

    bench.py rust=PATH gnu=prefix:/opt/homebrew/bin/g [rig=PATH ...] [--only REGEX]

Each arm is NAME=PATH: a multi-call binary (run as `PATH UTIL ARGS`), a
directory of one binary per utility (`PATH/UTIL ARGS`), or prefix:P, one
binary per utility named P followed by the utility (`/opt/homebrew/bin/gwc`
for prefix:/opt/homebrew/bin/g). An arm without the utility sits that
bench out. The first arm is the reference the others are compared with.

For each bench it:
  - builds the input once (cached in --work across runs, keyed by generator);
  - runs each binary once untimed, writing stdout and stderr to files, and
    digests stdout, stderr, the exit code, and any output files or trees;
    an arm whose stdout, exit code, or output files differ from the first
    arm's is reported as differing, not failed (GNU and uutils differ on
    some inputs; a port must match the Rust arm). Stderr is compared on its
    own, since GNU names itself by argv[0] (gsort:). --against FILE checks
    the first arm's digests against a saved results file;
  - then times N rounds; each round runs every binary once, in an order
    rotated by one each round, so no binary is always first after a wait;
  - reports the fastest of N and the median wall time, and the peak RSS
    (ru_maxrss of the process, from wait4).

Untimed setup (removing a previous output, rebuilding a tree that mv or rm
consumes) runs before each timed run. Results go to --json.
"""

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import statistics
import sys
import time

# ---------------------------------------------------------------------------
# Generators: ports of uucore/src/lib/features/benchmark.rs
# ---------------------------------------------------------------------------

MB = 1024 * 1024


def write_by_size(path, size_mb, avg_line_length):
    """text_data::generate_by_size, streamed. Byte p is a letter
    'a' + p % 26, except every (L+1)th, which is a newline; the pattern
    repeats every lcm(L+1, 26) bytes."""
    total = size_mb * MB
    period = (avg_line_length + 1) * 26 // math.gcd(avg_line_length + 1, 26)
    block = bytes(
        10 if p % (avg_line_length + 1) == avg_line_length else 97 + p % 26
        for p in range(period)
    )
    big = block * max(1, (4 * MB) // period)
    with open(path, "wb") as f:
        left = total
        while left >= len(big):
            f.write(big)
            left -= len(big)
        tail = (big * 2)[:left] if left else b""
        f.write(tail)
        last = tail[-1:] if tail else (big[-1:] if total else b"")
        if last != b"\n":
            f.write(b"\n")


def gen_by_lines(num_lines, avg_line_length):
    """text_data::generate_by_lines. A line depends only on line_num % 26
    (letters) and line_num % 40 (length), so the pattern repeats every
    520 lines."""
    cache = {}
    out = []
    for n in range(num_lines):
        key = (n % 26, n % 40)
        line = cache.get(key)
        if line is None:
            length = avg_line_length + max(0, n % 40 - 20)
            line = bytes(
                32 if (c > 0 and c % 8 == 0) else 97 + (n + c) % 26
                for c in range(length)
            ) + b"\n"
            cache[key] = line
        out.append(line)
    return b"".join(out)


def words_numbered(words, n):  # generate_data_from_words
    return "".join(f"{words[i % len(words)]}_{i % 1000:03}\n" for i in range(n)).encode()


def words_simple(words, n):  # generate_data_from_words_simple
    return "".join(f"{words[i % len(words)]}\n" for i in range(n)).encode()


def words_counter(words, n):  # generate_data_from_words_with_counter
    return "".join(f"{words[i % len(words)]}{i:04}\n" for i in range(n)).encode()


ASCII_WORDS = ["apple", "banana", "cherry", "date", "elderberry", "fig", "grape",
               "honeydew", "kiwi", "lemon", "mango", "nectarine", "orange", "papaya",
               "quince", "raspberry", "strawberry", "tangerine", "ugli", "vanilla",
               "watermelon", "xigua", "yellow", "zucchini", "avocado"]
ACCENTED_WORDS = ["café", "naïve", "résumé", "fiancé", "crème", "déjà", "façade",
                  "château", "élève", "côte", "über", "Müller", "schön", "Köln",
                  "Düsseldorf", "Österreich", "Zürich", "Mädchen", "Bär", "größer",
                  "niño", "señor", "año", "mañana", "español", "corazón", "María",
                  "José", "más", "también"]
MIXED_WORDS = ["apple", "café", "banana", "naïve", "cherry", "résumé", "date", "fiancé",
               "elderberry", "crème", "über", "grape", "Müller", "honeydew", "schön",
               "niño", "kiwi", "señor", "lemon", "año", "mango", "María", "orange",
               "José", "papaya"]
MIXED_LOCALE = ["zebra", "äpfel", "banana", "öl", "cat", "über", "dog", "zürich",
                "elephant", "café", "fish", "naïve", "grape", "résumé", "house", "piñata"]
GERMAN = ["Ärger", "Öffnung", "Über", "Zucker", "Bär", "Föhn", "Größe", "Höhe", "Käse",
          "Löwe", "Mädchen", "Nüsse", "Röntgen", "Schäfer", "Tür", "Würfel", "ä", "ö",
          "ü", "ß", "a", "o", "u", "s"]
CASE_WORDS = ["apple", "Apple", "APPLE", "banana", "Banana", "BANANA", "café", "Café",
              "CAFÉ", "über", "Über", "ÜBER"]


def ascii_data(n): return words_numbered(ASCII_WORDS, n)
def accented_data(n): return words_numbered(ACCENTED_WORDS, n)
def mixed_data(n): return words_numbered(MIXED_WORDS, n)
def mixed_locale_data(n): return words_counter(MIXED_LOCALE, n)
def german_data(n): return words_counter(GERMAN, n)
def case_data(n): return words_simple(CASE_WORDS, n)


def ascii_simple(n):  # generate_ascii_data_simple
    return "".join(f"line_{n - i - 1:06}\n" for i in range(n)).encode()


def sorted_lines(data):  # split on \n, drop empties, sort bytewise, rejoin
    lines = sorted(l for l in data.split(b"\n") if l)
    return b"".join(l + b"\n" for l in lines)


def presorted_chunks(data, k):  # sort_bench_merge's eight pre-sorted files
    lines = [l for l in data.split(b"\n") if l]
    per = len(lines) // k
    chunks = []
    for i in range(k):
        part = lines[i * per:(len(lines) if i == k - 1 else (i + 1) * per)]
        chunks.append(b"".join(l + b"\n" for l in sorted(part)))
    return chunks


# fs_tree ------------------------------------------------------------------

def touch(p):
    open(p, "wb").close()


def balanced_tree(base, depth, dirs, files):
    if depth == 0:
        return
    for i in range(files):
        touch(os.path.join(base, f"f{i}"))
    for d in range(dirs):
        sub = os.path.join(base, f"d{d}")
        os.mkdir(sub)
        balanced_tree(sub, depth - 1, dirs, files)


def wide_tree(base, files, dirs):
    for i in range(files):
        touch(os.path.join(base, f"f{i}"))
    for d in range(dirs):
        sub = os.path.join(base, f"d{d}")
        os.mkdir(sub)
        for i in range(5):
            touch(os.path.join(sub, f"f{i}"))


def deep_tree(base, depth, files):
    cur = base
    for level in range(depth):
        for i in range(files):
            touch(os.path.join(cur, f"f{i}"))
        if level < depth - 1:
            cur = os.path.join(cur, "d")
            os.mkdir(cur)


def mixed_tree(base):
    exts = ["txt", "log", "dat", "tmp", "bak", "cfg"]
    sizes = [0, 100, 1024, 10240]
    modes = [0o644, 0o755, 0o600, 0o444]
    for i, ext in enumerate(exts):
        for j, size in enumerate(sizes):
            p = os.path.join(base, f"mixed_file_{i}_{j}.{ext}")
            with open(p, "wb") as f:
                f.write(b"x" * size)
            os.chmod(p, modes[(i + j) % 4])
    for i in range(5):
        sub = os.path.join(base, f"mixed_subdir_{i}")
        os.mkdir(sub)
        for j in range(3):
            with open(os.path.join(sub, f"sub_file_{j}.txt"), "w") as f:
                f.write(f"File {j} in subdir {i}\n")


def ls_mixed_tree(base):
    mixed_tree(base)
    for i in range(10):
        sub = os.path.join(base, f"mixed_branch_{i}")
        os.mkdir(sub)
        mixed_tree(sub)


# Bench-specific generators ---------------------------------------------------

def tsort_linear(n):
    return "".join(f"node{i} node{i + 1}\n" for i in range(max(0, n - 1))).encode()


def tsort_tree(depth, b):
    out, node_id = [], 0
    for level in range(depth):
        at = b ** level
        for parent in range(at):
            for child in range(b):
                if level + 1 < depth:
                    out.append(f"node{node_id + parent} node{node_id + at + parent * b + child}\n")
        node_id += at
    return "".join(out).encode()


def tsort_complex(n):
    out = []
    levels = max(int(math.sqrt(n)), 4)
    per = n // levels
    for level in range(levels - 1):
        sc, sn = level * per, (level + 1) * per
        ec, en = min((level + 1) * per, n), min((level + 2) * per, n)
        for i in range(sc, ec):
            for j in range(min(i % 3 + 1, en - sn)):
                out.append(f"node{i} node{sn + (i + j) % (en - sn)}\n")
    return "".join(out).encode()


def tsort_wide(n):
    out = []
    chains = max(n // 50, 5)
    length = n // chains
    for c in range(chains):
        start, end = c * length, min((c + 1) * length, n)
        for i in range(start, max(0, end - 1)):
            out.append(f"chain{c}_{i - start} chain{c}_{i + 1 - start}\n")
        if c > 0 and c % 3 == 0:
            p = c - 1
            pend = min(p * length + length // 2, n - 1)
            mid = start + length // 4
            out.append(f"chain{p}_{pend - p * length} chain{c}_{mid - start}\n")
    return "".join(out).encode()


def uniq_dups(groups, per):
    out = []
    for g in range(groups):
        line = (f"Line content for group {g:06} with additional text to make it "
                f"more realistic for testing performance\n")
        out.append(line * per)
    return "".join(out).encode()


def uniq_case(n):
    words = ["Hello", "WORLD", "Testing", "UNIQ", "Benchmark", "Performance"]
    out = []
    for i in range(n):
        w = words[(i // 50) % len(words)]
        m = i % 4
        if m == 0:
            v = w.lower()
        elif m == 1:
            v = w.upper()
        elif m == 2:
            v = w
        else:
            v = "".join(c.lower() if k % 2 == 0 else c.upper() for k, c in enumerate(w))
        out.append(v + "\n")
    return "".join(out).encode()


def unexpand_text(n):
    return b"".join(b" " * ((i % 4 + 1) * 4) + b"This is a line of text with leading spaces\n"
                    for i in range(n))


def ptx_fixed(n):
    return gen_by_lines(n, max(1024 * 1024 // n, 1))


PTX_TEX = ["the permuted index of \\alpha sorted around each keyword",
           "context $x$ lines paired with file_name and A&B output",
           "roughly 50% of {group} entries escaped as #1 or x_1 here",
           "each \\ref and $y$ carries a file_name style suffix too",
           "sorted A&B context around 90% of the {group} keywords",
           "index entries with x_1 and #1 spread across the \\alpha line"]


def shared_prefix(n):
    prefix = "/srv/data/2026/09/03/node-07/service/events/request-"
    s, out = 0x9E3779B9, []
    for _ in range(n):
        s ^= (s << 13) & 0xFFFFFFFF
        s ^= s >> 17
        s ^= (s << 5) & 0xFFFFFFFF
        out.append(f"{prefix}{s:08x}.json\n")
    return "".join(out).encode()


def general_numeric(n):
    out = []
    for i in range(n):
        sign = "" if i % 2 == 0 else "-"
        out.append(f"{sign}{(i * 13) % 100_000}.{(i * 7) % 1000:03}e{(i % 5) - 2:+}\n")
    return "".join(out).encode()


def key_field(n):
    words = ["café", "naïve", "apple", "über", "banana"]
    return "".join(f"{i % 100}\t{words[i % 5]}\t{(i * 7) % 100}\n" for i in range(n)).encode()


# ---------------------------------------------------------------------------
# Inputs: each is (kind, key, builder). Files are cached under WORK/inputs.
# ---------------------------------------------------------------------------

def F(key, fn):  # a file whose bytes fn() returns
    return ("file", key, fn)


def S(key, size_mb, avg):  # a generate_by_size file, streamed
    return ("write", key, lambda p: write_by_size(p, size_mb, avg))


def T(key, fn):  # a directory tree fn(path) builds
    return ("tree", key, fn)


def BIN(size_mb, byte=b"x"):  # binary_data::create_file
    return ("write", f"bin_{size_mb}m_{byte[0]:02x}",
            lambda p: _write_repeat(p, byte * MB, size_mb))


def _write_repeat(p, block, times):
    with open(p, "wb") as f:
        for _ in range(times):
            f.write(block)


def date_lines(text, n=1000):
    return lambda: (text + "\n").encode() * n


# ---------------------------------------------------------------------------
# The benches
# ---------------------------------------------------------------------------
#
# Fields:
#   name    the divan bench name (args appended as divan shows them)
#   util    the utility
#   args    argv after the utility; {in}, {in2}, ... name inputs, {out} an
#           output file, {outdir} an output directory, {tree} a tree input
#   inputs  dict placeholder -> input spec
#   stdin   placeholder of an input file given as stdin
#   stdout  "file" (a regular file, truncated each run) or "null" (/dev/null)
#   env     extra environment (LC_ALL as the bench's main() sets it)
#   reps    the call runs this many times per sample (in-process loops)
#   calls   fn(ctx) -> list of argvs, all run in one sample (mv, rm per file)
#   prep    untimed per-run setup: "rm_out", "fresh_outdir", or fn(ctx)
#   outs    what else to digest: "out" (file), "outdir"/"dest" (tree)
#   check   "exact" | "sorted" (shuf: sorted stdout) | "exit" (exit code only)
#   note    how this differs from the Rust bench, if it does


class Bench:
    def __init__(self, name, util, args=(), inputs=None, stdin=None, stdout="file",
                 env=None, reps=1, calls=None, prep=None, outs=(), check="exact",
                 note="", cwd_deep=None, tree_mtime=False):
        self.__dict__.update(locals())
        del self.__dict__["self"]
        self.inputs = inputs or {}
        self.env = env or {}


B = []

def add(*a, **k):
    B.append(Bench(*a, **k))


# base64 -------------------------------------------------------------------
B64 = S("by_size_100m_80", 100, 80)
add("b64_encode_synthetic", "base64", ["{in}"], {"in": B64},
    note="Rust: 5000 MB input, but its tempdir is dropped before timing, so "
         "uumain gets a missing file; here 100 MB, the intent.")
add("b64_decode_synthetic", "base64", ["-d", "{in}"],
    {"in": ("write", "b64_of_by_size_100m", lambda p: _b64_of(p, B64))},
    note="Rust decodes an empty file (its setup call fails); here the "
         "base64 of the 100 MB input, the intent.")
add("b64_decode_ignore_garbage_synthetic", "base64", ["-d", "-i", "{in}"],
    {"in": ("write", "b64_of_by_size_100m", lambda p: _b64_of(p, B64))},
    note="as b64_decode_synthetic")

# basenc -------------------------------------------------------------------
A5 = F("a5_16m", lambda: b"\xa5" * (16 * MB))
add("base16_encode_to_dev_null", "basenc", ["--base16", "{in}"], {"in": A5}, stdout="null")
add("base16_encode_to_file", "basenc", ["--base16", "{in}"], {"in": A5})

# cat ----------------------------------------------------------------------
for n in (10_000, 10_000_000):
    add(f"cat_default/{n}", "cat", ["{in}"], {"in": F(f"a_{n}", lambda n=n: b"a" * n)})

# cksum --------------------------------------------------------------------
CK = S("by_size_100m_80", 100, 80)
for algo, length in [("sysv", None), ("bsd", None), ("crc", None), ("crc32b", None),
                     ("md5", None), ("sha1", None), ("sha2", "256"), ("sha3", "256"),
                     ("blake2b", None), ("sm3", None), ("sha224", None), ("sha256", None),
                     ("sha384", None), ("sha512", None), ("blake3", None)]:
    a = ["--algorithm", algo] + (["--length", length] if length else []) + ["{in}"]
    add(f"cksum_{algo}", "cksum", a, {"in": CK})
add("cksum_shake128", "cksum", ["--algorithm", "shake128", "--length", "256", "{in}"],
    {"in": CK}, note="Rust hashes in memory through uucore::sum, not uumain; here the CLI.")
add("cksum_shake256", "cksum", ["--algorithm", "shake256", "--length", "512", "{in}"],
    {"in": CK}, note="as cksum_shake128")
add("cksum_default", "cksum", ["{in}"], {"in": CK})
add("cksum_raw_output", "cksum", ["--raw", "{in}"], {"in": CK})
add("cksum_multiple_files", "cksum", ["{in}", "{in2}", "{in3}"],
    {"in": S("by_size_50m_80_a", 50, 80), "in2": S("by_size_50m_80_b", 50, 80), "in3": S("by_size_50m_80_c", 50, 80)})

# cp -----------------------------------------------------------------------
BAL = T("balanced_5_4_10", lambda p: balanced_tree(p, 5, 4, 10))
add("cp_recursive_balanced_tree/(5,4,10)", "cp", ["-R", "{tree}", "{dest}"], {"tree": BAL},
    prep="rm_dest", outs=["dest"])
add("cp_archive_balanced_tree/(5,4,10)", "cp", ["-a", "{tree}", "{dest}"], {"tree": BAL},
    prep="rm_dest", outs=["dest"], tree_mtime=True)
add("cp_recursive_wide_tree/(6000,800)", "cp", ["-R", "{tree}", "{dest}"],
    {"tree": T("wide_6000_800", lambda p: wide_tree(p, 6000, 800))}, prep="rm_dest", outs=["dest"])
add("cp_recursive_deep_tree/(120,4)", "cp", ["-R", "{tree}", "{dest}"],
    {"tree": T("deep_120_4", lambda p: deep_tree(p, 120, 4))}, prep="rm_dest", outs=["dest"])
add("cp_preserve_metadata/(5,4,10)", "cp", ["-R", "--preserve=mode,timestamps", "{tree}", "{dest}"],
    {"tree": BAL}, prep="rm_dest", outs=["dest"], tree_mtime=True)
add("cp_large_file/16", "cp", ["{in}", "{dest}"], {"in": BIN(16)}, prep="rm_dest", outs=["dest"])

# csplit -------------------------------------------------------------------
L100K = F("by_lines_100000_80", lambda: gen_by_lines(100_000, 80))
add("csplit_line_number", "csplit", ["-f", "{outdir}/xx", "{in}", "10000", "50000", "90000"],
    {"in": L100K}, prep="fresh_outdir", outs=["outdir"])
add("csplit_regex_pattern", "csplit", ["-f", "{outdir}/xx", "{in}", "/^SECTION/", "{*}"],
    {"in": F("csplit_sections", lambda: "".join(
        f"SECTION {i}\n" if (i % 10_000 == 0 and i > 0) else f"line {i} with some content to process\n"
        for i in range(100_000)).encode())}, prep="fresh_outdir", outs=["outdir"])

# cut ----------------------------------------------------------------------
add("cut_bytes", "cut", ["-b", "1-20", "{in}"], {"in": L100K})
add("cut_characters", "cut", ["-c", "5-30", "{in}"], {"in": F("mixed_100000", lambda: mixed_data(100_000))})
add("cut_characters_long_lines", "cut", ["-c", "20-70", "{in}"],
    {"in": F("cut_long", lambda: "".join(f"{'aéiöu' * 16}école-piñata-{i:05}-Straße-\n"
                                         for i in range(40_000)).encode())})
add("cut_fields_tab", "cut", ["-f", "2,4", "{in}"],
    {"in": F("cut_tab", lambda: "".join(f"field1\tfield2_{i}\tfield3\tfield4\tfield5\n"
                                        for i in range(100_000)).encode())})
add("cut_fields_custom_delim", "cut", ["-d", ",", "-f", "1,3,5", "{in}"],
    {"in": F("cut_comma", lambda: "".join(f"apple,banana_{i},cherry,date,elderberry\n"
                                          for i in range(100_000)).encode())})
add("cut_fields_newline_delim", "cut", ["-d", "\n", "-f", "1,3,5", "{in}"],
    {"in": F("cut_nl", lambda: "".join(f"field_content_number_{i}\n"
                                       for i in range(100_000)).encode())})

# date ---------------------------------------------------------------------
ISO = F("dates_iso_1000", date_lines("2023-05-10 12:00:00"))
add("file_iso_dates", "date", ["-f", "{in}"], {"in": ISO})
add("file_tz_abbreviations", "date", ["-f", "{in}"],
    {"in": F("dates_est_1000", date_lines("2023-05-10 12:00:00 EST"))})
add("file_custom_format", "date", ["-f", "{in}", "+%A %d %B %Y"], {"in": ISO})
add("single_date_now", "date", [], check="exit")
add("complex_relative_date", "date", ["--date=last friday 12:00 + 2 days"], check="exit",
    note="output depends on today; exit code only")
add("file_localized_names", "date", ["-f", "{in}", "+%A %a %B %b"], {"in": ISO},
    env={"LC_ALL": "fr_FR.UTF-8"})

# dd -----------------------------------------------------------------------
for name, mb, ops in [("dd_copy_default", 32, []), ("dd_copy_4k_blocks", 24, ["bs=4K"]),
                      ("dd_copy_64k_blocks", 64, ["bs=64K"]), ("dd_copy_1m_blocks", 128, ["bs=1M"]),
                      ("dd_copy_separate_blocks", 48, ["ibs=8K", "obs=16K"]),
                      ("dd_copy_partial", 32, ["bs=4K", "count=1024"]),
                      ("dd_copy_with_skip", 48, ["bs=4K", "skip=256"]),
                      ("dd_copy_with_seek", 48, ["bs=4K", "seek=256"]),
                      ("dd_copy_8k_blocks", 32, ["bs=8K"])]:
    add(name, "dd", ["if={in}", "of={dest}"] + ops + ["status=none"], {"in": BIN(mb)},
        prep="rm_dest", outs=["dest"])

# df -----------------------------------------------------------------------
DF_DEPTH = 20000 if sys.platform != "darwin" else 2000
add("df_deep_directory", "df", [], {"tree": ("deepcwd", f"deep_cwd_{DF_DEPTH}", DF_DEPTH)},
    cwd_deep=DF_DEPTH, check="exit",
    note="run from a directory 20000 deep (Rust); on macOS 2000 deep, since APFS makes "
         "each level slower than the last (8000 levels take 170 s). Exit code only: "
         "free space changes between runs.")

# du -----------------------------------------------------------------------
WIDE5K = T("wide_5000_500", lambda p: wide_tree(p, 5000, 500))
add("du_wide_tree/(5000,500)", "du", ["{tree}"], {"tree": WIDE5K})
add("du_all_wide_tree/(5000,500)", "du", ["-a", "{tree}"], {"tree": WIDE5K})
add("du_deep_tree/(100,3)", "du", ["{tree}"], {"tree": T("deep_100_3", lambda p: deep_tree(p, 100, 3))})
add("du_summarize_balanced_tree/(5,4,10)", "du", ["-s", "{tree}"], {"tree": BAL})

# echo, true, false ----------------------------------------------------------
add("echo_consecutive_calls", "echo", ["Hello World"], reps=100)
add("true_consecutive_calls", "true", [], reps=100)
add("false_consecutive_calls", "false", [], reps=100)

# expand, unexpand -------------------------------------------------------------
add("expand_many_lines/100000", "expand", ["{in}"],
    {"in": F("expand_100000", lambda: "".join(f"line{i}\tvalue{i * 2}\tdata{i * 3}\n"
                                              for i in range(100_000)).encode())})
add("expand_custom_tabstops/50000", "expand", ["--tabs=4,8,12", "{in}"],
    {"in": F("expand_tabs_50000", lambda: "".join(f"a\tb\tc\td\te{i}\n"
                                                  for i in range(50_000)).encode())})
add("unexpand_many_lines/100000", "unexpand", ["{in}"],
    {"in": F("unexpand_100000", lambda: unexpand_text(100_000))})
add("unexpand_large_file/10", "unexpand", ["{in}"],
    {"in": F("unexpand_10m", lambda: unexpand_text(10 * MB // 50))})

# expr ---------------------------------------------------------------------
add("expr_index_no_match", "expr", ["index", "A" * 100_000, "B" * 100_000], check="exact")
add("expr_index_match_at_end", "expr", ["index", "A" * 100_000 + "Z", "Z" * 100_000])

# factor -------------------------------------------------------------------
add("factor_multiple_u64s/2", "factor", [str(n) for n in range(2, 2503)],
    note="Rust calls uumain 2501 times, one number each; here one process with "
         "2501 numbers (the per-call cost is what true/false/echo measure).")
add("factor_large_u64_prime", "factor", ["18446744073709551557"])
add("factor_64bit_semiprime", "factor", ["18446743979220271189"])
for name, num in [
    ("factor_three_39_bit_primes", "148322726715648124896087586879631159"),
    ("factor_five_38_bit_primes", "1569275491456096801522790424087360918295323588350447935207"),
    ("factor_thirteen_39_bit_primes", "256192672085272469290287843204387360975152374284235599731951768269391636066386517575760286247162035537155995319918598846421204855240141082924971355328149"),
    ("factor_a_prime_to_the_seventh", "56539106683390492137844827055225747632151249167945695848217966183182073341"),
    ("factor_small_factors_and_a_large_prime", "488107430943668296195870985548628140589274519139277715139461120"),
    ("factor_a_1279_bit_prime", "10407932194664399081925240327364085538615262247266704805319112350403608059673360298012239441732324184842421613954281007791383566248323464908139906605677320762924129509389220345773183349661583550472959420547689811211693677147548478866962501384438260291732348885311160828538416585028255604666224831890918801847068222203140521026698435488732958028878050869736186900714720710555703168729087"),
]:
    add(f"hard::{name}", "factor", [num])

# fold ---------------------------------------------------------------------
add("fold_many_lines/100000", "fold", ["{in}"],
    {"in": F("fold_100000", lambda: "".join(
        f"This is a very long line number {i} that definitely needs to be folded at the default width of 80 columns\n"
        for i in range(100_000)).encode())})
add("fold_custom_width/50000", "fold", ["-w", "40", "{in}"],
    {"in": F("fold_50000", lambda: "".join(
        f"Line {i} with enough text to exceed width 40 characters and require folding\n"
        for i in range(50_000)).encode())})

# hostname -----------------------------------------------------------------
add("hostname_ip_lookup/100000", "hostname", ["-i"], check="exit",
    note="Rust uses a 100k-line hosts file only under LD_PRELOAD nss_wrapper (Linux); "
         "on macOS -i fails to resolve and exits 1.")
add("hostname_basic", "hostname", [])
# socket_addrs_direct times std::net::ToSocketAddrs, no utility: not ported.

# join ---------------------------------------------------------------------
def join_pair(fmt1, fmt2, n):
    return (lambda: "".join(fmt1(i) for i in range(n)).encode(),
            lambda: "".join(fmt2(i) for i in range(n)).encode())
j1, j2 = join_pair(lambda i: f"{i:08} field1_{i} field2_{i}\n", lambda i: f"{i:08} data1_{i} data2_{i}\n", 10_000)
JF = {"in": F("join_full_1", j1), "in2": F("join_full_2", j2)}
add("join_full_match", "join", ["{in}", "{in2}"], JF)
p1, p2 = join_pair(lambda i: f"{i:08} f1_data_{i}\n", lambda i: f"{5000 + i:08} f2_data_{i}\n", 10_000)
add("join_partial_overlap", "join", ["{in}", "{in2}"], {"in": F("join_part_1", p1), "in2": F("join_part_2", p2)})
t1, t2 = join_pair(lambda i: f"{i:08}\tfield1_{i}\tfield2_{i}\n", lambda i: f"{i:08}\tdata1_{i}\tdata2_{i}\n", 10_000)
add("join_custom_separator", "join", ["-t", "\t", "{in}", "{in2}"], {"in": F("join_tab_1", t1), "in2": F("join_tab_2", t2)})
add("join_french_locale", "join", ["{in}", "{in2}"], JF, env={"LC_ALL": "fr_FR.UTF-8"})
ACC = ["àbc", "àbd", "abc", "abd", "èfg", "efg", "çar", "car", "öst", "ost"]
u1, u2 = join_pair(lambda i: f"{ACC[i % 10]}:{i:06} field1_{i}\n", lambda i: f"{ACC[i % 10]}:{i:06} data1_{i}\n", 1000)
add("join_unicode_locale", "join", ["{in}", "{in2}"], {"in": F("join_uni_1", u1), "in2": F("join_uni_2", u2)},
    env={"LC_ALL": "fr_FR.UTF-8"})

# ls -----------------------------------------------------------------------
LS = [("balanced_tree/(6,4,15)", T("balanced_6_4_15", lambda p: balanced_tree(p, 6, 4, 15)), None),
      ("wide_tree/(10000,1000)", T("wide_10000_1000", lambda p: wide_tree(p, 10000, 1000)), None),
      ("wide_tree/(15000,1500)", T("wide_15000_1500", lambda p: wide_tree(p, 15000, 1500)), "la"),
      ("deep_tree/(200,2)", T("deep_200_2", lambda p: deep_tree(p, 200, 2)), None),
      ("deep_tree/(100,4)", T("deep_100_4", lambda p: deep_tree(p, 100, 4)), "la"),
      ("mixed_tree", T("ls_mixed", ls_mixed_tree), None)]
add("ls_recursive_balanced_tree/(6,4,15)", "ls", ["-R", "{tree}"], {"tree": LS[0][1]})
add("ls_recursive_long_all_balanced_tree/(6,4,15)", "ls", ["-R", "-a", "-l", "{tree}"], {"tree": LS[0][1]})
add("ls_recursive_wide_tree/(10000,1000)", "ls", ["-R", "{tree}"], {"tree": LS[1][1]})
add("ls_recursive_long_all_wide_tree/(15000,1500)", "ls", ["-R", "-a", "-l", "{tree}"], {"tree": LS[2][1]})
add("ls_recursive_deep_tree/(200,2)", "ls", ["-R", "{tree}"], {"tree": LS[3][1]})
add("ls_recursive_long_all_deep_tree/(100,4)", "ls", ["-R", "-a", "-l", "{tree}"], {"tree": LS[4][1]})
add("ls_recursive_mixed_tree", "ls", ["-R", "{tree}"], {"tree": LS[5][1]})
add("ls_recursive_long_all_mixed_tree", "ls", ["-R", "-a", "-l", "{tree}"], {"tree": LS[5][1]})

# mv, rm (each sample consumes a fresh tree, built untimed) --------------------
def fresh(fn):
    def prep(ctx):
        d = ctx["scratch"]
        if os.path.exists(d):
            shutil.rmtree(d)
        os.makedirs(d)
        fn(d)
    return prep

def wide_n(n):
    return fresh(lambda d: wide_tree(d, n, 0))

def mv_dir_prep(d):
    os.mkdir(os.path.join(d, "src_tree"))
    balanced_tree(os.path.join(d, "src_tree"), 5, 5, 10)

def mvdest_prep(d):
    wide_tree(d, 1000, 0)
    os.mkdir(os.path.join(d, "dest"))

add("mv_single_file", "mv", calls=lambda c: [[f"{c['scratch']}/f{i}", f"{c['scratch']}/moved_{i}"] for i in range(1000)],
    prep=wide_n(1000), outs=["scratch"])
add("mv_multiple_to_dir", "mv", calls=lambda c: [[f"{c['scratch']}/f{i}" for i in range(1000)] + [f"{c['scratch']}/dest"]],
    prep=fresh(mvdest_prep), outs=["scratch"])
add("mv_directory", "mv", ["{scratch}/src_tree", "{scratch}/dest_tree"], prep=fresh(mv_dir_prep), outs=["scratch"])
add("mv_force_overwrite", "mv", calls=lambda c: [["-f", f"{c['scratch']}/f{i}", f"{c['scratch']}/f{i + 1000}"] for i in range(1000)],
    prep=wide_n(2000), outs=["scratch"])
add("rm_single_file", "rm", calls=lambda c: [[f"{c['scratch']}/f{i}"] for i in range(1000)],
    prep=wide_n(1000), outs=["scratch"])
add("rm_multiple_files", "rm", calls=lambda c: [[f"{c['scratch']}/f{i}" for i in range(1000)]],
    prep=wide_n(1000), outs=["scratch"])
add("rm_recursive_tree", "rm", ["-r", "{scratch}/test_tree"],
    prep=fresh(lambda d: (os.mkdir(f"{d}/test_tree"), balanced_tree(f"{d}/test_tree", 5, 5, 10))), outs=["scratch"])
add("rm_force_files", "rm", calls=lambda c: [["-f"] + [f"{c['scratch']}/f{i}" for i in range(1000)]],
    prep=wide_n(1000), outs=["scratch"])

# nl -----------------------------------------------------------------------
add("nl_many_lines/100000", "nl", ["{in}"], {"in": L100K})
add("nl_large_file/10", "nl", ["-ba", "{in}"], {"in": S("by_size_10m_80", 10, 80)})

# numfmt -------------------------------------------------------------------
NUMS = [str(n) for n in range(1, 10_001)]
add("numfmt_to_si/10000", "numfmt", ["--to=si"] + NUMS)
add("numfmt_to_si_precision/10000", "numfmt", ["--to=si", "--format=%.6f"] + NUMS)
add("numfmt_to_iec/10000", "numfmt", ["--to=iec"] + NUMS)
add("numfmt_from_si/10000", "numfmt", ["--from=si"] + [f"{n}K" for n in range(1, 10_001)])
add("numfmt_large_numbers_si/10000", "numfmt", ["--to=si"] + [str(((n % 9) + 1) * 1_000_000) for n in range(1, 10_001)])
add("numfmt_padding/(10000,50)", "numfmt", ["--to=si", "--padding=50"] + NUMS)
for mode in ("up", "down", "towards-zero"):
    add(f"numfmt_round_modes/({mode},10000)", "numfmt", ["--to=si", f"--round={mode}"] + NUMS)
NSTREAM = F("numfmt_stream", lambda: "".join(f"{n * 7919}\n" for n in range(1, 100_001)).encode())
add("numfmt_stream_to_si", "numfmt", ["--to=si"], {"in": NSTREAM}, stdin="in", stdout="null")
add("numfmt_stream_to_si_precision", "numfmt", ["--to=si", "--format=%.2f"], {"in": NSTREAM}, stdin="in", stdout="null")

# od -----------------------------------------------------------------------
OD = F("od_1m", lambda: bytes(i % 256 for i in range(256)) * 4096)
add("od_default", "od", ["{in}"], {"in": OD})
add("od_hex_bytes", "od", ["-t", "x1", "{in}"], {"in": OD})
add("od_chars", "od", ["-c", "{in}"], {"in": OD})

# ptx ----------------------------------------------------------------------
add("ptx_short_lines/100000", "ptx", ["{in}"], {"in": L100K})
add("ptx_long_lines/100", "ptx", ["{in}"], {"in": F("ptx_fixed_100", lambda: ptx_fixed(100))})
add("ptx_input_references_short_lines/100000", "ptx", ["-r", "{in}"], {"in": L100K})
add("ptx_input_references_long_lines/1000", "ptx", ["-r", "{in}"], {"in": F("ptx_fixed_1000", lambda: ptx_fixed(1000))})
add("ptx_tex/10000", "ptx", ["-T", "{in}"], {"in": F("ptx_tex_10000", lambda: words_numbered(PTX_TEX, 10_000))})

# seq ----------------------------------------------------------------------
add("seq_integers", "seq", ["1", "1000000"])
add("seq_large_integers", "seq", ["4e10003", "4e10003"])
add("seq_custom_separator", "seq", ["-s", ",", "1", "1000000"])
add("seq_with_step", "seq", ["1", "2", "1000000"])
add("seq_formatted", "seq", ["-f", "%.3f", "1", "0.1", "10000"])

# shuf (random output: compare sorted stdout) --------------------------------
for n, l in [(100_000, 80), (100_000, 10)]:
    add(f"shuf_lines/({n},{l})", "shuf", ["{in}"], {"in": F(f"by_lines_{n}_{l}", lambda n=n, l=l: gen_by_lines(n, l))},
        check="sorted")
add("shuf_input_range/1000000", "shuf", ["-i", "1-1000000"], check="sorted")
for h, l in [(50_000, 80), (50_000, 10)]:
    add(f"shuf_repeat_sampling/({h},{l})", "shuf", ["-r", "-n", str(h), "{in}"],
        {"in": F(f"by_lines_10000_{l}", lambda l=l: gen_by_lines(10_000, l))}, check="lines")

# sort (sort_bench.rs: default environment) -----------------------------------
SORT = [("sort_ascii_only", [], F("ascii_500000", lambda: ascii_data(500_000))),
        ("sort_accented_data", [], F("accented_500000", lambda: accented_data(500_000))),
        ("sort_mixed_data", [], F("mixed_500000", lambda: mixed_data(500_000))),
        ("sort_case_sensitive", [], F("case_500000", lambda: case_data(500_000))),
        ("sort_case_insensitive", ["-f"], F("case_500000", lambda: case_data(500_000))),
        ("sort_dictionary_order", ["-d"], F("mixed_500000", lambda: mixed_data(500_000))),
        ("sort_numeric", ["-n"], F("sort_numeric_500000", lambda: "".join(
            f"value_{(i * 13) % 10000}\n" for i in range(500_000)).encode())),
        ("sort_general_numeric/200000", ["-g"], F("sort_g_200000", lambda: general_numeric(200_000))),
        ("sort_reverse_locale", ["-r"], F("accented_500000", lambda: accented_data(500_000))),
        ("sort_key_field", ["-k", "2"], F("sort_key_500000", lambda: key_field(500_000))),
        ("sort_unique_locale", ["-u"], F("accented_500000", lambda: accented_data(500_000)))]
for name, flags, inp in SORT:
    add(name if "/" in name else f"{name}/500000", "sort", flags + ["-o", "{out}", "{in}"], {"in": inp}, outs=["out"])
add("sort_long_line/10000", "sort", ["{in}", "{in2}", "-o", "{out}"],
    {"in": F("b_10000_nl", lambda: b"b" * 10_000 + b"\n"), "in2": F("a_10000_nl", lambda: b"a" * 10_000 + b"\n")},
    outs=["out"])

def merge_inputs(prefix):
    return {f"m{i}": F(f"{prefix}_{i}", lambda i=i: presorted_chunks(ascii_data(500_000), 8)[i]) for i in range(8)}

MERGE = merge_inputs("merge8_ascii_500000")
MERGE_ARGS = ["-m", "-o", "{out}"] + [f"{{m{i}}}" for i in range(8)]
add("merge_pre_sorted_files", "sort", MERGE_ARGS, MERGE, outs=["out"])

# sort_locale_c_bench.rs: LC_ALL=C
C = {"LC_ALL": "C"}
add("sort_ascii_c_locale", "sort", ["-o", "{out}", "{in}"], {"in": F("ascii_simple_2000000", lambda: ascii_simple(2_000_000))}, env=C, outs=["out"])
add("sort_mixed_c_locale", "sort", ["-o", "{out}", "{in}"], {"in": F("mixed_locale_50000", lambda: mixed_locale_data(50_000))}, env=C, outs=["out"])
add("sort_german_c_locale", "sort", ["-o", "{out}", "{in}"], {"in": F("german_50000", lambda: german_data(50_000))}, env=C, outs=["out"])
add("sort_shared_prefix_c_locale", "sort", ["--parallel=1", "-o", "{out}", "{in}"], {"in": F("shared_prefix_500000", lambda: shared_prefix(500_000))}, env=C, outs=["out"])

# sort_locale_de_bench.rs: LC_ALL=de_DE.UTF-8
add("sort_german_de_locale", "sort", ["-o", "{out}", "{in}"], {"in": F("german_50000", lambda: german_data(50_000))},
    env={"LC_ALL": "de_DE.UTF-8"}, outs=["out"])

# sort_locale_utf8_bench.rs: LC_ALL=en_US.UTF-8
U = {"LC_ALL": "en_US.UTF-8"}
ML = F("mixed_locale_50000", lambda: mixed_locale_data(50_000))
add("sort_ascii_utf8_locale", "sort", ["-o", "{out}", "{in}"], {"in": F("ascii_simple_1500000", lambda: ascii_simple(1_500_000))}, env=U, outs=["out"])
add("sort_mixed_utf8_locale", "sort", ["-o", "{out}", "{in}"], {"in": ML}, env=U, outs=["out"])
add("sort_numeric_utf8_locale", "sort", ["-n", "-o", "{out}", "{in}"],
    {"in": F("desc_50000", lambda: "".join(f"{50_000 - i}\n" for i in range(50_000)).encode())}, env=U, outs=["out"])
add("sort_reverse_utf8_locale", "sort", ["-r", "-o", "{out}", "{in}"], {"in": ML}, env=U, outs=["out"])
add("sort_unique_utf8_locale", "sort", ["-u", "-o", "{out}", "{in}"], {"in": ML}, env=U, outs=["out"])
add("sort_very_long_lines_utf8_locale", "sort", ["--parallel", "1", "-o", "{out}", "{in}"],
    {"in": F("letters_1m_lines", lambda: b"".join(bytes([c]) * 1_000_000 + b"\n" for c in range(97, 123)))}, env=U, outs=["out"])
add("sort_long_common_prefix_utf8_locale", "sort", ["--parallel", "1", "-o", "{out}", "{in}"],
    {"in": F("prefix16k", lambda: b"".join(b"x" * 16384 + bytes([c]) * 100 + b"\n" for c in range(97, 123)))}, env=U, outs=["out"])
add("merge_single_file_utf8_locale", "sort", ["-m", "-o", "{out}", "{in}"],
    {"in": F("ascii_simple_500000_sorted", lambda: sorted_lines(ascii_simple(500_000)))}, env=U, outs=["out"])
add("merge_pre_sorted_files_utf8_locale", "sort", MERGE_ARGS, MERGE, env=U, outs=["out"])
add("sort_spill_to_tmp_files_utf8_locale", "sort", ["--parallel", "1", "-S", "1M", "-o", "{out}", "{in}"],
    {"in": F("mixed_200000", lambda: mixed_data(200_000))}, env=U, outs=["out"])
add("check_sorted_utf8_locale", "sort", ["-c", "{in}"],
    {"in": ("sorted_by", "mixed_2500000_sorted_en_US", None)}, env=U,
    note="input: mixed_data(2.5M) sorted bytewise, then sorted by the first binary "
         "under en_US.UTF-8, as the Rust bench does with uumain")

# split --------------------------------------------------------------------
for name, flags, inp in [("split_lines", ["-l", "1000"], L100K),
                         ("split_bytes", ["-b", "100K"], S("by_size_10m_80", 10, 80)),
                         ("split_number_chunks", ["-n", "10"], L100K),
                         ("split_number_chunks_round_robin", ["-n", "r/10"], L100K),
                         ("split_numeric_suffix", ["-d", "-l", "500"], L100K)]:
    add(name, "split", flags + ["{in}", "{outdir}/x"], {"in": inp}, prep="fresh_outdir", outs=["outdir"])

# tee ----------------------------------------------------------------------
add("tee_stdin_file/10000000", "tee", [], {"in": F("a_10000000", lambda: b"a" * 10_000_000)}, stdin="in")

# timeout ------------------------------------------------------------------
add("timeout_quick_exit", "timeout", ["0.02", "true"], check="exit")
add("timeout_enforced", "timeout", ["0.02", "sleep", "0.2"], check="exit",
    note="the system sleep; exits 124")
for d in ("0.001", "0.005", "0.02"):
    add(f"timer_expiry_latency/{d}", "timeout", [d, "sleep", "5"], check="exit",
        note="Rust's child is the bench executable sleeping 5 s; here the system sleep")

# tr (stdin a 16 MB file, stdout /dev/null) ------------------------------------
TR = S("by_size_16m_80", 16, 80)
for name, a in [("tr_ascii_range_lower_to_upper", ["a-z", "A-Z"]), ("tr_single_char_replace", ["a", "b"]),
                ("tr_multi_char_translate", ["aeiou", "AEIOU"]), ("tr_delete_ascii_range", ["-d", "a-z"]),
                ("tr_delete_single_char", ["-d", "\\n"])]:
    add(name, "tr", a, {"in": TR}, stdin="in", stdout="null")

# tsort --------------------------------------------------------------------
add("tsort_linear_chain/1000000", "tsort", ["{in}"], {"in": F("tsort_linear_1000000", lambda: tsort_linear(1_000_000))})
add("tsort_tree_dag/(10,3)", "tsort", ["{in}"], {"in": F("tsort_tree_10_3", lambda: tsort_tree(10, 3))})
add("tsort_complex_dag/50000", "tsort", ["{in}"], {"in": F("tsort_complex_50000", lambda: tsort_complex(50_000))})
add("tsort_wide_dag/100000", "tsort", ["{in}"], {"in": F("tsort_wide_100000", lambda: tsort_wide(100_000))})

# uniq ---------------------------------------------------------------------
UD = F("uniq_1000x10", lambda: uniq_dups(1000, 10))
add("uniq_heavy_duplicates/10000", "uniq", ["{in}"], {"in": UD})
add("uniq_with_count/10000", "uniq", ["-c", "{in}"], {"in": F("uniq_100x100", lambda: uniq_dups(100, 100))})
add("uniq_case_insensitive/10000", "uniq", ["-i", "{in}"], {"in": F("uniq_case_10000", lambda: uniq_case(10_000))})
for w in ("1", "512"):
    add(f"uniq_check_chars/(10000,{w})", "uniq", ["-w", w, "{in}"], {"in": UD})

# wc (wc_bench.rs: LC_ALL=C.UTF-8) ----------------------------------------------
W = {"LC_ALL": "C.UTF-8"}
add("wc_bytes_synthetic/1", "wc", ["-c", "{in}"], {"in": S("by_size_1m_80", 1, 80)}, env=W)
add("wc_bytes_synthetic/500", "wc", ["-c", "{in}"], {"in": S("by_size_500m_80", 500, 80)}, env=W)
add("wc_words_synthetic/2000", "wc", ["-w", "{in}"], {"in": S("by_size_2000m_80", 2000, 80)}, env=W)
add("wc_bytes_lines_synthetic/2000", "wc", ["-cl", "{in}"], {"in": S("by_size_2000m_80", 2000, 80)}, env=W)
add("wc_lines_variable_length/(50,500)", "wc", ["-l", "{in}"], {"in": S("by_size_50m_500", 50, 500)}, env=W)
add("wc_lines_large_line_count/500000", "wc", ["-l", "{in}"], {"in": F("by_lines_500000_80", lambda: gen_by_lines(500_000, 80))}, env=W)
add("wc_chars_large_line_count/100000", "wc", ["-m", "{in}"], {"in": L100K}, env=W)
add("wc_chars_utf8/100000", "wc", ["-m", "{in}"], {"in": F("wc_utf8_100000", lambda: "hello ä € 💩\n".encode() * 100_000)}, env=W)
add("wc_words_large_line_count/100000", "wc", ["-w", "{in}"], {"in": L100K}, env=W)
add("wc_default_large_line_count/100000", "wc", ["-lwc", "{in}"], {"in": L100K}, env=W)
add("wc_lines_extreme_line_lengths/(100000,200)", "wc", ["-l", "{in}"], {"in": F("by_lines_100000_200", lambda: gen_by_lines(100_000, 200))}, env=W)


# ---------------------------------------------------------------------------
# Building inputs
# ---------------------------------------------------------------------------

WORK = None
_first_binary = None


def _b64_of(path, src_spec):
    import base64
    src = input_path(src_spec)
    with open(src, "rb") as f:
        data = f.read()
    enc = base64.encodebytes(data)  # 76-column lines; base64 -d accepts any width
    with open(path, "wb") as f:
        f.write(enc)


def input_path(spec):
    kind, key, fn = spec
    d = os.path.join(WORK, "inputs")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, key)
    done = p + ".done"
    if os.path.exists(done):
        return p
    if os.path.lexists(p):
        rmtree_any(p)
    t0 = time.time()
    if kind == "write":
        fn(p)
    elif kind == "file":
        with open(p, "wb") as f:
            f.write(fn())
    elif kind == "tree":
        os.mkdir(p)
        fn(p)
    elif kind == "deepcwd":
        make_deep_cwd(p, fn)
    elif kind == "sorted_by":
        raw = os.path.join(d, "mixed_2500000_bytewise")
        with open(raw, "wb") as f:
            f.write(sorted_lines(mixed_data(2_500_000)))
        argv, _ = argv_for(_first_binary, "sort", ["-o", p, raw])
        rc, *_ = spawn(argv, None, "/dev/null", "/dev/null", dict(base_env(), LC_ALL="en_US.UTF-8"))
        if rc != 0:
            sys.exit(f"building {key}: sort exited {rc}")
    open(done, "w").close()
    log(f"  built {key} in {time.time() - t0:.1f} s")
    return p


def make_deep_cwd(p, depth):
    os.mkdir(p)
    fd = os.open(p, os.O_RDONLY)
    for _ in range(depth):
        os.mkdir("d", dir_fd=fd)
        nfd = os.open("d", os.O_RDONLY, dir_fd=fd)
        os.close(fd)
        fd = nfd
    os.close(fd)


def deep_fd(p, depth):
    fd = os.open(p, os.O_RDONLY)
    for _ in range(depth):
        nfd = os.open("d", os.O_RDONLY, dir_fd=fd)
        os.close(fd)
        fd = nfd
    return fd


def rmtree_any(p):
    if os.path.isdir(p) and not os.path.islink(p):
        shutil.rmtree(p)
    elif os.path.lexists(p):
        os.unlink(p)


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

def base_env():
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ.get("HOME", "/tmp"),
            "TZ": "UTC", "LANG": ARGS.lang, "TMPDIR": os.path.join(WORK, "tmp")}


def argv_for(binpath, util, args):
    if binpath.startswith("prefix:"):
        exe = binpath[len("prefix:"):] + util
        return [exe] + list(args), exe
    if os.path.isdir(binpath):
        exe = os.path.join(binpath, util)
        return [exe] + list(args), exe
    return [binpath, util] + list(args), binpath


def spawn(argv, stdin, stdout, stderr, env, cwd_fd=None):
    """posix_spawn one process; return (exit, wall_ns, maxrss_bytes)."""
    acts = [(os.POSIX_SPAWN_OPEN, 0, stdin or "/dev/null", os.O_RDONLY, 0),
            (os.POSIX_SPAWN_OPEN, 1, stdout, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644),
            (os.POSIX_SPAWN_OPEN, 2, stderr, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)]
    here = None
    if cwd_fd is not None:
        here = os.open(".", os.O_RDONLY)
        os.fchdir(cwd_fd)
    try:
        t0 = time.perf_counter_ns()
        pid = os.posix_spawn(argv[0], argv, env, file_actions=acts)
        _, status, ru = os.wait4(pid, 0)
        t1 = time.perf_counter_ns()
    finally:
        if here is not None:
            os.fchdir(here)
            os.close(here)
    rss = ru.ru_maxrss if sys.platform == "darwin" else ru.ru_maxrss * 1024
    return os.waitstatus_to_exitcode(status), t1 - t0, rss


def digest_file(p, mode="exact"):
    if not os.path.exists(p):
        return "missing"
    if mode == "sorted":
        with open(p, "rb") as f:
            return hashlib.sha256(b"\n".join(sorted(f.read().split(b"\n")))).hexdigest()[:16]
    if mode == "lines":
        with open(p, "rb") as f:
            return f"lines={f.read().count(b'\n')}"
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


def digest_tree(root, mtime=False):
    if not os.path.lexists(root):
        return "missing"
    if not os.path.isdir(root):
        st = os.lstat(root)
        return f"{digest_file(root)}:{oct(st.st_mode)}" + (f":{st.st_mtime_ns}" if mtime else "")
    h = hashlib.sha256()
    for d, dirs, files in os.walk(root):
        dirs.sort()
        rel = os.path.relpath(d, root)
        for name in sorted(files) + [""]:
            p = os.path.join(d, name) if name else d
            st = os.lstat(p)
            h.update(f"{rel}/{name}|{st.st_mode:o}|{st.st_size}".encode())
            if mtime:
                h.update(f"|{st.st_mtime_ns}".encode())
            if name and st.st_size:
                h.update(digest_file(p).encode())
    return h.hexdigest()[:16]


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def run_bench(b, binaries, rounds):
    rundir = os.path.join(WORK, "run", re.sub(r"[^\w.-]+", "_", b.name))
    rmtree_any(rundir)
    os.makedirs(rundir)
    ctx = {"out": f"{rundir}/out", "outdir": f"{rundir}/outdir", "dest": f"{rundir}/dest",
           "scratch": f"{rundir}/scratch"}
    for ph, spec in b.inputs.items():
        ctx[ph] = input_path(spec)
    cwd_fd = deep_fd(ctx["tree"], b.cwd_deep) if b.cwd_deep else None
    env = dict(base_env(), **b.env)
    os.makedirs(env["TMPDIR"], exist_ok=True)

    def prep():
        if b.prep == "rm_dest":
            rmtree_any(ctx["dest"])
        elif b.prep == "fresh_outdir":
            rmtree_any(ctx["outdir"])
            os.mkdir(ctx["outdir"])
        elif callable(b.prep):
            b.prep(ctx)

    def argvs():
        if b.calls:
            lists = b.calls(ctx)
        else:
            lists = [[a.format(**ctx) if "{" in a and a != "{*}" else a for a in b.args]] * b.reps
        return lists

    def one(binpath, stdout, stderr):
        total, rss, codes = 0, 0, []
        for a in argvs():
            argv, _ = argv_for(binpath, b.util, a)
            stdin = ctx[b.stdin] if b.stdin else None
            rc, ns, r = spawn(argv, stdin, stdout, stderr, env, cwd_fd)
            total += ns
            rss = max(rss, r)
            codes.append(rc)
        return total, rss, sorted(set(codes))

    res = {"name": b.name, "util": b.util, "env": b.env, "note": b.note, "per": {},
           "absent": [n for n, p in binaries if not os.access(argv_for(p, b.util, [])[1], os.X_OK)]}
    binaries = [(n, p) for n, p in binaries if n not in res["absent"]]
    if not binaries:
        return res
    # Verification run (also the warm-up): stdout and stderr to files.
    digests = {}
    for name, path in binaries:
        prep()
        so, se = f"{rundir}/stdout.{name}", f"{rundir}/stderr.{name}"
        ns, rss, codes = one(path, so, se)
        mode = b.check if b.check in ("sorted", "lines") else "exact"
        d = {"exit": codes}
        if b.check != "exit":
            d["stdout"] = digest_file(so, mode)
            d["stderr"] = digest_file(se)
            for o in b.outs:
                p = ctx[o]
                d[o] = digest_tree(p, b.tree_mtime) if os.path.isdir(p) or o != "out" else digest_file(p)
        digests[name] = d
        res["per"][name] = {"digest": d, "first_s": ns / 1e9}
    ref = next(iter(digests.values()))
    res["differs"] = {n: [k for k in d if k != "stderr" and d.get(k) != ref.get(k)]
                      for n, d in digests.items() if any(k != "stderr" and d.get(k) != ref.get(k) for k in d)}
    res["stderr_differs"] = [n for n, d in digests.items() if d.get("stderr") != ref.get("stderr")]
    res["same"] = not res["differs"]
    # Rounds, scaled down for slow benches.
    first = max(v["first_s"] for v in res["per"].values())
    n = rounds if first * rounds * len(binaries) <= ARGS.budget else max(ARGS.min_rounds, int(ARGS.budget / max(first * len(binaries), 1e-9)))
    times = {name: [] for name, _ in binaries}
    rsses = {name: 0 for name, _ in binaries}
    sink_out = "/dev/null" if b.stdout == "null" else f"{rundir}/stdout.timed"
    for r in range(n):
        order = binaries[r % len(binaries):] + binaries[:r % len(binaries)]
        for name, path in order:
            prep()
            ns, rss, _ = one(path, sink_out, f"{rundir}/stderr.timed")
            times[name].append(ns / 1e9)
            rsses[name] = max(rsses[name], rss)
    for name, _ in binaries:
        t = times[name]
        res["per"][name].update(min_s=min(t), median_s=statistics.median(t), rounds=n,
                                peak_rss_mb=rsses[name] / MB)
    if cwd_fd is not None:
        os.close(cwd_fd)
    if not ARGS.keep:
        rmtree_any(rundir)
    return res


def fmt_s(s):
    return f"{s * 1e3:.2f} ms" if s < 1 else f"{s:.3f} s"


ARGS = None


def main():
    global ARGS, WORK, _first_binary
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("binaries", nargs="*", help="NAME=PATH, PATH a multi-call binary or a directory of per-utility binaries")
    ap.add_argument("--only", help="regex on bench names or utility")
    ap.add_argument("--rounds", type=int, default=10)
    ap.add_argument("--min-rounds", type=int, default=3)
    ap.add_argument("--budget", type=float, default=30.0, help="seconds of timed runs per bench before rounds are cut (default 30)")
    ap.add_argument("--work", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "coreutils-bench"))
    ap.add_argument("--json", default="bench-results.json")
    ap.add_argument("--against", help="a results JSON whose digests every binary must match")
    ap.add_argument("--lang", default="en_US.UTF-8", help="LANG for every run (LC_ALL as each bench sets it)")
    ap.add_argument("--keep", action="store_true", help="keep each bench's run directory")
    ap.add_argument("--list", action="store_true")
    ARGS = ap.parse_args()
    benches = [b for b in B if not ARGS.only or re.search(ARGS.only, b.name) or re.fullmatch(ARGS.only, b.util)]
    if ARGS.list:
        for b in benches:
            print(f"{b.name}\t{b.util} {' '.join(a if len(a) < 40 else a[:12] + '...' for a in (b.args or ['<per-file calls>']))}"
                  f"{'  ' + str(b.env) if b.env else ''}")
        print(f"{len(benches)} benches", file=sys.stderr)
        return
    binaries = []
    for s in ARGS.binaries:
        name, _, path = s.partition("=")
        if not path:
            sys.exit(f"expected NAME=PATH, got {s}")
        if not path.startswith("prefix:"):
            path = os.path.abspath(os.path.expanduser(path))
        binaries.append((name, path))
    if not binaries:
        sys.exit("give at least one NAME=PATH")
    WORK = os.path.abspath(ARGS.work)
    os.makedirs(WORK, exist_ok=True)
    _first_binary = binaries[0][1]
    against = {}
    if ARGS.against:
        with open(ARGS.against) as f:
            for r in json.load(f)["results"]:
                against[r["name"]] = next(iter(r["per"].values()))["digest"]
    load0 = os.getloadavg()
    t0 = time.time()
    results = []
    for i, b in enumerate(benches):
        la = os.getloadavg()[0]
        log(f"[{i + 1}/{len(benches)}] {b.name} (load {la:.1f})")
        r = run_bench(b, binaries, ARGS.rounds)
        r["load"] = la
        if b.name in against and r["per"]:
            mine = next(iter(r["per"].values()))["digest"]
            r["matches_against"] = {k: v for k, v in mine.items() if k != "stderr"} == \
                {k: v for k, v in against[b.name].items() if k != "stderr"}
        results.append(r)
        cells = "  ".join(f"{n}: {fmt_s(v['min_s'])} min, {fmt_s(v['median_s'])} med, {v['peak_rss_mb']:.1f} MB"
                          for n, v in r["per"].items())
        flag = "".join(f"  {n} differs ({', '.join(k)})" for n, k in r.get("differs", {}).items())
        if not r.get("matches_against", True):
            flag += "  DIFFERS FROM --against"
        if r["absent"]:
            flag += f"  absent: {', '.join(r['absent'])}"
        log(f"    {cells}{flag}")
        with open(ARGS.json, "w") as f:
            json.dump({"binaries": dict(binaries), "load_start": load0, "results": results}, f, indent=1)
    load1 = os.getloadavg()
    meta = {"binaries": dict(binaries), "load_start": load0, "load_end": load1,
            "elapsed_s": time.time() - t0, "lang": ARGS.lang, "rounds": ARGS.rounds,
            "ncpu": os.cpu_count(), "results": results}
    with open(ARGS.json, "w") as f:
        json.dump(meta, f, indent=1)
    # Summary table
    names = [n for n, _ in binaries]
    print(f"| bench | util | " + " | ".join(f"{n} min | {n} median | {n} RSS MB" for n in names) +
          (" | " + " | ".join(f"{n} vs {names[0]}" for n in names[1:]) if len(names) > 1 else "") + " | output |")
    print("|---" * (2 + 3 * len(names) + max(0, len(names) - 1) + 1) + "|")
    for r in results:
        p = r["per"]
        row = [r["name"], r["util"]]
        for n in names:
            row += [fmt_s(p[n]["min_s"]), fmt_s(p[n]["median_s"]), f"{p[n]['peak_rss_mb']:.1f}"] if n in p else ["n/a"] * 3
        for n in names[1:]:
            if n not in p or names[0] not in p:
                row.append("n/a")
                continue
            if "exit" in r.get("differs", {}).get(n, []):
                row.append("n/a (exit differs)")
                continue
            a, c = p[names[0]]["min_s"], p[n]["min_s"]
            row.append(f"{(a / c - 1) * 100:.0f}% faster" if c < a else f"{(c / a - 1) * 100:.0f}% slower")
        out = "; ".join(f"{n} differs: {', '.join(k)}" for n, k in r.get("differs", {}).items()) or "same"
        if not r.get("matches_against", True):
            out += "; first arm differs from --against"
        row.append(out)
        print("| " + " | ".join(row) + " |")
    log(f"load average {load0[0]:.1f} at start, {load1[0]:.1f} at end; {len(results)} benches in {time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()
