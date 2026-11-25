#!/usr/bin/env python3
"""structure.py: lines of the tracked files at HEAD, by area and language (blank lines and comment-only lines
counted apart), and the 20 largest source files. Run from the checkout's root."""
import subprocess, os, collections
RUNTIME = {"src/runtime.zig", "src/sched.zig", "src/tasks.zig", "src/net.zig", "src/alloc.zig", "src/ordered.zig", "src/unordered.zig"}
files = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.split()
LANG = {".zig": "Zig", ".rig": "Rig", ".py": "Python", ".md": "Markdown", ".sh": "shell", ".rip": "Rip", ".grammar": "grammar",
        ".lean": "Lean", ".test": "Rig tests", ".go": "Go", ".rs": "Rust", ".c": "C", ".h": "C", ".swift": "Swift", ".json": "JSON", ".ts": "TypeScript", ".js": "JavaScript"}
def area(f):
    if f.startswith("src/"): return "runtime (src/)" if f in RUNTIME else "compiler (src/)"
    if f == "rig.grammar": return "compiler (src/)"
    if f.startswith("std/"): return "std/"
    if f.startswith("test/"): return "tests (test/)"
    if f.startswith("docs/history/"): return "docs/history/"
    if f.startswith("docs/") or (f.endswith(".md") and "/" not in f): return "docs (root, docs/)"
    return f.split("/")[0] + "/" if "/" in f else "root files"
def lang(f):
    if f.endswith(".rig.test"): return "Rig tests"
    if f.split("/")[-1] in ("Makefile",): return "make"
    e = os.path.splitext(f)[1]
    if e == "" and f.startswith(("tools/", "bench/")):
        try:
            l = open(f, errors="replace").readline()
            return "Python" if "python" in l else "shell" if "sh" in l else "other"
        except Exception: return "other"
    return LANG.get(e, "other")
COMMENT = {"Zig": "//", "Rig": "#", "Rig tests": "#", "Python": "#", "shell": "#", "Rip": "#", "grammar": "#", "Lean": "--", "Go": "//", "Rust": "//", "C": "//", "Swift": "//"}
T = collections.defaultdict(lambda: [0, 0, 0, 0])  # files, lines, blank, comment
sizes = []
for f in files:
    if not os.path.isfile(f): continue
    try: text = open(f, encoding="utf8").read()
    except Exception: continue
    a, l = area(f), lang(f)
    lines = text.splitlines(); c = COMMENT.get(l)
    blank = sum(1 for x in lines if not x.strip()); com = sum(1 for x in lines if c and x.strip().startswith(c))
    t = T[(a, l)]; t[0] += 1; t[1] += len(lines); t[2] += blank; t[3] += com
    if l in ("Zig", "Rig", "Rig tests", "Python", "grammar", "Markdown", "Lean", "shell") and not f.startswith("docs/history/"):
        sizes.append((len(lines), f))
print("| area | language | files | lines | blank | comment | code |"); print("|---|---|---:|---:|---:|---:|---:|")
for (a, l), (n, ln, b, c) in sorted(T.items(), key=lambda kv: (kv[0][0], -kv[1][1])):
    if ln < 200 and n < 3: continue
    print(f"| {a} | {l} | {n} | {ln} | {b} | {c} | {ln-b-c} |")
print(); print("| lines | file |"); print("|---:|---|")
for n, f in sorted(sizes, reverse=True)[:20]: print(f"| {n} | {f} |")
