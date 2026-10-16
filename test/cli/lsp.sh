# `rig lsp` over stdio, driven by test/cli/_lsp.py: the lifecycle, the
# diagnostics of a parse error, an ownership error, and an error in an
# imported file, as the file is opened, changed, and saved; semantic
# tokens, document symbols, and folding ranges; positions in UTF-16 and
# UTF-8 on a line with a character outside the Basic Multilingual Plane.
# The server's checking allocator reports any leak on stderr, which must
# stay empty.
source "$ROOT/test/cli/_lib.sh"

cat >parse.rig <<'EOF'
sub main()
  x = (1 +
  print(x)
EOF

cat >own.rig <<'EOF'
obj Box
  v: Int

sub take(b: Box)
  print(b.v)

sub main()
  b = Box(v: 1)
  take(<b)
  print(b.v)
EOF

cat >shapes.rig <<'EOF'
# Shapes, and how big they are.
# Two comment lines fold.
pub obj Square unique
  side: Int

  fun area(?self) -> Int
    self.side * self.side

  sub grow(!self, by: Int)
    self.side += by

enum Color
  red
  green

sub main()
  s = Square(side: 2)
  new t = <s
  print(t.area()) if t.side > 0
EOF

cat >lib.rig <<'EOF'
pub fun twice(n: Int) -> Int
  n * missing
EOF

cat >uses.rig <<'EOF'
use lib

sub main()
  print(lib.twice(2))
EOF

printf 'sub main()\n  s = "\xf0\x9f\x98\x80\xc3\xa9"; x = 1\n' >wide.rig

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


def open_doc(c, path, version=1):
    c.notify("textDocument/didOpen", {"textDocument": {"uri": _lsp.uri(path), "languageId": "rig", "version": version, "text": text(path)}})
    return {n["params"]["uri"]: n["params"] for n in c.sync() if n.get("method") == "textDocument/publishDiagnostics"}


def rng(l1, c1, l2, c2):
    return {"start": {"line": l1, "character": c1}, "end": {"line": l2, "character": c2}}


def decode(data, legend, source):
    """The semantic tokens as (line, character, text, type, modifiers)."""
    lines = source.split("\n")
    out, line, col = [], 0, 0
    for i in range(0, len(data), 5):
        dl, dc, n, ty, mods = data[i : i + 5]
        line, col = (line + dl, dc) if dl else (line, col + dc)
        units = lines[line].encode("utf-16-le")
        word = units[col * 2 : (col + n) * 2].decode("utf-16-le")
        names = [m for b, m in enumerate(legend["tokenModifiers"]) if mods >> b & 1]
        out.append([line, col, word, legend["tokenTypes"][ty]] + names)
    return out


# --- before initialize, and the lifecycle ---------------------------------
c = _lsp.Client(rig)
early = c.request("textDocument/documentSymbol", {"textDocument": {"uri": _lsp.uri("own.rig")}})
check(early.get("error", {}).get("code"), -32002, "a request before initialize")
init = c.request("initialize", {"processId": None, "rootUri": None, "capabilities": {}})["result"]
caps = init["capabilities"]
check(caps["positionEncoding"], "utf-16", "the default position encoding")
check(caps["textDocumentSync"], {"openClose": True, "change": 1, "save": {"includeText": False}}, "text sync")
check([caps.get("documentSymbolProvider"), caps.get("foldingRangeProvider")], [True, True], "providers")
check(sorted(caps), ["documentSymbolProvider", "foldingRangeProvider", "positionEncoding", "semanticTokensProvider", "textDocumentSync"], "only what is built is advertised")
legend = caps["semanticTokensProvider"]["legend"]
check(init["serverInfo"]["name"], "rig", "server name")
c.notify("initialized", {})
c.notify("rig/unknownNotification", {})
unknown = c.request("rig/unknownRequest", {})
check(unknown.get("error", {}).get("code"), -32601, "an unknown request")

# --- a parse error, on open ----------------------------------------------
published = open_doc(c, "parse.rig")
check(list(published), [_lsp.uri("parse.rig")], "the files a parse error publishes to")
check(published[_lsp.uri("parse.rig")]["diagnostics"], [
    {"range": rng(2, 10, 2, 10), "severity": 1, "source": "rig", "message": "unexpected end of block; expected `,` or `)`", "relatedInformation": [
        {"location": {"uri": _lsp.uri("parse.rig"), "range": rng(1, 6, 1, 7)}, "message": "the `(` opened here is not closed"}]},
    {"range": rng(1, 6, 1, 7), "severity": 3, "source": "rig", "message": "the `(` opened here is not closed", "relatedInformation": [
        {"location": {"uri": _lsp.uri("parse.rig"), "range": rng(2, 10, 2, 10)}, "message": "unexpected end of block; expected `,` or `)`"}]},
], "the parse error and its note")

# --- an ownership error, with its note as related information -------------
published = open_doc(c, "own.rig")
own = _lsp.uri("own.rig")
check(published[own]["diagnostics"], [
    {"range": rng(9, 8, 9, 8), "severity": 1, "source": "rig", "message": "use of `b` after move",
     "relatedInformation": [{"location": {"uri": own, "range": rng(8, 8, 8, 8)}, "message": "`b` was moved here"}]},
    {"range": rng(8, 8, 8, 8), "severity": 3, "source": "rig", "message": "`b` was moved here",
     "relatedInformation": [{"location": {"uri": own, "range": rng(9, 8, 9, 8)}, "message": "use of `b` after move"}]},
], "the use after move")
check(published[own]["version"], 1, "the version diagnostics are for")

# --- typing: parse errors as they come, the check again on save ----------
fixed = text("own.rig").replace("print(b.v)\n", "print(1)\n").replace("take(<b)", "take(<b")
c.notify("textDocument/didChange", {"textDocument": {"uri": own, "version": 2}, "contentChanges": [{"text": fixed}]})
diags = [n["params"] for n in c.sync()]
check([(d["version"], [x["message"] for x in d["diagnostics"]]) for d in diags],
      [(2, ["unexpected name `print`", "the `(` opened here is not closed"])], "a parse error as it is typed")
fixed = fixed.replace("take(<b", "take(<b)")
c.notify("textDocument/didChange", {"textDocument": {"uri": own, "version": 3}, "contentChanges": [{"text": fixed}]})
check([(n["params"]["version"], n["params"]["diagnostics"]) for n in c.sync()], [(3, [])], "the parse error fixed")
with open("own.rig", "w") as f:
    f.write(fixed)
c.notify("textDocument/didSave", {"textDocument": {"uri": own}})
check([(n["params"]["version"], n["params"]["diagnostics"]) for n in c.sync()], [(3, [])], "the check on save")

# --- an error in an imported file, published to that file ----------------
published = open_doc(c, "uses.rig")
check(sorted(published), sorted([_lsp.uri("uses.rig"), _lsp.uri("lib.rig")]), "the files an import's error publishes to")
check(published[_lsp.uri("lib.rig")]["diagnostics"], [
    {"range": rng(1, 6, 1, 13), "severity": 1, "source": "rig", "message": "use of unbound name `missing`"}], "the import's error")
check(published[_lsp.uri("uses.rig")]["diagnostics"], [], "the importer's own diagnostics")
c.notify("textDocument/didClose", {"textDocument": {"uri": _lsp.uri("uses.rig")}})
check(sorted((n["params"]["uri"], n["params"]["diagnostics"]) for n in c.sync()),
      sorted([(_lsp.uri("uses.rig"), []), (_lsp.uri("lib.rig"), [])]), "closing clears what the check published")

# --- semantic tokens, symbols, folding ------------------------------------
published = open_doc(c, "shapes.rig")
check(published[_lsp.uri("shapes.rig")]["diagnostics"], [], "shapes.rig checks clean")
doc = {"textDocument": {"uri": _lsp.uri("shapes.rig")}}
tokens = decode(c.request("textDocument/semanticTokens/full", doc)["result"]["data"], legend, text("shapes.rig"))
by_line = {}
for t in tokens:
    by_line.setdefault(t[0], []).append(t[1:])
check(by_line[2], [[0, "pub", "keyword"], [4, "obj", "keyword"], [8, "Square", "struct", "declaration"], [15, "unique", "keyword"]], "an obj header with `unique`")
check(by_line[5], [[2, "fun", "keyword"], [6, "area", "method", "declaration"], [11, "?", "modifier"], [12, "self", "parameter", "declaration"], [18, "->", "operator"]], "a method taking `?self`")
check(by_line[8], [[2, "sub", "keyword"], [6, "grow", "method", "declaration"], [11, "!", "modifier"], [12, "self", "parameter", "declaration"], [18, "by", "parameter", "declaration"]], "a method taking `!self`")
check(by_line[17], [[2, "new", "keyword"], [8, "=", "operator"], [10, "<", "modifier"]], "`new` and a move")
check(by_line[18], [[10, "area", "method"], [18, "if", "keyword", "control"], [23, "side", "property"], [28, ">", "operator"], [30, "0", "number"]], "a method called, a postfix `if`, and a field")
check(by_line[0], [[0, "# Shapes, and how big they are.", "comment"]], "a comment")

symbols = c.request("textDocument/documentSymbol", doc)["result"]
def outline(syms, depth=0):
    out = []
    for s in syms:
        r = s["range"]
        out.append("  " * depth + f"{s['kind']} {s['name']} {s['detail']} {r['start']['line']}:{r['start']['character']}-{r['end']['line']}:{r['end']['character']}")
        out += outline(s["children"], depth + 1)
    return out
check(outline(symbols), [
    "23 Square obj 2:0-9:19",
    "  8 side Int 3:2-3:11",
    "  6 area fun 5:2-6:25",
    "  6 grow sub 8:2-9:19",
    "10 Color enum 11:0-13:7",
    "  22 red  12:2-12:5",
    "  22 green  13:2-13:7",
    "12 main sub 15:0-18:31",
], "document symbols")
check(symbols[0]["selectionRange"], rng(2, 8, 2, 14), "an object's name")

folds = c.request("textDocument/foldingRange", doc)["result"]
check(folds, [
    {"startLine": 0, "endLine": 1, "kind": "comment"},
    {"startLine": 2, "endLine": 9},
    {"startLine": 5, "endLine": 6},
    {"startLine": 8, "endLine": 9},
    {"startLine": 11, "endLine": 13},
    {"startLine": 15, "endLine": 18},
], "folding ranges")

# --- UTF-16: a character outside the BMP is two units ---------------------
published = open_doc(c, "wide.rig")
check([d["range"] for d in published[_lsp.uri("wide.rig")]["diagnostics"]], [rng(1, 11, 1, 11)], "a position after a surrogate pair, in UTF-16")
wide = decode(c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": _lsp.uri("wide.rig")}})["result"]["data"], legend, text("wide.rig"))
check([t for t in wide if t[0] == 1], [[1, 4, "=", "operator"], [1, 6, '"😀é"', "string"], [1, 11, ";", "invalid"], [1, 15, "=", "operator"], [1, 17, "1", "number"]], "a string holding a surrogate pair, in UTF-16")

# --- a long line: positions are counted once per line, not once per token --
import time
long_text = "sub main()\n  x = [" + ", ".join(str(i) for i in range(40000)) + "]\n"
c.notify("textDocument/didOpen", {"textDocument": {"uri": "untitled:long", "languageId": "rig", "version": 1, "text": long_text}})
c.sync()
began = time.time()
data = c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": "untitled:long"}})["result"]["data"]
took = time.time() - began
check(len(data) // 5, 2 + 1 + 40000, "the tokens of a 230 KB line")
check(took < 10, True, f"the tokens of a 230 KB line in {took:.1f}s")
c.notify("textDocument/didClose", {"textDocument": {"uri": "untitled:long"}})
c.sync()

# --- shutdown, exit -------------------------------------------------------
check(c.request("shutdown"), {"jsonrpc": "2.0", "id": c.next_id, "result": None}, "shutdown")
late = c.request("textDocument/documentSymbol", doc)
check(late.get("error", {}).get("code"), -32600, "a request after shutdown")
status, err = c.finish()
check([status, err], [0, ""], "exit after shutdown: status 0, nothing on stderr (no leak)")

# --- UTF-8, when the client offers it -------------------------------------
c = _lsp.Client(rig)
init = c.request("initialize", {"capabilities": {"general": {"positionEncodings": ["utf-8", "utf-16"]}}})["result"]
check(init["capabilities"]["positionEncoding"], "utf-8", "the negotiated encoding")
c.notify("initialized", {})
published = open_doc(c, "wide.rig")
check([d["range"] for d in published[_lsp.uri("wide.rig")]["diagnostics"]], [rng(1, 14, 1, 14)], "a position after a surrogate pair, in UTF-8")
status, err = c.finish()
check([status, err], [1, ""], "exit without shutdown: status 1")

sys.exit(1 if failed else 0)
PY
