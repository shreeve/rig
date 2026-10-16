#!/usr/bin/env python3
"""A small LSP client for the tests of `rig lsp` (test/cli/lsp.sh).

`Client(rig)` starts `rig lsp` and speaks JSON-RPC to it over its stdin and
stdout, each message after a `Content-Length` header. `request` sends a
request and returns its response, keeping every notification that came
before it in `notes`; `notify` sends a notification. The server answers
each message before it reads the next, so a request after a notification
is a barrier: its response comes after everything the notification made.
"""
import json
import os
import re
import subprocess


class Client:
    def __init__(self, rig, env=None):
        self.proc = subprocess.Popen(
            [rig, "lsp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env if env is not None else os.environ.copy(),
        )
        self.next_id = 0
        self.notes = []

    def send(self, msg):
        body = json.dumps(msg).encode()
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.proc.stdin.flush()

    def read(self):
        length = None
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise EOFError("rig lsp closed its output: " + self.proc.stderr.read().decode())
            line = line.rstrip(b"\r\n")
            if not line:
                break
            name, _, value = line.partition(b":")
            if name.strip().lower() == b"content-length":
                length = int(value)
        return json.loads(self.proc.stdout.read(length))

    def request(self, method, params=None):
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)
        while True:
            reply = self.read()
            if reply.get("id") == self.next_id and "method" not in reply:
                return reply
            self.notes.append(reply)

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)

    def sync(self):
        """Everything the server sent since the last call, up to a barrier."""
        self.request("rig/sync")
        notes, self.notes = self.notes, []
        return notes

    def finish(self):
        """`exit`, then the exit status and what the server wrote on stderr."""
        self.notify("exit")
        self.proc.stdin.close()
        status = self.proc.wait(timeout=60)
        return status, self.proc.stderr.read().decode()


def uri(path):
    """The `file:` URI of a path, as an editor writes it."""
    from urllib.parse import quote

    return "file://" + quote(os.path.abspath(path))


def path_of(file_uri):
    from urllib.parse import unquote

    assert file_uri.startswith("file://"), file_uri
    return unquote(file_uri[len("file://"):])


HEADER = re.compile(r"^(.+?):(\d+):(\d+): (error|  note): (.*)$")

# A note's message with its place in front, `std/x.rig:3:5: ...`.
PLACED = re.compile(r"^\S+\.rig:\d+:\d+: ")


def utf16_column(path, line, col):
    """The UTF-16 units before the `col`th character (1-based, as `rig
    check` counts them: one per UTF-8 character, a byte order mark none)
    of line `line` of the file at `path`."""
    with open(path, "rb") as f:
        text = f.read()
    if text.startswith(b"\xef\xbb\xbf"):
        text = text[3:]
    row = text.split(b"\n")[line - 1].decode("utf-8", errors="surrogateescape")
    return len(row[: col - 1].encode("utf-16-le", errors="surrogatepass")) // 2


def cli_diagnostics(rig, root, cwd):
    """`rig check ROOT`'s diagnostics, run in `cwd`: one (path, line,
    character, severity, message) for each, the path absolute and the
    character in UTF-16 units from 0, as the language server gives them. A
    note in the standard library built into the compiler, which has no file
    to open, is ("", ...) with its place in the message."""
    run = subprocess.run([rig, "check", root], cwd=cwd, capture_output=True, text=True)
    lines = run.stderr.split("\n")
    out = []
    i = 0
    while i < len(lines):
        m = HEADER.match(lines[i])
        i += 1
        if not m:
            continue
        path, line, col, sev, message = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4).strip(), m.group(5)
        full = os.path.join(cwd, path)
        if not os.path.exists(full):
            out.append(("", 0, 0, sev, f"{path}:{line}:{col}: {message}"))
        else:
            out.append((os.path.abspath(full), line - 1, utf16_column(full, line, col), sev, message))
        i += 2  # the excerpt and its underline
    return run.returncode, out


def lsp_diagnostics(client, root):
    """What the language server publishes when `root` is opened: the same
    tuples as `cli_diagnostics`, a note in a file no editor can open given
    by the related information of its error."""
    with open(root, encoding="utf-8", errors="surrogateescape", newline="") as f:
        text = f.read()
    client.notify("textDocument/didOpen", {"textDocument": {"uri": uri(root), "languageId": "rig", "version": 1, "text": text}})
    out = []
    for n in client.sync():
        if n.get("method") != "textDocument/publishDiagnostics":
            continue
        path = path_of(n["params"]["uri"])
        for d in n["params"]["diagnostics"]:
            start = d["range"]["start"]
            out.append((path, start["line"], start["character"], "error" if d["severity"] == 1 else "note", d["message"]))
            for r in d.get("relatedInformation", []):
                if r["location"] == {"uri": n["params"]["uri"], "range": d["range"]} and PLACED.match(r["message"]):
                    out.append(("", 0, 0, "note", r["message"]))
    client.notify("textDocument/didClose", {"textDocument": {"uri": uri(root)}})
    client.sync()
    return out
