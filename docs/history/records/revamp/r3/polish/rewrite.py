#!/usr/bin/env python3
"""Rewrite Rig sources to put a comparison under `not` in parentheses
(branch polish).

    rewrite.py scan  [ROOT] [--rig BIN]   report what would change
    rewrite.py apply [ROOT] [--rig BIN]   rewrite every tracked source

`not` applies to the whole comparison after it, and a comparison
directly under `not` is written in parentheses: `not it.qty > 3`
becomes `not (it.qty > 3)`, which means the same, so every rewritten
program emits the Zig it did. (The compiler also offers the flipped
comparison, `it.qty <= 3`; the rewrite keeps the meaning to the letter
and writes the parentheses.)

The rewrite is driven by the diagnostics of the new compiler (BIN,
default ROOT/bin/rig),

    write `it.qty <= 3`, or `not (it.qty > 3)`: `not` applies to the whole comparison

each at the `not`. It reads every tracked `.rig` file (a directory with
`main.rig` is one program; std/ through a program that uses every
module, with RIG_STD=ROOT/std), every ```rig block of every tracked
`.md` file (with the `file=` modules before it), and every `.rig`
heredoc in test/cli/*.sh, and puts each such comparison in
parentheses. A `# error: L:C:` directive after an insertion on its line
moves with it.

It is idempotent: once rewritten, the compiler reports nothing more, so
a second run changes nothing, and the script can be re-run after main
moves. Programs whose point is the rule itself (KEEP) are left alone.
`scan` also lists, as `UNCHECKED`, a `not` before a comparison in text
the compiler did not reach (a program rejected before the type checker,
a fragment, prose): each is for a hand to look at.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

MESSAGE = re.compile(r"^(.*?):(\d+):(\d+): error: write .*`not \((.*)\)`: `not` applies to the whole comparison$")

# Programs whose point is the rule: they show the bare form on purpose.
KEEP = re.compile(r"^test/reject/syntax/not_comparison_(scope|lines)\.rig$")

# Doc blocks whose expected error is the rule's.
KEEP_ERROR = re.compile(r"`not` applies to the whole comparison")

STD_PROGRAM = """use std.math
use std.os
use std.random
use std.slices
use std.sort
use std.text
use std.time

sub main()
  print(1)
"""


def git_files(root):
    r = subprocess.run(["git", "ls-files"], cwd=root, capture_output=True, text=True, check=True)
    return r.stdout.split()


def offsets(text):
    offs, o = [], 0
    for line in text.split("\n"):
        offs.append(o)
        o += len(line) + 1
    return offs


def check(rig, path, cwd, env):
    p = subprocess.run([rig, "check", path], cwd=cwd, capture_output=True, text=True, env=env, timeout=300)
    out = []
    for line in p.stderr.split("\n"):
        m = MESSAGE.match(line)
        if m:
            out.append((os.path.realpath(os.path.join(cwd, m.group(1))), int(m.group(2)), int(m.group(3)), m.group(4)))
    return p.returncode, out


class Unit:
    """A text the rewrite may change: a file, a doc block, a heredoc. Its
    `text` is what the compiler sees; `put` writes the new text back."""

    def __init__(self, name, text):
        self.name, self.text, self.edits = name, text, []

    def edit(self, line, col, operand, report):
        offs = offsets(self.text)
        if line > len(offs):
            report.append("SKIP %s:%d:%d: no such line" % (self.name, line, col))
            return
        at = offs[line - 1] + col - 1
        m = re.compile(r"not[ \t]+").match(self.text, at)
        if not m or self.text[m.end():m.end() + len(operand)] != operand:
            report.append("SKIP %s:%d:%d: `not %s` is not at the diagnostic" % (self.name, line, col, operand))
            return
        if (m.end(), operand) not in self.edits:
            self.edits.append((m.end(), operand))
            report.append("write %s:%d: not (%s)" % (self.name, line, operand))

    def rewritten(self):
        text = self.text
        # Insertions, each `(pos, s)`; the last first.
        ins = []
        for at, operand in self.edits:
            ins.append((at, "("))
            ins.append((at + len(operand), ")"))
        directives = list(ERROR_AT.finditer(text))
        offs = offsets(text)
        places = []
        for m in directives:
            line, col = int(m.group(2)), int(m.group(3))
            if 1 <= line <= len(offs):
                places.append([m, offs[line - 1] + col - 1])
        for pos, s in sorted(ins, key=lambda x: -x[0]):
            text = text[:pos] + s + text[pos:]
            for p in places:
                if p[1] >= pos:
                    p[1] += len(s)
        # Rewrite the directives where their places are now; a directive
        # follows every edit, so its own position moved by the edits
        # before it.
        offs_new = offsets(text)
        out = []
        for m, at in places:
            shift = sum(len(s) for pos, s in ins if pos <= m.start())
            start = m.start() + shift
            line = text.count("\n", 0, at) + 1
            col = at - offs_new[line - 1] + 1
            out.append((start, start + len(m.group(0)), "%s%d:%d:" % (m.group(1), line, col)))
        for a, b, s in sorted(out, reverse=True):
            text = text[:a] + s + text[b:]
        return text


ERROR_AT = re.compile(r"^(# error: )(\d+):(\d+):", re.M)

FENCE = re.compile(r"^```rig([ \t].*)?$")


def md_blocks(text):
    """Each ```rig block: (words after `rig`, first body line index, body
    lines, the error block after it or None)."""
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if not m:
            i += 1
            continue
        start, body = i + 1, []
        i += 1
        while i < len(lines) and lines[i] != "```":
            body.append(lines[i])
            i += 1
        k = i + 1
        while k < len(lines) and lines[k].strip() == "":
            k += 1
        err = None
        if k < len(lines) and lines[k] == "```error":
            err = []
            k += 1
            while k < len(lines) and lines[k] != "```":
                err.append(lines[k])
                k += 1
        out.append(((m.group(1) or "").split(), start, body, err))
        i += 1
    return out


def heredocs(text):
    """Each `.rig` heredoc: (file name, first body line index, body)."""
    lines = text.split("\n")
    out, i = [], 0
    pat = re.compile(r">\s*\"?([\w./$-]+\.rig)\"?.*<<-?\s*'?\"?([A-Za-z_]+)'?\"?\s*$")
    while i < len(lines):
        m = pat.search(lines[i])
        if not m:
            i += 1
            continue
        name, tag = os.path.basename(m.group(1)), m.group(2)
        i += 1
        start, body = i, []
        while i < len(lines) and lines[i] != tag:
            body.append(lines[i])
            i += 1
        out.append((name, start, body))
        i += 1
    return out


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("scan", "apply"):
        sys.exit(__doc__)
    mode = args[0]
    rig = None
    if "--rig" in args:
        rig = os.path.abspath(args[args.index("--rig") + 1])
        del args[args.index("--rig"):args.index("--rig") + 2]
    rest = args[1:]
    root = os.path.realpath(rest[0] if rest else ".")
    rig = rig or os.path.join(root, "bin", "rig")
    env = dict(os.environ, RIG_STD=os.path.join(root, "std"))
    env.pop("RIG_OUT_DIR", None)
    tmp = tempfile.mkdtemp(prefix="rewrite-not-")
    report = []
    files = git_files(root)

    # Units by the absolute path the compiler reports.
    units = {}

    def unit_file(rel):
        path = os.path.join(root, rel)
        if path not in units:
            units[path] = Unit(rel, open(path).read())
        return units[path]

    std_units = {os.path.realpath(os.path.join(root, g)): (unit_file(g), 0) for g in files if g.startswith("std/") and g.endswith(".rig")}

    def take(diags, mapping):
        for path, line, col, hint in diags:
            if path in mapping or path in std_units:
                u, base = mapping.get(path) or std_units[path]
                u.edit(line + base, col, hint, report)
            elif ("SKIP %s:%d:%d: outside the tree" % (path, line, col)) not in report:
                report.append("SKIP %s:%d:%d: outside the tree" % (path, line, col))

    # Programs: every `.rig` file, a directory with `main.rig` as one.
    programs, seen = [], set()
    for f in files:
        if not f.endswith(".rig") or f.startswith("test/torture/") or f.startswith("std/"):
            continue
        d = os.path.dirname(f)
        main_rig = os.path.join(d, "main.rig")
        if d.startswith("test/") and main_rig in files and d not in ("test", "test/corpus"):
            f = main_rig
        if f not in seen:
            seen.add(f)
            programs.append(f)
    for f in programs:
        if KEEP.match(f):
            continue
        d = os.path.dirname(os.path.join(root, f))
        mapping = {}
        for g in files:
            if g.endswith(".rig") and (g == f or (os.path.basename(f) == "main.rig" and os.path.dirname(os.path.join(root, g)) == d)):
                mapping[os.path.realpath(os.path.join(root, g))] = (unit_file(g), 0)
        _, diags = check(rig, os.path.join(root, f), root, env)
        take(diags, mapping)

    # The standard library, through a program that uses all of it.
    sp = os.path.join(tmp, "std_all.rig")
    open(sp, "w").write(STD_PROGRAM)
    _, diags = check(rig, sp, tmp, env)
    take(diags, {})

    # Doc blocks, each with the modules written before it.
    md_units = {}
    for f in files:
        if not f.endswith(".md"):
            continue
        text = open(os.path.join(root, f)).read()
        blocks = md_blocks(text)
        mods = []
        for words, start, body, err in blocks:
            if any(w.startswith("file=") for w in words):
                mods.append((words, start, body))
                continue
            here, mods = mods, []
            if "fragment" in words or "facts" in words:
                continue
            if err is not None and KEEP_ERROR.search("\n".join(err)):
                continue
            d = tempfile.mkdtemp(dir=tmp)
            mapping = {}
            for mw, ms, mb in here + [(["file=main.rig"], start, body)]:
                name = [w[5:] for w in mw if w.startswith("file=")][0]
                p = os.path.join(d, name)
                open(p, "w").write("\n".join(mb) + "\n")
                key = (f, ms)
                if key not in md_units:
                    md_units[key] = Unit("%s:L%d" % (f, ms), "\n".join(mb) + "\n")
                mapping[os.path.realpath(p)] = (md_units[key], 0)
            _, diags = check(rig, os.path.join(d, "main.rig"), d, env)
            take(diags, mapping)

    # CLI heredocs, each script's in one directory.
    sh_units = {}
    for f in files:
        if not (f.startswith("test/cli/") and f.endswith(".sh")):
            continue
        docs = heredocs(open(os.path.join(root, f)).read())
        if not docs:
            continue
        d = tempfile.mkdtemp(dir=tmp)
        for name, start, body in docs:
            # A name written twice is checked as each body in turn.
            p = os.path.join(d, name)
            open(p, "w").write("\n".join(body) + "\n")
            key = (f, start)
            sh_units[key] = Unit("%s:%d" % (f, start + 1), "\n".join(body) + "\n")
            if "sub main()" in "\n".join(body):
                mapping = {os.path.realpath(p): (sh_units[key], 0)}
                _, diags = check(rig, p, d, env)
                take(diags, mapping)

    # The new text of every file, in memory.
    texts = {}
    for path, u in units.items():
        if u.edits:
            texts[path] = u.rewritten()
    for group in (md_units, sh_units):
        by_file = {}
        for (f, start), u in group.items():
            if u.edits:
                by_file.setdefault(f, []).append((start, u))
        for f, us in by_file.items():
            path = os.path.join(root, f)
            lines = texts.get(path, open(path).read()).split("\n")
            for start, u in sorted(us, key=lambda x: -x[0]):
                old = u.text[:-1].split("\n")
                new = u.rewritten()[:-1].split("\n")
                assert lines[start:start + len(old)] == old, (f, start)
                lines[start:start + len(old)] = new
            texts[path] = "\n".join(lines)
    changed = len(texts)
    if mode == "apply":
        for path, text in texts.items():
            open(path, "w").write(text)

    # What the compiler did not reach: `not` before a comparison by its
    # look, in the new text, left for a hand.
    bare = re.compile(r"\bnot[ \t]+(?!\()[^#]*?(==|!=|<=|>=| < | > )")
    for f in files:
        if f.startswith("test/torture/") or KEEP.match(f) or not (f.endswith(".rig") or f.endswith(".md")):
            continue
        path = os.path.join(root, f)
        text = texts.get(path) or open(path).read()
        for n, line in enumerate(text.split("\n"), 1):
            code = line.split("#", 1)[0] if f.endswith(".rig") else line
            if bare.search(code):
                report.append("UNCHECKED %s:%d: %s" % (f, n, line.strip()))

    for r in report:
        print(r)
    print("%d files %s" % (changed, "rewritten" if mode == "apply" else "to rewrite"), file=sys.stderr)
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
