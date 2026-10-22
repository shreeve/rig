#!/usr/bin/env python3
"""IR-equivalence dump: irdump.py <rig-binary> <tree> <outdir> [-j N]

For every tracked .rig file in <tree> (tests, examples, std, corpus) and
every ```rig block in its Markdown docs, write the output of
`rig parse`, `rig normalize`, `rig check`, `rig check --facts` and, when
check accepts, `rig emit` and `rig sema` into <outdir>, one file per program and command.
Diff two outdirs with `diff -r` to prove a refactor changed nothing.
Run both sides from the same <tree> so paths in diagnostics match.
"""
import os, re, subprocess, sys, concurrent.futures as cf

rig, tree, out = sys.argv[1:4]
jobs = int(sys.argv[sys.argv.index("-j") + 1]) if "-j" in sys.argv else 2
rig = os.path.abspath(rig); out = os.path.abspath(out); tree = os.path.abspath(tree)
os.chdir(tree)

files = subprocess.run(["git", "ls-files", "*.rig"], capture_output=True, text=True).stdout.split()
# Only entry points: skip files inside a multi-file test dir that are not main.rig
progs = []
for f in files:
    parts = f.split("/")
    d = os.path.dirname(f)
    if os.path.basename(f) != "main.rig" and os.path.exists(os.path.join(d, "main.rig")) and d.startswith("test/"):
        continue
    progs.append(f)

# Doc blocks -> .git/revamp/r3/docs-<treehash>/<doc>/L<n>/main.rig (with file= modules)
import shutil
docdir = os.path.join(tree, ".irdump")
shutil.rmtree(docdir, ignore_errors=True)
for md in subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True).stdout.split():
    lines = open(md).read().split("\n")
    pending = {}
    i = 0
    while i < len(lines):
        m = re.match(r"^```rig([ \t].*)?$", lines[i])
        if not m:
            i += 1; continue
        start = i + 1
        words = (m.group(1) or "").split()
        body = []
        i += 1
        while i < len(lines) and lines[i] != "```":
            body.append(lines[i]); i += 1
        i += 1
        fname = next((w[5:] for w in words if w.startswith("file=")), None)
        if fname:
            pending[fname] = "\n".join(body) + "\n"; continue
        d = os.path.join(docdir, md.replace("/", "-")[:-3], "L%d" % start)
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "main.rig"), "w").write("\n".join(body) + "\n")
        for k, v in pending.items():
            open(os.path.join(d, k), "w").write(v)
        pending = {}
        progs.append(os.path.relpath(os.path.join(d, "main.rig"), tree))

def run(args):
    p = subprocess.run([rig] + args, capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout + ("\n--stderr--\n" + p.stderr if p.stderr else "")

def dump(f):
    key = f.replace("/", "__")
    res = []
    for name, args in (("parse", ["parse", f]), ("normalize", ["normalize", f]),
                       ("check", ["check", f]), ("facts", ["check", "--facts", f])):
        try:
            rc, o = run(args)
        except subprocess.TimeoutExpired:
            rc, o = -1, "TIMEOUT"
        o = o.replace(out, "<OUT>")
        res.append("== %s rc=%d\n%s" % (name, rc, o))
        if name == "check":
            ok = rc == 0
    if ok:
        try:
            rc, o = run(["emit", f])
        except subprocess.TimeoutExpired:
            rc, o = -1, "TIMEOUT"
        res.append("== emit rc=%d\n%s" % (rc, o))
        try:
            rc, o = run(["sema", f])
        except subprocess.TimeoutExpired:
            rc, o = -1, "TIMEOUT"
        res.append("== sema rc=%d\n%s" % (rc, o.replace(out, "<OUT>")))
    open(os.path.join(out, key + ".txt"), "w").write("\n".join(res))

os.makedirs(out, exist_ok=True)
with cf.ThreadPoolExecutor(jobs) as ex:
    list(ex.map(dump, progs))
print("dumped", len(progs), "programs to", out)
