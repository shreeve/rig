#!/usr/bin/env python3
"""Rewrite Rig sources for the v0.3.0 type renames (branch `rename`).

    rewrite.py MODE scan  [ROOT]   report what would change, change nothing
    rewrite.py MODE apply [ROOT]   rewrite every tracked source in place

MODE is one of three renames, each idempotent in effect (a second run
finds nothing to do, because the old spelling is gone):

  box     `Box[T]` -> `^T`, `Box(v)` -> `^v`.
  list    `Vec` -> `List` (the type, its constructor, its prose). A name
          the program already declares as `List` is renamed first.
  string  `Text` -> `String` (the owned text), and the read view
          `String` -> `?String`; `?Text` -> `?String`; `String?` and
          `String!` (an optional or fallible view) -> `(?String)?`,
          `(?String)!`.

ROOT is a checkout (default: the current directory). It reads every
tracked `.rig` file, every ```rig block of every tracked `.md` file
(with the ```error and ```output blocks that follow it), every heredoc
program in test/cli/*.sh, and the `# error:` and `# expect:` lines of a
program; `# error: L:C:` columns follow the rewrite. Prose in Markdown
and everything in `src/` are by hand.

Everything it cannot decide is printed as `MANUAL path:line: why` and
left as written.
"""
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# Lexical scan: code, comment and string spans of a Rig source
# ---------------------------------------------------------------------------


def spans(src):
    """(code, comment, string) spans: three lists of (start, end)."""
    code, comment, string = [], [], []
    i, n, start = 0, len(src), 0
    while i < n:
        c = src[i]
        if c == "#":
            if start < i:
                code.append((start, i))
            j = src.find("\n", i)
            j = n if j < 0 else j
            comment.append((i, j))
            i = start = j
        elif c in "\"'":
            if start < i:
                code.append((start, i))
            j = i + 1
            while j < n and src[j] != "\n":
                if src[j] == "\\" and c == '"':
                    j += 2
                    continue
                if src[j] == c:
                    if c == "'" and src[j + 1:j + 2] == "'":
                        j += 2
                        continue
                    break
                j += 1
            j = min(j + 1, n)
            string.append((i, j))
            i = start = j
        else:
            i += 1
    if start < n:
        code.append((start, n))
    return code, comment, string


def apply_edits(src, edits):
    """edits: (start, end, new). Applied last first; they must not overlap."""
    for a, b, new in sorted(edits, key=lambda e: -e[0]):
        src = src[:a] + new + src[b:]
    return src


ERROR_AT = re.compile(r"^(# (?:error|warning|note): )(\d+):(\d+):", re.M)


def line_starts(src):
    offs, o = [], 0
    for l in src.split("\n"):
        offs.append(o)
        o += len(l) + 1
    return offs


def move_directives(old, edits):
    """The `# error: L:C:` places of `old`, mapped through `edits` (a list
    of (start, end, new) on `old`), as {directive start: (line, col)}."""
    offs = line_starts(old)
    ed = sorted(edits)

    def newpos(p):
        delta = 0
        for a, b, new in ed:
            if p >= b:
                delta += len(new) - (b - a)
            elif p >= a:
                # Inside a replaced span: the span's start.
                return a + delta
            else:
                break
        return p + delta

    res = {}
    for m in ERROR_AT.finditer(old):
        line, col = int(m.group(2)), int(m.group(3))
        if not 1 <= line <= len(offs):
            continue
        at = offs[line - 1] + col - 1
        # Only a line the rewrite changed moves.
        ls, le = offs[line - 1], (offs[line] - 1 if line < len(offs) else len(old))
        if not any(a < le and b > ls for a, b, _ in ed):
            continue
        res[m.start()] = at
    return res, newpos


def rewrite_with(old, edits):
    """Apply `edits` to `old` and move the `# error: L:C:` directives."""
    if not edits:
        return old
    moved, newpos = move_directives(old, edits)
    new = apply_edits(old, edits)
    if not moved:
        return new
    fixes = []
    for dstart, at in moved.items():
        m = ERROR_AT.match(old, dstart)
        nd = newpos(dstart)
        nat = newpos(at)
        line = new.count("\n", 0, nat) + 1
        col = nat - (new.rfind("\n", 0, nat) + 1) + 1
        fixes.append((nd, nd + len(m.group(0)), "%s%d:%d:" % (m.group(1), line, col)))
    return apply_edits(new, fixes)


# ---------------------------------------------------------------------------
# Mode box
# ---------------------------------------------------------------------------

SIGILS = "<+-?!*~^"


def find_close(s, i, open_ch, close_ch):
    """Index of the bracket closing the one at s[i], skipping strings and comments."""
    depth = 0
    j = i
    while j < len(s):
        c = s[j]
        if c in "\"'":
            q = c
            j += 1
            while j < len(s) and s[j] != q and s[j] != "\n":
                if s[j] == "\\" and q == '"':
                    j += 1
                j += 1
        elif c == "#":
            while j < len(s) and s[j] != "\n":
                j += 1
            continue
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
            if depth == 0:
                return j if c == close_ch else None
        j += 1
    return None


def top_level(s):
    """s with everything inside brackets and strings blanked, for depth-0 scans."""
    out, depth, j = [], 0, 0
    while j < len(s):
        c = s[j]
        if c in "\"'":
            q = c
            k = j + 1
            while k < len(s) and s[k] != q:
                k += 1
            out.append("_" * (k - j + 1))
            j = k + 1
            continue
        if c in "([":
            depth += 1
            out.append("_")
        elif c in ")]":
            depth -= 1
            out.append("_")
        else:
            out.append(c if depth == 0 else "_")
        j += 1
    return "".join(out)


def box_type_operand(t):
    """`^` + type t, parenthesized where `^` would bind differently."""
    t = t.strip()
    top = top_level(t)
    if t[:1] == "?":
        # A read view is the one prefix a box takes whole: `^?T`.
        rest = t[1:]
        if top_level(rest).rstrip().endswith(("?", "!")) and not rest.strip().startswith("("):
            return "^(" + t + ")"
        return "^" + t
    if top.rstrip().endswith(("?", "!")) or t[:1] == "!":
        return "^(" + t + ")"
    return "^" + t


def box_expr_operand(a):
    """`^` + expression a, parenthesized unless a is a unary-level operand."""
    a = a.strip()
    top = top_level(a)
    body = top.lstrip(SIGILS)
    rest = body.rstrip("?!")
    simple = rest != "" and not re.search(r"[\s+\-*/%=<>&|^]|\.\.", rest[1:] if rest[:1] == "-" else rest)
    if a[:1] == "|":
        simple = False
    return ("^" + a) if simple else ("^(" + a + ")")


def box_source(src, path, report, in_comments=True, permissive=False):
    """Rewrite every `Box[...]` / `Box(...)` of src, innermost last in
    effect (rightmost first), and move the `# error: L:C:` directives
    whose column the rewrite shifts."""
    text = src
    skipped = set()
    # Places to carry through the rewrite: each directive's own start
    # and the column it names.
    offs = line_starts(src)
    marks = []  # [directive_start, place]
    for m in ERROR_AT.finditer(src):
        line, col = int(m.group(2)), int(m.group(3))
        if 1 <= line <= len(offs):
            marks.append([m.start(), offs[line - 1] + col - 1, line])
    changed_lines = set()
    while True:
        code, comment, string = spans(text)

        def ok(off):
            if permissive or in_spans(code, off):
                return True
            return in_comments and in_spans(comment, off)

        hits = [m for m in re.finditer(r"(?<![A-Za-z0-9_.])Box([\[(])", text) if ok(m.start()) and (m.start(), m.group(1)) not in skipped]
        if not hits:
            break
        m = hits[-1]
        start, br = m.start(), m.group(1)
        line = text.count("\n", 0, start) + 1
        close = find_close(text, m.end() - 1, br, ")" if br == "(" else "]")
        if close is None:
            skipped.add((start, br))
            report.append("MANUAL %s:%d: unbalanced `Box%s`" % (path, line, br))
            continue
        inner = text[m.end():close]
        arg = inner
        if br == "[":
            if text[close + 1:close + 2] == "(":
                skipped.add((start, br))
                report.append("MANUAL %s:%d: explicit instance `Box[...](...)`" % (path, line))
                continue
            new = box_type_operand(inner)
        else:
            if "," in top_level(inner):
                skipped.add((start, br))
                report.append("MANUAL %s:%d: `Box(...)` with more than one argument" % (path, line))
                continue
            kw = re.match(r"\s*value:\s*", inner)
            if kw:
                arg = inner[kw.end():]
            elif re.match(r"\s*[A-Za-z_]\w*:\s", inner):
                skipped.add((start, br))
                report.append("MANUAL %s:%d: `Box(name: ...)` with a field other than `value`" % (path, line))
                continue
            if not arg.strip():
                skipped.add((start, br))
                report.append("MANUAL %s:%d: `Box()` with no argument" % (path, line))
                continue
            new = box_expr_operand(arg)
        # A box of a view followed by a suffix is an optional box, not a
        # box of an optional view: `(^?T)?`.
        wrap = br == "[" and new.startswith("^?") and text[close + 1:close + 2] in ("?", "!")
        if wrap:
            new = "(" + new + ")"
        stripped = arg.strip()
        old_inner = close - len(arg) + (len(arg) - len(arg.lstrip())) - (len(inner) - len(arg) if False else 0)
        old_inner = m.end() + (len(inner) - len(arg)) + (len(arg) - len(arg.lstrip()))
        new_inner = new.index(stripped) if stripped in new else len(new)
        end = close + 1
        delta = len(new) - (end - start)

        def mv(p):
            if p >= end:
                return p + delta
            if p <= start:
                return p
            if old_inner <= p < old_inner + len(stripped):
                return start + new_inner + (p - old_inner)
            return start + len(new) if p >= old_inner + len(stripped) else start
        for mk in marks:
            mk[0], mk[1] = mv(mk[0]), mv(mk[1])
        text = text[:start] + new + text[end:]
    if text == src:
        return src
    fixes = []
    for d, at, old_line in marks:
        m = ERROR_AT.match(text, d)
        if not m:
            continue
        line = text.count("\n", 0, at) + 1
        # Only a line the rewrite changed moves, and only within it: an
        # expectation may name another module's line.
        if line != old_line:
            continue
        if src.split("\n")[old_line - 1] == text.split("\n")[line - 1]:
            continue
        col = at - (text.rfind("\n", 0, at) + 1) + 1
        fixes.append((d, d + len(m.group(0)), "%s%d:%d:" % (m.group(1), line, col)))
    return apply_edits(text, fixes)


# ---------------------------------------------------------------------------
# Token modes: list, string
# ---------------------------------------------------------------------------

WORD = re.compile(r"(?<![A-Za-z0-9_.])[A-Za-z_][A-Za-z0-9_]*")


def in_spans(sp, off):
    for a, b in sp:
        if a <= off < b:
            return True
    return False


def declares(src, name):
    return re.search(r"(?m)^\s*(?:pub\s+)?(?:struct|enum|type|union|error)\s+" + name + r"\b", src) is not None


def backticks(text):
    """Spans of backticked text inside a comment line."""
    return [(m.start(1), m.end(1)) for m in re.finditer(r"`([^`\n]*)`", text)]


def list_edits(src, path, report):
    """`List` (a name some program declares for itself) -> `Chain`, then
    `Vec` -> `List`, in code and comments; one pass, so the two never meet."""
    code, comment, string = spans(src)
    edits = []
    for m in re.finditer(r"(?<![A-Za-z0-9_])(Vec|List)\b(?!<|::)", src):
        off = m.start()
        # In prose a `List.` is a name of the compiler's own (a parser
        # node list); in a program it is the program's type.
        if PROSE[0] and m.group(1) == "List" and src[m.end():m.end() + 1] == ".":
            continue
        # `lib.List` is a program's own `List` named through its module;
        # `lib.Vec` is nothing.
        if m.group(1) == "Vec" and off > 0 and src[off - 1] == ".":
            continue
        if in_spans(code, off) or in_spans(comment, off):
            edits.append((off, m.end(), "List" if m.group(1) == "Vec" else "Chain"))
    return edits


DIAG_WORD = re.compile(r"(?<![A-Za-z0-9_.`])(Text|String)(?![A-Za-z0-9_`(])")


def diag_words(text):
    """The words of a diagnostic's message outside its backticks: `Text`
    is `String`, and `String` is the `?String` view, as the compiler's
    messages say them."""
    out, pos = [], 0
    for m in re.finditer(r"`[^`]*`", text):
        out.append((False, text[pos:m.start()]))
        out.append((True, m.group(0)))
        pos = m.end()
    out.append((False, text[pos:]))
    return "".join(t if ticked else DIAG_WORD.sub(lambda m: "String" if m.group(1) == "Text" else "`?String`", t) for ticked, t in out)


# `String` followed by a suffix needs the view in parentheses.
def string_edits(src, path, report, permissive=False):
    code, comment, string = spans(src)
    if permissive:
        # A generator's text is Rig programs in Python strings: all code.
        code, comment, string = [(0, len(src))], [], []
    edits = []
    for m in re.finditer(r"(?<![A-Za-z0-9_.])(Text|String)\b", src):
        off, name = m.start(), m.group(1)
        line = src.count("\n", 0, off) + 1
        before = src[off - 1] if off > 0 else "\n"
        after = src[m.end():m.end() + 1]
        if in_spans(code, off):
            if name == "Text":
                edits.append((off, m.end(), "String"))
                continue
            # The name a declaration gives its own type stays: `String` is
            # reserved, as `Text` was.
            if re.search(r"\b(struct|enum|type|union|error)\s+$", src[max(0, off - 12):off]):
                continue
            # The read view.
            if before == "?":
                continue  # `?String` is already the view (the fold)
            if before == "!":
                report.append("MANUAL %s:%d: `!String`" % (path, line))
                continue
            # A prefix sigil of a handle cannot hold a view, nor can a
            # path (`std.String`): left alone.
            new = "?String"
            if after in ("?", "!") and src[m.end():m.end() + 2] != "??":
                new = "(?String)"
            elif after in ("?", "!") and src[m.end():m.end() + 2] == "??" and before in "(\n [,":
                new = "(?String)"
            edits.append((off, m.end(), new))
        elif in_spans(comment, off):
            # Inside backticks of a comment only: `Text`, `String`.
            ls = src.rfind("\n", 0, off) + 1
            le = src.find("\n", off)
            le = len(src) if le < 0 else le
            if any(a <= off - ls < b for a, b in backticks(src[ls:le])):
                if name == "Text":
                    edits.append((off, m.end(), "String"))
                elif before != "?" and before != "!":
                    new = "?String"
                    if after in ("?", "!"):
                        new = "(?String)"
                    edits.append((off, m.end(), new))
            elif re.match(r"#\s*(?:errors?|warning|note):", src[ls:le]) and after not in ("`", "("):
                # The words of a diagnostic's message, as the compiler's
                # messages say them.
                edits.append((off, m.end(), "String" if name == "Text" else "`?String`"))
    return edits


# ---------------------------------------------------------------------------
# Walking the tree
# ---------------------------------------------------------------------------

FENCE = re.compile(r"^```rig([ \t].*)?$")


def source_edits(mode, src, path, report):
    if mode == "list":
        return list_edits(src, path, report)
    if mode == "string":
        return string_edits(src, path, report)
    raise SystemExit("no such mode: " + mode)


def rewrite_source(mode, src, path, report, directives=True):
    if mode == "box":
        return box_source(src, path, report)
    edits = source_edits(mode, src, path, report)
    return rewrite_with(src, edits) if directives else apply_edits(src, edits)


PROSE = [False]
INLINE = re.compile(r"(?<!`)(`+)(?!`)([^`\n]+?)(?<!`)\1(?!`)")


def rewrite_prose(mode, line, path, n, report):
    """The code spans of a prose line (and, for `list`, its words)."""
    def span(m):
        inner = m.group(2)
        PROSE[0] = True
        try:
            new = rewrite_source(mode, inner, "%s:%d" % (path, n), report, directives=False)
        finally:
            PROSE[0] = False
        return m.group(1) + new + m.group(1)
    line = INLINE.sub(span, line)
    if mode == "list":
        line = re.sub(r"(?<![A-Za-z0-9_.`])Vecs\b", "Lists", line)
        line = re.sub(r"(?<![A-Za-z0-9_.`])Vec\b(?!<|::)", "List", line)
    return line


def rewrite_md(mode, text, path, report):
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        m = re.match(r"^```(?!`)(\w*)", lines[i])
        if not m:
            out.append(rewrite_prose(mode, lines[i], path, i + 1, report))
            i += 1
            continue
        out.append(lines[i])
        start, body = i + 1, []
        i += 1
        while i < len(lines) and lines[i] != "```":
            body.append(lines[i])
            i += 1
        if FENCE.match(lines[start - 1]):
            src = "\n".join(body) + "\n"
            new = rewrite_source(mode, src, "%s:L%d" % (path, start), report)
            out.extend(new[:-1].split("\n") if new.endswith("\n") else new.split("\n"))
        elif m.group(1) == "error":
            lines_ = [rewrite_prose(mode, l, path, start + k + 1, report) for k, l in enumerate(body)]
            out.extend(diag_words(l) if mode == "string" else l for l in lines_)
        else:
            out.extend(body)
        if i < len(lines):
            out.append(lines[i])
            i += 1
    return "\n".join(out)


HEREDOC = re.compile(r"<<-?\s*'?\"?([A-Za-z_0-9]+)'?\"?\s*$")


def rewrite_sh(mode, text, path, report):
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        out.append(lines[i])
        m = HEREDOC.search(lines[i])
        if not m or ".rig" not in lines[i]:
            i += 1
            continue
        tag = m.group(1)
        i += 1
        body = []
        while i < len(lines) and lines[i] != tag:
            body.append(lines[i])
            i += 1
        src = "\n".join(body) + "\n"
        new = rewrite_source(mode, src, "%s:%d" % (path, i - len(body)), report)
        out.extend(new[:-1].split("\n"))
    return "\n".join(out)


def rewrite_zig(mode, text, path, report):
    """The Rig programs in a Zig file's multiline strings (`\\\\` lines)."""
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        m = re.match(r"^(\s*)\\\\(.*)$", lines[i])
        if not m:
            out.append(lines[i])
            i += 1
            continue
        indent = m.group(1)
        body = []
        j = i
        while j < len(lines):
            mm = re.match(r"^\s*\\\\(.*)$", lines[j])
            if not mm:
                break
            body.append(mm.group(1))
            j += 1
        src = "\n".join(body) + "\n"
        new = rewrite_source(mode, src, "%s:%d" % (path, i + 1), report)
        out.extend(indent + "\\\\" + l for l in new[:-1].split("\n"))
        i = j
    return "\n".join(out)


ZIG_RIG = re.compile(r"^\s*\\\\")


def rewrite_plain(mode, text, path, report):
    """A file whose text is the compiler's own (`src/*.zig`, the oracle,
    the test generators): names the mode renames, in identifiers (by
    camel- and snake-case part), comments and messages alike. A Rig
    program in a Zig multiline string takes the Rig rules."""
    out, i = [], 0
    lines = text.split("\n")
    plain = []

    def flush():
        if not plain:
            return
        chunk = "\n".join(plain)
        if mode == "list":
            chunk = re.sub(r"Vecs\b", "Lists", chunk)
            chunk = re.sub(r"Vec(?![a-z]|<|::)", "List", chunk)
            chunk = re.sub(r"(?<![a-z])vec(?![a-z])", "list", chunk)
        elif mode == "box":
            chunk = box_source(chunk, path, report, permissive=True)
        elif mode == "string" and path in PLAIN:
            chunk = apply_edits(chunk, string_edits(chunk, path, report, permissive=True))
        out.extend(chunk.split("\n"))
        plain.clear()

    while i < len(lines):
        if not ZIG_RIG.match(lines[i]):
            plain.append(lines[i])
            i += 1
            continue
        flush()
        j = i
        while j < len(lines) and ZIG_RIG.match(lines[j]):
            j += 1
        out.extend(rewrite_zig(mode, "\n".join(lines[i:j]), path, report).split("\n"))
        i = j
    flush()
    return "\n".join(out)


def rewrite_data(mode, text, path, report):
    """A data file that names programs and types in backticks."""
    return "\n".join(rewrite_prose(mode, l, path, n + 1, report) for n, l in enumerate(text.split("\n")))


def tracked(root):
    r = subprocess.run(["git", "ls-files"], cwd=root, capture_output=True, text=True, check=True)
    return r.stdout.split()


# Tests that show an old spelling on purpose (the hint a retired name
# draws): the script leaves them as written.
KEEP = {
    "test/reject/types/box_retired_name.rig",
    "test/reject/types/list_retired_name.rig",
    "test/reject/types/string_retired_name.rig",
}


# Files whose text is the compiler's or the generators' own, and files
# of backticked names.
PLAIN = {"test/matrix.py", "test/equiv.py", "test/hints.py"}
DATA = {"test/oracle/differences", "test/oracle/rejections", "test/oracle/coverage", "test/vocabulary-allow.txt"}


def own_declarers(root, files, name):
    """The files and directories that declare their own `name`: a program
    that does keeps its uses of it, as do the modules of its test."""
    own, dirs = set(), set()
    for f in files:
        if f.endswith(".rig") and declares(open(os.path.join(root, f)).read(), name):
            own.add(f)
            d = os.path.dirname(f)
            if os.path.exists(os.path.join(root, d, "main.rig")) and d.startswith("test/"):
                dirs.add(d + "/")
    return own, dirs


def is_own(f, own, dirs):
    if f in own or any(f.startswith(d) for d in dirs):
        return True
    if f.endswith(".rig"):
        stem = f[:-4]
        for o in own:
            os_ = o[:-4]
            if os_.startswith(stem + "-") or stem.startswith(os_ + "-") or os_.rsplit("-", 1)[0] == stem.rsplit("-", 1)[0] and "-lib" in o + f:
                return True
    return False


def main():
    args = sys.argv[1:]
    if len(args) < 2 or args[0] not in ("box", "list", "string") or args[1] not in ("scan", "apply"):
        sys.exit(__doc__)
    mode, act = args[0], args[1]
    root = os.path.abspath(args[2] if len(args) > 2 else ".")
    report = []
    files = 0
    all_files = tracked(root)
    own, dirs = own_declarers(root, all_files, {"box": "Box", "list": "List", "string": "String"}[mode]) if mode == "box" else (set(), set())
    for f in all_files:
        path = os.path.join(root, f)
        if f in KEEP:
            continue
        if mode == "box" and is_own(f, own, dirs):
            report.append("SKIP %s: declares its own `Box`, or is a module of a test that does" % f)
            continue
        if f.endswith(".rig"):
            text = open(path).read()
            new = rewrite_source(mode, text, f, report)
        elif f.endswith(".md"):
            text = open(path).read()
            new = rewrite_md(mode, text, f, report)
        elif f.startswith("test/cli/") and f.endswith(".sh"):
            text = open(path).read()
            new = rewrite_sh(mode, text, f, report)
        elif f.endswith(".zig") and f != "src/parser.zig":
            text = open(path).read()
            # The Zig of the compiler already says `^T`: only its Rig is rewritten.
            new = rewrite_zig(mode, text, f, report) if mode == "box" else rewrite_plain(mode, text, f, report)
        elif f in PLAIN:
            text = open(path).read()
            new = rewrite_plain(mode, text, f, report)
        elif f in DATA:
            text = open(path).read()
            new = rewrite_data(mode, text, f, report)
        else:
            continue
        if new != text:
            files += 1
            if act == "apply":
                open(path, "w").write(new)
    seen = set()
    for r in report:
        if r not in seen:
            seen.add(r)
            print(r)
    print("%d files %s" % (files, "rewritten" if act == "apply" else "to rewrite"), file=sys.stderr)


if __name__ == "__main__":
    main()
