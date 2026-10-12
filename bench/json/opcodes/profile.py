#!/usr/bin/env python3
"""Where std.json's cycles go, per corpus file (macOS: xctrace; Linux: perf).

usage: profile.py OUT FILES [VARIANT] [SECONDS]

Profiles OUT/FILE-VARIANT/prog (built by build.py with --dsym on macOS)
for about SECONDS (default 8) and charges each sample to the innermost
function of std/json.rig that its address belongs to, through the inlined
frames in the debug info (atos -i on macOS, perf's --inline srcline on
Linux). Prints one table: the share of samples per category per file.
"""
import collections, glob, os, platform, re, subprocess, sys, tempfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))

# The std/json.rig functions (their names in the emitted Zig) of each
# category. The first json function met walking out from the sample's
# innermost inlined frame decides it.
CATEGORIES = [
    ("string scan", "skip_plain_ascii special special64 first_marked64"),
    ("UTF-8", "utf8_end utf8_end3 plain"),
    ("escapes", "escaped escape unicode hex4 hex_value hex_error push_utf8 push_utf8_two3"),
    ("whitespace", "skip_space"),
    ("digits", "number take_digits take_last_digits eight_digits peek is_digit add_int"),
    ("float conversion", "decimal_to_float normal_float_bits eisel_lemire float_from_bits slow_float infinity add_float"),
    ("string end, tape", "string add_string"),
    ("structure", "document open close key scalar literal fail parse"),
]
CAT_OF = {fn: c for c, fns in CATEGORIES for fn in fns.split()}
ORDER = [c for c, _ in CATEGORIES] + ["other"]


def category(chain):
    """chain: function names, innermost first."""
    for fn in chain:
        m = re.match(r"json\.(?:Doc\.)?(\w+)", fn)
        if m and m.group(1) in CAT_OF:
            return CAT_OF[m.group(1)]
    return "other"


def runtime_leaf(chain):
    return bool(chain) and not chain[0].startswith("json.")


def mac_samples(exe, n):
    tmp = tempfile.mkdtemp(prefix="opprof-")
    trace = os.path.join(tmp, "t.trace")
    subprocess.run(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--output", trace,
                    "--launch", "--", exe, str(n)], capture_output=True, check=True, cwd=os.path.dirname(exe))
    x = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                        '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                       capture_output=True, check=True).stdout
    subprocess.run(["rm", "-rf", tmp])
    root = ET.fromstring(x)
    ids = {e.attrib["id"]: e for e in root.iter() if "id" in e.attrib}
    deref = lambda e: ids[e.attrib["ref"]] if "ref" in e.attrib else e
    addrs, load = collections.Counter(), None
    other = 0
    for row in root.iter("row"):
        bt = row.find("tagged-backtrace")
        if bt is None:
            bt = row.find("backtrace")
        if bt is None:
            continue
        fr = deref(bt).find("frame")
        if fr is None:
            continue
        fr = deref(fr)
        b = fr.find("binary")
        b = deref(b) if b is not None else None
        if b is None or b.attrib.get("name") != "prog":
            other += 1
            continue
        load = b.attrib["load-addr"]
        addrs[int(fr.attrib["addr"], 16)] += 1
    dwarf = glob.glob(exe + ".dSYM/Contents/Resources/DWARF/*")[0]
    chains = {}
    keys = sorted(addrs)
    for k in range(0, len(keys), 400):
        part = keys[k:k + 400]
        # Each address is followed by 0x1, outside the image, which atos
        # echoes as a bare line: the frames between two echoes are one
        # address's, innermost first.
        argv = []
        for a in part:
            argv += ["0x%x" % a, "0x1"]
        out = subprocess.run(["atos", "-o", dwarf, "-l", load, "-i"] + argv,
                             capture_output=True, text=True, check=True).stdout
        blocks, cur = [], []
        for l in out.splitlines():
            if l.strip() == "0x1":
                blocks.append(cur)
                cur = []
            elif l.strip():
                cur.append(re.sub(r" \(in .*", "", l))
        assert len(blocks) == len(part), (len(blocks), len(part))
        chains.update(zip(part, blocks))
    return [(chains[a], c) for a, c in addrs.items()], other


def linux_samples(exe, n):
    tmp = tempfile.mkdtemp(prefix="opprof-")
    data = os.path.join(tmp, "perf.data")
    subprocess.run(["perf", "record", "-F", "4000", "-o", data, "--", exe, str(n)],
                   capture_output=True, check=True)
    out = subprocess.run(["perf", "script", "-i", data, "-F", "ip,sym,dso", "--inline", "--no-demangle"],
                         capture_output=True, text=True, check=True).stdout
    subprocess.run(["rm", "-rf", tmp])
    samples, other = [], 0
    cur = None
    for line in out.splitlines():
        if not line.strip():
            continue
        m = re.match(r"\s*([0-9a-f]+) (\S.*?) \((.*)\)$", line)
        if m:
            if cur is not None:
                samples.append((cur, 1))
            cur = [m.group(2)] if m.group(3).endswith("/prog") else None
            if cur is None:
                other += 1
        elif cur is not None:
            cur.insert(-1, line.strip())  # inlined frames come innermost first
    if cur is not None:
        samples.append((cur, 1))
    return samples, other


def main():
    out, files = sys.argv[1], sys.argv[2].split(",")
    variant = sys.argv[3] if len(sys.argv) > 3 else "base"
    secs = float(sys.argv[4]) if len(sys.argv) > 4 else 8
    mac = platform.system() == "Darwin"
    table, rt = {}, {}
    for f in files:
        exe = os.path.join(os.path.abspath(out), "%s-%s" % (f, variant), "prog")
        t = subprocess.run([exe, "20"], capture_output=True, text=True).stdout.split()
        n = max(20, int(secs * 1e9 / (int(t[0]) / 20)))
        samples, other = (mac_samples if mac else linux_samples)(exe, n)
        cats, rts = collections.Counter(), collections.Counter()
        for chain, c in samples:
            k = category(chain)
            cats[k] += c
            if runtime_leaf(chain):
                rts[k] += c
        lines = collections.Counter()
        for chain, c in samples:
            lines[" < ".join(chain[:3])] += c
        if os.environ.get("LINES"):
            for k, v in lines.most_common(int(os.environ["LINES"])):
                print("  %5.1f%%  %s" % (100.0 * v / (sum(lines.values()) + other), k), file=sys.stderr)
        cats["other"] += other
        total = sum(cats.values())
        table[f] = {k: 100.0 * v / total for k, v in cats.items()}
        rt[f] = 100.0 * sum(rts.values()) / total
        table[f]["_n"] = total
        print("%s: %d samples" % (f, total), file=sys.stderr, flush=True)
    print("| category | " + " | ".join(files) + " |")
    print("|---|" + "---:|" * len(files))
    for k in ORDER:
        print("| %s | %s |" % (k, " | ".join("%.1f%%" % table[f].get(k, 0) for f in files)))
    print("| of which in the runtime (checks, pushes) | %s |" % " | ".join("%.1f%%" % rt[f] for f in files))
    print("| samples | %s |" % " | ".join("%d" % table[f]["_n"] for f in files))


main()
