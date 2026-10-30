#!/usr/bin/env python3
"""Drop the parentheses a write call no longer needs: a write call whose
value is used is written short, and only one whose method declares a
`Bool` result keeps its `!` in parentheses (SYNTAX "Self sigils"):

    x = (!v).pop() ?? 0        ->  x = !v.pop() ?? 0
    t = (!@).new_node(k)       ->  t = !@new_node(k)
    n = (!@items).remove(0)    ->  n = !@items.remove(0)
    if (!seen).add(k)              (kept: its value is a `Bool`)

A site is `(!PLACE).m(` where PLACE is a name, `@`, or `@name`, with the
fields and elements after it (`a.b[i]`), outside strings and comments,
and not written after a name or a bracket that would make it a call's
arguments, nor as a `for` source, where a `!` is the loop's mode. The short form means what the long form does (the `!` lends
the receiver of the chain's first method call), so a rewrite never
changes what a program does; the compiler says which sites keep their
parentheses. The script rewrites every site of every `.rig` file under
DIR, runs `RIG check` with each group of ARGS, and puts back the
parentheses at each site the compiler reports as a `Bool`, or on a line
with an error the program did not have before, until none is left.

Every file a site is rewritten in must be read by some check, or its
`Bool` sites stay short and are rejected the next time it is checked.

usage: tools/drop-write-parens.py [--dry-run] RIG DIR ARGS [-- ARGS ...]
  ARGS are `rig check`'s, one group per check: a program, `main.rig`,
  or a module with its tests, `--tests src/core`. `--dry-run` counts
  the sites and leaves every file as it was.
"""
import os, re, subprocess, sys

ERROR = re.compile(r"^(\S+\.rig):(\d+):(\d+): error: (.*)$")
BOOL = "a write call whose `Bool` value is used puts its `!` in parentheses"
NAME = r"[A-Za-z_]\w*"
PLACE = r"(?:@(?:%s)?|%s)(?:\.%s|\[[^\[\]()\n]*\])*" % (NAME, NAME, NAME)
SITE = re.compile(r"\(!(%s)\)\.(%s)\s*[(\[]" % (PLACE, NAME))
BEFORE = set(" \t\n([{,")
FOR_SOURCE = re.compile(r"\bfor\b.*\bin\s+$")


def code_mask(text):
    """Whether each character of `text` is code: not in a string, a
    character literal, or a comment."""
    mask = [True] * len(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "#":
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                mask[k] = False
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            for k in range(i, min(j + 1, n)):
                mask[k] = False
            i = j + 1
        else:
            i += 1
    return mask


def sites_of(text):
    """Each site in `text`: (start, end, short), where text[start:end] is
    `(!PLACE)` and `short` what replaces it, `!PLACE` (`!@` for `(!@).`,
    whose `.` goes too)."""
    mask = code_mask(text)
    out = []
    for m in SITE.finditer(text):
        s = m.start()
        if not mask[s] or (s > 0 and text[s - 1] not in BEFORE):
            continue
        if FOR_SOURCE.search(text[text.rfind("\n", 0, s) + 1 : s]):
            continue
        place = m.group(1)
        end = m.start() + len(place) + 3
        if place == "@":
            out.append((s, end + 1, "!@"))
        else:
            out.append((s, end, "!" + place))
    return out


def render(text, sites, active):
    """`text` with each active site written short, and where each active
    site's `!` lands, as (line, column) -> site index."""
    parts, at, where = [], 0, {}
    line, col = 1, 1

    def advance(s):
        nonlocal line, col
        nl = s.count("\n")
        if nl:
            line += nl
            col = len(s) - s.rfind("\n")
        else:
            col += len(s)

    for i, (s, e, short) in enumerate(sites):
        if i not in active:
            continue
        advance(text[at:s])
        parts.append(text[at:s])
        where[(line, col)] = i
        parts.append(short)
        advance(short)
        at = e
    parts.append(text[at:])
    return "".join(parts), where


def check(rig, groups):
    """The errors of every check, as (path, line, column, message)."""
    errors = []
    for args in groups:
        p = subprocess.run([rig, "check", *args], capture_output=True, text=True)
        for l in (p.stdout + p.stderr).split("\n"):
            e = ERROR.match(l)
            if e:
                errors.append((os.path.realpath(e.group(1)), int(e.group(2)), int(e.group(3)), e.group(4)))
    return errors


def main():
    argv = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry = len(argv) != len(sys.argv) - 1
    if len(argv) < 3:
        sys.exit(__doc__.strip().split("\n\n")[-1])
    rig, root, rest = os.path.abspath(argv[0]), argv[1], argv[2:]
    groups, group = [], []
    for a in rest:
        if a == "--":
            if group:
                groups.append(group)
            group = []
        else:
            group.append(a)
    if group:
        groups.append(group)

    files = {}
    for d, _, names in os.walk(root):
        for f in names:
            if f.endswith(".rig"):
                path = os.path.realpath(os.path.join(d, f))
                with open(path) as fh:
                    text = fh.read()
                sites = sites_of(text)
                if sites:
                    files[path] = {"text": text, "sites": sites, "active": set(range(len(sites)))}

    before = {(p, m) for p, _, _, m in check(rig, groups)}
    try:
        while True:
            where = {}
            for path, f in files.items():
                out, where[path] = render(f["text"], f["sites"], f["active"])
                with open(path, "w") as fh:
                    fh.write(out)
            back = 0
            for path, line, col, msg in check(rig, groups):
                f, w = files.get(path), where.get(path, {})
                if f is None:
                    continue
                if BOOL in msg and (line, col) in w:
                    f["active"].discard(w[(line, col)])
                    back += 1
                elif (path, msg) not in before:
                    # An error the program did not have: every site of
                    # its line keeps its parentheses.
                    for (l, _), i in w.items():
                        if l == line and i in f["active"]:
                            f["active"].discard(i)
                            back += 1
                            print("KEPT %s:%d: %s" % (path, line, msg))
            if back == 0:
                break
        left = [(p, l, c, m) for p, l, c, m in check(rig, groups) if (p, m) not in before]
    finally:
        if dry:
            for path, f in files.items():
                with open(path, "w") as fh:
                    fh.write(f["text"])
    total = sum(len(f["sites"]) for f in files.values())
    short = sum(len(f["active"]) for f in files.values())
    for p, l, c, m in left:
        print("MANUAL %s:%d:%d: %s" % (p, l, c, m))
    print("%d sites in %d files: %d %s short, %d keep their parentheses" % (total, len(files), short, "would be written" if dry else "written", total - short))


if __name__ == "__main__":
    main()
