#!/usr/bin/env python3
"""Rewrite `for x in it` over an existing iterator to `for x in !it`.

Re-runnable: usage  rewrite.py REPO RIG_BIN [JOBS]
Runs `rig check` on every .rig file under REPO (and every ```rig block of
the Markdown docs), takes each diagnostic "write `for x in !it`: the loop
advances `it`" and inserts the `!` at its position. Repeats until no such
diagnostic remains. Only that one diagnostic is acted on.
"""
import os, re, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

repo, rig = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
jobs = int(sys.argv[3]) if len(sys.argv) > 3 else 4
DIAG = re.compile(r"^(.+?):(\d+):(\d+): error: write `for \S+ in !(\S+)`: the loop advances")

def files():
    out = subprocess.run(["git", "-C", repo, "ls-files", "*.rig", "*.rig.tmpl"], capture_output=True, text=True).stdout.split("\n")
    return [os.path.join(repo, f) for f in out if f and os.path.exists(os.path.join(repo, f))]

def check(path):
    r = subprocess.run([rig, "check", path], capture_output=True, text=True, cwd=os.path.dirname(path))
    return [(m.group(1), int(m.group(2)), int(m.group(3))) for l in r.stderr.split("\n") + r.stdout.split("\n") if (m := DIAG.match(l))]

def shift_expectations(lines, ln, col):
    """`# error: L:C:` comments naming a later column of the edited line."""
    for k, l in enumerate(lines):
        m = re.match(r"^(# (?:error|warning|note): )(\d+):(\d+):", l)
        if m and int(m.group(2)) == ln and int(m.group(3)) >= col:
            lines[k] = "%s%d:%d:%s" % (m.group(1), ln, int(m.group(3)) + 1, l[m.end():])

def insert(path, hits):
    lines = open(path).read().split("\n")
    for ln, col in sorted(set(hits), reverse=True):
        l = lines[ln - 1]
        lines[ln - 1] = l[:col - 1] + "!" + l[col - 1:]
        shift_expectations(lines, ln, col)
    open(path, "w").write("\n".join(lines))

def fix_rig(path):
    n = 0
    for _ in range(8):
        hits = [(l, c) for p, l, c in check(path) if os.path.abspath(os.path.join(os.path.dirname(path), p)) == path]
        if not hits:
            break
        insert(path, hits)
        n += len(set(hits))
    return n

def fix_md(path):
    text = open(path).read().split("\n")
    n, i = 0, 0
    while i < len(text):
        if re.match(r"^```rig([ \t].*)?$", text[i]):
            j = i + 1
            while j < len(text) and not text[j].startswith("```"):
                j += 1
            block = text[i + 1:j]
            with tempfile.TemporaryDirectory() as d:
                f = os.path.join(d, "main.rig")
                for _ in range(8):
                    open(f, "w").write("\n".join(block) + "\n")
                    hits = [(l, c) for p, l, c in check(f) if os.path.basename(p) == "main.rig"]
                    if not hits:
                        break
                    for ln, col in sorted(set(hits), reverse=True):
                        block[ln - 1] = block[ln - 1][:col - 1] + "!" + block[ln - 1][col - 1:]
                    n += len(set(hits))
            text[i + 1:j] = block
            i = j
        i += 1
    if n:
        open(path, "w").write("\n".join(text))
    return n

mds = [os.path.join(repo, f) for f in subprocess.run(["git", "-C", repo, "ls-files", "*.md"], capture_output=True, text=True).stdout.split() ]
with ThreadPoolExecutor(jobs) as ex:
    total = sum(ex.map(fix_rig, files())) + sum(ex.map(fix_md, mds))
print("inserted %d `!`" % total)
