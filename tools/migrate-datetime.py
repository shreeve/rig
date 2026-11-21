#!/usr/bin/env python3
"""Rewrite a program's std.time for the `Duration` and `Monotonic` of
std.time (SPEC "Durations"), where a clock gives a `time.Duration`, not
an `Int` of nanoseconds, and `time.now()`, `time.Instant`, and the
constants `NS`, `US`, `MS`, `SECOND`, and `MINUTE` are gone:

    time.now()                         ->  time.monotonic()
    time.Instant, time.Instant.at(x)   ->  time.Monotonic, time.Monotonic.at(x)
    t.elapsed() < 250 * time.MS        ->  t.elapsed() < time.duration(ms: 250)
    t.elapsed() >= time.SECOND         ->  t.elapsed() >= time.duration(1)
    print(t.elapsed())                 ->  print(t.elapsed().ns())
    took = later.since(start)          ->  took = later.since(start).ns()
    a = time.since_start()             ->  a = time.since_start().ns()
    t.add(ns: u.since(v))              ->  t.add(u.since(v))
    time.sleep(ns: 5 * time.MS)        ->  time.sleep(ms: 5)
    Row(ns: t.elapsed())               ->  Row(ns: t.elapsed().ns())
    TIMEOUT = 30 * time.SECOND         ->  TIMEOUT = 30 * 1_000_000_000

Every rewrite keeps what the program means. A reading of the clock
compared with a count of a constant becomes a comparison of durations;
any other reading, `t.elapsed()`, `t.since(u)` or `time.since_start()`,
keeps its `Int` of nanoseconds with `.ns()`, unless it is given to
`ns:` of `sleep`, `within`, `after`, `add` or `at`, which takes the
`Duration` itself; and any other constant
becomes its number of nanoseconds, so arithmetic on them means what it
meant. A constant of nanoseconds a program keeps is better written as
the seconds it counts, `TIMEOUT_S = 30`, passed bare: each line where a
constant becomes a number is printed as `CHECK path:line`, for a person
to tidy.

It finds `X.now()`, `X.Instant`, `X.since_start()`, and `X.NS` and its
kin of `std.time`, `X` being `time` or the name of `use std.time as X`;
and `.elapsed()` and `.since(` in a file that uses std.time, which it
takes for a reading's and prints as `CHECK path:line` once a line. A
`time.since_start` taken as a function value now gives a `Duration`; it
is printed as `MANUAL path:line`. In a Markdown file it rewrites the
```rig blocks only. A program is migrated once.

usage: tools/migrate-datetime.py [--dry-run] PATH...
  Each PATH is a file or a directory searched for .rig, .rig.test, and
  .md files. It prints each rewrite, and each file it changes with its
  count; --dry-run changes nothing.
"""
import os, re, sys

OPEN = {"(": ")", "[": "]", "{": "}"}
CLOSE = set(OPEN.values())
UNITS = {"NS": 1, "US": 1_000, "MS": 1_000_000, "SECOND": 1_000_000_000, "MINUTE": 60_000_000_000}
NUMBER = {"NS": "1", "US": "1_000", "MS": "1_000_000", "SECOND": "1_000_000_000", "MINUTE": "60_000_000_000"}
INT = re.compile(r"^-?\d[\d_]*$")
FENCE = re.compile(r"^```rig[^\n]*\n(.*?)^```", re.S | re.M)
COMPARE = re.compile(r"\s*(<=|>=|==|!=|<|>)\s*")


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
        if c in OPEN:
            depth.append(OPEN[c])
        elif c in CLOSE:
            if not depth or depth.pop() != c:
                return -1
            if not depth:
                return i
        i += 1
    return -1


def operand_end(text, i):
    """The end of the operand starting at `i`: the first `,`, `)`, `]`,
    `}`, line end, `and`, `or`, `if`, or `else` at its own depth."""
    depth = 0
    while i < len(text):
        c = text[i]
        if c == '"':
            i = skip_string(text, i)
            continue
        if c in OPEN:
            depth += 1
        elif c in CLOSE:
            if depth == 0:
                return i
            depth -= 1
        elif depth == 0 and (c in ",\n#" or re.match(r" (and|or|if|else|catch)\b", text[i:])):
            return i
        i += 1
    return i


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
    parts = factors(expr.strip())
    if parts is None:
        return None
    const = re.compile(r"(?:%s)\.(%s)" % ("|".join(aliases), "|".join(UNITS)))
    names = [m.group(1) for p in parts for m in [const.fullmatch(p)] if m]
    if len(names) != 1:
        return None
    rest = [unparen(p) if len(parts) == 2 else p for p in parts if not const.fullmatch(p)]
    return (" * ".join(rest) if rest else "1", names[0])


def unparen(p):
    """`p` without parentheses around the whole of it: `(i % 7)`."""
    if p.startswith("(") and close_of(p, 0) == len(p) - 1:
        return p[1:-1].strip()
    return p


def literal(text):
    return int(text.replace("_", "")) if INT.match(text) else None


def paren(k):
    return k if re.fullmatch(r"[\w.@]+(\([^()]*\))?", k) else "(%s)" % k


def form(k, name):
    """The duration form of `k` of the constant `name`: `ms: 5`, `2`."""
    if name == "SECOND":
        return k
    if name == "MINUTE":
        return "minutes: %s" % k
    return "%s: %s" % ({"MS": "ms", "US": "us", "NS": "ns"}[name], k)


def readings(text, aliases):
    """The spans of each reading of the clock in `text`, in order:
    `t.elapsed()`, `t.since(u)`, and `time.since_start()`."""
    a = "|".join(re.escape(x) for x in aliases)
    pat = re.compile(r"(?<![\w.@])(?:(?:%s)\.since_start\(\)|[@\w][\w.@]*(?:\([^()\n]*\))?\.(?:elapsed\(\)|since\())" % a)
    out = []
    for m in pat.finditer(text):
        end = m.end()
        if text[m.end() - 1] == "(" and not m.group(0).endswith("()"):
            close = close_of(text, m.end() - 1)
            if close < 0:
                continue
            end = close + 1
        out.append((m.start(), end))
    return out


def callee_of(text, at):
    """The name of the call whose argument list holds `at`, or ""."""
    depth, i = 0, at - 1
    while i >= 0:
        c = text[i]
        if c in CLOSE:
            depth += 1
        elif c in OPEN:
            if depth == 0:
                if c != "(":
                    return ""
                m = re.search(r"(\w+)(?:\[[^\[\]]*\])?$", text[:i])
                return m.group(1) if m else ""
            depth -= 1
        elif c == "\n" and depth == 0 and not text[:i].rstrip().endswith((",", "(")):
            return ""
        i -= 1
    return ""


# The calls of std.time whose `ns:` is a duration's unit.
TAKES = ("sleep", "within", "after", "add", "at")


def in_code(text, at):
    """Whether `at` is in code: not in a string nor a comment."""
    line_start = text.rfind("\n", 0, at) + 1
    before = text[line_start:at]
    if before.count('"') % 2 or before.count("`") % 2:
        return False
    return "#" not in before


def rewrite(text, path, base, aliases, out):
    """`text` with its std.time rewritten, and how many; `base` is the
    line `text` starts on in its file."""
    a = "|".join(re.escape(x) for x in aliases)
    n = 0
    checked = set()

    def where(at):
        return "%s:%d" % (path, base + text.count("\n", 0, at))

    def note(kind, at, msg):
        w = where(at)
        if (kind, w) not in checked:
            checked.add((kind, w))
            out.append("%s %s: %s" % (kind, w, msg))

    # A reading compared with a count of a constant: durations compared.
    # Any other reading keeps its nanoseconds with `.ns()`. Back to
    # front, so the spans found stay true.
    for s, e in reversed(readings(text, aliases)):
        if not in_code(text, s):
            continue
        reading = text[s:e]
        if not reading.startswith(tuple(x + "." for x in aliases)):
            note("CHECK", s, "`%s` taken as a reading of the monotonic clock" % reading.split("(")[0])
        m = COMPARE.match(text, e)
        if m:
            end = operand_end(text, m.end())
            c = count_of(text[m.end() : end], aliases)
            if c:
                new = "%stime.duration(%s)" % (m.group(0), form(*c))
                out.append("%s: %s%s -> %s%s" % (where(s), reading, text[e:end], reading, new))
                text = text[:e] + new + text[end:]
                n += 1
                continue
        # `ns: reading` passes the Duration on as it is.
        before = text[:s]
        k = re.search(r"\bns:\s*$", before)
        if k and text[e : e + 1] in (")", ",") and callee_of(text, s) in TAKES:
            out.append("%s: ns: %s -> %s" % (where(s), reading, reading))
            text = text[: k.start()] + reading + text[e:]
            n += 1
            continue
        out.append("%s: %s -> %s.ns()" % (where(s), reading, reading))
        text = text[:e] + ".ns()" + text[e:]
        n += 1

    # `ns: k * time.MS`, a duration of nanoseconds, in its unit.
    for m in reversed(list(re.finditer(r"\bns:\s*", text))):
        if not in_code(text, m.start()) or callee_of(text, m.start()) not in TAKES:
            continue
        end = operand_end(text, m.end())
        c = count_of(text[m.end() : end], aliases)
        if c:
            new = form(*c)
            out.append("%s: ns: %s -> %s" % (where(m.start()), text[m.end() : end], new))
            text = text[: m.start()] + new + text[end:]
            n += 1

    # A count of a constant given bare to a duration, which only a
    # program the checker rejected writes: the duration it names.
    for m in reversed(list(re.finditer(r"[(,]\s*", text))):
        start = m.end()
        if not in_code(text, start) or callee_of(text, start + 1) not in TAKES:
            continue
        end = operand_end(text, start)
        c = count_of(text[start:end], aliases)
        if not c:
            continue
        new = c[0] if c[1] == "SECOND" else "time.duration(%s)" % form(*c)
        out.append("%s: %s -> %s" % (where(start), text[start:end], new))
        text = text[:start] + new + text[end:]
        n += 1

    # Any other constant: its nanoseconds.
    for m in reversed(list(re.finditer(r"(?<![\w.@])(?:%s)\.(%s)\b" % (a, "|".join(UNITS)), text))):
        if not in_code(text, m.start()):
            continue
        note("CHECK", m.start(), "a constant of nanoseconds kept as a number: a duration is better written as its seconds, passed bare")
        out.append("%s: %s -> %s" % (where(m.start()), m.group(0), NUMBER[m.group(1)]))
        text = text[: m.start()] + NUMBER[m.group(1)] + text[m.end() :]
        n += 1

    # `time.now()` and `time.Instant`.
    for m in reversed(list(re.finditer(r"(?<![\w.@])(%s)\.(now\(\)|Instant\b)" % a, text))):
        if not in_code(text, m.start()):
            continue
        new = "%s.%s" % (m.group(1), "monotonic()" if m.group(2) == "now()" else "Monotonic")
        out.append("%s: %s -> %s" % (where(m.start()), m.group(0), new))
        text = text[: m.start()] + new + text[m.end() :]
        n += 1

    for m in re.finditer(r"(?<![\w.@])(?:%s)\.since_start\b(?!\()" % a, text):
        if in_code(text, m.start()):
            out.append("MANUAL %s: `%s` as a value gives a `time.Duration` now: write `|| %s().ns()` for its nanoseconds" % (where(m.start()), m.group(0), m.group(0)))
    return text, n


def aliases_of(text):
    names = {"time"}
    for m in re.finditer(r"^\s*use std\.time as (\w+)", text, re.M):
        names.add(m.group(1))
    return sorted(names)


def uses_time(text):
    return re.search(r"^\s*use std\.time\b", text, re.M) is not None


def migrate(text, path):
    """`text` of the file at `path` migrated, its count, and its report."""
    out = []
    if not path.endswith(".md"):
        if not uses_time(text):
            return text, 0, out
        new, n = rewrite(text, path, 1, aliases_of(text), out)
        return new, n, out
    pieces, n, last = [], 0, 0
    for m in FENCE.finditer(text):
        body = m.group(1)
        k = 0
        if uses_time(body):
            body, k = rewrite(body, path, text.count("\n", 0, m.start(1)) + 1, aliases_of(body), out)
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
