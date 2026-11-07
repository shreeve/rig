#!/usr/bin/env python3
"""Migrate a program to Rig's loop rules (SPEC "Loops"):

    while true      ->  loop

and flag, without rewriting, what has no one spelling to rewrite to,
each with a suggested rewrite:

  - a loop `else` (no loop has one);
  - a `for` or `while` loop used as a value (only `loop` gives one);
  - `break v` in a `for` or `while` loop (it carries no value there);
  - `else` on a `while true`, which never runs (delete it);
  - `while true : step`, which `loop` cannot write as a header.

Only code changes: comments and strings are left alone, and in a
Markdown file only ```rig blocks are read. In a .rig.test file the
multi-line results (`'''`) are skipped.

usage: tools/migrate-loops.py [--dry-run] [--quiet] PATH...
  Each PATH is a file, read whatever its name, or a directory searched
  for .rig, .rig.test, .rig.tmpl (a template of Rig code), and .md files. It prints each flag as PATH:LINE: what, then the
  suggestion; then each file it changes, with its count, and the totals.
  --dry-run changes no file; --quiet prints only the totals.
"""
import os, re, sys

FENCE = re.compile(r"^(\s*)```")
HEADER = re.compile(
    r"^(?P<label>(?:\$[A-Za-z_]\w*:\s*)+)?"
    r"(?:(?P<lhs>(?:new\s+)?[A-Za-z_@][\w.@]*(?:\s*:\s*[^=]+?)?)\s*(?P<op>=!?)\s+|(?P<ret>return)\s+)?"
    r"(?P<kw>for|while)\b(?P<rest>.*)$"
)
LABEL_BLOCK = re.compile(r"^\$(?P<name>[A-Za-z_]\w*):")
BREAK = re.compile(r"(?<![\w$])break\b(?P<label>\s*\$[A-Za-z_]\w*)?(?P<value>.*)$")
LOOP_HEADER = re.compile(r"^(?P<label>(?:\$[A-Za-z_]\w*:\s*)+)?(?:[^=]*=!?\s+|return\s+)?loop$")


def break_value(rest):
    """The value a `break` carries, from the text after it (and its
    label): up to a postfix `if`, a `while` step's `:`, or a bracket the
    `break` stands inside (`(n ?? break)`); empty for none."""
    depth, out, i = 0, [], 0
    while i < len(rest):
        c = rest[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and (rest.startswith(" if ", i) or rest[i:].rstrip() == " if" or rest.startswith(" : ", i) or c == ","):
            break
        out.append(c)
        i += 1
    value = "".join(out).strip()
    return "" if value.startswith(":") else value
WHILE_TRUE = re.compile(r"\bwhile\s+true\b")


def mask(line):
    """The line with its comment cut and each string's text blanked, so
    that a pattern matches only code; positions are kept."""
    out, q, i = [], None, 0
    while i < len(line):
        c = line[i]
        if q:
            if c == "\\" and i + 1 < len(line):
                out.append("  ")
                i += 2
                continue
            out.append(c if c == q else " ")
            if c == q:
                q = None
            i += 1
            continue
        if c in "\"'":
            q = c
            out.append(c)
            i += 1
            continue
        if c == "#":
            break
        out.append(c)
        i += 1
    return "".join(out).rstrip()


def code_lines(path, text):
    """The indices of the lines of `text` that are Rig code."""
    lines = text.split("\n")
    keep = []
    if path.endswith(".md"):
        in_rig = False
        for i, line in enumerate(lines):
            m = FENCE.match(line)
            if m:
                info = line.strip()[3:].strip()
                in_rig = (not in_rig) and info.startswith("rig")
                continue
            if in_rig:
                keep.append(i)
    elif path.endswith(".rig.test"):
        in_result = False
        for i, line in enumerate(lines):
            if in_result:
                if line.startswith("'''"):
                    in_result = False
                continue
            if line[:1] not in ("", " ", "\t", "'") and line.count("'''") == 1:
                in_result = True
                continue
            keep.append(i)
    else:
        keep = list(range(len(lines)))
    return lines, keep


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


class Loop:
    def __init__(self, idx, indent, kw, rest, label, value_site):
        self.idx, self.indent, self.kw, self.rest = idx, indent, kw, rest.strip()
        self.label, self.value_site = label, value_site
        self.while_true = kw == "while" and re.fullmatch(r"true", self.rest) is not None
        self.while_true_step = kw == "while" and re.match(r"true\s*:", self.rest) is not None


def analyze(path, text):
    lines, keep = code_lines(path, text)
    code = {i: mask(lines[i]) for i in keep}
    rows = [i for i in keep if code[i].strip()]
    flags, rewrites = [], []
    stack = []  # (indent, Loop or ("block", label))

    def close(indent):
        while stack and stack[-1][0] >= indent:
            stack.pop()

    def suggest_value(lp):
        return ("a `for` or `while` loop gives no value: write `r = xs.find(f) ?? d` for a search, "
                "`r = loop` with the iteration written in its body, or `return` from a function")

    def scan_breaks(i, matches):
        for bm in matches:
            label = bm.group("label")
            label = label.strip()[1:] if label else None
            value = break_value(" " + bm.group("value"))
            target = None
            for _, fr in reversed(stack):
                if isinstance(fr, Loop):
                    if label is None or fr.label == label:
                        target = fr
                        break
                elif label is not None and fr[1] == label:
                    target = None
                    break
            if value and target is not None and target.kw != "loop":
                target.value_breaks.append((i, value))

    loops = []
    for n, i in enumerate(rows):
        c = code[i]
        ind = indent_of(c)
        close(ind)
        s = c.strip()
        m = HEADER.match(s)
        header_breaks = []
        if m and m.group("kw") == "for":
            # A `for` source runs before its loop: a jump there leaves
            # the loop around it.
            header_breaks = list(BREAK.finditer(c))
            scan_breaks(i, header_breaks)
        lm = LOOP_HEADER.match(s)
        if lm:
            label = re.findall(r"\$(\w+):", lm.group("label") or "")
            stack.append((ind, Loop(i, ind, "loop", "", label[-1] if label else None, False)))
        elif m and (m.group("kw") == "for" or m.group("kw") == "while"):
            label = m.group("label")
            label = re.findall(r"\$(\w+):", label)[-1] if label else None
            value_site = bool(m.group("op") or m.group("ret"))
            lp = Loop(i, ind, m.group("kw"), m.group("rest"), label, value_site)
            loops.append(lp)
            # The block's extent, then an `else` at the loop's indent.
            j = n + 1
            while j < len(rows) and indent_of(code[rows[j]]) > ind:
                j += 1
            lp.else_idx = None
            if j < len(rows) and indent_of(code[rows[j]]) == ind and code[rows[j]].strip() == "else":
                lp.else_idx = rows[j]
            lp.value_breaks = []
            # A jump in a `while` header leaves that loop.
            stack.append((ind, lp))
        else:
            b = LABEL_BLOCK.match(s)
            if b and s.endswith(":"):
                stack.append((ind, ("block", b.group("name"))))
        scan_breaks(i, [bm for bm in BREAK.finditer(c) if bm.start() not in {h.start() for h in header_breaks}])

    for lp in loops:
        ln = lp.idx + 1
        if lp.while_true:
            new = WHILE_TRUE.sub("loop", lines[lp.idx], count=1)
            if new != lines[lp.idx]:
                rewrites.append((lp.idx, new))
            if lp.else_idx is not None:
                flags.append((lp.else_idx + 1, "`else` on `while true`, which never runs",
                              "delete the `else` and its block: a `loop` ends only by a jump"))
            continue
        if lp.while_true_step:
            flags.append((ln, "`while true : step`",
                          "write `loop`, with the step as the body's last line (a `continue` then skips it; write the step before each `continue`)"))
            continue
        what = f"`{lp.kw}`"
        if lp.else_idx is not None:
            flags.append((lp.else_idx + 1, f"`else` on a {what} loop",
                          "a loop has no `else`: test first (`if not xs.any(f)`, `xs.find(f) ?? d`), "
                          "or set a name before the loop, change it before the `break`, and test it after"))
        if lp.value_site:
            flags.append((ln, f"a {what} loop used as a value", suggest_value(lp)))
        for bi, value in lp.value_breaks:
            flags.append((bi + 1, f"`break {value}` in a {what} loop",
                          f"a `break` there carries no value: assign the value to a name declared before the loop, then `break`; or make the loop a `loop`"))
    flags.sort()
    return lines, flags, rewrites


def files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in ("zig-cache", ".zig-cache", "zig-out", "node_modules"))
                for name in sorted(names):
                    if name.endswith((".rig", ".rig.test", ".rig.tmpl", ".md")):
                        yield os.path.join(root, name)
        else:
            yield p


def main(argv):
    dry = "--dry-run" in argv
    quiet = "--quiet" in argv
    paths = [a for a in argv if a not in ("--dry-run", "--quiet")]
    if not paths:
        print(__doc__.strip().splitlines()[-5], file=sys.stderr)
        return 2
    total_rw, total_flags, changed = 0, 0, 0
    kinds = {}
    for path in files(paths):
        with open(path, encoding="utf-8", newline="") as f:
            text = f.read()
        lines, flags, rewrites = analyze(path, text)
        for ln, what, fix in flags:
            key = re.sub(r"`break [^`]*`", "`break v`", what)
            kinds[key] = kinds.get(key, 0) + 1
            if not quiet:
                print(f"{path}:{ln}: {what}\n    {fix}")
        total_flags += len(flags)
        if rewrites:
            for i, new in rewrites:
                lines[i] = new
            total_rw += len(rewrites)
            changed += 1
            if not quiet:
                print(f"{path}: {len(rewrites)} `while true` -> `loop`")
            if not dry:
                with open(path, "w", encoding="utf-8", newline="") as f:
                    f.write("\n".join(lines))
    verb = "would rewrite" if dry else "rewrote"
    print(f"{verb} {total_rw} `while true` in {changed} files; {total_flags} flagged")
    for k in sorted(kinds):
        print(f"  {kinds[k]:5}  {k}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
