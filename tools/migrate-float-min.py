#!/usr/bin/env python3
"""Rewrite a program's `math.min`, `math.max`, and `math.clamp` of floats
as the floats' own methods, which a float takes since it provides no
`Ord` (SPEC "Floats in order"):

    math.min(a, b)          ->  a.min(b)
    math.max(a, b)          ->  a.max(b)
    math.clamp(x, lo, hi)   ->  x.clamp(lo, hi)

A first argument that is not a name, a field, an index, or a call chain
is put in parentheses: `math.min(d + 1.0, e)` becomes `(d + 1.0).min(e)`.

The compiler finds the sites: the script runs `RIG check ARGS` and
rewrites the call at each "`math.min[Float]` cannot use" error, and runs
it again until none is left, since the compiler reports an instance
once. The other float rejections it prints as MANUAL lines with their
fix: `sort.sort` of floats is `sort.sort_by(!xs, |a, b|
a.total_order(?b) == .less)`, an `obj V: Ord` with a float field writes
its own `order` with `total_order`, and a float's `x.order(?y)` is
`x.total_order(?y)`.

Each rewrite keeps what the program computes for numbers; for a NaN the
method answers the number where `math.min` answered by argument order.

usage: tools/migrate-float-min.py [--dry-run] RIG ARGS...
  ARGS are `rig check`'s: a program, `main.rig`, or a directory module
  with its tests, `--tests src/core`.
"""
import os, re, subprocess, sys

ERROR = re.compile(r"^(\S+\.rig):(\d+):(\d+): error: (.*)$")
SITE = re.compile(r"^`(?:\w+\.)?(min|max|clamp)\[(?:Float|F32|F64)\]` cannot use")
SIMPLE = re.compile(r"^[A-Za-z_@][\w@]*(?:\.[A-Za-z_]\w*|\[[^\[\]]*\]|\([^()]*\))*$|^\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?$")


def args_of(text, open_at):
    """The arguments of the call whose `(` is at `open_at`, split at its
    top-level commas, and the index of its `)`."""
    depth = 0
    quote = None
    parts, start = [], open_at + 1
    i = open_at
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                parts.append(text[start:i].strip())
                return parts, i
        elif c == "," and depth == 1:
            parts.append(text[start:i].strip())
            start = i + 1
        i += 1
    return None, None


def rewrite(path, line, col, method):
    """Rewrites the call of `method` named at `line`:`col` of `path`.
    True when it did."""
    with open(path) as f:
        lines = f.read().split("\n")
    text = "\n".join(lines)
    at = sum(len(l) + 1 for l in lines[: line - 1]) + col - 1
    if not text.startswith(method, at):
        return False
    # The module the function is reached through: `math.` before it.
    m = re.search(r"([A-Za-z_]\w*)\.$", text[:at])
    if not m:
        return False
    start = m.start(1)
    open_at = at + len(method)
    if open_at >= len(text) or text[open_at] != "(":
        return False
    args, close = args_of(text, open_at)
    want = 3 if method == "clamp" else 2
    if args is None or len(args) != want:
        return False
    first = args[0] if SIMPLE.match(args[0]) else "(%s)" % args[0]
    call = "%s.%s(%s)" % (first, method, ", ".join(args[1:]))
    with open(path, "w") as f:
        f.write(text[:start] + call + text[close + 1 :])
    return True


def main():
    argv = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry = len(argv) != len(sys.argv) - 1
    if len(argv) < 2:
        sys.exit(__doc__.strip().split("\n\n")[-1])
    rig, check_args = argv[0], argv[1:]
    done, manual = 0, set()
    while True:
        p = subprocess.run([rig, "check", *check_args], capture_output=True, text=True)
        sites = []
        for l in (p.stdout + p.stderr).split("\n"):
            e = ERROR.match(l)
            if not e:
                continue
            path, line, col, msg = e.group(1), int(e.group(2)), int(e.group(3)), e.group(4)
            s = SITE.match(msg)
            if s:
                sites.append((path, line, col, s.group(1)))
            elif "a NaN is neither below nor above a number" in msg:
                manual.add("%s:%d:%d: %s" % (path, line, col, msg))
        if not sites:
            break
        # The last site of a line first, so an inner call's rewrite
        # leaves the outer call's position where it was.
        sites.sort(key=lambda s: (s[0], s[1], -s[2]))
        changed = False
        for path, line, col, method in sites:
            if dry:
                print("%s:%d:%d: math.%s of floats" % (path, line, col, method))
                continue
            if rewrite(path, line, col, method):
                print("%s:%d:%d: math.%s -> .%s" % (path, line, col, method, method))
                done += 1
                changed = True
            else:
                manual.add("%s:%d:%d: math.%s of floats, not rewritten" % (path, line, col, method))
        if dry or not changed:
            break
    for m in sorted(manual):
        print("MANUAL " + m)
    print("%d rewritten, %d by hand" % (done, len(manual)))


if __name__ == "__main__":
    main()
