#!/usr/bin/env python3
"""Move Rig labels from `:name` to `@name`.

    migrate-labels.py scan  PATH...  report what would change, change nothing
    migrate-labels.py apply PATH...  rewrite the files in place

A PATH is a directory (every `.rig`, `.rig.tmpl`, and `.md` file under it)
or a file of one of those kinds. In a Markdown file only the code of its
```` ```rig ```` blocks is rewritten; a line of prose that looks like it
spells a label is printed as `MANUAL path:line: text`.

A label is written `@name` now, wherever it stands:

    :outer for x in xs     ->  @outer for x in xs
    break :outer           ->  break @outer
    continue :outer        ->  continue @outer
    x ?? break :outer      ->  x ?? break @outer

The rule is on tokens, not on spacing. In code, a `:` is a label's when
it starts a statement (the start of a line, or after `=>`, `defer`,
`errdefer`, or another label) and a name follows it, or when it comes
right after `break` or `continue`; any blanks between the `:` and the
name go (`break : outer` -> `break @outer`). The one exception is the
first `:` of a `while` header, which starts its step even right after a
jump (`while a ?? break : i += 1`) and is left alone.

In comments, three label shapes are rewritten: `break :x`, `continue :x`,
and `:x for` (or `while`, `match`, `raw`), plus a backticked `` `:x` ``
(or `` `:x for` ``). Each is listed as `COMMENT path:line: text`, since a
comment may quote Zig, whose labels keep their `:` (`break :blk`). A
`# error: L:C:` place on a line that changed moves with it.

The tool is idempotent: a file it has rewritten has no `:` label left.
It prints a summary of the sites it changed. Commit first; the rewrite is
textual.
"""

import os
import re
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


def rewrite_with(old, edits):
    """Apply `edits` to `old`, and move each `# error: L:C:` place on a
    line they change."""
    if not edits:
        return old
    offs = line_starts(old)
    ed = sorted(edits)

    def newpos(p):
        delta = 0
        for a, b, new in ed:
            if p >= b:
                delta += len(new) - (b - a)
            elif p >= a:
                return a + delta
            else:
                break
        return p + delta

    moved = {}
    for m in ERROR_AT.finditer(old):
        line, col = int(m.group(2)), int(m.group(3))
        if not 1 <= line <= len(offs):
            continue
        ls = offs[line - 1]
        le = offs[line] - 1 if line < len(offs) else len(old)
        if any(a < le and b > ls for a, b, _ in ed):
            moved[m.start()] = ls + col - 1
    new = apply_edits(old, edits)
    fixes = []
    for dstart, at in moved.items():
        m = ERROR_AT.match(old, dstart)
        nd, nat = newpos(dstart), newpos(at)
        line = new.count("\n", 0, nat) + 1
        col = nat - (new.rfind("\n", 0, nat) + 1) + 1
        fixes.append((nd, nd + len(m.group(0)), "%s%d:%d:" % (m.group(1), line, col)))
    return apply_edits(new, fixes)


# ---------------------------------------------------------------------------
# Labels in code
# ---------------------------------------------------------------------------

TOKEN = re.compile(r"\n|[A-Za-z_][A-Za-z0-9_]*|=>|\S")
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
STMT_START = ("\n", "=>", "defer", "errdefer")
JUMPS = ("break", "continue")
MEMBER_LISTS = ("obj", "enum", "error")


def after_label_line(toks, i):
    """toks[i] is the name after a `:`: what follows it is a statement a
    label may name, or another label."""
    return i + 1 < len(toks) and toks[i + 1][2] in ("for", "while", "match", "raw", ":")


def code_edits(src, code, strings):
    """The label edits in the code of `src`: (start, end, "@"), each
    replacing a label's `:` and any blanks after it."""
    toks = []
    for a, b in code:
        toks.extend((m.start(), m.end(), m.group()) for m in TOKEN.finditer(src, a, b))
    toks.extend((a, b, '"') for a, b in strings)  # a string is an operand
    toks.sort()
    edits = []
    prev = "\n"        # the token before; "\n" at a line start
    prev_end = 0        # where it ends
    before = "\n"      # the token before that one
    after_label = False  # the token before is a statement's label
    nesting = 0
    header = None       # the bracket nesting of the `while` header being read
    blocks = []         # (indent, holds members) of the lines that may open a block
    in_members = False  # this line stands directly in an obj, enum, or error set
    i = 0
    while i < len(toks):
        a, b, t = toks[i]
        i += 1
        if t == "\n":
            before, prev, prev_end, after_label = prev, "\n", b, False
            if nesting == 0:
                header = None
            continue
        if prev == "\n" and nesting == 0:
            indent = a - (src.rfind("\n", 0, a) + 1)
            while blocks and blocks[-1][0] >= indent:
                blocks.pop()
            in_members = bool(blocks) and blocks[-1][1]
            word = toks[i][2] if t == "pub" and i < len(toks) else t
            blocks.append((indent, word in MEMBER_LISTS))
        stmt_start = prev in STMT_START or after_label
        after_label = False
        if t == ":":
            if header is not None and header == nesting:
                header = None  # the `while` step
                before, prev, prev_end = prev, ":", b
                continue
            # A keyword before a `:` names a member: a keyword argument
            # after `(` or `,` (`f(break: 1)`), or a field in a member list
            # (`break: Int`, `break : Int`).
            member = NAME.fullmatch(prev) and (before in ("(", ",") or (before == "\n" and in_members))
            jump = prev in JUMPS and not member
            stmt_start = stmt_start and not member
            nxt = toks[i] if i < len(toks) else None
            # Inside brackets a line break is whitespace (`f(x\n  :T)`),
            # but for a closure body laid out there: a line there starts
            # with a label only when a loop, `match`, or `raw` follows it.
            if stmt_start and nesting > 0 and prev == "\n" and not after_label_line(toks, i):
                stmt_start = False
            if (jump or stmt_start) and nxt and NAME.fullmatch(nxt[2]) and src[b:nxt[0]].strip(" \t") == "":
                # `continue:outer` -> `continue @outer`
                edits.append((a, nxt[0], " @" if jump and prev_end == a else "@"))
                after_label = not jump
                before, prev, prev_end = prev, "<label>", nxt[1]
                i += 1
                continue
            before, prev, prev_end = prev, ":", b
            continue
        if t in "([":
            nesting += 1
        elif t in ")]":
            nesting = max(0, nesting - 1)
        elif t == "while":
            header = nesting
        before, prev, prev_end = prev, t, b
    return edits


# ---------------------------------------------------------------------------
# Labels in comments
# ---------------------------------------------------------------------------

COMMENT_JUMP = re.compile(r"\b(break|continue) :([A-Za-z_][A-Za-z0-9_]*)\b")
COMMENT_STMT = re.compile(r"(?<![A-Za-z0-9_:])`?:([A-Za-z_][A-Za-z0-9_]*)(?= (?:for|while|match|raw)\b)")
TICK = re.compile(r"`:([A-Za-z_][A-Za-z0-9_]*)(?=[` ])")
ZIG_LABELS = ("blk",)


def comment_edits(src, comments, report, path):
    edits = []
    for a, b in comments:
        text = src[a:b]
        hits = []
        for m in COMMENT_JUMP.finditer(text):
            if m.group(2) in ZIG_LABELS:
                continue
            hits.append((a + m.start(0) + len(m.group(1)) + 1, a + m.start(0) + len(m.group(1)) + 2, "@"))
        for m in COMMENT_STMT.finditer(text):
            at = a + m.start(0) + (1 if m.group(0).startswith("`") else 0)
            hits.append((at, at + 1, "@"))
        for m in TICK.finditer(text):
            at = a + m.start(0) + 1
            if not any(h[0] == at for h in hits):
                hits.append((at, at + 1, "@"))
        if hits:
            line = src.count("\n", 0, a) + 1
            report.append("COMMENT %s:%d: %s" % (path, line, text.strip()))
            edits.extend(hits)
    return edits


def migrate_source(src, path, report, counts):
    code, comments, strings = spans(src)
    ce = code_edits(src, code, strings)
    me = comment_edits(src, comments, report, path)
    counts["code"] += len(ce)
    counts["comment"] += len(me)
    return rewrite_with(src, ce + me)


# ---------------------------------------------------------------------------
# Markdown: ```rig blocks
# ---------------------------------------------------------------------------

FENCE = re.compile(r"^\s*(`{3,})([^`]*)$")
PROSE_LABEL = re.compile(r"\b(?:break|continue) :[A-Za-z_]|(?<![A-Za-z0-9_`]):[a-z_]+ (?:for|while|match|raw)\b|`:[a-z_]+`")


def closes(line, fence):
    """`line` closes a block opened by `fence` backticks."""
    m = FENCE.match(line)
    return m is not None and len(m.group(1)) >= len(fence) and not m.group(2).strip()


def migrate_markdown(text, path, report, counts):
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if m:
            fence, info = m.group(1), m.group(2).split()[:1]
            out.append(lines[i])
            j = i + 1
            while j < len(lines) and not closes(lines[j], fence):
                j += 1
            body = lines[i + 1:j]
            if info == ["rig"]:
                out.extend(migrate_source("\n".join(body), "%s:%d" % (path, i + 2), report, counts).split("\n"))
            else:
                # An expected error or output may quote a label; Zig keeps
                # its own spelling.
                if info != ["zig"]:
                    for k, l in enumerate(body):
                        if PROSE_LABEL.search(l):
                            report.append("MANUAL %s:%d: %s" % (path, i + 2 + k, l.strip()))
                out.extend(body)
            if j < len(lines):
                out.append(lines[j])
            i = j + 1
            continue
        if PROSE_LABEL.search(lines[i]):
            report.append("MANUAL %s:%d: %s" % (path, i + 1, lines[i].strip()))
        out.append(lines[i])
        i += 1
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

SKIP_DIRS = ("zig-cache", ".zig-cache", "zig-out", "node_modules")


def wanted(name):
    return name.endswith(".rig") or name.endswith(".rig.tmpl") or name.endswith(".md")


def files(paths):
    out, seen = [], set()
    for p in paths:
        if os.path.isdir(p):
            found = []
            for dp, ds, fs in os.walk(p):
                ds[:] = sorted(d for d in ds if not d.startswith(".") and d not in SKIP_DIRS)
                found.extend(os.path.join(dp, n) for n in sorted(fs) if wanted(n))
        elif os.path.isfile(p):
            if not wanted(p):
                sys.exit("not a .rig, .rig.tmpl, or .md file: " + p)
            found = [p]
        else:
            sys.exit("no such file or directory: " + p)
        for f in found:
            if f not in seen:
                seen.add(f)
                out.append(f)
    return out


def main():
    args = sys.argv[1:]
    if len(args) < 2 or args[0] not in ("scan", "apply"):
        sys.exit(__doc__)
    act = args[0]
    report = []
    counts = {"code": 0, "comment": 0}
    total = changed = 0
    for path in files(args[1:]):
        text = open(path, encoding="utf-8").read()
        total += 1
        if path.endswith(".md"):
            new = migrate_markdown(text, path, report, counts)
        else:
            new = migrate_source(text, path, report, counts)
        if new != text:
            changed += 1
            if act == "apply":
                open(path, "w", encoding="utf-8").write(new)
    for r in report:
        print(r)
    print("%d files: %d %s; %d labels in code, %d in comments" % (
        total, changed, "rewritten" if act == "apply" else "to rewrite", counts["code"], counts["comment"]))


if __name__ == "__main__":
    main()
