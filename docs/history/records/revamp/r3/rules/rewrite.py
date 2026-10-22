#!/usr/bin/env python3
"""Rewrite Rig sources to the v0.3.0 rules (branch rules).

    rewrite.py scan  [ROOT] [--rig BIN]   report what would change
    rewrite.py apply [ROOT] [--rig BIN]   rewrite every tracked source

Four rules, each driven by the new compiler's own diagnostics or by an
exact textual form:

  * A lasting borrow is written. A call whose result keeps an argument or
    its receiver lent, and whose result is stored in a binding, a field,
    or a return, writes the lend: `r = head(v)` becomes `r = head(?v)`,
    `xs = b.all()` becomes `xs = ?b.all()`. The diagnostic

        `head(v)` keeps `v` lent while `r` lives; write `head(?v)`

    points at the argument or receiver, which gets a `?` before it.
  * No space before a call's or index's bracket: `f (x)` becomes `f(x)`
    (the diagnostic points at the bracket; the blanks before it go).
  * `_ =` discards its value, so `_ = (!v).pop()` becomes `_ = !v.pop()`.
  * `print` and `Text` read their arguments implicitly, so a `?` before
    a slice that is a direct argument of either goes:
    `print(?w[1..3])` becomes `print(w[1..3])`.

It reads every tracked `.rig` file (a directory with `main.rig` is one
program; std/ through a program that uses every module, with
RIG_STD=ROOT/std), every ```rig block of every tracked `.md` file (with
the `file=` modules before it; a `fragment` block is parsed), and every
`.rig` heredoc in test/cli/*.sh. A `# error: L:C:` directive after an
edit on its line moves with it.

A lend the compiler reports only after an earlier one is written (its
check stops at the first kind of error), so `apply` is run until it
reports 0 files. It is idempotent, so it can be re-run after main
moves. Programs whose point is the old form (KEEP, and any whose
expected errors are these rules') are left alone. `scan` also lists, as
`UNCHECKED`, text the compiler did not reach.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

LASTING = re.compile(r"^(.*?):(\d+):(\d+): error: `.*` keeps `.*` lent (?:while `.*` lives|in the value it returns|in what `.*` stores); write `.*`$")
BRACKET = re.compile(r"^(.*?):(\d+):(\d+): error: `.*`: a call's or index's bracket touches what it follows; write `.*`$")
RULE_TEXT = re.compile(r"keeps `.*` lent (while|in the value|in what)|a call's or index's bracket touches what it follows")

# Programs whose point is an old form or the rules themselves.
KEEP = re.compile(r"""^(test/reject/syntax/(spaced_call_bracket|unbalanced_spacing)\.rig
    |test/reject/types/lasting_lend_(written|stored)\.rig)$""", re.X)

# Doc blocks whose expected error is the rule's.
KEEP_ERROR = RULE_TEXT

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


def check(rig, path, cwd, env, verb="check"):
    p = subprocess.run([rig, verb, path], cwd=cwd, capture_output=True, text=True, env=env, timeout=300)
    out = []
    for line in p.stderr.split("\n"):
        for kind, pat in (("lend", LASTING), ("bracket", BRACKET)):
            m = pat.match(line)
            if m:
                out.append((os.path.realpath(os.path.join(cwd, m.group(1))), int(m.group(2)), int(m.group(3)), kind))
    return p.returncode, out


class Unit:
    """A text the rewrite may change: a file, a doc block, a heredoc. Its
    `text` is what the compiler sees; `put` writes the new text back.
    An edit is `(pos, delete, insert)`."""

    def __init__(self, name, text, keep=False):
        self.name, self.text, self.edits = name, text, []
        if not keep and not RULE_TEXT.search("\n".join(l for l in text.split("\n") if l.startswith("# error"))):
            self.edits = text_edits(text, slices=not name.startswith(("test/reject/", "test/torture/")))

    def edit(self, line, col, kind, report):
        offs = offsets(self.text)
        if line > len(offs):
            report.append("SKIP %s:%d:%d: no such line" % (self.name, line, col))
            return
        at = offs[line - 1] + col - 1
        if kind == "lend":
            if self.text[at:at + 1] == "?":
                report.append("SKIP %s:%d:%d: already a lend" % (self.name, line, col))
                return
            e = (at, 0, "?")
        else:
            if self.text[at] not in "([":
                report.append("SKIP %s:%d:%d: no bracket at the diagnostic" % (self.name, line, col))
                return
            j = at
            while j > 0 and self.text[j - 1] in " \t":
                j -= 1
            e = (j, at - j, "")
        if e not in self.edits:
            self.edits.append(e)
            report.append("%s %s:%d" % (kind, self.name, line))

    def rewritten(self):
        text = self.text
        edits = sorted(set(self.edits))
        directives = list(ERROR_AT.finditer(text))
        offs = offsets(text)
        places = []
        for m in directives:
            line, col = int(m.group(2)), int(m.group(3))
            if 1 <= line <= len(offs):
                places.append((m, offs[line - 1] + col - 1))

        def moved(p):
            return p + sum(len(ins) - dele for (pos, dele, ins) in edits if pos <= p)

        new_places = [(m, moved(at)) for m, at in places]
        for pos, dele, ins in sorted(edits, key=lambda e: -e[0]):
            text = text[:pos] + ins + text[pos + dele:]
        offs_new = offsets(text)
        out = []
        for m, at in new_places:
            start = moved(m.start())
            line = text.count("\n", 0, at) + 1
            col = at - offs_new[line - 1] + 1
            out.append((start, start + len(m.group(0)), "%s%d:%d:" % (m.group(1), line, col)))
        for a, b, s_ in sorted(out, reverse=True):
            text = text[:a] + s_ + text[b:]
        return text


DISCARD = re.compile(r"\b_ = \(!([A-Za-z_][\w.]*(?:\[[^\]\n()]*\])*(?:\.[A-Za-z_]\w*(?:\[[^\]\n()]*\])*)*)\)\.(\w+)\(")
LENT_SLICE = re.compile(r"\?[A-Za-z_][\w.]*(?:\[[^\]\n]*\])*\[[^\]\n]*\.\.[^\]\n]*\]\s*$")


def text_edits(text, slices=True):
    """The edits of the textual rules: `_ = (!p).m(` -> `_ = !p.m(`, and
    a lent slice directly under `print(` or `Text(` loses its `?`."""
    edits = []
    def comment(pos):
        return text[text.rfind("\n", 0, pos) + 1:pos].lstrip().startswith("#")

    for m in DISCARD.finditer(text):
        if comment(m.start()):
            continue
        open_ = m.start(1) - 2
        close = m.end(1)
        edits.append((open_, 1, ""))
        edits.append((close, 1, ""))
    for m in re.finditer(r"\b(?:print|Text)\(", text) if slices else []:
        if comment(m.start()):
            continue
        depth, start, k = 0, m.end(), m.end()
        args = []
        ok = True
        while k < len(text):
            c = text[k]
            if c == '"':
                k += 1
                while k < len(text) and text[k] != '"':
                    k += 2 if text[k] == "\\" else 1
            elif c in "([":
                depth += 1
            elif c in ")]":
                if depth == 0:
                    args.append((start, k))
                    break
                depth -= 1
            elif c == "," and depth == 0:
                args.append((start, k))
                start = k + 1
            elif c == "\n":
                ok = False
                break
            k += 1
        if not ok or k >= len(text):
            continue
        for a, b in args:
            arg = text[a:b]
            lead = len(arg) - len(arg.lstrip(" "))
            if LENT_SLICE.match(arg[lead:]):
                edits.append((a + lead, 1, ""))
    return edits


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
    tmp = tempfile.mkdtemp(prefix="rewrite-b-")
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
            if "facts" in words:
                continue
            if err is not None and KEEP_ERROR.search("\n".join(err)):
                continue
            if "fragment" in words:
                # Only parsed: the bracket rule is the lexer's.
                d = tempfile.mkdtemp(dir=tmp)
                p = os.path.join(d, "main.rig")
                open(p, "w").write("\n".join(body) + "\n")
                key = (f, start)
                if key not in md_units:
                    md_units[key] = Unit("%s:L%d" % (f, start), "\n".join(body) + "\n")
                _, diags = check(rig, p, d, env)
                take(diags, {os.path.realpath(p): (md_units[key], 0)})
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

    for r in report:
        print(r)
    print("%d files %s" % (changed, "rewritten" if mode == "apply" else "to rewrite"), file=sys.stderr)
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
