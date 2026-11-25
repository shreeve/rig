#!/usr/bin/env python3
"""emit-snapshot.py OUT [RIG]: emit every program tools/emit-diff emits (examples/*.rig, every Rig program under
bench/, a program that uses every std module, and Trig from $TRIG) with RIG (default bin/rig) into OUT/<program>,
the way emit-diff does (`rig emit` with RIG_OUT_DIR, RIG_STD and RIG_BUILD_STORE unset), and write OUT/MANIFEST:
one `sha256  path` line per file, sorted, then OUT/STATUS: each program's exit status. Run from a Rig checkout's
root. OUT must be a fixed path: an embedded file's emitted Zig names its absolute path under OUT, so an emit into
another directory differs in that text."""
import hashlib, importlib.machinery, importlib.util, os, subprocess, sys
root = os.getcwd(); out = os.path.abspath(sys.argv[1]); rig = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else "bin/rig")
loader = importlib.machinery.SourceFileLoader("emitdiff", os.path.join(root, "tools", "emit-diff"))
spec = importlib.util.spec_from_loader("emitdiff", loader); ed = importlib.util.module_from_spec(spec); loader.exec_module(ed)
sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
if os.path.exists(out): sys.exit("emit-snapshot: %s exists; remove it first" % out)
src = os.path.join(out, "_sources"); os.makedirs(src)
progs = ed.programs(src, sha)
status = []
for label, cwd, name in progs:
    d = os.path.join(out, ed.slug(label))
    _, code, err = ed.emit(rig, label, cwd, name, d)
    status.append("%s\t%d\t%s" % (label, code, err.strip().splitlines()[0] if err.strip() else ""))
lines = []
for dp, _, names in os.walk(out):
    for n in names:
        p = os.path.join(dp, n); rel = os.path.relpath(p, out)
        if rel.startswith("_sources" + os.sep): continue
        lines.append("%s  %s" % (hashlib.sha256(open(p, "rb").read()).hexdigest(), rel))
lines.sort(key=lambda l: l[66:])
open(os.path.join(out, "MANIFEST"), "w").write("\n".join(lines) + "\n")
open(os.path.join(out, "STATUS"), "w").write("\n".join(status) + "\n")
print("emit-snapshot: %d programs (%d failed), %d files, rig %s at %s" % (len(progs), sum(1 for s in status if s.split("\t")[1] != "0"), len(lines), rig, sha[:12]))
