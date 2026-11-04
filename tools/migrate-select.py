#!/usr/bin/env python3
"""Rewrite a `task.select` of closure arms as one of named arms, whose
value a `match` takes apart (SPEC "Channels"):

    got = task.select(                     got = match task.select(
      (!a).on_recv(|v| (v ?? 0) + 100),      a: !a.on_recv(),
      (!b).on_send(<x, || 0),          ->    b: !b.on_send(<x),
    )!                                     )!
                                             .a(v) => (v ?? 0) + 100
                                             .b => 0

Each arm is named for its channel when the channel is a name, else
`arm1`, `arm2`, ...; a function's name or view, `?g`, becomes its call,
`g(v)`. A closure's captures go: the body reads the enclosing scope.

It rewrites a select that is a statement, a binding's value (`x =`),
or a `return`'s, followed by `!` alone, whose closures each fit on one
line. Anything else it leaves, printing `MANUAL path:line` and why: a
`catch` after the select, a closure over several lines, a closure that
moves a capture in (`|<x|`) or holds one weakly (`|~x|`), one that
copies a capture in (`|+k, v|`) that another arm names, which could
change it after the copy, a select inside another, or a select in an
expression. A rewrite never changes what the program does.

usage: tools/migrate-select.py [--dry-run] PATH...
  Each PATH is a file or a directory searched for .rig and .rig.test
  files. It prints each file it changes, with its count.
"""
import os, re, sys

OPEN = {"(": ")", "[": "]", "{": "}"}
CLOSE = set(OPEN.values())
NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def skip_string(text, i):
    """The index past the string literal opening at `i`."""
    q = text[i]
    i += 1
    while i < len(text) and text[i] != q:
        i += 2 if text[i] == "\\" else 1
    return i + 1


def close_of(text, i):
    """The index of the bracket closing the one at `i`, or -1."""
    depth = []
    while i < len(text):
        c = text[i]
        if c in "\"'":
            i = skip_string(text, i)
            continue
        if c == "#":
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        if c in OPEN:
            depth.append(OPEN[c])
        elif c in CLOSE:
            if not depth or depth.pop() != c:
                return -1
            if not depth:
                return i
        i += 1
    return -1


def split_top(text, sep=","):
    """`text` split at each `sep` outside brackets and strings."""
    parts, depth, start, i = [], 0, 0, 0
    while i < len(text):
        c = text[i]
        if c in "\"'":
            i = skip_string(text, i)
            continue
        # A closure's parameters, `|?s, v|`, hold commas of their own.
        if c == "|" and depth == 0 and not text[start:i].strip():
            i = text.index("|", i + 1) + 1
            continue
        if c in OPEN:
            depth += 1
        elif c in CLOSE:
            depth -= 1
        elif c == sep and depth == 0:
            parts.append(text[start:i])
            start = i + 1
        i += 1
    parts.append(text[start:])
    return [p.strip() for p in parts if p.strip()]


OP = re.compile(r"^\.on_(recv|send)\(")


def arm_of(text):
    """(channel, op, sent value or None, function) of an arm, or a
    reason it cannot be rewritten."""
    shape = "an arm that is not `(!ch).on_recv(f)` or `(!ch).on_send(<v, f)`"
    if not text.startswith("(!"):
        return shape
    e = close_of(text, 0)
    m = OP.match(text[e + 1 :]) if e > 0 else None
    if not m or close_of(text, e + m.end()) != len(text) - 1:
        return shape
    op = m.group(1)
    args = split_top(text[e + 1 + m.end() : -1])
    want = 1 if op == "recv" else 2
    if len(args) != want:
        return "an arm with %d arguments" % len(args)
    value = args[0] if want == 2 else None
    return text[2:e].strip(), op, value, args[-1]


def body_of(f, op):
    """(binding, body) of an arm's function: a closure's parameter and
    its body, or a function's call. A reason when it cannot."""
    if f.startswith("|"):
        end = f.index("|", 1)
        params = split_top(f[1:end])
        body = f[end + 1 :].strip()
        if "\n" in body:
            return "a closure over several lines"
        if "task.select(" in body:
            return "a select inside another"
        if any(p.startswith("<") for p in params):
            return "a closure that moves a capture in (`|<x|`)"
        if any(p.startswith("~") for p in params):
            return "a closure that holds a capture weakly (`|~x|`)"
        rest = [p for p in params if p[0] not in "+?!"]
        if op == "recv":
            if len(rest) != 1:
                return "a receive's closure without its value"
            bind = rest[0].split(":")[0].strip()
            # A value the body never reads is not bound.
            return (bind if re.search(r"\b%s\b" % re.escape(bind), body) else None), body
        if rest:
            return "a send's closure with a parameter"
        return None, body
    name = f[1:] if f.startswith("?") else f
    if not NAME.match(name):
        return "an arm's function that is neither a closure nor a name"
    return ("v", "%s(v)" % name) if op == "recv" else (None, "%s()" % name)


CAPTURES = re.compile(r"\|([^|]*)\|")


def copied_elsewhere(arm, others):
    """Why an arm's closure that copies a capture in (`|+k, v|`) cannot
    become a body that reads `k` once the select returns: another arm
    names `k`, and may change it after the copy is made. None when no
    other arm names one."""
    m = CAPTURES.search(arm)
    if not m:
        return None
    for p in split_top(m.group(1)):
        if not p.startswith("+"):
            continue
        name = p[1:].strip()
        if any(re.search(r"\b%s\b" % re.escape(name), o) for o in others):
            return "a closure that copies `%s` in, which another arm names: the body would read it after the select" % name
    return None


SITE = re.compile(r"task\.select\(")
KEYWORD = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*:\s")
LEAD = re.compile(r"^(?P<indent>[ \t]*)(?P<head>(?:[A-Za-z_][A-Za-z0-9_]*(?:: [^=]+)? = |return )?)$")


def rewrite(text, path, manual):
    out, n, pos, skip = [], 0, 0, 0
    for m in SITE.finditer(text):
        start = m.start()
        if start < max(pos, skip):
            continue
        line_start = text.rfind("\n", 0, start) + 1
        line_no = text.count("\n", 0, start) + 1
        end = close_of(text, m.end() - 1)
        if end < 0:
            continue
        line_end = text.find("\n", end)
        line_end = len(text) if line_end < 0 else line_end
        # Named arms already: nothing to do.
        if any(KEYWORD.match(a) for a in split_top(text[m.end() : end])):
            continue
        lead = LEAD.match(text[line_start:start])
        tail = text[end + 1 : line_end]
        why = None
        if not lead:
            why = "a select inside an expression"
        elif tail.strip() != "!":
            why = "a select followed by `%s`, not `!` alone" % tail.strip() if tail.strip() else "a select that is not followed by `!`"
        arms = []
        if not why:
            texts = split_top(text[m.end() : end])
            for k, a in enumerate(texts):
                why = copied_elsewhere(a, texts[:k] + texts[k + 1 :])
                if why:
                    break
                got = arm_of(a)
                if isinstance(got, str):
                    why = got
                    break
                ch, op, value, f = got
                b = body_of(f, op)
                if isinstance(b, str):
                    why = b
                    break
                arms.append((ch, op, value) + b)
        if why:
            manual.append("MANUAL %s:%d: %s" % (path, line_no, why))
            skip = end
            continue
        indent = lead.group("indent")
        step = "  "
        names, seen = [], set()
        for k, (ch, *_r) in enumerate(arms, 1):
            name = ch if NAME.match(ch) else "arm%d" % k
            while name in seen:
                name = "%s%d" % (name, k)
            seen.add(name)
            names.append(name)
        lines = ["%s%smatch task.select(" % (indent, lead.group("head"))]
        for name, (ch, op, value, _b, _body) in zip(names, arms):
            call = "!%s.on_recv()" % ch if op == "recv" else "!%s.on_send(%s)" % (ch, value)
            lines.append("%s%s%s: %s," % (indent, step, name, call))
        lines.append("%s)!" % indent)
        for name, (_ch, op, _v, bind, body) in zip(names, arms):
            pattern = ".%s(%s)" % (name, bind) if bind and bind != "_" else ".%s" % name
            lines.append("%s%s%s => %s" % (indent, step, pattern, body))
        out.append(text[pos:line_start])
        out.append("\n".join(lines))
        pos = line_end
        n += 1
    out.append(text[pos:])
    return "".join(out), n


def files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("zig-cache", "zig-out", "node_modules")]
                for name in sorted(names):
                    if name.endswith((".rig", ".rig.test")):
                        yield os.path.join(root, name)
        else:
            yield p


def main(argv):
    dry = "--dry-run" in argv
    paths = [a for a in argv if a != "--dry-run"]
    if not paths:
        print(__doc__.strip().split("\n\n")[-1], file=sys.stderr)
        return 2
    for path in files(paths):
        with open(path) as f:
            text = f.read()
        manual = []
        new, n = rewrite(text, path, manual)
        for line in manual:
            print(line)
        if n:
            print("%s: %d" % (path, n))
            if not dry:
                with open(path, "w") as f:
                    f.write(new)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
