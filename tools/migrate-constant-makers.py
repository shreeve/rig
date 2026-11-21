#!/usr/bin/env python3
"""Rewrite a program's calls of std.datetime's makers for the rule that
checks a maker called with constants as Rig compiles (SPEC §13): such a
call gives the plain type, so the `!` on it goes, and a constant the
maker refuses is a compile error.

    datetime.Date.new(2026, 1, 31)!              ->  datetime.Date.new(2026, 1, 31)
    dt.Time.new(hour: 8, minute: 30)!            ->  dt.Time.new(hour: 8, minute: 30)
    D.new(-9999, 1, 1)!.add(days: 1)             ->  D.new(-9999, 1, 1).add(days: 1)

It reaches the makers only through a name std.datetime is bound to: the
`datetime` of `use std.datetime`, the `X` of `use std.datetime as X`, or
a `type` alias of `Date`, `Time`, or `DateTime` through one of these, as
`D` above; a program's own `Time.new` is left as it is. It drops the `!`
after a call whose arguments are each an integer literal, by position or
by name, when the literal date or time is a real one, and leaves text in
a string as it is. A literal call the maker refuses, with a `!` or a
`catch`, and a real one handled with `catch` (whose handler never runs),
it leaves and prints for a person, as `MANUAL path:line` with the reason.
A call whose arguments are constants by name (a module constant, or a
binding never changed) it leaves without a word, for the compiler, whose
error on its `!` names each. In a test file it leaves the `fail` cases,
which show errors, and prints each line it changes as `CHECK path:line`,
since a position after the call on that line moves; in a Markdown file
it rewrites the ```rig blocks only, not the prose. A second run changes
nothing.

usage: tools/migrate-constant-makers.py [--dry-run] PATH...
  Each PATH is a file or a directory searched for .rig, .rig.test, and
  .md files. It prints each file it changes with its count; --dry-run
  changes nothing.
"""
import os, re, sys

USE = re.compile(r"^[ \t]*use std\.datetime(?:[ \t]+as[ \t]+(\w+))?[ \t]*$", re.M)
ALIAS = re.compile(r"^[ \t]*(?:pub[ \t]+)?type[ \t]+(\w+)[ \t]*=[ \t]*(\w+)\.(Date|Time|DateTime)[ \t]*$", re.M)
FENCE = re.compile(r"^```rig([^\n]*)\n(.*?)^```", re.S | re.M)
CASE = re.compile(r"^(?:test|fail|bomb|code) ", re.M)
INT = re.compile(r"^-?\d[\d_]*$")
PARTS = {
    "Date": ["year", "month", "day"],
    "Time": ["hour", "minute", "second", "ns"],
    "DateTime": ["year", "month", "day", "hour", "minute", "second", "ns"],
}
DEFAULTS = {"second": 0, "ns": 0, "hour": 0, "minute": 0}
RANGE = {"year": (-9999, 9999), "month": (1, 12), "day": (1, 31), "hour": (0, 23), "minute": (0, 59), "second": (0, 59), "ns": (0, 999_999_999)}


def close_of(text, i):
    """The index of the `)` closing the `(` at `i` on its line, or -1."""
    depth = 0
    while i < len(text) and text[i] != "\n":
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def month_days(y, m):
    if m == 2:
        return 29 if y % 4 == 0 and (y % 100 != 0 or y % 400 == 0) else 28
    return 30 if m in (4, 6, 9, 11) else 31


def values(kind, args):
    """The literal value of each of the maker's parts, or None when an
    argument is not an integer literal."""
    names = PARTS[kind]
    got = {}
    pos = 0
    for a in [x.strip() for x in args.split(",")] if args.strip() else []:
        m = re.fullmatch(r"(\w+):\s*(.*)", a)
        name, lit = (m.group(1), m.group(2)) if m else (names[pos] if pos < len(names) else None, a)
        if not m:
            pos += 1
        if name not in names or not INT.match(lit):
            return None
        got[name] = int(lit.replace("_", ""))
    out = []
    for n in names:
        if n in got:
            out.append(got[n])
        elif n in DEFAULTS:
            out.append(DEFAULTS[n])
        else:
            return None
    return dict(zip(names, out))


def refused(v):
    """Why the maker refuses the parts `v`, or None."""
    for n, x in v.items():
        lo, hi = RANGE[n]
        if n == "day" and lo <= v["month"] <= 12:
            hi = month_days(v["year"], v["month"])
        if not lo <= x <= hi:
            return "%s %d is refused" % (n, x)
    return None


def strings(text):
    """The spans of the string literals in `text`: `"..."`, `'...'`, and
    templates, `` `...` ``, each on its line."""
    out, i = [], 0
    while i < len(text):
        c = text[i]
        if c == "#":
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        if c in "\"'`":
            j = i + 1
            while j < len(text) and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append((i, j + 1))
            i = j + 1
            continue
        i += 1
    return out


def makers(text):
    """The pattern of a maker's call in `text`, reached through the names
    std.datetime is bound to there, and the type each alias names; None
    when it binds none."""
    names = [m.group(1) or "datetime" for m in USE.finditer(text)]
    if not names:
        return None
    aliases = {m.group(1): m.group(3) for m in ALIAS.finditer(text) if m.group(2) in names}
    alts = [r"(?:%s)\.(Date|Time|DateTime)" % "|".join(map(re.escape, names))]
    if aliases:
        alts.append(r"(%s)" % "|".join(map(re.escape, aliases)))
    return re.compile(r"(?<![\w.])(?:%s)\.new\(" % "|".join(alts)), aliases


def rewrite(text, path, first_line, out, found):
    """`text` with the `!` dropped from each maker's call that cannot
    fail, and the count; `found` is what `makers` gave for the file. What
    it leaves for a person goes to `out`."""
    if found is None:
        return text, 0
    call, aliases = found
    quoted = strings(text)
    pieces, last, n = [], 0, 0
    for m in call.finditer(text):
        if any(a <= m.start() < b for a, b in quoted):
            continue
        close = close_of(text, m.end() - 1)
        if close < 0:
            continue
        kind = m.group(1) or aliases[m.group(2)]
        v = values(kind, text[m.end() : close])
        if v is None:
            continue
        line = first_line + text.count("\n", 0, m.start())
        after = text[close + 1 :]
        handled = re.match(r" catch\b", after)
        if not after.startswith("!") and not handled:
            continue
        why = refused(v)
        if why:
            out.append("MANUAL %s:%d: %s, always fails" % (path, line, why))
            continue
        if handled:
            out.append("MANUAL %s:%d: handled with `catch`, which never runs" % (path, line))
            continue
        pieces.append(text[last : close + 1])
        last = close + 2
        n += 1
        if path.endswith(".rig.test"):
            out.append("CHECK %s:%d" % (path, line))
    pieces.append(text[last:])
    return "".join(pieces), n


def migrate(text, path, out):
    """`text` rewritten as its kind of file is, and the count."""
    if path.endswith(".md"):
        pieces, n, last = [], 0, 0
        for m in FENCE.finditer(text):
            body = m.group(2)
            if "reject" not in m.group(1):
                body, k = rewrite(body, path, text.count("\n", 0, m.start(2)) + 1, out, makers(body))
                n += k
            pieces.append(text[last : m.start(2)])
            pieces.append(body)
            last = m.end(2)
        pieces.append(text[last:])
        return "".join(pieces), n
    found = makers(text)
    if not path.endswith(".rig.test"):
        return rewrite(text, path, 1, out, found)
    # A test file case by case, its `fail` cases left as they are.
    starts = [m.start() for m in CASE.finditer(text)] + [len(text)]
    pieces, n = [text[: starts[0]]], 0
    for a, b in zip(starts, starts[1:]):
        case = text[a:b]
        if not case.startswith("fail "):
            case, k = rewrite(case, path, text.count("\n", 0, a) + 1, out, found)
            n += k
        pieces.append(case)
    return "".join(pieces), n


def files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("zig-cache", "zig-out", "node_modules")]
                for name in sorted(names):
                    if name.endswith((".rig", ".rig.test", ".md")):
                        yield os.path.join(root, name)
        else:
            yield p


def main(argv):
    dry = "--dry-run" in argv
    paths = [a for a in argv if a != "--dry-run"]
    if not paths:
        print(__doc__.strip().split("\n\n")[-1], file=sys.stderr)
        return 2
    total = 0
    for path in files(paths):
        with open(path, encoding="utf-8", newline="") as f:
            text = f.read()
        out = []
        new, n = migrate(text, path, out)
        for line in out:
            print(line)
        if n:
            total += n
            print("%s: %d" % (path, n))
            if not dry:
                with open(path, "w", encoding="utf-8", newline="") as f:
                    f.write(new)
    print("%d rewritten" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
