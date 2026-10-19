#!/usr/bin/env python3
"""Move Rig's labels from `@outer` to `$outer:` and `break $outer`.

    migrate-labels-dollar.py scan  PATH...  report what would change, change nothing
    migrate-labels-dollar.py apply PATH...  rewrite the files in place

A PATH is a directory (every `.rig`, `.rig.tmpl`, `.rig.test`, and `.md`
file under it) or a file of one of those kinds.

In Rig code, outside strings, `@name` with no `(` touching the name is a
label: after `break` or `continue` it becomes `$name` (`break $outer`),
and where a statement starts (at the start of a line, or after another
label) `$name:` (`$outer: for ...`). Any other `@name` is left and listed
as `MANUAL path:line: text` for a person to decide.

Zig is never rewritten: a `.zig` file, the Zig a `code` case of a test
file expects, a `file "x.zig"` block of a case, and a ```` ```zig ````
block of a doc. A test file's expected results (a `fail` case's
diagnostics, a `test` case's output) are left too: the suite says which
of them name a label the old way.

In comments and prose, `break @name` and `continue @name` become
`break $name` and `continue $name`, and `@name` before `for`, `while`,
`match`, or `raw` becomes `$name:`. Any other `@name` with no `(` after
it, unless it is a Zig builtin's name, is listed as MANUAL.
"""
import os
import re
import sys

WORD = r"[A-Za-z_][A-Za-z0-9_]*"
HEADER = re.compile(r'^(code|fail|test|bomb) "')
FILE_BLOCK = re.compile(r'^  file "([^"]+)"\s*$')
PROSE_JUMP = re.compile(r"\b(break|continue)(\s+)@(" + WORD + r")\b(?!\()")
PROSE_DECL = re.compile(r"(?<![A-Za-z0-9_$@])@(" + WORD + r")(\s+)(for|while|match|raw)\b")
LEFT = re.compile(r"(?<![A-Za-z0-9_\\])@(" + WORD + r")\b(?!\()")
# A Zig builtin named without its `(`, in prose about Zig.
ZIG = re.compile(r"^[a-z]+[A-Z]|^(import|This|as|field|src|panic|splat|max|min|abs|mod|rem|sqrt|export|extern|cImport|compileError|compileLog|embedFile|call|select|shuffle|reduce|memcpy|memset|memmove|trap|breakpoint|ctz|clz|exp|log|sin|cos|tan|floor|ceil|round|trunc)$")

manual = []


def note(path, n, text):
    manual.append(f"MANUAL {path}:{n}: {text.strip()}")


def prose(path, n, text):
    """A comment or a line of prose."""
    out = PROSE_JUMP.sub(lambda m: f"{m.group(1)}{m.group(2)}${m.group(3)}", text)
    out = PROSE_DECL.sub(lambda m: f"${m.group(1)}:{m.group(2)}{m.group(3)}", out)
    for m in LEFT.finditer(out):
        if not ZIG.match(m.group(1)):
            note(path, n, text)
            break
    return out


def code(path, n, line):
    """A line of Rig code: every label outside a string, and the comment
    after `#` as prose."""
    out = []
    i = 0
    prev = ""  # the last word or symbol outside strings
    start = True  # a statement starts here
    while i < len(line):
        ch = line[i]
        if ch in "\"'":
            j = i + 1
            while j < len(line) and line[j] != ch:
                j += 2 if line[j] == "\\" else 1
            out.append(line[i:j + 1])
            i = j + 1
            prev, start = "str", False
            continue
        if ch == "#":
            out.append(prose(path, n, line[i:]))
            return "".join(out)
        if ch in " \t\r":
            out.append(ch)
            i += 1
            continue
        m = re.match("@(" + WORD + ")", line[i:])
        if m and not line[i + m.end():].startswith("("):
            name = m.group(1)
            i += m.end()
            if prev in ("break", "continue"):
                out.append("$" + name)
                prev, start = name, False
            elif start:
                out.append("$" + name + ":")
                prev, start = ":", True
            else:
                out.append(m.group(0))
                note(path, n, line)
                prev, start = name, False
            continue
        m = re.match(WORD, line[i:])
        tok = m.group(0) if m else ch
        out.append(tok)
        i += len(tok)
        prev, start = tok, False
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
