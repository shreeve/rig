# The diagnostics `rig lsp` publishes are the compiler's own: for every
# program of test/reject (`<name>.rig` or `<name>/main.rig`), opening its
# root in the server publishes, in each file, exactly the diagnostics
# `rig check` prints for it (the line, the column in UTF-16 units, the
# severity, and the message), a note in the standard library built into
# the compiler as its error's related information. Then a change to the
# root's text that leaves its meaning alone (a comment appended) publishes
# the parse errors the server reads as the text is typed: none, or exactly
# what `rig check` printed, when the root does not parse.
source "$ROOT/test/cli/_lib.sh"

python3 - "$RIG" "$ROOT" <<'PY' || exit 1
import glob, os, sys

rig, root = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "test", "cli"))
import _lsp

roots = []
for p in sorted(glob.glob(os.path.join(root, "test", "reject", "*", "*"))):
    if p.endswith(".rig"):
        roots.append(p)
    elif os.path.isfile(os.path.join(p, "main.rig")):
        roots.append(os.path.join(p, "main.rig"))
if len(roots) < 1000:
    print(f"FAIL: only {len(roots)} programs in test/reject")
    sys.exit(1)

c = _lsp.Client(rig)
c.request("initialize", {"capabilities": {}})
c.notify("initialized", {})
failed = 0
typed = 0
for path in roots:
    rel = os.path.relpath(path, root)
    status, cli = _lsp.cli_diagnostics(rig, path, os.path.dirname(path))
    if status != 1 or not cli:
        print(f"FAIL: {rel}: `rig check` exited {status} with {len(cli)} diagnostics")
        failed += 1
        continue
    got = _lsp.lsp_diagnostics(c, path)
    if sorted(got) != sorted(cli):
        failed += 1
        print(f"FAIL: {rel}: the server's diagnostics differ from `rig check`'s")
        for d in sorted(set(cli) - set(got)):
            print("  only rig check:", d)
        for d in sorted(set(got) - set(cli)):
            print("  only rig lsp:  ", d)
        continue

    # As typed: the same text with a comment line after it.
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
        text = f.read()
    edited = text + ("#\n" if text.endswith("\n") else "\n#\n")
    uri = _lsp.uri(path)
    c.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "rig", "version": 1, "text": text}})
    c.sync()
    c.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": 2}, "contentChanges": [{"text": edited}]})
    notes = [n["params"] for n in c.sync() if n.get("method") == "textDocument/publishDiagnostics"]
    c.notify("textDocument/didClose", {"textDocument": {"uri": uri}})
    c.sync()
    if len(notes) != 1 or notes[0]["uri"] != uri:
        failed += 1
        print(f"FAIL: {rel}: a change published {len(notes)} times")
        continue
    as_typed = [(_lsp.path_of(uri), d["range"]["start"]["line"], d["range"]["start"]["character"],
                 "error" if d["severity"] == 1 else "note", d["message"]) for d in notes[0]["diagnostics"]]
    if as_typed:
        typed += 1
        if sorted(as_typed) != sorted(cli):
            failed += 1
            print(f"FAIL: {rel}: the parse errors as typed differ from `rig check`'s diagnostics")
            for d in sorted(set(cli) - set(as_typed)):
                print("  only rig check:", d)
            for d in sorted(set(as_typed) - set(cli)):
                print("  only as typed: ", d)

c.request("shutdown")
status, err = c.finish()
if status != 0 or err:
    failed += 1
    print(f"FAIL: rig lsp exited {status}: {err}")
if typed < 100:
    failed += 1
    print(f"FAIL: only {typed} programs fail to parse; the as-typed check proves little")
print(f"{len(roots)} programs, {typed} of them parse errors as typed, {failed} failed")
sys.exit(1 if failed else 0)
PY
