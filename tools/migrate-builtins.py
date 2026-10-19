#!/usr/bin/env python3
"""Move Rig's builtin calls from `@name(...)` to `$name(...)`.

    migrate-builtins.py scan  PATH...  report what would change, change nothing
    migrate-builtins.py apply PATH...  rewrite the files in place

A PATH is a directory (every `.rig`, `.rig.tmpl`, `.rig.test`, and `.md`
file under it) or a file of one of those kinds.

In Rig code every `@name(`, the `(` touching the name, is a builtin call,
but after `break` or `continue`, where `@name` is a label, so each becomes `$name(`: Rig's
own builtins (`@size`, `@align`, `@name`, `@type`, `@variants`) and
Zig's, which `raw` admits under their Zig names (`@intCast`, `@bitCast`,
`@sizeOf`, ...). String literals are left as they are.

Zig is never rewritten: a `.zig` file, the Zig a `code` case of a test
file expects, a `file "x.zig"` block of a case, and a ```` ```zig ````
block of a doc. A test file's expected results (a `fail` case's
diagnostics, a `test` case's output) are left too: the suite says which
of them name a builtin the old way.

In comments and prose, where `@` may quote Zig, only Rig's own builtins
are rewritten (`@size`, `@align`, `@name`, `@type`, `@variants`: no Zig
builtin has these names), and not on a line about labels, whose
placeholder is `@name`. Any other `@name(` there is listed as
`MANUAL path:line: text` for a person to decide.
"""
import os
import re
import sys

RIG_ONLY = re.compile(r"@(size|align|name|type|variants)\b")
CALL = re.compile(r"@([A-Za-z_][A-Za-z0-9_]*)\(")
ANY = re.compile(r"@([A-Za-z_][A-Za-z0-9_]*)\(")
HEADER = re.compile(r'^(code|fail|test|bomb) "')
FILE_BLOCK = re.compile(r'^  file "([^"]+)"\s*$')

manual = []


def prose(path, n, text):
    """A comment or a line of prose: Rig's own builtins only."""
    if "label" in text:
        return text
    out = RIG_ONLY.sub(lambda m: "$" + m.group(1), text)
    for m in ANY.finditer(out):
        manual.append(f"MANUAL {path}:{n}: {text.strip()}")
        break
    return out


def code(path, n, line):
    """A line of Rig code: every builtin call outside a string, and the
    comment after `#` as prose."""
    out, i, quote = [], 0, None
    seg_start = 0

    def flush(upto):
        seg = line[seg_start:upto]
        # After `break` or `continue`, `@name` is a label even with a `(`
        # touching it (an error the suite tests), never a builtin call.
        out.append(CALL.sub(lambda m: m.group(0) if re.search(r"\b(break|continue)\s+$", seg[:m.start()]) else "$" + m.group(1) + "(", seg))

    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
                out.append(line[seg_start:i + 1])
                seg_start = i + 1
            i += 1
            continue
        if ch in "\"'":
            flush(i)
            seg_start = i
            quote = ch
            i += 1
            continue
        if ch == "#":
            flush(i)
            out.append(prose(path, n, line[i:]))
            return "".join(out)
        i += 1
    if quote:
        out.append(line[seg_start:])
    else:
        flush(len(line))
    return "".join(out)


def rig_file(path, lines):
    return [code(path, k + 1, l) for k, l in enumerate(lines)]


def test_file(path, lines):
    out, k = [], 0
    verb, zig_block = None, False
    while k < len(lines):
        l = lines[k]
        m = HEADER.match(l)
        if m:
            verb = m.group(1)
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
