#!/usr/bin/env python3
"""Rename an enum tag or union field by what the Zig compiler says.

    tagrename.py OLD NEW [STEP...]     (run under cpuq; STEP = a zig build step)

The definition is renamed by hand first. Each round builds the steps
(default: install, test), reads every `error: ... no member named 'OLD'`
or `no field named 'OLD'`, and renames the identifier at that line and
column to NEW, until none is left. A use the compiler does not reach
(code no step builds) is not found; the tests run it.
"""
import os, re, subprocess, sys, tempfile

old, new = sys.argv[1], sys.argv[2]
steps = sys.argv[3:] or ["install", "test", "oracle"]
pat = re.compile(r"^(\S+?):(\d+):(\d+): error: .*?(?:no member named|no field named|no member or field named) '%s'" % re.escape(old))
jobs = os.environ.get("CPUQ_CORES", "2")
total = 0
for rnd in range(30):
    edits = {}
    for st in steps:
        cmd = ["zig", "build", st, "-j" + jobs]
        if st == "test":
            cmd += ["--cache-dir", tempfile.mkdtemp()]
        p = subprocess.run(cmd, capture_output=True, text=True)
        for line in p.stderr.split("\n"):
            m = pat.match(line)
            if m:
                edits.setdefault(m.group(1), set()).add((int(m.group(2)), int(m.group(3))))
    n = sum(len(v) for v in edits.values())
    if not n:
        break
    for f, places in edits.items():
        lines = open(f).read().split("\n")
        for ln, col in sorted(places, reverse=True):
            l = lines[ln - 1]
            assert l[col - 1:col - 1 + len(old)] == old, (f, ln, col, l)
            lines[ln - 1] = l[:col - 1] + new + l[col - 1 + len(old):]
        open(f, "w").write("\n".join(lines))
    total += n
    print("round %d: %d renamed" % (rnd, n))
print("%d renamed in all" % total)
