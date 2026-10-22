#!/usr/bin/env python3
"""Prove a source rewrite changed no program: OLD_RIG on the tree at
OLD_ROOT against NEW_RIG on the rewritten tree at NEW_ROOT.

    emit_equiv.py OLD_RIG OLD_ROOT NEW_RIG NEW_ROOT [-j N] [--docs-only]

For every program entry (.rig files as test/run takes them, and the
```rig blocks of the Markdown files, each old block paired with the
new block of its file that its rewrite became), it compares `rig check`'s verdict, the messages of a rejection
(without their file:line:col, which a rewrite may move), and, for an
accepted program, the Zig `rig emit` prints. It prints each program
that differs and exits 1 if any does.
"""
import concurrent.futures as cf
import os
import re
import subprocess
import sys
import tempfile


def entries(root):
    files = subprocess.run(["git", "ls-files", "*.rig"], cwd=root, capture_output=True, text=True).stdout.split()
    out = []
    for f in files:
        d = os.path.dirname(f)
        if os.path.basename(f) != "main.rig" and os.path.exists(os.path.join(root, d, "main.rig")):
            continue
        out.append(f)
    return out


def blocks(root):
    out = {}
    for md in subprocess.run(["git", "ls-files", "*.md"], cwd=root, capture_output=True, text=True).stdout.split():
        lines = open(os.path.join(root, md)).read().split("\n")
        i, n, mods = 0, 0, {}
        while i < len(lines):
            m = re.match(r"^```rig([ \t].*)?$", lines[i])
            if not m:
                i += 1
                continue
            j = i + 1
            while j < len(lines) and lines[j] != "```":
                j += 1
            text = "\n".join(lines[i + 1:j]) + "\n"
            name = next((w[5:] for w in (m.group(1) or "").split() if w.startswith("file=")), None)
            if name:
                mods[name] = text
            else:
                out["%s#%d" % (md, n)] = (text, dict(mods), "fragment" in (m.group(1) or ""))
                mods = {}
                n += 1
            i = j + 1
    return out


def run(rig, cwd, path):
    c = subprocess.run([rig, "check", path], cwd=cwd, capture_output=True, text=True)
    if c.returncode != 0:
        msgs = re.findall(r"^\S*?:\d+:\d+: +(?:error|note): (.*)$", c.stdout + c.stderr, re.M)
        return ("rejected", tuple(msgs) or (c.stdout + c.stderr)[:400])
    e = subprocess.run([rig, "emit", path], cwd=cwd, capture_output=True, text=True)
    return ("accepted", e.returncode, e.stdout)


def main():
    args = sys.argv[1:]
    jobs = 4
    if "-j" in args:
        k = args.index("-j")
        jobs = int(args[k + 1])
        del args[k:k + 2]
    args = [a for a in args if a != "--docs-only"]
    old_rig, old_root, new_rig, new_root = [os.path.abspath(a) for a in args]
    work = []
    old_e, new_e = entries(old_root), set(entries(new_root))
    for f in old_e:
        if f in new_e:
            work.append((f, (old_root, f), (new_root, f)))
    if "--docs-only" in sys.argv:
        work = []
    tmp = tempfile.mkdtemp(prefix="emit-equiv-")
    ob, nb = blocks(old_root), blocks(new_root)
    # A doc block is paired with the new block its rewrite became, in the
    # same file (blocks added since have none).
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import polish_rewrite as pr

    def rewritten(text):
        lines = text.rstrip("\n").split("\n")
        e = pr.Edits()
        pr.add_params(lines, e)
        pr.rename_builtins(lines, e)
        return "\n".join(pr.tidy(lines)[0]).strip("\n")
    by_text = {}
    for key, val in nb.items():
        by_text.setdefault((key.split("#")[0], val[0].strip("\n")), []).append(key)
    pairs = []
    for key, val in ob.items():
        cands = by_text.get((key.split("#")[0], rewritten(val[0])), [])
        if cands:
            pairs.append((key, cands.pop(0)))
    paired_new = {b for _, b in pairs}
    for okey, nkey in sorted(pairs):
        if ob[okey][2]:
            continue  # a fragment is only parsed
        key = nkey
        pair = []
        for side, (text, mods, _) in (("old", ob[okey]), ("new", nb[nkey])):
            d = os.path.join(tmp, side, key.replace("/", "-").replace("#", "-"))
            os.makedirs(d, exist_ok=True)
            for name, mtext in mods.items():
                open(os.path.join(d, name), "w").write(mtext)
            open(os.path.join(d, "main.rig"), "w").write(text)
            pair.append((d, "main.rig"))
        work.append((key, pair[0], pair[1]))
    missing = len(nb) - len(paired_new)
    print("unpaired new doc blocks: %s" % sorted(set(nb) - paired_new))
    print("unpaired old doc blocks: %s" % sorted(set(ob) - {a for a, _ in pairs}))

    def one(w):
        name, (oc, op), (nc, np_) = w
        return name, run(old_rig, oc, op), run(new_rig, nc, np_)

    bad = 0
    with cf.ThreadPoolExecutor(jobs) as ex:
        for name, o, n in ex.map(one, work):
            if o != n:
                bad += 1
                what = "verdict" if o[0] != n[0] else ("messages" if o[0] == "rejected" else "emit")
                print("DIFFERS %s (%s): old %s, new %s" % (name, what, str(o)[:200], str(n)[:200]))
    print("%d programs compared, %d differ%s" % (len(work), bad, ", %d new doc blocks unpaired" % missing if missing else ""))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
