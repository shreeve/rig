#!/usr/bin/env python3
"""The polish round's mechanical rewrite of a Rig checkout.

    polish_rewrite.py [--check] [--root DIR] [--rig BIN]

Over every tracked (or untracked, not ignored) `.rig` file and every
```rig block of the Markdown files:

  1. A definition writes its parameter list, even when empty:
     `sub main` -> `sub main()`, `fun answer -> Int` -> `fun answer() -> Int`,
     `fun get[T] -> T` -> `fun get[T]() -> T`, `sub save!` -> `sub save()!`,
     for `fun`, `sub`, `pub`, methods, `extern fun` / `extern sub`, and the
     declarations of an `extern zig` block.
  2. Outside `raw`, Zig's names for Rig's builtins become Rig's:
     `@sizeOf` -> `@size`, `@alignOf` -> `@align`, `@TypeOf` -> `@type`,
     `@typeName` -> `@name` (keeping any space after the `@`). Inside
     `raw` both spellings work, and the
     code is left as written.
  3. Style (not under test/torture/, whose files are malformed on
     purpose): no trailing whitespace, no run of blank lines, no blank
     line at the start or end (of a file, or of a doc block), a file
     ends with one newline, and exactly one blank line between top-level
     declarations, except that one-line declarations (`use`, constants,
     `extern`, `type`) may stand together with none.

Only code is rewritten: never a string or a comment. A file or doc block
whose expected errors are the very diagnostics of rules 1 and 2 (it
tests them) keeps its code as written. Every `# error: L:C:` pin in a
file follows its line and column. A changed test/ir/*.rig gets its
snapshots regenerated with `--rig` (default bin/rig). An entry of
test/vocabulary-allow.txt follows its line.

The rewrite is idempotent: a second run changes nothing. `--check`
changes nothing and exits 1 if a run would.
"""
import argparse
import os
import re
import subprocess
import sys

EXEMPT = ("a function's parameter list is always written", "works only inside `raw`")
BUILTINS = {"sizeOf": "size", "alignOf": "align", "TypeOf": "type", "typeName": "name"}
BUILTIN_RE = re.compile(r"@(\s*)(sizeOf|alignOf|TypeOf|typeName)(?![A-Za-z0-9_])")
DEF_RE = re.compile(r"^(\s*)((?:pub\s+)?(?:extern\s+)?(?:fun|sub)\s+)([A-Za-z_][A-Za-z0-9_]*)")
RAW_RE = re.compile(r"^\s*(?:(?::[A-Za-z_]\w*|defer|errdefer)\s+)*raw\s*$")
DECL_RE = re.compile(r"^(?:pub\s+)?(?:fun|sub|struct|enum|error|type|test|use|extern|const)\b")
CONST_RE = re.compile(r"^(?:pub\s+)?[A-Za-z_]\w*\s*(?::[^=]*)?=(?!=)")
ERROR_PIN_RE = re.compile(r"^(#\s*error:\s*)(\d+):(\d+):(.*)$")
BOM = "﻿"


def split_code(line):
    """The code of `line` (strings blanked to spaces of the same length,
    so columns hold) and the column where its comment starts, or None."""
    out = []
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if c == "#":
            return "".join(out), i
        if c == '"':
            j = i + 1
            while j < n and line[j] != '"':
                j += 2 if line[j] == "\\" else 1
            j = min(j + 1, n)
            out.append('"' + " " * (j - i - 2) + ('"' if j - i >= 2 else ""))
            i = j
            continue
        if c == "'":
            j = i + 1
            while j < n:
                if line[j] == "'":
                    if j + 1 < n and line[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            j = min(j + 1, n)
            out.append("'" + " " * (j - i - 2) + ("'" if j - i >= 2 else ""))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out), None


class Edits:
    """The column edits made to one line: (start, old_len, new_len)."""

    def __init__(self):
        self.by_line = {}

    def add(self, line, start, old_len, new_len):
        self.by_line.setdefault(line, []).append((start, old_len, new_len))

    def col(self, line, col0):
        """Column `col0` of the old line, on the new one."""
        shift = 0
        for start, old_len, new_len in self.by_line.get(line, ()):
            if col0 >= start + old_len and old_len + new_len > 0:
                shift += new_len - old_len
            elif start <= col0 < start + old_len:
                shift += min(col0 - start, new_len) - (col0 - start)
        return col0 + shift


def add_params(lines, edits):
    """Rule 1, in place."""
    for k, line in enumerate(lines):
        code, _ = split_code(line)
        m = DEF_RE.match(code.lstrip(BOM) if k == 0 else code)
        if not m:
            continue
        off = len(code) - len(code.lstrip(BOM)) if k == 0 else 0
        at = off + m.end()
        p = at
        while p < len(code) and code[p] == " ":
            p += 1
        if p < len(code) and code[p] == "[":
            depth = 0
            while p < len(code):
                if code[p] == "[":
                    depth += 1
                elif code[p] == "]":
                    depth -= 1
                    if depth == 0:
                        break
                p += 1
            if depth != 0:
                continue
            at = p + 1
        rest = code[at:].strip()
        if not (rest == "" or rest.startswith("->") or rest.startswith("!")):
            continue  # `(` already, or something malformed
        lines[k] = line[:at] + "()" + line[at:]
        edits.add(k, at, 0, 2)


def rename_builtins(lines, edits):
    """Rule 2, in place, outside `raw` blocks."""
    raw_indent = None
    for k, line in enumerate(lines):
        code, _ = split_code(line)
        if code.strip() == "":
            continue
        indent = len(code) - len(code.lstrip(" " + BOM))
        if raw_indent is not None and indent <= raw_indent:
            raw_indent = None
        if raw_indent is None and RAW_RE.match(code):
            raw_indent = indent
            continue
        if raw_indent is not None:
            continue
        new, last = [], 0
        for m in BUILTIN_RE.finditer(code):
            new.append(line[last:m.start()])
            rig = "@" + m.group(1) + BUILTINS[m.group(2)]
            new.append(rig)
            edits.add(k, m.start(), len(m.group(0)), len(rig))
            last = m.end()
        if last:
            new.append(line[last:])
            lines[k] = "".join(new)


def item_starts(lines):
    """The top-level items: (start, end, is_decl) line ranges, where a
    line at column 0 that is code, outside brackets and not continuing
    the line before, starts one."""
    items = []
    depth = 0
    cont = False
    for k, line in enumerate(lines):
        code, _ = split_code(line)
        body = code.lstrip(BOM) if k == 0 else code
        stripped = body.strip()
        if stripped:
            starts = depth == 0 and not cont and not body[0].isspace()
            if starts:
                items.append([k, k, bool(DECL_RE.match(body) or CONST_RE.match(body))])
            elif items:
                items[-1][1] = k
            for c in code:
                if c in "([":
                    depth += 1
                elif c in ")]":
                    depth = max(0, depth - 1)
            cont = code.rstrip().endswith("\\")
        elif line.strip() and items and line[0].isspace():
            items[-1][1] = k  # an indented comment belongs to its item
    return items


def tidy(lines):
    """Rule 3: the new lines and, for each old line, its new index."""
    # A comment keeps its trailing spaces: an `# expect:` line may need
    # them.
    lines = [l if l.lstrip().startswith("#") else l.rstrip() for l in lines]
    # One blank line before a declaration that lacks one.
    items = item_starts(lines)
    insert = set()
    for a, b in zip(items, items[1:]):
        if not (a[2] and b[2]):
            continue
        gap = lines[a[1] + 1:b[0]]
        if any(not g.strip() for g in gap):
            continue
        if a[1] > a[0] or b[1] > b[0]:
            insert.add(a[1] + 1)
    out, where = [], []
    blank_run = 0
    for k, l in enumerate(lines):
        if k in insert and out and out[-1] != "":
            out.append("")
        if l.strip() == "":
            if not out or out[-1] == "":
                where.append(len(out) - 1 if out else 0)
                continue
        where.append(len(out))
        out.append(l)
    while out and out[-1] == "":
        out.pop()
    return out, where


def expected_errors(lines):
    return [l for l in lines if re.match(r"^#\s*error:", l)]


def rewrite_rig(text, style, syntax=True):
    """The rewritten text, the old-to-new line map, and the column edits."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    edits = Edits()
    exempt = any(e in l for l in expected_errors(lines) for e in EXEMPT)
    if syntax and not exempt:
        add_params(lines, edits)
        rename_builtins(lines, edits)
    where = list(range(len(lines)))
    if style:
        lines, where = tidy(lines)
    return lines, where, edits


def repin(lines, where, edits):
    """Each `# error: L:C:` pin follows its line and column."""
    out = []
    for l in lines:
        m = ERROR_PIN_RE.match(l)
        if m:
            old = int(m.group(2)) - 1
            if 0 <= old < len(where):
                col0 = edits.col(old, int(m.group(3)) - 1)
                l = "%s%d:%d:%s" % (m.group(1), where[old] + 1, col0 + 1, m.group(4))
        out.append(l)
    return out


def rewrite_md(text):
    lines = text.split("\n")
    out, i, changed_blocks = [], 0, 0
    while i < len(lines):
        out.append(lines[i])
        if not re.match(r"^```rig([ \t].*)?$", lines[i]):
            i += 1
            continue
        j = i + 1
        while j < len(lines) and lines[j] != "```":
            j += 1
        body = lines[i + 1:j]
        # The block's error block, after blank lines.
        k = j + 1
        while k < len(lines) and not lines[k].strip():
            k += 1
        errors = []
        if k < len(lines) and lines[k].startswith("```error"):
            k += 1
            while k < len(lines) and lines[k] != "```":
                errors.append(lines[k])
                k += 1
        new = body[:]
        if not any(e in l for l in errors for e in EXEMPT):
            edits = Edits()
            add_params(new, edits)
            rename_builtins(new, edits)
        new, _ = tidy(new)
        while new and not new[0].strip():
            new.pop(0)
        if new != body:
            changed_blocks += 1
        out.extend(new)
        i = j
    return "\n".join(out), changed_blocks


def multi_file_entry(path):
    """Whether `path` is the main.rig of a multi-file test or probe."""
    d = os.path.dirname(path)
    return path.startswith("test/") and os.path.basename(path) == "main.rig" and \
        any(x.endswith(".rig") and x != "main.rig" for x in os.listdir(d))


def repin_multi(main_rig, maps, rig, warnings):
    """A multi-file test's pins name a line and column of whichever file
    reports there, which the pin does not say: each pin goes where one
    of the files' rewrites moved it and the rewritten program reports
    its text, or stays where it is."""
    lines = open(main_rig, encoding="utf-8").read().split("\n")
    pins = [(k, ERROR_PIN_RE.match(l)) for k, l in enumerate(lines)]
    pins = [(k, m) for k, m in pins if m]
    if not pins:
        return False
    r = subprocess.run([rig, "check", main_rig], capture_output=True, text=True)
    reported = [(int(m.group(1)), int(m.group(2)), m.group(3)) for m in
                re.finditer(r"\.rig:(\d+):(\d+): +(?:error|note): (.*)", r.stdout + r.stderr)]
    changed = False
    for k, m in pins:
        line, col, text = int(m.group(2)), int(m.group(3)), m.group(4).strip()
        found = lambda l, c: any(rl == l and rc == c and text in msg for rl, rc, msg in reported)
        if found(line, col):
            continue
        cands = set()
        for where, edits in maps:
            if 0 < line <= len(where):
                cands.add((where[line - 1] + 1, edits.col(line - 1, col - 1) + 1))
        hits = sorted(c for c in cands if found(*c))
        if len(hits) == 1:
            lines[k] = "%s%d:%d:%s" % (m.group(1), hits[0][0], hits[0][1], m.group(4))
            changed = True
        elif not main_rig.startswith("test/corpus/"):  # a probe's pins are not checked
            warnings.append("%s:%d: pin %d:%d is reported nowhere a rewrite moved it" % (main_rig, k + 1, line, col))
    if changed:
        open(main_rig, "w", encoding="utf-8").write("\n".join(lines))
    return changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--root", default=None)
    ap.add_argument("--rig", default="bin/rig")
    args = ap.parse_args()
    root = args.root or subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    os.chdir(root)
    files = sorted(set(subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"],
                                      capture_output=True, text=True, check=True).stdout.split("\n")) - {""})
    changed, md_blocks, warnings, ir_changed = [], 0, [], []
    allow_path = "test/vocabulary-allow.txt"
    allow = open(allow_path).read() if os.path.exists(allow_path) else None
    moved_lines = {}  # path -> {old line text: new line text}, for the allow list
    line_maps = {}
    for f in files:
        if not os.path.isfile(f):
            continue
        if f.endswith(".rig"):
            text = open(f, encoding="utf-8").read()
            style = not f.startswith("test/torture/")
            lines, where, edits = rewrite_rig(text, style)
            if not multi_file_entry(f):
                lines = repin(lines, where, edits)
            new = "\n".join(lines) + "\n" if lines else ""
            if not style and not text.endswith("\n"):
                new = new[:-1] if new.endswith("\n") else new
            if new != text:
                changed.append(f)
                old_lines = text.split("\n")
                for k, l in enumerate(old_lines[:len(where)]):
                    if where[k] < len(lines) and lines[where[k]] != l:
                        moved_lines.setdefault(f, {})[l] = lines[where[k]]
                line_maps[f] = (where, edits)
                if f.startswith("test/ir/"):
                    ir_changed.append(f)
                if not args.check:
                    open(f, "w", encoding="utf-8").write(new)
        elif f.endswith(".md"):
            text = open(f, encoding="utf-8").read()
            new, n = rewrite_md(text)
            if new != text:
                changed.append(f)
                md_blocks += n
                if not args.check:
                    open(f, "w", encoding="utf-8").write(new)
    # A multi-file test's pins, once every file is rewritten.
    if not args.check:
        dirs = sorted({os.path.dirname(f) for f in line_maps if f.startswith("test/")})
        for d in dirs:
            main_rig = os.path.join(d, "main.rig")
            if not os.path.exists(main_rig) or not multi_file_entry(main_rig):
                continue
            maps = [line_maps[x] for x in line_maps if os.path.dirname(x) == d]
            if repin_multi(main_rig, maps, args.rig, warnings) and main_rig not in changed:
                changed.append(main_rig)
    if allow is not None and moved_lines:
        new_allow = allow
        for f, moves in moved_lines.items():
            for old, new in moves.items():
                new_allow = new_allow.replace("%s: %s\n" % (f, old), "%s: %s\n" % (f, new))
        if new_allow != allow:
            changed.append(allow_path)
            if not args.check:
                open(allow_path, "w").write(new_allow)
    if ir_changed and not args.check:
        for f in ir_changed:
            base = f[:-4]
            for cmd, ext in (("parse", "raw"), ("normalize", "sem")):
                r = subprocess.run([args.rig, cmd, f], capture_output=True, text=True)
                if r.returncode != 0:
                    warnings.append("%s: rig %s failed: %s" % (f, cmd, r.stderr.strip().split("\n")[0]))
                    continue
                open("%s.%s.sexp" % (base, ext), "w").write(r.stdout if r.stdout.endswith("\n") else r.stdout + "\n")
    rig_n = sum(1 for f in changed if f.endswith(".rig"))
    md_n = sum(1 for f in changed if f.endswith(".md"))
    print("%s %d .rig files and %d .md files (%d rig blocks)%s" % (
        "would change" if args.check else "changed", rig_n, md_n, md_blocks,
        (", and " + allow_path) if allow_path in changed else ""))
    for w in warnings:
        print("warning: " + w, file=sys.stderr)
    if args.check and changed:
        for f in changed:
            print("  " + f)
        sys.exit(1)


if __name__ == "__main__":
    main()
