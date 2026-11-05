#!/usr/bin/env python3
"""Rewrite a 0.3.0 program's durations, a bare `Int` of nanoseconds, in
the forms a duration takes since 0.3.1 (SPEC "Durations"), where a bare
number is seconds and a unit's keyword names any other unit:

    time.sleep(40 * time.MS)            ->  time.sleep(ms: 40)
    time.sleep(5 * time.US)             ->  time.sleep(us: 5)
    time.sleep(2 * time.SECOND)         ->  time.sleep(2)
    time.sleep(time.MS)                 ->  time.sleep(ms: 1)
    time.sleep(3 * time.MINUTE)         ->  time.sleep(180)
    time.sleep(1_000_000)               ->  time.sleep(ms: 1)
    time.sleep(d)                       ->  time.sleep(ns: d)
    time.within(d, work)                ->  time.within(ns: d, f: work)
    late: time.after(50 * time.MS)      ->  late: time.after(ms: 50)
    time.Instant.at(5)                  ->  time.Instant.at(ns: 5)
    t.add(3 * time.SECOND)              ->  t.add(3)
    task.supervise(f, per: time.MINUTE) ->  task.supervise(f, per: 60)

Every rewrite keeps what the call means. A count times one of std.time's
constants takes the constant's unit; an integer literal takes the
largest unit that counts it whole; anything else keeps its nanoseconds
with `ns:`. `per:` of `task.supervise` and `*Actor.supervised` is in
seconds: a literal, or a literal count of a unit, becomes its seconds
(`per: 1000` -> `per: 0.000001`); any other value it leaves, printing
`MANUAL path:line` with the fix.

It finds `X.sleep(`, `X.after(`, and `X.within(` of `std.time`, `X`
being `time` or the name of `use std.time as X`; `Instant.at(`; and
`.add(` when its argument names a constant of std.time, which it takes
for an Instant's and prints as `CHECK path:line` (an `.add(d)` of an
Instant with no constant in it is not found: look for those by hand). In
a Markdown file it rewrites the ```rig blocks only. A call already in
the new form (a unit's keyword, or a float) is left alone; a program is
migrated once, since a bare number it wrote for 0.3.0 cannot be told
from one written since.

usage: tools/migrate-durations.py [--dry-run] PATH...
  Each PATH is a file or a directory searched for .rig, .rig.test, and
  .md files. It prints each rewrite, and each file it changes with its
  count; --dry-run changes nothing.
"""
import os, re, sys
from decimal import Decimal

OPEN = {"(": ")", "[": "]", "{": "}"}
CLOSE = set(OPEN.values())
UNITS = {"NS": 1, "US": 1_000, "MS": 1_000_000, "SECOND": 1_000_000_000, "MINUTE": 60_000_000_000}
KEYWORD = re.compile(r"^[A-Za-z_]\w*:\s")
INT = re.compile(r"^-?\d[\d_]*$")
FLOAT = re.compile(r"^-?\d[\d_]*(\.\d[\d_]*([eE][+-]?\d+)?|[eE][+-]?\d+)$")
FENCE = re.compile(r"^```rig[^\n]*\n(.*?)^```", re.S | re.M)


def skip_string(text, i):
    """The index past the string literal opening at `i`."""
    q = text[i]
    i += 1
    while i < len(text) and text[i] != q and text[i] != "\n":
        i += 2 if text[i] == "\\" else 1
    return i + 1


def close_of(text, i):
    """The index of the bracket closing the one at `i`, or -1."""
    depth = []
    while i < len(text):
        c = text[i]
        if c == '"':
            i = skip_string(text, i)
            continue
        if c == "#":
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        if c in OPEN:
            depth.append(OPEN[c])
        elif c in CLOSE:
            if not depth or depth.pop() != c:
                return -1
            if not depth:
                return i
        i += 1
    return -1


def args_of(text, open_at, close):
    """The arguments between `open_at`'s `(` and `close`, as (start,
    end) spans of their text, blanks trimmed."""
    spans, depth, start, i = [], 0, open_at + 1, open_at + 1
    while i < close:
        c = text[i]
        if c == '"':
            i = skip_string(text, i)
            continue
        if c in OPEN:
            depth += 1
        elif c in CLOSE:
            depth -= 1
        elif c == "|" and depth == 0 and not text[start:i].strip():
            # A closure's parameters, `|a, b|`, hold commas of their own.
            j = text.find("|", i + 1)
            i = j + 1 if j > 0 else i + 1
            continue
        elif c == "," and depth == 0:
            spans.append(trim(text, start, i))
            start = i + 1
        i += 1
    if text[start:close].strip():
        spans.append(trim(text, start, close))
    return spans


def trim(text, start, end):
    while start < end and text[start].isspace():
        start += 1
    while end > start and text[end - 1].isspace():
        end -= 1
    return start, end


def factors(expr):
    """`expr`'s factors when it is a product at its top level, `a * b`;
    None when it holds another operator there."""
    out, depth, start, i = [], 0, 0, 0
    while i < len(expr):
        c = expr[i]
        if c == '"':
            return None
        if c in OPEN:
            depth += 1
        elif c in CLOSE:
            depth -= 1
        elif depth == 0:
            if c == "*" and expr[i + 1 : i + 2] not in ("%", "|", "*"):
                out.append(expr[start:i].strip())
                start = i + 1
            elif c in "+/%<>=&|^?!" or (c == "-" and expr[:i].strip()):
                return None
            elif c == " " and re.match(r" (or|and|if|else|catch|as) ", expr[i:]):
                return None
        i += 1
    out.append(expr[start:].strip())
    return out if all(out) else None


def count_of(expr, aliases):
    """`expr` as a count of one of std.time's constants: (count, the
    constant's name), the count "1" for a constant alone; or None."""
    parts = factors(expr)
    if parts is None:
        return None
    names = [m.group(1) for p in parts for m in [re.fullmatch(r"(?:%s)\.(%s)" % ("|".join(aliases), "|".join(UNITS)), p)] if m]
    if len(names) != 1:
        return None
    rest = [unparen(p) if len(parts) == 2 else p for p in parts if not re.fullmatch(r"(?:%s)\.(%s)" % ("|".join(aliases), "|".join(UNITS)), p)]
    return (" * ".join(rest) if rest else "1", names[0])


def unparen(p):
    """`p` without parentheses around the whole of it: `(i % 7)`."""
    if p.startswith("(") and close_of(p, 0) == len(p) - 1:
        return p[1:-1].strip()
    return p


def literal(text):
    return int(text.replace("_", "")) if INT.match(text) else None


def seconds(n_ns):
    """The seconds in `n_ns` nanoseconds, as a literal."""
    d = Decimal(n_ns) / Decimal(10**9)
    return str(int(d)) if d == d.to_integral_value() else format(d.normalize(), "f")


def by_unit(expr, aliases):
    """The argument a duration of `expr` nanoseconds becomes."""
    c = count_of(expr, aliases)
    if c:
        k, name = c
        n = literal(k)
        if name == "SECOND":
            return k
        if name == "MINUTE":
            return str(60 * n) if n is not None else "60 * %s" % paren(k)
        return "%s: %s" % ({"MS": "ms", "US": "us", "NS": "ns"}[name], k)
    n = literal(expr)
    if n is not None:
        if n == 0 or n % 10**9 == 0:
            return str(n // 10**9)
        for unit, size in (("ms", 10**6), ("us", 10**3)):
            if n % size == 0:
                return "%s: %d" % (unit, n // size)
        return "ns: %s" % expr
    return "ns: %s" % expr


def in_seconds(expr, aliases):
    """The seconds `per: expr`, of nanoseconds, becomes; None when they
    are not known as written."""
    c = count_of(expr, aliases)
    if c:
        k, name = c
        if name == "SECOND":
            return k
        if name == "MINUTE":
            n = literal(k)
            return str(60 * n) if n is not None else "60 * %s" % paren(k)
        n = literal(k)
        return seconds(n * UNITS[name]) if n is not None else None
    n = literal(expr)
    return seconds(n) if n is not None else None


def paren(k):
    return k if re.fullmatch(r"[\w.@]+(\([^()]*\))?", k) else "(%s)" % k


def new_form(arg):
    return bool(KEYWORD.match(arg)) or bool(FLOAT.match(arg))


def rewrite(text, path, base, aliases, out):
    """`text` with its durations rewritten, and how many; `base` is the
    line `text` starts on in its file."""
    a = "|".join(re.escape(x) for x in aliases)
    call = re.compile(r"(?<![\w.@])(?:(?:%s)\.(sleep|after|within)|(?:(?:%s)\.)?Instant\.(at)|task\.(supervise)|Actor\.(supervised))(?:\[[^\[\]]*\])?\(|\.(add)\(" % (a, a))
    n, i = 0, 0
    while True:
        m = call.search(text, i)
        if not m:
            return text, n
        i = m.end()
        # Not in a string or a comment's prose after a `"`.
        line_start = text.rfind("\n", 0, m.start()) + 1
        if text.count('"', line_start, m.start()) % 2:
            continue
        kind = next(g for g in m.groups() if g)
        open_at = m.end() - 1
        close = close_of(text, open_at)
        if close < 0:
            continue
        spans = args_of(text, open_at, close)
        line = base + text.count("\n", 0, m.start())
        where = "%s:%d" % (path, line)
        edits = []
        if kind in ("supervise", "supervised"):
            for s, e in spans:
                arg = text[s:e]
                pm = re.match(r"per:\s*", arg)
                if not pm:
                    continue
                value = arg[pm.end() :]
                if FLOAT.match(value):
                    continue
                secs = in_seconds(value, aliases)
                if secs is None:
                    out.append("MANUAL %s: `per: %s` is nanoseconds, and `per:` is seconds now: write the seconds it counts" % (where, value))
                    continue
                edits.append((s + pm.end(), e, secs))
        else:
            if not spans:
                continue
            s, e = spans[0]
            arg = text[s:e]
            if new_form(arg):
                continue
            if kind == "add" and not count_of(arg, aliases) and not re.search(r"(?:%s)\.(%s)\b" % (a, "|".join(UNITS)), arg):
                continue
            new = by_unit(arg, aliases)
            if new == arg:
                continue
            edits.append((s, e, new))
            # A positional argument after a keyword is named: `f: work`.
            if kind == "within" and ":" in new and len(spans) > 1:
                s2, e2 = spans[1]
                second = text[s2:e2]
                if not KEYWORD.match(second) and not second.startswith("|"):
                    edits.append((s2, s2, "f: "))
            if kind == "add":
                out.append("CHECK %s: `.add(%s)` taken as an Instant's" % (where, arg))
        if not edits:
            continue
        old = text[m.start() : close + 1]
        for s, e, new in sorted(edits, reverse=True):
            text = text[:s] + new + text[e:]
            close += len(new) - (e - s)
        out.append("%s: %s -> %s" % (where, one_line(old), one_line(text[m.start() : close + 1])))
        n += 1
        i = m.start() + 1


def one_line(s):
    return " ".join(s.split())


def aliases_of(text):
    names = {"time"}
    for m in re.finditer(r"^\s*use std\.time as (\w+)", text, re.M):
        names.add(m.group(1))
    return sorted(names)


def migrate(text, path):
    """`text` of the file at `path` migrated, its count, and its report."""
    out = []
    aliases = aliases_of(text)
    if not path.endswith(".md"):
        new, n = rewrite(text, path, 1, aliases, out)
        return new, n, out
    pieces, n, last = [], 0, 0
    for m in FENCE.finditer(text):
        body, k = rewrite(m.group(1), path, text.count("\n", 0, m.start(1)) + 1, aliases_of(m.group(1)), out)
        pieces.append(text[last : m.start(1)])
        pieces.append(body)
        last = m.end(1)
        n += k
    pieces.append(text[last:])
    return "".join(pieces), n, out


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
        with open(path, encoding="utf-8") as f:
            text = f.read()
        new, n, out = migrate(text, path)
        for line in out:
            print(line)
        if n:
            total += n
            print("%s: %d" % (path, n))
            if not dry:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(new)
    print("%d rewritten" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
