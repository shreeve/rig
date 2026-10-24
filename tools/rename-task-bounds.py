#!/usr/bin/env python3
"""Rewrite Rig sources for the task bounds `Sends` and `Syncs`.

    rename-task-bounds.py PATH...             rewrite in place
    rename-task-bounds.py --dry-run PATH...   print the diff, change nothing

Rewrites every `.rig`, `.rig.test`, and `.md` file under each PATH (a
directory, or a file of one of those kinds). The built-in bounds a type
needs to cross to other tasks are `Sends` (it may go to another task)
and `Syncs` (several tasks may read it at once); `Moves` and `Shares`,
their earlier names, are rejected with the new ones.

In each program (a `.rig` file, a case of a `.rig.test` file, a code
block of a `.md` file), `Moves` becomes `Sends` and `Shares` becomes
`Syncs` wherever the word stands in code, outside strings and comments:
in a type parameter's bounds (`[T: Moves + Clone]`), on a type's or an
API's header (`api Job: Moves`), in an API object's braces
(`^{Job + Moves}`), and in a method's bounds. A name after a `.`
(another module's `m.Moves`) is left. In a `.md` file's prose, a
`` `...` `` span is rewritten by the same rule.

A program that declares its own `Moves` or `Shares` (an `obj`, `enum`,
`error`, `api`, or `type` of that name, in the file or in a `.rig` file
beside it, which is the same directory module) keeps it, and each line
naming it is reported as `CHECK path:line` for a person to decide.

Prints each file it changed (or its diff, with `--dry-run`). Running it
again changes nothing.
"""
import difflib
import os
import re
import sys

RENAMES = {"Moves": "Sends", "Shares": "Syncs"}
WORD = re.compile(r"(?<![A-Za-z0-9_.@$])(Moves|Shares)(?![A-Za-z0-9_])")
OWN = re.compile(r"^\s*(?:pub\s+)?(?:obj|struct|enum|error|api|type)\s+(Moves|Shares)\b")
SPAN = re.compile(r"(`+)(.+?)\1")
HEADER = re.compile(r"^(test|fail|bomb|code|accept) ")
FENCES = ("```rig", "```rig reject", "```rig pending", "```rig fragment")


def split_code(line):
    """The code spans of `line` and the rest (strings and its comment),
    as a list of (text, is_code)."""
    parts, start, i, quote = [], 0, 0, None
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                parts.append((line[start:i + 1], False))
                start, quote = i + 1, None
        elif c in "\"'":
            parts.append((line[start:i], True))
            start, quote = i, c
        elif c == "#":
            parts.append((line[start:i], True))
            parts.append((line[i:], False))
            return parts
        i += 1
    parts.append((line[start:], quote is None))
    return parts


def rename(text):
    return WORD.sub(lambda m: RENAMES[m.group(1)], text)


def migrate_code(lines, own):
    """One program's lines, its bounds renamed. With `own`, the program
    declares a type of one of the old names: nothing is renamed, and the
    indexes of the lines naming one are returned."""
    if own:
        left = [i for i, l in enumerate(lines)
                if any(code and WORD.search(t) for t, code in split_code(l))]
        return lines, left
    out = []
    for line in lines:
        out.append("".join(rename(t) if code else t for t, code in split_code(line)))
    return out, []


def migrate_prose(lines):
    return [SPAN.sub(lambda m: m.group(1) + rename(m.group(2)) + m.group(1), l) for l in lines]


def units(lines, kind):
    """(start, end, is_code) for each program and each stretch of text
    between programs."""
    if kind == "rig":
        return [(0, len(lines), True)]
    bounds = []
    if kind == "test":
        start = 0
        for i, line in enumerate(lines):
            if HEADER.match(line):
                bounds.append((start, i, True))
                start = i
        bounds.append((start, len(lines), True))
        return bounds
    start, inside = 0, None
    for i, line in enumerate(lines):
        if not line.lstrip().startswith("```"):
            continue
        if inside is None:
            bounds.append((start, i, False))
            start, inside = i, line.strip() in FENCES
        else:
            if inside:
                bounds.append((start, i + 1, True))
            else:
                bounds.append((start, i + 1, None))
            start, inside = i + 1, None
    bounds.append((start, len(lines), False))
    return bounds


def owns(lines):
    return any(OWN.match(l) for l in lines)


def migrate(text, kind, beside):
    """The file's text migrated, and the 1-based lines left for a person.
    `beside` says whether a `.rig` file beside it declares an old name."""
    lines = text.split("\n")
    out, left = [], []
    for a, b, is_code in units(lines, kind):
        part = lines[a:b]
        if is_code:
            got, kept = migrate_code(part, beside or owns(part))
            left.extend(a + k + 1 for k in kept)
        elif is_code is False and kind == "md":
            got = migrate_prose(part)
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
            dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in ("zig-cache", "zig-out"))
            for name in sorted(names):
                if name.endswith((".rig", ".rig.test", ".md")):
                    yield os.path.join(root, name)


def declares_beside(path, cache={}):
    """Whether a `.rig` file in `path`'s directory declares `Moves` or
    `Shares`: a directory's files are one module."""
    d = os.path.dirname(os.path.abspath(path))
    if d not in cache:
        found = False
        for name in os.listdir(d):
            if name.endswith(".rig"):
                with open(os.path.join(d, name), newline="") as f:
                    if owns(f.read().split("\n")):
                        found = True
                        break
        cache[d] = found
    return cache[d]


def main(argv):
    dry = "--dry-run" in argv
    paths = [a for a in argv[1:] if a != "--dry-run"]
    if not paths:
        print(__doc__.strip())
        return 2
    for path in files(paths):
        with open(path, newline="") as f:
            text = f.read()
        kind = "md" if path.endswith(".md") else "test" if path.endswith(".rig.test") else "rig"
        beside = kind == "rig" and declares_beside(path)
        new, left = migrate(text, kind, beside)
        for n in left:
            print(f"CHECK {path}:{n}: the program declares its own Moves or Shares; rewrite this line by hand")
        if new == text:
            continue
        if dry:
            sys.stdout.writelines(difflib.unified_diff(
                text.splitlines(True), new.splitlines(True), path, path))
        else:
            with open(path, "w", newline="") as f:
                f.write(new)
            print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
