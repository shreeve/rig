#!/usr/bin/env python3
"""Rewrite Rig sources for `Symbols` as std.text's `Interner`.

    rename-interner.py PATH...

Rewrites in place every `.rig`, `.rig.test`, and `.md` file under each
PATH (a directory, or a file of one of those kinds). The run-time string
interner is `Interner`, in std.text: a program writes `use std.text` and
then `text.Interner()`, `text.Interner` in a type.

In each program (a `.rig` file, a case of a `.rig.test` file, a code
block of a `.md` file) that names `Symbols` in code:

  - `Symbols` becomes `text.Interner`, or `t.Interner` where the program
    has `use std.text as t`;
  - a `use std.text` line is added where the program has none, after
    its last `use` line, or else before its first line of code.

In a `.md` file's prose, `` `Symbols` `` and `` `Symbols()` `` become
`` `text.Interner` `` and `` `text.Interner()` ``. Comments are left as
they are. A program that declares its own `Symbols` keeps it, and is
reported as `CHECK path:line`.

Prints each file it changed.
"""
import os
import re
import sys

USE = re.compile(r"^(\s*)use\s+std\.text(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*(#.*)?$")
ANY_USE = re.compile(r"^(\s*)use\s+\S")
OWN = re.compile(r"^\s*(?:pub\s+)?(?:obj|enum|type)\s+Symbols\b")
NAME = re.compile(r"(?<![A-Za-z0-9_.:@`])Symbols\b")
PROSE = re.compile(r"`Symbols(\(\))?`")
HEADER = re.compile(r"^(test|fail|bomb|code|accept) ")


def code(line):
    """The part of `line` before a comment, and the comment."""
    in_str = False
    for i, c in enumerate(line):
        if c == '"':
            in_str = not in_str
        elif c == "#" and not in_str:
            return line[:i], line[i:]
    return line, ""


def migrate_unit(lines, preset):
    """One program: `Symbols` in its code made `text.Interner`, and a
    `use std.text` added where none is. `preset` is the alias a test
    file's header gives every case, or None."""
    uses = any(NAME.search(code(l)[0]) for l in lines if not l.lstrip().startswith("#"))
    if not uses:
        return lines, []
    if any(OWN.match(l) for l in lines):
        return lines, [i for i, l in enumerate(lines) if NAME.search(code(l)[0])]
    alias = preset
    for l in lines:
        m = USE.match(l)
        if m:
            alias = m.group(2) or "text"
    add = alias is None
    alias = alias or "text"
    out = []
    for l in lines:
        body, comment = code(l)
        if not l.lstrip().startswith("#"):
            body = NAME.sub(alias + ".Interner", body)
        out.append(body + comment)
    if add:
        last_use = max((i for i, l in enumerate(out) if ANY_USE.match(l)), default=None)
        if last_use is not None:
            indent = ANY_USE.match(out[last_use]).group(1)
            out.insert(last_use + 1, indent + "use std.text")
        else:
            # Past a test case's header and the result block it opens.
            skip = 0
            if out and HEADER.match(out[0]):
                skip = 1
                if out[0].rstrip().endswith("'''"):
                    skip = next(i for i in range(1, len(out)) if out[i].strip() == "'''") + 1
            first = next(i for i, l in enumerate(out) if i >= skip and l.strip() and not l.lstrip().startswith("#") and not l.lstrip().startswith("```"))
            indent = out[first][: len(out[first]) - len(out[first].lstrip())]
            out[first:first] = [indent + "use std.text", ""]
    return out, []


def units(lines, kind):
    if kind == "rig":
        return [(0, len(lines), True)]
    bounds = []
    if kind == "test":
        start = 0
        for i, line in enumerate(lines):
            if HEADER.match(line):
                bounds.append((start, i, start > 0))
                start = i
        bounds.append((start, len(lines), start > 0))
        return bounds
    start = 0
    inside = False
    for i, line in enumerate(lines):
        if line.lstrip().startswith("```"):
            if not inside:
                bounds.append((start, i, False))
                start = i
                inside = line.strip() in ("```rig", "```rig reject", "```rig pending", "```rig fragment")
                if not inside:
                    inside = "other"
            else:
                bounds.append((start, i + 1, inside is True))
                start = i + 1
                inside = False
    bounds.append((start, len(lines), False))
    return bounds


def migrate(text, kind):
    lines = text.split("\n")
    spans = units(lines, kind)
    preset = None
    if kind == "test":
        for l in lines[spans[0][0]:spans[0][1]]:
            m = USE.match(l)
            if m:
                preset = m.group(2) or "text"
    out = []
    left = []
    for a, b, is_code in spans:
        part = lines[a:b]
        if is_code:
            got, kept = migrate_unit(part, preset)
            left.extend(a + k + 1 for k in kept)
        elif kind == "md":
            got = [PROSE.sub(lambda m: "`text.Interner" + (m.group(1) or "") + "`", l) for l in part]
        else:
            got = part
        out.extend(got)
    return "\n".join(out), left


def files(paths):
    for p in paths:
        if os.path.isfile(p):
            yield p
            continue
        for root, dirs, names in os.walk(p):
            dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("zig-cache", "zig-out")]
            for name in sorted(names):
                if name.endswith((".rig", ".rig.test", ".md")):
                    yield os.path.join(root, name)


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip())
        return 2
    for path in files(argv[1:]):
        with open(path, newline="") as f:
            text = f.read()
        kind = "md" if path.endswith(".md") else "test" if path.endswith(".rig.test") else "rig"
        new, left = migrate(text, kind)
        for n in left:
            print(f"CHECK {path}:{n}: declares its own Symbols; rewrite this line by hand")
        if new != text:
            with open(path, "w", newline="") as f:
                f.write(new)
            print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
