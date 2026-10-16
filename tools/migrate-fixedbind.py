#!/usr/bin/env python3
"""Spell a fixed binding `x =! e` again, where it was `const x = e`.

    migrate-fixedbind.py scan  PATH...   report what would change, change nothing
    migrate-fixedbind.py apply PATH...   rewrite the files in place

A PATH is a directory (every `.rig`, `.rig.tmpl` and `.md` file under
it, skipping `.git`, `.zig-cache` and `zig-out`) or a file. In a Rig
file every line is a candidate, a line inside a multi-line string too.
In a Markdown file the candidates are the lines of a ```` ```rig ````
block (a fence of three or more backticks or tildes, any words after
`rig`), and a code span in prose that holds a whole binding
(`` `const x = e` ``). A span with `;`, `{` or `@import` in it is
Zig's, and kept. A ```` ```rig reject ```` block is listed, not
rewritten: what it shows rejected may be the `const` itself.

A line is rewritten when, after its indentation, it starts with a
binding written with `const`:

    const x = e               ->  x =! e
    const x: T = e            ->  x: T =! e
    new const x = e           ->  new x =! e
    new const x: T = e        ->  new x: T =! e
    const q, r = f()          ->  q, r =! f()
    pub const X = e           ->  pub X =! e
    errdefer const x = e      ->  errdefer x =! e   (and after `defer`)

Everything after the `=` is kept as written, as is the type. A module-
level `const X = e` becomes `X =! e`, which Rig rejects as it rejected
the first (a module-level binding is already a constant): write `X = e`.

Not rewritten: the word `const` in a comment or in prose ("a `const`
binding"), and a binding that does not start its line. `scan` lists
each, as `MANUAL path:line: text`, so a person can decide. The type is
taken to hold no `=`, as no Rig type does.

The rewrite is textual; commit first, and read `scan` before `apply`.
Run again on a tree it migrated, it rewrites only the `const` bindings
written since, which includes a test that shows `const` rejected.
"""
import os
import re
import sys

SKIP_DIRS = {".git", ".zig-cache", "zig-out"}
EXTS = (".rig", ".rig.tmpl", ".md")

NAME = r"[A-Za-z_][A-Za-z0-9_]*"
# A binding written with `const` at the start of a line (after its
# indentation): the names, an optional type, and `=` (not `==` or `=>`).
BIND = re.compile(
    r"^(?P<ind>[ \t]*)(?P<pre>(?:pub|defer|errdefer)[ \t]+)?(?P<new>new[ \t]+)?const[ \t]+"
    r"(?P<names>" + NAME + r"(?:[ \t]*,[ \t]*" + NAME + r")*)"
    r"(?P<ty>[ \t]*:[^=\n]*?)?[ \t]*=(?![=>])[ \t]*(?P<rest>.*)$"
)
# A code span in prose that holds a whole binding; Zig's hold `;`, `{`
# or `@import`.
SPAN = re.compile(r"`((?:new[ \t]+)?const[ \t]+" + NAME + r"[^`]*)`")
ZIG = re.compile(r"[;{]|@import")
# Any other `const` as a word, for the MANUAL report.
WORD = re.compile(r"(?<![A-Za-z0-9_@.\"])const(?![A-Za-z0-9_])")
# A fence: its characters, and the words after them.
FENCE = re.compile(r"^[ \t]*(`{3,}|~{3,})[ \t]*([^`]*?)[ \t]*$")


def rewrite(line):
    """The line with its `const` binding respelled, or None."""
    m = BIND.match(line)
    if not m:
        return None
    ty = (m.group("ty") or "").rstrip()
    rest = m.group("rest")
    out = m.group("ind") + (m.group("pre") or "") + (m.group("new") or "") + m.group("names") + ty + " =!"
    return out + (" " + rest if rest else "")


def span(m):
    new = None if ZIG.search(m.group(1)) else rewrite(m.group(1))
    return "`" + (new if new is not None else m.group(1)) + "`"


def migrate(path, text):
    """(new text, [(line number, old, new)], [(line number, text)] to review)."""
    lines = text.split("\n")
    changes, manual = [], []
    markdown = path.endswith(".md")
    fence = None  # the open fence's characters
    kind = None  # "rig", "reject" (a rig reject block), or "other"
    for i, line in enumerate(lines):
        if markdown:
            f = FENCE.match(line)
            if fence is None and f:
                fence = f.group(1)
                words = f.group(2).split()
                kind = "other" if not words or words[0] != "rig" else "reject" if "reject" in words[1:] else "rig"
                continue
            if fence is not None and f and f.group(1)[0] == fence[0] and len(f.group(1)) >= len(fence) and not f.group(2):
                fence = kind = None
                continue
            if kind == "other":
                continue
            if kind == "reject":
                if BIND.match(line) or WORD.search(line):
                    manual.append((i + 1, line))
                continue
            if fence is None:
                new = SPAN.sub(span, line)
                if new != line:
                    changes.append((i + 1, line, new))
                    lines[i] = new
                if WORD.search(SPAN.sub(lambda m: m.group(0) if ZIG.search(m.group(1)) else "", new)):
                    manual.append((i + 1, new))
                continue
        new = rewrite(line)
        if new is not None:
            changes.append((i + 1, line, new))
            lines[i] = new
        elif WORD.search(line):
            manual.append((i + 1, line))
    return "\n".join(lines), changes, manual


def files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
                for n in sorted(names):
                    if n.endswith(EXTS):
                        yield os.path.join(root, n)
        else:
            yield p


def main(argv):
    if len(argv) < 3 or argv[1] not in ("scan", "apply"):
        sys.stderr.write(__doc__)
        return 2
    apply = argv[1] == "apply"
    nfiles = nlines = 0
    for path in files(argv[2:]):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        new, changes, manual = migrate(path, text)
        for n, line in manual:
            print("MANUAL %s:%d: %s" % (path, n, line.strip()))
        if not changes:
            continue
        nfiles += 1
        nlines += len(changes)
        for n, old, line in changes:
            print("%s %s:%d: %s" % ("FIXED" if apply else "WOULD", path, n, line.strip()))
        if apply:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
    print("%s %d lines in %d files" % ("rewrote" if apply else "would rewrite", nlines, nfiles))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
