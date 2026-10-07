#!/usr/bin/env python3
"""Prove a refactor changed nothing: compare two Rig compilers.

    test/equiv.py OLD_RIG NEW_RIG [-j N] [--keep DIR] [--no-cache]

Runs both compilers over every tracked program (tests, examples, std,
corpus) and every ```rig block in the Markdown docs, and compares what
each prints for `parse`, `normalize`, `check`, `check --facts`, and, for
a program `check` accepts, `check --facts=sema`, `check --facts=storage`,
`emit`, and `pkg`: a hash of the whole package `RIG_SANITIZE=1 rig emit`
writes (every module, the standard library's shims, and the runtime with
its sanitizer), so a change to any module of a program, or to the code
the sanitizer adds, shows. It prints each program whose output differs,
with the sections that differ, and exits 1 if any does. Both compilers
run from the repository root, so paths in diagnostics match. A section
one compiler does not support (an unknown option exits 2) is left out
for both.

The old compiler's outputs are cached, by a hash of its binary, the
section, the program's path, and the contents of every file the program
can read (it and the modules beside it that a `use` names), in
rig-equiv-cache in the repository's git directory, so a rerun against
the same old compiler runs only the new one. `--no-cache` runs both.
"""
import concurrent.futures as cf
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECTIONS = (
    ("parse", ["parse"]),
    ("normalize", ["normalize"]),
    ("check", ["check"]),
    ("facts", ["check", "--facts"]),
)
ACCEPTED = (
    ("sema", ["check", "--facts=sema"]),
    ("storage", ["check", "--facts=storage"]),
    ("emit", ["emit"]),
    ("pkg", None),
)
# The environment that changes what a compiler prints.
ENV_KEYS = ("RIG_SANITIZE", "RIG_LEAK_TRACE", "RIG_STD")


def programs(docdir):
    """Every program's entry file, relative to ROOT; doc blocks go into docdir."""
    git = lambda pat: subprocess.run(["git", "ls-files", pat], cwd=ROOT, capture_output=True, text=True).stdout.split()
    progs = []
    for f in git("*.rig"):
        d = os.path.dirname(f)
        # A multi-file test is its directory's main.rig.
        if d.startswith("test/") and os.path.basename(f) != "main.rig" and os.path.exists(os.path.join(ROOT, d, "main.rig")):
            continue
        progs.append(f)
    for md in git("*.md"):
        lines = open(os.path.join(ROOT, md)).read().split("\n")
        modules, i = {}, 0
        while i < len(lines):
            m = re.match(r"^```rig([ \t].*)?$", lines[i])
            if not m:
                i += 1
                continue
            start, body, i = i + 1, [], i + 1
            while i < len(lines) and lines[i] != "```":
                body.append(lines[i])
                i += 1
            i += 1
            text = "\n".join(body) + "\n"
            name = next((w[5:] for w in (m.group(1) or "").split() if w.startswith("file=")), None)
            if name:
                modules[name] = text
                continue
            d = os.path.join(docdir, md[:-3].replace("/", "-"), "L%d" % start)
            os.makedirs(d)
            for f, t in [("main.rig", text)] + list(modules.items()):
                open(os.path.join(d, f), "w").write(t)
            modules = {}
            progs.append(os.path.relpath(os.path.join(d, "main.rig"), ROOT))
    return progs


def normalize(text, outdir):
    return text.replace(outdir, "<OUT>").replace(ROOT, "<ROOT>")


def run(rig, args, f, tmp):
    """What `rig ARGS f` prints, as (exit status, text); `pkg` hashes the
    sanitized package instead."""
    if args is None:
        return package(rig, f, tmp)
    env = dict(os.environ, RIG_OUT_DIR=tmp)
    try:
        p = subprocess.run([rig] + args + [f], cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"
    return p.returncode, normalize(p.stdout + "\n--stderr--\n" + p.stderr, tmp)


def package(rig, f, tmp, keep=None):
    """`pkg`: the exit status of `RIG_SANITIZE=1 rig emit f`, and a hash of
    every file of the package it writes, each by its path; with `keep`,
    the package is moved there."""
    d = tempfile.mkdtemp(dir=tmp)
    env = dict(os.environ, RIG_OUT_DIR=d, RIG_SANITIZE="1")
    try:
        p = subprocess.run([rig, "emit", f], cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        shutil.rmtree(d, ignore_errors=True)
        return -1, "TIMEOUT"
    h = hashlib.sha256()
    listing = []
    for dirpath, dirs, files in os.walk(d):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(dirpath, name)
            data = open(path, "rb").read()
            rel = os.path.relpath(path, d)
            listing.append("%s %s" % (hashlib.sha256(data).hexdigest(), rel))
            h.update(b"%d:%s%d:" % (len(rel), rel.encode(), len(data)) + data)
    if keep:
        shutil.rmtree(keep, ignore_errors=True)
        shutil.move(d, keep)
    else:
        shutil.rmtree(d, ignore_errors=True)
    files = "\n".join(listing)
    return p.returncode, "package %s\n%s\n--stderr--\n%s" % (h.hexdigest(), files, normalize(p.stderr, d))


def digest(result):
    rc, text = result
    return rc, hashlib.sha256(text.encode()).hexdigest()


class OldCache:
    """The old compiler's (exit status, output hash) per section and input,
    in a file per old binary; it only grows, by appended lines."""

    def __init__(self, rig, cache_dir):
        self.rig, self.lock, self.entries, self.path = rig, threading.Lock(), {}, None
        self.listings = {}
        if cache_dir is None or os.environ.get("RIG_STD"):
            return  # the standard library would be an input of every program
        os.makedirs(cache_dir, exist_ok=True)
        binary = hashlib.sha256(open(rig, "rb").read()).hexdigest()
        self.binary = binary
        self.path = os.path.join(cache_dir, binary + ".tsv")
        if os.path.exists(self.path):
            for line in open(self.path):
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 3:
                    self.entries[parts[0]] = (int(parts[1]), parts[2])

    def listing(self, d):
        """The exact names in directory d (a file system may ignore case)."""
        with self.lock:
            if d not in self.listings:
                self.listings[d] = set(os.listdir(d)) if os.path.isdir(d) else set()
            return self.listings[d]

    def key(self, name, args, f):
        """A hash of everything `rig ARGS f` reads: the program, and each
        module beside it a `use` in any of them could name (`use NAME`
        reads NAME.rig in the root's directory), present or not."""
        h = hashlib.sha256()
        for part in [self.binary, name, repr(args), f] + ["%s=%s" % (k, os.environ.get(k, "")) for k in ENV_KEYS]:
            h.update(b"%d:" % len(part.encode()) + part.encode())
        d = os.path.dirname(os.path.join(ROOT, f))
        todo, seen = [os.path.basename(f)], set()
        while todo:
            file = todo.pop()
            if file in seen:
                continue
            seen.add(file)
            path = os.path.join(d, file)
            data = open(path, "rb").read() if file in self.listing(d) or file == os.path.basename(f) else None
            h.update(b"%d:%s" % (len(file), file.encode()))
            h.update(b"missing" if data is None else b"%d:" % len(data) + data)
            if data is None:
                # A file system that ignores case reads `Lib.rig` from
                # `lib.rig`, and rig reports the other name: the names
                # that differ only in case are inputs too.
                for other in sorted(e for e in self.listing(d) if e.casefold() == file.casefold()):
                    h.update(b"case:%d:%s" % (len(other.encode()), other.encode()))
            if data is not None:
                todo.extend(m.decode() + ".rig" for m in re.findall(rb"\buse\s+([A-Za-z_][A-Za-z0-9_]*)", data))
        return h.hexdigest()

    def get(self, name, args, f, tmp):
        if self.path is None:
            return digest(run(self.rig, args, f, tmp))
        k = self.key(name, args, f)
        hit = self.entries.get(k)
        if hit is not None:
            return hit
        result = digest(run(self.rig, args, f, tmp))
        # A timeout, or a compiler a signal killed, says nothing about the
        # program; nor does an accepted program's failure (see compare).
        if result[0] >= 0 and (result[0] == 0 or name in dict(SECTIONS)):
            with self.lock:
                self.entries[k] = result
                with open(self.path, "a") as out:
                    out.write("%s\t%d\t%s\n" % (k, result[0], result[1]))
        return result


def compare(old, new, f, tmp):
    diffs = []
    a_ok = b_ok = False
    for name, args in SECTIONS:
        a, b = old.get(name, args, f, tmp), digest(run(new, args, f, tmp))
        if a != b:
            diffs.append(name)
        if name == "check":
            a_ok, b_ok = a[0] == 0, b[0] == 0
    if a_ok and b_ok:
        for name, args in ACCEPTED:
            a, b = old.get(name, args, f, tmp), digest(run(new, args, f, tmp))
            if 2 in (a[0], b[0]):  # an option one compiler lacks
                continue
            if a[0] != 0 or b[0] != 0:
                # An accepted program's section cannot fail: equal
                # failures (a full disk, a crash) prove nothing.
                diffs.append(name + "(failed)")
            elif a != b:
                diffs.append(name)
    return f, diffs


def cache_dir():
    """rig-equiv-cache in the repository's git directory, shared by its
    worktrees; None outside a git checkout."""
    if not os.path.exists(os.path.join(ROOT, ".git")):
        return None
    r = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                       cwd=ROOT, capture_output=True, text=True)
    return os.path.join(r.stdout.strip(), "rig-equiv-cache") if r.returncode == 0 else None


def main():
    argv = sys.argv[1:]
    jobs = int(argv[argv.index("-j") + 1]) if "-j" in argv else 2
    keep = argv[argv.index("--keep") + 1] if "--keep" in argv else None
    pos = [a for i, a in enumerate(argv) if not a.startswith("-") and (i == 0 or argv[i - 1] not in ("-j", "--keep"))]
    if len(pos) != 2:
        sys.exit(__doc__)
    old_rig, new = (os.path.abspath(p) for p in pos)
    old = OldCache(old_rig, None if "--no-cache" in argv else cache_dir())
    tmp = tempfile.mkdtemp(prefix="rig-equiv-")
    docdir = os.path.join(ROOT, ".equiv-docs")
    shutil.rmtree(docdir, ignore_errors=True)
    try:
        progs = programs(docdir)
        changed = 0
        with cf.ThreadPoolExecutor(jobs) as ex:
            for f, diffs in ex.map(lambda f: compare(old, new, f, tmp), progs):
                if diffs:
                    changed += 1
                    print("%s: %s" % (f, " ".join(diffs)))
                    if keep:
                        for name, args in SECTIONS + ACCEPTED:
                            if name in diffs or name + "(failed)" in diffs:
                                base = os.path.join(keep, f.replace("/", "__") + "." + name)
                                if args is None:
                                    package(old_rig, f, tmp, base + ".old.d")
                                    package(new, f, tmp, base + ".new.d")
                                open(base + ".old", "w").write(run(old_rig, args, f, tmp)[1])
                                open(base + ".new", "w").write(run(new, args, f, tmp)[1])
        print("%d programs, %d differ" % (len(progs), changed))
        sys.exit(1 if changed else 0)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(docdir, ignore_errors=True)


if __name__ == "__main__":
    if "--keep" in sys.argv:
        os.makedirs(sys.argv[sys.argv.index("--keep") + 1], exist_ok=True)
    main()
