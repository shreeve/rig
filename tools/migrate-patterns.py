#!/usr/bin/env python3
"""Rewrite variant patterns to bind their fields by name, as Rig asks
(SPEC "match"):

    .rect(w, h)            ->  .rect(:w, :h)
    .rect(h, w)            ->  .rect(w: h, h: w)      (the meaning kept)
    .between(_, close, _)  ->  .between(:close)
    .run(_?, none)         ->  .run(id: _?, note: none)
    .rect(w: w, h: tall)   ->  .rect(:w, h: tall)
    .rect(_, _), .dot()    ->  .rect, .dot
    .rect(w: _, h: tall)   ->  .rect(h: tall)

A variant with one field keeps its positional binding (`.circle(r)`).
The fields of a variant come from the `enum` and `error` declarations
of every file given and of Rig's std. A pattern whose variant is not
declared there, or is declared with different fields in two places, or
that Rig rejected already (a wrong count, order mixed with names), is
left as it is and printed as MANUAL: the script never guesses.

Patterns are found after `matches` and at the start of each arm of a
`match`. In a Markdown file only ```rig blocks change.

usage: tools/migrate-patterns.py [--dry-run] PATH...
  Each PATH is a file or a directory searched for .rig, .rig.test, and
  .md files. It prints each site it rewrites, each MANUAL one, and a
  count of both.
"""
import os, re, sys
from collections import ChainMap

NAME = r"[A-Za-z_][A-Za-z0-9_]*"
DECL = re.compile(r"^(\s*)(?:pub\s+)?(enum|error)\s+(" + NAME + r")\b")
VARIANT = re.compile(r"^\s*(" + NAME + r")\((.*)\)\s*(?:#.*)?$")
MATCH = re.compile(r"(?<![.\w])match\b(?!\w)")
MATCHES = re.compile(r"(?<![.\w])matches\b")
HEAD = re.compile(r"(?:" + NAME + r"\.)*\.?(" + NAME + r")\(")
FENCE = re.compile(r"^\s*```")


def lines_of(text):
    """`text`'s lines, each with its `\\n`: no other byte ends one."""
    return re.findall(r"[^\n]*\n|[^\n]+$", text)


def split_top(s):
    """`s` split at its commas outside brackets and strings."""
    parts, depth, cur, q = [], 0, "", None
    for ch in s:
        if q:
            cur += ch
            if ch == q:
                q = None
            continue
        if ch in "\"'":
            q = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
            continue
        cur += ch
    parts.append(cur)
    return [p.strip() for p in parts]


def closing(text, i):
    """The index of the `)` that closes the `(` at `i`, or -1."""
    depth, q = 0, None
    while i < len(text):
        ch = text[i]
        if q:
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch == "#":
            j = text.find("\n", i)
            if j < 0:
                return -1
            i = j
            continue
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


# --- Declarations ----------------------------------------------------------


def declared(text, variants):
    """Add each payload variant `text` declares to `variants`: its name
    to the set of its field-name tuples."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        m = DECL.match(lines[i])
        i += 1
        if not m:
            continue
        outer = len(m.group(1))
        inner = None
        while i < len(lines):
            line = lines[i]
            if not line.strip() or line.strip().startswith("#"):
                i += 1
                continue
            ind = len(line) - len(line.lstrip())
            if ind <= outer:
                break
            if inner is None:
                inner = ind
            if ind == inner:
                v = VARIANT.match(line)
                if v and not line.lstrip().startswith(("fun ", "sub ", "drop")):
                    fields = []
                    for p in split_top(v.group(2)):
                        f = re.match(r"(" + NAME + r")\s*:", p)
                        if f:
                            fields.append(f.group(1))
                    if fields:
                        variants.setdefault(v.group(1), set()).add(tuple(fields))
            i += 1


# --- Rewriting one pattern -------------------------------------------------


class Manual(Exception):
    pass


def by_name(head, name, args, fields_of):
    """The pattern `head(args)` written by name, or None when it needs no
    change. Raises Manual where the fields cannot be known for sure."""
    if not args or all(a == "_" or re.fullmatch(NAME + r"\s*:\s*_", a) for a in args):
        return head
    keyed = [re.fullmatch(r"(" + NAME + r")\s*:\s*(.+)", a) for a in args]
    puns = [re.fullmatch(r":" + NAME + r"\??", a) for a in args]
    named = [k is not None or p is not None for k, p in zip(keyed, puns)]
    if all(named):
        out, changed = [], False
        for a, k in zip(args, keyed):
            if k is None:
                out.append(a)
                continue
            field, value = k.group(1), k.group(2).strip()
            if value == "_":
                changed = True
            elif value in (field, field + "?"):
                out.append(":" + value)
                changed = True
            else:
                out.append(a)
        return head + "(" + ", ".join(out) + ")" if changed else None
    if any(named):
        raise Manual("binds both in order and by name")
    if len(args) == 1:
        return None
    shapes = fields_of.get(name)
    if not shapes:
        raise Manual("no declaration of `%s` found" % name)
    if len(shapes) > 1:
        raise Manual("`%s` is declared with different fields" % name)
    fields = next(iter(shapes))
    if len(fields) != len(args):
        raise Manual("`%s` has %d fields, the pattern %d" % (name, len(fields), len(args)))
    out = []
    for f, a in zip(fields, args):
        if a == "_":
            continue
        if a == "none" or a == "_?":
            out.append("%s: %s" % (f, a))
        elif re.fullmatch(NAME + r"\??", a):
            out.append(":" + a if a.rstrip("?") == f else "%s: %s" % (f, a))
        else:
            raise Manual("`%s` is no binding" % a)
    return head + "(" + ", ".join(out) + ")" if out else head


def rewrite_span(text, start, end, fields_of, report):
    """Rewrite each variant pattern in `text[start:end]`; the new text of
    that span."""
    out, i = [], start
    while i < end:
        m = HEAD.search(text, i, end)
        if not m:
            break
        k = closing(text, m.end() - 1)
        if k < 0 or k >= end:
            break
        head = text[m.start():m.end() - 1]
        if not head.startswith(".") and not re.search(r"(?:^|\.)[A-Z]\w*\.\w+$", head):
            # A call, not a pattern: patterns name a variant `.name`, or
            # an error `E.name`, `m.E.name`.
            out.append(text[i:m.end()])
            i = m.end()
            continue
        out.append(text[i:m.start()])
        old = text[m.start():k + 1]
        inner = text[m.end():k].strip()
        args = split_top(inner) if inner else []
        if args and args[-1] == "":
            args.pop()
        try:
            new = by_name(head, m.group(1), args, fields_of)
        except Manual as why:
            report(m.start(), "MANUAL", "%s: %s" % (old, why))
            new = None
        if new is not None and new != old:
            report(m.start(), "rewrite", "%s -> %s" % (old, new))
            out.append(new)
        else:
            out.append(old)
        i = k + 1
    out.append(text[i:end])
    return "".join(out)


# --- Finding patterns ------------------------------------------------------


def code_end(line):
    """Where `line`'s code ends: at a `#` outside a string."""
    q = None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch == "#":
            return i
    return len(line)


def masked(code):
    """`code` with each string's contents blanked, so no word in a string
    reads as `match` or `matches`."""
    out, q = [], None
    for ch in code:
        if q:
            out.append(q if ch == q else " ")
            if ch == q:
                q = None
        else:
            if ch in "\"'":
                q = ch
            out.append(ch)
    return "".join(out)


def arm_pattern_end(line, start):
    """Where the pattern of the arm line starting at `start` ends: before
    `=>` or a guard's ` if `, outside brackets."""
    depth, q, i = 0, None, start
    stop = code_end(line)
    while i < stop:
        ch = line[i]
        if q:
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif depth == 0 and line.startswith("=>", i):
            return i
        elif depth == 0 and line.startswith(" if ", i):
            return i
        i += 1
    return stop


def spans(text):
    """The spans of `text` that hold patterns: each `matches` pattern,
    and each arm's pattern."""
    found = []
    lines = lines_of(text)
    offsets, pos = [], 0
    for line in lines:
        offsets.append(pos)
        pos += len(line)
    stack = []  # (indent of a match header, indent of its arms)
    for n, line in enumerate(lines):
        body = line.rstrip("\n")
        if not body.strip():
            continue
        ind = len(body) - len(body.lstrip())
        while stack and ind <= stack[-1][0]:
            stack.pop()
        if stack:
            header, arms = stack[-1]
            if arms is None:
                stack[-1] = (header, ind)
                arms = ind
            if ind == arms and not body.lstrip().startswith("#"):
                end = arm_pattern_end(body, ind)
                found.append((offsets[n] + ind, offsets[n] + end))
        code = masked(body[:code_end(body)])
        for m in MATCH.finditer(code):
            if code[m.end():].strip():
                stack.append((ind, None))
                break
        for m in MATCHES.finditer(code):
            j = m.end()
            while j < len(code) and code[j] == " ":
                j += 1
            at = offsets[n] + j
            if j < len(code) and code[j] == "(":
                k = closing(text, at)
                if k > 0:
                    found.append((at, k + 1))
                continue
            h = HEAD.match(text, at)
            if h:
                k = closing(text, h.end() - 1)
                if k > 0:
                    found.append((at, k + 1))
    return found


def migrate_code(text, fields_of, report, base=0):
    out, i = [], 0
    for start, end in sorted(set(spans(text))):
        if start < i:
            continue
        out.append(text[i:start])
        out.append(rewrite_span(text, start, end, fields_of, lambda at, kind, msg: report(base + at, kind, msg)))
        i = end
    out.append(text[i:])
    return "".join(out)


def units(text, path):
    """`text` cut into the pieces that each declare their own enums: a
    test file's cases (each starts at the margin), a Markdown file's
    ```rig blocks, or the whole of a source file. Each piece is
    (offset, text, is_code)."""
    if path.endswith(".md"):
        out, pos, start, in_rig = [], 0, 0, False
        for line in lines_of(text):
            if FENCE.match(line):
                out.append((start, text[start:pos], in_rig))
                in_rig = (not in_rig) and line.strip()[3:].strip().startswith("rig")
                out.append((pos, line, False))
                start = pos + len(line)
            pos += len(line)
        out.append((start, text[start:], in_rig))
        return out
    if path.endswith(".rig.test"):
        out, pos, start = [], 0, 0
        for line in lines_of(text):
            if pos > start and line.strip() and not line[0].isspace() and not line.startswith("#"):
                out.append((start, text[start:pos], True))
                start = pos
            pos += len(line)
        out.append((start, text[start:], True))
        return out
    return [(0, text, True)]


def migrate(text, path, file_decls, global_decls, report):
    """`text` with its patterns rewritten, each looked up first among the
    declarations of its own piece, then its file's, then all."""
    out = []
    for at, piece, code in units(text, path):
        if not code:
            out.append(piece)
            continue
        own = {}
        declared(piece, own)
        out.append(migrate_code(piece, ChainMap(own, file_decls, global_decls), report, at))
    return "".join(out)


def rig_blocks(text):
    if not text:
        return ""
    out, in_rig = [], False
    for line in lines_of(text):
        if FENCE.match(line):
            in_rig = (not in_rig) and line.strip()[3:].strip().startswith("rig")
        elif in_rig:
            out.append(line)
    return "".join(out)


def files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in ("zig-cache", ".zig-cache", "node_modules", "zig-out"))
                for name in sorted(names):
                    if name.endswith((".rig", ".rig.test", ".md")):
                        yield os.path.join(root, name)
        else:
            yield p


def main(argv):
    dry = "--dry-run" in argv
    paths = [a for a in argv if a != "--dry-run"]
    if not paths:
        sys.exit(__doc__)
    targets = list(files(paths))
    std = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "std")
    global_decls, file_decls, texts = {}, {}, {}
    for path in targets:
        with open(path, encoding="utf-8", newline="") as f:
            texts[path] = f.read()
        file_decls[path] = {}
        declared(rig_blocks(texts[path]) if path.endswith(".md") else texts[path], file_decls[path])
        for name, shapes in file_decls[path].items():
            global_decls.setdefault(name, set()).update(shapes)
    if os.path.isdir(std):
        for path in files([std]):
            if path.endswith(".rig") and path not in texts:
                with open(path, encoding="utf-8", newline="") as f:
                    declared(f.read(), global_decls)
    counts = {"rewrite": 0, "MANUAL": 0}
    for path in targets:
        text = texts[path]

        def report(at, kind, msg):
            counts[kind] += 1
            line = text.count("\n", 0, at) + 1
            print("%s:%d: %s%s" % (path, line, "MANUAL: " if kind == "MANUAL" else "", msg))

        new = migrate(text, path, file_decls[path], global_decls, report)
        if new != text and not dry:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(new)
    print("%d rewritten, %d MANUAL" % (counts["rewrite"], counts["MANUAL"]))


if __name__ == "__main__":
    main(sys.argv[1:])
