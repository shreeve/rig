#!/usr/bin/env python3
"""Prove a refactor changed nothing: compare two Rig compilers.

    test/equiv.py OLD_RIG NEW_RIG [-j N] [--keep DIR]

Runs both compilers over every tracked program (tests, examples, std,
corpus) and every ```rig block in the Markdown docs, and compares what
each prints for `parse`, `normalize`, `check`, `check --facts`, and, for
a program `check` accepts, `check --facts=sema` and `emit`. It prints
each program whose output differs, with the sections that differ, and
exits 1 if any does. Both compilers run from the repository root, so
paths in diagnostics match. A section one compiler does not support
(an unknown option exits 2) is left out for both.
"""
import concurrent.futures as cf
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECTIONS = (
    ("parse", ["parse"]),
    ("normalize", ["normalize"]),
    ("check", ["check"]),
    ("facts", ["check", "--facts"]),
)
ACCEPTED = (
    ("sema", ["check", "--facts=sema"]),
    ("emit", ["emit"]),
)


def programs(docdir):
    """Every program's entry file, relative to ROOT; doc blocks go into docdir."""
    git = lambda pat: subprocess.run(["git", "ls-files", pat], cwd=ROOT, capture_output=True, text=True).stdout.split()
    progs = []
    for f in git("*.rig"):
        d = os.path.dirname(f)
        # A multi-file test is its directory's main.rig.
        if d.startswith("test/") and os.path.basename(f) != "main.rig" and os.path.exists(os.path.join(ROOT, d, "main.rig")):
            continue
        progs.append(f)
    for md in git("*.md"):
        lines = open(os.path.join(ROOT, md)).read().split("\n")
        modules, i = {}, 0
        while i < len(lines):
            m = re.match(r"^```rig([ \t].*)?$", lines[i])
            if not m:
                i += 1
                continue
            start, body, i = i + 1, [], i + 1
            while i < len(lines) and lines[i] != "```":
                body.append(lines[i])
                i += 1
            i += 1
            text = "\n".join(body) + "\n"
            name = next((w[5:] for w in (m.group(1) or "").split() if w.startswith("file=")), None)
            if name:
                modules[name] = text
                continue
            d = os.path.join(docdir, md[:-3].replace("/", "-"), "L%d" % start)
            os.makedirs(d)
            for f, t in [("main.rig", text)] + list(modules.items()):
                open(os.path.join(d, f), "w").write(t)
            modules = {}
            progs.append(os.path.relpath(os.path.join(d, "main.rig"), ROOT))
    return progs


def run(rig, args, f, outdir):
    env = dict(os.environ, RIG_OUT_DIR=outdir)
    try:
        p = subprocess.run([rig] + args + [f], cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"
    return p.returncode, (p.stdout + "\n--stderr--\n" + p.stderr).replace(outdir, "<OUT>")


def compare(old, new, f, outdir):
    diffs = []
    a_ok = b_ok = False
    for name, args in SECTIONS:
        a, b = run(old, args, f, outdir), run(new, args, f, outdir)
        if a != b:
            diffs.append(name)
        if name == "check":
            a_ok, b_ok = a[0] == 0, b[0] == 0
    if a_ok and b_ok:
        for name, args in ACCEPTED:
            a, b = run(old, args, f, outdir), run(new, args, f, outdir)
            if 2 in (a[0], b[0]):  # an option one compiler lacks
                continue
            if a != b:
                diffs.append(name)
    return f, diffs


def main():
    argv = sys.argv[1:]
    jobs = int(argv[argv.index("-j") + 1]) if "-j" in argv else 2
    keep = argv[argv.index("--keep") + 1] if "--keep" in argv else None
    pos = [a for i, a in enumerate(argv) if not a.startswith("-") and (i == 0 or argv[i - 1] not in ("-j", "--keep"))]
    if len(pos) != 2:
        sys.exit(__doc__)
    old, new = (os.path.abspath(p) for p in pos)
    tmp = tempfile.mkdtemp(prefix="rig-equiv-")
    docdir = os.path.join(ROOT, ".equiv-docs")
    shutil.rmtree(docdir, ignore_errors=True)
    try:
        progs = programs(docdir)
        changed = 0
        with cf.ThreadPoolExecutor(jobs) as ex:
            for f, diffs in ex.map(lambda f: compare(old, new, f, tmp), progs):
                if diffs:
                    changed += 1
                    print("%s: %s" % (f, " ".join(diffs)))
                    if keep:
                        for name, args in SECTIONS + ACCEPTED:
                            if name in diffs:
                                base = os.path.join(keep, f.replace("/", "__") + "." + name)
                                open(base + ".old", "w").write(run(old, args, f, tmp)[1])
                                open(base + ".new", "w").write(run(new, args, f, tmp)[1])
        print("%d programs, %d differ" % (len(progs), changed))
        sys.exit(1 if changed else 0)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(docdir, ignore_errors=True)


if __name__ == "__main__":
    if "--keep" in sys.argv:
        os.makedirs(sys.argv[sys.argv.index("--keep") + 1], exist_ok=True)
    main()
