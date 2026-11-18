#!/usr/bin/env python3
"""Drop the parentheses a self sigil no longer needs: `?`, `!`, or `<`
before a place reaches the self of the method call after it, so the
call is written short, and only a write call whose `Bool` value is
used keeps its `!` in parentheses, as
does an assignment's target (SYNTAX "Self sigils"):

    x = (!v).pop() ?? 0        ->  x = !v.pop() ?? 0
    t = (!@).new_node(k)       ->  t = !@new_node(k)
    for x in (!b).drain()      ->  for x in !b.drain()
    d = (?p).dist(q)           ->  d = ?p.dist(q)
    (<conn).close()            ->  <conn.close()
    if (!seen).add(k)              (kept: its value is a `Bool`)
    (!a).at_mut(i).n = 1           (kept: an assignment's target)

A site is `(SIGIL PLACE).m(` where PLACE is a name, `@`, or `@name`,
with the fields and elements after it (`a.b[i]`), outside strings and
comments, and not written after a name or a bracket that would make it
a call's arguments, nor at the start of a statement that assigns. The
short form means what the long form does, so a rewrite never changes
what a program does; the compiler says which sites keep their
parentheses. The script rewrites every site, runs `RIG check`, and puts
back the parentheses at each site the compiler reports as a `Bool`, or
on a line with an error the program did not have before, until none is
left.

With DIR, it rewrites every `.rig` file under DIR and runs `RIG check`
with each group of ARGS. Every file a site is rewritten in must be read
by some check, or its `Bool` sites stay short and are rejected the next
time it is checked.

With `--md`, it rewrites the ```rig blocks of each Markdown FILE, the
blocks the doc tests read: each program, with the `file=` modules
before it, is checked on its own in a folder of its own. A block the
compiler cannot judge, a ```rig fragment, keeps every site, and each is
listed as `FRAGMENT` to be judged by hand.

usage: tools/drop-write-parens.py [--dry-run] RIG DIR ARGS [-- ARGS ...]
       tools/drop-write-parens.py [--dry-run] --md RIG FILE.md ...
  ARGS are `rig check`'s, one group per check: a program, `main.rig`,
  or a module with its tests, `--tests src/core`. `--dry-run` counts
  the sites and leaves every file as it was.
"""
import os, re, shutil, subprocess, sys, tempfile

ERROR = re.compile(r"^(\S+\.rig):(\d+):(\d+): error: (.*)$")
BOOL = "to write and never negates: write `"
NAME = r"[A-Za-z_]\w*"
PLACE = r"(?:@(?:%s)?|%s)(?:\.%s|\[[^\[\]()\n]*\])*" % (NAME, NAME, NAME)
SITE = re.compile(r"\(([!?<])(%s)\)\.(%s)\s*[(\[]" % (PLACE, NAME))
BEFORE = set(" \t\n([{,")
FENCE = re.compile(r"^```rig([ \t].*)?$")


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


def assigns(rest):
    """Whether `rest`, a line from a statement's start, assigns: an `=`
    or a compound `op=` outside brackets, which is no comparison or
    match arm."""
    depth, i = 0, 0
    while i < len(rest):
        c = rest[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c in "\"'#":
            return False
        elif c == "=" and depth == 0:
            prev = rest[i - 1] if i else ""
            nxt = rest[i + 1] if i + 1 < len(rest) else ""
            if nxt not in "=>" and (prev not in "=!<>" or rest[i - 2 : i] in ("<<", ">>")):
                return True
            i += 1
        i += 1
    return False


def sites_of(text):
    """Each site in `text`: (start, end, short), where text[start:end] is
    `(SIGIL PLACE)` and `short` what replaces it, `SIGIL PLACE` (`!@` for
    `(!@).`, whose `.` goes too)."""
    mask = code_mask(text)
    out = []
    for m in SITE.finditer(text):
        s = m.start()
        if not mask[s] or (s > 0 and text[s - 1] not in BEFORE):
            continue
        bol = text.rfind("\n", 0, s) + 1
        eol = text.find("\n", s)
        if text[bol:s].strip() == "" and assigns(text[s : len(text) if eol < 0 else eol]):
            continue
        sigil, place = m.group(1), m.group(2)
        end = m.start() + len(place) + 3
        if place == "@":
            out.append((s, end + 1, sigil + "@"))
        else:
            out.append((s, end, sigil + place))
    return out


def render(text, sites, active):
    """`text` with each active site written short, and where each active
    site's sigil lands, as (line, column) -> site index."""
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
    for args, cwd in groups:
        p = subprocess.run([rig, "check", *args], capture_output=True, text=True, cwd=cwd)
        for l in (p.stdout + p.stderr).split("\n"):
            e = ERROR.match(l)
            if e:
                path = os.path.realpath(os.path.join(cwd or ".", e.group(1)))
                errors.append((path, int(e.group(2)), int(e.group(3)), e.group(4)))
    return errors


def rig_units(root):
    """Each `.rig` file under `root` with a site, by path: its text."""
    units = {}
    for d, _, names in os.walk(root):
        for f in names:
            if f.endswith(".rig"):
                path = os.path.realpath(os.path.join(d, f))
                with open(path) as fh:
                    units[path] = fh.read()
    return units


def md_blocks(path):
    """The ```rig blocks of the Markdown file at `path`: (first line,
    last line, fence words, file name or None), lines counted from 0,
    the body between them."""
    with open(path) as fh:
        lines = fh.read().split("\n")
    out, i = [], 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if not m:
            i += 1
            continue
        words = (m.group(1) or "").split()
        j = i + 1
        while j < len(lines) and lines[j] != "```":
            j += 1
        fname = next((w[5:] for w in words if w.startswith("file=")), None)
        out.append((i + 1, j, words, fname))
        i = j + 1
    return lines, out


def main():
    argv = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry = len(argv) != len(sys.argv) - 1
    md = "--md" in argv
    argv = [a for a in argv if a != "--md"]
    if len(argv) < 2 or (not md and len(argv) < 3):
        sys.exit(__doc__.strip().split("\n\n")[-1])
    rig = os.path.abspath(argv[0])

    # Each unit is a file the checks read: its text, its sites, and
    # which are written short.
    units, groups, docs, tmp, origin = {}, [], {}, None, {}
    if not md:
        root, rest = argv[1], argv[2:]
        group = []
        for a in rest + ["--"]:
            if a == "--":
                if group:
                    groups.append((group, None))
                group = []
            else:
                group.append(a)
        units = rig_units(root)
    else:
        tmp = tempfile.mkdtemp(prefix="drop-write-parens-")
        for doc in argv[1:]:
            lines, blocks = md_blocks(doc)
            docs[doc] = (lines, [])
            pending = []
            for n, (a, b, words, fname) in enumerate(blocks):
                body = "\n".join(lines[a:b]) + "\n"
                if "fragment" in words:
                    for s, _, _ in sites_of(body):
                        print("FRAGMENT %s:%d" % (doc, a + 1 + body.count("\n", 0, s)))
                    continue
                pending.append((a, b, fname or "main.rig", body))
                if fname:
                    continue
                d = os.path.join(tmp, "%d-%d" % (len(groups), n))
                for a2, b2, name, text in pending:
                    path = os.path.realpath(os.path.join(d, name))
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    units[path] = text
                    origin[path] = (doc, a2)
                    docs[doc][1].append((a2, b2, path))
                groups.append((["main.rig"], d))
                pending = []

    files = {}
    for path, text in units.items():
        sites = sites_of(text)
        if sites or md:
            files[path] = {"text": text, "sites": sites, "active": set(range(len(sites)))}
    def at(path, line):
        """Where line `line` of `path` is, in its Markdown file if any."""
        doc, a = origin.get(path, (path, 0))
        return "%s:%d" % (doc, a + line)

    if md:
        for path, f in files.items():
            with open(path, "w") as fh:
                fh.write(f["text"])

    before = {(p, m) for p, _, _, m in check(rig, groups)}
    out = {}
    try:
        while True:
            where = {}
            for path, f in files.items():
                out[path], where[path] = render(f["text"], f["sites"], f["active"])
                with open(path, "w") as fh:
                    fh.write(out[path])
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
                            print("KEPT %s: %s" % (at(path, line), msg))
            if back == 0:
                break
        left = [(p, l, c, m) for p, l, c, m in check(rig, groups) if (p, m) not in before]
    finally:
        if dry and not md:
            for path, f in files.items():
                with open(path, "w") as fh:
                    fh.write(f["text"])
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    if md and not dry:
        for doc, (lines, blocks) in docs.items():
            new = list(lines)
            # Last block first, so each splice keeps the lines before it.
            for a, b, path in sorted(blocks, reverse=True):
                body = out.get(path, files[path]["text"])
                new[a:b] = body[:-1].split("\n") if body.endswith("\n") else body.split("\n")
            if new != lines:
                with open(doc, "w") as fh:
                    fh.write("\n".join(new))
    total = sum(len(f["sites"]) for f in files.values())
    short = sum(len(f["active"]) for f in files.values())
    for p, l, c, m in left:
        print("MANUAL %s:%d: %s" % (at(p, l), c, m))
    print("%d sites in %d files: %d %s short, %d keep their parentheses" % (total, sum(1 for f in files.values() if f["sites"]), short, "would be written" if dry else "written", total - short))


if __name__ == "__main__":
    main()
