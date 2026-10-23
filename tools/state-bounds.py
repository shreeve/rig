#!/usr/bin/env python3
"""Write the bounds a `pub` generic must state, from the compiler's own fixes.

A `pub` generic names by bounds everything its body does with each type
parameter (SPEC, "Bounds"). Where it does not, `rig check` reports the
error at the parameter, in its brackets, with the bounds to write:

    lib.rig:1:15: error: `pub fun sum[T]` adds `T`s: write `[T: Num]`

This script runs `rig check` on each ENTRY (a program, or a module, as
`rig check` takes it), reads each such fix, writes it into the brackets
(`[T]` becomes `[T: Num]`, `[T: Num]` becomes `[T: Copy + Num]`), and
checks again until no fix is left. The compiler is the authority: the
script decides nothing, it only writes what the errors say.

    tools/state-bounds.py src/main.rig             # rewrite in place
    tools/state-bounds.py --dry-run src/main.rig   # print the diff, change nothing
    RIG_STD=$PWD/std tools/state-bounds.py all.rig # std/, read from disk

It ends with the count of type parameters and declarations changed. An error with no fix it
can write (a method called on a `T` that no API names, or any other
error) stops it, printed, with exit status 1.
"""

import argparse
import difflib
import os
import re
import subprocess
import sys

ERROR = re.compile(r"^(?P<file>.+?):(?P<line>\d+):(?P<col>\d+): error: (?P<msg>.*)$")
FIX = re.compile(r"write `\[(?P<name>[A-Za-z_][A-Za-z0-9_]*): (?P<bounds>[^\]`]+)\]`$")
MAX_ROUNDS = 1000


def check(rig, entries, tests):
    """Every error `rig check` reports for the entries, as (file, line, col, message)."""
    errors = []
    for entry in entries:
        cmd = [rig, "check"] + (["--tests"] if tests else []) + [entry]
        out = subprocess.run(cmd, capture_output=True, text=True)
        for text in (out.stdout + out.stderr).splitlines():
            m = ERROR.match(text)
            if m:
                errors.append((m["file"], int(m["line"]), int(m["col"]), m["msg"]))
    # One finding reached from two entries is one.
    return list(dict.fromkeys(errors))


def entry_span(text, start):
    """The end of the bracket entry that starts at `start`: the next `,` or
    `]` outside nested brackets."""
    depth = 0
    i = start
    while i < len(text):
        c = text[i]
        if c in "[(":
            depth += 1
        elif c in ")]":
            if depth == 0:
                break
            depth -= 1
        elif c == "," and depth == 0:
            break
        i += 1
    return i


def offset_of(text, line, col):
    """The offset of 1-based `line`, `col` (in bytes, as rig counts) in `text`."""
    lines = text.split("\n")
    if line > len(lines):
        return None
    head = sum(len(l) + 1 for l in lines[: line - 1])
    raw = lines[line - 1].encode()[: col - 1].decode(errors="ignore")
    return head + len(raw)


def apply(fixes):
    """Write each fix: {(file, line, col): (name, {bounds})}. Returns the
    number of entries rewritten."""
    by_file = {}
    for (path, line, col), fix in fixes.items():
        by_file.setdefault(path, []).append((line, col, fix))
    changed = 0
    for path, items in by_file.items():
        with open(path, encoding="utf-8") as f:
            text = f.read()
        edits = []
        for line, col, (name, bounds) in items:
            at = offset_of(text, line, col)
            if at is None or not text.startswith(name, at) or (text[at + len(name) : at + len(name) + 1].isalnum()):
                sys.exit(f"state-bounds: {path}:{line}:{col} is not `{name}` in brackets; nothing written")
            edits.append((at, entry_span(text, at), f"{name}: {' + '.join(bounds)}"))
        for start, end, entry in sorted(edits, reverse=True):
            if text[start:end].strip() != entry:
                text = text[:start] + entry + text[end:]
                changed += 1
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
    return changed


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("entries", nargs="+", metavar="ENTRY", help="a program or module `rig check` takes")
    ap.add_argument("--dry-run", action="store_true", help="print the diff, and leave every file as it was")
    ap.add_argument("--rig", default=os.environ.get("RIG", "bin/rig"), help="the compiler (default: $RIG, else bin/rig)")
    ap.add_argument("--tests", action="store_true", help="check with `--tests`: a directory module's `*_test.rig` files too")
    args = ap.parse_args()

    originals = {}
    declarations = set()
    try:
        for _ in range(MAX_ROUNDS):
            errors = check(args.rig, args.entries, args.tests)
            fixes = {}
            unfixed = []
            for path, line, col, msg in errors:
                m = FIX.search(msg)
                if not m or not msg.startswith("`pub "):
                    unfixed.append(f"{path}:{line}:{col}: {msg}")
                    continue
                # One fix per parameter a round: the next round's error
                # carries what this one wrote, so each fix is the
                # compiler's whole list.
                key = (path, line, col)
                if key not in fixes:
                    fixes[key] = (m["name"], [b.strip() for b in m["bounds"].split("+")])
            if not fixes:
                if unfixed:
                    print("state-bounds: errors with no fix to write:", file=sys.stderr)
                    for u in unfixed:
                        print("  " + u, file=sys.stderr)
                    return finish(originals, declarations, args.dry_run, 1)
                return finish(originals, declarations, args.dry_run, 0)
            for path, line, col in fixes:
                if path not in originals:
                    with open(path, encoding="utf-8") as f:
                        originals[path] = f.read()
                declarations.add((path, line, col))
            if apply(fixes) == 0:
                print("state-bounds: the fixes are written, and rig still asks for them", file=sys.stderr)
                return finish(originals, declarations, args.dry_run, 1)
        print(f"state-bounds: not clean after {MAX_ROUNDS} rounds", file=sys.stderr)
        return finish(originals, declarations, args.dry_run, 1)
    except BaseException:
        if args.dry_run:
            restore(originals)
        raise


def restore(originals):
    for path, text in originals.items():
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)


def finish(originals, declarations, dry_run, status):
    """Print the diff (on a dry run, restoring every file) and the count."""
    for path in sorted(originals):
        with open(path, encoding="utf-8") as f:
            now = f.read()
        if dry_run:
            sys.stdout.writelines(difflib.unified_diff(originals[path].splitlines(True), now.splitlines(True), "a/" + path, "b/" + path))
    if dry_run:
        restore(originals)
    decls = len({(path, line) for path, line, _ in declarations})
    print(f"state-bounds: {len(declarations)} type parameter(s) of {decls} declaration(s) in {len(originals)} file(s) {'would state' if dry_run else 'state'} their bounds", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
