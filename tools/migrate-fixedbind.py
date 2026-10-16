#!/usr/bin/env python3
"""Spell a fixed binding `x =! e` again, where it was `const x = e`.

    migrate-fixedbind.py scan  PATH...   report what would change, change nothing
    migrate-fixedbind.py apply PATH...   rewrite the files in place

A PATH is a directory (every `.rig`, `.rig.tmpl` and `.md` file under
it, skipping `.git`, `.zig-cache` and `zig-out`) or a file. In a Rig
file every line is a candidate; in a Markdown file only the lines of a
```` ```rig ```` block (any words after `rig` allowed), and a code span
in prose that holds a whole binding (`` `const x = e` ``; one with a
`;` in it is Zig's, and kept).

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
each, as `MANUAL path:line: text`, so a person can decide. The rewrite
is textual and idempotent; commit first.
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
# A code span in prose that holds a whole binding (Zig's end in `;`).
SPAN = re.compile(r"`((?:new[ \t]+)?const[ \t]+" + NAME + r"[^`;]*)`")
# Any other `const` as a word, for the MANUAL report.
WORD = re.compile(r"(?<![A-Za-z0-9_@.\"])const(?![A-Za-z0-9_])")
FENCE = re.compile(r"^[ \t]*```")
RIG_FENCE = re.compile(r"^[ \t]*```rig(?:[ \t].*)?$")


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
    new = rewrite(m.group(1))
    return "`" + (new if new is not None else m.group(1)) + "`"


def migrate(path, text):
    """(new text, [(line number, old, new)], [(line number, text)] to review)."""
    lines = text.split("\n")
    changes, manual = [], []
    markdown = path.endswith(".md")
    in_rig = in_other = False
    for i, line in enumerate(lines):
        if markdown:
            if not in_rig and not in_other and FENCE.match(line):
                if RIG_FENCE.match(line):
                    in_rig = True
                else:
                    in_other = True
                continue
            if (in_rig or in_other) and FENCE.match(line):
                in_rig = in_other = False
                continue
            if in_other:
                continue
            if not in_rig:
                new = SPAN.sub(span, line)
                if new != line:
                    changes.append((i + 1, line, new))
                    lines[i] = new
                if WORD.search(SPAN.sub("", new)):
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
