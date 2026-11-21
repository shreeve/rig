#!/usr/bin/env python3
"""Rewrite a program's calls of std.datetime's makers for the rule that
checks a maker called with constants as Rig compiles (SPEC §13): such a
call gives the plain type, so the `!` on it goes, and a constant the
maker refuses is a compile error.

    datetime.Date.new(2026, 1, 31)!              ->  datetime.Date.new(2026, 1, 31)
    Time.new(hour: 8, minute: 30)!               ->  Time.new(hour: 8, minute: 30)
    datetime.DateTime.new(-9999, 1, 1)!.add(...) ->  datetime.DateTime.new(-9999, 1, 1).add(...)

It finds `Date.new(`, `Time.new(` and `DateTime.new(`, reached through
any name (`datetime.Date`, `dt.Date`, `Date`), whose arguments are each
an integer literal, by position or by name, and drops the `!` after the
call when the literal date or time is a real one. Every such call it
leaves is printed for a person, as `MANUAL path:line` with the reason:
one the maker refuses (a program that shows the failure gives the value
at run time, through a parameter), and one handled with `catch` (the
handler never runs). A call whose arguments are constants by name (a
module constant, or a binding never changed) is left for the compiler,
whose error on its `!` names each. A test file's `fail` case whose line
changes is printed as `CHECK path:line`: a position after the call on
that line moves. A Markdown file is rewritten in its ```rig blocks and
its inline code alike; a second run changes nothing.

usage: tools/migrate-constant-makers.py [--dry-run] PATH...
  Each PATH is a file or a directory searched for .rig, .rig.test, and
  .md files. It prints each file it changes with its count; --dry-run
  changes nothing.
"""
import os, re, sys

CALL = re.compile(r"(?<![\w])(?:[A-Za-z_][\w]*\.)*(Date|Time|DateTime)\.new\(")
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


def rewrite(text, path, first_line, out):
    """`text` with the `!` dropped from each maker's call that cannot
    fail, and the count; what it leaves for a person goes to `out`."""
    pieces, last, n = [], 0, 0
    for m in CALL.finditer(text):
        close = close_of(text, m.end() - 1)
        if close < 0:
            continue
        v = values(m.group(1), text[m.end() : close])
        if v is None:
            continue
        line = first_line + text.count("\n", 0, m.start())
        after = text[close + 1 :]
        why = refused(v)
        if why:
            out.append("MANUAL %s:%d: %s, always fails" % (path, line, why))
            continue
        if re.match(r" catch\b", after):
            out.append("MANUAL %s:%d: handled with `catch`, which never runs" % (path, line))
            continue
        if not after.startswith("!"):
            continue
        pieces.append(text[last : close + 1])
        last = close + 2
        n += 1
        if path.endswith(".rig.test"):
            out.append("CHECK %s:%d" % (path, line))
    pieces.append(text[last:])
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
        new, n = rewrite(text, path, 1, out)
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
