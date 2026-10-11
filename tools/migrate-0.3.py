#!/usr/bin/env python3
"""Migrate Rig 0.2 programs to Rig 0.3.0.

    migrate-0.3.py scan  PATH...  report what would change, change nothing
    migrate-0.3.py apply PATH... [--force FILE...]  rewrite the programs in place

A PATH is a directory (every `.rig` and `.rig.tmpl` file under it) or a
file of either kind. `scan` also prints a `HINT` for each other text
file under a directory that spells Box, Vec, or Text the old way (a
build script, a README, a generator): such a file is never rewritten.

The renames of 0.3.0, applied in this order to each file:

  box     `Box[T]` -> `^T`, `Box(v)` -> `^v`.
  list    `Vec` -> `List`. A type your program already calls `List` is
          renamed `Chain` first (the built-in owns the name now).
  string  `Text` -> `String` (the owned text), and the read view
          `String` -> `?String` (`String?` -> `(?String)?`, `String!` ->
          `(?String)!`); `?Text` -> `?String`.
  obj     a declaration `struct Name` (after any `pub`, at the start of
          a line) -> `obj Name`. `struct` is an ordinary name elsewhere,
          so nothing else changes.

Then, in `apply`, one change that needs the compiler: `for x in it` over
an iterator that is a place is written `for x in !it`. The tool runs
`rig check` (`$RIG`, else bin/rig of the checkout beside this tool, else
`rig` on PATH) on each `.rig` file it rewrote and inserts the `!` where the
compiler asks for it. Without a compiler it prints a `MANUAL` line.

Each rename is its own pass with its own applicability test (`PASSES`).
`obj` is purely textual and safe on any version, so it runs on every file
and is idempotent. The 0.2 renames (box, list, string) run only on a file
that is 0.2: it spells `Vec[`, `Vec(`, `Box[`, `Box(`, or `Text` in code.
Only such a spelling decides; a failing `rig check` does not (a 0.3 file
fails it for any error). A file that spells none of them is 0.3: only
`obj` touches it, and `scan` and `apply` print `CURRENT path` if that
changes nothing. `--force FILE...` (after the PATHs) runs the 0.2 renames
on the named files whatever they look like, and is the way to migrate a 0.2
file that has no such spelling. A `List` is renamed `Chain` only where the
file, or a program beside it, declares `struct List`, `obj List` or `enum List`.

`apply` is idempotent: it records the 0.2 files it migrated, with the hash
of what it wrote, in DIR/.rig-migrated-0.3, and skips the 0.2 renames of a
file whose hash is the same. The record never holds back a later rename
(obj). A file you edited since is migrated again, so run it once on a tree
that is still 0.2 and then compile. It prints one line for each thing it
could not decide (`MANUAL path:line: why`) and a summary.
Not rewritten: `!String` (a 0.2 write view of text, which 0.3.0 cannot
write), a `Box[T](...)` that names its type argument, and the prose of
Markdown files. Commit first; the rewrite is textual.
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
    return re.search(r"(?m)^\s*(?:pub\s+)?(?:struct|obj|enum|type|union|error)\s+" + name + r"\b", src) is not None


def backticks(text):
    """Spans of backticked text inside a comment line."""
    return [(m.start(1), m.end(1)) for m in re.finditer(r"`([^`\n]*)`", text)]


def declares_list(src):
    return re.search(r"(?m)^\s*(?:pub\s+)?(?:struct|obj|enum)\s+List\b", src) is not None


def list_edits(src, path, report):
    """`List` (a name some program declares for itself) -> `Chain`, then
    `Vec` -> `List`, in code and comments; one pass, so the two never meet.
    A `List` is the program's own only where this file, or its package
    (the files beside it), declares a `struct List` or `enum List`;
    elsewhere it is left alone."""
    code, comment, string = spans(src)
    edits = []
    own = PROSE[0] or LISTS_OWN[0] or declares_list(src)
    for m in re.finditer(r"(?<![A-Za-z0-9_])(Vec|List)\b(?!<|::)", src):
        off = m.start()
        if m.group(1) == "List" and not own:
            continue
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
            if re.search(r"\b(struct|obj|enum|type|union|error)\s+$", src[max(0, off - 12):off]):
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


# A declaration `struct Name`: at the start of a line, after any `pub`.
STRUCT_DECL = re.compile(r"(?m)^([ \t]*(?:pub[ \t]+)?)(struct)(?=[ \t]+[A-Za-z_])")


def obj_edits(src, path, report, permissive=False):
    """`struct Name` -> `obj Name` for each declaration in code; `struct`
    elsewhere (a name, a word in a comment or a string) is left."""
    code = [(0, len(src))] if permissive else spans(src)[0]
    return [(m.start(2), m.end(2), "obj") for m in STRUCT_DECL.finditer(src) if in_spans(code, m.start(2))]


# ---------------------------------------------------------------------------
# Walking the tree
# ---------------------------------------------------------------------------

FENCE = re.compile(r"^```rig([ \t].*)?$")


def source_edits(mode, src, path, report):
    if mode == "list":
        return list_edits(src, path, report)
    if mode == "string":
        return string_edits(src, path, report)
    if mode == "obj":
        return obj_edits(src, path, report)
    raise SystemExit("no such mode: " + mode)


def rewrite_source(mode, src, path, report, directives=True):
    if mode == "box":
        return box_source(src, path, report)
    edits = source_edits(mode, src, path, report)
    return rewrite_with(src, edits) if directives else apply_edits(src, edits)


PROSE = [False]
LISTS_OWN = [False]  # the package of the file being migrated declares a `List`
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



MARK = ".rig-migrated-0.3"
SKIP_DIRS = ("zig-cache", "zig-out", "node_modules")
OLD_SPELLING = re.compile(r"(?<![A-Za-z0-9_.])(Box[\[(]|Vec\b|Text\b)|(?m:^[ \t]*(?:pub[ \t]+)?(struct)(?=[ \t]+[A-Za-z_]))")


def is_program(name):
    return name.endswith(".rig") or name.endswith(".rig.tmpl")


def files_under(root, want=is_program):
    for dp, ds, fs in os.walk(root):
        ds[:] = sorted(d for d in ds if not d.startswith(".") and d not in SKIP_DIRS)
        for n in sorted(fs):
            if want(n) and n != MARK:
                yield os.path.join(dp, n)


def targets(paths):
    """(root, path) for each program the PATHs name: the root holds the
    record of what was migrated."""
    out, seen = [], set()
    for p in paths:
        p = os.path.abspath(p)
        if os.path.isdir(p):
            found = [(p, f) for f in files_under(p)]
        elif os.path.isfile(p):
            if not is_program(p):
                sys.exit("not a .rig or .rig.tmpl file: " + p)
            found = [(os.path.dirname(p), p)]
        else:
            sys.exit("no such file or directory: " + p)
        for root, f in found:
            if f not in seen:
                seen.add(f)
                out.append((root, f))
    return out


def hints(paths):
    """A line for each non-program text file under a directory PATH that
    spells something the old way. Hints only: these files are not ours
    to rewrite."""
    out = []
    for p in paths:
        p = os.path.abspath(p)
        if not os.path.isdir(p):
            continue
        for f in files_under(p, lambda n: not is_program(n)):
            try:
                if os.path.getsize(f) > 1 << 20:
                    continue
                text = open(f, encoding="utf-8").read()
            except (UnicodeDecodeError, OSError):
                continue
            for n, line in enumerate(text.split("\n"), 1):
                m = OLD_SPELLING.search(line)
                if m:
                    out.append("HINT %s:%d: old spelling `%s` (not rewritten)" % (os.path.relpath(f), n, m.group(1) or m.group(2)))
                    break
    return out


def package_declares_list(path):
    """Whether a program beside `path` (its package) declares `List`."""
    d = os.path.dirname(os.path.abspath(path))
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return False
    for n in names:
        f = os.path.join(d, n)
        if is_program(n) and os.path.isfile(f):
            try:
                if declares_list(open(f, encoding="utf-8").read()):
                    return True
            except (UnicodeDecodeError, OSError):
                pass
    return False


# The renames, in order. Each is one mode (see `source_edits`) and one
# applicability test over `is02`, whether the file spells something the
# 0.2 way. A 0.2 rename is not idempotent (`String` -> `?String`), so it
# runs only on a 0.2 file. A purely textual rename that is safe on any
# version (obj) applies to every file. A later rename adds one line here.
PASSES = (
    ("box", lambda is02: is02),
    ("list", lambda is02: is02),
    ("string", lambda is02: is02),
    ("obj", lambda is02: True),
)


def migrate(text, path, report, full=None, is02=True):
    LISTS_OWN[0] = bool(full) and package_declares_list(full)
    for mode, applies in PASSES:
        if applies(is02):
            text = rewrite_source(mode, text, path, report)
    LISTS_OWN[0] = False
    return text


ERR_LINE = re.compile(r"^(.+?):\d+:\d+: error:")


def has_old_spelling(path, text):
    """An unambiguous 0.2 spelling: `Vec[`, `Vec(`, `Box[`, `Box(`, or
    `Text` (a type or constructor; `String` reserves the name now)."""
    pat = re.compile(r"(?<![A-Za-z0-9_.])(?:(?:Box|Vec)[\[(]|Text\b)")
    if not path.endswith(".rig"):
        return pat.search(text) is not None
    code = spans(text)[0]
    return any(pat.search(text, a, b) for a, b in code)


def is_02(path, text):
    """Whether a file is 0.2: it spells something the 0.2 way (see
    `has_old_spelling`). Only a 0.2-only spelling decides: a failing
    `rig check` does not, since a 0.3 file fails it for any error, or for
    a rename a later release makes."""
    return has_old_spelling(path, text)


ITER_DIAG = re.compile(r"^(.+?):(\d+):(\d+): error: write `for \S+ in !\S+`: the loop advances")


def find_rig():
    cands = [os.environ.get("RIG"), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "rig")]
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return os.path.abspath(c)
    for d in os.environ.get("PATH", "").split(os.pathsep):
        c = os.path.join(d, "rig")
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def iterator_loops(rig, files):
    """Insert the `!` the compiler asks for, in any of `files`."""
    ours = set(files)
    for f in files:
        if not f.endswith(".rig"):
            continue
        for _ in range(8):
            r = subprocess.run([rig, "check", f], capture_output=True, text=True, cwd=os.path.dirname(f))
            hits = {}
            for l in (r.stderr + r.stdout).split("\n"):
                m = ITER_DIAG.match(l)
                if m:
                    g = os.path.abspath(os.path.join(os.path.dirname(f), m.group(1)))
                    if g in ours:
                        hits.setdefault(g, set()).add((int(m.group(2)), int(m.group(3))))
            if not hits:
                break
            for g, at in hits.items():
                lines = open(g).read().split("\n")
                for ln, col in sorted(at, reverse=True):
                    lines[ln - 1] = lines[ln - 1][:col - 1] + "!" + lines[ln - 1][col - 1:]
                    for k, l in enumerate(lines):
                        m = ERROR_AT.match(l)
                        if m and int(m.group(2)) == ln and int(m.group(3)) >= col:
                            lines[k] = "%s%d:%d:%s" % (m.group(1), ln, int(m.group(3)) + 1, l[m.end():])
                open(g, "w").write("\n".join(lines))


def main():
    import hashlib
    args = sys.argv[1:]
    if len(args) < 2 or args[0] not in ("scan", "apply"):
        sys.exit(__doc__)
    act, rest = args[0], args[1:]
    forced = []
    if "--force" in rest:
        i = rest.index("--force")
        rest, forced = rest[:i], [os.path.abspath(f) for f in rest[i + 1:]]
        if not forced:
            sys.exit("--force needs at least one FILE")
    paths = rest + forced
    if not paths:
        sys.exit(__doc__)
    rig = find_rig()
    marks = {}
    report, changed, skipped, total, current = [], 0, 0, 0, 0
    work = targets(paths)
    for root, _ in work:
        if root not in marks:
            marks[root] = {}
            mark = os.path.join(root, MARK)
            if os.path.exists(mark):
                for l in open(mark).read().split("\n"):
                    if l:
                        h, p = l.split("  ", 1)
                        marks[root][p] = h
    touched, record = [], []
    for root, path in work:
        rel = os.path.relpath(path, root)
        text = open(path).read()
        total += 1
        force = path in forced
        h = hashlib.sha256(text.encode()).hexdigest()
        # The record says the 0.2 renames are done for this text; it
        # holds back those passes only, never a later rename.
        done = not force and marks[root].get(rel) == h
        is02 = force or (not done and is_02(path, text))
        new = migrate(text, rel, report, path, is02)
        if new != text:
            changed += 1
            if act == "apply":
                open(path, "w").write(new)
        elif done:
            skipped += 1
        elif not is02:
            current += 1
            report.append("CURRENT %s: already 0.3, left alone" % os.path.relpath(path))
        if act == "apply":
            if is02 or new != text:
                touched.append(path)
            if is02 or rel in marks[root]:
                record.append((root, rel, path))
    if act == "apply" and touched:
        if rig is None:
            report.append("MANUAL: no `rig` compiler found (set RIG); write `for x in !it` over an iterator in a place by hand")
        else:
            iterator_loops(rig, touched)
    if act == "apply" and record:
        for root, rel, path in record:
            marks[root][rel] = hashlib.sha256(open(path).read().encode()).hexdigest()
        for root, m in marks.items():
            open(os.path.join(root, MARK), "w").write("".join("%s  %s\n" % (h, p) for p, h in sorted(m.items())))
    seen = set()
    for r in report:
        if r not in seen and not r.startswith("SKIP"):
            seen.add(r)
            print(r)
    if act == "scan":
        for h in hints(paths):
            print(h)
    print("%d files: %d %s, %d already migrated, %d already 0.3" % (total, changed, "rewritten" if act == "apply" else "to rewrite", skipped, current))


if __name__ == "__main__":
    main()
