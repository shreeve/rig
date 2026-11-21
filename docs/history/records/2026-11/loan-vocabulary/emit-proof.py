#!/usr/bin/env python3
"""emit-proof.py [BASE]: the Zig bin/rig emits differs from BASE's
(default origin/main) only by the view vocabulary's renames.

Run from the checkout's root. Emits the programs tools/emit-diff emits
with BASE's rig (tools/baseline) and with bin/rig, applies the rename
table below to BASE's output, and checks that every file is then
byte-identical to bin/rig's.

The table has two parts. `IDENT` renames identifiers: the names emitted
Zig and the runtime carry, file by file. `TEXT` holds the comment and
test-name rewrites of the files written beside each program (the runtime
and std's Zig shims, copied verbatim from src/ and std/): each is a
hunk of the source diff from BASE, after `IDENT`, whose lines on both
sides are comments or a `test "..."` line, checked so. A program's own
Zig gets `IDENT` alone. Prints the table and the result; exits 0 when
every file matches, 1 when one does not.
"""

import importlib.machinery
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import concurrent.futures

ROOT = os.getcwd()

# Identifier renames: (files they apply to, pattern, replacement). `*`
# is every file; a name is a file's base name.
IDENT = [
    ("*", r"\brig\.lend\(", "rig.readView("),
    ("*", r"\brt\.lend\(", "rt.readView("),
    ("*", r"`rig\.lend`", "`rig.readView`"),
    ("*", r"__rig_lent", "__rig_viewed"),
    ("runtime.zig", r"\bpub fn lend\(", "pub fn readView("),
    ("runtime.zig", r"(?<![\w.])lend\(", "readView("),
    ("alloc.zig", r"(?<![\w.])lent\(", "handedOut("),
    ("alloc.zig", r"\blendSpan\b", "handOutSpan"),
    ("alloc.zig", r"\blent_out\b", "handed_out"),
    ("net.zig", r"(?<![\w.])lend\(", "callFd("),
]


# How many times each IDENT entry renamed a name in the emitted Zig.
HITS = [0] * len(IDENT)


def ident(name, text, count=False):
    for i, (where, pat, new) in enumerate(IDENT):
        if where == "*" or where == name:
            text, n = re.subn(pat, new, text)
            if count:
                HITS[i] += n
    return text


def is_prose(line):
    s = line.strip()
    return s.startswith("//") or s.startswith('test "')


def text_hunks(base, rel):
    """The (old, new) blocks of the source diff of `rel` from `base`,
    after IDENT, each of comments or test names only."""
    old = subprocess.run(["git", "show", f"{base}:{rel}"], capture_output=True, text=True, check=True).stdout
    old = ident(os.path.basename(rel), old)
    with tempfile.NamedTemporaryFile("w", suffix=".zig", delete=False) as f:
        f.write(old)
    d = subprocess.run(["diff", "-U0", f.name, rel], capture_output=True, text=True).stdout
    os.unlink(f.name)
    hunks, cur = [], None
    for line in d.splitlines():
        if line.startswith("@@"):
            cur = ([], [])
            hunks.append(cur)
        elif cur is not None and line[:1] in "-+" and not line.startswith(("---", "+++")):
            (cur[0] if line[0] == "-" else cur[1]).append(line[1:])
    out = []
    for a, b in hunks:
        bad = [l for l in a + b if not is_prose(l)]
        if bad:
            sys.exit(f"emit-proof: {rel}: a change that is no comment or test name, outside IDENT: {bad[0]!r}")
        out.append(("\n".join(a) + "\n", "\n".join(b) + "\n"))
    return out


def load_emit_diff():
    path = os.path.join(ROOT, "tools", "emit-diff")
    loader = importlib.machinery.SourceFileLoader("emit_diff", path)
    spec = importlib.util.spec_from_loader("emit_diff", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else "origin/main"
    sha = subprocess.run(["git", "rev-parse", "--verify", base + "^{commit}"], capture_output=True, text=True, check=True).stdout.strip()
    base_rig = subprocess.run([os.path.join(ROOT, "tools", "baseline"), sha], stdout=subprocess.PIPE, text=True, check=True).stdout.strip()
    cur_rig = os.path.join(ROOT, "bin", "rig")
    ed = load_emit_diff()
    work = tempfile.mkdtemp(prefix="rig-emit-proof.")
    progs = ed.programs(work, sha)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        jobs = [(side, label, pool.submit(ed.emit, rig, label, cwd, name, os.path.join(work, side, ed.slug(label))))
                for label, cwd, name in progs for side, rig in (("base", base_rig), ("cur", cur_rig))]
        status = {(side, label): job.result()[1:] for side, label, job in jobs}
    # A program both rigs refuse alike is skipped, as tools/emit-diff skips it.
    failed = set()
    for label, _, _ in progs:
        b, c = status[("base", label)], status[("cur", label)]
        if b[0] or c[0]:
            if b != c:
                sys.exit(f"emit-proof: {label}: the emits fail differently: {b[1].strip()[:200]!r} and {c[1].strip()[:200]!r}")
            failed.add(label)

    # The files of src/ and std/ that changed: an emitted file that is a
    # verbatim copy of one at BASE gets its prose rewrites (`TEXT`).
    changed = {os.path.basename(rel): rel for rel in subprocess.run(["git", "diff", "--name-only", sha, "--", "src", "std"], capture_output=True, text=True, check=True).stdout.split() if rel.endswith(".zig")}
    at_base, text = {}, {}

    def verbatim(name, old):
        if name not in changed:
            return False
        if name not in at_base:
            at_base[name] = subprocess.run(["git", "show", f"{sha}:{changed[name]}"], capture_output=True, text=True, check=True).stdout
        return old == at_base[name]

    print(f"emit-proof: rig at {sha[:12]} and bin/rig")
    files_total = files_renamed = files_text = own_renamed = 0
    used = set()
    bad = []
    for label, _, _ in progs:
        if label in failed:
            continue
        bd, cd = os.path.join(work, "base", ed.slug(label)), os.path.join(work, "cur", ed.slug(label))
        bf, cf = ed.files(bd), ed.files(cd)
        if set(bf) != set(cf):
            bad.append(f"{label}: files differ: {sorted(set(bf) ^ set(cf))}")
            continue
        for rel in sorted(bf):
            files_total += 1
            with open(os.path.join(bd, rel), encoding="utf-8", errors="surrogateescape") as f:
                old = f.read()
            with open(os.path.join(cd, rel), encoding="utf-8", errors="surrogateescape") as f:
                new = f.read()
            name = os.path.basename(rel)
            beside = verbatim(name, old)
            got = ident(name, old, count=True)
            if got != old:
                files_renamed += 1
                if not beside:
                    own_renamed += 1
            if beside:
                if name not in text:
                    text[name] = text_hunks(sha, changed[name])
                before = got
                for a, b in text[name]:
                    n = got.count(a)
                    if n != 1:
                        bad.append(f"{label}: {rel}: a TEXT hunk is found {n} times")
                        break
                    got = got.replace(a, b)
                    used.add((name, a))
                if got != before:
                    files_text += 1
            if got != new:
                bad.append(f"{label}: {rel}: differs after the table")
    print("IDENT (file, pattern, replacement, renames made in the emitted Zig):")
    for (where, pat, new), hits in zip(IDENT, HITS):
        print(f"  {where:12} {pat:24} -> {new:16} {hits}")
    print("TEXT (comment and test-name hunks of the files written beside a program):")
    for name in sorted(text):
        print(f"  {changed[name]}: {len(text[name])} hunks")
    print(f"  {sum(len(h) for h in text.values())} hunks in all, every one checked to be comments or test names")
    print(f"{len(progs)} programs ({len(failed)} refused alike by both, skipped), {files_total} files: {files_renamed} changed by IDENT ({own_renamed} of them a program's own Zig), {files_text} by TEXT")
    if bad:
        print("NOT identical:")
        for b in bad[:40]:
            print("  " + b)
        print(f"the emitted Zig is in {work}")
        return 1
    print("identical: every file of BASE's emit, renamed by the table, is byte-identical to bin/rig's")
    subprocess.run(["rm", "-rf", work])
    return 0


if __name__ == "__main__":
    sys.exit(main())
