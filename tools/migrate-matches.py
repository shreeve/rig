#!/usr/bin/env python3
"""Rewrite a pattern test written with `as` as `matches`, which Rig
takes in its place (SPEC "Testing a pattern: matches"):

    if s as .circle(r)          ->  if s matches .circle(r)
    ok = e.state as .ready(_)   ->  ok = e.state matches .ready(_)

`as` keeps naming a value (`if o as x`, `if f() as a, b`, `use m as n`);
only an `as` before a variant pattern, a `.` and a name, changes. In a
Markdown file only code changes: ```rig blocks and `inline` spans.

usage: tools/migrate-matches.py [--dry-run] PATH...
  Each PATH is a file or a directory searched for .rig, .rig.test, and
  .md files. It prints each file it changes, with its count.
"""
import os, re, sys

# A value's last character, then ` as `, then `.name`.
SITE = re.compile(r"(?<=[A-Za-z0-9_)\]?!@]) as (?=\.[A-Za-z_])")
FENCE = re.compile(r"^(\s*)```")
INLINE = re.compile(r"`[^`\n]+`")


def migrate_code(text):
    return SITE.subn(" matches ", text)


def migrate_markdown(text):
    out, n, in_rig = [], 0, False
    for line in text.splitlines(keepends=True):
        m = FENCE.match(line)
        if m:
            info = line.strip()[3:].strip()
            in_rig = (not in_rig) and info.startswith("rig")
            out.append(line)
            continue
        if in_rig:
            line, k = migrate_code(line)
        else:
            k = 0

            def span(m):
                nonlocal k
                s, c = migrate_code(m.group(0))
                k += c
                return s

            line = INLINE.sub(span, line)
        n += k
        out.append(line)
    return "".join(out), n


def files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("zig-cache", ".zig-cache", "node_modules")]
                for name in sorted(names):
                    if name.endswith((".rig", ".rig.test", ".md")):
                        yield os.path.join(root, name)
        else:
            yield p


def main(argv):
    dry = "--dry-run" in argv
    paths = [a for a in argv if a != "--dry-run"]
    if not paths:
        print(__doc__.strip().splitlines()[-4], file=sys.stderr)
        return 2
    total = 0
    for path in files(paths):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        new, n = migrate_markdown(text) if path.endswith(".md") else migrate_code(text)
        if n == 0:
            continue
        total += n
        print(f"{path}: {n}")
        if not dry:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
    print(f"{total} rewritten")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
