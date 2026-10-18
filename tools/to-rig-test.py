#!/usr/bin/env python3
"""Write behavior and rejection tests as Rig test files (docs/RIG-TESTS.md):

    tools/to-rig-test.py OUT.rig.test "TITLE" TEST...   the tests named, in one file
    tools/to-rig-test.py --all DIR                      every test of test/behavior and
                                                        test/reject, in files by area

A TEST is a `.rig` file or a directory holding `main.rig`. With --all,
each area's tests are grouped by the first word of their names: a group
of 15 or more is a file of its own (`ownership-match.rig.test`), the rest
of the area shares one (`ownership-misc.rig.test`), and a file of more
than MAX_RUNS cases that run is split in parts.

A file under test/reject/ becomes a `fail` case, a behavior test with an
`# expect-panic:` line a `bomb` case, and any other a `test` case, named
by its file with `_` as a space. Every `use` of the standard library
moves to the top of the file, once, where it serves every case (Rig
accepts a `use` a program does not need). Its directives become the header's
result and options; its `sub main()` goes, its statements moving two
spaces out, and the positions its `# error:` lines pin move with them. A
test whose top level holds more than declarations and a plain `sub
main()` keeps its whole program, `main` and all, and so does a test of
several files, whose other files follow its body as `file "PATH"`
blocks.
"""
import os
import re
import sys

DECL = re.compile(r"^(pub )?(inline )?(fun|sub|obj|enum|error|type|use|extern) [A-Za-z_\"]")
MAX_RUNS = 120
OWN_FILE = 15
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


def entry(path):
    return os.path.join(path, "main.rig") if os.path.isdir(path) else path


def uses(path):
    return [l.rstrip() for l in open(entry(path), newline="").read().split("\n") if l.startswith("use std.")]


def convert(path, name=None):
    many = os.path.isdir(path)
    source = open(entry(path), newline="").read()
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
            key, value = m.group(1), m.group(2).rstrip("\r")
            if key == "error":
                d["errors"].append(value)
            else:
                d[{"expect-panic": "panic", "expect-exit": "exit", "errors": "count", "timeout": "timeout"}[key]] = value
        elif line.rstrip() == "# release":
            d["release"] = True
        elif line.startswith("use std.") and not many:
            pass
        else:
            keep.append((i + 1, line))
        i += 1

    top = [l for _, l in keep if l and not l[0].isspace() and not l.startswith("#")]
    whole = many or not top or any(not (DECL.match(l) or l.rstrip() == "sub main()") for l in top)
    # A test that compares stderr keeps its program, so the positions a
    # panic names there stay where they are.
    whole = whole or d["stderr"] is not None
    # An error pinned to `sub main()` itself needs the line kept.
    mains = {at for at, l in keep if l.rstrip() == "sub main()"}
    pinned = {int(m.group(1)) for e in d["errors"] for m in [re.match(r"^(\d+):\d+: ", e)] if m}
    whole = whole or bool(mains & pinned)

    def lay(whole):
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
                    # `main` goes only where moving its body out two
                    # columns changes nothing else: no line of it stands
                    # less than two spaces in, and none of its own
                    # statements is a declaration (one nested in `main`
                    # would become a module's).
                    if l.strip() and not l.startswith("  "):
                        return None
                    if DECL.match(l[2:]):
                        return None
                    body.append((at, 2, l[2:]))
                else:
                    body.append((at, 0, l))
        while body and not body[-1][2].strip():
            body.pop()
        while body and not body[0][2].strip():
            body.pop(0)
        return body

    body = None if whole else lay(False)
    whole = body is None
    if whole:
        body = lay(True)

    def pin(text, body):
        m = re.match(r"^(\d+):(\d+): (.*)$", text)
        # A test of several files keeps its program, and a pin may name a
        # place in any of its files: it stays as it is.
        if not m or many:
            return text
        line, col = int(m.group(1)), int(m.group(2))
        for k, (at, moved, _) in enumerate(body):
            if at == line and col - moved >= 1:
                return f"{k + 1}:{col - moved}: {m.group(3)}"
        return None

    # A pin that cannot move with its line keeps the program whole.
    if not whole and any(pin(e, body) is None for e in d["errors"]):
        whole, body = True, lay(True)
    errors = [pin(e, body) for e in d["errors"]]
    if any(e is None for e in errors):
        sys.exit(f"{path}: an error's position is on no line of the program")

    if "/reject/" in path:
        verb = "fail"
        items = [rig_string(e) for e in errors]
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
    # The runner takes a body for a whole program when it declares `main`;
    # one that does not says so.
    if whole and not many and not any(re.search(r"\b(sub|fun) main\b", l) for _, _, l in body if l and not l[0].isspace() and not l.startswith("#")):
        items.append("whole: true")
    # A directory test is a module named `main`; a test of one file is named
    # for the case, as the file was.
    if many and not any(f != "main.rig" for _, _, fs in os.walk(path) for f in fs):
        items.append('file: "main.rig"')
    name = name or os.path.basename(path.rstrip("/")).removesuffix(".rig").replace("_", " ")
    header = f'{verb} "{name}"' + "".join(", " + it for it in items)
    out = [header]
    if verb == "test" and heredoc is not None:
        header = f'{verb} "{name}", ' + "".join(it + ", " for it in items) + "'''"
        out = [header] + [("  " + l) if l else "" for l in heredoc] + ["'''"]
    out += [("  " + l) if l.strip() else "" for _, _, l in body]
    if many:
        for dirpath, _, names in sorted(os.walk(path)):
            for f in sorted(names):
                rel = os.path.relpath(os.path.join(dirpath, f), path)
                if rel == "main.rig":
                    continue
                out += ["", f'  file "{rel}"']
                out += [("    " + l) if l.strip() else "" for l in open(os.path.join(dirpath, f), newline="").read().rstrip("\n").split("\n")]
    return verb, "\n".join(out) + "\n"


def write(out, title, tests):
    """`tests`: (path, name) pairs."""
    shared = sorted({u for p, _ in tests if not os.path.isdir(p) for u in uses(p)})
    parts = [f"# {title}\n"] + ([] if not shared else ["\n" + "\n".join(shared) + "\n"])
    for path, name in tests:
        parts.append("\n" + convert(path, name)[1])
    open(out, "w", newline="").write("".join(parts))
    print(f"{out}: {len(tests)} cases")


def runs(path):
    return "/reject/" not in path


def write_all(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    areas = {}
    for kind in ("behavior", "reject"):
        root = os.path.join("test", kind)
        for area in sorted(os.listdir(root)):
            d = os.path.join(root, area)
            if not os.path.isdir(d):
                continue
            for t in sorted(os.listdir(d)):
                path = os.path.join(d, t)
                if t.endswith(".rig") or os.path.exists(os.path.join(path, "main.rig")):
                    areas.setdefault(area, []).append(path)
    for area, paths in sorted(areas.items()):
        # A test and a rejection of the same name keep apart by their names.
        stems = {}
        for p in paths:
            stems.setdefault(os.path.basename(p).removesuffix(".rig"), []).append(p)
        named = []
        for stem, ps in sorted(stems.items()):
            for p in sorted(ps, key=lambda p: not runs(p)):
                name = stem.replace("_", " ")
                if len(ps) > 1 and not runs(p):
                    name += " is rejected"
                named.append((p, name))
        groups = {}
        for p, name in named:
            groups.setdefault(name.split(" ")[0], []).append((p, name))
        files = {}
        for word, tests in sorted(groups.items()):
            key = word if len(tests) >= OWN_FILE else "misc"
            files.setdefault(key, []).extend(tests)
        for key, tests in sorted(files.items()):
            chunks, cur, n = [], [], 0
            for t in tests:
                if n >= MAX_RUNS and runs(t[0]):
                    chunks.append(cur)
                    cur, n = [], 0
                cur.append(t)
                n += runs(t[0])
            chunks.append(cur)
            for k, chunk in enumerate(chunks):
                stem = f"{area}-{key}" + (f"-{k + 1}" if len(chunks) > 1 else "")
                what = f"tests whose names start `{key}`" if key != "misc" else "the rest of its tests"
                write(os.path.join(out_dir, stem + ".rig.test"), f"{area}: {what}" + (f", part {k + 1}" if len(chunks) > 1 else "") + ".", chunk)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--all":
        write_all(sys.argv[2])
        return
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    write(sys.argv[1], sys.argv[2], [(p, None) for p in sys.argv[3:]])


main()
