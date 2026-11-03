#!/usr/bin/env python3
"""Per-utility counts from a cargo test log of tests/tests.rs, and static
#[test] counts from tests/by-util and src/uu/*/src."""
import re, sys, os, collections, glob
log, root = sys.argv[1], sys.argv[2]
run = collections.defaultdict(lambda: collections.Counter())
sect = False
for line in open(log, errors="replace"):
    if line.strip().startswith("Running"):
        sect = "tests/tests.rs" in line
    if not sect:
        continue
    m = re.match(r"^test (test_\w+)::(\S+)(?: - should panic)? \.\.\. (ok|FAILED|ignored)", line)
    if m:
        run[m.group(1)[5:]][m.group(3)] += 1
static = {}
linux_only = {}
for f in glob.glob(f"{root}/tests/by-util/test_*.rs"):
    u = os.path.basename(f)[5:-3]
    lines = open(f).read().split("\n")
    n = lin = 0
    for i, l in enumerate(lines):
        if l.strip() in ("#[test]", "#[rstest]"):
            n += 1
            j, attrs = i, []
            while j > 0 and lines[j - 1].strip().startswith(("#[", ")]", "target_os", "all(", "any(", "not(")):
                j -= 1
                attrs.append(lines[j])
            k = i + 1
            while k < len(lines) and lines[k].strip().startswith("#["):
                attrs.append(lines[k]); k += 1
            a = " ".join(attrs)
            if "cfg" in a and re.search(r'"linux"|"android"|selinux|smack', a) and not re.search(r'"macos"|apple|not\(', a):
                lin += 1
    static[u] = n
    linux_only[u] = lin
unit = {}
for d in glob.glob(f"{root}/src/uu/*"):
    n = 0
    for f in glob.glob(f"{d}/src/**/*.rs", recursive=True):
        n += len(re.findall(r"#\[test\]", open(f, errors="replace").read()))
    unit[os.path.basename(d)] = n
utils = sorted(set(static) | set(run) | set(unit))
print("| utility | passed | failed | ignored | ran | #[test]/#[rstest] in tests/by-util | of them cfg Linux-only | unit #[test] in src/uu |")
print("|---|---|---|---|---|---|---|---|")
T = collections.Counter()
for u in utils:
    c = run.get(u, collections.Counter())
    ran = c["ok"] + c["FAILED"] + c["ignored"]
    s = static.get(u, 0)
    row = [u, c["ok"], c["FAILED"], c["ignored"], ran, s, linux_only.get(u, 0), unit.get(u, 0)]
    T.update(dict(zip(["ok", "FAILED", "ignored", "ran", "static", "absent", "unit"], row[1:])))
    print("| " + " | ".join(map(str, row)) + " |")
print(f"| **total** | {T['ok']} | {T['FAILED']} | {T['ignored']} | {T['ran']} | {T['static']} | {T['absent']} | {T['unit']} |")
