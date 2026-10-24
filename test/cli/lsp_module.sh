# `rig lsp` and `rig check` on a file of a directory module: the file is
# checked as its module (`ModuleGraph.rootOf`), whose imports are beside
# the directory, so a `use` of a sibling module or a name another file
# declares is no error. A real error in the open file's text, saved or
# not, is published at its line; one in another file of the module, to
# that file. A file of a program's directory, and a lone file, are still
# their own roots. The server's checking allocator reports any leak on
# stderr, which must stay empty.
source "$ROOT/test/cli/_lib.sh"

# A program: main.rig and util.rig, and the directory module shapes/,
# whose files use util (beside the directory) and each other's names. Its
# own util.rig names nothing: a `use util` there says nothing about
# where shapes/ is.
mkdir -p prog/shapes counts lone
cat >prog/main.rig <<'EOF'
use shapes
use util

sub main()
  print(shapes.Square(side: util.double(1)).big())
EOF
cat >prog/util.rig <<'EOF'
pub fun double(n: Int) -> Int
  n * 2
EOF
cat >prog/shapes/square.rig <<'EOF'
use util

pub obj Square
  pub side: Int

fun grow(n: Int) -> Int
  util.double(n)
EOF
cat >prog/shapes/area.rig <<'EOF'
pub fun Square.area(?@) -> Int
  @side * @side

pub fun Square.big(?@) -> Int
  grow(@area())
EOF
cat >prog/shapes/util.rig <<'EOF'
pub fun twice(n: Int) -> Int
  n * 2
EOF
printf 'test "a private helper"\n  print(grow(3))\n' >prog/shapes/area_test.rig

# A directory module that uses only the standard library.
printf 'pub fun one() -> Int\n  two() - 1\n' >counts/a.rig
printf 'pub fun two() -> Int\n  2\n' >counts/b.rig

# A lone file, with an error.
printf 'pub fun f() -> Int\n  missing\n' >lone/lib.rig

# A file that does not parse is its own root, whatever its directory.
mkdir typing
printf 'pub fun f() -> Int\n  (1 +\n' >typing/a.rig
printf 'pub fun g() -> Int\n  nope\n' >typing/b.rig

out=$("$RIG" run prog/main.rig 2>&1); expect_rc $? 0 "rig run: $out"
expect_eq "$out" "8" "rig run"
for f in prog/shapes/area.rig prog/shapes/area_test.rig prog/util.rig counts/a.rig; do
  out=$("$RIG" check "$f" 2>&1); expect_rc $? 0 "rig check $f: $out"
done
out=$("$RIG" check lone/lib.rig 2>&1); expect_rc $? 1 "rig check lone/lib.rig"
expect_has "$out" "lone/lib.rig:2:3: error: use of unbound name \`missing\`" "a lone file is its own root"
out=$("$RIG" check typing/a.rig 2>&1); expect_rc $? 1 "rig check typing/a.rig"
expect_has "$out" "typing/a.rig:" "a file that does not parse"
[[ $out == *b.rig* ]] && fail "a file that does not parse is checked alone: $out"

python3 - "$RIG" "$ROOT" <<'PY' || exit 1
import json, os, sys

rig, root = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "test", "cli"))
import _lsp

failed = False


def check(got, want, what):
    global failed
    if got != want:
        failed = True
        print(f"FAIL: {what}:\n  expected {json.dumps(want)}\n  got      {json.dumps(got)}")


def text(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def open_doc(c, path, body=None):
    c.notify("textDocument/didOpen", {"textDocument": {"uri": _lsp.uri(path), "languageId": "rig", "version": 1, "text": text(path) if body is None else body}})
    return {n["params"]["uri"]: n["params"]["diagnostics"] for n in c.sync() if n.get("method") == "textDocument/publishDiagnostics"}


def close(c, path):
    c.notify("textDocument/didClose", {"textDocument": {"uri": _lsp.uri(path)}})
    return {n["params"]["uri"]: n["params"]["diagnostics"] for n in c.sync() if n.get("method") == "textDocument/publishDiagnostics"}


def errors(diags):
    return [(d["range"]["start"]["line"], d["range"]["start"]["character"], d["message"]) for d in diags]


area, square = "prog/shapes/area.rig", "prog/shapes/square.rig"
c = _lsp.Client(rig)
c.request("initialize", {"capabilities": {}})
c.notify("initialized", {})

# A file of a directory module: no error for its `use`s or its module's names.
for path in (area, square, "prog/shapes/area_test.rig", "counts/a.rig"):
    check(open_doc(c, path), {_lsp.uri(path): []}, f"{path} checks as its module")
    check(close(c, path), {_lsp.uri(path): []}, f"closing {path}")

# A real error in the editor's text of the open file, not saved: at its line.
broken = text(area).replace("@side * @side", "@side * missing")
check({u: errors(d) for u, d in open_doc(c, area, broken).items()},
      {_lsp.uri(area): [(1, 10, "use of unbound name `missing`")]}, "an error in the open file")
close(c, area)

# An error in another file of the module, published to that file.
good = text(square)
with open(square, "w") as f:
    f.write(good.replace("util.double(n)", "util.double(n) + nope"))
published = open_doc(c, area)
check({u: errors(d) for u, d in published.items()},
      {_lsp.uri(area): [], _lsp.uri(square): [(6, 19, "use of unbound name `nope`")]}, "an error in another file of the module")
check(close(c, area), {_lsp.uri(area): [], _lsp.uri(square): []}, "closing clears the other file")
with open(square, "w") as f:
    f.write(good)

# A file of a program's directory, and a lone file, are their own roots,
# with what `rig check` gives for them.
for path in ("prog/util.rig", "prog/main.rig", "lone/lib.rig", "typing/a.rig"):
    status, cli = _lsp.cli_diagnostics(rig, path, os.getcwd())
    check(sorted(_lsp.lsp_diagnostics(c, path)), sorted(cli), f"{path} as `rig check` gives it")
check(errors(open_doc(c, "lone/lib.rig")[_lsp.uri("lone/lib.rig")]), [(1, 2, "use of unbound name `missing`")], "a lone file's error")
close(c, "lone/lib.rig")

c.request("shutdown")
status, err = c.finish()
check([status, err], [0, ""], "exit after shutdown: status 0, nothing on stderr (no leak)")
sys.exit(1 if failed else 0)
PY
