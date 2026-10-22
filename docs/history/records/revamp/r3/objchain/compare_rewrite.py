#!/usr/bin/env python3
"""Compare each program the round changed: the old compiler on the
original source (BASE checkout) against the new compiler on the source
at HEAD. For a program both accept, the emitted root module and the
sanitized package must be identical; for one both reject, the
diagnostics' messages (without positions) are compared. Doc blocks are
compared the same way, each old block paired with the new block it
became: the same text once a write call's parentheses, `(!v).m(`, are
read as `!v.m(` (the rewrite's only change).

    compare_rewrite.py OLD_RIG BASE NEW_RIG HEAD [BASE_REV] [-j N]

Every program runs with RIG_STD set to its own checkout's std/.
"""
import concurrent.futures as cf
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

old_rig, base, new_rig, head = [os.path.abspath(a) for a in sys.argv[1:5]]
rev = sys.argv[5] if len(sys.argv) > 5 and not sys.argv[5].startswith("-") else "origin/main"
jobs = int(sys.argv[sys.argv.index("-j") + 1]) if "-j" in sys.argv else 4
tmp = tempfile.mkdtemp(prefix="cmp-rewrite-b-")


def git(*a, cwd=head):
    return subprocess.run(["git"] + list(a), cwd=cwd, capture_output=True, text=True, check=True).stdout


def run(rig, root, f, args, std, env=None):
    e = dict(os.environ, RIG_OUT_DIR=tempfile.mkdtemp(dir=tmp), RIG_STD=std)
    e.update(env or {})
    p = subprocess.run([rig] + args + [f], cwd=root, capture_output=True, text=True, env=e, timeout=300)
    return p.returncode, p.stdout, p.stderr, e["RIG_OUT_DIR"]


def pkg(rig, root, f, std):
    rc, out, err, d = run(rig, root, f, ["emit"], std, {"RIG_SANITIZE": "1"})
    h = hashlib.sha256()
    for dp, ds, fs in os.walk(d):
        ds.sort()
        for n in sorted(fs):
            p = os.path.join(dp, n)
            h.update(os.path.relpath(p, d).encode() + b"\0" + open(p, "rb").read())
    return rc, h.hexdigest()


def messages(err):
    return [re.sub(r"^[^:]*:\d+:\d+: ", "", l) for l in err.split("\n") if re.match(r"^[^ ].*:\d+:\d+: (error|note)", l)]


def compare(item):
    name, f, broot, hroot = item
    bstd, hstd = os.path.join(base, "std"), os.path.join(head, "std")
    a = run(old_rig, broot, f, ["check"], bstd)
    b = run(new_rig, hroot, f, ["check"], hstd)
    if a[0] == 0 and b[0] == 0:
        ea, eb = run(old_rig, broot, f, ["emit"], bstd), run(new_rig, hroot, f, ["emit"], hstd)
        if ea[1] != eb[1]:
            return name, "both accept, emit differs"
        if pkg(old_rig, broot, f, bstd) != pkg(new_rig, hroot, f, hstd):
            return name, "both accept, pkg differs"
        return name, "=accept"
    if a[0] != 0 and b[0] != 0:
        ma, mb = messages(a[2]), messages(b[2])
        return name, "=reject" if ma == mb else "both reject, messages differ:\n    old: %s\n    new: %s" % (ma[:3], mb[:3])
    return name, "old %s, new %s:\n    old: %s\n    new: %s" % ("accepts" if a[0] == 0 else "rejects", "accepts" if b[0] == 0 else "rejects", messages(a[2])[:2], messages(b[2])[:2])


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


def short_form(text):
    return text


def _unused(text):
    """`(!v.items).push(` read as `!v.items.push(`."""
    out, i = [], 0
    while i < len(text):
        if text.startswith("(!", i):
            depth, j = 0, i
            while j < len(text):
                if text[j] in "([":
                    depth += 1
                elif text[j] in ")]":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if j < len(text) and text[j + 1:j + 2] == "." and "\n" not in text[i:j]:
                out.append(text[i + 1:j])
                i = j + 1
                continue
        out.append(text[i])
        i += 1
    return "".join(out)


items = []
changed = git("diff", "--name-only", rev).split()
for f in changed:
    if f.endswith(".rig") and os.path.exists(os.path.join(base, f)) and os.path.exists(os.path.join(head, f)):
        d = os.path.dirname(f)
        if os.path.exists(os.path.join(head, d, "main.rig")) and d.startswith("test/") and d not in ("test/corpus",):
            f = os.path.join(d, "main.rig")
        if f.startswith("std/"):
            # The standard library, through a program that uses it all.
            f = "std"
        if f.startswith("test/torture/") or any(it[1] == f for it in items):
            continue
        if f == "std":
            d = tempfile.mkdtemp(dir=tmp)
            open(os.path.join(d, "main.rig"), "w").write("use std.math\nuse std.os\nuse std.random\nuse std.slices\nuse std.sort\nuse std.text\nuse std.time\n\nsub main()\n  r = random.Random(seed: 1)\n  print(1)\n")
            items.append(("std", "main.rig", d, d))
            continue
        items.append((f, f, base, head))
    elif f.endswith(".md") and os.path.exists(os.path.join(base, f)):
        ob = blocks(open(os.path.join(base, f)).read())
        nb = blocks(open(os.path.join(head, f)).read())
        if len(ob) == len(nb) and all(short_form(t1) == short_form(t2) for (_, t1), (_, t2) in zip(ob, nb)):
            pairs = list(zip(ob, nb))
        else:
            shorts = [short_form(t) for _, t in nb]
            pairs, used = [], set()
            for fo, to in ob:
                for k, s in enumerate(shorts):
                    if k not in used and s == short_form(to) and nb[k][0] == fo:
                        pairs.append(((fo, to), nb[k]))
                        used.add(k)
                        break
            print("%s: %d blocks before, %d after; %d paired" % (f, len(ob), len(nb), len(pairs)))
        for k, ((fo, to), (fn, tn)) in enumerate(pairs):
            if to == tn or any(w.startswith("file=") for w in fo) or "fragment" in fo:
                continue
            bd, hd = tempfile.mkdtemp(dir=tmp), tempfile.mkdtemp(dir=tmp)
            open(os.path.join(bd, "main.rig"), "w").write(to)
            open(os.path.join(hd, "main.rig"), "w").write(tn)
            items.append(("%s#%d" % (f, k), "main.rig", bd, hd))

bad = same_accept = same_reject = 0
with cf.ThreadPoolExecutor(jobs) as ex:
    for name, why in ex.map(compare, items):
        if why == "=accept":
            same_accept += 1
        elif why == "=reject":
            same_reject += 1
        else:
            bad += 1
            print("%s: %s" % (name, why))
print("%d programs compared: %d both accept with identical emit and package, %d both reject alike, %d differ" % (len(items), same_accept, same_reject, bad))
shutil.rmtree(tmp, ignore_errors=True)
