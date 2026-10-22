#!/usr/bin/env python3
"""Compare every program of the OLD tree under the OLD compiler with the
same program, rewritten, of the NEW tree under the NEW compiler.

    compare_rewrite.py MODE OLD_RIG OLD_ROOT NEW_RIG NEW_ROOT [-j N]

MODE (box, list, string, all) names the renames the NEW tree has made,
which fixes the names the new emitted Zig is mapped back through (below).

For a program both compilers accept, the emitted root module and the
emitted package must be identical, after the new text is mapped back
through NAMES (a type name the runtime or a hidden local carries), and
leaving out `rig/runtime.zig`, which is read as a diff on its own. For a
program both reject, the diagnostics' messages (without positions) must
equal the old ones rewritten (`rewrite.py`'s prose rule for backticked
spans and, for `list`, the word `Vec`); each difference is printed. A
program one accepts and the other rejects is printed with both messages.

Doc blocks are paired by position, or, when a branch added or removed
examples, by the rewrite of the old block.
"""
import concurrent.futures as cf
import hashlib
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rewrite as rw  # noqa: E402

args = [a for a in sys.argv[1:] if not a.startswith("-j")]
mode = args[0]
old_rig, old_root, new_rig, new_root = [os.path.abspath(a) for a in args[1:5]]
jobs = int(sys.argv[sys.argv.index("-j") + 1]) if "-j" in sys.argv else 4
tmp = tempfile.mkdtemp(prefix="cmp-rename-")
modes = ["box", "list", "string"] if mode == "all" else [mode]

# What the new compiler spells differently in the Zig it emits: the new
# text is mapped back to the old before the comparison. Whole words.
NAMES = {
    "list": [(r"\brig\.List\b", "rig.Vec"), (r"\b__rig_list\b", "__rig_vec"),
             (r"\.list(Push|Pop|Len|At|Get|Set|Clear)\b", r".vec\1")],
    "string": [(r"\brig\.String\b", "rig.Text")],
    "box": [],
}


def back(text):
    for m in modes:
        for pat, rep in NAMES[m]:
            text = re.sub(pat, rep, text)
    return text


def forward_msg(msg):
    for m in modes:
        msg = rw.rewrite_prose(m, msg, "msg", 0, [])
        if m == "string":
            msg = rw.diag_words(msg)
            # A handle's view is parenthesized when a type is printed.
            msg = re.sub(r"([*~])\?String", r"\1(?String)", msg)
        if m == "list":
            msg = re.sub(r"\?vec\b", "?list", msg)
    return msg


def run(rig, root, f, args, env=None):
    e = dict(os.environ, RIG_OUT_DIR=tempfile.mkdtemp(dir=tmp))
    e.update(env or {})
    p = subprocess.run([rig] + args + [f], cwd=root, capture_output=True, text=True, env=e, timeout=300)
    return p.returncode, p.stdout, p.stderr, e["RIG_OUT_DIR"]


def pkg(out_dir):
    """{relative path: text} of an emit's output, without the runtime."""
    res = {}
    for dp, ds, fs in os.walk(out_dir):
        ds.sort()
        for n in sorted(fs):
            p = os.path.join(dp, n)
            rel = os.path.relpath(p, out_dir)
            if rel.endswith("rig/runtime.zig") or rel.endswith("runtime.zig"):
                continue
            try:
                res[rel] = open(p).read()
            except UnicodeDecodeError:
                res[rel] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    return res


def messages(err):
    out = []
    for l in err.split("\n"):
        m = re.match(r"^[^ ].*?:\d+:\d+: (error|note|warning): (.*)$", l)
        if m:
            out.append(m.group(1) + ": " + m.group(2))
    return out


def user_names(text):
    """The names the script gave a program's own identifiers, mapped back:
    a type it called List is Chain, a variable it called Vec is List."""
    text = re.sub(r"\bList\b", "\0Vec", text)
    text = re.sub(r"\bString\b", "\0Text", text)
    text = re.sub(r"\bChain\b", "List", text)
    return text.replace("\0Vec", "Vec").replace("\0Text", "Text")


def same_mod_const(old, new):
    """Whether the texts are equal but for `var x: T = v; _ = &x;` in the
    old where the new says `const x: T = v;`: a type argument `?String` in
    an expression is a read sigil, which the emitter treats as a run-time
    expression (`isZigComptimeIn`), so the binding is `const`."""
    ol, nl = old.split("\n"), new.split("\n")
    if len(ol) != len(nl):
        return False
    for a, b in zip(ol, nl):
        if a == b:
            continue
        m = re.match(r"^(\s*)var (\w+)(: .+?)? = (.*); _ = &\2;$", a)
        if not m or b != "%sconst %s%s = %s;" % (m.group(1), m.group(2), m.group(3) or "", m.group(4)):
            return False
    return True


def edited_by_hand(f, broot, hroot):
    """Whether the new file is not what the scripts make of the old one."""
    try:
        old = open(os.path.join(broot, f)).read()
        new = open(os.path.join(hroot, f)).read()
    except OSError:
        return False
    return rewritten(old, f) != new


def compare(item):
    f, broot, hroot = item
    a = run(old_rig, broot, f, ["check"])
    b = run(new_rig, hroot, f, ["check"])
    if a[0] == 0 and b[0] == 0:
        ea = run(old_rig, broot, f, ["emit"], {"RIG_SANITIZE": "1"})
        eb = run(new_rig, hroot, f, ["emit"], {"RIG_SANITIZE": "1"})
        if ea[1] != back(eb[1]):
            if ea[1] == user_names(back(eb[1])):
                return f, "names", "emit differs only in the names the script gave the program's own identifiers"
            if same_mod_const(ea[1], user_names(back(eb[1]))):
                return f, "const", "emit differs only in a binding the emitter declares const"
            if edited_by_hand(f, broot, hroot):
                return f, "hand", "emit differs: the test was edited by hand"
            return f, "emit", "emit differs"
        pa, pb = pkg(ea[3]), pkg(eb[3])
        pb = {k: back(v) for k, v in pb.items()}
        # The standard library's Zig differs in its comments alone.
        nocomment = lambda t: re.sub(r"(?m)^\s*//.*\n", "", t)
        for k in list(pa):
            if "/std/" in "/" + k and k.endswith(".zig") and k in pb:
                pa[k], pb[k] = nocomment(pa[k]), nocomment(pb[k])
        if set(pa) != set(pb):
            return f, "pkg", "package files differ: %s" % sorted(set(pa) ^ set(pb))
        for k in pa:
            if pa[k] != pb[k]:
                return f, "pkg", "package file differs: %s" % k
        return f, None, None
    if a[0] != 0 and b[0] != 0:
        ma = [forward_msg(m) for m in messages(a[2])]
        mb = messages(b[2])
        if ma == mb:
            return f, None, None
        if sorted(ma) == sorted(mb):
            return f, "order", "both reject with the same messages in another order"
        return f, "msg", "both reject, messages differ:\n    old: %s\n    new: %s" % (ma[:4], mb[:4])
    return f, "status", "old %s, new %s:\n    old: %s\n    new: %s" % (
        "accepts" if a[0] == 0 else "rejects", "accepts" if b[0] == 0 else "rejects", messages(a[2])[:2], messages(b[2])[:2])


def blocks(text):
    lines, out, i = text.split("\n"), [], 0
    while i < len(lines):
        m = re.match(r"^```rig([ \t].*)?$", lines[i])
        if not m:
            i += 1
            continue
        body, i = [], i + 1
        while i < len(lines) and lines[i] != "```":
            body.append(lines[i])
            i += 1
        out.append(((m.group(1) or "").split(), "\n".join(body) + "\n"))
        i += 1
    return out


def rewritten(text, path):
    for m in modes:
        text = rw.rewrite_source(m, text, path, [])
    return text


def tracked(root):
    return subprocess.run(["git", "ls-files"], cwd=root, capture_output=True, text=True, check=True).stdout.split()


items = []
old_files = set(tracked(old_root))
for f in tracked(new_root):
    if f not in old_files or f.startswith("test/torture/"):
        continue
    d = os.path.dirname(f)
    if f.endswith(".rig"):
        if f.startswith("test/") and os.path.basename(f) != "main.rig" and os.path.exists(os.path.join(new_root, d, "main.rig")):
            continue
        # A standalone module of a corpus program that names no entry.
        items.append((f, old_root, new_root))
    elif f.endswith(".md"):
        ob = blocks(open(os.path.join(old_root, f)).read())
        nb = blocks(open(os.path.join(new_root, f)).read())
        texts = [t for _, t in nb]
        pairs = []
        if len(ob) == len(nb):
            pairs = list(zip(ob, nb))
        else:
            for fo, to in ob:
                rt = rewritten(to, f)
                if rt in texts:
                    pairs.append(((fo, to), nb[texts.index(rt)]))
            print("%s: %d blocks before, %d after; %d paired by the rewrite" % (f, len(ob), len(nb), len(pairs)))
        for k, ((fo, to), (fn, tn)) in enumerate(pairs):
            if any(w.startswith("file=") for w in fo) or "fragment" in fo or "pending" in fo:
                continue
            bd, hd = tempfile.mkdtemp(dir=tmp), tempfile.mkdtemp(dir=tmp)
            open(os.path.join(bd, "main.rig"), "w").write(to)
            open(os.path.join(hd, "main.rig"), "w").write(tn)
            items.append(("main.rig#%s#%d" % (f, k), bd, hd))


def fix(item):
    f, b, h = item
    if "#" in f:
        r = compare(("main.rig", b, h))
        return f, r[1], r[2]
    return compare(item)


stats = {}
bad = []
with cf.ThreadPoolExecutor(jobs) as ex:
    for f, kind, why in ex.map(fix, items):
        stats[kind or "same"] = stats.get(kind or "same", 0) + 1
        if kind:
            bad.append((kind, f, why))
for kind, f, why in sorted(bad):
    print("%s: %s: %s" % (kind, f, why))
print("%d programs compared: %s" % (len(items), ", ".join("%s %d" % kv for kv in sorted(stats.items()))))
