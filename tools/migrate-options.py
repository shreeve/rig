#!/usr/bin/env python3
"""Rewrite a program's calls for the rule that a parameter with a default
is an option, given by name (SPEC "Functions"), and for std.datetime's
`Time.new`, whose second has no default:

    connect("db", 5432, 5)               ->  connect("db", 5432, timeout: 5)
    text.parse_int(s, 16)                ->  text.parse_int(s, base: 16)
    datetime.Time.new(8, 7, 3, 500)      ->  datetime.Time.new(8, 7, 3, ns: 500)
    datetime.DateTime.new(2026, 1, 31, 9, 30)
                                         ->  datetime.DateTime.new(2026, 1, 31, hour: 9, minute: 30)
    dt.add(span)                         ->  dt.add(duration: span)
    datetime.Time.new(8, 30)             ->  datetime.Time.new(8, 30, 0)
    datetime.Time.new(hour: 8, minute: 30)
                                         ->  datetime.Time.new(hour: 8, minute: 30, second: 0)

It is driven by the compiler, not by patterns in the text: it runs `rig
check` with a Rig that has the rule, and each argument it refuses as an
option given by position gets the name its diagnostic gives, written
before the argument where the diagnostic points; a call of `Time.new`
that the diagnostic says lacks its second gets `0` for it. It checks again
until nothing more is refused, since an error in a module the program uses
hides the program's own. In a test file it checks each case as the test
runner writes it out, and in a Markdown file each ```rig block, with the
`file=` blocks before it, leaving the `pending` and `fragment` blocks as
they are. A refusal it cannot place, or a call whose arguments it cannot
read, it prints as `MANUAL path:line` for a person. A second run changes
nothing.

The named form compiles under a Rig without the rule too, so a program
rewritten by it builds with either.

usage: tools/migrate-options.py [--dry-run] [--rig RIG] [-j N] PATH...
  Each PATH is a file or a directory searched for .rig, .rig.test, and
  .md files. RIG is the `rig` to run (default: $RIG, else `rig`); set
  RIG_STD to rewrite a copy of std/ read from disk. It prints each file it
  changes with its count; --dry-run changes nothing.
"""
import os, re, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

DIAG = re.compile(r"^(\S+\.rig):(\d+):(\d+): error: (.*)$", re.M)
OPTION = re.compile(r"^`(\w+)` has a default, so it is an option, given by name: ")
SECOND = re.compile(r"^call to `new` (?:is missing an argument for parameter `second`|expects 3 to 4 arguments, got 2)$")
FENCE = re.compile(r"^```rig([^\n]*)$")
HEADER = re.compile(r'^(code|fail|test|bomb) "((?:[^"\\]|\\.)*)"(.*)$')
OPEN = {"(": ")", "[": "]", "{": "}"}


# ---- What a refusal asks for -------------------------------------------------


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


def keyword(text, span):
    """The name of the keyword argument at `span`, or None."""
    m = re.match(r"\s*(\w+):(?!:)", text[span[0] : span[1]])
    return m.group(1) if m else None


def second_edit(text, at):
    """The insertion that gives `Time.new`'s second, for the call whose
    name `new` is at `at`: `0` after the minute by position, or `second: 0`
    after the minute by name; None when its arguments cannot be read."""
    m = re.compile(r"new\s*\(").match(text, at)
    if not m:
        return None
    got = arguments(text, m.end() - 1)
    if got is None:
        return None
    spans, close = got
    names = [keyword(text, s) for s in spans]
    positional = next((k for k, n in enumerate(names) if n is not None), len(names))
    if positional == 2:
        return (spans[1][1], ", 0")
    if positional > 2:
        return None
    if "minute" in names:
        return (spans[names.index("minute")][1], ", second: 0")
    return (close, ", second: 0" if spans else "second: 0")


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


def doc_units(text):
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
        if "pending" not in words and "fragment" not in words:
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


def wanted(message):
    return OPTION.match(message) or SECOND.match(message)


class Edits:
    """Insertions by file: (offset, text), applied together."""

    def __init__(self):
        self.by_path = {}
        self.manual = []

    def add(self, path, line, col, message, text_of):
        text = text_of(path)
        if text is None:
            return
        lines = text.split("\n")
        if line < 1 or line > len(lines):
            self.manual.append("MANUAL %s:%d: %s" % (path, line, message))
            return
        offset = sum(len(l) + 1 for l in lines[: line - 1]) + column(lines[line - 1], col)
        m = OPTION.match(message)
        if m:
            name = m.group(1)
            if text.startswith(name + ":", offset):
                return
            self.by_path.setdefault(path, set()).add((offset, name + ": "))
            return
        edit = second_edit(text, offset)
        if edit is None:
            self.manual.append("MANUAL %s:%d: %s" % (path, line, message))
            return
        self.by_path.setdefault(path, set()).add(edit)


def unit_errors(rig, unit, tmp):
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
        if not wanted(msg):
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
    tmp = tempfile.mkdtemp(prefix="rig-options-")
    texts, counts, manual = {}, {}, []

    def text_of(path):
        path = os.path.realpath(path)
        if path not in texts:
            try:
                with open(path, encoding="utf-8", newline="") as f:
                    texts[path] = f.read()
            except OSError:
                texts[path] = None
        return texts[path]

    todo = [os.path.realpath(p) for p in files(paths)]
    for _ in range(8):
        edits = Edits()
        units = []
        for path in todo:
            text = text_of(path)
            if text is None:
                continue
            if path.endswith(".rig.test"):
                units += [(path, ("case", c)) for c in test_cases(text)]
            elif path.endswith(".md"):
                units += [(path, ("block", u)) for u in doc_units(text)]
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
                    if own and line is None:
                        edits.manual.append("MANUAL %s: %s" % (path, msg))
                        continue
                    edits.add(target, line, col, msg, text_of)
        manual = edits.manual
        if not edits.by_path:
            break
        for path, ins in edits.by_path.items():
            text = texts[path]
            for offset, s in sorted(ins, reverse=True):
                text = text[:offset] + s + text[offset:]
            texts[path] = text
            counts[path] = counts.get(path, 0) + len(ins)
            # The next check reads the files from disk.
            if not dry:
                with open(path, "w", encoding="utf-8", newline="") as f:
                    f.write(text)
        # What a rewrite reveals is found by checking again, which a dry
        # run, leaving the files as they are, cannot do.
        if dry:
            break
        todo = sorted(set(todo) | set(edits.by_path))
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
