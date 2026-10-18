#!/usr/bin/env python3
"""Write the behavior and rejection tests named into one Rig test file
(docs/RIG-TESTS.md):

    tools/to-rig-test.py OUT.rig.test "TITLE" FILE.rig...

A file under test/reject/ becomes a `fail` case, a behavior test with an
`# expect-panic:` line a `bomb` case, and any other a `test` case, named
by its file with `_` as a space. Every `use` of the tests moves to the
top of the file, once, where it serves every case (Rig accepts a `use`
a program does not need). Its directives become the header's
result and options; its `sub main()` goes, its statements moving two
spaces out, and the positions its `# error:` lines pin move with them. A
test whose top level holds more than declarations and a plain `sub
main()` keeps its whole program, `main` and all.
"""
import os
import re
import sys

DECL = re.compile(r"^(pub )?(fun|sub|obj|enum|error|type|use|extern) ")
BLOCKS = ("# expect:", "# expect-stderr:")


def rig_string(text):
    out = []
    for ch in text:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 0x20:
            out.append("\\x%02x" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def uses(path):
    return [l.rstrip() for l in open(path).read().split("\n") if l.startswith("use ")]


def convert(path):
    source = open(path).read()
    lines = source.rstrip("\n").split("\n")
    d = {"expect": None, "stderr": None, "panic": None, "exit": None, "errors": [], "count": None, "release": False, "timeout": None}
    keep = []  # (line in the file, text)
    i = 0
    while i < len(lines):
        line = lines[i]
        t = line.rstrip()
        if t in BLOCKS:
            block = []
            i += 1
            while i < len(lines) and lines[i].startswith("#") and lines[i].rstrip() not in BLOCKS:
                block.append(re.sub(r"^# ?", "", lines[i]).rstrip("\r"))
                i += 1
            d["expect" if t == "# expect:" else "stderr"] = block
            continue
        m = re.match(r"^# (expect-panic|expect-exit|error|errors|timeout):[ \t]*(.*)$", line)
        if m:
            key, value = m.group(1), m.group(2)
            if key == "error":
                d["errors"].append(value)
            else:
                d[{"expect-panic": "panic", "expect-exit": "exit", "errors": "count", "timeout": "timeout"}[key]] = value
        elif re.match(r"^# release[ \t]*$", line):
            d["release"] = True
        elif line.startswith("use "):
            pass
        else:
            keep.append((i + 1, line))
        i += 1

    top = [l for _, l in keep if l and not l[0].isspace() and not l.startswith("#")]
    whole = any(not (DECL.match(l) or l.rstrip() == "sub main()") for l in top)
    body = []  # (line in the file, column moved, text)
    if whole:
        body = [(at, 0, l) for at, l in keep]
    else:
        in_main = False
        for at, l in keep:
            if l.rstrip() == "sub main()":
                in_main = True
                continue
            if in_main and l and not l[0].isspace():
                in_main = False
            if in_main:
                body.append((at, 2, l[2:] if l.startswith("  ") else l))
            else:
                body.append((at, 0, l))
    while body and not body[-1][2].strip():
        body.pop()
    while body and not body[0][2].strip():
        body.pop(0)

    def pin(text):
        m = re.match(r"^(\d+):(\d+): (.*)$", text)
        if not m:
            return text
        line, col = int(m.group(1)), int(m.group(2))
        for k, (at, moved, _) in enumerate(body):
            if at == line:
                return f"{k + 1}:{col - moved}: {m.group(3)}"
        sys.exit(f"{path}: the position {line}:{col} is on no line of the body")

    if "/reject/" in path:
        verb = "fail"
        items = [rig_string(pin(e)) for e in d["errors"]]
    elif d["panic"] is not None:
        verb = "bomb"
        items = [rig_string(d["panic"])]
        if d["expect"]:
            items.append("prints: " + rig_string("\n".join(d["expect"])))
    else:
        verb = "test"
        items = []
        heredoc = None
        if d["expect"]:
            text = "\n".join(d["expect"])
            if len(d["expect"]) == 1 and '"' not in text and "\\" not in text and text == text.strip():
                items.append(rig_string(text))
            else:
                heredoc = d["expect"]
    if d["count"] is not None:
        items.append(f"errors: {d['count']}")
    if d["exit"] is not None:
        items.append(f"exit: {d['exit']}")
    if d["stderr"] is not None:
        items.append("stderr: " + rig_string("\n".join(d["stderr"])))
    if d["release"]:
        items.append("release: true")
    if d["timeout"] is not None:
        items.append(f"timeout: {d['timeout']}")
    name = os.path.basename(path)[: -len(".rig")].replace("_", " ")
    header = f'{verb} "{name}"' + "".join(", " + it for it in items)
    out = [header]
    if verb == "test" and heredoc is not None:
        header = f'{verb} "{name}", ' + "".join(it + ", " for it in items) + "'''"
        out = [header] + [("  " + l) if l else "" for l in heredoc] + ["'''"]
    out += [("  " + l) if l.strip() else "" for _, _, l in body]
    return verb, "\n".join(out) + "\n"


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    out, title, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
    shared = sorted({u for p in paths if not os.path.isdir(p) for u in uses(p)})
    parts = [f"# {title}\n"] + ([] if not shared else ["\n" + "\n".join(shared) + "\n"])
    for path in paths:
        if os.path.isdir(path):
            sys.exit(f"{path}: a directory module is not one program; leave it out")
        parts.append("\n" + convert(path)[1])
    open(out, "w").write("".join(parts))
    print(f"{out}: {len(paths)} cases")


main()
