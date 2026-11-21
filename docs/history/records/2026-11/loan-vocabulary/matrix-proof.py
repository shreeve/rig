#!/usr/bin/env python3
"""matrix-proof.py [BASE]: test/matrix.py makes the same programs as at
BASE (default origin/main), under the cell names the view vocabulary
renames, and test/oracle/rejections names the same cells.

Run from the checkout's root. Writes every cell's program with BASE's
test/matrix.py and with this checkout's (as `--oracle --keep` would,
without running the oracle), renames BASE's cell ids by `new_id`, and
checks that the two sets of ids are equal and each program is
byte-identical; then that BASE's rejections, renamed by `new_id`, are
this checkout's line for line. Exits 0 when all hold.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile

ROOT = os.getcwd()


def new_id(ident):
    """A matrix cell's id at BASE, renamed."""
    parts = ident.split(".")
    fam = parts[0]
    if fam == "lendw":
        parts[0] = "vieww"
        parts[1] = {"match_branch_lent_on": "match_branch_viewed_on",
                    "match_call_lent_on": "match_call_viewed_on",
                    "copied_branch_write_view_and_lend": "copied_branch_write_view_and_view"}.get(parts[1], parts[1])
    elif fam == "payload":
        parts[2] = {"lend": "view", "generic_lend_call": "generic_view_call"}.get(parts[2], parts[2])
    elif fam == "dloop":
        parts[1] = {"lent": "viewed"}.get(parts[1], parts[1])
    elif fam == "rootidx":
        parts = [{"lend": "wview"}.get(p, p) for p in parts]
    else:
        parts = [{"lend_arg": "view_arg", "recv_write_lent": "recv_write_viewed"}.get(p, p) for p in parts]
    return ".".join(parts)


def cells(script, work):
    """{id: program text} of every cell `script` makes."""
    spec = importlib.util.spec_from_file_location("matrix_" + str(abs(hash(script))), script)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    got = {}

    def capture(work_, cells_, args):
        for ident, path in cells_:
            with open(path) as f:
                got[ident] = f.read()
        return 0
    m.run_oracle = capture
    sys.argv = ["matrix.py", "--oracle", "--keep", work, "--rig", os.path.join(ROOT, "bin", "rig")]
    try:
        m.main()
    except SystemExit:
        pass
    return got


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else "origin/main"
    work = tempfile.mkdtemp(prefix="rig-matrix-proof.")
    # BASE's script finds the checkout from its own path, so it runs
    # from test/ for as long as it takes to write its programs.
    old_script = os.path.join(ROOT, "test", ".matrix-proof-base.py")
    with open(old_script, "w") as f:
        f.write(subprocess.run(["git", "show", f"{base}:test/matrix.py"], capture_output=True, text=True, check=True).stdout)
    try:
        old = cells(old_script, os.path.join(work, "base"))
    finally:
        os.unlink(old_script)
    new = cells(os.path.join(ROOT, "test", "matrix.py"), os.path.join(work, "cur"))
    renamed = {new_id(k): v for k, v in old.items()}
    moved = sum(1 for k in old if new_id(k) != k)
    bad = []
    if len(renamed) != len(old):
        bad.append("two cells at BASE take one name")
    if set(renamed) != set(new):
        bad.append(f"ids differ: {sorted(set(renamed) ^ set(new))[:10]}")
    bad += [f"{k}: the program differs" for k in sorted(set(renamed) & set(new)) if renamed[k] != new[k]]
    rej_old = subprocess.run(["git", "show", f"{base}:test/oracle/rejections"], capture_output=True, text=True, check=True).stdout.split("\n")
    rej_new = open(os.path.join(ROOT, "test", "oracle", "rejections")).read().split("\n")
    renamed_rej = [l if not l or l.startswith("#") else new_id(l.split(" ", 1)[0]) + " " + l.split(" ", 1)[1] for l in rej_old]
    rej_moved = sum(1 for a, b in zip(rej_old, renamed_rej) if a != b)
    if renamed_rej != rej_new:
        bad.append("test/oracle/rejections is not BASE's renamed")
    print(f"matrix-proof: test/matrix.py at {base} and this checkout")
    print(f"{len(old)} cells at BASE, {len(new)} now; {moved} renamed; every program byte-identical: {not bad}")
    print(f"test/oracle/rejections: {len(rej_new)} lines, {rej_moved} renamed, the rest unchanged: {renamed_rej == rej_new}")
    for b in bad[:20]:
        print("  " + b)
    subprocess.run(["rm", "-rf", work])
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
