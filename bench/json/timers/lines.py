#!/usr/bin/env python3
"""Where a program spends its time, by source line: samples from macOS
Instruments' Time Profiler, each charged to the line of its program
counter, through the inlined frames `atos -i` gives.

usage: lines.py [--top N] [--module FILE.zig] PROG ARGS...

It records `PROG ARGS...` with `xcrun xctrace record --template 'Time
Profiler'`, so the run should take a few seconds (thousands of samples),
then prints the lines with the most samples: each line's share, the
innermost frame's file:line, and the function it was inlined into. The
second table charges each sample to the innermost frame in the Zig of
the module `--module` names (default `json.zig`, std.json's for a
program built from `bench-json`'s copy), with the line of the `.rig`
source above it when the emitted line says. The program needs its debug
information: on macOS, the objects of its build, or a `.dSYM` beside it
(`dsymutil PROG` while they exist). macOS only.
"""
import collections, os, re, subprocess, sys, tempfile


def main():
    args = sys.argv[1:]
    top, module = 30, "json.zig"
    while args[:1] in (["--top"], ["--module"]):
        if args[0] == "--top":
            top = int(args[1])
        else:
            module = args[1]
        args = args[2:]
    if not args:
        sys.exit(__doc__)
    prog = os.path.abspath(args[0])
    with tempfile.TemporaryDirectory() as d:
        trace = os.path.join(d, "t.trace")
        subprocess.run(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--output", trace, "--launch", "--", prog] + args[1:],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                              '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                             capture_output=True, text=True, check=True).stdout
    load = None
    for m in re.finditer(r'<binary id="\d+"[^>]*load-addr="(0x[0-9a-f]+)" path="([^"]*)"', xml):
        if os.path.realpath(m.group(2)) == os.path.realpath(prog):
            load = m.group(1)
    if load is None:
        sys.exit("lines: no samples in %s" % prog)
    # Each sample row names its backtrace, by a definition or a reference
    # to one; a backtrace's first frame is the leaf, by a definition or a
    # reference to a frame.
    addr_of = {}
    for m in re.finditer(r'<frame id="(\d+)" name="[^"]*" addr="(0x[0-9a-f]+)"', xml):
        addr_of[m.group(1)] = m.group(2)
    leaf_of = {}
    for m in re.finditer(r'<tagged-backtrace id="(\d+)"[^>]*>.*?<frame (?:id|ref)="(\d+)"', xml, re.S):
        leaf_of[m.group(1)] = m.group(2)
    leaves = collections.Counter()
    for row in re.finditer(r"<row>.*?</row>", xml, re.S):
        m = re.search(r'<tagged-backtrace (?:id|ref)="(\d+)"', row.group(0))
        if m and leaf_of.get(m.group(1)) in addr_of:
            leaves[addr_of[leaf_of[m.group(1)]]] += 1
    addrs = list(leaves)
    out = subprocess.run(["atos", "-i", "-o", prog, "-l", load] + addrs, capture_output=True, text=True).stdout
    # `atos -i` prints each address's inlined frames, innermost first, then
    # a blank line.
    blocks = out.strip("\n").split("\n\n")
    lines = collections.Counter()
    own = collections.Counter()
    total = 0
    for a, block in zip(addrs, blocks):
        frames = [f for f in block.split("\n") if f.strip()]
        n = leaves[a]
        total += n
        loc = lambda f: (re.search(r"\(([^()]*:\d+)\)\s*$", f) or [None, "?"])[1]
        fn = lambda f: f.split(" (in ")[0]
        if frames:
            lines["%s  %s" % (loc(frames[0]), fn(frames[-1]))] += n
            mine = next((f for f in frames if re.search(r"\(%s:\d+\)" % re.escape(module), f)), None)
            own[loc(mine) if mine else "(outside the program's modules)"] += n
    in_prog = sum(lines.values())
    print("%d samples, %d in %s" % (sum(leaves.values()), in_prog, os.path.basename(prog)))
    print("\n| share | innermost line | function |\n|---:|---|---|")
    for k, n in lines.most_common(top):
        l, _, f = k.partition("  ")
        print("| %.1f%% | %s | %s |" % (100 * n / in_prog, l, f[:60]))
    print("\n| share | line of the program's modules |\n|---:|---|")
    for k, n in own.most_common(top):
        print("| %.1f%% | %s |" % (100 * n / in_prog, k))


if __name__ == "__main__":
    main()
