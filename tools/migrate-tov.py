#!/usr/bin/env python3
"""Rewrite a program's std.time and std.datetime for "total or visible"
(docs/design/datetime.md, 10.4): every call is total or returns `!`,
nothing panics, and `Duration` holds its whole seconds and nanoseconds:

    d.add(days: 1)                   ->  d.add(days: 1)!
    i.round(seconds: 1)              ->  i.round(seconds: 1)!
    a.checked_add(b)                 ->  a.add(b)
    Instant.from_unix(x)             ->  Instant.from_unix_s(x)!
    Instant.from_unix(1.5)           ->  Instant.from_unix_float(1.5)!
    Instant.from_unix(ms: t)         ->  Instant.from_unix_ms(t)!
    Instant.from_unix(ns: t)         ->  Instant.from_unix_ns(t)
    Instant.from_unix(d)             ->  Instant.from_unix_s(d.seconds(), ns: d.subsec_ns())!
    n = t.elapsed().ns() + k         ->  n = Int(t.elapsed().ns()) + k
    t.add(minutes: n)                ->  t.add(time.duration(minutes: n)!)
    time.sleep(x)                    ->  time.sleep(time.duration(x)!)!   (a `Float` x)

It is driven by the compiler, as tools/migrate-options.py is: it runs
`rig check` with a Rig that has the rule, and rewrites what each refusal
asks for, where it points: a call that now fails gets `!`; where its
function cannot pass a failure on, the `!` becomes `catch panic("...")`
naming the call, so a panic the library had stays where it was, now in
the program's own source, printed as `MANUAL path:line` for a person to
judge; a `!` on a call that now cannot fail (a constant `Instant` maker)
is dropped; a removed `checked_` method becomes its plain name; an
`I128` reader (`ns()`, `us()`, `ms()`) where an `Int` is wanted is read
through `Int(...)`; and a duration form with a number known only as the
program runs that the callee cannot fail for is made visibly first,
`time.duration(...)!`. `Instant.from_unix(...)` becomes the maker for its
unit by the text of its argument, and the compiler then says which of a
`Float` or a `Duration` it was. `t.checked_add(d)` of a `Time`, whose
`add` wraps past midnight and has no failing twin, a computed `round`
increment of a `Time`, `from_unix` of minutes or hours or several units,
and anything still refused in a file it changed are printed as `MANUAL
path:line`. It checks again until nothing more is refused. In a test file
it checks each case as the test runner writes it out, and in a Markdown
file each ```rig block, with the `file=` blocks before it, leaving the
`pending` and `fragment` blocks as they are. A second run changes
nothing.

usage: tools/migrate-tov.py [--dry-run] [--rig RIG] [-j N] PATH...
  Each PATH is a file or a directory searched for .rig, .rig.test, and
  .md files. RIG is the `rig` to run (default: $RIG, else `rig`). It
  prints each file it changes with its count; --dry-run changes nothing.
"""
import os, re, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

DIAG = re.compile(r"^(\S+\.rig):(\d+):(\d+): error: (.*)$", re.M)
FENCE = re.compile(r"^```rig([^\n]*)$")
HEADER = re.compile(r'^(code|fail|test|bomb) "((?:[^"\\]|\\.)*)"(.*)$')
OPEN = {"(": ")", "[": "]", "{": "}"}

BARE = re.compile(r"^fallible call to `([\w.]+)` must be wrapped with `!`")
NO_PROPAGATE = re.compile(r"^use of `!` propagation requires the enclosing")
NOT_FALLIBLE = re.compile(r"^`!` needs a fallible operand")
CHECKED = re.compile(r"^no method `checked_(add|sub|times)` on type `(\w+)`")
WIDE = re.compile(r"^type mismatch: expected `Int`, got `I128`")
FORM = re.compile(r"^`([^`]+)` (?:is a `Float`, which may not be finite or may be|can be) beyond a `Duration`'s range as the program runs, and this call cannot fail")
WAIT_FLOAT = re.compile(r"^a wait takes no `Float` known only as the program runs")
UNIX_ARG = re.compile(r"^type mismatch: expected `Int`, got `(Float|time\.Duration)`")
TIME_STEP = re.compile(r"^an increment of a `Time`'s `(round|floor)` is a constant")
FROM_UNIX = re.compile(r"\bInstant\.from_unix\(")
# The calls that now fail, which a bare call of is given `!`.
FAILS = {"add", "sub", "times", "div", "round", "floor", "at", "from_parts", "from_unix_s", "from_unix_ms", "from_unix_us", "from_unix_float", "duration"}


# ---- Reading the text ---------------------------------------------------------


def skip_string(text, i):
    """The index past the string or template literal opening at `i`."""
    q = text[i]
    i += 1
    while i < len(text) and text[i] != q and text[i] != "\n":
        i += 2 if text[i] == "\\" else 1
    return i + 1


def arguments(text, open_at):
    """The spans of the arguments of the call whose `(` is at `open_at`,
    split at its top-level commas, and the index of its `)`; None when it
    does not close."""
    spans, start, depth, i = [], open_at + 1, [], open_at + 1
    while i < len(text):
        c = text[i]
        if c in "\"'`":
            i = skip_string(text, i)
            continue
        if c in OPEN:
            depth.append(OPEN[c])
        elif c in ")]}":
            if not depth:
                if c != ")":
                    return None
                if text[start:i].strip():
                    spans.append((start, i))
                return spans, i
            if depth.pop() != c:
                return None
        elif c == "," and not depth:
            spans.append((start, i))
            start = i + 1
        i += 1
    return None


def argument_start(text, offset):
    """Where the argument of a call holding `offset` begins, past its
    spaces; None when no call's argument holds it."""
    depth, i = 0, offset - 1
    while i >= 0:
        c = text[i]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            if depth == 0:
                if c != "(":
                    return None
                # A parenthesis that only groups, `(a)`, is no call's.
                if i == 0 or not (text[i - 1].isalnum() or text[i - 1] in "_])"):
                    i -= 1
                    continue
                got = arguments(text, i)
                for a, b in (got[0] if got else []):
                    if a <= offset <= b:
                        return a + len(text[a:b]) - len(text[a:b].lstrip())
                return None
            depth -= 1
        i -= 1
    return None



def call_close(text, at, name):
    """The `(` and `)` of the call of `name` (its last part) whose callee
    begins at `at`: the first `name(` at the callee's own depth."""
    last = name.split(".")[-1]
    pat = re.compile(r"\b%s\s*\(" % re.escape(last))
    i, depth = at, 0
    while i < len(text):
        c = text[i]
        if c in "\"'`":
            i = skip_string(text, i)
            continue
        if depth == 0:
            m = pat.match(text, i)
            if m and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
                got = arguments(text, m.end() - 1)
                if got is None:
                    return None
                # A call of the same name earlier in a chain that already
                # passes its failure on is not this one: `a.add(b)!.add(c)`.
                if not re.match(r"!|\s+catch\b", text[got[1] + 1 :]):
                    return (m.end() - 1, got[1])
                i = got[1] + 1
                continue
        if c in OPEN:
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return None
            depth -= 1
        elif c == "\n" and depth == 0:
            return None
        i += 1
    return None


def postfix_end(text, at, bang=False):
    """The end of the postfix expression starting at `at`: names, `.`,
    calls and indexes, and `!` after a call, which with `bang` ends it;
    None for anything else."""
    m = re.compile(r"[@?!<+]*[A-Za-z_@][\w]*").match(text, at)
    if not m:
        return None
    i = m.end()
    while i < len(text):
        c = text[i]
        if c in "([":
            got = arguments(text, i) if c == "(" else None
            if c == "(":
                if got is None:
                    return None
                i = got[1] + 1
            else:
                depth, j = 0, i
                while j < len(text):
                    if text[j] == "[":
                        depth += 1
                    elif text[j] == "]":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                i = j + 1
            continue
        if c == "." and i + 1 < len(text) and (text[i + 1].isalpha() or text[i + 1] == "_"):
            m = re.compile(r"\.[A-Za-z_]\w*").match(text, i)
            i = m.end()
            continue
        if c == "!" and text[i - 1] == ")" and text[i + 1 : i + 2] != "=":
            i += 1
            if bang:
                return i
            continue
        break
    return i


def argument_span(text, offset):
    """The span of the whole argument of a call that holds `offset`."""
    start = argument_start(text, offset)
    if start is None:
        return None
    depth, i = 0, start
    while i < len(text):
        c = text[i]
        if c in "\"'`":
            i = skip_string(text, i)
            continue
        if c in OPEN:
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return start, len(text[start:i].rstrip()) + start
            depth -= 1
        elif c == "," and depth == 0:
            return start, len(text[start:i].rstrip()) + start
        i += 1
    return None


def code_spans(path, text):
    """The spans of `text` that are code: a Markdown file's ```rig blocks
    but `pending` and `fragment` ones, a test file's lines but its case
    headers, and the whole of a `.rig` file."""
    if path.endswith(".md"):
        out, pos = [], 0
        for m in re.finditer(r"^```rig([^\n]*)\n(.*?)^```", text, re.S | re.M):
            words = m.group(1).split()
            if "pending" not in words and "fragment" not in words:
                out.append((m.start(2), m.end(2)))
        return out
    if path.endswith(".rig.test"):
        out, pos = [], 0
        for line in text.split("\n"):
            if not HEADER.match(line):
                out.append((pos, pos + len(line)))
            pos += len(line) + 1
        return out
    return [(0, len(text))]


def from_unix(text, spans):
    """`text` with each `Instant.from_unix(...)` in `spans` written as the
    maker for the unit its argument gives, and the lines it leaves for a
    person."""
    out, manual, i = [], [], 0
    while True:
        m = FROM_UNIX.search(text, i)
        while m and not any(a <= m.start() < b for a, b in spans):
            m = FROM_UNIX.search(text, m.end())
        if not m:
            out.append(text[i:])
            return "".join(out), manual
        got = arguments(text, m.end() - 1)
        line = text.count("\n", 0, m.start()) + 1
        if got is None or len(got[0]) != 1:
            out.append(text[i : m.end()])
            i = m.end()
            manual.append((line, "`Instant.from_unix` of several units or none: write the maker of one unit"))
            continue
        args, close = got
        arg = text[args[0][0] : args[0][1]].strip()
        kw = re.match(r"(\w+):\s*(.*)$", arg, re.S)
        unit, value = (kw.group(1), kw.group(2)) if kw else ("seconds", arg)
        bang = text[close + 1 : close + 2] == "!"
        maker = {"seconds": "from_unix_s", "ms": "from_unix_ms", "us": "from_unix_us", "ns": "from_unix_ns"}.get(unit)
        if maker is None:
            out.append(text[i : m.end()])
            i = m.end()
            manual.append((line, "`Instant.from_unix(%s)`: give the time in seconds, ms, us or ns" % arg))
            continue
        if maker == "from_unix_s" and re.fullmatch(r"-?[\d_]*\.[\d_]+(e-?\d+)?|-?[\d_]+e-?\d+", value):
            maker = "from_unix_float"
        fails = maker != "from_unix_ns"
        out.append(text[i : m.start()] + "Instant.%s(%s)%s" % (maker, value, "!" if fails and not bang else ""))
        i = close + 1
        if bang and not fails:
            i += 1


# ---- Programs as the test runner writes them out ------------------------------


def declares(line):
    return bool(re.match(r"(pub )?(inline )?(fun|sub|obj|enum|error|type|use|extern|api) [A-Za-z_\"]", line) or re.match(r"add [A-Za-z_?!*^~(\[]", line))


def refers(body, files, use):
    """Whether a case uses the module of its file's `use` line, as the
    runner decides it (test/rig.rip, `refers`)."""
    m = re.match(r"use\s+([\w.]+)(?:\s+as\s+(\w+))?", use)
    if not m:
        return True
    name = m.group(2) or m.group(1).split(".")[-1]
    lines = body + [l for f in files for l in f["lines"]]
    if not any(re.search(r"\b%s\." % name, l) for l in lines):
        return False
    binds = [
        r"^\s*(pub )?(inline )?(fun|sub)\b[^(]*\(.*\b%s\s*:" % name,
        r"^\s*(new\s+)?%s\s*(:[^=]*)?=(?!=)" % name,
        r"\bfor\s+(\w+\s*,\s*)?%s\b" % name,
        r"\|[^|]*\b%s\b[^|]*\|" % name,
        r"^\s*\.\w+\([^)]*\b%s\b(?!\.)[^)]*\)\s*(=>|$|if\b)" % name,
    ]
    return not any(re.search(b, l) for l in lines for b in binds)


def header_items(rest):
    """The count of a header's results, and whether it says `whole: true`."""
    out, cur, depth, quote, i = [], "", 0, False, 0
    while i < len(rest):
        c = rest[i]
        if quote:
            cur += c
            if c == "\\":
                cur += rest[i + 1 : i + 2]
                i += 1
            elif c == '"':
                quote = False
        elif c == '"':
            quote = True
            cur += c
        elif c in "[({":
            depth += 1
            cur += c
        elif c in "])}":
            depth -= 1
            cur += c
        elif c == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += c
        i += 1
    if cur.strip():
        out.append(cur.strip())
    results = [x for x in out if not re.match(r"[a-z]+:\s*", x)]
    whole = any(re.fullmatch(r"whole:\s*true", x) for x in out)
    return results, whole


def test_cases(text):
    """Each case of a test file: its verb, body lines with the file line of
    each (1-based), its files, its results, whether it is whole, and the
    file's `use` lines."""
    lines = text.split("\n")
    shared, out, cur, i = [], [], None, 0
    while i < len(lines):
        line = lines[i]
        m = HEADER.match(line)
        if m:
            if cur:
                out.append(cur)
            results, whole = header_items(m.group(3).strip()[1:]) if m.group(3).strip() else ([], False)
            if "'''" in results:
                i += 1
                while i < len(lines) and lines[i] != "'''":
                    i += 1
            cur = {"verb": m.group(1), "body": [], "at": [], "results": results, "whole": whole}
        elif cur is not None and (line == "" or line.startswith("  ")):
            cur["body"].append(line[2:])
            cur["at"].append(i + 1)
        elif line.startswith("use "):
            if cur:
                out.append(cur)
            cur = None
            shared.append(line)
        elif cur is not None:
            out.append(cur)
            cur = None
        i += 1
    if cur:
        out.append(cur)
    for c in out:
        c["files"] = []
        at = next((k for k, l in enumerate(c["body"]) if re.fullmatch(r'file "[^"]+"(, hex)?\s*', l)), -1)
        if at >= 0:
            for l, n in zip(c["body"][at:], c["at"][at:]):
                m = re.fullmatch(r'file "([^"]+)"(, hex)?\s*', l)
                if m:
                    c["files"].append({"path": m.group(1), "hex": bool(m.group(2)), "lines": [], "map": []})
                else:
                    f = c["files"][-1]
                    f["lines"].append(l[2:] if l.startswith("  ") else l)
                    f["map"].append((n, 4 if l.startswith("  ") else 2))
            c["body"], c["at"] = c["body"][:at], c["at"][:at]
        while c["body"] and c["body"][-1].strip() == "":
            c["body"].pop()
            c["at"].pop()
        c["shared"] = shared
    return out


def test_program(c):
    """The program the runner writes for case `c`: its lines, and for each
    the file line and the columns added to it (None for a line it adds)."""
    lines, where = [], []

    def add(text, at):
        lines.append(text)
        where.append(at)

    body = c["body"]
    for u in c["shared"]:
        if refers(body, c["files"], u) and u not in body:
            add(u, None)
    if c["whole"] or any(re.match(r"(?![\s#]).*\b(sub|fun) main\b", l) for l in body):
        for l, n in zip(body, c["at"]):
            add(l, (n, 2))
    else:
        decl, stmt, in_decl = [], [], False
        for l, n in zip(body, c["at"]):
            if l != "" and not l.startswith(" ") and not l.startswith("#"):
                in_decl = declares(l)
            (decl if in_decl else stmt).append([l, n, 2])
        for l, n, s in decl:
            add(l, (n, s))
        while stmt and stmt[-1][0].strip() == "":
            stmt.pop()
        if c["verb"] == "test" and c["results"] and stmt and not any(re.search(r"\bprint\(", l) for l in body):
            last = stmt[-1][0]
            bare = not re.match(r"(if|for|while|match|return|break|continue|defer|errdefer|print|warn|panic)\b", last) and not re.match(r"[A-Za-z_][\w.\[\]]*\s*([-+*/%|&^]|<<|>>)?=(?!=)", last) and not last.startswith(" ") and not last.startswith("#")
            if bare:
                stmt[-1] = ["print(%s)" % last, stmt[-1][1], 2 - len("print(")]
        fallible = any(re.search(r"\)!(?!=)", l) for l, _, _ in stmt)
        add("sub main()!" if fallible else "sub main()", None)
        for l, n, s in stmt:
            add("" if l == "" else "  " + l, (n, s - 2))
        if not any(l.strip() != "" and not l.lstrip().startswith("#") for l, _, _ in stmt):
            add("  pass", None)
    return lines, where


def doc_units(text, rejects=True):
    """Each program of a Markdown file's ```rig blocks: its main lines with
    the file line of each, and its `file=` modules, as (path, lines, at)."""
    lines = text.split("\n")
    out, modules, i = [], [], 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if not m:
            i += 1
            continue
        words = m.group(1).split()
        start = i + 1
        i += 1
        body = []
        while i < len(lines) and lines[i] != "```":
            body.append(lines[i])
            i += 1
        i += 1
        at = list(range(start + 1, start + 1 + len(body)))
        fname = next((w[5:] for w in words if w.startswith("file=")), None)
        if fname:
            modules.append((fname, body, at))
            continue
        if "pending" not in words and "fragment" not in words and (rejects or "reject" not in words):
            out.append((body, at, modules))
        modules = []
    return out


# ---- Checking -----------------------------------------------------------------


def check(rig, root):
    """The refusals `rig check` gives for the program `root`: (path, line,
    column, message)."""
    try:
        r = subprocess.run([rig, "check", root], capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return [("", 0, 0, "timed out: " + root)]
    return [(m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)) for m in DIAG.finditer(r.stdout + r.stderr)]


def column(line, col):
    """The character index of byte column `col` (1-based) of `line`."""
    return len(line.encode("utf-8")[: col - 1].decode("utf-8", "ignore"))


def check(rig, root):
    """The refusals `rig check` gives for the program `root`: (path, line,
    column, message)."""
    try:
        r = subprocess.run([rig, "check", root], capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return [("", 0, 0, "timed out: " + root)]
    return [(m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)) for m in DIAG.finditer(r.stdout + r.stderr)]


def column(line, col):
    """The character index of byte column `col` (1-based) of `line`."""
    return len(line.encode("utf-8")[: col - 1].decode("utf-8", "ignore"))


WANTED = (BARE, NO_PROPAGATE, NOT_FALLIBLE, CHECKED, WIDE, FORM, WAIT_FLOAT, UNIX_ARG, TIME_STEP)


def wanted(message):
    return any(p.match(message) for p in WANTED) or message.startswith("timed out: ")


class Edits:
    """Replacements by file: (start, end, text), applied together."""

    def __init__(self):
        self.by_path = {}
        self.manual = []
        # What a rewrite leaves for a person to judge, kept across rounds.
        self.notes = []

    def put(self, path, start, end, s):
        self.by_path.setdefault(path, set()).add((start, end, s))

    def add(self, path, line, col, message, text_of):
        text = text_of(path)
        if text is None:
            return
        lines = text.split("\n")
        if line < 1 or line > len(lines):
            self.manual.append("MANUAL %s:%d: %s" % (path, line, message))
            return
        offset = sum(len(l) + 1 for l in lines[: line - 1]) + column(lines[line - 1], col)
        where = "%s:%d" % (os.path.relpath(path), line)
        m = BARE.match(message)
        if m:
            # Only the calls that now fail: another fallible call is one
            # whose operand was such a call, and the next check finds it
            # gone once that operand passes its failure on.
            if m.group(1).split(".")[-1] not in FAILS:
                self.manual.append("MANUAL %s: %s" % (where, message))
                return
            got = call_close(text, offset, m.group(1))
            if got is None:
                self.manual.append("MANUAL %s: %s" % (where, message))
                return
            self.put(path, got[1] + 1, got[1] + 1, "!")
            return
        if NO_PROPAGATE.match(message):
            end = postfix_end(text, offset, bang=True)
            if end is None or text[end - 1] != "!":
                self.manual.append("MANUAL %s: %s" % (where, message))
                return
            call = text[offset : end - 1]
            name = call.split("(")[0]
            shown = re.sub(r'["\\`{}]', "", call) if len(call) <= 60 else name
            self.put(path, offset, offset, "(")
            self.put(path, end - 1, end, ' catch panic("%s failed"))' % shown)
            self.notes.append("MANUAL %s: `%s` cannot pass a failure on, so it panics there: handle it, or make the function fallible" % (where, call))
            return
        if NOT_FALLIBLE.match(message):
            end = postfix_end(text, offset, bang=True)
            if end is None or text[end - 1] != "!":
                self.manual.append("MANUAL %s: %s" % (where, message))
                return
            self.put(path, end - 1, end, "")
            return
        m = CHECKED.match(message)
        if m:
            if m.group(2) == "Time":
                self.notes.append("MANUAL %s: `Time.checked_add` is gone: `Time.add` wraps past midnight; a sum that must not pass it is a `DateTime`'s" % where)
                return
            at = text.find(".checked_" + m.group(1), offset - 1)
            if at < 0:
                self.manual.append("MANUAL %s: %s" % (where, message))
                return
            self.put(path, at, at + len(".checked_"), ".")
            return
        m = UNIX_ARG.match(message)
        if m and re.search(r"from_unix_s\(\s*$", text[max(0, offset - 40) : offset]):
            end = postfix_end(text, offset)
            arg = text[offset:end] if end else None
            close = text.find(")", end or offset)
            if arg is None or close < 0 or text[end:close].strip():
                self.manual.append("MANUAL %s: %s" % (where, message))
                return
            at = text.rfind("from_unix_s", 0, offset)
            if m.group(1) == "Float":
                self.put(path, at, at + len("from_unix_s"), "from_unix_float")
            else:
                self.put(path, offset, end, "%s.seconds(), ns: %s.subsec_ns()" % (arg, arg))
            return
        if WIDE.match(message):
            end = postfix_end(text, offset)
            if end is None or not re.search(r"\.(ns|us|ms)\(\)$", text[offset:end]):
                self.manual.append("MANUAL %s: %s" % (where, message))
                return
            self.put(path, offset, offset, "Int(")
            self.put(path, end, end, ")")
            return
        if FORM.match(message) or WAIT_FLOAT.match(message):
            span = argument_span(text, offset)
            if span is None:
                self.manual.append("MANUAL %s: %s" % (where, message))
                return
            arg = text[span[0] : span[1]]
            if re.match(r"(duration|d):\s", arg):
                arg = re.sub(r"^(duration|d):\s*", "", arg)
                self.put(path, span[0], span[1], text[span[0] : span[1]].split(":")[0] + ": time.duration(%s)!" % arg)
            else:
                self.put(path, span[0], span[1], "time.duration(%s)!" % arg)
            return
        self.manual.append("MANUAL %s: %s" % (where, message))


def unit_errors(rig, unit, tmp, every=False):
    """Write a test case or a doc block out as its program and check it:
    the refusals it is given, each placed at its file line and column, or
    with no line when it lies outside the case's own lines."""
    kind = unit[0]
    d = tempfile.mkdtemp(dir=tmp)
    maps = {}
    if kind == "case":
        c = unit[1]
        lines, where = test_program(c)
        name = "main.rig"
        for f in c["files"]:
            p = os.path.join(d, f["path"])
            os.makedirs(os.path.dirname(p), exist_ok=True)
            if f["hex"]:
                open(p, "wb").write(bytes.fromhex("".join(f["lines"]).replace(" ", "")))
                continue
            open(p, "w").write("\n".join(f["lines"]) + "\n")
            maps[os.path.realpath(p)] = f["map"]
    else:
        body, at, modules = unit[1]
        lines, where = body, [(n, 0) for n in at]
        name = "main.rig"
        for path, mbody, mat in modules:
            p = os.path.join(d, path)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write("\n".join(mbody) + "\n")
            maps[os.path.realpath(p)] = [(n, 0) for n in mat]
    main = os.path.join(d, name)
    open(main, "w").write("\n".join(lines) + "\n")
    maps[os.path.realpath(main)] = where
    out = []
    for path, line, col, msg in check(rig, main):
        if not every and not wanted(msg):
            continue
        m = maps.get(os.path.realpath(path))
        if m is None:
            out.append((path, line, col, msg, False))
            continue
        w = m[line - 1] if 0 < line <= len(m) else None
        if w is None:
            out.append((None, line, col, msg, True))
            continue
        out.append((None, w[0], col + w[1], msg, True))
    shutil.rmtree(d, ignore_errors=True)
    return out


def files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in ("zig-cache", "zig-out", "node_modules", "history"))
                for name in sorted(names):
                    if name.endswith((".rig", ".rig.test", ".md")):
                        yield os.path.join(root, name)
        else:
            yield p


def files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in ("zig-cache", "zig-out", "node_modules", "history"))
                for name in sorted(names):
                    if name.endswith((".rig", ".rig.test", ".md")):
                        yield os.path.join(root, name)
        else:
            yield p


def apply(text, edits):
    """`text` with each replacement (start, end, s) made, the last first."""
    for start, end, s in sorted(edits, key=lambda e: (e[0], e[1]), reverse=True):
        text = text[:start] + s + text[end:]
    return text


def main(argv):
    dry, rig, jobs, paths = False, os.environ.get("RIG", "rig"), os.cpu_count() or 4, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--dry-run":
            dry = True
        elif a == "--rig":
            i += 1
            rig = argv[i]
        elif a == "-j":
            i += 1
            jobs = int(argv[i])
        else:
            paths.append(a)
        i += 1
    if not paths:
        print(__doc__.strip().split("\n\n")[-1], file=sys.stderr)
        return 2
    rig = os.path.abspath(rig) if os.sep in rig else (shutil.which(rig) or rig)
    tmp = tempfile.mkdtemp(prefix="rig-tov-")
    texts, counts, manual, notes = {}, {}, [], []

    def text_of(path):
        path = os.path.realpath(path)
        if path not in texts:
            try:
                with open(path, encoding="utf-8", newline="") as f:
                    texts[path] = f.read()
            except OSError:
                texts[path] = None
        return texts[path]

    def write(path, text):
        texts[path] = text
        if not dry:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(text)

    todo = [os.path.realpath(p) for p in files(paths)]
    # `from_unix` by the text of its argument, first: the compiler only
    # says the name is gone.
    early = []
    for path in todo:
        text = text_of(path)
        if text is None or "from_unix(" not in text:
            continue
        new, left = from_unix(text, code_spans(path, text))
        early += ["MANUAL %s:%d: %s" % (os.path.relpath(path), line, why) for line, why in left]
        if new != text:
            counts[path] = counts.get(path, 0) + text.count("from_unix(") - new.count("from_unix(")
            write(path, new)
    for _ in range(12):
        edits = Edits()
        units = []
        for path in todo:
            text = text_of(path)
            if text is None:
                continue
            if path.endswith(".rig.test"):
                units += [(path, ("case", c)) for c in test_cases(text) if c["verb"] != "fail"]
            elif path.endswith(".md"):
                units += [(path, ("block", u)) for u in doc_units(text, rejects=False)]
            else:
                units.append((path, ("file", path)))

        def run(item):
            path, unit = item
            if unit[0] == "file":
                return path, [(p, l, c, m, False) for p, l, c, m in check(rig, path) if wanted(m)]
            return path, unit_errors(rig, unit, tmp)

        with ThreadPoolExecutor(max_workers=jobs) as pool:
            for path, found in pool.map(run, units):
                for p, line, col, msg, own in found:
                    target = path if own else os.path.realpath(p)
                    if msg.startswith("timed out: "):
                        edits.manual.append("MANUAL %s: `rig check` timed out, so it is not rewritten" % path)
                        continue
                    if own and line is None:
                        edits.manual.append("MANUAL %s: %s" % (path, msg))
                        continue
                    if target.startswith(os.path.realpath(tmp)):
                        continue
                    edits.add(target, line, col, msg, text_of)
        notes += edits.notes
        manual = early + edits.manual + notes
        if not edits.by_path:
            break
        for path, eds in edits.by_path.items():
            write(path, apply(texts[path], eds))
            counts[path] = counts.get(path, 0) + len(eds)
        if dry:
            break
        todo = sorted(set(todo) | set(edits.by_path))
    # What is still refused in a file the script changed, it could not
    # rewrite: a person finishes it (an `Int` compared with an `I128` it
    # gave, `n >= took`, is one).
    if counts and not dry:
        changed = set(counts)
        units = []
        for path in todo:
            text = text_of(path)
            if text is None or path not in changed:
                continue
            if path.endswith(".rig.test"):
                units += [(path, ("case", c)) for c in test_cases(text) if c["verb"] != "fail"]
            elif path.endswith(".md"):
                units += [(path, ("block", u)) for u in doc_units(text, rejects=False)]
            else:
                units.append((path, ("file", path)))

        def final(item):
            path, unit = item
            if unit[0] == "file":
                return path, [(p, l, c, m, False) for p, l, c, m in check(rig, path)]
            return path, unit_errors(rig, unit, tmp, every=True)

        with ThreadPoolExecutor(max_workers=jobs) as pool:
            for path, found in pool.map(final, units):
                for p, line, col, msg, own in found:
                    target = path if own else os.path.realpath(p)
                    if target in changed:
                        manual.append("MANUAL %s:%s: still refused: %s" % (os.path.relpath(target), line, msg))
    shutil.rmtree(tmp, ignore_errors=True)
    for line in sorted(set(manual)):
        print(line)
    total = 0
    for path in sorted(counts):
        total += counts[path]
        print("%s: %d" % (os.path.relpath(path), counts[path]))
    print("%d rewritten" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
