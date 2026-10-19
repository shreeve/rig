#!/usr/bin/env python3
"""Move Rig's receiver from `self` to `@`.

    migrate-receiver.py scan  PATH...  report what would change, change nothing
    migrate-receiver.py apply PATH...  rewrite the files in place

A PATH is a directory (every `.rig`, `.rig.tmpl`, `.rig.test`, and `.md`
file under it) or a file of one of those kinds.

In Rig code, outside strings, the word `self` becomes `@`, and `self.name`
becomes `@name`. `Self`, the receiver's type, stays. A `self` after a `.`
(a member named `self`) is left and listed as `MANUAL path:line: text`.

In comments and prose only code is rewritten: `self` inside a `` `...` ``
span, by the same rule. Zig is never rewritten: a `.zig` file, the Zig a
`code` case of a test file expects, a `file "x.zig"` block of a case, and
a ```` ```zig ```` block of a doc. A test file's expected results are left
too: the suite says which of them name the receiver the old way.
"""
import os
import re
import sys

HEADER = re.compile(r'^(code|fail|test|bomb) "')
FILE_BLOCK = re.compile(r'^  file "([^"]+)"\s*$')
SPAN = re.compile(r"(`+)(.+?)\1")
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

manual = []


def rig(path, n, text):
    """Rig code with no strings or comments in it."""
    out, i = [], 0
    while i < len(text):
        m = WORD.match(text, i)
        if not m:
            out.append(text[i])
            i += 1
            continue
        w = m.group(0)
        before = text[:i].rstrip(" \t")
        if w == "self" and not (i > 0 and (text[i - 1].isalnum() or text[i - 1] in "_$@")):
            if before.endswith(".") and not before.endswith(".."):
                manual.append(f"MANUAL {path}:{n}: {text.strip()}")
                out.append(w)
            elif text.startswith(".", m.end()) and WORD.match(text, m.end() + 1):
                out.append("@")
                i = m.end() + 1
                continue
            else:
                out.append("@")
        else:
            out.append(w)
        i = m.end()
    return "".join(out)


def prose(path, n, text):
    """A comment or a line of prose: code spans only."""
    return SPAN.sub(lambda m: m.group(1) + code(path, n, m.group(2), comments=False) + m.group(1), text)


def code(path, n, line, comments=True):
    """A line of Rig code: outside strings, and the comment after `#` as
    prose."""
    out, i, seg = [], 0, 0
    while i < len(line):
        ch = line[i]
        if ch in "\"'":
            out.append(rig(path, n, line[seg:i]))
            j = i + 1
            while j < len(line) and line[j] != ch:
                j += 2 if line[j] == "\\" else 1
            out.append(line[i:j + 1])
            i = seg = j + 1
            continue
        if ch == "#" and comments:
            out.append(rig(path, n, line[seg:i]))
            out.append(prose(path, n, line[i:]))
            return "".join(out)
        i += 1
    out.append(rig(path, n, line[seg:]))
    return "".join(out)


def rig_file(path, lines):
    return [code(path, k + 1, l) for k, l in enumerate(lines)]


def test_file(path, lines):
    out, k = [], 0
    zig_block = False
    while k < len(lines):
        l = lines[k]
        if HEADER.match(l):
            zig_block = False
            out.append(l)
            # A header's heredoc result: its lines up to `'''` alone.
            if l.rstrip().endswith("'''"):
                k += 1
                while k < len(lines) and lines[k] != "'''":
                    out.append(lines[k])
                    k += 1
                if k < len(lines):
                    out.append(lines[k])
            k += 1
            continue
        if l.startswith("  "):
            fb = FILE_BLOCK.match(l)
            if fb:
                zig_block = fb.group(1).endswith(".zig")
                out.append(l)
            elif zig_block and (l.startswith("    ") or l.strip() == ""):
                out.append(l)
            else:
                zig_block = False
                out.append(code(path, k + 1, l))
        elif l.startswith("#"):
            out.append(prose(path, k + 1, l))
        else:
            out.append(code(path, k + 1, l))
        k += 1
    return out


def md_file(path, lines):
    out, fence = [], None
    for k, l in enumerate(lines):
        m = re.match(r"^(```+)(\S*)", l)
        if m and not l.startswith("```` "):
            if fence is None:
                fence = m.group(2) or "plain"
            elif l.strip() == m.group(1):
                fence = None
            out.append(l)
            continue
        if fence is None:
            out.append(prose(path, k + 1, l))
        elif fence.startswith("rig"):
            out.append(code(path, k + 1, l))
        else:
            out.append(l)
    return out


def files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in ("zig-out",))
                for name in sorted(names):
                    if name.endswith((".rig", ".rig.tmpl", ".rig.test", ".md")):
                        yield os.path.join(root, name)
        else:
            yield p


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("scan", "apply"):
        sys.exit(__doc__)
    apply = sys.argv[1] == "apply"
    changed = 0
    for path in files(sys.argv[2:]):
        text = open(path, encoding="utf-8", newline="").read()
        lines = text.split("\n")
        if path.endswith(".rig.test"):
            new = test_file(path, lines)
        elif path.endswith(".md"):
            new = md_file(path, lines)
        else:
            new = rig_file(path, lines)
        out = "\n".join(new)
        if out != text:
            changed += 1
            n = sum(1 for a, b in zip(lines, new) if a != b)
            print(f"{'rewrote' if apply else 'would rewrite'} {path}: {n} line{'s' if n != 1 else ''}")
            if apply:
                open(path, "w", encoding="utf-8", newline="").write(out)
    for m in manual:
        print(m)
    print(f"{changed} files")


if __name__ == "__main__":
    main()
