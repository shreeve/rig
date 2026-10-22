#!/usr/bin/env python3
"""Rewrite test/oracle/rejections after a rename: a doc example is named
by the checksum of its text (test/run), a matrix cell by its type key.

    remap_oracle.py BASE NEW MODES

BASE is the checkout before the renames, NEW the one after, MODES the
renames made (box, list, string). For each doc example of BASE that has a
rewritten counterpart in NEW, the lines that name it follow it; matrix
cells of the `vec` type follow `list`. Lines it cannot map are printed.
"""
import os, re, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rewrite as rw

base, new, modes = sys.argv[1], sys.argv[2], sys.argv[3].split(",")


def tracked_md(root):
    return [f for f in subprocess.run(["git", "ls-files", "*.md"], cwd=root, capture_output=True, text=True).stdout.split()
            if not f.startswith("test/corpus")]


def blocks(text):
    """(flags, body, tail) for each ```rig block: tail is the main.rig
    that test/run writes after the body for the output or error block
    that follows it (test/run, `extract_docs`)."""
    lines, out, i = text.split("\n"), [], 0
    while i < len(lines):
        m = re.match(r"^```rig([ \t].*)?$", lines[i])
        if not m:
            i += 1
            continue
        flags = (m.group(1) or "").split()
        body, i = [], i + 1
        while i < len(lines) and lines[i] != "```":
            body.append(lines[i])
            i += 1
        i += 1
        j = i
        while j < len(lines) and lines[j].strip() == "":
            j += 1
        kind, extra = "", []
        if j < len(lines) and lines[j] in ("```output", "```error", "```facts"):
            kind = lines[j][3:]
            j += 1
            while j < len(lines) and lines[j] != "```":
                extra.append(lines[j])
                j += 1
            i = j + 1
        mode = "check"
        for w in flags:
            if w in ("reject", "fragment", "facts"):
                mode = w
        if "pending" in flags and kind == "error":
            mode = "reject"
        if kind == "output" and mode == "check":
            mode = "run"
        text_ = "\n".join(body) + "\n"
        tail = text_
        if mode == "run":
            tail += "\n# expect:\n" + "".join(("#" if l == "" else "# " + l) + "\n" for l in extra)
        elif mode == "reject":
            tail += "\n\n" + "".join("# error: %s\n" % l for l in extra)
        out.append((flags, text_, tail))
    return out


def cksum(text):
    p = subprocess.run(["cksum"], input=text.encode(), capture_output=True)
    return p.stdout.split()[0].decode()


def keys(fname, bl):
    """The names test/run gives the examples of one file: doc/NAME/SUM,
    with a suffix for a repeat. Blocks that are modules (file=) or
    fragments are skipped as it skips them."""
    name = fname[:-3]
    if name.startswith("docs/"):
        name = name[5:]
    name = name.replace("/", "-")
    seen, res = {}, []
    for flags, text, tail in bl:
        if any(f.startswith("file=") for f in flags) or "fragment" in flags:
            res.append(None)
            continue
        k = "doc/%s/%s" % (name, cksum(tail))
        seen[k] = seen.get(k, 0) + 1
        res.append(k if seen[k] == 1 else "%s-%d" % (k, seen[k]))
    return res


def rewritten(text, path):
    for m in modes:
        text = rw.rewrite_source(m, text, path, [])
    return text


mapping = {}
for f in tracked_md(base):
    if not os.path.exists(os.path.join(new, f)):
        continue
    ob, nb = blocks(open(os.path.join(base, f)).read()), blocks(open(os.path.join(new, f)).read())
    ok, nk = keys(f, ob), keys(f, nb)
    ntexts = [t for _, t, _ in nb]
    for n_, ((fo, to, _), k) in enumerate(zip(ob, ok)):
        if k is None:
            continue
        rt = rewritten(to, f)
        if rt in ntexts:
            mapping[k] = nk[ntexts.index(rt)]
        elif len(ob) == len(nb):
            mapping[k] = nk[n_]
lost = 0
out = []
path = os.path.join(new, "test/oracle/rejections")
for line in open(path).read().split("\n"):
    m = re.match(r"^(doc/[^ ]+) (.*)$", line)
    if m:
        key = m.group(1)
        if key in mapping:
            line = "%s %s" % (mapping[key], m.group(2))
        elif os.path.exists(os.path.join(base, "SPEC.md")):
            print("UNMAPPED", line)
            lost += 1
    elif "list" in modes:
        if line.startswith("test/"):
            # A program's own type named List is Chain now.
            line = re.sub(r" List\.", " Chain.", line)
        elif line and not line.startswith("#"):
            # A matrix cell: its type and context names.
            line = re.sub(r"(?<![a-z])vec(?![a-z])", "list", line)
    out.append(line)
open(path, "w").write("\n".join(out))
print("unmapped:", lost)
