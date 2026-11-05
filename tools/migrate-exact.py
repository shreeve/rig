#!/usr/bin/env python3
"""tools/migrate-exact.py PATH [RIG]: add `exact` to each object that
`extend_from_bytes` makes from bytes, where `rig check` of the program
PATH (its root file) asks for it: "add `exact` to `obj Name`". Rig
0.3.1 reads only `exact` objects from bytes (CHANGELOG, "Upgrading").
Each fix edits the object's declaration, `obj Name` or `pub obj Name`
(before any `:` and its APIs), in the file of the program that declares
it, then checks again until nothing more is asked. Prints each edit;
exits 1 if `rig check` still fails for another reason."""
import os, re, subprocess, sys

def check(rig, path):
    r = subprocess.run([rig, "check", path], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    rig = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("RIG", "rig")
    root = os.path.dirname(os.path.abspath(path))
    done = set()
    while True:
        code, out = check(rig, path)
        names = sorted(set(re.findall(r"add `exact` to `obj ([A-Za-z_][A-Za-z0-9_]*)`", out)) - done)
        if not names:
            if code != 0:
                print(out, end="")
                return 1
            return 0
        for name in names:
            done.add(name)
            decl = re.compile(r"^((?:pub\s+)?obj\s+" + re.escape(name) + r")(\s*(?::.*)?)$")
            hit = False
            for d, _, files in os.walk(root):
                for f in files:
                    if not f.endswith(".rig"):
                        continue
                    p = os.path.join(d, f)
                    lines = open(p).read().split("\n")
                    for i, l in enumerate(lines):
                        m = decl.match(l)
                        if m and " exact" not in l:
                            lines[i] = m.group(1) + " exact" + m.group(2)
                            open(p, "w").write("\n".join(lines))
                            print("%s:%d: obj %s exact" % (os.path.relpath(p), i + 1, name))
                            hit = True
            if not hit:
                print("migrate-exact: no declaration of `obj %s` under %s" % (name, root), file=sys.stderr)

if __name__ == "__main__":
    sys.exit(main())
