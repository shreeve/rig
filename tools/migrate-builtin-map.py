#!/usr/bin/env python3
"""Rewrite Rig sources for Map, Set, and Symbols as built-in types.

    migrate-builtin-map.py PATH...

Rewrites in place every `.rig`, `.rig.test`, and `.md` file under each
PATH (a directory, or a file of one of those kinds). `Map`, `Set`, and
`Symbols`, and the types that come with them (`Item`, `Items`, `Keys`,
`Values`, `Members`), are part of the language, named with no import:

  - a line `use std.hash`, or `use std.hash as h`, is removed;
  - `hash.Map[K, V]`, `h.Set[K]`, `hash.Symbols()` and the rest lose the
    module's name: `Map[K, V]`, `Set[K]`, `Symbols()`.

In a `.md` file the `hash.` prefix is removed wherever it names one of
those types, in prose as in code. A file that declares its own `Map`,
`Set`, or `Symbols` keeps it: the built-in one is hidden there, so a
prefixed name in such a file is reported and left for a person.

Prints each file it changed, and `CHECK path:line` for what it left.
"""
import os
import re
import sys

NAMES = ["Map", "Set", "Symbols", "Item", "Items", "Keys", "Values", "Members"]
USE = re.compile(r"^(\s*)use\s+std\.hash(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*(#.*)?$")
OWN = re.compile(r"^\s*(?:pub\s+)?(?:obj|enum|type)\s+(Map|Set|Symbols)\b")


def prefixed(alias):
    return re.compile(r"(?<![A-Za-z0-9_.])" + re.escape(alias) + r"\.(" + "|".join(NAMES) + r")\b")


def migrate_unit(lines, default):
    """One program, or text around programs: its `use std.hash` lines
    removed and its prefixed names made bare, unless it declares its own
    Map, Set, or Symbols. Returns the lines and the indexes it left."""
    aliases = set(default)
    for line in lines:
        m = USE.match(line)
        if m:
            aliases.add(m.group(2) or "hash")
    if not aliases:
        return lines, []
    own = any(OWN.match(line) for line in lines)
    out = []
    left = []
    for n, line in enumerate(lines):
        if USE.match(line) and not own:
            continue
        for alias in aliases:
            pattern = prefixed(alias)
            if not pattern.search(line):
                continue
            if own:
                left.append(n)
                continue
            line = pattern.sub(lambda m: m.group(1), line)
        out.append(line)
    return out, left


HEADER = re.compile(r"^(test|fail|bomb|code|accept) ")


def units(lines, kind):
    """The file's lines split into units migrated apart: a `.rig` file is
    one program; a `.rig.test` file one per case; a `.md` file one per
    code block, and its prose."""
    if kind == "rig":
        return [(0, len(lines))]
    bounds = []
    if kind == "test":
        start = 0
        for i, line in enumerate(lines):
            if HEADER.match(line) and (i > start or bounds):
                bounds.append((start, i))
                start = i
        bounds.append((start, len(lines)))
        return bounds
    start = 0
    inside = False
    for i, line in enumerate(lines):
        if line.lstrip().startswith("```"):
            if not inside:
                bounds.append((start, i))
                start = i
                inside = True
            else:
                bounds.append((start, i + 1))
                start = i + 1
                inside = False
    bounds.append((start, len(lines)))
    return bounds


def migrate(text, kind):
    lines = text.split("\n")
    default = {"hash"} if kind == "md" else set()
    spans = units(lines, kind)
    # A test file's lines before its first case are part of every case.
    if kind == "test":
        for line in lines[spans[0][0]:spans[0][1]]:
            m = USE.match(line)
            if m:
                default.add(m.group(2) or "hash")
    out = []
    left = []
    for a, b in spans:
        got, kept = migrate_unit(lines[a:b], default)
        left.extend(a + k + 1 for k in kept)
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
            print(f"CHECK {path}:{n}: declares its own Map, Set, or Symbols; rewrite this line by hand")
        if new != text:
            with open(path, "w", newline="") as f:
                f.write(new)
            print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
